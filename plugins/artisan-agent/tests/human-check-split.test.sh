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
