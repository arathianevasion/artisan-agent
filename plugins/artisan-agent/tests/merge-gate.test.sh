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
  assert_contains "$out" "parked ci: #1's merge gate got no conclusion from CI"
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
