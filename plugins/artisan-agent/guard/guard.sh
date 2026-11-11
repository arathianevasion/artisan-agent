#!/bin/bash
# Generates everything the replaced-skill guard needs from guard/replaced-skills.list.
# Bash 3.2-safe. Usage: guard.sh <command> [--list FILE] [--hook-command CMD]
#   matcher        the UserPromptExpansion matcher regex
#   hooks-json     the plugin's hooks/hooks.json (committed; a test keeps it fresh)
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
hook_command='${CLAUDE_PLUGIN_ROOT}/guard/block-replaced.sh'
cmd=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list=$2; shift 2 ;;
    --hook-command) hook_command=$2; shift 2 ;;
    *) echo "guard.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

entries() { # prints "name replacement" lines, comments and blanks removed
  [ -f "$list" ] || { echo "guard.sh: no list at $list" >&2; exit 2; }
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$' || true
}

names() { entries | while read -r name _; do printf '%s\n' "$name"; done; }

join() { # join lines of stdin with $1
  local sep=$1 out="" line
  while IFS= read -r line; do
    if [ -z "$out" ]; then out=$line; else out="$out$sep$line"; fi
  done
  printf '%s' "$out"
}

matcher() { printf '^%s:(%s)$' "$UPSTREAM" "$(names | join '|')"; }

deny_lines() { names | while read -r n; do printf 'Skill(%s:%s)\n' "$UPSTREAM" "$n"; done; }

json_hooks_body() { # the "hooks" object value
  printf '{"UserPromptExpansion":[{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}]}' \
    "$(matcher)" "$hook_command"
}

deny_array() { printf '['; deny_lines | sed 's/.*/"&"/' | join ','; printf ']'; }

case "$cmd" in
  matcher) matcher; echo ;;
  hooks-json) printf '{"hooks":%s}\n' "$(json_hooks_body)" ;;
  deny-rules) deny_lines ;;
  deny-json) printf '{"permissions":{"deny":%s}}\n' "$(deny_array)" ;;
  flag-watch) names | while read -r n; do printf '%s:%s\n' "$UPSTREAM" "$n"; done ;;
  settings-json) printf '{"hooks":%s,"permissions":{"deny":%s}}\n' "$(json_hooks_body)" "$(deny_array)" ;;
  reasons)
    entries | while read -r name repl; do
      printf '%s\t%s /%s:%s is replaced in this pipeline. Use %s instead.\n' \
        "$name" "$MARKER" "$UPSTREAM" "$name" "$repl"
    done ;;
  -h|--help|help|"") sed -n '2,12p' "$0" ;;
  *) echo "guard.sh: unknown command $cmd" >&2; exit 2 ;;
esac
