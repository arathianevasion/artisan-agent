# to-plan.sh and resolve-scope.sh: proposing plans from a ticket graph,
# editing them, the approval view, creating `plan` issues with sub-issues and
# native blocking, and resolving plan issues into a run's scope. A fake `gh`
# over a folder tracker stands in for GitHub.

TP="$PLUGIN_ROOT/scripts/to-plan.sh"
RS="$PLUGIN_ROOT/scripts/resolve-scope.sh"
SKILL="$PLUGIN_ROOT/skills/to-plan/SKILL.md"

# Sample graph: upload (1, 2), billing (3, 4, both after 1), export (5, after 2 and 4).
sample_graph() {
  cat >"$TEST_TMPDIR/graph.json" <<'JSON'
{"tickets": {
  "1": {"title": "Upload endpoint", "slice": "upload", "estimate_usd": 2, "acceptance": ["accepts a file", "rejects 10 MB+"]},
  "2": {"title": "Upload progress", "slice": "upload", "estimate_usd": 2, "blocked_by": ["1"], "acceptance": ["shows percent"]},
  "3": {"title": "Billing model", "slice": "billing", "estimate_usd": 2, "blocked_by": ["1"], "acceptance": ["stores a plan"]},
  "4": {"title": "Billing tab", "slice": "billing", "estimate_usd": 2, "blocked_by": ["3"], "acceptance": ["tab lists invoices | with totals"]},
  "5": {"title": "Export CSV", "slice": "export", "estimate_usd": 2, "blocked_by": ["2", "4"], "acceptance": ["downloads a CSV"]}
}}
JSON
  GRAPH="$TEST_TMPDIR/graph.json"
  PLANS="$TEST_TMPDIR/plans.json"
}

plan_of() { jq -r --argjson i "$2" '.plans[$i].tickets | join(",")' "$1"; }

test_proposed_plans_end_at_slices_show_estimates_and_keep_blockers_first() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  assert_eq 2 "$(jq '.plans | length' "$PLANS")" "plan count"
  assert_eq "1,2" "$(plan_of "$PLANS" 0)"
  assert_eq "3,4,5" "$(plan_of "$PLANS" 1)"
  assert_eq "upload" "$(jq -r '.plans[0].slice' "$PLANS")"
  assert_eq "billing, export" "$(jq -r '.plans[1].slice' "$PLANS")"
  "$TP" check "$PLANS" --graph "$GRAPH"
  local view=; view=$("$TP" render "$PLANS" --graph "$GRAPH")
  assert_contains "$view" "| Plan 1 | upload | 2 | \$4.00 of \$6.00 | nothing |"
  assert_contains "$view" "| Plan 2 | billing, export | 3 | \$6.00 of \$6.00 | Plan 1 |"
}

test_a_small_budget_makes_more_plans_and_a_big_one_makes_one() {
  sample_graph
  assert_eq 3 "$("$TP" propose --graph "$GRAPH" --budget 4 | jq '.plans | length')"
  assert_eq 1 "$("$TP" propose --graph "$GRAPH" --budget 100 | jq '.plans | length')"
}

test_a_slice_over_budget_stays_whole_and_is_flagged() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 3 >"$PLANS"
  assert_eq "1,2" "$(plan_of "$PLANS" 0)"
  assert_contains "$("$TP" render "$PLANS" --graph "$GRAPH")" "| Plan 1 | estimated at \$4.00, over the \$3.00 budget"
}

test_slices_that_block_each_other_are_one_unit_so_no_blocker_follows_its_dependent() {
  # A holds 1 and 3; B holds 2; 2 is blocked by 1 and 3 by 2: cut between A and B
  # either way would put a blocker after its dependent.
  cat >"$TEST_TMPDIR/graph.json" <<'JSON'
{"tickets": {
  "1": {"title": "a1", "slice": "A", "estimate_usd": 3},
  "2": {"title": "b1", "slice": "B", "estimate_usd": 3, "blocked_by": ["1"]},
  "3": {"title": "a2", "slice": "A", "estimate_usd": 3, "blocked_by": ["2"]}
}}
JSON
  "$TP" propose --graph "$TEST_TMPDIR/graph.json" --budget 3 >"$TEST_TMPDIR/p.json"
  assert_eq 1 "$(jq '.plans | length' "$TEST_TMPDIR/p.json")"
  assert_eq "1,2,3" "$(plan_of "$TEST_TMPDIR/p.json" 0)"
}

test_every_proposal_over_many_budgets_has_blockers_in_the_same_or_an_earlier_plan() {
  sample_graph
  local b=
  for b in 1 2 3 4 5 6 7 8 9 10 11; do
    "$TP" propose --graph "$GRAPH" --budget "$b" >"$TEST_TMPDIR/p.json"
    "$TP" check "$TEST_TMPDIR/p.json" --graph "$GRAPH" || fail "budget $b gave an invalid proposal"
  done
}

