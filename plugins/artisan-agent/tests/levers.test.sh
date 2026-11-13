# lever.sh and its neighbours (#76): steering a worker (stop and redispatch with
# the Artisan's notes, recorded as steering and not as a failed attempt),
# adding work to a running run (one-line approval, joins the next wave ahead of
# lower-priority tickets, grows the run budget), and urgent tickets (dispatch
# at once on the one extra slot, from main, own end gate and PR, then main is
# merged into the integration branch with the full suite green). Fake `claude`
# and fake `gh`; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

L="$PLUGIN_ROOT/scripts/lever.sh"
W="$PLUGIN_ROOT/scripts/wave.sh"
E="$PLUGIN_ROOT/scripts/end-gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# A project whose suite (check.sh) fails when a file named BROKEN exists, a
# fake tracker with tickets 1 to 4, and a run r1 over SCOPE (default ["1"]).
setup_levers() { # scope-json
  make_project
  printf '#!/bin/sh\n[ ! -e BROKEN ] && echo "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  MAIN_HEAD=$(git -C "$PROJECT" rev-parse HEAD)

  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3 4; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}], body: "- [ ] it works"}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done

  jq -n --argjson scope "${1:-[\"1\"]}" '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: $scope,
    max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh",
    estimate_usd: 0.5, budget_usd: 0.625,
    tickets: {
      "1": {title: "Add hello", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, expected_files: ["a/"],
            caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}},
      "2": {title: "Add goodbye", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, expected_files: ["b/"],
            caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"

  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script FAKE_CLAUDE_LOG="$TEST_TMPDIR/fake-claude.log"
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
sleep "${WORKER_SLEEP:-0}"
echo hi >"${WORKER_FILE:-hello.txt}"
git add -A && git commit -q --allow-empty -m "worker"
jq -n --arg c "$(git rev-parse HEAD)" '{ticket: "1", status: "complete", commit: $c,
  acceptance: [{criterion: "it works", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true}, unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
EOF
  "$W" start "$RUN_DIR" >/dev/null
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  export ARTISAN_MAIN_BRANCH=main
  trap cleanup EXIT
}

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-30} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

# ----------------------------------------------------------------- steering

test_steering_stops_the_worker_and_redispatches_it_with_the_notes_not_as_a_failed_attempt() {
  setup_levers
  export WORKER_SLEEP=30
  "$W" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/workers/1.1/runner.pid"
  local wt=
  wt=$(state_get '.tickets["1"].worktree')
  echo half >"$wt/half.txt"      # work the worker had not committed
  "$L" steer "$RUN_DIR" 1 --note "Use the existing parser; do not write a new one" >"$TEST_TMPDIR/out"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "not a failed attempt"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')" "steering is not a failure"
  assert_eq "Use the existing parser; do not write a new one" "$(state_get '.tickets["1"].steering[0].note')"
  assert_eq 1 "$(state_get '.tickets["1"].steering[0].attempt')"
  assert_eq steered "$(state_get '[.events[] | select(.event == "steered")] | first | .event')"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "failed")] | length')"
  assert_contains "$(git -C "$PROJECT" log --format=%s agent/1)" "WIP: stopped for steering"
  # Redispatched: attempt 2, with the notes in its prompt, on the same branch.
  export WORKER_SLEEP=0
  "$W" dispatch "$RUN_DIR" 1 >/dev/null
  assert_eq 2 "$(state_get '.tickets["1"].attempts')"
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "Use the existing parser; do not write a new one"
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "not a failed attempt"
  wait_for "$RUN_DIR/results/1.2.exit.json" 60
}

test_steering_a_ticket_that_is_not_in_flight_is_refused() {
  setup_levers
  assert_status 6 "$L" steer "$RUN_DIR" 1 --note "x"
}

test_while_a_wave_holds_the_lock_the_orchestrators_sweep_records_the_steering() {
  setup_levers
  export WORKER_SLEEP=30
  "$W" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/workers/1.1/runner.pid"
  local orch=
  orch=$(start_worker)
  "$SCRIPTS/state.sh" unlock "$RUN_DIR"
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$orch"
  local rc=0
  ( unset ARTISAN_WRITER_PID; "$L" steer "$RUN_DIR" 1 --note "go slower" >"$TEST_TMPDIR/out" ) || rc=$?
  assert_eq 0 "$rc"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "orchestrator holds the state lock"
  assert_eq in_flight "$(state_get '.tickets["1"].status')" "not written while another process holds the lock"
  ARTISAN_WRITER_PID=$orch "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')"
  assert_eq "go slower" "$(state_get '.tickets["1"].steering[0].note')"
}

# ------------------------------------------------------------------ adding

