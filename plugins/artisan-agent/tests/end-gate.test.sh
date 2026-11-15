# end-gate.sh (#71): the end gate lists every deferred gate (both kinds) and
# the cards carried from gates closed by hand; a Bug run's end gate doubles as
# its slice gate and leads with the failing test; once approved, the PRs to
# main are cut along the pr-boundaries guardrail (at whatever level setup
# recorded it, or a boundary the Artisan approves), and the run ends with the
# in-run labels off and the retro offered. Fake `gh`; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

E="$PLUGIN_ROOT/scripts/end-gate.sh"

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

individual_boundary() {
  mkdir -p "$ARTISAN_HOME"
  printf '# Individual standards\n\n## Guardrails\n\n- `pr-boundaries`: one PR per %s (set at setup).\n' "$1" >"$ARTISAN_HOME/CODING_STANDARDS.md"
}

team_boundary() {
  printf 'team_guardrails_repo: acme/guardrails\n' >"$PROJECT/.artisan-agent/config.yml"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m team
  mkdir -p "$ARTISAN_TEAM_CACHE/acme_guardrails"
  printf '## Guardrails\n\n- `pr-boundaries`: one PR per %s\n' "$1" >"$ARTISAN_TEAM_CACHE/acme_guardrails/CODING_STANDARDS.md"
}

cut_all() {
  local n=
  for n in $("$E" prs "$RUN_DIR" --json | jq -r '.[].n'); do
    printf 'Body of PR %s, written with upstream pr.\n' "$n" >"$TEST_TMPDIR/body-$n.md"
    "$E" cut "$RUN_DIR" "$n" --body-file "$TEST_TMPDIR/body-$n.md" >/dev/null
  done
}

prs() { # one line per PR: head base tickets-in-title
  local f=
  for f in "$FAKE_GH_DIR"/pr-*.json; do
    [ -f "$f" ] && jq -r '"\(.head) \(.base)"' "$f"
  done
}

# ------------------------------------------------------------ the packet

test_the_end_gate_lists_deferred_gates_of_both_kinds_and_carried_cards() {
  setup_end
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .review_gates = [
      {id: "slice-1", kind: "slice", title: "Slice gate: export (run r1)", issue: 40, tickets: ["1"],
       dependents: [{number: "2", title: "Ticket 2"}], cards: [], status: "deferred",
       deferral: {by: "Artisan", why: "after the demo", at: 1}, decisions: [], reworks: []},
      {id: "slice-2", kind: "slice", title: "Slice gate: billing (run r1)", issue: 41, tickets: ["3"], dependents: [],
       cards: [{card: 1, ticket: "3", question: "Which currency?", choice: "EUR", by: "worker 3"}],
       status: "approved", closed_on_tracker: true, carried: [1], decisions: [], reworks: []}]
    | .exception_gates = [{id: "exception-5", kind: "exception", reason: "gave-up", ticket: "4",
       title: "Exception gate: run r1 gave up on #4 after 2 attempts", issue: 42, dependents: [],
       status: "deferred", deferral: {by: "Artisan", at: 1}}]'
  local body=
  body=$("$E" packet "$RUN_DIR")
  assert_contains "$body" "## Deferred gates"
  assert_contains "$body" "| Slice gate: export (run r1) | #40 | slice | Artisan | after the demo | #2 |"
  assert_contains "$body" "| Exception gate: run r1 gave up on #4 after 2 attempts | #42 | exception | Artisan | - | - |"
  assert_contains "$body" "## Cards carried from gates closed on GitHub"
  assert_contains "$body" "| #41 (closed on GitHub) | 1 | #3 | Which currency? → EUR | worker 3 |"
  # Anything deferred is still waiting there: approval is refused until each is answered.
  product_boundary slice
  local err=
  err=$("$E" approve "$RUN_DIR" 2>&1) && fail "approved with deferred gates open"
  assert_status 6 "$E" approve "$RUN_DIR"
  assert_contains "$err" "#40"
  assert_contains "$err" "#42"
}