test_a_ticket_without_a_slice_is_its_own_slice_and_is_estimated_from_tokens() {
  cat >"$TEST_TMPDIR/graph.json" <<'JSON'
{"tickets": {
  "7": {"title": "tiny", "model": "claude-sonnet-5-5", "expected": {"input_tokens": 1000000, "output_tokens": 100000}},
  "8": {"title": "next", "estimate_usd": 1, "blocked_by": ["7"]}
}}
JSON
  "$TP" propose --graph "$TEST_TMPDIR/graph.json" --budget 4 >"$TEST_TMPDIR/p.json"
  assert_eq "#7, #8" "$(jq -r '.plans[0].slice' "$TEST_TMPDIR/p.json")"
  # 1M in at $2 + 0.1M out at $10 = $3.00; plus $1.00 for #8.
  assert_contains "$("$TP" render "$TEST_TMPDIR/p.json" --graph "$TEST_TMPDIR/graph.json")" '$3.00'
}

test_a_cycle_a_missing_estimate_and_a_missing_budget_are_refused() {
  cat >"$TEST_TMPDIR/cyc.json" <<'JSON'
{"tickets": {"1": {"title": "a", "estimate_usd": 1, "blocked_by": ["2"]}, "2": {"title": "b", "estimate_usd": 1, "blocked_by": ["1"]}}}
JSON
  assert_status 1 "$TP" propose --graph "$TEST_TMPDIR/cyc.json" --budget 5
  assert_contains "$("$TP" propose --graph "$TEST_TMPDIR/cyc.json" --budget 5 2>&1 || true)" "cycle"
  echo '{"tickets": {"1": {"title": "a"}}}' >"$TEST_TMPDIR/noest.json"
  assert_contains "$("$TP" propose --graph "$TEST_TMPDIR/noest.json" --budget 5 2>&1 || true)" "#1 has no estimate"
  sample_graph
  assert_status 1 "$TP" propose --graph "$GRAPH"
  assert_status 1 "$TP" propose --graph "$GRAPH" --budget 0
}

test_split_moves_tickets_into_a_new_plan_after_the_original() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  "$TP" split "$PLANS" --graph "$GRAPH" 2 5
  assert_eq 3 "$(jq '.plans | length' "$PLANS")"
  assert_eq "3,4" "$(plan_of "$PLANS" 1)"
  assert_eq "5" "$(plan_of "$PLANS" 2)"
  assert_eq "export" "$(jq -r '.plans[2].slice' "$PLANS")"
}

test_split_that_puts_a_blocker_after_its_dependent_is_refused_and_changes_nothing() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  local before=; before=$(cat "$PLANS")
  # Moving 3 (blocks 4) out of plan 2 into a new plan after it puts 3 behind 4.
  assert_status 1 "$TP" split "$PLANS" --graph "$GRAPH" 2 3
  assert_contains "$("$TP" split "$PLANS" --graph "$GRAPH" 2 3 2>&1 || true)" "#4 (plan 2) would run before its blocker #3 (plan 3)"
  assert_eq "$before" "$(cat "$PLANS")" "plans file changed by a refused edit"
}

test_merge_joins_two_plans_and_renumbers() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 4 >"$PLANS"
  assert_eq 3 "$(jq '.plans | length' "$PLANS")"
  "$TP" merge "$PLANS" --graph "$GRAPH" 1 2
  assert_eq 2 "$(jq '.plans | length' "$PLANS")"
  assert_eq "1,2,3,4" "$(plan_of "$PLANS" 0)"
  assert_eq "upload, billing" "$(jq -r '.plans[0].slice' "$PLANS")"
  assert_status 1 "$TP" merge "$PLANS" --graph "$GRAPH" 1 1
  assert_status 1 "$TP" merge "$PLANS" --graph "$GRAPH" 1 9
}

test_merge_that_would_jump_a_plan_over_its_blocker_is_refused() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 4 >"$PLANS"   # [1,2] [3,4] [5]
  # Joining 5 into plan 1 puts 5 ahead of its blockers 4 (plan 2).
  assert_status 1 "$TP" merge "$PLANS" --graph "$GRAPH" 1 3
}

test_reorder_works_between_independent_plans_and_refuses_against_a_blocking_edge() {
  cat >"$TEST_TMPDIR/graph.json" <<'JSON'
{"tickets": {
  "1": {"title": "x", "slice": "X", "estimate_usd": 2},
  "2": {"title": "y", "slice": "Y", "estimate_usd": 2},
  "3": {"title": "z", "slice": "Z", "estimate_usd": 2, "blocked_by": ["2"]}
}}
JSON
  GRAPH="$TEST_TMPDIR/graph.json"; PLANS="$TEST_TMPDIR/plans.json"
  "$TP" propose --graph "$GRAPH" --budget 2 >"$PLANS"   # [1] [2] [3]
  "$TP" reorder "$PLANS" --graph "$GRAPH" 2,3,1
  assert_eq "2" "$(plan_of "$PLANS" 0)"
  assert_eq "1" "$(plan_of "$PLANS" 2)"
  local before=; before=$(cat "$PLANS")
  assert_status 1 "$TP" reorder "$PLANS" --graph "$GRAPH" 3,2,1
  assert_eq "$before" "$(cat "$PLANS")"
  assert_status 1 "$TP" reorder "$PLANS" --graph "$GRAPH" 1,2
}

