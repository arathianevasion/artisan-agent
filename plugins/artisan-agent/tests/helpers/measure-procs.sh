#!/usr/bin/env bash
# Measure what single tests cost: the processes they start (in total, and how
# many of them are jq) and their wall time. Written for #185, to compare the
# slowest tests before and after a change, measured the same way both times.
#
# Usage: tests/helpers/measure-procs.sh <file>:<test> ...
#   <file> is a test file's name without .test.sh (as on run.sh's lines),
#   looked up in this suite's directory; <test> is one test_* function.
#
# Prints one tab-separated line per test, then a total line:
#   <processes>\t<jq>\t<seconds>\t<file>: <test>
#
# Each test runs twice, alone, the way tests/run.sh runs it (its own bash with
# set -euo pipefail, lib.sh, a fresh scratch directory, no ARTISAN_* variable,
# a fixed git identity): once under `strace -ff -e trace=execve` to count every
# successful exec (one log per process), and once plain for the wall time, so
# strace's overhead never reaches the seconds. A test that fails is reported on stderr and the helper
# exits 1. Needs strace, so Linux only; never run by the suite (not *.test.sh).

set -uo pipefail

HELPERS_DIR=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HELPERS_DIR/.." && pwd)
PLUGIN_ROOT=$(cd "$TESTS_DIR/.." && pwd)
export TESTS_DIR PLUGIN_ROOT
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid

command -v strace >/dev/null 2>&1 || { echo "measure-procs.sh: needs strace" >&2; exit 2; }
[ $# -gt 0 ] || { echo "usage: measure-procs.sh <file>:<test> ..." >&2; exit 2; }

now() { echo "${EPOCHREALTIME:-$(date +%s)}"; }

# run_test file name [strace log]: one test, as run.sh's run_one runs it.
run_test() {
  local file=$1 name=$2 log=${3:-} tmp="" status=0
  tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/artisan-test.XXXXXX")" && pwd -P)
  local -a pre=()
  [ -z "$log" ] || pre=(strace -ff -qq -e trace=execve -e signal=none -o "$log/p")
  (cd "$tmp" && TEST_TMPDIR="$tmp" ${pre[@]+"${pre[@]}"} "$BASH" -c '
    set -euo pipefail
    for v in $(compgen -v ARTISAN_); do unset "$v"; done
    # Nor the Claude session the caller runs in (#283).
    unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
    unset TESTS_TIMES GITHUB_STEP_SUMMARY
    source "$TESTS_DIR/lib.sh"
    source "$1"
    "$2"
  ' _ "$file" "$name") >"$tmp.out" 2>&1 || status=$?
  for pid in $(pgrep -f "$tmp" 2>/dev/null); do
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
  [ "$status" -eq 0 ] || { echo "measure-procs.sh: $name failed:" >&2; cat "$tmp.out" >&2; }
  rm -rf "$tmp" "$tmp.out" "$tmp.usage.json" "$tmp.claude"
  return "$status"
}

log=$(mktemp -d "${TMPDIR:-/tmp}/measure-procs.XXXXXX")
trap 'rm -rf "$log"' EXIT
tp=0 tj=0 ts=0 rc=0
for spec in "$@"; do
  f=${spec%%:*} name=${spec#*:}
  file="$TESTS_DIR/$f.test.sh"
  [ -f "$file" ] || { echo "measure-procs.sh: no such test file: $file" >&2; exit 2; }
  rm -f "$log"/p.*
  run_test "$file" "$name" "$log" || rc=1
  # -ff writes one file per process, so no exec line is split by another's.
  procs=$(cat "$log"/p.* | grep -c '^execve(.* = 0$')
  jqs=$(cat "$log"/p.* | grep -cE '^execve\("[^"]*/jq",.* = 0$')
  a=$(now)
  run_test "$file" "$name" || rc=1
  secs=$(awk -v a="$a" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }')
  printf '%s\t%s\t%s\t%s: %s\n' "$procs" "$jqs" "$secs" "$f" "$name"
  tp=$((tp + procs)) tj=$((tj + jqs))
  ts=$(awk -v a="$ts" -v b="$secs" 'BEGIN { printf "%.2f", a + b }')
done
printf '%s\t%s\t%s\t%s\n' "$tp" "$tj" "$ts" "total"
exit "$rc"
