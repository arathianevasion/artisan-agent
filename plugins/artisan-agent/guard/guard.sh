#!/bin/bash
# Generates everything the replaced-skill guard needs from guard/replaced-skills.list.
# Bash 3.2-safe. Usage: guard.sh <command> [--list FILE] [--hook-command CMD]
#   matcher        the UserPromptExpansion matcher regex
#   hooks-json     the plugin's hooks/hooks.json: the replaced-skill hook plus the
#                  main-checkout and run-lock hooks and the compaction hooks
#                  (committed; a test keeps it fresh)
#   deny-rules     one Skill(...) deny rule per line
#   deny-json      {"permissions":{"deny":[...]}} for project settings
#   flag-watch     one upstream skill (plugin:name) per line for the upstream check
#   settings-json  project-settings fallback: the hook plus the deny rules
#                  (use --hook-command with an absolute path to block-replaced.sh)
#   reasons        "<upstream name><TAB><block reason>" per line (used by the hook)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
UPSTREAM=mattpocock-skills
# Stable text at the start of every block reason; a blocked headless run exits 0,
# so callers detect the block by this text in the result.
MARKER="Blocked by the artisan-agent replaced-skill guard:"

list="$HERE/replaced-skills.list"
# The placeholder is double-quoted so an install path with a space stays one word.
hook_command='"${CLAUDE_PLUGIN_ROOT}/guard/block-replaced.sh"'
cmd=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list=$2; shift 2 ;;
    --hook-command) hook_command=$2; shift 2 ;;
    *) echo "guard.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

validate_list() { # a missing or empty list, or a line without a replacement, is an error
  [ -f "$list" ] || { echo "guard.sh: no list at $list" >&2; exit 2; }
  local n=0 name= repl=
  while read -r name repl; do
    [ -n "$repl" ] || { echo "guard.sh: $name has no replacement in $list" >&2; exit 2; }
    n=$((n + 1))
  done <<EOT
$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$' || true)
EOT
  [ "$n" -gt 0 ] || { echo "guard.sh: $list is empty" >&2; exit 2; }
}
case "$cmd" in -h|--help|help|"") ;; *) validate_list ;; esac

entries() { # prints "name replacement" lines, comments and blanks removed
  [ -f "$list" ] || { echo "guard.sh: no list at $list" >&2; exit 2; }
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$' || true
}

names() { entries | while read -r name _; do printf '%s\n' "$name"; done; }

join() { # join lines of stdin with $1
  local sep=$1 out="" line=
  while IFS= read -r line; do
    if [ -z "$out" ]; then out=$line; else out="$out$sep$line"; fi
  done
  printf '%s' "$out"
}

matcher() { printf '^%s:(%s)$' "$UPSTREAM" "$(names | join '|')"; }

deny_lines() { names | while read -r n; do printf 'Skill(%s:%s)\n' "$UPSTREAM" "$n"; done; }

# JSON string escaping for a value that goes between double quotes: backslash, quote, tab, LF, CR (enough for a hook command; other control characters are not handled). Only --hook-command needs it; the matcher, deny rules and ${CLAUDE_PLUGIN_ROOT} paths are fixed literals or skill names. bash 3.2-safe.
json_escape() {
  local s=$1 tab= nl= cr=
  tab=$(printf '\t'); nl=$(printf '\n'); cr=$(printf '\r')
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//"$tab"/\\t}; s=${s//"$nl"/\\n}; s=${s//"$cr"/\\r}
  printf '%s' "$s"
}

json_hooks_body() { # the "hooks" object value
  printf '{"UserPromptExpansion":[{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}]}' \
    "$(matcher)" "$(json_escape "$hook_command")"
}

# The plugin's hook set: the replaced-skill block, plus the main-checkout and
# run-lock hooks (protect.sh). settings-json carries only the replaced-skill
# hook: the fallbacks for the other two are the git pre-commit hook and
# implement-plan's own lock check (guard/README.md).
json_plugin_hooks_body() {
  local protect='"${CLAUDE_PLUGIN_ROOT}/guard/protect.sh"'
  local compact='"${CLAUDE_PLUGIN_ROOT}/scripts/compact-hook.sh"'
  protect=$(json_escape "$protect"); compact=$(json_escape "$compact")
  printf '{"UserPromptExpansion":[{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]},' \
    "$(matcher)" "$(json_escape "$hook_command")"
  printf '{"matcher":"^(artisan-agent:)?implement-plan$","hooks":[{"type":"command","command":"%s run-start"}]}],' "$protect"
  printf '"PreToolUse":[{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"%s main-edit"}]},' "$protect"
  printf '{"matcher":"Skill","hooks":[{"type":"command","command":"%s run-start"}]}],' "$protect"
  # The context drain and resume (scripts/compact-hook.sh, #59): the
  # orchestrator's hand-off marker, the chat's steered summary and the run
  # digest put back after compaction or /resume.
  printf '"PreCompact":[{"hooks":[{"type":"command","command":"%s pre-compact"}]}],' "$compact"
  printf '"SessionStart":[{"matcher":"startup|resume|compact|clear","hooks":[{"type":"command","command":"%s session-start"}]}]}' "$compact"
}

deny_array() { printf '['; deny_lines | sed 's/.*/"&"/' | join ','; printf ']'; }

case "$cmd" in
  matcher) matcher; echo ;;
  hooks-json) printf '{"hooks":%s}\n' "$(json_plugin_hooks_body)" ;;
  deny-rules) deny_lines ;;
  deny-json) printf '{"permissions":{"deny":%s}}\n' "$(deny_array)" ;;
  flag-watch) names | while read -r n; do printf '%s:%s\n' "$UPSTREAM" "$n"; done ;;
  settings-json) printf '{"hooks":%s,"permissions":{"deny":%s}}\n' "$(json_hooks_body)" "$(deny_array)" ;;
  reasons)
    entries | while read -r name repl; do
      printf '%s\t%s /%s:%s is replaced in this pipeline. Use %s instead.\n' \
        "$name" "$MARKER" "$UPSTREAM" "$name" "$repl"
    done ;;
  -h|--help|help|"") sed -n '2,13p' "$0" ;;
  *) echo "guard.sh: unknown command $cmd" >&2; exit 2 ;;
esac