test_move_a_ticket_between_plans() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 4 >"$PLANS"   # [1,2] [3,4] [5]
  assert_status 1 "$TP" move "$PLANS" --graph "$GRAPH" 5 1
  "$TP" move "$PLANS" --graph "$GRAPH" 4 3
  assert_eq "3" "$(plan_of "$PLANS" 1)"
  assert_eq "4,5" "$(plan_of "$PLANS" 2)"
}

test_the_approval_view_shows_every_tickets_acceptance_criteria_and_estimate() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  local view=; view=$("$TP" render "$PLANS" --graph "$GRAPH")
  assert_contains "$view" "| #1 (Upload endpoint) | none | \$2.00 | ☐ accepts a file<br>☐ rejects 10 MB+ |"
  assert_contains "$view" "☐ shows percent"
  assert_contains "$view" "☐ downloads a CSV"
  assert_contains "$view" 'tab lists invoices \| with totals'
  assert_contains "$view" "| #5 (Export CSV) | #2, #4 |"
  # Tickets are shown as tables, never as bulleted or numbered lists.
  ! printf '%s\n' "$view" | grep -E '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+#[0-9]' || fail "ticket list that is not a table"
}

test_the_view_warns_about_a_split_slice_and_an_outside_blocker() {
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  "$TP" split "$PLANS" --graph "$GRAPH" 2 4,5      # billing now spans plans 2 and 3
  jq '.tickets["1"].external_blockers = ["90"]' "$GRAPH" >"$GRAPH.tmp" && mv "$GRAPH.tmp" "$GRAPH"
  local view=; view=$("$TP" render "$PLANS" --graph "$GRAPH")
  assert_contains "$view" '| Slice "billing" | split across plans 2, 3'
  assert_contains "$view" "| #1 (Upload endpoint) | waits on #90"
}

# ---- the tracker half, against the fake gh ------------------------------

use_fake_gh() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  local n=
  for n in 1 2 3 4 5; do
    jq -n --argjson n "$n" --arg t "ticket $n" \
      '{number: $n, id: (1000 + $n), title: $t, state: "open", labels: [],
        body: "## What\nx\n\n## Acceptance criteria\n- [ ] first \($n)\n- [x] second \($n)\n\n## Other\n- [ ] not a criterion"}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '{number: 44, id: 1044, title: "Spec", state: "open", labels: [], body: "spec"}' >"$FAKE_GH_DIR/issue-44.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[1]' >"$FAKE_GH_DIR/blocked_by-3.json"
  echo '[3]' >"$FAKE_GH_DIR/blocked_by-4.json"
  echo '[2,4,60]' >"$FAKE_GH_DIR/blocked_by-5.json"
  jq -n '{number: 60, id: 1060, title: "elsewhere", state: "open", labels: [], body: ""}' >"$FAKE_GH_DIR/issue-60.json"
  jq -n '{number: 61, id: 1061, title: "done", state: "closed", labels: [], body: ""}' >"$FAKE_GH_DIR/issue-61.json"
}

test_graph_reads_titles_criteria_blockers_and_open_outside_blockers() {
  use_fake_gh
  echo '[2,4,60,61]' >"$FAKE_GH_DIR/blocked_by-5.json"
  "$TP" graph --repo local/sample 1 2 3 4 5 >"$TEST_TMPDIR/g.json"
  assert_eq "first 1,second 1" "$(jq -r '.tickets["1"].acceptance | join(",")' "$TEST_TMPDIR/g.json")"
  assert_eq "ticket 2" "$(jq -r '.tickets["2"].title' "$TEST_TMPDIR/g.json")"
  assert_eq "1" "$(jq -r '.tickets["2"].blocked_by | join(",")' "$TEST_TMPDIR/g.json")"
  assert_eq "2,4" "$(jq -r '.tickets["5"].blocked_by | join(",")' "$TEST_TMPDIR/g.json")"
  assert_eq "60" "$(jq -r '.tickets["5"].external_blockers | join(",")' "$TEST_TMPDIR/g.json")"
  assert_eq "null" "$(jq -c '.tickets["1"].external_blockers' "$TEST_TMPDIR/g.json")"
  assert_status 1 "$TP" graph --repo not-a-repo 1
}

publish_sample() {
  use_fake_gh
  sample_graph
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
}

test_publish_needs_approval_and_a_valid_plan() {
  publish_sample
  assert_status 1 "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample
  ! grep -qs 'issue create' "$FAKE_GH_DIR/calls" || fail "an issue was created without approval"
  jq '.plans = [{"slice":"x","tickets":["5"]},{"slice":"y","tickets":["1","2","3","4"]}]' "$PLANS" >"$PLANS.t" && mv "$PLANS.t" "$PLANS"
  assert_status 1 "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved
  ! grep -q 'issue create' "$FAKE_GH_DIR/calls" || fail "an invalid plan reached the tracker"
}

