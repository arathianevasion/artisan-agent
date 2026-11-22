# Static checks (#330): the design standards are read at the point of use, so the
# design stage's entry points name them and nothing at the front door imports them.

file_text() { cat "$PLUGIN_ROOT/$1"; }

test_grill_and_the_implement_worker_brief_name_the_design_standards() {
  local f=
  for f in skills/grill/SKILL.md skills/implement/SKILL.md; do
    assert_contains "$(file_text "$f")" "DESIGN_STANDARDS.md" "$f does not name the design standards"
  done
}

test_the_design_skill_names_the_design_standards_when_it_exists() {
  local f=
  for f in "$PLUGIN_ROOT"/skills/design*/SKILL.md; do
    [ -e "$f" ] || continue
    assert_contains "$(cat "$f")" "DESIGN_STANDARDS.md" "$f does not name the design standards"
  done
}

test_the_worker_brief_reads_design_standards_only_for_a_journey_step_ticket() {
  assert_contains "$(file_text skills/implement/SKILL.md)" "changes a step of a user journey, also read the design standards"
  assert_contains "$(file_text skills/implement/SKILL.md)" "a ticket that touches no journey step reads none"
}

test_no_front_door_file_imports_the_design_standards() {
  local f= root=
  root=$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)
  # an @-import line, in any front-door file the repo or a template ships
  for f in "$root/CLAUDE.md" "$root/AGENTS.md" "$PLUGIN_ROOT"/templates/CLAUDE.md "$PLUGIN_ROOT"/templates/AGENTS.md; do
    [ -e "$f" ] || continue
    assert_not_contains "$(grep -E '^@' "$f" || true)" "DESIGN_STANDARDS" "$f imports the design standards"
  done
  # the code that writes imports (project setup, machine setup) never writes one for design
  for f in skills/setup/scripts/project-setup.sh skills/setup/scripts/project_edit.py skills/setup/scripts/machine-setup.sh; do
    assert_not_contains "$(grep -E '@[^ ]*DESIGN_STANDARDS|import_line.*DESIGN' "$PLUGIN_ROOT/$f" || true)" "DESIGN_STANDARDS" "$f writes an import of the design standards"
  done
}
