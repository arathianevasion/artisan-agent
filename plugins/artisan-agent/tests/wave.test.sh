# wave.sh: the two-tier run. The chat starts the integration worktree and
# launches a detached orchestrator; the orchestrator dispatches, waits,
# merges --no-ff, runs the suite and closes the ticket; the chat learns the
# outcome from files alone. Fake `claude` (scripted per role) and fake `gh`
# (a folder tracker) stand in for the real ones, so nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"
. "$PLUGIN_ROOT/scripts/lib/state-lib.sh"   # state_pid_alive

# A project whose suite (check.sh) fails when a file named BROKEN exists, a
# fake tracker with tickets 1 and 2 (2 blocked by 1), and a run r1 over SCOPE.
setup_wave() { # scope-json
  make_project
  printf '#!/bin/sh\n[ ! -e BROKEN ] && echo "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  MAIN_HEAD=$(git -C "$PROJECT" rev-parse HEAD)

  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  jq -n '{number: 1, title: "Add hello", state: "open", labels: [],
          body: "## Acceptance criteria\n- [ ] hello.txt exists\n- [ ] It says hi\n\n## Notes\n- [ ] not a criterion"}' >"$FAKE_GH_DIR/issue-1.json"
  jq -n '{number: 2, title: "Add goodbye", state: "open", labels: [], body: "- [ ] goodbye"}' >"$FAKE_GH_DIR/issue-2.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"

  jq -n --argjson scope "${1:-[\"1\"]}" '{
    run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: $scope,
    waves: [["1"], ["2"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh",
    orchestrator: {estimate_usd: 0.25},
    tickets: {
      "1": {title: "Add hello", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
            caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}},
      "2": {title: "Add goodbye", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
            caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"

  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script FAKE_CLAUDE_LOG="$TEST_TMPDIR/fake-claude.log"
  write_worker_script
  write_verifier_script
  write_orchestrator_script
  # The chat's long-lived session: a process that outlives every call.
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

cleanup() {
  kill_test_processes
  kill_workers
}

# The worker: commits hello.txt (or what WORKER_FILE says) and writes its
# evidence record, after WORKER_SLEEP seconds.
write_worker_script() {
  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
sleep "${WORKER_SLEEP:-0}"
echo "${WORKER_TEXT:-hi}" >"${WORKER_FILE:-hello.txt}"
git add -A && git commit -q --allow-empty -m "worker"
jq -n --arg c "$(git rev-parse HEAD)" '{ticket: "1", status: "complete", commit: $c,
  acceptance: [{criterion: "hello.txt exists", met: true, evidence: {tests: ["check.sh"]}},
               {criterion: "It says hi", met: true, evidence: {diff: "hello.txt +1 -0"}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: ["Whether hi needs a newline"],
  decisions: [{job: 3, question: "Which file?", choice: "hello.txt", alternative: "HELLO", by: "worker 1",
               kind: "engineering taste", criterion: "4", confidence: "provisional"}],
  review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
# WORKER_PARAPHRASE=1 rewords every criterion.
if [ -n "${WORKER_PARAPHRASE:-}" ]; then
  jq '.acceptance = [{criterion: "The file hello.txt is there", met: true, evidence: {tests: ["check.sh"]}},
                     {criterion: "Greeting says hi", met: true, evidence: {diff: "hello.txt +1 -0"}}]' "$ARTISAN_RESULT_FILE" >"$ARTISAN_RESULT_FILE.tmp"
  mv "$ARTISAN_RESULT_FILE.tmp" "$ARTISAN_RESULT_FILE"
fi
EOF
}

# The verifier: a verdict in the evidence format on the criteria verify.sh
# gave it, after VERIFIER_SLEEP seconds, each met unless VERIFIER_UNMET names
# it (naming VERIFIER_GUARDRAIL on it, if set), or "human" (needs a human
# check) if VERIFIER_HUMAN names it ("|" between names), or "gate" (checked by
# the merge gate) if VERIFIER_GATE names it. VERIFIER_MODE=garbage writes something that is not a verdict.
write_verifier_script() {
  export FAKE_CLAUDE_SCRIPT_VERIFIER="$TEST_TMPDIR/verifier.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
set -e
sleep "${VERIFIER_SLEEP:-0}"
echo "$PWD" >>"$ARTISAN_RUN_DIR/../verifier-dirs"
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
if [ "${VERIFIER_MODE:-}" = garbage ]; then echo '{"verdict": "pass"}' >"$ARTISAN_RESULT_FILE"; exit 0; fi
jq --arg unmet "${VERIFIER_UNMET:-}" --arg g "${VERIFIER_GUARDRAIL:-}" --arg human "${VERIFIER_HUMAN:-}" --arg gate "${VERIFIER_GATE:-}" '{verdict: "pass", acceptance: [.[] | {criterion: .,
    met: (. != $unmet), evidence: (if . == $unmet then {why: "not in the diff"} else {checks: [{command: "sh check.sh", result: "suite ok"}]} end)}
    + (if . == $unmet and $g != "" then {guardrail: $g} else {} end)
    + (if . as $c | $human | split("|") | index($c) then {met: "human", evidence: {why: "only play shows it"}} else {} end)
    + (if . as $c | $gate | split("|") | index($c) then {met: "gate", evidence: {why: "only the merge gate shows it"}} else {} end)],
  unsure: [], notes: "checked by behaviour"}' "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF
}

# The orchestrator's loop, as references/orchestrator.md tells the real one.
# ORCH_STOP=returned stops once the workers are back (nothing verified);
# ORCH_STOP=verified verifies but merges nothing; ORCH_STOP=fail ends at once,
# without the completion line.
write_orchestrator_script() {
  export FAKE_CLAUDE_SCRIPT_ORCHESTRATOR="$TEST_TMPDIR/orchestrator.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_ORCHESTRATOR" <<EOF
set -euo pipefail
[ "\${ORCH_STOP:-}" != fail ] || exit 1
S="$SCRIPTS"
R="\$ARTISAN_RUN_DIR"
inflight() { jq '[.tickets[] | select(.status == "in_flight")] | length' "\$R/state.json"; }
# A fresh verifier per returned ticket; only its one-line verdict is read.
verify() {
  local rc=
  "\$S/verify.sh" start "\$R" "\$1" >/dev/null || return 1
  while :; do
    rc=0
    "\$S/verify.sh" judge "\$R" "\$1" >>"\$R/../verdicts" 2>/dev/null || rc=\$?
    case \$rc in
      0) return 0 ;;
      8) sleep 0.2 ;;
      14) "\$S/verify.sh" start "\$R" "\$1" >/dev/null || return 1 ;;
      *) return 1 ;;
    esac
  done
}
for t in \$("\$S/reconcile.sh" "\$R"); do "\$S/wave.sh" dispatch "\$R" "\$t" >/dev/null; done
while [ "\$(inflight)" -gt 0 ]; do
  "\$S/wait-any.sh" "\$R" --timeout 5 >/dev/null || true
  "\$S/sweep.sh" "\$R"
