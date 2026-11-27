# plan.sh build sets plan.tickets.<t>.priority from the approved order (#416):
# the draft's scope order (plan order, then listed order), with tickets the
# draft marks "ci": true first (the owner rule that CI work goes ahead). The
# reconciler sorts the frontier by priority, highest first, so the first
# ticket gets 0 and each later one a step lower: tickets lever.sh add records
# (priority 1, urgent 2) still sort ahead of every planned one.

. "$TESTS_DIR/helpers/run-state.sh"

plan() { "$SCRIPTS/plan.sh" "$@"; }

# build_draft [jq filter on the draft]: tickets 30, 10, 20 in that scope order.
build_draft() {
  jq -n '
    def t($n): {title: "Ticket \($n)", model: "claude-sonnet-5-5", blocked_by: [],
                acceptance: ["t\($n).txt exists"], expected_output: "t\($n).txt", expected_files: ["t\($n).txt"],
                expected: {input_tokens: 100000, output_tokens: 10000, minutes: 10}};
    {run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
     scope: ["30", "10", "20"], waves: [["30", "10", "20"]],
     gates: [{kind: "slice", tickets: ["30", "10", "20"]}, {kind: "end"}],
     tickets: {"30": t(30), "10": t(10), "20": t(20)}}' >"$TEST_TMPDIR/draft.json"
  if [ -n "${1:-}" ]; then
    jq "$1" "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2"
    mv "$TEST_TMPDIR/d2" "$TEST_TMPDIR/draft.json"
  fi
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json" || fail "build refused the draft"
}

prios() { jq -c '[.scope[] as $t | .tickets[$t].priority]' "$TEST_TMPDIR/plan.json"; }

test_priority_follows_scope_order_not_ticket_number() {
  make_project
  build_draft
  assert_eq '[0,-1,-2]' "$(prios)"
}

test_ci_tickets_go_first_then_scope_order() {
  make_project
  build_draft '.tickets["20"].ci = true'
  assert_eq '[-1,-2,0]' "$(prios)"
}

test_a_priority_the_draft_sets_is_kept() {
  make_project
  build_draft '.tickets["10"].priority = -7'
  assert_eq '[0,-7,-2]' "$(prios)"
}

test_no_planned_priority_is_above_zero_so_added_tickets_stay_ahead() {
  make_project
  build_draft '.tickets["20"].ci = true'
  assert_eq 0 "$(jq '[.tickets[].priority | select(. > 0)] | length' "$TEST_TMPDIR/plan.json")"
}
