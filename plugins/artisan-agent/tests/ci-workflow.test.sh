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
  # Job names are recorded, never matched on.
  grep -q 'select(.name' "$PLUGIN_ROOT/scripts/merge-gate.sh" && fail "merge-gate.sh must not select on a job name"
  grep -q 'failure | timed_out) record "\$view" ""; return 7' "$PLUGIN_ROOT/scripts/merge-gate.sh" \
    || fail "a failed run must be red (exit 7)"
  return 0
}
