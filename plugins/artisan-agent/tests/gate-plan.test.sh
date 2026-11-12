# gate-plan.sh (#71): the plan step proposes one slice gate per slice, a
# risk gate per ticket meeting an escalation test and the end gate; the
# Artisan moves or removes any of them, never an exception gate. A Small
# change or Bug has no slice gate: its end gate doubles as one.

GP="$PLUGIN_ROOT/scripts/gate-plan.sh"

draft() { # route
  jq -n --arg route "$1" '{run_id: "r1", repo: "o/r", integration_branch: "run/r1", route: $route,
    scope: ["1", "2", "3"], waves: [["1"], ["2", "3"]],
    tickets: {
      "1": {title: "export seam", slice: "export", escalation: ["new-seam"]},
      "2": {title: "CSV header", slice: "export"},
      "3": {title: "billing tab", slice: "billing", escalation: ["judgement-criteria", "vocabulary-adr"]}}}' >draft.json
}

test_propose_places_a_slice_gate_per_slice_every_risk_gate_and_the_end_gate() {
  draft feature
  "$GP" propose draft.json >out.md
  assert_eq '[{"kind":"slice","slice":"export"},{"kind":"slice","slice":"billing"},{"kind":"risk","after":"1","tests":["new-seam"]},{"kind":"risk","after":"3","tests":["judgement-criteria","vocabulary-adr"]},{"kind":"end"}]' \
    "$(jq -c .gates draft.json)"
  assert_contains "$(cat out.md)" "| Gate | Kind | Opens after | Why | Can be removed |"
  assert_contains "$(cat out.md)" "| slice-1 | slice | #1 (export seam), #2 (CSV header) merge | the slice export is reviewable end to end | yes |"
  assert_contains "$(cat out.md)" "| risk-3 | risk | #1 (export seam) merges | new seam or module boundary | yes |"
  assert_contains "$(cat out.md)" "| risk-4 | risk | #3 (billing tab) merges | judgement-like acceptance criteria, change to vocabulary or an ADR | yes |"
  assert_contains "$(cat out.md)" "| end | end | every ticket in scope is done | the end gate, before the PRs to main | yes |"
  assert_contains "$(cat out.md)" "Exception gates are never placed here"
}

test_a_ticket_with_no_slice_is_its_own_slice() {
  draft feature
  jq '.tickets["3"] |= del(.slice)' draft.json >d && mv d draft.json
  "$GP" propose draft.json >/dev/null
  assert_eq '{"kind":"slice","after":"3"}' "$(jq -c '.gates[1]' draft.json)"
}

test_a_bug_has_one_end_gate_that_doubles_as_the_slice_gate() {
  jq -n '{run_id: "r1", route: "bug", scope: ["7"], tickets: {"7": {title: "crash on empty cart",
    failing_test: "tests/cart.test.sh: test_empty_cart_does_not_crash"}}}' >draft.json
  "$GP" propose draft.json >out.md
  assert_eq '[{"kind":"end","doubles_as_slice":true,"bug":true}]' "$(jq -c .gates draft.json)"
  assert_contains "$(cat out.md)" "| end | end | every ticket in scope is done | the end gate, doubling as the slice gate; it leads with the failing test | yes |"
}

test_a_small_change_meeting_an_escalation_test_keeps_its_risk_gate() {
  jq -n '{run_id: "r1", route: "small-change", scope: ["7"], tickets: {"7": {title: "t", escalation: ["tracer-bullet"]}}}' >draft.json
  "$GP" propose draft.json >/dev/null
  assert_eq '[{"kind":"risk","after":"7","tests":["tracer-bullet"]},{"kind":"end","doubles_as_slice":true}]' "$(jq -c .gates draft.json)"
}

test_an_unknown_escalation_test_is_refused() {
  draft feature
  jq '.tickets["1"].escalation = ["looks-hard"]' draft.json >d && mv d draft.json
  assert_status 2 "$GP" propose draft.json
}

test_the_artisan_removes_slice_risk_and_end_gates() {
  draft feature
  "$GP" propose draft.json >/dev/null
  "$GP" remove draft.json risk-3 >/dev/null
  "$GP" remove draft.json end >/dev/null
  "$GP" remove draft.json slice-2 >/dev/null
  assert_eq '[{"kind":"slice","slice":"export"},{"kind":"risk","after":"3","tests":["judgement-criteria","vocabulary-adr"]}]' "$(jq -c .gates draft.json)"
}

test_an_exception_gate_can_never_be_removed() {
  draft feature
  "$GP" propose draft.json >/dev/null
  local before err
  before=$(jq -c .gates draft.json)
  err=$("$GP" remove draft.json exception-4 2>&1 >/dev/null) && fail "removed an exception gate"
  assert_status 6 "$GP" remove draft.json exception-4
  assert_contains "$err" "exception gates can't be removed"
  assert_eq "$before" "$(jq -c .gates draft.json)"
  assert_status 6 "$GP" remove draft.json slice-9
}

test_the_artisan_moves_a_slice_or_risk_gate() {
  draft feature
  "$GP" propose draft.json >/dev/null
  "$GP" move draft.json slice-1 --after 2 >/dev/null
  "$GP" move draft.json risk-3 --after 2 >/dev/null
  "$GP" move draft.json slice-2 --tickets 2,3 >out.md
  assert_eq '{"kind":"slice","slice":"export","after":"2"}' "$(jq -c '.gates[0]' draft.json)"
  assert_eq '{"kind":"risk","after":"2","tests":["new-seam"]}' "$(jq -c '.gates[2]' draft.json)"
  assert_eq '{"kind":"slice","slice":"billing","tickets":["2","3"]}' "$(jq -c '.gates[1]' draft.json)"
  assert_contains "$(cat out.md)" "| slice-2 | slice | #2 (CSV header), #3 (billing tab) merge |"
  assert_status 6 "$GP" move draft.json slice-1 --after 99
}

test_the_end_gate_has_one_place_and_is_moved_by_removing_it() {
  draft feature
  "$GP" propose draft.json >/dev/null
  local err
  err=$("$GP" move draft.json end --after 1 2>&1 >/dev/null) && fail "moved the end gate"
  assert_contains "$err" "the end gate has one place"
}

test_a_proposal_already_in_the_plan_is_kept_until_the_artisan_reproposes() {
  draft feature
  "$GP" propose draft.json >/dev/null
  "$GP" remove draft.json risk-3 >/dev/null
  "$GP" render draft.json >out.md
  assert_eq 4 "$(jq '.gates | length' draft.json)"
  assert_contains "$(cat out.md)" "| risk-3 | risk | #3 (billing tab) merges |"
}
