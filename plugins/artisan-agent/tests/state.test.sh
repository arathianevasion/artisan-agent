# The run state file: shape, schema version, lock and one-step rewrite.

. "$TESTS_DIR/helpers/run-state.sh"

test_init_writes_every_documented_field_with_schema_version() {
  init_run
  assert_eq 1 "$(state_get .schema_version)"
  local key=
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
  local documented= written=
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
  local from_wt=
  from_wt=$(cd "$TEST_TMPDIR/wt10" && "$SCRIPTS/state.sh" run-dir r1)
  assert_eq "$(cd "$PROJECT" && pwd -P)/.artisan-agent/runs/r1" "$from_wt"
}

test_a_second_writer_is_refused_while_the_lock_is_held() {
  trap kill_workers EXIT
  init_run
  local holder= before=
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
  local dead=
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
  local before= fifo= writer=
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
  local before=
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
  assert_status 4 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 99 1
}

test_a_dispatch_without_a_deadline_is_refused() {
  init_run '' '{"10": {"model": "mid"}}'
  assert_status 1 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 4242
  assert_eq queued "$(state_get '.tickets["10"].status')"
}

test_a_failed_write_changes_nothing_and_releases_the_lock() {
  init_run
  local before=
  before=$(state_sum)
  assert_status 1 "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["10"] | error("boom")'
  assert_eq "$before" "$(state_sum)"
  [ ! -L "$RUN_DIR/state.lock" ] || fail "lock left behind by a failed write"
}

# The run status file (#192): status.json, rewritten with every state write.
status_get() { jq -r "$1" "$RUN_DIR/status.json"; }

test_init_writes_the_run_status_file_with_the_chats_session() {
  make_project
  write_plan "$TEST_TMPDIR/plan.json"
  ARTISAN_NOW=1000 CLAUDE_CODE_SESSION_ID=sess-1 "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  assert_eq 1 "$(wc -l <"$RUN_DIR/status.json" | tr -d ' ')" "one line"
  # (next is the chain's from the state file alone: no frontier until the
  # reconciler first runs, at wave.sh start, status or launch.)
  assert_eq "1 r1 owner/repo run r1 0 3 0" \
    "$(status_get '"\(.v) \(.run) \(.repo) \(.plan) \(.wave) \(.waves) \(.waiting_on_artisan)"')"
  assert_eq '{"merged":0,"in_flight":0,"verifying":0,"merge_gate":0,"queued":3,"blocked":0,"other":0,"total":3}' \
    "$(jq -c .counts "$RUN_DIR/status.json")"
  assert_eq "sess-1 null null" "$(status_get '"\(.owner.chat_session) \(.owner.chat_pid) \(.owner.lock_pid)"')" \
    "a one-off call holds the lock for itself only"
  assert_eq 1000 "$(status_get .last_event_at)" "always set, even before the first event"
  assert_eq 'repo run r1 · Wave 0/3 · 0/3 merged · $0.00/$20.00' "$(status_get .text)"
  assert_eq sess-1 "$(state_get .chat_session)"
}

