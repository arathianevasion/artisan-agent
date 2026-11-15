# A criterion no worker can meet (#186): a worker lists it in its record's
# `unmeetable`; when the verifier agrees, verify.sh judge sends the ticket to
# an exception gate (reason "unmeetable") without using another attempt, and
# the gate's choices (split into a Human check or a new ticket, rewrite,
# drop the criterion, retry anyway) each work. When the verifier disagrees,
# the attempt fails as now and the retry's notes say why. Built on
# verify.test.sh's run (fake `claude`, fake `gh` over a folder tracker);
# nothing reaches GitHub.

. "$TESTS_DIR/verify.test.sh"
# Only this file's tests run here; verify.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_u_/ {print $3}'); do unset -f "$_f"; done
unset _f

A="$PLUGIN_ROOT/scripts/gate-action.sh"
PY="$PLUGIN_ROOT/scripts/lib/criteria.py"

# The worker lists WORKER_UNMEETABLE as a criterion no worker could meet; the
# verifier finds VERIFIER_UNMET unmet and, with VERIFIER_UNMEETABLE=agree or
# disagree, says whether it agrees.
unmeetable_scripts() {
  cat >>"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
if [ -n "${WORKER_UNMEETABLE:-}" ]; then
  jq --arg c "$WORKER_UNMEETABLE" '.unmeetable = [{criterion: $c, why: "it needs recorded fixtures that do not exist yet"}]
    | .acceptance |= map(if .criterion == $c then .met = false | .evidence = {why: "no fixtures"} else . end)' \
    "$ARTISAN_RESULT_FILE" >"$ARTISAN_RESULT_FILE.tmp"
  mv "$ARTISAN_RESULT_FILE.tmp" "$ARTISAN_RESULT_FILE"
fi
EOF
  cat >>"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
if [ -n "${VERIFIER_UNMEETABLE:-}" ]; then
  jq --arg c "${VERIFIER_UNMET:-}" --arg a "$VERIFIER_UNMEETABLE" '.acceptance |= map(if .criterion == $c
      then .unmeetable = ($a == "agree")
        | .evidence.why = (if $a == "agree" then "no fixtures exist and none can be recorded here" else "the fixtures can be recorded from the sample data" end)
      else . end)' "$ARTISAN_RESULT_FILE" >"$ARTISAN_RESULT_FILE.tmp"
  mv "$ARTISAN_RESULT_FILE.tmp" "$ARTISAN_RESULT_FILE"
fi
EOF
}

# Ticket 1's worker lists "It says hi" as unmeetable; the verifier says
# whether it agrees ($1: agree | disagree).
judge_unmeetable() {
  setup_wave
  unmeetable_scripts
  export WORKER_UNMEETABLE="It says hi" VERIFIER_UNMET="It says hi" VERIFIER_UNMEETABLE="$1"
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
}

# The verifier agreed and the gate is open: GATE_ISSUE is its number.
GATE_ISSUE=
open_unmeetable_gate() {
  judge_unmeetable agree
  "$A" sync "$RUN_DIR" >"$TEST_TMPDIR/sync.out"
  GATE_ISSUE=$(state_get '.exception_gates[0].issue')
  # From here the verifier finds everything it is given met.
  unset VERIFIER_UNMET VERIFIER_UNMEETABLE
}

# A fresh verifier on the same commit, judged (the second verifier).
reverify() {
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 2
}

test_u_align_keeps_the_workers_unmeetable_claim_and_whether_the_verifier_agrees() {
  echo '["A thing", "B thing", "C thing"]' >c.json
  echo '{"acceptance": [{"criterion": "A thing", "met": true},
    {"criterion": "B thing", "met": false, "unmeetable": true, "evidence": {"why": "no fixtures"}},
    {"criterion": "C thing", "met": false, "unmeetable": false}]}' >v.json
  echo '{"unmeetable": [{"criterion": "b  THING", "why": "needs fixtures"}, {"criterion": "C thing", "why": "hard"},
    {"criterion": "A thing", "why": "x"}]}' >r.json
  assert_eq '[{"why":"x","verifier_agrees":false},{"why":"needs fixtures","verifier_agrees":true},{"why":"hard","verifier_agrees":false}]' \
    "$(python3 -I "$PY" align c.json v.json r.json | jq -c 'map(.unmeetable)')"
  # No claim, no field.
  assert_eq '[null,null,null]' "$(python3 -I "$PY" align c.json v.json missing.json | jq -c 'map(.unmeetable)')"
}

