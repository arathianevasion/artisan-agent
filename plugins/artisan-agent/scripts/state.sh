#!/usr/bin/env bash
# The run state file: create it, lock it, and record events in it.
# Shape and meaning of every field: ${CLAUDE_PLUGIN_ROOT}/references/state-file.md
#
# Usage:
#   state.sh run-dir <run-id>                 print <main checkout>/.artisan-agent/runs/<run-id>
#   state.sh init <run-dir> <plan.json>       create the state file from an approved plan
#   state.sh show <run-dir>                   print the state file
#   state.sh lock <run-dir> [pid]             take the writer lock for pid (default: parent)
#   state.sh unlock <run-dir> [pid]           release it
#   state.sh write <run-dir>                  replace the state file with stdin
#   state.sh update <run-dir> <filter> [jq args...]
#   state.sh wave-start <run-dir> <wave> <plugin-version> <team-sha> <product-sha> <individual-sha>
#                                             (- for a guardrail level with no source)
#   state.sh dispatch <run-dir> <ticket> <worker-pid> [deadline-epoch]
#                                             (default: now + the ticket's caps.deadline_seconds;
#                                             refused when there is neither)
#   state.sh evidence <run-dir> <ticket> <evidence.json>
#   state.sh merge <run-dir> <ticket> <merge-commit>
#   state.sh decision <run-dir> <decision.json>
#   state.sh cost <run-dir> <orchestrator-usd>  add orchestrator spend
#
# Every write takes the lock unless ARTISAN_WRITER_PID already holds it, and
# rewrites the file in one step. Exit status: 0 ok, 1 error, 2 usage,
# 3 the lock is held by another live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }

cmd_run_dir() {
  local id="$1" common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || state_die 1 "not inside a git repository"
  printf '%s/.artisan-agent/runs/%s\n' "$(dirname "$common")" "$id"
}

cmd_init() {
  local run_dir="$1" plan="$2"
  [ -f "$plan" ] || state_die 1 "no plan file: $plan"
  jq -e 'type == "object" and (.run_id | type == "string") and (.repo | type == "string")
         and (.integration_branch | type == "string") and (.scope | type == "array")' \
    "$plan" >/dev/null 2>&1 \
    || state_die 1 "plan must be an object with run_id, repo, integration_branch and scope"
  [ ! -e "$(state_file "$run_dir")" ] || state_die 1 "state file already exists in $run_dir"
  mkdir -p "$run_dir/results/findings"
  (cd "$run_dir" && git rev-parse --show-toplevel >/dev/null 2>&1) \
    || state_die 1 "run folder $run_dir is not inside a git repository"
  (cd "$run_dir" && git check-ignore -q state.json) \
    || state_die 1 "run folder $run_dir is not gitignored; add .artisan-agent/runs/ to .gitignore"
  state_with_lock "$run_dir" init_write "$run_dir" "$plan"
}

