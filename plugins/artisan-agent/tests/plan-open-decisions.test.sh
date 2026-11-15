# Open decisions at the plan step (#229, references/open-decisions.md): the
# Run chat records each one in the draft; plan.sh build lists it under
# "Needs your attention" and state.sh init refuses the plan while one is
# left. The Artisan keeps a ticket with --override-open-decision and a
# reason, or plan.sh drop files the decision through questions.sh (no run,
# raised at the plan step) and takes the ticket and its dependents out of
# the draft's scope. Fake `gh` over a folder tracker; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

plan() { "$SCRIPTS/plan.sh" "$@"; }

# draft_with_decision path: tickets 10, 11 (blocked by 10), 12 (blocked by
# 11), 13 (on its own) and 14, the Human check for 10; an open decision on 10.
draft_with_decision() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  case ":$PATH:" in *":$TESTS_DIR/fixtures/fake-gh:"*) ;; *) PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"; export PATH ;; esac
  jq -n '
    def t($n; $b): {title: "Ticket \($n)", model: "claude-sonnet-5-5", blocked_by: $b,
                    acceptance: ["t\($n).txt exists"], expected_output: "t\($n).txt",
                    expected: {input_tokens: 100000, output_tokens: 10000, minutes: 10}};
    {run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
     scope: ["10", "11", "12", "13", "14"], waves: [["10", "13"], ["11", "14"], ["12"]],
     gates: [{kind: "slice", tickets: ["10", "14"]}, {kind: "risk", after: "11", tests: ["new-seam"]},
             {kind: "slice", tickets: ["13"]}, {kind: "end"}],
     tickets: {"10": t(10; []), "11": t(11; ["10"]), "12": t(12; ["11"]), "13": t(13; []),
               "14": {title: "Human check: t10 reads well", human_check_for: "10", blocked_by: ["10"],
                      model: "claude-sonnet-5-5", acceptance: ["It reads well"],
                      expected: {input_tokens: 1, output_tokens: 1, minutes: 1}}},
     open_decisions: [{ticket: "10", case: "incomplete",
                       harm: "the export menu offers PDF but nothing writes one",
                       recommendation: "drop PDF from the menu until a ticket writes it"}]}' >"$1"
}

build() { # draft [build args...] -> plan.json in $TEST_TMPDIR
  local d="$1"
  shift
  (cd "$PROJECT" && plan build --draft "$d" "$@") >"$TEST_TMPDIR/plan.json"
}

init_refuses() {
  local out= rc=0
  out=$(cd "$PROJECT" && "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json" 2>&1) || rc=$?
  assert_eq 1 "$rc" "state.sh init refused the plan"
  assert_contains "$out" "open decision"
  [ ! -e "$RUN_DIR/state.json" ] || fail "a refused plan left a state file"
}

init_starts() {
  (cd "$PROJECT" && "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json") >/dev/null \
    || fail "state.sh init refused the plan"
  [ -f "$RUN_DIR/state.json" ] || fail "no state file"
}

# --------------------------------------------------------- the flag blocks

test_an_open_decision_in_the_draft_is_listed_under_needs_your_attention_and_init_refuses() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  build "$TEST_TMPDIR/draft.json"
  assert_eq '[{"ticket":"10","case":"incomplete","harm":"the export menu offers PDF but nothing writes one","recommendation":"drop PDF from the menu until a ticket writes it"}]' \
    "$(jq -c .open_decision_flags "$TEST_TMPDIR/plan.json")"
  local out=; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Needs your attention"
  assert_contains "$out" "| #10 (Ticket 10) | incomplete | the export menu offers PDF but nothing writes one | drop PDF from the menu until a ticket writes it |"
  assert_contains "$out" "plan.sh drop"
  assert_contains "$out" "--override-open-decision"
  assert_contains "$out" "Not approvable yet: 1 open decision(s) (above)."
  assert_not_contains "$out" "Approve as shown"
  init_refuses
}

# ----------------------------------------------------------- the override

