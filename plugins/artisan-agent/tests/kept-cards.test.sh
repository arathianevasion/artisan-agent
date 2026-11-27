# Kept decision cards (#426): approving the end gate files one needs-triage
# ticket listing every card the Artisan kept at a gate in the run, once each,
# grouped by area, so the Decision chat reviews them later. Cards changed,
# made a guardrail or sent to triage are only counted. Filing is idempotent,
# nothing is filed when nothing was kept, and the ticket blocks nothing.
# Fake `gh`; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

E="$PLUGIN_ROOT/scripts/end-gate.sh"

. "$TESTS_DIR/helpers/end-gate-run.sh"

# Tickets 1 and 2 are in the area "exporter", ticket 3 has none. A risk gate on
# ticket 1 folded into the export slice gate (#50), which shows its card again;
# the billing slice gate (#51) was closed on the tracker. One card each was
# changed, made a guardrail and sent to triage.
kept_gates() {
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .plan.tickets["1"].areas = ["exporter"] | .plan.tickets["2"].areas = ["exporter"]
    | .review_gates = [
      {id: "risk-1", kind: "risk", title: "Risk gate: #1 (run r1)", issue: null, tickets: ["1"], dependents: [],
       cards: [{card: 1, ticket: "1", question: "Where is CSV tested?", choice: "At to_csv", confidence: "provisional", criterion: "3"}],
       status: "approved", folded_into: "slice-export", answered_with: "slice-export", decisions: [], reworks: []},
      {id: "slice-export", kind: "slice", title: "Slice gate: export (run r1)", issue: 50, tickets: ["1", "2"], dependents: [],
       cards: [{card: 1, ticket: "1", question: "Where is CSV tested?", choice: "At to_csv", confidence: "provisional", criterion: "3"},
               {card: 2, ticket: "2", question: "Column order?", choice: "As the schema", confidence: "high"},
               {card: 3, ticket: "2", question: "Quote every field?", choice: "Only when needed", confidence: "provisional"}],
       status: "approved",
       decisions: [{card: 1, ticket: "1", outcome: "keep", job: 13, choice: "At to_csv", by: "Artisan"},
                   {card: 2, ticket: "2", outcome: "keep", job: 13, choice: "As the schema", by: "Artisan"},
                   {card: 3, ticket: "2", outcome: "change", job: 13, choice: "Quote every field", by: "Artisan"},
                   {outcome: "approve", job: 13, choice: "approve the slice", by: "Artisan"}],
       reworks: [{number: 60}]},
      {id: "slice-billing", kind: "slice", title: "Slice gate: billing (run r1)", issue: 51, tickets: ["3"], dependents: [],
       cards: [{card: 1, ticket: "3", question: "Which currency?", choice: "EUR", confidence: "provisional"},
               {card: 2, ticket: "3", question: "Round where?", choice: "At the total", confidence: "provisional"},
               {card: 3, ticket: "3", question: "Store cents?", choice: "Yes", confidence: "low", criterion: "4"}],
       status: "approved", closed_on_tracker: true,
       triaged: [{card: 2, ticket: "3", question: "Round where?", by: "Artisan", at: 1}],
       decisions: [{card: 1, ticket: "3", outcome: "keep", job: 13, choice: "EUR", by: "Artisan", guardrail_level: "product", reach: "area"},
                   {card: 3, ticket: "3", outcome: "keep", job: 13, choice: "Yes", by: "Artisan (closed on the tracker)"}],
       reworks: []}]'
}

kept_tickets() { # the issue files the fake tracker holds for kept-cards tickets
  local f=
  for f in "$FAKE_GH_DIR"/issue-*.json; do
    jq -e 'select(.title | startswith("Review kept decision cards"))' "$f" >/dev/null && echo "$f"
  done
  return 0
}

approve() {
  product_boundary slice
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
}

