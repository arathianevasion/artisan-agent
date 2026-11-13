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
  local before= err=
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
  assert_status 4 "$GP" move draft.json slice-1 --after 99
}

test_the_end_gate_has_one_place_and_is_moved_by_removing_it() {
  draft feature
  "$GP" propose draft.json >/dev/null
  local err=
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

# Areas (#77): per-area gate settings at the plan step.

areas_config() {
  cat >areas.yml <<'YML'
areas:
  billing:
    paths: [src/billing/, db/migrations/]
    gates: [risk]
  export:
    paths: [src/export]
    gates: [slice]
  docs:
    paths: [docs/]
YML
}

# elsewhere: every ticket declares files outside every area, so a test names
# only the tickets it means to put in an area.
elsewhere() { jq '.tickets |= map_values(.expected_files = ["lib/other.sh"])' draft.json >d && mv d draft.json; }

test_with_no_areas_configured_the_proposal_is_unchanged() {
  draft feature
  elsewhere
  jq '.tickets["3"].expected_files = ["src/billing/tab.sh"]' draft.json >d && mv d draft.json
  : >empty.yml
  "$GP" propose draft.json --config empty.yml >out.md
  assert_eq '[{"kind":"slice","slice":"export"},{"kind":"slice","slice":"billing"},{"kind":"risk","after":"1","tests":["new-seam"]},{"kind":"risk","after":"3","tests":["judgement-criteria","vocabulary-adr"]},{"kind":"end"}]' \
    "$(jq -c .gates draft.json)"
  assert_eq 'false' "$(jq 'any(.tickets[]; has("areas"))' draft.json)"
  assert_not_contains "$(cat out.md)" "| Ticket | Areas |"
}

test_a_ticket_belongs_to_every_area_its_expected_files_overlap_and_the_plan_names_them() {
  draft feature
  elsewhere
  areas_config
  jq '.tickets["2"].expected_files = ["src/export/csv.sh", "docs/csv.md", "src/exporter/x.sh"]' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >out.md
  assert_eq '["docs","export"]' "$(jq -c '.tickets["2"].areas' draft.json)"
  assert_contains "$(cat out.md)" "| Ticket | Areas |"
  assert_contains "$(cat out.md)" "| #2 (CSV header) | docs, export |"
}

test_a_ticket_in_two_areas_gets_the_stricter_gate_setting_of_the_two() {
  draft feature
  elsewhere
  areas_config
  jq '.tickets["2"].expected_files = ["src/export/csv.sh", "db/migrations/001.sql"]' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >out.md
  # export asks for its own slice gate, billing for a risk gate: both, so the union
  assert_eq '{"kind":"slice","after":"2"}' "$(jq -c '.gates[] | select(.kind == "slice" and .after == "2")' draft.json)"
  assert_eq '{"kind":"risk","after":"2","tests":["area:billing"]}' "$(jq -c '.gates[] | select(.kind == "risk" and .after == "2")' draft.json)"
  assert_contains "$(cat out.md)" "area billing gate setting"
}

test_an_area_risk_setting_joins_the_tickets_own_escalation_in_one_risk_gate() {
  draft feature
  elsewhere
  areas_config
  jq '.tickets["1"].expected_files = ["src/billing/x.sh"]' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >/dev/null
  assert_eq '[{"kind":"risk","after":"1","tests":["new-seam","area:billing"]}]' \
    "$(jq -c '[.gates[] | select(.kind == "risk" and .after == "1")]' draft.json)"
}

test_an_area_with_no_gate_setting_changes_no_gate() {
  draft feature
  elsewhere
  areas_config
  jq '.tickets["2"].expected_files = ["docs/a.md"]' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >/dev/null
  assert_eq '["docs"]' "$(jq -c '.tickets["2"].areas' draft.json)"
  assert_eq '[{"kind":"slice","slice":"export"},{"kind":"slice","slice":"billing"},{"kind":"risk","after":"1","tests":["new-seam"]},{"kind":"risk","after":"3","tests":["judgement-criteria","vocabulary-adr"]},{"kind":"end"}]' \
    "$(jq -c .gates draft.json)"
}

test_a_ticket_with_no_expected_files_is_in_every_area_so_it_gets_the_strictest_gates() {
  draft feature
  areas_config
  "$GP" propose draft.json --config areas.yml >/dev/null
  assert_eq '["billing","docs","export"]' "$(jq -c '.tickets["2"].areas' draft.json)"
  assert_eq '{"kind":"slice","after":"2"}' "$(jq -c '.gates[] | select(.kind == "slice" and .after == "2")' draft.json)"
  assert_eq '["area:billing"]' "$(jq -c '.gates[] | select(.kind == "risk" and .after == "2") | .tests' draft.json)"
}

test_an_empty_expected_files_touches_nothing_so_it_is_in_no_area() {
  draft feature
  areas_config
  jq '.tickets["2"].expected_files = []' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >/dev/null
  assert_eq 'false' "$(jq '.tickets["2"] | has("areas")' draft.json)"
}

test_expected_files_match_areas_as_parallel_waves_reads_them() {
  draft feature
  elsewhere
  areas_config
  # a directory holding the area, an area dir with no trailing slash, a file in one
  jq '.tickets["1"].expected_files = ["src/"] | .tickets["2"].expected_files = ["src/export"] | .tickets["3"].expected_files = ["src/billing/tab.sh"]' draft.json >d && mv d draft.json
  "$GP" propose draft.json --config areas.yml >/dev/null
  assert_eq '["billing","export"]' "$(jq -c '.tickets["1"].areas' draft.json)"
  assert_eq '["export"]' "$(jq -c '.tickets["2"].areas' draft.json)"
  assert_eq '["billing"]' "$(jq -c '.tickets["3"].areas' draft.json)"
}

test_an_unknown_area_gate_setting_is_refused() {
  draft feature
  printf 'areas:\n  x:\n    paths: [a/]\n    gates: [loud]\n' >bad.yml
  assert_status 2 "$GP" propose draft.json --config bad.yml
}
