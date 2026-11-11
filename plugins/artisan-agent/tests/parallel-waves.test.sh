# Parallel waves (#58): wave width, serial merges with the suite after each,
# one /artisan-agent:resolve-conflicts try per conflict, two attempts per
# ticket, and a wholly failed wave halting the run. End to end through the
# two tiers, with the fake `claude` running a scripted orchestrator that
# follows references/orchestrator.md and parallel-waves.md, scripted workers,
# and the fake `gh` over a folder tracker. Nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"
. "$PLUGIN_ROOT/scripts/lib/state-lib.sh"   # state_pid_alive

# setup_waves max-agents ticket...: a project whose suite (check.sh) logs
# the commit it ran on and fails when a file named BROKEN exists; a fake
# tracker with each ticket open and unblocked; a run r1 over the tickets.
# Each ticket expects the files in $EXPECT_<t> (JSON; default ["t<t>.txt"],
# "none" to declare none). Per-ticket worker behaviour: $WAVES/ticket-<t>.
setup_waves() {
  local max="$1" t
  shift
  make_project
  export WAVES="$TEST_TMPDIR/waves"
  mkdir -p "$WAVES"
  printf '#!/bin/sh\ngit rev-parse HEAD >>"%s/suite-runs"\n[ ! -e BROKEN ] && echo "suite ok"\n' "$WAVES" >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  MAIN_HEAD=$(git -C "$PROJECT" rev-parse HEAD)

  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local tickets='{}'
  for t in "$@"; do
    jq -n --argjson n "$t" '{number: $n, title: "Ticket \($n)", state: "open", labels: [],
      body: "## Acceptance criteria\n- [ ] it works"}' >"$FAKE_GH_DIR/issue-$t.json"
    local var="EXPECT_$t" files
    files=${!var:-"[\"t$t.txt\"]"}
    tickets=$(jq --arg t "$t" --arg f "$files" '.[$t] = ({title: "Ticket \($t)", model: "claude-sonnet-5-5",
      estimate_usd: 0.25, expected: {minutes: 5}, expected_output: "t\($t).txt",
      caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}
      + (if $f == "none" then {} else {expected_files: ($f | fromjson)} end))' <<<"$tickets")
  done
  jq -n --argjson scope "$(printf '%s\n' "$@" | jq -R . | jq -s .)" --argjson tickets "$tickets" \
    --argjson max "$max" '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: $scope,
    waves: [$scope], max_agents: $max, attempts_per_ticket: 2, suite_command: "sh check.sh",
    orchestrator: {estimate_usd: 0.25}, tickets: $tickets}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"

  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script FAKE_CLAUDE_LOG="$TEST_TMPDIR/fake-claude.log" SCRIPTS
  write_worker
  write_orchestrator
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  INTEGRATION="$TEST_TMPDIR/project-wt/run-r1"
}

