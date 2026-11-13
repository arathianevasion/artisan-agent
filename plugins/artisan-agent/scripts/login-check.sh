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
#       that is not the host (no host.json written by host setup) is not
#       checked, exit 0. A host with no login stamp is refused too: unknown is
#       not safe.
#       The span from a run folder, tickets not yet merged or closed only: per forecast wave, its longest ticket
#       (expected.minutes, else half its deadline), summed; with no forecast
#       waves, every ticket in scope in turn.
#   login-check.sh stamp [--at EPOCH] [--lifetime-days N]
#       record that the login was made now (or --at), in login.json. It never
#       creates host.json: only host setup does (#108).
#   login-check.sh show
#       print the host record (host.json) and the login stamp (login.json)
#   login-check.sh legacy
#       exit 0 and say so when host.json is only a leftover of an old stamp
#       (no host setup wrote it): that machine is not a host. Exit 1 if not.
#   login-check.sh cleanup
#       fix a legacy host.json: move its stamp into login.json and remove it.
#       A real host's stamp is moved too, and its host.json kept.
#
# The individual home is ARTISAN_HOME, default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent.
# host.json there means "this machine is the host" (written by host setup:
# {configured: true, workdir, ...}); login.json is the login stamp:
# {login_at, login_lifetime_days}. A host.json with no `configured` is not a host.
# Exit status: 0 ok, 1 error, 2 usage, 15 refused (would expire, or no stamp).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
HOST_FILE=$HOME_DIR/host.json
LOGIN_FILE=$HOME_DIR/login.json
DEFAULT_LIFETIME_DAYS=30

usage() { state_usage "$0"; }

# A machine is the host when host setup wrote host.json (configured: true).
is_host() { [ -f "$HOST_FILE" ] && jq -e '.configured == true' "$HOST_FILE" >/dev/null 2>&1; }
# host.json that exists but host setup did not write: an old login stamp made it.
is_legacy() { [ -f "$HOST_FILE" ] && ! is_host; }
# The login stamp: login.json, else (a host set up before #108) host.json.
login_source() { if [ -f "$LOGIN_FILE" ]; then echo "$LOGIN_FILE"; else echo "$HOST_FILE"; fi; }

fmt_time() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

span_of_run() { # run-dir -> minutes
  jq -r '
    (.plan.tickets // {}) as $t | (.tickets // {}) as $prog
    | def left($n): (($prog[$n].status // "queued") | . != "merged" and . != "closed");
    def mins($n): ($t[$n].expected.minutes // (($t[$n].caps.deadline_seconds // 3600) / 120));
    ((.plan.waves // []) | map(select(length > 0))) as $w
    | if ($w | length) > 0
      then ([$w[] | map(select(left(.)) | mins(.)) | max // 0] | add // 0)
      else ([.plan.scope[]? | select(left(.)) | mins(.)] | add // 0) end
    | ceil' "$(state_file "$1")"
}

cmd_check() {
  local span="" margin=120 now= expires= login_at= days= need= rd="" src=
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
  if ! is_host; then
    echo "no host here: the login is not checked"
    is_legacy && echo "note: $HOST_FILE came from a login stamp, not host setup; run: login-check.sh cleanup" >&2
    return 0
  fi
  if [ -z "$span" ]; then
    state_require_run_dir "$rd"
    span=$(span_of_run "$rd")
  fi
  state_is_uint "$span" && state_is_uint "$margin" || state_die 2 "login-check.sh: minutes must be whole numbers"
  src=$(login_source)
  login_at=$(jq -r '.login_at // empty' "$src")
  if [ -z "$login_at" ]; then
    echo "login-check.sh: refused: $LOGIN_FILE records no login time, so the login's expiry is unknown. Log in (claude auth login), then run: login-check.sh stamp" >&2
    return 15
  fi
  days=$(jq -r --argjson d "$DEFAULT_LIFETIME_DAYS" '.login_lifetime_days // $d' "$src")
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
  local at="" days="" tmp=
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) [ $# -ge 2 ] || usage; at=$2; shift 2 ;;
      --lifetime-days) [ $# -ge 2 ] || usage; days=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$at" ] || at=$(state_now)
  state_is_uint "$at" && { [ -z "$days" ] || state_is_uint "$days"; } || state_die 2 "login-check.sh: --at and --lifetime-days must be whole numbers"
  mkdir -p "$HOME_DIR"
  [ -f "$LOGIN_FILE" ] || echo '{}' >"$LOGIN_FILE"
  tmp="$LOGIN_FILE.tmp.$$"
  jq --argjson at "$at" --arg d "$days" --argjson dl "$DEFAULT_LIFETIME_DAYS" '.login_at = $at | .login_lifetime_days = (if $d == "" then (.login_lifetime_days // $dl) else ($d | tonumber) end)' "$LOGIN_FILE" >"$tmp"
  mv -f "$tmp" "$LOGIN_FILE"
  printf 'recorded: login at %s\n' "$(fmt_time "$at")"
}

cmd_legacy() {
  if is_legacy; then
    echo "legacy: $HOST_FILE was made by a login stamp, not by host setup, so this machine is not the host. Offer the Artisan: login-check.sh cleanup (moves the stamp to $LOGIN_FILE and removes the file)"
    return 0
  fi
  echo "ok: nothing to clean up"
  return 1
}

cmd_cleanup() { # move a stamp out of host.json into login.json
  local tmp=
  if [ ! -f "$HOST_FILE" ] || ! jq -e 'has("login_at") or has("login_lifetime_days")' "$HOST_FILE" >/dev/null 2>&1; then
    echo "unchanged: no login stamp in $HOST_FILE"
    return 0
  fi
  mkdir -p "$HOME_DIR"
  [ -f "$LOGIN_FILE" ] || echo '{}' >"$LOGIN_FILE"
  tmp="$LOGIN_FILE.tmp.$$"
  # an existing login.json wins; host.json only fills what it lacks
  jq -s '(.[1] | {login_at, login_lifetime_days} | with_entries(select(.value != null))) + .[0]' "$LOGIN_FILE" "$HOST_FILE" >"$tmp"
  mv -f "$tmp" "$LOGIN_FILE"
  if is_host; then
    tmp="$HOST_FILE.tmp.$$"
    jq 'del(.login_at, .login_lifetime_days)' "$HOST_FILE" >"$tmp" && mv -f "$tmp" "$HOST_FILE"
    echo "changed: moved the login stamp to $LOGIN_FILE; $HOST_FILE kept (this machine is a host)"
  else
    rm -f "$HOST_FILE"
    echo "changed: moved the login stamp to $LOGIN_FILE and removed $HOST_FILE; this machine is not a host"
  fi
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  stamp) shift; cmd_stamp "$@" ;;
  legacy) cmd_legacy ;;
  cleanup) cmd_cleanup ;;
  show) for f in "$HOST_FILE" "$LOGIN_FILE"; do [ -f "$f" ] && cat "$f" || echo "{}"; done ;;
  *) usage ;;
esac
