# The project config and the plan step's run envelope (#55): config fallback,
# per-run overrides kept out of config.yml, both estimate modes, the approval
# text, and the refusal of tickets outside the approved scope.

. "$TESTS_DIR/helpers/run-state.sh"

config() { "$SCRIPTS/config.sh" "$@"; }
plan() { "$SCRIPTS/plan.sh" "$@"; }

# write_draft path: two tickets, one Sonnet and one Opus, in two waves.
write_draft() {
  jq -n '{
    run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
    scope: ["10", "11"], waves: [["10"], ["11"]], gates: [{kind: "end"}],
    tickets: {
      "10": {title: "Retry failed uploads", model: "claude-sonnet-5-5",
             expected_output: "uploads retry twice",
             expected: {input_tokens: 2000000, output_tokens: 100000, minutes: 30}},
      "11": {title: "Billing tab", model: "claude-opus-5-5",
             expected_output: "billing tab shows invoices",
             expected: {input_tokens: 1000000, output_tokens: 50000, minutes: 45}}
    }}' >"$1"
}

# seed_history run-id ticket model cost status: a past run's state file.
seed_history() {
  local dir="$PROJECT/.artisan-agent/runs/$1"
  mkdir -p "$dir"
  jq -n --arg run "$1" --arg t "$2" --arg m "$3" --argjson c "$4" --arg s "$5" '{
    schema_version: 1, run_id: $run,
    plan: {tickets: {($t): {model: $m}}},
    tickets: {($t): {status: $s, cost_usd: $c}}}' >"$dir/state.json.tmp"
  if [ -f "$dir/state.json" ]; then
    jq -s '.[0] * .[1]' "$dir/state.json" "$dir/state.json.tmp" >"$dir/state.json.next"
    mv "$dir/state.json.next" "$dir/state.json"
    rm -f "$dir/state.json.tmp"
  else
    mv "$dir/state.json.tmp" "$dir/state.json"
  fi
}

config_sum() { cksum <"$PROJECT/.artisan-agent/config.yml"; }

# ------------------------------------------------------------------ config

test_defaults_hold_every_setting_from_the_ticket_table() {
  local d
  d=$(config defaults)
  assert_eq 5 "$(jq .max_agents <<<"$d")" "Max Agents"
  assert_eq 5 "$(jq .sweep_minutes <<<"$d")" "sweep"
  assert_eq 30 "$(jq .context.drain_percent <<<"$d")" "context drain"
  assert_eq 50 "$(jq .context.review_percent <<<"$d")" "context review"
  assert_eq 25 "$(jq .overrun_allowance_percent <<<"$d")" "overrun allowance"
  assert_eq 20 "$(jq .usage_reserve.five_hour_reserve_percent <<<"$d")" "5-hour reserve"
  assert_eq 90 "$(jq .usage_reserve.seven_day_ceiling_percent <<<"$d")" "7-day limit"
  assert_eq 10 "$(jq .stale_usage_minutes <<<"$d")" "stale usage reading"
  assert_eq 2 "$(jq .attempts_per_ticket <<<"$d")" "attempts per ticket"
  assert_eq 30 "$(jq .deferral_review_days <<<"$d")" "deferral review"
  assert_eq 3 "$(jq .evidence_threshold <<<"$d")" "evidence threshold"
  assert_eq 5 "$(jq .hands_on_nudge_runs <<<"$d")" "hands-on nudge"
  assert_eq '{}' "$(jq -c .areas <<<"$d")" "areas"
  assert_eq null "$(jq .team_guardrails_repo <<<"$d")" "team guardrails repo"
  assert_eq '{}' "$(jq -c .estimate_multipliers <<<"$d")" "estimate multipliers"
  assert_eq false "$(jq .host_configured <<<"$d")" "host configured"
}

test_a_project_with_no_config_file_gets_every_default() {
  make_project
  rm "$PROJECT/.artisan-agent/config.yml"
  assert_eq "$(config defaults | jq -cS .)" "$(cd "$PROJECT" && config show | jq -cS .)"
}

