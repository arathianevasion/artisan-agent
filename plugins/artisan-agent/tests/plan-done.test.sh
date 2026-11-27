# plan-done.sh: a plan is done only when its tickets' work is on main (#431),
# and resolve-scope.sh (the plan step) refuses a plan whose blocker plan isn't.
# A fake `gh` over a folder tracker stands in for GitHub; a bare repo is origin.

PD="$PLUGIN_ROOT/scripts/plan-done.sh"
RS="$PLUGIN_ROOT/scripts/resolve-scope.sh"

# A repo with an origin; run p1's integration branch run/p1 holds tickets 1
# and 2, merged there but not into main. Plan 10 holds tickets 1 and 2, both
# closed; plan 11 (ticket 3, open) is blocked by plan 10.
plan_fixture() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"; export PATH
  local n=
  for n in 1 2; do
    jq -n --argjson n "$n" '{number: $n, title: "ticket \($n)", state: "closed", labels: [], body: ""}' >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '{number: 3, title: "ticket 3", state: "open", labels: [], body: ""}' >"$FAKE_GH_DIR/issue-3.json"
  jq -n '{number: 10, title: "Plan 1: upload", state: "closed", labels: [{name: "plan"}], body: ""}' >"$FAKE_GH_DIR/issue-10.json"
  jq -n '{number: 11, title: "Plan 2: billing", state: "open", labels: [{name: "plan"}], body: ""}' >"$FAKE_GH_DIR/issue-11.json"
  echo '[1,2]' >"$FAKE_GH_DIR/sub_issues-10.json"
  echo '[3]' >"$FAKE_GH_DIR/sub_issues-11.json"
  echo '[10]' >"$FAKE_GH_DIR/blocked_by-11.json"

  git init -q --bare "$TEST_TMPDIR/origin.git"
  REPO_DIR="$TEST_TMPDIR/repo"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@example.com; git config user.name t
  printf '.artisan-agent/runs/\n' >.gitignore
  git add .gitignore; git commit -qm base
  git remote add origin "$TEST_TMPDIR/origin.git"
  git push -q origin main
  git checkout -qb run/p1
  echo one >one; git add one; git commit -qm "ticket 1"; C1=$(git rev-parse HEAD)
  echo two >two; git add two; git commit -qm "ticket 2"; C2=$(git rev-parse HEAD)
  git checkout -q main
  mkdir -p .artisan-agent/runs/p1
  jq -n --arg c1 "$C1" --arg c2 "$C2" '{run_id: "p1", repo: "local/sample", integration: {branch: "run/p1"},
    tickets: {"1": {status: "merged", merge_commit: $c1}, "2": {status: "merged", merge_commit: $c2}}}' \
    >.artisan-agent/runs/p1/state.json
}

test_a_closed_plan_whose_run_branch_is_not_on_main_is_not_done() {
  plan_fixture
  local out=
  assert_status 3 "$PD" --repo local/sample 10
  out=$("$PD" --repo local/sample 10 || true)
  assert_eq false "$(jq .done <<<"$out")"
  assert_eq '[{"ticket":1,"branch":"run/p1","run":"p1"},{"ticket":2,"branch":"run/p1","run":"p1"}]' \
    "$(jq -c '.not_on_main' <<<"$out")"
}

test_the_same_plan_is_done_once_its_run_branch_is_merged_into_main() {
  plan_fixture
  git merge -q --no-ff -m "merge run/p1" run/p1
  git push -q origin main
  local out=; out=$("$PD" --repo local/sample 10)
  assert_eq true "$(jq .done <<<"$out")"
  assert_eq '[]' "$(jq -c '.not_on_main' <<<"$out")"
}

test_a_local_merge_not_yet_on_origin_does_not_count() {
  plan_fixture
  git merge -q --no-ff -m "merge run/p1" run/p1
  assert_status 3 "$PD" --repo local/sample 10
}

test_an_open_ticket_keeps_the_plan_not_done() {
  plan_fixture
  jq '.state = "open"' "$FAKE_GH_DIR/issue-2.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-2.json"
  git merge -q --no-ff -m "merge run/p1" run/p1
  git push -q origin main
  local out=; out=$("$PD" --repo local/sample 10 || true)
  assert_eq false "$(jq .done <<<"$out")"
  assert_eq '[2]' "$(jq -c '.open' <<<"$out")"
}

test_a_closed_ticket_no_run_merged_does_not_hold_the_plan_back() {
  # Closed by hand (wontfix, a human check): no run recorded a merge for it.
  plan_fixture
  jq 'del(.tickets["2"])' .artisan-agent/runs/p1/state.json >s && mv s .artisan-agent/runs/p1/state.json
  git merge -q --no-ff -m "merge ticket 1" "$C1"
  git push -q origin main
  local out=; out=$("$PD" --repo local/sample 10)
  assert_eq true "$(jq .done <<<"$out")"
  assert_eq '[2]' "$(jq -c '.unrecorded' <<<"$out")"
}

test_a_run_of_another_repo_is_not_read() {
  plan_fixture
  jq '.repo = "other/repo"' .artisan-agent/runs/p1/state.json >s && mv s .artisan-agent/runs/p1/state.json
  local out=; out=$("$PD" --repo local/sample 10)
  assert_eq '[1,2]' "$(jq -c '.unrecorded' <<<"$out")"
}

test_plan_done_refuses_bad_usage() {
  plan_fixture
  assert_status 2 "$PD" --repo local/sample
  assert_status 1 "$PD" --repo sample 10
  assert_status 1 "$PD" --repo local/sample 3
}

test_the_plan_step_refuses_a_plan_whose_blocker_plan_is_not_on_main() {
  plan_fixture
  local err=
  assert_status 4 "$RS" --repo local/sample 11
  err=$("$RS" --repo local/sample 11 2>&1 >/dev/null || true)
  assert_contains "$err" "plan #11 is blocked by plan #10"
  assert_contains "$err" "#1, #2 on run/p1"
  # Merged: the blocker plan is done and the plan resolves.
  git merge -q --no-ff -m "merge run/p1" run/p1
  git push -q origin main
  assert_eq "3" "$("$RS" --repo local/sample 11 | jq -r '.tickets | map(.number) | join(",")')"
}
