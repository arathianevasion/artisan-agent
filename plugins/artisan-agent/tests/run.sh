#!/usr/bin/env bash
# Script test harness for the pipeline's scripts.
#
# Usage: tests/run.sh [dir]
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

suite_dir=${1:-$TESTS_DIR}
if [ ! -d "$suite_dir" ]; then
  echo "run.sh: no such directory: $suite_dir" >&2
  exit 2
fi
suite_dir=$(cd "$suite_dir" && pwd)

passed=0
failed=0

for file in "$suite_dir"/*.test.sh; do
  [ -f "$file" ] || continue
  names=$("$BASH" -c 'source "$1" >/dev/null 2>&1; declare -F' _ "$file" | awk '$3 ~ /^test_/ {print $3}')
  if [ -z "$names" ]; then
    echo "FAIL $(basename "$file"): no test_ functions found"
    failed=$((failed + 1))
    continue
  fi
  for name in $names; do
    label="$(basename "$file" .test.sh): $name"
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
    rm -rf "$tmp" "$tmp.usage.json" "$markdir"   # lib.sh's usage reading sits beside the test's folder
    if [ "$status" -eq 0 ]; then
      echo "ok   $label"
      passed=$((passed + 1))
    else
      echo "FAIL $label"
      [ -n "$output" ] && printf '%s\n' "$output" | sed 's/^/     /'
      failed=$((failed + 1))
    fi
  done
done

total=$((passed + failed))
echo
echo "$passed passed, $failed failed"
if [ "$total" -eq 0 ]; then
  echo "run.sh: no tests found in $suite_dir" >&2
  exit 2
fi
[ "$failed" -eq 0 ]