test_publish_creates_plan_issues_with_sub_issues_and_native_blocking() {
  publish_sample
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err"
  local p1= p2=
  p1=$(jq -r '.plans[0].issue' "$PLANS"); p2=$(jq -r '.plans[1].issue' "$PLANS")
  [ "$p1" -gt 60 ] && [ "$p2" -gt "$p1" ] || fail "plan issue numbers $p1 $p2"
  assert_eq '["plan"]' "$(jq -c '[.labels[].name]' "$FAKE_GH_DIR/issue-$p1.json")"
  assert_eq "Plan 1: upload" "$(jq -r .title "$FAKE_GH_DIR/issue-$p1.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$p1.json")" "- [ ] #1 (Upload endpoint)"
  assert_eq "[1,2]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-$p1.json")"
  assert_eq "[3,4,5]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-$p2.json")"
  # Plan 2 is blocked by plan 1, natively; plan 1 by nothing.
  assert_eq "[$p1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-$p2.json")"
  [ ! -f "$FAKE_GH_DIR/blocked_by-$p1.json" ] || fail "plan 1 should have no blockers"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "| Plan 2 | #$p2 | #3, #4, #5 |"
}

test_a_ticket_that_already_has_a_parent_keeps_it_unless_told_to_replace_it() {
  publish_sample
  echo 44 >"$FAKE_GH_DIR/parent-1"; echo '[1]' >"$FAKE_GH_DIR/sub_issues-44.json"
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved 2>"$TEST_TMPDIR/err" >/dev/null
  assert_contains "$(cat "$TEST_TMPDIR/err")" "#1 stays under its existing parent"
  local p1=; p1=$(jq -r '.plans[0].issue' "$PLANS")
  assert_eq "[2]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-$p1.json")"
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-44.json")" "the spec lost its child without --replace-parent"
}

test_replace_parent_moves_the_ticket_under_its_plan() {
  publish_sample
  echo 44 >"$FAKE_GH_DIR/parent-1"; echo '[1]' >"$FAKE_GH_DIR/sub_issues-44.json"
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved --replace-parent >/dev/null 2>&1
  local p1=; p1=$(jq -r '.plans[0].issue' "$PLANS")
  assert_eq "[1,2]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-$p1.json")"
  assert_eq "[]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-44.json")"
}

test_publish_twice_creates_nothing_new() {
  publish_sample
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>&1
  local creates=; creates=$(grep -c '^issue create' "$FAKE_GH_DIR/calls")
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>&1
  assert_eq "$creates" "$(grep -c '^issue create' "$FAKE_GH_DIR/calls")" "second publish created issues"
}

test_published_plans_cannot_be_edited_and_the_repo_must_be_owner_name() {
  publish_sample
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>&1
  assert_status 1 "$TP" split "$PLANS" --graph "$GRAPH" 2 5
  assert_status 1 "$TP" publish "$PLANS" --graph "$GRAPH" --repo sample --approved
}

# ---- resolve-scope.sh ----------------------------------------------------

scope_tracker() {
  publish_sample
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>&1
  P1=$(jq -r '.plans[0].issue' "$PLANS"); P2=$(jq -r '.plans[1].issue' "$PLANS")
}

test_a_plan_issue_stands_for_its_tickets() {
  scope_tracker
  local out=; out=$("$RS" --repo local/sample "$P1")
  assert_eq "1,2" "$(jq -r '.tickets | map(.number) | join(",")' <<<"$out")"
  assert_eq "$P1" "$(jq -r '.tickets[0].from' <<<"$out")"
}

test_several_plans_and_single_tickets_mix_without_duplicates() {
  scope_tracker
  local out=; out=$("$RS" --repo local/sample "$P2" 1 "#3" "$P1")
  # Order named: plan 2's tickets, then 1, then plan 1's remaining (2).
  assert_eq "3,4,5,1,2" "$(jq -r '.tickets | map(.number) | join(",")' <<<"$out")"
  assert_eq "$P2" "$(jq -r '.tickets[0].from' <<<"$out")"
  assert_eq "null" "$(jq -c '.tickets[3].from' <<<"$out")"
}

test_a_single_ticket_is_its_own_scope() {
  scope_tracker
  local out=; out=$("$RS" --repo local/sample 4)
  assert_eq "4" "$(jq -r '.tickets | map(.number) | join(",")' <<<"$out")"
  assert_eq "null" "$(jq -c '.tickets[0].from' <<<"$out")"
}

test_closed_tickets_are_skipped_and_outside_blocking_plans_reported() {
  scope_tracker
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-2.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-2.json"
  local out=; out=$("$RS" --repo local/sample "$P2")
  assert_eq "[]" "$(jq -c '.skipped' <<<"$out")"
  assert_eq "[{\"plan\":$P2,\"blocker\":$P1}]" "$(jq -c '.outside_blockers' <<<"$out")"
  out=$("$RS" --repo local/sample "$P1")
  assert_eq '[{"number":2,"reason":"closed"}]' "$(jq -c '.skipped' <<<"$out")"
  assert_eq "1" "$(jq -r '.tickets | map(.number) | join(",")' <<<"$out")"
  out=$("$RS" --repo local/sample "$P2" "$P1")
  assert_eq "[]" "$(jq -c '.outside_blockers' <<<"$out")"
}

test_a_plan_issue_with_a_task_list_and_no_sub_issues_still_resolves() {
  use_fake_gh
  jq -n '{number: 70, id: 1070, title: "Plan 1: x", state: "open", labels: [{name: "plan"}],
          body: "## Tickets\n- [ ] #1 (ticket 1)\n- [x] #2 (ticket 2)\n"}' >"$FAKE_GH_DIR/issue-70.json"
  local out=; out=$("$RS" --repo local/sample 70)
  assert_eq "1,2" "$(jq -r '.tickets | map(.number) | join(",")' <<<"$out")"
}

