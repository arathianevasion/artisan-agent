# A criterion about CI, the merge gate or the PR (#174): a run can't judge
# it, since workers never open PRs and the merge gate runs after the
# verifier. The verifier marks it "gate" (and the judge reads one that says
# so plainly as "gate" whatever the verifier said), the ticket passes on its
# other criteria, and wave.sh merge's gate is what satisfies it: green merges
# and ticks it, red still fails the ticket. The shipped ticket-writing
# guidance never suggests one. Built on verify.test.sh's run (fake `claude`,
# fake `gh` over a folder tracker); nothing reaches GitHub.

. "$TESTS_DIR/verify.test.sh"
# Only this file's tests run here; verify.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_g_/ {print $3}'); do unset -f "$_f"; done
unset _f

CRITERIA_PY="$PLUGIN_ROOT/scripts/lib/criteria.py"

# Ticket 1 gets a third criterion, $1, the one the merge gate covers.
gate_ticket() { # criterion
  setup_wave
  jq --arg c "$1" '.body = "## Acceptance criteria\n- [ ] hello.txt exists\n- [ ] It says hi\n- [ ] \($c)\n"' \
    "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/issue-1.tmp"
  mv "$FAKE_GH_DIR/issue-1.tmp" "$FAKE_GH_DIR/issue-1.json"
  returned_ticket
}

judge_once() {
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier "${1:-1}"
}

test_g_align_keeps_a_gate_criterion_apart_from_met_unmet_and_human() {
  echo '["A thing", "B thing", "C thing", "D thing"]' >c.json
  echo '{"acceptance": [{"criterion": "A thing", "met": true},
    {"criterion": "B thing", "met": "gate", "evidence": {"why": "only the merge gate shows it"}},
    {"criterion": "C thing", "met": "human"},
    {"criterion": "D thing", "met": false}]}' >v.json
  assert_eq '[[true,null,null],[false,true,null],[false,null,true],[false,null,null]]' \
    "$(python3 -I "$CRITERIA_PY" align c.json v.json missing.json | jq -c 'map([.met, .gate, .human])')"
}

test_g_a_criterion_that_reads_as_the_merge_gates_is_gate_whatever_the_verifier_said() {
  echo '["CI is green on the PR", "the run'"'"'s merge gate is green", "The PR shows the review notes", "A red merge gate fails the ticket"]' >c.json
  echo '{"acceptance": [{"criterion": "CI is green on the PR", "met": true},
    {"criterion": "the run'"'"'s merge gate is green", "met": false, "evidence": {"why": "no CI run exists for this commit"}},
    {"criterion": "The PR shows the review notes", "met": false},
    {"criterion": "A red merge gate fails the ticket", "met": true}]}' >v.json
  assert_eq '[[false,true],[false,true],[false,true],[true,null]]' \
    "$(python3 -I "$CRITERIA_PY" align c.json v.json missing.json | jq -c 'map([.met, .gate])')"
}

test_g_a_quoted_merge_gate_phrase_is_about_one_not_one_itself() {
  printf '%s\n' '- [ ] A ticket whose only unmet criterion is "CI is green on the PR" passes' \
    '- [ ] CI'"'"'s `check` job is green on the PR' '- [ ] hello.txt exists' >b.md
  assert_eq '["CI'"'"'s `check` job is green on the PR"]' "$(python3 -I "$CRITERIA_PY" merge-gate <b.md | jq -c .)"
}

test_g_a_criterion_about_code_that_runs_ci_or_a_merge_gate_is_the_verifiers_to_judge() {
  local c=
  for c in "wave.sh merge blocks the ticket when CI is not green" "When CI passes, merge-gate.sh merges the PR" \
    "the merge gate passes when the suite is green" "a CI run that succeeds marks the ticket merged" \
    "gate.sh end writes the PR body; the PR shows the packet" "The PR has a description" \
    "A red merge gate still fails the ticket, through the merge gate"; do
    printf -- '- [ ] %s\n' "$c" >b.md
    assert_eq "[]" "$(python3 -I "$CRITERIA_PY" merge-gate <b.md | jq -c .)" "$c"
  done
  for c in "CI is green on the PR" "the run's merge gate is green" "The PR lists the changed files" "CI is green."; do
    printf -- '- [ ] %s\n' "$c" >b.md
    assert_eq "1" "$(python3 -I "$CRITERIA_PY" merge-gate <b.md | jq length)" "$c"
  done
}

test_g_a_ticket_whose_only_unmet_criterion_is_ci_on_the_pr_passes_and_the_merge_gate_satisfies_it() {
  gate_ticket "CI is green on the PR"
  export VERIFIER_UNMET="CI is green on the PR"
  judge_once
  assert_eq 0 "$JUDGE_STATUS"
  assert_eq "pass 2/3, 1 to the merge gate" "$JUDGE_OUT"
  assert_eq "[]" "$(state_get '.tickets["1"].failures | tostring')"
  assert_eq "pass 2 1" "$(state_get '.tickets["1"].evidence | "\(.verdict) \(.criteria_met) \(.criteria_gate)"')"
  assert_eq "false true" "$(state_get '.tickets["1"].evidence.acceptance[2] | "\(.met) \(.gate)"')"
  assert_eq '["CI is green on the PR"]' "$(state_get '[.events[] | select(.event == "verified")][-1].gate' | jq -c .)"
  # Judging again says the same.
  assert_eq "pass 2/3, 1 to the merge gate" "$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1)"
  # The merge gate is what satisfies it: green, it is ticked with the others.
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  "$SCRIPTS/wave.sh" close "$RUN_DIR" 1 >/dev/null
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [x] CI is green on the PR"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "| CI is green on the PR | checked by the merge gate: green |"
  # The slice gate's packet names it with the merge gate's result.
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  merge_gate_local "$ARTISAN_HOME"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = [{kind: "slice", slice: "hello", tickets: ["1"]}, {kind: "end"}]'
  local num= body=
  num=$("$SCRIPTS/gate.sh" open "$RUN_DIR" slice-1)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_contains "$body" "| #1 | CI is green on the PR | checked by the merge gate (run r1): green |"
}

