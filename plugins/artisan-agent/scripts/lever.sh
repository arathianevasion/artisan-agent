#!/usr/bin/env bash
# The levers on a running run (#76): steering a worker, adding work, and urgent
# tickets. The rules: ${CLAUDE_PLUGIN_ROOT}/references/run-levers.md. State
# file: references/state-file.md.
#
# Usage, from the Engineering chat that holds the run:
#   lever.sh steer <run-dir> <ticket> --note TEXT [--wait SECONDS]
#       stop the ticket's worker and send it back to queued with the Artisan's
#       notes, to be dispatched again (wave.sh dispatch puts the notes in the
#       new worker's prompt). It is recorded as steering (tickets.<t>.steering,
#       a "steered" event), never as a failed attempt: it costs none of the
#       ticket's attempts. Work the worker had not committed is committed as
#       WIP on its branch, so the next worker continues from it. 6: the ticket
#       is not in flight. The state file is written by the next sweep (this
#       command runs one; while a wave's orchestrator holds the lock, its own
#       sweep records it from steering/<ticket>.<attempt>.json).
#   lever.sh add <run-dir> <ticket> --model M --estimate-usd N [--title T]
#                [--minutes N] [--expected-files a,b/] [--priority N]
#                [--approve] [--by NAME]
#       add a ticket to the running run. Without --approve it records nothing
#       and prints the one-line approval: model, estimate and the new run
#       budget (the scope gate). With --approve the ticket joins the scope at
#       a priority above the plan's (default 1; 0 is a planned ticket), and
#       dispatches in the next wave ahead of lower-priority tickets. Both the
#       estimate and the overrun allowance on it join the run budget.
#   lever.sh urgent <run-dir> <ticket> --model M --estimate-usd N [same options]
#       marking a ticket urgent is its scope approval: it is recorded at once,
#       its estimate joins the run budget, and wave.sh dispatch sends it at
#       once on the one extra slot above Max Agents (a second urgent ticket
#       waits), from main. It keeps its gates and cost cap, and ships through
#       its own end gate and PR (end-gate.sh urgent-*).
#   lever.sh pending <run-dir>
#       the urgent tickets still to dispatch, one per line (the orchestrator
#       reads this after every sweep).
#
# A request made while a wave's orchestrator holds the state lock is left in
# levers/<kind>-<ticket>.json and joins the run at that orchestrator's next
# sweep (sweep.sh); the command says so.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held (the request
# is kept), 6 refused.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git and jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "lever.sh: $*"; }
refuse() { state_die 6 "lever.sh: $*"; }

# Runs a sweep (which applies requests and records steering); 3 means a wave
# holds the lock and its own sweep will.
run_sweep() {
  local rc=0
  "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" --no-guard >/dev/null || rc=$?
  return "$rc"
}

# ------------------------------------------------------------------- steer

cmd_steer() {
  open_run "${1:-}"
  local t="${2:-}" note= wait_s=60 status= n= pid= wt= runner= i= rc=0
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) [ $# -ge 2 ] || usage; note=$2; shift 2 ;;
      --wait) [ $# -ge 2 ] || usage; wait_s=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$note" ] || usage
  state_is_uint "$wait_s" || usage
  status=$(get --arg t "$t" '.tickets[$t].status // "none"')
  [ "$status" = in_flight ] || refuse "#$t is $status, not in flight: there is no worker to stop"
  n=$(get --arg t "$t" '.tickets[$t].attempts')
  mkdir -p "$RUN_DIR/steering"
  jq -n --arg t "$t" --argjson n "$n" --arg note "$note" --argjson now "$(state_now)" \
    '{ticket: $t, attempt: $n, note: $note, at: $now}' >"$RUN_DIR/steering/.$t.$n.json.tmp.$$"
  mv "$RUN_DIR/steering/.$t.$n.json.tmp.$$" "$RUN_DIR/steering/$t.$n.json"
  # The runner stops its worker and everything the worker left running, then
  # writes its exit record.
  runner=$(cat "$RUN_DIR/workers/$t.$n/runner.pid" 2>/dev/null || true)
  if state_is_uint "$runner" && state_pid_alive "$runner"; then
    kill -TERM "$runner" 2>/dev/null || true
  fi
  i=0
  while [ ! -f "$RUN_DIR/results/$t.$n.exit.json" ] && [ "$i" -lt $((wait_s * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$RUN_DIR/results/$t.$n.exit.json" ] \
    || die "the worker for #$t did not stop within ${wait_s}s; its steering note is kept, run this again"
  # What it had not committed stays on its branch, for the next worker.
  wt=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    git -C "$wt" add -A >/dev/null 2>&1 || true
    git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-Artisan-Agent}" -c user.email="${GIT_AUTHOR_EMAIL:-artisan-agent@localhost}" \
      commit -q -m "WIP: stopped for steering (#$t attempt $n)" >/dev/null 2>&1 || true
  fi
  run_sweep || rc=$?
  case "$rc" in
    0) echo "steered #$t: attempt $n stopped, queued again with your notes; not a failed attempt. Dispatch it again (wave.sh dispatch)." ;;
    3) echo "steered #$t: attempt $n stopped; the orchestrator holds the state lock and records the steering at its next sweep." ;;
    *) exit "$rc" ;;
  esac
}