test_u_change_applies_the_artisans_criteria_changes_in_order() {
  echo '[{"action": "drop", "criterion": "a THING"}, {"action": "rewrite", "criterion": "B thing", "as": "B, reworded"},
    {"action": "split", "criterion": "C thing", "to": "9"}, {"action": "drop", "criterion": "not there"}]' >ch.json
  assert_eq '["B, reworded","D thing"]' \
    "$(echo '["A thing", "B thing", "C thing", "D thing"]' | python3 -I "$PY" change ch.json | jq -c .)"
  assert_eq '["A thing"]' "$(echo '["A thing"]' | python3 -I "$PY" change missing.json | jq -c .)"
}

test_u_an_agreed_unmeetable_criterion_opens_an_exception_gate_and_uses_no_further_attempt() {
  judge_unmeetable agree
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 1/2 unmeetable: It says hi" "$JUDGE_OUT"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_eq 1 "$(state_get '.tickets["1"].attempts')"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')" "not a failed attempt"
  assert_eq "unmeetable exception waiting" "$(state_get '.decisions[0] | "\(.reason) \(.kind) \(.status)"')"
  assert_eq '[{"ticket":"1","attempt":1,"criterion":"It says hi","why":"it needs recorded fixtures that do not exist yet","verifier_agrees":true}]' \
    "$(state_get '[.events[] | select(.event == "criterion-unmeetable") | {ticket, attempt, criterion, why, verifier_agrees}]' | jq -c .)"
  # Judging again says the same.
  assert_eq "fail 1/2 unmeetable: It says hi" "$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1 || true)"
  # The run raises the exception gate, with the new choices.
  "$A" sync "$RUN_DIR" >"$TEST_TMPDIR/sync.out"
  local num= body=
  num=$(state_get '.exception_gates[0].issue')
  assert_eq "unmeetable" "$(state_get '.exception_gates[0].reason')"
  assert_eq "Exception gate: #1 has criteria no worker can meet (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$num.json")"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$num.json")
  assert_contains "$body" "## Criteria no worker can meet"
  assert_contains "$body" "| 1 | It says hi | it needs recorded fixtures that do not exist yet | no fixtures exist and none can be recorded here |"
  assert_contains "$body" "| split into a Human check |"
  assert_contains "$body" "| split into a new ticket |"
  assert_contains "$body" "| rewrite |"
  assert_contains "$body" "| drop it |"
  assert_contains "$body" "| retry anyway |"
  assert_not_contains "$body" "| reslice |"
  assert_contains "$("$A" chat "$RUN_DIR")" "criteria no worker can meet"
  # Nothing dispatches it while the gate waits.
  ! "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null 2>&1 || fail "a blocked ticket was dispatched"
  assert_eq 1 "$(state_get '.tickets["1"].attempts')"
}

test_u_a_disagreed_unmeetable_criterion_fails_the_attempt_and_the_retry_is_told_why() {
  judge_unmeetable disagree
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 1/2 retry: It says hi" "$JUDGE_OUT"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_eq 1 "$(state_get '.tickets["1"].failures | length')"
  assert_eq null "$(state_get '.tickets["1"].unmeetable')"
  assert_eq false "$(state_get '[.events[] | select(.event == "criterion-unmeetable")][0].verifier_agrees')"
  local prompt=
  prompt=$("$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null; cat "$RUN_DIR/prompts/1.2.md")
  assert_contains "$prompt" "- The last worker said no worker could meet It says hi (it needs recorded fixtures that do not exist yet); the verifier did not agree, so meet it: the fixtures can be recorded from the sample data"
}

test_u_drop_criterion_drops_it_with_the_reason_and_the_same_commit_is_verified_again() {
  open_unmeetable_gate
  assert_status 2 "$A" drop-criterion "$RUN_DIR" "$GATE_ISSUE"   # a reason is required
  "$A" drop-criterion "$RUN_DIR" "$GATE_ISSUE" --why "Fixtures come in #9" >"$TEST_TMPDIR/out"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "#1: 1 criteria dropped"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq '[{"action":"drop","criterion":"It says hi","why":"Fixtures come in #9"}]' "$(state_get '.tickets["1"].criteria_changes' | jq -c .)"
  assert_eq "closed decided" "$(jq -r .state "$FAKE_GH_DIR/issue-$GATE_ISSUE.json") $(state_get '.exception_gates[0].status')"
  assert_eq "drop the criterion" "$(state_get '.decisions[0].choice')"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "criterion-changed" and .action == "drop")] | length')"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "- It says hi: dropped (Fixtures come in #9)"
  reverify
  assert_eq '["hello.txt exists"]' "$(jq -c . "$RUN_DIR/prompts/verify-1.2.criteria.json")"
  assert_eq "pass 1/1" "$JUDGE_OUT"
  assert_eq 1 "$(state_get '.tickets["1"].attempts')" "no worker attempt used"
}

