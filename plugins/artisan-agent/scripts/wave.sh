#!/usr/bin/env bash
# A run's waves: its integration worktree, the orchestrator that runs each
# wave, and the orchestrator's steps for one ticket. The two tiers and who
# calls what: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/SKILL.md and
# references/orchestrator.md beside it. State file: references/state-file.md.
#
# Usage, from the Engineering chat:
#   wave.sh start <run-dir> [--base REF]
#       create the integration branch (from REF, default the main checkout's
#       branch) and the run's integration worktree beside the repo, at
#       <repo>-wt/run-<run-id>; record both. Prints the worktree. Idempotent.
#   wave.sh launch <run-dir> [--resume] [--handoff] [--model M] [--estimate-usd N] [-- claude args...]
#       launch the next wave's orchestrator: a detached headless claude -p
#       under run-ticket.sh --role orchestrator, in the integration worktree.
#       The state lock passes to the orchestrator's runner for the wave.
#       Prints "orchestrator-w<wave> <attempt> <runner-pid>". 12: the run
#       halted (a whole wave failed); --resume is the Artisan's decision to
#       carry on, and clears the halt. --handoff is for drain.sh handoff
#       only: the running orchestrator, having recorded its hand-off, launches
#       the next attempt of the same wave and hands it the lock (6 from anyone
#       else); the wave's guardrails are not read again.
#   wave.sh status <run-dir>
#       how the run stands, from files only: the orchestrator's exit record
#       and classification, then (once it has ended) the reconciler (git, the
#       sweep, the tracker). First line "orchestrator: <state>", second
#       "next: <launch|wait|halted|decide|blocked|done>", then a
#       ticket table. A waiting risk gate (drain.sh gate) holds only its
#       ticket's dependents: next is still launch while the frontier has work.
#
# Usage, from the orchestrator:
#   wave.sh dispatch <run-dir> <ticket> [--brief TEXT]
#       refuse unless the ticket is in scope (4), queued, every blocker is
#       merged into the integration branch or closed (5), a slot is free
#       under Max Agents (9) and its expected files overlap no ticket in
#       flight or in this wave (10, wave-width.sh check); then branch a
#       worktree from the integration tip and launch the worker with
#       /artisan-agent:implement. A retry is a fresh worker on the same
#       branch, given the failed attempt's evidence, and only once the
#       failed attempt's session has ended (8 until then). Prints its pid.
#   wave.sh merge <run-dir> <ticket>
#       merge a completed worker's branch --no-ff into the integration
#       branch in the integration worktree, run the plan's suite command
#       there, record the merge and remove the worker's worktree. Prints the
#       merge commit. 8: the worker is still running. 13: not verified (no
#       passing verdict from verify.sh for this attempt and commit; nothing
#       changes). 11: a conflict, left in
#       progress for its one /artisan-agent:resolve-conflicts try (then
#       wave.sh resolved; the conflicted paths are a JSON array in the state
#       file's conflict event, exactly as git reports them). 6: refused, or a conflict after that try was used,
#       7: suite red (both mark the ticket blocked and queue a decision).
#       An attempt that did not complete is a failed attempt: queued for a
#       fresh worker, or blocked once it has used its attempts (6).
#   wave.sh resolved <run-dir> <ticket> [--gave-up REASON]
#       after /artisan-agent:resolve-conflicts: commit the resolved merge and
#       run the suite as merge does. 6: still conflicted, markers, unstaged
#       changes or untracked files left, or gave up (the merge is aborted
#       and the untracked files removed); 7: suite red. Either way the ticket is blocked
#       with its branch and worktree kept.
#   wave.sh block <run-dir> <ticket> <reason>
#       block a returned ticket the orchestrator won't merge (its diff misses
#       the expected output): queues an exception decision, logs the event.
#   wave.sh close <run-dir> <ticket>
#       post the evidence contract on the ticket (evidence.sh comment), tick
#       its met criteria, close it.
#   wave.sh report <run-dir>
#       the wave report (JSON) the orchestrator writes as its result file.
#       Halts the run first if every ticket dispatched in this wave failed.
#
# Environment:
#   ARTISAN_WRITER_PID      the long-lived pid writing state (the chat's
#                           session between waves; set for the orchestrator)
#   ARTISAN_CLAUDE_ARGS     extra arguments, split on whitespace, added to
#                           every orchestrator and worker session
#   ARTISAN_MAX_BUDGET_USD  ceiling on any one session's --max-budget-usd
#                           (for trials; caps are otherwise twice the estimate)
#
# Exit status: 0 ok, 1 error, 2 usage, 3 lock held or an orchestrator still
# running, 4 outside the scope, 5 a blocker not merged, 6 merge refused or
# conflicted, 7 suite red, 8 worker still running, 9 no free slot, 10
# expected files overlap, 11 conflict awaiting its one resolution try,
# 12 the run is halted, 13 not verified, 15 the login would expire mid-run. One table of every code, with
# verify.sh's: scripts/README.md, "Exit status".
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

DEFAULT_ORCHESTRATOR_MODEL=claude-sonnet-5-5
DEFAULT_ORCHESTRATOR_ESTIMATE_USD=1
SESSION_TOOLS="Bash,Read,Write,Edit,Glob,Grep,Skill,Agent"

usage() { state_usage "$0"; }
die() { state_die 1 "wave.sh: $*"; }

# ----------------------------------------------------------------- helpers

