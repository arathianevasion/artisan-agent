# scripts/tracker.sh (#146): every plugin issue is created through it, and
# with tracker.board set the ones that outlive the run go on the project's
# board, each "set at filing" field copied from the ticket it came from.

# shellcheck source=helpers/run-state.sh
. "$TESTS_DIR/helpers/run-state.sh"

TRACKER="$PLUGIN_ROOT/scripts/tracker.sh"

setup_board() { # a project with tracker.board and a fake gh holding the board
  init_run
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker" FAKE_GH_REPO=owner/repo
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  cat >>"$PROJECT/.artisan-agent/config.yml" <<'EOF'
tracker:
  board:
    owner: someone
    number: 1
    fields_at_filing: [Area]
EOF
  # Issue #5 is on the board with Area UI; #6 is on it with no Area.
  local n=
  for n in 1 2 3 4 5 6; do
    jq -n --argjson n "$n" '{number: $n, title: "t\($n)", body: "", state: "open", labels: []}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '{id: "PVT_1", fields: [
      {id: "F_area", name: "Area", type: "ProjectV2SingleSelectField", options: [{id: "O_ui", name: "UI"}, {id: "O_pipe", name: "Pipeline"}]},
      {id: "F_prio", name: "Priority", type: "ProjectV2SingleSelectField", options: [{id: "O_p0", name: "P0"}]}],
    items: [
      {id: "PVTI_a", content: {type: "Issue", number: 5, repository: "owner/repo", url: "https://github.com/owner/repo/issues/5"}, values: {Area: "UI", Priority: "P0"}},
      {id: "PVTI_b", content: {type: "Issue", number: 6, repository: "owner/repo", url: "https://github.com/owner/repo/issues/6"}, values: {}},
      {id: "PVTI_c", content: {type: "Issue", number: 5, repository: "other/repo", url: "https://github.com/other/repo/issues/5"}, values: {Area: "Pipeline"}}]}' \
    >"$FAKE_GH_DIR/project-someone-1.json"
  cd "$PROJECT"
}

board_item() { # issue number -> its board item's values, or "absent"
  jq -r --argjson n "$1" '[.items[] | select(.content.number == $n and .content.repository == "owner/repo") | .values | tojson] | first // "absent"' \
    "$FAKE_GH_DIR/project-someone-1.json"
}

new_issue() { # kind from [extra tracker.sh args...]
  local kind=$1 from=$2
  shift 2
  "$TRACKER" new-issue --kind "$kind" --from "$from" "$@" -- -R owner/repo --title "A $kind" --body "body" --label needs-triage
}

test_without_tracker_board_it_only_creates_the_issue() {
  init_run
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker" FAKE_GH_REPO=owner/repo
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  cd "$PROJECT"
  local out=
  out=$(new_issue finding 5)
  assert_eq "https://github.com/owner/repo/issues/1" "$out"
  assert_eq "A finding" "$(jq -r .title "$FAKE_GH_DIR/issue-1.json")"
  assert_eq needs-triage "$(jq -r '.labels[0].name' "$FAKE_GH_DIR/issue-1.json")"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "project"
}

test_a_finding_goes_on_the_board_with_its_source_tickets_area() {
  setup_board
  local out=
  out=$(new_issue finding 5)
  assert_eq "https://github.com/owner/repo/issues/7" "$out"
  assert_eq '{"Area":"UI"}' "$(board_item 7)"
}

test_human_checks_reworks_plans_and_splits_go_on_the_board() {
  setup_board
  local k= n=7
  for k in human-check rework plan split; do
    new_issue "$k" 5 >/dev/null
    assert_eq '{"Area":"UI"}' "$(board_item "$n")" "kind $k"
    n=$((n + 1))
  done
}

test_gates_and_worker_questions_stay_off_the_board() {
  setup_board
  new_issue gate 5 >/dev/null
  new_issue question 5 >/dev/null
  assert_eq absent "$(board_item 7)"
  assert_eq absent "$(board_item 8)"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "item-add"
}