test_u_rewrite_gives_the_criterion_new_wording_for_the_next_verifier_and_worker() {
  open_unmeetable_gate
  assert_status 2 "$A" rewrite "$RUN_DIR" "$GATE_ISSUE"   # --as is required
  assert_status 6 "$A" rewrite "$RUN_DIR" "$GATE_ISSUE" --criterion "Not listed" --as "x"
  "$A" rewrite "$RUN_DIR" "$GATE_ISSUE" --criterion 1 --as "It says hi in hello.txt" >/dev/null
  assert_eq returned "$(state_get '.tickets["1"].status')"
  assert_eq rewrite "$(state_get '.decisions[0].choice')"
  reverify
  assert_eq '["hello.txt exists","It says hi in hello.txt"]' "$(jq -c . "$RUN_DIR/prompts/verify-1.2.criteria.json")"
  assert_eq "pass 2/2" "$JUDGE_OUT"
  # A later worker is told of the change.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].status = "queued"'
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "  - It says hi: now reads: It says hi in hello.txt"
}

test_u_split_into_a_human_check_moves_the_criterion_and_the_check_joins_the_run() {
  open_unmeetable_gate
  assert_status 2 "$A" split "$RUN_DIR" "$GATE_ISSUE"   # --human or --ticket
  "$A" split "$RUN_DIR" "$GATE_ISSUE" --human --criterion "it says HI" >"$TEST_TMPDIR/out"
  local hc=$((GATE_ISSUE + 1))
  assert_contains "$(cat "$TEST_TMPDIR/out")" "moved to #$hc"
  assert_eq "Human check: Add hello (#1)" "$(jq -r .title "$FAKE_GH_DIR/issue-$hc.json")"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$hc.json")" "- [ ] It says hi"
  assert_not_contains "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "It says hi"
  assert_eq "true 1 queued" "$(state_get '"\(.plan.scope | index("'"$hc"'") != null) \(.tickets["'"$hc"'"].human_check.for) \(.tickets["'"$hc"'"].status)"')"
  assert_eq "split into a Human check" "$(state_get '.decisions[0].choice')"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "human-check-split" and .gate != null)] | length')"
  reverify
  assert_eq "pass 1/1" "$JUDGE_OUT"
}

