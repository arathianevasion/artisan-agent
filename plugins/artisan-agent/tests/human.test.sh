# human.sh: the hands-on ticket. The plan step suggests at most one, off the
# critical path, with its focus, and shows the delay of a critical-path pick;
# a ready-for-human ticket gets a worktree from the integration branch and is
# never dispatched; "done" goes through the verifier, the suite and the serial
# merge; and a run with only work behind it parked says so. Built on
# wave.test.sh's run (fake `claude` per role, fake `gh` over a folder tracker).

. "$TESTS_DIR/wave.test.sh"
# Only this file's tests run here; wave.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_h_/ {print $3}'); do unset -f "$_f"; done
unset _f

# A draft over tickets 10 (3 min), 11 (blocked by 10, 5 min), 12 (4 min, alone).
write_hands_on_draft() { # hands_on-json
  jq -n --argjson h "$1" '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["10", "11", "12"],
    waves: [["10", "12"], ["11"]], hands_on: $h,
    tickets: {
      "10": {title: "Schema", blocked_by: [], model: "claude-sonnet-5-5", expected_output: "x", expected: {minutes: 3, input_tokens: 1000, output_tokens: 1000}},
      "11": {title: "Endpoint", model: "claude-sonnet-5-5", expected_output: "x", expected: {minutes: 5, input_tokens: 1000, output_tokens: 1000}, blocked_by: ["10"]},
      "12": {title: "Docs", blocked_by: [], model: "claude-sonnet-5-5", expected_output: "x", expected: {minutes: 2, input_tokens: 1000, output_tokens: 1000}}}}' \
    >"$TEST_TMPDIR/draft.json"
}

