#!/bin/bash
# Plugin hook for the two repo rules: no session edits the main checkout, and
# one run per repo. Reads the hook event JSON on stdin. Bash 3.2-safe; needs jq
# (without it the hook says so on stderr and lets the call through).
#   protect.sh main-edit   PreToolUse on Edit|Write|MultiEdit|NotebookEdit
#   protect.sh run-start   UserPromptExpansion and PreToolUse(Skill) for implement-plan
#                          (while a run holds the lock only the holding chat, a
#                          resume, "add <tickets>" or "urgent <ticket>" passes: the
#                          last two are the add-work flow)
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

# True when pid is one of this hook's ancestors. `ps -o ppid= -p` reads the
# same on BSD (macOS) and Linux ps.
is_ancestor() { # pid
  local p=$PPID depth=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  return 1
}

# True when the lock holder is this hook's own chat. The chat holds the lock
# with its Claude process's pid between waves (implement-plan, "Hold the
# run"), and that process runs the hook, so the pid is an ancestor. While a
# wave runs, the orchestrator's runner holds it instead: it is detached, but
# its command line names the chat it took the lock from
# (`run-ticket.sh ... --lock-from <chat pid>`, wave.sh launch).
holding_chat() { # lock pid
  local args="" from=""
  is_ancestor "$1" && return 0
  args=$(ps -ww -o args= -p "$1" 2>/dev/null) || return 1
  case "$args" in *run-ticket.sh*--lock-from\ *) ;; *) return 1 ;; esac
  from=${args#*--lock-from }; from=${from%% *}
  case "$from" in "" | *[!0-9]*) return 1 ;; esac
  is_ancestor "$from"
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
    # The chat that holds the run is carrying on or adding to its own run,
    # whatever the wording (#153).
    holding_chat "$pid" && exit 0
    # Resuming the open run is not a second run: a bare call, "resume" or the
    # run's id opens with its digest (skills/implement-plan/references/context-drain.md).
    # (With no arguments the request is the prompt itself: drop the command.)
    resume=$(printf '%s' "$request" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
    case "$resume" in
      /implement-plan | /artisan-agent:implement-plan) resume= ;;
      "/implement-plan "* | "/artisan-agent:implement-plan "*) resume=${resume#* } ;;
    esac
    # "continue", "carry on", "resume" or "pick up", optionally followed by
    # "run" and the run's id (or #id), any case and punctuation; words after
    # the id are fine (#153). "run <id>" or the id alone is a resume too.
    # words: the request lowercased, punctuation (but # _ - and inner dots)
    # turned into single spaces.
    words=$(printf '%s' "$resume" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]#_.-' ' ' \
      | sed -E -e 's/\.+( |$)/ /g' -e 's/  +/ /g' -e 's/^ //' -e 's/ $//')
    run_id_lc=$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')
    rest=$words prefix=
    for verb in continue "carry on" resume "pick up"; do
      case "$rest" in "$verb" | "$verb "*) rest=${rest#"$verb"}; rest=${rest# }; prefix=verb; break ;; esac
    done
    case "$rest" in run | "run "*) rest=${rest#run}; rest=${rest# }; prefix=${prefix:-run} ;; esac
    case "$rest" in
      "$run_id_lc" | "#$run_id_lc") exit 0 ;;
      "$run_id_lc "* | "#$run_id_lc "*) [ -z "$prefix" ] || exit 0 ;;
      "") if [ -z "$words" ] || [ "$prefix" = verb ]; then exit 0; fi ;;
    esac
    # Adding work to the running run is not a second run either: "add <tickets>"
    # and "urgent <ticket>" go through to the add-work flow
    # (skills/implement-plan/SKILL.md, "Adding to a running run"), and are not
    # refused or queued as a separate plan.
    # The request must name a ticket (#45 or 45): "add login page" is a new plan.
    case "$words" in
      add\ * | add-work\ * | urgent\ * | --urgent\ *)
        if printf '%s' "$resume" | grep -Eq '(^|[^[:alnum:]])#?[0-9]+([^[:alnum:]]|$)'; then exit 0; fi ;;
    esac
    msg="Blocked by the artisan-agent run lock: run $run_id (pid $pid) holds the lock, and a repo has one run at a time."
    # A request naming the running run ("run <id>" or "#<id>") is about that
    # run, never a new plan: say how to carry it on and file nothing (#153).
    case " $words " in
      *" run $run_id_lc "* | *"#$run_id_lc "*)
        refuse "$msg Your request names run $run_id, which is already running, so it was not filed as a \`plan\` issue. To carry the run on, call \`/artisan-agent:implement-plan resume $run_id\` (or \`carry on run $run_id\`); the chat that holds the run can carry it on with any wording." ;;
    esac
    if (cd "$cwd" && "$HERE/queue-plan.sh" "$request") >/dev/null 2>&1; then
      msg="$msg Your request is left as a \`plan\` issue on the tracker; it runs after the current run."
    else
      msg="$msg Leaving the request as a \`plan\` issue failed (is gh logged in?); file one yourself."
    fi
    refuse "$msg"
    ;;
  *) echo "usage: protect.sh main-edit|run-start (event JSON on stdin)" >&2; exit 2 ;;
esac
