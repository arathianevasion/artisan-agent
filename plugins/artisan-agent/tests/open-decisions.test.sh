# Open decisions (#227): controversy criterion 8 and the one way to file one,
# `questions.sh file --criterion 8`. A worker, the plan step, a verifier, a
# gate or a finding files the case, the harm and one recommendation, and
# nothing more. Fake `gh` (a folder tracker) stands in for the real one.
# ADR 0002 holds the rule; references/open-decisions.md the cases.

. "$TESTS_DIR/helpers/run-state.sh"

Q="$PLUGIN_ROOT/scripts/questions.sh"
CRITERIA="$PLUGIN_ROOT/references/controversy-criteria.md"
OPEN="$PLUGIN_ROOT/references/open-decisions.md"
IMPLEMENT="$PLUGIN_ROOT/skills/implement/SKILL.md"
EVIDENCE="$PLUGIN_ROOT/references/evidence-record.md"

# A fake tracker holding tickets 1 and 2, with no run.
fake_tracker() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [], body: "- [ ] it works"}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  unset ARTISAN_RUN_ID ARTISAN_FINDINGS_FILE
}

# Tickets 1 and 2 in a run r1 on the fake tracker.
run_with_tracker() {
  make_project
  fake_tracker
  jq -n '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2"],
    waves: [["1", "2"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "true",
    orchestrator: {estimate_usd: 0.25},
    tickets: {
      "1": {title: "Ticket 1", areas: ["billing"], expected_files: ["one.txt"], model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}},
      "2": {title: "Ticket 2", expected_files: ["two.txt"], model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  ARTISAN_WRITER_PID=$(start_worker)
  export ARTISAN_WRITER_PID
  trap kill_workers EXIT
}

issue_count() { ls "$FAKE_GH_DIR" | grep -c '^issue-' || true; }
body_of() { jq -r .body "$FAKE_GH_DIR/issue-$1.json"; }

file_open() { # ticket mode [more args]
  local t="$1" mode="$2"
  shift 2
  "$Q" file --ticket "$t" --criterion 8 --case incomplete \
    --harm "The Export button offers PDF, and nothing can render a PDF yet" \
    --recommendation "Hide the PDF option until the renderer lands" "$mode" --repo local/sample "$@"
}

open_decision_events() { state_get '[.events[] | select(.event == "guardrail-fired" and .guardrail == "open-decision")]'; }

test_criterion_8_files_a_needs_triage_ticket_with_the_case_harm_and_recommendation() {
  fake_tracker
  local n= body= mode=
  for mode in --blocking --split; do
    n=$(file_open 1 "$mode")
    body=$(body_of "$n")
    assert_contains "$body" "## Case"
    assert_contains "$body" "incomplete"
    assert_contains "$body" "## Harm"
    assert_contains "$body" "nothing can render a PDF yet"
    assert_contains "$body" "## Recommendation"
    assert_contains "$body" "Hide the PDF option until the renderer lands"
    assert_contains "$body" "8: an open decision"
    assert_eq needs-triage "$(jq -r '.labels[0].name' "$FAKE_GH_DIR/issue-$n.json")"
    assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-$n.json")" "Open decision in #1"
    case "$body" in *"## Options"*) fail "an open decision holds no options: researching them is the Decision chat's work" ;; esac
  done
  assert_contains "$(body_of 3)" "Blocked by this open decision"
  assert_contains "$(body_of 4)" "split off"
}

test_every_case_is_accepted_and_an_unknown_one_refused() {
  fake_tracker
  local c=
  for c in incomplete misaligned invented adr; do
    "$Q" file --ticket 1 --criterion 8 --case "$c" --harm h --recommendation r --split --repo local/sample >/dev/null \
      || fail "case $c refused"
  done
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case unclear --harm h --recommendation r --split --repo local/sample
}

test_a_filing_with_no_case_or_no_harm_is_refused_and_files_nothing() {
  fake_tracker
  local before=
  before=$(issue_count)
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --harm h --recommendation r --blocking --repo local/sample
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --recommendation r --blocking --repo local/sample
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --harm "" --recommendation r --split --repo local/sample
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --harm "  " --recommendation r --split --repo local/sample
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --harm h --recommendation " " --split --repo local/sample
  assert_eq "$before" "$(issue_count)"
}

test_an_open_decision_holds_nothing_more_than_case_harm_and_recommendation() {
  fake_tracker
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --harm h --recommendation r --split \
    --option a --option b --repo local/sample
  assert_status 1 "$Q" file --ticket 1 --criterion 8 --case adr --harm h --split --repo local/sample
  # The case and harm belong to criterion 8 only.
  assert_status 1 "$Q" file --ticket 1 --criterion 3 --case adr --harm h --question q --option a --option b \
    --recommendation r --split --repo local/sample
}

test_it_files_with_no_run_and_names_another_ticket_without_blocking_it() {
  fake_tracker
  local n= body=
  n=$(file_open 2 --non-blocking --raised-by finding --from 1)
  body=$(body_of "$n")
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-$n.json")" "Open decision in #2"
  assert_contains "$body" "Raised at: finding"
  assert_contains "$body" "the worker of #1"
  assert_contains "$body" "Filed without blocking #2"
  case "$body" in *"(run "*) fail "no run: the body names none" ;; esac
  # The plan step files with no run too.
  n=$(file_open 2 --non-blocking --raised-by plan)
  assert_contains "$(body_of "$n")" "Raised at: plan"
}

test_only_a_worker_blocks_its_own_ticket_and_a_finding_never_blocks() {
  fake_tracker
  local before= r=
  before=$(issue_count)
  for r in plan verifier gate finding; do
    assert_status 1 file_open 2 --blocking --raised-by "$r" --from 1
  done
  assert_status 1 file_open 2 --split --raised-by finding --from 1
  assert_status 1 file_open 2 --non-blocking --raised-by finding
  assert_status 1 file_open 2 --split --raised-by somewhere
  # A worker's own ticket blocks or splits; non-blocking is for another ticket's.
  assert_status 1 file_open 1 --non-blocking
  # Non-blocking is criterion 8's form; criteria 1-7 keep blocking or split.
  assert_status 1 "$Q" file --ticket 1 --criterion 3 --question q --option a --option b --recommendation r \
    --non-blocking --repo local/sample
  assert_eq "$before" "$(issue_count)"
}

test_each_raiser_is_recorded_where_it_was_raised() {
  fake_tracker
  local r= n=
  for r in plan verifier gate; do
    n=$(file_open 1 --split --raised-by "$r")
    assert_contains "$(body_of "$n")" "Raised at: $r"
  done
  n=$(file_open 1 --blocking)
  assert_contains "$(body_of "$n")" "Raised at: worker"
}

test_a_filing_with_a_run_logs_the_open_decision_guardrail_firing() {
  run_with_tracker
  local n=
  n=$(file_open 1 --split --raised-by gate --run "$RUN_DIR")
  assert_contains "$(body_of "$n")" "(run r1)"
  assert_eq 1 "$(open_decision_events | jq length)"
  assert_eq "1 gate incomplete $n billing" \
    "$(open_decision_events | jq -r '.[0] | "\(.ticket) \(.raised_by) \(.case) \(.question) \(.areas | join(","))"')"
}

test_a_workers_open_decision_logs_the_guardrail_once_at_the_sweep() {
  run_with_tracker
  export ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/1.jsonl" ARTISAN_RUN_ID=r1
  local q1= q2=
  q1=$(file_open 1 --split)
  q2=$(file_open 2 --non-blocking --raised-by finding --from 1)
  unset ARTISAN_FINDINGS_FILE ARTISAN_RUN_ID
  assert_contains "$(body_of "$q1")" "(run r1)"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  assert_eq 2 "$(open_decision_events | jq length)"
  assert_eq "1 worker incomplete $q1 null" \
    "$(open_decision_events | jq -r '.[0] | "\(.ticket) \(.raised_by) \(.case) \(.question) \(.from)"')"
  assert_eq "2 finding incomplete $q2 1" \
    "$(open_decision_events | jq -r '.[1] | "\(.ticket) \(.raised_by) \(.case) \(.question) \(.from)"')"
  # A split or non-blocking open decision gives the orchestrator nothing to block on.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked"'
  assert_status 1 "$Q" block "$RUN_DIR" 1
}

test_a_blocking_open_decision_blocks_the_ticket_as_a_worker_question_does() {
  run_with_tracker
  export ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/1.jsonl"
  local q= dep=
  q=$(file_open 1 --blocking)
  unset ARTISAN_FINDINGS_FILE
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked" | .tickets["1"].attempts = 1'
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  "$Q" block "$RUN_DIR" 1
  assert_eq "$q" "$(state_get '.tickets["1"].questions[0].ticket')"
  assert_eq "waiting on the answer to #$q" "$(state_get '.tickets["1"].blocked_reason')"
}

test_a_criterion_8_card_is_never_a_provisional_card() {
  run_with_tracker
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["1"].status = "merged"
    | .tickets["1"].evidence = {decisions: [
        {question: "Ship PDF export?", choice: "Yes", alternative: "No", criterion: "8", confidence: "provisional"},
        {question: "Which file name?", choice: "a.txt", alternative: "b.txt", criterion: "4", confidence: "provisional"}]}'
  local out=
  out=$("$Q" provisional "$RUN_DIR")
  assert_contains "$out" "Which file name?"
  case "$out" in *"Ship PDF export"*) fail "a criterion-8 card was shown as provisional" ;; esac
  assert_contains "$(cat "$CRITERIA")" "Criterion 8 is never picked provisionally"
  assert_contains "$(cat "$EVIDENCE")" "never \`provisional\`"
}

