#!/usr/bin/env bash
# A worker's full suite before hand-in (#406). The covering tests miss what
# cuts across scripts (whole-tree rule checks, one script's output read
# through another), and a red merge gate costs a new attempt, so the worker
# (/artisan-agent:implement) runs the project's recorded suite on its own
# commit before it writes its result. It runs on the home PC: the host the
# merge gate's local fallback uses (ci_gate.fallback_host, default
# home-wsl), in a fresh clone of the commit sent there as a git bundle
# (lib/remote-suite-lib.sh). When the host doesn't answer, nothing runs here:
# a full local suite is the slow case #376 ruled out, so the worker runs the
# guard tests and its covering tests instead. The merge gate still runs the
# suite after the merge. Rules: ${CLAUDE_PLUGIN_ROOT}/references/checks.md,
# "A worker's full suite".
#
# Usage:
#   worker-suite.sh run [--dir D] [--host H] [--command CMD] [--log FILE]
#       run CMD (default: checks.sh suite in D, the recorded checks) on H
#       (default: the project's ci_gate.fallback_host; "" for none) against
#       D's HEAD (D defaults to the top of the checkout holding the current
#       directory, which must have nothing uncommitted). Output to FILE
#       (default: a temporary file, named in the record). Prints the record
#       for the evidence record's tests.full_suite, as JSON:
#         ran on H:  {where: H, ran: true, commit, command, passed,
#                     counts: {passed, failed}, summary, log, seconds}
#         not run:   {where: "local", ran: false, commit, command, why,
#                     instead: "the guard tests and the covering tests, here"}
#       counts are read from the log's last "N passed" and "N failed" (null
#       when it has none); summary is the log's last line naming either.
#       Exit 0 green, 7 red, 17 H did not answer ssh, the link failed, the
#       clone could not be made there, or no host is set (the worker runs the
#       guard and covering tests here), 16 no recorded checks and no --command
#       (prints {ran: false, why}), 1 error (uncommitted work), 2 bad usage.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git and jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/remote-suite-lib.sh
. "$SCRIPT_DIR/lib/remote-suite-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'worker-suite.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

# fallback_host: the project's ci_gate.fallback_host, home-wsl when unset.
fallback_host() {
  local h=""
  h=$(cd "$DIR" && "$SCRIPT_DIR/config.sh" get ci_gate.fallback_host 2>/dev/null) || h='"home-wsl"'
  jq -r '. // ""' <<<"$h"
}

# last_count word log: the number before the last "<n> <word>" in log.
last_count() {
  grep -oE "[0-9]+ $1" "$2" 2>/dev/null | tail -1 | grep -oE '^[0-9]+' || true
}

cmd_run() {
  local host_set=0 host="" cmd="" log="" sha="" rc=0 why="" started=0 passed=true summary="" np="" nf=""
  DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || usage; DIR=$2; shift 2 ;;
      --host) [ $# -ge 2 ] || usage; host=$2; host_set=1; shift 2 ;;
      --command) [ $# -ge 2 ] || usage; cmd=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || usage; log=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$DIR" ] || DIR=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git checkout"
  sha=$(git -C "$DIR" rev-parse HEAD) || die "no commit in $DIR"
  [ -z "$(git -C "$DIR" status --porcelain)" ] \
    || die "uncommitted work in $DIR: commit it first, so the suite runs on what you hand in"
  if [ -z "$cmd" ]; then
    if ! cmd=$(cd "$DIR" && "$SCRIPT_DIR/checks.sh" suite 2>/dev/null); then
      jq -nc --arg s "$sha" '{where: "local", ran: false, commit: $s, why: "no recorded checks: nothing to run as the full suite"}'
      return 16
    fi
  fi
  [ "$host_set" = 1 ] || host=$(fallback_host)
  [ -n "$log" ] || log=$(mktemp "${TMPDIR:-/tmp}/artisan-worker-suite.XXXXXX")
  mkdir -p "$(dirname "$log")"; : >"$log"

  if [ -z "$host" ]; then
    why="no host set (ci_gate.fallback_host is empty)"
  elif ! remote_host_up "$host"; then
    why="$host did not answer ssh within 10 seconds"
  else
    started=$(date +%s)
    remote_suite "$host" "$DIR" "$sha" "$cmd" "$log" || rc=$?
    case "$rc" in
      255) why="the ssh link to $host failed during the run" ;;
      "$REMOTE_NO_CHECKOUT") why="could not check out $sha on $host" ;;
      1) [ -s "$log" ] || why="could not bundle $sha here" ;;
    esac
  fi
  if [ -n "$why" ]; then
    echo "worker-suite.sh: full suite not run ($why); run the guard tests and the covering tests here" >&2
    jq -nc --arg s "$sha" --arg c "$cmd" --arg w "$why" \
      '{where: "local", ran: false, commit: $s, command: $c, why: $w,
        instead: "the guard tests and the covering tests, here"}'
    return 17
  fi

  [ "$rc" -eq 0 ] || passed=false
  np=$(last_count passed "$log"); nf=$(last_count failed "$log")
  summary=$(grep -E '[0-9]+ (passed|failed)' "$log" | tail -1 || true)
  echo "worker-suite.sh: full suite on $host: $([ "$passed" = true ] && echo passed || echo failed) ($log)" >&2
  jq -nc --arg h "$host" --arg s "$sha" --arg c "$cmd" --argjson p "$passed" \
    --arg np "$np" --arg nf "$nf" --arg sum "$summary" --arg l "$log" \
    --argjson secs "$(( $(date +%s) - started ))" \
    '{where: $h, ran: true, commit: $s, command: $c, passed: $p,
      counts: {passed: (if $np == "" then null else ($np | tonumber) end),
               failed: (if $nf == "" then null else ($nf | tonumber) end)},
      summary: $sum, log: $l, seconds: $secs}'
  [ "$passed" = true ] || return 7
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  *) usage ;;
esac