test_a_queued_request_plan_issue_is_not_a_plan_to_run() {
  use_fake_gh
  jq -n '{number: 71, id: 1071, title: "Plan: run tickets 5 and 6", state: "open", labels: [{name: "plan"}],
          body: "A run was requested while another run held the run lock.\n\nRequest: run tickets 5 and 6"}' >"$FAKE_GH_DIR/issue-71.json"
  assert_status 3 "$RS" --repo local/sample 71
  assert_contains "$("$RS" --repo local/sample 71 2>&1 || true)" "queued request"
}

test_resolve_scope_refuses_bad_usage() {
  use_fake_gh
  assert_status 2 "$RS" --repo local/sample
  assert_status 1 "$RS" --repo sample 1
  assert_status 1 "$RS" --repo local/sample abc
  assert_status 1 "$RS" --repo local/sample 999
}

# ---- the skill's text -----------------------------------------------------

test_to_plan_skill_has_frontmatter_and_cites_the_shared_files() {
  [ "$(sed -n 1p "$SKILL")" = "---" ] || fail "no frontmatter"
  grep -q '^name: to-plan$' "$SKILL" || fail "name"
  grep -q '^description: .\{20,\}' "$SKILL" || fail "description"
  local body=; body=$(cat "$SKILL")
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/ARTISAN.md'
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh'
  assert_contains "$body" "to-plan.sh split"
  assert_contains "$body" "to-plan.sh merge"
  assert_contains "$body" "to-plan.sh reorder"
  assert_contains "$body" "acceptance criteria"
  assert_contains "$body" "--approved"
}

test_to_plan_skill_shows_tickets_as_tables_and_never_in_lists() {
  ! grep -n -E '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+#[0-9]' "$SKILL" || fail "a ticket list that is not a table"
  assert_contains "$(cat "$SKILL")" "| Ticket |"
}

test_to_plan_skill_uses_glossary_words() {
  local hits=
  hits=$(grep -n -i -w 'batch\|milestone\|sprint\|workflow' "$SKILL" || true)
  assert_eq "" "$hits"
}

test_implement_plan_resolves_plan_issues_and_points_at_the_reference() {
  local skill=; skill=$(cat "$PLUGIN_ROOT/skills/implement-plan/SKILL.md")
  assert_contains "$skill" 'scripts/resolve-scope.sh'
  assert_contains "$skill" 'references/plan-issues.md'
  [ -f "$PLUGIN_ROOT/skills/implement-plan/references/plan-issues.md" ] || fail "reference missing"
}

# ---- tracker failures stop loudly (#102) ---------------------------------
# A wrapper in front of the fake gh fails any call whose arguments match
# FAIL_GH_MATCH (a shell glob), with the given exit and message; the rest pass
# through, so a test can fail exactly one read or write.

fail_gh_on() { # glob [message]
  local d="$TEST_TMPDIR/failgh"
  mkdir -p "$d"
  cat >"$d/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  \$FAIL_GH_MATCH) echo "\${FAIL_GH_SAY:-gh: HTTP 500}" >&2; exit 1 ;;
esac
exec "$TESTS_DIR/fixtures/fake-gh/gh" "\$@"
SH
  chmod +x "$d/gh"
  PATH="$d:$PATH"
  export PATH
  export FAIL_GH_MATCH="$1" FAIL_GH_SAY="${2:-gh: HTTP 500}"
}

test_graph_stops_naming_the_issue_when_the_blocked_by_read_fails() {
  use_fake_gh
  fail_gh_on '*issues/3/dependencies/blocked_by*'
  local rc=0
  "$TP" graph --repo local/sample 1 2 3 4 5 >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "graph exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot read the blockers of #3"
  assert_eq "" "$(cat "$TEST_TMPDIR/out")" "a partial graph was printed"
}

test_resolve_scope_stops_naming_the_plan_when_the_blocked_by_read_fails() {
  scope_tracker
  fail_gh_on "*issues/$P2/dependencies/blocked_by*"
  local rc=0
  "$RS" --repo local/sample "$P1" "$P2" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve-scope exited 0"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot read the blockers of plan #$P2"
  assert_eq "" "$(cat "$TEST_TMPDIR/out")" "a partial scope was printed"
}

test_resolve_scope_stops_naming_the_plan_when_the_sub_issues_read_fails() {
  scope_tracker
  fail_gh_on "*issues/$P1/sub_issues*"
  local rc=0
  "$RS" --repo local/sample "$P1" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve-scope exited 0"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot read the sub-issues of plan #$P1"
  assert_eq "" "$(cat "$TEST_TMPDIR/out")" "a partial scope was printed"
}

test_publish_stops_when_a_sub_issue_attach_fails_for_any_other_reason() {
  publish_sample
  fail_gh_on '*--method POST*sub_issues*' 'gh: HTTP 502 bad gateway'
  local rc=0
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "publish exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "could not make #1 a sub-issue of #"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "running publish again"
}

