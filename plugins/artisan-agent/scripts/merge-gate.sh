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
#                    [--skip-path PATTERN]... [--base SHA]
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
#       A red record (exit 7) also holds failing_tests: what failed-tests
#       read from the run's failed jobs (#176).
#       --base (#195) is the integration tip before the merge (a merge
#       batch's base). With it, a red run is checked before it counts: the
#       failed jobs are rerun on the merge commit (gh run rerun --failed)
#       while FILE runs on the base (pushed to B-base), both within a fresh
#       M minutes (the --deadline's span). The record gains base_check:
#       {verdict, rerun: {attempt, conclusion}, base: {sha, branch, run_id,
#       url, conclusion, failing_tests}}, and the verdict decides:
#         flaky      the rerun passed: exit 0, conclusion success (the first
#                    try's failing_tests kept, to name in a finding)
#         base-red   the base failed too, and every test the merge commit
#                    failed (or none could be named) failed there: exit 7
#         new        some failures are new against the base: exit 7, with
#                    failing_tests only the new ones when the base was red
#         unchecked  neither gave a verdict in time: exit 7, as before
#       Both branches are deleted after (a base run still going when the
#       rerun passed is left to finish). With --resume, a run already at a
#       later attempt was cut off mid check: that attempt is the rerun, so
#       nothing is rerun again (and a green one is flaky).
#   merge-gate.sh failed-tests --repo O/N --run-id ID [--max N]
#       the tests a red run failed, read from its failed jobs' log (gh run
#       view --log-failed), as JSON: {tests: [{job, name, where, message}],
#       total, truncated} with at most N tests (default 20). where is
#       file:line, or null where the log gives none; message is the first
#       assertion or error line. Reads Playwright's failure headers, the
#       FAIL lines of this plugin's tests/run.sh (never its FLAKY or
#       QUARANTINED ones), pytest's FAILED lines, Go's
#       --- FAIL and TAP's not ok. With no test it can name, excerpt holds
#       the log's last error lines instead; with no log to read, tests is
#       empty and why says so. Never fails a gate: exit 0 whether or not
#       it names a test (2 on bad arguments). A log not served yet is asked
#       for again, three times in all, ARTISAN_CI_POLL_SECONDS apart.
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

delete_branch() { # [branch], default the gate's
  local b="${1:-$CI_BRANCH}"
  git -C "$CI_DIR" push -q "$CI_REMOTE" --delete "$b" >/dev/null 2>&1 \
    || echo "merge-gate.sh: could not delete $b on $CI_REMOTE; the next gate's sweep will" >&2
}

# The dispatched run for exactly this commit: the newest workflow_dispatch run
# on the branch whose head SHA is ours. Empty while none is listed yet.
find_run() { find_run_on "$CI_BRANCH" "$CI_SHA"; }
find_run_on() { # branch sha
  gh run list -R "$CI_REPO" --workflow "$CI_WF" --branch "$1" --event workflow_dispatch \
    --limit 20 --json databaseId,headSha,status,conclusion,url 2>/dev/null \
    | jq -c --arg sha "$2" '[.[] | select(.headSha == $sha)] | first // empty' 2>/dev/null || true
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

CI_BASE=
cmd_ci() {
  local timeout=30 run="" id="" view="" deadline=0 poll=${ARTISAN_CI_POLL_SECONDS:-20} conclusion="" resume=0 allowed=""
  local window=0 red="" attempt=""
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
      --base) [ $# -ge 2 ] || usage; CI_BASE=$2; shift 2 ;;
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
  # The base check's own span: as long as the gate itself was given.
  window=$((deadline - $(date +%s)))
  [ "$window" -ge 60 ] || window=60
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
  view=$(gh run view "$id" -R "$CI_REPO" --json databaseId,attempt,headSha,status,conclusion,url,jobs 2>/dev/null) || view=$run
  jq -e --arg sha "$CI_SHA" '.headSha == $sha' <<<"$view" >/dev/null 2>&1 || view=$run
  conclusion=$(jq -r '.conclusion // ""' <<<"$view")
  # Only a failed or hung suite is red; any other conclusion means CI never
  # judged the commit, which is not the ticket's fault.
  # A resumed gate whose run has a later attempt was cut off mid base check:
  # that attempt is the rerun, so it is not rerun again.
  attempt=$(jq -r '.attempt // 1' <<<"$view")
  case "$attempt" in '' | *[!0-9]*) attempt=1 ;; esac
  [ "$resume" -eq 1 ] && [ "$attempt" -gt 1 ] && [ -n "$CI_BASE" ] || attempt=""
  case "$conclusion" in
    success)
      if [ -z "$attempt" ]; then delete_branch; record "$view" ""; return 0; fi
      red=$(record "$view" "" | jq -c --argjson f "$(failed_tests "$id" 20)" '. + {failing_tests: $f}')
      base_check "$id" "$red" "$window" "$attempt" success ;;
    failure | timed_out)
      red=$(record "$view" "" | jq -c --argjson f "$(failed_tests "$id" 20)" '. + {failing_tests: $f}')
      if [ -z "$CI_BASE" ]; then
        delete_branch
        printf '%s\n' "$red"
        return 7
      fi
      if [ -n "$attempt" ]; then base_check "$id" "$red" "$window" "$attempt" "$conclusion"
      else base_check "$id" "$red" "$window"; fi ;;
    *)
      delete_branch
      record "$view" "$CI_WF concluded ${conclusion:-nothing} for $CI_SHA, so CI did not judge it"
      return 19 ;;
  esac
}

