# worker-ci.sh (#194): on a machine whose merge gate runs on CI, a worker
# gets CI green on its own branch for the checks it can't run there
# (runs_locally never, or mac off macOS). Built on a throwaway repo with a
# bare origin and the fake gh, whose workflow runs read that origin.

WCI="$PLUGIN_ROOT/scripts/worker-ci.sh"

# A project with a unit check (always) and an e2e check (never), a gate
# workflow recorded in its config, a bare origin and the worker's branch.
setup_worker() { # [config-extra]
  P="$TEST_TMPDIR/project"
  ORIGIN="$TEST_TMPDIR/origin.git"
  mkdir -p "$P/.artisan-agent"
  git -C "$P" init -q -b main
  cat >"$P/CODING_STANDARDS.md" <<'MD'
## Checks

- `./unit.sh`: proven to fail on 2026-11-01, breaking: flipped an assertion
- `npx playwright test`: proven to fail on 2026-11-01, breaking: a wrong label (runs_locally: never)
MD
  printf 'ci_gate:\n  workflow: ci.yml\n%s' "${1:-}" >"$P/.artisan-agent/config.yml"
  echo one >"$P/file"
  git -C "$P" add -A && git -C "$P" commit -q -m base
  git clone -q --bare "$P" "$ORIGIN"
  git -C "$P" remote add origin "$ORIGIN"
  git -C "$P" checkout -q -b agent/7
  echo two >"$P/file"
  git -C "$P" commit -q -am "the ticket's work"
  export FAKE_GH_DIR="$TEST_TMPDIR/gh" FAKE_GH_REMOTE="$ORIGIN" ARTISAN_CI_POLL_SECONDS=0
  export ARTISAN_MERGE_GATE=ci ARTISAN_HOST_OS=linux
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
}

RC=
worker_run() { # extra args...
  RC=0
  OUT=$(cd "$P" && "$WCI" run --repo local/sample "$@" 2>"$TEST_TMPDIR/err") || RC=$?
}

test_wci_a_worker_on_a_ci_machine_with_a_never_check_gets_ci_green_on_its_branch() {
  setup_worker
  local sha=
  sha=$(git -C "$P" rev-parse HEAD)
  worker_run
  assert_eq 0 "$RC" "$(cat "$TEST_TMPDIR/err")"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "workflow run ci.yml -R local/sample --ref agent/7"
  assert_eq "$sha" "$(git -C "$ORIGIN" rev-parse refs/heads/agent/7)" "the branch was pushed"
  assert_eq "9001 success $sha agent/7 ci.yml" "$(jq -r '"\(.run_id) \(.conclusion) \(.sha) \(.branch) \(.workflow)"' <<<"$OUT")"
  assert_eq "$(git -C "$P" rev-parse "HEAD^{tree}")" "$(jq -r .tree <<<"$OUT")"
  assert_eq "https://github.com/local/sample/actions/runs/9001" "$(jq -r .url <<<"$OUT")"
  assert_eq '{} true ["npx playwright test"]' "$(jq -c '.inputs, .full, .checks' <<<"$OUT" | tr '\n' ' ' | sed 's/ $//')"
  # What it cost: the run's time is on the record.
  assert_eq true "$(jq '(.minutes | type) == "number" and (.started_at | type) == "string" and (.finished_at | type) == "string"' <<<"$OUT")"
  # No PR is opened.
  if grep -q '^pr create' "$FAKE_GH_DIR/calls"; then fail "a PR was opened"; fi
}

test_wci_a_red_run_says_so_with_its_failing_tests_and_a_rerun_after_the_fix_is_green() {
  setup_worker
  echo failure >"$FAKE_GH_DIR/ci-outcome"
  cp "$TESTS_DIR/fixtures/ci-logs/failed.log" "$FAKE_GH_DIR/ci-log-failed"
  worker_run
  assert_eq 7 "$RC"
  assert_eq "9001 failure" "$(jq -r '"\(.run_id) \(.conclusion)"' <<<"$OUT")"
  assert_eq "tests/save.spec.ts:48" "$(jq -r '.failing_tests.tests[0].where' <<<"$OUT")"
  # The worker fixes it and runs again: the new commit's run is the one that counts.
  rm "$FAKE_GH_DIR/ci-outcome"
  echo three >"$P/file"
  git -C "$P" commit -q -am "the fix"
  worker_run
  assert_eq 0 "$RC" "$(cat "$TEST_TMPDIR/err")"
  assert_eq "9002 success $(git -C "$P" rev-parse HEAD)" "$(jq -r '"\(.run_id) \(.conclusion) \(.sha)"' <<<"$OUT")"
}

