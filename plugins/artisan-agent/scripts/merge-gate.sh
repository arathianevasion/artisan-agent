#!/usr/bin/env bash
# The merge gate's two modes (#139): where the full suite runs after a merge.
# The machine chooses, not the project: host.json in the individual home holds
# merge_gate: auto | local | ci (machine-setup.sh merge-gate writes it); auto,
# the default, is local on macOS and ci on Linux. local runs the plan's suite
# in the integration worktree, as always (wave.sh). ci pushes the merge commit
# to a throwaway ci/* branch, dispatches the project's gate workflow there and
# gates on that run's overall conclusion, for that exact commit; it never runs
# the suite on this machine. This script reads and talks to CI; it never writes
# the run's state file (wave.sh does). Rules: references/checks.md, "The merge
# gate on CI".
#
# Usage:
#   merge-gate.sh mode
#       local or ci: the mode this machine's merge gate runs in.
#   merge-gate.sh show
#       how it was chosen, as JSON: {mode, setting, source, os, batch,
#       batch_source}.
#   merge-gate.sh batch
#       on or off: whether wave.sh merge gates tickets ready together as one
#       merge batch (#167). host.json's merge_batch (on | off), default on.
#   merge-gate.sh start --result FILE --pid-file FILE --log FILE -- local|ci ARGS...
#       run the gate (merge-gate.sh local or ci with ARGS) detached, the way
#       run-ticket.sh starts a worker (lib/detach-lib.sh), so it outlives its
#       caller and no caller's time cap stops it (#142). Prints the gate
#       runner's pid and returns at once. The runner writes its pid to the pid
#       file and, when the gate ends, its outcome to the result file, which
#       wait-any.sh sees under results/: {exit_code, record, finished_at},
#       exit_code and record (its JSON output, or null) as the gate gave them.
#       A runner that is stopped or dies writes no result, so a missing result
#       with no live runner is a gate that never finished. The gate runs in the
#       runner's session: stopping that session's group stops the suite too.
#   merge-gate.sh local --dir D --command CMD --log FILE
#       the gate on this machine: CMD (the plan's suite) in D, its output to
#       FILE. Prints {mode: "local", command, passed}. Exit 0 green, 7 red.
#   merge-gate.sh find --repo O/N --workflow FILE --branch B --sha SHA
#       the gate workflow's dispatched run on B for SHA, as JSON (any status);
#       exit 1 when there is none, so a gate cut off before its dispatch has
#       no CI run to wait on.
#   merge-gate.sh ci --repo O/N --workflow FILE --branch B --sha SHA --dir D
#                    [--timeout-minutes M | --deadline EPOCH] [--resume] [--remote R]
#                    [--skip-path PATTERN]...
#       push SHA (a commit in the git checkout D) to branch B on remote R
#       (default origin), dispatch FILE there (gh workflow run), wait for the
#       workflow_dispatch run on B whose head SHA is SHA, and delete B, pass
#       or fail. Prints the gate's record as JSON: {mode: "ci", workflow,
#       branch, sha, run_id, url, conclusion, jobs: [{name, conclusion}]}
#       (run_id, url, conclusion null when no run concluded; with a "why"
#       when CI gave no verdict). Exit 0 the run concluded success; 7 red:
#       it concluded failure or timed_out (the suite failed or hung); 19 no
#       verdict: the push or dispatch failed, none concluded within M minutes
#       (default 30), or the run concluded anything else (cancelled, skipped,
#       stale, startup_failure, action_required or a conclusion not known
#       here), so CI never judged the commit. A run for any other SHA never
#       counts. --deadline stops waiting at that epoch second instead of M
#       minutes from now. --resume waits on a run already dispatched on B
#       (a gate whose runner died): no push and no new dispatch.
#       --skip-path (#168, from merge_gate_skip_paths in the config) is the
#       release allowlist: before pushing, find the newest run of FILE that
#       concluded success on a commit that is an ancestor of SHA; when every
#       path SHA changed since that commit matches the allowlist, nothing is
#       pushed or dispatched and the record is green with skipped: true,
#       relied_on {run_id, url, sha} and a why naming that run. Patterns are
#       shell globs ("*" crosses "/"); they are read in order and the last to
#       match a path decides, a leading "!" meaning "never skip on this".
#       With no green ancestor, or any other path changed, CI runs as usual.
#   merge-gate.sh sweep --prefix P [--dir D] [--remote R]
#       delete every branch on the remote whose name starts with P (a run's
#       ci/<run-id>- leftovers from a crash). Prints one "deleted <branch>"
#       line each. A checkout without the remote has nothing to sweep.
#   merge-gate.sh minutes --repo O/N --workflow FILE [--limit N]
#       expected CI minutes per merge, from the workflow's last N (default 10)
#       completed runs: {runs, minutes} (minutes null with no runs). For the
#       plan step on a CI machine.
#   merge-gate.sh workflow-check FILE
#       exit 0 when the workflow file has a workflow_dispatch trigger; 1 and a
#       line naming it otherwise (setup refuses such a gate workflow).
#
# Environment: ARTISAN_MERGE_GATE (auto|local|ci) and ARTISAN_MERGE_BATCH
# (on|off) override host.json, for tests and trials; ARTISAN_HOST_OS (macos|linux) stands in for uname;
# ARTISAN_HOME, CLAUDE_CONFIG_DIR place host.json (as login-check.sh);
# ARTISAN_CI_POLL_SECONDS, the wait between readings (default 20).
#
# Exit status: 0 ok, 1 error, 2 usage, 7 CI concluded red (failure or
# timed_out), 19 no CI verdict (scripts/README.md, "Exit status").
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq and, for ci and
# minutes, gh.