test_g_the_packet_names_a_ci_gates_run_and_one_not_run_yet() {
  local view=
  view=$(jq -n '{gate: {kind: "slice", title: "Slice", tickets: ["1", "2"]},
    state: {run_id: "p1", plan: {tickets: {}}, tickets: {
      "1": {status: "merged", suite: {passed: true, mode: "ci", run_id: 42, url: "https://ci/42"},
            evidence: {acceptance: [{criterion: "CI is green", met: false, gate: true, evidence: {}}]}},
      "2": {status: "returned", evidence: {acceptance: [{criterion: "merge gate green", met: false, gate: true, evidence: {}}]}}}}}')
  local body=
  body=$(printf '%s' "$view" | python3 -I "$PLUGIN_ROOT/scripts/lib/packet.py" body)
  assert_contains "$body" "| #1 | CI is green | checked by the merge gate (run p1): green, CI run 42 (https://ci/42) |"
  assert_contains "$body" "| #2 | merge gate green | checked by the merge gate (run p1): not run yet |"
}

# Two verifiers on the same "merge gate is green" criterion: one calls it
# met, the other unmet for want of a CI run (#220 and #175 against #154).
# Both give gate.
gate_twice() { # verifier-unmet
  gate_ticket "the run's merge gate is green"
  export VERIFIER_UNMET="$1"
  judge_once
  assert_eq "pass 2/3, 1 to the merge gate" "$JUDGE_OUT"
  assert_eq "false true" "$(state_get '.tickets["1"].evidence.acceptance[2] | "\(.met) \(.gate)"')"
}
test_g_a_verifier_that_calls_the_merge_gate_criterion_met_gives_gate() { gate_twice ""; }
test_g_a_verifier_that_finds_no_ci_run_for_the_merge_gate_criterion_gives_gate() { gate_twice "the run's merge gate is green"; }

test_g_the_verifier_may_mark_another_criterion_gate() {
  gate_ticket "the release workflow publishes the tag"
  export VERIFIER_GATE="the release workflow publishes the tag"
  judge_once
  assert_eq "pass 2/3, 1 to the merge gate" "$JUDGE_OUT"
}

test_g_a_red_merge_gate_still_fails_the_ticket() {
  export WORKER_FILE=BROKEN
  gate_ticket "CI is green on the PR"
  judge_once
  assert_eq "pass 2/3, 1 to the merge gate" "$JUDGE_OUT"
  assert_status 7 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "nothing merged"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [ ] CI is green on the PR"
}

test_g_a_gate_criterion_does_not_save_an_unmet_one_and_the_retry_is_told() {
  gate_ticket "CI is green on the PR"
  export VERIFIER_UNMET="It says hi"
  judge_once
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 1/3 retry: It says hi" "$JUDGE_OUT"
  assert_contains "$(state_get '.tickets["1"].failures[-1].reason')" "the verifier found 1 of 3 criteria unmet, first: It says hi"
  local prompt=
  prompt=$("$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null; cat "$RUN_DIR/prompts/1.2.md")
  assert_contains "$prompt" "- Unmet (verifier): It says hi"
  assert_contains "$prompt" "- Checked by the merge gate, not yours to meet (verifier): CI is green on the PR"
  assert_not_contains "$prompt" "- Unmet (verifier): CI is green on the PR"
}

test_g_a_red_recorded_check_no_criterion_cites_leaves_nothing_to_the_merge_gate() {
  setup_wave
  record_checks
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF2'
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
eval "$(sed -n 's/^    \$ //p' "$ARTISAN_RUN_DIR/prompts/$key.md")" >/dev/null || true
jq '{acceptance: [.[] | {criterion: ., met: "gate", evidence: {why: "the merge gate shows it"}}]}' \
  "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF2
  export WORKER_FILE=BROKEN
  returned_ticket
  judge_once
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 0/2 retry: hello.txt exists" "$JUDGE_OUT"
}

test_g_the_verifier_prompt_and_brief_say_what_is_gate_with_examples() {
  gate_ticket "CI is green on the PR"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  local prompt=
  prompt=$(cat "$RUN_DIR/prompts/verify-1.1.md")
  assert_contains "$prompt" '"met": "gate"'
  assert_contains "$prompt" '"CI green"'
  assert_contains "$prompt" '"the PR shows'
  assert_contains "$prompt" '"merge gate green"'
  judge_verifier 1
  local brief="$PLUGIN_ROOT/skills/implement-plan/references/verifier.md"
  assert_contains "$(cat "$brief")" '"met": "gate"'
  assert_contains "$(cat "$PLUGIN_ROOT/references/evidence-contract.md")" "## Checked by the merge gate"
}

test_g_the_shipped_ticket_writing_guidance_suggests_no_pr_or_ci_criterion() {
  local f= hits=
  while IFS= read -r f; do
    hits=$(python3 -I "$CRITERIA_PY" merge-gate <"$f")
    [ "$hits" = "[]" ] || fail "$f suggests a criterion only the merge gate can check: $hits"
  done < <(find "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/references" "$PLUGIN_ROOT/templates" -type f -name '*.md')
  # It says what to write instead.
  local g=
  for g in skills/triage/AGENT-BRIEF.md skills/to-plan/SKILL.md references/human-checks.md; do
    assert_contains "$(cat "$PLUGIN_ROOT/$g")" "docs/review/<n>/" "$g"
  done
}
