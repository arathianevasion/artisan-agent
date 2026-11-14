# The merge gate on CI (#139, merge-gate.sh, wave.sh merge): on a machine
# whose merge_gate resolves to ci, a merge runs no suite here; it pushes the
# merge commit to a unique ci/* branch, dispatches the project's gate
# workflow and gates on that run's conclusion for that exact commit. Built on
# wave.test.sh's run (fake `claude`, fake `gh` over a folder tracker, whose
# workflow runs read the test's bare origin).

. "$TESTS_DIR/wave.test.sh"
# Only this file's tests run here; wave.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_mg_/ {print $3}'); do unset -f "$_f"; done
unset _f

MG="$PLUGIN_ROOT/scripts/merge-gate.sh"

# A run whose project has a bare origin (where CI reads the ci/* branch), a
# gate workflow recorded in the plan's config, and a suite that leaves a mark
# when it runs here.
setup_ci() { # [timeout-minutes] [scope-json]
  setup_wave "${2:-}"
  ORIGIN="$TEST_TMPDIR/origin.git"
  git_quiet clone --bare "$PROJECT" "$ORIGIN"
  git_quiet -C "$PROJECT" remote add origin "$ORIGIN"
  export FAKE_GH_REMOTE="$ORIGIN" ARTISAN_CI_POLL_SECONDS=0 ARTISAN_MERGE_GATE=ci
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.ci_gate = {workflow: "ci.yml", timeout_minutes: $m}
    | .plan.suite_command = ("touch " + $mark + " && sh check.sh")' \
    --argjson m "${1:-30}" --arg mark "$TEST_TMPDIR/suite-ran-here"
}

# Ticket 1 returned and verified (wave.sh merge's preconditions).
verified_ticket() {
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  "$SCRIPTS/verify.sh" judge "$RUN_DIR" 1 >/dev/null
}

MERGE_STATUS=
merge_1() {
  MERGE_STATUS=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >"$TEST_TMPDIR/merge.out" 2>"$TEST_TMPDIR/merge.err" || MERGE_STATUS=$?
}

ci_branches() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' 'refs/heads/ci/'; }

test_mg_a_green_ci_run_for_the_merge_commit_records_the_merge_and_no_suite_runs_here() {
  setup_ci
  verified_ticket
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  [ ! -e "$TEST_TMPDIR/suite-ran-here" ] || fail "the suite ran on this machine"
  local sha=
  sha=$(git -C "$PROJECT" rev-parse run/r1)
  assert_eq "$sha" "$(state_get '.tickets["1"].merge_commit')"
  # The suite record names the mode and cites the run.
  assert_eq "ci true 9001 success" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed) \(.run_id) \(.conclusion)"')"
  assert_eq "https://github.com/local/sample/actions/runs/9001" "$(state_get '.tickets["1"].suite.url')"
  assert_eq '[{"name":"bash 5.2","conclusion":"success"},{"name":"bash 3.2","conclusion":"success"}]' \
    "$(state_get '.tickets["1"].suite.jobs | tojson')"
  assert_eq "$sha" "$(jq -r .headSha "$FAKE_GH_DIR/run-9001.json")" "CI ran the merge commit itself"
  # A unique ci/* branch was dispatched on, then deleted.
  local branch=
  branch=$(state_get '.tickets["1"].suite.branch')
  case "$branch" in ci/r1-1-1-*) ;; *) fail "branch $branch is not ci/<run>-<ticket>-<attempt>-<ts>" ;; esac
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "workflow run ci.yml -R local/sample --ref $branch"
  assert_eq "" "$(ci_branches)" "the ci branch is gone after a pass"
  assert_eq null "$(state_get '.ci_gate')" "no gate left in progress"
}

test_mg_a_red_ci_run_undoes_the_merge_and_blocks_the_ticket_naming_the_run() {
  setup_ci
  verified_ticket
  echo failure >"$FAKE_GH_DIR/ci-outcome"
  merge_1
  assert_eq 7 "$MERGE_STATUS"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "https://github.com/local/sample/actions/runs/9001"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "the merge was undone"
  assert_eq "ci false failure" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed) \(.conclusion)"')"
  assert_eq "" "$(ci_branches)" "the ci branch is gone after a fail"
  [ ! -e "$TEST_TMPDIR/suite-ran-here" ] || fail "the suite ran on this machine"
}

