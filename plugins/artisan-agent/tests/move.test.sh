# Moving a run between machines (#69): two clones and one bare remote.
# ARTISAN_MACHINE names each clone, so one machine can play both.

. "$TESTS_DIR/helpers/run-state.sh"

# two_machines: PROJECT is machine "laptop" with run r1 started (integration
# worktree, one commit on it); CLONE is machine "host", a clone of the remote.
two_machines() {
  make_project
  REMOTE="$TEST_TMPDIR/remote.git"
  git_quiet init --bare "$REMOTE"
  git_quiet -C "$PROJECT" remote add origin "$REMOTE"
  git_quiet -C "$PROJECT" push origin main
  write_plan "$TEST_TMPDIR/plan.json"
  ARTISAN_MACHINE=laptop "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  ARTISAN_MACHINE=laptop "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  WT="$TEST_TMPDIR/project-wt/run-r1"
  printf 'work\n' >"$WT/work.txt"
  git_quiet -C "$WT" add -A
  git_quiet -C "$WT" commit -m "merged work"
  mkdir -p "$RUN_DIR/results"
  printf '{"ticket":"10"}\n' >"$RUN_DIR/results/10.1.result.json"
  CLONE="$TEST_TMPDIR/host/project"
  mkdir -p "$TEST_TMPDIR/host"
  git_quiet clone "$REMOTE" "$CLONE"
  CLONE_RUN="$CLONE/.artisan-agent/runs/r1"
}

laptop() { ( cd "$PROJECT" && ARTISAN_MACHINE=laptop "$@" ); }
host() { ( cd "$CLONE" && ARTISAN_MACHINE=host "$@" ); }

test_out_pushes_the_run_branch_and_in_resumes_it_on_the_other_machine() {
  two_machines
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  git -C "$REMOTE" rev-parse -q --verify refs/heads/runs/r1 >/dev/null
  git -C "$REMOTE" rev-parse -q --verify refs/heads/run/r1 >/dev/null
  assert_eq "moved laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_eq "live host" "$(host "$SCRIPTS/move.sh" where "$CLONE_RUN")"
  assert_eq r1 "$(jq -r .run_id "$CLONE_RUN/state.json")"
  assert_eq '{"ticket":"10"}' "$(cat "$CLONE_RUN/results/10.1.result.json")"
  # the integration branch, with the merged work, and its worktree are in place
  assert_eq work "$(cat "$TEST_TMPDIR/host/project-wt/run-r1/work.txt")"
  assert_eq "$TEST_TMPDIR/host/project-wt/run-r1" "$(jq -r .integration.worktree "$CLONE_RUN/state.json")"
  # the event log says both moves, in order
  assert_eq "moved-out moved-in" "$(jq -r '[.events[] | select(.event | startswith("moved")) | .event] | join(" ")' "$CLONE_RUN/state.json")"
}

test_the_lock_travels_a_run_is_never_live_on_both_machines() {
  two_machines
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  # moved away: the laptop's copy refuses every write and every lock
  assert_status 3 "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}'
  assert_status 3 "$SCRIPTS/state.sh" lock "$RUN_DIR" 1
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  # live on the host: the laptop still cannot resume it, nor take it from the host
  assert_status 5 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' in r1"
  assert_status 3 "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}'
  # the host writes freely
  host "$SCRIPTS/state.sh" event "$CLONE_RUN" '{"event":"hello"}'
  # and the laptop's stale copy can't be pushed over it: it is not live there
  assert_status 3 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' out '$RUN_DIR'"
}

test_two_machines_resuming_at_once_exactly_one_wins() {
  two_machines
  local third="$TEST_TMPDIR/third/project"
  mkdir -p "$TEST_TMPDIR/third"
  git_quiet clone "$REMOTE" "$third"
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  # both fetch while the run is in transit; the host claims, then the third tries
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_status 5 bash -c "cd '$third' && ARTISAN_MACHINE=third '$SCRIPTS/move.sh' in r1"
  # a stale claim built before the host's lands is refused by the fast-forward rule:
  # push a competing commit on the old tip
  local old=
  old=$(git -C "$REMOTE" rev-parse refs/heads/runs/r1~1)
  git_quiet -C "$third" fetch origin
  local c=
  c=$(git -C "$third" -c user.name=T -c user.email=t@e commit-tree "$(git -C "$third" rev-parse "$old^{tree}")" -p "$old" -m rival)
  if git -C "$third" push -q origin "$c:refs/heads/runs/r1" >/dev/null 2>&1; then fail "a non-fast-forward claim was accepted"; fi
}

