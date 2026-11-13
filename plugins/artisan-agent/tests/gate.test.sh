# gate.sh: slice gates (#65). Once every ticket of a slice has merged, a
# review-gate issue holds the packet and natively blocks only the slice's
# dependents; "keep all" approves and closes it, "change" on a card makes a
# rework ticket in the run. Fake `claude` (scripted per role) and fake `gh`
# (a folder tracker); nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

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

# Tickets: 1 is the slice "greeting"; 2 depends on it; 4 is outside the
# slice, and 3 depends only on 4. So once 1 and 4 merge, the gate holds 2
# and nothing else: 3 still dispatches.
setup_gate() {
  make_project
  printf '#!/bin/sh\necho "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3 4; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}],
      body: "## Acceptance criteria\n\n- [ ] t\($n).txt exists"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[4]' >"$FAKE_GH_DIR/blocked_by-3.json"
  jq -n '
    def t($n): {title: "Ticket \($n)", expected_output: "t\($n).txt", expected_files: ["t\($n).txt"],
                model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
                caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3", "4"],
     waves: [["1", "4"], ["2", "3"]], max_agents: 4, attempts_per_ticket: 2, suite_command: "sh check.sh",
     estimate_usd: 1, budget_usd: 1.25, orchestrator: {estimate_usd: 0.25},
     gates: [{kind: "slice", slice: "greeting", tickets: ["1"],
              problem: "Nobody is greeted.", solution: "t1.txt says hi."}],
     checks: [{command: "sh check.sh", covers: "the whole suite", proven_to_fail: true}],
     tickets: {"1": t(1), "2": t(2), "3": t(3), "4": t(4)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script
  # Guardrails are read from throwaway homes, never the machine's.
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  merge_gate_local "$ARTISAN_HOME"   # lib.sh's host.json is not read once ARTISAN_HOME moves
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

# A merged ticket with the evidence contract verify.sh judge would store.
merged_with_evidence() { # ticket
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets[$t] |= (.status = "merged" | .merge_commit = "abcdef1234567" | .cost_usd = 0.3
      | .suite = {command: "sh check.sh", passed: true, log: "x"}
      | .evidence = {ticket: $t, verdict: "pass",
          acceptance: [
            {criterion: "t\($t).txt exists", met: true, evidence: {tests: ["tests/t.sh: exists"]}},
            {criterion: "It reads well", met: true, evidence: {diff: "t\($t).txt +1 -0"}}],
          unsure: ["Whether hi needs a newline"],
          decisions: [
            {job: 3, question: "Which file name?", choice: "t\($t).txt", alternative: "T.TXT", by: "worker \($t)",
             kind: "engineering taste", criterion: "4", confidence: "provisional"},
            {job: 3, question: "Plain text or JSON?", choice: "Plain text", alternative: "JSON", by: "worker \($t)",
             kind: "engineering", criterion: "none", confidence: "firm"}],
          verifier: {unsure: ["Could not judge the tone"]}})' --arg t "$1"
}

# ------------------------------------------------------------ the packet

test_the_packet_follows_variant_b_top_to_bottom() {
  setup_gate
  merged_with_evidence 1
  local num= body= last=0 line= h=
  num=$("$G" open "$RUN_DIR" slice-1)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_eq "Slice gate: greeting (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq review-gate "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$num.json")" "one label, no per-kind label"
  # Header: kind in the title, role needed, tickets blocked.
  assert_contains "$body" "| slice | Engineering (QA) | #1 (Ticket 1) | #2 (Ticket 2) |"
  # Summary: counts, then Problem, Solution, Verification.
  assert_contains "$body" "**2 decisions (1 low confidence), 2 uncertainties.**"
  assert_contains "$body" "- **Problem:** Nobody is greeted."
  assert_contains "$body" "- **Verification:** 2 of 2 criteria verified across 1 ticket: 1 proven by a test or check, 1 needs you."
  # A card: question, choice, alternative, confidence, kind, actions.
  assert_contains "$body" "### Card 1: Which file name? (low confidence)"
  assert_contains "$body" "| Alternative considered | T.TXT |"
  assert_contains "$body" "| Confidence | **provisional (low)** |"
  assert_contains "$body" "| Kind | engineering taste |"
  assert_contains "$body" "keep · change (\`change 1 to <choice>\`) · make it a guardrail"
  assert_contains "$body" "| Confidence | firm |"
  # Evidence by criterion: proven or needs you; checks proven to fail; cost.
  assert_contains "$body" "| #1 | t1.txt exists | proven | tests/t.sh: exists |"
  assert_contains "$body" "| #1 | It reads well | **needs you** | - |"
  assert_contains "$body" "| \`sh check.sh\` | the whole suite | yes |"
  assert_contains "$body" "| #1 | \$0.30 | \$0.25 |"
  assert_contains "$body" "\`git diff abcdef1^1 abcdef1\`"
  # The sections, in variant B's order.
  for h in "| Gate | Role needed" "**2 decisions" "- **Problem:**" "- **Solution:**" "- **Verification:**" \
           "## Decisions" "### Card 1" "### Card 2" "## Uncertainties" "Could not judge the tone" "## Evidence" \
           "### By criterion" "### Guardrails applied" "### Checks proven to fail" "### Cost against estimate" \
           "### Diffs" "## Overall action"; do
    line=$(printf '%s\n' "$body" | grep -nF -- "$h" | head -1 | cut -d: -f1)
    [ -n "$line" ] || fail "missing section: $h"
    [ "$line" -gt "$last" ] || fail "out of order: $h (line $line, after line $last)"
    last=$line
  done
}

test_the_packet_names_the_areas_its_tickets_belong_to() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].areas = ["billing", "docs"]'
  local num= body=
  num=$("$G" open "$RUN_DIR" slice-1)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_contains "$body" "### Areas"
  assert_contains "$body" "| #1 | billing, docs |"
}

test_the_packet_has_no_areas_section_when_no_ticket_has_an_area() {
  setup_gate
  merged_with_evidence 1
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  assert_not_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")" "### Areas"
}

test_the_gate_blocks_only_the_slice_dependents_natively() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["4"].status = "merged"'
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  assert_eq "[1,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_eq "[4]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-3.json")"
  [ ! -f "$FAKE_GH_DIR/blocked_by-4.json" ] || fail "#4 is not a dependent"
  # Opening again opens nothing new.
  assert_eq "$num" "$("$G" open "$RUN_DIR" slice-1)"
  assert_eq "$num" "$(ls "$FAKE_GH_DIR"/issue-*.json | wc -l | tr -d ' ')"
  assert_eq "gate-opened" "$(jq -r '[.events[].event | select(. == "gate-opened")] | join(" ")' "$RUN_DIR/state.json")"
  assert_eq "review-gate" "$(state_get '.decisions[-1].kind')"
}