test_the_end_gates_human_checks_name_the_agent_ticket_they_verify() {
  setup_end
  local n=
  for n in 4 5; do
    jq -n --argjson n "$n" '{number: $n, title: "Human check \($n)", state: "open", labels: [{name: "ready-for-human"}], body: "Try it."}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .plan.scope += ["4", "5"]
    | .plan.tickets["4"] = {title: "Human check 4 (#1)", human_check_for: "1"}
    | .plan.tickets["5"] = {title: "Human check 5 (#3)", human_check_for: "3"}
    | .tickets["4"] = {status: "queued"} | .tickets["5"] = {status: "queued"}
    | .tickets["5"].human_check = {state: "deferred", for: "3", deferral: {by: "Artisan", why: "later", return: "x"}}'
  local body=
  body=$("$E" packet "$RUN_DIR")
  assert_contains "$body" "| #4 (Human check 4 (#1)) | #1 |"
  assert_contains "$body" "| #5 (Human check 5 (#3)) | #3 |"
  assert_not_contains "$body" "#None"
}

test_the_end_gate_lists_and_waits_on_a_deferred_overrun_gate() {
  setup_end
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .overrun_gates = [{id: "overrun-1", kind: "exception", title: "Exception gate: overrun (run r1)", issue: 50,
       status: "deferred", gate_actions: ["defer"], deferred_at: 5,
       decision: {card: 1, option: "raise", choice: "raise the budget to $2.75", why: "demo first", by: "Artisan", job: 10, at: 5}},
      {id: "overrun-2", kind: "exception", title: "Exception gate: overrun 2 (run r1)", issue: 51, status: "open"}]'
  local body= err=
  body=$("$E" packet "$RUN_DIR")
  assert_contains "$body" "| Exception gate: overrun (run r1) | #50 | overrun | Artisan | demo first | - |"
  assert_not_contains "$body" "overrun 2"
  product_boundary slice
  err=$("$E" approve "$RUN_DIR" 2>&1) && fail "approved with a deferred overrun gate"
  assert_status 6 "$E" approve "$RUN_DIR"
  assert_contains "$err" "Exception gate: overrun (run r1) #50"
  assert_contains "$("$SCRIPTS/gate-action.sh" deferred "$RUN_DIR")" "| #50 | overrun | Artisan |"
}

test_a_run_with_no_overrun_gates_lists_no_deferred_gate() {
  setup_end
  assert_contains "$("$SCRIPTS/gate-action.sh" deferred "$RUN_DIR")" "No gate is deferred."
}

test_a_one_ticket_bug_run_has_one_end_gate_leading_with_the_failing_test() {
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  jq -n '{number: 7, title: "crash on empty cart", state: "closed", labels: [{name: "in-run"}], body: "x"}' >"$FAKE_GH_DIR/issue-7.json"
  jq -n '{run_id: "r1", repo: "local/sample", integration_branch: "run/r1", route: "bug", scope: ["7"],
    waves: [["7"]], max_agents: 1, attempts_per_ticket: 2, estimate_usd: 1, budget_usd: 1.25,
    gates: [{kind: "end", doubles_as_slice: true, bug: true}],
    tickets: {"7": {title: "crash on empty cart", failing_test: "tests/cart.test.sh: test_empty_cart_does_not_crash",
                    model: "claude-sonnet-5-5", caps: {max_budget_usd: 1, max_turns: 20, deadline_seconds: 60}}}}' >plan.json
  "$SCRIPTS/state.sh" init "$RUN_DIR" plan.json
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["7"] += {status: "merged", merge_commit: "abcdef1234567",
      evidence: {ticket: "7", verdict: "pass",
        acceptance: [{criterion: "The empty-cart test fails before the fix and passes after", met: true,
                      evidence: {tests: ["tests/cart.test.sh: test_empty_cart_does_not_crash"]}}],
        unsure: [], decisions: [{job: 3, question: "Guard in the view or the model?", choice: "the model",
          alternative: "the view", by: "worker 7", kind: "engineering", criterion: "4", confidence: "provisional"}]}}'
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"; export PATH
  export ARTISAN_HOME="$TEST_TMPDIR/home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/tc" CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cc"
  CHAT=$(start_worker); export ARTISAN_WRITER_PID=$CHAT; trap cleanup EXIT
  # No slice gate and no risk gate: the end gate is the only one.
  assert_eq "" "$("$SCRIPTS/gate.sh" due "$RUN_DIR")"
  assert_eq due "$("$E" status "$RUN_DIR")"
  local num= body= first=
  num=$("$E" open "$RUN_DIR")
  assert_eq "End gate: run r1" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  assert_eq review-gate "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$num.json")"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  first=$(printf '%s\n' "$body" | grep '^## ' | head -1)
  assert_eq "## The failing test" "$first" "the packet leads with the failing test"
  assert_contains "$body" "| #7 (crash on empty cart) | \`tests/cart.test.sh: test_empty_cart_does_not_crash\` | proven |"
  # It doubles as the slice gate: the worker's decision cards are on it.
  assert_contains "$body" "Guard in the view or the model?"
  assert_eq "$num" "$("$E" open "$RUN_DIR")" "opening again opens nothing new"
  assert_eq "end-gate" "$(state_get '.decisions[-1].kind')"
}