test_wci_a_rerun_on_the_same_commit_waits_on_its_own_run_not_the_earlier_one() {
  setup_worker
  echo failure >"$FAKE_GH_DIR/ci-outcome"
  worker_run
  assert_eq 7 "$RC"
  rm "$FAKE_GH_DIR/ci-outcome"
  worker_run
  assert_eq "0 9002 success" "$RC $(jq -r '"\(.run_id) \(.conclusion)"' <<<"$OUT")"
}

test_wci_a_cancelled_run_is_no_verdict() {
  setup_worker
  echo cancelled >"$FAKE_GH_DIR/ci-outcome"
  worker_run
  assert_eq 19 "$RC"
  assert_contains "$(jq -r .why <<<"$OUT")" "cancelled"
}

test_wci_no_conclusion_in_time_is_no_verdict() {
  setup_worker
  echo never >"$FAKE_GH_DIR/ci-outcome"
  worker_run --timeout-minutes 0
  assert_eq 19 "$RC"
  assert_eq "9001 null" "$(jq -r '"\(.run_id) \(.conclusion)"' <<<"$OUT")"
}

test_wci_worker_inputs_are_passed_and_the_run_is_marked_partial() {
  setup_worker '  worker_inputs:
    macos: false
'
  worker_run
  assert_eq 0 "$RC" "$(cat "$TEST_TMPDIR/err")"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "workflow run ci.yml -R local/sample --ref agent/7 -f macos=false"
  assert_eq '{"macos":"false"}' "$(jq -c .inputs "$FAKE_GH_DIR/run-9001.json")" "CI got the input"
  assert_eq '{"macos":false} false' "$(jq -c '.inputs, .full' <<<"$OUT" | tr '\n' ' ' | sed 's/ $//')"
}

test_wci_with_a_local_merge_gate_or_every_check_always_nothing_is_dispatched() {
  setup_worker
  ARTISAN_MERGE_GATE=local worker_run
  assert_eq 16 "$RC"
  assert_eq '[]' "$(jq -c .checks <<<"$OUT")"
  [ ! -e "$FAKE_GH_DIR/calls" ] || ! grep -q 'workflow run' "$FAKE_GH_DIR/calls" || fail "CI was dispatched on a local machine"
  sed -i.bak 's/ (runs_locally: never)//' "$P/CODING_STANDARDS.md"
  worker_run
  assert_eq 16 "$RC"
  [ ! -e "$FAKE_GH_DIR/calls" ] || ! grep -q 'workflow run' "$FAKE_GH_DIR/calls" || fail "CI was dispatched with every check always"
}

test_wci_check_wants_a_green_run_for_exactly_the_commit() {
  setup_worker
  worker_run
  local sha= id= rc=0
  sha=$(git -C "$P" rev-parse HEAD)
  id=$(jq -r .run_id <<<"$OUT")
  "$WCI" check --repo local/sample --run-id "$id" --sha "$sha" >/dev/null || fail "a green run for the commit did not pass"
  "$WCI" check --repo local/sample --run-id "$id" --sha "$(git -C "$P" rev-parse HEAD~1)" >"$TEST_TMPDIR/out" || rc=$?
  assert_eq 7 "$rc" "another commit"
  assert_contains "$(jq -r .why "$TEST_TMPDIR/out")" "not $(git -C "$P" rev-parse HEAD~1)"
  jq '.conclusion = "failure"' "$FAKE_GH_DIR/run-$id.json" >"$TEST_TMPDIR/r" && mv "$TEST_TMPDIR/r" "$FAKE_GH_DIR/run-$id.json"
  rc=0; "$WCI" check --repo local/sample --run-id "$id" --sha "$sha" >/dev/null || rc=$?
  assert_eq 7 "$rc" "a red run"
  rc=0; "$WCI" check --repo local/sample --run-id 4242 --sha "$sha" >/dev/null || rc=$?
  assert_eq 7 "$rc" "no such run"
}
