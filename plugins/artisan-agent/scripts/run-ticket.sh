#!/usr/bin/env bash
# Launch one capped headless worker for a ticket, detached, and always leave
# an exit record when it ends.
#
# Usage:
#   run-ticket.sh --run-dir DIR --ticket ID --prompt-file FILE --workdir DIR
#                 --estimate-usd N --expected-minutes N
#                 [--attempt N] [--model MODEL] [--max-turns N]
#                 [--deadline-seconds N] [-- extra claude arguments...]
#
# Prints the detached runner's PID and returns at once. The runner starts its
# own session (setsid, or perl's POSIX::setsid where there is no setsid
# command) under nohup, so neither the launcher exiting, a hang-up, nor the
# Bash tool's 2-hour background cap stops it. It runs, in --workdir:
#
#   claude -p <prompt> --output-format json
#          --max-budget-usd <2 x estimate> --max-turns <40 per estimated dollar, at least 20>
#
# with a wall-clock deadline of twice --expected-minutes. The worker runs in
# its own process group; at the deadline, or when the runner gets TERM or INT
# (the sweep stopping it), that group is stopped (TERM, then KILL after 5s).
# Anything the worker left running in its group is stopped when it exits.
#
# Files, with <t>.<n> the ticket and attempt (see scripts/README.md):
#   results/<t>.<n>.exit.json     exit record, written last and atomically
#   results/<t>.<n>.result.json   the worker's result file (it writes this)
#   results/findings/<t>.jsonl    the worker's findings file (it appends)
#   workers/<t>.<n>/              runner.pid, prompt.md, output.json (claude's
#                                 JSON output), stderr.log, runner.log
#
# A ticket's attempt is refused if its worker folder already exists; pass
# --attempt for a retry.
#
# Exit status: 0 launched, 1 failed to launch, 2 bad usage.
#
# Portable to bash 3.2 (macOS) and Linux.

set -euo pipefail

COMPLETION_LINE="ARTISAN-WORKER: complete"
TURNS_PER_DOLLAR=40
MIN_TURNS=20
STOP_GRACE_SECONDS=5

die_usage() {
  echo "run-ticket.sh: $*" >&2
  exit 2
}

orig_args=("$@")
run_dir= ticket= prompt_file= workdir= estimate= expected_minutes=
attempt=1 model= max_turns= deadline_seconds= foreground=
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir=${2:-}; shift 2 ;;
    --ticket) ticket=${2:-}; shift 2 ;;
    --prompt-file) prompt_file=${2:-}; shift 2 ;;
    --workdir) workdir=${2:-}; shift 2 ;;
    --estimate-usd) estimate=${2:-}; shift 2 ;;
    --expected-minutes) expected_minutes=${2:-}; shift 2 ;;
    --attempt) attempt=${2:-}; shift 2 ;;
    --model) model=${2:-}; shift 2 ;;
    --max-turns) max_turns=${2:-}; shift 2 ;;
    --deadline-seconds) deadline_seconds=${2:-}; shift 2 ;;
    --foreground) foreground=1; shift ;;
    --) shift; extra=("$@"); break ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

for pair in "run-dir:$run_dir" "ticket:$ticket" "prompt-file:$prompt_file" \
  "workdir:$workdir" "estimate-usd:$estimate" "expected-minutes:$expected_minutes"; do
  [ -n "${pair#*:}" ] || die_usage "--${pair%%:*} is required"
done