test_a_due_gate_not_yet_opened_still_holds_the_dependents() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["4"].status = "merged"'
  assert_eq slice-1 "$("$G" due "$RUN_DIR")"
  assert_eq held "$("$G" holds "$RUN_DIR" 1)"
  assert_eq free "$("$G" holds "$RUN_DIR" 4)"
  # The reconciler leaves #2 off the frontier, #3 stays on it.
  assert_eq 3 "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
}

test_a_gate_is_not_due_until_every_ticket_of_its_slice_has_merged() {
  setup_gate
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates[0].tickets = ["1", "4"]'
  merged_with_evidence 1
  assert_eq "" "$("$G" due "$RUN_DIR")"
  assert_status 6 "$G" open "$RUN_DIR" slice-1
  assert_eq "" "$("$G" sync "$RUN_DIR")"
}

# --------------------------------------------------- the chat and its answers

test_the_chat_shows_the_compressed_packet() {
  setup_gate
  merged_with_evidence 1
  local num= out=
  num=$("$G" open "$RUN_DIR" slice-1)
  out=$("$G" chat "$RUN_DIR")
  assert_contains "$out" "Slice gate: greeting (run r1) #$num: 2 decisions (1 low confidence), 2 uncertainties. Blocks #2 (Ticket 2)."
  assert_contains "$out" "| 1 | #1 | Which file name? → t1.txt | **provisional (low)** |"
  assert_contains "$out" "| 2 | #1 | Plain text or JSON? → Plain text | firm |"
  assert_eq "Keep all, or name one to change." "$(printf '%s\n' "$out" | tail -1)"
}

