#!/usr/bin/env bash
# A worker's CI run on its own branch (#194). On a machine whose merge gate
# runs on CI, a recorded check this machine can't run (runs_locally never, or
# mac off macOS: checks.sh ci-only) is run by the project's gate workflow on
# the worker's branch instead. The worker (/artisan-agent:implement) calls
# `run`, fixes and calls it again until it is green, and puts every record in
# its evidence's ci_runs; the verifier calls `check` on the green one. It
# opens no PR. Rules: ${CLAUDE_PLUGIN_ROOT}/references/checks.md, "A worker's
# CI run".
#
# Usage:
#   worker-ci.sh run [--dir D] [--branch B] [--repo O/N] [--remote R]
#                    [--timeout-minutes M]
#       push B (default: D's current branch; D defaults to the top of the
#       checkout holding the current directory) at its tip to R (default
#       origin), dispatch the gate workflow (ci_gate.workflow in the project
#       config) there with the inputs in ci_gate.worker_inputs (gh workflow
#       run -f key=value each), and wait, in this one call, for that
#       dispatch's run (a workflow_dispatch run on B for the tip, newer than
#       any before the dispatch). Prints the record as JSON:
#         {workflow, branch, sha, tree, run_id, url, conclusion, jobs,
#          inputs, full, checks, started_at, finished_at, minutes}
#       full is true when inputs is empty: the run is the gate's own run, so
#       the merge gate may reuse it; checks are the CI-only checks it stood
#       for; minutes is the run's own time (created to last updated), what it
#       costs the attempt. A red record also holds failing_tests
#       (merge-gate.sh failed-tests), one with no verdict a why. M defaults to
#       ci_gate.timeout_minutes (30).
#       Exit 0 green (success), 7 red (failure or timed_out), 19 no verdict
#       (push or dispatch failed, none in time, any other conclusion), 16
#       nothing to run on CI: the merge gate is local or every check runs
#       here (prints {checks: [], why}, dispatches nothing), 1 no gate
#       workflow recorded.
#   worker-ci.sh check --repo O/N --run-id ID --sha SHA
#       whether run ID is green for exactly SHA (gh run view): prints
#       {run_id, url, conclusion, sha, ok, why}. Exit 0 ok, 7 not (red, for
#       another commit, or not found).
#
# Environment: ARTISAN_CI_POLL_SECONDS, the wait between readings (default
# 20); ARTISAN_MERGE_GATE and ARTISAN_HOST_OS as in merge-gate.sh.
#
# Exit status: 0 ok, 1 error, 2 usage, 7 red, 16 nothing to run, 19 no
# verdict (scripts/README.md, "Exit status").
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'worker-ci.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The newest workflow_dispatch run of WF on BRANCH, any commit, as JSON; empty
# when there is none.
runs_on() { # repo wf branch
  gh run list -R "$1" --workflow "$2" --branch "$3" --event workflow_dispatch --limit 20 \
    --json databaseId,headSha,status,conclusion,url,createdAt,updatedAt 2>/dev/null || echo '[]'
}

