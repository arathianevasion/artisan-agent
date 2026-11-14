# The CI workflow (#166): macOS is the longest job, so it is split across three
# runners with run.sh --shard, and the merge gate still judges the run by its
# overall conclusion alone. Static checks on the workflow file and merge-gate.sh.
# Bash 3.2-safe: grep and awk only.

WORKFLOW="$PLUGIN_ROOT/../../.github/workflows/script-tests.yml"

# The macOS job's block: from its key to the next top-level job or end of file.
macos_job() {
  awk '/^  script-tests-macos:/ {on=1; print; next} on && /^  [^ ]/ {on=0} on {print}' "$WORKFLOW"
}

test_macos_job_is_a_matrix_over_three_shards() {
  local job=
  [ -f "$WORKFLOW" ] || fail "no workflow at $WORKFLOW"
  job=$(macos_job)
  printf '%s\n' "$job" | grep -q 'shard: \[1, 2, 3\]' || fail "macOS job has no shard: [1, 2, 3] matrix"
  printf '%s\n' "$job" | grep -q 'fail-fast: false' || fail "macOS matrix must set fail-fast: false"
}

test_each_macos_shard_runs_its_own_slice_under_apple_bash() {
  local job=
  job=$(macos_job)
  printf '%s\n' "$job" | grep -q '/bin/bash plugins/artisan-agent/tests/run.sh .*--shard \${{ matrix.shard }}/3' \
    || fail "macOS job must run run.sh --shard \${{ matrix.shard }}/3 under /bin/bash"
}

test_each_macos_shard_has_its_own_job_name() {
  macos_job | grep -q 'name: Script tests (macOS, Apple bash 3.2, \${{ matrix.shard }}/3)' \
    || fail "macOS job name must include the shard"
}

test_linux_stays_a_single_unsharded_job() {
  awk '/^  script-tests:/ {on=1; next} on && /^  [^ ]/ {on=0} on' "$WORKFLOW" | grep -q -e '--shard' \
    && fail "the Linux job should not be sharded"
  return 0
}

test_workflow_comment_describes_the_shards() {
  head -n 20 "$WORKFLOW" | grep -qi 'shard' || fail "the comment at the top of the workflow must describe the shards"
}

test_merge_gate_judges_the_run_by_its_overall_conclusion_only() {
  local mg="$PLUGIN_ROOT/scripts/merge-gate.sh" branch=
  # Job names are recorded, never matched on (failed jobs' logs are read
  # only to name the failing tests, after the verdict).
  grep -q 'select(.name' "$mg" && fail "merge-gate.sh must not select on a job name"
  # The verdict is a case on the run's overall conclusion.
  grep -qF 'conclusion=$(jq -r '"'"'.conclusion // ""'"'"' <<<"$view")' "$mg" \
    || fail "the verdict must come from the run's overall .conclusion"
  grep -qF 'case "$conclusion" in' "$mg" || fail "the verdict must be a case on \$conclusion"
  # Its failure | timed_out branch, up to its ;;, records the run and is red.
  branch=$(awk '/^ *failure \| timed_out\)/ {on=1} on {print} on && /;;/ {exit}' "$mg")
  [ -n "$branch" ] || fail "no failure | timed_out branch in the verdict"
  printf '%s\n' "$branch" | grep -qF 'record "$view" ""' || fail "a failed run must be recorded"
  printf '%s\n' "$branch" | grep -qF 'return 7' || fail "a failed run must be red (exit 7)"
  return 0
}

# --- flaky tests and the quarantine (#198) ---

linux_job() {
  awk '/^  script-tests:/ {on=1; print; next} on && /^  [^ ]/ {on=0} on {print}' "$WORKFLOW"
}

test_every_test_job_reruns_failed_tests() {
  linux_job | grep -q 'tests/run.sh .*--rerun-failed' || fail "the Linux job must pass --rerun-failed to run.sh"
  macos_job | grep -q 'tests/run.sh .*--rerun-failed' || fail "the macOS job must pass --rerun-failed to run.sh"
}

test_the_quarantine_is_checked_once_outside_the_matrix() {
  local n=
  n=$(grep -c 'tests/run.sh --check-quarantine' "$WORKFLOW" || true)
  assert_eq 1 "$n" "run.sh --check-quarantine in the workflow"
  assert_not_contains "$(macos_job)" "--check-quarantine" "the quarantine check must not run in the macOS matrix"
  assert_not_contains "$(linux_job)" "--check-quarantine" "the quarantine check runs on its own, with gh, not in the container job"
  grep -q 'issues: read' "$WORKFLOW" || fail "the quarantine check needs issues: read to see an issue's state"
}

test_the_linux_job_writes_its_step_summary_from_outside_the_tester_user() {
  local job=
  job=$(linux_job)
  # The tester user can't write the runner's summary file: run.sh writes a
  # file it can, and a later step (even after a red run) appends it.
  printf '%s\n' "$job" | grep -q 'GITHUB_STEP_SUMMARY=/tmp/' || fail "the Linux job must point run.sh's GITHUB_STEP_SUMMARY at a file the tester can write"
  printf '%s\n' "$job" | grep -q 'if: always()' || fail "the summary step must run after a red run too"
  printf '%s\n' "$job" | grep -q '>> *"\$GITHUB_STEP_SUMMARY"' || fail "the summary step must append to the real step summary"
}

# --- a Linux-only worker run (#197) ---

# The workflow_dispatch block: from its key to the end of the on: block.
dispatch_block() {
  awk '/^  workflow_dispatch:/ {on=1; print; next} on && /^[^ #]/ {on=0} on {print}' "$WORKFLOW"
}

test_dispatch_has_a_boolean_macos_input_defaulting_to_true() {
  local input=""
  input=$(dispatch_block | awk '/^      macos:/ {on=1; next} on && /^      [^ ]/ {on=0} on {print}')
  [ -n "$input" ] || fail "workflow_dispatch has no macos input"
  printf '%s\n' "$input" | grep -q 'type: boolean' || fail "the macos input must be a boolean"
  printf '%s\n' "$input" | grep -q 'default: true' || fail "the macos input must default to true"
}

test_macos_job_runs_unless_a_dispatch_turns_it_off() {
  local cond=""
  cond=$(macos_job | grep '^    if:' || true)
  [ -n "$cond" ] || fail "the macOS job has no if: condition"
  # A pull request has no inputs, and GitHub compares null loosely equal to
  # false, so the condition must only read the input on a dispatch.
  assert_contains "$cond" "github.event_name != 'workflow_dispatch' || inputs.macos" "the macOS job's condition"
  assert_not_contains "$cond" "!= false" "a missing input compares equal to false"
  assert_not_contains "$cond" "github.event.inputs" "github.event.inputs holds strings, so 'false' would be truthy"
}

test_only_the_macos_job_reads_the_macos_input() {
  local n=""
  n=$(grep -v '^ *#' "$WORKFLOW" | grep -c 'inputs.macos' || true)
  assert_eq 1 "$n" "inputs.macos in the workflow"
}

test_workflow_comment_says_what_the_macos_input_is_for() {
  head -n 30 "$WORKFLOW" | grep -q '^#.*macos input' || fail "the comment at the top must describe the macos input"
}

test_this_repo_runs_worker_branch_runs_on_linux_only() {
  local got=""
  got=$(cd "$PLUGIN_ROOT/../.." && "$PLUGIN_ROOT/scripts/config.sh" show --file .artisan-agent/config.yml | jq -c '.ci_gate.worker_inputs')
  assert_eq '{"macos":false}' "$got" "ci_gate.worker_inputs in this repo's config"
}
