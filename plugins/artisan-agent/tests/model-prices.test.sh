# The price check (#91): scripts/model-prices.sh on a copy of the price file and a stub claude.
# No network.

MP="$PLUGIN_ROOT/scripts/model-prices.sh"

setup_prices() {
  export ARTISAN_PRICES_FILE="$TEST_TMPDIR/model-prices.json"
  cp "$PLUGIN_ROOT/references/model-prices.json" "$ARTISAN_PRICES_FILE"
  export ARTISAN_TODAY=2027-01-02
}

# A stub claude that writes $PUBLISHED_JSON to the answer path named in the prompt.
stub_claude() {
  cat >"$TEST_TMPDIR/claude" <<'S'
#!/bin/bash
out=$(printf '%s' "$*" | sed -n 's/.*Write your answer to: \([^ ]*published.json\).*/\1/p' | head -1)
printf '%s' "$*" >"$(dirname "$out")/prompt-seen"
[ -z "${PUBLISHED_JSON:-}" ] || printf '%s' "$PUBLISHED_JSON" >"$out"
echo '{"result":"done"}'
S
  chmod +x "$TEST_TMPDIR/claude"
  export ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude"
}

test_matching_prices_say_no_change_and_leave_the_file_alone() {
  setup_prices; stub_claude
  export PUBLISHED_JSON; PUBLISHED_JSON=$(jq -c '{models}' "$ARTISAN_PRICES_FILE")
  local before out; before=$(cat "$ARTISAN_PRICES_FILE")
  out=$(bash "$MP" run "$TEST_TMPDIR/w")
  assert_eq "no price change" "$out"
  assert_eq "$before" "$(cat "$ARTISAN_PRICES_FILE")" "file changed"
}

test_a_changed_new_and_dropped_model_are_tabled_and_offered() {
  setup_prices; stub_claude
  export PUBLISHED_JSON='{"models":{"claude-opus-5-5":{"input_per_mtok":5,"output_per_mtok":25},"claude-sonnet-5-5":{"input_per_mtok":2,"output_per_mtok":10},"claude-haiku-5-5":{"input_per_mtok":0.1,"output_per_mtok":0.5},"claude-new-6":{"input_per_mtok":1,"output_per_mtok":3}}}'
  local out rc=0
  out=$(bash "$MP" run "$TEST_TMPDIR/w") || rc=$?
  assert_eq 10 "$rc" "exit"
  assert_contains "$out" "| claude-opus-5-5 | \$4 / \$20 | \$5 / \$25 |"
  assert_contains "$out" "| claude-new-6 | not recorded | \$1 / \$3 |"
  assert_contains "$out" "| claude-fable-5-2 | \$8 / \$40 | no longer published |"
  assert_contains "$out" "Update model prices?"
  case "$out" in *"claude-sonnet-5-5 |"*) fail "unchanged model listed" ;; esac
}

test_the_brief_and_recorded_file_reach_the_agent() {
  setup_prices; stub_claude
  export PUBLISHED_JSON; PUBLISHED_JSON=$(jq -c '{models}' "$ARTISAN_PRICES_FILE")
  bash "$MP" fetch "$TEST_TMPDIR/w"
  assert_contains "$(cat "$TEST_TMPDIR/w/prompt-seen")" "Model prices check"
  assert_contains "$(cat "$TEST_TMPDIR/w/prompt-seen")" "$ARTISAN_PRICES_FILE"
}

test_apply_updates_rates_and_date_keeps_dropped_models() {
  setup_prices
  printf '%s' '{"models":{"claude-opus-5-5":{"input_per_mtok":5,"output_per_mtok":25},"claude-new-6":{"input_per_mtok":1,"output_per_mtok":3}}}' >"$TEST_TMPDIR/p.json"
  bash "$MP" apply "$TEST_TMPDIR/p.json" >/dev/null
  assert_eq 5 "$(jq '.models["claude-opus-5-5"].input_per_mtok' "$ARTISAN_PRICES_FILE")"
  assert_eq 3 "$(jq '.models["claude-new-6"].output_per_mtok' "$ARTISAN_PRICES_FILE")"
  assert_eq 40 "$(jq '.models["claude-fable-5-2"].output_per_mtok * 1' "$ARTISAN_PRICES_FILE")" "dropped model deleted"
  assert_contains "$(jq -r '._source' "$ARTISAN_PRICES_FILE")" "as of 2027-01-02"
  local out; out=$(bash "$MP" compare "$TEST_TMPDIR/p.json" || true)
  case "$out" in *"claude-opus-5-5 |"*) fail "applied model still differs" ;; esac
}

test_an_agent_that_writes_nothing_or_nonsense_fails_and_changes_nothing() {
  setup_prices; stub_claude
  local before; before=$(cat "$ARTISAN_PRICES_FILE")
  unset PUBLISHED_JSON
  assert_status 1 bash "$MP" run "$TEST_TMPDIR/w"
  export PUBLISHED_JSON='{"models":{"claude-opus-5-5":{"input_per_mtok":"free","output_per_mtok":0}}}'
  assert_status 1 bash "$MP" run "$TEST_TMPDIR/w"
  assert_eq "$before" "$(cat "$ARTISAN_PRICES_FILE")"
}

test_no_arguments_is_bad_usage() {
  assert_status 2 bash "$MP"
}