test_mg_a_timed_out_ci_run_is_red_undoes_the_merge_and_blocks_the_ticket() {
  setup_ci
  verified_ticket
  echo timed_out >"$FAKE_GH_DIR/ci-outcome"
  merge_1
  assert_eq 7 "$MERGE_STATUS"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "timed_out"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "https://github.com/local/sample/actions/runs/9001"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "the merge was undone"
  assert_eq "ci false timed_out" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed) \(.conclusion)"')"
  assert_eq null "$(state_get '.ci_park')" "red blocks, it does not park"
  assert_eq "" "$(ci_branches)" "the ci branch is gone after a fail"
}

test_mg_a_cancelled_ci_run_parks_the_run_unblocked_and_clearing_the_park_retries_the_gate() {
  setup_ci 30 '["1","2"]'
  verified_ticket
  echo cancelled >"$FAKE_GH_DIR/ci-outcome"
  merge_1
  assert_eq 19 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq returned "$(state_get '.tickets["1"].status')" "CI never judged it: not blocked"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "the merge was undone"
  assert_eq "" "$(ci_branches)" "the ci branch is gone after a park"
  assert_eq "cancelled https://github.com/local/sample/actions/runs/9001" \
    "$(state_get '.ci_park | "\(.conclusion) \(.url)"')"
  local parked_sha= out=
  parked_sha=$(state_get '.ci_park.sha')
  assert_eq "ci 1" "$(state_get '[.events[] | select(.event == "parked")] | last | "\(.reason) \(.ticket)"')"
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "cancelled"
  assert_contains "$out" "https://github.com/local/sample/actions/runs/9001"
  assert_status 19 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
  rm -f "$FAKE_GH_DIR/ci-outcome"
  "$SCRIPTS/wave.sh" unpark-ci "$RUN_DIR" >/dev/null
  merge_1
  assert_eq 0 "$MERGE_STATUS" "retry: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "$parked_sha" "$(state_get '.tickets["1"].merge_commit')" "the same merge commit, gated again"
  assert_eq "" "$(ci_branches)"
}

test_mg_a_green_run_for_another_commit_does_not_count_and_the_run_parks() {
  setup_ci 0
  verified_ticket
  # CI reports green, but for a commit that is not the merge.
  echo 0123456789abcdef0123456789abcdef01234567 >"$FAKE_GH_DIR/ci-sha"
  merge_1
  assert_eq 19 "$MERGE_STATUS"
  assert_eq returned "$(state_get '.tickets["1"].status')" "the ticket is not at fault"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "nothing merged"
  assert_contains "$(state_get '.ci_park.why')" "no conclusion from ci.yml"
  assert_eq "" "$(ci_branches)"
}

test_mg_no_conclusion_in_time_parks_the_run_and_clearing_the_park_retries_the_gate() {
  setup_ci 0 '["1","2"]'
  verified_ticket
  echo never >"$FAKE_GH_DIR/ci-outcome"
  merge_1
  assert_eq 19 "$MERGE_STATUS"
  assert_eq returned "$(state_get '.tickets["1"].status')" "not blocked"
  assert_eq "" "$(ci_branches)" "the ci branch is gone after a park"
  local parked_sha= out=
  parked_sha=$(state_get '.ci_park.sha')
  assert_eq "ci 1" "$(state_get '[.events[] | select(.event == "parked")] | last | "\(.reason) \(.ticket)"')"
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked ci: #1's merge gate got no verdict from CI"
  assert_contains "$out" "wave.sh unpark-ci"
  # Parked: nothing merges or dispatches.
  merge_1
  assert_eq 19 "$MERGE_STATUS"
  assert_status 19 "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 2
  # CI is back; the Artisan clears the park, and the next merge gates the same commit again.
  rm -f "$FAKE_GH_DIR/ci-outcome"
  "$SCRIPTS/wave.sh" unpark-ci "$RUN_DIR" >/dev/null
  assert_eq null "$(state_get '.ci_park')"
  assert_eq decided "$(state_get '[.decisions[] | select(.kind == "ci")] | last | .status')"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "retry: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "$parked_sha" "$(state_get '.tickets["1"].merge_commit')" "the same merge commit, gated again"
  assert_eq "$parked_sha" "$(git -C "$PROJECT" rev-parse run/r1)"
  assert_status 6 "$SCRIPTS/wave.sh" unpark-ci "$RUN_DIR"
}

