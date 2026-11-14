# ci-checklist.sh (#196): the CI checklist setup prints. Fixtures: a riley-like
# repo (unsharded e2e, retries 0, no caching) and a claudia-like one (every item
# in place). Read-only, bash 3.2-safe.

CL="$PLUGIN_ROOT/skills/setup/scripts/ci-checklist.sh"
FIX="$TESTS_DIR/fixtures/ci-checklist"

ITEMS="Shard the slow suite
Cache dependencies and browsers
Cheap checks first, fail fast
Cancel superseded runs
Skip a tree that already passed
Retry in the job, with a quarantine list
One gate command
No second run on main
Docs-only changes run nothing
Per-test timings kept
The merge-gate time limit is recorded"

# status of one item in a table
status_of() { # table item
  printf '%s\n' "$1" | awk -F'|' -v item="$2" '{ n=$2; gsub(/^ +| +$/, "", n); if (n == item) { s=$3; gsub(/ /, "", s); print s } }'
}

all_are() { # table status
  local item=
  while IFS= read -r item; do
    assert_eq "$2" "$(status_of "$1" "$item")" "$item"
  done <<EOF2
$ITEMS
EOF2
}

test_riley_like_workflow_has_every_item_missing() {
  all_are "$("$CL" "$FIX/riley")" missing
}

test_claudia_like_workflow_has_every_item_present() {
  all_are "$("$CL" "$FIX/claudia")" present
}

test_a_repo_with_no_workflow_has_every_item_na() {
  all_are "$("$CL" "$FIX/none")" n/a
}

test_each_row_has_a_how_to_and_a_reference_link() {
  local out= line=
  out=$("$CL" "$FIX/riley")
  assert_eq 13 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "header, rule and 11 items"
  while IFS= read -r line; do
    assert_contains "$line" '`${CLAUDE_PLUGIN_ROOT}/references/ci.md#'
  done <<EOF2
$(printf '%s\n' "$out" | tail -n +3)
EOF2
  assert_contains "$out" "retries: 0 today"
}

test_every_reference_link_has_an_entry_in_the_reference() {
  local a= out=
  out=$("$CL" "$FIX/riley")
  for a in $(printf '%s\n' "$out" | grep -o 'ci.md#[a-z-]*' | sed 's/ci.md#//'); do
    grep -q "^## $a\$" "$PLUGIN_ROOT/references/ci.md" || fail "no entry ## $a in references/ci.md"
  done
}

test_it_never_changes_the_repo() {
  local d="$TEST_TMPDIR/copy" before= after=
  mkdir -p "$d" && cp -R "$FIX/claudia/." "$d/"
  before=$(cd "$d" && find . -type f | sort | xargs cksum; find . -type f -newer "$CL" | wc -l)
  "$CL" "$d" >/dev/null
  after=$(cd "$d" && find . -type f | sort | xargs cksum; find . -type f -newer "$CL" | wc -l)
  assert_eq "$before" "$after"
}

test_a_retry_without_a_quarantine_list_is_missing() {
  local d="$TEST_TMPDIR/r" out=
  mkdir -p "$d" && cp -R "$FIX/riley/." "$d/"
  printf 'export default defineConfig({ retries: 2 });\n' >"$d/playwright.config.ts"
  out=$("$CL" "$d")
  assert_eq missing "$(status_of "$out" "Retry in the job, with a quarantine list")"
  assert_contains "$out" "retries are set but no quarantine list"
  printf 'a.spec.ts: x #1 flaky\n' >"$d/quarantine.txt"
  assert_eq present "$(status_of "$("$CL" "$d")" "Retry in the job, with a quarantine list")"
}

test_a_workflow_filter_without_skip_paths_is_missing() {
  local d="$TEST_TMPDIR/c" out=
  mkdir -p "$d" && cp -R "$FIX/claudia/." "$d/"
  printf 'merge_gate_skip_paths: []\n' >"$d/.artisan-agent/config.yml"
  out=$("$CL" "$d")
  assert_eq missing "$(status_of "$out" "Docs-only changes run nothing")"
  assert_contains "$out" "merge_gate_skip_paths is empty"
  assert_eq missing "$(status_of "$out" "The merge-gate time limit is recorded")"
}

test_no_push_trigger_makes_no_second_run_on_main_na() {
  local d="$TEST_TMPDIR/p" out=
  mkdir -p "$d" && cp -R "$FIX/riley/." "$d/"
  printf 'name: CI\non:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm test\n' >"$d/.github/workflows/ci.yml"
  assert_eq n/a "$(status_of "$("$CL" "$d")" "No second run on main")"
}

test_a_cache_used_as_the_record_is_flagged() {
  local d="$TEST_TMPDIR/k" out=
  mkdir -p "$d/.github/workflows"
  printf 'on:\n  push:\njobs:\n  t:\n    steps:\n      - uses: actions/cache@v4\n        with:\n          key: passed-${{ github.sha }}-tree\n          path: .passed\n' >"$d/.github/workflows/ci.yml"
  out=$("$CL" "$d")
  assert_eq missing "$(status_of "$out" "Skip a tree that already passed")"
  assert_contains "$out" "a cache is used as the record"
}

test_the_reference_says_why_actions_cache_cannot_hold_the_record() {
  local r="$PLUGIN_ROOT/references/ci.md"
  grep -q 'cannot be restored by the base branch' "$r" || fail "missing the GitHub quote"
  grep -q 'actions/artifacts?name=' "$r" || fail "missing the artifact lookup"
  grep -q 'merge commit' "$r" || fail "missing the merge-commit rule"
  grep -q 'names the run it relied on' "$r" || fail "missing the named run"
  grep -q 'run in full' "$r" || fail "missing the failed-lookup rule"
  grep -q 'retries hide real flakes' "$r" || fail "missing the retries trade-off"
}

test_bad_usage_exits_2() {
  assert_status 2 "$CL" "$TEST_TMPDIR/does-not-exist"
}
