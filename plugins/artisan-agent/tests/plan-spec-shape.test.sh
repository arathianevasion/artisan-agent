# plan.sh build checks the draft's spec shape (#270): {number, title}. A bare
# string ("66") once passed the plan step and failed the first wave launch,
# when run_title read .plan.spec.title. A draft with no spec still builds.

. "$TESTS_DIR/helpers/run-state.sh"

# draft path spec-json|"" : a one-ticket draft, with the spec when given.
draft() {
  jq -n --arg s "${2:-}" '
    {run_id: "r1", repo: "owner/repo", integration_branch: "run/r1", scope: ["10"],
     waves: [["10"]],
     tickets: {"10": {title: "T", model: "claude-sonnet-5-5", blocked_by: [],
                      acceptance: ["a"], expected: {input_tokens: 1000, output_tokens: 100, minutes: 5}}}}
    | if $s == "" then . else .spec = ($s | fromjson) end' >"$1"
}

build_in_project() { (cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$1" 2>&1); }

test_a_bare_string_spec_is_refused_naming_the_shape() {
  make_project
  draft "$TEST_TMPDIR/d.json" '"66"'
  local out= rc=0
  out=$(build_in_project "$TEST_TMPDIR/d.json") || rc=$?
  assert_eq 1 "$rc" "build refused the string spec"
  assert_contains "$out" "{number, title}"
}

test_a_spec_missing_its_title_or_number_is_refused() {
  make_project
  local s=
  for s in 'false' '{"number":66}' '{"title":"X"}' '{"number":"66","title":"X"}' '{"number":66,"title":7}'; do
    draft "$TEST_TMPDIR/d.json" "$s"
    local out= rc=0
    out=$(build_in_project "$TEST_TMPDIR/d.json") || rc=$?
    assert_eq 1 "$rc" "build refused spec $s"
    assert_contains "$out" "{number, title}"
  done
}

test_a_valid_spec_builds_and_is_carried_into_the_plan() {
  make_project
  draft "$TEST_TMPDIR/d.json" '{"number":66,"title":"Run view"}'
  local out=; out=$(cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/d.json") || fail "valid spec refused"
  assert_eq '{"number":66,"title":"Run view"}' "$(jq -c .spec <<<"$out")"
}

test_a_draft_without_a_spec_still_builds() {
  make_project
  draft "$TEST_TMPDIR/d.json" ""
  (cd "$PROJECT" && "$SCRIPTS/plan.sh" build --draft "$TEST_TMPDIR/d.json") >/dev/null || fail "spec-less draft refused"
}
