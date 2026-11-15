# The ticket branches the plugin pushes (#211): worker-ci.sh run and move.sh
# out record each push in the state file's `pushed`, and once the ticket is
# closed or leaves the run, wave.sh close or the next sweep deletes the
# branch on the remote. A local bare remote stands in for GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

PUSHED="$PLUGIN_ROOT/scripts/pushed.sh"

# A project with run r1 started (integration worktree run/r1), a bare remote,
# a CI-only check and a gate workflow, so worker-ci.sh dispatches on CI.
setup_remote_run() {
  make_project
  REMOTE="$TEST_TMPDIR/remote.git"
  git_quiet init --bare "$REMOTE"
  git_quiet -C "$PROJECT" remote add origin "$REMOTE"
  cat >"$PROJECT/CODING_STANDARDS.md" <<'MD'
## Checks

- `npx playwright test`: proven to fail on 2026-11-01, breaking: a wrong label (runs_locally: never)
MD
  printf 'max_agents: 5\nci_gate:\n  workflow: ci.yml\n' >"$PROJECT/.artisan-agent/config.yml"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "checks"
  git_quiet -C "$PROJECT" push origin main
  write_plan "$TEST_TMPDIR/plan.json"
  ARTISAN_MACHINE=laptop "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  ARTISAN_MACHINE=laptop "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export FAKE_GH_DIR="$TEST_TMPDIR/gh" FAKE_GH_REMOTE="$REMOTE" ARTISAN_CI_POLL_SECONDS=0
  export ARTISAN_MERGE_GATE=ci ARTISAN_HOST_OS=linux ARTISAN_MACHINE=laptop
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
}

# A worker on ticket t: its branch off run/r1 with one commit, in its own
# worktree, then its CI run (worker-ci.sh run) as a run's worker makes it.
worker_ci_for() { # ticket
  local wt="$TEST_TMPDIR/project-wt/w$1"
  git_quiet -C "$PROJECT" worktree add -b "agent/$1" "$wt" run/r1
  printf '%s\n' "$1" >"$wt/t$1.txt"
  git_quiet -C "$wt" add -A
  git_quiet -C "$wt" commit -m "ticket $1"
  (cd "$wt" && ARTISAN_RUN_DIR="$RUN_DIR" "$SCRIPTS/worker-ci.sh" run --repo local/sample >/dev/null 2>"$TEST_TMPDIR/wci.err") \
    || fail "worker-ci.sh run failed: $(cat "$TEST_TMPDIR/wci.err")"
  git_quiet -C "$PROJECT" worktree remove --force "$wt"
}

on_remote() { git -C "$REMOTE" rev-parse -q --verify "refs/heads/$1" >/dev/null 2>&1; }

# The ticket's work is merged into run/r1 and the ticket marked merged (and,
# with "closed", closed on the tracker) in the state file.
mark_merged() { # ticket [closed]
  local tc=false
  [ "${2:-}" = closed ] && tc=true
  git_quiet -C "$TEST_TMPDIR/project-wt/run-r1" merge --no-ff -m "Merge agent/$1" "agent/$1"
  jq --arg t "$1" --argjson tc "$tc" '.tickets[$t].status = "merged" | .tickets[$t].tracker_closed = $tc' \
    "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json" && mv "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
}

test_a_worker_ci_branch_is_gone_from_the_remote_once_its_ticket_is_closed() {
  setup_remote_run
  worker_ci_for 10
  on_remote agent/10 || fail "worker-ci.sh did not push agent/10"
  # Merged but not yet closed: the branch stays.
  mark_merged 10
  "$PUSHED" prune "$RUN_DIR" >/dev/null 2>&1
  on_remote agent/10 || fail "agent/10 was deleted before its ticket was closed"
  assert_eq "10 worker-ci" "$(jq -r '.pushed["agent/10"] | "\(.ticket) \(.by)"' "$RUN_DIR/state.json")"
  # wave.sh close, on a ticket already closed on the tracker, deletes it.
  jq '.tickets["10"].tracker_closed = true' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json" && mv "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
  "$SCRIPTS/wave.sh" close "$RUN_DIR" 10 >/dev/null 2>"$TEST_TMPDIR/close.err" || fail "wave.sh close failed: $(cat "$TEST_TMPDIR/close.err")"
  if on_remote agent/10; then fail "agent/10 is still on the remote after its ticket closed"; fi
  assert_eq null "$(jq -c '.pushed["agent/10"]' "$RUN_DIR/state.json")"
  assert_eq "agent/10" "$(jq -r '[.events[] | select(.event == "branch-deleted")][0].branch' "$RUN_DIR/state.json")"
  # The local branch is the worker's, untouched.
  git -C "$PROJECT" rev-parse -q --verify refs/heads/agent/10 >/dev/null || fail "the local agent/10 was deleted"
}

test_a_ticket_that_leaves_the_run_has_its_branch_deleted_by_the_sweep() {
  setup_remote_run
  worker_ci_for 11
  jq '.tickets["11"].status = "dropped"' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json" && mv "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard >/dev/null 2>&1
  if on_remote agent/11; then fail "agent/11 is still on the remote after its ticket was dropped"; fi
}

