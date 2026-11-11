# Static check: a skill or reference that names a kept upstream skill sharing its short name
# with a Claude Code built-in must use the full mattpocock-skills:<name>, or the
# bare name resolves to the built-in (#89).
#
# Clashing names were found by listing the skills and commands a headless session
# reports with this plugin loaded: an unprefixed `code-review` is the built-in,
# next to `mattpocock-skills:code-review`. No other upstream name appears bare.
# Add a name here when a built-in starts sharing it.
CLASHING="code-review"

test_no_bare_clashing_skill_names() {
  local name hits
  for name in $CLASHING; do
    # A bare use: the name not preceded by ":" or another name character.
    # Lines that explicitly talk about the built-in are allowed.
    hits=$(grep -rnE "(^|[^:A-Za-z0-9_-])$name([^A-Za-z0-9_-]|$)" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/references" \
      --include='*.md' | grep -v 'built-in' || true)
    [ -z "$hits" ] || fail "bare $name (use mattpocock-skills:$name):
$hits"
  done
}

test_the_check_catches_a_bare_name() {
  local f="$TEST_TMPDIR/SKILL.md"
  printf 'Run /code-review now.\n' > "$f"
  grep -qE '(^|[^:A-Za-z0-9_-])code-review([^A-Za-z0-9_-]|$)' "$f" || fail "pattern missed a bare name"
  printf 'Run /mattpocock-skills:code-review now.\n' > "$f"
  ! grep -qE '(^|[^:A-Za-z0-9_-])code-review([^A-Za-z0-9_-]|$)' "$f" || fail "pattern flagged a full name"
}
