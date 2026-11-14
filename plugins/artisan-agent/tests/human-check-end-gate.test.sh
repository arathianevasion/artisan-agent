# A Human check from plan to end gate (#162): state.sh init records the
# check's human_check from the plan graph (human_check_for), in the shape
# reconcile.sh writes, so it is a Human check from the first moment of the
# run; a reconcile then changes nothing for it. A check failed at the end
# gate keeps the gate closed (22), records the verdict, logs the events and
# opens its rework ticket; --not-bug leaves bug-found out.
# Fake `gh` over a folder tracker; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

G="$PLUGIN_ROOT/scripts/gate.sh"
E="$PLUGIN_ROOT/scripts/end-gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# Ticket 1 is the agent ticket (area "ui"); 2 is its Human check, known from
# the plan graph (human_check_for) and its body marker. One gate: the end.
setup_plan() {
  make_project
  printf '#!/bin/sh\necho "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  WT="$TEST_TMPDIR/project-wt/run-r1"
  git_quiet -C "$PROJECT" worktree add -b run/r1 "$WT" main
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  jq -n '{number: 1, title: "Ticket 1", state: "open",
    labels: [{name: "in-run"}, {name: "ready-for-agent"}], body: "## Acceptance criteria\n\n- [ ] t1.txt exists"}' \
    >"$FAKE_GH_DIR/issue-1.json"
  jq -n '{number: 2, title: "Human check: the greeting reads well (#1)", state: "open",
    labels: [{name: "in-run"}, {name: "ready-for-human"}],
    body: "<!-- artisan-agent:human-check-for #1 -->\n\n## Acceptance criteria\n\n- [ ] The greeting reads well\n\n## Blocked by\n\n- #1\n"}' \
    >"$FAKE_GH_DIR/issue-2.json"
  echo '[]' >"$FAKE_GH_DIR/blocked_by-1.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  jq -n '
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: [1, 2],
     waves: [["1"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh",
     estimate_usd: 0.25, budget_usd: 2, orchestrator: {estimate_usd: 0.25},
     gates: [{kind: "end"}],
     checks: [{command: "sh check.sh", covers: "the whole suite", proven_to_fail: true}],
     tickets: {"1": {title: "Ticket 1", expected_output: "t1.txt", expected_files: ["t1.txt"],
                     model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5}, areas: ["ui"],
                     caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}},
               "2": {title: "Human check: the greeting reads well (#1)", human_check_for: 1}}}' \
    >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.integration.worktree = $wt' --arg wt "$WT"
  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  merge_gate_local "$ARTISAN_HOME"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

merged() { # ticket: merged, closed on the tracker, with a verdict
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets[$t] |= (.status = "merged" | .merge_commit = "abcdef1234567" | .tracker_closed = true
      | .suite = {command: "sh check.sh", passed: true, log: "x"}
      | .evidence = {ticket: $t, verdict: "pass", acceptance: [], unsure: [], decisions: []})
    | .integration.merges += [{ticket: $t, commit: "abcdef1234567"}]' --arg t "$1"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-$1.json"
}

events() { jq -r --arg e "$1" '[.events[] | select(.event == $e)]' "$RUN_DIR/state.json"; }

# ------------------------------------------------------------------ plan time

test_init_records_the_human_check_from_the_plan_graph() {
  setup_plan
  # Before any reconcile: the shape reconcile.sh writes, `for` a string.
  assert_eq '{"state":"open","for":"1"}' "$(state_get '.tickets["2"].human_check' | jq -c .)"
  assert_eq null "$(state_get '.tickets["1"].human_check')"
  assert_eq queued "$(state_get '.tickets["2"].status')"
}

test_a_reconcile_changes_nothing_for_a_check_known_at_plan_time() {
  setup_plan
  local before=
  before=$(state_get '.tickets["2"]' | jq -c .)
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_eq "$before" "$(state_get '.tickets["2"]' | jq -c .)"
}