test_moved_tickets_branches_are_gone_from_the_remote_once_closed_on_the_other_machine() {
  setup_remote_run
  local t=
  for t in 10 11; do
    git_quiet -C "$PROJECT" branch "agent/$t" run/r1
    git_quiet -C "$PROJECT" checkout "agent/$t"
    printf '%s\n' "$t" >"$PROJECT/t$t.txt"
    git_quiet -C "$PROJECT" add "t$t.txt"
    git_quiet -C "$PROJECT" commit -m "ticket $t"
    git_quiet -C "$PROJECT" checkout main
  done
  jq '.tickets["10"].status = "returned" | .tickets["11"].status = "returned"' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json" && mv "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
  (cd "$PROJECT" && "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null)
  on_remote agent/10 && on_remote agent/11 || fail "move.sh out did not push the ticket branches"
  assert_eq "move move" "$(jq -r '[.pushed["agent/10"].by, .pushed["agent/11"].by] | join(" ")' "$RUN_DIR/state.json")"
  # The host resumes the run, merges and closes 10, drops 11.
  local clone="$TEST_TMPDIR/host/project" crun=
  mkdir -p "$TEST_TMPDIR/host"
  git_quiet clone "$REMOTE" "$clone"
  crun="$clone/.artisan-agent/runs/r1"
  (cd "$clone" && ARTISAN_MACHINE=host "$SCRIPTS/move.sh" in r1 >/dev/null) || fail "move.sh in failed"
  git_quiet -C "$TEST_TMPDIR/host/project-wt/run-r1" merge --no-ff -m "Merge agent/10" agent/10
  jq '.tickets["10"].status = "merged" | .tickets["10"].tracker_closed = true | .tickets["11"].status = "dropped"' \
    "$crun/state.json" >"$TEST_TMPDIR/s.json" && mv "$TEST_TMPDIR/s.json" "$crun/state.json"
  (cd "$clone" && ARTISAN_MACHINE=host "$PUSHED" prune "$crun" >/dev/null 2>&1) || fail "prune on the host failed"
  if on_remote agent/10; then fail "agent/10 is still on the remote"; fi
  if on_remote agent/11; then fail "agent/11 is still on the remote"; fi
  assert_eq "{}" "$(jq -c '.pushed' "$crun/state.json")"
}

test_a_branch_someone_else_pushed_to_is_left_with_a_warning_naming_it() {
  setup_remote_run
  worker_ci_for 10
  # Someone else pushes a commit the run never saw onto agent/10.
  local other="$TEST_TMPDIR/other"
  git_quiet clone -b agent/10 "$REMOTE" "$other"
  printf 'theirs\n' >"$other/theirs.txt"
  git_quiet -C "$other" add -A
  git_quiet -C "$other" commit -m "someone else's work"
  git_quiet -C "$other" push origin agent/10
  mark_merged 10 closed
  local err=
  err=$("$PUSHED" prune "$RUN_DIR" 2>&1 >/dev/null)
  on_remote agent/10 || fail "agent/10 was deleted although someone else pushed to it"
  assert_contains "$err" "agent/10"
  assert_contains "$err" "moved"
  # Left for good: the next prune neither deletes nor warns again.
  assert_eq null "$(jq -c '.pushed["agent/10"]' "$RUN_DIR/state.json")"
  assert_eq "agent/10" "$(jq -r '[.events[] | select(.event == "branch-left")][0].branch' "$RUN_DIR/state.json")"
  assert_eq "" "$("$PUSHED" prune "$RUN_DIR" 2>&1)"
}

test_a_branch_whose_tip_is_already_merged_is_deleted() {
  setup_remote_run
  worker_ci_for 10
  # A later attempt's commit reached the remote some other way, and was merged.
  git_quiet -C "$PROJECT" checkout agent/10
  printf 'more\n' >>"$PROJECT/t10.txt"
  git_quiet -C "$PROJECT" commit -am "attempt 2"
  git_quiet -C "$PROJECT" checkout main
  git_quiet -C "$PROJECT" push -f origin agent/10
  mark_merged 10 closed
  "$PUSHED" prune "$RUN_DIR" >/dev/null 2>&1
  if on_remote agent/10; then fail "agent/10, merged, is still on the remote"; fi
}

test_a_failed_delete_is_retried_by_the_next_sweep() {
  setup_remote_run
  worker_ci_for 10
  mark_merged 10 closed
  mv "$REMOTE" "$REMOTE.away"
  local err=
  err=$("$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard 2>&1 >/dev/null)
  assert_contains "$err" "could not delete agent/10"
  assert_eq 1 "$(jq -r '.pushed["agent/10"].failed.tries' "$RUN_DIR/state.json")"
  mv "$REMOTE.away" "$REMOTE"
  on_remote agent/10 || fail "agent/10 vanished while the remote was away"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" --no-guard >/dev/null 2>&1
  if on_remote agent/10; then fail "agent/10 is still on the remote after the retry"; fi
  assert_eq null "$(jq -c '.pushed["agent/10"]' "$RUN_DIR/state.json")"
}

test_note_and_prune_on_a_run_with_nothing_pushed_change_nothing() {
  init_run
  local before=
  before=$(state_sum)
  "$PUSHED" prune "$RUN_DIR"
  assert_eq "$before" "$(state_sum)"
}