test_adding_work_shows_a_one_line_approval_and_records_nothing_until_approved() {
  setup_levers
  local before=
  before=$(state_sum)
  local out=
  out=$("$L" add "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.4 --title "Fix the parser")
  assert_contains "$out" 'Add #3 (Fix the parser): claude-sonnet-5-5, estimate $0.4, run budget $0.625 -> $1.13'
  assert_eq "$before" "$(state_sum)" "nothing recorded before approval"
}

test_an_approved_addition_joins_the_scope_and_the_budget_includes_both_estimates() {
  setup_levers
  "$L" add "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.4 --title "Fix the parser" --approve >/dev/null
  assert_eq '["1","3"]' "$(jq -c '.plan.scope' "$RUN_DIR/state.json")"
  assert_eq 0.9 "$(state_get '.plan.estimate_usd')"
  assert_eq 1.13 "$(state_get '.plan.budget_usd')"
  assert_eq 0.625 "$(state_get '.plan.additions[0].budget_before')"
  assert_eq queued "$(state_get '.tickets["3"].status')"
  assert_eq 0.8 "$(state_get '.plan.tickets["3"].caps.max_budget_usd')"
  assert_eq work-added "$(state_get '.events[-1].event')"
  # The budget projection counts both.
  assert_eq 0.65 "$("$SCRIPTS/budget.sh" project "$RUN_DIR" | jq -r '.to_come')"
  # Again: idempotent.
  local before=
  before=$(state_sum)
  assert_status 6 "$L" add "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.4 --approve
  assert_eq "$before" "$(state_sum)"
}

test_a_ticket_added_mid_run_dispatches_in_the_next_wave_ahead_of_lower_priority_tickets() {
  setup_levers '["1","2"]'
  "$L" add "$RUN_DIR" 4 --model claude-sonnet-5-5 --estimate-usd 0.25 --approve >/dev/null
  assert_eq "4 1 2" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')" "the added ticket leads the frontier"
  # An explicit lower priority than a later addition sorts below it.
  "$L" add "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.25 --priority 5 --approve >/dev/null
  assert_eq "3 4 1 2" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
}

test_an_addition_made_while_a_wave_holds_the_lock_joins_at_the_orchestrators_sweep() {
  setup_levers
  local orch=
  orch=$(start_worker)
  "$SCRIPTS/state.sh" unlock "$RUN_DIR"
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$orch"
  ( unset ARTISAN_WRITER_PID; "$L" add "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.4 --approve >"$TEST_TMPDIR/out" )
  assert_contains "$(cat "$TEST_TMPDIR/out")" "orchestrator holds the state lock"
  assert_eq '["1"]' "$(jq -c '.plan.scope' "$RUN_DIR/state.json")"
  ARTISAN_WRITER_PID=$orch "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard
  assert_eq '["1","3"]' "$(jq -c '.plan.scope' "$RUN_DIR/state.json")"
  assert_eq 1.13 "$(state_get '.plan.budget_usd')"
  ARTISAN_WRITER_PID=$orch "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard
  assert_eq 1.13 "$(state_get '.plan.budget_usd')" "a second sweep adds nothing"
}

# ------------------------------------------------------------------ urgent

test_an_urgent_ticket_dispatches_at_once_on_an_extra_slot_from_main() {
  setup_levers '["1","2"]'
  export WORKER_SLEEP=30
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 1'
  "$W" dispatch "$RUN_DIR" 1 >/dev/null          # Max Agents is full
  assert_status 9 "$W" dispatch "$RUN_DIR" 2
  git_quiet -C "$PROJECT" commit --allow-empty -m "main moves on"
  "$L" urgent "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.4 --title "Hotfix" >"$TEST_TMPDIR/out"
  assert_contains "$(cat "$TEST_TMPDIR/out")" 'Urgent #3 (Hotfix): claude-sonnet-5-5, estimate $0.4, run budget $0.625 -> $1.13'
  assert_eq 1.13 "$(state_get '.plan.budget_usd')" "marking it urgent is its approval, and its estimate joins the budget"
  assert_eq 3 "$("$L" pending "$RUN_DIR")"
  "$W" dispatch "$RUN_DIR" 3 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["3"].status')"
  assert_eq "$(git -C "$PROJECT" rev-parse main)" "$(state_get '.tickets["3"].base')" "branched from main, not the integration branch"
  assert_contains "$(cat "$RUN_DIR/prompts/3.1.md")" "urgent"
  assert_eq "" "$("$L" pending "$RUN_DIR")"
  # Max Agents did not change for planned work: still full without the urgent slot.
  assert_status 9 "$W" dispatch "$RUN_DIR" 2
}

test_a_second_urgent_ticket_waits_for_the_slot() {
  setup_levers
  export WORKER_SLEEP=30
  "$L" urgent "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.25 >/dev/null
  "$L" urgent "$RUN_DIR" 4 --model claude-sonnet-5-5 --estimate-usd 0.25 >/dev/null
  "$W" dispatch "$RUN_DIR" 3 >/dev/null
  local rc=0
  "$W" dispatch "$RUN_DIR" 4 >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 9 "$rc"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "urgent slot is taken"
  assert_eq queued "$(state_get '.tickets["4"].status')"
  assert_eq 4 "$("$L" pending "$RUN_DIR")"
  # Once the first has left the slot, the second dispatches.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].status = "returned"'
  "$W" dispatch "$RUN_DIR" 4 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["4"].status')"
}

test_an_urgent_ticket_is_never_on_the_frontier_and_never_merges_into_the_integration_branch() {
  setup_levers
  "$L" urgent "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.25 >/dev/null
  assert_eq 1 "$("$SCRIPTS/reconcile.sh" "$RUN_DIR")"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].status = "returned"'
  local rc=0
  "$W" merge "$RUN_DIR" 3 >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 6 "$rc"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "own end gate"
}

# An urgent ticket 3 whose work (agent/3, from main) has returned and passed
# verification, with the run's integration branch already moved on by ticket 1.
setup_urgent_returned() {
  setup_levers
  "$L" urgent "$RUN_DIR" 3 --model claude-sonnet-5-5 --estimate-usd 0.25 --title "Hotfix" >/dev/null
  git_quiet -C "$PROJECT" branch agent/3 main
  git_quiet -C "$PROJECT" worktree add "$TEST_TMPDIR/w3" agent/3
  echo fix >"$TEST_TMPDIR/w3/fix.txt"
  git_quiet -C "$TEST_TMPDIR/w3" add -A
  git_quiet -C "$TEST_TMPDIR/w3" commit -m "the hotfix"
  URGENT_TIP=$(git -C "$PROJECT" rev-parse agent/3)
  # Ticket 1 merged into the integration branch meanwhile.
  local wt=$TEST_TMPDIR/project-wt/run-r1
  echo one >"$wt/one.txt"
  git_quiet -C "$wt" add -A
  git_quiet -C "$wt" commit -m "ticket 1"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"] += {status: "returned", attempts: 1, base: $b,
      evidence: {verdict: "pass", attempt: 1, commit: $tip, acceptance: [{criterion: "it works", met: true, evidence: {tests: ["check.sh"]}}]}}
    | .tickets["1"].status = "merged"' --arg tip "$URGENT_TIP" --arg b "$MAIN_HEAD"
}

