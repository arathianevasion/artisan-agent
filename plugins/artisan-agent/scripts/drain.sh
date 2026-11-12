#!/usr/bin/env bash
# The context drain: how full a session's context is, what that lets it do,
# and the orchestrator's hand-off to a fresh orchestrator for the same wave.
# The rules, for both tiers: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/context-drain.md.
#
#   (thresholds: the run's plan.config.context, defaults 30 and 50)
#   | Context              | Band   | Does                                                  |
#   | under drain (30%)    | normal | dispatch                                              |
#   | drain up to review   | drain  | dispatch nothing new; keep processing; hand off idle  |
#   | review (50%) and up  | review | as drain, and every merge processed gets a risk gate  |
#
# Usage:
#   drain.sh percent --transcript FILE [--window TOKENS]
#       the session's context use from its transcript's last main-thread usage
#       record (input + cache creation + cache read + output tokens) against
#       the model's window. Prints "<percent> <used> <window>", or "unknown"
#       when the transcript is missing or has no usage yet.
#   drain.sh decide --tier chat|orchestrator --percent P|unknown --outstanding N
#                   [--marker] [--drain P] [--review P]
#       the rule alone. Prints "<band> <percent>% <action>[ risk-gate]":
#         action dispatch   carry on as normal
#                process    dispatch nothing new; keep processing results
#                handoff    hand off now: nothing is outstanding, or (an
#                           orchestrator's --marker) compaction was blocked
#       band is normal, drain, review, compact (the marker) or unknown (no
#       reading: treated as normal; the marker is the backstop).
#   drain.sh check <run-dir> [--tier orchestrator|chat] [--transcript FILE]
#       decide from the run's files. Orchestrator (the default; its session
#       from $ARTISAN_RESULT_FILE, else the last orchestrator): outstanding is
#       its workers in flight and verifiers not yet judged, the transcript is
#       the one its SessionStart hook recorded, the marker is its PreCompact
#       hook's. Chat: outstanding is a running orchestrator; pass the
#       transcript the chat's SessionStart line named. Thresholds come from
#       the state file's plan.config.context.
#   drain.sh handoff <run-dir>
#       the orchestrator hands its wave on: records why in the state file
#       (orchestrators[].handoff, event "handoff"), launches the next
#       orchestrator for the same wave (wave.sh launch --handoff, which takes
#       the state lock over), and writes the hand-off report to
#       $ARTISAN_RESULT_FILE. Prints "handed-off <id> <attempt> <pid>", or
#       "none" when nothing in scope is queued, in flight or returned (write
#       the wave report and exit as usual).
#   drain.sh chat <run-dir> --transcript FILE
#       the Engineering chat's context, which never asks the Artisan to compact
#       (Claude Code compacts it at chat_context.compact_percent, default 40,
#       through CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in the project settings).
#       Prints "<state> <percent>%" with state
#         ok            at or below chat_context.warn_percent (30): say nothing
#         warn          above it: end the message with the one-line warning
#         warn ask      past compact_percent + 15 (55) with no compaction:
#                       also ask once for /compact. Printed once; the marker
#                       <run-dir>/chat-compact-asked is cleared when the
#                       reading falls back under the line (a compaction)
#         unknown -     no reading: say nothing
#       The window is ARTISAN_CONTEXT_WINDOW, else chat_context.window_tokens
#       (1,000,000, the Opus chat's window; recorded, never forced).
#   drain.sh gate <run-dir> <ticket> <percent>
#       a merge processed at the review band: a risk gate on the merged
#       ticket. Its dependents don't dispatch until it is cleared (wave.sh
#       dispatch exit 5, and the reconciler leaves them off the frontier);
#       nothing else waits. A decision for the Artisan, event "risk-gate".
#   drain.sh gate-cleared <run-dir> <ticket> [--by NAME]
#       the Artisan reviewed it: its dependents may dispatch.
#
# Environment: ARTISAN_CONTEXT_WINDOW overrides the window (tokens). Without
# it the window is 1,000,000 for a model id ending "[1m]" or once the context
# used is past 200,000 tokens (it can only be the larger window), else 200,000.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 4 the
# ticket is outside the scope, 6 refused (gate: the ticket isn't merged;
# handoff: this session isn't the run's orchestrator).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

DEFAULT_WINDOW=200000

