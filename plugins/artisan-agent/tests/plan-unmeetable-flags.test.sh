# plan.sh build flags the criteria a headless worker can't meet before dispatch
# (#424): one that reads as needing the running app (the config's
# running_app_phrases) and one that cites another ticket of the plan the ticket
# is not blocked by. Both are warnings: the plan stays approvable.

. "$TESTS_DIR/helpers/run-state.sh"

plan() { "$SCRIPTS/plan.sh" "$@"; }

# build_draft [jq filter]: tickets 10 and 20, no edge between them.
build_draft() {
  jq -n '
    def t($n): {title: "Ticket \($n)", model: "claude-sonnet-5-5", blocked_by: [],
                acceptance: ["t\($n).txt exists"], expected_output: "t\($n).txt", expected_files: ["t\($n).txt"],
                expected: {input_tokens: 100000, output_tokens: 10000, minutes: 10}};
    {run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
     scope: ["10", "20"], waves: [["10", "20"]],
     gates: [{kind: "slice", tickets: ["10", "20"]}, {kind: "end"}],
     tickets: {"10": t(10), "20": t(20)}}' >"$TEST_TMPDIR/draft.json"
  jq "${1:-.}" "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2"
  mv "$TEST_TMPDIR/d2" "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json" || fail "build refused the draft"
}

test_a_criterion_with_a_configured_running_app_phrase_is_flagged() {
  make_project
  printf 'running_app_phrases: [with KSP running]\n' >>"$PROJECT/.artisan-agent/config.yml"
  build_draft '.tickets["10"].acceptance = ["Mun slopes read 12 degrees with KSP running"]'
  assert_eq '[{"ticket":"10","criterion":"Mun slopes read 12 degrees with KSP running","phrase":"with KSP running"}]' \
    "$(jq -c .running_app_flags "$TEST_TMPDIR/plan.json")"
  local out; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Criteria that may need the running app"
  assert_contains "$out" "| #10 (Ticket 10) | Mun slopes read 12 degrees with KSP running | \"with KSP running\" |"
  assert_contains "$out" "Approve as shown"
}

test_no_phrases_configured_flags_nothing() {
  make_project
  build_draft '.tickets["10"].acceptance = ["Mun slopes read 12 degrees with KSP running"]'
  assert_eq '[]' "$(jq -c .running_app_flags "$TEST_TMPDIR/plan.json")"
  assert_not_contains "$(plan render "$TEST_TMPDIR/plan.json")" "running app"
}

test_a_criterion_citing_a_ticket_with_no_blocking_edge_is_flagged() {
  make_project
  build_draft '.tickets["20"].acceptance = ["uses the table from #10"]'
  assert_eq '[{"ticket":"20","criterion":"uses the table from #10","needs":"10"}]' \
    "$(jq -c .undeclared_dependency_flags "$TEST_TMPDIR/plan.json")"
  local out; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "| #20 (Ticket 20) | uses the table from #10 | #10 (Ticket 10) |"
  assert_contains "$out" "Approve as shown"
}

test_a_declared_or_transitive_edge_or_a_self_cite_is_not_flagged() {
  make_project
  build_draft '.tickets["20"].blocked_by = ["10"] | .tickets["20"].acceptance = ["uses the table from #10", "#20 stays quiet"]'
  assert_eq '[]' "$(jq -c .undeclared_dependency_flags "$TEST_TMPDIR/plan.json")"
}