test_mg_a_gate_cut_short_by_a_crash_is_undone_retried_and_its_branch_swept() {
  setup_ci
  verified_ticket
  # A merge whose gate never came back: the merge commit at the integration
  # tip, its branch left on the remote, the gate still recorded in progress.
  local wt= pre= sha=
  wt=$(state_get '.integration.worktree')
  pre=$(git -C "$wt" rev-parse HEAD)
  git_quiet -C "$wt" merge --no-ff -m "Merge #1" agent/1
  sha=$(git -C "$wt" rev-parse HEAD)
  git_quiet -C "$wt" push origin "$sha:refs/heads/ci/r1-1-1-100"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.ci_gate = {ticket: "1", attempt: 1, pre: $p, sha: $s, branch: "ci/r1-1-1-100", at: 100}' \
    --arg p "$pre" --arg s "$sha"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq "$sha" "$(state_get '.tickets["1"].merge_commit')" "the cut-short merge commit, gated"
  assert_eq "$sha" "$(git -C "$PROJECT" rev-parse run/r1)"
  assert_eq "" "$(ci_branches)" "the leftover branch is swept"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "ci-gate-abandoned")] | length')"
}

test_mg_with_a_local_gate_the_suite_runs_here_as_before() {
  setup_ci
  export ARTISAN_MERGE_GATE=local
  verified_ticket
  merge_1
  assert_eq 0 "$MERGE_STATUS"
  [ -e "$TEST_TMPDIR/suite-ran-here" ] || fail "the suite did not run here"
  assert_eq "local true" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed)"')"
  [ ! -e "$FAKE_GH_DIR/calls" ] || assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "workflow run"
}

test_mg_a_ci_machine_without_a_gate_workflow_merges_nothing_and_says_so() {
  setup_ci
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.ci_gate.workflow = null'
  verified_ticket
  merge_1
  assert_eq 1 "$MERGE_STATUS"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "records no gate workflow"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)"
  [ ! -e "$TEST_TMPDIR/suite-ran-here" ] || fail "fell back to the local suite"
}

test_mg_the_verifier_on_a_ci_machine_leaves_the_suite_to_the_merge_gate() {
  setup_ci
  printf '# Coding standards\n\n## Checks\n\n- `sh check.sh`: proven to fail on 2026-11-13, breaking: BROKEN\n- `true`: proven to fail on 2026-11-13, breaking: x\n' >"$PROJECT/CODING_STANDARDS.md"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m standards
  git_quiet -C "$PROJECT" branch -f run/r1 main
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = "sh check.sh"'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  local prompt= cmd= out=
  prompt=$(cat "$RUN_DIR/prompts/verify-1.1.md")
  assert_contains "$prompt" "run --worker --suite"
  assert_contains "$prompt" '- `sh check.sh`: left to the merge gate'
  assert_eq '["true"]' "$(state_get '.tickets["1"].verifications[0].checks.commands | tojson')"
  assert_eq '["sh check.sh"]' "$(state_get '.tickets["1"].verifications[0].checks.left_to_merge_gate | tojson')"
  # The command the verifier is given runs the other check and says the suite was left.
  cmd=$(printf '%s\n' "$prompt" | sed -n 's/^    \$ //p' | head -n 1)
  out=$(cd "$PROJECT" && eval "$cmd")
  assert_eq '["true"]' "$(printf '%s' "$out" | jq -c '[.results[].command]')"
  assert_contains "$(printf '%s' "$out" | jq -r '.not_run[]')" "sh check.sh: left to the merge gate"
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
}

test_mg_the_verifier_on_a_local_machine_runs_every_recorded_check() {
  setup_ci
  export ARTISAN_MERGE_GATE=local
  printf '# Coding standards\n\n## Checks\n\n- `sh check.sh`: proven to fail on 2026-11-13, breaking: BROKEN\n' >"$PROJECT/CODING_STANDARDS.md"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m standards
  git_quiet -C "$PROJECT" branch -f run/r1 main
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = "sh check.sh"'
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  assert_not_contains "$(cat "$RUN_DIR/prompts/verify-1.1.md")" "--worker"
  assert_eq '["sh check.sh"]' "$(state_get '.tickets["1"].verifications[0].checks.commands | tojson')"
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
}

# ---- the gate runs detached (#142): no merge call waits on it for long

# A local gate whose suite counts its runs and sleeps for as many seconds as
# the file "slow" says, when there is one.
setup_slow_local() {
  setup_ci
  export ARTISAN_MERGE_GATE=local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = ("echo run >>" + $d + "/suite-runs && sh check.sh && { [ ! -e " + $d + "/slow ] || sleep $(cat " + $d + "/slow); }")' \
    --arg d "$TEST_TMPDIR"
}

