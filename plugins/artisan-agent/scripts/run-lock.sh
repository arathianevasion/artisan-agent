#!/usr/bin/env bash
# The run lock: one run per repo. A run holds the lock while its state.lock
# (see ${CLAUDE_PLUGIN_ROOT}/references/state-file.md) names a live pid.
#
# Usage:
#   run-lock.sh check [dir]   exit 0 if no run holds the lock; exit 3 and print
#                             "<run-id> <pid>" if one does. dir: any path inside
#                             the repo (default: the current directory)
#
# A lock whose pid is dead is stale and does not count. A one-off state write
# takes the lock for a moment too, so a check can be refused for that moment;
# retry. Exit status: 0 free, 1 error, 2 usage, 3 held.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"

case "${1:-}" in
  check)
    dir=${2:-.}
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || state_die 1 "not inside a git repository: $dir"
    runs="$(dirname "$common")/.artisan-agent/runs"
    for lock in "$runs"/*/state.lock; do
      [ -L "$lock" ] || continue
      pid=$(readlink "$lock")
      if state_pid_alive "$pid"; then
        printf '%s %s\n' "$(basename "$(dirname "$lock")")" "$pid"
        exit 3
      fi
    done
    exit 0
    ;;
  *) state_usage "$0" ;;
esac
