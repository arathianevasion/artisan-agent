# A red merge gate checks the base first (#195): when a gate on CI concludes
# failure or timed_out, merge-gate.sh reruns the failed jobs on the merge
# commit and runs the gate workflow on the base (the integration tip before
# the merge, or the merge batch's base) at the same time. A red base parks
# the run on a base-red decision, a green rerun merges as flaky, and only
# failures new against the base are charged to the ticket (#176's retry).
# Built on merge-batch.test.sh's run (fake `claude`, fake `gh` whose workflow
# runs read the test's bare origin).

. "$TESTS_DIR/merge-batch.test.sh"
# Only this file's tests run here.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_bc_/ {print $3}'); do unset -f "$_f"; done
unset _f

# Red on both the merge commit and the base: check.sh is in every commit.
red_base() {
  echo check.sh >"$FAKE_GH_DIR/ci-red-if-file"
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
}

test_bc_a_red_gate_whose_tests_also_fail_on_the_base_parks_the_run_with_a_base_red_decision() {
  setup_ci
  verified_ticket
  red_base
  merge_1
  assert_eq 19 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "the base is red"
  # The ticket is not charged: still returned and verified, no attempt used.
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq "1 0" "$(state_get '.tickets["1"] | "\(.attempts) \(.failures // [] | length)"')"
  assert_eq pass "$(state_get '.tickets["1"].evidence.verdict')"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "the merge was undone"
  # The rerun was on the merge commit's run; the base ran on the commit before the merge.
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "run rerun 9001 -R local/sample --failed"
  assert_eq "$MAIN_HEAD" "$(jq -r .headSha "$FAKE_GH_DIR/run-9002.json")" "the base ran on the integration tip before the merge"
  assert_eq "" "$(ci_branches)" "every ci branch is gone, the base's too"
  # Parked, reason base, with one base-red decision naming the tests and the run.
  assert_eq "1 9002" "$(state_get '.base_park | "\(.ticket) \(.run_id)"')"
  assert_eq null "$(state_get '.ci_park')"
  assert_eq 1 "$(state_get '[.decisions[] | select(.kind == "base-red" and .status == "waiting")] | length')"
  local q=
  q=$(state_get '[.decisions[] | select(.kind == "base-red")][0].question')
  assert_contains "$q" "the base is red: "
  assert_contains "$q" "tests/save.spec.ts:48 Save v3 › loads a v2 save"
  assert_contains "$q" "run 9002"
  assert_eq "base 1" "$(state_get '[.events[] | select(.event == "parked")] | last | "\(.reason) \(.ticket)"')"
  assert_eq 0 "$(state_get '[.decisions[] | select(.kind == "exception")] | length')" "not blocked"
  # Merging waits for the base; status says why.
  merge_1
  assert_eq 19 "$MERGE_STATUS"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "the base is red"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR" 2>/dev/null)" "parked base: "
  # Once the base is fixed, the Artisan clears the park and the ticket merges.
  rm "$FAKE_GH_DIR/ci-red-if-file"
  assert_contains "$("$SCRIPTS/wave.sh" unpark-base "$RUN_DIR")" "#1"
  assert_eq null "$(state_get '.base_park')"
  assert_eq decided "$(state_get '[.decisions[] | select(.kind == "base-red")][0].status')"
  assert_eq "base 1" "$(state_get '[.events[] | select(.event == "unparked")] | last | "\(.reason) \(.ticket)"')"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_status 6 "$SCRIPTS/wave.sh" unpark-base "$RUN_DIR"
}

test_bc_a_red_gate_whose_rerun_passes_merges_files_a_flaky_finding_and_uses_no_attempt() {
  setup_ci
  verified_ticket
  echo hello.txt >"$FAKE_GH_DIR/ci-red-if-file"
  echo success >"$FAKE_GH_DIR/ci-rerun-outcome"
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(state_get '.tickets["1"].merge_commit')"
  assert_eq "1 0" "$(state_get '.tickets["1"] | "\(.attempts) \(.failures // [] | length)"')"
  assert_eq "ci true flaky" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed) \(.base_check.verdict)"')"
  assert_eq "" "$(ci_branches)"
  # A flaky-test finding for triage (no ticket in blocks), naming the tests and runs.
  local f=
  f=$(state_get '[.findings[] | select(.title | startswith("Flaky"))] | first | tojson')
  assert_eq 1 "$(state_get '[.findings[] | select(.title | startswith("Flaky"))] | length')"
  assert_eq '[]' "$(jq -c '.blocks' <<<"$f")"
  assert_contains "$(jq -r .title <<<"$f")" "tests/save.spec.ts:48 Save v3 › loads a v2 save"
  assert_contains "$(jq -r .why <<<"$f")" "https://github.com/local/sample/actions/runs/9001"
  assert_contains "$(jq -r .why <<<"$f")" "#1"
  assert_eq "" "$(state_get '.base_park // empty')"
}

test_bc_only_failures_new_against_the_base_go_to_the_retry() {
  setup_ci
  verified_ticket
  red_base
  # The base fails only the two e2e tests; the merge fails the unit test too.
  grep '^e2e' "$TESTS_DIR/fixtures/ci-logs/failed.log" >"$FAKE_GH_DIR/ci-log-failed-9002"
  merge_1
  assert_eq 7 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq queued "$(state_get '.tickets["1"].status')" "a failed attempt, requeued"
  assert_eq "1 ci" "$(state_get '.tickets["1"] | "\(.failures | length) \(.failures[0].kind)"')"
  assert_eq '["merge-gate: test_mg_a_red_ci_run_requeues_the_ticket"]' \
    "$(state_get '[.tickets["1"].failures[0].ci.failing_tests.tests[].name] | tojson')" "only the new failure"
  assert_contains "$(state_get '.tickets["1"].failures[0].reason')" "test_mg_a_red_ci_run_requeues_the_ticket"
  assert_not_contains "$(state_get '.tickets["1"].failures[0].reason')" "save.spec.ts"
  assert_eq null "$(state_get '.base_park')"
  assert_eq new "$(state_get '.tickets["1"].suite.base_check.verdict')"
  # The retry's notes list only the new failure.
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "test_mg_a_red_ci_run_requeues_the_ticket"
  assert_not_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "Save v3"
  wait_for "$RUN_DIR/results/1.2.exit.json" 30
}

test_bc_a_merge_batch_on_a_red_base_parks_with_every_ticket_left_verified() {
  setup_batch
  ready 1 a.txt
  ready 2 b.txt
  red_base
  local pre=
  pre=$(git -C "$PROJECT" rev-parse run/r1)
  merge_batch 1 2
  assert_eq 19 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "returned returned" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
  assert_eq "0 0" "$(state_get '[.tickets["1","2"].failures // [] | length] | join(" ")')"
  assert_eq "$pre" "$(git -C "$PROJECT" rev-parse run/r1)" "nothing merged"
  assert_eq "$pre" "$(jq -r .headSha "$FAKE_GH_DIR/run-9002.json")" "the base is the batch's base"
  assert_eq 1 "$(gates)" "one gate: the base was red, so no split"
  assert_eq '["1","2"]' "$(state_get '.base_park.tickets | tojson')"
  assert_eq null "$(state_get '.merge_batch')"
  assert_contains "$(state_get '[.decisions[] | select(.kind == "base-red")][0].question')" "merge batch 1"
  assert_contains "$(state_get '[.decisions[] | select(.kind == "base-red")][0].question')" "the base is red: "
  assert_eq "" "$(ci_branches)"
  rm "$FAKE_GH_DIR/ci-red-if-file"
  "$SCRIPTS/wave.sh" unpark-base "$RUN_DIR" >/dev/null
  merge_batch 1 2
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
}

test_bc_a_flaky_gate_in_a_merge_batch_merges_the_batch_without_a_split() {
  setup_batch
  ready 1 a.txt
  ready 2 b.txt
  echo b.txt >"$FAKE_GH_DIR/ci-red-if-file"
  echo success >"$FAKE_GH_DIR/ci-rerun-outcome"
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
  merge_batch 1 2
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
  assert_eq 1 "$(gates)"
  assert_eq 1 "$(state_get '[.findings[] | select(.title | startswith("Flaky"))] | length')"
  assert_contains "$(state_get '[.findings[] | select(.title | startswith("Flaky"))][0].why')" "merge batch 1"
}

test_bc_each_merge_logs_its_ci_wait_and_the_reports_show_it_per_merge_and_in_total() {
  setup_ci 30 '["1","2"]'   # two tickets: the run is still open for its digest
  verified_ticket
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  local ev=
  ev=$(state_get '[.events[] | select(.event == "ci-wait")] | last | tojson')
  assert_eq "1 success" "$(jq -r '"\(.ticket) \(.outcome)"' <<<"$ev")"
  jq -e '.minutes | type == "number" and . >= 0' <<<"$ev" >/dev/null || fail "no minutes: $ev"
  local report=
  report=$("$SCRIPTS/wave.sh" report "$RUN_DIR")
  assert_eq '1 ["1"]' "$(jq -c -r '"\(.ci_wait.merges | length) \(.ci_wait.merges[0].tickets | tojson)"' <<<"$report")"
  jq -e '.ci_wait.total_minutes | type == "number"' <<<"$report" >/dev/null || fail "no total: $report"
  local digest=
  digest=$("$SCRIPTS/run-digest.sh" --run-dir "$RUN_DIR" --peek)
  assert_contains "$digest" "CI wait: "
  assert_contains "$digest" "#1 "
}

# A gate runner that died mid base check is resumed (--resume) on its same
# run, whose failed jobs were already rerun (attempt 2): no second rerun, and
# a rerun that passed is still flaky.
resumed_gate() { # conclusion of attempt 2
  local sha=
  sha=$(git -C "$PROJECT" rev-parse HEAD)
  git_quiet -C "$PROJECT" push -q origin "$sha:refs/heads/ci/r1-x"
  jq -n --arg sha "$sha" --arg c "$1" '{databaseId: 9001, attempt: 2, workflowName: "ci.yml", headBranch: "ci/r1-x",
      headSha: $sha, event: "workflow_dispatch", status: "completed", conclusion: $c,
      url: "https://github.com/local/sample/actions/runs/9001", createdAt: "2026-11-14T10:00:00Z",
      updatedAt: "2026-11-14T10:05:00Z", jobs: [{name: "bash 5.2", status: "completed", conclusion: $c}]}' \
    >"$FAKE_GH_DIR/run-9001.json"
  RESUMED_STATUS=0
  RESUMED=$("$MG" ci --repo local/sample --workflow ci.yml --branch ci/r1-x --sha "$sha" --dir "$PROJECT" \
    --timeout-minutes 1 --resume --base "$sha" 2>/dev/null) || RESUMED_STATUS=$?
}

test_bc_a_resumed_gate_whose_rerun_passed_is_flaky_and_reruns_nothing() {
  setup_ci
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
  resumed_gate success
  assert_eq 0 "$RESUMED_STATUS" "$RESUMED"
  assert_eq "flaky 2" "$(jq -r '"\(.base_check.verdict) \(.base_check.rerun.attempt)"' <<<"$RESUMED")"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "run rerun"
}

test_bc_a_resumed_gate_whose_rerun_failed_checks_the_base_without_a_second_rerun() {
  setup_ci
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
  resumed_gate failure
  assert_eq 7 "$RESUMED_STATUS" "$RESUMED"
  assert_eq "new success" "$(jq -r '"\(.base_check.verdict) \(.base_check.base.conclusion)"' <<<"$RESUMED")"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "run rerun"
}