set -euo pipefail

# shellcheck source=lib/detach-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/detach-lib.sh"

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOST_FILE=${ARTISAN_HOME:-$CFG/artisan-agent}/host.json

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'merge-gate.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

host_os() {
  if [ -n "${ARTISAN_HOST_OS:-}" ]; then printf '%s\n' "$ARTISAN_HOST_OS"
  elif [ "$(uname -s)" = Darwin ]; then echo macos; else echo linux; fi
}

# batch_setting: "<on|off> <source>", from ARTISAN_MERGE_BATCH, else
# host.json's merge_batch, else on.
batch_setting() {
  local b="" src=""
  if [ -n "${ARTISAN_MERGE_BATCH:-}" ]; then
    b=$ARTISAN_MERGE_BATCH src=ARTISAN_MERGE_BATCH
  elif [ -f "$HOST_FILE" ] && b=$(jq -er '.merge_batch // empty' "$HOST_FILE" 2>/dev/null); then
    src=$HOST_FILE
  else
    b=on src=default
  fi
  case "$b" in on | off) ;; *) die "merge_batch must be on or off, not \"$b\" ($src)" ;; esac
  printf '%s %s\n' "$b" "$src"
}

cmd_batch() { batch_setting | cut -d' ' -f1; }

# mode_json: how the mode was chosen, {mode, setting, source, os}.
mode_json() {
  local setting="" source="" os="" mode=""
  if [ -n "${ARTISAN_MERGE_GATE:-}" ]; then
    setting=$ARTISAN_MERGE_GATE source=ARTISAN_MERGE_GATE
  elif [ -f "$HOST_FILE" ] && setting=$(jq -er '.merge_gate // empty' "$HOST_FILE" 2>/dev/null); then
    source=$HOST_FILE
  else
    setting=auto source=default
  fi
  os=$(host_os)
  case "$setting" in
    local | ci) mode=$setting ;;
    auto) if [ "$os" = macos ]; then mode=local; else mode=ci; fi ;;
    *) die "merge_gate must be auto, local or ci, not \"$setting\" ($source)" ;;
  esac
  jq -nc --arg m "$mode" --arg s "$setting" --arg src "$source" --arg os "$os" \
    '{mode: $m, setting: $s, source: $src, os: $os}'
}

cmd_show() {
  local m="" batch=""
  m=$(mode_json)
  batch=$(batch_setting)
  jq -c --arg b "${batch%% *}" --arg bsrc "${batch#* }" '. + {batch: $b, batch_source: $bsrc}' <<<"$m"
}

cmd_mode() { mode_json | jq -r .mode; }

# ----------------------------------------------------------------------- ci