test_keep_all_approves_closes_and_records_each_decision_with_its_job_and_who() {
  setup_gate
  merged_with_evidence 1
  local num= out=
  num=$("$G" open "$RUN_DIR" slice-1)
  out=$("$G" approve "$RUN_DIR" "$num" --by Andrew)
  assert_eq "approved #$num: #2 can dispatch in the next wave" "$out"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-$num.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-$num.md")" "| 1 | #1 | 3 | keep: t1.txt | Andrew | worker 1 |"
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_eq 3 "$(state_get '.review_gates[0].decisions | length')"
  assert_eq true "$(state_get '.review_gates[0].decisions | all(.job != null and .by == "Andrew")')"
  assert_eq 13 "$(state_get '.review_gates[0].decisions[] | select(.outcome == "approve") | .job')"
  assert_eq decided "$(state_get '.decisions[] | select(.kind == "review-gate") | .status')"
  assert_eq free "$("$G" holds "$RUN_DIR" 1)"
  # Approving twice is refused.
  assert_status 6 "$G" approve "$RUN_DIR" "$num"
}

test_change_on_a_card_creates_a_rework_ticket_in_the_run() {
  setup_gate
  merged_with_evidence 1
  local num= rw=
  num=$("$G" open "$RUN_DIR" slice-1)
  rw=$("$G" change "$RUN_DIR" "$num" 1 "Name it greeting.txt" --why "Matches the feature")
  assert_eq "Rework #1: Which file name?" "$(jq -r .title "$FAKE_GH_DIR/issue-$rw.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$rw.json")" "- [ ] Name it greeting.txt, replacing: t1.txt"
  assert_contains "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$rw.json")" "in-run"
  # In the run: scope, a queued ticket, the original's model and caps.
  assert_eq true "$(jq -r --arg r "$rw" '.plan.scope | index($r) != null' "$RUN_DIR/state.json")"
  assert_eq queued "$(jq -r --arg r "$rw" '.tickets[$r].status' "$RUN_DIR/state.json")"
  assert_eq 1 "$(jq -r --arg r "$rw" '.plan.tickets[$r].rework_of' "$RUN_DIR/state.json")"
  assert_eq claude-sonnet-5-5 "$(jq -r --arg r "$rw" '.plan.tickets[$r].model' "$RUN_DIR/state.json")"
  # Its cost counts against the approved budget; raising that is the overrun gate's.
  assert_eq "1 1.25" "$(state_get '"\(.plan.estimate_usd) \(.plan.budget_usd)"')"
  # The dependents wait for the rework too.
  assert_eq "[1,$num,$rw]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  # The decision: the card's job, who changed it, what it was.
  assert_eq "3 Artisan change Name it greeting.txt t1.txt worker 1 Matches the feature" \
    "$(state_get '.review_gates[0].decisions[0] | "\(.job) \(.by) \(.outcome) \(.choice) \(.original.choice) \(.original.by) \(.why)"')"
  assert_eq rework "$(state_get '.events[-1].event')"
  # A decided card can't be decided again; approving keeps the rest.
  assert_status 6 "$G" change "$RUN_DIR" "$num" 1 "Something else"
  "$G" approve "$RUN_DIR" "$num" >/dev/null
  assert_eq "change keep approve" "$(state_get '[.review_gates[0].decisions[].outcome] | join(" ")')"
}

test_make_it_a_guardrail_keeps_the_card_and_notes_a_lesson() {
  setup_gate
  merged_with_evidence 1
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  assert_status 2 "$G" guardrail "$RUN_DIR" "$num" 2 product area
  "$G" guardrail "$RUN_DIR" "$num" 2 product area --area docs >/dev/null
  assert_eq "product area docs keep" "$(state_get '.review_gates[0].decisions[0] | "\(.guardrail_level) \(.reach) \(.area) \(.outcome)"')"
  assert_eq "guardrail 2 Plain text" "$(state_get '.lessons[-1] | "\(.kind) \(.card) \(.choice)"')"
}