test_an_override_with_a_reason_records_it_and_the_plan_starts() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  # A reason is required, and the ticket must carry an open decision.
  assert_status 1 "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json" --config "$PROJECT/.artisan-agent/config.yml" \
    --override-open-decision 10
  assert_status 1 "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/draft.json" --config "$PROJECT/.artisan-agent/config.yml" \
    --override-open-decision 13 --why "no decision there"
  build "$TEST_TMPDIR/draft.json" --override-open-decision 10 --why "PDF lands in this run's wave 2"
  assert_eq '[]' "$(jq -c .open_decision_flags "$TEST_TMPDIR/plan.json")"
  assert_eq '[{"ticket":"10","why":"PDF lands in this run'"'"'s wave 2"}]' "$(jq -c .open_decision_overrides "$TEST_TMPDIR/plan.json")"
  local out=; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Open-decision overrides"
  assert_contains "$out" "| #10 | incomplete: the export menu offers PDF but nothing writes one | PDF lands in this run's wave 2 |"
  assert_not_contains "$out" "### Needs your attention"
  assert_contains "$out" "Approve as shown"
  init_starts
  assert_eq '["10","11","12","13","14"]' "$(jq -c .plan.scope "$RUN_DIR/state.json")"
}

test_a_malformed_open_decision_in_the_draft_is_refused() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  local bad=
  for bad in '.open_decisions[0].harm = "  "' '.open_decisions[0].case = "unclear"' \
             '.open_decisions[0].recommendation = ""' '.open_decisions[0].ticket = "99"'; do
    jq "$bad" "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/bad.json"
    assert_status 1 "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/bad.json" --config "$PROJECT/.artisan-agent/config.yml"
  done
}

# ------------------------------------------------------------- the drop

test_drop_files_the_open_decision_at_the_plan_step_and_takes_out_the_ticket_with_its_dependents() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  # A second one, on a dependent: it leaves with #10, so it is filed too.
  jq '.open_decisions += [{ticket: "#12", case: "adr", harm: "picks the storage format every exporter reads",
                           recommendation: "an ADR for the format first"}]' "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2.json"
  mv "$TEST_TMPDIR/d2.json" "$TEST_TMPDIR/draft.json"
  echo '{"number": 40, "title": "older", "state": "open", "labels": [], "body": ""}' >"$FAKE_GH_DIR/issue-40.json"
  local out=
  out=$(cd "$PROJECT" && plan drop --draft "$TEST_TMPDIR/draft.json" 10) || fail "plan.sh drop failed: $out"
  # Filed with no run, through questions.sh: raised at the plan step,
  # non-blocking, the case, the harm and the recommendation.
  local q41= q42=
  q41=$(jq -r '.title + "|" + ([.labels[].name] | join(","))' "$FAKE_GH_DIR/issue-41.json")
  q42=$(jq -r .title "$FAKE_GH_DIR/issue-42.json")
  assert_eq "Open decision in #10: the export menu offers PDF but nothing writes one|needs-triage" "$q41"
  assert_eq "Open decision in #12: picks the storage format every exporter reads" "$q42"
  local body=; body=$(jq -r .body "$FAKE_GH_DIR/issue-41.json")
  assert_contains "$body" "Raised at: plan, by the plan step."
  assert_contains "$body" "incomplete: the feature would be incomplete"
  assert_contains "$body" "drop PDF from the menu until a ticket writes it"
  assert_contains "$body" "Filed without blocking #10"
  [ ! -e "$FAKE_GH_DIR/blocked_by-10.json" ] || fail "the plan step blocked #10 on its open decision"
  assert_contains "$out" "#41"
  assert_contains "$out" "#11, #12, #14"
  # The ticket and its dependents (blocked_by, through #11 to #12, and its
  # Human check) leave scope, waves, tickets and gates; #13 stays.
  assert_eq '["13"]' "$(jq -c .scope "$TEST_TMPDIR/draft.json")"
  assert_eq '[["13"]]' "$(jq -c .waves "$TEST_TMPDIR/draft.json")"
  assert_eq '["13"]' "$(jq -c '.tickets | keys' "$TEST_TMPDIR/draft.json")"
  assert_eq '[{"kind":"slice","tickets":["13"]},{"kind":"end"}]' "$(jq -c .gates "$TEST_TMPDIR/draft.json")"
  assert_eq '[]' "$(jq -c .open_decisions "$TEST_TMPDIR/draft.json")"
  assert_eq '[{"ticket":"10","title":"Ticket 10","filed":["41","42"],"dependents":["11","12","14"]}]' \
    "$(jq -c .dropped "$TEST_TMPDIR/draft.json")"
  assert_eq "draft.json" "$(ls "$TEST_TMPDIR" | grep draft)" "no temp file left beside the draft"
  # The rebuilt plan is approvable and starts.
  build "$TEST_TMPDIR/draft.json"
  assert_eq '[]' "$(jq -c .open_decision_flags "$TEST_TMPDIR/plan.json")"
  out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Out of the run for the Decision chat"
  assert_contains "$out" "| #10 (Ticket 10) | #41, #42 | #11, #12, #14 |"
  assert_contains "$out" "Approve as shown"
  init_starts
  assert_eq '["13"]' "$(jq -c .plan.scope "$RUN_DIR/state.json")"
}

