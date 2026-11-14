# Findings shared between workers: relay, triage, late facts, design stops.

. "$TESTS_DIR/helpers/run-state.sh"

setup() {
  trap kill_workers EXIT
  init_run
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  local n=
  for n in 10 11 12; do
    printf '{"number":%s,"title":"T%s","body":"","state":"open","labels":[]}\n' "$n" "$n" >"$FAKE_GH_DIR/issue-$n.json"
  done
  worker10=$(start_worker)
  worker11=$(start_worker)
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$worker10"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 11 "$worker11"
}

finding() { # from json
  printf '%s\n' "$2" >>"$RUN_DIR/results/findings/$1.jsonl"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
}

test_a_finding_about_an_in_flight_ticket_is_relayed_and_logged_on_both_tickets() {
  setup
  finding 10 '{"title":"parse() drops blanks","why":"Callers must trim first.","blocks":["11"]}'
  local line=
  line=$("$SCRIPTS/findings.sh" pending "$RUN_DIR")
  assert_eq 1 "$(printf '%s\n' "$line" | wc -l | tr -d ' ')"
  assert_eq relay "$(printf '%s' "$line" | jq -r .action)"
  assert_eq worker-11 "$(printf '%s' "$line" | jq -r .name)"
  assert_contains "$(printf '%s' "$line" | jq -r .message)" "Callers must trim first."
  "$SCRIPTS/findings.sh" mark "$RUN_DIR" 10 1 11 relay
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "parse() drops blanks"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-11.md")" "parse() drops blanks"
  assert_eq relay "$(state_get '.relays[0].action')"
  assert_eq finding "$(state_get '.events[-1].event')"
  # Handled once: nothing pending, and marking again posts nothing more.
  assert_eq "" "$("$SCRIPTS/findings.sh" pending "$RUN_DIR")"
  "$SCRIPTS/findings.sh" mark "$RUN_DIR" 10 1 11 relay
  assert_eq 1 "$(state_get '.relays | length')"
  assert_eq 1 "$(grep -c 'parse() drops' "$FAKE_GH_DIR/comments-11.md")"
}

test_a_finding_about_a_finished_ticket_becomes_a_needs_triage_ticket() {
  setup
  # 11's worker finishes and its work is merged.
  printf '{"ticket":"11","status":"complete","commit":"abc"}' >"$RUN_DIR/results/11.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 11 deadbeef
  finding 10 '{"title":"11 left a stale cache","why":"Reads are wrong.","blocks":["11"]}'
  assert_eq triage "$("$SCRIPTS/findings.sh" pending "$RUN_DIR" | jq -r .action)"
  "$SCRIPTS/findings.sh" mark "$RUN_DIR" 10 1 11 triage
  assert_contains "$(cat "$FAKE_GH_DIR/issue-13.json")" needs-triage
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-13.json")" "11 left a stale cache"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "filed for triage"
  [ ! -e "$FAKE_GH_DIR/comments-11.md" ] || fail "a finished ticket was commented on as if relayed"
  assert_eq triage "$(state_get '.relays[0].action')"
  assert_contains "$(state_get '.relays[0].issue')" "/issues/13"
}

test_a_finding_about_a_queued_ticket_is_a_comment_and_names_no_worker() {
  setup
  finding 10 '{"title":"Use the shared parser","why":"12 should too.","blocks":["12"]}'
  local line=
  line=$("$SCRIPTS/findings.sh" pending "$RUN_DIR")
  assert_eq comment "$(printf '%s' "$line" | jq -r .action)"
  assert_eq null "$(printf '%s' "$line" | jq -r .name)"
}

test_a_finding_that_names_no_ticket_is_left_for_triage_between_waves() {
  setup
  finding 10 '{"title":"Add a retry","why":"Flaky.","blocks":[]}'
  assert_eq "" "$("$SCRIPTS/findings.sh" pending "$RUN_DIR")"
}

