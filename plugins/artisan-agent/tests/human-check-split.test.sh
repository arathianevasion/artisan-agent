# A criterion only a person can verify (#158, references/human-checks.md):
# the verifier marks it "human", the judge passes the ticket on its other
# criteria, never as a failed attempt, and splits the person-only criteria
# into one Human check ticket in the run's scope, which the next slice gate
# lists. Built on verify.test.sh's run (fake `claude`, fake `gh` over a
# folder tracker); nothing reaches GitHub.

. "$TESTS_DIR/verify.test.sh"
# Only this file's tests run here; verify.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_h_/ {print $3}'); do unset -f "$_f"; done
unset _f

test_h_align_keeps_a_criterion_needing_a_human_check_apart_from_met_and_unmet() {
  local py="$PLUGIN_ROOT/scripts/lib/criteria.py"
  echo '["A thing", "B thing", "C thing"]' >c.json
  echo '{"acceptance": [{"criterion": "A thing", "met": true},
    {"criterion": "B thing", "met": "human", "evidence": {"why": "only play shows it"}},
    {"criterion": "C thing", "met": false, "human": true}]}' >v.json
  assert_eq '[[true,null],[false,true],[false,null]]' \
    "$(python3 -I "$py" align c.json v.json missing.json | jq -c 'map([.met, .human])')"
  assert_eq "only play shows it" "$(python3 -I "$py" align c.json v.json missing.json | jq -r '.[1].evidence.why')"
}

# The verifier marks VERIFIER_HUMAN's criteria "human" and the rest met.
judge_human() { # human-criteria
  setup_wave
  returned_ticket
  export VERIFIER_HUMAN="$1"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
}

test_h_a_criterion_needing_a_human_check_passes_the_ticket_without_a_failed_attempt() {
  judge_human "It says hi"
  assert_eq 0 "$JUDGE_STATUS"
  assert_eq "pass 1/2, 1 to Human check #3" "$JUDGE_OUT"
  assert_eq "[]" "$(state_get '.tickets["1"].failures | tostring')"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq "pass 1 1" "$(state_get '.tickets["1"].evidence | "\(.verdict) \(.criteria_met) \(.criteria_human)"')"
  assert_eq "false true" "$(state_get '.tickets["1"].evidence.acceptance[1] | "\(.met) \(.human)"')"
  # Merged, the agent ticket is closed with the met criterion ticked and the
  # moved one gone from it: it is the Human check's now.
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  "$SCRIPTS/wave.sh" close "$RUN_DIR" 1 >/dev/null
  local body=
  body=$(jq -r .body "$FAKE_GH_DIR/issue-1.json")
  assert_contains "$body" "- [x] hello.txt exists"
  assert_not_contains "$body" "It says hi"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "| It says hi | needs a human check (#3) | only play shows it |"
}

test_h_the_pass_splits_the_human_criteria_into_one_human_check_once() {
  judge_human "It says hi"
  local hc="$FAKE_GH_DIR/issue-3.json"
  [ -f "$hc" ] || fail "no Human check ticket"
  assert_eq "Human check: Add hello (#1)" "$(jq -r .title "$hc")"
  assert_contains "$(jq -r .body "$hc")" "<!-- artisan-agent:human-check-for #1 -->"
  assert_contains "$(jq -r .body "$hc")" "- [ ] It says hi"
  assert_eq ready-for-human "$(jq -r '.labels | map(.name) | join(",")' "$hc")"
  assert_eq "[1]" "$(jq -c . "$FAKE_GH_DIR/blocked_by-3.json")"
  # In the run's scope, as a Human check of #1, open.
  assert_eq true "$(state_get '.plan.scope | index("3") != null')"
  assert_eq "1 queued" "$(state_get '.tickets["3"] | "\(.human_check.for) \(.status)"')"
  assert_eq '[{"ticket":"1","criteria":["It says hi"],"human_check":"3"}]' \
    "$(state_get '[.events[] | select(.event == "human-check-split") | {ticket, criteria, human_check}]' | jq -c .)"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "moved to Human check #3"
  # Judging again says the same and splits nothing more.
  local again=
  again=$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1)
  assert_eq "pass 1/2, 1 to Human check #3" "$again"
  [ ! -f "$FAKE_GH_DIR/issue-4.json" ] || fail "a second Human check was created"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "human-check-split")] | length')"
}

