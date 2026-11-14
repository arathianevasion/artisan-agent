# worktree_setup (#173): the project's setup command runs once in every new
# worker, verifier and hands-on worktree (and the end gate's), with the
# worktree as its directory and ARTISAN_MAIN set to the main checkout; unset
# runs nothing; a failing command is a setup failure with the stderr tail, not
# a red test. Built on wave.test.sh's run (fake `claude`, fake `gh`).

. "$TESTS_DIR/wave.test.sh"
# Only this file's tests run here; wave.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_ws_/ {print $3}'); do unset -f "$_f"; done
unset _f

# Writes the project's config with worktree_setup = $1 (a shell command).
set_setup() {
  mkdir -p "$PROJECT/.artisan-agent"
  printf "worktree_setup: '%s'\n" "$(printf '%s' "$1" | sed "s/'/''/g")" >"$PROJECT/.artisan-agent/config.yml"
}

test_ws_a_worker_worktree_runs_the_setup_once_in_the_worktree_with_artisan_main() {
  setup_wave
  export SETUP_LOG="$TEST_TMPDIR/setup.log"
  set_setup 'echo "$PWD $ARTISAN_MAIN" >>"$SETUP_LOG"'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export FAKE_CLAUDE_MODE=complete
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["1"].status')"
  assert_eq "1" "$(wc -l <"$SETUP_LOG" | tr -d ' ')" "ran once"
  assert_eq "$(cd "$TEST_TMPDIR/project-wt/r1-1.1" && pwd -P) $(cd "$PROJECT" && pwd -P)" "$(cat "$SETUP_LOG")"
}

test_ws_unset_runs_nothing_and_dispatches_as_before() {
  setup_wave
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export FAKE_CLAUDE_MODE=complete
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["1"].status')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')"
}

test_ws_a_failing_setup_fails_the_attempt_with_reason_setup_and_the_stderr_tail() {
  setup_wave
  set_setup 'echo "vitest: could not install" >&2; exit 3'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export FAKE_CLAUDE_MODE=complete
  local status=0
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 6 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "vitest: could not install"
  assert_eq 1 "$(state_get '.tickets["1"].attempts')"
  assert_eq queued "$(state_get '.tickets["1"].status')" "a retry is allowed"
  assert_contains "$(state_get '.tickets["1"].failures[0].reason')" "setup:"
  assert_contains "$(state_get '.tickets["1"].failures[0].reason')" "exited 3"
  assert_contains "$(state_get '.tickets["1"].failures[0].reason')" "vitest: could not install"
  [ ! -d "$TEST_TMPDIR/project-wt/r1-1.1" ] || fail "the worktree was left behind"
  [ ! -e "$RUN_DIR/workers/1.1" ] || fail "a worker was launched"
  # The second failure uses the last attempt: the ticket is blocked, not dispatched red.
  assert_status 6 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1
  assert_eq blocked "$(state_get '.tickets["1"].status')"
}

test_ws_a_failing_setup_makes_the_verifier_an_error_verdict_with_reason_setup() {
  setup_wave
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  set_setup 'echo "no lockfile" >&2; exit 1'
  local status=0
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 1 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "no lockfile"
  assert_eq error "$(state_get '.tickets["1"].verifications[-1].verdict')"
  assert_contains "$(state_get '.tickets["1"].verifications[-1].reason')" "setup:"
  [ ! -d "$TEST_TMPDIR/project-wt/r1-verify-1.1" ] || fail "the verifier's worktree was left behind"
}

test_ws_a_hands_on_worktree_runs_the_setup_and_a_failure_keeps_the_ticket_queued() {
  setup_wave '["1","2"]'
  jq '.labels = [{name: "ready-for-human"}]' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/i.tmp" && mv "$FAKE_GH_DIR/i.tmp" "$FAKE_GH_DIR/issue-1.json"
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  set_setup 'echo "npm ci failed" >&2; exit 1'
  local status=0
  "$SCRIPTS/human.sh" start "$RUN_DIR" 1 >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 6 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "npm ci failed"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  [ ! -d "$TEST_TMPDIR/project-wt/r1-1.human" ] || fail "the worktree was left behind"
  set_setup 'touch deps-installed'
  "$SCRIPTS/human.sh" start "$RUN_DIR" 1 >/dev/null
  [ -e "$TEST_TMPDIR/project-wt/r1-1.human/deps-installed" ] || fail "setup did not run in the hands-on worktree"
}