cleanup() {
  local pid
  for pid in $(cat "$RUN_DIR"/workers/*/runner.pid 2>/dev/null); do
    kill -KILL "-$pid" "$pid" 2>/dev/null || true
  done
  kill_workers
}

# The worker: writes CONTENT to FILE (default t<t>.txt), commits, and writes
# its evidence record; on an attempt listed in FAIL it reports failed.
# $WAVES/ticket-<t> may set FILE, CONTENT, FAIL and SLEEP.
write_worker() {
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
base=$(basename "$ARTISAN_RESULT_FILE" .result.json)
t=${base%.*} n=${base##*.}
FILE="t$t.txt" CONTENT="$t" FAIL="" SLEEP="${WORKER_SLEEP:-0}"
[ ! -f "$WAVES/ticket-$t" ] || . "$WAVES/ticket-$t"
echo "$t.$n start" >>"$WAVES/worker.log"
sleep "$SLEEP"
mkdir -p "$(dirname "$FILE")"
printf '%s\n' "$CONTENT" >"$FILE"
git add -A && git commit -q --allow-empty -m "ticket $t attempt $n"
case " $FAIL " in
  *" $n "*)
    jq -n --arg t "$t" --arg c "$(git rev-parse HEAD)" '{ticket: $t, status: "failed", commit: $c,
      acceptance: [{criterion: "it works", met: false, evidence: {why: "seeded failure"}}],
      tests: {suite_passed: false, command: "sh check.sh", summary: "1 failed"},
      unsure: ["whether the seed is right"], decisions: [], review: {ran: false, remarks: []}, findings: [],
      notes: "Seeded failure: the parser half is done, the writer is not."}' >"$ARTISAN_RESULT_FILE"
    echo "$t.$n failed" >>"$WAVES/worker.log"
    exit 0 ;;
esac
jq -n --arg t "$t" --arg c "$(git rev-parse HEAD)" '{ticket: $t, status: "complete", commit: $c,
  acceptance: [{criterion: "it works", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
echo "$t.$n done" >>"$WAVES/worker.log"
EOF
}

# The orchestrator, as references/orchestrator.md and parallel-waves.md tell
# the real one: pick the wave, dispatch, wait and sweep, retry a failed
# attempt with a fresh worker, merge one ticket at a time, give a conflict
# its one resolve-conflicts try, close, report. RESOLVE_MODE picks what the
# stand-in for the skill does: both (keep both sides), markers (stage the
# file with its markers), giveup.
write_orchestrator() {
  export FAKE_CLAUDE_SCRIPT_ORCHESTRATOR="$TEST_TMPDIR/orchestrator.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_ORCHESTRATOR" <<'EOF'
set -uo pipefail
S="$SCRIPTS" R="$ARTISAN_RUN_DIR"
st() { jq -r "$@" "$R/state.json"; }
resolve_conflicts() { # the stand-in for /artisan-agent:resolve-conflicts
  echo "$1" >>"$WAVES/skill-calls"
  case "${RESOLVE_MODE:-both}" in
    both)
      for f in $(git diff --name-only --diff-filter=U); do
        grep -v -E '^(<<<<<<<|=======|>>>>>>>)' "$f" >"$f.tmp"; mv "$f.tmp" "$f"; git add "$f"
      done
      "$S/wave.sh" resolved "$R" "$1" ;;
    markers) git add -A; "$S/wave.sh" resolved "$R" "$1" ;;
    litter)
      for f in $(git diff --name-only --diff-filter=U); do
        grep -v -E '^(<<<<<<<|=======|>>>>>>>)' "$f" >"$f.tmp"; mv "$f.tmp" "$f"; git add "$f"
      done
      mkdir -p __pycache__ && touch __pycache__/x.pyc
      "$S/wave.sh" resolved "$R" "$1" ;;
    giveup) "$S/wave.sh" resolved "$R" "$1" --gave-up "both tickets rewrite the greeting" ;;
  esac
}
"$S/reconcile.sh" "$R" >/dev/null || { "$S/wave.sh" report "$R" >"$ARTISAN_RESULT_FILE"; exit 0; }
for t in $("$S/wave-width.sh" pick "$R" 2>>"$WAVES/held.log"); do "$S/wave.sh" dispatch "$R" "$t" >/dev/null; done
w=$(st '.orchestrators | last | .wave')
while :; do
  while [ "$(st '[.tickets[] | select(.status == "in_flight")] | length')" -gt 0 ]; do
    "$S/wait-any.sh" "$R" --timeout 5 >/dev/null || true
    "$S/sweep.sh" "$R"
  done
  again=0
  for t in $(st --argjson w "$w" '.tickets | to_entries[] | select(.value.status == "queued" and .value.wave == $w) | .key'); do
    rc=0
    "$S/wave.sh" dispatch "$R" "$t" >/dev/null 2>&1 || rc=$?
    case "$rc" in 0) again=1 ;; 8) sleep 0.2; again=1 ;; esac
  done
  [ "$again" -eq 0 ] || continue
  returned=$(st '.tickets | to_entries[] | select(.value.status == "returned") | .key')
  [ -n "$returned" ] || break
  for t in $returned; do
    n=$(st --arg t "$t" '.tickets[$t].attempts')
    while [ "$("$S/classify-worker.sh" "$R" "$t" "$n")" = "running -" ]; do sleep 0.2; done
    rc=0
    "$S/wave.sh" merge "$R" "$t" >/dev/null 2>>"$WAVES/merge.err" || rc=$?
    if [ "$rc" -eq 11 ]; then rc=0; resolve_conflicts "$t" >/dev/null 2>>"$WAVES/merge.err" || rc=$?; fi
    [ "$rc" -ne 0 ] || "$S/wave.sh" close "$R" "$t" >/dev/null
  done
done
"$S/wave.sh" report "$R" >"$ARTISAN_RESULT_FILE"
EOF
}

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-60} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

run_wave() { # wave [launch args...]: launch the next orchestrator and wait for it
  local w="$1"
  shift
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" "$@" >/dev/null
  wait_for "$RUN_DIR/results/orchestrator-w$w.1.exit.json" 90
  assert_eq "completed -" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" "orchestrator-w$w" 1)" "orchestrator for wave $w"
}

status_of() { state_get ".tickets[\"$1\"].status"; }
wave_of() { state_get ".tickets[\"$1\"].wave"; }

# ------------------------------------------------------------- wave width

test_four_independent_tickets_and_max_agents_3_dispatch_3_in_the_first_wave() {
  export WORKER_SLEEP=2
  setup_waves 3 1 2 3 4
  run_wave 1
  # Three in flight together: all three dispatched before any result came in.
  assert_eq "dispatch dispatch dispatch" \
    "$(state_get '[.events[] | select(.event == "dispatch" or .event == "result") | .event][0:3] | join(" ")')"
  assert_eq "1 1 1" "$(wave_of 1) $(wave_of 2) $(wave_of 3)"
  assert_eq "merged merged merged queued" "$(status_of 1) $(status_of 2) $(status_of 3) $(status_of 4)"
  assert_contains "$(cat "$WAVES/held.log")" "held #4: no free slot (Max Agents 3, 0 in flight)"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: launch"
  run_wave 2
  assert_eq "merged 2" "$(status_of 4) $(wave_of 4)"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: done"
}

test_pick_is_the_smallest_of_max_agents_ready_and_non_overlapping() {
  EXPECT_1='["src/"]' EXPECT_2='["src/parser.py"]' EXPECT_3='["docs/a.md"]' EXPECT_4='["docs/b.md"]' \
    setup_waves 5 1 2 3 4
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  # Max Agents 5, four ready, but 2 overlaps 1: three.
  assert_eq "1 3 4" "$("$SCRIPTS/wave-width.sh" pick "$RUN_DIR" 2>"$TEST_TMPDIR/held" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "held #2: overlaps #1: both expect src/parser.py" "$(cat "$TEST_TMPDIR/held")"
  # Fewer ready than slots: the ready ones.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.frontier = ["3"]'
  assert_eq "3" "$("$SCRIPTS/wave-width.sh" pick "$RUN_DIR" 2>/dev/null)"
  # Slots already taken by tickets in flight count against Max Agents.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 2 | .frontier = ["3","4"] | .tickets["1"].status = "in_flight"'
  assert_eq "3" "$("$SCRIPTS/wave-width.sh" pick "$RUN_DIR" 2>/dev/null)"
}

test_tickets_with_overlapping_expected_files_never_share_a_wave() {
  EXPECT_1='["src/"]' EXPECT_2='["src/a.txt"]' EXPECT_3='["t3.txt"]' setup_waves 3 1 2 3
  printf 'FILE=src/one.txt\n' >"$WAVES/ticket-1"
  printf 'FILE=src/a.txt\n' >"$WAVES/ticket-2"
  run_wave 1
  assert_eq "1 null 1" "$(wave_of 1) $(wave_of 2) $(wave_of 3)"
  assert_eq "merged queued merged" "$(status_of 1) $(status_of 2) $(status_of 3)"
  # Even with #1 merged, #2 may not join wave 1 late: dispatch refuses it.
  local status=0
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2 >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 10 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "#2 can't join this wave: it overlaps #1: both expect src/a.txt"
  run_wave 2
  assert_eq "merged 2" "$(status_of 2) $(wave_of 2)"
}

test_dispatch_refuses_a_ticket_overlapping_one_in_flight() {
  EXPECT_1='["a/"]' EXPECT_2='["a/b/c.txt"]' setup_waves 3 1 2
  export FAKE_CLAUDE_MODE=sleep FAKE_CLAUDE_SLEEP=30
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_status 10 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
  [ ! -e "$RUN_DIR/workers/2.1" ] || fail "a worker was launched"
  assert_eq queued "$(status_of 2)"
}

test_a_ticket_with_no_expected_files_runs_alone() {
  EXPECT_1=none setup_waves 3 1 2 3
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_eq "1" "$("$SCRIPTS/wave-width.sh" pick "$RUN_DIR" 2>"$TEST_TMPDIR/held")"
  assert_contains "$(cat "$TEST_TMPDIR/held")" "held #2: overlaps #1: #1 declares no expected_files"
}

# ----------------------------------------------------------------- merges

test_merges_are_serial_with_the_suite_after_each_and_a_red_suite_blocks_only_its_ticket() {
  setup_waves 3 1 2 3
  printf 'FILE=BROKEN\n' >"$WAVES/ticket-2"
  EXPECT_2=
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["2"].expected_files = ["BROKEN"]'
  run_wave 1
  assert_eq "merged blocked merged" "$(status_of 1) $(status_of 2) $(status_of 3)"
  assert_contains "$(state_get '.tickets["2"].blocked_reason')" "the suite failed after merging"
  # The suite ran once per merge, each on the integration branch as it stood
  # after that one merge: 1, then 2 (red, undone), then 3 on top of 1.
  local runs m1 m3
  runs=$(cat "$WAVES/suite-runs")
  assert_eq 3 "$(printf '%s\n' "$runs" | wc -l | tr -d ' ')" "suite runs"
  m1=$(state_get '.tickets["1"].merge_commit')
  m3=$(state_get '.tickets["3"].merge_commit')
  assert_eq "$m1" "$(printf '%s\n' "$runs" | sed -n 1p)"
  assert_eq "$m3" "$(printf '%s\n' "$runs" | sed -n 3p)"
  assert_eq "$m1" "$(git -C "$PROJECT" rev-parse "$m3^1")" "#3 merged on top of #1, not of #2"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse "$m1^1")"
  # Only #2 waits on the Artisan; the integration branch is green.
  assert_eq "2" "$(state_get '[.decisions[] | select(.status == "waiting") | .ticket] | join(" ")')"
  (cd "$INTEGRATION" && [ ! -e BROKEN ]) || fail "the red merge was not undone"
  assert_eq "merge merge" "$(state_get '[.events[] | select(.event == "merge") | .event] | join(" ")')"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: decide"
}

# A seeded conflict: tickets 1 and 2 both write greeting.txt, though each
# expected only its own file.
seed_conflict() {
  printf 'FILE=greeting.txt\nCONTENT=hello\n' >"$WAVES/ticket-1"
  printf 'FILE=greeting.txt\nCONTENT=howdy\n' >"$WAVES/ticket-2"
}

test_a_seeded_conflict_gets_one_resolve_conflicts_try_which_resolves_it() {
  setup_waves 3 1 2
  seed_conflict
  run_wave 1
  assert_eq "2" "$(cat "$WAVES/skill-calls")" "resolve-conflicts called once, for #2"
  assert_eq "merged merged" "$(status_of 1) $(status_of 2)"
  assert_eq resolved "$(state_get '.tickets["2"].resolve.outcome')"
  assert_eq "greeting.txt" "$(state_get '.tickets["2"].resolve.paths | join(" ")')"
  assert_eq "conflict resolve" "$(state_get '[.events[] | select(.event == "conflict" or .event == "resolve") | .event] | join(" ")')"
  # Merged --no-ff with both sides kept, and the suite ran on the resolution.
  local m2
  m2=$(state_get '.tickets["2"].merge_commit')
  assert_eq "$(git -C "$PROJECT" rev-parse agent/2)" "$(git -C "$PROJECT" rev-parse "$m2^2")"
  assert_eq "hello howdy" "$(git -C "$PROJECT" show "$m2:greeting.txt" | tr '\n' ' ' | sed 's/ $//')"
  assert_contains "$(git -C "$PROJECT" log -1 --format=%B "$m2")" "resolved by /artisan-agent:resolve-conflicts"
  assert_eq "$m2" "$(tail -n 1 "$WAVES/suite-runs")"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-2.json")"
}

test_a_conflict_it_cannot_resolve_blocks_the_ticket_with_branch_and_worktree_kept() {
  setup_waves 3 1 2
  seed_conflict
  export RESOLVE_MODE=giveup
  run_wave 1
  assert_eq "2" "$(cat "$WAVES/skill-calls")" "resolve-conflicts called once"
  assert_eq "merged blocked" "$(status_of 1) $(status_of 2)"
  assert_contains "$(state_get '.tickets["2"].blocked_reason')" "could not resolve: both tickets rewrite the greeting"
  assert_eq unresolved "$(state_get '.tickets["2"].resolve.outcome')"
  # The branch and its worktree are kept; the integration branch is #1's merge, clean.
  git -C "$PROJECT" rev-parse -q --verify refs/heads/agent/2 >/dev/null || fail "branch agent/2 was deleted"
  [ -d "$TEST_TMPDIR/project-wt/r1-2.1" ] || fail "#2's worktree was removed"
  assert_eq "$(state_get '.tickets["1"].merge_commit')" "$(git -C "$PROJECT" rev-parse run/r1)"
  assert_eq "" "$(git -C "$INTEGRATION" status --porcelain)" "integration worktree clean"
  ! git -C "$INTEGRATION" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "merge left in progress"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-2.json")"
  # Once only: merging again blocks at once, with no second try offered.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["2"].status = "returned"'
  local status=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 2 >/dev/null 2>&1 || status=$?
  assert_eq 6 "$status"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "conflict")] | length')"
  assert_contains "$(state_get '.tickets["2"].blocked_reason')" "its one /artisan-agent:resolve-conflicts try is used"
}

test_a_resolution_that_leaves_conflict_markers_is_unresolved() {
  setup_waves 3 1 2
  seed_conflict
  export RESOLVE_MODE=markers
  run_wave 1
  assert_eq blocked "$(status_of 2)"
  assert_contains "$(state_get '.tickets["2"].resolve.why')" "conflict markers left in greeting.txt"
  assert_eq "$(state_get '.tickets["1"].merge_commit')" "$(git -C "$PROJECT" rev-parse run/r1)"
}

test_a_resolution_that_leaves_files_behind_is_unresolved_and_cleaned_up() {
  setup_waves 3 1 2
  seed_conflict
  export RESOLVE_MODE=litter
  run_wave 1
  assert_eq blocked "$(status_of 2)"
  assert_contains "$(state_get '.tickets["2"].resolve.why')" "files left behind: __pycache__/"
  assert_eq "" "$(git -C "$INTEGRATION" status --porcelain)" "integration worktree clean"
}

test_a_resolution_that_never_came_back_is_abandoned_before_the_next_merge() {
  setup_waves 3 1 2 3
  seed_conflict
  # Workers only: build all three, then merge by hand as an orchestrator would.
  local t
  for t in 1 2 3; do "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" "$t" >/dev/null; done
  for t in 1 2 3; do wait_for "$RUN_DIR/results/$t.1.exit.json"; done
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  assert_status 11 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 2
  git -C "$INTEGRATION" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "the conflict is not left in progress"
  # The orchestrator ended mid-try; the next merge clears it first.
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 3 >/dev/null
  assert_eq "merged blocked merged" "$(status_of 1) $(status_of 2) $(status_of 3)"
  assert_eq abandoned "$(state_get '.tickets["2"].resolve.outcome')"
  assert_status 1 "$SCRIPTS/wave.sh" resolved "$RUN_DIR" 2
}

# ---------------------------------------------------------------- retries

test_a_failed_first_attempt_is_retried_by_a_fresh_worker_given_the_failure_evidence() {
  setup_waves 3 1
  printf 'FAIL=1\n' >"$WAVES/ticket-1"
  run_wave 1
  assert_eq "merged 2" "$(status_of 1) $(state_get '.tickets["1"].attempts')"
  assert_eq "1.1 start|1.1 failed|1.2 start|1.2 done" "$(tr '\n' '|' <"$WAVES/worker.log" | sed 's/|$//')"
  # A fresh session: its own worker folder, runner and prompt.
  [ "$(cat "$RUN_DIR/workers/1.1/runner.pid")" != "$(cat "$RUN_DIR/workers/1.2/runner.pid")" ] \
    || fail "the retry reused the first runner"
  local prompt
  prompt=$(cat "$RUN_DIR/workers/1.2/prompt.md")
  assert_contains "$prompt" "This is a retry, attempt 2 of 2. The last attempt failed: worker reported failed"
  assert_contains "$prompt" "## Failure evidence from attempt 1"
  assert_contains "$prompt" "- Its evidence record said: status failed, suite_passed false (1 failed)"
  assert_contains "$prompt" "- Judged from its files: completed -"
  assert_contains "$prompt" "- Session: success, is_error false, 6 turns"
  assert_contains "$prompt" "- Not met: it works (seeded failure)"
  assert_contains "$prompt" "- Notes: Seeded failure: the parser half is done, the writer is not."
  assert_contains "$prompt" "ticket 1 attempt 1"
  ! grep -q "Failure evidence" "$RUN_DIR/workers/1.1/prompt.md" || fail "the first attempt had failure evidence"
  assert_eq 1 "$(state_get '.tickets["1"].failures | length')"
}

test_a_second_failure_blocks_the_ticket() {
  setup_waves 3 1 2
  printf 'FAIL="1 2"\n' >"$WAVES/ticket-1"
  run_wave 1
  assert_eq "blocked 2" "$(status_of 1) $(state_get '.tickets["1"].attempts')"
  [ ! -e "$RUN_DIR/workers/1.3" ] || fail "a third attempt ran"
  assert_contains "$(state_get '.decisions[] | select(.ticket == "1") | .question')" "failed 2 attempts"
  assert_eq merged "$(status_of 2)"
  # One ticket failing is not a failed wave.
  assert_eq null "$(state_get '.halted')"
}

test_an_attempt_that_did_not_complete_is_a_failed_attempt_at_merge() {
  setup_waves 3 1
  export FAKE_CLAUDE_MODE=no-marker
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "returned"'
  assert_status 6 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1
  assert_eq queued "$(status_of 1)"
  assert_contains "$(state_get '.tickets["1"].failures[0].reason')" "did not complete (not-completed"
}

# ------------------------------------------------------------------- halt

test_a_one_ticket_wave_or_a_design_question_does_not_halt_the_run() {
  setup_waves 3 1 2
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.orchestrators = [{id: "orchestrator-w1", wave: 1, attempt: 1}]
    | .tickets["1"] |= (.status = "blocked" | .wave = 1)'
  "$SCRIPTS/wave.sh" report "$RUN_DIR" >/dev/null
  assert_eq null "$(state_get '.halted')" "one ticket is not a whole wave"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["2"] |= (.status = "blocked" | .wave = 1 | .result = {status: "blocked"})'
  "$SCRIPTS/wave.sh" report "$RUN_DIR" >/dev/null
  assert_eq null "$(state_get '.halted')" "a design question is not a failure"
}

test_a_wave_in_which_every_ticket_fails_halts_the_run_and_says_so() {
  setup_waves 3 1 2 3
  printf 'FAIL="1 2"\n' >"$WAVES/ticket-1"
  printf 'FAIL="1 2"\n' >"$WAVES/ticket-2"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 2'
  run_wave 1
  assert_eq "blocked blocked queued" "$(status_of 1) $(status_of 2) $(status_of 3)"
  assert_eq 1 "$(jq -r '.halted.wave' "$RUN_DIR/results/orchestrator-w1.1.result.json")" "the wave report says so"
  local out
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: halted"
  assert_contains "$out" "halted: every ticket dispatched in wave 1 failed (#1, #2); nothing more launches until the Artisan decides"
  assert_contains "$out" "(halt) | - | Wave 1 failed whole (#1, #2)"
  assert_eq halted "$(state_get '.events[-1].event')"
  # Nothing launches until the Artisan decides to carry on.
  local status=0
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 12 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "the run is halted"
  [ ! -e "$RUN_DIR/workers/orchestrator-w2.1" ] || fail "an orchestrator launched while halted"
  run_wave 2 --resume
  assert_eq merged "$(status_of 3)"
  assert_eq null "$(state_get '.halted')"
  assert_eq decided "$(state_get '.decisions[] | select(.kind == "halt") | .status')"
}