# ------------------------------------------------------------ PR boundaries

test_per_slice_from_the_product_guardrail_cuts_one_pr_per_slice() {
  setup_end
  product_boundary slice
  assert_eq '{"value":"slice","level":"product","source":"guardrail"}' "$("$E" boundary "$RUN_DIR")"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_eq "pr/r1/1 main
pr/r1/2 pr/r1/1" "$(prs)"
  assert_eq "$M2" "$(git -C "$PROJECT" rev-parse pr/r1/1)" "the export slice's PR ends at #2's merge"
  assert_eq "$M3" "$(git -C "$PROJECT" rev-parse pr/r1/2)"
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/pr-1.json")" "#1, #2"
  assert_eq "Body of PR 1, written with upstream pr." "$(jq -r .body "$FAKE_GH_DIR/pr-1.json")"
  # The approval records job 13 and whether the Artisan changed anything;
  # the boundary came from a guardrail, so no job-17 decision was asked.
  assert_eq "approve 13 false" "$(state_get '.decisions[] | select(.kind == "end-gate") | "\(.choice) \(.job) \(.changed)"')"
  assert_eq "slice guardrail product" "$(state_get '.end_gate.boundary | "\(.value) \(.source) \(.level)"')"
}

test_per_plan_from_the_team_guardrail_cuts_one_pr_per_plan() {
  setup_end
  team_boundary plan
  assert_eq '{"value":"plan","level":"team","source":"guardrail"}' "$("$E" boundary "$RUN_DIR")"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_eq "pr/r1/1 main
pr/r1/2 pr/r1/1" "$(prs)"
  assert_eq "$M1" "$(git -C "$PROJECT" rev-parse pr/r1/1)" "plan #100 is #1 alone"
  assert_eq "$M3" "$(git -C "$PROJECT" rev-parse pr/r1/2)"
}

test_per_ticket_from_the_individual_guardrail_cuts_one_pr_per_ticket() {
  setup_end
  individual_boundary ticket
  assert_eq '{"value":"ticket","level":"individual","source":"guardrail"}' "$("$E" boundary "$RUN_DIR")"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_eq "pr/r1/1 main
pr/r1/2 pr/r1/1
pr/r1/3 pr/r1/2" "$(prs)"
  assert_eq "$M2" "$(git -C "$PROJECT" rev-parse pr/r1/2)"
}

test_the_product_guardrail_beats_team_and_individual() {
  setup_end
  individual_boundary ticket
  team_boundary plan
  product_boundary slice
  assert_eq slice "$("$E" boundary "$RUN_DIR" | jq -r .value)"
}

