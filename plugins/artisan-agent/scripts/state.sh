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
#   state.sh dispatch <run-dir> <ticket> <worker-pid> [deadline-epoch]
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

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

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
  jq --argjson v "$ARTISAN_STATE_SCHEMA_VERSION" '
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
        tickets: (
          $p.scope | map(tostring) | map({
            key: .,
            value: {
              status: "queued", attempts: 0, pid: null,
              branch: ($p.tickets[.].branch // ("agent/" + .)),
              dispatched_at: null, deadline_at: null,
              result: null, evidence: null, merge_commit: null,
              cost_usd: 0, failures: []
            }
          }) | from_entries
        ),
        integration: { branch: $p.integration_branch, merges: [] },
        findings: [],
        findings_read: {},
        costs: { workers_usd: 0, orchestrator_usd: 0, total_usd: 0 },
        decisions: [],
        waves: [],
        frontier: []
      }' "$plan" >"$tmp" || { rm -f "$tmp"; return 1; }
  state_commit "$run_dir" "$tmp"
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
    state_with_lock "$1" state_apply "$1" '
      if .tickets[$t] == null then error("ticket \($t) is not in the run") else . end
      | (.plan.tickets[$t].caps.deadline_seconds // null) as $secs
      | .tickets[$t] |= (
          .status = "in_flight" | .attempts += 1 | .pid = $pid
          | .dispatched_at = $now | .result = null
          | .deadline_at = (if $deadline != "" then ($deadline | tonumber)
                            elif $secs != null then $now + $secs else null end))' \
      --arg t "$2" --argjson pid "$3" --argjson now "$(state_now)" --arg deadline "${4:-}"
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
    state_with_lock "$1" state_apply "$1" '
      if .tickets[$t] == null then error("ticket \($t) is not in the run") else . end
      | .tickets[$t] |= (.status = "merged" | .merge_commit = $sha | .pid = null)
      | .integration.merges |= (map(select(.ticket != $t)) + [{ticket: $t, commit: $sha}])' \
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
