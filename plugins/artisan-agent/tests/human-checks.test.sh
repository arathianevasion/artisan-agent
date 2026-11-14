# Human checks in a run (#157, references/human-checks.md): a Human check
# ticket rides along without being dispatched or holding anything up; the
# slice gate after its agent ticket merges lists it with the build to try;
# the Artisan passes, fails or carries it there; "keep all" never passes it;
# the end gate won't approve while one is open unless it is deferred.
# Fake `gh` over a folder tracker; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

G="$PLUGIN_ROOT/scripts/gate.sh"
E="$PLUGIN_ROOT/scripts/end-gate.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# Tickets: 1 is slice "greeting", 4 is slice "farewell"; 2 depends on 1, 3
# depends on 4. 5 is the Human check for 1: ready-for-human, its body marker,
# natively blocked by 1, and (odd, but the run must not care) 6 lists 5 as a
# blocker.
setup_checks() {
  make_project
  printf '#!/bin/sh\necho "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  WT="$TEST_TMPDIR/project-wt/run-r1"
  git_quiet -C "$PROJECT" worktree add -b run/r1 "$WT" main
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3 4 6; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open",
      labels: [{name: "in-run"}, {name: "ready-for-agent"}], body: "## Acceptance criteria\n\n- [ ] t\($n).txt exists"}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '{number: 5, title: "Human check: the greeting reads well in game (#1)", state: "open",
    labels: [{name: "in-run"}, {name: "ready-for-human"}],
    body: "<!-- artisan-agent:human-check-for #1 -->\n\n## What to check\n\nLoad the build and read the greeting.\n\n## Acceptance criteria\n\n- [ ] The greeting reads well in game\n- [ ] It fits on one line\n\n## Blocked by\n\n- #1\n"}' \
    >"$FAKE_GH_DIR/issue-5.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[4]' >"$FAKE_GH_DIR/blocked_by-3.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-5.json"
  echo '[5]' >"$FAKE_GH_DIR/blocked_by-6.json"
  jq -n '
    def t($n): {title: "Ticket \($n)", expected_output: "t\($n).txt", expected_files: ["t\($n).txt"],
                model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
                caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3", "4", "5", "6"],
     waves: [["1", "4"], ["2", "3", "6"]], max_agents: 4, attempts_per_ticket: 2, suite_command: "sh check.sh",
     estimate_usd: 1.25, budget_usd: 2, orchestrator: {estimate_usd: 0.25},
     gates: [{kind: "slice", slice: "greeting", tickets: ["1", "5"]},
             {kind: "slice", slice: "farewell", tickets: ["4"]},
             {kind: "end"}],
     checks: [{command: "sh check.sh", covers: "the whole suite", proven_to_fail: true}],
     tickets: {"1": (t(1) + {slice: "greeting", areas: ["ui"]}), "2": t(2), "3": t(3), "4": (t(4) + {slice: "farewell"}),
               "5": {title: "Human check: the greeting reads well in game (#1)", slice: "greeting"}, "6": t(6)}}' \
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

# ---------------------------------------------------------- runs don't wait

test_the_run_never_dispatches_a_human_check_and_its_dependents_never_wait_on_it() {
  setup_checks
  merged 1
  local frontier=
  # #2 waits on #1's slice gate; the check never holds the gate's dependents.
  assert_eq "4 6 " "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ')"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.review_gates = [
    {id: "slice-1", kind: "slice", issue: 90, tickets: ["1"], status: "approved", cards: [], decisions: [], dependents: []}]'
  frontier=$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ')
  # #2 waits only on #1, not on #1's Human check; #4 never waited; #6 lists
  # the Human check as a blocker, which the run ignores. #5 itself is never
  # on the frontier.
  assert_eq "2 4 6 " "$frontier"
  assert_eq 1 "$(state_get '.tickets["5"].human_check.for')" "the marker is read from the tracker"
  local out= rc=0
  out=$("$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 5 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Human check was dispatched"
  assert_contains "$out" "Human check"
  # It is not a hands-on ticket: no worktree for the Artisan to build in.
  assert_eq "" "$("$SCRIPTS/human.sh" setup "$RUN_DIR")"
  assert_eq null "$(state_get '.tickets["5"].human')"
}

test_status_counts_open_human_checks_and_the_run_is_done_without_them() {
  setup_checks
  local n=
  for n in 1 2 3 4 6; do merged "$n"; done
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  # The slice gates are approved, so only the end gate is left.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.review_gates = [
    {id: "slice-1", kind: "slice", issue: 90, tickets: ["1"], status: "approved", cards: [], decisions: [], dependents: []},
    {id: "slice-2", kind: "slice", issue: 91, tickets: ["4"], status: "approved", cards: [], decisions: [], dependents: []}]'
  local out=
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: done"
  assert_contains "$out" "Human checks: 1 open (end gate)"
  assert_eq due "$("$E" status "$RUN_DIR")"
}

