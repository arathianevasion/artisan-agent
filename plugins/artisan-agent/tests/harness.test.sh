# Tests for the harness itself, run through its command line.

FIXTURES="$TESTS_DIR/fixtures/harness"

test_a_passing_suite_exits_zero_and_counts_passes() {
  local out= status=0
  out=$("$TESTS_DIR/run.sh" "$FIXTURES/passing" 2>&1) || status=$?
  assert_eq 0 "$status" "exit status"
  assert_contains "$out" "1 passed, 0 failed"
}

test_a_failing_test_fails_the_suite_and_is_named_with_its_message() {
  local out= status=0
  out=$("$TESTS_DIR/run.sh" "$FIXTURES/failing" 2>&1) || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$out" "FAIL sample: test_fails_an_assertion"
  assert_contains "$out" "the fixture's assertion: expected [expected], got [actual]"
  assert_contains "$out" "1 passed, 2 failed"
}

test_a_failed_command_inside_a_test_fails_it() {
  local out=
  out=$("$TESTS_DIR/run.sh" "$FIXTURES/failing" 2>&1) || true
  assert_contains "$out" "FAIL sample: test_stops_at_first_failed_command"
  case "$out" in
    *"should not be reached"*) fail "test kept running after a failed command" ;;
  esac
}

test_an_empty_suite_is_never_green() {
  assert_status 2 "$TESTS_DIR/run.sh" "$FIXTURES/empty"
}

test_a_missing_directory_is_an_error() {
  assert_status 2 "$TESTS_DIR/run.sh" "$TEST_TMPDIR/does-not-exist"
}

test_each_test_starts_in_its_own_empty_directory() {
  assert_eq "$TEST_TMPDIR" "$(pwd -P)"
  assert_eq "" "$(ls -A)"
}

test_a_test_that_sets_an_exit_trap_then_dies_is_reported_failed() {
  local out= status=0
  out=$("$TESTS_DIR/run.sh" "$FIXTURES/exit-trap-dies" 2>&1) || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$out" "FAIL sample: test_trap_then_unbound_variable"
  assert_contains "$out" "0 passed, 1 failed"
}

test_a_test_with_an_exit_trap_that_passes_is_still_ok() {
  local out= status=0
  out=$("$TESTS_DIR/run.sh" "$FIXTURES/exit-trap-passes" 2>&1) || status=$?
  assert_eq 0 "$status" "exit status"
  assert_contains "$out" "ok   sample: test_trap_then_passes"
}
