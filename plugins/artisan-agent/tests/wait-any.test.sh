# wait-any.sh returns when a result file, exit record or findings file
# appears or grows under a run's results/ folder, or on timeout.

wait_any() { "$PLUGIN_ROOT/scripts/wait-any.sh" "$@"; }

setup_run() {
  RUN="$TEST_TMPDIR/run"
  mkdir -p "$RUN/results/findings"
}

# Write after a delay, in the background, so wait-any is already waiting.
later() { # seconds command...
  local delay="$1"
  shift
  (sleep "$delay"; "$@") >/dev/null 2>&1 &
}

append() { printf '%s\n' "$2" >>"$1"; }

test_times_out_with_status_124_when_nothing_changes() {
  setup_run
  local out status=0 start=$SECONDS
  out=$(wait_any "$RUN" --timeout 2) || status=$?
  assert_eq 124 "$status" "exit status on timeout"
  assert_eq "" "$out" "nothing reported on timeout"
  [ $((SECONDS - start)) -ge 2 ] || fail "returned before the timeout"
}

test_first_call_reports_files_already_present() {
  setup_run
  echo '{}' >"$RUN/results/46.1.exit.json"
  local out
  out=$(wait_any "$RUN" --timeout 5)
  assert_contains "$out" "new results/46.1.exit.json"
}

test_returns_on_a_new_result_file() {
  setup_run
  wait_any "$RUN" --timeout 1 >/dev/null || true # take the baseline
  later 1 append "$RUN/results/46.1.result.json" '{"ok":true}'
  local out
  out=$(wait_any "$RUN" --timeout 10)
  assert_eq "new results/46.1.result.json" "$out"
}

test_returns_on_a_new_exit_record() {
  setup_run
  wait_any "$RUN" --timeout 1 >/dev/null || true
  later 1 append "$RUN/results/46.1.exit.json" '{"exit_code":0}'
  local out
  out=$(wait_any "$RUN" --timeout 10)
  assert_eq "new results/46.1.exit.json" "$out"
}

test_returns_when_a_findings_file_appears() {
  setup_run
  wait_any "$RUN" --timeout 1 >/dev/null || true
  later 1 append "$RUN/results/findings/46.jsonl" '{"finding":"one"}'
  local out
  out=$(wait_any "$RUN" --timeout 10)
  assert_eq "new results/findings/46.jsonl" "$out"
}

test_returns_when_a_findings_file_grows() {
  setup_run
  append "$RUN/results/findings/46.jsonl" '{"finding":"one"}'
  wait_any "$RUN" --timeout 1 >/dev/null || true
  later 1 append "$RUN/results/findings/46.jsonl" '{"finding":"two"}'
  local out
  out=$(wait_any "$RUN" --timeout 10)
  assert_eq "grew results/findings/46.jsonl" "$out"
}

test_seen_files_do_not_wake_it_again() {
  setup_run
  append "$RUN/results/findings/46.jsonl" '{"finding":"one"}'
  wait_any "$RUN" --timeout 5 >/dev/null
  local status=0
  wait_any "$RUN" --timeout 1 >/dev/null || status=$?
  assert_eq 124 "$status" "an unchanged file is not reported twice"
}

test_ignores_temporary_files_being_written() {
  setup_run
  wait_any "$RUN" --timeout 1 >/dev/null || true
  append "$RUN/results/.46.1.exit.json.tmp" '{"partial":'
  local status=0
  wait_any "$RUN" --timeout 1 >/dev/null || status=$?
  assert_eq 124 "$status" "dotfiles are in-progress writes"
}

test_waits_for_a_results_folder_that_does_not_exist_yet() {
  RUN="$TEST_TMPDIR/run"
  mkdir -p "$RUN"
  later 1 mkdir -p "$RUN/results"
  later 2 append "$RUN/results/46.1.exit.json" '{}'
  local out
  out=$(wait_any "$RUN" --timeout 10)
  assert_eq "new results/46.1.exit.json" "$out"
}

test_rejects_a_missing_run_folder() {
  assert_status 2 wait_any "$TEST_TMPDIR/nope" --timeout 1
}
