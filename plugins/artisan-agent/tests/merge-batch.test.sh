# Batch merge gating (#167, wave.sh merge with several tickets): tickets
# ready together are merged in order onto the integration branch and gated
# once; a red gate is split until the red ticket is found, and only it gets
# the red handling. Built on merge-gate.test.sh's run (fake `claude`, fake
# `gh` whose workflow runs read the test's bare origin).

. "$TESTS_DIR/merge-gate.test.sh"
# Only this file's tests run here.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_mb_/ {print $3}'); do unset -f "$_f"; done
unset _f

# A run over tickets 1-4, none blocking another, on a CI machine (setup_ci).
setup_batch() {
  setup_ci 30 '["1","2","3","4"]'
  rm -f "$FAKE_GH_DIR/blocked_by-2.json"
  local t=
  for t in 3 4; do
    jq -n --argjson n "$t" '{number: $n, title: "Ticket \($n)", state: "open", labels: [], body: "- [ ] it works"}' >"$FAKE_GH_DIR/issue-$t.json"
  done
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 4
    | .plan.tickets["3"] = (.plan.tickets["2"] | .title = "Ticket 3")
    | .plan.tickets["4"] = (.plan.tickets["2"] | .title = "Ticket 4")
    | reduce ("1", "2", "3", "4") as $t (.; .plan.tickets[$t].expected_files = ["t\($t)"])'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
}

# ready ticket file [text]: the ticket's worker writes text (default hi) to
# file; it returns and is verified.
ready() {
  WORKER_FILE=$2 WORKER_TEXT=${3:-hi} "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" "$1" >/dev/null
  wait_for "$RUN_DIR/results/$1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" "$1" >/dev/null
  wait_for "$RUN_DIR/results/verify-$1.1.exit.json" 30
  "$SCRIPTS/verify.sh" judge "$RUN_DIR" "$1" >/dev/null
}

merge_batch() { # tickets...
  MERGE_STATUS=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" "$@" >"$TEST_TMPDIR/merge.out" 2>"$TEST_TMPDIR/merge.err" || MERGE_STATUS=$?
}

gates() { state_get '[.events[] | select(.event == "merge-gate")] | length'; }

test_mb_three_green_tickets_ready_together_are_gated_by_one_ci_run_and_all_merge() {
  setup_batch
  ready 1 a.txt
  ready 2 b.txt
  ready 3 c.txt
  merge_batch 1 2 3
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged merged" "$(state_get '[.tickets["1","2","3"].status] | join(" ")')"
  assert_eq 1 "$(ls "$FAKE_GH_DIR"/run-*.json | wc -l | tr -d ' ')" "one CI run for the batch"
  assert_eq 1 "$(gates)"
  assert_eq '["1","2","3"]' "$(state_get '[.events[] | select(.event == "merge-gate")][0].tickets | tojson')" \
    "the gate's event names every ticket in it"
  # In order: 3's merge commit is the tip, on 2's, on 1's.
  local tip=
  tip=$(git -C "$PROJECT" rev-parse run/r1)
  assert_eq "$tip" "$(state_get '.tickets["3"].merge_commit')"
  assert_eq "$(state_get '.tickets["2"].merge_commit')" "$(git -C "$PROJECT" rev-parse "$tip^1")"
  assert_eq "$(state_get '.tickets["1"].merge_commit')" "$(git -C "$PROJECT" rev-parse "$tip^1^1")"
  assert_eq "$tip" "$(jq -r .headSha "$FAKE_GH_DIR/run-9001.json")" "CI ran the batch's tip"
  assert_eq "ci true success" "$(state_get '.tickets["2"].suite | "\(.mode) \(.passed) \(.conclusion)"')"
  assert_eq "1 1 1" "$(state_get '[.tickets["1","2","3"].attempts] | join(" ")')" "a batch run counts against no attempt"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#1 merged"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#3 merged $tip"
  assert_eq null "$(state_get '.merge_batch')"
  assert_eq null "$(state_get '.merge_gate')"
  assert_eq "" "$(ci_branches)" "every ci branch is gone"
  [ ! -e "$TEST_TMPDIR/suite-ran-here" ] || fail "the suite ran on this machine"
}

