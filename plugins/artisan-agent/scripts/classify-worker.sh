#!/usr/bin/env bash
# Classify one attempt of a ticket's worker from the files it left.
#
# Usage: classify-worker.sh <run-dir> <ticket> [attempt]   (attempt defaults to 1)
#
# Prints one line, "<status> <reason>":
#
#   running -                         no exit record and the runner is alive
#   completed -                       the result text ends with the completion
#                                     line and the result file exists
#   not-completed no-completion-line  ended cleanly but the result text lacks
#                                     the completion line (for example a session
#                                     blocked by a hook, which exits 0 with
#                                     is_error false)
#   not-completed no-result-file      completion line but no result file
#   failed deadline                   the runner stopped it at its deadline
#   failed stopped                    the runner was told to stop it
#   failed budget                     hit --max-budget-usd
#   failed turns                      hit --max-turns
#   failed error                      claude reported an error
#   failed crashed                    no readable JSON output
#   failed vanished                   no exit record and the runner is gone
#
# Every "failed" is a failed attempt. A worker's session is judged by its
# result text, never by its exit code alone.
#
# Exit status: 0 when it classified, 2 on bad usage or an unknown attempt, 3 when
# it could not read what it needs (an unreadable runner pid). A caller never
# turns an error into "failed vanished": it surfaces it or retries.
# Needs jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"

COMPLETION_LINE="ARTISAN-WORKER: complete"

usage() { # print this header (the leading comment block) and exit 2
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

[ $# -ge 2 ] || usage
run_dir=$1 ticket=$2 attempt=${3:-1}
key=$ticket.$attempt
worker_dir=$run_dir/workers/$key
exit_record=$run_dir/results/$key.exit.json

# Alive means a process that has not ended: a zombie is a finished runner.
# (ps, not kill -0, so a test can stand in for the liveness check.)
runner_alive() {
  local stat=
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  [ -n "$stat" ] || return 1
  case "$stat" in Z*) return 1 ;; esac
  return 0
}

command -v jq >/dev/null 2>&1 || { echo "classify-worker.sh: needs jq" >&2; exit 2; }

# The runner writes its exit record in its exit trap and then exits, so a dead
# runner may only mean the record landed after we looked. Only a dead runner
# with still no record is vanished: check the record again before deciding.
if [ ! -f "$exit_record" ]; then
  if [ ! -f "$worker_dir/runner.pid" ]; then
    echo "classify-worker.sh: no attempt $attempt of ticket $ticket in $run_dir" >&2
    exit 2
  fi
  # A pid we cannot read is an error, never a dead session.
  runner_pid=$(cat "$worker_dir/runner.pid" 2>/dev/null) || runner_pid=
  if ! state_is_uint "$runner_pid"; then
    echo "classify-worker.sh: cannot read the runner pid in $worker_dir/runner.pid" >&2
    exit 3
  fi
  if ! runner_alive "$runner_pid" && [ ! -f "$exit_record" ]; then
    echo "failed vanished"
    exit 0
  fi
  if [ ! -f "$exit_record" ]; then
    echo "running -"
    exit 0
  fi
fi

case "$(jq -r .reason "$exit_record")" in
  deadline) echo "failed deadline"; exit 0 ;;
  stopped) echo "failed stopped"; exit 0 ;;
esac

output=$worker_dir/output.json
if ! jq -e 'type == "object" and .type == "result"' "$output" >/dev/null 2>&1; then
  echo "failed crashed"
  exit 0
fi

subtype=$(jq -r '.subtype // ""' "$output")
case "$subtype" in
  error_max_budget_usd) echo "failed budget"; exit 0 ;;
  error_max_turns) echo "failed turns"; exit 0 ;;
esac
if [ "$(jq -r '.is_error // false' "$output")" != false ] || [ "$subtype" != success ]; then
  echo "failed error"
  exit 0
fi

last_line=$(jq -r '.result // ""' "$output" | awk 'NF { last = $0 } END { print last }' | sed 's/[[:space:]]*$//')
if [ "$last_line" != "$COMPLETION_LINE" ]; then
  echo "not-completed no-completion-line"
elif [ ! -f "$run_dir/results/$key.result.json" ]; then
  echo "not-completed no-result-file"
else
  echo "completed -"
fi
