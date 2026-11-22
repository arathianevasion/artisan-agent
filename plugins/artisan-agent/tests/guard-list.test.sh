# The guard tests: tests that check the whole plugin tree rather than one seam.
# tests/guard.txt lists them ("guard <file>") and the whole-tree scanners left
# out on purpose ("exclude <file> <why>"); tests/run.sh --guard runs just those.

GUARD_LIST="$TESTS_DIR/guard.txt"

# listed kind: the test names (no .test.sh) the list gives that kind.
listed() { awk -v k="$1" '$1 == k { print $2 }' "$GUARD_LIST"; }

# scanning_tests: every test file that walks the plugin tree: a find or
# recursive grep from $PLUGIN_ROOT, a scan or shell_files helper handed it, or
# a glob over its scripts or skills.
scanning_tests() {
  grep -lE 'find "\$PLUGIN_ROOT|grep -[a-zA-Z]*r[a-zA-Z]* .*PLUGIN_ROOT|(scan|shell_files) "\$PLUGIN_ROOT|"\$PLUGIN_ROOT"/(scripts|skills)/\*' \
    "$TESTS_DIR"/*.test.sh | while IFS= read -r f; do
    basename "$f" .test.sh
  done | grep -vxF guard-list
}

test_the_list_names_the_guards_the_ticket_names() {
  local n=
  for n in tracker bare-local jq-args; do
    listed guard | grep -qxF "$n" || fail "$n is not in tests/guard.txt as a guard test"
  done
}

test_every_listed_test_exists() {
  local n=
  for n in $(listed guard) $(listed exclude); do
    [ -f "$TESTS_DIR/$n.test.sh" ] || fail "tests/guard.txt names $n, which has no $n.test.sh"
  done
}

test_every_excluded_test_says_why() {
  local bad=
  bad=$(awk '$1 == "exclude" && NF < 3 { print $2 }' "$GUARD_LIST")
  assert_eq "" "$bad" "excluded without a reason in tests/guard.txt"
}

test_every_line_is_a_guard_or_an_exclusion() {
  local bad=
  bad=$(awk '$0 !~ /^#/ && NF > 0 && $1 != "guard" && $1 != "exclude" { print }' "$GUARD_LIST")
  assert_eq "" "$bad" "lines in tests/guard.txt that are not 'guard <file>' or 'exclude <file> <why>'"
}

test_every_whole_tree_scanner_is_a_guard_or_deliberately_excluded() {
  local n= missing= all=
  all=$(printf '%s\n%s\n' "$(listed guard)" "$(listed exclude)")
  for n in $(scanning_tests); do
    printf '%s\n' "$all" | grep -qxF "$n" || missing="$missing $n"
  done
  assert_eq "" "$missing" "whole-tree scanning tests in neither list of tests/guard.txt (add 'guard <file>' or 'exclude <file> <why>')"
}

test_guard_runs_only_the_guard_tests() {
  mkdir suite
  printf '# a comment\nguard a\nexclude c why not\n' > suite/guard.txt
  printf 'test_one() { :; }\n' > suite/a.test.sh
  printf 'test_two() { :; }\n' > suite/b.test.sh
  printf 'test_three() { :; }\n' > suite/c.test.sh
  local out=
  out=$("$TESTS_DIR/run.sh" --guard suite 2>&1) || fail "run.sh --guard failed: $out"
  assert_contains "$out" "ok   a: test_one"
  assert_not_contains "$out" "b: test_two" "a test outside the list ran under --guard"
  assert_not_contains "$out" "c: test_three" "an excluded test ran under --guard"
  assert_contains "$out" "1 passed, 0 failed"
}

test_guard_with_a_missing_listed_file_fails() {
  mkdir suite
  printf 'guard nothing-here\n' > suite/guard.txt
  printf 'test_a() { :; }\n' > suite/a.test.sh
  local rc=0 out=
  out=$("$TESTS_DIR/run.sh" --guard suite 2>&1) || rc=$?
  assert_eq 2 "$rc"
  assert_contains "$out" "nothing-here"
}

test_guard_with_no_list_fails() {
  mkdir suite
  printf 'test_a() { :; }\n' > suite/a.test.sh
  local rc=0
  "$TESTS_DIR/run.sh" --guard suite >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc"
}

test_the_implement_skill_has_workers_run_the_guard_and_ticket_tests() {
  local s=
  s=$(cat "$PLUGIN_ROOT/skills/implement/SKILL.md")
  assert_contains "$s" "tests/run.sh --guard" "SKILL.md does not give the guard command"
  assert_contains "$s" "the guard tests, before the result file" "SKILL.md does not have workers run the guard tests before the result file"
  assert_contains "$s" "Name each test you ran in \`tests.files\`" "SKILL.md does not have workers name the tests they ran"
  assert_contains "$s" '`tests.not_run`' "SKILL.md does not say where a test it couldn't run goes"
}

test_the_implement_skill_says_not_to_run_the_full_suite() {
  assert_contains "$(cat "$PLUGIN_ROOT/skills/implement/SKILL.md")" "Don't run the full suite"
}
