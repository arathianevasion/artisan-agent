# classify-worker.sh judges an attempt from its files: the exit record, the
# worker's JSON output and its result text, never the exit code alone.

setup_run() {
  RUN="$TEST_TMPDIR/run"
  WORKTREE="$TEST_TMPDIR/worktree"
  mkdir -p "$RUN" "$WORKTREE"
  # An approved plan with ticket 46 in scope: nothing launches without one.
  jq -n '{schema_version: 1, plan: {scope: ["46"]}}' >"$RUN/state.json"
  printf 'Build ticket 46.\n' >"$TEST_TMPDIR/prompt.md"
  PATH="$TESTS_DIR/fixtures/fake-claude:$PATH"
  export PATH FAKE_CLAUDE_PID="$TEST_TMPDIR/claude.pid"
  trap cleanup EXIT
}

cleanup() {
  kill_test_processes
}

classify() { "$PLUGIN_ROOT/scripts/classify-worker.sh" "$RUN" 46 "$@"; }

# Run a fake worker to the end and print its classification.
finished() { # FAKE_CLAUDE_MODE [run-ticket args...]
  export FAKE_CLAUDE_MODE=$1
  shift
  "$PLUGIN_ROOT/scripts/run-ticket.sh" --run-dir "$RUN" --ticket 46 \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$WORKTREE" \
    --estimate-usd 1 --expected-minutes 10 "$@" >/dev/null
  local i=0
  while [ ! -f "$RUN/results/46.1.exit.json" ]; do
    i=$((i + 1))
    [ "$i" -le 150 ] || fail "no exit record"
    sleep 0.1
  done
  classify
}

test_a_worker_that_finished_with_the_completion_line_is_completed() {
  setup_run
  assert_eq "completed -" "$(finished complete)"
}

test_a_hook_blocked_run_that_exited_zero_is_not_completed() {
  setup_run
  assert_eq "not-completed no-completion-line" "$(finished blocked)"
  assert_eq 0 "$(jq -r .exit_code "$RUN/results/46.1.exit.json")" "the blocked run did exit 0"
  assert_eq false "$(jq -r .is_error "$RUN/workers/46.1/output.json")" "and reported no error"
}

test_a_clean_exit_without_the_completion_line_is_not_completed() {
  setup_run
  assert_eq "not-completed no-completion-line" "$(finished no-marker)"
}

test_the_completion_line_without_a_result_file_is_not_completed() {
  setup_run
  finished complete >/dev/null
  rm "$RUN/results/46.1.result.json"
  assert_eq "not-completed no-result-file" "$(classify)"
}

test_hitting_the_budget_cap_is_a_failed_attempt() {
  setup_run
  assert_eq "failed budget" "$(finished budget)"
}

test_hitting_the_turn_cap_is_a_failed_attempt() {
  setup_run
  assert_eq "failed turns" "$(finished turns)"
}

test_passing_the_deadline_is_a_failed_attempt() {
  setup_run
  export FAKE_CLAUDE_SLEEP=30
  assert_eq "failed deadline" "$(finished sleep --deadline-seconds 1)"
}

test_an_error_result_is_a_failed_attempt_even_with_subtype_success() {
  setup_run
  assert_eq "failed error" "$(finished api-error)"
}

test_a_crash_with_no_output_is_a_failed_attempt() {
  setup_run
  assert_eq "failed crashed" "$(finished crash)"
}

test_a_stopped_worker_is_a_failed_attempt() {
  setup_run
  export FAKE_CLAUDE_MODE=sleep
  local runner
  runner=$("$PLUGIN_ROOT/scripts/run-ticket.sh" --run-dir "$RUN" --ticket 46 \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$WORKTREE" \
    --estimate-usd 1 --expected-minutes 10)
  assert_eq "running -" "$(classify)"
  kill -TERM "$runner"
  local i=0
  while [ ! -f "$RUN/results/46.1.exit.json" ]; do
    i=$((i + 1)); [ "$i" -le 150 ] || fail "no exit record"; sleep 0.1
  done
  assert_eq "failed stopped" "$(classify)"
}

test_a_runner_that_vanished_without_an_exit_record_is_a_failed_attempt() {
  setup_run
  mkdir -p "$RUN/workers/46.1"
  sh -c 'exit 0' &
  local dead=$!
  wait "$dead"
  echo "$dead" >"$RUN/workers/46.1/runner.pid"
  assert_eq "failed vanished" "$(classify)"
}

test_a_runner_that_writes_its_exit_record_between_the_two_checks_is_classified_from_it() {
  setup_run
  mkdir -p "$RUN/workers/46.1" "$RUN/results" "$TEST_TMPDIR/stub"
  echo 99999 >"$RUN/workers/46.1/runner.pid"
  # The liveness check is the moment the runner's exit trap lands: the stub
  # writes the exit record, then reports the runner gone.
  printf '#!/bin/sh\necho %s >"%s"\nexit 1\n' "'{\"reason\": \"deadline\"}'" "$RUN/results/46.1.exit.json" >"$TEST_TMPDIR/stub/ps"
  chmod +x "$TEST_TMPDIR/stub/ps"
  assert_eq "failed deadline" "$(PATH="$TEST_TMPDIR/stub:$PATH" classify)"
}

test_a_runner_pid_that_cannot_be_read_is_an_error_not_a_vanished_session() {
  setup_run
  mkdir -p "$RUN/workers/46.1"
  : >"$RUN/workers/46.1/runner.pid"
  local out status=0
  out=$(classify 2>/dev/null) || status=$?
  assert_eq 3 "$status"
  assert_eq "" "$out"
}

test_reads_the_attempt_it_is_given() {
  setup_run
  finished complete >/dev/null
  assert_eq "completed -" "$(classify 1)"
  assert_status 2 classify 2
}

test_usage_prints_the_whole_header() {
  local out
  out=$("$PLUGIN_ROOT/scripts/classify-worker.sh" 2>&1) || true
  assert_contains "$out" "Needs jq."
}