done
if [ "\${ORCH_STOP:-}" = returned ]; then "\$S/wave.sh" report "\$R" >"\$ARTISAN_RESULT_FILE"; exit 0; fi
for t in \$(jq -r '.tickets | to_entries[] | select(.value.status == "returned") | .key' "\$R/state.json"); do
  n=\$(jq -r --arg t "\$t" '.tickets[\$t].attempts' "\$R/state.json")
  while [ "\$("\$S/classify-worker.sh" "\$R" "\$t" "\$n")" = "running -" ]; do sleep 0.2; done
  if [ "\${ORCH_STOP:-}" = verified ]; then verify "\$t" || true; continue; fi
  if verify "\$t" && "\$S/wave.sh" merge "\$R" "\$t"; then "\$S/wave.sh" close "\$R" "\$t"; fi
done
"\$S/wave.sh" report "\$R" >"\$ARTISAN_RESULT_FILE"
EOF
}

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-30} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

ORCH_EXIT=
start_and_launch() {
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >"$TEST_TMPDIR/start.out"
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >"$TEST_TMPDIR/launch.out"
  ORCH_EXIT="$RUN_DIR/results/orchestrator-w1.1.exit.json"
}

test_launch_stops_with_its_own_exit_when_the_runs_base_is_not_in_main() {
  setup_wave
  local wt=
  wt=$("$SCRIPTS/wave.sh" start "$RUN_DIR")
  echo only-here >"$wt/only-here.txt"
  git_quiet -C "$wt" add -A
  git_quiet -C "$wt" commit -m "only in the run"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.integration.base = $b' --arg b "$(git -C "$wt" rev-parse HEAD)" >/dev/null
  mkdir -p "$PROJECT/.artisan-agent"
  echo '{"id":"p","key":"k","value":"v","strict":1}' >"$PROJECT/.artisan-agent/guardrails.jsonl"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "main changes a guardrail"
  assert_status 21 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
  assert_eq "guardrail-base waiting" "$(jq -r '.decisions[0] | "\(.reason) \(.status)"' "$RUN_DIR/state.json")"
  assert_eq 0 "$(jq '.orchestrators // [] | length' "$RUN_DIR/state.json")"
  "$SCRIPTS/state.sh" decide "$RUN_DIR" 1 halt >/dev/null
  assert_status 12 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
}

