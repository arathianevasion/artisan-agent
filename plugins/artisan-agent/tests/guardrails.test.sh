# guardrails.sh: the three guardrail levels read at the point of use. A
# project repo (product), a team repo cloned from a local "remote" and an
# individual home, all under $TEST_TMPDIR; nothing outside it is touched.

. "$TESTS_DIR/helpers/run-state.sh"

G="$SCRIPTS/guardrails.sh"

# jsonl_line file id key value strict [scope]
rec() { jq -nc --arg id "$1" --arg k "$2" --arg v "$3" --argjson s "$4" --arg scope "${5:-}" --arg role "${6:-}" \
  '{id: $id, key: $k, value: $v, strict: $s, rule: "rule \($id)", origin: {date: "2026-01-01T00:00:00Z", reason: "seed"}, moves: []}
   + (if $scope == "" then {} else {scope: $scope} end) + (if $role == "" then {} else {role: $role} end)'; }

commit_all() { git_quiet -C "$1" add -A; git_quiet -C "$1" commit -m "${2:-change}"; }

# setup_levels: product repo with a run and its integration worktree, a team
# repo named in config, and an individual home. Sets HOME_DIR, TEAM_SRC.
setup_levels() {
  init_run
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/home"
  export ARTISAN_TEAM_CACHE="$TEST_TMPDIR/teamcache" ARTISAN_TEAM_URL_BASE="$TEST_TMPDIR/teamsrc/"
  export ARTISAN_WRITER_PID=$$
  TEAM_SRC="$TEST_TMPDIR/teamsrc/acme/guardrails"
  mkdir -p "$TEAM_SRC" "$ARTISAN_HOME"
  git_quiet -C "$TEAM_SRC" init
  : >"$TEAM_SRC/guardrails.jsonl"
  commit_all "$TEAM_SRC" "team init"
  git_quiet -C "$ARTISAN_HOME" init
  git -C "$ARTISAN_HOME" symbolic-ref HEAD refs/heads/main
  : >"$ARTISAN_HOME/guardrails.jsonl"
  commit_all "$ARTISAN_HOME" "home init"
  printf 'max_agents: 5\nteam_guardrails_repo: acme/guardrails\n' >"$PROJECT/.artisan-agent/config.yml"
  mkdir -p "$PROJECT/.artisan-agent"
  : >"$PROJECT/.artisan-agent/guardrails.jsonl"
  commit_all "$PROJECT" "product guardrails"
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  cd "$PROJECT"
}

test_wave_start_records_each_source_commit_and_the_plugin_version() {
  setup_levels
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  assert_eq "$(git -C "$TEAM_SRC" rev-parse HEAD)" "$(state_get '.waves[0].guardrails.team')"
  assert_eq "$(git -C "$PROJECT" rev-parse main)" "$(state_get '.waves[0].guardrails.product')"
  assert_eq "$(git -C "$ARTISAN_HOME" rev-parse HEAD)" "$(state_get '.waves[0].guardrails.individual')"
  assert_eq "$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json")" "$(state_get '.waves[0].plugin_version')"
}

test_a_change_committed_between_waves_applies_from_the_next_wave() {
  setup_levels
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  # Committed after wave 1 started: wave 1 still reads the old commits.
  rec ind-1 review-depth deep 1 >"$ARTISAN_HOME/guardrails.jsonl"
  commit_all "$ARTISAN_HOME" "tighten"
  rec team-1 commit-style small 1 >"$TEAM_SRC/guardrails.jsonl"
  commit_all "$TEAM_SRC" "team change"
  assert_eq 0 "$("$G" resolve --run-dir "$RUN_DIR" | jq '.applied | length')"
  "$G" wave-start "$RUN_DIR" 2 >/dev/null
  assert_eq "$(git -C "$ARTISAN_HOME" rev-parse HEAD)" "$(state_get '.waves[1].guardrails.individual')"
  assert_eq "$(git -C "$TEAM_SRC" rev-parse HEAD)" "$(state_get '.waves[1].guardrails.team')"
  assert_eq "commit-style review-depth" "$("$G" resolve --run-dir "$RUN_DIR" | jq -r '[.applied[].key] | sort | join(" ")')"
}

