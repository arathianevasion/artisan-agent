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
  local n=
  for n in implement-spec implement to-spec retro triage grill-with-docs; do
    assert_contains "$("$GUARD" matcher)" "$n"
    assert_contains "$("$GUARD" deny-rules)" "Skill(mattpocock-skills:$n)"
    assert_contains "$("$GUARD" flag-watch)" "mattpocock-skills:$n"
  done
}

test_grill_with_docs_points_at_grill() {
  assert_contains "$("$GUARD" replacements)" "grill-with-docs	/artisan-agent:grill"
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

test_hook_redirects_to_the_replacement_with_the_typed_arguments() {
  local out=
  out=$(printf '{"command_name":"mattpocock-skills:implement","command_args":"#12 now"}' | "$PLUGIN_ROOT/guard/block-replaced.sh")
  assert_eq UserPromptExpansion "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
  local ctx=; ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
  assert_contains "$ctx" 'artisan-agent:implement'
  assert_contains "$ctx" 'Skill tool'
  assert_contains "$ctx" '#12 now'
  assert_eq null "$(printf '%s' "$out" | jq -r '.decision // "null"')"
}

test_hook_output_has_no_suppress_original_prompt() {
  local out=
  out=$(printf '{"command_name":"mattpocock-skills:retro"}' | "$PLUGIN_ROOT/guard/block-replaced.sh")
  assert_eq null "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.suppressOriginalPrompt // "null"')"
  case "$out" in *suppressOriginalPrompt*) fail "suppressOriginalPrompt in $out" ;; esac
}

test_hook_names_grill_for_grill_with_docs() {
  local out=
  out=$(printf '{"command_name":"mattpocock-skills:grill-with-docs"}' | "$PLUGIN_ROOT/guard/block-replaced.sh")
  assert_contains "$out" 'artisan-agent:grill'
}

test_triage_can_be_started_by_claude() {
  if awk 'NR==1{next} /^---$/{exit} {print}' "$PLUGIN_ROOT/skills/triage/SKILL.md" | grep -q '^disable-model-invocation'; then
    fail "artisan-agent:triage still sets disable-model-invocation"
  fi
}

test_every_replacement_in_the_list_exists_as_a_plugin_skill() {
  local name= repl= skill=
  while read -r name repl; do
    skill=${repl#/artisan-agent:}
    [ -f "$PLUGIN_ROOT/skills/$skill/SKILL.md" ] || fail "$name maps to $repl, which is not a skill in the plugin"
  done <<EOT
$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PLUGIN_ROOT/guard/replaced-skills.list")
EOT
}

test_no_skill_is_both_replaced_and_a_dependency() {
  local n=
  for n in $("$GUARD" flag-watch | sed 's/^[^:]*://'); do
    if grep -qx "$n" "$PLUGIN_ROOT/guard/dependencies.list"; then fail "$n is on both lists"; fi
  done
}

test_hook_redirects_every_replaced_name_to_its_own_replacement() {
  local name= repl= out=
  while read -r name repl; do
    out=$(printf '{"command_name":"mattpocock-skills:%s","command_args":"ARGS-%s"}' "$name" "$name" | "$PLUGIN_ROOT/guard/block-replaced.sh")
    assert_contains "$out" "${repl#/}"
    assert_contains "$out" "/mattpocock-skills:$name"
    assert_contains "$out" "ARGS-$name"
    case "$out" in *'"decision"'*) fail "$name still carries a decision: $out" ;; esac
  done <<EOT
$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PLUGIN_ROOT/guard/replaced-skills.list")
EOT
}

test_settings_json_has_hook_and_deny_rules() {
  local out=
  out=$("$GUARD" settings-json --hook-command /abs/block-replaced.sh)
  assert_contains "$out" '"command":"/abs/block-replaced.sh"'
  assert_contains "$out" '"deny":["Skill(mattpocock-skills:implement-spec)"'
}

test_settings_json_escapes_the_hook_command() {
  local cmd= out= got=
  for cmd in '"$CLAUDE_PROJECT_DIR"/x/block-replaced.sh' 'C:\dir\my hook.sh "a b"'; do
    out=$("$GUARD" settings-json --hook-command "$cmd")
    got=$(printf '%s' "$out" | jq -r '.hooks.UserPromptExpansion[0].hooks[0].command')
    assert_eq "$cmd" "$got"
    # second, independent parser
    got=$(printf '%s' "$out" | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["hooks"]["UserPromptExpansion"][0]["hooks"][0]["command"],end="")')
    assert_eq "$cmd" "$got"
  done
}

test_every_hook_command_runs_when_the_plugin_path_has_a_space() {
  local root="$TEST_TMPDIR/plug in" cmds= c= out= n=0 f=
  mkdir -p "$root/guard" "$root/scripts"
  for f in guard/block-replaced.sh guard/protect.sh scripts/compact-hook.sh; do
    printf '#!/bin/sh\necho "ran $0 $*"\n' > "$root/$f"
    chmod +x "$root/$f"
  done
  cmds=$("$GUARD" hooks-json | jq -r '.hooks[][].hooks[].command')
  while IFS= read -r c; do
    out=$(CLAUDE_PLUGIN_ROOT="$root" sh -c "$c" 2>&1)
    assert_contains "$out" "ran $root/"
    n=$((n + 1))
  done <<EOT
$cmds
EOT
  assert_eq 6 "$n"
}

test_missing_empty_or_incomplete_list_fails_loudly() {
  assert_status 2 "$GUARD" hooks-json --list "$TEST_TMPDIR/nope.list"
  : > "$TEST_TMPDIR/empty.list"
  assert_status 2 "$GUARD" hooks-json --list "$TEST_TMPDIR/empty.list"
  printf 'alpha\n' > "$TEST_TMPDIR/norepl.list"
  assert_status 2 "$GUARD" matcher --list "$TEST_TMPDIR/norepl.list"
}

dep_names() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PLUGIN_ROOT/guard/dependencies.list"; }

test_dependency_list_names_no_artisan_agent_skill() {
  local n=
  for n in $(dep_names); do
    if [ -d "$PLUGIN_ROOT/skills/$n" ]; then fail "$n is an artisan-agent skill, not an upstream one"; fi
  done
}

test_dependency_list_and_replaced_list_do_not_overlap() {
  local n=
  for n in $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PLUGIN_ROOT/guard/replaced-skills.list" | awk '{print $1}'); do
    if dep_names | grep -qx "$n"; then fail "$n is on both the dependency list and the replaced-skill list"; fi
  done
}

test_dependency_list_has_wayfinder_and_not_to_plan() {
  dep_names | grep -x wayfinder >/dev/null || fail "wayfinder missing from the dependency list"
  if dep_names | grep -qx to-plan; then fail "to-plan is ours and must not be on the dependency list"; fi
}

test_every_dependency_exists_in_the_upstream_cache_when_present() {
  local root= newest= n=
  root="${CLAUDE_CODE_PLUGIN_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins}/cache/claude-plugins-official/mattpocock-skills"
  newest=$(ls "$root" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)
  if [ -z "$newest" ] || [ ! -d "$root/$newest/skills" ]; then
    echo "skip: no mattpocock-skills cache at $root"
    return 0
  fi
  for n in $(dep_names); do
    [ -f "$(ls "$root/$newest"/skills/*/"$n"/SKILL.md 2>/dev/null | head -n 1)" ] || fail "$n is not in the upstream cache ($newest)"
  done
}