suite_runs() { wc -l <"$TEST_TMPDIR/suite-runs" 2>/dev/null | tr -d ' ' || echo 0; }
gate_pid() { cat "$RUN_DIR/$(state_get '.merge_gate.pid_file')"; }
gate_result() { printf '%s/%s\n' "$RUN_DIR" "$(state_get '.merge_gate.result')"; }

merge_1_wait() { # seconds
  MERGE_STATUS=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 --wait "$1" >"$TEST_TMPDIR/merge.out" 2>"$TEST_TMPDIR/merge.err" || MERGE_STATUS=$?
}

test_mg_a_suite_slower_than_the_callers_limit_still_merges_and_runs_once() {
  setup_slow_local
  echo 4 >"$TEST_TMPDIR/slow"
  verified_ticket
  local t0=$SECONDS result=
  merge_1_wait 1
  assert_eq 20 "$MERGE_STATUS" "gate running: $(cat "$TEST_TMPDIR/merge.err")"
  [ $((SECONDS - t0)) -lt 4 ] || fail "merge waited on the whole suite ($((SECONDS - t0))s)"
  assert_contains "$(cat "$TEST_TMPDIR/merge.err")" "merge gate is running"
  assert_eq "local 1 1" "$(state_get '.merge_gate | "\(.mode) \(.ticket) \(.attempt)"')"
  result=$(gate_result)
  case "$result" in "$RUN_DIR"/results/merge-1.1.g1.json) ;; *) fail "the outcome goes under results/: $result" ;; esac
  # Called again while it runs: still running, nothing started twice.
  merge_1_wait 0
  assert_eq 20 "$MERGE_STATUS"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  wait_for "$result" 30
  merge_1_wait 0
  assert_eq 0 "$MERGE_STATUS" "finish: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(cat "$TEST_TMPDIR/merge.out")"
  assert_eq 1 "$(suite_runs)" "the suite ran once"
  assert_eq "local true" "$(state_get '.tickets["1"].suite | "\(.mode) \(.passed)"')"
  assert_eq null "$(state_get '.merge_gate')"
  assert_eq "" "$(pgrep -f "$RUN_DIR/results/merge-" || true)" "no gate process outlives the gate"
}

test_mg_killing_the_caller_mid_gate_then_calling_again_records_the_merge_once() {
  setup_slow_local
  echo 3 >"$TEST_TMPDIR/slow"
  verified_ticket
  local caller= i=0
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null 2>&1 &
  caller=$!
  until [ "$(state_get '.merge_gate != null')" = true ] && [ -s "$RUN_DIR/$(state_get '.merge_gate.pid_file')" ]; do
    i=$((i + 1)); [ "$i" -le 100 ] || fail "the gate never started"; sleep 0.1
  done
  kill -KILL "$caller"
  wait "$caller" 2>/dev/null || true
  wait_for "$(gate_result)" 30
  merge_1_wait 0
  assert_eq 0 "$MERGE_STATUS" "finish: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq 1 "$(suite_runs)" "the finished suite is not run again"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "merge")] | length')" "recorded once"
}

test_mg_a_local_gate_that_died_without_an_outcome_is_undone_and_retried() {
  setup_slow_local
  echo 60 >"$TEST_TMPDIR/slow"
  verified_ticket
  merge_1_wait 0
  assert_eq 20 "$MERGE_STATUS"
  local sha=
  sha=$(state_get '.merge_gate.sha')
  kill -KILL "-$(gate_pid)"
  mv "$TEST_TMPDIR/slow" "$TEST_TMPDIR/slow.gone"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "retry: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "$sha" "$(state_get '.tickets["1"].merge_commit')" "the same merge commit, gated again"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "merge-gate-abandoned")] | length')"
  assert_eq 2 "$(suite_runs)"
}

test_mg_a_merge_recorded_just_before_a_crash_is_finished_not_left_in_the_way() {
  setup_slow_local
  echo 1 >"$TEST_TMPDIR/slow"
  verified_ticket
  merge_1_wait 0
  wait_for "$(gate_result)" 30
  # Cut off after recording the merge, before clearing the gate's record.
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 1 "$(state_get '.merge_gate.sha')"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "finish: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq null "$(state_get '.merge_gate')"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "merge")] | length')"
}

