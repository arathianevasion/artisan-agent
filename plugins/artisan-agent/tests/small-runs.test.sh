# Small clean runs (#407): when a run has at most small_run_tickets tickets
# (the plan's config; 0 off) and none has failed an attempt, been redirected
# or reached an exception gate, its slice and risk gates don't wait on the
# Artisan: they are carried to the end gate, which shows their cards and
# answers them. Fake `gh` (a folder tracker); nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

G="$PLUGIN_ROOT/scripts/gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# Three tickets: 2 depends on 1; 3 stands alone.
setup_small() { # gates-json [small_run_tickets]
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}],
      body: "## Acceptance criteria\n\n- [ ] t\($n).txt exists"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  jq -n --argjson gates "$1" --argjson small "${2:-3}" '
    def t($n): {title: "Ticket \($n)", expected_output: "t\($n).txt", model: "claude-sonnet-5-5",
                estimate_usd: 0.25, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3"],
     waves: [["1", "3"], ["2"]], max_agents: 4, attempts_per_ticket: 2,
     estimate_usd: 1, budget_usd: 1.25, gates: $gates, config: {small_run_tickets: $small},
     tickets: {"1": t(1), "2": t(2), "3": t(3)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  merge_gate_local "$ARTISAN_HOME"
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

review_gate_issues() {
  local n=0 f=
  for f in "$FAKE_GH_DIR"/issue-*.json; do
    jq -e 'any(.labels[]?; .name == "review-gate")' "$f" >/dev/null && n=$((n + 1))
  done
  echo "$n"
}

SLICE_END='[{"kind": "slice", "tickets": ["1"]}, {"kind": "end"}]'

test_a_small_clean_runs_slice_gate_is_carried_to_the_end_gate_and_holds_nothing() {
  setup_small "$SLICE_END"
  merged_with_cards 1 none
  assert_contains "$("$G" sync "$RUN_DIR")" "carried slice-1 to the end gate"
  assert_eq 0 "$(review_gate_issues)" "no issue opened"
  assert_eq 0 "$(state_get '[.decisions[] | select(.gate == "slice-1")] | length')" "no decision waiting"
  assert_eq "folded end true" "$(state_get '.review_gates[] | select(.id == "slice-1") | "\(.status) \(.folded_into) \(.carried)"')"
  assert_eq free "$("$G" holds "$RUN_DIR" 1 2)" "its dependent goes ahead"
  assert_eq "" "$("$G" sync "$RUN_DIR")" "a second sync does nothing"
}

test_a_risk_gate_with_a_waiting_dependent_is_carried_too() {
  setup_small '[{"kind": "risk", "after": "1", "tests": ["new-seam"]}, {"kind": "end"}]'
  merged_with_cards 1 3
  assert_contains "$("$G" sync "$RUN_DIR")" "carried risk-1 to the end gate"
  assert_eq "risk folded end" "$(state_get '.review_gates[] | select(.id == "risk-1") | "\(.kind) \(.status) \(.folded_into)"')"
  assert_eq 0 "$(review_gate_issues)"
  assert_eq free "$("$G" holds "$RUN_DIR" 1 2)"
}

opens_as_today() { # why
  local out=
  out=$("$G" sync "$RUN_DIR")
  assert_contains "$out" "opened #" "$1"
  assert_not_contains "$out" "carried" "$1"
  assert_eq open "$(state_get '.review_gates[] | select(.id == "slice-1") | .status')" "$1"
  assert_eq held "$("$G" holds "$RUN_DIR" 1 2)" "$1"
}

test_a_run_with_a_failed_attempt_keeps_its_gates() {
  setup_small "$SLICE_END"
  merged_with_cards 1 none
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].failures = [{attempt: 1, reason: "verifier fail", at: 1}]'
  opens_as_today "a failed attempt"
}

test_a_run_with_a_redirected_gate_keeps_its_gates() {
  setup_small "$SLICE_END"
  merged_with_cards 1 none
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.review_gates = [{id: "risk-9", kind: "risk", status: "redirected", tickets: ["3"], cards: [], decisions: [], reworks: []}]'
  opens_as_today "a redirect"
}

test_a_run_with_an_exception_gate_keeps_its_gates() {
  setup_small "$SLICE_END"
  merged_with_cards 1 none
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.exception_gates = [{id: "exception-3", ticket: "3", status: "approved"}]'
  opens_as_today "an exception gate"
}

test_a_run_bigger_than_the_setting_keeps_its_gates() {
  setup_small "$SLICE_END" 2
  merged_with_cards 1 none
  opens_as_today "three tickets, small_run_tickets 2"
}

test_a_setting_of_0_turns_carrying_off() {
  setup_small "$SLICE_END" 0
  merged_with_cards 1 none
  opens_as_today "small_run_tickets 0"
}

test_a_plan_from_before_the_setting_keeps_its_gates() {
  setup_small "$SLICE_END"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config = {}'
  merged_with_cards 1 none
  opens_as_today "no small_run_tickets in the plan's config"
}

test_a_run_with_no_end_gate_keeps_its_gates() {
  setup_small '[{"kind": "slice", "tickets": ["1"]}]'
  merged_with_cards 1 none
  opens_as_today "no end gate to carry to"
}
