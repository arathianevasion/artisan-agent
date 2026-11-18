# The permission arguments every headless `claude -p` step starts with, chosen
# in one place (#187): wave.sh's orchestrator and workers, verify.sh's
# verifier, retro.sh's preparer, upstream-check.sh's judge and model-prices.sh's
# price agent (#214). Sourced, never run.
#
# --permission-mode dontAsk denies a tool outside the allowlist at once and
# never asks. A headless session has no one to answer a prompt, and a `claude`
# wrapper on PATH (the cmux shim) can carry hooks that turn a permission
# request into a "needs input" wait the step never comes back from. In
# dontAsk no permission request is raised, so no hook can make one wait,
# whichever `claude` is on PATH. Settings' allow rules still apply.
#
# A denied tool shows in the session's final result event, as
# permission_denials (run-ticket.sh counts them into the exit record).
#
# Portable to bash 3.2 (macOS) and Linux.

HEADLESS_PERMISSION_MODE=dontAsk

# headless_args tools: sets HEADLESS_ARGS to the permission arguments for a
# headless session allowed exactly tools (a --allowedTools list).
headless_args() {
  HEADLESS_ARGS=(--permission-mode "$HEADLESS_PERMISSION_MODE" --allowedTools "$1")
}

# headless_denials session-json: prints, one per line, the tools the session
# was denied (its final result event's permission_denials). Nothing when it
# was denied none or the file is not JSON. Needs jq.
headless_denials() {
  jq -r '(if type == "array" then .[-1] else . end) | (.permission_denials // [])[] | .tool_name' "$1" 2>/dev/null || true
}

# headless_denied_calls session-json: prints, one per line, each call the
# session was denied as "<tool> <what it asked for>" (the file, URL, command,
# search or pattern), so a report can name it (#245). Nothing when it was
# denied none or the file is not JSON. Needs jq; the file reaches it on stdin.
headless_denied_calls() {
  jq -r '(if type == "array" then .[-1] else . end) | (.permission_denials // [])[]
    | .tool_name + ((.tool_input // {}) | (.file_path // .url // .command // .query // .pattern // .path // "")
                    | if . == "" then "" else " " + (tostring | gsub("\\s+"; " ")) end)' <"$1" 2>/dev/null || true
}

# headless_check_write_target path: refuses (returns 1, says why on stderr) a
# folder a headless session is to write to when its path has a .claude
# component (#249). Claude Code protects every .claude/ folder: a headless
# session's writes there are refused whatever its allowlist or --add-dir
# grants, with nothing saying why. Reading under .claude/ works, so only write
# targets are checked. Every caller goes through this one function.
headless_check_write_target() {
  local path="$1" rest="" prefix=""
  case "/$path/" in
    */.claude/*) ;;
    *) return 0 ;;
  esac
  rest="/$path/"
  prefix="${rest%%/.claude/*}/.claude"
  case "$path" in /*) prefix="${prefix#/}"; prefix="/${prefix#/}" ;; *) prefix="${prefix#/}" ;; esac
  printf 'headless sessions can'"'"'t write under a .claude/ folder (Claude Code protects it, whatever the allowlist or --add-dir grants): %s is under the protected folder %s; put it elsewhere\n' \
    "$path" "$prefix" >&2
  return 1
}

# headless_check_add_dirs args...: runs headless_check_write_target on the
# value of every --add-dir in args; returns 1 at the first refused one.
headless_check_add_dirs() {
  while [ $# -gt 0 ]; do
    if [ "$1" = --add-dir ] && [ $# -gt 1 ]; then
      headless_check_write_target "$2" || return 1
      shift
    fi
    shift
  done
  return 0
}