test_mg_a_red_gate_undone_before_a_crash_still_blocks_the_ticket() {
  setup_slow_local
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.suite_command = "sleep 1; exit 1"'
  verified_ticket
  local wt=
  wt=$(state_get '.integration.worktree')
  merge_1_wait 0
  wait_for "$(gate_result)" 30
  # Cut off after undoing the merge, before clearing the gate's record.
  git_quiet -C "$wt" reset --hard "$(state_get '.merge_gate.pre')"
  merge_1
  assert_eq 7 "$MERGE_STATUS" "red: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)"
  assert_eq null "$(state_get '.merge_gate')"
}

test_mg_cutting_off_a_ci_gate_waits_on_the_same_run_with_no_new_dispatch() {
  setup_ci
  verified_ticket
  echo never >"$FAKE_GH_DIR/ci-outcome"
  merge_1_wait 1
  assert_eq 20 "$MERGE_STATUS" "gate running: $(cat "$TEST_TMPDIR/merge.err")"
  local branch=
  branch=$(state_get '.merge_gate.branch')
  # The caller cut off: calling again finds the gate still going.
  merge_1_wait 0
  assert_eq 20 "$MERGE_STATUS"
  # The gate's own process dies too, while its CI run carries on.
  kill -KILL "-$(gate_pid)"
  sleep 0.2
  jq '.status = "completed" | .conclusion = "success" | .jobs |= map(.status = "completed" | .conclusion = "success")' \
    "$FAKE_GH_DIR/run-9001.json" >"$FAKE_GH_DIR/run.tmp" && mv "$FAKE_GH_DIR/run.tmp" "$FAKE_GH_DIR/run-9001.json"
  merge_1
  assert_eq 0 "$MERGE_STATUS" "resume: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq "9001 $branch" "$(state_get '.tickets["1"].suite | "\(.run_id) \(.branch)"')" "the same run on the same branch"
  assert_eq 1 "$(grep -c 'workflow run' "$FAKE_GH_DIR/calls")" "no new dispatch"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "ci-gate-abandoned")] | length')"
  assert_eq "9001" "$(state_get '[.events[] | select(.event == "merge-gate-resumed")] | last | .run_id')"
  assert_eq "" "$(ci_branches)"
}

# ---- merge-gate.sh on its own

test_mg_the_machine_chooses_the_mode_auto_by_os_and_host_json_overrides() {
  unset ARTISAN_MERGE_GATE
  export ARTISAN_HOME="$TEST_TMPDIR/home"
  mkdir -p "$ARTISAN_HOME"
  assert_eq ci "$(ARTISAN_HOST_OS=linux "$MG" mode)" "auto on Linux"
  assert_eq local "$(ARTISAN_HOST_OS=macos "$MG" mode)" "auto on macOS"
  echo '{"merge_gate": "local"}' >"$ARTISAN_HOME/host.json"
  assert_eq local "$(ARTISAN_HOST_OS=linux "$MG" mode)" "a Linux laptop set to local"
  assert_eq "$ARTISAN_HOME/host.json" "$(ARTISAN_HOST_OS=linux "$MG" show | jq -r .source)"
  echo '{"merge_gate": "ci"}' >"$ARTISAN_HOME/host.json"
  assert_eq ci "$(ARTISAN_HOST_OS=macos "$MG" mode)"
  echo '{"merge_gate": "cloud"}' >"$ARTISAN_HOME/host.json"
  assert_status 1 "$MG" mode
  assert_eq local "$(ARTISAN_MERGE_GATE=local "$MG" mode)" "the environment wins, for tests and trials"
}

test_mg_workflow_check_wants_a_workflow_dispatch_trigger() {
  local d="$TEST_TMPDIR/wf" err=
  mkdir -p "$d"
  printf 'on:\n  push:\n  workflow_dispatch:\njobs: {}\n' >"$d/ok.yml"
  printf 'on: [push, workflow_dispatch]\n' >"$d/flow.yml"
  printf 'on:\n  push:\n# workflow_dispatch: later\n' >"$d/no.yml"
  assert_status 0 "$MG" workflow-check "$d/ok.yml"
  assert_status 0 "$MG" workflow-check "$d/flow.yml"
  assert_status 1 "$MG" workflow-check "$d/no.yml"
  err=$("$MG" workflow-check "$d/no.yml" 2>&1 || true)
  assert_contains "$err" "$d/no.yml has no workflow_dispatch trigger"
  assert_status 1 "$MG" workflow-check "$d/missing.yml"
}

