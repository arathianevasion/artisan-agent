# Starts fake-claude's sleep mode and leaves its stray running; the test
# harness test (harness.test.sh) checks run.sh's cleanup ended it (#145).
test_leaves_a_stray() {
  PATH="$TESTS_DIR/fixtures/fake-claude:$PATH"
  FAKE_CLAUDE_MODE=sleep FAKE_CLAUDE_SLEEP=1 claude >/dev/null 2>&1 &
  local i=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "fake-claude-stray:$TEST_TMPDIR" >/dev/null && break
    sleep 0.3
  done
  pgrep -f "fake-claude-stray:$TEST_TMPDIR" >/dev/null || return 1
  printf '%s\n' "$TEST_TMPDIR" >"$STRAY_RECORD"
}