test_a_named_area_wins_over_the_source_tickets() {
  setup_board
  new_issue finding 5 --field Area=Pipeline >/dev/null
  assert_eq '{"Area":"Pipeline"}' "$(board_item 7)"
}

test_a_source_ticket_without_a_value_leaves_the_field_empty() {
  setup_board
  new_issue finding 6 >/dev/null
  assert_eq '{}' "$(board_item 7)"
  new_issue finding 3 >/dev/null   # not on the board at all
  assert_eq '{}' "$(board_item 8)"
}

test_priority_and_status_are_never_set() {
  setup_board
  new_issue finding 5 >/dev/null
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "F_prio"
}

test_a_failed_issue_create_fails_and_queues_nothing() {
  setup_board
  local status=0
  "$TRACKER" new-issue --kind finding --from 5 -- -R owner/repo --body "no title" 2>/dev/null || status=$?
  assert_eq 1 "$status"
  [ ! -s "$PROJECT/.artisan-agent/runs/.board/pending.jsonl" ] || fail "queued a board add for an issue that was never created"
}

test_a_board_failure_keeps_the_issue_warns_records_and_the_next_sweep_adds_it() {
  setup_board
  touch "$FAKE_GH_DIR/project-unavailable"
  local out= err= status=0
  out=$(new_issue finding 5 --run-dir "$RUN_DIR" 2>"$TEST_TMPDIR/err") || status=$?
  err=$(cat "$TEST_TMPDIR/err")
  assert_eq 0 "$status" "the issue creation does not fail"
  assert_eq "https://github.com/owner/repo/issues/7" "$out"
  assert_contains "$err" "#7"
  assert_contains "$err" "board"
  assert_eq absent "$(board_item 7)"
  assert_eq '7 finding 5' "$(state_get '.events[] | select(.event == "board-add-failed") | "\(.issue) \(.kind) \(.from)"')"
  # The orchestrator's sweep tries again.
  rm "$FAKE_GH_DIR/project-unavailable"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard >/dev/null
  assert_eq '{"Area":"UI"}' "$(board_item 7)"
  [ ! -s "$PROJECT/.artisan-agent/runs/.board/pending.jsonl" ] || fail "the retried add is still queued"
}

test_a_queued_add_keeps_the_named_area_and_waits_while_the_board_is_down() {
  setup_board
  touch "$FAKE_GH_DIR/project-unavailable"
  new_issue finding 5 --field Area=Pipeline >/dev/null 2>&1
  "$TRACKER" board-retry --project "$PROJECT" 2>/dev/null
  assert_eq 1 "$(wc -l <"$PROJECT/.artisan-agent/runs/.board/pending.jsonl" | tr -d ' ')" "still queued while the board is down"
  rm "$FAKE_GH_DIR/project-unavailable"
  "$TRACKER" board-retry --project "$PROJECT" >/dev/null
  assert_eq '{"Area":"Pipeline"}' "$(board_item 7)"
}

test_without_an_open_run_a_board_failure_is_queued_without_an_event() {
  setup_board
  touch "$FAKE_GH_DIR/project-unavailable"
  local status=0
  new_issue plan 5 >/dev/null 2>&1 || status=$?
  assert_eq 0 "$status"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "board-add-failed")] | length')"
  assert_contains "$(cat "$PROJECT/.artisan-agent/runs/.board/pending.jsonl")" '"issue":7'
}

test_an_unknown_kind_is_refused_before_anything_is_created() {
  setup_board
  local status=0
  new_issue gizmo 5 >/dev/null 2>&1 || status=$?
  assert_eq 2 "$status"
  [ ! -f "$FAKE_GH_DIR/issue-7.json" ] || fail "created an issue for an unknown kind"
}