test_mg_minutes_per_merge_come_from_the_workflows_recent_runs() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  jq -n '{databaseId: 1, workflowName: "ci.yml", status: "completed", conclusion: "success",
          createdAt: "2026-11-13T10:00:00Z", updatedAt: "2026-11-13T10:09:12Z"}' >"$FAKE_GH_DIR/run-1.json"
  jq -n '{databaseId: 2, workflowName: "ci.yml", status: "completed", conclusion: "failure",
          createdAt: "2026-11-13T11:00:00Z", updatedAt: "2026-11-13T11:15:30Z"}' >"$FAKE_GH_DIR/run-2.json"
  jq -n '{databaseId: 3, workflowName: "ci.yml", status: "in_progress", conclusion: null,
          createdAt: "2026-11-13T12:00:00Z", updatedAt: "2026-11-13T12:01:00Z"}' >"$FAKE_GH_DIR/run-3.json"
  jq -n '{databaseId: 4, workflowName: "other.yml", status: "completed", conclusion: "success",
          createdAt: "2026-11-13T12:00:00Z", updatedAt: "2026-11-13T14:00:00Z"}' >"$FAKE_GH_DIR/run-4.json"
  # (552 s + 930 s) / 2 = 741 s = 12.35 minutes, rounded up to a tenth.
  assert_eq '{"runs":2,"minutes":12.4}' "$("$MG" minutes --repo local/sample --workflow ci.yml)"
  assert_eq '{"runs":0,"minutes":null}' "$("$MG" minutes --repo local/sample --workflow none.yml)"
}

# ---- the release skip (#168): merge-gate.sh ci --skip-path

SKIP_PATHS=(--skip-path '*.md' --skip-path '!plugins/*' --skip-path CHANGELOG.md
  --skip-path plugins/p/.claude-plugin/plugin.json --skip-path .claude-plugin/marketplace.json)

# A repo whose first commit A passed CI (a run on file), with a bare origin
# for the gate's push. Sets SK_DIR, SK_A.
setup_skip() {
  SK_DIR="$TEST_TMPDIR/skip" ORIGIN="$TEST_TMPDIR/skip-origin.git"
  mkdir -p "$SK_DIR/plugins/p/.claude-plugin" "$SK_DIR/.claude-plugin"
  git_quiet init "$SK_DIR"
  printf '{"version":"1"}\n' >"$SK_DIR/plugins/p/.claude-plugin/plugin.json"
  printf '{"version":"1"}\n' >"$SK_DIR/.claude-plugin/marketplace.json"
  echo "# changes" >"$SK_DIR/CHANGELOG.md"
  echo 'echo hi' >"$SK_DIR/plugins/p/run.sh"
  echo "# plugin doc" >"$SK_DIR/plugins/p/README.md"
  git_quiet -C "$SK_DIR" add -A
  git_quiet -C "$SK_DIR" commit -m A
  SK_A=$(git -C "$SK_DIR" rev-parse HEAD)
  git_quiet clone --bare "$SK_DIR" "$ORIGIN"
  git_quiet -C "$SK_DIR" remote add origin "$ORIGIN"
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker" FAKE_GH_REMOTE="$ORIGIN" ARTISAN_CI_POLL_SECONDS=0
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  skip_run 9000 "$SK_A" success
}

skip_run() { # id sha conclusion
  jq -n --argjson id "$1" --arg sha "$2" --arg c "$3" '{databaseId: $id, workflowName: "ci.yml", headBranch: "main",
    headSha: $sha, event: "push", status: "completed", conclusion: $c,
    url: "https://github.com/local/sample/actions/runs/\($id)", jobs: []}' >"$FAKE_GH_DIR/run-$1.json"
}

# skip_commit FILE...: a commit changing each file; sets SK_SHA.
skip_commit() {
  local f=""
  for f in "$@"; do mkdir -p "$(dirname "$SK_DIR/$f")"; echo "$RANDOM" >>"$SK_DIR/$f"; done
  git_quiet -C "$SK_DIR" add -A
  git_quiet -C "$SK_DIR" commit -m change
  SK_SHA=$(git -C "$SK_DIR" rev-parse HEAD)
}

skip_gate() { # [extra args]: SK_OUT, SK_RC
  SK_RC=0
  SK_OUT=$("$MG" ci --repo local/sample --workflow ci.yml --branch ci/r1-1-1-1 --sha "$SK_SHA" --dir "$SK_DIR" \
    --timeout-minutes 1 "$@" 2>/dev/null) || SK_RC=$?
}

dispatched() { grep -q '^workflow run' "$FAKE_GH_DIR/calls" 2>/dev/null; }