test_the_check_is_never_on_the_frontier_before_a_reconcile() {
  setup_plan
  # Nothing has read the tracker yet: the first frontier already leaves it out.
  assert_eq "1" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ *$//')"
}

# ------------------------------------------------------------------ end gate

end_gate_open() {
  setup_plan
  merged 1
  assert_eq due "$("$E" status "$RUN_DIR")"
  "$E" open "$RUN_DIR" >/dev/null
  assert_eq open "$("$E" status "$RUN_DIR")"
}

test_a_check_failed_at_the_end_gate_keeps_it_closed_and_sends_the_work_back() {
  end_gate_open
  assert_status 22 "$E" approve "$RUN_DIR" --boundary slice
  local r=
  r=$("$G" check "$RUN_DIR" 2 fail --why "The greeting wraps onto two lines")
  [ -n "$r" ] || fail "no rework ticket"
  # The verdict, on the check.
  assert_eq '[{"verdict":"fail","gate":"end","by":"Artisan","why":"The greeting wraps onto two lines","rework":"'"$r"'"}]' \
    "$(state_get '.tickets["2"].human_check.answers' | jq -c 'map({verdict, gate, by, why, rework})')"
  assert_eq open "$(state_get '.tickets["2"].human_check.state')"
  assert_eq queued "$(state_get '.tickets["2"].status')"
  # The events.
  assert_eq '[{"ticket":"2","agent_ticket":"1","gate":"end","by":"Artisan","why":"The greeting wraps onto two lines","rework":"'"$r"'"}]' \
    "$(events human-check-failed | jq -c 'map({ticket, agent_ticket, gate, by, why, rework})')"
  assert_eq '[{"ticket":"1","where":"gate","gate":"end","areas":["ui"]}]' \
    "$(events bug-found | jq -c 'map({ticket, where, gate, areas})')"
  assert_eq '[{"ticket":"'"$r"'","from":"1","gate":"end","card":null,"human_check":"2"}]' \
    "$(events rework | jq -c 'map({ticket, from, gate, card, human_check})')"
  # The follow-up: a rework ticket in the run, queued, on the tracker.
  assert_eq 1 "$(jq -r --arg r "$r" '.plan.tickets[$r].rework_of' "$RUN_DIR/state.json")"
  assert_eq 2 "$(jq -r --arg r "$r" '.plan.tickets[$r].human_check' "$RUN_DIR/state.json")"
  assert_contains " $(state_get '.plan.scope | join(" ")') " " $r "
  assert_eq queued "$(jq -r --arg r "$r" '.tickets[$r].status' "$RUN_DIR/state.json")"
  assert_eq "Rework #1: Human check #2 failed" "$(jq -r .title "$FAKE_GH_DIR/issue-$r.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$r.json")" "Human check #2 failed at end."
  assert_contains "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$r.json")" "ready-for-agent"
  # The check waits on the rework's build, stays open, and still holds the gate.
  assert_contains "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")" "$r"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-2.json")"
  assert_status 22 "$E" approve "$RUN_DIR" --boundary slice
  assert_eq open "$("$E" status "$RUN_DIR")"
}

test_a_check_failed_at_the_end_gate_as_not_a_bug_logs_no_bug() {
  end_gate_open
  local r=
  r=$("$G" check "$RUN_DIR" 2 fail --why "Wording changed its mind" --not-bug)
  [ -n "$r" ] || fail "no rework ticket"
  assert_eq fail "$(state_get '.tickets["2"].human_check.answers[0].verdict')"
  assert_eq 1 "$(events human-check-failed | jq length)"
  assert_eq 0 "$(events bug-found | jq length)"
  assert_eq 1 "$(events rework | jq length)"
  assert_eq queued "$(jq -r --arg r "$r" '.tickets[$r].status' "$RUN_DIR/state.json")"
  assert_status 22 "$E" approve "$RUN_DIR" --boundary slice
}