test_the_evidence_record_checker_refuses_a_provisional_criterion_8_card() {
  local out="" status=0
  awk '/^## Example/ { f = 1; next } f && /^```json/ { g = 1; next } g && /^```/ { exit } g' "$EVIDENCE" \
    | jq '.decisions[0].criterion = "8" | .decisions[0].confidence = "provisional"' >card.json
  out=$("$TESTS_DIR/implement/check-evidence-record.sh" card.json) || status=$?
  assert_eq 1 "$status"
  assert_contains "$out" "decisions[0]: criterion 8 (an open decision) is never provisional"
  jq '.decisions[0].confidence = "firm"' card.json >firm.json
  "$TESTS_DIR/implement/check-evidence-record.sh" firm.json || fail "a firm criterion-8 card is a valid card"
}

# ------------------------------------------------------------------ static

test_criterion_8_is_added_and_criteria_1_to_7_keep_their_numbers_and_wording() {
  local body=
  body=$(cat "$CRITERIA")
  assert_contains "$body" '1. **Contradicts a recorded decision**: a grilled ticket, an ADR, the glossary or a guardrail.'
  assert_contains "$body" '2. **Adds scope**, unless the addition is minimal and reversible, or there are only one or a few sensible ways to do the work and the addition is moderate.'
  assert_contains "$body" '3. **Is hard to reverse**: schema or data changes, a public interface, a new dependency, anything shipping irreversibly.'
  assert_contains "$body" '4. **Is taste no guardrail covers.**'
  assert_contains "$body" '5. **Is a "stop and ask"** named in the ticket.'
  assert_contains "$body" '6. **Can only be judged by using the thing.**'
  assert_contains "$body" '7. **Is a priority call, a wontfix, or a choice between two reasonable designs.**'
  assert_contains "$body" '8. **Is an open decision**'
  assert_contains "$body" "When in doubt, it's the execution agent's call"
  assert_contains "$body" "for criterion 8 only"
  assert_contains "$body" "**When in doubt, it's controversial.**"
}