test_missing_and_empty_keys_fall_back_to_their_defaults() {
  make_project
  printf 'max_agents: 3\ncontext:\n  drain_percent: 40\nsweep_minutes:\n' >"$PROJECT/.artisan-agent/config.yml"
  local c
  c=$(cd "$PROJECT" && config show)
  assert_eq 3 "$(jq .max_agents <<<"$c")"
  assert_eq 40 "$(jq .context.drain_percent <<<"$c")"
  assert_eq 50 "$(jq .context.review_percent <<<"$c")" "sibling of a set key"
  assert_eq 5 "$(jq .sweep_minutes <<<"$c")" "empty key"
  assert_eq 2 "$(jq .attempts_per_ticket <<<"$c")" "missing key"
  assert_eq 50 "$(cd "$PROJECT" && config get context.review_percent)"
}

test_a_wrongly_typed_or_unsupported_config_is_refused() {
  make_project
  printf 'max_agents: lots\n' >"$PROJECT/.artisan-agent/config.yml"
  assert_status 1 config show --file "$PROJECT/.artisan-agent/config.yml"
  local err
  err=$(config show --file "$PROJECT/.artisan-agent/config.yml" 2>&1 || true)
  assert_contains "$err" "max_agents must be number"
  printf 'areas:\n  - name: billing\n' >"$PROJECT/.artisan-agent/config.yml"
  err=$(config show --file "$PROJECT/.artisan-agent/config.yml" 2>&1 || true)
  assert_contains "$err" "line 2"
}

test_areas_and_multipliers_are_read() {
  make_project
  cat >"$PROJECT/.artisan-agent/config.yml" <<'EOF'
areas:
  billing:
    paths: [src/billing/, db/]
    gates:
      - risk
estimate_multipliers: {all: 1.1, claude-opus-5-5: 1.3}
team_guardrails_repo: owner/guardrails  # the team's repo
EOF
  local c
  c=$(cd "$PROJECT" && config show)
  assert_eq '["src/billing/","db/"]' "$(jq -c .areas.billing.paths <<<"$c")"
  assert_eq '["risk"]' "$(jq -c .areas.billing.gates <<<"$c")"
  assert_eq 1.3 "$(jq '.estimate_multipliers["claude-opus-5-5"]' <<<"$c")"
  assert_eq owner/guardrails "$(jq -r .team_guardrails_repo <<<"$c")"
}

test_the_committed_project_config_is_valid() {
  local repo_config="$PLUGIN_ROOT/../../.artisan-agent/config.yml"
  [ -f "$repo_config" ] || fail "no committed .artisan-agent/config.yml at the repo root"
  config show --file "$repo_config" >/dev/null
}

# --------------------------------------------------------------- estimates

test_with_no_history_estimates_come_from_model_price_and_expected_size() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  # Sonnet 5.5: 2M in x $2 + 0.1M out x $10 = $5.00. Opus 5.5: 1M x $4 + 0.05M x $20 = $5.00.
  assert_eq 5 "$(jq '.tickets["10"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq price "$(jq -r '.tickets["10"].estimate_basis.mode' "$TEST_TMPDIR/plan.json")"
  assert_eq 5 "$(jq '.tickets["11"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq 10 "$(jq .estimate_usd "$TEST_TMPDIR/plan.json")" "total"
  assert_eq 12.5 "$(jq .budget_usd "$TEST_TMPDIR/plan.json")" "total + 25% overrun allowance"
  # Caps as run-ticket.sh applies them: 2x budget, 40 turns per dollar, 2x minutes.
  assert_eq '{"max_budget_usd":10,"max_turns":200,"deadline_seconds":3600}' \
    "$(jq -c '.tickets["10"].caps' "$TEST_TMPDIR/plan.json")"
}

test_with_history_estimates_come_from_logged_costs_times_the_multiplier() {
  make_project
  printf 'estimate_multipliers:\n  claude-sonnet-5-5: 1.5\n' >"$PROJECT/.artisan-agent/config.yml"
  seed_history old1 20 claude-sonnet-5-5 3 merged
  seed_history old2 21 claude-sonnet-5-5 5 merged
  seed_history old2 22 claude-sonnet-5-5 99 blocked  # not merged: ignored
  seed_history r1 23 claude-sonnet-5-5 77 merged     # this run itself: ignored
  write_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  # mean(3, 5) = 4, x 1.5 = 6.
  assert_eq 6 "$(jq '.tickets["10"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq '{"mode":"history","tickets":2,"mean_usd":4,"multiplier":1.5}' \
    "$(jq -c '.tickets["10"].estimate_basis' "$TEST_TMPDIR/plan.json")"
  # Opus has no history: still from price and size.
  assert_eq price "$(jq -r '.tickets["11"].estimate_basis.mode' "$TEST_TMPDIR/plan.json")"
  assert_eq 11 "$(jq .estimate_usd "$TEST_TMPDIR/plan.json")"
}

