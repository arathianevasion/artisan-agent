# gate-action.sh and state.sh decide (#70): the gate actions (approve,
# redirect both ways, bypass, defer), the exception gate for a run giving up
# or a check that won't go green, and parking behind open reviews. Fake
# `claude` (scripted per role) and fake `gh` (a folder tracker); nothing
# reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"
. "$PLUGIN_ROOT/scripts/lib/state-lib.sh"   # STATE_JQ_DEFS, for gave_up_on_3

A="$PLUGIN_ROOT/scripts/gate-action.sh"
G="$PLUGIN_ROOT/scripts/gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-30} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

# Tickets: 1 is the slice "greeting" (its gate holds 2); 3 stands alone and
# 4 depends on it. check is the suite's script.
setup_run() { # [check.sh body]
  make_project
  printf '%s\n' "${1:-echo suite ok}" >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3 4; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open",
      labels: [{name: "in-run"}, {name: "ready-for-agent"}],
      body: "## Acceptance criteria\n\n- [ ] t\($n).txt exists"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[3]' >"$FAKE_GH_DIR/blocked_by-4.json"
  jq -n '
    def t($n): {title: "Ticket \($n)", expected_output: "t\($n).txt", expected_files: ["t\($n).txt"],
                model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
                caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3", "4"],
     waves: [["1", "3"], ["2", "4"]], max_agents: 4, attempts_per_ticket: 2, suite_command: "sh check.sh",
     estimate_usd: 1, budget_usd: 1.25, orchestrator: {estimate_usd: 0.25},
     gates: [{kind: "slice", slice: "greeting", tickets: ["1"]}],
     tickets: {"1": t(1), "2": t(2), "3": t(3), "4": t(4)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  merge_gate_local "$ARTISAN_HOME"   # lib.sh's host.json is not read once ARTISAN_HOME moves
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

# Ticket 1 merged with one decision card, and its slice gate open. Prints the gate's issue.
open_slice_gate() {
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["1"] |= (.status = "merged" | .merge_commit = "abcdef1234567" | .attempts = 1
      | .evidence = {ticket: "1", verdict: "pass",
          acceptance: [{criterion: "t1.txt exists", met: true, evidence: {tests: ["check.sh"]}}],
          unsure: [], decisions: [{job: 3, question: "Which file name?", choice: "t1.txt",
            alternative: "T.TXT", by: "worker 1", kind: "engineering taste", confidence: "provisional"}]})'
  "$G" open "$RUN_DIR" slice-1
}

frontier() { "$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//'; }
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH_DIR/issue-$1.json"; }
issue_state() { jq -r .state "$FAKE_GH_DIR/issue-$1.json"; }

# ------------------------------------------------------------ state.sh decide

test_decide_marks_a_waiting_decision_decided_as_a_decision_record() {
  init_run
  jq -n '{kind: "design", ticket: "10", question: "Which store?"}' >"$TEST_TMPDIR/d.json"
  "$SCRIPTS/state.sh" decision "$RUN_DIR" "$TEST_TMPDIR/d.json"
  "$SCRIPTS/state.sh" decide "$RUN_DIR" 1 "Use SQLite" --by Andrew --job 3 --why "Fits one machine" \
    --level product --reach area --area storage --confidence provisional --redirect notes
  assert_eq '{"kind":"design","choice":"Use SQLite","by":"Andrew","job":3,"why":"Fits one machine","guardrail_level":"product","reach":"area","area":"storage","confidence":"provisional","redirect":"notes","status":"decided"}' \
    "$(state_get '.decisions[0] | {kind, choice, by, job, why, guardrail_level, reach, area, confidence, redirect, status}' | jq -c .)"
  assert_eq "decided 1 Andrew" "$(state_get '.events[-1] | "\(.event) \(.decision) \(.by)"')"
  # Decided once; an unknown id or a bad value is refused.
  assert_status 6 "$SCRIPTS/state.sh" decide "$RUN_DIR" 1 "Again"
  assert_status 6 "$SCRIPTS/state.sh" decide "$RUN_DIR" 9 "No such"
  "$SCRIPTS/state.sh" decision "$RUN_DIR" "$TEST_TMPDIR/d.json"
  assert_status 2 "$SCRIPTS/state.sh" decide "$RUN_DIR" 2 x --level team --reach area
  assert_status 2 "$SCRIPTS/state.sh" decide "$RUN_DIR" 2 x --confidence sure
  # Only the choice is required; who defaults to the Artisan.
  "$SCRIPTS/state.sh" decide "$RUN_DIR" 2 "Postgres"
  assert_eq '{"choice":"Postgres","by":"Artisan"}' "$(state_get '.decisions[1] | {choice, by, why}' | jq -c 'del(.why)')"
}

# ------------------------------------------------------------ review gates

test_approve_closes_a_slice_gate_with_the_optional_fields() {
  setup_run
  local num=
  num=$(open_slice_gate)
  "$A" approve "$RUN_DIR" "$num" --by Andrew --why "Reads well" --confidence firm \
    --level product --reach everywhere >/dev/null
  assert_eq closed "$(issue_state "$num")"
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_eq '{"job":13,"by":"Andrew","why":"Reads well","confidence":"firm","guardrail_level":"product","reach":"everywhere"}' \
    "$(state_get '.review_gates[0].decisions[] | select(.outcome == "approve") | {job, by, why, confidence, guardrail_level, reach}' | jq -c .)"
  assert_eq "2 3" "$(frontier)"
}

test_redirect_with_notes_reworks_in_the_same_run_counted_separately() {
  setup_run
  local num= rw=
  num=$(open_slice_gate)
  rw=$("$A" redirect "$RUN_DIR" "$num" --notes "Greet by name" --why "Too terse")
  # The gate closes as redirected; its decision is a decision record.
  assert_eq closed "$(issue_state "$num")"
  assert_eq redirected "$(state_get '.review_gates[0].status')"
  assert_eq '{"status":"decided","choice":"redirect","redirect":"notes","by":"Artisan","why":"Too terse","job":13}' \
    "$(state_get '.decisions[] | select(.kind == "review-gate") | {status, choice, redirect, by, why, job}' | jq -c .)"
  # A rework ticket of its own, in scope and queued, for an agent.
  assert_eq "in-run,ready-for-agent" "$(labels "$rw")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$rw.json")" "- [ ] Greet by name"
  assert_eq "queued 0" "$(state_get ".tickets[\"$rw\"] | \"\(.status) \(.attempts)\"")"
  assert_eq true "$(state_get ".plan.scope | index(\"$rw\") != null")"
  assert_eq "1" "$(state_get ".plan.tickets[\"$rw\"].rework_of")"
  # It holds the gate's dependent (the closed gate no longer does), and runs first.
  assert_eq "[1,$num,$rw]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_eq "3 $rw" "$(frontier)"
  # Its attempts are its own: the original's stay as they were.
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" "$rw" "$(start_worker)" >/dev/null
  assert_eq "1 1" "$(state_get ".tickets[\"$rw\"].attempts, .tickets[\"1\"].attempts" | tr '\n' ' ' | sed 's/ $//')"
  # Redirecting twice is refused: the gate is closed.
  assert_status 6 "$A" redirect "$RUN_DIR" "$num" --notes again
}

test_redirect_mine_puts_the_rework_ready_for_human() {
  setup_run
  local num= rw=
  num=$(open_slice_gate)
  rw=$("$A" redirect "$RUN_DIR" "$num" --mine --by Andrew)
  assert_eq "in-run,ready-for-human" "$(labels "$rw")"
  assert_eq self "$(state_get '.decisions[] | select(.kind == "review-gate") | .redirect')"
  # Held for the Artisan: never on the frontier.
  assert_eq "3" "$(frontier)"
}

test_bypass_closes_the_gate_unreviewed_and_records_who() {
  setup_run
  local num=
  num=$(open_slice_gate)
  "$A" bypass "$RUN_DIR" "$num" --by Andrew --why "Trivial slice" >/dev/null
  assert_eq closed "$(issue_state "$num")"
  assert_eq '{"status":"bypassed","by":"Andrew","why":"Trivial slice","cards":0}' \
    "$(state_get '.review_gates[0] | {status, by: .bypass.by, why: .bypass.why, cards: (.decisions | length)}' | jq -c .)"
  assert_eq "gate-bypassed Andrew" "$(state_get '.events[-1] | "\(.event) \(.by)"')"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-$num.md")" "Bypassed by Andrew"
  assert_eq "2 3" "$(frontier)"
}

test_a_deferred_gate_closed_on_the_tracker_by_hand_is_approved_at_the_next_sync() {
  setup_run
  local num= cards=
  num=$(open_slice_gate)
  cards=$(state_get '.review_gates[0].cards | length')
  "$A" defer "$RUN_DIR" "$num" --by Andrew --why "Busy today" >/dev/null
  gh issue close "$num" -R local/sample
  "$G" sync "$RUN_DIR" >/dev/null
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_eq "Artisan (closed on the tracker)" "$(state_get '.review_gates[0].decisions[-1].by')"
  assert_eq "$cards" "$(state_get '.review_gates[0].carried | length')"
  assert_eq "No gate is deferred." "$("$A" deferred "$RUN_DIR")"
  # Nothing released or held: the dependents that already ran stay released.
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
}

test_the_sweep_syncs_a_run_whose_only_review_gate_is_deferred() {
  setup_run
  local num= out=
  num=$(open_slice_gate)
  "$A" defer "$RUN_DIR" "$num" --by Andrew --why "Busy today" >/dev/null
  gh issue close "$num" -R local/sample
  out=$(ARTISAN_REPO=local/sample "$PLUGIN_ROOT/scripts/chats.sh" sweep --chat engineering --no-fetch --project "$PROJECT")
  assert_contains "$out" "Gate #$num closed on GitHub: treated as approved"
  assert_eq approved "$(state_get '.review_gates[0].status')"
}

test_defer_releases_the_dependents_and_keeps_the_gate_for_the_end_gate() {
  setup_run
  local num= out= rw=
  num=$(open_slice_gate)
  "$A" defer "$RUN_DIR" "$num" --by Andrew --why "Busy today" >/dev/null
  # The issue stays open but no longer blocks; the dependent runs.
  assert_eq open "$(issue_state "$num")"
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_eq deferred "$(state_get '.review_gates[0].status')"
  assert_eq "2 3" "$(frontier)"
  assert_eq '{"status":"decided","choice":"defer"}' \
    "$(state_get '.decisions[] | select(.kind == "review-gate") | {status, choice}' | jq -c .)"
  # Listed for the end gate.
  out=$("$A" deferred "$RUN_DIR")
  assert_contains "$out" "| Slice gate: greeting (run r1) | #$num | slice | Andrew | Busy today | #2 |"
  assert_status 6 "$A" defer "$RUN_DIR" "$num"
  # At the end gate a card can still become a rework ticket, which doesn't
  # hold the dependents that already ran; then keep all closes it.
  rw=$("$G" change "$RUN_DIR" "$num" 1 "hello.txt")
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_eq queued "$(state_get ".tickets[\"$rw\"].status")"
  "$G" approve "$RUN_DIR" "$num" >/dev/null
  assert_eq closed "$(issue_state "$num")"
  assert_eq "No gate is deferred." "$("$A" deferred "$RUN_DIR")"
}

test_actions_wait_while_a_wave_holds_the_lock() {
  setup_run
  local num= other=
  num=$(open_slice_gate)
  other=$(start_worker)
  "$SCRIPTS/state.sh" unlock "$RUN_DIR" "$CHAT" 2>/dev/null || true
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$other"
  assert_status 3 "$A" bypass "$RUN_DIR" "$num"
  assert_eq open "$(issue_state "$num")"
  assert_eq open "$(jq -r .review_gates[0].status "$RUN_DIR/state.json")"
}

# ------------------------------------------------------------ exception gates

# Ticket 3 failed both attempts, as the sweep leaves it.
gave_up_on_3() {
  "$SCRIPTS/state.sh" update "$RUN_DIR" "$STATE_JQ_DEFS"'
    .tickets["3"].attempts = 1 | failed_attempt("3"; "attempt 1 did not complete (failed crashed)"; 100)
    | .tickets["3"].attempts = 2 | failed_attempt("3"; "verifier: t3.txt is empty"; 200)'
}

test_a_ticket_failing_twice_raises_an_exception_gate_that_cannot_be_removed() {
  setup_run
  # No gates in the plan at all: exception gates are never the plan's to remove.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = []'
  gave_up_on_3
  local out= num= body=
  out=$("$A" sync "$RUN_DIR")
  num=$(state_get '.exception_gates[0].issue')
  assert_eq "opened #$num exception-1" "$out"
  assert_eq "Exception gate: run r1 gave up on #3 after 2 attempts" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq review-gate "$(labels "$num")"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_contains "$body" "| exception | Engineering | #3 (Ticket 3) | #4 (Ticket 4) |"
  assert_contains "$body" "| 2 | verifier: t3.txt is empty |"
  for c in "retry with notes" "reslice" "take it myself" "drop" "bypass" "defer"; do
    assert_contains "$body" "| $c |"
  done
  # It natively holds the ticket's dependents; the exception decision names it.
  assert_eq "[3,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")"
  assert_eq "$num exception-1" "$(state_get '.decisions[0] | "\(.issue) \(.gate)"')"
  # Syncing again opens nothing new.
  assert_eq "" "$("$A" sync "$RUN_DIR")"
  # Never approved or redirected: bypassed, deferred or decided.
  assert_status 6 "$A" approve "$RUN_DIR" "$num"
  assert_status 6 "$A" redirect "$RUN_DIR" "$num" --notes x
  out=$("$A" chat "$RUN_DIR")
  assert_contains "$out" "The run gave up on #3 after 2 attempts. Holds #4."
  assert_contains "$out" "| take it myself |"
}

test_the_exception_choices_leave_the_ticket_and_dependents_as_stated() {
  local choice=
  for choice in take reslice drop bypass defer; do
    rm -rf "$TEST_TMPDIR/project" "$TEST_TMPDIR/tracker"
    setup_run
    gave_up_on_3
    "$A" sync "$RUN_DIR" >/dev/null
    local num=
    num=$(state_get '.exception_gates[0].issue')
    "$A" "$choice" "$RUN_DIR" "$num" --by Andrew >/dev/null
    case "$choice" in
      take)
        assert_eq "queued closed" "$(state_get '.tickets["3"].status') $(issue_state "$num")"
        assert_eq "in-run,ready-for-human" "$(labels 3)"
        assert_eq self "$(state_get '.decisions[0].redirect')"
        assert_eq "1" "$(frontier)" "take: held for the Artisan, 4 still waits" ;;
      reslice)
        assert_eq "resliced closed" "$(state_get '.tickets["3"].status') $(issue_state "$num")"
        assert_eq "needs-triage,ready-for-agent" "$(labels 3)"
        assert_eq "[3]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")" "reslice: 4 keeps its blocker, not the closed gate"
        assert_eq "sent_back needs-triage,ready-for-agent" "$(state_get '.tickets["4"].status') $(labels 4)" "reslice: 4 goes back to triage" ;;
      drop)
        assert_eq "dropped closed" "$(state_get '.tickets["3"].status') $(issue_state "$num")"
        assert_eq "ready-for-agent" "$(labels 3)"
        assert_eq "open" "$(issue_state 3)"
        assert_eq "1" "$(frontier)" "drop: 4 is out of the run, not on the frontier"
        assert_eq "sent_back needs-triage,ready-for-agent" "$(state_get '.tickets["4"].status') $(labels 4)" "drop: 4 goes back to triage" ;;
      bypass)
        assert_eq "bypassed closed" "$(state_get '.tickets["3"].status') $(issue_state "$num")"
        assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")"
        assert_eq "Andrew" "$(state_get '.exception_gates[0].bypass.by')"
        assert_eq '[{"dependent":"4","blocker":"'"$num"'"},{"dependent":"4","blocker":"3"}]' \
          "$(state_get '.exception_gates[0].bypass.released' | jq -c .)"
        assert_eq "1 4" "$(frontier)" ;;
      defer)
        assert_eq "deferred open" "$(state_get '.tickets["3"].status') $(issue_state "$num")"
        assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")"
        assert_eq "1 4" "$(frontier)"
        assert_contains "$("$A" deferred "$RUN_DIR")" "| #$num | exception | Andrew |" ;;
    esac
    assert_eq "decided Andrew 15" "$(state_get '.decisions[0] | "\(.status) \(.by) \(.job)"')" "$choice"
    kill_workers
  done
}