test_a_one_ticket_run_ends_merged_green_and_closed() {
  setup_wave
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  local wt= ib= tip=
  wt=$(cat "$TEST_TMPDIR/start.out")
  assert_eq "$TEST_TMPDIR/project-wt/run-r1" "$wt" "the run's own integration worktree"
  # The orchestrator completed and wrote its wave report.
  assert_eq "completed -" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" orchestrator-w1 1)"
  assert_eq merged "$(jq -r '.tickets[0].status' "$RUN_DIR/results/orchestrator-w1.1.result.json")"
  # Launching read the guardrail sources: main's commit and the plugin version are recorded.
  assert_eq "$MAIN_HEAD" "$(state_get '.waves[0].guardrails.product')"
  assert_eq "$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json")" "$(state_get '.waves[0].plugin_version')"
  assert_contains "$(cat "$RUN_DIR/prompts/1.1.md")" "guardrails.sh resolve --run-dir"
  # Merged --no-ff: the merge commit's second parent is the worker's tip.
  tip=$(git -C "$PROJECT" rev-parse run/r1)
  assert_eq "$(git -C "$PROJECT" rev-parse agent/1)" "$(git -C "$PROJECT" rev-parse "$tip^2")"
  assert_eq "$tip" "$(state_get '.tickets["1"].merge_commit')"
  # The suite is green on the integration branch.
  (cd "$wt" && sh check.sh >/dev/null) || fail "suite red on the integration branch"
  assert_eq true "$(state_get '.tickets["1"].suite.passed')"
  # Closed on the tracker, with the evidence posted and the met criterion ticked.
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "| hello.txt exists | yes | sh check.sh: suite ok |"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [x] hello.txt exists"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [x] It says hi"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [ ] not a criterion"
  # The worker's worktree is gone; the main checkout never moved or changed.
  [ ! -d "$TEST_TMPDIR/project-wt/r1-1.1" ] || fail "worker worktree left behind"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse HEAD)" "main checkout's HEAD"
  assert_eq main "$(git -C "$PROJECT" symbolic-ref --short HEAD)"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "main checkout is clean"
}

test_a_worker_that_paraphrases_every_criterion_still_closes_the_ticket_ticked() {
  setup_wave
  export WORKER_PARAPHRASE=1
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  assert_eq "hello.txt exists|true It says hi|true" \
    "$(state_get '[.tickets["1"].evidence.acceptance[] | "\(.criterion)|\(.claimed)"] | join(" ")')" "claims follow the ticket's wording by position"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [x] hello.txt exists"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [x] It says hi"
}

