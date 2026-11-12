# The fake `gh` (fixtures/fake-gh/gh): it answers like real `gh` on an empty tracker (#125).

setup_fake_gh() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
}

test_issue_list_on_an_empty_tracker_prints_an_empty_list_and_exits_zero() {
  setup_fake_gh
  local out= status=0
  out=$(gh issue list --json number) || status=$?
  assert_eq 0 "$status" "exit status"
  assert_eq "[]" "$out"
}

test_issue_list_filters_on_an_empty_tracker_also_print_an_empty_list() {
  setup_fake_gh
  local out= status=0 args=
  for args in "--label plan" "--state closed" "--state all" "--state open --label review-gate"; do
    status=0
    # shellcheck disable=SC2086
    out=$(gh issue list -R local/sample $args --json number) || status=$?
    assert_eq 0 "$status" "exit status for: $args"
    assert_eq "[]" "$out" "output for: $args"
  done
}

test_issue_list_without_json_on_an_empty_tracker_prints_nothing_and_exits_zero() {
  setup_fake_gh
  local out= status=0
  out=$(gh issue list) || status=$?
  assert_eq 0 "$status" "exit status"
  assert_eq "" "$out"
}
