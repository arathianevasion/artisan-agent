#!/usr/bin/env bash
# The claude.ai login-expiry check for a run on the always-on host (#69, pilot
# prerequisite 10). Spec: a run must not die overnight because the login ran out.
# The login lasts about 30 days (observed, not documented), and nothing reports
# when it started, so the host records it: `stamp` right after logging in.
#
# Usage:
#   login-check.sh check (--run-dir D | --span-minutes N) [--margin-minutes M] [--now EPOCH]
#       refuse (exit 15) when the login would expire before the run ends: now +
#       the run's expected span + the margin (default 120 minutes). A machine
#       with no host record (host.json) is not a host: nothing is checked, exit 0.
#       A host record with no login stamp is refused too: unknown is not safe.
#       The span from a run folder: per forecast wave, its longest ticket
#       (expected.minutes, else half its deadline), summed; with no forecast
#       waves, every ticket in scope in turn.
#   login-check.sh stamp [--at EPOCH] [--lifetime-days N]
#       record that the login was made now (or --at). Creates host.json.
#   login-check.sh show
#       print host.json
#
# host.json lives in the individual home (ARTISAN_HOME, default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent): {login_at, login_lifetime_days, ...}.
# Exit status: 0 ok, 1 error, 2 usage, 15 refused (would expire, or no stamp).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOST_FILE=${ARTISAN_HOME:-$CFG/artisan-agent}/host.json
DEFAULT_LIFETIME_DAYS=30

usage() { state_usage "$0"; }

fmt_time() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

span_of_run() { # run-dir -> minutes
  jq -r '
    (.plan.tickets // {}) as $t
    | def mins($n): ($t[$n].expected.minutes // (($t[$n].caps.deadline_seconds // 3600) / 120));
    ((.plan.waves // []) | map(select(length > 0))) as $w
    | if ($w | length) > 0
      then ([$w[] | map(mins(.)) | max // 0] | add)
      else ([.plan.scope[]? | mins(.)] | add // 0) end
    | ceil' "$(state_file "$1")"
}

cmd_check() {
  local span="" margin=120 now expires login_at days need rd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) [ $# -ge 2 ] || usage; rd=$2; shift 2 ;;
      --span-minutes) [ $# -ge 2 ] || usage; span=$2; shift 2 ;;
      --margin-minutes) [ $# -ge 2 ] || usage; margin=$2; shift 2 ;;
      --now) [ $# -ge 2 ] || usage; ARTISAN_NOW=$2; export ARTISAN_NOW; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$span" ] || [ -n "$rd" ] || usage
  if [ ! -f "$HOST_FILE" ]; then
    echo "no host here: the login is not checked"
    return 0
  fi
  if [ -z "$span" ]; then
    state_require_run_dir "$rd"
    span=$(span_of_run "$rd")
  fi
  case "$span$margin" in *[!0-9]*) state_die 2 "login-check.sh: minutes must be whole numbers" ;; esac
  login_at=$(jq -r '.login_at // empty' "$HOST_FILE")
  if [ -z "$login_at" ]; then
    echo "login-check.sh: refused: $HOST_FILE records no login time, so the login's expiry is unknown. Log in (claude auth login), then run: login-check.sh stamp" >&2
    return 15
  fi
  days=$(jq -r --argjson d "$DEFAULT_LIFETIME_DAYS" '.login_lifetime_days // $d' "$HOST_FILE")
  now=$(state_now)
  expires=$((login_at + days * 86400))
  need=$((now + (span + margin) * 60))
  if [ "$need" -gt "$expires" ]; then
    printf 'login-check.sh: refused: the claude.ai login expires %s and this run needs it until about %s (%s minutes expected, %s of margin). Log in again (claude auth login), then run: login-check.sh stamp\n' \
      "$(fmt_time "$expires")" "$(fmt_time "$need")" "$span" "$margin" >&2
    return 15
  fi
  printf 'ok: the login lasts until %s; the run needs it until about %s\n' "$(fmt_time "$expires")" "$(fmt_time "$need")"
}

cmd_stamp() {
  local at="" days="" tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) [ $# -ge 2 ] || usage; at=$2; shift 2 ;;
      --lifetime-days) [ $# -ge 2 ] || usage; days=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$at" ] || at=$(state_now)
  case "$at${days:-0}" in *[!0-9]*) state_die 2 "login-check.sh: --at and --lifetime-days must be whole numbers" ;; esac
  mkdir -p "$(dirname "$HOST_FILE")"
  [ -f "$HOST_FILE" ] || echo '{}' >"$HOST_FILE"
  tmp="$HOST_FILE.tmp.$$"
  jq --argjson at "$at" --arg d "$days" '.login_at = $at | .login_lifetime_days = (if $d == "" then (.login_lifetime_days // 30) else ($d | tonumber) end)' "$HOST_FILE" >"$tmp"
  mv -f "$tmp" "$HOST_FILE"
  printf 'recorded: login at %s\n' "$(fmt_time "$at")"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  stamp) shift; cmd_stamp "$@" ;;
  show) [ -f "$HOST_FILE" ] && cat "$HOST_FILE" || echo "{}" ;;
  *) usage ;;
esac