test_the_state_file_logs_each_event_in_order() {
  setup_wave
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_eq "integration orchestrator dispatch result verify verified merge-gate merge closed" \
    "$(state_get '[.events[].event] | join(" ")')"
  assert_eq "1 2 3 4 5 6 7 8 9" "$(state_get '[.events[].seq | tostring] | join(" ")')"
}

test_the_chat_learns_of_completion_from_the_exit_record_and_sweep_alone() {
  setup_wave
  export WORKER_SLEEP=3
  start_and_launch
  # While the wave runs, the orchestrator's runner holds the state lock.
  local runner=
  runner=$(awk '{print $3}' "$TEST_TMPDIR/launch.out")
  assert_eq "$runner" "$(readlink "$RUN_DIR/state.lock")" "the orchestrator holds the lock"
  local out=
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "orchestrator: running -"
  assert_contains "$out" "next: wait"
  wait_for "$ORCH_EXIT" 60
  # No message, no notification: only the files.
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "orchestrator: completed - (wave 1, attempt 1"
  assert_contains "$out" "next: done"
  assert_contains "$out" "run the end gate: end-gate.sh open $RUN_DIR"
  assert_contains "$out" "| Ticket | Wave | Model | Status |"
  assert_contains "$out" "| #1 (Add hello) | 1 | claude-sonnet-5-5 | merged as "
  assert_eq "$CHAT" "$(readlink "$RUN_DIR/state.lock")" "the chat holds the lock between waves"
}

test_killing_the_launching_process_stops_neither_orchestrator_nor_worker() {
  setup_wave
  export WORKER_SLEEP=3
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  # The chat: a shell in its own process group that launches and lingers.
  set -m
  bash -c '"$1" launch "$2" >"$3"; sleep 60' _ "$SCRIPTS/wave.sh" "$RUN_DIR" "$TEST_TMPDIR/launch.out" &
  local chat=$!
  set +m
  wait_for "$RUN_DIR/workers/1.1/runner.pid" 30
  kill -HUP "-$chat" 2>/dev/null || true
  kill -KILL "-$chat" 2>/dev/null || true
  wait "$chat" 2>/dev/null || true
  local orch=
  orch=$(cat "$RUN_DIR/workers/orchestrator-w1.1/runner.pid")
  state_pid_alive "$orch" || fail "the orchestrator died with the chat"
  wait_for "$RUN_DIR/results/orchestrator-w1.1.exit.json" 60
  assert_eq "completed -" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" orchestrator-w1 1)"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  # The orchestrator exited after writing state: its lock is stale, not held.
  ! state_pid_alive "$orch" || fail "the orchestrator did not exit"
}

test_a_ticket_whose_blocker_is_not_merged_is_refused_at_dispatch() {
  setup_wave '["1","2"]'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  export ARTISAN_WRITER_PID=$CHAT
  # 1 reported complete, but nothing is merged.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "returned"'
  local status=0
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2 >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 5 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "blocker #1 is not merged into run/r1"
  [ ! -e "$RUN_DIR/workers/2.1" ] || fail "a worker was launched"
  assert_eq queued "$(state_get '.tickets["2"].status')"
  # A merge commit recorded but not on the integration branch is not merged work.
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 1 "$MAIN_HEAD"
  git_quiet -C "$PROJECT" branch -f side main
  git_quiet -C "$PROJECT" checkout side
  git_quiet -C "$PROJECT" commit --allow-empty -m "elsewhere"
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 1 "$(git -C "$PROJECT" rev-parse side)"
  git_quiet -C "$PROJECT" checkout main
  assert_status 5 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
}

test_a_blocker_outside_the_run_must_be_closed() {
  setup_wave '["2"]'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  assert_status 5 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-1.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-1.json"
  export FAKE_CLAUDE_MODE=complete
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["2"].status')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(state_get '.tickets["2"].base')" "branched from the integration tip"
}