test_with_no_boundary_recorded_the_end_gate_proposes_one_as_an_approved_step() {
  setup_end
  assert_eq '{"value":null,"proposed":"slice","source":"none"}' "$("$E" boundary "$RUN_DIR")"
  local num=
  num=$("$E" open "$RUN_DIR")
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")" "No PR boundary is recorded: proposed **one PR per slice**"
  assert_status 6 "$E" approve "$RUN_DIR"
  "$E" approve "$RUN_DIR" --boundary ticket --why "small tickets" >/dev/null
  assert_eq "ticket approved Artisan" "$(state_get '.end_gate.boundary | "\(.value) \(.source) \(.by)"')"
  assert_eq "ticket 17 true" "$(state_get '.decisions[] | select(.kind == "pr-boundary") | "\(.choice) \(.job) \(.changed)"')"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-$num.json")"
  cut_all
  assert_eq 3 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
}

test_prs_wait_for_the_end_gate_and_cutting_again_opens_nothing_new() {
  setup_end
  product_boundary ticket
  assert_status 6 "$E" prs "$RUN_DIR"
  "$E" open "$RUN_DIR" >/dev/null
  assert_status 6 "$E" cut "$RUN_DIR" 1 --body-file /dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  echo body >b.md
  local url=
  url=$("$E" cut "$RUN_DIR" 1 --body-file b.md)
  assert_eq "$url" "$("$E" cut "$RUN_DIR" 1 --body-file b.md)"
  assert_eq 1 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
  assert_status 6 "$E" cut "$RUN_DIR" 3 --body-file b.md   # stacked: PR 2 first
}

test_a_removed_end_gate_still_needs_the_boundary_before_prs() {
  setup_end '[]'
  assert_eq removed "$("$E" status "$RUN_DIR")"
  assert_status 6 "$E" open "$RUN_DIR"
  assert_status 6 "$E" prs "$RUN_DIR"
  "$E" approve "$RUN_DIR" --boundary plan >/dev/null
  cut_all
  assert_eq 2 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
}

# ------------------------------------------------------------ ending the run

test_finishing_removes_the_in_run_labels_and_offers_the_retro() {
  setup_end
  product_boundary plan
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  assert_status 6 "$E" finish "$RUN_DIR"   # PRs not cut yet
  cut_all
  local out= n=
  out=$("$E" finish "$RUN_DIR")
  for n in 1 2 3; do
    assert_eq "ready-for-agent" "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$n.json")"
  done
  assert_contains "$out" "/artisan-agent:retro"
  # The run summary's merge gate costs (#199): none ran here; the end gate waited on the Artisan.
  assert_contains "$out" "| Merge gates | This run |"
  assert_contains "$out" "| Merge gates run | - |"
  assert_contains "$out" "min over 1 decision (longest"
  assert_eq ended "$("$E" status "$RUN_DIR")"
  assert_eq "run-ended" "$(state_get '.events[-1].event')"
}

test_the_end_gate_is_not_due_while_tickets_remain() {
  setup_end
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].status = "queued"'
  assert_eq not-due "$("$E" status "$RUN_DIR")"
  assert_status 6 "$E" open "$RUN_DIR"
}

test_a_slice_whose_merges_interleave_is_cherry_picked_onto_the_previous_pr() {
  setup_end
  # #2 moves to its own slice, so "export" (#1, #3) straddles it.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["2"].slice = "billing" | .plan.tickets["3"].slice = "export"'
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" --boundary slice >/dev/null
  assert_eq '[["2"],["1","3"]]' "$("$E" prs "$RUN_DIR" --json | jq -c 'map(.tickets)')"
  cut_all
  assert_eq "t2.txt" "$(git -C "$PROJECT" diff --name-only main pr/r1/1)" "PR 1 is #2 alone"
  assert_eq "t1.txt t3.txt" "$(git -C "$PROJECT" diff --name-only pr/r1/1 pr/r1/2 | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "" "$(git -C "$PROJECT" diff "$M3" pr/r1/2)" "the stack ends where the integration branch does"
}