# The drain and review thresholds' defaults, from templates/config.yml (the
# one place defaults are written), for a run or a call that doesn't give them.
default_threshold() { # drain_percent|review_percent
  "$SCRIPT_DIR/config.sh" defaults | jq -r --arg k "$1" '.context[$k]'
}
LARGE_WINDOW=1000000

usage() { state_usage "$0"; }
die() { state_die 1 "drain.sh: $*"; }

# ----------------------------------------------------------------- percent

# The last main-thread record carrying usage (subagents' sidechain records
# don't fill this session's context): "<used> <model>".
last_usage() { # transcript
  jq -r 'select(type == "object" and .type == "assistant" and (.isSidechain // false) == false
               and (.message.usage? | type) == "object")
         | .message as $m
         | "\(($m.usage.input_tokens // 0) + ($m.usage.cache_creation_input_tokens // 0)
              + ($m.usage.cache_read_input_tokens // 0) + ($m.usage.output_tokens // 0)) \($m.model // "-")"' \
    "$1" 2>/dev/null | tail -n 1
}

percent_of() { # transcript window-or-empty -> "<percent> <used> <window>" or "unknown"
  local line used model window
  [ -n "$1" ] && [ -f "$1" ] || { echo unknown; return 0; }
  line=$(last_usage "$1" || true)
  [ -n "$line" ] || { echo unknown; return 0; }
  used=${line%% *} model=${line#* }
  window=${2:-${ARTISAN_CONTEXT_WINDOW:-}}
  if [ -z "$window" ]; then
    window=$DEFAULT_WINDOW
    case "$model" in *'[1m]') window=$LARGE_WINDOW ;; esac
    [ "$used" -le "$window" ] || window=$LARGE_WINDOW
  fi
  awk -v u="$used" -v w="$window" 'BEGIN { printf "%d %d %d\n", (u * 100) / w, u, w }'
}

cmd_percent() {
  local transcript= window=
  while [ $# -gt 0 ]; do
    case "$1" in
      --transcript) [ $# -ge 2 ] || usage; transcript=$2; shift 2 ;;
      --window) [ $# -ge 2 ] || usage; window=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$transcript" ] || usage
  [ -z "$window" ] || printf '%s' "$window" | grep -Eq '^[1-9][0-9]*$' || usage
  percent_of "$transcript" "$window"
}

# ------------------------------------------------------------------ decide

decide() { # tier percent outstanding marker drain review
  local tier="$1" pct="$2" outstanding="$3" marker="$4" drain="$5" review="$6" band action shown
  if [ "$tier" = orchestrator ] && [ "$marker" = 1 ]; then
    band=compact
  elif [ "$pct" = unknown ]; then
    band=unknown
  elif [ "$pct" -lt "$drain" ]; then
    band=normal
  elif [ "$pct" -lt "$review" ]; then
    band=drain
  else
    band=review
  fi
  case "$band" in
    normal | unknown) action=dispatch ;;
    compact) action=handoff ;;   # finish the step and go, agents outstanding or not
    *) if [ "$outstanding" -gt 0 ]; then action=process; else action=handoff; fi ;;
  esac
  shown="$pct%"
  [ "$pct" != unknown ] || shown=-
  if [ "$band" = review ] || { [ "$band" = compact ] && [ "$pct" != unknown ] && [ "$pct" -ge "$review" ]; }; then
    echo "$band $shown $action risk-gate"
  else
    echo "$band $shown $action"
  fi
}

is_percent() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }

cmd_decide() {
  local tier= pct= outstanding= marker=0 drain= review=
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) [ $# -ge 2 ] || usage; tier=$2; shift 2 ;;
      --percent) [ $# -ge 2 ] || usage; pct=$2; shift 2 ;;
      --outstanding) [ $# -ge 2 ] || usage; outstanding=$2; shift 2 ;;
      --marker) marker=1; shift ;;
      --drain) [ $# -ge 2 ] || usage; drain=$2; shift 2 ;;
      --review) [ $# -ge 2 ] || usage; review=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$tier" in chat | orchestrator) ;; *) usage ;; esac
  [ "$pct" = unknown ] || is_percent "$pct" || usage
  [ -n "$drain" ] || drain=$(default_threshold drain_percent)
  [ -n "$review" ] || review=$(default_threshold review_percent)
  is_percent "$outstanding" && is_percent "$drain" && is_percent "$review" || usage
  decide "$tier" "$pct" "$outstanding" "$marker" "$drain" "$review"
}

