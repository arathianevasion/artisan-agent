# run-ticket.sh launches one capped headless worker detached and always
# leaves an exit record, however the worker ends. A fake `claude` stands in
# for the real one (tests/fixtures/fake-claude/claude).

setup_run() {
  RUN="$TEST_TMPDIR/run"
  WORKTREE="$TEST_TMPDIR/worktree"
  mkdir -p "$RUN" "$WORKTREE"
  # An approved plan with ticket 46 in scope: nothing launches without one.
  jq -n '{schema_version: 1, plan: {scope: ["46"]}}' >"$RUN/state.json"
  printf 'Build ticket 46.\n' >"$TEST_TMPDIR/prompt.md"
  PATH="$TESTS_DIR/fixtures/fake-claude:$PATH"
  export PATH
  export FAKE_CLAUDE_ARGS="$TEST_TMPDIR/claude.args"
  export FAKE_CLAUDE_ENV="$TEST_TMPDIR/claude.env"
  export FAKE_CLAUDE_PID="$TEST_TMPDIR/claude.pid"
  trap cleanup EXIT
}

# Stop anything a test left running: the runner and its worker's group.
cleanup() {
  kill_test_processes
}

run_ticket() {
  "$PLUGIN_ROOT/scripts/run-ticket.sh" --run-dir "$RUN" --ticket 46 \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$WORKTREE" \
    --estimate-usd 1.50 --expected-minutes 30 "$@"
}

EXIT_RECORD=
launch() { # FAKE_CLAUDE_MODE [run-ticket args...]
  export FAKE_CLAUDE_MODE=$1
  shift
  run_ticket "$@" >"$TEST_TMPDIR/launch.out"
  EXIT_RECORD="$RUN/results/46.1.exit.json"
}

wait_for_file() { # path [seconds]
  local i=0 limit=$((${2:-15} * 10))
  while [ ! -f "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

field() { jq -r ".$2" "$1"; }

alive() { kill -0 "$1" 2>/dev/null; }

test_clean_exit_leaves_an_exit_record_with_code_zero() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  assert_eq 0 "$(field "$EXIT_RECORD" exit_code)"
  assert_eq exited "$(field "$EXIT_RECORD" reason)"
  assert_eq 46 "$(field "$EXIT_RECORD" ticket)"
  assert_eq 1 "$(field "$EXIT_RECORD" attempt)"
  [ -n "$(field "$EXIT_RECORD" finished_at)" ] || fail "no finish time"
  assert_contains "$(cat "$RUN/workers/46.1/output.json")" '"subtype":"success"'
  [ -f "$RUN/results/46.1.result.json" ] || fail "worker's result file missing"
}

test_non_zero_exit_leaves_an_exit_record_with_its_code() {
  setup_run
  launch nonzero
  wait_for_file "$EXIT_RECORD"
  assert_eq 3 "$(field "$EXIT_RECORD" exit_code)"
  assert_eq exited "$(field "$EXIT_RECORD" reason)"
  assert_contains "$(cat "$RUN/workers/46.1/stderr.log")" "boom"
}

test_crashed_worker_that_writes_nothing_still_leaves_an_exit_record() {
  setup_run
  launch crash
  wait_for_file "$EXIT_RECORD"
  assert_eq 139 "$(field "$EXIT_RECORD" exit_code)" "SIGSEGV is 128+11"
  [ ! -f "$RUN/results/46.1.result.json" ] || fail "a crashed worker wrote a result file"
  [ ! -s "$RUN/workers/46.1/output.json" ] || fail "a crashed worker wrote output"
}

test_killed_worker_leaves_an_exit_record_and_no_stray_processes() {
  setup_run
  launch sleep
  wait_for_file "$FAKE_CLAUDE_PID"
  local worker
  worker=$(cat "$FAKE_CLAUDE_PID")
  kill -KILL "$worker"
  wait_for_file "$EXIT_RECORD"
  assert_eq 137 "$(field "$EXIT_RECORD" exit_code)" "SIGKILL is 128+9"
  assert_eq exited "$(field "$EXIT_RECORD" reason)"
  sleep 0.5
  ! pgrep -g "$worker" >/dev/null || fail "the worker's stray background sleep survived"
}

test_passes_the_caps_and_json_output_to_claude() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  local args
  args=$(cat "$FAKE_CLAUDE_ARGS")
  assert_contains "$args" "[-p]"
  assert_contains "$args" "[--output-format]
[json]"
  assert_contains "$args" "[--max-budget-usd]
[3.00]" "budget is twice the 1.50 estimate"
  assert_contains "$args" "[--max-turns]
[60]" "40 turns per estimated dollar"
  assert_eq 3.00 "$(field "$EXIT_RECORD" max_budget_usd)"
  assert_eq 60 "$(field "$EXIT_RECORD" max_turns)"
  assert_eq 3600 "$(field "$EXIT_RECORD" deadline_seconds)" "deadline is twice the 30 expected minutes"
}

