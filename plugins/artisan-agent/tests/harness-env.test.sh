# run.sh must not leak the caller's ARTISAN_* variables into tests (#121).

test_artisan_variables_are_cleared_by_prefix() {
  mkdir suite
  cat > suite/probe.test.sh <<'EOF'
test_probe() {
  # Fake worker: writes where a real run's variables point, if it sees them.
  [ -z "${ARTISAN_FINDINGS_FILE:-}" ] || echo '{"title":"fake"}' >> "$ARTISAN_FINDINGS_FILE"
  [ -z "${ARTISAN_RESULT_FILE:-}" ] || echo fake > "$ARTISAN_RESULT_FILE"
  [ -z "${ARTISAN_RUN_DIR:-}" ] || touch "$ARTISAN_RUN_DIR/leak"
  # lib.sh sets its own (TEST_LIB_ARTISAN_VARS: the usage file, #72, and the
  # poll intervals, #169); anything else, or any other value, is a caller leak.
  left=$(artisan_vars_from_caller)
  [ -z "$left" ] || { echo "leaked: $left" >&2; exit 1; }
}
EOF
  mkdir rundir
  echo before > findings; echo before > result
  ARTISAN_FINDINGS_FILE=$PWD/findings ARTISAN_RESULT_FILE=$PWD/result \
    ARTISAN_RUN_DIR=$PWD/rundir ARTISAN_ADDED_LATER_X=1 ARTISAN_RUNNER_POLL_SECONDS=7 \
    bash "$TESTS_DIR/run.sh" suite > out 2>&1 || fail "probe suite failed (variable leaked): $(cat out)"
  assert_contains "$(cat out)" "1 passed, 0 failed" "probe did not run"
  assert_eq before "$(cat findings)" "findings file touched"
  assert_eq before "$(cat result)" "result file touched"
  [ ! -e rundir/leak ] || fail "run dir touched"
}

# The Claude session's id must not reach a test either (#283): a suite run by
# an orchestrator inside a Claude session would otherwise see its session.
write_session_probe() { # dir
  mkdir -p "$1"
  cat > "$1/probe.test.sh" <<'EOF2'
test_probe() {
  [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || { echo "leaked CLAUDE_CODE_SESSION_ID=$CLAUDE_CODE_SESSION_ID" >&2; exit 1; }
  [ -z "${CLAUDE_SESSION_ID:-}" ] || { echo "leaked CLAUDE_SESSION_ID=$CLAUDE_SESSION_ID" >&2; exit 1; }
}
EOF2
}

test_the_claude_session_ids_are_cleared_from_each_test() {
  write_session_probe suite
  CLAUDE_CODE_SESSION_ID=sess-a CLAUDE_SESSION_ID=sess-b \
    bash "$TESTS_DIR/run.sh" suite > out 2>&1 || fail "a session id reached the test: $(cat out)"
  assert_contains "$(cat out)" "1 passed, 0 failed" "probe did not run"
}

test_the_measuring_helper_clears_the_claude_session_ids_too() {
  mkdir -p fake/helpers bin
  cp "$TESTS_DIR/helpers/measure-procs.sh" fake/helpers/
  cp "$TESTS_DIR/lib.sh" fake/
  write_session_probe fake
  # A stand-in strace: drops its options (the last is -o <file>), runs the command.
  printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done\nshift 2\nexec "$@"\n' >bin/strace
  chmod +x bin/strace
  PATH="$PWD/bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-a CLAUDE_SESSION_ID=sess-b \
    bash fake/helpers/measure-procs.sh probe:test_probe >out 2>&1 || fail "a session id reached the measured test: $(cat out)"
}

test_a_test_started_outside_its_own_folder_stops_before_it_writes_anything() {
  local status=0
  mkdir elsewhere
  (cd elsewhere && TEST_TMPDIR="$TEST_TMPDIR" bash -c 'source "$1"; touch stray' _ "$TESTS_DIR/lib.sh") >out 2>&1 || status=$?
  assert_eq 1 "$status" "lib.sh let a test run outside TEST_TMPDIR"
  assert_contains "$(cat out)" "tests/run.sh"
  [ ! -e elsewhere/stray ] || fail "the test wrote into the folder it was started from"
}
