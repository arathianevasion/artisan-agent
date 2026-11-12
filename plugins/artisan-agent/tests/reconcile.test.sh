# The reconciler: state against git and the tracker (a stub gh), and the
# frontier recomputed from them rather than from the plan.

. "$TESTS_DIR/helpers/run-state.sh"

# The run used by most tests. Scope 10..15, forecast waves [[10,13],[11],[12]].
#   10  merged into run/r1, closed on the tracker
#   11  blocked by 10                         -> frontier
#   12  blocked by 11                         -> waits
#   13  forecast in wave 1, but the tracker now has it blocked by #99 (open,
#       outside the run)                      -> waits
#   14  its branch exists on the integration line with nothing merged yet,
#       no blockers                           -> frontier, not merged
#   15  labelled ready-for-human             -> held, not on the frontier
setup_run() {
  install_gh_stub
  init_run '["10","11","12","13","14","15"]'
  git_quiet -C "$PROJECT" branch run/r1 main
  branch_with_commit 10
  MERGE10=$(merge_ticket 10)
  git_quiet -C "$PROJECT" branch agent/14 run/r1
  stub_issue 10 closed
  stub_issue 11 open ready-for-agent
  stub_issue 12 open
  stub_issue 13 open
  stub_issue 14 open
  stub_issue 15 open ready-for-human
  stub_blocked_by 11 10:closed
  stub_blocked_by 12 11:open
  stub_blocked_by 13 99:open
}

test_a_crashed_orchestrator_is_recovered_by_a_new_reconciler_run() {
  setup_run
  # The orchestrator dispatched 10, merged it, and died before writing the
  # merge to the state file: the file still says 10 is in flight, under a
  # worker pid that is gone, and the frontier it left is the plan's wave 1.
  local dead=
  sleep 0 &
  dead=$!
  wait "$dead"
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$dead"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.frontier = ["10","13"]'
  local frontier=
  frontier=$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ')
  assert_eq "11 14 " "$frontier" "frontier printed"
  assert_eq '["11","14"]' "$(jq -c .frontier "$RUN_DIR/state.json")" "frontier stored"
  assert_eq merged "$(state_get '.tickets["10"].status')"
  assert_eq "$MERGE10" "$(state_get '.tickets["10"].merge_commit')"
  assert_eq "$MERGE10" "$(state_get '.integration.merges[0].commit')"
  assert_eq 0 "$(state_get '.tickets["10"].failures | length')" "a merged worker is not a failed attempt"
  assert_eq queued "$(state_get '.tickets["14"].status')"
}

test_reconciling_twice_changes_nothing() {
  setup_run
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local first=
  first=$(cat "$RUN_DIR/state.json")
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_eq "$first" "$(cat "$RUN_DIR/state.json")" "state after a second reconcile"
}

test_a_blocker_merged_into_the_integration_branch_unblocks_its_dependent() {
  setup_run
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  # 11 lands; the tracker still has it open (not closed yet) but it is merged.
  branch_with_commit 11
  merge_ticket 11 >/dev/null
  assert_eq "12 14" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq merged "$(state_get '.tickets["11"].status')"
}

test_a_reported_but_unmerged_blocker_does_not_unblock() {
  setup_run
  # 11 says complete, but nothing is merged: 12 must wait.
  branch_with_commit 11
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["11"].status = "returned"'
  stub_blocked_by 12 11:closed
  local frontier=
  frontier=$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ')
  case " $frontier" in *" 12 "*) fail "12 dispatchable on a reported, unmerged blocker: [$frontier]" ;; esac
}

test_a_ticket_closed_on_the_tracker_without_a_merge_leaves_the_run() {
  setup_run
  stub_issue 14 closed
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_eq closed "$(state_get '.tickets["14"].status')"
}

test_a_ticket_added_to_the_scope_gets_an_entry() {
  setup_run
  stub_issue 16 open
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.scope += ["16"]'
  assert_contains "$("$SCRIPTS/reconcile.sh" "$RUN_DIR")" 16
  assert_eq queued "$(state_get '.tickets["16"].status')"
  assert_eq agent/16 "$(state_get '.tickets["16"].branch')"
}

test_a_failed_tracker_read_exits_nonzero() {
  setup_run
  rm "$GH_STUB/issue-12.json"
  assert_status 1 "$SCRIPTS/reconcile.sh" "$RUN_DIR"
  assert_eq '[]' "$(jq -c .frontier "$RUN_DIR/state.json")"
}

test_only_the_stub_gh_is_called() {
  setup_run
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_eq "$GH_STUB/bin/gh" "$(command -v gh)"
  assert_contains "$(cat "$GH_STUB/calls")" "api repos/owner/repo/issues/11/dependencies/blocked_by"
}
