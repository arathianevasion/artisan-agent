#!/usr/bin/env bash
# Where should this run start? (#108) The project config's host_configured says
# this project's runs live on an always-on host; host.json in the individual
# home says this machine is that host (written only by host setup). implement-plan
# runs this before it starts a run, and acts on the exit status.
#
# Usage:
#   host-notice.sh [--repo D]
#
# Output and exit status:
#   0  run here: nothing printed when host_configured is false or absent, or this
#      machine is the host ("here: this machine is the host")
#   10 host_configured is true and this machine is not the host: prints the
#      one-line notice and the offer, for the Engineering chat. Do not start the
#      run locally unless the Artisan says so; to move one, see
#      ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/host-and-move.md
#   Either way, a leftover host.json from an old login stamp (not a host) adds a
#   line starting "legacy:" offering `login-check.sh cleanup`.
#
# Environment: CLAUDE_CONFIG_DIR, ARTISAN_HOME (as login-check.sh).
# Exit status: 0 or 10 as above, 1 error.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
repo=$PWD
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "usage: host-notice.sh [--repo D]" >&2; exit 2; }; repo=$2; shift 2 ;;
    *) echo "usage: host-notice.sh [--repo D]" >&2; exit 2 ;;
  esac
done

configured=$(cd "$repo" && "$SCRIPT_DIR/config.sh" show | jq -r '.host_configured') || exit 1
LC="$SCRIPT_DIR/login-check.sh"
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOST_FILE=${ARTISAN_HOME:-$CFG/artisan-agent}/host.json

is_host=0
if [ -f "$HOST_FILE" ] && jq -e '.configured == true' "$HOST_FILE" >/dev/null 2>&1; then is_host=1; fi

"$LC" legacy 2>/dev/null | grep '^legacy:' || true

if [ "$configured" = true ] && [ "$is_host" = 0 ]; then
  echo "This project's runs live on the always-on host and this machine is not it: start the run there? (It starts here only if you tell me to run it here.)"
  exit 10
fi
[ "$configured" = true ] && echo "here: this machine is the host"
exit 0
