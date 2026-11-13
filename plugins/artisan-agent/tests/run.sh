#!/usr/bin/env bash
# Script test harness for the pipeline's scripts.
#
# Usage: tests/run.sh [-j N] [--shard i/n] [dir]
#
#   -j N         run up to N tests at once, one test per job (default 1).
#                Output order, format, summary and exit status are those of a
#                serial run: each result is printed in list order as soon as it
#                and every test before it have finished.
#   --shard i/n  run only every n-th test, starting at the i-th (1 <= i <= n),
#                of the full ordered list of tests, so n machines can split
#                the suite. A shard that gets no test exits 2 like an empty
#                suite. Combines with -j.
#
# Runs every test_* function in every *.test.sh file directly inside dir
# (default: this script's own directory; subdirectories are not searched).
# Each test runs in its own bash process with `set -euo pipefail`, lib.sh's
# assertions, and a fresh empty working directory that is removed afterwards.
# No ARTISAN_* variable from the caller reaches a test; tests set their own.
# Tests can read:
#   TESTS_DIR    this harness's directory
#   PLUGIN_ROOT  the plugin's root directory
#   TEST_TMPDIR  the test's own scratch directory (also its working directory)
#
# Pass rule: a test passes only if its process exits 0 AND the wrapper
# reached its very last step, which writes a pass marker after the test
# function returns. The marker lives in a private directory outside the
# test's scratch directory, and its path is passed to the wrapper as an
# argument, never exported, so tests cannot write it by accident. This matters
# on bash 3.2, where a test that sets an EXIT trap and then dies (an unbound
# variable, say) exits with the trap's status, usually 0; it never reaches the
# marker, so it is reported FAIL whatever its traps return.
#
# Under -j, a test's output goes to a file and is printed in order; every job
# has its own scratch directory and pass-marker directory (mktemp), and the
# pass rule and ARTISAN_* clearing are the same code as in a serial run (a job
# is this script run again with --run-one). The pool is `xargs -P`, because
# bash 3.2 has no `wait -n`.
#
# Tests run under the same bash that runs this script ($BASH), not whichever
# `bash` is first on PATH, so `/bin/bash tests/run.sh` really tests bash 3.2.
#
# Exit status: 0 when every test passes, 1 when any fails, 2 when no tests
# were found (an empty suite is never reported green).
#
# Portable to bash 3.2 (macOS) and Linux.

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$TESTS_DIR/.." && pwd)
export TESTS_DIR PLUGIN_ROOT

# Tests must not depend on the machine's git identity (CI runners have none):
# give every script a fixed one. Tests that need "no identity" unset these.
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid


# run_one: one test, in its own process, scratch directory and marker directory.
# Called as `run.sh --run-one <resdir> <file> <name> <idx>` (by xargs). Writes
# <resdir>/<idx>.out, then <idx>.status (0 pass, 1 fail) last, atomically, so
# the printer never reads a half-written result. Always exits 0.
run_one() {
  local resdir=$1 file=$2 name=$3 idx=$4
  local tmp= markdir= marker= output= status= pid=
  tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/artisan-test.XXXXXX")" && pwd -P)
  markdir=$(mktemp -d "${TMPDIR:-/tmp}/artisan-pass.XXXXXX")
  marker="$markdir/passed"
  output=$(cd "$tmp" && TEST_TMPDIR="$tmp" "$BASH" -c '
    set -euo pipefail
    # Clear every ARTISAN_* variable the caller has, by prefix, so a suite
    # run inside a real worker never reaches that worker'"'"'s run (#121).
    for v in $(compgen -v ARTISAN_); do unset "$v"; done
    source "$TESTS_DIR/lib.sh"
    source "$1"
    "$2"
    : > "$3"
  ' _ "$file" "$name" "$marker" 2>&1)
  status=$?
  if [ "$status" -eq 0 ] && [ ! -e "$marker" ]; then
    status=1
    output="${output:+$output
}run.sh: test exited 0 but never reached its end (no pass marker)"
  fi
  # No process a test started outlives it (#137): end whatever still names the
  # test's own folder, and its process group, before the folder goes. Not by a
  # recorded pid: pids wrap (see kill_test_processes in lib.sh).
  for pid in $(pgrep -f "$tmp" 2>/dev/null); do
    [ "$pid" != "$$" ] || continue
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp" "$tmp.usage.json" "$tmp.claude" "$markdir"   # lib.sh's usage reading and config folder sit beside the test's folder
  printf '%s\n' "$output" >"$resdir/$idx.out"
  [ "$status" -eq 0 ] || status=1
  echo "$status" >"$resdir/$idx.status.tmp"
  mv "$resdir/$idx.status.tmp" "$resdir/$idx.status"
  exit 0
}

if [ "${1:-}" = "--run-one" ]; then
  shift
  run_one "$@"
fi

