# questions.sh: decisions a worker may not make (#61). A worker files a
# needs-triage ticket; a ticket that can't finish waits on it while the wave
# carries on; the answer redispatches it; a deferral asks "pull or carry on";
# reversible taste comes back as a provisional card. Fake `claude` and a
# folder tracker (fake `gh`) stand in for the real ones.

. "$TESTS_DIR/helpers/run-state.sh"

Q="$PLUGIN_ROOT/scripts/questions.sh"

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-30} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

cleanup() {
  local pid
  for pid in $(cat "$RUN_DIR"/workers/*/runner.pid 2>/dev/null); do
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
  kill_workers
}

# Tickets 1 and 2 in a run r1 on a fake tracker; 1's worker meets a decision.
setup_questions() {
  make_project
  printf '#!/bin/sh\necho "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n
  for n in 1 2; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}], body: "- [ ] it works"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2"],
    waves: [["1", "2"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh",
    orchestrator: {estimate_usd: 0.25},
    tickets: {
      "1": {title: "Ticket 1", expected_files: ["one.txt"], model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}},
      "2": {title: "Ticket 2", expected_files: ["two.txt"], model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

file_blocking() { # ticket
  "$Q" file --ticket "$1" --criterion 3 --question "Add a runtime dependency on left-pad?" \
    --option "Add it" --option "Write the six lines ourselves" --recommendation "Write them ourselves" --blocking \
    --repo local/sample
}

# A blocked ticket 1 with its worker's blocking question logged, as the sweep would.
blocked_with_question() {
  setup_questions
  export ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/1.jsonl"
  Q1=$(file_blocking 1)
  unset ARTISAN_FINDINGS_FILE
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked" | .tickets["1"].attempts = 1 | .tickets["2"].status = "returned"'
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
}

test_a_worker_files_a_needs_triage_ticket_with_question_options_recommendation_and_criterion() {
  setup_questions
  local n body
  n=$(file_blocking 1)
  assert_eq 3 "$n"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$n.json")
  assert_contains "$body" "Add a runtime dependency on left-pad?"
  assert_contains "$body" "1. Add it"
  assert_contains "$body" "2. Write the six lines ourselves"
  assert_contains "$body" "## Recommendation"
  assert_contains "$body" "Write them ourselves"
  assert_contains "$body" "3: criterion 3"
  assert_contains "$body" "Blocked by this question"
  assert_eq needs-triage "$(jq -r '.labels[0].name' "$FAKE_GH_DIR/issue-$n.json")"
}

test_an_always_ask_item_names_itself_as_the_criterion() {
  setup_questions
  local n
  n=$("$Q" file --ticket 1 --criterion always-ask --question "Rename the public flag?" \
    --option "Rename" --option "Keep" --recommendation "Keep" --split --repo local/sample)
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$n.json")" 'an "Always ask" item'
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$n.json")" "split off"
}

test_filing_needs_two_options_a_criterion_and_a_mode() {
  setup_questions
  assert_status 1 "$Q" file --ticket 1 --criterion 3 --question q --option a --recommendation r --blocking
  assert_status 1 "$Q" file --ticket 1 --criterion 9 --question q --option a --option b --recommendation r --blocking
  assert_status 2 "$Q" file --ticket 1 --criterion 3 --question q --option a --option b --recommendation r
}

test_a_split_question_leaves_the_worker_free_to_finish() {
  setup_questions
  export ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/1.jsonl"
  "$Q" file --ticket 1 --criterion 7 --question "Which of two designs?" --option a --option b \
    --recommendation a --split --repo local/sample >/dev/null
  assert_contains "$(cat "$ARTISAN_FINDINGS_FILE")" '"blocking":false'
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "returned"'
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  assert_eq returned "$(state_get '.tickets["1"].status')"
  # Not blocking: nothing to block the ticket on.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked"'
  assert_status 1 "$Q" block "$RUN_DIR" 1
}

test_a_ticket_that_cant_finish_is_blocked_by_the_new_ticket_while_the_wave_carries_on() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "#$Q1"
  assert_eq "[$Q1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-1.json")"
  assert_eq waiting "$(state_get '[.decisions[] | select(.kind == "question")][0].status')"
  # The rest of the wave is untouched and still moves on.
  assert_eq returned "$(state_get '.tickets["2"].status')"
  [ ! -e "$FAKE_GH_DIR/blocked_by-2.json" ] || fail "ticket 2 was blocked too"
  # Asking twice changes nothing.
  local before
  before=$(state_sum)
  "$Q" block "$RUN_DIR" 1
  assert_eq "$before" "$(state_sum)"
  assert_contains "$("$Q" list "$RUN_DIR")" "| #$Q1 | #1 | blocks it | open | - |"
}

test_block_refuses_a_ticket_with_no_question() {
  setup_questions
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked"'
  assert_status 1 "$Q" block "$RUN_DIR" 1
  assert_status 1 "$Q" block "$RUN_DIR" 2
}

test_an_answer_from_triage_redispatches_the_ticket_with_it() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  # Still open: nothing changes.
  assert_eq "open #1 #$Q1" "$("$Q" sync "$RUN_DIR")"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  # Triage answers it: an Answer: comment, and the ticket closed.
  printf 'Some discussion.\n---\nAnswer: Write the six lines ourselves.\nNo new dependency.' >"$FAKE_GH_DIR/comments-$Q1.md"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$Q1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$Q1.json"
  assert_eq "answered #1 #$Q1" "$("$Q" sync "$RUN_DIR")"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq resolved "$(state_get '[.decisions[] | select(.kind == "question")][0].status')"
  assert_contains "$(state_get '.tickets["1"].answers[0].answer')" "Write the six lines ourselves."
  assert_eq "answered" "$(state_get '.events[] | select(.event == "answered") | .event')"
  # The next worker is told the answer, and it is not described as a retry.
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  local script="$TEST_TMPDIR/worker.sh"
  echo 'exit 0' >"$script"
  export FAKE_CLAUDE_SCRIPT_WORKER=$script
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  local prompt
  prompt=$(cat "$RUN_DIR/prompts/1.2.md")
  assert_contains "$prompt" "The Artisan has answered"
  assert_contains "$prompt" "#$Q1: Write the six lines ourselves."
  case "$prompt" in *"This is a retry"*) fail "an answered ticket is not a retry" ;; esac
  assert_eq 2 "$(state_get '.tickets["1"].attempts')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')"
}

test_a_question_closed_without_an_answer_goes_to_the_artisan() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$Q1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$Q1.json"
  assert_eq "closed #1 #$Q1" "$("$Q" sync "$RUN_DIR")"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq 1 "$(state_get '[.decisions[] | select(.closed_unanswered == true)] | length')"
}

defer_the_question() {
  jq '.labels += [{name: "deferred"}]' "$FAKE_GH_DIR/issue-$Q1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$Q1.json"
}

test_deferring_a_blocking_finding_asks_pull_or_carry_on() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  defer_the_question
  assert_eq "deferred #1 #$Q1" "$("$Q" sync "$RUN_DIR")"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq 1 "$(state_get '[.decisions[] | select(.kind == "defer-question" and .status == "waiting")] | length')"
  assert_contains "$(state_get '[.decisions[] | select(.kind == "defer-question")][0].question')" "Pull ticket 1 from the run"
  assert_contains "$(state_get '[.decisions[] | select(.kind == "defer-question")][0].question')" '"not now"'
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_status 2 "$Q" deferred "$RUN_DIR" 1 maybe
}

test_pulling_the_ticket_defers_it_with_the_finding_and_leaves_the_run() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  defer_the_question
  "$Q" sync "$RUN_DIR" >/dev/null
  "$Q" deferred "$RUN_DIR" 1 pull
  assert_eq deferred "$(state_get '.tickets["1"].status')"
  assert_eq '["2"]' "$(state_get '.plan.scope | tostring')"
  assert_eq resolved "$(state_get '[.decisions[] | select(.kind == "defer-question")][0].status')"
  local labels
  labels=$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_DIR/issue-1.json")
  assert_contains "$labels" deferred
  case "$labels" in *in-run*) fail "in-run stayed on a ticket pulled from the run" ;; esac
  # The comment carries the contract triage's deferred-due.sh reads.
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "Return condition: blocked-by #$Q1"
  # It stays blocked on the tracker; the run won't dispatch it.
  assert_eq "[$Q1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-1.json")"
  assert_status 4 "$SCRIPTS/state.sh" in-scope "$RUN_DIR" 1
}

test_carrying_on_redispatches_the_ticket_with_not_now() {
  blocked_with_question
  "$Q" block "$RUN_DIR" 1
  defer_the_question
  "$Q" sync "$RUN_DIR" >/dev/null
  "$Q" deferred "$RUN_DIR" 1 carry
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq "not now" "$(state_get '.tickets["1"].answers[0].answer')"
  assert_eq '["1","2"]' "$(state_get '.plan.scope | tostring')"
  assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-1.json")"
  local labels
  labels=$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_DIR/issue-1.json")
  assert_contains "$labels" in-run
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  echo 'exit 0' >"$TEST_TMPDIR/worker.sh"
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "#$Q1: not now"
}

test_a_reversible_taste_choice_is_a_provisional_card_at_the_next_slice_gate() {
  setup_questions
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["1"].status = "merged"
    | .tickets["1"].evidence = {decisions: [
        {question: "Which file name?", choice: "hello.txt", alternative: "HELLO", criterion: "4", confidence: "provisional"},
        {question: "Add a column?", choice: "No", alternative: "Yes", criterion: "2", confidence: "provisional"},
        {question: "Sure thing", choice: "x", alternative: "y", criterion: "4", confidence: "firm"}]}'
  local out
  out=$("$Q" provisional "$RUN_DIR")
  assert_contains "$out" "| Ticket | Question | Picked | Alternative | Criterion | Confidence |"
  assert_contains "$out" "| #1 | Which file name? | hello.txt | HELLO | 4 | provisional |"
  case "$out" in *"Add a column"*|*"Sure thing"*) fail "only provisional criteria 4, 6, 7 are cards" ;; esac
  # Shown once: the next gate doesn't repeat it.
  "$Q" provisional "$RUN_DIR" --shown >/dev/null
  case "$("$Q" provisional "$RUN_DIR")" in *"Which file name"*) fail "shown twice" ;; esac
}

test_the_whole_flow_with_real_workers() {
  setup_questions
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<EOF
set -e
case "\$(basename "\$ARTISAN_RESULT_FILE")" in
  1.1.*)
    $Q file --ticket 1 --criterion 3 --question "Add a dependency?" --option yes --option no \\
      --recommendation no --blocking --repo local/sample >/dev/null
    jq -n '{ticket: "1", status: "blocked", commit: null, acceptance: [], unsure: ["needs the dependency answer"],
            decisions: [], findings: [], review: {ran: false, remarks: []}}' >"\$ARTISAN_RESULT_FILE" ;;
  *)
    echo hi >"f-\$\$.txt"; git add -A; git commit -q -m w
    jq -n --arg c "\$(git rev-parse HEAD)" '{ticket: "2", status: "complete", commit: \$c, acceptance: [], findings: []}' >"\$ARTISAN_RESULT_FILE" ;;
esac
EOF
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json"
  wait_for "$RUN_DIR/results/2.1.exit.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq returned "$(state_get '.tickets["2"].status')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')"
  "$Q" block "$RUN_DIR" 1
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq returned "$(state_get '.tickets["2"].status')"
  assert_eq "$(jq -r '.title' "$FAKE_GH_DIR/issue-3.json")" "Question from #1: Add a dependency?"
}
