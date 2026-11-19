# Static checks on ARTISAN.md rule 7 (voice standards) and the skills that cite
# it. They check rule numbers and citations, never the wording, so tuning the
# wording doesn't break them.

ARTISAN="$PLUGIN_ROOT/ARTISAN.md"

test_artisan_has_rule_7_and_tuning_names_voice_standards() {
  grep -Eq '^7\. ' "$ARTISAN" || fail "ARTISAN.md has no rule 7"
  grep -Eq '^6\. ' "$ARTISAN" || fail "ARTISAN.md lost rule 6"
  if grep -Eq '^8\. ' "$ARTISAN"; then fail "ARTISAN.md has a rule 8"; fi
  local rule7= tuning=
  rule7=$(grep -E '^7\. ' "$ARTISAN")
  assert_contains "$rule7" "VOICE_STANDARDS.md"
  assert_contains "$rule7" "ADR 0003"
  tuning=$(awk '/^## Tuning/ { f = 1; next } /^## / { f = 0 } f' "$ARTISAN")
  assert_contains "$tuning" "voice standards"
}

test_skills_that_write_shared_text_cite_the_voice_standards() {
  local f=
  for f in skills/implement/SKILL.md skills/implement-plan/SKILL.md skills/triage/SKILL.md skills/triage/AGENT-BRIEF.md; do
    assert_contains "$(cat "$PLUGIN_ROOT/$f")" "VOICE_STANDARDS.md" "$f does not cite the voice standards"
  done
}

test_skills_that_reach_rule_7_by_artisan_md_are_not_edited_to_cite_voice() {
  local s=
  for s in craft to-spec to-plan grill debate-me resolve-conflicts; do
    assert_not_contains "$(cat "$PLUGIN_ROOT/skills/$s/SKILL.md")" "VOICE_STANDARDS.md" "$s cites voice directly"
  done
}