test_mb_one_red_ticket_in_a_batch_of_four_is_found_in_three_more_gates_and_only_it_is_blocked() {
  setup_batch
  echo BROKEN >"$FAKE_GH_DIR/ci-red-if-file"
  ready 1 a.txt
  ready 2 b.txt
  ready 3 BROKEN
  ready 4 d.txt
  merge_batch 1 2 3 4
  assert_eq 7 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged blocked merged" "$(state_get '[.tickets["1","2","3","4"].status] | join(" ")')"
  # The whole batch, then [1,2] green, [3] red, and 4 merged afresh without 3.
  assert_eq 4 "$(gates)" "found in at most 3 more gates"
  assert_eq '[["1","2","3","4"],["1","2"],["3"],["4"]]' \
    "$(state_get '[.events[] | select(.event == "merge-gate") | .tickets] | tojson')"
  # Only the red ticket gets the red handling: blocked, with a decision, naming the run.
  assert_eq '["3"]' "$(state_get '[.decisions[] | select(.kind == "exception") | .ticket] | tojson')"
  assert_contains "$(state_get '.tickets["3"].blocked_reason')" "CI went red after merging (failure on https://github.com/local/sample/actions/runs/"
  assert_eq "ci false failure" "$(state_get '.tickets["3"].suite | "\(.mode) \(.passed) \(.conclusion)"')"
  assert_eq "1 1 1 1" "$(state_get '[.tickets["1","2","3","4"].attempts] | join(" ")')" "a batch run counts against no attempt"
  # The integration branch holds 1, 2 and 4, never 3.
  local tip=
  tip=$(git -C "$PROJECT" rev-parse run/r1)
  assert_eq "$tip" "$(state_get '.tickets["4"].merge_commit')"
  assert_eq "$(state_get '.tickets["2"].merge_commit')" "$(git -C "$PROJECT" rev-parse "$tip^1")"
  git -C "$PROJECT" cat-file -e "$tip:d.txt" || fail "4 is not on the integration branch"
  ! git -C "$PROJECT" cat-file -e "$tip:BROKEN" 2>/dev/null || fail "the red ticket is on the integration branch"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#3 red"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#4 merged $tip"
  assert_eq null "$(state_get '.merge_batch')"
  assert_eq "" "$(ci_branches)" "every ci branch is gone"
}

test_mb_a_red_ticket_in_a_local_batch_is_found_and_the_rest_merge() {
  setup_batch
  export ARTISAN_MERGE_GATE=local
  ready 1 a.txt
  ready 2 BROKEN
  ready 3 c.txt
  merge_batch 1 2 3
  assert_eq 7 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged blocked merged" "$(state_get '[.tickets["1","2","3"].status] | join(" ")')"
  assert_eq "local false" "$(state_get '.tickets["2"].suite | "\(.mode) \(.passed)"')"
  assert_contains "$(state_get '.tickets["2"].blocked_reason')" "the suite failed after merging"
  [ -f "$RUN_DIR/$(state_get '.tickets["2"].suite.log')" ] || fail "no suite log at $(state_get '.tickets["2"].suite.log')"
  assert_eq "local true" "$(state_get '.tickets["3"].suite | "\(.mode) \(.passed)"')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(state_get '.tickets["3"].merge_commit')"
}

test_mb_a_conflict_while_building_leaves_its_ticket_out_for_the_conflict_path() {
  setup_batch
  ready 1 a.txt one
  ready 2 a.txt two
  ready 3 c.txt
  merge_batch 1 2 3
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged returned merged" "$(state_get '[.tickets["1","2","3"].status] | join(" ")')"
  assert_eq 1 "$(gates)" "1 and 3 gated together"
  assert_eq '["1","3"]' "$(state_get '[.events[] | select(.event == "merge-gate")][0].tickets | tojson')"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#2 left out: conflict in a.txt"
  assert_eq '["2"]' "$(state_get '[.events[] | select(.event == "merge-batch-ended")][0].left_out | tojson')"
  # Merged alone, it takes the existing conflict path: its one resolve try.
  merge_batch 2
  assert_eq 11 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq '["a.txt"]' "$(state_get '.tickets["2"].resolve.paths | tojson')"
}

test_mb_a_batch_of_one_is_a_merge_as_before() {
  setup_batch
  ready 1 a.txt
  merge_batch 1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(cat "$TEST_TMPDIR/merge.out")" "prints the merge commit, as before"
  case "$(state_get '.tickets["1"].suite.branch')" in ci/r1-1-1-*) ;; *) fail "not the single-merge branch" ;; esac
  assert_eq 0 "$(state_get '[.events[] | select(.event == "merge-batch")] | length')" "no batch"
}

test_mb_with_merge_batch_off_only_the_first_ticket_merges_alone() {
  setup_batch
  export ARTISAN_MERGE_BATCH=off
  ready 1 a.txt
  ready 2 b.txt
  merge_batch 1 2
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged returned" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(cat "$TEST_TMPDIR/merge.out")"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "merge batching is off"
  merge_batch 2
  assert_eq 0 "$MERGE_STATUS"
  assert_eq 2 "$(gates)" "one gate each"
}

test_mb_merge_batch_is_a_host_setting_on_by_default() {
  unset ARTISAN_MERGE_BATCH
  export ARTISAN_HOME="$TEST_TMPDIR/home"
  mkdir -p "$ARTISAN_HOME"
  assert_eq on "$("$MG" batch)" "on by default"
  assert_eq "on default" "$(ARTISAN_MERGE_GATE=ci "$MG" show | jq -r '"\(.batch) \(.batch_source)"')"
  echo '{"merge_batch": "off"}' >"$ARTISAN_HOME/host.json"
  assert_eq off "$("$MG" batch)"
  assert_eq "$ARTISAN_HOME/host.json" "$(ARTISAN_MERGE_GATE=ci "$MG" show | jq -r .batch_source)"
  echo '{"merge_batch": "sometimes"}' >"$ARTISAN_HOME/host.json"
  assert_status 1 "$MG" batch
  assert_eq ci "$(ARTISAN_MERGE_GATE=ci "$MG" mode)" "a bad merge_batch never stops the mode"
  assert_eq on "$(ARTISAN_MERGE_BATCH=on "$MG" batch)" "the environment wins, for tests and trials"
}

