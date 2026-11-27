# The run end-gate tests start from (end-gate.test.sh, kept-cards.test.sh):
# setup_end [gates-json], product_boundary. Sourced after helpers/run-state.sh.

cleanup() {
  kill_test_processes
  kill_workers
}

# Three tickets merged --no-ff into run/r1 in order 1, 2, 3. Slices: 1 and 2
# are "export", 3 is "billing". Plans: 1 is plan #100; 2 and 3 are plan #101.
setup_end() { # gates-json
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n= wt=
  for n in 1 2 3; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "closed", labels: [{name: "in-run"}, {name: "ready-for-agent"}], body: "x"}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done
  wt="$TEST_TMPDIR/project-wt/run-r1"
  git_quiet -C "$PROJECT" worktree add -b run/r1 "$wt" main
  for n in 1 2 3; do
    git_quiet -C "$PROJECT" branch "agent/$n" main
    git_quiet -C "$PROJECT" worktree add "$TEST_TMPDIR/w$n" "agent/$n"
    echo "$n" >"$TEST_TMPDIR/w$n/t$n.txt"
    git_quiet -C "$TEST_TMPDIR/w$n" add -A
    git_quiet -C "$TEST_TMPDIR/w$n" commit -m "ticket $n"
    git_quiet -C "$wt" merge --no-ff -m "Merge #$n" "agent/$n"
    eval "M$n=\$(git -C \"\$wt\" rev-parse HEAD)"
  done
  local gates='[{"kind": "end"}]'
  [ $# -eq 0 ] || gates=$1
  jq -n --argjson gates "$gates" '
    def t($n; $s; $p): {title: "Ticket \($n)", slice: $s, plan: $p, model: "claude-sonnet-5-5", estimate_usd: 0.25,
                        expected_output: "t\($n).txt", caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3"],
     waves: [["1"], ["2"], ["3"]], max_agents: 2, attempts_per_ticket: 2, estimate_usd: 1, budget_usd: 1.25,
     gates: $gates,
     tickets: {"1": t(1; "export"; 100), "2": t(2; "export"; 101), "3": t(3; "billing"; 101)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .integration += {worktree: $wt, base: $base, merges: [{ticket: "1", commit: $m1}, {ticket: "2", commit: $m2}, {ticket: "3", commit: $m3}]}
    | .tickets["1"] += {status: "merged", merge_commit: $m1, tracker_closed: true}
    | .tickets["2"] += {status: "merged", merge_commit: $m2, tracker_closed: true}
    | .tickets["3"] += {status: "merged", merge_commit: $m3, tracker_closed: true}' \
    --arg wt "$wt" --arg base "$(git -C "$PROJECT" rev-parse main)" --arg m1 "$M1" --arg m2 "$M2" --arg m3 "$M3"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  merge_gate_local "$ARTISAN_HOME"   # lib.sh's host.json is not read once ARTISAN_HOME moves
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

product_boundary() { # slice|plan|ticket: as setup records it, in the PR it lands
  printf '# Coding standards\n\n## Guardrails\n\n- `pr-boundaries`: one PR per %s\n' "$1" >"$PROJECT/CODING_STANDARDS.md"
  git_quiet -C "$PROJECT" add CODING_STANDARDS.md
  git_quiet -C "$PROJECT" commit -m "setup"
}