test_a_red_suite_after_merging_blocks_the_ticket_and_undoes_the_merge() {
  setup_wave
  export WORKER_FILE=BROKEN
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "suite failed"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "integration branch back where it was"
  assert_eq exception "$(state_get '.decisions[0].kind')"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")" "never closed"
  local out=
  # The red check raises an exception gate, and the run parks on it (#70).
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "check won't go green"
  assert_contains "$out" "| Decision | Ticket | Question |"
}

test_a_second_orchestrator_is_refused_while_one_runs() {
  setup_wave
  export WORKER_SLEEP=3
  start_and_launch
  assert_status 3 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
  wait_for "$ORCH_EXIT" 60
}

test_the_next_orchestrator_takes_the_next_wave() {
  setup_wave '["1","2"]'
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: launch"
  export WORKER_FILE=goodbye.txt
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >"$TEST_TMPDIR/launch2.out"
  assert_eq orchestrator-w2 "$(awk '{print $1}' "$TEST_TMPDIR/launch2.out")"
  wait_for "$RUN_DIR/results/orchestrator-w2.1.exit.json" 60
  assert_eq merged "$(state_get '.tickets["2"].status')"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: done"
  assert_eq "2" "$(state_get '.waves | length')"
}

test_dispatch_never_exceeds_max_agents() {
  setup_wave '["1","2"]'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.max_agents = 1 | .tickets["2"].status = "in_flight"'
  assert_status 9 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1
}

test_tick_criteria_ticks_only_met_criteria() {
  printf '{"acceptance":[{"criterion":"Adds  a thing","met":true},{"criterion":"Other","met":false}]}' >"$TEST_TMPDIR/r.json"
  local out=
  out=$(printf -- '- [ ] adds a thing\n- [ ] Other\n- [ ] Unrelated' | python3 -I "$PLUGIN_ROOT/scripts/lib/criteria.py" tick "$TEST_TMPDIR/r.json")
  assert_eq "- [x] adds a thing
- [ ] Other
- [ ] Unrelated" "$out"
}

test_costs_come_from_each_session_once_it_has_ended() {
  setup_wave
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  # The fake claude reports $0.01 per session: one worker and its verifier
  # (the ticket's cost), one orchestrator.
  assert_eq 0.02 "$(state_get '.tickets["1"].cost_usd')"
  assert_eq 0.01 "$(state_get '.tickets["1"].attempt_costs["verify.1"]')"
  assert_eq 0.01 "$(state_get '.costs.orchestrator_usd')"
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  assert_eq 0.03 "$(state_get '.costs.total_usd')" "counted once"
}

test_a_repo_that_is_not_owner_and_name_is_refused_at_start() {
  setup_wave
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.repo = "/tmp/sample"'
  local status=0
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null 2>"$TEST_TMPDIR/err" || status=$?
  assert_eq 1 "$status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "must be owner/name"
}

test_blocking_a_returned_ticket_queues_a_decision_and_logs_it() {
  setup_wave
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "returned"'
  "$SCRIPTS/wave.sh" block "$RUN_DIR" 1 "misses the expected output"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq exception "$(state_get '.decisions[0].kind')"
  assert_eq blocked "$(state_get '.events[-1].event')"
}

test_fractional_expected_minutes_still_dispatch_with_a_deadline() {
  setup_wave
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["1"].expected.minutes = 2.5 | del(.plan.tickets["1"].caps.deadline_seconds)'
  export FAKE_CLAUDE_MODE=complete
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_eq in_flight "$(state_get '.tickets["1"].status')"
  [ "$(state_get '.tickets["1"].deadline_at - .tickets["1"].dispatched_at')" -ge 299 ] || fail "deadline not twice 2.5 minutes"
}

# --- settable merge-gate poll interval (#169) ---