# record why: the gate's record with no conclusion.
CI_REPO= CI_WF= CI_BRANCH= CI_SHA= CI_DIR= CI_REMOTE=origin
record() { # run-json why
  jq -nc --argjson r "$1" --arg why "$2" --arg wf "$CI_WF" --arg b "$CI_BRANCH" --arg sha "$CI_SHA" '
    {mode: "ci", workflow: $wf, branch: $b, sha: $sha,
     run_id: ($r.databaseId // null), url: ($r.url // null), conclusion: ($r.conclusion // null),
     jobs: [($r.jobs // [])[] | {name, conclusion}]}
    + (if $why == "" then {} else {why: $why} end)'
}

delete_branch() {
  git -C "$CI_DIR" push -q "$CI_REMOTE" --delete "$CI_BRANCH" >/dev/null 2>&1 \
    || echo "merge-gate.sh: could not delete $CI_BRANCH on $CI_REMOTE; the next gate's sweep will" >&2
}

# The dispatched run for exactly this commit: the newest workflow_dispatch run
# on the branch whose head SHA is ours. Empty while none is listed yet.
find_run() {
  gh run list -R "$CI_REPO" --workflow "$CI_WF" --branch "$CI_BRANCH" --event workflow_dispatch \
    --limit 20 --json databaseId,headSha,status,conclusion,url 2>/dev/null \
    | jq -c --arg sha "$CI_SHA" '[.[] | select(.headSha == $sha)] | first // empty' 2>/dev/null || true
}

# skippable PATH PATTERN...: 0 when the allowlist lets a change to PATH go
# without CI: the last pattern to match decides, and "!" denies.
skippable() {
  local path="$1" pat="" neg=0 ok=1
  shift
  for pat in "$@"; do
    neg=0
    case "$pat" in '!'*) neg=1 pat=${pat#!} ;; esac
    # shellcheck disable=SC2254
    case "$path" in $pat) if [ "$neg" -eq 1 ]; then ok=1; else ok=0; fi ;; esac
  done
  return "$ok"
}

# green_ancestor: the newest successful run of the workflow whose head SHA is
# an ancestor of the candidate, as the run's JSON; empty when there is none.
green_ancestor() {
  local runs="" sha=""
  runs=$(gh run list -R "$CI_REPO" --workflow "$CI_WF" --limit 50 \
    --json databaseId,headSha,status,conclusion,url 2>/dev/null) || return 0
  for sha in $(jq -r '.[] | select(.conclusion == "success") | .headSha' <<<"$runs" 2>/dev/null); do
    if git -C "$CI_DIR" merge-base --is-ancestor "$sha" "$CI_SHA" 2>/dev/null; then
      jq -c --arg sha "$sha" '[.[] | select(.conclusion == "success" and .headSha == $sha)] | first' <<<"$runs"
      return 0
    fi
  done
}

# try_skip PATTERN...: when only allowlisted paths changed since the last
# green run, print the green record and return 0; 1 means run CI.
try_skip() {
  local green="" base="" path="" changed="" n=0
  [ $# -gt 0 ] || return 1
  green=$(green_ancestor)
  [ -n "$green" ] || return 1
  base=$(jq -r .headSha <<<"$green")
  changed=$(git -C "$CI_DIR" -c core.quotepath=off diff --name-only --no-renames "$base" "$CI_SHA" 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    skippable "$path" "$@" || return 1
    n=$((n + 1))
  done <<<"$changed"
  jq -nc --argjson g "$green" --argjson n "$n" --arg wf "$CI_WF" --arg b "$CI_BRANCH" --arg sha "$CI_SHA" '
    {mode: "ci", workflow: $wf, branch: $b, sha: $sha, run_id: $g.databaseId, url: $g.url,
     conclusion: "success", jobs: [], skipped: true,
     relied_on: {run_id: $g.databaseId, url: $g.url, sha: $g.headSha},
     why: "CI not dispatched: only release paths changed (\($n) file\(if $n == 1 then "" else "s" end)) since \($g.headSha[0:12]), which run \($g.databaseId) passed"}'
}

cmd_ci() {
  local timeout=30 run="" id="" view="" deadline=0 poll=${ARTISAN_CI_POLL_SECONDS:-20} conclusion="" resume=0 allowed=""
  local -a skip=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; CI_REPO=$2; shift 2 ;;
      --workflow) [ $# -ge 2 ] || usage; CI_WF=$2; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage; CI_BRANCH=$2; shift 2 ;;
      --sha) [ $# -ge 2 ] || usage; CI_SHA=$2; shift 2 ;;
      --dir) [ $# -ge 2 ] || usage; CI_DIR=$2; shift 2 ;;
      --remote) [ $# -ge 2 ] || usage; CI_REMOTE=$2; shift 2 ;;
      --timeout-minutes) [ $# -ge 2 ] || usage; timeout=$2; shift 2 ;;
      --deadline) [ $# -ge 2 ] || usage; deadline=$2; shift 2 ;;
      --skip-path) [ $# -ge 2 ] || usage; skip+=("$2"); shift 2 ;;
      --resume) resume=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$CI_REPO" ] && [ -n "$CI_WF" ] && [ -n "$CI_BRANCH" ] && [ -n "$CI_SHA" ] && [ -n "$CI_DIR" ] || usage
  case "$CI_BRANCH" in ci/*) ;; *) die "the gate branch must be under ci/, not $CI_BRANCH" ;; esac
  case "$timeout" in '' | *[!0-9]*) die "--timeout-minutes must be a whole number" ;; esac
  case "$deadline" in '' | *[!0-9]*) die "--deadline must be an epoch second" ;; esac

  if [ "$resume" -eq 0 ]; then
    if try_skip ${skip[@]+"${skip[@]}"}; then return 0; fi
    if ! git -C "$CI_DIR" push -q "$CI_REMOTE" "$CI_SHA:refs/heads/$CI_BRANCH" >/dev/null 2>&1; then
      record '{}' "could not push $CI_BRANCH to $CI_REMOTE"
      return 19
    fi
    if ! gh workflow run "$CI_WF" -R "$CI_REPO" --ref "$CI_BRANCH" >/dev/null 2>&1; then
      delete_branch
      record '{}' "could not dispatch $CI_WF on $CI_BRANCH (gh workflow run failed)"
      return 19
    fi
  fi
  allowed="$timeout minutes"
  if [ "$deadline" -gt 0 ]; then allowed="the gate's deadline"; else deadline=$(($(date +%s) + timeout * 60)); fi
  while :; do
    run=$(find_run)
    if [ -n "$run" ] && [ "$(jq -r .status <<<"$run")" = completed ]; then break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      delete_branch
      [ -n "$run" ] || run='{}'
      record "$run" "no conclusion from $CI_WF for $CI_SHA within $allowed"
      return 19
    fi
    sleep "$poll"
  done
  id=$(jq -r .databaseId <<<"$run")
  # The jobs, and the head SHA once more, from the run itself.
  view=$(gh run view "$id" -R "$CI_REPO" --json databaseId,headSha,status,conclusion,url,jobs 2>/dev/null) || view=$run
  jq -e --arg sha "$CI_SHA" '.headSha == $sha' <<<"$view" >/dev/null 2>&1 || view=$run
  delete_branch
  conclusion=$(jq -r '.conclusion // ""' <<<"$view")
  # Only a failed or hung suite is red; any other conclusion means CI never
  # judged the commit, which is not the ticket's fault.
  case "$conclusion" in
    success) record "$view" "" ;;
    failure | timed_out) record "$view" ""; return 7 ;;
    *)
      record "$view" "$CI_WF concluded ${conclusion:-nothing} for $CI_SHA, so CI did not judge it"
      return 19 ;;
  esac
}

cmd_find() {
  local run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; CI_REPO=$2; shift 2 ;;
      --workflow) [ $# -ge 2 ] || usage; CI_WF=$2; shift 2 ;;
      --branch) [ $# -ge 2 ] || usage; CI_BRANCH=$2; shift 2 ;;
      --sha) [ $# -ge 2 ] || usage; CI_SHA=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$CI_REPO" ] && [ -n "$CI_WF" ] && [ -n "$CI_BRANCH" ] && [ -n "$CI_SHA" ] || usage
  run=$(find_run)
  [ -n "$run" ] || return 1
  printf '%s\n' "$run"
}

# -------------------------------------------------------------------- local

cmd_local() {
  local dir="" command="" log="" passed=true rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || usage; dir=$2; shift 2 ;;
      --command) [ $# -ge 2 ] || usage; command=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || usage; log=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$dir" ] && [ -n "$command" ] && [ -n "$log" ] || usage
  (cd "$dir" && sh -c "$command") >"$log" 2>&1 || { passed=false rc=7; }
  jq -nc --arg c "$command" --argjson p "$passed" '{mode: "local", command: $c, passed: $p}'
  return "$rc"
}

# -------------------------------------------------------- start (detached)

START_RESULT="" START_PID_FILE="" START_LOG=""
start_args() { # parses --result --pid-file --log up to --; sets START_SHIFT
  START_SHIFT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --result) [ $# -ge 2 ] || usage; START_RESULT=$2; shift 2; START_SHIFT=$((START_SHIFT + 2)) ;;
      --pid-file) [ $# -ge 2 ] || usage; START_PID_FILE=$2; shift 2; START_SHIFT=$((START_SHIFT + 2)) ;;
      --log) [ $# -ge 2 ] || usage; START_LOG=$2; shift 2; START_SHIFT=$((START_SHIFT + 2)) ;;
      --) START_SHIFT=$((START_SHIFT + 1)); break ;;
      *) usage ;;
    esac
  done
  [ -n "$START_RESULT" ] && [ -n "$START_PID_FILE" ] && [ -n "$START_LOG" ] || usage
}

cmd_start() {
  start_args "$@"
  shift "$START_SHIFT"
  case "${1:-}" in local | ci) ;; *) usage ;; esac
  [ ! -e "$START_RESULT" ] || die "$START_RESULT already holds a gate's outcome"
  rm -f "$START_PID_FILE"
  mkdir -p "$(dirname "$START_RESULT")" "$(dirname "$START_PID_FILE")" "$(dirname "$START_LOG")"
  detach_start "$START_PID_FILE" "$START_LOG" "$0" run --result "$START_RESULT" \
    --pid-file "$START_PID_FILE" --log "$START_LOG" -- "$@" \
    || die "the gate runner did not start; see $START_LOG"
}

# The detached runner: the gate in the foreground, then its outcome, written
# atomically (a dotfile first, which wait-any.sh skips). Stopped by a signal,
# it writes nothing: the gate did not finish.
cmd_run() {
  local out="" rc=0 tmp=""
  start_args "$@"
  shift "$START_SHIFT"
  detach_write_pid "$START_PID_FILE"
  trap 'exit 143' TERM INT HUP
  out=$("$0" "$@") || rc=$?
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || out=null
  tmp="$(dirname "$START_RESULT")/.$(basename "$START_RESULT").tmp"
  jq -nc --argjson c "$rc" --argjson r "$out" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{exit_code: $c, record: $r, finished_at: $at}' >"$tmp"
  mv "$tmp" "$START_RESULT"
}

# -------------------------------------------------------------------- sweep

cmd_sweep() {
  local prefix="" dir="" b=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || usage; prefix=$2; shift 2 ;;
      --dir) [ $# -ge 2 ] || usage; dir=$2; shift 2 ;;
      --remote) [ $# -ge 2 ] || usage; CI_REMOTE=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$prefix" in ci/?*) ;; *) die "--prefix must start ci/ and name more than ci/ itself" ;; esac
  [ -n "$dir" ] || dir=$PWD
  git -C "$dir" remote get-url "$CI_REMOTE" >/dev/null 2>&1 || return 0
  for b in $(git -C "$dir" ls-remote --heads "$CI_REMOTE" "$prefix*" 2>/dev/null | awk '{ sub("^refs/heads/", "", $2); print $2 }'); do
    case "$b" in "$prefix"*) ;; *) continue ;; esac
    if git -C "$dir" push -q "$CI_REMOTE" --delete "$b" >/dev/null 2>&1; then echo "deleted $b"; fi
  done
}

# ------------------------------------------------------------------ minutes

cmd_minutes() {
  local repo="" wf="" limit=10 runs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
      --workflow) [ $# -ge 2 ] || usage; wf=$2; shift 2 ;;
      --limit) [ $# -ge 2 ] || usage; limit=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$wf" ] || usage
  runs=$(gh run list -R "$repo" --workflow "$wf" --limit "$limit" --json status,conclusion,createdAt,updatedAt) \
    || die "could not list the runs of $wf on $repo"
  jq -c '
    def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    [.[] | select(.status == "completed" and .createdAt and .updatedAt)
         | (.updatedAt | secs) - (.createdAt | secs)] as $d
    | {runs: ($d | length),
       minutes: (if ($d | length) == 0 then null else (($d | add) / ($d | length) / 60 * 10 | ceil) / 10 end)}' <<<"$runs"
}

# ----------------------------------------------------------- workflow-check

cmd_workflow_check() {
  local f="${1:-}"
  [ -n "$f" ] || usage
  [ -f "$f" ] || { echo "merge-gate.sh: no gate workflow at $f" >&2; return 1; }
  # A trigger key or a list entry, never a comment.
  if sed 's/#.*//' "$f" | grep -Eq '(^|[^A-Za-z0-9_-])workflow_dispatch([^A-Za-z0-9_-]|$)'; then return 0; fi
  echo "merge-gate.sh: the gate workflow $f has no workflow_dispatch trigger, so the merge gate cannot start it; add workflow_dispatch to its on: triggers" >&2
  return 1
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  mode) [ $# -eq 0 ] || usage; cmd_mode ;;
  show) [ $# -eq 0 ] || usage; cmd_show ;;
  batch) [ $# -eq 0 ] || usage; cmd_batch ;;
  ci) cmd_ci "$@" ;;
  find) cmd_find "$@" ;;
  local) cmd_local "$@" ;;
  start) cmd_start "$@" ;;
  run) cmd_run "$@" ;;
  sweep) cmd_sweep "$@" ;;
  minutes) cmd_minutes "$@" ;;
  workflow-check) [ $# -eq 1 ] || usage; cmd_workflow_check "$1" ;;
  *) usage ;;
esac