# ------------------------------------------------------------------- check

# The orchestrator session this call belongs to: "<id>.<attempt>".
session_key() {
  if [ -n "${ARTISAN_RESULT_FILE:-}" ]; then
    basename "$ARTISAN_RESULT_FILE" .result.json
  else
    get '(.orchestrators // []) | last // empty | "\(.id).\(.attempt)"'
  fi
}

last_orchestrator_running() {
  local line
  line=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt)"')
  [ -n "$line" ] || return 1
  set -- $line
  case "$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$1" "$2" 2>/dev/null || true)" in
    running*) return 0 ;;
  esac
  return 1
}

# Sets DECISION (the decide line), KEY and PCT.
KEY= PCT= DECISION=
check() { # tier transcript
  local tier="$1" transcript="$2" outstanding marker=0 drain review reading
  drain=$(get '.plan.config.context.drain_percent // empty')
  [ -n "$drain" ] || drain=$(default_threshold drain_percent)
  review=$(get '.plan.config.context.review_percent // empty')
  [ -n "$review" ] || review=$(default_threshold review_percent)
  if [ "$tier" = orchestrator ]; then
    KEY=$(session_key)
    [ -n "$KEY" ] || die "no orchestrator in run $RUN_ID"
    [ -n "$transcript" ] || transcript=$(cat "$RUN_DIR/workers/$KEY/transcript.path" 2>/dev/null || true)
    [ ! -e "$RUN_DIR/workers/$KEY/handoff.json" ] || marker=1
    outstanding=$(get '([.tickets[] | select(.status == "in_flight")] | length)
               + ([.tickets[] | .verifications[]? | select(.verdict == null)] | length)')
  else
    if last_orchestrator_running; then outstanding=1; else outstanding=0; fi
  fi
  reading=$(percent_of "$transcript" "")
  PCT=${reading%% *}
  DECISION=$(decide "$tier" "$PCT" "$outstanding" "$marker" "$drain" "$review")
}

cmd_check() {
  open_run "${1:-}"
  shift
  local tier=orchestrator transcript=
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) [ $# -ge 2 ] || usage; tier=$2; shift 2 ;;
      --transcript) [ $# -ge 2 ] || usage; transcript=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$tier" in chat | orchestrator) ;; *) usage ;; esac
  check "$tier" "$transcript"
  echo "$DECISION"
}

# ----------------------------------------------------------------- handoff

cmd_handoff() {
  open_run "${1:-}"
  local line id attempt pid me remaining band reason launched
  line=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt)"')
  [ -n "$line" ] || state_die 6 "drain.sh: run $RUN_ID has no orchestrator to hand off from"
  set -- $line
  id=$1 attempt=$2
  pid=$(cat "$RUN_DIR/workers/$id.$attempt/runner.pid" 2>/dev/null || echo -)
  me=$(writer)
  [ "$me" = "$pid" ] || state_die 6 "drain.sh: only the run's running orchestrator ($id, pid $pid) hands off; this writer is $me"

  remaining=$(get '[.plan.scope[] as $t | .tickets[$t].status
                    | select(. == "queued" or . == "in_flight" or . == "returned")] | length')
  if [ "$remaining" -eq 0 ]; then
    echo none
    return 0
  fi

  check orchestrator ""
  band=${DECISION%% *}
  case "$band" in
    compact) reason="compaction blocked: hand-off marker" ;;
    drain | review) reason="context $PCT% ($band band), idle" ;;
    *) reason="asked to hand off at context $PCT%" ;;
  esac

  apply '
    (.orchestrators | length - 1) as $i
    | .orchestrators[$i].handoff = {reason: $reason, percent: $pct, at: $now}
    | event({event: "handoff", id: $id, attempt: $a, wave: current_wave, reason: $reason, percent: $pct}; $now)' \
    --arg id "$id" --argjson a "$attempt" --arg reason "$reason" \
    --argjson pct "$(if [ "$PCT" = unknown ]; then echo null; else echo "$PCT"; fi)"

  launched=$("$SCRIPT_DIR/wave.sh" launch "$RUN_DIR" --handoff) || {
    # Nothing handed off: take the record back, so the wave reads as this
    # orchestrator's still, and carry on.
    apply '(.orchestrators | length - 1) as $i | .orchestrators[$i] |= del(.handoff)
      | event({event: "handoff-failed", id: $id, attempt: $a}; $now)' --arg id "$id" --argjson a "$attempt" || true
    die "could not launch the next orchestrator; carry the wave on yourself"
  }
  set -- $launched
  if [ -n "${ARTISAN_RESULT_FILE:-}" ]; then
    jq -n --arg run "$RUN_ID" --argjson wave "$(get '((.orchestrators // []) | last | .wave) // 0')" \
      --arg from "$id.$attempt" --arg to "$1" --argjson ta "$2" --argjson tp "$3" --arg reason "$reason" \
      '{run_id: $run, wave: $wave, handoff: {from: $from, to: $to, attempt: $ta, runner_pid: $tp, reason: $reason}}' \
      >"$ARTISAN_RESULT_FILE"
  fi
  echo "handed-off $launched"
}

