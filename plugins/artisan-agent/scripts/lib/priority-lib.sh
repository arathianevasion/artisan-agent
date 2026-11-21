# shellcheck shell=bash
# Background priority (#248): the one place a suite or recorded check the
# pipeline starts on this machine gets its priority. checks.sh run (the
# worker's and the verifier's), the local merge gate (merge-gate.sh local,
# which wave.sh merge and wave.sh resolved start) and end-gate.sh
# urgent-finish all start their commands through priority_run, so a wave's
# suites never take the machine from the Artisan's own apps. Sourced, never run.
#
# host.json in the individual home holds local_suite_priority: background |
# normal (ARTISAN_LOCAL_SUITE_PRIORITY overrides it, for tests and trials).
# Missing means background; machine setup leaves it unset. background runs
# the command under nice -n 10 on both, inside ionice -c 3 on Linux where it
# works. Never taskpolicy -b on macOS (#312): it throttles disk and network
# too and ran a 4-minute suite in about 85. Children inherit it. normal runs it
# directly, as before #248. A priority tool missing (or refusing) runs the
# command at normal priority with a one-line note on stderr ("<tool> not
# found" or "<tool> could not run here"); it never fails the run.
# Rules: ${CLAUDE_PLUGIN_ROOT}/references/checks.md, "Background priority".
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

PRIORITY_PREFIX=()
PRIORITY_READY=

# priority_host_file: where host.json is (as merge-gate.sh and login-check.sh).
priority_host_file() {
  printf '%s/host.json\n' "${ARTISAN_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent}"
}

# priority_setting: "<background|normal> <source>"; for any other value, 1
# and a line naming the allowed values on stderr.
priority_setting() {
  local p="" src="" f=""
  f=$(priority_host_file)
  if [ -n "${ARTISAN_LOCAL_SUITE_PRIORITY:-}" ]; then
    p=$ARTISAN_LOCAL_SUITE_PRIORITY src=ARTISAN_LOCAL_SUITE_PRIORITY
  elif [ -f "$f" ] && p=$(jq -er '.local_suite_priority // empty' "$f" 2>/dev/null); then
    src=$f
  else
    p=background src=default
  fi
  case "$p" in
    background | normal) printf '%s %s\n' "$p" "$src" ;;
    *) printf 'local_suite_priority must be background or normal, not "%s" (%s)\n' "$p" "$src" >&2; return 1 ;;
  esac
}

# priority_os: macos or linux (ARTISAN_HOST_OS stands in for uname, as in
# merge-gate.sh).
priority_os() {
  if [ -n "${ARTISAN_HOST_OS:-}" ]; then printf '%s\n' "$ARTISAN_HOST_OS"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then echo macos; else echo linux; fi
}

# priority_tool name args...: 0 when name is on PATH and runs `true` with
# args; otherwise 1 and PRIORITY_WHY says why ("not found" or "could not run
# here").
PRIORITY_WHY=
priority_tool() {
  local n="$1"
  shift
  PRIORITY_WHY="$n not found"
  command -v "$n" >/dev/null 2>&1 || return 1
  PRIORITY_WHY="$n could not run here"
  "$n" "$@" true >/dev/null 2>&1
}

# priority_init: read the setting once and set PRIORITY_PREFIX, the command
# words priority_run puts first; notes go to stderr. 1 on a bad setting.
priority_init() {
  local setting=""
  setting=$(priority_setting) || return 1
  PRIORITY_PREFIX=()
  PRIORITY_READY=1
  [ "${setting%% *}" = background ] || return 0
  if ! priority_tool nice -n 10; then
    echo "$PRIORITY_WHY: ran at normal priority" >&2
    return 0
  fi
  PRIORITY_PREFIX=(nice -n 10)
  # ionice is Linux's; macOS has none.
  [ "$(priority_os)" = macos ] && return 0
  if priority_tool ionice -c 3; then PRIORITY_PREFIX=(ionice -c 3 nice -n 10)
  else echo "$PRIORITY_WHY: disk at normal priority" >&2; fi
}

# priority_run command...: run command at this machine's suite priority
# (priority_init first, if the caller hasn't).
priority_run() {
  [ -n "$PRIORITY_READY" ] || priority_init || return 1
  ${PRIORITY_PREFIX[@]+"${PRIORITY_PREFIX[@]}"} "$@"
}
