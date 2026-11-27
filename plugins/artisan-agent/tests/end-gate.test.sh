# end-gate.sh (#71): the end gate lists every deferred gate (both kinds) and
# the cards carried from gates closed by hand; a Bug run's end gate doubles as
# its slice gate and leads with the failing test; once approved, the PRs to
# main are cut along the pr-boundaries guardrail (at whatever level setup
# recorded it, or a boundary the Artisan approves), and the run ends with the
# in-run labels off and the retro offered. Fake `gh`; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

E="$PLUGIN_ROOT/scripts/end-gate.sh"

. "$TESTS_DIR/helpers/end-gate-run.sh"

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

test_the_end_gate_approves_once_gate_action_has_resolved_the_deferred_overrun_gate() {
  setup_end
  jq -n '{number: 50, title: "overrun", state: "open", labels: [], body: "x"}' >"$FAKE_GH_DIR/issue-50.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .overrun_gates = [{id: "overrun-1", kind: "exception", title: "Exception gate: overrun (run r1)", issue: 50,
       status: "deferred", gate_actions: ["defer"], deferred_at: 5,
       decision: {card: 1, option: "raise", choice: "raise", why: "demo", by: "Artisan", job: 10, at: 5}}]'
  product_boundary slice
  "$E" open "$RUN_DIR" >/dev/null
  assert_status 6 "$E" approve "$RUN_DIR"
  "$SCRIPTS/gate-action.sh" approve "$RUN_DIR" 50 --by Andrew >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq approved "$("$E" status "$RUN_DIR")"
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

test_per_run_from_the_product_guardrail_cuts_one_pr_from_the_integration_branch_to_main() {
  setup_end
  product_boundary run
  assert_eq '{"value":"run","level":"product","source":"guardrail"}' "$("$E" boundary "$RUN_DIR")"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq '[{"n":1,"branch":"run/r1","base":"main","tickets":["1","2","3"]}]' \
    "$("$E" prs "$RUN_DIR" --json | jq -c 'map({n, branch, base, tickets})')"
  assert_contains "$("$E" prs "$RUN_DIR")" '| 1 | `run/r1` | `main` |'
  cut_all
  assert_eq "run/r1 main" "$(prs)"
  assert_eq "$M3" "$(git -C "$PROJECT" rev-parse run/r1)" "the integration branch is the PR's head, untouched"
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/pr-1.json")" "#1, #2, #3"
  assert_contains "$("$E" finish "$RUN_DIR")" "1 PR(s) to main"
}

test_the_artisan_can_approve_one_pr_for_the_whole_run() {
  setup_end
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" --boundary run >/dev/null
  assert_eq "run 17 true" "$(state_get '.decisions[] | select(.kind == "pr-boundary") | "\(.choice) \(.job) \(.changed)"')"
  assert_eq "run/r1 main" "$("$E" prs "$RUN_DIR" --json | jq -r '.[] | "\(.branch) \(.base)"')"
}

test_a_group_already_on_main_is_left_out_with_a_reason_and_the_stack_starts_after_it() {
  setup_end
  product_boundary slice
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge #1 and #2 (#346)" "$M2"   # the export slice reached main another way
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq '[{"n":1,"base":"main","tickets":["3"]}]' "$("$E" prs "$RUN_DIR" --json | jq -c 'map({n, base, tickets})')"
  assert_contains "$("$E" prs "$RUN_DIR")" "Left out: #1, #2 (export): already on main"
  cut_all
  assert_eq "pr/r1/1 main" "$(prs)"
}

test_the_prs_keep_their_numbers_once_cutting_has_begun() {
  setup_end
  product_boundary ticket
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  echo body >"$TEST_TMPDIR/b.md"
  "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/b.md" >/dev/null
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge #1 and #2 by hand" "$M2"   # #2 reaches main after PR 1 is cut
  assert_eq '[["1"],["2"],["3"]]' "$("$E" prs "$RUN_DIR" --json | jq -c 'map(.tickets)')"
}

test_finish_does_not_fail_on_a_design_whose_tickets_were_left_out_as_already_on_main() {
  setup_end
  design_ticket 10 quick-pay
  names_design 1 10
  product_boundary slice
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge #1 and #2 (#346)" "$M2"
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  merge_all_prs
  local out=
  out=$("$E" finish "$RUN_DIR" 2>&1) || fail "finish failed: $out"
  assert_contains "$out" "design #10 is not retired: its tickets (#1) reached main outside this run's PRs"
  assert_eq ended "$("$E" status "$RUN_DIR")"
}