test_opening_the_end_gate_deletes_the_runs_leftover_ci_branches() {
  setup_end
  local origin="$TEST_TMPDIR/origin.git"
  git_quiet clone --bare "$PROJECT" "$origin"
  git_quiet -C "$PROJECT" remote add origin "$origin"
  # A merge gate on CI that crashed left its branch; another run's is not ours.
  git_quiet -C "$PROJECT" push origin "main:refs/heads/ci/r1-2-1-100" "main:refs/heads/ci/r10-1-1-100"
  "$E" open "$RUN_DIR" >/dev/null
  assert_eq "ci/r10-1-1-100" "$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/ci/')"
}

test_the_end_gate_packet_offers_flagging_a_bug_by_ticket() {
  setup_end
  assert_contains "$("$E" packet "$RUN_DIR")" "**a bug in #<ticket>**"
}

# #203: the end gate that doubles as the slice gate carries every merged
# ticket's cards; past 128 KiB (Linux) jq refused them as an argument.
test_an_end_gate_doubling_as_the_slice_gate_shows_cards_over_128_kib() {
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  jq -n '{run_id: "r1", repo: "local/sample", integration_branch: "run/r1", route: "bug", scope: ["7"],
    waves: [["7"]], max_agents: 1, attempts_per_ticket: 2, estimate_usd: 1, budget_usd: 1.25,
    gates: [{kind: "end", doubles_as_slice: true, bug: true}],
    tickets: {"7": {title: "crash on empty cart", failing_test: "tests/cart.test.sh: test_empty_cart_does_not_crash",
                    model: "claude-sonnet-5-5", caps: {max_budget_usd: 1, max_turns: 20, deadline_seconds: 60}}}}' >plan.json
  "$SCRIPTS/state.sh" init "$RUN_DIR" plan.json
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["7"] += {status: "merged", merge_commit: "abcdef1234567",
      evidence: {ticket: "7", verdict: "pass", acceptance: [], unsure: [],
        decisions: [range(300) | {job: 3, question: "Question \(.): \("y" * 500)?", choice: "the model",
          alternative: "the view", by: "worker 7", kind: "engineering", criterion: "4", confidence: "provisional"}]}}'
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"; export PATH
  export ARTISAN_HOME="$TEST_TMPDIR/home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/tc" CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cc"
  CHAT=$(start_worker); export ARTISAN_WRITER_PID=$CHAT; trap cleanup EXIT
  local body=
  body=$("$E" packet "$RUN_DIR")
  assert_contains "$body" "Question 0: y"
  assert_contains "$body" "Question 299: y"
}

# ------------------------------------------------------------ worktree_setup at the end gate (#182)

# #2 moves to its own slice, so both PRs are built in a worktree of their own
# (cherry-picked), and the project's worktree_setup runs in each.
setup_interleaved_cut() { # setup-command
  setup_end
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.tickets["2"].slice = "billing" | .plan.tickets["3"].slice = "export"'
  set_end_setup "$1"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" --boundary slice >/dev/null
  printf 'Body.\n' >"$TEST_TMPDIR/body.md"
}

set_end_setup() { # shell command
  printf "max_agents: 5\nworktree_setup: '%s'\n" "$(printf '%s' "$1" | sed "s/'/''/g")" >"$PROJECT/.artisan-agent/config.yml"
}

setup_decision() { state_get '[.decisions[] | select(.kind == "end-gate-setup")] | last | .id'; }