build_plan() {
  [ -d "${PROJECT:-/nonexistent}" ] || make_project
  (cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json" --history /nonexistent) >"$TEST_TMPDIR/plan.json"
}

test_h_an_off_critical_path_pick_names_its_focus_and_costs_nothing() {
  write_hands_on_draft '{"ticket": "12", "focus": "finding the best solution"}'
  build_plan
  assert_eq 12 "$(jq -r .hands_on.ticket "$TEST_TMPDIR/plan.json")"
  assert_eq false "$(jq -r .hands_on.on_critical_path "$TEST_TMPDIR/plan.json")"
  assert_eq 0 "$(jq -r .hands_on.delay_minutes "$TEST_TMPDIR/plan.json")"
  local out
  out=$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Hands-on ticket"
  assert_contains "$out" "| #12 (Docs) | finding the best solution | no (slack 6 min) | none |"
  assert_contains "$out" "the run is not delayed"
}

test_h_a_critical_path_pick_shows_the_delay_before_confirming() {
  write_hands_on_draft '{"ticket": "10", "focus": "understanding the problem", "minutes": 20}'
  build_plan
  assert_eq true "$(jq -r .hands_on.on_critical_path "$TEST_TMPDIR/plan.json")"
  # 20 hands-on minutes against 3 for a worker, no slack: 17 minutes later.
  assert_eq 17 "$(jq -r .hands_on.delay_minutes "$TEST_TMPDIR/plan.json")"
  assert_eq '["11"]' "$(jq -c .hands_on.dependents "$TEST_TMPDIR/plan.json")"
  local out
  out=$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "| #10 (Schema) | understanding the problem | yes | about 17 min later |"
  assert_contains "$out" "about 17 minutes later, and #11 waits for it. Confirm the delay, or choose a ticket off the critical path."
}

test_h_at_most_one_hands_on_ticket_with_a_focus_in_scope() {
  write_hands_on_draft '[{"ticket": "10", "focus": "a"}, {"ticket": "12", "focus": "b"}]'
  make_project
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --history /nonexistent"
  write_hands_on_draft '{"ticket": "12"}'
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --history /nonexistent"
  write_hands_on_draft '{"ticket": "99", "focus": "a"}'
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --history /nonexistent"
  write_hands_on_draft 'null'
  build_plan
  assert_eq null "$(jq -c '.hands_on // null' "$TEST_TMPDIR/plan.json")"
}

test_h_suggest_lists_only_what_can_be_taken_without_delay() {
  write_hands_on_draft null
  local out
  out=$("$SCRIPTS/human.sh" suggest --draft "$TEST_TMPDIR/draft.json")
  assert_contains "$out" "At most one hands-on ticket per plan"
  assert_contains "$out" "| #12 (Docs) | 6 | 2 | 6 | 0 |"
  assert_contains "$out" "| #10 (Schema) | 0 | 3 | 9 | 6 |"
  assert_contains "$out" "Eligible (delay 0): #12."
}

# Ticket 1 is the hands-on ticket (labelled ready-for-human); 2 waits on it.
human_run() {
  setup_wave '["1","2"]'
  jq '.labels = [{name: "ready-for-human"}]' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/i.tmp" && mv "$FAKE_GH_DIR/i.tmp" "$FAKE_GH_DIR/issue-1.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["2"].blocked_by = ["1"]'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
}

hands_on_commit() { # file
  local wt
  wt=$(state_get '.tickets["1"].human.worktree')
  echo hi >"$wt/${1:-hello.txt}"
  git_quiet -C "$wt" add -A
  git_quiet -C "$wt" commit -m "by hand"
}

test_h_a_ready_for_human_ticket_gets_a_worktree_and_is_not_dispatched() {
  human_run
  assert_eq "" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR")" "no frontier: ticket 1 is held, 2 is blocked"
  local out wt
  out=$("$SCRIPTS/human.sh" sync "$RUN_DIR")
  wt="$TEST_TMPDIR/project-wt/r1-1.human"
  assert_eq "#1 $wt" "$out"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(git -C "$wt" rev-parse HEAD)" "from the integration tip"
  assert_eq agent/1 "$(git -C "$wt" symbolic-ref --short HEAD)"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  # Setting up twice changes nothing.
  assert_eq "" "$("$SCRIPTS/human.sh" sync "$RUN_DIR")"
  # Never dispatched to a worker, even with the label gone; its dependent waits.
  assert_status 1 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1
  jq '.labels = []' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/i.tmp" && mv "$FAKE_GH_DIR/i.tmp" "$FAKE_GH_DIR/issue-1.json"
  assert_eq "" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR")" "still held once its worktree is set up"
  assert_status 5 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
  ls "$RUN_DIR/workers" 2>/dev/null | grep -q . && fail "a worker was started"
  true
}

test_h_the_run_parks_and_names_the_ticket_when_only_work_behind_it_remains() {
  human_run
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  local out
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked: waiting on the Artisan's hands-on ticket #1 (Add hello); 1 ticket(s) wait behind it: #2"
  assert_eq "parked" "$(state_get '[.events[] | select(.event == "parked")] | last | .event')"
  # Asking again records nothing more.
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked")] | length')"
}

test_h_done_is_refused_without_a_commit_and_with_uncommitted_work() {
  human_run
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  assert_status 6 "$SCRIPTS/human.sh" done "$RUN_DIR" 1
  echo hi >"$(state_get '.tickets["1"].human.worktree')/hello.txt"
  assert_status 6 "$SCRIPTS/human.sh" done "$RUN_DIR" 1
  assert_eq queued "$(state_get '.tickets["1"].status')"
}

test_h_done_goes_through_the_verifier_the_suite_and_the_serial_merge() {
  human_run
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  hands_on_commit
  local out
  out=$("$SCRIPTS/human.sh" done "$RUN_DIR" 1)
  assert_contains "$out" "awaiting its verifier"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  # The same verifier as a worker's ticket, then the merge behind the suite.
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  assert_eq "pass 2/2" "$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1)"
  # The Artisan sees the verdict.
  out=$("$SCRIPTS/human.sh" verdict "$RUN_DIR" 1)
  assert_contains "$out" "pass, 2/2 criteria met"
  assert_contains "$out" "| hello.txt exists | yes |"
  local sha
  sha=$("$SCRIPTS/wave.sh" merge "$RUN_DIR" 1)
  assert_eq "$sha" "$(state_get '.tickets["1"].merge_commit')"
  assert_eq true "$(state_get '.tickets["1"].suite.passed')"
  "$SCRIPTS/wave.sh" close "$RUN_DIR" 1
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  [ ! -d "$TEST_TMPDIR/project-wt/r1-1.human" ] || fail "the hands-on worktree was left behind"
  # Its dependent is released.
  assert_eq 2 "$("$SCRIPTS/reconcile.sh" "$RUN_DIR")"
  assert_eq "" "$("$SCRIPTS/human.sh" parked "$RUN_DIR" 2>&1 || true)"
}

test_h_a_failed_verdict_goes_back_to_the_artisan_not_to_a_worker() {
  human_run
  export VERIFIER_UNMET="It says hi"
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  hands_on_commit
  "$SCRIPTS/human.sh" done "$RUN_DIR" 1 >/dev/null
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  local rc=0 out
  out=$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1) || rc=$?
  assert_eq 6 "$rc"
  assert_contains "$out" "fail 1/2 human: It says hi"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq '["It says hi"]' "$(jq -c '.tickets["1"].human.feedback[0].unmet' "$RUN_DIR/state.json")"
  assert_contains "$("$SCRIPTS/human.sh" verdict "$RUN_DIR" 1)" "| It says hi | no | not in the diff |"
  assert_contains "$("$SCRIPTS/human.sh" status "$RUN_DIR")" "needs changes after the verifier"
  assert_status 1 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1   # not returned: nothing merges
  # Still the Artisan's: the worktree stays and no worker was started.
  [ -d "$TEST_TMPDIR/project-wt/r1-1.human" ] || fail "the worktree was removed"
  [ ! -d "$RUN_DIR/workers/1.2" ] || fail "a worker was started"
  # Fixed and said done again: a second round, verified afresh.
  unset VERIFIER_UNMET
  hands_on_commit more.txt
  "$SCRIPTS/human.sh" done "$RUN_DIR" 1 >/dev/null
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq 2 "$(state_get '.tickets["1"].attempts')"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.2.exit.json" 30
  assert_eq "pass 2/2" "$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1)"
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
}

