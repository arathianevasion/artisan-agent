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

# ------------------------------------------- a 5-ticket wave with 2 CI gates

# A CI run over tickets 1-5, none blocking another, Max Agents 5. Each worker
# commits t<ticket>.txt; tickets 4 and 5 take SLOW_SECONDS, so they come back
# while the first merge batch's CI gate is running and make a second gate.
setup_five() {
  setup_ci 30 '["1","2","3","4","5"]'
  rm -f "$FAKE_GH_DIR/blocked_by-2.json"
  local t=
  for t in 3 4 5; do
    jq -n --argjson n "$t" '{number: $n, title: "Ticket \($n)", state: "open", labels: [], body: "- [ ] it works"}' >"$FAKE_GH_DIR/issue-$t.json"
  done
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 5
    | .plan.waves = [["1","2","3","4","5"]]
    | reduce ("3", "4", "5") as $t (.; .plan.tickets[$t] = (.plan.tickets["2"] | .title = "Ticket \($t)"))
    | reduce ("1", "2", "3", "4", "5") as $t (.; .plan.tickets[$t].expected_files = ["t\($t).txt"])' >/dev/null
  export SLOW_SECONDS=${SLOW_SECONDS:-4}
  write_five_worker_script
  write_turn_counting_orchestrator
}

write_five_worker_script() {
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
t=${key%%.*}
# 1-3 return together: each waits until all three have committed.
barrier="$ARTISAN_RUN_DIR/../barrier"
mkdir -p "$barrier"
case "$t" in 4|5) sleep "$SLOW_SECONDS" ;; esac
echo "$t" >"t$t.txt"
git add -A && git commit -q -m "worker $t"
jq -n --arg t "$t" --arg c "$(git rev-parse HEAD)" '{ticket: $t, status: "complete", commit: $c,
  acceptance: [{criterion: "it works", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE.tmp"
case "$t" in
  1|2|3) touch "$barrier/$t"
         while [ ! -e "$barrier/1" ] || [ ! -e "$barrier/2" ] || [ ! -e "$barrier/3" ]; do sleep 0.1; done ;;
esac
mv "$ARTISAN_RESULT_FILE.tmp" "$ARTISAN_RESULT_FILE"
EOF
}

# The orchestrator, as references/orchestrator.md tells the real one, one
# `turn` per tool call it would make: reading its brief, reconcile, the
# hands-on sync, the wave width, a dispatch per ticket; then per wake, one
# wait-any.sh call (a CI wait included: never a merge-and-poll loop), the
# sweep, the urgent-lever check and the drain check; a verifier start and a
# judge per ticket; a merge per merge batch, plus one more after the wait that
# saw its gate's result; a close per ticket; findings; the report. Steps whose
# answer is fixed here (nothing hands-on, no lever, no drain) still cost their
# turn. Past FAKE_CLAUDE_MAX_TURNS it stops, as the real session would.
write_turn_counting_orchestrator() {
  export FAKE_CLAUDE_SCRIPT_ORCHESTRATOR="$TEST_TMPDIR/orchestrator.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_ORCHESTRATOR" <<EOF
set -uo pipefail
S="$SCRIPTS"
R="\$ARTISAN_RUN_DIR"
turn() {
  echo >>"\$FAKE_CLAUDE_TURNS"
  [ -z "\$FAKE_CLAUDE_MAX_TURNS" ] || [ "\$(wc -l <"\$FAKE_CLAUDE_TURNS")" -le "\$FAKE_CLAUDE_MAX_TURNS" ] || exit 1
  "\$@"
}
st() { jq -r "\$@" "\$R/state.json"; }
turn : read the brief
turn "\$S/reconcile.sh" "\$R" >/dev/null || exit 1
turn : human.sh sync, nothing hands-on
for t in \$(turn "\$S/wave-width.sh" pick "\$R"); do turn "\$S/wave.sh" dispatch "\$R" "\$t" >/dev/null || exit 1; done
started=" " judged=" " gate=""
woke=""
while :; do
  left=\$(st '[.tickets[] | select(.status == "in_flight" or .status == "returned")] | length')
  [ "\$left" -gt 0 ] || [ -n "\$gate" ] || break
  rc=0
  woke=\$(turn "\$S/wait-any.sh" "\$R" --timeout 570) || rc=\$?
  [ "\$rc" -eq 0 ] || [ "\$rc" -eq 124 ] || exit 1
  turn "\$S/sweep.sh" "\$R" >/dev/null || exit 1
  turn : lever.sh pending, none
  turn : drain.sh check, dispatch
  # A running gate: merge again only once wait-any saw its result.
  if [ -n "\$gate" ] && { [ "\$rc" -eq 124 ] || printf '%s\n' "\$woke" | grep -q '^new results/merge-'; }; then
    rc=0; turn "\$S/wave.sh" merge "\$R" \$gate >/dev/null 2>&1 || rc=\$?
    case \$rc in
      0) for t in \$gate; do turn "\$S/wave.sh" close "\$R" "\$t" >/dev/null || exit 1; done; gate="" ;;
      20) ;;
      *) exit 1 ;;
    esac
  fi
  passed=""
  for t in \$(st '.tickets | to_entries[] | select(.value.status == "returned") | .key'); do
    case "\$started" in *" \$t "*) ;; *)
      # Exit 8: its worker is still ending; start it after the next wake.
      rc=0; turn "\$S/verify.sh" start "\$R" "\$t" >/dev/null 2>&1 || rc=\$?
      case \$rc in 0) started="\$started\$t " ;; 8) ;; *) exit 1 ;; esac
      continue ;; esac
    case "\$judged" in *" \$t "*) passed="\$passed \$t"; continue ;; esac
    rc=0; turn "\$S/verify.sh" judge "\$R" "\$t" >/dev/null 2>&1 || rc=\$?
    case \$rc in 0) judged="\$judged\$t "; passed="\$passed \$t" ;; 8) ;; *) exit 1 ;; esac
  done
  # Tickets passing together go as one merge batch: hold while a returned
  # ticket is unjudged or a worker in flight has written its result.
  unjudged=0
  for t in \$(st '.tickets | to_entries[] | select(.value.status == "returned") | .key'); do
    case "\$judged" in *" \$t "*) ;; *) unjudged=1 ;; esac
  done
  for t in \$(st '.tickets | to_entries[] | select(.value.status == "in_flight") | "\(.key).\(.value.attempts)"'); do
    [ ! -e "\$R/results/\$t.result.json" ] || unjudged=1
  done
  if [ -z "\$gate" ] && [ -n "\$passed" ] && [ "\$unjudged" -eq 0 ]; then
    # --wait 0: the CI gate is always still running, so its wait is waited on.
    rc=0; turn "\$S/wave.sh" merge "\$R" \$passed --wait 0 >/dev/null 2>&1 || rc=\$?
    case \$rc in
      0) for t in \$passed; do turn "\$S/wave.sh" close "\$R" "\$t" >/dev/null || exit 1; done ;;
      20) gate=\$passed ;;
      *) exit 1 ;;
    esac
  fi