# ------------------------------------------------------------ the slice gate

test_the_slice_gate_after_the_agent_ticket_lists_the_check_with_the_build() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local num= body= tip=
  num=$("$G" open "$RUN_DIR" slice-1)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  tip=$(git -C "$PROJECT" rev-parse run/r1)
  assert_contains "$body" "## Human checks"
  assert_contains "$body" "#5 (Human check: the greeting reads well in game (#1))"
  assert_contains "$body" "Load the build and read the greeting."
  assert_contains "$body" "The greeting reads well in game; It fits on one line"
  assert_contains "$body" "\`${tip:0:7}\` in \`$WT\`"
  assert_contains "$body" "check 5 pass"
  # The check is no ticket of the slice: no cost row, no dependent, no hold.
  assert_not_contains "$body" "| #5 | -"
  assert_eq "[1,$num]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")"
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-5.json")" "the Human check is not a dependent the gate blocks"
  assert_eq "5" "$(state_get '.review_gates[0].human_checks | join(" ")')"
  assert_contains "$("$G" chat "$RUN_DIR")" "Human checks: #5"
}

test_check_pass_closes_the_human_check_with_the_result() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  "$G" check "$RUN_DIR" 5 pass --notes "Looks lovely" --by Andrew >/dev/null
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-5.md")" "passed"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-5.md")" "Looks lovely"
  assert_eq closed "$(state_get '.tickets["5"].status')"
  assert_eq passed "$(state_get '.tickets["5"].human_check.state')"
  assert_eq '[{"ticket":"5","agent_ticket":"1","gate":"slice-1","by":"Andrew"}]' \
    "$(events human-check-passed | jq -c 'map({ticket, agent_ticket, gate, by})')"
  # Answered once: a second answer is refused.
  assert_status 6 "$G" check "$RUN_DIR" 5 pass
}

test_check_fail_logs_a_bug_and_sends_the_agent_ticket_to_rework() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local num= r=
  num=$("$G" open "$RUN_DIR" slice-1)
  r=$("$G" check "$RUN_DIR" 5 fail --why "The greeting wraps onto two lines")
  [ -n "$r" ] || fail "no rework ticket"
  assert_eq "1" "$(jq -r --arg r "$r" '.plan.tickets[$r].rework_of' "$RUN_DIR/state.json")"
  assert_contains "$(state_get '.plan.scope | join(" ")')" "$r"
  assert_eq queued "$(jq -r --arg r "$r" '.tickets[$r].status' "$RUN_DIR/state.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$r.json")" "The greeting wraps onto two lines"
  assert_contains "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$r.json")" "ready-for-agent"
  # The gate's dependents wait for the rework, as with a redirect.
  assert_contains "$(jq -c . "$FAKE_GH_DIR/blocked_by-2.json")" "$r"
  assert_eq '[{"ticket":"5","agent_ticket":"1","gate":"slice-1","by":"Artisan"}]' \
    "$(events human-check-failed | jq -c 'map({ticket, agent_ticket, gate, by})')"
  assert_eq '[{"ticket":"1","where":"gate","gate":"slice-1","areas":["ui"]}]' \
    "$(events bug-found | jq -c 'map({ticket, where, gate, areas})')"
  # The check stays open, to be tried again on the rework's build.
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")"
  assert_eq queued "$(state_get '.tickets["5"].status')"
  # A frontier now has the rework; never the check.
  assert_not_contains " $("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ')" " 5 "
}

test_a_failed_check_the_artisan_says_is_not_a_bug_logs_no_bug() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  "$G" open "$RUN_DIR" slice-1 >/dev/null
  "$G" check "$RUN_DIR" 5 fail --why "Wording changed its mind" --not-bug >/dev/null
  assert_eq 1 "$(events human-check-failed | jq length)"
  assert_eq 0 "$(events bug-found | jq length)"
  assert_status 2 "$G" check "$RUN_DIR" 5 fail
}

test_later_and_keep_all_carry_the_check_to_the_next_gate() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local num= num2= body=
  num=$("$G" open "$RUN_DIR" slice-1)
  "$G" check "$RUN_DIR" 5 later >/dev/null
  "$G" approve "$RUN_DIR" "$num" >/dev/null
  # Keep all never passes a Human check.
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")"
  assert_eq queued "$(state_get '.tickets["5"].status')"
  assert_eq 0 "$(events human-check-passed | jq length)"
  merged 4
  num2=$("$G" open "$RUN_DIR" slice-2)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num2.json")
  assert_contains "$body" "## Human checks"
  assert_contains "$body" "#5 (Human check"
  assert_contains "$body" "carried from slice-1"
  "$G" check "$RUN_DIR" 5 pass >/dev/null
  assert_eq slice-2 "$(events human-check-passed | jq -r '.[0].gate')"
}