# halt_if_wave_failed: once nothing in the current wave is still in flight,
# returned or waiting to retry, and every ticket dispatched in it (two or
# more) failed, the run halts: a decision for the Artisan, and no wave
# launches until they resume it. A ticket failed when it is blocked for any
# reason but its worker's own design question (result status "blocked"); a
# one-ticket wave failing is that ticket's own exception decision. Idempotent.
halt_if_wave_failed() {
  apply '
    current_wave as $w
    | [.tickets | to_entries[] | select(.value.wave != null and .value.wave == $w)] as $d
    | if $w == 0 or .halted != null or ($d | length) < 2
         or ([$d[] | select(.value.status != "blocked" or .value.result.status? == "blocked")] | length) > 0 then .
      else ([$d[].key]) as $ts
        | .halted = {wave: $w, tickets: $ts, at: $now,
                     reason: "every ticket dispatched in wave \($w) failed"}
        | .decisions += [{id: ((.decisions | length) + 1), kind: "halt",
            question: "Wave \($w) failed whole (\($ts | map("#" + .) | join(", "))): something upstream is likely wrong. Recommended: look at the blocked tickets for a shared cause (a broken base, a missing setup step, a bad spec) and fix it before resuming; resume as is, reslice or end the run?",
            status: "waiting", at: $now}]
        | event({event: "halted", wave: $w, tickets: $ts}; $now)
      end'
}

# ------------------------------------------------------------------- start

cmd_start() {
  open_run "${1:-}"
  shift
  local base= ib wt sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || usage; base=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  ib=$(integration_branch)
  get '.repo' | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die "the plan's repo must be owner/name on the tracker (as docs/agents/issue-tracker.md names it), not $(get .repo)"
  if [ -z "$base" ]; then
    base=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$MAIN" rev-parse HEAD)
  fi
  if ! git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib" >/dev/null; then
    git -C "$MAIN" branch "$ib" "$base" >/dev/null || die "could not create $ib from $base"
  fi
  wt="$WT_ROOT/run-$RUN_ID"
  if [ ! -d "$wt" ]; then
    mkdir -p "$WT_ROOT"
    git -C "$MAIN" worktree add -q "$wt" "$ib" >/dev/null 2>&1 \
      || die "could not add the integration worktree $wt for $ib"
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  apply '
    if .integration.worktree == $wt then .
    else .integration.worktree = $wt
         | .integration.base = (.integration.base // $sha)
         | event({event: "integration", branch: .integration.branch, worktree: $wt, base: $sha}; $now)
    end' --arg wt "$wt" --arg sha "$sha"
  printf '%s\n' "$wt"
}

# ------------------------------------------------------------------ launch

# Last orchestrator: "id attempt wave pid", or nothing. Its pid is its
# runner's, from the runner's own pid file ("-" before it has one).
last_orchestrator() {
  local line pid
  line=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt) \(.wave)"')
  [ -n "$line" ] || return 0
  set -- $line
  pid=$(cat "$RUN_DIR/workers/$1.$2/runner.pid" 2>/dev/null || echo -)
  printf '%s %s\n' "$line" "$pid"
}

orchestrator_state() { # id attempt -> classify-worker.sh's line
  "$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$1" "$2" 2>/dev/null || echo "failed vanished"
}

cmd_launch() {
  open_run "${1:-}"
  shift
  local model= estimate= args=() resume=0 handoff=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) resume=1; shift ;;
      --handoff) handoff=1; shift ;;
      --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
      --estimate-usd) [ $# -ge 2 ] || usage; estimate=$2; shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) usage ;;
    esac
  done
  local wt last id attempt wave pid cls me deadline minutes prompt runner
  wave=1 attempt=1
  last=$(last_orchestrator)
  if [ -n "$last" ]; then
    set -- $last
    id=$1 attempt=$2 wave=$3 pid=$4
    cls=$(orchestrator_state "$id" "$attempt")
    # A hand-off (drain.sh handoff): the running orchestrator, which recorded
    # why, launches the next one for the same wave before it exits.
    if [ "$handoff" -eq 1 ]; then
      [ "$(writer)" = "$pid" ] && [ "$(get '(.orchestrators | last | .handoff) != null')" = true ] \
        || state_die 6 "wave.sh: --handoff is for the running orchestrator that recorded its hand-off (drain.sh handoff)"
      cls=handoff
    fi
    case "$cls" in
      handoff) attempt=$((attempt + 1)) ;;
      running*) state_die 3 "wave.sh: the orchestrator for wave $wave is still running (pid $pid)" ;;
      completed*) wave=$((wave + 1)) attempt=1 ;;
      *) attempt=$((attempt + 1)) ;;   # it ended without finishing: carry the same wave on
    esac
  fi
  id="orchestrator-w$wave"
  wt=$(integration_worktree)

  # A run on the always-on host must not outlive the claude.ai login (#69):
  # checked before every orchestrator launch but a hand-off (exit 15, nothing
  # launched), so a run moved onto the host is checked there too, against the
  # tickets it has left. A machine with no host record is not checked.
  if [ "$handoff" -eq 0 ]; then
    "$SCRIPT_DIR/login-check.sh" check --run-dir "$RUN_DIR" >&2 || exit $?
  fi

  # The chat's writer pid holds the lock (or takes it now) until it hands it on.
  me=$(writer)
  state_lock "$RUN_DIR" "$me" || exit 3
  export ARTISAN_WRITER_PID=$me

  if [ "$(get '.halted != null')" = true ]; then
    [ "$resume" -eq 1 ] || state_die 12 "wave.sh: the run is halted: $(get '.halted.reason'); nothing launches until the Artisan decides (wave.sh launch --resume carries on)"
    apply '
      .decisions |= map(if .kind == "halt" and .status == "waiting"
                        then .status = "decided" | .choice = "resume" | .by = "Artisan" | .decided_at = $now
                        else . end)
      | event({event: "resumed", wave: .halted.wave}; $now)
      | .halted = null'
  fi

  [ -n "$model" ] || model=$(get --arg d "$DEFAULT_ORCHESTRATOR_MODEL" '.plan.orchestrator.model // $d')
  [ -n "$estimate" ] || estimate=$(get --arg d "$DEFAULT_ORCHESTRATOR_ESTIMATE_USD" '.plan.orchestrator.estimate_usd // $d')
  estimate=$(clamp_estimate "$estimate")
  # The orchestrator outlives every worker it waits on: its deadline is the
  # longest worker deadline plus half an hour.
  deadline=$(get '.plan.orchestrator.deadline_seconds // (([.plan.tickets[]?.caps.deadline_seconds // 0] | max // 0) + 1800)')
  minutes=$(awk -v s="$deadline" 'BEGIN { printf "%d", (s / 120 < 1 ? 1 : s / 120) }')

  mkdir -p "$RUN_DIR/prompts"
  prompt="$RUN_DIR/prompts/$id.$attempt.md"
  cat >"$prompt" <<EOF