test_a_bad_merge_poll_interval_is_a_usage_error() {
  local out= status=0
  out=$(ARTISAN_MERGE_POLL_SECONDS=soon "$SCRIPTS/wave.sh" status "$TEST_TMPDIR/none" 2>&1) || status=$?
  assert_eq 2 "$status" "a bad ARTISAN_MERGE_POLL_SECONDS: $out"
  assert_contains "$out" "ARTISAN_MERGE_POLL_SECONDS"
}

# ---------------------------------------------- the orchestrator's exit (#171)

# Launch wave 1, wait for its orchestrator to end, and run status once.
exit_wave() {
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  STATUS_OUT=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
}

# The one orchestrator-exit decision queued, with its cause and tickets, and
# its event; status says decide and names both; launch refuses (23).
assert_exit_decision() { # cause tickets-json detail-fragment
  assert_eq 1 "$(state_get '[.decisions[] | select(.kind == "orchestrator-exit")] | length')"
  assert_eq "$1" "$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .cause')"
  assert_eq "$2" "$(jq -c '.decisions[] | select(.kind == "orchestrator-exit") | .tickets' "$RUN_DIR/state.json")"
  assert_eq 1 "$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .wave')"
  assert_eq "$1" "$(state_get '[.events[] | select(.event == "orchestrator-exit")] | last | .cause')"
  assert_contains "$STATUS_OUT" "next: decide"
  assert_contains "$STATUS_OUT" "orchestrator-exit: $1 in wave 1"
  assert_contains "$STATUS_OUT" "$3"
  assert_contains "$STATUS_OUT" "(orchestrator-exit)"
  assert_status 23 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
  assert_eq 1 "$(state_get '.orchestrators | length')" "nothing launched"
}

test_a_zero_exit_leaving_a_ticket_without_a_verdict_queues_an_orchestrator_exit_decision() {
  setup_wave
  export ORCH_STOP=returned
  exit_wave
  assert_contains "$STATUS_OUT" "orchestrator: completed"
  assert_exit_decision no-verdict '["1"]' "#1 returned, no verdict"
  # Judged once: another status queues nothing more and still says decide.
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: decide"
  assert_eq 1 "$(state_get '.decisions | length')"
}

test_a_verified_but_unmerged_ticket_counts_as_unfinished() {
  setup_wave
  export ORCH_STOP=verified
  exit_wave
  assert_eq pass "$(state_get '.tickets["1"].evidence.verdict')"
  assert_exit_decision unmerged '["1"]' "#1 verified, not merged"
}

test_error_max_turns_queues_the_decision_with_that_cause() {
  setup_wave
  export FAKE_CLAUDE_ORCHESTRATOR_END=turns
  exit_wave
  assert_contains "$STATUS_OUT" "orchestrator: failed turns"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_exit_decision error_max_turns '[]' "exit code 1"
}

test_a_budget_limit_queues_the_decision_with_that_cause() {
  setup_wave
  export FAKE_CLAUDE_ORCHESTRATOR_END=budget ORCH_STOP=verified
  exit_wave
  assert_exit_decision budget '["1"]' "#1 verified, not merged"
}

test_a_nonzero_exit_queues_the_decision_with_that_cause() {
  setup_wave
  export FAKE_CLAUDE_ORCHESTRATOR_END=nonzero
  exit_wave
  assert_exit_decision nonzero-exit '[]' "exit code 3"
}

test_a_deadline_queues_the_decision_with_that_cause() {
  setup_wave
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.orchestrator.deadline_seconds = 3'
  export FAKE_CLAUDE_ORCHESTRATOR_END=hang ORCH_STOP=returned
  exit_wave
  assert_contains "$STATUS_OUT" "orchestrator: failed deadline"
  assert_exit_decision deadline '["1"]' "#1 returned, no verdict"
}

test_a_clean_wave_end_queues_nothing() {
  setup_wave
  exit_wave
  assert_contains "$STATUS_OUT" "next: done"
  assert_eq true "$(state_get '.orchestrators[0].exit.clean')"
  assert_eq 0 "$(state_get '.decisions | length')"
  case "$STATUS_OUT" in *orchestrator-exit*) fail "a clean wave named an orchestrator exit" ;; esac
}