cmd_run() {
  local dir="" branch="" repo="" remote=origin timeout="" cfg="" wf="" inputs="" ci="" sha="" tree=""
  local before=0 run="" id="" view="" deadline=0 poll=${ARTISAN_CI_POLL_SECONDS:-20} conclusion="" started="" f=""
  local -a fields=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || usage; dir=$2; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage; branch=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
      --remote) [ $# -ge 2 ] || usage; remote=$2; shift 2 ;;
      --timeout-minutes) [ $# -ge 2 ] || usage; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$dir" ] || dir=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout; pass --dir"
  [ -n "$branch" ] || branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || die "$dir is not on a branch; pass --branch"
  ci=$("$SCRIPT_DIR/checks.sh" ci-only --dir "$dir" | jq -Rsc 'split("\n") | map(select(. != ""))') \
    || die "could not read the recorded checks in $dir"
  if [ "$ci" = '[]' ]; then
    jq -nc '{checks: [], why: "nothing to run on CI: this machine runs every recorded check (checks.sh ci-only)"}'
    return 16
  fi
  cfg=$(cd "$dir" && "$SCRIPT_DIR/config.sh" show) || die "could not read the project config"
  wf=$(jq -r '.ci_gate.workflow // ""' <<<"$cfg")
  [ -n "$wf" ] || die "the project records no gate workflow (ci_gate.workflow in .artisan-agent/config.yml), so $(jq -r 'join(", ")' <<<"$ci") can't run on CI"
  inputs=$(jq -c '.ci_gate.worker_inputs // {}' <<<"$cfg")
  [ -n "$timeout" ] || timeout=$(jq -r '.ci_gate.timeout_minutes // 30' <<<"$cfg")
  case "$timeout" in '' | *[!0-9]*) die "--timeout-minutes must be a whole number" ;; esac
  if [ -z "$repo" ]; then
    repo=$(git -C "$dir" remote get-url "$remote" 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##') || true
    [ -n "$repo" ] || die "could not tell the GitHub repo from $remote; pass --repo"
  fi
  sha=$(git -C "$dir" rev-parse --verify "refs/heads/$branch^{commit}") || die "no branch $branch in $dir"
  tree=$(git -C "$dir" rev-parse "$sha^{tree}")
  while IFS= read -r f; do [ -z "$f" ] || fields+=(-f "$f"); done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$inputs")

  # record run-json why: the run's record.
  record() {
    jq -nc --argjson r "$1" --arg why "$2" --arg wf "$wf" --arg b "$branch" --arg sha "$sha" --arg tree "$tree" \
      --argjson in "$inputs" --argjson ci "$ci" --arg s "$started" --arg f "$(now_iso)" '
      def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      {workflow: $wf, branch: $b, sha: $sha, tree: $tree,
       run_id: ($r.databaseId // null), url: ($r.url // null), conclusion: ($r.conclusion // null),
       jobs: [($r.jobs // [])[] | {name, conclusion}],
       inputs: $in, full: ($in == {}), checks: $ci, started_at: $s, finished_at: $f,
       minutes: (if $r.createdAt and $r.updatedAt
                 then ((($r.updatedAt | secs) - ($r.createdAt | secs)) / 60 * 10 | ceil) / 10 else null end)}
      + (if $why == "" then {} else {why: $why} end)'
  }

  started=$(now_iso)
  # The newest run before the dispatch: only a newer one is this dispatch's.
  before=$(runs_on "$repo" "$wf" "$branch" | jq '[.[].databaseId] | max // 0')
  if ! git -C "$dir" push -q --force "$remote" "$sha:refs/heads/$branch" >/dev/null 2>&1; then
    record '{}' "could not push $branch to $remote"
    return 19
  fi
  if ! gh workflow run "$wf" -R "$repo" --ref "$branch" ${fields[@]+"${fields[@]}"} >/dev/null 2>&1; then
    record '{}' "could not dispatch $wf on $branch (gh workflow run failed)"
    return 19
  fi
  deadline=$(($(date +%s) + timeout * 60))
  while :; do
    run=$(runs_on "$repo" "$wf" "$branch" | jq -c --arg sha "$sha" --argjson b "$before" \
      '[.[] | select(.headSha == $sha and .databaseId > $b)] | sort_by(.databaseId) | last // empty')
    if [ -n "$run" ] && [ "$(jq -r .status <<<"$run")" = completed ]; then break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      [ -n "$run" ] || run='{}'
      record "$run" "no conclusion from $wf for $sha within $timeout minutes"
      return 19
    fi
    sleep "$poll"
  done
  id=$(jq -r .databaseId <<<"$run")
  view=$(gh run view "$id" -R "$repo" --json databaseId,headSha,status,conclusion,url,jobs,createdAt,updatedAt 2>/dev/null) || view=$run
  jq -e --arg sha "$sha" '.headSha == $sha' <<<"$view" >/dev/null 2>&1 || view=$run
  conclusion=$(jq -r '.conclusion // ""' <<<"$view")
  case "$conclusion" in
    success) record "$view" "" ;;
    failure | timed_out)
      record "$view" "" | jq -c --argjson f "$("$SCRIPT_DIR/merge-gate.sh" failed-tests --repo "$repo" --run-id "$id" 2>/dev/null || echo null)" \
        '. + {failing_tests: $f}'
      return 7 ;;
    *)
      record "$view" "$wf concluded ${conclusion:-nothing} for $sha, so CI did not judge it"
      return 19 ;;
  esac
}

cmd_check() {
  local repo="" id="" sha="" view="" why=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
      --run-id) [ $# -ge 2 ] || usage; id=$2; shift 2 ;;
      --sha) [ $# -ge 2 ] || usage; sha=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$id" ] && [ -n "$sha" ] || usage
  view=$(gh run view "$id" -R "$repo" --json databaseId,headSha,status,conclusion,url 2>/dev/null) || view=""
  if [ -z "$view" ]; then
    why="no run $id on $repo"
    view='{}'
  elif [ "$(jq -r .headSha <<<"$view")" != "$sha" ]; then
    why="run $id ran $(jq -r .headSha <<<"$view"), not $sha"
  elif [ "$(jq -r '.conclusion // ""' <<<"$view")" != success ]; then
    why="run $id concluded $(jq -r '.conclusion // "nothing yet"' <<<"$view"), not success"
  fi
  jq -nc --argjson r "$view" --arg id "$id" --arg why "$why" '
    {run_id: ($r.databaseId // ($id | tonumber? // $id)), url: ($r.url // null), conclusion: ($r.conclusion // null),
     sha: ($r.headSha // null), ok: ($why == "")} + (if $why == "" then {} else {why: $why} end)'
  [ -z "$why" ] || return 7
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  run) cmd_run "$@" ;;
  check) cmd_check "$@" ;;
  *) usage ;;
esac
