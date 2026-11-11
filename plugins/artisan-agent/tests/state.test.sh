# The run state file: shape, schema version, lock and one-step rewrite.

. "$TESTS_DIR/helpers/run-state.sh"

test_init_writes_every_documented_field_with_schema_version() {
  init_run
  assert_eq 1 "$(state_get .schema_version)"
  local key
  for key in run_id repo plan tickets integration findings costs decisions waves frontier; do
    assert_eq true "$(state_get "has(\"$key\")")" "top-level field $key"
  done
  for key in waves tickets gates max_agents budget_usd scope attempts_per_ticket; do
    assert_eq true "$(state_get ".plan | has(\"$key\")")" "plan field $key"
  done
  for key in status attempts pid evidence merge_commit; do
    assert_eq true "$(state_get ".tickets[\"10\"] | has(\"$key\")")" "ticket field $key"
  done
  assert_eq run/r1 "$(state_get .integration.branch)"
  assert_eq queued "$(state_get '.tickets["11"].status')"
}

test_every_field_in_the_reference_is_written_by_init() {
  # The reference documents the shape once; init must produce exactly its
  # top-level fields, so the two cannot drift apart.
  init_run
  local documented written
  documented=$(sed -n 's/^| `\([a-z_]*\)` | top-level |.*/\1/p' "$PLUGIN_ROOT/references/state-file.md" | sort | tr '\n' ' ')
  written=$(state_get 'keys[]' | sort | tr '\n' ' ')
  assert_eq "$written" "$documented" "top-level fields in references/state-file.md vs init"
}

test_init_refuses_a_run_folder_that_is_not_gitignored() {
  make_project
  printf '' >"$PROJECT/.gitignore"
  write_plan "$TEST_TMPDIR/plan.json"
  assert_status 1 "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
}

test_init_refuses_to_overwrite_an_existing_run() {
  init_run
  assert_status 1 "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
}

test_run_dir_is_in_the_main_checkout_even_from_a_worktree() {
  make_project
  git_quiet -C "$PROJECT" worktree add -b agent/10 "$TEST_TMPDIR/wt10"
  local from_wt
  from_wt=$(cd "$TEST_TMPDIR/wt10" && "$SCRIPTS/state.sh" run-dir r1)
  assert_eq "$(cd "$PROJECT" && pwd -P)/.artisan-agent/runs/r1" "$from_wt"
}

test_a_second_writer_is_refused_while_the_lock_is_held() {
  trap kill_workers EXIT
  init_run
  local holder before
  holder=$(start_worker)
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$holder"
  before=$(state_sum)
  assert_status 3 "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 9'
  assert_status 3 "$SCRIPTS/state.sh" lock "$RUN_DIR" "$$"
  assert_eq "$before" "$(state_sum)" "state file changed under someone else's lock"
  # The holder itself may write.
  ARTISAN_WRITER_PID=$holder "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 9'
  assert_eq 9 "$(state_get .plan.max_agents)"
  "$SCRIPTS/state.sh" unlock "$RUN_DIR" "$holder"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 4'
  assert_eq 4 "$(state_get .plan.max_agents)"
}

test_a_stale_lock_from_a_dead_process_is_recovered() {
  init_run
  local dead
  sleep 0 &
  dead=$!
  wait "$dead"
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$dead"
  assert_eq "$dead" "$(readlink "$RUN_DIR/state.lock")"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 7'
  assert_eq 7 "$(state_get .plan.max_agents)"
  [ ! -e "$RUN_DIR/state.lock" ] && [ ! -L "$RUN_DIR/state.lock" ] || fail "lock left behind after update"
}

test_an_interrupted_write_leaves_the_previous_state_file_intact() {
  init_run
  local before fifo writer
  before=$(cat "$RUN_DIR/state.json")
  fifo="$TEST_TMPDIR/feed"
  mkfifo "$fifo"
  "$SCRIPTS/state.sh" write "$RUN_DIR" <"$fifo" &
  writer=$!
  exec 7>"$fifo"
  # Half a new state file, then the writer dies mid-write.
  jq '.plan.max_agents = 1' "$RUN_DIR/state.json" | head -c 200 >&7
  sleep 1
  kill -0 "$writer" 2>/dev/null || fail "writer was not still mid-write"
  pkill -KILL -P "$writer" 2>/dev/null || true
  kill -KILL "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  exec 7>&-
  assert_eq "$before" "$(cat "$RUN_DIR/state.json")" "state file after an interrupted write"
  jq -e . "$RUN_DIR/state.json" >/dev/null || fail "state file is not valid JSON"
}

test_a_write_of_the_wrong_schema_version_is_refused() {
  init_run
  local before
  before=$(state_sum)
  assert_status 1 sh -c "jq '.schema_version = 99' '$RUN_DIR/state.json' | '$SCRIPTS/state.sh' write '$RUN_DIR'"
  assert_status 1 sh -c "printf '{\"schema_version\": 1, ' | '$SCRIPTS/state.sh' write '$RUN_DIR'"
  assert_eq "$before" "$(state_sum)"
}

test_events_record_dispatch_merge_wave_evidence_decision_and_cost() {
  init_run '' '{"10": {"caps": {"deadline_seconds": 600}}}'
  export ARTISAN_NOW=1000
  "$SCRIPTS/state.sh" wave-start "$RUN_DIR" 1 0.1.0 - abc123 def456
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 4242
  assert_eq in_flight "$(state_get '.tickets["10"].status')"
  assert_eq 1 "$(state_get '.tickets["10"].attempts')"
  assert_eq 4242 "$(state_get '.tickets["10"].pid')"
  assert_eq 1600 "$(state_get '.tickets["10"].deadline_at')"
  printf '{"criteria": [{"criterion": "x", "met": true}]}' >"$TEST_TMPDIR/ev.json"
  "$SCRIPTS/state.sh" evidence "$RUN_DIR" 10 "$TEST_TMPDIR/ev.json"
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 10 deadbeef
  assert_eq merged "$(state_get '.tickets["10"].status')"
  assert_eq deadbeef "$(state_get '.integration.merges[0].commit')"
  assert_eq true "$(state_get '.tickets["10"].evidence.criteria[0].met')"
  assert_eq 0.1.0 "$(state_get '.waves[0].plugin_version')"
  assert_eq null "$(state_get '.waves[0].guardrails.team')"
  assert_eq abc123 "$(state_get '.waves[0].guardrails.product')"
  printf '{"kind": "slice", "ticket": "12", "question": "Approve?"}' >"$TEST_TMPDIR/d.json"
  "$SCRIPTS/state.sh" decision "$RUN_DIR" "$TEST_TMPDIR/d.json"
  assert_eq waiting "$(state_get '.decisions[0].status')"
  "$SCRIPTS/state.sh" cost "$RUN_DIR" 1.5
  assert_eq 1.5 "$(state_get '.costs.total_usd')"
  assert_status 1 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 99 1
}
