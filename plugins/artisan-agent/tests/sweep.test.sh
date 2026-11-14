# The sweep: in-flight tickets, deadlines and findings.

. "$TESTS_DIR/helpers/run-state.sh"

test_a_worker_past_its_deadline_is_stopped_and_counted_as_a_failed_attempt() {
  trap kill_workers EXIT
  init_run
  local pid=
  pid=$(start_worker)
  ARTISAN_NOW=1000 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid" 1600
  # Before the deadline nothing happens.
  ARTISAN_NOW=1500 "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq in_flight "$(state_get '.tickets["10"].status')"
  kill -0 "$pid" 2>/dev/null || fail "worker stopped before its deadline"
  ARTISAN_NOW=1601 ARTISAN_STOP_GRACE=2 "$SCRIPTS/sweep.sh" "$RUN_DIR"
  ! kill -0 "$pid" 2>/dev/null || fail "worker still running past its deadline"
  assert_eq queued "$(state_get '.tickets["10"].status')"
  assert_eq null "$(state_get '.tickets["10"].pid')"
  assert_eq 1 "$(state_get '.tickets["10"].failures | length')"
  assert_contains "$(state_get '.tickets["10"].failures[0].reason')" deadline
}

test_the_last_allowed_attempt_failing_blocks_the_ticket_and_queues_a_decision() {
  init_run
  local dead=
  sleep 0 &
  dead=$!
  wait "$dead"
  ARTISAN_NOW=1000 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$dead" 5000
  ARTISAN_NOW=1100 "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq queued "$(state_get '.tickets["10"].status')"
  ARTISAN_NOW=1200 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$dead" 5000
  ARTISAN_NOW=1300 "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq blocked "$(state_get '.tickets["10"].status')"
  assert_eq 2 "$(state_get '.tickets["10"].failures | length')"
  assert_eq exception "$(state_get '.decisions[0].kind')"
  assert_eq 10 "$(state_get '.decisions[0].ticket')"
}

test_a_result_file_records_the_result_and_cost() {
  trap kill_workers EXIT
  init_run
  local pid=
  pid=$(start_worker)
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 11 "$pid"
  printf '{"ticket":"10","status":"complete","commit":"abc","total_cost_usd":1.25}' >"$RUN_DIR/results/10.1.result.json"
  printf '{"ticket":"11","status":"blocked","notes":"needs a decision","cost_usd":0.5}' >"$RUN_DIR/results/11.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq returned "$(state_get '.tickets["10"].status')"
  assert_eq abc "$(state_get '.tickets["10"].result.commit')"
  assert_eq blocked "$(state_get '.tickets["11"].status')"
  assert_eq 1.75 "$(state_get '.costs.workers_usd')"
  assert_eq 0 "$(state_get '.tickets["10"].failures | length')"
}

test_an_exit_record_without_a_result_is_a_failed_attempt() {
  trap kill_workers EXIT
  init_run
  local pid=
  pid=$(start_worker)
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid"
  printf '{"ticket":"10","exit_status":1}' >"$RUN_DIR/results/10.1.exit.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq queued "$(state_get '.tickets["10"].status')"
  assert_contains "$(state_get '.tickets["10"].failures[0].reason')" "without a result"
}

test_a_crashed_worker_that_wrote_nothing_is_a_failed_attempt() {
  init_run
  local dead=
  sleep 0 &
  dead=$!
  wait "$dead"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$dead"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq queued "$(state_get '.tickets["10"].status')"
  assert_contains "$(state_get '.tickets["10"].failures[0].reason')" "gone"
}

test_findings_are_logged_once_and_a_half_written_line_waits() {
  init_run
  printf '{"to":"11","text":"API returns 204"}\nnot json\n{"to":"12","te' >"$RUN_DIR/results/findings/10.jsonl"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 2 "$(state_get '.findings | length')"
  assert_eq "API returns 204" "$(state_get '.findings[0].text')"
  assert_eq 10 "$(state_get '.findings[0].from')"
  assert_eq "not json" "$(state_get '.findings[1].raw')"
  printf 'xt":"late"}\n' >>"$RUN_DIR/results/findings/10.jsonl"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 3 "$(state_get '.findings | length')"
  assert_eq late "$(state_get '.findings[2].text')"
  assert_eq 3 "$(state_get '.findings[2].seq')"
}

test_sweeping_twice_on_the_same_files_changes_nothing() {
  trap kill_workers EXIT
  init_run
  local pid= dead= first=
  pid=$(start_worker)
  sleep 0 &
  dead=$!
  wait "$dead"
  export ARTISAN_NOW=2000 ARTISAN_STOP_GRACE=2
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid" 1000
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 11 "$dead"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 12 "$pid" 9999
  printf '{"text":"a"}\n' >"$RUN_DIR/results/findings/12.jsonl"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  # The guard records its verdict once (#120); a second sweep a second later
  # reads the same and writes nothing, the guard's verdict included.
  first=$(cat "$RUN_DIR/state.json")
  export ARTISAN_NOW=3000
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq "$first" "$(cat "$RUN_DIR/state.json")" "state after a second sweep"
  assert_eq 2000 "$(state_get .usage_verdict.at)" "the verdict keeps the time it was first seen"
}

test_the_sweep_is_refused_while_another_writer_holds_the_lock() {
  trap kill_workers EXIT
  init_run
  local holder=
  holder=$(start_worker)
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$holder"
  assert_status 3 "$SCRIPTS/sweep.sh" "$RUN_DIR"
}

