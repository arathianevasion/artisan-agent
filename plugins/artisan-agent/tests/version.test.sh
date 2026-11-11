# Every release bumps plugin.json's version (semver) with a changelog entry.

manifest_version() {
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -n 1
}

newest_changelog_version() {
  sed -n 's/^## \([^ ]*\).*/\1/p' "$PLUGIN_ROOT/CHANGELOG.md" | head -n 1
}

test_plugin_version_is_semver() {
  local version
  version=$(manifest_version)
  printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' \
    || fail "plugin.json version [$version] is not semver"
}

test_newest_changelog_entry_matches_plugin_version() {
  assert_eq "$(manifest_version)" "$(newest_changelog_version)" "newest CHANGELOG.md entry vs plugin.json version"
}
