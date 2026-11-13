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

# --- -j and --shard ---

# run_all_in dir [args...]: the harness's whole output and exit status, as
# "<status>\n<output>", with a fresh private scratch root so runs don't mix.
run_all_in() {
  local dir=$1 out= status=0
  shift
  out=$("$TESTS_DIR/run.sh" "$@" "$dir" 2>&1) || status=$?
  printf '%s\n%s\n' "$status" "$out"
}

test_parallel_output_and_exit_status_match_a_serial_run() {
  local d= serial= parallel=
  for d in passing failing empty exit-trap-dies exit-trap-passes many slow-first; do
    serial=$(run_all_in "$FIXTURES/$d")
    parallel=$(run_all_in "$FIXTURES/$d" -j 4)
    assert_eq "$serial" "$parallel" "-j 4 on $d"
  done
}

test_parallel_prints_a_slow_test_first_when_it_is_listed_first() {
  local out=
  out=$("$TESTS_DIR/run.sh" -j 3 "$FIXTURES/slow-first" 2>&1) || true
  assert_eq "ok   sample: test_a_slow" "$(printf '%s\n' "$out" | sed -n 1p)"
  assert_eq "ok   sample: test_b_fast" "$(printf '%s\n' "$out" | sed -n 2p)"
  assert_eq "FAIL sample: test_c_fails_fast" "$(printf '%s\n' "$out" | sed -n 3p)"
}

test_parallel_jobs_really_overlap() {
  # Three two-second tests finish well under six seconds with -j 3.
  local start= end=
  start=$(date +%s)
  "$TESTS_DIR/run.sh" -j 3 "$FIXTURES/slow-first" >/dev/null 2>&1 || true
  mkdir "$TEST_TMPDIR/three"
  local n=
  for n in 1 2 3; do
    printf 'test_s%s() { sleep 3; }\n' "$n" >"$TEST_TMPDIR/three/t$n.test.sh"
  done
  start=$(date +%s)
  "$TESTS_DIR/run.sh" -j 3 "$TEST_TMPDIR/three" >/dev/null 2>&1
  end=$(date +%s)
  [ $((end - start)) -lt 8 ] || fail "three 3s tests took $((end - start))s under -j 3"
}

test_every_parallel_job_has_its_own_scratch_directory_and_no_artisan_variables() {
  mkdir "$TEST_TMPDIR/probe"
  local n=
  for n in 1 2 3 4; do
    cat >"$TEST_TMPDIR/probe/p$n.test.sh" <<'PROBE'
test_probe() {
  # lib.sh sets ARTISAN_USAGE_FILE itself; anything else came from the caller.
  local leaked=
  leaked=$(compgen -v ARTISAN_ | grep -v '^ARTISAN_USAGE_FILE$' || true)
  [ -z "$leaked" ] || fail "ARTISAN_ variables reached the test: $leaked"
  [ -z "$(ls -A)" ] || fail "scratch directory was not empty: $(ls -A)"
  : > "$TEST_TMPDIR/mine"
  sleep 1
  [ "$(ls -A)" = mine ] || fail "another job wrote into this scratch directory"
}
PROBE
  done
  local out= status=0
  out=$(ARTISAN_RUN=leak ARTISAN_X=1 "$TESTS_DIR/run.sh" -j 4 "$TEST_TMPDIR/probe" 2>&1) || status=$?
  assert_eq 0 "$status" "exit status: $out"
  assert_contains "$out" "4 passed, 0 failed"
}

test_the_pass_marker_rule_holds_under_parallel_jobs() {
  local out= status=0
  out=$("$TESTS_DIR/run.sh" -j 4 "$FIXTURES/exit-trap-dies" 2>&1) || status=$?
  assert_eq 1 "$status" "exit status"
  assert_contains "$out" "FAIL sample: test_trap_then_unbound_variable"
}

test_shards_together_cover_every_test_exactly_once() {
  local n=3 i= all= shard=
  all=$("$TESTS_DIR/run.sh" "$FIXTURES/many" 2>&1 | grep -E '^(ok|FAIL) ')
  assert_eq 7 "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" "tests in the fixture"
  shard=""
  for i in $(seq 1 $n); do
    shard="$shard$("$TESTS_DIR/run.sh" --shard "$i/$n" "$FIXTURES/many" 2>&1 | grep -E '^(ok|FAIL) ')
"
  done
  assert_eq "$(printf '%s\n' "$all" | sort)" "$(printf '%s' "$shard" | sort)" "union of the shards"
}

test_a_shard_takes_every_nth_test_from_the_ith_and_combines_with_j() {
  local out=
  out=$("$TESTS_DIR/run.sh" -j 3 --shard 2/3 "$FIXTURES/many" 2>&1)
  # Full order: other: test_seven, test_six; sample: test_five, test_four, test_one, test_three, test_two.
  assert_eq "ok   other: test_six
ok   sample: test_one

2 passed, 0 failed" "$out"
}

test_bad_j_and_shard_arguments_are_usage_errors() {
  assert_status 2 "$TESTS_DIR/run.sh" -j 0 "$FIXTURES/passing"
  assert_status 2 "$TESTS_DIR/run.sh" -j x "$FIXTURES/passing"
  assert_status 2 "$TESTS_DIR/run.sh" --shard 0/3 "$FIXTURES/passing"
  assert_status 2 "$TESTS_DIR/run.sh" --shard 4/3 "$FIXTURES/passing"
  assert_status 2 "$TESTS_DIR/run.sh" --shard nonsense "$FIXTURES/passing"
  assert_status 2 "$TESTS_DIR/run.sh" --bogus "$FIXTURES/passing"
}