# --------------------------------------------------------------- add, urgent

# request_line ticket model estimate title: the one-line approval.
approval_line() { # kind ticket model estimate title
  get -r --arg k "$1" --arg t "$2" --arg m "$3" --argjson e "$4" --arg title "$5" '
    def r2: (. * 100 | round) / 100;
    def usd: "$" + (. | tostring);
    ((.plan.config.overrun_allowance_percent // 25) as $pct
     | (($e * (1 + $pct / 100)) | r2) as $inc
     | (.plan.budget_usd) as $b
     | (if $k == "urgent" then "Urgent #" else "Add #" end) + $t
       + (if $title == "" then "" else " (\($title))" end)
       + ": \($m), estimate \($e | usd), run budget "
       + (if $b == null then "unset (no budget to grow)" else "\($b | usd) -> \(($b + $inc) | r2 | usd)" end)
       + " (estimate plus the \($pct)% overrun allowance)")' "$FILE"
}

cmd_add() { # kind run-dir ticket ...
  local kind="$1"
  shift
  open_run "${1:-}"
  local t="${2:-}" model= est= title= minutes= files= priority= approve=0 by=Artisan req= rc=0
  [ -n "$t" ] || usage
  state_is_uint "$t" || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
      --estimate-usd) [ $# -ge 2 ] || usage; est=$2; shift 2 ;;
      --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
      --minutes) [ $# -ge 2 ] || usage; minutes=$2; shift 2 ;;
      --expected-files) [ $# -ge 2 ] || usage; files=$2; shift 2 ;;
      --priority) [ $# -ge 2 ] || usage; priority=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      --approve) approve=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$model" ] && [ -n "$est" ] || usage
  jq -e -n --argjson e "$est" '$e > 0' >/dev/null 2>&1 || usage
  [ -z "$minutes" ] || state_is_uint "$minutes" || usage
  [ -z "$priority" ] || state_is_uint "$priority" || usage
  [ "$(get --arg t "$t" '.plan.scope | map(tostring) | index($t) != null')" != true ] \
    || refuse "#$t is already in the run's scope"
  [ "$(get '.end_gate.status // "" | . == "ended"')" != true ] || refuse "the run has ended"
  approval_line "$kind" "$t" "$model" "$est" "$title"
  if [ "$kind" = add ] && [ "$approve" -eq 0 ]; then
    echo "Nothing is recorded. Approve with: lever.sh add $RUN_DIR $t --model $model --estimate-usd $est --approve"
    return 0
  fi
  mkdir -p "$RUN_DIR/levers"
  req="$RUN_DIR/levers/$kind-$t.json"
  jq -n --arg t "$t" --arg model "$model" --argjson est "$est" --arg title "$title" --arg minutes "$minutes" \
    --arg files "$files" --arg priority "$priority" --arg by "$by" --arg kind "$kind" '
    {ticket: $t, model: $model, estimate_usd: $est, by: $by, urgent: ($kind == "urgent")}
    + (if $title == "" then {} else {title: $title} end)
    + (if $minutes == "" then {} else {minutes: ($minutes | tonumber)} end)
    + (if $files == "" then {} else {expected_files: ($files | split(",") | map(select(. != ""))) } end)
    + (if $priority == "" then {} else {priority: ($priority | tonumber)} end)' >"$req.tmp.$$"
  mv "$req.tmp.$$" "$req"
  run_sweep || rc=$?
  case "$rc" in
    0) if [ "$kind" = urgent ]; then
         echo "recorded: #$t is urgent and in scope. Dispatch it now on the extra slot: wave.sh dispatch $RUN_DIR $t"
       else
         echo "recorded: #$t joins the next wave, ahead of lower-priority tickets."
       fi ;;
    3) echo "recorded in levers/: the orchestrator holds the state lock and the ticket joins the run at its next sweep." ;;
    *) exit "$rc" ;;
  esac
}

cmd_pending() {
  open_run "${1:-}"
  get -r '.tickets | to_entries[] | select(.value.urgent == true and .value.status == "queued") | .key'
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  steer) cmd_steer "$@" ;;
  add) cmd_add add "$@" ;;
  urgent) cmd_add urgent "$@" ;;
  pending) [ $# -eq 1 ] || usage; cmd_pending "$@" ;;
  *) usage ;;
esac
