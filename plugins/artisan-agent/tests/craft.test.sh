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