test_publish_stops_when_a_blocking_write_fails_for_any_other_reason() {
  publish_sample
  fail_gh_on '*--method POST*dependencies/blocked_by*' 'gh: HTTP 502 bad gateway'
  local rc=0
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "publish exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "could not block #"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "running publish again"
}

test_publish_stops_on_its_own_when_the_issue_id_lookup_fails() {
  publish_sample
  fail_gh_on '*api repos/local/sample/issues/1'
  local rc=0
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "publish exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot look up the id of #1"
  ! grep -q -- '--method POST' "$FAKE_GH_DIR/calls" || fail "a write was attempted after the failed lookup"
}

test_publish_stops_when_the_issue_lookup_returns_no_id() {
  publish_sample
  # gh succeeds but the answer carries no id: a stub that prints {}.
  local d="$TEST_TMPDIR/noid"; mkdir -p "$d"
  cat >"$d/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  "api repos/local/sample/issues/1") echo '{}' ;;
  *) exec "$TESTS_DIR/fixtures/fake-gh/gh" "\$@" ;;
esac
SH
  chmod +x "$d/gh"
  PATH="$d:$PATH"
  local rc=0
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "publish exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "returned no id for #1"
  ! grep -q -- '--method POST' "$FAKE_GH_DIR/calls" || fail "a write was attempted after the empty lookup"
}

# ---- resolve-scope.sh: each ticket's blocked_by ---------------------------

test_resolve_scope_returns_each_tickets_open_blockers_even_outside_the_scope() {
  use_fake_gh
  echo '[1,44]' >"$FAKE_GH_DIR/blocked_by-2.json"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-44.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-44.json"
  echo '[1,5]' >"$FAKE_GH_DIR/blocked_by-3.json"
  local out=; out=$("$RS" --repo local/sample 1 2 3)
  assert_eq "[]" "$(jq -c '.tickets[0].blocked_by' <<<"$out")"
  assert_eq "[1]" "$(jq -c '.tickets[1].blocked_by' <<<"$out")" "closed blocker 44 left out"
  assert_eq "[1,5]" "$(jq -c '.tickets[2].blocked_by' <<<"$out")" "open blocker 5 is outside the scope but listed"
}

test_resolve_scope_falls_back_to_the_body_line_where_there_are_no_native_dependencies() {
  use_fake_gh
  rm -f "$FAKE_GH_DIR"/blocked_by-*.json
  jq '.body = "Blocked by: #1, #44\n\n## What\nx"' "$FAKE_GH_DIR/issue-2.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-2.json"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-44.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-44.json"
  fail_gh_on '*dependencies/blocked_by*' "gh: Not Found (HTTP 404)"
  local out=; out=$("$RS" --repo local/sample 1 2)
  assert_eq "[]" "$(jq -c '.tickets[0].blocked_by' <<<"$out")"
  assert_eq "[1]" "$(jq -c '.tickets[1].blocked_by' <<<"$out")" "closed #44 left out"
}

set_body() { # issue body
  jq --arg b "$(printf '%b' "$2")" '.body = $b' "$FAKE_GH_DIR/issue-$1.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-$1.json"
}

test_resolve_scope_reads_a_blocked_by_heading_section_where_there_are_no_native_dependencies() {
  use_fake_gh
  rm -f "$FAKE_GH_DIR"/blocked_by-*.json
  set_body 2 "## What\nx\n\n## Blocked by\n\n- #1\n- #44 (done)\n* #5\n#4\n\n## Acceptance criteria\n- [ ] sees #3 here"
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-44.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-44.json"
  fail_gh_on '*dependencies/blocked_by*' "gh: Not Found (HTTP 404)"
  local out=; out=$("$RS" --repo local/sample 1 2)
  assert_eq "[]" "$(jq -c '.tickets[0].blocked_by' <<<"$out")"
  assert_eq "[1,5,4]" "$(jq -c '.tickets[1].blocked_by' <<<"$out")" "open refs under the heading only (a bare #4 line is a ref, not a heading); #44 closed, #3 is under another heading"
}

test_resolve_scope_reads_a_plan_issues_body_blockers_where_there_are_no_native_dependencies() {
  scope_tracker
  jq -n '{number: 70, id: 1070, title: "Other plan", state: "open", labels: [{name: "plan"}], body: ""}' >"$FAKE_GH_DIR/issue-70.json"
  jq -n '{number: 71, id: 1071, title: "Old plan", state: "closed", labels: [{name: "plan"}], body: ""}' >"$FAKE_GH_DIR/issue-71.json"
  set_body "$P2" "Plan two\n\n## Blocked by\n\n- #70\n- #71\n- #$P1\n"
  fail_gh_on "*issues/$P2/dependencies/blocked_by*" "gh: Not Found (HTTP 404)"
  local out=; out=$("$RS" --repo local/sample "$P1" "$P2")
  assert_eq "[{\"plan\":$P2,\"blocker\":70}]" "$(jq -c '.outside_blockers' <<<"$out")" "open unnamed plan 70 listed; closed 71 and named $P1 not"
}