test_move_works_back_to_the_first_machine() {
  two_machines
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  printf 'more\n' >"$TEST_TMPDIR/host/project-wt/run-r1/more.txt"
  git_quiet -C "$TEST_TMPDIR/host/project-wt/run-r1" add -A
  git_quiet -C "$TEST_TMPDIR/host/project-wt/run-r1" commit -m "host work"
  host "$SCRIPTS/state.sh" event "$CLONE_RUN" '{"event":"on-host"}'
  host "$SCRIPTS/move.sh" out "$CLONE_RUN" >/dev/null
  laptop "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_eq "live laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  assert_eq more "$(cat "$WT/more.txt")"
  assert_eq 1 "$(jq '[.events[] | select(.event == "on-host")] | length' "$RUN_DIR/state.json")"
  laptop "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"back"}'
}

test_out_refuses_a_run_that_is_not_idle_and_changes_nothing() {
  two_machines
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$$" >/dev/null 2>&1 || ARTISAN_MACHINE=laptop "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$$"
  assert_status 4 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' out '$RUN_DIR'"
  assert_status 4 "$SCRIPTS/move.sh" idle "$RUN_DIR"
  if git -C "$REMOTE" rev-parse -q --verify refs/heads/runs/r1 >/dev/null; then fail "runs/r1 was pushed from a busy run"; fi
  assert_eq "live laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
}

test_a_running_merge_gate_makes_the_run_not_idle_and_out_pushes_nothing() {
  two_machines
  jq '.merge_gate = {ticket: "10", attempt: 1, mode: "local", pre: "x", sha: "y"}' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json"
  cp "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
  assert_contains "$("$SCRIPTS/move.sh" idle "$RUN_DIR" || true)" "a merge gate is running for #10 (local)"
  assert_status 4 "$SCRIPTS/move.sh" idle "$RUN_DIR"
  assert_status 4 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' out '$RUN_DIR'"
  if git -C "$REMOTE" rev-parse -q --verify refs/heads/runs/r1 >/dev/null; then fail "runs/r1 was pushed mid-gate"; fi
  assert_contains "$("$SCRIPTS/move.sh" drain "$RUN_DIR")" "let the gate finish"
  jq '.merge_gate = null' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s.json"
  cp "$TEST_TMPDIR/s.json" "$RUN_DIR/state.json"
  "$SCRIPTS/move.sh" idle "$RUN_DIR"
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  assert_eq "moved host" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR" | sed 's/^moved .*/moved host/')"
}

test_a_live_runner_keeps_the_run_busy_even_when_no_ticket_is_in_flight() {
  two_machines
  sleep 30 &
  local p=$!
  mkdir -p "$RUN_DIR/workers/orchestrator-w1.1"
  echo "$p" >"$RUN_DIR/workers/orchestrator-w1.1/runner.pid"
  assert_status 4 "$SCRIPTS/move.sh" idle "$RUN_DIR"
  kill "$p"; wait "$p" 2>/dev/null || true
  "$SCRIPTS/move.sh" idle "$RUN_DIR"
}

test_drain_halts_new_waves_until_the_run_is_moved() {
  two_machines
  "$SCRIPTS/move.sh" drain "$RUN_DIR"
  assert_eq true "$(jq '.halted.move' "$RUN_DIR/state.json")"
  assert_status 12 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_eq null "$(jq '.halted' "$CLONE_RUN/state.json")"
}

test_a_run_that_never_moved_is_unchanged() {
  init_run
  assert_eq "live" "$("$SCRIPTS/move.sh" where "$RUN_DIR" | cut -d' ' -f1)"
  "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}'
  assert_eq false "$(state_get 'has("location")')"
}

# ---- two-phase out (#107): never live in two places, whenever out dies