test_one_reference_holds_the_cases_the_harm_bar_and_what_is_not_open_and_both_cite_it() {
  local body=
  body=$(cat "$OPEN")
  assert_contains "$body" "## The four cases"
  assert_contains "$body" '`incomplete`'
  assert_contains "$body" '`misaligned`'
  assert_contains "$body" '`invented`'
  assert_contains "$body" '`adr`'
  assert_contains "$body" "## The named-harm bar"
  assert_contains "$body" "## Not an open decision"
  assert_contains "$body" "docs/adr/0002-open-decisions-go-to-the-decision-chat.md"
  assert_contains "$(cat "$CRITERIA")" '${CLAUDE_PLUGIN_ROOT}/references/open-decisions.md'
  assert_contains "$(cat "$IMPLEMENT")" '${CLAUDE_PLUGIN_ROOT}/references/open-decisions.md'
}

test_the_implement_skill_keeps_ambiguous_readings_as_cards_and_builds_only_seams_that_are_not_adr_worthy() {
  local body=
  body=$(tr '\n' ' ' <"$IMPLEMENT")
  assert_contains "$body" "every reading you chose of an ambiguous acceptance criterion, unless the decision is open"
  assert_contains "$body" "only when it isn't ADR-worthy"
  assert_contains "$body" "An ADR-worthy seam is an open decision"
  assert_contains "$body" "--criterion 8"
}