test_a_run_already_on_main_has_no_pr_to_cut() {
  setup_end
  product_boundary run
  merge_integration_into_main
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq '[]' "$("$E" prs "$RUN_DIR" --json)"
  assert_contains "$("$E" prs "$RUN_DIR")" "Left out: #1, #2, #3 (run): already on main"
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

# Stacked PRs (#271): merging with --delete-branch closes the next PR, so the
# end gate says how to merge the stack.
test_two_or_more_prs_print_the_stack_steps_in_merge_order() {
  setup_end
  product_boundary ticket
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  local out= u1= u2=
  out=$("$E" prs "$RUN_DIR")
  u1=$(state_get '.end_gate.prs[0].url'); u2=$(state_get '.end_gate.prs[1].url')
  assert_contains "$out" "Merge the stack in this order"
  assert_contains "$out" "gh pr merge $u1 --merge"
  assert_contains "$out" "gh pr edit $u2 --base main"
  assert_contains "$out" "gh pr merge $u2 --merge"
  assert_contains "$out" "only after the whole stack has merged"
  assert_eq 0 "$(printf '%s\n' "$out" | grep -c 'gh pr merge.*--delete-branch' || true)"
  assert_contains "$("$E" finish "$RUN_DIR")" "gh pr edit $u2 --base main"
}

test_one_pr_prints_no_stack_steps() {
  setup_end
  product_boundary run
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_not_contains "$("$E" prs "$RUN_DIR")" "gh pr merge"
  assert_not_contains "$("$E" finish "$RUN_DIR")" "gh pr merge"
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

# A run whose integration branch the Artisan merged into main as one PR (#364).
merge_integration_into_main() { # [pr-number]: --no-ff into main, and a merged PR in the fake tracker
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge run/r1 (#${1:-7})" run/r1
  if [ -n "${1:-}" ]; then
    jq -n --argjson n "$1" --arg tip "$(git -C "$PROJECT" rev-parse run/r1)" --arg oid "$(git -C "$PROJECT" rev-parse HEAD)" \
      '{number: $n, base: "main", head: "run/r1", title: "Run r1", state: "MERGED", merge_oid: $oid, commits: [$tip]}' >"$FAKE_GH_DIR/pr-$1.json"
  fi
}

approved_end() {
  product_boundary plan
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
}

test_finish_ends_a_run_whose_integration_branch_was_merged_as_one_pr_and_records_that_pr() {
  setup_end
  approved_end
  merge_integration_into_main 7
  local out= n=
  out=$("$E" finish "$RUN_DIR")
  assert_contains "$out" "https://github.com/local/sample/pull/7"
  assert_contains "$out" "/artisan-agent:retro"
  assert_contains "$out" "| Merge gates | This run |"
  assert_eq ended "$("$E" status "$RUN_DIR")"
  assert_eq "https://github.com/local/sample/pull/7" "$(state_get '.end_gate.merged_outside.url')"
  assert_eq "https://github.com/local/sample/pull/7" "$(state_get '.events[-1].prs[0]')"
  assert_eq "run-ended" "$(state_get '.events[-1].event')"
  for n in 1 2 3; do
    assert_eq "ready-for-agent" "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$n.json")"
  done
}

test_finish_ends_that_run_even_when_the_merging_pr_cannot_be_found() {
  setup_end
  approved_end
  merge_integration_into_main
  "$E" finish "$RUN_DIR" >/dev/null
  assert_eq ended "$("$E" status "$RUN_DIR")"
  assert_eq "null" "$(state_get '.end_gate.merged_outside.url')"
  assert_eq "$(git -C "$PROJECT" rev-parse run/r1)" "$(state_get '.end_gate.merged_outside.tip')"
}

test_finish_still_refuses_when_the_integration_tip_is_not_on_main_and_names_the_missing_merges() {
  setup_end
  approved_end
  local err=
  err=$("$E" finish "$RUN_DIR" 2>&1) && fail "finished with nothing on main"
  assert_status 6 "$E" finish "$RUN_DIR"
  assert_contains "$err" "0 of 2 PRs cut"
  assert_contains "$err" "not on main"
  assert_contains "$err" "#1 (${M1:0:7})"
  assert_contains "$err" "#3 (${M3:0:7})"
  assert_eq approved "$("$E" status "$RUN_DIR")"
}

test_finish_names_only_the_merges_main_lacks_when_main_has_some_of_them() {
  setup_end
  approved_end
  git_quiet -C "$PROJECT" merge --no-ff -m "partial" "$M2"
  local err=
  err=$("$E" finish "$RUN_DIR" 2>&1) && fail "finished with the tip off main"
  assert_contains "$err" "#3 (${M3:0:7})"
  case "$err" in *"#1 ("*|*"#2 ("*) fail "named a merge that is on main: $err" ;; esac
}

test_run_digest_does_not_report_a_run_that_finish_has_ended() {
  setup_end
  approved_end
  merge_integration_into_main 7
  "$E" finish "$RUN_DIR" >/dev/null
  # Even with a ticket left unmerged in the record, an ended run is not open.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["3"].status = "blocked"'
  assert_eq "" "$("$SCRIPTS/run-digest.sh" --run-dir "$RUN_DIR" --peek)"
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

test_the_end_gate_runs_the_runs_setup_when_the_project_config_has_none() {
  export SETUP_LOG="$TEST_TMPDIR/setup.log"
  setup_interleaved_cut ''
  # The run's plan.config (#252): what plan.sh build snapshots and state.sh override changes.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config = ($c + {worktree_setup: "echo \"$PWD\" >>\"$SETUP_LOG\""})' \
    --argjson c "$("$PLUGIN_ROOT/scripts/config.sh" defaults)"
  "$E" cut "$RUN_DIR" 1 --body-file "$TEST_TMPDIR/body.md" >/dev/null
  assert_eq "$TEST_TMPDIR/project-wt/r1-pr-1" "$(sed "s#$(cd "$TEST_TMPDIR" && pwd -P)#$TEST_TMPDIR#" "$SETUP_LOG")"
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
  # The packet reads the ruling too.
  assert_contains "$("$E" packet "$RUN_DIR")" "None waiting"
  "$E" approve "$RUN_DIR" >/dev/null
  assert_eq answer "$(state_get '.tickets["2"].questions[0].ruling.kind')"
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

# A Defer or Discard on a gate-raised open decision (blocking: false, #238)
# is recorded and settled: no decision for the Artisan, the merged ticket
# left merged, in scope and unlabelled, and the end gate's hold released.
gate_raised_od_on_merged_ticket() {
  setup_end
  product_boundary ticket
  OD=$("$SCRIPTS/questions.sh" file --ticket 2 --criterion 8 --case invented --harm "Users see a name nobody chose" \
         --recommendation "Ask product" --split --raised-by gate --run "$RUN_DIR")
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["2"].questions = [{ticket: $q, blocking: false, state: "open",
      at: "2026-11-15T00:00:00Z", raised_at: "gate", gate: "slice-export", gate_issue: 9, item: {card: 1}}]' --arg q "$OD"
  "$E" open "$RUN_DIR" >/dev/null
  assert_status 6 "$E" approve "$RUN_DIR"
}

assert_settled_and_the_pr_opens() { # ruling
  assert_contains "$("$E" packet "$RUN_DIR")" "None waiting"
  assert_eq "$1 true false" "$(state_get '.tickets["2"].questions[0].ruling | "\(.kind) \(.took_recommendation) \(.needed_decision_chat)"')"
  assert_eq 1 "$(jq --arg q "$OD" '[.events[] | select(.event == "ruled" and .question == $q)] | length' "$RUN_DIR/state.json")"
  assert_eq 0 "$(state_get '[.decisions[] | select(.kind == "question" or .kind == "defer-question")] | length')"
  # The merged ticket is untouched: merged, in scope, never labelled deferred.
  assert_eq merged "$(state_get '.tickets["2"].status')"
  assert_eq true "$(state_get '.plan.scope | index("2") != null')"
  assert_eq false "$(jq '[.labels[].name] | index("deferred") != null' "$FAKE_GH_DIR/issue-2.json")"
  # Nothing for `deferred … pull` to take: the settled decision never blocked it.
  assert_status 1 "$SCRIPTS/questions.sh" deferred "$RUN_DIR" 2 pull
  assert_eq merged "$(state_get '.tickets["2"].status')"
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_eq 3 "$(ls "$FAKE_GH_DIR"/pr-*.json | wc -l | tr -d ' ')"
}

test_a_defer_on_a_gate_raised_open_decision_settles_it_and_the_end_gate_goes_on() {
  gate_raised_od_on_merged_ticket
  printf 'Deferred: not this run.\nTook the recommendation: yes\nNeeded the Decision chat: no' >"$FAKE_GH_DIR/comments-$OD.md"
  jq '.labels += [{name: "deferred"}]' "$FAKE_GH_DIR/issue-$OD.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$OD.json"
  assert_settled_and_the_pr_opens defer
}

test_a_discard_on_a_gate_raised_open_decision_settles_it_and_the_end_gate_goes_on() {
  gate_raised_od_on_merged_ticket
  printf 'Not worth it.\nTook the recommendation: yes\nNeeded the Decision chat: no' >"$FAKE_GH_DIR/comments-$OD.md"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-$OD.json" >"$TEST_TMPDIR/i" && mv "$TEST_TMPDIR/i" "$FAKE_GH_DIR/issue-$OD.json"
  assert_settled_and_the_pr_opens discard
}

# ------------------------------------------------------------ retiring designs (#335)

# A design ticket (number 10, slug "quick-pay") in the tracker and a real
# feature branch with a screenshot; the project's design.sh runs against it.
design_ticket() { # number slug [state]
  jq -n --argjson n "$1" --arg slug "$2" --arg st "${3:-open}" \
    '{number: $n, title: "Design: \($slug)", state: $st, labels: [{name: "design"}],
      body: "- **Feature branch:** `feature/\($slug)`\n- **Prototype branch:** `prototype/\($slug)`\n"}' \
    >"$FAKE_GH_DIR/issue-$1.json"
  git_quiet -C "$PROJECT" branch "feature/$2" main
  git_quiet -C "$PROJECT" branch "prototype/$2" main
  git_quiet -C "$PROJECT" worktree add "$TEST_TMPDIR/f-$2" "feature/$2"
  mkdir -p "$TEST_TMPDIR/f-$2/docs/journeys/screenshots"
  echo j >"$TEST_TMPDIR/f-$2/docs/journeys/pay.md"
  echo s >"$TEST_TMPDIR/f-$2/docs/journeys/screenshots/pay.png"
  git_quiet -C "$TEST_TMPDIR/f-$2" add -A
  git_quiet -C "$TEST_TMPDIR/f-$2" commit -m "journey"
  git_quiet -C "$PROJECT" worktree remove --force "$TEST_TMPDIR/f-$2"
}

names_design() { # ticket number: the ticket's body now says it builds that design
  jq --arg b $'Builds it.\nDesign: #'"$2" '.body = $b' "$FAKE_GH_DIR/issue-$1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-$1.json"
}

merge_all_prs() {
  local f= n=
  for f in "$FAKE_GH_DIR"/pr-*.json; do
    jq '.state = "MERGED" | .merge_oid = "abc123"' "$f" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$f"
  done
}

finish_run() { # [unmerged]: the PRs merge before finish unless told otherwise (#396)
  product_boundary plan
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  [ "${1:-}" = unmerged ] || merge_all_prs
  "$E" finish "$RUN_DIR"
}

test_the_end_gate_retires_the_design_a_shipped_ticket_names_and_no_other() {
  setup_end
  design_ticket 10 quick-pay
  design_ticket 11 other-design
  names_design 2 10
  finish_run >/dev/null
  # The named design is retired: prototype gone, screenshot gone, journey kept, ticket closed with its PR.
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null && fail "prototype/quick-pay is still there"
  assert_eq "docs/journeys/pay.md" "$(git -C "$PROJECT" ls-tree -r --name-only feature/quick-pay | grep '^docs/journeys/')"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Shipped in $(state_get '.end_gate.prs[-1].url')"
  # The design no shipped ticket names is untouched.
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/other-design >/dev/null || fail "an unnamed design was retired"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-11.json")"
  assert_eq "docs/journeys/pay.md
docs/journeys/screenshots/pay.png" "$(git -C "$PROJECT" ls-tree -r --name-only feature/other-design | grep '^docs/journeys/')"
}

test_finish_retires_a_design_through_the_pr_that_merged_the_whole_branch() {
  setup_end
  design_ticket 10 quick-pay
  names_design 2 10
  approved_end
  merge_integration_into_main 7
  "$E" finish "$RUN_DIR" >/dev/null
  assert_eq ended "$("$E" status "$RUN_DIR")"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Shipped in https://github.com/local/sample/pull/7"
}

test_the_end_gate_names_the_pr_that_carries_the_designs_ticket() {
  setup_end
  design_ticket 10 quick-pay
  names_design 1 10
  finish_run >/dev/null
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Shipped in $(state_get '.end_gate.prs[0].url')"
}

test_a_run_that_ships_no_design_retires_none() {
  setup_end
  design_ticket 10 quick-pay
  finish_run >/dev/null
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null || fail "a design was retired"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
}

test_a_design_already_closed_is_not_retired_again() {
  setup_end
  design_ticket 10 quick-pay closed
  names_design 2 10
  finish_run >/dev/null
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null || fail "a closed design was retired again"
}

test_a_design_line_with_windows_line_endings_still_names_its_design() {
  setup_end
  design_ticket 10 quick-pay
  jq --arg b $'Builds it.\r\nDesign: #10\r\n' '.body = $b' "$FAKE_GH_DIR/issue-2.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-2.json"
  finish_run >/dev/null
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
}

# ------------------------------------------------------------ retire after the merge (#396)

merge_pr() { # n: the PR has merged into its base
  jq '.state = "MERGED" | .merge_oid = "abc123"' "$FAKE_GH_DIR/pr-$1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/pr-$1.json"
}

test_finish_leaves_a_design_whose_pr_is_cut_but_not_merged_and_lists_it_as_waiting() {
  setup_end
  design_ticket 10 quick-pay
  names_design 2 10
  local out=
  out=$(finish_run unmerged 2>&1)
  assert_contains "$out" "design #10 is waiting on the merge of"
  assert_contains "$out" "Designs waiting on their PR's merge"
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null || fail "an unmerged design was retired"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
  assert_eq "docs/journeys/pay.md
docs/journeys/screenshots/pay.png" "$(git -C "$PROJECT" ls-tree -r --name-only feature/quick-pay | grep '^docs/journeys/')"
}

test_a_rerun_of_finish_retires_the_design_once_its_pr_has_merged_and_names_the_merge() {
  setup_end
  design_ticket 10 quick-pay
  names_design 2 10
  finish_run unmerged >/dev/null 2>&1
  merge_all_prs
  "$E" finish "$RUN_DIR" >/dev/null 2>&1
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null && fail "prototype/quick-pay is still there"
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Shipped in $(state_get '.end_gate.prs[-1].url')"
}

test_a_stacked_pr_that_merged_into_its_base_waits_for_the_pr_under_it() {
  setup_end
  design_ticket 10 quick-pay
  names_design 2 10
  finish_run unmerged >/dev/null 2>&1
  assert_eq 2 "$(state_get '.end_gate.prs | length')"
  merge_pr "$(state_get '.end_gate.prs[-1].url' | sed 's|.*/||')"
  "$E" finish "$RUN_DIR" >/dev/null 2>&1
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null || fail "retired before the PR under it merged"
}

test_a_design_whose_tickets_ride_two_prs_waits_for_the_later_pr_whatever_the_scope_order() {
  setup_end
  design_ticket 10 quick-pay
  names_design 1 10
  names_design 2 10 # ticket 2 rides PR 2; the body's one Design line names the design for both
  jq --arg b $'Builds it.\nDesign: #10' '.body = $b' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-1.json"
  jq '.plan.scope |= reverse' "$RUN_DIR/state.json" >"$TEST_TMPDIR/s" && mv "$TEST_TMPDIR/s" "$RUN_DIR/state.json"
  finish_run unmerged >/dev/null 2>&1
  jq '.state = "MERGED"' "$FAKE_GH_DIR/pr-1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/pr-1.json"
  "$E" finish "$RUN_DIR" >/dev/null 2>&1
  git -C "$PROJECT" rev-parse --verify -q refs/heads/prototype/quick-pay >/dev/null || fail "retired while PR 2, which also carries its tickets, is unmerged"
  merge_all_prs
  "$E" finish "$RUN_DIR" >/dev/null 2>&1
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-10.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-10.md")" "Shipped in $(state_get '.end_gate.prs[1].url')"
}

test_the_design_skill_and_the_end_gate_reference_say_retire_runs_after_the_merge() {
  assert_contains "$(cat "$SCRIPTS/../skills/design/SKILL.md")" "Retire runs after the merge, not at the cut"
  assert_contains "$(cat "$SCRIPTS/../references/end-gate.md")" "after the merge, not at the cut"
}

# ------------------------------------------------- end_gate.auto_merge (#393)

auto_merge() { # true|false: the project's end_gate.auto_merge
  printf 'end_gate:\n  auto_merge: %s\n' "$1" >>"$PROJECT/.artisan-agent/config.yml"
}

cut_two_stacked_prs() {
  product_boundary plan   # plan #100 (ticket 1), plan #101 (tickets 2 and 3): two stacked PRs
  "$E" open "$RUN_DIR" >/dev/null
  "$E" approve "$RUN_DIR" >/dev/null
  cut_all
  assert_eq 2 "$(state_get '.end_gate.prs | length')"
}

test_with_auto_merge_on_finish_merges_the_stack_in_order_and_retargets_before_deleting_branches() {
  setup_end
  auto_merge true
  cut_two_stacked_prs
  local out= calls=
  out=$("$E" finish "$RUN_DIR")
  calls=$(grep -E '^(pr merge|pr edit|api --method DELETE)' "$FAKE_GH_DIR/calls" | sed -E 's|https://github.com/local/sample/pull/||; s| -R local/sample||')
  assert_eq "pr merge 1 --merge
pr edit 2 --base main
pr merge 2 --merge
api --method DELETE repos/local/sample/git/refs/heads/pr/r1/1
api --method DELETE repos/local/sample/git/refs/heads/pr/r1/2" "$calls"
  assert_eq MERGED "$(jq -r .state "$FAKE_GH_DIR/pr-1.json")"
  assert_eq MERGED "$(jq -r .state "$FAKE_GH_DIR/pr-2.json")"
  assert_eq main "$(jq -r .base "$FAKE_GH_DIR/pr-2.json")"
  assert_eq ended "$("$E" status "$RUN_DIR")"
  assert_contains "$out" "Merged the stack"
  assert_not_contains "$out" "Merge the stack in this order"
}

test_a_failed_merge_stops_the_stack_leaves_later_prs_open_and_names_the_cause() {
  setup_end
  auto_merge true
  cut_two_stacked_prs
  echo "Pull request is not mergeable: the merge commit cannot be cleanly created." >"$FAKE_GH_DIR/pr-merge-fail-1"
  local out=
  out=$("$E" finish "$RUN_DIR" 2>&1) && fail "finish succeeded with a merge that failed"
  assert_contains "$out" "auto-merge stopped at PR 1"
  assert_contains "$out" "the merge commit cannot be cleanly created"
  assert_eq OPEN "$(jq -r '.state // "OPEN"' "$FAKE_GH_DIR/pr-2.json")"
  assert_eq pr/r1/1 "$(jq -r .base "$FAKE_GH_DIR/pr-2.json")"
  assert_eq 0 "$(grep -c '^pr merge.*/pull/2' "$FAKE_GH_DIR/calls" || true)"
  [ ! -f "$FAKE_GH_DIR/deleted-branches" ] || fail "a branch was deleted: $(cat "$FAKE_GH_DIR/deleted-branches")"
  assert_eq approved "$("$E" status "$RUN_DIR")"
  assert_eq "auto-merge-stopped" "$(state_get '.events[-1].event')"
  # Fixed, a rerun carries on from where it stopped.
  rm "$FAKE_GH_DIR/pr-merge-fail-1"
  "$E" finish "$RUN_DIR" >/dev/null
  assert_eq MERGED "$(jq -r .state "$FAKE_GH_DIR/pr-2.json")"
  assert_eq ended "$("$E" status "$RUN_DIR")"
}

test_with_auto_merge_off_or_unset_finish_merges_nothing() {
  setup_end
  cut_two_stacked_prs
  local out=
  out=$("$E" finish "$RUN_DIR")
  assert_contains "$out" "Merge the stack in this order"
  assert_eq 0 "$(grep -cE '^(pr merge|pr edit|api --method DELETE)' "$FAKE_GH_DIR/calls" || true)"
  assert_eq ended "$("$E" status "$RUN_DIR")"
}

test_with_auto_merge_set_off_finish_merges_nothing() {
  setup_end
  auto_merge false
  cut_two_stacked_prs
  "$E" finish "$RUN_DIR" >/dev/null
  assert_eq 0 "$(grep -cE '^(pr merge|pr edit|api --method DELETE)' "$FAKE_GH_DIR/calls" || true)"
  assert_eq OPEN "$(jq -r '.state // "OPEN"' "$FAKE_GH_DIR/pr-1.json")"
}