test_drop_refuses_a_ticket_with_no_open_decision_and_changes_nothing() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  local before=; before=$(cksum <"$TEST_TMPDIR/draft.json")
  assert_status 1 "$SCRIPTS/plan.sh" drop --draft "$TEST_TMPDIR/draft.json" 13
  assert_status 1 "$SCRIPTS/plan.sh" drop --draft "$TEST_TMPDIR/draft.json" 99
  assert_eq "$before" "$(cksum <"$TEST_TMPDIR/draft.json")"
  assert_eq "" "$(ls "$FAKE_GH_DIR")" "nothing filed"
}

test_a_failed_filing_leaves_the_ticket_in_and_a_retry_does_not_file_twice() {
  make_project
  draft_with_decision "$TEST_TMPDIR/draft.json"
  jq '.open_decisions += [{ticket: "11", case: "invented", harm: "the retry banner text is not in the ticket",
                           recommendation: "say nothing new"}]' "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2.json"
  mv "$TEST_TMPDIR/d2.json" "$TEST_TMPDIR/draft.json"
  # The first filing lands; the tracker is gone for the second.
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\nn=$(ls "$FAKE_GH_DIR" | grep -c issue-)\n[ "$n" -lt 1 ] || exit 1\nexec "%s" "$@"\n' \
    "$TESTS_DIR/fixtures/fake-gh/gh" >"$TEST_TMPDIR/bin/gh"
  chmod +x "$TEST_TMPDIR/bin/gh"
  assert_status 1 env PATH="$TEST_TMPDIR/bin:$PATH" "$SCRIPTS/plan.sh" drop --draft "$TEST_TMPDIR/draft.json" 10
  assert_eq '["10","11","12","13","14"]' "$(jq -c .scope "$TEST_TMPDIR/draft.json")"
  assert_eq '["1",null]' "$(jq -c '[.open_decisions[].filed]' "$TEST_TMPDIR/draft.json")"
  (cd "$PROJECT" && plan drop --draft "$TEST_TMPDIR/draft.json" 10) >/dev/null || fail "the retry failed"
  assert_eq "issue-1.json issue-2.json" "$(ls "$FAKE_GH_DIR" | grep issue- | tr '\n' ' ' | sed 's/ $//')"
  assert_eq '["1","2"]' "$(jq -c '.dropped[0].filed' "$TEST_TMPDIR/draft.json")"
}

# ------------------------------------------------------------ the skill

test_the_plan_step_checks_every_ticket_against_criterion_8_citing_its_reference() {
  local step=
  step=$(sed -n '/^### 3\. Get the plan approved/,/^### 4\./p' "$PLUGIN_ROOT/skills/implement-plan/SKILL.md")
  assert_contains "$step" "criterion 8"
  assert_contains "$step" '${CLAUDE_PLUGIN_ROOT}/references/open-decisions.md'
  assert_contains "$step" "open_decisions"
  assert_contains "$step" "plan.sh drop"
  assert_contains "$step" "--override-open-decision"
}