test_the_all_multiplier_applies_to_models_without_their_own() {
  make_project
  printf 'estimate_multipliers:\n  all: 2\n' >"$PROJECT/.artisan-agent/config.yml"
  seed_history old1 20 claude-opus-5-5 4 merged
  write_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  assert_eq 8 "$(jq '.tickets["11"].estimate_usd' "$TEST_TMPDIR/plan.json")"
}

# tiny_draft path: one Sonnet ticket far under any minimum, one Opus ticket above it.
tiny_draft() {
  jq -n '{
    run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
    scope: ["10", "11"], waves: [["10", "11"]], gates: [],
    tickets: {
      "10": {title: "Typo", model: "claude-sonnet-5-5",
             expected: {input_tokens: 100000, output_tokens: 5000, minutes: 10}},
      "11": {title: "Billing tab", model: "claude-opus-5-5",
             expected: {input_tokens: 1000000, output_tokens: 50000, minutes: 45}}
    }}' >"$1"
}

test_an_estimate_below_the_models_minimum_is_raised_to_it() {
  make_project
  tiny_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  # Sonnet: 0.1M x $2 + 0.005M x $10 = $0.25, under the $0.50 minimum.
  assert_eq 0.5 "$(jq '.tickets["10"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq minimum "$(jq -r '.tickets["10"].estimate_basis.mode' "$TEST_TMPDIR/plan.json")"
  assert_eq 0.25 "$(jq '.tickets["10"].estimate_basis.estimated_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq 1 "$(jq '.tickets["10"].caps.max_budget_usd' "$TEST_TMPDIR/plan.json")" "twice the minimum"
  assert_eq 20 "$(jq '.tickets["10"].caps.max_turns' "$TEST_TMPDIR/plan.json")"
  # Opus: $5.00, above its $1.00 minimum: unchanged.
  assert_eq 5 "$(jq '.tickets["11"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq price "$(jq -r '.tickets["11"].estimate_basis.mode' "$TEST_TMPDIR/plan.json")"
  # Total and budget use the floored numbers: 0.5 + 5 = 5.5, + 25%.
  assert_eq 5.5 "$(jq .estimate_usd "$TEST_TMPDIR/plan.json")"
  assert_eq 6.88 "$(jq .budget_usd "$TEST_TMPDIR/plan.json")"
  local out
  out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "| #10 (Typo) | claude-sonnet-5-5 | \$0.50 | minimum for claude-sonnet-5-5 (estimated \$0.25) |"
  assert_contains "$out" "| minimum_estimates.claude-sonnet-5-5 | 0.5 |"
}

test_the_floor_applies_to_history_estimates_and_falls_back_to_all() {
  make_project
  seed_history old1 20 claude-sonnet-5-5 0.1 merged
  tiny_draft "$TEST_TMPDIR/draft.json"
  jq '.tickets["11"].model = "claude-other-1"' "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2.json"
  seed_history old2 21 claude-other-1 0.2 merged
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/d2.json") >"$TEST_TMPDIR/plan.json"
  assert_eq 0.5 "$(jq '.tickets["10"].estimate_usd' "$TEST_TMPDIR/plan.json")"
  assert_eq history "$(jq -r '.tickets["10"].estimate_basis.was.mode' "$TEST_TMPDIR/plan.json")"
  assert_eq 0.5 "$(jq '.tickets["11"].estimate_usd' "$TEST_TMPDIR/plan.json")" "the all minimum"
}

test_a_minimum_can_be_overridden_for_one_run_and_every_priced_model_has_a_default() {
  make_project
  tiny_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json" \
    --set minimum_estimates.claude-sonnet-5-5=0.2) >"$TEST_TMPDIR/plan.json"
  assert_eq 0.25 "$(jq '.tickets["10"].estimate_usd' "$TEST_TMPDIR/plan.json")" "above the lowered minimum"
  assert_eq price "$(jq -r '.tickets["10"].estimate_basis.mode' "$TEST_TMPDIR/plan.json")"
  assert_contains "$(plan render "$TEST_TMPDIR/plan.json")" "| minimum_estimates.claude-sonnet-5-5 | 0.2 (this run only; project: 0.5) |"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "config.yml untouched"
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --set minimum_estimates.claude-sonnet-5-5=-1"
  local m
  for m in $(jq -r '.models | keys[]' "$PLUGIN_ROOT/references/model-prices.json"); do
    [ "$(config defaults | jq --arg m "$m" '.minimum_estimates[$m] > 0')" = true ] || fail "no default minimum for $m"
  done
}