# -------------------------------------------------------------------- chat

CHAT_ASK_MARGIN=15

chat_setting() { # key: the run's plan config, else the default
  local v
  v=$(get --arg k "$1" '.plan.config.chat_context[$k] // empty')
  [ -n "$v" ] || v=$("$SCRIPT_DIR/config.sh" defaults | jq -r --arg k "$1" '.chat_context[$k]')
  printf '%s\n' "$v"
}

cmd_chat() {
  open_run "${1:-}"
  shift
  local transcript= warn compact window reading pct marker state
  while [ $# -gt 0 ]; do
    case "$1" in
      --transcript) [ $# -ge 2 ] || usage; transcript=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$transcript" ] || usage
  warn=$(chat_setting warn_percent)
  compact=$(chat_setting compact_percent)
  window=${ARTISAN_CONTEXT_WINDOW:-$(chat_setting window_tokens)}
  reading=$(percent_of "$transcript" "$window")
  pct=${reading%% *}
  marker="$RUN_DIR/chat-compact-asked"
  if [ "$pct" = unknown ]; then
    echo "unknown -"
    return 0
  fi
  if [ "$pct" -le "$warn" ]; then
    state=ok
  else
    state=warn
  fi
  if [ "$pct" -gt $((compact + CHAT_ASK_MARGIN)) ]; then
    if [ ! -e "$marker" ]; then
      printf '%s\n' "$pct" >"$marker"
      state="warn ask"
    fi
  else
    rm -f "$marker"
  fi
  echo "$state $pct%"
}

# -------------------------------------------------------------------- gate

cmd_gate() {
  [ $# -eq 3 ] || usage
  open_run "$1"
  is_percent "$3" || usage
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$2" || exit $?
  [ "$(get --arg t "$2" '.tickets[$t].status')" = merged ] \
    || state_die 6 "drain.sh: #$2 is not merged; a risk gate is for a merge processed at the review band"
  apply '
    if .tickets[$t].risk_gate.status? == "waiting" then .
    else .tickets[$t].risk_gate = {status: "waiting", percent: $pct, at: $now}
      | .decisions += [{id: ((.decisions | length) + 1), kind: "risk-gate", ticket: $t,
          question: "#\($t) merged while the orchestrator was at \($pct)% context. Recommended: look over its merge before its dependents start; they wait for it, nothing else does. Clear it, or block its dependents?",
          status: "waiting", at: $now}]
      | event({event: "risk-gate", ticket: $t, percent: $pct}; $now) end' \
    --arg t "$2" --argjson pct "$3"
}

cmd_gate_cleared() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local t="$2" by=Artisan
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$(get --arg t "$t" '.tickets[$t].risk_gate.status? // ""')" = waiting ] \
    || state_die 6 "drain.sh: #$t has no risk gate waiting"
  apply '
    .tickets[$t].risk_gate.status = "cleared"
    | .tickets[$t].risk_gate.cleared_at = $now
    | .decisions |= map(if .kind == "risk-gate" and .ticket == $t and .status == "waiting"
                        then .status = "decided" | .choice = "clear" | .by = $by | .job = 13 | .changed = false | .decided_at = $now
                        else . end)
    | event({event: "risk-gate-cleared", ticket: $t, by: $by}; $now)' \
    --arg t "$t" --arg by "$by"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  percent) cmd_percent "$@" ;;
  decide) cmd_decide "$@" ;;
  chat) cmd_chat "$@" ;;
  check) cmd_check "$@" ;;
  handoff) cmd_handoff "$@" ;;
  gate) cmd_gate "$@" ;;
  gate-cleared) cmd_gate_cleared "$@" ;;
  *) usage ;;
esac
