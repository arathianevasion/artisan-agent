# Risk gates (#71): a ticket meeting an escalation test gets a risk gate in
# the plan; a worker's new-seam card (controversy criterion 3, #87) raises
# one too; either opens as a review-gate issue once the ticket merges and
# holds only its dependents. A merge processed at 50% context raises one
# through drain.sh gate (#59). Fake `gh` (a folder tracker); nothing reaches
# GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

G="$PLUGIN_ROOT/scripts/gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# Tickets: 1 meets an escalation test (a new seam) and 2 depends on it;
# 4 is ordinary and 3 depends only on 4.
setup_risk() { # gates-json
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n
  for n in 1 2 3 4; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}],
      body: "## Acceptance criteria\n\n- [ ] t\($n).txt exists"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[4]' >"$FAKE_GH_DIR/blocked_by-3.json"
  jq -n --argjson gates "${1:-[]}" '
    def t($n): {title: "Ticket \($n)", expected_output: "t\($n).txt", model: "claude-sonnet-5-5",
                estimate_usd: 0.25, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3", "4"],
     waves: [["1", "4"], ["2", "3"]], max_agents: 4, attempts_per_ticket: 2,
     estimate_usd: 1, budget_usd: 1.25, gates: $gates,
     tickets: {"1": t(1), "2": t(2), "3": t(3), "4": t(4)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

merged_with_cards() { # ticket criterion
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets[$t] |= (.status = "merged" | .merge_commit = "abcdef1234567"
      | .evidence = {ticket: $t, verdict: "pass",
          acceptance: [{criterion: "t\($t).txt exists", met: true, evidence: {tests: ["tests/t.sh"]}}],
          unsure: [],
          decisions: [{job: 3, question: "Where does the export seam go?", choice: "to_csv()",
                       alternative: "the controller", by: "worker \($t)", kind: "engineering",
                       criterion: $c, confidence: "firm"}]})' --arg t "$1" --arg c "$2"
}

test_an_escalated_ticket_gets_a_risk_gate_holding_only_its_dependents() {
  setup_risk '[{"kind": "risk", "after": "1", "tests": ["new-seam"]}]'
  merged_with_cards 1 none
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["4"].status = "merged"'
  assert_eq "risk-1" "$("$G" due "$RUN_DIR")"
  assert_eq held "$("$G" holds "$RUN_DIR" 1)"
  assert_eq free "$("$G" holds "$RUN_DIR" 4)"
  local num
  num=$("$G" open "$RUN_DIR" risk-1)
  assert_eq "Risk gate: #1 (Ticket 1), new seam or module boundary (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq "[1,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")" "only #2 waits"
  assert_eq "[4]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-3.json")" "#3 is not held"
  assert_eq risk "$(state_get '.review_gates[0].kind')"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")" "| risk |"
  # Approving it (keep all) is the slice gate's answer; it records job 13.
  "$G" approve "$RUN_DIR" "$num" >/dev/null
  assert_eq "approved 13 false" "$(state_get '.review_gates[0].status as $s | .decisions[] | select(.kind == "review-gate") | "\($s) \(.job) \(.changed)"')"
  assert_eq free "$("$G" holds "$RUN_DIR" 1)"
}

test_a_new_seam_card_raises_a_risk_gate_the_plan_did_not_place() {
  setup_risk '[]'
  merged_with_cards 1 3
  merged_with_cards 4 4
  assert_eq "risk-seam-1" "$("$G" due "$RUN_DIR")"
  assert_eq held "$("$G" holds "$RUN_DIR" 1)"
  assert_eq free "$("$G" holds "$RUN_DIR" 4)"
  local out num
  out=$("$G" sync "$RUN_DIR")
  num=$(printf '%s\n' "$out" | sed -n 's/^opened #\([0-9]*\) risk-seam-1$/\1/p')
  [ -n "$num" ] || fail "sync opened no risk gate: $out"
  assert_eq "Risk gate: #1 (Ticket 1), new seam (decision card) (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq "[1,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  # A second sync opens nothing new.
  assert_eq "" "$("$G" sync "$RUN_DIR")"
}

test_a_planned_risk_gate_also_covers_the_tickets_own_seam_card() {
  setup_risk '[{"kind": "risk", "after": "1", "tests": ["new-seam"]}]'
  merged_with_cards 1 3
  assert_eq "risk-1" "$("$G" due "$RUN_DIR")" "one risk gate per ticket, not two"
}

test_a_merge_at_the_review_band_raises_a_risk_gate_on_its_dependents_alone() {
  setup_risk '[]'
  merged_with_cards 1 none
  "$PLUGIN_ROOT/scripts/drain.sh" gate "$RUN_DIR" 1 55
  assert_eq waiting "$(state_get '.tickets["1"].risk_gate.status')"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["4"].status = "merged"'
  "$PLUGIN_ROOT/scripts/reconcile.sh" "$RUN_DIR" >/dev/null 2>&1 || true
  assert_eq "3" "$(state_get '.frontier | join(",")')" "#2 waits, #3 goes ahead"
  "$PLUGIN_ROOT/scripts/drain.sh" gate-cleared "$RUN_DIR" 1
  assert_eq "clear 13 false" "$(state_get '.decisions[] | select(.kind == "risk-gate") | "\(.choice) \(.job) \(.changed)"')"
}