test_mg_skip_a_release_commit_over_a_green_commit_is_green_without_a_dispatch() {
  setup_skip
  skip_commit CHANGELOG.md plugins/p/.claude-plugin/plugin.json .claude-plugin/marketplace.json docs/notes.md
  skip_gate "${SKIP_PATHS[@]}"
  assert_eq 0 "$SK_RC" "$SK_OUT"
  assert_eq "true success 9000 $SK_A" "$(jq -r '"\(.skipped) \(.conclusion) \(.relied_on.run_id) \(.relied_on.sha)"' <<<"$SK_OUT")"
  assert_eq "https://github.com/local/sample/actions/runs/9000" "$(jq -r .relied_on.url <<<"$SK_OUT")"
  assert_contains "$(jq -r .why <<<"$SK_OUT")" "run 9000"
  assert_eq "$SK_SHA" "$(jq -r .sha <<<"$SK_OUT")"
  if dispatched; then fail "CI was dispatched for a release commit"; fi
  assert_eq "" "$(git -C "$ORIGIN" for-each-ref 'refs/heads/ci/')" "nothing was pushed"
}

test_mg_skip_rides_over_a_green_commit_several_release_commits_back() {
  setup_skip
  skip_commit CHANGELOG.md
  skip_commit plugins/p/.claude-plugin/plugin.json
  skip_gate "${SKIP_PATHS[@]}"
  assert_eq "0 true 9000" "$SK_RC $(jq -r '"\(.skipped) \(.relied_on.run_id)"' <<<"$SK_OUT")"
}

test_mg_skip_any_change_to_a_script_a_test_or_a_skill_dispatches_as_before() {
  local f=""
  for f in plugins/p/run.sh tests/a.test.sh plugins/p/skills/x/SKILL.md plugins/p/README.md; do
    setup_skip
    skip_commit CHANGELOG.md "$f"
    skip_gate "${SKIP_PATHS[@]}"
    assert_eq 0 "$SK_RC" "$f: $SK_OUT"
    dispatched || fail "$f: CI was not dispatched"
    assert_eq null "$(jq '.skipped // null' <<<"$SK_OUT")" "$f: ran CI, not skipped"
    assert_eq "9001" "$(jq -r .run_id <<<"$SK_OUT")" "$f: the dispatched run"
    rm -rf "$TEST_TMPDIR/tracker" "$TEST_TMPDIR/skip" "$TEST_TMPDIR/skip-origin.git"
  done
}

test_mg_skip_with_no_green_run_to_compare_against_dispatches() {
  setup_skip
  rm "$FAKE_GH_DIR/run-9000.json"
  skip_commit CHANGELOG.md
  skip_gate "${SKIP_PATHS[@]}"
  assert_eq 0 "$SK_RC"
  dispatched || fail "CI was not dispatched with no green run"
  # A red run, a green run of another workflow, and a green run for a commit
  # the candidate does not descend from are no baseline either.
  rm -rf "$FAKE_GH_DIR"; mkdir -p "$FAKE_GH_DIR"
  skip_run 9000 "$SK_A" failure
  jq '.workflowName = "other.yml" | .databaseId = 9002' "$FAKE_GH_DIR/run-9000.json" | sed 's/failure/success/' >"$FAKE_GH_DIR/run-9002.json"
  local main_branch=""
  main_branch=$(git -C "$SK_DIR" symbolic-ref --short HEAD)
  git_quiet -C "$SK_DIR" checkout -q -b side "$SK_A"
  echo x >"$SK_DIR/side.txt"
  git_quiet -C "$SK_DIR" add side.txt
  git_quiet -C "$SK_DIR" commit -m side
  skip_run 9003 "$(git -C "$SK_DIR" rev-parse HEAD)" success
  git_quiet -C "$SK_DIR" checkout -q "$main_branch"
  skip_gate "${SKIP_PATHS[@]}"
  assert_eq 0 "$SK_RC"
  dispatched || fail "CI was not dispatched without a usable green baseline"
  assert_eq null "$(jq '.skipped // null' <<<"$SK_OUT")"
}

test_mg_skip_with_no_allowlist_every_merge_dispatches() {
  setup_skip
  skip_commit CHANGELOG.md
  skip_gate
  assert_eq 0 "$SK_RC"
  dispatched || fail "CI was not dispatched with no allowlist"
}

