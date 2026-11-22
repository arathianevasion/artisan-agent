# Static checks on the craft skill: the route test and command naming that the
# live headless checks (skills/craft/CHECKS.md) depend on.

CRAFT="$PLUGIN_ROOT/skills/craft/SKILL.md"

test_craft_names_wayfinder_and_to_tickets_in_full() {
  local body=; body=$(cat "$CRAFT")
  assert_contains "$body" '/mattpocock-skills:wayfinder'
  assert_contains "$body" '/mattpocock-skills:to-tickets'
  # Never the bare form: a "/wayfinder" or "/to-tickets" not preceded by ":".
  if grep -Eq '(^|[^:a-z-])/(wayfinder|to-tickets)([^a-z-]|$)' "$CRAFT"; then
    fail "craft names wayfinder or to-tickets without the /mattpocock-skills: prefix"
  fi
}

test_craft_names_our_replacements() {
  local body=; body=$(cat "$CRAFT")
  for s in grill to-spec to-plan implement-plan; do
    assert_contains "$body" "/artisan-agent:$s"
  done
}

test_craft_has_the_route_test_in_order() {
  local body=; body=$(cat "$CRAFT")
  assert_contains "$body" 'propose the bigger route'
  local a= b= c=
  a=$(grep -n 'Can the destination' "$CRAFT" | head -1 | cut -d: -f1 || true)
  b=$(grep -n 'Does it need more than one ticket' "$CRAFT" | head -1 | cut -d: -f1 || true)
  c=$(grep -n 'a \*\*Bug\*\* if something is broken' "$CRAFT" | head -1 | cut -d: -f1 || true)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] || fail "route test questions not all found"
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || fail "route test questions out of order"
}

test_craft_files_straight_to_ready_for_agent_and_cites_existing_files() {
  local body=; body=$(cat "$CRAFT")
  assert_contains "$body" 'ready-for-agent'
  assert_contains "$body" '${CLAUDE_PLUGIN_ROOT}/ARTISAN.md'
  [ -f "$PLUGIN_ROOT/ARTISAN.md" ] || fail "ARTISAN.md missing"
  [ -f "$PLUGIN_ROOT/skills/triage/AGENT-BRIEF.md" ] || fail "AGENT-BRIEF.md missing"
}

# The design stage in routing (#329, ADR 0001: wayfinder stays unedited).
route_section() { sed -n "/^\*\*$1\*\*/,/^\*\*[A-Z]/p" "$CRAFT"; }

test_craft_route_proposal_asks_the_design_question_and_records_the_answer() {
  local body; body=$(sed -n '/^## 2\./,/^## 3\./p' "$CRAFT")
  assert_contains "$body" 'design question'
  assert_contains "$body" 'what a persona sees or does'
  assert_contains "$body" 'records the answer with the route'
}

test_craft_feature_and_effort_name_the_design_stage_before_to_spec() {
  local r= n=
  for r in Effort Feature; do
    local sec; sec=$(route_section "$r")
    n=$(printf '%s\n' "$sec" | grep -n '/artisan-agent:design' | head -1 | cut -d: -f1 || true)
    [ -n "$n" ] || fail "$r route does not name /artisan-agent:design"
    local s; s=$(printf '%s\n' "$sec" | grep -n '/artisan-agent:to-spec' | head -1 | cut -d: -f1 || true)
    [ -n "$s" ] || fail "$r route does not name /artisan-agent:to-spec"
    [ "$n" -lt "$s" ] || fail "$r route names design after to-spec"
  done
}

test_craft_small_change_names_light_stage_and_bug_names_skip_and_exception() {
  assert_contains "$(route_section 'Small change')" 'light design stage'
  local bug; bug=$(route_section 'Bug')
  assert_contains "$bug" 'design stage is skipped'
  assert_contains "$bug" 'unless the fix changes the journey'
}

test_craft_says_design_can_start_any_time() {
  assert_contains "$(cat "$CRAFT")" 'at any time'
}