test_small_estimates_get_a_floor_of_twenty_turns() {
  setup_run
  export FAKE_CLAUDE_MODE=complete
  "$PLUGIN_ROOT/scripts/run-ticket.sh" --run-dir "$RUN" --ticket 46 \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$WORKTREE" \
    --estimate-usd 0.25 --expected-minutes 5 >/dev/null
  wait_for_file "$RUN/results/46.1.exit.json"
  assert_eq 0.50 "$(field "$RUN/results/46.1.exit.json" max_budget_usd)"
  assert_eq 20 "$(field "$RUN/results/46.1.exit.json" max_turns)"
}

test_explicit_caps_override_the_computed_ones() {
  setup_run
  launch complete --max-turns 7 --model sonnet
  wait_for_file "$EXIT_RECORD"
  assert_contains "$(cat "$FAKE_CLAUDE_ARGS")" "[--max-turns]
[7]"
  assert_contains "$(cat "$FAKE_CLAUDE_ARGS")" "[--model]
[sonnet]"
}

test_arguments_after_a_double_dash_go_to_claude() {
  setup_run
  launch complete -- --no-session-persistence --model haiku
  wait_for_file "$EXIT_RECORD"
  assert_eq 0 "$(field "$EXIT_RECORD" exit_code)"
  assert_contains "$(cat "$FAKE_CLAUDE_ARGS")" "[--no-session-persistence]
[--model]
[haiku]"
}

test_worker_is_told_its_files_and_not_to_leave_background_commands() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  local args env
  args=$(cat "$FAKE_CLAUDE_ARGS")
  env=$(cat "$FAKE_CLAUDE_ENV")
  assert_contains "$args" "Build ticket 46."
  assert_contains "$args" "background"
  assert_contains "$args" "ARTISAN-WORKER: complete"
  assert_contains "$env" "PWD=$WORKTREE"
  assert_contains "$env" "ARTISAN_RESULT_FILE=$RUN/results/46.1.result.json"
  assert_contains "$env" "ARTISAN_FINDINGS_FILE=$RUN/results/findings/46.jsonl"
}

test_worker_past_its_deadline_is_stopped_and_recorded() {
  setup_run
  launch sleep --deadline-seconds 2
  wait_for_file "$FAKE_CLAUDE_PID"
  local worker
  worker=$(cat "$FAKE_CLAUDE_PID")
  wait_for_file "$EXIT_RECORD" 15
  assert_eq deadline "$(field "$EXIT_RECORD" reason)"
  sleep 0.5
  ! alive "$worker" || fail "worker still running after its deadline"
  ! pgrep -g "$worker" >/dev/null || fail "the worker's stray background sleep survived"
}

test_stopping_the_runner_stops_the_worker_and_records_it() {
  setup_run
  launch sleep
  wait_for_file "$FAKE_CLAUDE_PID"
  local worker runner
  worker=$(cat "$FAKE_CLAUDE_PID")
  runner=$(cat "$TEST_TMPDIR/launch.out")
  kill -TERM "$runner"
  wait_for_file "$EXIT_RECORD"
  assert_eq stopped "$(field "$EXIT_RECORD" reason)"
  sleep 0.5
  ! alive "$worker" || fail "worker still running after the runner was stopped"
}

test_launch_returns_at_once_with_the_detached_runner_pid() {
  setup_run
  local start=$SECONDS runner
  launch sleep
  [ $((SECONDS - start)) -lt 5 ] || fail "launch blocked on the worker"
  runner=$(cat "$TEST_TMPDIR/launch.out")
  assert_eq "$runner" "$(cat "$RUN/workers/46.1/runner.pid")"
  alive "$runner" || fail "runner not running"
  assert_eq "$runner" "$(ps -o pgid= -p "$runner" | tr -d ' ')" "runner leads its own process group"
  [ "$(ps -o sess= -p "$runner" | tr -d ' ')" != "$(ps -o sess= -p $$ | tr -d ' ')" ] \
    || [ "$(uname)" = Darwin ] || fail "runner shares the launcher's session"
}