test_resolve_scope_reads_a_plan_issues_blocked_by_line_where_there_are_no_native_dependencies() {
  scope_tracker
  jq -n '{number: 70, id: 1070, title: "Other plan", state: "open", labels: [{name: "plan"}], body: ""}' >"$FAKE_GH_DIR/issue-70.json"
  set_body "$P2" "Blocked by: #70\n\nPlan two"
  fail_gh_on "*issues/$P2/dependencies/blocked_by*" "gh: Not Found (HTTP 404)"
  local out=; out=$("$RS" --repo local/sample "$P2")
  assert_eq "[{\"plan\":$P2,\"blocker\":70}]" "$(jq -c '.outside_blockers' <<<"$out")"
}

test_resolve_scope_fails_naming_the_plan_when_its_body_blocker_cannot_be_read() {
  scope_tracker
  set_body "$P2" "Blocked by: #999"
  fail_gh_on "*issues/$P2/dependencies/blocked_by*" "gh: Not Found (HTTP 404)"
  local rc=0
  "$RS" --repo local/sample "$P2" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 1 "$rc" "exit"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot read the blockers of plan #$P2"
}

test_resolve_scope_fails_naming_the_ticket_when_a_blocker_read_fails() {
  use_fake_gh
  fail_gh_on '*issues/2/dependencies/blocked_by*'
  local rc=0
  "$RS" --repo local/sample 1 2 >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve-scope exited 0"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "cannot read the blockers of #2"
  assert_eq "" "$(cat "$TEST_TMPDIR/out")" "a partial scope was printed"
}

# ---- Human checks (#156) ---------------------------------------------------

# The sample graph with one in-game criterion on #2.
human_graph() {
  sample_graph
  jq '.tickets["2"].acceptance += ["contract keys stay stable, checked in game"]' "$GRAPH" >"$GRAPH.t" && mv "$GRAPH.t" "$GRAPH"
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
}

test_check_flags_an_agent_criterion_checked_in_game_and_refuses_approval() {
  human_graph
  local out=
  assert_status 1 "$TP" check "$PLANS" --graph "$GRAPH"
  out=$("$TP" check "$PLANS" --graph "$GRAPH" 2>&1 || true)
  assert_contains "$out" "## Needs your attention"
  assert_contains "$out" "| #2 (Upload progress) | criterion \"contract keys stay stable, checked in game\" reads as needing a person (\"in game\")"
  assert_contains "$out" "split-human-check"
  assert_contains "$out" "not ready to approve"
  assert_contains "$("$TP" render "$PLANS" --graph "$GRAPH")" "| #2 (Upload progress) | criterion \"contract keys stay stable"
  use_fake_gh
  assert_status 1 "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved
  ! grep -q 'issue create' "$FAKE_GH_DIR/calls" || fail "a plan with a flagged criterion reached the tracker"
}

test_phrases_match_whole_words_case_insensitively_and_a_project_adds_its_own() {
  sample_graph
  jq '.tickets["1"].acceptance = ["Visually matches the mockup", "the gameplay loop runs in games tests", "works on the console"]' \
    "$GRAPH" >"$GRAPH.t" && mv "$GRAPH.t" "$GRAPH"
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  local out=; out=$("$TP" render "$PLANS" --graph "$GRAPH")
  assert_contains "$out" "\"Visually matches the mockup\" reads as needing a person"
  assert_not_contains "$out" "runs in games tests\" reads"
  assert_not_contains "$out" "works on the console\" reads"
  printf 'human_check_phrases: [on the console]\n' >"$TEST_TMPDIR/config.yml"
  assert_contains "$("$TP" render "$PLANS" --graph "$GRAPH" --config "$TEST_TMPDIR/config.yml")" \
    "\"works on the console\" reads as needing a person (\"on the console\")"
}

test_a_human_check_is_in_its_agent_tickets_plan_unestimated_and_never_flagged() {
  sample_graph
  jq '.tickets["6"] = {"title": "Human check: Upload progress (#2)", "human_check_for": "2", "blocked_by": ["2"],
                       "acceptance": ["percent looks right in game"]}' "$GRAPH" >"$GRAPH.t" && mv "$GRAPH.t" "$GRAPH"
  "$TP" propose --graph "$GRAPH" --budget 6 >"$PLANS"
  assert_eq "1,2,6" "$(plan_of "$PLANS" 0)" "the Human check joins its agent ticket's plan"
  "$TP" check "$PLANS" --graph "$GRAPH"
  local view=; view=$("$TP" render "$PLANS" --graph "$GRAPH")
  assert_contains "$view" "| #6 (Human check: Upload progress (#2)) | #2 | not estimated (Human check for #2) | ☐ percent looks right in game |"
  assert_contains "$view" "| Plan 1 | upload | 3 | \$4.00 of \$6.00 | nothing |"
  assert_not_contains "$view" "Needs your attention"
  # Moving it away from its agent ticket is refused.
  assert_status 1 "$TP" move "$PLANS" --graph "$GRAPH" 6 2
}

human_tracker() {
  use_fake_gh
  jq '.body = "## What\nx\n\n## Acceptance criteria\n- [ ] shows percent\n- [ ] contract keys stay stable, checked in game\n- [ ] snapshots recorded in a career, by hand\n\n## Blocked by\n- #1"' \
    "$FAKE_GH_DIR/issue-2.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-2.json"
  human_graph
}