test_an_answer_given_while_a_wave_holds_the_lock_is_folded_in_later() {
  setup_gate
  merged_with_evidence 1
  local num= other=
  num=$("$G" open "$RUN_DIR" slice-1)
  other=$(start_worker)
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$other"
  ARTISAN_WRITER_PID=$CHAT "$G" approve "$RUN_DIR" "$num" 2>"$TEST_TMPDIR/err" >/dev/null
  assert_contains "$(cat "$TEST_TMPDIR/err")" "folded into the state file at the next sync"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq open "$(state_get '.review_gates[0].status')"
  # The approval counts already: approving again is refused.
  assert_status 6 env ARTISAN_WRITER_PID=$CHAT "$G" change "$RUN_DIR" "$num" 1 x
  ARTISAN_WRITER_PID=$other "$G" sync "$RUN_DIR" >/dev/null
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_eq 0 "$(ls "$RUN_DIR/gates/pending" | wc -l | tr -d ' ')"
}

test_a_gate_closed_on_the_tracker_by_hand_is_approved_at_the_next_sync() {
  setup_gate
  merged_with_evidence 1
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  gh issue close "$num" -R local/sample
  "$G" sync "$RUN_DIR" >/dev/null
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_eq "Artisan (closed on the tracker)" "$(state_get '.review_gates[0].decisions[-1].by')"
}

test_a_gate_closed_by_hand_is_announced_in_one_line_and_its_cards_carry_to_the_end_gate() {
  setup_gate
  merged_with_evidence 1
  local num= cards= out=
  num=$("$G" open "$RUN_DIR" slice-1)
  cards=$(state_get '.review_gates[0].cards | length')
  [ "$cards" -ge 1 ] || fail "the seeded gate has no decision cards"
  gh issue close "$num" -R local/sample
  # The Product chat reads the line from the tracker alone, after the Engineering chat's sweep.
  out=$(ARTISAN_REPO=local/sample "$SCRIPTS/chats.sh" sweep --chat engineering --no-fetch --project "$PROJECT")
  assert_contains "$out" "Gate #$num closed on GitHub: treated as approved; $cards undecided card"
  assert_eq "$cards" "$(state_get '.review_gates[0].carried | length')"
  assert_eq approved "$(state_get '.review_gates[0].status')"
  assert_contains "$(state_get '.events[-1].event')" gate-approved
  out=$(ARTISAN_REPO=local/sample "$SCRIPTS/chats.sh" sweep --chat product --no-fetch --project "$PROJECT")
  assert_contains "$out" "Gate #$num closed on GitHub: treated as approved"
  # The end gate lists the cards the Artisan never decided.
  out=$("$G" carried "$RUN_DIR")
  assert_contains "$out" "| #$num (closed on GitHub) | 1 |"
}

test_gate_list_reads_the_tracker_across_runs_not_the_state_file() {
  setup_gate
  merged_with_evidence 1
  local num= out=
  num=$("$G" open "$RUN_DIR" slice-1)
  # A gate another run opened: in no state file here.
  jq -n '{number: 90, title: "Slice gate: other (run r9)", state: "open", labels: [{name: "review-gate"}],
    body: "| Gate | Role needed | Slice | Tickets blocked |\n|---|---|---|---|\n| slice | Product | #5 | - |"}' >"$FAKE_GH_DIR/issue-90.json"
  out=$("$G" list "$RUN_DIR")
  assert_contains "$out" "#$num (slice: greeting, run r1)"
  assert_contains "$out" "| Product | 13 Check a finished slice at a review gate | #90 (slice: other, run r9) | 1 |"
}

# ------------------------------------------------------- the run, end to end

