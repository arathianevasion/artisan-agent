# For --rerun-failed: one test passes, one fails on its first run only (the
# outer test sets FLAKY_STATE to a file path that does not exist yet), one
# always fails.

test_a_passes() {
  assert_eq a a
}

test_b_fails_once() {
  if [ ! -e "$FLAKY_STATE" ]; then
    : >"$FLAKY_STATE"
    fail "the first run fails"
  fi
}

test_c_always_fails() {
  fail "fails every time"
}