# ------------------------------------------------------------ rulings (#228)

# Ticket 1 blocked by its worker's blocking open decision, as the sweep and
# the orchestrator leave it; ticket 2 depends on ticket 1 on the tracker.
# Sets OD to the open decision's number.
blocked_by_open_decision() {
  run_with_tracker
  export ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/1.jsonl"
  OD=$(file_open 1 --blocking)
  unset ARTISAN_FINDINGS_FILE
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  jq '.labels = [{name: "in-run"}]' "$FAKE_GH_DIR/issue-1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-1.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "blocked" | .tickets["1"].attempts = 1'
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  "$Q" block "$RUN_DIR" 1
}

# rule <question> <comment>: the Decision chat's ruling comment, then closed.
rule() {
  printf '%s' "$2" >>"$FAKE_GH_DIR/comments-$1.md"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$1.json"
}

labels_of() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH_DIR/issue-$1.json"; }

test_a_reject_pulls_the_original_from_the_run_back_to_triage_and_its_dependents_wait() {
  blocked_by_open_decision
  rule "$OD" $'> *This was generated by AI during triage.*\n\nReject: the ticket must say which formats Export offers.\nTook the recommendation: no\nNeeded the Decision chat: yes'
  assert_eq "rejected #1 #$OD" "$("$Q" sync "$RUN_DIR")"
  local labels=""
  labels=$(labels_of 1)
  assert_contains "$labels" needs-triage
  case "$labels" in *in-run*) fail "in-run stayed on a rejected ticket" ;; esac
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "#$OD"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "the ticket must say which formats Export offers."
  assert_eq sent_back "$(state_get '.tickets["1"].status')"
  assert_eq "$OD" "$(state_get '.tickets["1"].sent_back.from')"
  assert_eq '["2"]' "$(state_get '.plan.scope | tostring')"
  assert_status 4 "$SCRIPTS/state.sh" in-scope "$RUN_DIR" 1
  assert_eq rejected "$(state_get '.tickets["1"].questions[0].state')"
  assert_eq resolved "$(state_get '[.decisions[] | select(.kind == "question")][0].status')"
  # Its dependent waits: still in the run, still queued, its edge kept.
  assert_eq queued "$(state_get '.tickets["2"].status')"
  assert_eq '[1]' "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  # Once only.
  local before=""
  before=$(state_sum)
  assert_eq "" "$("$Q" sync "$RUN_DIR")"
  assert_eq "$before" "$(state_sum)"
}

