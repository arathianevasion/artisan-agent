# verify.sh and evidence.sh: a fresh verifier per returned ticket, its
# verdict in the evidence format, the evidence contract in the state file and
# on the ticket, and the wave digest. Built on wave.test.sh's run (fake
# `claude` scripted per role, fake `gh` over a folder tracker).

. "$TESTS_DIR/wave.test.sh"
# Only this file's tests run here; wave.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_v_/ {print $3}'); do unset -f "$_f"; done
unset _f

# Ticket 1 dispatched, its worker done and swept: returned.
returned_ticket() {
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/1.1.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  assert_eq returned "$(state_get '.tickets["1"].status')"
}

JUDGE_OUT= JUDGE_STATUS=
judge_verifier() { # verifier-attempt
  wait_for "$RUN_DIR/results/verify-1.$1.exit.json" 30
  JUDGE_STATUS=0
  JUDGE_OUT=$("$SCRIPTS/verify.sh" judge "$RUN_DIR" 1 2>"$TEST_TMPDIR/judge.err") || JUDGE_STATUS=$?
}

test_v_the_verifier_is_a_fresh_session_in_its_own_checkout_of_the_commit() {
  setup_wave
  returned_ticket
  export FAKE_CLAUDE_ENV="$TEST_TMPDIR/verifier.env"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  local env wt commit
  env=$(cat "$FAKE_CLAUDE_ENV")
  wt="$TEST_TMPDIR/project-wt/r1-verify-1.1"
  commit=$(git -C "$PROJECT" rev-parse agent/1)
  assert_contains "$env" "ARTISAN_ROLE=verifier"
  assert_contains "$env" "ARTISAN_WRITER_PID=" "no writer pid"
  case "$env" in *"ARTISAN_WRITER_PID=$CHAT"*) fail "the verifier inherited the writer pid" ;; esac
  assert_eq "$wt" "$(cat "$TEST_TMPDIR/project/.artisan-agent/runs/verifier-dirs")" "its own worktree, not the worker's"
  assert_eq "$commit" "$(state_get '.tickets["1"].verifications[0].commit')"
  [ ! -d "$wt" ] || fail "the verifier's worktree was left behind"
  # The prompt names the brief, the diff and the criteria verbatim, in order.
  local prompt
  prompt=$(cat "$RUN_DIR/prompts/verify-1.1.md")
  assert_contains "$prompt" "skills/implement-plan/references/verifier.md"
  assert_contains "$prompt" "...$commit"
  assert_contains "$prompt" "  1. hello.txt exists
  2. It says hi"
  case "$prompt" in *"not a criterion"*) fail "a checkbox outside the criteria reached the verifier" ;; esac
  assert_eq "pass 2/2" "$JUDGE_OUT"
  assert_eq 0 "$JUDGE_STATUS"
}

test_v_a_ticket_that_misses_a_criterion_is_not_merged() {
  setup_wave
  export VERIFIER_UNMET="It says hi"
  # One attempt, so the miss goes straight to the Artisan (retries: below).
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.attempts_per_ticket = 1'
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].failures[-1].reason')" "the verifier found 1 of 2 criteria unmet, first: It says hi"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)" "nothing merged"
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  assert_eq exception "$(state_get '.decisions[0].kind')"
  assert_contains "$(state_get '.decisions[0].question')" "failed 1 attempts (last: the verifier found 1 of 2"
  # The worker claimed it; the verifier says otherwise, and both are kept.
  assert_eq "false true" "$(state_get '.tickets["1"].evidence.acceptance[1] | "\(.met) \(.claimed)"')"
  assert_eq "fail 1/2 blocked: It says hi" "$(cat "$TEST_TMPDIR/project/.artisan-agent/runs/verdicts")"
  assert_eq fail "$(jq -r '.tickets[0].verdict' "$RUN_DIR/results/orchestrator-w1.1.result.json")"
  # The failed work is on the audit trail too.
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "| It says hi | no | not in the diff |"
}