test_h_done_while_a_wave_holds_the_lock_is_filed_and_taken_later() {
  human_run
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  hands_on_commit
  local other rc=0
  other=$(start_worker)
  "$SCRIPTS/state.sh" unlock "$RUN_DIR" "$CHAT" 2>/dev/null || true
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$other"
  ARTISAN_WRITER_PID=$CHAT "$SCRIPTS/human.sh" done "$RUN_DIR" 1 >/dev/null 2>&1 || rc=$?
  assert_eq 3 "$rc"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  [ -f "$RUN_DIR/human/1.done" ] || fail "the request was not filed"
  "$SCRIPTS/state.sh" unlock "$RUN_DIR" "$other"
  ARTISAN_WRITER_PID=$CHAT "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  assert_eq returned "$(state_get '.tickets["1"].status')"
}

# The plan drafted through resolve-scope.sh: ticket 2 is blocked by 1 on the
# fake tracker, and the draft copies each ticket's blocked_by from its output.
scoped_plan() { # hands_on-json
  setup_wave '["1","2"]'
  local scope
  scope=$("$SCRIPTS/resolve-scope.sh" --repo local/sample 1 2)
  jq -n --argjson h "$1" --argjson s "$scope" '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2"],
    waves: [["1"], ["2"]], hands_on: $h,
    tickets: ($s.tickets | map({key: (.number | tostring), value: {
      title, blocked_by: (.blocked_by | map(tostring)), model: "claude-sonnet-5-5", expected_output: "x",
      expected: {minutes: 5, input_tokens: 1000, output_tokens: 1000}}}) | from_entries)}' >"$TEST_TMPDIR/draft.json"
  build_plan
}

test_h_a_pick_on_the_critical_path_is_critical_with_a_delay_when_blocked_by_comes_from_resolve_scope() {
  scoped_plan '{"ticket": "1", "focus": "the hard part", "minutes": 20}'
  assert_eq '["1"]' "$(jq -c '.tickets["2"].blocked_by' "$TEST_TMPDIR/plan.json")"
  assert_eq true "$(jq -r .hands_on.on_critical_path "$TEST_TMPDIR/plan.json")"
  assert_eq 15 "$(jq -r .hands_on.delay_minutes "$TEST_TMPDIR/plan.json")"
  assert_contains "$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan.json")" "| #1 (Add hello) | the hard part | yes | about 15 min later |"
}

test_h_a_run_with_only_the_hands_on_ticket_and_its_dependents_parks_from_a_resolve_scope_plan() {
  scoped_plan '{"ticket": "1", "focus": "the hard part"}'
  jq '.labels = [{name: "ready-for-human"}]' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/i.tmp" && mv "$FAKE_GH_DIR/i.tmp" "$FAKE_GH_DIR/issue-1.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" ".plan.tickets = $(jq -c '.tickets' "$TEST_TMPDIR/plan.json")"
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  "$SCRIPTS/human.sh" sync "$RUN_DIR" >/dev/null
  local out
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "hands-on ticket #1"
}
