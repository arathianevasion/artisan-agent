#!/usr/bin/env bash
# Launch one capped headless worker for a ticket, detached, and always leave
# an exit record when it ends.
#
# Usage:
#   run-ticket.sh --run-dir DIR --ticket ID --prompt-file FILE --workdir DIR
#                 --estimate-usd N --expected-minutes N
#                 [--attempt N] [--model MODEL] [--max-turns N]
#                 [--deadline-seconds N] [--role worker|orchestrator|verifier]
#                 [--lock-from PID] [-- extra claude arguments...]
#
# Prints the detached runner's PID and returns at once. The runner starts its
# own session (setsid, or perl's POSIX::setsid where there is no setsid
# command) under nohup, so neither the launcher exiting, a hang-up, nor the
# Bash tool's 2-hour background cap stops it. It runs, in --workdir:
#
#   claude -p <prompt> --output-format stream-json --verbose
#          --max-budget-usd <2 x estimate> --max-turns <40 per estimated dollar, at least 20>
#
# with a wall-clock deadline of twice --expected-minutes. The worker runs in
# its own process group; at the deadline, or when the runner gets TERM or INT
# (the sweep stopping it), that group is stopped (TERM, then KILL after 5s).
# Anything the worker left running in its group is stopped when it exits.
#
# stream-json is what makes claude emit `rate_limit_event`s (plain json does
# not). The runner keeps the stream in workers/<t>.<n>/stream.jsonl, records the
# latest rate-limit reading, with the time it was received, in
# workers/<t>.<n>/usage.json (budget.sh's usage guard reads it), and, when the
# worker ends, writes output.json: the final `result` event of the stream, the
# same JSON object `--output-format json` printed, so nothing that reads
# output.json changes.
#
# Files, with <t>.<n> the ticket and attempt (see scripts/README.md):
#   results/<t>.<n>.exit.json     exit record, written last and atomically
#   results/<t>.<n>.result.json   the worker's result file (it writes this)
#   results/findings/<t>.jsonl    the worker's findings file (it appends)
#   workers/<t>.<n>/              runner.pid, prompt.md, output.json (claude's
#                                 final result event), stream.jsonl (its whole
#                                 stream), usage.json (latest rate-limit
#                                 reading), stderr.log, runner.log
#
# A ticket's attempt is refused if its worker folder already exists; pass
# --attempt for a retry. The run folder must hold a state file (an approved
# plan): a worker for a ticket outside its approved scope (plan.scope), or any
# launch into a run folder with no state file, is refused before anything
# starts.
#
# --role orchestrator launches a wave's orchestrator the same way (detached,
# capped, always an exit record) instead of a worker. Its id must start with
# "orchestrator-" (wave.sh uses orchestrator-w<wave>), it is not a ticket so
# the scope check does not apply, and its session gets ARTISAN_WRITER_PID set
# to the runner's PID: the long-lived pid that holds the state lock while the
# wave runs. With --lock-from PID, the runner takes the state lock over from
# PID (the chat that launched it) before the session starts, so the
# orchestrator never finds its own run locked. --role verifier launches a
# ticket's verifier (verify.sh) the same way: its id starts with "verify-",
# it is not a ticket either, and it never gets a writer pid. Every session
# gets ARTISAN_ROLE (worker, orchestrator or verifier) and ARTISAN_RUN_DIR.
#
# A worker (not an orchestrator or verifier) is also started with
#   --name worker-<ticket> --settings '{"crossSessionInbound":"accept"}'
# so the orchestrator can relay a finding to it (references/findings.md).
#
# Exit status: 0 launched, 1 failed to launch, 2 bad usage, 4 the ticket is
# outside the approved scope.
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
attempt=1 model= max_turns= deadline_seconds= foreground= role=worker lock_from=
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    --foreground|--) ;;
    *) [ $# -ge 2 ] || die_usage "$1 needs a value" ;;
  esac
  case "$1" in
    --run-dir) run_dir=$2; shift 2 ;;
    --ticket) ticket=$2; shift 2 ;;
    --prompt-file) prompt_file=$2; shift 2 ;;
    --workdir) workdir=$2; shift 2 ;;
    --estimate-usd) estimate=$2; shift 2 ;;
    --expected-minutes) expected_minutes=$2; shift 2 ;;
    --attempt) attempt=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-turns) max_turns=$2; shift 2 ;;
    --deadline-seconds) deadline_seconds=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --lock-from) lock_from=$2; shift 2 ;;
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
case "$role" in
  worker) ;;
  orchestrator) case "$ticket" in orchestrator-*) ;; *) die_usage "an orchestrator's id starts with orchestrator-" ;; esac ;;
  verifier) case "$ticket" in verify-*) ;; *) die_usage "a verifier's id starts with verify-" ;; esac ;;
  *) die_usage "--role is worker, orchestrator or verifier" ;;
esac
[ -z "$lock_from" ] || [ "$role" = orchestrator ] || die_usage "--lock-from is for an orchestrator"

# Nothing launches without an approved plan, and the scope is exactly the set
# approved: never launch a worker outside it.
if [ -z "$foreground" ]; then
  if [ ! -f "$run_dir/state.json" ]; then
    echo "run-ticket.sh: refusing $ticket: $run_dir has no state file, so there is no approved scope; start the run with state.sh init" >&2
    exit 4
  fi
  if [ "$role" = worker ]; then
    "$(dirname "$0")/state.sh" in-scope "$run_dir" "$ticket" || exit $?
  fi
