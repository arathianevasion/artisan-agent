# Static check (#207): references/state-file.md and scripts/README.md keep one
# entry per line, so two tickets that add different entries touch different
# lines and git merges them on its own. No line may pass MAX_LINE characters.
# Also: the event log still names every event it named when it was one paragraph.
# Bash 3.2-safe: awk and grep only.

MAX_LINE=1000
STATE_FILE="$PLUGIN_ROOT/references/state-file.md"
SCRIPTS_README="$PLUGIN_ROOT/scripts/README.md"

# The events the event-log paragraph named before it became a list (#207).
EVENTS='dispatch result verify verified failed blocked merge closed conflict resolve finding design-question integration orchestrator guardrail-merge guardrail-base-kept halted resumed orchestrator-exit handoff handoff-failed risk-gate risk-gate-cleared asked answered deferred-question pulled provisional-shown gate-opened gate-decision rework gate-approved end-gate-approved pr-cut run-ended gate-redirected gate-bypassed gate-deferred gate-decided gate-resolved gate-empty repaired sent-back decided parked human-check-passed human-check-failed human-check-deferred human-check-split human-start human-done human-feedback overrun-gate overrun-decision unparked ci-gate-abandoned ci-wait merge-gate merge-gate-resumed merge-gate-abandoned merge-batch merge-batch-ended resume-asked ceiling-raised guardrail-fired guardrail-bypassed bug-found shipped-bug spot-check merge-gate-skipped'

# long_lines file: "line number: length" for each line over MAX_LINE characters.
long_lines() {
  awk -v max="$MAX_LINE" 'length($0) > max { print FNR ": " length($0) }' "$1"
}

test_no_line_in_state_file_md_is_over_the_limit() {
  local hits=
  hits=$(long_lines "$STATE_FILE")
  [ -z "$hits" ] || fail "references/state-file.md has lines over $MAX_LINE characters (one entry per line):
$hits"
}

test_no_line_in_scripts_readme_is_over_the_limit() {
  local hits=
  hits=$(long_lines "$SCRIPTS_README")
  [ -z "$hits" ] || fail "scripts/README.md has lines over $MAX_LINE characters (one entry per line):
$hits"
}

test_the_check_flags_an_overlong_line() {
  local f="$TEST_TMPDIR/long.md" out=
  awk -v n="$((MAX_LINE + 1))" 'BEGIN { s = ""; for (i = 0; i < n; i++) s = s "x"; print "short"; print s }' >"$f"
  out=$(long_lines "$f")
  assert_eq "2: $((MAX_LINE + 1))" "$out"
}

test_the_event_log_still_documents_every_event() {
  local section= e=
  section=$(sed -n '/^## The event log/,/^## The sweep/p' "$STATE_FILE")
  for e in $EVENTS; do
    assert_contains "$section" "\`$e\`" "event log names $e"
  done
}

test_the_event_log_lists_one_event_per_line() {
  local lines=
  lines=$(sed -n '/^## The event log/,/^## The sweep/p' "$STATE_FILE" | grep -c '^- ')
  [ "$lines" -ge 50 ] || fail "expected the event log as a list of at least 50 lines, got $lines"
}

test_each_section_says_one_entry_per_line() {
  assert_contains "$(sed -n '/^## The event log/,/^## The sweep/p' "$STATE_FILE")" "One entry per line"
  assert_contains "$(sed -n '1,6p' "$SCRIPTS_README")" "One entry per line"
}