# base_check run-id red-record window [rerun-attempt rerun-conclusion]: a
# red run, checked before it counts (#195). At once: its failed jobs rerun
# on the merge commit, and the gate workflow on the base. Waits up to
# `window` seconds (a green rerun decides at once; a base run still going
# then is left to finish), deletes both branches, and prints the record
# with base_check (above). Returns 0 flaky, 7 otherwise. A resumed gate
# passes the rerun it already has: no second rerun, and no base run when it
# passed.
base_check() {
  local id="$1" red="$2" window="$3" att0="" end=0 rr="" brun="" btests='null' bbranch="$CI_BRANCH-base"
  local rdone=0 bdone=0 rconc="" bconc="" verdict="" out="" poll=${ARTISAN_CI_POLL_SECONDS:-20}
  # done: 0 waiting, 1 nothing to wait on (it never started), 2 concluded.
  if [ -n "${4:-}" ]; then
    att0=$(($4 - 1)) rdone=2 rconc=$5
    [ "$rconc" != success ] || bdone=1
  else
    att0=$(gh run view "$id" -R "$CI_REPO" --json attempt -q '.attempt // 1' 2>/dev/null) || att0=1
    case "$att0" in '' | *[!0-9]*) att0=1 ;; esac
    gh run rerun "$id" -R "$CI_REPO" --failed >/dev/null 2>&1 || rdone=1
  fi
  if [ "$bdone" -ne 0 ]; then :
  elif ! git -C "$CI_DIR" push -q "$CI_REMOTE" "$CI_BASE:refs/heads/$bbranch" >/dev/null 2>&1; then bdone=1
  elif ! gh workflow run "$CI_WF" -R "$CI_REPO" --ref "$bbranch" >/dev/null 2>&1; then bdone=1
  fi
  end=$(($(date +%s) + window))
  while :; do
    if [ "$rdone" -eq 0 ]; then
      rr=$(gh run view "$id" -R "$CI_REPO" --json databaseId,attempt,status,conclusion,url,jobs 2>/dev/null) || rr=""
      if [ -n "$rr" ] && jq -e --argjson a "$att0" '(.attempt // 0) > $a and .status == "completed"' <<<"$rr" >/dev/null 2>&1; then
        rdone=2 rconc=$(jq -r '.conclusion // ""' <<<"$rr")
      fi
    fi
    if [ "$bdone" -eq 0 ]; then
      brun=$(find_run_on "$bbranch" "$CI_BASE")
      if [ -n "$brun" ] && [ "$(jq -r .status <<<"$brun")" = completed ]; then
        bdone=2 bconc=$(jq -r '.conclusion // ""' <<<"$brun")
      fi
    fi
    [ "$rconc" != success ] || break
    if [ "$rdone" -ne 0 ] && [ "$bdone" -ne 0 ]; then break; fi
    [ "$(date +%s)" -lt "$end" ] || break
    sleep "$poll"
  done
  delete_branch
  delete_branch "$bbranch"
  [ -n "$brun" ] || brun='{}'
  case "$bconc" in
    failure | timed_out) btests=$(failed_tests "$(jq -r .databaseId <<<"$brun")" 50) ;;
  esac
  # The same test: the same job and name (its line may move with the change).
  out=$(jq -c --arg rc "$rconc" --arg bc "$bconc" --argjson ra "$((att0 + 1))" --argjson rr "${rr:-null}" \
      --argjson b "$brun" --argjson bt "$btests" --arg bsha "$CI_BASE" --arg bb "$bbranch" '
    (.failing_tests.tests // []) as $mine | ($bt.tests // []) as $theirs
    | ($bc == "failure" or $bc == "timed_out") as $bred
    | [$mine[] | . as $x | select(any($theirs[]; .job == $x.job and .name == $x.name) | not)] as $new
    | (if $rc == "success" then "flaky"
       elif $bred and ($new == [] or $theirs == []) then "base-red"
       elif $bred or $bc == "success" then "new"
       else "unchecked" end) as $v
    | . + {base_check: {verdict: $v,
            rerun: {attempt: (if $rc == "" then null else $ra end), conclusion: (if $rc == "" then null else $rc end)},
            base: {sha: $bsha, branch: $bb, run_id: ($b.databaseId // null), url: ($b.url // null),
                   conclusion: (if $bc == "" then null else $bc end), failing_tests: $bt}}}
    | if $v == "flaky" then .conclusion = "success" | .jobs = (if $rr == null then .jobs else [($rr.jobs // [])[] | {name, conclusion}] end)
      elif $v == "new" and $bred and $theirs != [] then
        .failing_tests = {tests: $new, total: ($new | length), truncated: false, also_on_base: (($mine | length) - ($new | length))}
      else . end' <<<"$red")
  printf '%s\n' "$out"
  verdict=$(jq -r .base_check.verdict <<<"$out")
  [ "$verdict" = flaky ] || return 7
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

# ------------------------------------------------------------ failed tests

# The parser for gh run view --log-failed: each line "<job>\t<step>\t<ts>
# <text>". Prints one "<job>\t<where>\t<name>\t<message>" line per failing
# test, in the log's order, each once; where and message may be empty.
FAILED_TESTS_AWK='
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
function cut(x, n) { return length(x) > n ? substr(x, 1, n - 3) "..." : x }
function add(w, nm,   k) {
  k = job SUBSEP w SUBSEP nm
  if (k in seen) { cur = 0; return }
  seen[k] = 1; n++; J[n] = job; W[n] = w; N[n] = nm; M[n] = ""; cur = n; kind = ""
}
function noline(w) { sub(/:[0-9]+$/, "", w); return w }
{
  line = $0; job = ""
  if ((i = index(line, "\t")) > 0) {
    job = substr(line, 1, i - 1); line = substr(line, i + 1)
    if ((i = index(line, "\t")) > 0) line = substr(line, i + 1)
  }
  sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "", line)
  t = trim(line)
  if (cur && J[cur] != job) cur = 0
  # Playwright: "  1) [project] › file:line:col › title ───"
  if (t ~ /^[0-9]+\) /) {
    r = substr(t, index(t, ") ") + 2)
    if (substr(r, 1, 1) == "[" && (i = index(r, "] ")) > 0) r = substr(r, i + 2)
    if (index(r, "› ") == 1) r = substr(r, length("› ") + 1)
    if ((i = index(r, " › ")) > 0) {
      w = substr(r, 1, i - 1); nm = substr(r, i + length(" › "))
      if (w ~ /:[0-9]+:[0-9]+$/) w = noline(w)
      if (w ~ /:[0-9]+$/) {
        while (match(nm, /(─| )$/)) nm = substr(nm, 1, RSTART - 1)
        add(w, trim(nm)); kind = "pw"; next
      }
    }
  }
  # This plugin'"'"'s tests/run.sh: "FAIL <file>: <test>", its output indented below.
  if (t ~ /^FAIL [^ ]/ && line ~ /^FAIL /) { add("", substr(t, 6)); kind = "first"; next }
  # Its FLAKY and QUARANTINED lines (#198) never fail a run: nor does their output.
  if (line ~ /^(FLAKY|QUARANTINED) [^ ]/) { cur = 0; next }
  # pytest: "FAILED path::test - message"
  if (t ~ /^FAILED [^ ]+::/) {
    r = substr(t, 8); w = r; nm = r; m = ""
    if ((i = index(r, " - ")) > 0) { m = substr(r, i + 3); w = substr(r, 1, i - 1) }
    nm = w; sub(/::.*/, "", w); sub(/^[^:]*::/, "", nm)
    add(w, nm); if (cur) M[cur] = m; cur = 0; next
  }
  # Go: "--- FAIL: TestName (0.00s)", then "    file.go:12: message"
  if (t ~ /^--- FAIL: /) { nm = substr(t, 11); sub(/ \(.*$/, "", nm); add("", nm); kind = "go"; next }
  # TAP: "not ok 3 - name"
  if (t ~ /^not ok [0-9]+/) { nm = t; sub(/^not ok [0-9]+( - )?/, "", nm); add("", nm); kind = "first"; next }
  if (!cur || M[cur] != "" || t == "") next
  if (kind == "pw" && t ~ /^[A-Za-z]*Error[:]/) M[cur] = t
  else if (kind == "first" && line ~ /^[ \t]/ && t != "---") M[cur] = t
  else if (kind == "go" && t ~ /^[^ ]+\.go:[0-9]+: /) {
    i = index(t, ": "); W[cur] = substr(t, 1, i - 1); M[cur] = substr(t, i + 2)
  }
}
END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\n", J[i], W[i], cut(N[i], 200), cut(M[i], 300) }'

# failed_tests run-id max: the failing tests of a red run, as JSON (above).
failed_tests() {
  local id="$1" max="$2" log="" esc="" parsed="" excerpt='[]' try=0
  esc=$(printf '\033')
  # GitHub can be slow to serve a run's log just after it concludes.
  while [ "$try" -lt 3 ]; do
    try=$((try + 1))
    log=$(gh run view "$id" -R "$CI_REPO" --log-failed 2>/dev/null) || log=""
    [ -z "$log" ] || break
    [ "$try" -ge 3 ] || sleep "${ARTISAN_CI_POLL_SECONDS:-20}"
  done
  if [ -z "$log" ]; then
    jq -nc --arg id "$id" '{tests: [], total: 0, truncated: false, why: "could not read the failed jobs'"'"' log of run \($id) (gh run view --log-failed)"}'
    return 0
  fi
  # In the C locale: a log cut mid-character never stops BSD sed or awk.
  log=$(printf '%s\n' "$log" | LC_ALL=C sed "s/${esc}\[[0-9;]*[A-Za-z]//g")
  parsed=$(printf '%s\n' "$log" | LC_ALL=C awk "$FAILED_TESTS_AWK")
  if [ -z "$parsed" ]; then
    excerpt=$(printf '%s\n' "$log" | LC_ALL=C awk -F '\t' '{
        l = $0; j = ""
        if (NF >= 3) { j = $1; l = $3; for (i = 4; i <= NF; i++) l = l " " $i }
        sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "", l)
        if (l ~ /[Ee][Rr][Rr][Oo][Rr]|[Ff][Aa][Ii][Ll]|[Aa]ssert/) print (j == "" ? "" : j ": ") substr(l, 1, 300)
      }' | tail -n 15 | jq -Rsc 'split("\n") | map(select(. != ""))')
  fi
  jq -Rsc --argjson max "$max" --argjson ex "$excerpt" '
    [split("\n")[] | select(. != "") | split("\t")
     | {job: .[0], name: .[2], where: (if .[1] == "" then null else .[1] end),
        message: (if (.[3] // "") == "" then null else .[3] end)}] as $all
    | {tests: $all[:$max], total: ($all | length), truncated: (($all | length) > $max)}
      + (if $all == [] then {excerpt: $ex} else {} end)' <<<"$parsed"
}

cmd_failed_tests() {
  local id="" max=20
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; CI_REPO=$2; shift 2 ;;
      --run-id) [ $# -ge 2 ] || usage; id=$2; shift 2 ;;
      --max) [ $# -ge 2 ] || usage; max=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$CI_REPO" ] && [ -n "$id" ] || usage
  case "$max" in '' | *[!0-9]*) die "--max must be a whole number" ;; esac
  failed_tests "$id" "$max"
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
  failed-tests) cmd_failed_tests "$@" ;;
  local) cmd_local "$@" ;;
  start) cmd_start "$@" ;;
  run) cmd_run "$@" ;;
  sweep) cmd_sweep "$@" ;;
  minutes) cmd_minutes "$@" ;;
  workflow-check) [ $# -eq 1 ] || usage; cmd_workflow_check "$1" ;;
  *) usage ;;
esac