done
turn "\$S/findings.sh" pending "\$R" >/dev/null || true
turn "\$S/wave.sh" report "\$R" >"\$ARTISAN_RESULT_FILE"
EOF
}

test_ot_a_five_ticket_wave_with_two_ci_gates_finishes_within_its_turn_budget() {
  setup_five
  start_and_launch
  wait_for "$ORCH_EXIT" 120
  local turns= max=
  max=$(orchestrator_max_turns)
  assert_eq 130 "$max" "the defaults: 20 + 5 x 12 + 5 x 10"
  assert_eq "completed -" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" orchestrator-w1 1)" \
    "$(cat "$TEST_TMPDIR/fake-claude.log" 2>/dev/null | tail -5)"
  assert_eq "merged merged merged merged merged" "$(state_get '[.tickets["1","2","3","4","5"].status] | join(" ")')"
  assert_eq 2 "$(state_get '[.events[] | select(.event == "merge-gate")] | length')" "two CI gates: $(state_get '[.events[] | select(.event == "merge-gate" or .event == "returned" or .event == "verdict") | [.event, .ticket // (.tickets|tostring)] | join(":")] | join(" ")')"
  turns=$(jq -r '.num_turns' "$RUN_DIR/workers/orchestrator-w1.1/output.json" 2>/dev/null \
    || jq -rs 'map(select(.type == "result")) | last | .num_turns' "$RUN_DIR/workers/orchestrator-w1.1/output.json")
  [ "$turns" -le "$max" ] || fail "took $turns turns of $max"
  # The old budget (40, one estimated dollar) would not have held it.
  [ "$turns" -gt 40 ] || fail "took only $turns turns: the test no longer stands for riley's wave"
}

test_ot_an_orchestrator_out_of_turns_is_an_orchestrator_exit_decision() {
  setup_five
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.orchestrator_turns = {base: 5, per_ticket: 1, per_ci_gate: 0}' >/dev/null
  start_and_launch
  wait_for "$ORCH_EXIT" 120
  assert_eq 10 "$(orchestrator_max_turns)"
  assert_eq "failed turns" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" orchestrator-w1 1)"
  # R7 (#171): the chat's status makes it a decision, never a silent stop.
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null 2>&1 || true
  assert_eq "error_max_turns waiting" \
    "$(state_get '[.decisions[] | select(.kind == "orchestrator-exit")] | last | "\(.cause) \(.status)"')"
}