test_v_merge_refuses_work_without_a_passing_verdict() {
  setup_wave
  returned_ticket
  assert_status 13 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1
  assert_eq returned "$(state_get '.tickets["1"].status')" "refusing is not blocking"
  assert_eq "$MAIN_HEAD" "$(git -C "$PROJECT" rev-parse run/r1)"
  # A pass for an earlier commit doesn't count either.
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].evidence.commit = "0000000"'
  assert_status 13 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"].evidence.commit = $c' --arg c "$(git -C "$PROJECT" rev-parse agent/1)"
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  assert_eq merged "$(state_get '.tickets["1"].status')"
}

test_v_a_verdict_that_leaves_out_a_criterion_counts_it_unmet() {
  setup_wave
  returned_ticket
  # This verifier answers only the first criterion.
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
jq -n '{verdict: "pass", acceptance: [{criterion: "HELLO.TXT  exists", met: true}]}' >"$ARTISAN_RESULT_FILE"
EOF
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq "fail 1/2 retry: It says hi" "$JUDGE_OUT"
  assert_eq "hello.txt exists" "$(state_get '.tickets["1"].evidence.acceptance[0].criterion')" "the ticket's wording, not the verifier's"
  assert_contains "$(state_get '.tickets["1"].evidence.acceptance[1].evidence.why')" "no verdict"
  assert_eq queued "$(state_get '.tickets["1"].status')" "a failed attempt, with one left"
}

test_v_a_verifier_that_fails_is_started_again_once_then_the_ticket_is_blocked() {
  setup_wave
  returned_ticket
  export VERIFIER_MODE=garbage
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq 14 "$JUDGE_STATUS"
  assert_contains "$JUDGE_OUT" "error the verdict is not in the evidence format"
  assert_eq returned "$(state_get '.tickets["1"].status')"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 2
  assert_eq 6 "$JUDGE_STATUS"
  assert_eq blocked "$(state_get '.tickets["1"].status')"
  assert_contains "$(state_get '.tickets["1"].blocked_reason')" "the verifier failed 2 times"
  assert_eq 0 "$(state_get '.tickets["1"].failures | length')" "the worker's attempt is not used up"
  judge_verifier 2
  assert_eq 6 "$JUDGE_STATUS" "judging again says blocked, not start again"
}

test_v_a_classifier_error_does_not_record_an_error_verdict_or_start_a_second_verifier() {
  setup_wave
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  wait_for "$RUN_DIR/results/verify-1.1.exit.json" 30
  # Take the exit record away and empty the pid: the classifier can't read
  # the verifier's state, which must not look like a dead verifier.
  mv "$RUN_DIR/results/verify-1.1.exit.json" "$TEST_TMPDIR/exit.json"
  : >"$RUN_DIR/workers/verify-1.1/runner.pid"
  JUDGE_STATUS=0
  "$SCRIPTS/verify.sh" judge "$RUN_DIR" 1 >"$TEST_TMPDIR/judge.out" 2>"$TEST_TMPDIR/judge.err" || JUDGE_STATUS=$?
  assert_eq 1 "$JUDGE_STATUS" "an error, not exit 14 (verifier failed, start again)"
  assert_contains "$(cat "$TEST_TMPDIR/judge.err")" "could not classify"
  assert_eq 1 "$(state_get '.tickets["1"].verifications | length')" "no second verifier"
  assert_eq "null" "$(state_get '.tickets["1"].verifications[0].verdict')" "no error verdict"
  if "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null 2>&1; then fail "start launched another verifier over an unclassifiable one"; fi
  assert_eq 1 "$(state_get '.tickets["1"].verifications | length')"
}

test_v_judging_twice_says_the_same_and_writes_nothing() {
  setup_wave
  returned_ticket
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  cp "$RUN_DIR/state.json" "$TEST_TMPDIR/before.json"
  judge_verifier 1
  assert_eq "pass 2/2" "$JUDGE_OUT"
  cmp -s "$TEST_TMPDIR/before.json" "$RUN_DIR/state.json" || fail "a second judge rewrote the state file"
  # Verified work is not verified again: starting again is a no-op.
  local pid
  pid=$("$SCRIPTS/verify.sh" start "$RUN_DIR" 1 2>/dev/null)
  assert_eq "$(cat "$RUN_DIR/workers/verify-1.1/runner.pid")" "$pid" "the first verifier's pid"
  cmp -s "$TEST_TMPDIR/before.json" "$RUN_DIR/state.json" || fail "a second start rewrote the state file"
}