test_a_gate_closed_by_hand_on_the_tracker_is_a_bypass() {
  setup_run
  gave_up_on_3
  "$A" sync "$RUN_DIR" >/dev/null
  local num=
  num=$(state_get '.exception_gates[0].issue')
  gh issue close "$num" -R local/sample
  "$A" sync "$RUN_DIR" >/dev/null
  assert_eq "bypassed bypassed" "$(state_get '"\(.exception_gates[0].status) \(.tickets["3"].status)"')"
  assert_eq "Artisan (closed on the tracker)" "$(state_get '.exception_gates[0].bypass.by')"
}

# ------------------------------------------------------- end to end, scripted

# Role scripts: a worker builds t<N>.txt; ticket 3's worker fails unless its
# prompt carries the Artisan's notes. A verifier passes everything. The
# orchestrator dispatches the frontier, retries failed attempts, verifies,
# merges and closes, then reports.
write_role_scripts() {
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
t=${key%%.*}
if [ "$t" = 3 ] && ! grep -q "Say hello in plain text" "$ARTISAN_RUN_DIR/prompts/$key.md"; then exit 1; fi
echo hi >"t$t.txt"
git add -A && git commit -q -m "worker $t"
jq -n --arg c "$(git rev-parse HEAD)" --arg t "$t" '{ticket: $t, status: "complete", commit: $c,
  acceptance: [{criterion: "t\($t).txt exists", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
EOF
  export FAKE_CLAUDE_SCRIPT_VERIFIER="$TEST_TMPDIR/verifier.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
set -e
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
jq '{verdict: "pass", acceptance: [.[] | {criterion: ., met: true,
    evidence: {checks: [{command: "sh check.sh", result: "suite ok"}]}}], unsure: []}' \
  "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF
  export FAKE_CLAUDE_SCRIPT_ORCHESTRATOR="$TEST_TMPDIR/orchestrator.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_ORCHESTRATOR" <<EOF
