# Static checks on /artisan-agent:grill and /artisan-agent:to-spec (live behaviour
# is checked by capped headless sessions; see skills/grill/VERIFICATION.md).

GRILL="$PLUGIN_ROOT/skills/grill/SKILL.md"
TOSPEC="$PLUGIN_ROOT/skills/to-spec/SKILL.md"

template_of() { sed -n '/<spec-template>/,/<\/spec-template>/p' "$1"; }

test_skills_have_frontmatter_name_and_description() {
  local f= name=
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
  local up= h=
  up=$(ls "$HOME"/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/*/skills/engineering/to-spec/SKILL.md 2>/dev/null | tail -n 1 || true)
  if [ -n "$up" ] && [ -f "$up" ]; then
    assert_eq "$(template_of "$up")" "$(template_of "$TOSPEC")" "spec template differs from upstream"
  fi
  for h in '## Problem Statement' '## Solution' '## User Stories' '## Implementation Decisions' '## Testing Decisions' '## Out of Scope' '## Further Notes'; do
    template_of "$TOSPEC" | grep -xF "$h" >/dev/null || fail "template lacks $h"
  done
  grep -q 'Sketch the seams' "$TOSPEC" || fail "no seam check"
  grep -q 'ideal number is one' "$TOSPEC" || fail "seam guidance dropped"
}

test_skills_cite_plugin_files_that_exist() {
  local f= ref= rel=
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

test_to_spec_checks_draft_against_the_motivation() {
  local n_check="" n_show=""
  grep -qF 'motivations/<repo>.md' "$TOSPEC" || fail "to-spec does not name motivations/<repo>.md"
  grep -qF 'individual home' "$TOSPEC" || fail "to-spec does not name the individual home"
  grep -qF '## Motivation check' "$TOSPEC" || fail "no Motivation check heading"
  grep -qF '## Additions to accept or cut' "$TOSPEC" || fail "no additions heading"
  grep -qF 'strongest alternative' "$TOSPEC" || fail "motivation items lack the strongest alternative"
  grep -qF 'Batch both lists' "$TOSPEC" || fail "motivation check not in the same batch"
  n_check=$(grep -n 'Check the draft against the motivation' "$TOSPEC" | head -n 1 | cut -d: -f1)
  n_show=$(grep -n 'Show the draft before publishing' "$TOSPEC" | head -n 1 | cut -d: -f1)
  [ -n "$n_check" ] && [ -n "$n_show" ] && [ "$n_check" -lt "$n_show" ] || fail "motivation step not before the draft is shown"
}

test_to_spec_keeps_the_motivation_out_of_the_spec() {
  grep -qF 'contains no text from the motivation' "$TOSPEC" || fail "no ban on motivation text"
  grep -qF 'Scope never widens to match the motivation without the Artisan' "$TOSPEC" || fail "no scope rule"
}

test_to_spec_reads_always_ask_lines_at_the_motivation_step() {
  grep -qF '"Always ask" lines' "$TOSPEC" || fail "no Always ask lines"
  grep -qF 'individual and project `PRODUCT_STANDARDS.md`' "$TOSPEC" || fail "no individual and project PRODUCT_STANDARDS.md"
}

test_to_spec_without_a_motivation_file_changes_nothing() {
  grep -qF 'With no motivation file, nothing changes' "$TOSPEC" || fail "no-motivation-file behaviour unsaid"
}

test_grill_experience_pass_ends_with_the_journey_diff_in_words() {
  local sec=; sec=$(sed -n '/^## Experience pass/,/^## Record/p' "$GRILL")
  assert_contains "$sec" 'journey diff in words'
  assert_contains "$sec" '/artisan-agent:design'
}

test_wayfinder_is_not_edited() {
  [ ! -e "$PLUGIN_ROOT/skills/wayfinder" ] || fail "wayfinder ships in the plugin (ADR 0001)"
}

# #328: the design package comes into the spec as its Experience section.
test_to_spec_writes_an_experience_section_only_with_a_design_package() {
  local s=
  s=$(sed -n '/^## Experience section/,/^## /p' "$TOSPEC")
  [ -n "$s" ] || fail "to-spec has no Experience section instructions"
  grep -q 'design package' <<<"$s" || fail "Experience section is not tied to the design package"
  grep -qi 'affected journeys' <<<"$s" || fail "no affected journeys"
  grep -qi 'journey diff' <<<"$s" || fail "no journey diff link"
  grep -qi 'changed step' <<<"$s" || fail "no changed steps"
  grep -qi 'screenshot' <<<"$s" || fail "no design screenshots"
  grep -qi 'why' <<<"$s" || fail "no experience whys"
  grep -qi 'no design package.*no Experience section\|without a design package.*no Experience section' <<<"$s" || fail "Experience section is not left out without a package"
}

test_to_spec_shows_the_journey_diff_as_always_ask_in_review() {
  grep -q '^ *## Always ask: journey diff' "$TOSPEC" || fail "spec review has no journey diff Always ask block"
  grep -qi 'approving the spec approves this design package' "$TOSPEC" || fail "spec approval does not cover the package"
  grep -qi 'no second approval' "$TOSPEC" || fail "a second approval is not ruled out"
}

test_to_spec_tells_tickets_to_cite_journey_steps_by_name() {
  grep -q 'Each ticket written from it cites the journey steps it builds by name' "$TOSPEC" || fail "tickets are not told to cite steps by name"
  grep -q '`Steps: <journey>: <step>, …`' "$TOSPEC" || fail "no step citation line for tickets"
}

test_jobs_list_has_design_the_experience_and_job_8_covers_the_package() {
  local jobs="$PLUGIN_ROOT/references/jobs.md"
  grep -q '^| 25 | Design the experience: direct the prototype and any high-fidelity design | Human-led | Product (design) | Solution |$' "$jobs" || fail "no design-the-experience job"
  grep -q '^| 8 | Approve the spec, including its design package |' "$jobs" || fail "job 8 does not cover the design package"
  grep -q '^| 21 | Decide which lessons become guardrails' "$jobs" || fail "job 21 was renumbered"
}
