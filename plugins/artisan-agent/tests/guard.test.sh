# The replaced-skill guard: one list generates the hook, the deny rules and the flag watch.

GUARD="$PLUGIN_ROOT/guard/guard.sh"

make_list() { # file name...  (each name replaced by /artisan-agent:<name>)
  local f=$1; shift
  : > "$f"
  for n in "$@"; do printf '%s /artisan-agent:%s\n' "$n" "$n" >> "$f"; done
}

test_committed_hooks_json_is_generated_from_the_list() {
  assert_eq "$("$GUARD" hooks-json)" "$(cat "$PLUGIN_ROOT/hooks/hooks.json")" \
    "hooks/hooks.json is stale; regenerate with guard/guard.sh hooks-json > hooks/hooks.json"
}

test_every_replaced_name_is_in_matcher_deny_rules_and_flag_watch() {
  local n
  for n in implement-spec implement to-spec retro triage grill-with-docs; do
    assert_contains "$("$GUARD" matcher)" "$n"
    assert_contains "$("$GUARD" deny-rules)" "Skill(mattpocock-skills:$n)"
    assert_contains "$("$GUARD" flag-watch)" "mattpocock-skills:$n"
  done
}

test_grill_with_docs_points_at_grill() {
  assert_contains "$("$GUARD" reasons)" "Use /artisan-agent:grill instead."
}

test_adding_a_name_reaches_all_three_outputs() {
  make_list "$TEST_TMPDIR/l.list" alpha beta
  "$GUARD" matcher --list "$TEST_TMPDIR/l.list" > "$TEST_TMPDIR/m"
  assert_eq '^mattpocock-skills:(alpha|beta)$' "$(cat "$TEST_TMPDIR/m")"
  make_list "$TEST_TMPDIR/l.list" alpha beta gamma
  assert_contains "$("$GUARD" hooks-json --list "$TEST_TMPDIR/l.list")" '(alpha|beta|gamma)$'
  assert_contains "$("$GUARD" deny-json --list "$TEST_TMPDIR/l.list")" '"Skill(mattpocock-skills:gamma)"'
  assert_contains "$("$GUARD" flag-watch --list "$TEST_TMPDIR/l.list")" 'mattpocock-skills:gamma'
  assert_contains "$("$GUARD" settings-json --list "$TEST_TMPDIR/l.list")" 'Skill(mattpocock-skills:gamma)'
}

test_comments_and_blank_lines_are_ignored() {
  printf '# c\n\nalpha /artisan-agent:alpha # trailing\n' > "$TEST_TMPDIR/l.list"
  assert_eq '^mattpocock-skills:(alpha)$' "$("$GUARD" matcher --list "$TEST_TMPDIR/l.list")"
}

test_hook_blocks_with_replacement_and_suppresses_original_prompt() {
  local out
  out=$(printf '{"command_name":"mattpocock-skills:implement","prompt":"/x"}' | "$PLUGIN_ROOT/guard/block-replaced.sh")
  assert_contains "$out" '"decision":"block"'
  assert_contains "$out" 'Blocked by the artisan-agent replaced-skill guard:'
  assert_contains "$out" 'Use /artisan-agent:implement instead.'
  assert_contains "$out" '"suppressOriginalPrompt":true'
}

test_hook_names_grill_for_grill_with_docs() {
  local out
  out=$(printf '{"command_name":"mattpocock-skills:grill-with-docs"}' | "$PLUGIN_ROOT/guard/block-replaced.sh")
  assert_contains "$out" 'Use /artisan-agent:grill instead.'
}

test_no_skill_is_both_replaced_and_a_dependency() {
  local n
  for n in $("$GUARD" flag-watch | sed 's/^[^:]*://'); do
    if grep -qx "$n" "$PLUGIN_ROOT/guard/dependencies.list"; then fail "$n is on both lists"; fi
  done
}

test_hook_blocks_every_replaced_name_with_its_own_replacement() {
  local name repl out
  while read -r name repl; do
    out=$(printf '{"command_name":"mattpocock-skills:%s"}' "$name" | "$PLUGIN_ROOT/guard/block-replaced.sh")
    assert_contains "$out" "/mattpocock-skills:$name is replaced"
    assert_contains "$out" "Use $repl instead."
  done <<EOT
$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PLUGIN_ROOT/guard/replaced-skills.list")
EOT
}

test_settings_json_has_hook_and_deny_rules() {
  local out
  out=$("$GUARD" settings-json --hook-command /abs/block-replaced.sh)
  assert_contains "$out" '"command":"/abs/block-replaced.sh"'
  assert_contains "$out" '"deny":["Skill(mattpocock-skills:implement-spec)"'
}

test_settings_json_escapes_the_hook_command() {
  local cmd out got
  for cmd in '"$CLAUDE_PROJECT_DIR"/x/block-replaced.sh' 'C:\dir\my hook.sh "a b"'; do
    out=$("$GUARD" settings-json --hook-command "$cmd")
    got=$(printf '%s' "$out" | jq -r '.hooks.UserPromptExpansion[0].hooks[0].command')
    assert_eq "$cmd" "$got"
    got=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hooks"]["UserPromptExpansion"][0]["hooks"][0]["command"],end="")')
    assert_eq "$cmd" "$got"
  done
}

test_missing_empty_or_incomplete_list_fails_loudly() {
  assert_status 2 "$GUARD" hooks-json --list "$TEST_TMPDIR/nope.list"
  : > "$TEST_TMPDIR/empty.list"
  assert_status 2 "$GUARD" hooks-json --list "$TEST_TMPDIR/empty.list"
  printf 'alpha\n' > "$TEST_TMPDIR/norepl.list"
  assert_status 2 "$GUARD" matcher --list "$TEST_TMPDIR/norepl.list"
}