set -euo pipefail
S="$SCRIPTS"
R="\$ARTISAN_RUN_DIR"
inflight() { jq '[.tickets[] | select(.status == "in_flight")] | length' "\$R/state.json"; }
verify() {
  local rc=
  "\$S/verify.sh" start "\$R" "\$1" >/dev/null || return 1
  while :; do
    rc=0
    "\$S/verify.sh" judge "\$R" "\$1" >/dev/null 2>&1 || rc=\$?
    case \$rc in 0) return 0 ;; 8) sleep 0.2 ;; *) return 1 ;; esac
  done
}
for i in \$(seq 1 150); do
  "\$S/sweep.sh" "\$R"
  ready=\$("\$S/reconcile.sh" "\$R")
  for t in \$ready; do "\$S/wave.sh" dispatch "\$R" "\$t" >/dev/null 2>&1 || true; done
  [ "\$(inflight)" -gt 0 ] || [ -n "\$ready" ] || break
  "\$S/wait-any.sh" "\$R" --timeout 2 >/dev/null || true
done
for t in \$(jq -r '.tickets | to_entries[] | select(.value.status == "returned") | .key' "\$R/state.json"); do
  n=\$(jq -r --arg t "\$t" '.tickets[\$t].attempts' "\$R/state.json")
  while [ "\$("\$S/classify-worker.sh" "\$R" "\$t" "\$n")" = "running -" ]; do sleep 0.2; done
  if verify "\$t" && "\$S/wave.sh" merge "\$R" "\$t" >/dev/null; then "\$S/wave.sh" close "\$R" "\$t"; fi
