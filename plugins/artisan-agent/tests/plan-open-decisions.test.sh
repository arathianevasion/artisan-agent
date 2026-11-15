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