test_v_starting_a_verifier_twice_for_one_attempt_launches_one() {
  setup_wave
  returned_ticket
  export VERIFIER_SLEEP=2   # still running for the second call
  local first second third
  first=$("$SCRIPTS/verify.sh" start "$RUN_DIR" 1)
  second=$("$SCRIPTS/verify.sh" start "$RUN_DIR" 1 2>/dev/null)
  assert_eq "$first" "$second" "the running verifier's pid, not a new one"
  judge_verifier 1
  third=$("$SCRIPTS/verify.sh" start "$RUN_DIR" 1 2>/dev/null)
  assert_eq "$first" "$third" "ended and judged pass: still that verifier"
  assert_eq 1 "$(state_get '.tickets["1"].verifications | length')"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "verify")] | length')"
  [ ! -e "$RUN_DIR/workers/verify-1.2" ] || fail "a second verifier was launched"
}

test_v_two_starts_at_once_launch_one_verifier() {
  setup_wave
  returned_ticket
  local i pids=
  for i in 1 2 3 4; do
    "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >"$TEST_TMPDIR/start.$i" 2>/dev/null &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i" || fail "a concurrent start failed"; done
  judge_verifier 1
  assert_eq "pass 2/2" "$JUDGE_OUT"
  assert_eq 1 "$(cat "$TEST_TMPDIR"/start.* | sort -u | wc -l | tr -d ' ')" "every call names the same verifier"
  assert_eq 1 "$(state_get '.tickets["1"].verifications | length')"
  [ ! -e "$RUN_DIR/workers/verify-1.2" ] || fail "a second verifier was launched"
}

test_v_a_start_that_fails_before_launching_does_not_wedge_the_attempt() {
  setup_wave
  returned_ticket
  # The first start dies before recording a verifier: its claim is cleared.
  mkdir -p "$TEST_TMPDIR/project-wt/r1-verify-1.1"
  assert_status 1 "$SCRIPTS/verify.sh" start "$RUN_DIR" 1
  [ ! -e "$RUN_DIR/verify/claims/1.1" ] || fail "a failed start left its claim"
  rmdir "$TEST_TMPDIR/project-wt/r1-verify-1.1"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq "pass 2/2" "$JUDGE_OUT"
}

test_v_a_claim_whose_start_was_killed_is_cleared() {
  setup_wave
  returned_ticket
  # A start killed (no trap ran) between claiming and recording.
  local dead
  sh -c 'exit 0' & dead=$!; wait "$dead"
  mkdir -p "$RUN_DIR/verify/claims/1.1"
  echo "$dead" >"$RUN_DIR/verify/claims/1.1/pid"
  assert_status 8 "$SCRIPTS/verify.sh" start "$RUN_DIR" 1
  [ ! -e "$RUN_DIR/verify/claims/1.1" ] || fail "the dead start's claim was kept"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq "pass 2/2" "$JUDGE_OUT"
  assert_eq 1 "$(state_get '.tickets["1"].verifications | length')"
}

test_v_the_ticket_comment_is_the_contract_in_the_state_file() {
  setup_wave
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  assert_eq closed "$(jq -r .state "$FAKE_GH_DIR/issue-1.json")"
  local comment
  comment=$(cat "$FAKE_GH_DIR/comments-1.md")
  # Every criterion with its evidence, what the worker was unsure of, its
  # cost and the decisions it made alone.
  assert_contains "$comment" "the verifier says **pass**, 2 of 2 criteria met"
  assert_contains "$comment" "| hello.txt exists | yes | sh check.sh: suite ok |"
  assert_contains "$comment" "| It says hi | yes | sh check.sh: suite ok |"
  assert_contains "$comment" "- Whether hi needs a newline"
  assert_contains "$comment" "| Which file? | hello.txt | HELLO | engineering taste | provisional |"
  assert_contains "$comment" "- **Cost:** \$0.02 (worker \$0.01, verifier \$0.01) against an estimate of \$0.25"
  assert_contains "$comment" "- **Diff:** 1 file changed, 1 insertion(+)"
  # The JSON in the comment is the state file's contract, exactly.
  printf '%s\n' "$comment" | awk '/^```json$/ {on = 1; next} /^```$/ {on = 0} on' >"$TEST_TMPDIR/posted.json"
  assert_eq "$(state_get '.tickets["1"].evidence' | jq -cS .)" "$(jq -cS . "$TEST_TMPDIR/posted.json")"
  for k in acceptance unsure decisions cost tests diff verdict; do
    assert_eq true "$(state_get ".tickets[\"1\"].evidence | has(\"$k\")")" "contract has $k"
  done
}