# #215: a ticket whose criteria are in its triage comment, not its body.
test_u_split_into_a_human_check_takes_the_criterion_off_the_triage_comment() {
  setup_wave
  jq '.body = "## What\nno checkboxes"' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/t" && mv "$FAKE_GH_DIR/t" "$FAKE_GH_DIR/issue-1.json"
  printf '%s' $'> *This was generated by AI during triage.*\n\n## Agent Brief\n\n**Acceptance criteria:**\n- [ ] hello.txt exists\n- [ ] It says hi\n\n**Out of scope:**\n- goodbye' \
    >"$FAKE_GH_DIR/comments-1.md"
  unmeetable_scripts
  export WORKER_UNMEETABLE="It says hi" VERIFIER_UNMET="It says hi" VERIFIER_UNMEETABLE=agree
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  "$A" sync "$RUN_DIR" >/dev/null
  GATE_ISSUE=$(state_get '.exception_gates[0].issue')
  [ -n "$GATE_ISSUE" ] && [ "$GATE_ISSUE" != null ] || fail "no exception gate opened"
  unset VERIFIER_UNMET VERIFIER_UNMEETABLE
  "$A" split "$RUN_DIR" "$GATE_ISSUE" --human --criterion "it says HI" >"$TEST_TMPDIR/out"
  local hc=$((GATE_ISSUE + 1)) triage=""
  assert_contains "$(cat "$TEST_TMPDIR/out")" "moved to #$hc"
  assert_contains "$(jq -r .body "$FAKE_GH_DIR/issue-$hc.json")" "- [ ] It says hi"
  triage=$(jq -Rrs 'split("\n---\n")[0]' "$FAKE_GH_DIR/comments-1.md")
  assert_eq $'> *This was generated by AI during triage.*\n\n## Agent Brief\n\n**Acceptance criteria:**\n- [ ] hello.txt exists\n\n**Out of scope:**\n- goodbye' \
    "$triage" "only the moved line left the triage comment"
  assert_eq "## What"$'\n'"no checkboxes" "$(jq -r .body "$FAKE_GH_DIR/issue-1.json")" "the body is untouched"
  reverify
  assert_eq "pass 1/1" "$JUDGE_OUT"
}

test_u_split_into_a_new_ticket_opens_it_for_triage_outside_the_run() {
  open_unmeetable_gate
  "$A" split "$RUN_DIR" "$GATE_ISSUE" --ticket --why "Needs the fixture recorder" >/dev/null
  local n=$((GATE_ISSUE + 1)) body=
  assert_eq "Split off #1: Add hello" "$(jq -r .title "$FAKE_GH_DIR/issue-$n.json")"
  assert_eq needs-triage "$(jq -r '.labels | map(.name) | join(",")' "$FAKE_GH_DIR/issue-$n.json")"
  body=$(jq -r .body "$FAKE_GH_DIR/issue-$n.json")
  assert_contains "$body" "- [ ] It says hi"
  assert_contains "$body" "Why: Needs the fixture recorder"
  assert_eq false "$(state_get '.plan.scope | index("'"$n"'") != null')" "outside the run"
  assert_eq "split $n" "$(state_get '.tickets["1"].criteria_changes[0] | "\(.action) \(.to)"')"
  reverify
  assert_eq "pass 1/1" "$JUDGE_OUT"
}

test_u_retry_anyway_needs_no_notes_and_gives_a_fresh_worker_one_more_attempt() {
  open_unmeetable_gate
  "$A" retry "$RUN_DIR" "$GATE_ISSUE" >/dev/null
  assert_eq "queued 1" "$(state_get '.tickets["1"] | "\(.status) \(.extra_attempts)"')"
  assert_eq "retry anyway" "$(state_get '.decisions[0].choice')"
  assert_eq answered "$(state_get '.tickets["1"].unmeetable.status')"
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  assert_contains "$(cat "$RUN_DIR/prompts/1.2.md")" "The Artisan judges these criteria meetable, though the last worker said no worker could meet them: It says hi"
}

test_u_the_criterion_choices_are_refused_on_another_exception_gate() {
  setup_wave
  export VERIFIER_UNMET="It says hi"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.attempts_per_ticket = 1'
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq "fail 1/2 blocked: It says hi" "$JUDGE_OUT"
  "$A" sync "$RUN_DIR" >/dev/null
  local num=
  num=$(state_get '.exception_gates[0].issue')
  assert_eq gave-up "$(state_get '.exception_gates[0].reason')"
  assert_status 6 "$A" drop-criterion "$RUN_DIR" "$num" --why "x"
  assert_status 6 "$A" split "$RUN_DIR" "$num" --human
  assert_status 2 "$A" retry "$RUN_DIR" "$num"   # notes still required here
}

test_u_the_worker_brief_limits_unmeetable_to_real_impossibility() {
  local skill="$PLUGIN_ROOT/skills/implement/SKILL.md" rec="$PLUGIN_ROOT/references/evidence-record.md"
  assert_contains "$(cat "$skill")" '`unmeetable`'
  assert_contains "$(cat "$skill")" "only when no worker could meet the criterion in this environment"
  assert_contains "$(cat "$skill")" "ran out of time or budget, or because it is hard"
  assert_contains "$(cat "$rec")" '| `unmeetable` | no |'
}
