# adr-check.sh: the ADR and guardrail check at plan approval (#67), seeded with
# ADRs and, for the guardrail half, real guardrail files at two levels.

. "$TESTS_DIR/helpers/run-state.sh"

AC="$PLUGIN_ROOT/scripts/adr-check.sh"
REF="$PLUGIN_ROOT/references/adr-check.md"

seed_adrs() {
  ADRS="$TEST_TMPDIR/adr"
  mkdir -p "$ADRS"
  printf '# Layer on upstream skills\n\nbody\n' >"$ADRS/0001-layer-on-upstream.md"
  printf '# Scripts are bash 3.2-safe\n\nbody\n' >"$ADRS/0002-bash-three.md"
  CHECK="$TEST_TMPDIR/check.json"
  cat >"$CHECK" <<'JSON'
{"plan_adrs": [
   {"adr": "0001", "compliance": "complies", "note": "adds skills beside upstream"},
   {"adr": "0002", "compliance": "complies", "note": "all scripts bash"}],
 "tickets": [
   {"ticket": "12", "title": "Fork the grill skill", "adrs": [{"adr": "0001", "tension": true, "note": "copies upstream | not layering"}]},
   {"ticket": "13", "title": "Add a script", "adrs": [{"adr": "0002", "tension": false, "note": ""}]},
   {"ticket": "14", "title": "Docs only", "adrs": []}],
 "gaps": [{"decision": "Which queue library", "tickets": ["13", "14"], "suggestion": "record an ADR"}]}
JSON
}

test_approval_opens_with_plan_compliance_ticket_tension_and_gaps() {
  seed_adrs
  local out; out=$("$AC" render "$CHECK" --adr-dir "$ADRS")
  assert_contains "$out" "### The plan against its ADRs"
  assert_contains "$out" "| 0001 | Layer on upstream skills | complies | adds skills beside upstream |"
  assert_contains "$out" "| #12 (Fork the grill skill) | 0001 | TENSION | copies upstream \\| not layering |"
  assert_contains "$out" "| #13 (Add a script) | 0002 | none |  |"
  assert_contains "$out" "| #14 (Docs only) | none | none |"
  assert_contains "$out" "| Which queue library | #13, #14 | record an ADR |"
  # plan compliance comes first, then tickets, then gaps
  local a b c
  a=$(printf '%s\n' "$out" | grep -n 'The plan against' | cut -d: -f1)
  b=$(printf '%s\n' "$out" | grep -n 'Each ticket against' | cut -d: -f1)
  c=$(printf '%s\n' "$out" | grep -n 'no ADR covers' | cut -d: -f1)
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || fail "sections out of order"
}

test_an_adr_with_no_file_is_refused() {
  seed_adrs
  jq '.tickets[0].adrs[0].adr = "0099"' "$CHECK" >"$CHECK.2"
  assert_status 1 "$AC" render "$CHECK.2" --adr-dir "$ADRS"
  assert_contains "$("$AC" render "$CHECK.2" --adr-dir "$ADRS" 2>&1 || true)" "0099"
}

test_no_gaps_and_no_adrs_say_so() {
  seed_adrs
  echo '{"plan_adrs": [], "tickets": [], "gaps": []}' >"$CHECK"
  local out; out=$("$AC" render "$CHECK" --adr-dir "$ADRS")
  assert_contains "$out" "No ADR applies to this plan."
  assert_contains "$out" "No gaps found."
  assert_contains "$out" "Guardrails not checked."
}

test_refs_finds_the_adrs_a_ticket_cites_and_ignores_unknown_ones() {
  seed_adrs
  local out
  out=$(printf 'Must respect ADR 0001 and ADR-2; see docs/adr/0002-bash-three.md, not ADR 0077.\n' | "$AC" refs --adr-dir "$ADRS")
  assert_eq "0001
0002" "$out"
  assert_eq "" "$(printf 'nothing here\n' | "$AC" refs --adr-dir "$ADRS")"
}

test_list_names_each_adr() {
  seed_adrs
  assert_eq "0001 Layer on upstream skills" "$("$AC" list --adr-dir "$ADRS" | jq -r '.[0] | "\(.number) \(.title)"')"
}

test_affected_names_the_tickets_to_recheck_after_an_adr_changes() {
  seed_adrs
  assert_eq "12" "$("$AC" affected "$CHECK" --adr 1 --adr-dir "$ADRS")"
  assert_eq "13" "$("$AC" affected "$CHECK" --adr 0002 --adr-dir "$ADRS")"
}

# Real guardrail files at the product and individual levels, in conflict.
test_a_seeded_conflict_between_levels_is_flagged_with_the_level_that_applies() {
  seed_adrs
  make_project
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/home"
  mkdir -p "$ARTISAN_HOME"
  git_quiet -C "$ARTISAN_HOME" init
  git -C "$ARTISAN_HOME" symbolic-ref HEAD refs/heads/main
  jq -nc '{id: "i1", key: "pr-boundary", value: "per-ticket", strict: false, rule: "one PR per ticket", origin: {date: "2026-01-01T00:00:00Z", reason: "seed"}, moves: []}' >"$ARTISAN_HOME/guardrails.jsonl"
  git_quiet -C "$ARTISAN_HOME" add -A; git_quiet -C "$ARTISAN_HOME" commit -m ind
  jq -nc '{id: "p1", key: "pr-boundary", value: "per-slice", strict: false, rule: "one PR per slice", origin: {date: "2026-01-01T00:00:00Z", reason: "seed"}, moves: []}' >"$PROJECT/.artisan-agent/guardrails.jsonl"
  git_quiet -C "$PROJECT" add -A; git_quiet -C "$PROJECT" commit -m prod
  (cd "$PROJECT" && "$PLUGIN_ROOT/scripts/guardrails.sh" resolve >"$TEST_TMPDIR/resolve.json")
  local out; out=$("$AC" render "$CHECK" --adr-dir "$ADRS" --guardrails "$TEST_TMPDIR/resolve.json")
  assert_contains "$out" "| pr-boundary | product: per-slice | individual: per-ticket |"
}

test_no_conflicts_is_said_plainly() {
  seed_adrs
  echo '{"applied": [], "own_reviews": [], "overridden": [], "conflicts": []}' >"$TEST_TMPDIR/r.json"
  assert_contains "$("$AC" render "$CHECK" --adr-dir "$ADRS" --guardrails "$TEST_TMPDIR/r.json")" "No conflicts between the three levels."
}

# The skills carry the check and the loop; the reference defines it.
test_both_plan_approval_paths_and_the_reference_carry_the_check_and_the_loop() {
  assert_contains "$(cat "$PLUGIN_ROOT/skills/implement-plan/SKILL.md")" 'references/adr-check.md'
  assert_contains "$(cat "$PLUGIN_ROOT/skills/to-plan/SKILL.md")" 'references/adr-check.md'
  local r; r=$(cat "$REF")
  assert_contains "$r" "guardrails.sh resolve"
  assert_contains "$r" "adr-check.sh render"
  assert_contains "$r" "adr-check.sh affected"
  assert_contains "$r" "doc-change.sh start"
  assert_contains "$r" "before dispatch"
  assert_contains "$r" "Small change"
}