test_approving_the_end_gate_files_one_ticket_listing_each_kept_card_once_by_area() {
  setup_end
  kept_gates
  approve
  local f= body=
  f=$(kept_tickets)
  assert_eq 1 "$(printf '%s\n' "$f" | grep -c .)" "exactly one kept-cards ticket"
  assert_eq "Review kept decision cards: run r1" "$(jq -r .title "$f")"
  assert_contains "$(jq -r '.labels | map(.name) | join(",")' "$f")" needs-triage
  body=$(jq -r .body "$f")
  assert_contains "$body" "### exporter"
  assert_contains "$body" "### No area"
  assert_contains "$body" "| #2 | #50 | Column order? | As the schema | high | - |"
  assert_contains "$body" "| #3 | #51 | Store cents? | Yes | low | 4 |"
  assert_eq 1 "$(grep -c 'Where is CSV tested?' <<<"$body")" "a risk-gate card shown again at its slice gate is listed once"
  assert_contains "$body" "| #1 | #50 | Where is CSV tested? | At to_csv | provisional | 3 |"
  # The exporter group comes before No area, and No area holds only ticket 3.
  assert_contains "$(sed -n '/### No area/,$p' <<<"$body")" "Store cents?"
  assert_not_contains "$(sed -n '/### No area/,$p' <<<"$body")" "Column order?"
}

test_cards_already_acted_on_are_counted_not_listed() {
  setup_end
  kept_gates
  approve
  local body=
  body=$(jq -r .body "$(kept_tickets)")
  assert_not_contains "$body" "Quote every field?"
  assert_not_contains "$body" "Which currency?"
  assert_not_contains "$body" "Round where?"
  assert_contains "$body" "3 cards are left out: the Artisan already changed them, made them a guardrail or sent them to triage."
}

test_the_ticket_is_recorded_and_a_second_approval_files_no_second_one() {
  setup_end
  kept_gates
  approve
  local n=
  n=$(jq -r .number "$(kept_tickets)")
  assert_eq "$n 3" "$(state_get '"\(.end_gate.kept_cards.issue) \(.end_gate.kept_cards.cards)"')"
  assert_eq "$n" "$(state_get '[.events[] | select(.event == "kept-cards-filed")] | "\(length):\(.[0].issue)"' | sed 's/^1://')"
  "$E" approve "$RUN_DIR" >/dev/null 2>&1 || true
  assert_eq 1 "$(kept_tickets | grep -c .)"
}

test_a_crash_after_filing_reuses_the_ticket_already_on_the_tracker() {
  setup_end
  kept_gates
  product_boundary slice
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  local n=
  n=$(jq -r .number "$(kept_tickets)")
  # As if the run crashed between filing the ticket and approving the gate.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.end_gate.status = "open" | del(.end_gate.kept_cards)'
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq 1 "$(kept_tickets | grep -c .)"
  assert_eq "$n" "$(state_get .end_gate.kept_cards.issue)"
}

test_approve_names_the_kept_cards_ticket() {
  setup_end
  kept_gates
  product_boundary slice
  "$E" open "$RUN_DIR" >/dev/null
  local out=
  out=$("$E" approve "$RUN_DIR")
  assert_contains "$out" "kept decision cards: #$(jq -r .number "$(kept_tickets)") for the Decision chat"
}

test_a_run_that_kept_no_cards_files_nothing() {
  setup_end
  approve
  assert_eq "" "$(kept_tickets)"
  assert_eq null "$(state_get '.end_gate.kept_cards')"
}

test_the_kept_cards_ticket_blocks_nothing_and_the_prs_open_as_before() {
  setup_end
  kept_gates
  approve
  assert_eq approved "$("$E" status "$RUN_DIR")"
  assert_eq '[["1","2"],["3"]]' "$("$E" prs "$RUN_DIR" --json | jq -c 'map(.tickets)')"
  assert_eq '[]' "$(jq -c '[.body | scan("[Bb]locked by #[0-9]+")]' "$(kept_tickets)")"
}

test_the_references_and_triage_describe_the_kept_cards_ticket() {
  assert_contains "$(cat "$SCRIPTS/../references/end-gate.md")" "Review kept decision cards"
  assert_contains "$(cat "$SCRIPTS/../references/review-gates.md")" "kept-cards ticket"
  assert_contains "$(cat "$SCRIPTS/../references/state-file.md")" "kept-cards-filed"
  assert_contains "$(cat "$SCRIPTS/../skills/triage/SKILL.md")" "Review kept decision cards"
}
