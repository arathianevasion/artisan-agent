#!/bin/bash
# UserPromptExpansion hook: a typed, replaced upstream skill runs our
# replacement. It adds context telling Claude to ignore the upstream skill and
# invoke the replacement with the typed arguments; it blocks nothing.
# Reads the event JSON on stdin; the replacement comes from the same
# replaced-skills.list that generated the matcher. Bash 3.2-safe.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
name=$(printf '%s' "$input" | jq -r '.command_name // ""')
args=$(printf '%s' "$input" | jq -r '.command_args // ""')
name=${name#mattpocock-skills:}
repl=$("$HERE/guard.sh" replacements | awk -F'\t' -v n="$name" '$1 == n { print $2 }')
if [ -z "$repl" ]; then
  jq -cn '{hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:"This upstream skill is replaced in this pipeline. Ignore its instructions and use the artisan-agent skills instead."}}'
  exit 0
fi
repl=${repl#/}
ctx="The Artisan typed /mattpocock-skills:$name but means the artisan-agent replacement, $repl. Ignore the instructions of the upstream skill. Invoke $repl through the Skill tool now, with the same arguments the Artisan typed: ${args:-(none)}"
jq -cn --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:$c}}'
