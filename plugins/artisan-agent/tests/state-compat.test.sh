# The state file's versioning rule (references/state-file.md, Schema version):
# an optional field added without a bump is ignored by older scripts and
# defaulted by newer ones when it is missing; a different version is refused
# with the plugin version the run started on.

. "$TESTS_DIR/helpers/run-state.sh"

# The optional fields, as the reference's "Optional fields" table lists them.
OPTIONAL_TOP='events orchestrators findings_read relays lessons review_gates halted waves location provisional_shown'
OPTIONAL_PLAN='gates overrides suite_command checks orchestrator'
OPTIONAL_TICKET='attempt_costs verifications worktree base suite tracker_closed wave resolve risk_gate context_risk questions answers blocked_reason'

# drop_field jq-path: remove a field from the state file in place.
drop_field() {
  jq "del($1)" "$RUN_DIR/state.json" >"$TEST_TMPDIR/dropped.json"
  mv "$TEST_TMPDIR/dropped.json" "$RUN_DIR/state.json"
}

# exercise_readers: every reader and writer that must cope with a missing
# optional field. Each must succeed.
exercise_readers() {
  "$SCRIPTS/state.sh" show "$RUN_DIR" >/dev/null
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave-width.sh" pick "$RUN_DIR" >/dev/null
  "$PLUGIN_ROOT/scripts/run-digest.sh" --run-dir "$RUN_DIR" --peek >/dev/null
  "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"probe"}'
  "$SCRIPTS/state.sh" cost "$RUN_DIR" 0.5
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$$" >/dev/null
}

test_every_reader_accepts_a_version_1_file_with_an_unknown_extra_field() {
  init_run
  jq '.future_top = {"x": 1}
      | .plan.future_plan = [1]
      | .tickets["10"].future_ticket = "y"
      | .events = [{"seq": 1, "at": 1, "event": "future", "extra": true}]' \
    "$RUN_DIR/state.json" >"$TEST_TMPDIR/extra.json"
  mv "$TEST_TMPDIR/extra.json" "$RUN_DIR/state.json"
  exercise_readers
  assert_eq '{"x":1}' "$(jq -c .future_top "$RUN_DIR/state.json")" "the unknown field survives a rewrite"
  assert_eq "y" "$(state_get '.tickets["10"].future_ticket')"
  assert_eq 1 "$(state_get .schema_version)"
}

test_readers_accept_a_file_missing_each_top_level_optional_field() {
  local f=
  for f in $OPTIONAL_TOP; do
    init_run
    drop_field ".$f"
    exercise_readers || fail "a file without $f was refused"
    rm -rf "$TEST_TMPDIR/project"
  done
}

test_readers_accept_a_file_missing_each_plan_optional_field() {
  local f=
  for f in $OPTIONAL_PLAN; do
    init_run
    drop_field ".plan.$f"
    exercise_readers || fail "a file without plan.$f was refused"
    rm -rf "$TEST_TMPDIR/project"
  done
}

test_readers_accept_a_file_missing_each_ticket_optional_field() {
  local f=
  for f in $OPTIONAL_TICKET; do
    init_run
    drop_field ".tickets[\"10\"].$f"
    exercise_readers || fail "a file without tickets.10.$f was refused"
    rm -rf "$TEST_TMPDIR/project"
  done
}

test_a_missing_event_log_starts_at_one_and_missing_costs_default() {
  init_run
  drop_field .events
  drop_field .orchestrators
  "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"probe"}'
  assert_eq 1 "$(state_get '.events | length')" "the log starts with the first event"
  assert_eq 1 "$(state_get '.events[0].seq')"
  assert_eq null "$(state_get '.halted')" "a missing halted reads as null"
  drop_field .plan.suite_command
  assert_eq null "$(state_get '.plan.suite_command // null')"
  assert_eq '[]' "$(jq -c '.plan.checks // []' "$RUN_DIR/state.json")"
}

test_the_digest_reads_a_file_without_events_halted_or_orchestrators() {
  init_run
  drop_field .events
  drop_field .halted
  drop_field .orchestrators
  local out=
  out=$("$PLUGIN_ROOT/scripts/run-digest.sh" --run-dir "$RUN_DIR" --peek)
  assert_contains "$out" "r1"
}

test_a_different_version_is_refused_naming_the_runs_starting_plugin_version() {
  init_run
  "$SCRIPTS/state.sh" wave-start "$RUN_DIR" 1 "0.7.0" - - - >/dev/null
  "$SCRIPTS/state.sh" wave-start "$RUN_DIR" 2 "0.8.0" - - - >/dev/null
  jq '.schema_version = 2' "$RUN_DIR/state.json" >"$TEST_TMPDIR/v2.json"
  mv "$TEST_TMPDIR/v2.json" "$RUN_DIR/state.json"
  local cmd= out=
  for cmd in "sweep" "wave-width-pick" "event" "cost" "evidence"; do
    case "$cmd" in
      sweep) out=$("$SCRIPTS/sweep.sh" "$RUN_DIR" 2>&1 || true) ;;
      wave-width-pick) out=$("$SCRIPTS/wave-width.sh" pick "$RUN_DIR" 2>&1 || true) ;;
      event) out=$("$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}' 2>&1 || true) ;;
      cost) out=$("$SCRIPTS/state.sh" cost "$RUN_DIR" 1 2>&1 || true) ;;
      evidence) out=$("$SCRIPTS/evidence.sh" show "$RUN_DIR" 2>&1 || true) ;;
    esac
    assert_contains "$out" "plugin version 0.7.0" "$cmd names the starting plugin version"
    assert_contains "$out" "schema version 2" "$cmd names the file's version"
  done
}

test_the_refusal_without_a_recorded_wave_still_says_what_to_do() {
  init_run
  jq '.schema_version = 2' "$RUN_DIR/state.json" >"$TEST_TMPDIR/v2.json"
  mv "$TEST_TMPDIR/v2.json" "$RUN_DIR/state.json"
  local out=
  out=$("$SCRIPTS/sweep.sh" "$RUN_DIR" 2>&1 || true)
  assert_contains "$out" "finish it on the plugin version that created it"
}

test_the_reference_lists_every_optional_field_with_its_default() {
  local ref="$PLUGIN_ROOT/references/state-file.md" f= section=
  section=$(sed -n '/^## Optional fields/,/^## Where a run lives/p' "$ref")
  assert_contains "$section" "Default when missing"
  for f in $OPTIONAL_TOP $OPTIONAL_PLAN $OPTIONAL_TICKET; do
    printf '%s\n' "$section" | grep -E "^\| .*\`(plan\.)?$f\`.* \| " >/dev/null \
      || fail "references/state-file.md has no Optional fields row for $f"
  done
}