test_a_product_guardrail_change_on_main_comes_into_the_integration_branch() {
  setup_levels
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  # An ordinary change on main is not a guardrail change: not brought in.
  echo hi >"$PROJECT/other.txt"; commit_all "$PROJECT" "ordinary"
  "$G" wave-start "$RUN_DIR" 2 | jq -e '.main_merged == false' >/dev/null
  [ ! -e "$(state_get .integration.worktree)/other.txt" ] || fail "an ordinary change was merged"
  rec prod-1 pr-boundary per-ticket 1 >"$PROJECT/.artisan-agent/guardrails.jsonl"
  commit_all "$PROJECT" "product guardrail"
  "$G" wave-start "$RUN_DIR" 3 | jq -e '.main_merged == true' >/dev/null
  wt=$(state_get .integration.worktree)
  [ -s "$wt/.artisan-agent/guardrails.jsonl" ] || fail "main's guardrail did not reach the integration branch"
  git -C "$wt" merge-base --is-ancestor "$(git -C "$PROJECT" rev-parse main)" HEAD || fail "main is not in the integration branch"
  assert_eq "$(git -C "$PROJECT" rev-parse main)" "$(state_get '.waves[2].guardrails.product')"
  assert_eq guardrail-merge "$(state_get '[.events[] | select(.event == "guardrail-merge")] | last | .event')"
}

test_a_guardrail_change_that_conflicts_queues_a_decision_and_records_no_wave() {
  setup_levels
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  wt=$(state_get .integration.worktree)
  rec a x 1 1 >"$wt/.artisan-agent/guardrails.jsonl"; commit_all "$wt" "integration edit"
  rec b x 2 1 >"$PROJECT/.artisan-agent/guardrails.jsonl"; commit_all "$PROJECT" "main edit"
  assert_status 6 "$G" wave-start "$RUN_DIR" 2
  assert_eq 1 "$(state_get '.waves | length')"
  assert_eq exception "$(state_get '.decisions[0].kind')"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "the failed merge was left half done"
}

test_tightening_in_the_chat_writes_the_individual_level_with_origin_and_applies_next_wave() {
  setup_levels
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  "$G" tighten --level individual --who Andrew --reason "reviews were too shallow" --run r1 \
    --key review-depth --value deep --rule "Review every diff line" --strict 2 >/dev/null
  assert_eq 0 "$("$G" resolve --run-dir "$RUN_DIR" | jq '.applied | length')"   # not this wave
  assert_eq clean "$([ -z "$(git -C "$ARTISAN_HOME" status --porcelain)" ] && echo clean)"
  line=$(tail -1 "$ARTISAN_HOME/guardrails.jsonl")
  assert_eq "r1 reviews were too shallow Andrew" "$(jq -r '[.origin.run, .origin.reason, .origin.who] | join(" ")' <<<"$line")"
  jq -e '.origin.date | test("^20")' <<<"$line" >/dev/null
  "$G" wave-start "$RUN_DIR" 2 >/dev/null
  assert_eq deep "$("$G" resolve --run-dir "$RUN_DIR" | jq -r '.applied[0].value')"
}

test_tightening_an_existing_guardrail_records_the_move_and_refuses_a_loosening() {
  setup_levels
  "$G" tighten --level individual --who Andrew --reason first --key k --value a --rule r --strict 2 >/dev/null
  "$G" tighten --level individual --who Andrew --id k --reason "second" --evidence "3 misses" --value b --strict 3 >/dev/null
  assert_eq "1 3 3 misses Andrew" "$(jq -r '[(.moves | length), .strict, .moves[0].evidence, .moves[0].who] | join(" ")' "$ARTISAN_HOME/guardrails.jsonl")"
  before=$(git -C "$ARTISAN_HOME" rev-parse HEAD)
  assert_status 5 "$G" tighten --level individual --who Andrew --id k --reason x --value c --strict 1
  assert_eq "$before" "$(git -C "$ARTISAN_HOME" rev-parse HEAD)"
  assert_status 2 "$G" tighten --level individual --who "agent worker-1" --id k --reason x --strict 9
}

test_tightening_at_product_level_makes_a_branch_that_applies_once_merged() {
  setup_levels
  main_before=$(git -C "$PROJECT" rev-parse main)
  "$G" tighten --level product --who Andrew --reason "cut per ticket" --key pr-boundary --value per-ticket \
    --rule "One PR per ticket" --strict 2 >/dev/null
  assert_eq "$main_before" "$(git -C "$PROJECT" rev-parse main)"   # a PR, never a direct commit
  br=$(git -C "$PROJECT" branch --list 'guardrail/*' | tr -d ' *+')
  git -C "$PROJECT" show "$br:.artisan-agent/guardrails.jsonl" | jq -e '.origin.reason == "cut per ticket"' >/dev/null
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  git -C "$PROJECT" merge -q --ff-only "$br" 2>/dev/null || git -C "$PROJECT" -c user.name=T -c user.email=t@e merge -q "$br" >/dev/null 2>&1
  "$G" wave-start "$RUN_DIR" 2 >/dev/null
  assert_eq per-ticket "$("$G" resolve --run-dir "$RUN_DIR" | jq -r '.applied[0].value')"
}

