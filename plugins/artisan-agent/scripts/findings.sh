#!/usr/bin/env bash
# Findings shared between workers: what to relay, record and file.
# Field meanings: ${CLAUDE_PLUGIN_ROOT}/references/state-file.md
# The flow: ${CLAUDE_PLUGIN_ROOT}/references/findings.md
#
# Usage:
#   findings.sh pending <run-dir>
#       one JSON line per (finding, ticket it names in "blocks") not yet handled:
#       {from, seq, target, action, title, name?, message?}. The action:
#         relay    the target's worker is in flight: send `message` to `name`
#                  with SendMessage, then run `mark`
#         comment  the target has not started (queued) or is with the Artisan
#                  (blocked): it reads the finding on its ticket
#         triage   the target has finished (returned, merged, closed) or is not
#                  in the run: `mark` files a needs-triage ticket
#       A finding that names no ticket in "blocks" is not listed.
#   findings.sh mark <run-dir> <from> <seq> <target> <relay|comment|triage>
#       does the tracker half and records it, once: a comment on both tickets
#       (relay, comment) or a needs-triage ticket plus a comment on the finding's
#       ticket (triage); then `.relays` and a `finding` event in the state file.
#       Marking again changes nothing.
#   findings.sh add <run-dir> <from> <title> <why> [target...]
#       a late fact read from a worker's result notes: appends it to the
#       ticket's findings file (source "result-notes"; once per title) and
#       runs the sweep, so it is logged like any finding. Relay it with the rest.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held by another live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

[ $# -ge 2 ] || state_usage "$0"
cmd=$1 RUN_DIR=$2
shift 2
state_require_run_dir "$RUN_DIR"
FILE=$(state_file "$RUN_DIR")

cmd_pending() {
  jq -c '
    . as $s
    | (.relays // []) as $done
    | .findings[]
    | select(.from != null and ((.blocks // []) | type) == "array")
    | . as $f
    | ($f.blocks[] | tostring) as $t
    | select($t != $f.from)
    | select(any($done[]; .from == $f.from and .seq == $f.seq and .target == $t) | not)
    | ($s.tickets[$t].status // "outside") as $st
    | (if $st == "in_flight" then "relay"
       elif ($st == "queued" or $st == "blocked") then "comment"
       else "triage" end) as $action
    | {from: $f.from, seq: $f.seq, target: $t, action: $action, title: ($f.title // $f.raw // "untitled")}
      + (if $action == "relay" then {
          name: ("worker-" + $t),
          message: ("FINDING from #\($f.from): \($f.title // "untitled"). \($f.why // "") This concerns your ticket #\($t). Take it as a fact. If it means a design or interface change, stop and record the question; do not reply or negotiate with the other worker.")
        } else {} end)' "$FILE"
}

cmd_mark() {
  [ $# -eq 4 ] || state_usage "$0"
  local from=$1 seq=$2 target=$3 action=$4 repo= title= why= body= issue= line=
  case "$action" in relay | comment | triage) ;; *) state_usage "$0" ;; esac
  line=$(cmd_pending | jq -c --arg f "$from" --argjson s "$seq" --arg t "$target" \
    'select(.from == $f and .seq == $s and .target == $t)' | head -1)
  [ -n "$line" ] || return 0   # unknown, or already marked
  repo=$(jq -r '.repo' "$FILE")
  title=$(jq -r --arg f "$from" --argjson s "$seq" '.findings[] | select(.from == $f and .seq == $s) | .title // "untitled"' "$FILE")
  why=$(jq -r --arg f "$from" --argjson s "$seq" '.findings[] | select(.from == $f and .seq == $s) | .why // ""' "$FILE")
  case "$action" in
    relay)
      gh issue comment "$from" -R "$repo" --body "Finding from #$from: $title. $why Relayed to the worker on #$target." >/dev/null || state_die 1 "could not comment on #$from"
      gh issue comment "$target" -R "$repo" --body "Finding from #$from: $title. $why Relayed to this ticket's worker." >/dev/null || state_die 1 "could not comment on #$target"
      ;;
    comment)
      gh issue comment "$from" -R "$repo" --body "Finding from #$from: $title. $why Logged on #$target." >/dev/null || state_die 1 "could not comment on #$from"
      gh issue comment "$target" -R "$repo" --body "Finding from #$from: $title. $why" >/dev/null || state_die 1 "could not comment on #$target"
      ;;
    triage)
      body="Found by the worker on #$from while building, and about #$target, which has already finished, so it was not relayed.

$why

Needs triage before it can join any run."
      issue=$(gh issue create -R "$repo" --title "Finding from #$from: $title" --body "$body" --label needs-triage) \
        || state_die 1 "could not file the finding for triage"
      gh issue comment "$from" -R "$repo" --body "Finding from #$from: $title. $why About finished #$target; filed for triage: $issue" >/dev/null || state_die 1 "could not comment on #$from"
      ;;
  esac
  state_with_lock "$RUN_DIR" state_apply "$RUN_DIR" "$STATE_JQ_DEFS"'
    .relays = ((.relays // []) + [{from: $from, seq: $seq, target: $t, action: $action, issue: $issue, at: $now}])
    | event({event: "finding", from: $from, seq: $seq, target: $t, action: $action}; $now)' \
    --arg from "$from" --argjson seq "$seq" --arg t "$target" --arg action "$action" \
    --arg issue "$issue" --argjson now "$(state_now)"
}

cmd_add() {
  [ $# -ge 3 ] || state_usage "$0"
  local from=$1 title=$2 why=$3 f=
  shift 3
  printf '%s' "$from" | grep -Eq '^[A-Za-z0-9_-]+$' || state_die 2 "bad ticket id: $from"
  f=$RUN_DIR/results/findings/$from.jsonl
  mkdir -p "$RUN_DIR/results/findings"
  if [ ! -f "$f" ] || [ -z "$(jq -c --arg t "$title" 'select(.source? == "result-notes" and .title? == $t)' "$f" 2>/dev/null)" ]; then
    # A worker's file may end without a newline; start on a fresh line.
    [ ! -s "$f" ] || [ -z "$(tail -c1 "$f")" ] || printf '\n' >>"$f"
    jq -cn --arg title "$title" --arg why "$why" --args \
      '{title: $title, why: $why, blocks: $ARGS.positional, source: "result-notes"}' "$@" >>"$f"
  fi
  "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" --no-guard
}

case "$cmd" in
  pending) cmd_pending ;;
  mark) cmd_mark "$@" ;;
  add) cmd_add "$@" ;;
  *) state_usage "$0" ;;
esac
