# The orchestrator's turn budget (#175): wave.sh launch gives it a base, plus
# so many turns per ticket in the wave, plus so many per CI gate when the merge
# gate runs on CI; and a CI wait costs one turn (wait-any.sh), so a 5-ticket
# wave with 2 CI gates finishes inside it. The fake `claude` counts the fake
# orchestrator's turns and ends it error_max_turns past --max-turns. Built on
# merge-gate.test.sh's run (fake `gh` whose workflow runs read a bare origin).

. "$TESTS_DIR/merge-gate.test.sh"
# Only this file's tests run here.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_ot_/ {print $3}'); do unset -f "$_f"; done
unset _f

# The max_turns the last launched orchestrator was given, from its exit record.
orchestrator_max_turns() { jq -r .max_turns "$RUN_DIR/results/orchestrator-w1.1.exit.json"; }

# Launch wave 1 with an orchestrator that ends at once, and wait for its exit.
launch_and_end() {
  ORCH_STOP=fail start_and_launch
  wait_for "$ORCH_EXIT" 30
}

test_ot_a_local_merge_gate_gives_a_base_plus_turns_per_ticket() {
  setup_wave '["1","2"]'
  export ARTISAN_MERGE_GATE=local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.orchestrator_turns = {base: 20, per_ticket: 12, per_ci_gate: 10}' >/dev/null
  launch_and_end
  # Two tickets open, Max Agents 2: 20 + 2 x 12.
  assert_eq 44 "$(orchestrator_max_turns)"
}

test_ot_a_ci_merge_gate_adds_turns_for_a_gate_per_ticket() {
  setup_ci 30 '["1","2"]'
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.orchestrator_turns = {base: 20, per_ticket: 12, per_ci_gate: 10}' >/dev/null
  launch_and_end
  # 20 + 2 x 12 + 2 x 10: each ticket may need a gate of its own.
  assert_eq 64 "$(orchestrator_max_turns)"
}

test_ot_the_wave_counts_open_tickets_no_more_than_max_agents() {
  setup_wave '["1","2"]'
  export ARTISAN_MERGE_GATE=local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.orchestrator_turns = {base: 5, per_ticket: 3, per_ci_gate: 7}
    | .plan.max_agents = 1' >/dev/null
  launch_and_end
  assert_eq 8 "$(orchestrator_max_turns)" "5 + 1 x 3: Max Agents 1 caps the wave at one ticket"
}

test_ot_a_plan_from_before_the_setting_gets_the_template_defaults() {
  setup_ci 30 '["1","2"]'
  "$SCRIPTS/state.sh" update "$RUN_DIR" 'del(.plan.config.orchestrator_turns)' >/dev/null
  launch_and_end
  # The defaults (base 20, 12 per ticket, 10 per CI gate): 20 + 2 x 12 + 2 x 10.
  assert_eq 64 "$(orchestrator_max_turns)"
}