done
"\$S/wave.sh" report "\$R" >"\$ARTISAN_RESULT_FILE"
EOF
}

run_wave() { # wave
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >/dev/null
  wait_for "$RUN_DIR/results/orchestrator-w$1.1.exit.json" 120
}

test_a_run_gives_up_parks_behind_its_reviews_and_retries_with_notes() {
  setup_run
  write_role_scripts
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  local out= ex= slice= prompt=
  # Wave 1: 1 merges (its slice gate holds 2); 3 fails twice (its exception
  # gate holds 4). Everything left waits on the two reviews: the run parks.
  run_wave 1
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_eq "merged blocked 2" "$(state_get '"\(.tickets["1"].status) \(.tickets["3"].status) \(.tickets["3"].attempts)"')"
  ex=$(state_get '.exception_gates[0].issue')
  slice=$(state_get '.review_gates[0].issue')
  [ "$ex" != null ] && [ "$slice" != null ] || fail "both gates should be open: $out"
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked: waiting on 2 reviews: "
  assert_contains "$out" "Slice gate: greeting (run r1) #$slice"
  assert_contains "$out" "Exception gate: run r1 gave up on #3 after 2 attempts #$ex"
  assert_contains "$out" "3 tickets wait behind them: #2, #3, #4"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked")] | length')"
  # Retry with notes: a fresh worker, its prompt carrying the notes, one more attempt.
  "$A" retry "$RUN_DIR" "$ex" --notes "Say hello in plain text" --by Andrew >/dev/null
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: launch"
  run_wave 2
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  prompt="$RUN_DIR/prompts/3.3.md"
  assert_contains "$(cat "$prompt")" "- Say hello in plain text (exception gate #$ex)"
  assert_contains "$(cat "$prompt")" "attempt 3 of 3"
  assert_eq "merged 3" "$(state_get '"\(.tickets["3"].status) \(.tickets["3"].attempts)"')"
  # Only the slice gate is left: 2 waits on it, 4 is free and runs.
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: launch"
  assert_eq "4" "$(state_get '.frontier | join(" ")')"
}