test_a_model_with_no_price_and_no_history_is_refused() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  jq '.tickets["10"].model = "claude-unknown-1"' "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2.json"
  local err
  err=$(cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/d2.json" 2>&1 || true)
  assert_contains "$err" "no price for model claude-unknown-1"
}

# ---------------------------------------------------------------- approval

test_the_approval_shows_waves_models_estimates_max_agents_and_every_number() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  local out key
  out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "### Wave 1"
  assert_contains "$out" "### Wave 2"
  assert_contains "$out" "| #10 (Retry failed uploads) | claude-sonnet-5-5 | \$5.00 |"
  assert_contains "$out" "| #11 (Billing tab) | claude-opus-5-5 | \$5.00 |"
  assert_contains "$out" "Total estimate: \$10.00"
  assert_contains "$out" "Max Agents: 5"
  for key in max_agents sweep_minutes context.drain_percent context.review_percent \
    chat_context.warn_percent chat_context.compact_percent chat_context.window_tokens \
    overrun_allowance_percent usage_reserve.five_hour_reserve_percent \
    usage_reserve.seven_day_ceiling_percent stale_usage_minutes attempts_per_ticket \
    deferral_review_days evidence_threshold hands_on_nudge_runs areas \
    team_guardrails_repo estimate_multipliers minimum_estimates.claude-sonnet-5-5 \
    minimum_estimates.all host_configured; do
    assert_contains "$out" "| $key |" "setting $key in the approval"
  done
}

test_the_approval_shows_expected_files_and_warns_once_per_ticket_without_them() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  jq '.tickets["10"].expected_files = ["src/up/", "tests/up.sh"]' "$TEST_TMPDIR/draft.json" >"$TEST_TMPDIR/d2.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/d2.json") >"$TEST_TMPDIR/plan.json"
  local out; out=$(plan render "$TEST_TMPDIR/plan.json")
  assert_contains "$out" "| Expected files |"
  assert_contains "$out" '| `src/up/`, `tests/up.sh` |'
  assert_contains "$out" "| none declared |"
  # A blank line separates the table from the warning, so it isn't read as a table row.
  assert_eq "" "$(printf '%s\n' "$out" | grep -B1 'runs alone' | head -1)" "blank line before the warning"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'runs alone')" "one warning, for the undeclared ticket"
  assert_contains "$out" "#11 runs alone: no expected files, so it's treated as touching everything. Name its files to let it share a wave."
  # The Wave column is gone; the headings keep the grouping.
  ! printf "%s" "$out" | grep -qF -- "| Wave |" || fail "unexpected: ""| Wave |"
  assert_contains "$out" "### Wave 2"
  # A fully declared plan prints no warning.
  jq '.tickets["11"].expected_files = ["src/billing/"]' "$TEST_TMPDIR/d2.json" >"$TEST_TMPDIR/d3.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/d3.json") >"$TEST_TMPDIR/plan3.json"
  out=$(plan render "$TEST_TMPDIR/plan3.json")
  ! printf "%s" "$out" | grep -qF -- "runs alone" || fail "unexpected: ""runs alone"
  ! printf "%s" "$out" | grep -qF -- "none declared" || fail "unexpected: ""none declared"
}

# --------------------------------------------------------------- overrides

test_a_plan_step_override_changes_the_plan_but_not_the_committed_config() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  local before
  before=$(config_sum)
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json" \
    --set max_agents=2 --set context.drain_percent=35) >"$TEST_TMPDIR/plan.json"
  assert_eq 2 "$(jq .max_agents "$TEST_TMPDIR/plan.json")"
  assert_eq 35 "$(jq .config.context.drain_percent "$TEST_TMPDIR/plan.json")"
  assert_eq '{"value":2,"project":5}' "$(jq -c .overrides.max_agents "$TEST_TMPDIR/plan.json")"
  assert_contains "$(plan render "$TEST_TMPDIR/plan.json")" "| max_agents | 2 (this run only; project: 5) |"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  assert_eq 2 "$(state_get .plan.max_agents)"
  assert_eq 35 "$(state_get .plan.config.context.drain_percent)"
  assert_eq "$before" "$(config_sum)" "config.yml unchanged"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "nothing committed changed"
}