test_mg_skip_the_last_matching_pattern_decides_and_bang_denies() {
  setup_skip
  skip_commit plugins/p/README.md
  skip_gate "${SKIP_PATHS[@]}"
  dispatched || fail "plugins/ docs are not on the allowlist"
  rm -rf "$FAKE_GH_DIR"; mkdir -p "$FAKE_GH_DIR"; skip_run 9000 "$SK_A" success
  skip_gate --skip-path '*.md'
  assert_eq "0 true" "$SK_RC $(jq -r .skipped <<<"$SK_OUT")" "without the ! a plugins doc is allowed"
}

test_mg_skip_a_merge_that_only_changed_release_files_is_merged_with_the_green_run_named() {
  setup_ci
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.merge_gate_skip_paths = ["hello.txt"]'
  # CI passed on the tree the ticket merges into.
  skip_run 9000 "$MAIN_HEAD" success
  git_quiet -C "$ORIGIN" fetch -q "$PROJECT" "$MAIN_HEAD"
  verified_ticket
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  if dispatched; then fail "CI was dispatched"; fi
  [ ! -e "$TEST_TMPDIR/suite-ran-here" ] || fail "the suite ran on this machine"
  assert_eq "true 9000 $MAIN_HEAD" "$(state_get '.tickets["1"].suite | "\(.skipped) \(.relied_on.run_id) \(.relied_on.sha)"')"
  assert_eq "9000 https://github.com/local/sample/actions/runs/9000" \
    "$(state_get '[.events[] | select(.event == "merge-gate-skipped")] | last | "\(.run_id) \(.url)"')"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "merge-gate-skipped" and .ticket == "1")] | length')"
}

test_mg_skip_a_ticket_that_changes_other_files_runs_ci_even_with_an_allowlist() {
  setup_ci
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.merge_gate_skip_paths = ["CHANGELOG.md"]'
  skip_run 9000 "$MAIN_HEAD" success
  verified_ticket
  merge_1
  assert_eq 0 "$MERGE_STATUS" "merge: $(cat "$TEST_TMPDIR/merge.err")"
  dispatched || fail "CI was not dispatched for a ticket"
  assert_eq null "$(state_get '.tickets["1"].suite.skipped // null')"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "merge-gate-skipped")] | length')"
}

# ---- the plan step on a CI machine

ci_draft() {
  jq -n '{run_id: "r1", repo: "local/sample", integration_branch: "run/r1",
    scope: ["10", "11"], waves: [["10", "11"]], gates: [{kind: "end"}],
    tickets: {
      "10": {title: "A", model: "claude-sonnet-5-5", blocked_by: [], expected: {input_tokens: 1000, output_tokens: 100, minutes: 10}},
      "11": {title: "B", model: "claude-sonnet-5-5", blocked_by: [], expected: {input_tokens: 1000, output_tokens: 100, minutes: 10}}}}' >"$1"
}

test_mg_on_a_ci_machine_the_plan_step_shows_expected_ci_minutes_per_merge() {
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker" ARTISAN_MERGE_GATE=ci
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  jq -n '{databaseId: 1, workflowName: "ci.yml", status: "completed", conclusion: "success",
          createdAt: "2026-11-13T10:00:00Z", updatedAt: "2026-11-13T10:09:12Z"}' >"$FAKE_GH_DIR/run-1.json"
  printf 'ci_gate:\n  workflow: ci.yml\n' >>"$PROJECT/.artisan-agent/config.yml"
  ci_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  assert_eq '{"mode":"ci","workflow":"ci.yml","timeout_minutes":30,"minutes_per_merge":9.2,"from_runs":1}' \
    "$(jq -c .merge_gate "$TEST_TMPDIR/plan.json")"
  local out=
  out=$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Merge gate: on CI"
  assert_contains "$out" "about 9.2 minutes per merge (mean of its last 1 completed runs), about 19 minutes for this run's 2 merges"
  # No gate workflow recorded: the approval says nothing can merge.
  printf 'max_agents: 5\n' >"$PROJECT/.artisan-agent/config.yml"
  (cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan2.json"
  assert_contains "$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan2.json")" "**No gate workflow recorded.**"
  # On a local machine the plan carries no merge gate and the approval no section.
  (cd "$PROJECT" && ARTISAN_MERGE_GATE=local "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan3.json"
  assert_eq null "$(jq -c .merge_gate "$TEST_TMPDIR/plan3.json")"
  assert_not_contains "$("$SCRIPTS/plan.sh" render "$TEST_TMPDIR/plan3.json")" "Merge gate"
}