test_pass_all_passes_every_check_on_the_gate() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local num=
  num=$("$G" open "$RUN_DIR" slice-1)
  "$G" check "$RUN_DIR" all pass --gate "$num" >/dev/null
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")"
  assert_eq 1 "$(events human-check-passed | jq length)"
}

# -------------------------------------------------------------- the end gate

end_gate_ready() {
  setup_checks
  local n=
  for n in 1 2 3 4 6; do merged "$n"; done
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.review_gates = [
    {id: "slice-1", kind: "slice", issue: 90, tickets: ["1"], status: "approved", cards: [], decisions: [], dependents: []}]
    | .tickets["5"].human_check.gate = "slice-1"'
  "$E" open "$RUN_DIR" >/dev/null
}

test_the_end_gate_refuses_approval_while_a_check_is_open() {
  end_gate_ready
  assert_contains "$("$E" packet "$RUN_DIR")" "## Human checks"
  assert_contains "$("$E" packet "$RUN_DIR")" "#5 (Human check: the greeting reads well in game (#1))"
  assert_status 22 "$E" approve "$RUN_DIR" --boundary slice
  assert_eq open "$("$E" status "$RUN_DIR")"
  # Passed at the end gate, it no longer holds the approval.
  "$G" check "$RUN_DIR" 5 pass >/dev/null
  assert_eq end "$(events human-check-passed | jq -r '.[0].gate')"
  "$E" approve "$RUN_DIR" --boundary slice >/dev/null
  assert_eq approved "$("$E" status "$RUN_DIR")"
}

test_a_check_deferred_with_a_reason_lets_the_end_gate_approve() {
  end_gate_ready
  assert_status 2 "$E" defer-check "$RUN_DIR" 5
  "$E" defer-check "$RUN_DIR" 5 --why "Needs the console devkit" --by Andrew >/dev/null
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")" "a deferred check stays open"
  assert_contains "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-5.json")" "deferred"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-5.md")" "Return condition:"
  assert_eq '[{"ticket":"5","agent_ticket":"1","gate":"end","by":"Andrew","why":"Needs the console devkit"}]' \
    "$(events human-check-deferred | jq -c 'map({ticket, agent_ticket, gate, by, why})')"
  assert_contains "$("$E" packet "$RUN_DIR")" "Needs the console devkit"
  "$E" approve "$RUN_DIR" --boundary slice >/dev/null
  assert_eq approved "$("$E" status "$RUN_DIR")"
  # The PRs carry only merged work, never the check.
  assert_not_contains "$("$E" prs "$RUN_DIR" --json | jq -c '[.[].tickets[]]')" '"5"'
}

# ------------------------------------------------------- review fixes (#157)

test_a_check_answered_while_a_wave_holds_the_lock_is_answered_once() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  local other=
  "$G" open "$RUN_DIR" slice-1 >/dev/null
  other=$(start_worker)
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$other"
  ARTISAN_WRITER_PID=$CHAT "$G" check "$RUN_DIR" 5 pass >/dev/null 2>&1
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-5.json")"
  # The pending answer counts already: a second one is refused.
  assert_status 6 env ARTISAN_WRITER_PID=$CHAT "$G" check "$RUN_DIR" 5 fail --why again
  ARTISAN_WRITER_PID=$other "$G" sync "$RUN_DIR" >/dev/null
  assert_eq 1 "$(events human-check-passed | jq length)"
  assert_eq 0 "$(events human-check-failed | jq length)"
}

test_a_hands_on_ticket_never_waits_on_a_human_check() {
  setup_checks
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  # #6 lists the Human check #5 as its only blocker; made the hands-on pick.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.hands_on = {ticket: "6", focus: "x"}'
  assert_contains "$("$SCRIPTS/human.sh" setup "$RUN_DIR")" "#6 "
}

test_status_names_the_end_gate_for_a_check_no_slice_gate_will_list() {
  setup_checks
  # #5 now checks #3, which is in no slice: only the end gate lists it,
  # though the farewell slice gate is still to open.
  jq '.body |= sub("human-check-for #1"; "human-check-for #3")' "$FAKE_GH_DIR/issue-5.json" >"$FAKE_GH_DIR/x" \
    && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-5.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["5"].slice = null | .plan.gates[0].tickets = ["1"]'
  merged 1
  merged 3
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "Human checks: 1 open (end gate)"
}

test_a_check_is_deferred_only_at_the_end_gate() {
  setup_checks
  merged 1
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null
  assert_status 6 "$E" defer-check "$RUN_DIR" 5 --why "too early"
  assert_eq 0 "$(events human-check-deferred | jq length)"
}
