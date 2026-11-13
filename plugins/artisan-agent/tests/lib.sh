# Assertions for script tests. Sourced by run.sh into each test's process.
# Portable to bash 3.2 (macOS) and GNU userland (Linux).

fail() {
  printf '  %s\n' "$*" >&2
  exit 1
}

assert_eq() { # expected actual [message]
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$1], got [$2]"
}

assert_contains() { # haystack needle [message]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-assert_contains}: [$2] not found in [$1]" ;;
  esac
}

assert_status() { # expected-status command...
  local want="$1" got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  [ "$want" = "$got" ] || fail "assert_status: expected exit $want from [$*], got $got"
}

# kill_test_processes: SIGKILL every live process whose command line names
# this test's own directory, and the process group each one leads (a runner's
# session, a worker's group). Never by a pid recorded earlier: a long suite
# wraps pids within a minute, so a dead runner's pid may by now be another
# process's, another suite's verifier, say, which a kill by number would end
# without an exit record (the "verified twice" flake, #106).
kill_test_processes() {
  local pid=
  for pid in $(pgrep -f "$TEST_TMPDIR" 2>/dev/null); do
    [ "$pid" != "$$" ] || continue
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
}

# A fresh plan-usage reading well under the limits, so the usage guard
# (budget.sh, #72) lets every test's dispatch through; tests of the guard
# write their own. Never the machine's own reading. Beside the test's folder,
# not in it (tests check what lands there); run.sh removes it.
export ARTISAN_USAGE_FILE="$TEST_TMPDIR.usage.json"
jq -nc --argjson t "$(date +%s)" '{schema_version: 1, written_at: $t,
  rate_limits: {at: $t, five_hour: {used_percentage: 10, resets_at: ($t + 3600)},
                seven_day: {used_percentage: 20, resets_at: ($t + 86400)}}}' >"$ARTISAN_USAGE_FILE"