test_h_a_criterion_needing_a_human_check_does_not_save_an_unmet_one() {
  export VERIFIER_UNMET="hello.txt exists"
  judge_human "It says hi"
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 0/2 retry: hello.txt exists" "$JUDGE_OUT"
  assert_contains "$(state_get '.tickets["1"].failures[-1].reason')" "the verifier found 1 of 2 criteria unmet, first: hello.txt exists"
  [ ! -f "$FAKE_GH_DIR/issue-3.json" ] || fail "a failed attempt split a Human check"
  assert_eq 0 "$(state_get '[.events[] | select(.event == "human-check-split")] | length')"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "- [ ] It says hi" "the criterion stays on the ticket"
  # The fresh worker is told what to meet, and what is not its to meet.
  local prompt=
  prompt=$("$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null; cat "$RUN_DIR/prompts/1.2.md")
  assert_contains "$prompt" "- Unmet (verifier): hello.txt exists"
  assert_contains "$prompt" "- Needs a human check, not yours to meet (verifier): It says hi"
  assert_not_contains "$prompt" "- Unmet (verifier): It says hi"
}

test_h_a_ticket_whose_criteria_all_need_a_human_check_passes_with_a_note() {
  judge_human "hello.txt exists|It says hi"
  assert_eq 0 "$JUDGE_STATUS"
  assert_eq "pass 0/2, 2 to Human check #3" "$JUDGE_OUT"
  assert_contains "$(state_get '.tickets["1"].evidence.note')" "Every criterion needs a human check"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-3.json")" "- [ ] hello.txt exists
- [ ] It says hi"
  assert_eq '["hello.txt exists","It says hi"]' \
    "$(state_get '[.events[] | select(.event == "human-check-split")][0].criteria' | jq -c .)"
}

test_h_a_red_recorded_check_no_criterion_cites_leaves_nothing_to_a_human_check() {
  setup_wave
  record_checks
  # Runs the recorded checks as its prompt says, then marks every criterion "human".
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF2'
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
eval "$(sed -n 's/^    \$ //p' "$ARTISAN_RUN_DIR/prompts/$key.md")" >/dev/null || true
jq '{acceptance: [.[] | {criterion: ., met: "human", evidence: {why: "only play shows it"}}]}' \
  "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF2
  export WORKER_FILE=BROKEN
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 0/2 retry: hello.txt exists" "$JUDGE_OUT"
  [ ! -f "$FAKE_GH_DIR/issue-3.json" ] || fail "a broken build was handed to a Human check"
}

test_h_the_next_slice_gate_lists_the_new_human_check() {
  judge_human "It says hi"
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  "$SCRIPTS/wave.sh" close "$RUN_DIR" 1 >/dev/null
  export ARTISAN_HOME="$TEST_TMPDIR/artisan-home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/team-cache"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/claude-config"
  merge_gate_local "$ARTISAN_HOME"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.gates = [{kind: "slice", slice: "hello", tickets: ["1"]}, {kind: "end"}]'
  local num= body=
  num=$("$SCRIPTS/gate.sh" open "$RUN_DIR" slice-1)
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_contains "$body" "## Human checks"
  assert_contains "$body" "#3 (Human check: Add hello (#1))"
  assert_contains "$body" "It says hi"
}

test_h_a_judge_that_split_but_crashed_before_recording_splits_nothing_more() {
  setup_wave
  returned_ticket
  export VERIFIER_HUMAN="It says hi"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  # The split happened, then the judge died before writing the verdict.
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH" "$SCRIPTS/to-plan.sh" split-human-check --repo local/sample 1 "It says hi" >/dev/null
  judge_verifier 1
  assert_eq "pass 1/2, 1 to Human check #3" "$JUDGE_OUT"
  [ ! -f "$FAKE_GH_DIR/issue-4.json" ] || fail "a second Human check was created"
  assert_eq 1 "$(jq -r .body "$FAKE_GH_DIR/issue-3.json" | grep -c 'It says hi')" "the criterion is on the Human check once"
}

test_h_the_all_human_note_is_on_the_ticket_comment() {
  judge_human "hello.txt exists|It says hi"
  assert_contains "$("$SCRIPTS/evidence.sh" comment "$RUN_DIR" 1)" "- **Note:** Every criterion needs a human check"
}

test_h_a_moved_comment_that_could_not_be_posted_records_nothing_and_judging_again_posts_it() {
  setup_wave
  returned_ticket
  export VERIFIER_HUMAN="It says hi"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  : >"$FAKE_GH_DIR/comments-1.md"
  chmod a-w "$FAKE_GH_DIR/comments-1.md"   # the comment can't be posted
  local rc=0
  "$SCRIPTS/verify.sh" judge "$RUN_DIR" 1 >/dev/null 2>&1 || rc=$?
  chmod u+w "$FAKE_GH_DIR/comments-1.md"
  [ "$rc" -ne 0 ] || fail "a judge that could not comment said it was done"
  assert_eq '"-"' "$(state_get '.tickets["1"].verifications[-1].verdict // "-" | tojson')"
  judge_verifier 1
  assert_eq "pass 1/2, 1 to Human check #3" "$JUDGE_OUT"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "moved to Human check #3"
}