test_worker_survives_its_launcher_exiting_and_being_signalled() {
  setup_run
  export FAKE_CLAUDE_MODE=sleep FAKE_CLAUDE_SLEEP=3
  # The launcher is a shell in its own process group that starts the runner
  # and then lingers. Hang up and terminate that whole group, as closing a
  # terminal or ending a tool's background command would.
  set -m
  bash -c '"$1" --run-dir "$2" --ticket 46 --prompt-file "$3" --workdir "$4" \
      --estimate-usd 1.50 --expected-minutes 30 >"$5"; sleep 60' \
    _ "$PLUGIN_ROOT/scripts/run-ticket.sh" "$RUN" "$TEST_TMPDIR/prompt.md" "$WORKTREE" \
    "$TEST_TMPDIR/launch.out" &
  local launcher=$!
  set +m
  wait_for_file "$FAKE_CLAUDE_PID"
  kill -HUP "-$launcher"
  kill -TERM "-$launcher" 2>/dev/null || true
  wait "$launcher" 2>/dev/null || true
  ! alive "$launcher" || fail "launcher still alive"
  alive "$(cat "$FAKE_CLAUDE_PID")" || fail "worker died with its launcher"
  wait_for_file "$RUN/results/46.1.exit.json" 15
  assert_eq 0 "$(field "$RUN/results/46.1.exit.json" exit_code)"
  assert_eq exited "$(field "$RUN/results/46.1.exit.json" reason)"
}

test_refuses_to_overwrite_an_earlier_attempt() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  local status=0
  run_ticket >/dev/null 2>&1 || status=$?
  assert_eq 2 "$status" "a second attempt must pass --attempt"
  launch complete --attempt 2
  wait_for_file "$RUN/results/46.2.exit.json"
  assert_eq 2 "$(field "$RUN/results/46.2.exit.json" attempt)"
}

test_rejects_missing_arguments() {
  assert_status 2 "$PLUGIN_ROOT/scripts/run-ticket.sh" --ticket 46
}

test_an_option_missing_its_value_is_a_usage_error() {
  setup_run
  assert_status 2 run_ticket --attempt
}

test_nothing_launches_into_a_run_folder_with_no_state_file() {
  setup_run
  rm "$RUN/state.json"
  export FAKE_CLAUDE_MODE=complete
  local status=0
  run_ticket >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 4 "$status" "no approved scope"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "no state file"
  [ ! -e "$RUN/workers/46.1" ] || fail "a worker folder was created"
}

test_an_orchestrator_launches_outside_the_ticket_scope_and_owns_the_writer_pid() {
  setup_run
  export FAKE_CLAUDE_MODE=complete
  local runner
  runner=$("$PLUGIN_ROOT/scripts/run-ticket.sh" --run-dir "$RUN" --ticket orchestrator-w1 --role orchestrator \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$WORKTREE" \
    --estimate-usd 0.25 --expected-minutes 5)
  wait_for_file "$RUN/results/orchestrator-w1.1.exit.json"
  assert_contains "$(cat "$FAKE_CLAUDE_ENV")" "ARTISAN_WRITER_PID=$runner"
  assert_contains "$(cat "$FAKE_CLAUDE_ENV")" "ARTISAN_ROLE=orchestrator"
  assert_contains "$(cat "$RUN/workers/orchestrator-w1.1/prompt.md")" "the wave is done"
}

test_a_worker_gets_its_role_and_no_writer_pid() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  assert_contains "$(cat "$FAKE_CLAUDE_ENV")" "ARTISAN_ROLE=worker"
  assert_contains "$(cat "$FAKE_CLAUDE_ENV")" "ARTISAN_WRITER_PID="$'\n'
}

test_an_orchestrator_id_must_say_so() {
  setup_run
  assert_status 2 run_ticket --role orchestrator
  assert_status 2 run_ticket --role verifier
}

test_a_worker_gets_a_name_and_accepts_messages_from_other_sessions() {
  setup_run
  launch complete
  wait_for_file "$EXIT_RECORD"
  assert_contains "$(cat "$FAKE_CLAUDE_ARGS")" "[--name]
[worker-46]"
  assert_contains "$(cat "$FAKE_CLAUDE_ARGS")" '[{"crossSessionInbound":"accept"}]'
}