test_an_add_ticket_unblocks_the_original_and_queues_it_with_not_covered_here() {
  blocked_by_open_decision
  local added=""
  added=$(gh issue create -R local/sample --title "PDF export" --body "the case" --label needs-triage)
  added=${added##*/}
  rule "$OD" "Add ticket: #$added
Took the recommendation: yes
Needed the Decision chat: yes"
  assert_eq "added #1 #$OD #$added" "$("$Q" sync "$RUN_DIR")"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq "not covered here" "$(state_get '.tickets["1"].answers[0].answer')"
  assert_eq "$added" "$(state_get '.tickets["1"].questions[0].added')"
  assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-1.json")"
  assert_eq '["1","2"]' "$(state_get '.plan.scope | tostring')"
  assert_contains "$(labels_of 1)" in-run
  # The added ticket is triaged as usual: sync leaves it alone.
  assert_eq needs-triage "$(labels_of "$added")"
}

test_a_reject_after_the_work_merged_files_a_follow_up_and_pulls_nothing() {
  run_with_tracker
  jq '.labels = [{name: "in-run"}]' "$FAKE_GH_DIR/issue-1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-1.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "merged"'
  local od="" before_issues="" n=""
  od=$(file_open 1 --split --raised-by gate --run "$RUN_DIR")
  # The open decision is on ticket 1's questions, as a gate's triage records it.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].questions = [{ticket: "'"$od"'", blocking: false, state: "open", at: "2026-11-15T00:00:00Z"}]'
  rule "$od" $'Reject: Export must not offer PDF at all.\nTook the recommendation: no\nNeeded the Decision chat: yes'
  before_issues=$(issue_count)
  n=$((before_issues + 1))
  assert_eq "rejected #1 #$od follow-up #$n" "$("$Q" sync "$RUN_DIR")"
  assert_eq "$n" "$(issue_count)"
  assert_eq needs-triage "$(labels_of "$n")"
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-$n.json")" "#1"
  assert_contains "$(body_of "$n")" "#$od"
  assert_contains "$(body_of "$n")" "Export must not offer PDF at all."
  # Nothing pulled: still merged, in scope, labels as they were.
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq '["1","2"]' "$(state_get '.plan.scope | tostring')"
  assert_eq in-run "$(labels_of 1)"
  assert_eq "$n" "$(state_get '.tickets["1"].questions[0].follow_up')"
  # Once only: a second sync files nothing more.
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "$n" "$(issue_count)"
}

ruling_of() { # ticket question
  state_get '.tickets["'"$1"'"].questions[] | select(.ticket == "'"$2"'") | .ruling | "\(.kind) \(.took_recommendation) \(.needed_decision_chat)"'
}

test_sync_records_both_verdicts_of_each_ruling_in_the_runs_state() {
  blocked_by_open_decision
  # Defer, with its verdicts in the deferral comment.
  printf 'Deferred.\nReturn condition: next review on 2026-12-15\nTook the recommendation: yes\nNeeded the Decision chat: no' >"$FAKE_GH_DIR/comments-$OD.md"
  jq '.labels += [{name: "deferred"}]' "$FAKE_GH_DIR/issue-$OD.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$OD.json"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "defer true false" "$(ruling_of 1 "$OD")"
  # Then answered after all: the new ruling and its verdicts replace it.
  rule "$OD" $'\n---\nAnswer: Hide the PDF option.\nTook the recommendation: yes\nNeeded the Decision chat: yes'
  assert_eq "answered #1 #$OD" "$("$Q" sync "$RUN_DIR")"
  assert_eq "answer true true" "$(ruling_of 1 "$OD")"
  # The verdict lines are not part of the answer the next worker reads.
  assert_eq "Hide the PDF option." "$(state_get '.tickets["1"].answers[0].answer')"
  assert_eq 2 "$(state_get '[.events[] | select(.event == "ruled")] | length')"
  assert_eq "answer true true" "$(state_get '[.events[] | select(.event == "ruled")] | last | "\(.ruling) \(.took_recommendation) \(.needed_decision_chat)"')"
}

test_a_discard_records_its_verdicts_and_behaves_as_before() {
  blocked_by_open_decision
  rule "$OD" $'Not worth doing: nobody asked for PDF.\nTook the recommendation: no\nNeeded the Decision chat: no'
  assert_eq "closed #1 #$OD" "$("$Q" sync "$RUN_DIR")"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "discard false false" "$(ruling_of 1 "$OD")"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "ruled")] | length')"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
}