test_resume_answers_the_exit_decision_and_carries_the_wave_on() {
  setup_wave
  export ORCH_STOP=returned
  exit_wave
  unset ORCH_STOP
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" --resume >"$TEST_TMPDIR/launch2.out"
  assert_eq "orchestrator-w1 2" "$(awk '{print $1, $2}' "$TEST_TMPDIR/launch2.out")" "the same wave carries on"
  assert_eq resume "$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .choice')"
  assert_eq true "$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .applied')"
  wait_for "$RUN_DIR/results/$(awk '{print $1 "." $2}' "$TEST_TMPDIR/launch2.out").exit.json" 60
  assert_eq merged "$(state_get '.tickets["1"].status')" "the next orchestrator verified and merged it"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: done"
}

test_retry_sends_the_tickets_back_for_fresh_workers() {
  setup_wave
  export ORCH_STOP=returned
  exit_wave
  local d=""
  d=$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .id')
  "$SCRIPTS/state.sh" decide "$RUN_DIR" "$d" retry >/dev/null
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: launch"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].steering[-1].note')" "exited (no-verdict)"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')" "no attempt used"
}

test_halt_halts_the_run_until_the_artisan_resumes() {
  setup_wave
  export ORCH_STOP=returned
  exit_wave
  local d=""
  d=$(state_get '.decisions[] | select(.kind == "orchestrator-exit") | .id')
  "$SCRIPTS/state.sh" decide "$RUN_DIR" "$d" halt >/dev/null
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: halted"
  assert_contains "$(state_get '.halted.reason')" "exited (no-verdict)"
  assert_status 12 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
}

test_wait_returns_once_the_orchestrator_has_ended() {
  setup_wave
  export WORKER_SLEEP=2 ARTISAN_WAIT_INTERVAL=1
  start_and_launch
  assert_status 3 "$SCRIPTS/wave.sh" wait "$RUN_DIR" --timeout 0
  local out=""
  out=$("$SCRIPTS/wave.sh" wait "$RUN_DIR" --timeout 60)
  assert_contains "$out" "orchestrator: completed - (wave 1, attempt 1)"
  [ -f "$ORCH_EXIT" ] || fail "wait returned before the orchestrator ended"
}

test_an_orchestrator_ending_without_its_completion_line_queues_the_decision() {
  setup_wave
  export ORCH_STOP=fail
  exit_wave
  assert_contains "$STATUS_OUT" "orchestrator: not-completed"
  assert_exit_decision not-completed '[]' "exit code 0"
}

# A ticket an earlier wave left without a verdict is still unfinished when a
# later wave's orchestrator ends cleanly.
test_an_earlier_waves_unfinished_ticket_is_still_unfinished_later() {
  setup_wave
  export ORCH_STOP=returned
  exit_wave
  "$SCRIPTS/state.sh" decide "$RUN_DIR" 1 resume >/dev/null
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.decisions[0].applied = true
    | .orchestrators += [{id: "orchestrator-w2", wave: 2, attempt: 1, launched_at: 1}]'
  mkdir -p "$RUN_DIR/workers/orchestrator-w2.1"
  cp "$RUN_DIR/workers/orchestrator-w1.1/output.json" "$RUN_DIR/workers/orchestrator-w2.1/"
  cp "$RUN_DIR/results/orchestrator-w1.1.exit.json" "$RUN_DIR/results/orchestrator-w2.1.exit.json"
  cp "$RUN_DIR/results/orchestrator-w1.1.result.json" "$RUN_DIR/results/orchestrator-w2.1.result.json"
  echo 1 >"$RUN_DIR/workers/orchestrator-w2.1/runner.pid"
  local out=""
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: decide"
  assert_contains "$out" "orchestrator-exit: no-verdict in wave 2 (#1)"
}