test_mb_a_batch_gate_still_running_returns_20_and_a_later_call_finishes_the_batch() {
  setup_batch
  export ARTISAN_MERGE_GATE=local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = ("{ [ ! -e " + $d + "/slow ] || sleep $(cat " + $d + "/slow); } && sh check.sh")' \
    --arg d "$TEST_TMPDIR"
  ready 1 a.txt
  ready 2 BROKEN
  echo 2 >"$TEST_TMPDIR/slow"
  MERGE_STATUS=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 2 --wait 0 >"$TEST_TMPDIR/merge.out" 2>"$TEST_TMPDIR/merge.err" || MERGE_STATUS=$?
  assert_eq 20 "$MERGE_STATUS" "$(cat "$TEST_TMPDIR/merge.err")"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "merge batch 1's gate is running on #1, #2"
  # New work branches from the batch's green base, never an ungated merge.
  assert_eq "$(state_get '.merge_batch.pre')" "$(state_get '.merge_gate.pre')"
  assert_eq "$(git -C "$PROJECT" rev-parse main)" "$(state_get '.merge_batch.pre')"
  # Another ticket's merge waits for the batch.
  ready 3 c.txt
  merge_batch 3
  assert_eq 20 "$MERGE_STATUS"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "merge batch 1 (#1, #2) is in progress"
  # Naming any ticket of the batch carries it on, to the end.
  local i=0
  MERGE_STATUS=20
  while [ "$MERGE_STATUS" -eq 20 ]; do
    i=$((i + 1)); [ "$i" -le 30 ] || fail "the batch never settled"
    merge_batch 2
  done
  assert_eq 7 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged blocked" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
  assert_eq 2 "$(gates)" "the batch, then [1] green: 2 is red without a gate of its own"
}

test_mb_ci_giving_a_batch_no_verdict_parks_the_run_and_unpark_lets_the_batch_merge_afresh() {
  setup_batch
  ready 1 a.txt
  ready 2 b.txt
  echo cancelled >"$FAKE_GH_DIR/ci-outcome"
  merge_batch 1 2
  assert_eq 19 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "returned returned" "$(state_get '[.tickets["1","2"].status] | join(" ")')" "CI never judged them: not blocked"
  assert_eq '["1","2"]' "$(state_get '.ci_park.tickets | tojson')"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR" 2>/dev/null || true)" "parked ci: merge batch 1 (#1, #2)"
  assert_eq null "$(state_get '.merge_batch')"
  rm "$FAKE_GH_DIR/ci-outcome"
  assert_contains "$("$SCRIPTS/wave.sh" unpark-ci "$RUN_DIR")" "merge #1, #2 again"
  assert_eq null "$(state_get '.tickets["1"].ci_retry')"
  merge_batch 1 2
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
}

test_mb_a_ticket_named_beside_a_batch_in_progress_is_reported_not_dropped() {
  setup_batch
  export ARTISAN_MERGE_GATE=local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = ("{ [ ! -e " + $d + "/slow ] || sleep $(cat " + $d + "/slow); } && sh check.sh")' \
    --arg d "$TEST_TMPDIR"
  ready 1 a.txt
  ready 2 b.txt
  ready 3 c.txt
  echo 1 >"$TEST_TMPDIR/slow"
  MERGE_STATUS=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 2 --wait 0 >/dev/null 2>&1 || MERGE_STATUS=$?
  assert_eq 20 "$MERGE_STATUS"
  local i=0
  MERGE_STATUS=20
  while [ "$MERGE_STATUS" -eq 20 ]; do
    i=$((i + 1)); [ "$i" -le 30 ] || fail "the batch never settled"
    merge_batch 2 3
  done
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged returned" "$(state_get '[.tickets["1","2","3"].status] | join(" ")')"
  assert_contains "$(cat "$TEST_TMPDIR/merge.out")" "#3 not merged: not in merge batch 1; merge it next"
}

test_mb_a_batch_of_release_only_changes_over_a_green_commit_is_gated_without_a_dispatch() {
  setup_batch
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.merge_gate_skip_paths = ["a.txt", "b.txt"]'
  skip_run 9000 "$MAIN_HEAD" success
  ready 1 a.txt
  ready 2 b.txt
  merge_batch 1 2
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "merged merged" "$(state_get '[.tickets["1","2"].status] | join(" ")')"
  if dispatched; then fail "CI was dispatched"; fi
  assert_eq "true true" "$(state_get '[.tickets["1","2"].suite.skipped] | map(tostring) | join(" ")')"
  assert_eq '9000 ["1","2"]' "$(state_get '[.events[] | select(.event == "merge-gate-skipped")] | last | "\(.run_id) \(.tickets | tojson)"')" \
    "the event names the green run and the batch's tickets"
}