test_a_fact_in_result_notes_is_logged_once_as_a_finding() {
  setup
  "$SCRIPTS/findings.sh" add "$RUN_DIR" 10 "Config is read twice" "Noted in 10's notes, not acted on." 11
  "$SCRIPTS/findings.sh" add "$RUN_DIR" 10 "Config is read twice" "Noted in 10's notes, not acted on." 11
  assert_eq 1 "$(state_get '.findings | length')"
  assert_eq result-notes "$(state_get '.findings[0].source')"
  assert_eq relay "$("$SCRIPTS/findings.sh" pending "$RUN_DIR" | jq -r .action)"
}

test_a_fact_added_after_a_worker_line_without_a_newline_keeps_both() {
  setup
  printf '{"title":"A","why":"a","blocks":["12"]}' >"$RUN_DIR/results/findings/10.jsonl"
  "$SCRIPTS/findings.sh" add "$RUN_DIR" 10 "B" "b" 12
  assert_eq 2 "$(state_get '.findings | length')"
  assert_eq A "$(state_get '.findings[0].title')"
}

test_a_design_question_blocks_the_ticket_queues_it_and_notes_a_slicing_lesson() {
  setup
  jq -n '{ticket: "10", status: "blocked", notes: "stopped",
          design_question: {question: "Should Store.get() return a Result?", recommendation: "Yes, in a ticket that owns Store"}}' \
    >"$RUN_DIR/results/10.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq blocked "$(state_get '.tickets["10"].status')"
  assert_eq design "$(state_get '.decisions[-1].kind')"
  assert_eq 10 "$(state_get '.decisions[-1].ticket')"
  assert_contains "$(state_get '.decisions[-1].question')" "Store.get()"
  assert_eq slicing "$(state_get '.lessons[0].kind')"
  assert_contains "$(state_get '.lessons[0].note')" "design"
  # Sweeping again changes nothing.
  local before=
  before=$(state_sum)
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq "$before" "$(state_sum)"
}

test_a_plain_blocked_result_is_not_a_design_stop() {
  setup
  printf '{"ticket":"10","status":"blocked","notes":"x"}' >"$RUN_DIR/results/10.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 0 "$(state_get '.lessons | length')"
}

test_a_finding_with_no_blocks_list_is_skipped_and_the_next_one_is_listed_and_marked() {
  setup
  finding 10 '{"title":"A note with no blocks","why":"Recorded by the verifier."}'
  finding 10 '{"title":"Use the shared parser","why":"12 should too.","blocks":["12"]}'
  local out= rc=0
  out=$("$SCRIPTS/findings.sh" pending "$RUN_DIR") || rc=$?
  assert_eq 0 "$rc"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_eq 2 "$(printf '%s' "$out" | jq -r .seq)"
  assert_eq comment "$(printf '%s' "$out" | jq -r .action)"
  "$SCRIPTS/findings.sh" mark "$RUN_DIR" 10 2 12 comment
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Use the shared parser"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-12.md")" "Use the shared parser"
  assert_eq comment "$(state_get '.relays[0].action')"
  assert_eq 2 "$(state_get '.relays[0].seq')"
  assert_eq finding "$(state_get '.events[-1].event')"
}

test_a_finding_whose_blocks_is_null_or_not_a_list_is_skipped() {
  setup
  finding 10 '{"title":"Null blocks","why":"x","blocks":null}'
  finding 10 '{"title":"String blocks","why":"x","blocks":"12"}'
  finding 10 '{"title":"Object blocks","why":"x","blocks":{"12":true}}'
  finding 10 '{"title":"Use the shared parser","why":"12 should too.","blocks":["12"]}'
  local out= rc=0
  out=$("$SCRIPTS/findings.sh" pending "$RUN_DIR") || rc=$?
  assert_eq 0 "$rc"
  assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_eq 4 "$(printf '%s' "$out" | jq -r .seq)"
}
