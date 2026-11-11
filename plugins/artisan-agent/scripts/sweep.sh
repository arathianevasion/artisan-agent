#!/usr/bin/env bash
# The sweep: check every in-flight ticket and log new findings.
# Field meanings: ${CLAUDE_PLUGIN_ROOT}/references/state-file.md
#
# Usage: sweep.sh <run-dir>
#
# For each ticket whose status is in_flight, in this order:
#   1. a result file results/<ticket>.json  -> the result is recorded
#        (status "complete" -> returned, "blocked" -> blocked, "failed" -> failed attempt)
#   2. an exit record results/<ticket>.exit.json and no result -> failed attempt
#   3. past its deadline -> the worker is stopped, failed attempt
#   4. its worker pid is no longer alive -> failed attempt
# A failed attempt sends the ticket back to queued, or, once it has used the
# run's attempts per ticket, to blocked with an exception decision queued for
# the Artisan. New lines in results/findings/<ticket>.jsonl join the findings
# log. Running it again on the same files changes nothing.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the lock is held by another live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

[ $# -eq 1 ] || state_usage "$0"
RUN_DIR=$1
state_require_run_dir "$RUN_DIR"
RESULTS="$RUN_DIR/results"

# The pid and every process descended from it.
process_tree() {
  local pid="$1" child
  printf '%s\n' "$pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    process_tree "$child"
  done
}

# Stop a worker and everything it started (run-ticket.sh -> claude -> tools):
# TERM the whole tree, then KILL whatever is left after the grace period.
stop_worker() {
  local pid="$1" tree p alive waited=0
  state_pid_alive "$pid" || return 0
  tree=$(process_tree "$pid")
  for p in $tree; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$waited" -lt "${ARTISAN_STOP_GRACE:-5}" ]; do
    alive=0
    for p in $tree; do state_pid_alive "$p" && alive=1; done
    [ "$alive" -eq 1 ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  for p in $tree; do kill -KILL "$p" 2>/dev/null || true; done
}

# A failed attempt for ticket $t; jq args: --arg t, --arg reason, --argjson now.
FAIL_FILTER='
  .plan.attempts_per_ticket as $max
  | .tickets[$t] as $tk
  | .tickets[$t] |= (
      .failures += [{attempt: .attempts, reason: $reason, at: $now}]
      | .pid = null
      | .status = (if .attempts >= $max then "blocked" else "queued" end))
  | if $tk.attempts >= $max then
      .decisions += [{
        id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
        question: "Ticket \($t) failed \($tk.attempts) attempts (last: \($reason)). Bypass or defer?",
        status: "waiting", at: $now
      }]
    else . end'

RESULT_FILTER='
  $rs[0] as $r
  | ($r.status // "complete") as $s
  | .tickets[$t] |= (
      .result = {status: $s, commit: ($r.commit // null), notes: ($r.notes // null),
                 file: $file}
      | .cost_usd = ($r.cost_usd // $r.total_cost_usd // .cost_usd)
      | .pid = null)
  | if $s == "failed" then .
    elif $s == "blocked" then .tickets[$t].status = "blocked"
    else .tickets[$t].status = "returned" end'

sweep() {
  local file tmp now tickets t status pid deadline result exit_record
  file=$(state_file "$RUN_DIR")
  state_valid_file "$file" || state_die 1 "unreadable or wrong schema version: $file"
  tmp=$(state_tmp "$RUN_DIR")
  cp "$file" "$tmp"
  now=$(state_now)

  step() { state_step "$tmp" "$@"; }

  tickets=$(jq -r '.tickets | to_entries[] | select(.value.status == "in_flight") | .key' "$tmp")
  for t in $tickets; do
    pid=$(jq -r --arg t "$t" '.tickets[$t].pid // ""' "$tmp")
    deadline=$(jq -r --arg t "$t" '.tickets[$t].deadline_at // ""' "$tmp")
    result="$RESULTS/$t.json"
    exit_record="$RESULTS/$t.exit.json"
    if [ -f "$result" ] && jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
      step "$RESULT_FILTER" --arg t "$t" --slurpfile rs "$result" --arg file "results/$t.json"
      status=$(jq -r '.status // "complete"' "$result")
      if [ "$status" = "failed" ]; then
        step "$FAIL_FILTER" --arg t "$t" --arg reason "worker reported failed" --argjson now "$now"
      fi
    elif [ -f "$exit_record" ]; then
      step "$FAIL_FILTER" --arg t "$t" --arg reason "exited without a result" --argjson now "$now"
    elif [ -n "$deadline" ] && [ "$now" -gt "$deadline" ]; then
      [ -n "$pid" ] && stop_worker "$pid"
      step "$FAIL_FILTER" --arg t "$t" --arg reason "past deadline; stopped" --argjson now "$now"
    elif ! state_pid_alive "$pid"; then
      step "$FAIL_FILTER" --arg t "$t" --arg reason "worker gone without a result or exit record" --argjson now "$now"
    fi
  done

  # Findings: append lines beyond what has been read, per ticket.
  local f ticket total seen
  for f in "$RESULTS"/findings/*.jsonl; do
    [ -f "$f" ] || continue
    ticket=$(basename "$f" .jsonl)
    # Complete lines only: a line still being written has no newline yet.
    total=$(wc -l <"$f" | tr -d ' ')
    seen=$(jq -r --arg t "$ticket" '.findings_read[$t] // 0' "$tmp")
    [ "$total" -gt "$seen" ] || continue
    step '
      .findings += ($lines | to_entries | map(
        {from: $t, seq: ($seen + .key + 1)}
        + ((.value | try fromjson catch null) as $j
           | if ($j | type) == "object" then $j else {raw: .value} end)))
      | .findings_read[$t] = $total' \
      --arg t "$ticket" --argjson seen "$seen" --argjson total "$total" \
      --argjson lines "$(awk -v from="$seen" -v to="$total" 'NR > from && NR <= to' "$f" | jq -R . | jq -s .)"
  done

  step '.costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
        | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)'

  state_commit "$RUN_DIR" "$tmp"
}

state_with_lock "$RUN_DIR" sweep