is_number() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }
is_count() { printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'; }

printf '%s' "$ticket" | grep -Eq '^[A-Za-z0-9_-]+$' || die_usage "ticket ids are letters, digits, _ and -"
is_count "$attempt" || die_usage "--attempt must be a positive whole number"
is_number "$estimate" || die_usage "--estimate-usd must be a number"
is_number "$expected_minutes" || die_usage "--expected-minutes must be a number"
[ -z "$max_turns" ] || is_count "$max_turns" || die_usage "--max-turns must be a positive whole number"
[ -z "$deadline_seconds" ] || is_count "$deadline_seconds" || die_usage "--deadline-seconds must be a positive whole number"
[ -f "$prompt_file" ] || die_usage "no such prompt file: $prompt_file"
[ -d "$workdir" ] || die_usage "no such workdir: $workdir"

mkdir -p "$run_dir"
run_dir=$(cd "$run_dir" && pwd)
workdir=$(cd "$workdir" && pwd)
prompt_file=$(cd "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")

key=$ticket.$attempt
worker_dir=$run_dir/workers/$key
exit_record=$run_dir/results/$key.exit.json
result_file=$run_dir/results/$key.result.json
findings_file=$run_dir/results/findings/$ticket.jsonl

# ---------------------------------------------------------------- launcher

detach() { # command... — run in a new session, never returning its status
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@"
  else
    perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!\n"; exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@"
  fi
}

if [ -z "$foreground" ]; then
  if [ -e "$worker_dir" ] || [ -e "$exit_record" ]; then
    die_usage "attempt $attempt of ticket $ticket already exists ($worker_dir); pass --attempt"
  fi
  mkdir -p "$worker_dir" "$run_dir/results/findings"
  detach nohup "$0" --foreground "${orig_args[@]}" \
    </dev/null >>"$worker_dir/runner.log" 2>&1 &
  # The runner writes its own PID once it is up; wait for it (up to 10s).
  i=0
  while [ ! -s "$worker_dir/runner.pid" ]; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      echo "run-ticket.sh: runner did not start; see $worker_dir/runner.log" >&2
      exit 1
    fi
    sleep 0.1
  done
  cat "$worker_dir/runner.pid"
  exit 0
fi

# ------------------------------------------------------------------ runner

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
max_budget=$(awk -v e="$estimate" 'BEGIN { printf "%.2f", e * 2 }')
if [ -z "$max_turns" ]; then
  max_turns=$(awk -v e="$estimate" -v per="$TURNS_PER_DOLLAR" -v min="$MIN_TURNS" \
    'BEGIN { t = e * per; if (t > int(t)) t = int(t) + 1; if (t < min) t = min; print t }')
fi
if [ -z "$deadline_seconds" ]; then
  deadline_seconds=$(awk -v m="$expected_minutes" 'BEGIN { s = m * 2 * 60; if (s > int(s)) s = int(s) + 1; print s }')
fi

child= code= reason= recorded= stop_requested=

write_exit_record() {
  [ -z "$recorded" ] || return 0
  recorded=1
  local tmp="$run_dir/results/.$key.exit.json.tmp"
  printf '{"ticket":"%s","attempt":%s,"exit_code":%s,"reason":"%s","runner_pid":%s,"started_at":"%s","finished_at":"%s","max_budget_usd":"%s","max_turns":%s,"deadline_seconds":%s,"output":"workers/%s/output.json","result_file":"results/%s.result.json"}\n' \
    "$ticket" "$attempt" "${code:-255}" "${reason:-runner-error}" "$$" "$started_at" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$max_budget" "$max_turns" "$deadline_seconds" "$key" "$key" \
    >"$tmp"
  mv "$tmp" "$exit_record"
}

group_alive() { kill -0 "-$child" 2>/dev/null; }

stop_group() { # TERM the worker's process group, then KILL what is left
  local i=0
  kill -TERM "-$child" 2>/dev/null || return 0
  while group_alive && [ "$i" -lt $((STOP_GRACE_SECONDS * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "-$child" 2>/dev/null || true
}

# Whatever happens to the runner short of SIGKILL, leave an exit record.
trap 'write_exit_record' EXIT
trap 'stop_requested=1' TERM INT

mkdir -p "$worker_dir" "$run_dir/results/findings"
echo $$ >"$worker_dir/runner.pid.tmp" && mv "$worker_dir/runner.pid.tmp" "$worker_dir/runner.pid"

prompt="$(cat "$prompt_file")

---
Notes from the ticket runner:
- Write your result file to $result_file (also in \$ARTISAN_RESULT_FILE).
- Append any findings, one JSON object per line, to $findings_file (also in \$ARTISAN_FINDINGS_FILE).
- Do not leave background commands running. Anything still running when you finish is stopped.
- Only when the ticket is done and your result file is written, end your final reply with this line on its own:
$COMPLETION_LINE
  If you could not finish, leave that line out and say why."
printf '%s\n' "$prompt" >"$worker_dir/prompt.md"

claude_args=(-p "$prompt" --output-format json --max-budget-usd "$max_budget" --max-turns "$max_turns")
[ -z "$model" ] || claude_args+=(--model "$model")

# set -m gives the worker its own process group, so it and anything it
# leaves running can be stopped together without stopping the runner.
set -m
(
  cd "$workdir"
  ARTISAN_RESULT_FILE=$result_file ARTISAN_FINDINGS_FILE=$findings_file \
    exec claude "${claude_args[@]}" ${extra[@]+"${extra[@]}"}
) <"/dev/null" >"$worker_dir/output.json" 2>"$worker_dir/stderr.log" &
child=$!
set +m

reason=exited
deadline_at=$((SECONDS + deadline_seconds))
while kill -0 "$child" 2>/dev/null; do
  if [ -n "$stop_requested" ]; then
    reason=stopped
    stop_group
    break
  fi
  if [ "$SECONDS" -ge "$deadline_at" ]; then
    reason=deadline
    stop_group
    break
  fi
  sleep 1
done

code=0
wait "$child" 2>/dev/null || code=$?

# Stop anything the worker left behind in its group.
group_alive && stop_group

write_exit_record