test_a_retry_is_not_failed_by_the_previous_attempts_files() {
  trap kill_workers EXIT
  init_run
  local pid=
  pid=$(start_worker)
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid" 9999999999
  printf '{"ticket":"10","exit_status":1}' >"$RUN_DIR/results/10.1.exit.json"
  printf '{"ticket":"10","status":"failed"}' >"$RUN_DIR/results/10.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq queued "$(state_get '.tickets["10"].status')"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid" 9999999999
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq in_flight "$(state_get '.tickets["10"].status')" "second attempt still running"
  assert_eq 1 "$(state_get '.tickets["10"].failures | length')"
}

test_stopping_a_worker_also_stops_its_descendants() {
  trap kill_workers EXIT
  init_run
  local tree= grandchild=
  # A worker whose child starts a grandchild, like run-ticket.sh -> claude -> a tool.
  bash -c 'bash -c "sleep 347 & echo \$! >\"$1/grandchild\"; wait" _ "$1" & wait' _ "$TEST_TMPDIR" >/dev/null 2>&1 &
  tree=$!
  printf '%s\n' "$tree" >>"$TEST_TMPDIR/.workers"
  while [ ! -s "$TEST_TMPDIR/grandchild" ]; do sleep 0.1; done
  grandchild=$(cat "$TEST_TMPDIR/grandchild")
  printf '%s\n' "$grandchild" >>"$TEST_TMPDIR/.workers"
  ARTISAN_NOW=1000 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$tree" 1100
  ARTISAN_NOW=1200 ARTISAN_STOP_GRACE=2 "$SCRIPTS/sweep.sh" "$RUN_DIR"
  sleep 0.5
  ! kill -0 "$grandchild" 2>/dev/null || fail "grandchild $grandchild survived the stop"
}

# qfind ticket-file criterion question: a question finding as questions.sh file writes it.
qfind() {
  jq -nc --arg c "$2" --arg q "$3" --arg by "$(basename "$1" .jsonl)" \
    '{kind: "question", ticket: $q, asked_by: $by, criterion: $c, blocking: false, title: ("Question #" + $q), why: "x", blocks: []}' >>"$1"
}

test_a_criterion_2_question_logs_scope_floor_fired_once_with_ticket_and_areas() {
  init_run
  jq '.plan.tickets["10"].areas = ["billing"]' "$RUN_DIR/state.json" >"$RUN_DIR/s.tmp" && mv "$RUN_DIR/s.tmp" "$RUN_DIR/state.json"
  qfind "$RUN_DIR/results/findings/10.jsonl" 2 77
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "guardrail-fired")] | length')"
  assert_eq "scope-floor 10 billing 77" "$(state_get '.events[] | select(.event == "guardrail-fired") | [.guardrail, .ticket, (.areas | join(",")), .question] | join(" ")')"
  # Sweeping again, and a later question, log only the new one.
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "guardrail-fired")] | length')"
  qfind "$RUN_DIR/results/findings/10.jsonl" 2 78
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq "77 78" "$(state_get '[.events[] | select(.event == "guardrail-fired") | .question] | join(" ")')"
}

test_other_criteria_log_no_guardrail_event() {
  init_run
  qfind "$RUN_DIR/results/findings/10.jsonl" 1 70
  qfind "$RUN_DIR/results/findings/10.jsonl" 3 71
  qfind "$RUN_DIR/results/findings/10.jsonl" always-ask 72
  printf '{"to":"11","text":"plain"}\n' >>"$RUN_DIR/results/findings/10.jsonl"
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq 4 "$(state_get '.findings | length')"
  assert_eq 0 "$(state_get '[.events[]? | select(.event == "guardrail-fired")] | length')"
}

test_health_shows_the_scope_floor_as_fired_after_a_scope_question() {
  init_run
  qfind "$RUN_DIR/results/findings/10.jsonl" 2 77
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/tc"
  mkdir -p "$ARTISAN_HOME"
  git_quiet -C "$ARTISAN_HOME" init
  git -C "$ARTISAN_HOME" symbolic-ref HEAD refs/heads/main
  jq -nc '{id: "scope-floor", key: "scope-floor", value: "on", rule: "r", strict: 1, origin: {date: "2026-01-01T00:00:00Z", reason: "seed", who: "Andrew"}, moves: []}' >"$ARTISAN_HOME/guardrails.jsonl"
  git_quiet -C "$ARTISAN_HOME" add -A
  git_quiet -C "$ARTISAN_HOME" commit -m seed
  cd "$PROJECT"
  assert_eq fired "$("$SCRIPTS/guardrail-health.sh" health --runs "$RUN_DIR" | jq -r '.guardrails[] | select(.key == "scope-floor") | .status')"
}

test_a_blocking_scope_question_filed_by_questions_sh_logs_it_for_a_ticket_with_no_areas() {
  init_run
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho https://github.com/owner/repo/issues/91\n' >"$TEST_TMPDIR/bin/gh"
  chmod +x "$TEST_TMPDIR/bin/gh"
  PATH="$TEST_TMPDIR/bin:$PATH" ARTISAN_FINDINGS_FILE="$RUN_DIR/results/findings/10.jsonl" \
    "$SCRIPTS/questions.sh" file --ticket 10 --criterion 2 --question "add export?" --option a --option b \
    --recommendation a --blocking >/dev/null
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq "scope-floor 10 0 91" "$(state_get '.events[] | select(.event == "guardrail-fired") | [.guardrail, .ticket, (.areas | length), .question] | join(" ")')"
}