fi

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
if [ -n "$lock_from" ]; then
  # shellcheck source=lib/state-lib.sh
  . "$(dirname "$0")/lib/state-lib.sh"
  if ! state_hand_lock "$run_dir" "$lock_from" "$$"; then
    echo "run-ticket.sh: could not take the state lock from $lock_from; not starting" >&2
    code=1 reason=runner-error
    echo $$ >"$worker_dir/runner.pid"
    exit 1
  fi
fi
echo $$ >"$worker_dir/runner.pid.tmp" && mv "$worker_dir/runner.pid.tmp" "$worker_dir/runner.pid"

if [ "$role" = orchestrator ]; then
  done_what="the wave is done and your result file (the wave report) is written"
elif [ "$role" = verifier ]; then
  done_what="your result file (the verdict) is written"
else
  done_what="the ticket is done and your result file is written"
fi

prompt="$(cat "$prompt_file")

---
Notes from the ticket runner:
- Write your result file to $result_file (also in \$ARTISAN_RESULT_FILE).
- Append any findings, one JSON object per line, to $findings_file (also in \$ARTISAN_FINDINGS_FILE).
- Do not leave background commands running. Anything still running when you finish is stopped.
- Never end a turn to wait for something (a test run, a command): in a headless session, ending the turn ends the session. Run it in the foreground, to the end. Don't run the whole test suite; run the test files covering your change. The merge gate runs the full suite.
- Only when $done_what, end your final reply with this line on its own:
$COMPLETION_LINE
  If you could not finish, leave that line out and say why."
printf '%s\n' "$prompt" >"$worker_dir/prompt.md"

claude_args=(-p "$prompt" --output-format stream-json --verbose --max-budget-usd "$max_budget" --max-turns "$max_turns")
[ -z "$model" ] || claude_args+=(--model "$model")
# A worker is named, so the orchestrator can SendMessage a finding to it, and
# accepts messages from other sessions, which a project-level setting can't
# switch on (it is ignored); only --settings does.
if [ "$role" = worker ]; then
  claude_args+=(--name "worker-$ticket" --settings '{"crossSessionInbound":"accept"}')
fi

# set -m gives the worker its own process group, so it and anything it
# leaves running can be stopped together without stopping the runner.
set -m
(
  cd "$workdir"
  # Only an orchestrator writes the state file; a worker started by one must
  # not inherit its writer pid.
  if [ "$role" = orchestrator ]; then
    ARTISAN_WRITER_PID=$$
    export ARTISAN_WRITER_PID
  else
    unset ARTISAN_WRITER_PID
  fi
  ARTISAN_ROLE=$role ARTISAN_RUN_DIR=$run_dir \
  ARTISAN_RESULT_FILE=$result_file ARTISAN_FINDINGS_FILE=$findings_file \
    exec claude "${claude_args[@]}" ${extra[@]+"${extra[@]}"}
) <"/dev/null" >"$worker_dir/stream.jsonl" 2>"$worker_dir/stderr.log" &
child=$!
set +m

# record_usage: the latest rate_limit_event in the stream becomes usage.json,
# stamped with the time the runner saw it (the event has none of its own, and
# a resent old limit must not pass as fresh). Windows accumulate: an event
# names one window, and each keeps the time it was last seen. Utilisation is
# a fraction (0.29); the reading holds percent, as the status line does.
usage_seen=0
record_usage() {
  local lines total now
  total=$(grep -c '^{"type":"rate_limit_event"' "$worker_dir/stream.jsonl" 2>/dev/null) || total=0
  [ "$total" -gt "$usage_seen" ] || return 0
  # Every event since the last look, in order, so two landing between polls
  # both count; the later one wins a window.
  lines=$(grep '^{"type":"rate_limit_event"' "$worker_dir/stream.jsonl" | tail -n +$((usage_seen + 1)))
  usage_seen=$total
  now=$(date +%s)
  jq -nc --argjson now "$now" --arg t "$ticket" --argjson n "$attempt" \
    --slurpfile prev <(cat "$worker_dir/usage.json" 2>/dev/null || echo null) '
    reduce (inputs | (.rate_limit_info.unifiedWindows // {}) | to_entries[]
            | select((.key == "five_hour" or .key == "seven_day") and (.value.utilization | type) == "number"))
      as $e (($prev[0].rate_limits // {});
        .[$e.key] = {used_percentage: (($e.value.utilization * 10000 | round) / 100),
                     resets_at: ($e.value.resetsAt // null), at: $now})
    | select(length > 0)
    | {source: "worker", ticket: $t, attempt: $n, received_at: $now, rate_limits: .}' \
    <<<"$lines" >"$worker_dir/.usage.json.tmp" 2>/dev/null \
    && [ -s "$worker_dir/.usage.json.tmp" ] && mv "$worker_dir/.usage.json.tmp" "$worker_dir/usage.json" \
    || rm -f "$worker_dir/.usage.json.tmp"
  return 0
}

# finish_output: output.json is the stream's final result event, as before.
finish_output() {
  record_usage
  grep '^{"type":"result"' "$worker_dir/stream.jsonl" 2>/dev/null | tail -n 1 >"$worker_dir/output.json" || true
  return 0
}

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
  record_usage
  sleep 1
done

code=0
wait "$child" 2>/dev/null || code=$?

# Stop anything the worker left behind in its group.
group_alive && stop_group

finish_output
write_exit_record
