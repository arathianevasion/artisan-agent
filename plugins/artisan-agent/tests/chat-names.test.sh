# Static check (#235): the chats are the Decision chat and the Run chat. No
# skill, reference, script message, template, test or the root README names
# them by the names from before the rename; only the glossary's _Avoid_ lines
# and the changelog may. The Product and Engineering roles keep their names and jobs.
# Bash 3.2-safe: grep and awk only.

GLOSSARY="$PLUGIN_ROOT/../../GLOSSARY.md"
# Split so this file never matches itself.
OLD_NAMES='(Product|Engineering)[ -]'"chats?"'|(Product|Engineering) ?(and|/) ?(Product|Engineering) '"chats?"

# old_names_in dir: "file:line: text" for each old chat name outside the changelog.
old_names_in() {
  grep -rnIiE "$OLD_NAMES" "$1" | grep -v '/CHANGELOG\.md:' || true
}

test_no_skill_reference_script_or_template_names_the_chats_by_their_old_names() {
  local hits=""
  hits=$(old_names_in "$PLUGIN_ROOT")
  [ -z "$hits" ] || fail "the old chat names are still used:
$hits"
}

test_the_root_readme_names_the_chats_by_their_new_names() {
  local hits=""
  hits=$(grep -nIiE "$OLD_NAMES" "$PLUGIN_ROOT/../../README.md" || true)
  [ -z "$hits" ] || fail "the root README uses an old chat name:
$hits"
}

test_the_glossary_names_the_old_chat_names_only_on_its_avoid_lines() {
  local hits=""
  hits=$(grep -nIiE "$OLD_NAMES" "$GLOSSARY" | grep -v ':_Avoid_:' || true)
  [ -z "$hits" ] || fail "the glossary uses an old chat name outside an _Avoid_ line:
$hits"
  assert_contains "$(cat "$GLOSSARY")" "**Decision chat**"
  assert_contains "$(cat "$GLOSSARY")" "**Run chat**"
}

test_the_check_catches_an_old_name() {
  local d="$TEST_TMPDIR/p"
  mkdir -p "$d/skills/x"
  echo "Ask the Product"" chat." >"$d/skills/x/SKILL.md"
  echo "the Engineering""-chat's sweep" >"$d/skills/x/more.md"
  echo "the Product/Engineering"" chat" >"$d/skills/x/slash.md"
  echo "was the Product"" chat" >"$d/CHANGELOG.md"
  local hits=""
  hits=$(old_names_in "$d")
  assert_contains "$hits" "SKILL.md:1:"
  assert_contains "$hits" "more.md:1:"
  assert_contains "$hits" "slash.md:1:"
  case "$hits" in *CHANGELOG*) fail "the changelog was checked" ;; esac
}

test_the_product_and_engineering_roles_keep_their_names_and_jobs() {
  local g="" jobs=""
  g=$(cat "$GLOSSARY")
  assert_contains "$g" "**Product role**:
The role holding the jobs about what to build and why"
  assert_contains "$g" "**Engineering role**:
The role holding the jobs about how it's built"
  jobs="$PLUGIN_ROOT/references/jobs.md"
  # Each job keeps its role.
  assert_eq "Product" "$(awk -F' *\\| *' '$2 == "8" {print $5}' "$jobs")"
  assert_eq "Engineering" "$(awk -F' *\\| *' '$2 == "10" {print $5}' "$jobs")"
  assert_eq "Engineering (QA)" "$(awk -F' *\\| *' '$2 == "13" {print $5}' "$jobs")"
  assert_eq "Product" "$(awk -F' *\\| *' '$2 == "18" {print $5}' "$jobs")"
}