test_a_ruling_with_no_verdict_lines_records_them_as_unknown() {
  blocked_by_open_decision
  rule "$OD" "Answer: Hide it."
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "answer null null" "$(ruling_of 1 "$OD")"
}

test_the_triage_skill_lists_the_five_rulings_with_add_tickets_limit_and_both_verdicts() {
  local body="" section=""
  section=$(sed -n '/^## Worker questions/,/^## Ending a turn/p' "$PLUGIN_ROOT/skills/triage/SKILL.md")
  body=$(printf '%s' "$section" | tr '\n' ' ')
  local r=""
  for r in "**Answer**" "**Reject**" "**Add ticket**" "**Defer**" "**Discard**"; do
    assert_contains "$body" "$r"
  done
  assert_contains "$body" "Reject: <"
  assert_contains "$body" "Add ticket: #<"
  # Add ticket's limit on an incomplete-feature decision.
  assert_contains "$body" "doesn't expose the incomplete behaviour"
  assert_contains "$body" "lands before the run's end gate"
  # Every ruling records both verdicts.
  assert_contains "$body" "Took the recommendation: yes"
  assert_contains "$body" "Needed the Decision chat: yes"
  assert_contains "$body" "Every ruling records two verdicts"
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/references/open-decisions.md'
}

test_verdicts_written_after_the_deferral_label_still_reach_the_state() {
  blocked_by_open_decision
  jq '.labels += [{name: "deferred"}]' "$FAKE_GH_DIR/issue-$OD.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$OD.json"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "defer null null" "$(ruling_of 1 "$OD")"
  printf 'Return condition: next review on 2026-12-15\nTook the recommendation: no\nNeeded the Decision chat: yes' >"$FAKE_GH_DIR/comments-$OD.md"
  "$Q" sync "$RUN_DIR" >/dev/null
  assert_eq "defer false true" "$(ruling_of 1 "$OD")"
  # Still one ruling: its event carries the verdicts now.
  assert_eq 1 "$(state_get '[.events[] | select(.event == "ruled")] | length')"
  assert_eq "false true" "$(state_get '[.events[] | select(.event == "ruled")] | last | "\(.took_recommendation) \(.needed_decision_chat)"')"
}

test_an_add_ticket_that_names_no_ticket_is_not_taken_for_a_discard() {
  blocked_by_open_decision
  rule "$OD" $'Add ticket: the PDF case\nTook the recommendation: yes\nNeeded the Decision chat: yes'
  assert_eq "closed #1 #$OD" "$("$Q" sync "$RUN_DIR")"
  assert_eq "null" "$(state_get '.tickets["1"].questions[0].ruling')"
  assert_contains "$(state_get '[.decisions[] | select(.closed_unanswered == true)][0].question')" "Add ticket: line that names no ticket"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
}

test_a_reject_of_a_ticket_closed_without_a_merge_files_nothing() {
  run_with_tracker
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "closed"'
  local od="" before=""
  od=$(file_open 1 --split --raised-by gate --run "$RUN_DIR")
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].questions = [{ticket: "'"$od"'", blocking: false, state: "open", at: "2026-11-15T00:00:00Z"}]'
  rule "$od" "Reject: never mind."
  before=$(issue_count)
  assert_eq "rejected #1 #$od" "$("$Q" sync "$RUN_DIR")"
  assert_eq "$before" "$(issue_count)"
  assert_eq closed "$(state_get '.tickets["1"].status')"
  assert_eq rejected "$(state_get '.tickets["1"].questions[0].state')"
}
