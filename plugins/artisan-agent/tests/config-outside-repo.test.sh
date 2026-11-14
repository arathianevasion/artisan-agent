# config.sh outside a git repository (#159): with no --file every subcommand
# that resolves the project path fails with exit 1, empty stdout and the
# message on stderr; --file still works.

. "$TESTS_DIR/helpers/run-state.sh"

# outside_run args...: config.sh from a directory that is not in any repo.
outside_run() {
  local dir="$TEST_TMPDIR/outside"
  mkdir -p "$dir"
  (cd "$dir" && GIT_CEILING_DIRECTORIES="$TEST_TMPDIR" "$SCRIPTS/config.sh" "$@")
}

check_refused() {
  local out="" rc=0
  out=$(outside_run "$@" 2>"$TEST_TMPDIR/err") || rc=$?
  assert_eq 1 "$rc" "config.sh $* exit"
  assert_eq "" "$out" "config.sh $* stdout"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "not inside a git repository; pass --file"
}

test_show_outside_a_repo_exits_1_with_nothing_on_stdout() { check_refused show; }
test_get_outside_a_repo_exits_1_with_nothing_on_stdout() { check_refused get max_agents; }
test_path_outside_a_repo_exits_1_with_nothing_on_stdout() { check_refused path; }

test_file_still_works_outside_a_repo() {
  printf 'max_agents: 7\n' >"$TEST_TMPDIR/c.yml"
  assert_eq 7 "$(outside_run get max_agents --file "$TEST_TMPDIR/c.yml")"
  assert_eq 7 "$(outside_run show --file "$TEST_TMPDIR/c.yml" | jq .max_agents)"
}

test_inside_a_repo_get_reads_the_project_config() {
  make_project
  assert_eq 5 "$(cd "$PROJECT" && "$SCRIPTS/config.sh" get max_agents)"
  assert_eq "$PROJECT/.artisan-agent/config.yml" "$(cd "$PROJECT" && "$SCRIPTS/config.sh" path)"
}