test_the_urgent_ticket_ships_through_its_own_end_gate_and_pr_scoped_to_it_and_based_on_main() {
  setup_urgent_returned
  local packet=
  packet=$("$E" urgent-packet "$RUN_DIR" 3)
  assert_contains "$packet" "End gate: urgent #3 (run r1)"
  assert_contains "$packet" "Hotfix"
  case "$packet" in *"#1 ("*|*"| #1 |"*) fail "the packet lists another ticket: $packet" ;; esac
  assert_contains "$packet" "One PR for #3 alone"
  # Not before it has returned with a passing verdict.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].evidence.verdict = "fail"'
  assert_status 6 "$E" urgent-open "$RUN_DIR" 3
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].evidence.verdict = "pass"'
  local issue=
  issue=$("$E" urgent-open "$RUN_DIR" 3)
  assert_eq "$issue" "$("$E" urgent-open "$RUN_DIR" 3)" "opening twice finds the same issue"
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-$issue.json")" "End gate: urgent #3 (run r1)"
  assert_eq open "$(state_get '.urgent_gates["3"].status')"
  assert_eq "end-gate urgent-3 waiting" "$(state_get '.decisions[-1] | "\(.kind) \(.gate) \(.status)"')"
  # No PR before approval.
  printf 'body from pr\n' >"$TEST_TMPDIR/body.md"
  assert_status 6 "$E" urgent-cut "$RUN_DIR" 3 --body-file "$TEST_TMPDIR/body.md"
  "$E" urgent-approve "$RUN_DIR" 3 --why "ship it" >/dev/null
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-$issue.json")"
  assert_eq decided "$(state_get '.decisions[-1].status')"
  local url=
  url=$("$E" urgent-cut "$RUN_DIR" 3 --body-file "$TEST_TMPDIR/body.md")
  assert_eq "$url" "$("$E" urgent-cut "$RUN_DIR" 3 --body-file "$TEST_TMPDIR/body.md")" "cutting twice gives the same PR"
  local pr="$FAKE_GH_DIR/pr-1.json"
  assert_eq main "$(jq -r .base "$pr")"
  assert_eq pr/r1/urgent-3 "$(jq -r .head "$pr")"
  assert_eq "body from pr" "$(jq -r .body "$pr")"
  assert_eq "$URGENT_TIP" "$(git -C "$PROJECT" rev-parse pr/r1/urgent-3)" "the PR is the urgent ticket's own work, not the integration branch"
}

