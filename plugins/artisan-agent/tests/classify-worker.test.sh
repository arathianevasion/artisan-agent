# classify-worker.sh judges an attempt from its files: the exit record, the
# worker's JSON output and its result text, never the exit code alone.

setup_run() {
  RUN="$TEST_TMPDIR/run"
  WORKTREE="$TEST_TMPDIR/worktree"
  mkdir -p "$RUN" "$WORKTREE"
  printf 'Build ticket 46.\n' >"$TEST_TMPDIR/prompt.md"
  PATH="$TESTS_DIR/fixtures/fake-claude:$PATH"
  export PATH FAKE_CLAUDE_PID="$TEST_TMPDIR/claude.pid"
  trap cleanup EXIT
}

cleanup() {
  local pid
  for pid in $(cat "$RUN"/workers/*/runner.pid "$FAKE_CLAUDE_PID" 2>/dev/null); do
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
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

test_reads_the_attempt_it_is_given() {
  setup_run
  finished complete >/dev/null
  assert_eq "completed -" "$(classify 1)"
  assert_status 2 classify 2
}
