#!/bin/bash
# Plugin hook for the two repo rules: no session edits the main checkout, and
# one run per repo. Reads the hook event JSON on stdin. Bash 3.2-safe; needs jq
# (without it the hook says so on stderr and lets the call through).
#   protect.sh main-edit   PreToolUse on Edit|Write|MultiEdit|NotebookEdit
#   protect.sh run-start   UserPromptExpansion and PreToolUse(Skill) for implement-plan
# Both refuse by printing the host's deny/block JSON and exit 0.
# Details: guard/README.md, "Main-checkout protection and the run lock".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPTS="$ROOT/scripts"
mode=${1:-}
input=$(cat)

command -v jq >/dev/null 2>&1 || { echo "artisan-agent protect.sh: jq not found; not checking" >&2; exit 0; }
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

event=$(field '.hook_event_name')
cwd=$(field '.cwd'); [ -n "$cwd" ] || cwd=$PWD

refuse() { # message
  case "$event" in
    PreToolUse)
      jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    *)
      jq -cn --arg r "$1" '{decision:"block",reason:$r,hookSpecificOutput:{hookEventName:"UserPromptExpansion",suppressOriginalPrompt:true}}' ;;
  esac
  exit 0
}

# Existing directory at or above a path.
existing_dir() {
  local d=$1
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  printf '%s' "$d"
}

case "$mode" in
  main-edit)
    file=$(field '.tool_input.file_path'); [ -n "$file" ] || file=$(field '.tool_input.notebook_path')
    [ -n "$file" ] || exit 0
    case "$file" in /*) ;; *) file="$cwd/$file" ;; esac
    dir=$(existing_dir "$(dirname "$file")")
    gitdir=$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
    [ "$gitdir" = "$common" ] || exit 0                      # a linked worktree: fine
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0   # not a work tree (bare, .git): fine
    [ -e "$root/.artisan-agent/config.yml" ] || exit 0       # the repo has not adopted the pipeline
    git -C "$dir" check-ignore -q -- "$file" 2>/dev/null && exit 0   # ignored runtime files are not "edits to main"
    refuse "Blocked by the artisan-agent main-checkout guard: $root is the main checkout, and no session edits it directly. Work in a worktree instead: for a doc or small change run \`$SCRIPTS/doc-change.sh start <name>\` and edit there (finish fast-forwards the main checkout); a run's workers and integration branch already have their own worktrees. See $ROOT/references/main-checkout.md."
    ;;
  run-start)
    case "$event" in
      PreToolUse) skill=$(field '.tool_input.skill'); request=$(field '.tool_input.args') ;;
      *) skill=$(field '.command_name'); request=$(field '.command_args'); [ -n "$request" ] || request=$(field '.prompt') ;;
    esac
    skill=${skill#artisan-agent:}
    [ "$skill" = implement-plan ] || exit 0
    holder=$("$SCRIPTS/run-lock.sh" check "$cwd" 2>/dev/null) && exit 0
    [ -n "$holder" ] || exit 0          # not a repo, or the check itself failed: do not block
    run_id=${holder% *}; pid=${holder#* }
    # Resuming the open run is not a second run: a bare call, "resume" or the
    # run's id opens with its digest (skills/implement-plan/references/context-drain.md).
    # (With no arguments the request is the prompt itself: drop the command.)
    resume=$(printf '%s' "$request" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
    case "$resume" in
      /implement-plan | /artisan-agent:implement-plan) resume= ;;
      "/implement-plan "* | "/artisan-agent:implement-plan "*) resume=${resume#* } ;;
    esac
    case "$resume" in
      "" | resume | "$run_id" | "resume $run_id") exit 0 ;;
    esac
    msg="Blocked by the artisan-agent run lock: run $run_id (pid $pid) holds the lock, and a repo has one run at a time."
    if (cd "$cwd" && "$HERE/queue-plan.sh" "$request") >/dev/null 2>&1; then
      msg="$msg Your request is left as a \`plan\` issue on the tracker; it runs after the current run."
    else
      msg="$msg Leaving the request as a \`plan\` issue failed (is gh logged in?); file one yourself."
    fi
    refuse "$msg"
    ;;
  *) echo "usage: protect.sh main-edit|run-start (event JSON on stdin)" >&2; exit 2 ;;
esac
