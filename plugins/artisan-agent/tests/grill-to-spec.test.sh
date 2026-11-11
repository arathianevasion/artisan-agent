# Static checks on /artisan-agent:grill and /artisan-agent:to-spec (live behaviour
# is checked by capped headless sessions; see skills/grill/VERIFICATION.md).

GRILL="$PLUGIN_ROOT/skills/grill/SKILL.md"
TOSPEC="$PLUGIN_ROOT/skills/to-spec/SKILL.md"

template_of() { sed -n '/<spec-template>/,/<\/spec-template>/p' "$1"; }

test_skills_have_frontmatter_name_and_description() {
  local f name
  for name in grill to-spec; do
    f="$PLUGIN_ROOT/skills/$name/SKILL.md"
    [ "$(sed -n '1p' "$f")" = "---" ] || fail "$name: no frontmatter"
    grep -q "^name: $name\$" "$f" || fail "$name: name mismatch"
    grep -q '^description: .\{20,\}' "$f" || fail "$name: description missing"
  done
}

test_skills_never_mention_replaced_grill_skills() {
  assert_eq 0 "$(cat "$GRILL" "$TOSPEC" | grep -Ec 'grill-me|grill-with-docs' || true)" "a skill names a replaced grilling skill"
}

test_grill_always_loads_grilling_and_domain_modeling() {
  grep -q '`grilling`' "$GRILL" || fail "grill does not name grilling"
  grep -q '`domain-modeling`' "$GRILL" || fail "grill does not name domain-modeling"
  grep -qi 'always both' "$GRILL" || fail "grill does not say both are always loaded"
}

test_grill_offers_debate_research_and_prototype() {
  grep -q '/artisan-agent:debate-me' "$GRILL" || fail "no debate-me offer"
  grep -q '`research`' "$GRILL" || fail "no research"
  grep -q '`prototype`' "$GRILL" || fail "no prototype"
  grep -qi 'without asking approval' "$GRILL" || fail "research is not autonomous"
}

test_grill_question_format_has_options_recommendation_and_loser() {
  grep -q 'Options:' "$GRILL" || fail "no options"
  grep -q 'Recommend' "$GRILL" || fail "no recommendation"
  grep -q 'lost because' "$GRILL" || fail "no strongest-alternative reason"
}

test_grill_records_glossary_and_adr_in_session() {
  grep -q 'GLOSSARY.md' "$GRILL" || fail "no glossary"
  grep -q 'docs/adr' "$GRILL" || fail "no ADR"
  grep -qi 'same session' "$GRILL" || fail "no same-session rule"
}

test_to_spec_shows_draft_and_lists_additions_before_publishing() {
  grep -q 'Show the draft before publishing' "$TOSPEC" || fail "no draft step"
  grep -q 'Additions to accept or cut' "$TOSPEC" || fail "no additions list"
  grep -q "Don't publish until" "$TOSPEC" || fail "no publish gate"
  grep -qi 'cut must not appear' "$TOSPEC" || fail "cut lines may be published"
}

test_to_spec_keeps_upstream_template_and_seam_check() {
  local up h
  up=$(ls "$HOME"/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/*/skills/engineering/to-spec/SKILL.md 2>/dev/null | tail -n 1 || true)
  if [ -n "$up" ] && [ -f "$up" ]; then
    assert_eq "$(template_of "$up")" "$(template_of "$TOSPEC")" "spec template differs from upstream"
  fi
  for h in '## Problem Statement' '## Solution' '## User Stories' '## Implementation Decisions' '## Testing Decisions' '## Out of Scope' '## Further Notes'; do
    template_of "$TOSPEC" | grep -qxF "$h" || fail "template lacks $h"
  done
  grep -q 'Sketch the seams' "$TOSPEC" || fail "no seam check"
  grep -q 'ideal number is one' "$TOSPEC" || fail "seam guidance dropped"
}

test_skills_cite_plugin_files_that_exist() {
  local f ref rel
  for f in "$GRILL" "$TOSPEC"; do
    for ref in $(grep -o '\${CLAUDE_PLUGIN_ROOT}/[A-Za-z0-9_./-]*' "$f" | sort -u); do
      rel=${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}
      rel=${rel%.}
      [ -f "$PLUGIN_ROOT/$rel" ] || fail "$f cites missing $ref"
    done
  done
}

test_skills_avoid_workflow_as_a_term() {
  if grep -qi 'workflow' "$GRILL" "$TOSPEC"; then fail "uses 'workflow'; say pipeline"; fi
  return 0
}