test_an_override_during_the_run_changes_the_state_file_but_not_the_config() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  local before
  before=$(config_sum)
  "$SCRIPTS/state.sh" override "$RUN_DIR" attempts_per_ticket 3
  "$SCRIPTS/state.sh" override "$RUN_DIR" attempts_per_ticket 4
  assert_eq 4 "$(state_get .plan.attempts_per_ticket)" "the sweep reads this"
  assert_eq 4 "$(state_get .plan.config.attempts_per_ticket)"
  assert_eq '{"value":4,"project":2}' "$(state_get '.plan.overrides.attempts_per_ticket | tojson')"
  "$SCRIPTS/state.sh" override "$RUN_DIR" overrun_allowance_percent 50
  assert_eq 15 "$(state_get .plan.budget_usd)" "budget follows the overrun allowance (10 + 50%)"
  assert_eq "$before" "$(config_sum)" "config.yml unchanged"
  assert_eq 2 "$(cd "$PROJECT" && config get attempts_per_ticket)"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "nothing committed changed"
}

test_an_override_of_an_unknown_key_or_with_the_wrong_type_is_refused() {
  make_project
  write_draft "$TEST_TMPDIR/draft.json"
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --set nope=1"
  assert_status 1 sh -c "cd '$PROJECT' && '$SCRIPTS/plan.sh' build --draft '$TEST_TMPDIR/draft.json' --set max_agents=many"
  (cd "$PROJECT" && plan build --draft "$TEST_TMPDIR/draft.json") >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  local before
  before=$(state_sum)
  assert_status 1 "$SCRIPTS/state.sh" override "$RUN_DIR" max_agents -1
  assert_status 1 "$SCRIPTS/state.sh" override "$RUN_DIR" nope 3
  local err
  err=$("$SCRIPTS/state.sh" override "$RUN_DIR" max_agents.x 3 2>&1 || true)
  assert_contains "$err" "max_agents.x is not a setting"
  assert_eq "$before" "$(state_sum)" "state file untouched"
}

# ----------------------------------------------------------------- refusal

test_a_ticket_outside_the_approved_scope_is_refused_at_dispatch() {
  trap kill_workers EXIT
  init_run
  local pid before
  pid=$(start_worker)
  # Even with an entry slipped into tickets, scope is what was approved.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["99"] = .tickets["10"]'
  before=$(state_sum)
  assert_status 4 "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 99 "$pid"
  assert_eq "$before" "$(state_sum)" "state file untouched"
  assert_status 4 "$SCRIPTS/state.sh" in-scope "$RUN_DIR" 99
  assert_status 0 "$SCRIPTS/state.sh" in-scope "$RUN_DIR" 10
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$pid"
  assert_eq in_flight "$(state_get '.tickets["10"].status')"
}

test_run_ticket_never_launches_a_worker_outside_the_approved_scope() {
  init_run
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/wt"
  printf '#!/bin/sh\ntouch "%s/claude-ran"\n' "$TEST_TMPDIR" >"$TEST_TMPDIR/bin/claude"
  chmod +x "$TEST_TMPDIR/bin/claude"
  printf 'Build it.\n' >"$TEST_TMPDIR/prompt.md"
  local got=0
  PATH="$TEST_TMPDIR/bin:$PATH" "$SCRIPTS/run-ticket.sh" --run-dir "$RUN_DIR" --ticket 99 \
    --prompt-file "$TEST_TMPDIR/prompt.md" --workdir "$TEST_TMPDIR/wt" \
    --estimate-usd 1 --expected-minutes 10 >/dev/null 2>"$TEST_TMPDIR/err" || got=$?
  assert_eq 4 "$got" "exit status"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "not in the approved scope"
  [ ! -e "$RUN_DIR/workers/99.1" ] || fail "a worker folder was created"
  [ ! -e "$TEST_TMPDIR/claude-ran" ] || fail "claude ran"
}