write_role_scripts() {
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
t=$(basename "$ARTISAN_RESULT_FILE" | cut -d. -f1)
echo hi >"t$t.txt"
git add -A && git commit -q -m "worker $t"
jq -n --arg c "$(git rev-parse HEAD)" --arg t "$t" '{ticket: $t, status: "complete", commit: $c,
  acceptance: [{criterion: "t\($t).txt exists", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: ["Whether hi needs a newline"],
  decisions: [{job: 3, question: "Which file?", choice: "t\($t).txt", alternative: "T.TXT", by: "worker \($t)",
               kind: "engineering taste", criterion: "4", confidence: "provisional"}],
  review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
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
for t in \$("\$S/reconcile.sh" "\$R"); do "\$S/wave.sh" dispatch "\$R" "\$t" >/dev/null || true; done
while [ "\$(inflight)" -gt 0 ]; do
  "\$S/wait-any.sh" "\$R" --timeout 5 >/dev/null || true
  "\$S/sweep.sh" "\$R"
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
  wait_for "$RUN_DIR/results/orchestrator-w$1.1.exit.json" 90
}

test_a_run_holds_the_dependent_at_the_gate_and_releases_it_on_keep_all() {
  setup_gate
  write_role_scripts
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  local out= num=
  # Wave 1: 1 and 4 merge; closing 1 opens the gate, which holds only 2.
  run_wave 1
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  num=$(state_get '.review_gates[0].issue')
  [ "$num" != null ] || fail "no gate opened: $out"
  assert_eq "Slice gate: greeting (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq "[1,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_contains "$out" "next: launch"
  assert_contains "$out" "(review-gate)"
  # Wave 2: the independent 3 dispatches and merges; 2 waits.
  run_wave 2
  assert_eq merged "$(state_get '.tickets["3"].status')"
  assert_eq "queued 0" "$(state_get '.tickets["2"] | "\(.status) \(.attempts)"')"
  # Only gated work is left: the run parks on the review (#70).
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked: waiting on 1 review: Slice gate: greeting (run r1) #$num; 1 ticket waits behind it: #2"
  # The chat shows the compressed packet; keep all releases 2.
  assert_contains "$("$G" chat "$RUN_DIR")" "Keep all, or name one to change."
  "$G" approve "$RUN_DIR" "$num" >/dev/null
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: launch"
  run_wave 3
  assert_eq merged "$(state_get '.tickets["2"].status')"
  assert_eq "gate-opened gate-approved" "$(state_get '[.events[].event | select(startswith("gate-"))] | join(" ")')"
}

# ------------------------------------------- guardrail health events (#122)

test_a_gate_decision_carries_its_outcome_redirect_and_the_tickets_areas() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].areas = ["billing", "docs"]'
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  "$G" guardrail "$RUN_DIR" "$num" 2 product everywhere >/dev/null
  "$G" change "$RUN_DIR" "$num" 1 "Name it greeting.txt" --by Andrew >/dev/null
  assert_eq '[{"card":2,"outcome":"keep","redirect":false,"areas":["billing","docs"]},{"card":1,"outcome":"change","redirect":false,"areas":["billing","docs"]}]' \
    "$(state_get '[.events[] | select(.event == "gate-decision") | {card, outcome, redirect, areas}]' | jq -c .)"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "bug-found")] | length')"
}

test_flagging_a_change_as_a_bug_logs_bug_found_at_the_gate_in_the_same_write() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].areas = ["billing"]'
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  "$G" change "$RUN_DIR" "$num" 1 "Name it greeting.txt" --bug --by Andrew >/dev/null
  assert_eq '{"event":"bug-found","ticket":"1","areas":["billing"],"where":"gate","gate":"slice-1","by":"Andrew"}' \
    "$(state_get '.events[] | select(.event == "bug-found") | {event, ticket, areas, where, gate, by}' | jq -c .)"
  assert_eq true "$(state_get '.review_gates[0].decisions[0].bug')"
}

test_a_bug_found_at_the_end_gate_is_flagged_by_ticket() {
  setup_gate
  merged_with_evidence 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].areas = ["billing"]'
  "$G" bug "$RUN_DIR" 1 --gate end --by Andrew --why "totals off by a penny" >/dev/null
  assert_eq '{"ticket":"1","areas":["billing"],"where":"gate","gate":"end","by":"Andrew","why":"totals off by a penny"}' \
    "$(state_get '.events[-1] | {ticket, areas, where, gate, by, why}' | jq -c .)"
  assert_status 4 "$G" bug "$RUN_DIR" 99 --gate end
  assert_status 2 "$G" bug "$RUN_DIR" 1
}
