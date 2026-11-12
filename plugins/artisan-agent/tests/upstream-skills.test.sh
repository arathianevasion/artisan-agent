# skills/setup/upstream-skills.txt must match the installed mattpocock-skills (#85).
# The cache is read-only here. When it is absent (CI, a fresh machine) the test skips.

LIST="$PLUGIN_ROOT/skills/setup/upstream-skills.txt"

cache_root() {
  printf '%s/cache/claude-plugins-official/mattpocock-skills' "${CLAUDE_CODE_PLUGIN_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins}"
}

list_names() { grep -v '^#' "$LIST" | grep -v '^$' | sort -u; }

test_list_has_no_duplicate_names() {
  local dups=
  dups=$(grep -v '^#' "$LIST" | grep -v '^$' | sort | uniq -d)
  assert_eq "" "$dups" "duplicate names"
}

test_list_matches_newest_installed_cache_when_present() {
  local root= newest= actual=
  root=$(cache_root)
  newest=$(ls "$root" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)
  if [ -z "$newest" ] || [ ! -d "$root/$newest/skills" ]; then
    echo "skip: no mattpocock-skills cache at $root"
    return 0
  fi
  actual=$(for f in "$root/$newest"/skills/*/*/SKILL.md; do [ -f "$f" ] && basename "$(dirname "$f")"; done | sort -u)
  assert_eq "$actual" "$(list_names)" "upstream-skills.txt differs from the installed cache ($newest)"
}