die_at() { # point: run move.sh out on the laptop with a self-kill at that point
  ( cd "$PROJECT" && ARTISAN_MACHINE=laptop ARTISAN_MOVE_DIE_AT="$1" "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null 2>&1 ) || true
}

remote_has_run_branch() { git -C "$REMOTE" rev-parse -q --verify refs/heads/runs/r1 >/dev/null 2>&1; }

test_out_killed_after_the_local_mark_is_live_nowhere_and_a_rerun_completes_it() {
  two_machines
  die_at after-mark
  # the local copy is moved, nothing claims it on the remote: live nowhere
  assert_eq "moved laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  if remote_has_run_branch; then fail "runs/r1 was pushed although out died before the push"; fi
  assert_status 3 "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}'
  # a rerun finishes the move
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  remote_has_run_branch
  assert_eq "moved laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  assert_eq false "$(state_get '.location | has("pending")')"
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_eq "live host" "$(host "$SCRIPTS/move.sh" where "$CLONE_RUN")"
}

test_a_refused_push_restores_the_local_copy_to_live_and_reports_it() {
  two_machines
  mkdir -p "$PROJECT/.git/hooks"
  cat >"$PROJECT/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
while read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in refs/heads/runs/*) exit 1 ;; esac
done
exit 0
HOOK
  chmod +x "$PROJECT/.git/hooks/pre-push"
  assert_status 6 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' out '$RUN_DIR'"
  assert_eq "live laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  if remote_has_run_branch; then fail "runs/r1 was pushed although the push was refused"; fi
  assert_eq false "$(state_get '.location | has("pending")')"
  laptop "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"still-mine"}'
  assert_eq "move-out-undone" "$(jq -r '[.events[] | select(.event | startswith("move-out")) | .event] | last' "$RUN_DIR/state.json")"
}

test_a_refused_push_keeps_the_drain_halt_so_no_wave_starts_by_surprise() {
  two_machines
  "$SCRIPTS/move.sh" drain "$RUN_DIR"
  mkdir -p "$PROJECT/.git/hooks"
  printf '#!/bin/sh\nwhile read -r a b c d; do case "$c" in refs/heads/runs/*) exit 1 ;; esac; done\nexit 0\n' >"$PROJECT/.git/hooks/pre-push"
  chmod +x "$PROJECT/.git/hooks/pre-push"
  assert_status 6 bash -c "cd '$PROJECT' && ARTISAN_MACHINE=laptop '$SCRIPTS/move.sh' out '$RUN_DIR'"
  assert_eq true "$(state_get '.halted.move')"
}

test_out_killed_after_the_push_reads_as_moved_and_the_other_machine_resumes() {
  two_machines
  die_at after-push
  assert_eq "moved laptop" "$(laptop "$SCRIPTS/move.sh" where "$RUN_DIR")"
  assert_status 3 "$SCRIPTS/state.sh" event "$RUN_DIR" '{"event":"x"}'
  host "$SCRIPTS/move.sh" in r1 >/dev/null
  assert_eq "live host" "$(host "$SCRIPTS/move.sh" where "$CLONE_RUN")"
  # a rerun on the laptop only clears its marker; it does not touch the host's claim
  laptop "$SCRIPTS/move.sh" out "$RUN_DIR" >/dev/null
  assert_eq false "$(state_get '.location | has("pending")')"
  assert_eq "live host" "$(host "$SCRIPTS/move.sh" where "$CLONE_RUN")"
}

# bash 3.2 (macOS) gives a bare `local x` an empty value; bash 4+ (Linux CI) leaves
# it unset, so under set -u the first move (no runs/<id> on the remote yet: the fetch
# fails) died at "rstatus: unbound variable". 3.2 cannot show that, so pin the cause:
# the remote-state variables are set before the fetch that may skip them.
test_the_remote_state_is_set_before_the_fetch_that_may_fail() {
  local var= assign= fetch=
  fetch=$(grep -n 'fetch -q "\$remote" "+refs/heads/runs/\$id:\$rref"' "$SCRIPTS/move.sh" | head -1 | cut -d: -f1)
  [ -n "$fetch" ] || fail "cannot find the runs/<id> fetch in move.sh"
  for var in prev rstate rstatus rmach; do
    assign=$(grep -n "^ *\(.* \)\{0,1\}$var=\"\"" "$SCRIPTS/move.sh" | head -1 | cut -d: -f1)
    [ -n "$assign" ] && [ "$assign" -lt "$fetch" ] || fail "$var is not set before the runs/<id> fetch (unbound under set -u on bash 4+)"
  done
}