test_the_run_status_file_follows_each_write_and_the_lock_holder() {
  trap kill_workers EXIT
  init_run
  local chat=
  assert_eq null "$(state_get .chat_session)" "no session in the environment"
  ARTISAN_NOW=2000 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 4242 9999
  assert_eq "dispatch 2000 1 2" "$(status_get '"\(.last_event) \(.last_event_at) \(.counts.in_flight) \(.counts.queued)"')"
  assert_contains "$(status_get .text)" "0/3 merged, 1 in flight"
  # The chat takes the lock with its long-lived pid: the file names it.
  chat=$(start_worker)
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$chat"
  ARTISAN_NOW=2100 ARTISAN_WRITER_PID=$chat "$SCRIPTS/state.sh" merge "$RUN_DIR" 10 abc123
  assert_eq "merge 2100 1 $chat $chat" \
    "$(status_get '"\(.last_event) \(.last_event_at) \(.counts.merged) \(.owner.lock_pid) \(.owner.chat_pid)"')"
  ARTISAN_NOW=2200 ARTISAN_WRITER_PID=$chat "$SCRIPTS/state.sh" update "$RUN_DIR" \
    '.decisions += [{id: 1, kind: "design", ticket: "11", question: "Which?", status: "waiting", at: 2200}]'
  assert_eq "decide 1" "$(status_get '"\(.next) \(.waiting_on_artisan)"')"
  ARTISAN_NOW=2300 ARTISAN_WRITER_PID=$chat "$SCRIPTS/state.sh" update "$RUN_DIR" \
    '.halted = {wave: 1, tickets: ["11"], reason: "test", at: 2300}'
  assert_eq halted "$(status_get .next)"
  # Halted comes first, as in wave.sh status; an ended run says done.
  ARTISAN_WRITER_PID=$chat "$SCRIPTS/state.sh" update "$RUN_DIR" '.end_gate = {status: "ended"}'
  assert_eq halted "$(status_get .next)"
  ARTISAN_WRITER_PID=$chat "$SCRIPTS/state.sh" update "$RUN_DIR" '.halted = null'
  assert_eq done "$(status_get .next)" "an ended run says so"
  # A write refused under someone else's lock leaves the file as it was.
  local before=
  before=$(cat "$RUN_DIR/status.json")
  assert_status 3 "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 9'
  assert_eq "$before" "$(cat "$RUN_DIR/status.json")"
  [ -z "$(ls -A "$RUN_DIR" | grep '^\.status\.json\.tmp')" ] || fail "a temp file was left behind"
}

test_a_reader_never_sees_a_partial_run_status_file() {
  init_run
  local i=0 bad=0
  ( for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = $n' --argjson n "$i" >/dev/null 2>&1 || true
    done; touch "$TEST_TMPDIR/writes.done" ) &
  while [ ! -e "$TEST_TMPDIR/writes.done" ]; do
    jq -e '.v == 1 and (.text | length) > 0' "$RUN_DIR/status.json" >/dev/null 2>&1 || bad=$((bad + 1))
  done
  wait
  assert_eq 0 "$bad" "reads that found a partial or missing file"
}

test_the_run_status_text_stays_under_a_hundred_characters() {
  init_run
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.repo = "some-owner/a-rather-long-repository-name"
    | .run_id = "20261117-101"
    | .tickets["10"].status = "in_flight" | .tickets["11"].status = "returned" | .tickets["12"].status = "blocked"
    | .merge_gate = {ticket: "11", mode: "ci"} | .costs.total_usd = 123.456 | .plan.budget_usd = 456.7'
  assert_eq true "$(status_get '.text | length <= 100')" "text: $(status_get .text)"
  assert_contains "$(status_get .text)" "a-rather-long-repository-name run 20261117-101 · Wave 0/3 · 0/3 merged, "
  assert_contains "$(status_get .text)" '1 in CI · $123.46/$456.70'
  # A name too long for the line is cut, so the run, wave, counts and cost still show.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.repo = "o/" + ("x" * 120)'
  assert_eq true "$(status_get '.text | length <= 100')" "text: $(status_get .text)"
  assert_contains "$(status_get .text)" '… run 20261117-101 · Wave 0/3 · 0/3 merged'
  assert_contains "$(status_get .text)" '$123.46/$456.70'
  # A shorter name leaves room for every count.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.repo = "o/app"'
  assert_contains "$(status_get .text)" 'app run 20261117-101 · Wave 0/3 · 0/3 merged, 1 in flight, 1 in CI, 1 blocked · $123.46/$456.70'
}

test_init_refuses_a_run_folder_under_a_claude_folder_and_names_it() {
  make_project
  write_plan "$TEST_TMPDIR/plan.json"
  local bad="$PROJECT/.claude/worktrees/w/.artisan-agent/runs/r1" out=
  out=$("$SCRIPTS/state.sh" init "$bad" "$TEST_TMPDIR/plan.json" 2>&1) && fail "init accepted a run folder under .claude/"
  assert_contains "$out" "headless sessions can't write under a .claude/ folder"
  assert_contains "$out" "$PROJECT/.claude"
  [ ! -e "$bad" ] || fail "init created the refused run folder"
}
