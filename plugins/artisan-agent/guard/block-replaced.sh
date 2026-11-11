#!/bin/bash
# UserPromptExpansion hook: blocks a typed, replaced upstream skill and names
# our replacement. Reads the event JSON on stdin; the reason text comes from
# the same replaced-skills.list that generated the matcher. Bash 3.2-safe.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
name=$(printf '%s' "$input" | sed -n 's/.*"command_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
name=${name%%$'\n'*}
name=${name#mattpocock-skills:}
reason=$("$HERE/guard.sh" reasons | awk -F'\t' -v n="$name" '$1 == n { print $2 }')
[ -n "$reason" ] || reason="Blocked by the artisan-agent replaced-skill guard: this upstream skill is replaced in this pipeline. See the artisan-agent skills."
printf '{"decision":"block","reason":"%s","hookSpecificOutput":{"hookEventName":"UserPromptExpansion","suppressOriginalPrompt":true}}\n' "$reason"