You are the orchestrator for wave $wave of run $RUN_ID. Follow $PLUGIN_DIR/skills/implement-plan/references/orchestrator.md exactly; it is your whole brief.

- Run folder: $RUN_DIR
- Integration worktree: $wt (branch $(integration_branch)); you are in it.
- Scripts: $PLUGIN_DIR/scripts
- Your state-writer pid is already exported as ARTISAN_WRITER_PID, and you hold the state lock.
EOF
  if [ "$attempt" -gt 1 ]; then
    printf -- '- An earlier orchestrator for this wave %s. Carry the same wave on from the state file: reconcile first.\n' \
      "$(get '(.orchestrators | last | .handoff) as $h | if $h then "handed off to you (\($h.reason))" else "ended without finishing" end')" >>"$prompt"
  fi

  # Guardrails are read at the point of use: fetch the team, product and
  # individual sources, bring main in if a product guardrail changed, record
  # each commit and the plugin version for this wave (references/guardrails.md).
  # A hand-off carries the wave on with the guardrails its workers were given.
  if [ "$handoff" -eq 0 ]; then
    "$SCRIPT_DIR/guardrails.sh" wave-start "$RUN_DIR" "$wave" >/dev/null \
      || die "could not read the guardrails for wave $wave (guardrails.sh wave-start failed)"
  fi

  apply '
    .orchestrators = ((.orchestrators // []) + [{id: $id, wave: $w, attempt: $a, launched_at: $now}])
    | event({event: "orchestrator", id: $id, wave: $w, attempt: $a}; $now)' \
    --arg id "$id" --argjson w "$wave" --argjson a "$attempt"

  # The runner takes the lock over from this writer before its session
  # starts: the orchestrator is the writer for the wave.
  read_extra_args
  runner=$("$SCRIPT_DIR/run-ticket.sh" --role orchestrator --lock-from "$me" --run-dir "$RUN_DIR" --ticket "$id" \
    --attempt "$attempt" --prompt-file "$prompt" --workdir "$wt" --model "$model" \
    --estimate-usd "$estimate" --expected-minutes "$minutes" --deadline-seconds "$deadline" \
    -- --permission-mode acceptEdits --allowedTools "$SESSION_TOOLS" \
    --add-dir "$MAIN" --add-dir "$WT_ROOT" \
    ${EXTRA[@]+"${EXTRA[@]}"} ${args[@]+"${args[@]}"}) || die "could not launch $id"

  [ "$(state_lock_holder "$RUN_DIR")" = "$runner" ] \
    || die "$id started (pid $runner) but did not take the state lock; see $RUN_DIR/workers/$id.$attempt/runner.log"
  printf '%s %s %s\n' "$id" "$attempt" "$runner"
}

# ------------------------------------------------------------------ status

ticket_table() {
  jq -r '
    . as $s
    | ($s.plan.waves // []) as $w
    | "| Ticket | Wave | Model | Status |",
      "|---|---|---|---|",
      ( $s.plan.scope[] as $t | $s.tickets[$t] as $k | $s.plan.tickets[$t] as $p
        | ([$w | to_entries[] | select(.value | index($t)) | .key + 1] | first // "-") as $wave
        | "| #\($t) (\($p.title // "untitled")) | \($wave) | \($p.model // "-") | \($k.status)"
          + (if $k.status == "merged" then " as \($k.merge_commit[0:7])"
                + (if $k.tracker_closed then ", closed" else ", not closed yet" end)
             elif $k.status == "blocked" then ": \($k.blocked_reason // ($k.failures | last | .reason) // "see decisions")"
             elif $k.status == "in_flight" then " (attempt \($k.attempts))"
             else "" end) + " |" )' "$FILE"
}

# An ended orchestrator's spend, from its session's output, counted once.
record_orchestrator_cost() { # id attempt
  local usd
  usd=$(jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$1.$2/output.json" 2>/dev/null || true)
  [ -n "$usd" ] || return 0
  apply '(.orchestrators | map(.id == $id and .attempt == $a) | index(true)) as $i
    | if $i == null or .orchestrators[$i].cost_usd != null then .
      else .orchestrators[$i].cost_usd = $usd
        | .costs.orchestrator_usd += $usd
        | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd) end' \
    --arg id "$1" --argjson a "$2" --argjson usd "$usd"
}

cmd_status() {
  open_run "${1:-}"
  local last id attempt wave pid cls next reconciled=1 waiting o
  last=$(last_orchestrator)
  if [ -z "$last" ]; then
    echo "orchestrator: none"
  else
    set -- $last
    id=$1 attempt=$2 wave=$3 pid=$4
    cls=$(orchestrator_state "$id" "$attempt")
    echo "orchestrator: $cls (wave $wave, attempt $attempt, pid $pid)"
  fi
  case "${cls:-}" in
    running*) next=wait ;;
    *)
      # Ended (or never started): this tier writes again. Between waves the
      # chat holds the lock with its own long-lived pid.
      if [ -n "${ARTISAN_WRITER_PID:-}" ]; then
        state_lock "$RUN_DIR" "$ARTISAN_WRITER_PID" || exit 3
      fi
      # Every ended orchestrator's spend, a handed-off one's included.
      for o in $(get '(.orchestrators // [])[] | select(.cost_usd == null) | "\(.id).\(.attempt)"'); do
        record_orchestrator_cost "${o%.*}" "${o##*.}"
      done
      # The Artisan's gate actions taken while the lock was held, a gate
      # closed on the tracker, and any slice gate due (gate.sh, #65).
      "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.gate.err" \
        || echo "gate.sh sync failed: $(tr '\n' ' ' <"$RUN_DIR/.gate.err")" >&2
      "$SCRIPT_DIR/reconcile.sh" "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.status.err" || {
        reconciled=0
        "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" >/dev/null
      }
      [ -z "${id:-}" ] || halt_if_wave_failed
      # A risk gate or a review gate holds only its tickets' dependents
      # (drain.sh gate, gate.sh): the run carries on while the frontier has work.
      waiting=$(get '[.decisions[] | select(.status == "waiting" and .kind != "risk-gate" and .kind != "review-gate")] | length')
      [ "$(get '.frontier | length')" -gt 0 ] \
        || waiting=$(get '[.decisions[] | select(.status == "waiting")] | length')
      if [ "$(get '.halted != null')" = true ]; then next=halted
      elif [ "$waiting" -gt 0 ]; then next=decide
      elif [ "$reconciled" -eq 0 ]; then next=blocked
      elif [ "$(get '.frontier | length')" -gt 0 ]; then next=launch
      elif [ "$(get '[.plan.scope[] as $t | .tickets[$t].status | select(. == "merged" or . == "closed")] | length')" \
             = "$(get '.plan.scope | length')" ]; then next=done
      else next=blocked
      fi
      ;;
  esac
  echo "next: $next"
  [ "$reconciled" -eq 1 ] || echo "tracker: unreadable, frontier not recomputed ($(tr '\n' ' ' <"$RUN_DIR/.status.err"))"
  [ "$next" != halted ] || get '"halted: \(.halted.reason) (\(.halted.tickets | map("#" + .) | join(", "))); nothing more launches until the Artisan decides"'
  echo
  ticket_table
  if [ "${next}" = decide ] || [ "${next}" = halted ] \
     || { [ "$next" = launch ] && [ "$(get '[.decisions[] | select(.status == "waiting")] | length')" -gt 0 ]; }; then
    echo
    echo "| Decision | Ticket | Question |"
    echo "|---|---|---|"
    get '.decisions[] | select(.status == "waiting") | "| \(.id) (\(.kind)) | \(if .ticket then "#" + .ticket else "-" end) | \(.question) |"'
  fi
}

# ---------------------------------------------------------------- dispatch

# Every blocker of the ticket must be merged into the integration branch (a
# blocker in the run) or closed (one outside it). The tracker says what blocks
# what; git says what is merged. Refuses with 5, or 1 if either can't be read.
check_blockers() { # ticket
  local t="$1" repo ib tip blockers b state status sha
  repo=$(get '.repo')
  ib=$(integration_branch)
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib") || die "no integration branch $ib"
  blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
    || die "could not read the blockers of #$t from the tracker; not dispatching blind"
  for b in $(printf '%s' "$blockers" | jq -r '.[] | "\(.number)=\(.state | ascii_downcase)"'); do
    state=${b#*=} b=${b%%=*}
    status=$(get --arg b "$b" '.tickets[$b].status // ""')
    if [ -n "$status" ]; then
      sha=$(get --arg b "$b" '.tickets[$b].merge_commit // ""')
      if [ "$status" != merged ] || [ -z "$sha" ] || ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        state_die 5 "wave.sh: refusing #$t: its blocker #$b is not merged into $ib (status $status); dispatch only on merged work"
      fi
      [ "$(get --arg b "$b" '.tickets[$b].risk_gate.status? // ""')" != waiting ] \
        || state_die 5 "wave.sh: refusing #$t: its blocker #$b merged under a risk gate the Artisan hasn't cleared (drain.sh gate)"
      [ "$("$SCRIPT_DIR/gate.sh" holds "$RUN_DIR" "$b" 2>/dev/null)" = free ] \
        || state_die 5 "wave.sh: refusing #$t: its blocker #$b is in a slice whose review gate the Artisan hasn't approved (gate.sh)"
    elif [ "$state" != closed ]; then
      state_die 5 "wave.sh: refusing #$t: its blocker #$b, outside this run, is still open"
    fi
  done
}

cmd_dispatch() {
  open_run "${1:-}"
  local t="${2:-}" brief=
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) [ $# -ge 2 ] || usage; brief=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$t" || exit $?
  local status in_flight max
  status=$(get --arg t "$t" '.tickets[$t].status')
  [ "$status" = queued ] || die "#$t is $status, not queued"
  in_flight=$(get '[.tickets[] | select(.status == "in_flight")] | length')
  max=$(get '.plan.max_agents // 5')
  [ "$in_flight" -lt "$max" ] || state_die 9 "wave.sh: no free slot: $in_flight of Max Agents $max in flight"
  check_blockers "$t"
  "$SCRIPT_DIR/wave-width.sh" check "$RUN_DIR" "$t" || exit $?

  local ib base branch n wt prev repo title path expected estimate minutes model turns deadline prompt pid ref
  ib=$(integration_branch)
  base=$(git -C "$MAIN" rev-parse "refs/heads/$ib")
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  n=$(( $(get --arg t "$t" '.tickets[$t].attempts') + 1 ))
  wt="$WT_ROOT/$RUN_ID-$t.$n"
  prev=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  # A fresh worker never starts while the last attempt's session is still
  # ending in its worktree (a worker can report failed before it exits).
  if [ "$n" -gt 1 ]; then
    case "$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$((n - 1))" 2>/dev/null || true)" in
      running*) state_die 8 "wave.sh: #$t's attempt $((n - 1)) is still ending; dispatch the retry once it has" ;;
    esac
  fi
  if [ -n "$prev" ] && [ -d "$prev" ]; then
    # A retry continues the same branch in a fresh worktree; the old one must be clean.
    if ! git -C "$MAIN" worktree remove "$prev" 2>/dev/null; then
      block "$t" "attempt $((n - 1))'s worktree $prev has uncommitted work, so no fresh worker can take the branch"
      state_die 6 "wave.sh: #$t blocked: the previous attempt's worktree $prev has uncommitted work"
    fi
  fi
  mkdir -p "$WT_ROOT"
  if git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git -C "$MAIN" worktree add -q "$wt" "$branch" >/dev/null 2>&1 || die "could not add worktree $wt for $branch"
  else
    git -C "$MAIN" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 || die "could not add worktree $wt"
  fi

  repo=$(get '.repo')
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  path=$(get --arg t "$t" '.plan.tickets[$t].ticket_path // ""')
  expected=$(get --arg t "$t" '.plan.tickets[$t].expected_output // "see the ticket'"'"'s acceptance criteria"')
  estimate=$(clamp_estimate "$(get --arg t "$t" '.plan.tickets[$t].estimate_usd // 1')")
  minutes=$(get --arg t "$t" '.plan.tickets[$t].expected.minutes // 30')
  model=$(get --arg t "$t" '.plan.tickets[$t].model // ""')
  turns=$(get --arg t "$t" '.plan.tickets[$t].caps.max_turns // ""')
  deadline=$(get --arg t "$t" '.plan.tickets[$t].caps.deadline_seconds // ""')
  if [ -n "$path" ]; then ref="$path (ticket $t)"; else ref="#$t on $repo"; fi

  mkdir -p "$RUN_DIR/prompts"
  prompt="$RUN_DIR/prompts/$t.$n.md"
  cat >"$prompt" <<EOF
/artisan-agent:implement $ref: $title

You are the worker for ticket $t, attempt $n, in run $RUN_ID.
- Base: $base (the integration branch $ib). Your branch: $branch, already checked out here.
- Expected output: $expected
- Plugin version this wave: $(get '.waves | last | .plugin_version // "unknown"'). Guardrails in force for this wave, with their versions: run $SCRIPT_DIR/guardrails.sh resolve --run-dir $RUN_DIR (plugin version and source commits are in the state file's latest wave). Follow them; product beats team beats individual.
- Write the evidence record to the result file named below, as in $PLUGIN_DIR/references/evidence-record.md.
- Do not close the ticket, edit the tracker, merge or push. Do not use git stash; commit instead.
EOF
  [ -z "$brief" ] || printf -- '- Brief: %s\n' "$brief" >>"$prompt"
  # The Artisan's answers to the questions an earlier worker filed (questions.sh).
  if [ "$(get --arg t "$t" '(.tickets[$t].answers // []) | length')" -gt 0 ]; then
    printf -- '- The Artisan has answered what blocked an earlier attempt; treat each answer as decided, and continue from the branch:\n' >>"$prompt"
    get --arg t "$t" '.tickets[$t].answers[] | "  - #\(.question): \(.answer)"' >>"$prompt"
  fi
  if [ "$n" -gt 1 ] && [ "$(get --arg t "$t" '.tickets[$t].failures | length')" -gt 0 ]; then
    printf -- '- This is a retry, attempt %s of %s. The last attempt failed: %s\n' "$n" \
      "$(get '.plan.attempts_per_ticket // 2')" \
      "$(get --arg t "$t" '.tickets[$t].failures | last | "\(.reason)"')" >>"$prompt"
    failure_evidence "$t" "$((n - 1))" >"$RUN_DIR/prompts/$t.$n.failure.md"
    { echo; cat "$RUN_DIR/prompts/$t.$n.failure.md"; } >>"$prompt"
  fi

  read_extra_args
  local caps=()
  [ -z "$turns" ] || caps+=(--max-turns "$turns")
  [ -z "$deadline" ] || caps+=(--deadline-seconds "$deadline")
  [ -z "$model" ] || caps+=(--model "$model")
  pid=$("$SCRIPT_DIR/run-ticket.sh" --run-dir "$RUN_DIR" --ticket "$t" --attempt "$n" \
    --prompt-file "$prompt" --workdir "$wt" --estimate-usd "$estimate" --expected-minutes "$minutes" \
    ${caps[@]+"${caps[@]}"} \
    -- --permission-mode acceptEdits --allowedTools "$SESSION_TOOLS" --add-dir "$RUN_DIR/results" \
    ${EXTRA[@]+"${EXTRA[@]}"}) || die "could not launch the worker for #$t"

  if [ -n "$deadline" ]; then
    "$SCRIPT_DIR/state.sh" dispatch "$RUN_DIR" "$t" "$pid"
  else
    "$SCRIPT_DIR/state.sh" dispatch "$RUN_DIR" "$t" "$pid" \
      "$(awk -v now="$(state_now)" -v m="$minutes" 'BEGIN { printf "%d", now + m * 120 }')"
  fi
  apply 'current_wave as $w | .tickets[$t] |= (.worktree = $wt | .base = $base | .wave = $w)' \
    --arg t "$t" --arg wt "$wt" --arg base "$base"
  printf '%s\n' "$pid"
}

# failure_evidence ticket attempt: what a retry's fresh worker is told about
# the attempt that failed, from that attempt's files and its branch. Bounded:
# a few lines from each source, never a transcript.
failure_evidence() {
  local t="$1" p="$2" w="$RUN_DIR/workers/$1.$2" res="$RUN_DIR/results/$1.$2.result.json"
  local exitf="$RUN_DIR/results/$1.$2.exit.json" branch base log
  echo "## Failure evidence from attempt $p"
  echo
  get --arg t "$t" --argjson p "$p" '.tickets[$t].failures[] | select(.attempt == $p) | "- Why it counted as failed: \(.reason)"'
  echo "- Judged from its files: $("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$p" 2>/dev/null || echo "unknown")"
  [ ! -f "$exitf" ] || jq -r '"- Exit record: \(.reason), exit code \(.exit_code)"' "$exitf" 2>/dev/null || true
  [ ! -f "$w/output.json" ] || jq -r '"- Session: \(.subtype // "-"), is_error \(.is_error | tostring), \(.num_turns // "-") turns"' "$w/output.json" 2>/dev/null || true
  if [ -f "$res" ]; then
    jq -r '
      "- Its evidence record said: status \(.status // "-")"
        + (if .tests then ", suite_passed \(.tests.suite_passed | tostring) (\(.tests.summary // "-"))" else "" end),
      ((.acceptance // [])[] | select(.met != true) | "- Not met: \(.criterion) (\(.evidence.why // "no reason given"))"),
      ((.unsure // [])[] | "- Unsure: \(.)"),
      (if .notes then "- Notes: \(.notes)" else empty end)' "$res" 2>/dev/null || true
  else
    echo "- It wrote no evidence record."
  fi
  # A verifier's fail: what it found unmet, from the contract it judged.
  if [ -f "$RUN_DIR/verify/$t.$p.evidence.json" ]; then
    jq -r '
      "- The verifier found \(.criteria_met) of \(.criteria_total) criteria met:",
      (.acceptance[] | select(.met != true) | "- Unmet (verifier): \(.criterion) (\(.evidence.why // "no reason given"))"),
      ((.verifier.unsure // [])[] | "- The verifier was unsure: \(.)")' "$RUN_DIR/verify/$t.$p.evidence.json" 2>/dev/null || true
  fi
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  base=$(get --arg t "$t" '.tickets[$t].base // ""')
  if [ -n "$base" ] && log=$(git -C "$MAIN" log --oneline -n 10 "$base..refs/heads/$branch" 2>/dev/null) && [ -n "$log" ]; then
    echo "- Its commits, already on $branch (build on them or replace them):"
    printf '%s\n' "$log" | sed 's/^/    /'
  else
    echo "- It left no commits on $branch."
  fi
  if [ -f "$w/output.json" ] && [ -n "$(jq -r '.result // empty' "$w/output.json" 2>/dev/null)" ]; then
    echo "- The end of its last reply:"
    jq -r '.result' "$w/output.json" | tail -n 8 | sed 's/^/    /'
  fi
  if [ -s "$w/stderr.log" ]; then
    echo "- The end of its stderr:"
    tail -n 8 "$w/stderr.log" | sed 's/^/    /'
  fi
}

# ------------------------------------------------------------------- merge

# The sweep can record a result before the session has written its JSON
# output; once the attempt has ended, take its cost from there.
record_session_cost() { # ticket attempt
  local usd
  usd=$(jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$1.$2/output.json" 2>/dev/null || true)
  [ -n "$usd" ] || return 0
  apply 'attempt_cost($t; $n; $usd)
    | .costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
    | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)' --arg t "$1" --argjson n "$2" --argjson usd "$usd"
}

# Paths stay a list end to end: git's -z output (no quoting, no splitting on
# spaces) becomes a JSON array, and only messages join it for display.
unmerged_json() { # worktree
  git -C "$1" diff -z --name-only --diff-filter=U | jq -Rs 'split("\u0000")[:-1]'
}
join_paths() { # JSON array -> "a b c" for messages
  jq -r 'join(" ")' <<<"$1"
}

cmd_merge() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local n branch wt ib suite pre title
  check_returned wave.sh "$t" "not merged"
  n=$ATTEMPT
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  # Only verified work merges: a fresh verifier's pass for this attempt at
  # this commit (verify.sh, references/evidence-contract.md).
  [ "$(get --arg t "$t" --argjson n "$n" --arg tip "$TIP" \
        '.tickets[$t].evidence | if . != null and .verdict == "pass" and .attempt == $n and .commit == $tip then "pass" else "" end')" = pass ] \
    || state_die 13 "wave.sh: #$t not merged: no passing verdict for attempt $n at $TIP; run verify.sh start, then verify.sh judge"
  suite=$(get '.plan.suite_command // ""')
  [ -n "$suite" ] || die "the plan has no suite_command; the full suite must run after every merge"
  wt=$(integration_worktree)
  ib=$(integration_branch)
  abandon_pending_resolution "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "the integration worktree $wt has uncommitted changes"
  pre=$(git -C "$wt" rev-parse HEAD)
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  if ! git -C "$wt" merge --no-ff --no-edit -m "Merge #$t ($title) into $ib" "$branch" >/dev/null 2>&1; then
    local paths pjson
    pjson=$(unmerged_json "$wt")
    paths=$(join_paths "$pjson")
    if [ "$(get --arg t "$t" '.tickets[$t].resolve != null')" = true ] || [ -z "$paths" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
      block "$t" "merge conflict in ${paths:-unknown paths}; its one /artisan-agent:resolve-conflicts try is used"
      state_die 6 "wave.sh: #$t not merged: conflict in ${paths:-unknown paths}"
    fi
    # Left in progress for the one try at resolving it.
    apply '.tickets[$t].resolve = {attempt: $n, paths: $p, pre: $pre, outcome: "pending", at: $now}
      | event({event: "conflict", ticket: $t, paths: $p, next: "resolve-conflicts"}; $now)' \
      --arg t "$t" --argjson n "$n" --argjson p "$pjson" --arg pre "$pre"
    state_die 11 "wave.sh: #$t conflicts in $paths; run /artisan-agent:resolve-conflicts once in $wt, then wave.sh resolved $RUN_DIR $t"
  fi
  finish_merge "$t" "$n" "$wt" "$pre"
}

# The suite after a merge commit is made: green records the merge, red undoes
# it and blocks the ticket (7).
finish_merge() { # ticket attempt worktree pre-merge-commit
  local t="$1" n="$2" wt="$3" pre="$4" suite log sha worker_wt
  suite=$(get '.plan.suite_command')
  mkdir -p "$RUN_DIR/merges"
  log="$RUN_DIR/merges/$t.$n.suite.log"
  if ! (cd "$wt" && sh -c "$suite") >"$log" 2>&1; then
    git -C "$wt" reset -q --hard "$pre"
    apply '.tickets[$t].suite = {command: $c, passed: false, log: $l}' --arg t "$t" --arg c "$suite" --arg l "merges/$t.$n.suite.log"
    block "$t" "the suite failed after merging (merges/$t.$n.suite.log); the merge was undone"
    state_die 7 "wave.sh: #$t not merged: the suite failed after the merge; see $log"
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  "$SCRIPT_DIR/state.sh" merge "$RUN_DIR" "$t" "$sha"
  record_session_cost "$t" "$n"
  apply '.tickets[$t].suite = {command: $c, passed: true, log: $l}' --arg t "$t" --arg c "$suite" --arg l "merges/$t.$n.suite.log"
  worker_wt=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$worker_wt" ] && [ -d "$worker_wt" ]; then
    git -C "$MAIN" worktree remove "$worker_wt" 2>/dev/null \
      || echo "wave.sh: left $worker_wt in place (it has changes); the merge stands" >&2
  fi
  printf '%s\n' "$sha"
}

# A conflict left in progress whose resolution never came back (the
# orchestrator ended mid-try): abort it, and block its ticket, whose one try
# is used. Runs before any other merge.
abandon_pending_resolution() { # integration worktree
  local wt="$1" t
  t=$(get '[.tickets | to_entries[] | select(.value.resolve.outcome? == "pending") | .key] | first // ""')
  [ -n "$t" ] || return 0
  git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$(get --arg t "$t" '.tickets[$t].resolve.pre')"
  apply '.tickets[$t].resolve.outcome = "abandoned"' --arg t "$t"
  block "$t" "its conflict resolution never finished (the merge was aborted); its one /artisan-agent:resolve-conflicts try is used"
}

# --------------------------------------------------------------- resolved

cmd_resolved() {
  open_run "${1:-}"
  local t="${2:-}" gave_up=
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --gave-up) [ $# -ge 2 ] || usage; gave_up=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  local wt ib n pre branch paths pjson left markers title why p
  [ "$(get --arg t "$t" '.tickets[$t].resolve.outcome? // ""')" = pending ] \
    || die "#$t has no conflict waiting on its resolution"
  wt=$(integration_worktree)
  ib=$(integration_branch)
  n=$(get --arg t "$t" '.tickets[$t].resolve.attempt')
  pre=$(get --arg t "$t" '.tickets[$t].resolve.pre')
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  pjson=$(get --arg t "$t" '.tickets[$t].resolve.paths')
  paths=$(join_paths "$pjson")
  why=$gave_up
  if [ -z "$why" ]; then
    if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null; then
      why="the merge is no longer in progress"
    elif [ "$(git -C "$wt" rev-parse MERGE_HEAD)" != "$(git -C "$MAIN" rev-parse "refs/heads/$branch")" ]; then
      why="the merge in progress is not $branch"
    else
      left=$(join_paths "$(unmerged_json "$wt")")
      markers=
      # Each recorded path, quoted: no word splitting, no glob expansion.
      while IFS= read -r -d '' p; do
        if grep -q -E '^(<<<<<<<|>>>>>>>)( |$)' -- "$wt/$p" 2>/dev/null; then markers="$markers$p "; fi
      done < <(jq -j '.[] + "\u0000"' <<<"$pjson")
      if [ -n "$left" ]; then why="still conflicted: $left"
      elif [ -n "$markers" ]; then why="conflict markers left in ${markers% }"
      elif ! git -C "$wt" diff --quiet; then why="changes left unstaged: $(git -C "$wt" diff --name-only | tr '\n' ' ')"
      elif [ -n "$(git -C "$wt" ls-files --others --exclude-standard)" ]; then
        why="files left behind: $(git -C "$wt" ls-files --others --exclude-standard --directory | tr '\n' ' ')"
      fi
    fi
  fi
  if [ -n "$why" ]; then
    git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
    # The integration worktree holds nothing but the integration branch.
    git -C "$wt" clean -q -fd >/dev/null 2>&1 || true
    apply '.tickets[$t].resolve |= (.outcome = "unresolved" | .why = $w)
      | event({event: "resolve", ticket: $t, outcome: "unresolved", why: $w}; $now)' --arg t "$t" --arg w "$why"
    block "$t" "merge conflict in $paths that /artisan-agent:resolve-conflicts could not resolve: $why"
    state_die 6 "wave.sh: #$t not merged: $why; blocked, with $branch and its worktree kept"
  fi
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  git -C "$wt" commit -q --no-verify -m "Merge #$t ($title) into $ib" \
    -m "Conflicts in $paths resolved by /artisan-agent:resolve-conflicts." >/dev/null \
    || die "could not commit the resolved merge of #$t"
  apply '.tickets[$t].resolve.outcome = "resolved"
    | event({event: "resolve", ticket: $t, outcome: "resolved"}; $now)' --arg t "$t"
  finish_merge "$t" "$n" "$wt" "$pre"
}

# ------------------------------------------------------------------- close

cmd_close() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local status repo body newbody
  status=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ "$status" = merged ] || die "#$t is ${status:-not in the run}, not merged; only merged work closes"
  if [ "$(get --arg t "$t" '.tickets[$t].tracker_closed // false')" = true ]; then
    "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null || die "#$t is closed, but its slice gate could not be opened (gate.sh sync)"
    return 0
  fi
  repo=$(get '.repo')
  mkdir -p "$RUN_DIR/merges"
  # The comment is the evidence contract in the state file, shown.
  body="$RUN_DIR/merges/$t.comment.md"
  "$SCRIPT_DIR/evidence.sh" comment "$RUN_DIR" "$t" >"$body" || die "no evidence contract for #$t"
  gh issue comment "$t" -R "$repo" --body-file "$body" >/dev/null || die "could not comment on #$t"
  newbody="$RUN_DIR/merges/$t.body.md"
  get --arg t "$t" '.tickets[$t].evidence' >"$newbody.evidence.json"
  if gh issue view "$t" -R "$repo" --json body -q .body >"$newbody.orig" 2>/dev/null \
    && python3 -I "$SCRIPT_DIR/lib/criteria.py" tick "$newbody.evidence.json" <"$newbody.orig" >"$newbody" \
    && ! cmp -s "$newbody.orig" "$newbody"; then
    gh issue edit "$t" -R "$repo" --body-file "$newbody" >/dev/null || die "could not tick the criteria on #$t"
  fi
  gh issue close "$t" -R "$repo" >/dev/null || die "could not close #$t"
  "$SCRIPT_DIR/state.sh" closed "$RUN_DIR" "$t"
  # The last merge of a slice opens its review gate before anything else
  # dispatches (gate.sh, references/review-gates.md).
  "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null || die "#$t is closed, but its slice gate could not be opened (gate.sh sync)"
}

# ------------------------------------------------------------------ report

cmd_report() {
  open_run "${1:-}"
  halt_if_wave_failed
  jq '{
    run_id, wave: ((.orchestrators // []) | last | .wave // null),
    integration: .integration,
    tickets: [.plan.scope[] as $t | .tickets[$t] as $k | {
      ticket: $t, title: (.plan.tickets[$t].title // null), status: $k.status,
      attempts: $k.attempts, merge_commit: $k.merge_commit,
      tracker_closed: ($k.tracker_closed // false), cost_usd: $k.cost_usd,
      verdict: ($k.evidence.verdict // null),
      blocked_reason: ($k.blocked_reason // null), resolve: ($k.resolve // null)}],
    decisions_waiting: [.decisions[] | select(.status == "waiting")],
    halted: (.halted // null),
    findings: (.findings | length),
    costs: .costs,
    events: (.events // [] | length)
  }' "$FILE"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  start) cmd_start "$@" ;;
  launch) cmd_launch "$@" ;;
  status) cmd_status "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  merge) cmd_merge "$@" ;;
  resolved) cmd_resolved "$@" ;;
  close) cmd_close "$@" ;;
  block)
    [ $# -eq 3 ] || usage
    open_run "$1"
    "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$2" || exit $?
    block "$2" "$3"
    ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