test_v_the_digest_names_each_ticket_in_a_few_lines() {
  setup_wave '["1","2"]'
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  export WORKER_FILE=goodbye.txt
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >/dev/null
  wait_for "$RUN_DIR/results/orchestrator-w2.1.exit.json" 60
  "$SCRIPTS/wave.sh" status "$RUN_DIR" >/dev/null
  local d1 d2 all
  d1=$("$SCRIPTS/evidence.sh" digest "$RUN_DIR" --wave 1)
  d2=$("$SCRIPTS/evidence.sh" digest "$RUN_DIR")
  all=$("$SCRIPTS/evidence.sh" digest "$RUN_DIR" --all)
  assert_contains "$d1" "| #1 (Add hello) | merged as "
  assert_contains "$d1" ", closed | 2/2 verified | 1 unsure, 1 decision | \$0.02 of \$0.25 |"
  case "$d1" in *"#2 (Add goodbye)"*) fail "wave 1's digest shows wave 2's ticket" ;; esac
  assert_contains "$d2" "Wave 2 of run r1: 1 ticket."
  assert_contains "$d2" "| #2 (Add goodbye) | merged as "
  assert_contains "$all" "#1 (Add hello)"
  assert_contains "$all" "#2 (Add goodbye)"
  # A few lines per ticket: a header, the table and one line of cost.
  [ "$(printf '%s\n' "$all" | wc -l)" -le 8 ] || fail "digest too long: $all"
}

test_v_the_digest_shows_a_blocked_ticket_and_why() {
  setup_wave
  export VERIFIER_UNMET="It says hi"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.attempts_per_ticket = 1'
  start_and_launch
  wait_for "$ORCH_EXIT" 60
  local d
  d=$("$SCRIPTS/evidence.sh" digest "$RUN_DIR")
  assert_contains "$d" "| #1 (Add hello) | blocked: the verifier found 1 of 2 criteria unmet, first: It says hi | 1/2 verified |"
  assert_contains "$d" "Blocked: #1, each with a decision waiting"
}

test_v_criteria_come_from_the_acceptance_section_or_every_checkbox() {
  local py="$PLUGIN_ROOT/scripts/lib/criteria.py"
  assert_eq '["A thing","B | pipes","still in"]' "$(printf '## Acceptance criteria\n- [ ] A thing\n- [x] B | pipes\n### Sub\n- [ ] still in\n## Spec\n- [ ] out' | python3 -I "$py" extract | jq -c .)"
  assert_eq '["one","two"]' "$(printf -- '- [ ] one\n* [X] two\n- plain' | python3 -I "$py" extract | jq -c .)"
}

test_v_align_matches_by_text_then_position_and_keeps_the_claim() {
  local py="$PLUGIN_ROOT/scripts/lib/criteria.py"
  echo '["A thing", "B thing"]' >c.json
  echo '{"acceptance": [{"criterion": "b  THING", "met": true, "evidence": {"diff": "b +1"}}, {"criterion": "other", "met": true}]}' >v.json
  echo '{"acceptance": [{"criterion": "A thing", "met": true}]}' >r.json
  # By text first; the counts agree, so "A thing" takes the entry in its position.
  assert_eq '[{"criterion":"A thing","met":true,"claimed":true},{"criterion":"B thing","met":true,"claimed":null}]' \
    "$(python3 -I "$py" align c.json v.json r.json | jq -c 'map(del(.evidence))')"
  # A verdict with fewer entries leaves the missing one unmet; a missing record is no claims.
  echo '{"acceptance": [{"criterion": "B thing", "met": true}]}' >v.json
  assert_eq 'false null' "$(python3 -I "$py" align c.json v.json missing.json | jq -r '.[0] | "\(.met) \(.claimed)"')"
}