test_a_seeded_check_that_wont_go_green_raises_an_exception_gate() {
  # The suite fails once t3.txt exists: merging #3 can never go green.
  setup_run '[ ! -e t3.txt ] && echo suite ok'
  write_role_scripts
  sed -i.bak 's/if \[ "$t" = 3 \].*fi$/:/' "$FAKE_CLAUDE_SCRIPT_WORKER"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = []'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  local out= num=
  run_wave 1
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$(state_get '.tickets["3"].blocked_reason')" "the suite failed after merging"
  num=$(state_get '.exception_gates[0].issue')
  [ "$num" != null ] || fail "no exception gate: $out"
  assert_eq "Exception gate: #3's check won't go green (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq red-check "$(state_get '.exception_gates[0].reason')"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")" "The suite log: \`merges/3.1.suite.log\`"
  # It holds only #3's dependent: #2 runs in wave 2, then the run parks on it.
  assert_contains "$out" "next: launch"
  run_wave 2
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_eq merged "$(state_get '.tickets["2"].status')"
  assert_contains "$out" "parked: waiting on 1 review: Exception gate: #3's check won't go green (run r1) #$num; 2 tickets wait behind it: #3, #4"
}

# ---------------------------------------------- dependents leave with a drop (#116)

# 3 is blocked-by chain: 4 depends on 3, and 2 on 4 (and 1).
chain_run() {
  setup_run
  echo '[3]' >"$FAKE_GH_DIR/blocked_by-4.json"
  echo '[1,4]' >"$FAKE_GH_DIR/blocked_by-2.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = [{kind: "slice", slice: "greeting", tickets: ["1","2"]}]'
  gave_up_on_3
  "$A" sync "$RUN_DIR" >/dev/null
  GATE_NO=$(state_get '.exception_gates[0].issue')
}

test_a_drop_lists_what_leaves_with_it_before_it_applies() {
  chain_run
  local choice= out=
  for choice in drop reslice; do
    [ "$choice" = drop ] || { kill_workers; rm -rf "$TEST_TMPDIR/project" "$TEST_TMPDIR/tracker"; chain_run; }
    # The gate's table row says it too.
    assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$GATE_NO.json")" "#2, #4 (everything that depends on it"
    out=$("$A" "$choice" "$RUN_DIR" "$GATE_NO" --by Andrew)
    # The impact comes before the confirmation line.
    assert_eq "Impact: #2, #4 depend on #3, directly or through others, so they leave the run with it and go back to needs-triage. Not every slice survives (slice \"greeting\" loses #2), so it cannot be reviewed end to end as planned." \
      "$(printf '%s\n' "$out" | sed -n 1p)" "$choice"
    assert_contains "$(printf '%s\n' "$out" | sed -n 2p)" "it leaves the run; #2, #4 go back to needs-triage with it"
    assert_eq "sent_back sent_back" "$(state_get '"\(.tickets["2"].status) \(.tickets["4"].status)"')" "$choice: B and C are out of the run"
    assert_eq "needs-triage" "$(labels 4 | tr ',' '\n' | grep -x needs-triage)" "$choice"
    assert_eq "needs-triage" "$(labels 2 | tr ',' '\n' | grep -x needs-triage)" "$choice"
    assert_eq "" "$(labels 4 | tr ',' '\n' | grep -x in-run || true)" "$choice"
    assert_contains "$(cat "$FAKE_GH_DIR/comments-4.md")" "Taken out of run r1: it depends on #3, which was"
    assert_contains "$(cat "$FAKE_GH_DIR/comments-4.md")" "grilled again"
    assert_eq "[3]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")" "$choice: native blockers kept, the closed gate's edge gone"
    assert_eq "sent-back 2 3" "$(state_get '[.events[] | select(.event == "sent-back")][0] | "\(.event) \(.ticket) \(.from)"')"
    if [ "$choice" = drop ]; then
      assert_eq "open ready-for-agent" "$(issue_state 3) $(labels 3)" "A open, unlabelled by the run"
    else
      assert_contains "$(labels 3)" needs-triage
    fi
  done
}

test_a_drop_with_no_dependents_says_so() {
  setup_run
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = []'
  echo '[]' >"$FAKE_GH_DIR/blocked_by-4.json"
  gave_up_on_3
  "$A" sync "$RUN_DIR" >/dev/null
  local out=
  out=$("$A" drop "$RUN_DIR" "$(state_get '.exception_gates[0].issue')")
  assert_contains "$out" "Impact: Nothing else in the run depends on #3. Every slice can still be reviewed end to end."
}

# The old way: A dropped, its dependents left queued behind it.
seed_stranded() {
  setup_run
  echo '[3]' >"$FAKE_GH_DIR/blocked_by-4.json"
  echo '[4]' >"$FAKE_GH_DIR/blocked_by-2.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = []
    | .tickets["1"].status = "merged" | .tickets["3"].status = "dropped"'
}

test_stranded_tickets_give_next_stranded_never_a_bare_blocked() {
  seed_stranded
  local out=
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: stranded"
  assert_contains "$out" "#3 dropped: #2, #4 can't start"
  assert_contains "$out" "gate-action.sh send-back $RUN_DIR"
  case "$out" in *"next: blocked"*|*"next: done"*) fail "stranded run reported: $out" ;; esac
}

test_send_back_clears_the_stranded_and_the_run_reaches_done() {
  seed_stranded
  local out=
  out=$("$A" send-back "$RUN_DIR" --by Andrew)
  assert_contains "$out" "sent back to needs-triage, out of the run: #2, #4 (stranded behind #3)"
  assert_eq "sent_back sent_back" "$(state_get '"\(.tickets["2"].status) \(.tickets["4"].status)"')"
  assert_contains "$(labels 2)" needs-triage
  assert_contains "$(cat "$FAKE_GH_DIR/comments-2.md")" "depends on #3"
  assert_eq "dropped" "$(state_get '.tickets["3"].status')"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: done"
  assert_contains "$("$A" send-back "$RUN_DIR")" "No ticket is stranded."
}

test_bypass_still_lets_dependents_go_ahead() {
  chain_run
  "$A" bypass "$RUN_DIR" "$GATE_NO" --by Andrew >/dev/null
  assert_eq "queued" "$(state_get '.tickets["4"].status')"
  assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-4.json")"
  assert_eq "1 4" "$(frontier)"
}

# ------------------------------------------- guardrail health events (#122)

test_a_redirect_logs_a_gate_decision_to_change_with_the_tickets_areas_and_a_flagged_bug() {
  setup_run
  local num=
  num=$(open_slice_gate)
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].areas = ["uploads"]'
  "$A" redirect "$RUN_DIR" "$num" --notes "Greet by name" --bug --by Andrew >/dev/null
  assert_eq '{"card":null,"outcome":"change","redirect":true,"areas":["uploads"],"by":"Andrew"}' \
    "$(state_get '.events[] | select(.event == "gate-decision") | {card, outcome, redirect, areas, by}' | jq -c .)"
  assert_eq '{"ticket":"1","areas":["uploads"],"where":"gate","gate":"slice-1"}' \
    "$(state_get '.events[] | select(.event == "bug-found") | {ticket, areas, where, gate}' | jq -c .)"
}

test_an_exception_gate_the_scope_floor_opened_logs_guardrail_fired_and_its_bypass_guardrail_bypassed() {
  setup_run
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = []'
  gave_up_on_3
  # The exception was raised because the ticket would add scope.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.decisions[0].guardrail = "scope-floor"'
  "$A" sync "$RUN_DIR" >/dev/null
  num=$(state_get '.exception_gates[0].issue')
  assert_eq '[{"guardrail":"scope-floor"}]' "$(state_get '.exception_gates[0].guardrails' | jq -c .)"
  assert_eq '{"guardrail":"scope-floor","gate":"exception-1","tickets":["3"]}' \
    "$(state_get '.events[] | select(.event == "guardrail-fired") | {guardrail, gate, tickets}' | jq -c .)"
  "$A" bypass "$RUN_DIR" "$num" --by Andrew --why "the extra field is tiny" >/dev/null
  assert_eq "guardrail-bypassed scope-floor the extra field is tiny Andrew" \
    "$(state_get '.events[-1] | "\(.event) \(.guardrail) \(.reason) \(.by)"')"
}

test_an_exception_gate_no_guardrail_opened_logs_no_guardrail_event_and_retry_can_flag_a_bug() {
  setup_run
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = [] | .plan.tickets["3"].areas = ["auth"]'
  gave_up_on_3
  "$A" sync "$RUN_DIR" >/dev/null
  num=$(state_get '.exception_gates[0].issue')
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")" "| retry or take, a bug |"
  "$A" retry "$RUN_DIR" "$num" --notes "check the token expiry" --bug >/dev/null
  assert_eq 0 "$(state_get '[.events[] | select(.event | startswith("guardrail"))] | length')"
  assert_eq '{"ticket":"3","areas":["auth"],"where":"gate","gate":"exception-1"}' \
    "$(state_get '.events[] | select(.event == "bug-found") | {ticket, areas, where, gate}' | jq -c .)"
  assert_status 2 "$A" defer "$RUN_DIR" "$num" --bug
}