# Every plugin issue is created through tracker.sh: no script creates one
# with gh directly. upstream-check.sh (and skills/retro/scripts/retro.sh,
# outside scripts/) file to the pipeline's own repo
# (PIPELINE_REPO), never to the project, so neither files a project issue.
test_no_script_creates_an_issue_except_through_tracker_sh() {
  local hits=
  hits=$(grep -rn 'issue create' "$PLUGIN_ROOT/scripts" --include='*.sh' \
    | grep -v '^[^:]*/scripts/tracker\.sh:' \
    | grep -v '^[^:]*/scripts/upstream-check\.sh:' \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)
  assert_eq "" "$hits" "direct issue creation outside tracker.sh"
}

test_text_number_and_date_fields_are_set_as_what_their_value_reads_as() {
  setup_board
  jq '.fields += [{id: "F_due", name: "Due", type: "ProjectV2Field"}, {id: "F_size", name: "Size", type: "ProjectV2Field"},
                  {id: "F_note", name: "Note", type: "ProjectV2Field"}]
      | .items[0].values += {Due: "2026-12-01", Size: 3, Note: "see #5"}' \
    "$FAKE_GH_DIR/project-someone-1.json" >"$TEST_TMPDIR/p" && mv "$TEST_TMPDIR/p" "$FAKE_GH_DIR/project-someone-1.json"
  sed -i.bak 's/fields_at_filing: \[Area\]/fields_at_filing: [Area, Due, Size, Note]/' "$PROJECT/.artisan-agent/config.yml"
  new_issue finding 5 >/dev/null
  assert_eq '{"Area":"UI","Due":"2026-12-01","Size":3,"Note":"see #5"}' "$(board_item 7)"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "--field-id F_due --date 2026-12-01"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "--field-id F_size --number 3"
}

test_a_queued_add_that_keeps_failing_is_given_up_with_a_warning() {
  setup_board
  touch "$FAKE_GH_DIR/project-unavailable"
  new_issue finding 5 >/dev/null 2>&1
  ARTISAN_BOARD_TRIES=2 "$TRACKER" board-retry --project "$PROJECT" 2>/dev/null
  assert_contains "$(cat "$PROJECT/.artisan-agent/runs/.board/pending.jsonl")" '"tries":1'
  local err=
  err=$(ARTISAN_BOARD_TRIES=2 "$TRACKER" board-retry --project "$PROJECT" 2>&1 >/dev/null)
  assert_contains "$err" "Given up: add it by hand"
  [ ! -s "$PROJECT/.artisan-agent/runs/.board/pending.jsonl" ] || fail "a given-up add is still queued"
}

# ------------------------------------------- bodies as files, whole (#209)

plain_tracker() {
  init_run
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker" FAKE_GH_REPO=owner/repo
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  cd "$PROJECT"
}

test_a_body_on_stdin_under_the_limit_is_the_issue_body_and_nothing_more() {
  plain_tracker
  printf 'line one\nline two\n' | "$TRACKER" new-issue --kind gate -- -R owner/repo --title "A gate" --body-file - >/dev/null
  assert_eq "line one"$'\n'"line two" "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")"
  [ ! -e "$FAKE_GH_DIR/comments-1.md" ] || fail "a short body was split"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "issue comment"
}

