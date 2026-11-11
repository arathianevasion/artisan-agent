# Tests for the worker skill /artisan-agent:implement: its citations, the
# evidence-record shape and checker, and the sample tickets that live.sh runs
# headless. The headless runs themselves spend money and are run by hand.

SKILL="$PLUGIN_ROOT/skills/implement/SKILL.md"
EVIDENCE="$PLUGIN_ROOT/references/evidence-record.md"
CHECK="$TESTS_DIR/implement/check-evidence-record.sh"
LIVE="$TESTS_DIR/implement/live.sh"

frontmatter() { awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$1"; }

example_record() { # the JSON block under "## Example" in evidence-record.md
  awk '/^## Example/ { f = 1; next } f && /^```json/ { g = 1; next } g && /^```/ { exit } g' "$EVIDENCE"
}

test_the_skill_is_claude_callable() {
  local fm
  fm=$(frontmatter "$SKILL")
  assert_contains "$fm" "name: implement"
  case "$fm" in
    *disable-model-invocation*) fail "SKILL.md must not set disable-model-invocation" ;;
  esac
}

test_the_skill_cites_the_shared_references_rather_than_copying_them() {
  local body
  body=$(cat "$SKILL")
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/ARTISAN.md'
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/references/decision-record.md'
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/references/evidence-record.md'
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md'
  case "$body" in
    *'| `guardrail_level`'*) fail "SKILL.md copies decision-record.md's fields" ;;
  esac
}

test_every_plugin_path_the_skill_and_evidence_record_cite_exists() {
  local path
  for path in $(grep -ho '\${CLAUDE_PLUGIN_ROOT}/[A-Za-z0-9_./-]*[A-Za-z0-9_]' "$SKILL" "$EVIDENCE" | sort -u); do
    [ -f "$PLUGIN_ROOT/${path#\$\{CLAUDE_PLUGIN_ROOT\}/}" ] || fail "cited path does not exist: $path"
  done
}

test_the_evidence_record_extends_the_decision_record_without_redefining_it() {
  local body
  body=$(cat "$EVIDENCE")
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/references/decision-record.md'
  case "$body" in
    *'| `job` |'* | *'| `guardrail_level` |'* | *'| `redirect` |'*)
      fail "evidence-record.md redefines a decision-record.md field" ;;
  esac
}

test_the_documented_example_is_a_valid_evidence_record() {
  example_record > example.json
  [ -s example.json ] || fail "no example found in evidence-record.md"
  "$CHECK" example.json || fail "the documented example fails the checker"
}

test_the_checker_rejects_a_malformed_record_and_names_each_problem() {
  local out status=0
  example_record | jq '.status = "done" | del(.base) | .decisions[0].kind = "taste"
    | .review.remarks[0].disposition = "not_acted"' > bad.json
  out=$("$CHECK" bad.json) || status=$?
  assert_eq 1 "$status" "checker exit status"
  assert_contains "$out" "record: missing base"
  assert_contains "$out" 'status: "done" is not one of'
  assert_contains "$out" 'decisions[0].kind: "taste" is not one of'
  assert_contains "$out" "review.remarks[0]: not_acted needs why"
}

test_the_checker_rejects_a_file_that_is_not_json() {
  echo "status: complete" > notes.txt
  assert_status 1 "$CHECK" notes.txt
}

test_each_sample_ticket_sets_up_a_repo_whose_suite_passes() {
  local scenario
  for scenario in named-seam unnamed-seam public-interface review-seeds; do
    "$LIVE" setup "$scenario" "$scenario"
    (cd "$scenario/repo" && python3 -m unittest -q >/dev/null 2>&1) || fail "$scenario: suite fails before the worker starts"
    [ -z "$(git -C "$scenario/repo" status --porcelain)" ] || fail "$scenario: setup left the tree dirty"
  done
}

test_the_review_seeds_are_really_there_before_the_worker_starts() {
  "$LIVE" setup review-seeds wd
  (cd wd/repo && python3 -c 'from shop import shipping; assert shipping(5000) == 499') \
    || fail "the seeded boundary bug is missing"
  grep -q 'print(' wd/repo/shop.py || fail "the seeded print() violation is missing"
  grep -q 'Library modules never call `print()`' wd/repo/CODING_STANDARDS.md || fail "the standard it violates is missing"
}

test_verify_fails_on_every_sample_before_a_worker_has_run() {
  local scenario out
  for scenario in named-seam unnamed-seam public-interface review-seeds; do
    "$LIVE" setup "$scenario" "$scenario"
    out=$("$LIVE" verify "$scenario" "$scenario" 2>&1) && fail "$scenario: verify passed with no worker run"
    assert_contains "$out" "FAIL a result file exists"
  done
}

test_the_skill_stops_only_for_something_another_ticket_owns() {
  local body
  body=$(tr '\n' ' ' < "$SKILL")
  assert_contains "$body" "Stop only when the ticket can't be built without changing the design or interface of something another ticket owns"
  assert_contains "$body" "including when it is a new public interface"
  assert_contains "$body" "**carry on**"
  case "$body" in
    *"If the seam changes an interface another ticket owns, or a schema or stored data"*) fail "SKILL.md still stops for a schema or any hard-to-reverse seam" ;;
    *"Stop and finish with status \`blocked\`, with the question and your recommendation in the record. "*) fail "SKILL.md still stops for every controversial decision" ;;
  esac
}
