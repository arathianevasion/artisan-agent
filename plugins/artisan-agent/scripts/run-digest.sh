#!/usr/bin/env bash
# The run digest: what a chat reads first when a run is open, so a compacted,
# resumed or new session carries on where the run is. Read-only on the state
# file (hooks call it and never take the lock).
#
# Usage:
#   run-digest.sh [--repo DIR | --run-dir DIR] [--line] [--peek]
#
# Finds the repo's open run (DIR, default the current directory, any
# worktree of it): a run folder under the main checkout's .artisan-agent/runs/
# whose state file has a ticket in scope not yet merged or closed; the newest
# if there are several. Prints nothing, exit 0, when there is none.
#
# Otherwise prints the digest, Markdown:
#   where the run is   wave, the orchestrator's state, tickets merged, cost
#                      against the budget, halted or not; then the ticket table
#   what's waiting     the decisions waiting for the Artisan, as a table
#   what changed       the events since the chat last saw the digest, as a table
# and marks those events seen (.digest-seen in the run folder) unless --peek.
# --line prints one line instead ("run <id> is open: ..."), always peeking.
#
# Exit status: 0 ok (with or without an open run), 2 usage.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git and jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"

usage() { state_usage "$0"; }
MAX_CHANGES=12

repo=. run_dir= line=0 peek=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --run-dir) [ $# -ge 2 ] || usage; run_dir=$2; shift 2 ;;
    --line) line=1 peek=1; shift ;;
    --peek) peek=1; shift ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || exit 0

is_open() { # state.json
  state_valid_file "$1" 2>/dev/null || return 1
  jq -e '[.plan.scope[] as $t | .tickets[$t].status // "queued"
          | select(. != "merged" and . != "closed")] | length > 0' "$1" >/dev/null 2>&1
}

if [ -z "$run_dir" ]; then
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
  runs="$(dirname "$common")/.artisan-agent/runs"
  [ -d "$runs" ] || exit 0
  # Newest state file first.
  while IFS= read -r f; do
    if is_open "$f"; then run_dir=$(dirname "$f"); break; fi
  done <<EOF
$(ls -t "$runs"/*/state.json 2>/dev/null)
EOF
  [ -n "$run_dir" ] || exit 0
else
  is_open "$run_dir/state.json" || exit 0
fi
run_dir=$(cd "$run_dir" && pwd)
FILE=$run_dir/state.json
get() { jq -r "$@" "$FILE"; }

# The orchestrator's state, from its exit record (classify-worker.sh only reads).
orch="no orchestrator yet"
last=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt) \(.wave)"')
if [ -n "$last" ]; then
  set -- $last
  cls=$("$SCRIPT_DIR/classify-worker.sh" "$run_dir" "$1" "$2" 2>/dev/null || echo "unknown classifier-error")
  case "$cls" in
    running*) orch="wave $3 running (orchestrator attempt $2)" ;;
    completed*) orch="wave $3 finished" ;;
    *) orch="wave $3's orchestrator ended without finishing (${cls}): launching again carries it on" ;;
  esac
fi

summary=$(jq -r --arg orch "$orch" '
  ([.plan.scope[] as $t | .tickets[$t].status // "queued"]) as $st
  | "\($st | map(select(. == "merged")) | length) of \($st | length) merged"
    + (if ($st | map(select(. == "blocked")) | length) > 0 then ", \($st | map(select(. == "blocked")) | length) blocked" else "" end)
    + ", $\(.costs.total_usd // 0 | . * 100 | round / 100) of $\(.plan.budget_usd // "?") budget"' "$FILE")
waiting=$(get '[.decisions[]? | select(.status == "waiting")] | length')
run_id=$(get '.run_id')

if [ "$line" -eq 1 ]; then
  printf 'run %s is open: %s; %s; %s\n' "$run_id" "$orch" "$summary" \
    "$(if [ "$waiting" -gt 0 ]; then echo "$waiting decision(s) waiting for you"; else echo "nothing waiting for you"; fi)"
  exit 0
fi

seen=$(cat "$run_dir/.digest-seen" 2>/dev/null || echo 0)
state_is_uint "$seen" || seen=0

echo "## Run $run_id is open"
echo
echo "Where it is: $orch; $summary. Run folder: \`$run_dir\`."
[ "$(get '.halted != null')" != true ] \
  || get '"**Halted:** \(.halted.reason). Nothing launches until the Artisan decides."'
echo
get '
  . as $s
  | "| Ticket | Wave | Model | Status |",
    "|---|---|---|---|",
    ( $s.plan.scope[] as $t | ($s.tickets[$t] // {status: "queued"}) as $k | ($s.plan.tickets[$t] // {}) as $p
      | (if ($k.wave // 0) > 0 then $k.wave
         else ([($s.plan.waves // []) | to_entries[] | select(.value | index($t)) | .key + 1] | first // "-") end) as $wave
      | "| #\($t) (\($p.title // "untitled")) | \($wave) | \($p.model // "-") | \($k.status)"
        + (if $k.status == "merged" then " as \(($k.merge_commit // "")[0:7])"
              + (if $k.tracker_closed then ", closed" else ", not closed yet" end)
              + (if $k.risk_gate.status? == "waiting" then ", risk gate waiting" else "" end)
           elif $k.status == "blocked" then ": \($k.blocked_reason // (($k.failures // []) | last | .reason?) // "see decisions")"
           elif $k.status == "in_flight" then " (attempt \($k.attempts))"
           else "" end) + " |" )'
echo
echo "### Waiting for you"
echo
if [ "$waiting" -gt 0 ]; then
  echo "| Decision | Ticket | Question |"
  echo "|---|---|---|"
  get '.decisions[] | select(.status == "waiting")
       | "| \(.id) (\(.kind)) | \(if .ticket then "#" + .ticket else "-" end) | \(.question | gsub("\n"; " ")) |"'
else
  echo "Nothing is waiting for you."
fi
echo
echo "### What changed since you last looked"
echo
changes=$(get --argjson seen "$seen" '[(.events // [])[] | select(.seq > $seen)] | length')
if [ "$changes" -gt 0 ]; then
  if [ "$changes" -gt "$MAX_CHANGES" ]; then
    echo "The last $MAX_CHANGES of $changes events:"
    echo
  fi
  echo "| # | Event | Ticket | Detail |"
  echo "|---|---|---|---|"
  get --argjson seen "$seen" --argjson max "$MAX_CHANGES" '
    [(.events // [])[] | select(.seq > $seen)] | .[-$max:][]
    | "| \(.seq) | \(.event) | \(if .ticket then "#" + .ticket else "-" end) | "
      + ([ (if .attempt then "attempt \(.attempt)" else empty end),
           (if .wave then "wave \(.wave)" else empty end),
           (if .status then .status else empty end),
           (if .verdict then .verdict else empty end),
           (if .commit then .commit[0:7] else empty end),
           (if .reason then .reason else empty end),
           (if .outcome then .outcome else empty end),
           (if .percent then "\(.percent)% context" else empty end)] | join(", ")) + " |"'
else
  echo "Nothing new since you last looked."
fi
echo
echo "Carry on with \`/artisan-agent:implement-plan\`: it checks the wave (\`wave.sh status\`) and launches the next one."

if [ "$peek" -eq 0 ]; then
  last_seq=$(get '[(.events // [])[].seq] | max // 0')
  printf '%s\n' "$last_seq" >"$run_dir/.digest-seen.tmp.$$" && mv "$run_dir/.digest-seen.tmp.$$" "$run_dir/.digest-seen"
fi
