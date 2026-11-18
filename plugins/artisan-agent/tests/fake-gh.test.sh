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

# A runner shortage (#258): a job no runner picks up is cancelled with
# GitHub's "not acquired by Runner" annotation, read through the check-runs
# annotations call; rerun --failed reruns only the jobs that did not pass,
# and the shortage lasts ci-no-runner-attempts attempts.
setup_fake_ci() {
  setup_fake_gh
  local repo="$TEST_TMPDIR/remote"
  git init -q "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git -C "$repo" branch -q -M ci/x
  export FAKE_GH_REMOTE="$repo"
}

test_a_job_no_runner_picks_up_is_cancelled_with_the_runner_annotation_and_reran_when_runners_return() {
  setup_fake_ci
  echo '["macos"]' >"$FAKE_GH_DIR/ci-no-runner"
  echo 1 >"$FAKE_GH_DIR/ci-no-runner-attempts"
  echo '["linux", "macos"]' >"$FAKE_GH_DIR/ci-jobs"
  gh workflow run ci.yml -R local/sample --ref ci/x
  local run=
  run=$(gh run view 9001 -R local/sample --json jobs,conclusion)
  assert_eq "failure 900101 linux success 900102 macos cancelled" \
    "$(jq -r '[.conclusion, (.jobs[] | .databaseId, .name, .conclusion)] | join(" ")' <<<"$run")"
  assert_eq "[]" "$(gh api repos/local/sample/check-runs/900101/annotations)" "a job that ran has none"
  assert_contains "$(gh api repos/local/sample/check-runs/900102/annotations | jq -r '.[0].message')" "not acquired by Runner"
  assert_status 1 gh api repos/local/sample/check-runs/12345/annotations
  gh run rerun 9001 -R local/sample --failed
  run=$(gh run view 9001 -R local/sample --json jobs,conclusion,attempt)
  assert_eq "2 success linux success macos success" \
    "$(jq -r '[.attempt, .conclusion, (.jobs[] | .name, .conclusion)] | map(tostring) | join(" ")' <<<"$run")"
  assert_eq "[]" "$(gh api repos/local/sample/check-runs/900102/annotations)" "the rerun job ran"
}

test_rerun_failed_leaves_a_passed_job_as_it_was_and_a_lasting_shortage_cancels_again() {
  setup_fake_ci
  echo '["macos"]' >"$FAKE_GH_DIR/ci-no-runner"
  echo '["linux", "macos"]' >"$FAKE_GH_DIR/ci-jobs"
  gh workflow run ci.yml -R local/sample --ref ci/x
  echo failure >"$FAKE_GH_DIR/ci-rerun-outcome"
  gh run rerun 9001 -R local/sample --failed
  assert_eq "2 failure linux success macos cancelled" \
    "$(gh run view 9001 -R local/sample --json jobs | jq -r '[.attempt, .conclusion, (.jobs[] | .name, .conclusion)] | map(tostring) | join(" ")')"
}
