# A folder in expected_files that two or more tickets share makes the wave
# picker see every one of them overlap and run them one at a time (#415).
# plan.sh build records each such folder entry once, naming the tickets
# (shared_folder_warnings); plan.sh render shows it under "Needs your
# attention". A warning only: it never blocks approval.

. "$TESTS_DIR/helpers/run-state.sh"

plan() { "$SCRIPTS/plan.sh" "$@"; }

# draft_with files10 files11 files12: three tickets with the given
# expected_files (JSON arrays) in scope order 10, 11, 12.
draft_with() {
  jq -n --argjson a "$1" --argjson b "$2" --argjson c "$3" '
    def t($n; $f): {title: "Ticket \($n)", model: "claude-sonnet-5-5", blocked_by: [],
                    acceptance: ["t\($n).txt exists"], expected_output: "t\($n).txt", expected_files: $f,
                    expected: {input_tokens: 100000, output_tokens: 10000, minutes: 10}};
    {run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
     scope: ["10", "11", "12"], waves: [["10", "11", "12"]],
     gates: [{kind: "slice", tickets: ["10", "11", "12"]}, {kind: "end"}],
     tickets: {"10": t(10; $a), "11": t(11; $b), "12": t(12; $c)}}' >"$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json" || fail "build refused the draft"
}

test_a_folder_shared_by_two_tickets_is_flagged_once_naming_them() {
  make_project
  draft_with '["tests/", "a.sh"]' '["tests/", "b.sh"]' '["c.sh"]'
  assert_eq '[{"entry":"tests/","tickets":["10","11"]}]' "$(jq -c .shared_folder_warnings "$TEST_TMPDIR/plan.json")"
  local out=; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Needs your attention"
  assert_contains "$out" '`tests/` is listed by #10, #11'
  assert_eq 1 "$(grep -c 'is listed by' <<<"$out")"
  assert_contains "$out" "Approve as shown"
}

test_each_shared_folder_gets_its_own_line() {
  make_project
  draft_with '["tests/", "docs/"]' '["tests/", "docs/"]' '["docs/"]'
  assert_eq '[{"entry":"tests/","tickets":["10","11"]},{"entry":"docs/","tickets":["10","11","12"]}]' \
    "$(jq -c .shared_folder_warnings "$TEST_TMPDIR/plan.json")"
  local out=; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_eq 2 "$(grep -c 'is listed by' <<<"$out")"
  assert_contains "$out" '`docs/` is listed by #10, #11, #12'
}

test_files_and_unshared_folders_are_not_flagged() {
  make_project
  draft_with '["tests/", "same.sh"]' '["docs/", "same.sh"]' '[]'
  assert_eq '[]' "$(jq -c .shared_folder_warnings "$TEST_TMPDIR/plan.json")"
  local out=; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_not_contains "$out" "is listed by"
}