test_tightening_at_team_level_branches_the_team_repo() {
  setup_levels
  "$G" tighten --level team --who Andrew --reason "shared taste" --key naming --value strict --rule "Name things" >/dev/null
  assert_eq 1 "$(git -C "$TEAM_SRC" log --oneline | wc -l | tr -d ' ')"
  br=$(git -C "$ARTISAN_TEAM_CACHE/acme_guardrails" branch --list 'guardrail/*' | tr -d ' *+')
  git -C "$ARTISAN_TEAM_CACHE/acme_guardrails" show "$br:guardrails.jsonl" | jq -e '.key == "naming"' >/dev/null
}

test_seeded_contradictions_resolve_by_precedence() {
  setup_levels
  { rec p-1 pr-boundary per-ticket 1
    rec p-2 reviews skim 1; } >"$PROJECT/.artisan-agent/guardrails.jsonl"
  commit_all "$PROJECT" product
  { rec t-1 pr-boundary per-plan 1
    rec t-2 reviews standard 5
    rec t-3 naming long 1; } >"$TEAM_SRC/guardrails.jsonl"
  commit_all "$TEAM_SRC" team
  { rec i-1 pr-boundary per-slice 9
    rec i-2 naming short 1
    rec i-3 reviews thorough 9 own-reviews
    rec i-4 spelling british 1; } >"$ARTISAN_HOME/guardrails.jsonl"
  commit_all "$ARTISAN_HOME" individual
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  out=$("$G" resolve --run-dir "$RUN_DIR")
  val() { jq -r --arg k "$1" '.applied[] | select(.key == $k) | "\(.level):\(.value)"' <<<"$out"; }
  assert_eq product:per-ticket "$(val pr-boundary)"   # product beats team and a stricter individual
  assert_eq product:skim "$(val reviews)"             # product beats team (strict 5) for everyone
  assert_eq team:long "$(val naming)"                 # team beats individual
  assert_eq individual:british "$(val spelling)"      # an individual guardrail fills a gap
  # The stricter individual review guardrail applies to the Artisan's own gates only.
  assert_eq "individual:thorough" "$(jq -r '.own_reviews[] | "\(.level):\(.value)"' <<<"$out")"
  assert_eq "naming pr-boundary reviews" "$(jq -r '.conflicts | join(" ")' <<<"$out")"
  assert_eq "i-1 i-2 t-1 t-2" "$(jq -r '[.overridden[].id] | sort | join(" ")' <<<"$out")"
}

test_a_pairs_individual_guardrails_apply_only_to_their_own_role() {
  setup_levels
  { rec i-1 taste-a one 1 "" product
    rec i-2 taste-b two 1 "" engineering
    rec i-3 taste-c three 1; } >"$ARTISAN_HOME/guardrails.jsonl"
  commit_all "$ARTISAN_HOME" individual
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  assert_eq "taste-a taste-c" "$("$G" resolve --run-dir "$RUN_DIR" --role product | jq -r '[.applied[].key] | sort | join(" ")')"
  assert_eq "taste-b taste-c" "$("$G" resolve --run-dir "$RUN_DIR" --role engineering | jq -r '[.applied[].key] | sort | join(" ")')"
}

test_the_packet_table_lists_guardrails_applied_with_versions() {
  setup_levels
  rec p-1 pr-boundary per-ticket 1 >"$PROJECT/.artisan-agent/guardrails.jsonl"; commit_all "$PROJECT" product
  rec t-1 pr-boundary per-plan 1 >"$TEAM_SRC/guardrails.jsonl"; commit_all "$TEAM_SRC" team
  "$G" wave-start "$RUN_DIR" 1 >/dev/null
  out=$("$G" table --run-dir "$RUN_DIR")
  assert_contains "$out" "| Guardrail | Level | Version | Says |"
  assert_contains "$out" "| p-1 | product | $(git -C "$PROJECT" rev-parse --short=7 main) | pr-boundary = per-ticket |"
  assert_contains "$out" "| t-1 | team | $(git -C "$TEAM_SRC" rev-parse --short=7 HEAD) | p-1 (product) |"
}

test_working_as_a_pair_doc_ships_in_the_plugin() {
  f="$PLUGIN_ROOT/WORKING-AS-A-PAIR.md"
  [ -s "$f" ] || fail "missing $f"
  for w in "tracker" "who" "joint retro" "private" "product beats team"; do
    grep -qi "$w" "$f" || fail "the pair doc does not say: $w"
  done
}
