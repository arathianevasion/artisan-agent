#!/usr/bin/env bash
# The plugin's PreCompact and SessionStart hooks (hooks/hooks.json), for the
# context drain and resume: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/context-drain.md.
#
# Usage (Claude Code passes the hook's JSON on stdin):
#   compact-hook.sh pre-compact
#   compact-hook.sh session-start
#
# Who the session is comes from the environment run-ticket.sh gives every
# session it launches (ARTISAN_ROLE, ARTISAN_RUN_DIR, ARTISAN_RESULT_FILE);
# a session without ARTISAN_ROLE is a chat.
#
#   pre-compact, orchestrator   writes the hand-off marker,
#                               workers/<id>.<n>/handoff.json, and blocks the
#                               compaction (exit 2, the reason on stderr). The
#                               orchestrator sees the marker at its next
#                               drain.sh check, finishes its step and hands off.
#   pre-compact, chat           with a run open in the repo: prints the
#                               instructions that steer the summary (Claude
#                               Code adds a PreCompact hook's output to them).
#   session-start, orchestrator records its transcript's path in
#                               workers/<id>.<n>/transcript.path, where
#                               drain.sh check reads its context percentage.
#   session-start, chat         in a repo set up for the plugin: one line naming
#                               this session's transcript (for drain.sh
#                               chat). With a run open: after compaction
#                               or /resume (source compact or resume), the run
#                               digest (run-digest.sh); at startup, one line
#                               saying the run is open.
#   workers and verifiers       nothing: their compaction is their own.
#
# Never fails a session: anything unexpected exits 0 with nothing printed.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
event=${1:-}
input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null || true; }

transcript=$(field transcript_path)
cwd=$(field cwd)
[ -n "$cwd" ] || cwd=$PWD
role=${ARTISAN_ROLE:-}

# Hook-fired proof for the live harnesses (#105): when ARTISAN_HOOK_PROOF names a
# file, every run of this hook appends one line to it, so a harness can tell a
# session that ran the plugin's hooks from one that silently skipped them.
if [ -n "${ARTISAN_HOOK_PROOF:-}" ]; then
  printf '%s %s role=%s session=%s\n' "$event" "$(date +%s)" "${role:--}" "$(field session_id)" >>"$ARTISAN_HOOK_PROOF" 2>/dev/null || true
fi

# This session's folder in its run, for a session run-ticket.sh launched.
session_dir() {
  [ -n "${ARTISAN_RUN_DIR:-}" ] && [ -n "${ARTISAN_RESULT_FILE:-}" ] || return 1
  printf '%s/workers/%s\n' "$ARTISAN_RUN_DIR" "$(basename "$ARTISAN_RESULT_FILE" .result.json)"
}

write_atomic() { # path content
  printf '%s\n' "$2" >"$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

case "$event:$role" in
  pre-compact:orchestrator)
    dir=$(session_dir) || exit 0
    mkdir -p "$dir" || exit 0
    write_atomic "$dir/handoff.json" "$(jq -n --arg trigger "$(field trigger)" --arg tp "$transcript" \
      --arg sid "$(field session_id)" --argjson at "$(date +%s)" \
      '{trigger: $trigger, at: $at, session_id: $sid, transcript_path: $tp}')" || exit 0
    echo "Artisan Agent: an orchestrator never compacts. The hand-off marker is written: finish the step you are on, run drain.sh handoff on the run folder, write its result and exit." >&2
    exit 2
    ;;
  session-start:orchestrator)
    dir=$(session_dir) || exit 0
    [ -n "$transcript" ] || exit 0
    mkdir -p "$dir" && write_atomic "$dir/transcript.path" "$transcript"
    exit 0
    ;;
  pre-compact:)
    run_line=$("$SCRIPT_DIR/run-digest.sh" --repo "$cwd" --line 2>/dev/null) || exit 0
    [ -n "$run_line" ] || exit 0
    cat <<EOF
This is the Engineering chat for an Artisan Agent run ($run_line). Write the summary so the chat carries on as if nothing happened:
- Keep: the run id and run folder; what the Artisan asked, decided or told you about this run in this chat that is not on the tracker or in the state file, in their words; the question or step you were in the middle of; anything you promised to do next.
- Leave out: ticket tables, wave reports, digests, plans and script output. The state file holds them, and the run digest is put back into context right after this compaction.
- Keep the chat's role: it launches waves and takes the Artisan's decisions; it never dispatches, merges or closes tickets itself.
EOF
    exit 0
    ;;
  session-start:)
    common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
    [ -d "$(dirname "$common")/.artisan-agent" ] || exit 0
    source=$(field source)
    [ -z "$transcript" ] || echo "Artisan Agent: this chat's transcript is $transcript (drain.sh chat --transcript reads its context percentage from it)."
    case "$source" in
      compact | resume)
        "$SCRIPT_DIR/run-digest.sh" --repo "$cwd" 2>/dev/null || true
        ;;
      *)
        run_line=$("$SCRIPT_DIR/run-digest.sh" --repo "$cwd" --line 2>/dev/null) || true
        [ -z "$run_line" ] || echo "Artisan Agent: $run_line. /artisan-agent:implement-plan opens with its digest."
        ;;
    esac
    exit 0
    ;;
esac
exit 0