test_a_failing_setup_at_the_end_gate_records_the_event_and_a_waiting_decision() {
  setup_interleaved_cut 'echo first >&2; echo "npm ci: lockfile out of date" >&2; exit 3'
  local err="" st=0
  err=$("$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" 2>&1 >/dev/null) || st=$?
  assert_eq 6 "$st"
  assert_eq 1 "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "one line: $err"
  assert_contains "$err" "exited 3"
  assert_contains "$err" "lockfile out of date"
  assert_contains "$err" "decision $(setup_decision) waits"
  assert_eq "end-gate-setup-failed 1 3" "$(state_get '.events[] | select(.event == "end-gate-setup-failed") | "\(.event) \(.n) \(.exit)"')"
  assert_eq 'waiting end 1 3 retry,bypass' "$(state_get '.decisions[] | select(.kind == "end-gate-setup")
    | "\(.status) \(.gate) \(.pr) \(.exit) \(.options | join(","))"')"
  assert_contains "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .command')" 'exit 3'
  assert_contains "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .stderr')" "npm ci: lockfile out of date"
  # No PR is cut, the run doesn't end, and status asks for the decision.
  assert_eq 0 "$(ls "$FAKE_GH_DIR"/pr-*.json 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "" "$(git -C "$PROJECT" branch --list 'pr/r1/*')"
  assert_eq approved "$("$E" status "$RUN_DIR")"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: decide"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "end-gate-setup: PR 1"
  # Cutting again before the Artisan answers is refused, naming the decision.
  err=$("$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" 2>&1 >/dev/null) || st=$?
  assert_eq 6 "$st"
  assert_contains "$err" "state.sh decide $RUN_DIR $(setup_decision) retry|bypass"
}

test_retry_after_fixing_the_setup_carries_on_with_the_end_gate() {
  setup_interleaved_cut 'exit 3'
  assert_status 6 "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md"
  export SETUP_LOG="$TEST_TMPDIR/setup.log"
  set_end_setup 'echo "$PWD" >>"$SETUP_LOG"'
  "$SCRIPTS/state.sh" decide "$RUN_DIR" "$(setup_decision)" retry >/dev/null
  "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  "$E" cut "$RUN_DIR" 2 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  assert_eq 2 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
  assert_eq 2 "$(wc -l <"$SETUP_LOG" | tr -d ' ')" "the setup ran for each PR"
  assert_eq "" "$(git -C "$PROJECT" diff "$M3" pr/r1/2)"
  assert_eq true "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .applied')"
  assert_not_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "next: decide"
  "$E" finish "$RUN_DIR" >/dev/null
  assert_eq ended "$("$E" status "$RUN_DIR")"
}

test_bypassing_the_setup_cuts_that_pr_without_it() {
  export SETUP_LOG="$TEST_TMPDIR/setup.log"
  setup_interleaved_cut 'echo "$PWD" >>"$SETUP_LOG"; exit 3'
  assert_status 6 "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md"
  "$SCRIPTS/state.sh" decide "$RUN_DIR" "$(setup_decision)" bypass >/dev/null
  "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  assert_eq 1 "$(wc -l <"$SETUP_LOG" | tr -d ' ')" "the bypassed cut ran no setup"
  assert_eq "t2.txt" "$(git -C "$PROJECT" diff --name-only main pr/r1/1)"
  # The bypass was for PR 1 alone: PR 2 runs the setup, which still fails.
  assert_status 6 "$E" cut "$RUN_DIR" 2 --body-file "$TEST_TMPDIR/body.md"
  assert_eq 2 "$(state_get '[.decisions[] | select(.kind == "end-gate-setup")] | last | .pr')"
}

test_a_passing_setup_at_the_end_gate_runs_once_in_each_pr_worktree() {
  export SETUP_LOG="$TEST_TMPDIR/setup.log"
  setup_interleaved_cut 'echo "$PWD $ARTISAN_MAIN" >>"$SETUP_LOG"'
  "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  assert_eq "$TEST_TMPDIR/project-wt/r1-pr-1 $(cd "$PROJECT" && pwd -P)" "$(sed "s#$(cd "$TEST_TMPDIR" && pwd -P)#$TEST_TMPDIR#" "$SETUP_LOG")"
  assert_eq 0 "$(state_get '[.decisions[] | select(.kind == "end-gate-setup")] | length')"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "end-gate-setup-failed")] | length')"
}

