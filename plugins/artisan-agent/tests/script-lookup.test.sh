# A script finds its sibling scripts from its own location, never through the
# repo's main checkout, and no process a test starts outlives that test (#137).
# Run from a worktree, the suite must test the branch's scripts, not main's.

. "$TESTS_DIR/helpers/run-state.sh"

# A repo whose main checkout and whose linked worktree each hold a copy of the
# plugin's scripts; each copy's run-ticket.sh only writes its own name to
# $TEST_TMPDIR/ran and fails.
setup_two_copies() {
  init_run
  local where= dir=
  mkdir -p "$TEST_TMPDIR/project-wt"
  WT="$TEST_TMPDIR/project-wt/w"
  git_quiet -C "$PROJECT" worktree add -b w "$WT"
  for where in "$PROJECT" "$WT"; do
    dir="$where/plugins/artisan-agent"
    mkdir -p "$dir"
    cp -R "$PLUGIN_ROOT/scripts" "$dir/scripts"
    printf '#!/bin/sh\necho %s >>"%s/ran"\nexit 1\n' "$(basename "$where")" "$TEST_TMPDIR" >"$dir/scripts/run-ticket.sh"
    chmod +x "$dir/scripts/run-ticket.sh"
  done
  : >"$TEST_TMPDIR/ran"
}

test_a_worktrees_wave_script_launches_the_worktrees_run_ticket() {
  setup_two_copies
  export PATH="$TESTS_DIR/fixtures/fake-gh:$TESTS_DIR/fixtures/fake-claude:$PATH"
  local scripts_dir="$WT/plugins/artisan-agent/scripts"
  (cd "$WT" && "$scripts_dir/wave.sh" start "$RUN_DIR" >/dev/null 2>&1; "$scripts_dir/wave.sh" launch "$RUN_DIR" >/dev/null 2>&1) || true
  assert_eq "w" "$(sort -u "$TEST_TMPDIR/ran")" "only the worktree's run-ticket.sh ran"
}

test_no_script_builds_a_sibling_path_from_the_main_checkout() {
  local f= bad=
  for f in "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/lib/*.sh; do
    if grep -nE '\$\{?(MAIN|main|common)\}?/(plugins|scripts)|dirname "\$common"\)?/(plugins|scripts)' "$f" >/dev/null; then
      bad="$bad $f"
    fi
  done
  assert_eq "" "$bad" "scripts that look for scripts through the main checkout"
}

test_a_process_a_test_leaves_behind_is_ended_when_the_test_ends() {
  local suite="$TEST_TMPDIR/suite"
  mkdir -p "$suite"
  cat >"$suite/leaky.test.sh" <<EOT
test_starts_a_detached_worker_and_walks_away() {
  ( cd "\$TEST_TMPDIR" && exec sh -c 'while :; do sleep 1; done' "\$TEST_TMPDIR" ) >/dev/null 2>&1 </dev/null &
  echo \$! >"$TEST_TMPDIR/leaked.pid"
  sleep 0.5
}
EOT
  bash "$PLUGIN_ROOT/tests/run.sh" "$suite" >"$TEST_TMPDIR/inner.out" 2>&1 || fail "inner suite failed: $(cat "$TEST_TMPDIR/inner.out")"
  local pid=
  pid=$(cat "$TEST_TMPDIR/leaked.pid")
  [ -n "$pid" ] || fail "no pid recorded"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "the test's detached process was still alive after the test ended"
  fi
}