test_split_moves_the_criterion_into_a_human_check_ticket_once() {
  human_tracker
  local out= hc= body=
  out=$("$TP" split-human-check --repo local/sample --graph "$GRAPH" --plans "$PLANS" 2 "contract keys stay stable, checked in game")
  hc=$(jq -r '[.[]] | max_by(.number) | .number' <<<"$(jq -s . "$FAKE_GH_DIR"/issue-*.json)")
  assert_contains "$out" "Human check #$hc for #2"
  assert_eq "Human check: ticket 2 (#2)" "$(jq -r .title "$FAKE_GH_DIR/issue-$hc.json")"
  assert_eq '["ready-for-human"]' "$(jq -c '[.labels[].name]' "$FAKE_GH_DIR/issue-$hc.json")"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$hc.json")
  assert_eq "<!-- artisan-agent:human-check-for #2 -->" "$(printf '%s\n' "$body" | head -1)"
  assert_contains "$body" "## What to check"
  assert_contains "$body" "- [ ] contract keys stay stable, checked in game"
  assert_contains "$body" "## Blocked by"
  assert_eq "[2]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-$hc.json")" "the agent ticket blocks the Human check natively"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-2.json")
  assert_not_contains "$body" "checked in game"
  assert_contains "$body" "- [ ] shows percent"
  assert_contains "$body" "## Blocked by"
  # The graph and the plan follow; the flag is gone, so check passes.
  assert_eq "2" "$(jq -r --arg h "$hc" '.tickets[$h].human_check_for' "$GRAPH")"
  assert_not_contains "$(jq -r '.tickets["2"].acceptance | join("|")' "$GRAPH")" "in game"
  assert_contains "$(plan_of "$PLANS" 0)" "$hc"
  "$TP" check "$PLANS" --graph "$GRAPH"
  # Twice: nothing new.
  local calls=; calls=$(grep -c '^issue \(create\|edit\)' "$FAKE_GH_DIR/calls")
  "$TP" split-human-check --repo local/sample --graph "$GRAPH" --plans "$PLANS" 2 "contract keys stay stable, checked in game" >/dev/null
  assert_eq "$calls" "$(grep -c '^issue \(create\|edit\)' "$FAKE_GH_DIR/calls")" "a repeat wrote to the tracker"
  assert_eq 1 "$(jq -r .body "$FAKE_GH_DIR/issue-$hc.json" | grep -c 'checked in game')"
  assert_eq 1 "$(jq --arg h "$hc" '[.plans[].tickets[] | select(. == $h)] | length' "$PLANS")"
}

test_a_second_split_adds_to_the_existing_human_check() {
  human_tracker
  "$TP" split-human-check --repo local/sample --graph "$GRAPH" 2 "checked in game" >/dev/null
  local before=; before=$(ls "$FAKE_GH_DIR"/issue-*.json | wc -l)
  "$TP" split-human-check --repo local/sample --graph "$GRAPH" 2 "by hand" >/dev/null
  assert_eq "$before" "$(ls "$FAKE_GH_DIR"/issue-*.json | wc -l)" "a second Human check was created"
  local hc=; hc=$(jq -r 'to_entries[] | select(.value.human_check_for == "2") | .key' <<<"$(jq .tickets "$GRAPH")")
  local body=; body=$(jq -r .body "$FAKE_GH_DIR/issue-$hc.json")
  assert_contains "$body" "- [ ] contract keys stay stable, checked in game
- [ ] snapshots recorded in a career, by hand"
  assert_eq 2 "$(jq --arg h "$hc" '.tickets[$h].acceptance | length' "$GRAPH")"
  assert_status 1 "$TP" split-human-check --repo local/sample --graph "$GRAPH" 2 "no such criterion"
}

test_an_override_with_a_reason_lets_approval_through_and_is_recorded_on_the_plan() {
  human_tracker
  assert_status 1 "$TP" check "$PLANS" --graph "$GRAPH" --override-human-check 2 "checked in game"
  "$TP" check "$PLANS" --graph "$GRAPH" --override-human-check 2 "checked in game" --why "the save test covers it"
  assert_eq "contract keys stay stable, checked in game|the save test covers it" \
    "$(jq -r '.human_check_overrides[] | "\(.criterion)|\(.why)"' "$PLANS")"
  assert_contains "$("$TP" render "$PLANS" --graph "$GRAPH")" \
    "| #2 | contract keys stay stable, checked in game | the save test covers it |"
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved >/dev/null 2>&1
  local p1=; p1=$(jq -r '.plans[0].issue' "$PLANS")
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$p1.json")" \
    "- #2: \"contract keys stay stable, checked in game\" stays on the agent ticket. Why: the save test covers it"
}

test_publish_takes_the_override_at_approval() {
  human_tracker
  "$TP" publish "$PLANS" --graph "$GRAPH" --repo local/sample --approved \
    --override-human-check 2 "contract keys stay stable, checked in game" --why "covered by a test" >/dev/null 2>&1
  assert_eq "covered by a test" "$(jq -r '.human_check_overrides[0].why' "$PLANS")"
  [ "$(jq -r '.plans[0].issue' "$PLANS")" != null ] || fail "the override did not let publish through"
}