test_a_setup_timeout_at_the_end_gate_records_exit_124_and_its_stderr() {
  setup_interleaved_cut 'echo "installing deps" >&2; sleep 30'
  printf 'worktree_setup_timeout: 1\n' >>"$PROJECT/.artisan-agent/config.yml"
  local err="" st=0
  err=$("$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" 2>&1 >/dev/null) || st=$?
  assert_eq 6 "$st"
  assert_contains "$err" "setup timeout after 1s"
  assert_eq 124 "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .exit')"
  assert_contains "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .stderr')" "installing deps"
  assert_eq 124 "$(state_get '.events[] | select(.event == "end-gate-setup-failed") | .exit')"
}

test_a_setup_that_cannot_start_at_the_end_gate_has_no_exit_status() {
  setup_interleaved_cut 'touch deps-installed'
  mkdir -p "$TEST_TMPDIR/nosetsid"
  printf '#!/bin/sh\necho "setsid: failed" >&2\nexit 1\n' >"$TEST_TMPDIR/nosetsid/setsid"
  chmod +x "$TEST_TMPDIR/nosetsid/setsid"
  assert_status 6 env PATH="$TEST_TMPDIR/nosetsid:$PATH" "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md"
  assert_eq null "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .exit')"
  assert_contains "$(state_get '.decisions[] | select(.kind == "end-gate-setup") | .stderr')" "setsid: failed"
  assert_contains "$("$SCRIPTS/wave.sh" status "$RUN_DIR")" "end-gate-setup: PR 1: \`touch deps-installed\` could not start"
}

# ------------------------------------------- open decisions raised at gates (#232)

test_the_end_gate_waits_until_each_open_decision_raised_at_a_gate_is_ruled() {
  setup_end
  product_boundary ticket
  local od=
  od=$("$SCRIPTS/questions.sh" file --ticket 2 --criterion 8 --case invented --harm "Users see a name nobody chose" \
         --recommendation "Ask product" --split --raised-by gate --run "$RUN_DIR")
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["2"].questions = [{ticket: $q, blocking: false, state: "open",
      at: "2026-11-15T00:00:00Z", raised_at: "gate", gate: "slice-export", gate_issue: 9, item: {card: 1}}]' --arg q "$od"
  "$E" open "$RUN_DIR" >/dev/null
  local packet=
  packet=$("$E" packet "$RUN_DIR")
  assert_contains "$packet" "## Open decisions raised at gates"
  assert_contains "$packet" "| #$od | #2 | gate #9 (slice-export) | card 1 |"
  # Refused while it is open: no approval, no PR.
  assert_status 6 "$E" approve "$RUN_DIR"
  assert_contains "$("$E" approve "$RUN_DIR" 2>&1 || true)" "#$od"
  assert_eq 0 "$(ls "$FAKE_GH_DIR"/pr-*.json 2>/dev/null | wc -l | tr -d ' ')"
  # The Decision chat rules on the tracker; the end gate reads it and goes on as today.
  printf 'Answer: Keep t2.txt.\nTook the recommendation: no\nNeeded the Decision chat: yes' >"$FAKE_GH_DIR/comments-$od.md"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$od.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$od.json"
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq answer "$(state_get '.tickets["2"].questions[0].ruling.kind')"
  assert_contains "$("$E" packet "$RUN_DIR")" "None waiting"
  cut_all
  assert_eq 3 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
}

test_a_pr_is_not_cut_while_an_open_decision_raised_at_a_gate_waits() {
  setup_end
  product_boundary ticket
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  local od=
  od=$("$SCRIPTS/questions.sh" file --ticket 1 --criterion 8 --case adr --harm "Settles the export format for good" \
         --recommendation "Write the ADR" --split --raised-by gate --run "$RUN_DIR")
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].questions = [{ticket: $q, blocking: false, state: "open",
      at: "2026-11-15T00:00:00Z", raised_at: "gate", gate: "slice-export", gate_issue: 9, item: {uncertainty: 2}}]' --arg q "$od"
  echo body >"$TEST_TMPDIR/b.md"
  assert_status 6 "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/b.md"
  assert_eq 0 "$(ls "$FAKE_GH_DIR"/pr-*.json 2>/dev/null | wc -l | tr -d ' ')"
}