test_v_paraphrased_claims_follow_position_only_when_the_counts_agree() {
  local py="$PLUGIN_ROOT/scripts/lib/criteria.py"
  echo '["A thing", "B thing"]' >c.json
  echo '{"acceptance": [{"criterion": "A thing", "met": true}, {"criterion": "B thing", "met": true}]}' >v.json
  echo '{"acceptance": [{"criterion": "the first, reworded", "met": true}, {"criterion": "the second, reworded", "met": false}]}' >r.json
  assert_eq "true false" "$(python3 -I "$py" align c.json v.json r.json | jq -r 'map(.claimed | tostring) | join(" ")')"
  # With the counts differing, a paraphrased claim stays null: no guessing.
  echo '{"acceptance": [{"criterion": "the first, reworded", "met": true}]}' >r.json
  assert_eq "null null" "$(python3 -I "$py" align c.json v.json r.json | jq -r 'map(.claimed | tostring) | join(" ")')"
  # Exact text still wins when the counts differ.
  echo '{"acceptance": [{"criterion": "b THING", "met": true}]}' >r.json
  assert_eq "null true" "$(python3 -I "$py" align c.json v.json r.json | jq -r 'map(.claimed | tostring) | join(" ")')"
}

test_v_a_ticket_the_verifier_fails_is_retried_by_a_fresh_worker_given_its_findings() {
  setup_wave
  returned_ticket
  export VERIFIER_UNMET="It says hi"
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 1
  assert_eq "6 fail 1/2 retry: It says hi" "$JUDGE_STATUS $JUDGE_OUT"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-1.md")" "| It says hi | no | not in the diff |"
  # The retry: a fresh worker told what the verifier found.
  unset VERIFIER_UNMET
  "$SCRIPTS/wave.sh" dispatch "$RUN_DIR" 1 >/dev/null
  local prompt
  prompt=$(cat "$RUN_DIR/prompts/1.2.md")
  assert_contains "$prompt" "The last attempt failed: the verifier found 1 of 2 criteria unmet, first: It says hi"
  assert_contains "$prompt" "- Unmet (verifier): It says hi (not in the diff)"
  # Judging again, with the retry under way, still says what happened.
  judge_verifier 1
  assert_eq "6 fail 1/2 retry: It says hi" "$JUDGE_STATUS $JUDGE_OUT"
  wait_for "$RUN_DIR/results/1.2.exit.json" 30
  "$SCRIPTS/sweep.sh" "$RUN_DIR"
  # Attempt 1's verdict doesn't let attempt 2 merge unverified.
  assert_status 13 "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1
  "$SCRIPTS/verify.sh" start "$RUN_DIR" 1 >/dev/null
  judge_verifier 2
  assert_eq "0 pass 2/2" "$JUDGE_STATUS $JUDGE_OUT"
  assert_eq 2 "$(state_get '.tickets["1"].evidence.attempt')"
  "$SCRIPTS/wave.sh" merge "$RUN_DIR" 1 >/dev/null
  assert_eq merged "$(state_get '.tickets["1"].status')"
}

test_v_the_orchestrator_brief_reads_verdicts_not_transcripts_or_diffs() {
  local brief="$PLUGIN_ROOT/skills/implement-plan/references/orchestrator.md"
  assert_contains "$(cat "$brief")" "verify.sh start"
  assert_contains "$(cat "$brief")" "verify.sh judge"
  ! grep -q 'git -C .* diff' "$brief" || fail "the orchestrator is told to read a diff itself"
  local v="$PLUGIN_ROOT/skills/implement-plan/references/verifier.md"
  [ -f "$v" ] || fail "no verifier brief"
  assert_contains "$(cat "$v")" "evidence-contract.md"
  assert_contains "$(cat "$PLUGIN_ROOT/skills/implement-plan/SKILL.md")" "evidence.sh digest"
}
