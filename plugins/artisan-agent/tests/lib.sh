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

# No pipe: `! printf ... | grep -q` passes on a match when printf takes SIGPIPE
# under pipefail, so never assert absence that way.
assert_not_contains() { # haystack needle [message]
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: [$2] unexpectedly found in [$1]" ;;
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

# The merge gate runs locally in every test (merge-gate.sh), whatever the
# machine: auto would mean CI on Linux. Said the way a machine says it, in a
# host.json, here in the test's own config folder, so no ARTISAN_* variable
# reaches a test (run.sh) and never the machine's own host.json. Beside the
# test's folder, not in it; run.sh removes it. A test that places its own
# config folder or individual home calls merge_gate_local on it; tests of the
# CI gate write ci there, or set ARTISAN_MERGE_GATE themselves.
merge_gate_local() { # individual-home-dir: its host.json gets merge_gate local
  local f="$1/host.json" j='{}'
  mkdir -p "$1"
  [ ! -f "$f" ] || j=$(cat "$f")
  printf '%s' "$j" | jq '.merge_gate = "local"' >"$f.tmp" && mv "$f.tmp" "$f"
}
export CLAUDE_CONFIG_DIR="$TEST_TMPDIR.claude"
merge_gate_local "$CLAUDE_CONFIG_DIR/artisan-agent"