init_write() {
  local run_dir="$1" plan="$2" tmp
  tmp=$(state_tmp "$run_dir")
  jq --argjson v "$ARTISAN_STATE_SCHEMA_VERSION" "$STATE_JQ_DEFS"'
    . as $p
    | {
        schema_version: $v,
        run_id: $p.run_id,
        repo: $p.repo,
        plan: {
          scope: ($p.scope | map(tostring)),
          waves: ($p.waves // []),
          tickets: ($p.tickets // {}),
          gates: ($p.gates // []),
          max_agents: ($p.max_agents // 5),
          budget_usd: ($p.budget_usd // null),
          attempts_per_ticket: ($p.attempts_per_ticket // 2)
        },
        tickets: {},
        integration: { branch: $p.integration_branch, merges: [] },
        findings: [],
        findings_read: {},
        costs: { workers_usd: 0, orchestrator_usd: 0, total_usd: 0 },
        decisions: [],
        waves: [],
        frontier: []
      }
    | reduce .plan.scope[] as $t (.; .tickets[$t] = new_ticket($t))' "$plan" >"$tmp" || { rm -f "$tmp"; return 1; }
  state_commit "$run_dir" "$tmp"
}

# dispatch_ticket run_dir ticket pid deadline-or-empty. Caller holds the lock.
# Every dispatch has a deadline, so a hung worker is always stopped. A retry
# first moves the previous attempt's result file and exit record aside to
# results/<ticket>.attempt-<n>.*, so the sweep reads only this attempt's.
dispatch_ticket() {
  local run_dir="$1" t="$2" pid="$3" deadline="$4" now file attempts ext
  file=$(state_file "$run_dir")
  now=$(state_now)
  jq -e --arg t "$t" '.tickets[$t] != null' "$file" >/dev/null \
    || state_die 1 "ticket $t is not in the run"
  if [ -z "$deadline" ]; then
    deadline=$(jq -r --arg t "$t" --argjson now "$now" \
      '(.plan.tickets[$t].caps.deadline_seconds // null) as $s
       | if $s == null then "" else $now + $s end' "$file")
    [ -n "$deadline" ] \
      || state_die 1 "ticket $t has no deadline: pass one or set plan.tickets[\"$t\"].caps.deadline_seconds"
  fi
  attempts=$(jq -r --arg t "$t" '.tickets[$t].attempts' "$file")
  for ext in json exit.json; do
    if [ -f "$run_dir/results/$t.$ext" ]; then
      mv -f "$run_dir/results/$t.$ext" "$run_dir/results/$t.attempt-$attempts.$ext"
    fi
  done
  state_apply "$run_dir" '
    .tickets[$t] |= (
      .status = "in_flight" | .attempts += 1 | .pid = $pid
      | .dispatched_at = $now | .deadline_at = $deadline | .result = null)' \
    --arg t "$t" --argjson pid "$pid" --argjson now "$now" --argjson deadline "$deadline"
}

write_stdin() {
  local run_dir="$1" tmp
  tmp=$(state_tmp "$run_dir")
  cat >"$tmp"
  state_commit "$run_dir" "$tmp"
}

[ $# -ge 1 ] || usage
cmd="$1"
shift

case "$cmd" in
  run-dir)
    [ $# -eq 1 ] || usage
    cmd_run_dir "$1"
    ;;
  init)
    [ $# -eq 2 ] || usage
    cmd_init "$1" "$2"
    ;;
  show)
    [ $# -eq 1 ] || usage
    state_require_run_dir "$1"
    cat "$(state_file "$1")"
    ;;
  lock)
    [ $# -ge 1 ] || usage
    mkdir -p "$1"
    state_lock "$1" "${2:-$PPID}"
    ;;
  unlock)
    [ $# -ge 1 ] || usage
    state_unlock "$1" "${2:-$PPID}"
    ;;
  write)
    [ $# -eq 1 ] || usage
    mkdir -p "$1"
    state_with_lock "$1" write_stdin "$1"
    ;;
  update)
    [ $# -ge 2 ] || usage
    state_require_run_dir "$1"
    state_with_lock "$1" state_apply "$@"
    ;;
  wave-start)
    [ $# -eq 6 ] || usage
    state_require_run_dir "$1"
    state_with_lock "$1" state_apply "$1" '
      .waves |= ((map(select(.wave != $w))) + [{
        wave: $w, started_at: $now, plugin_version: $pv,
        guardrails: {
          team: (if $team == "-" then null else $team end),
          product: (if $product == "-" then null else $product end),
          individual: (if $individual == "-" then null else $individual end)
        }
      }] | sort_by(.wave))' \
      --argjson w "$2" --argjson now "$(state_now)" --arg pv "$3" \
      --arg team "$4" --arg product "$5" --arg individual "$6"
    ;;
  dispatch)
    [ $# -ge 3 ] && [ $# -le 4 ] || usage
    state_require_run_dir "$1"
    state_with_lock "$1" dispatch_ticket "$1" "$2" "$3" "${4:-}"
    ;;
  evidence)
    [ $# -eq 3 ] || usage
    state_require_run_dir "$1"
    jq -e . "$3" >/dev/null 2>&1 || state_die 1 "evidence is not JSON: $3"
    state_with_lock "$1" state_apply "$1" '
      if .tickets[$t] == null then error("ticket \($t) is not in the run") else . end
      | .tickets[$t].evidence = $ev[0]' \
      --arg t "$2" --slurpfile ev "$3"
    ;;
  merge)
    [ $# -eq 3 ] || usage
    state_require_run_dir "$1"
    state_with_lock "$1" state_apply "$1" "$STATE_JQ_DEFS"'
      if .tickets[$t] == null then error("ticket \($t) is not in the run") else . end
      | merged($t; $sha)' \
      --arg t "$2" --arg sha "$3"
    ;;
  decision)
    [ $# -eq 2 ] || usage
    state_require_run_dir "$1"
    jq -e 'type == "object"' "$2" >/dev/null 2>&1 || state_die 1 "decision must be a JSON object: $2"
    state_with_lock "$1" state_apply "$1" '
      .decisions += [$d[0] + {id: ((.decisions | length) + 1), status: "waiting", at: $now}]' \
      --slurpfile d "$2" --argjson now "$(state_now)"
    ;;
  cost)
    [ $# -eq 2 ] || usage
    state_require_run_dir "$1"
    state_with_lock "$1" state_apply "$1" '
      .costs.orchestrator_usd += $usd
      | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)' \
      --argjson usd "$2"
    ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