test_after_the_urgent_pr_merges_main_joins_the_integration_branch_with_the_full_suite_green() {
  setup_urgent_returned
  "$E" urgent-open "$RUN_DIR" 3 >/dev/null
  "$E" urgent-approve "$RUN_DIR" 3 >/dev/null
  printf 'b\n' >"$TEST_TMPDIR/body.md"
  "$E" urgent-cut "$RUN_DIR" 3 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  # Not while the PR is open.
  assert_status 6 "$E" urgent-finish "$RUN_DIR" 3
  # The Artisan merges it on GitHub (here: into main, locally).
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge PR 1" agent/3
  local merge_oid=
  merge_oid=$(git -C "$PROJECT" rev-parse main)
  jq --arg o "$merge_oid" '.state = "MERGED" | .merge_oid = $o' "$FAKE_GH_DIR/pr-1.json" >"$TEST_TMPDIR/pr" && mv "$TEST_TMPDIR/pr" "$FAKE_GH_DIR/pr-1.json"
  "$E" urgent-finish "$RUN_DIR" 3 >"$TEST_TMPDIR/out"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "full suite green"
  local wt=$TEST_TMPDIR/project-wt/run-r1
  [ -f "$wt/fix.txt" ] || fail "main's work is not in the integration branch"
  [ -f "$wt/one.txt" ] || fail "the integration branch lost its own work"
  git -C "$PROJECT" merge-base --is-ancestor main run/r1 || fail "main is not in the integration branch"
  (cd "$wt" && sh check.sh >/dev/null) || fail "suite red on the integration branch"
  assert_eq merged "$(state_get '.tickets["3"].status')"
  assert_eq "$merge_oid" "$(state_get '.tickets["3"].merge_commit')"
  assert_eq true "$(state_get '.tickets["3"].suite.passed')"
  assert_eq ended "$(state_get '.urgent_gates["3"].status')"
  assert_eq 0 "$(state_get '[.integration.merges[] | select(.ticket == "3")] | length')" "never merged as a ticket of the run's own PRs"
  assert_eq "" "$(jq -r '.labels[].name | select(. == "in-run")' "$FAKE_GH_DIR/issue-3.json" 2>/dev/null)"
  assert_contains "$("$E" urgent-finish "$RUN_DIR" 3)" "already shipped"
}

test_a_red_suite_after_main_joins_undoes_the_merge_and_queues_a_decision() {
  setup_urgent_returned
  "$E" urgent-open "$RUN_DIR" 3 >/dev/null
  "$E" urgent-approve "$RUN_DIR" 3 >/dev/null
  printf 'b\n' >"$TEST_TMPDIR/body.md"
  "$E" urgent-cut "$RUN_DIR" 3 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  : >"$TEST_TMPDIR/w3/BROKEN"
  git_quiet -C "$TEST_TMPDIR/w3" add -A
  git_quiet -C "$TEST_TMPDIR/w3" commit -m "breaks the suite when combined"
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge PR 1" agent/3
  jq '.state = "MERGED"' "$FAKE_GH_DIR/pr-1.json" >"$TEST_TMPDIR/pr" && mv "$TEST_TMPDIR/pr" "$FAKE_GH_DIR/pr-1.json"
  local before=
  before=$(git -C "$PROJECT" rev-parse run/r1)
  assert_status 7 "$E" urgent-finish "$RUN_DIR" 3
  assert_eq "$before" "$(git -C "$PROJECT" rev-parse run/r1)" "the merge was undone"
  assert_eq "exception waiting" "$(state_get '.decisions[-1] | "\(.kind) \(.status)"')"
  assert_eq approved "$(state_get '.urgent_gates["3"].status')" "not shipped until the suite is green"
}

test_the_runs_own_prs_leave_out_the_urgent_ticket() {
  setup_urgent_returned
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].merge_commit = "abc" | .tickets["3"].status = "merged"
    | .tickets["1"].merge_commit = $c | .integration.merges = []
    | .end_gate = {status: "approved", boundary: {value: "ticket"}}' --arg c "$(git -C "$PROJECT" rev-parse run/r1)"
  assert_eq "1" "$("$E" prs "$RUN_DIR" --json | jq -r '[.[].tickets[]] | join(",")')"
}