# A part break inside a code fence closes the fence, and the next part opens
# it again, so every part renders on GitHub.
test_a_long_fenced_block_is_split_with_every_part_opening_and_closing_its_fence() {
  plain_tracker
  { printf '## Card\n\n```json\n'
    jq -nr '[range(0; 6000) | "{\"line\": \(.), \"text\": \"a decision the worker made alone\"}"] | join("\n")'
    printf '```\n\nThe end.\n'; } >"$TEST_TMPDIR/body.md"
  "$TRACKER" new-issue --kind gate -- -R owner/repo --title "A gate" --body-file "$TEST_TMPDIR/body.md" >/dev/null
  local parts=0 i=0
  jq -r .body "$FAKE_GH_DIR/issue-1.json" >"$TEST_TMPDIR/part-0"
  parts=$(jq -n --rawfile c "$FAKE_GH_DIR/comments-1.md" '$c | split("\n---\n") | length')
  [ "$parts" -ge 3 ] || fail "expected at least 3 comments, got $parts"
  while [ "$i" -lt "$parts" ]; do
    i=$((i + 1))
    jq -rn --rawfile c "$FAKE_GH_DIR/comments-1.md" --argjson i "$i" '$c | split("\n---\n")[$i - 1]' >"$TEST_TMPDIR/part-$i"
  done
  i=0
  while [ "$i" -le "$parts" ]; do
    assert_eq 0 "$(( $(grep -c '^```' "$TEST_TMPDIR/part-$i") % 2 ))" "fences balanced in part $i"
    [ "$i" = 0 ] || assert_eq '```json' "$(sed -n 3p "$TEST_TMPDIR/part-$i")" "part $i opens the fence again"
    i=$((i + 1))
  done
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "The end."
}

# No plugin script passes an issue body to gh as a command-line argument:
# GitHub caps a body at 65,536 characters and the OS caps an argument, so
# every issue body goes as a file (--body-file, or - for stdin) through
# tracker.sh, which splits one over the limit. Comments and PR bodies are
# not issue bodies.
test_no_script_passes_an_issue_body_to_gh_as_an_argument() {
  local hits=
  hits=$(find "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills" -name '*.sh' -path '*scripts*' -print0 \
    | xargs -0 awk '
        FNR == 1 { line = "" }
        { line = line $0 }
        /\\$/ { sub(/\\$/, "", line); next }
        line !~ /^[[:space:]]*#/ && line ~ /(issue (create|edit)|tracker\.sh" new-issue)/ \
          && line ~ /(^|[[:space:]])(--body|-b)[[:space:]=]/ { print FILENAME ":" FNR ": " line }
        { line = "" }' | grep -v '/scripts/tracker\.sh:' || true)
  assert_eq "" "$hits" "an issue body passed as an argument"
}

# Every lookup for an issue that may already exist sees every open issue
# with its label: gh lists 30 unless told more. guardrail-health.sh reads a
# bounded window of history on purpose; it looks nothing up.
test_every_issue_list_in_scripts_reads_every_matching_issue() {
  local hits=
  hits=$(awk '
      FNR == 1 { line = "" }
      { line = line $0 }
      /\\$/ { sub(/\\$/, "", line); next }
      line !~ /^[[:space:]]*#/ && line ~ /gh issue list/ {
        n = line; sub(/.*--limit[[:space:]]+/, "", n); sub(/[^0-9].*/, "", n)
        if (line !~ /--limit/ || n + 0 < 10000) print FILENAME ":" FNR ": " line
      }
      { line = "" }' "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/lib/*.sh \
    | grep -v '/scripts/guardrail-health\.sh:' || true)
  assert_eq "" "$hits" "a gh issue list that may miss an existing issue"
}

# A part that can't be posted fails the call, naming the missing parts, but
# the issue it made still gets its URL printed and goes on the board.
test_a_part_that_cannot_be_posted_fails_the_call_after_the_issue_reaches_the_board() {
  setup_board
  jq -nr '[range(0; 3000) | "line \(.) of a finding that keeps going for a while"] | join("\n")' >"$TEST_TMPDIR/body.md"
  touch "$FAKE_GH_DIR/comments-fail"
  local out="" status=0
  out=$("$TRACKER" new-issue --kind finding --from 5 -- -R owner/repo --title "A finding" --body-file "$TEST_TMPDIR/body.md" 2>"$TEST_TMPDIR/err") || status=$?
  assert_eq 1 "$status"
  assert_eq "https://github.com/owner/repo/issues/7" "$out"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "parts 2 3 of 3 of its body were not posted"
  assert_eq '{"Area":"UI"}' "$(board_item 7)"
}