usage() {
  echo "usage: run.sh [-j N] [--shard i/n] [dir]" >&2
  exit 2
}

jobs=1
shard_i=1
shard_n=1
suite_dir=
while [ $# -gt 0 ]; do
  case "$1" in
    -j) [ $# -ge 2 ] || usage; jobs=$2; shift 2 ;;
    -j*) jobs=${1#-j}; shift ;;
    --shard) [ $# -ge 2 ] || usage; shard=$2; shift 2 ;;
    --shard=*) shard=${1#--shard=}; shift ;;
    -*) echo "run.sh: unknown option: $1" >&2; usage ;;
    *) [ -z "$suite_dir" ] || usage; suite_dir=$1; shift ;;
  esac
  if [ -n "${shard:-}" ]; then
    case "$shard" in
      [0-9]*/[0-9]*) shard_i=${shard%/*}; shard_n=${shard#*/} ;;
      *) echo "run.sh: --shard wants i/n, got: $shard" >&2; usage ;;
    esac
    case "$shard_i$shard_n" in *[!0-9]*) echo "run.sh: --shard wants i/n, got: $shard" >&2; usage ;; esac
    if [ "$shard_i" -lt 1 ] || [ "$shard_i" -gt "$shard_n" ]; then
      echo "run.sh: --shard i/n needs 1 <= i <= n, got: $shard" >&2
      usage
    fi
    shard=
  fi
done
case "$jobs" in
  ''|*[!0-9]*) echo "run.sh: -j wants a positive number, got: $jobs" >&2; usage ;;
esac
[ "$jobs" -ge 1 ] || { echo "run.sh: -j wants a positive number, got: $jobs" >&2; usage; }

suite_dir=${suite_dir:-$TESTS_DIR}
if [ ! -d "$suite_dir" ]; then
  echo "run.sh: no such directory: $suite_dir" >&2
  exit 2
fi
suite_dir=$(cd "$suite_dir" && pwd)

resdir=$(mktemp -d "${TMPDIR:-/tmp}/artisan-results.XXXXXX")
xpid=
cleanup() {
  [ -n "$xpid" ] && kill "$xpid" 2>/dev/null
  rm -rf "$resdir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The full ordered list: entry k is the k-th test (or the k-th file with no
# test), across files in name order. The shard picks from this list.
k=0          # position in the full list
n_run=0      # entries this shard runs; their ids are 1..n_run
: >"$resdir/jobs"
for file in "$suite_dir"/*.test.sh; do
  [ -f "$file" ] || continue
  names=$("$BASH" -c 'source "$1" >/dev/null 2>&1; declare -F' _ "$file" | awk '$3 ~ /^test_/ {print $3}')
  [ -n "$names" ] || names=-
  for name in $names; do
    k=$((k + 1))
    [ $(((k - 1) % shard_n)) -eq $((shard_i - 1)) ] || continue
    n_run=$((n_run + 1))
    if [ "$name" = - ]; then
      printf 'FAIL %s: no test_ functions found\n' "$(basename "$file")" >"$resdir/$n_run.head"
      : >"$resdir/$n_run.out"
      echo 1 >"$resdir/$n_run.status"
    else
      echo "$(basename "$file" .test.sh): $name" >"$resdir/$n_run.label"
      printf '%s\0%s\0%s\0' "$file" "$name" "$n_run" >>"$resdir/jobs"
    fi
  done
done

if [ -s "$resdir/jobs" ]; then
  xargs -0 -n 3 -P "$jobs" "$BASH" "$0" --run-one "$resdir" <"$resdir/jobs" &
  xpid=$!
fi

passed=0
failed=0
i=0
while [ "$i" -lt "$n_run" ]; do
  i=$((i + 1))
  while [ ! -e "$resdir/$i.status" ]; do
    if [ -n "$xpid" ] && ! kill -0 "$xpid" 2>/dev/null && [ ! -e "$resdir/$i.status" ]; then
      echo 1 >"$resdir/$i.status"
      echo "run.sh: the job never reported back" >"$resdir/$i.out"
    else
      sleep 0.05
    fi
  done
  if [ -e "$resdir/$i.head" ]; then
    cat "$resdir/$i.head"
    failed=$((failed + 1))
    continue
  fi
  label=$(cat "$resdir/$i.label")
  if [ "$(cat "$resdir/$i.status")" = 0 ]; then
    echo "ok   $label"
    passed=$((passed + 1))
  else
    echo "FAIL $label"
    output=$(cat "$resdir/$i.out")
    [ -n "$output" ] && printf '%s\n' "$output" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done
[ -z "$xpid" ] || wait "$xpid" 2>/dev/null
xpid=

total=$((passed + failed))
echo
echo "$passed passed, $failed failed"
if [ "$total" -eq 0 ]; then
  echo "run.sh: no tests found in $suite_dir" >&2
  exit 2
fi
[ "$failed" -eq 0 ]
