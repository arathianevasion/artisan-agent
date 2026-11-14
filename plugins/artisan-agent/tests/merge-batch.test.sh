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
