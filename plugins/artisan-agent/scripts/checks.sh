#!/usr/bin/env bash
# The project's recorded checks: the one reader of CODING_STANDARDS.md
# `## Checks`, where /artisan-agent:setup records each check it proved can
# fail. The worker, the verifier and the plan step all read checks through
# this script, never on their own. With none recorded, each falls back to
# what it finds and says so: the fallback line always starts
# "no recorded checks". Rules: ${CLAUDE_PLUGIN_ROOT}/references/checks.md.
#
# Usage:
#   checks.sh json  [--file F | --dir D]
#       the recorded checks as JSON: {recorded, file, checks: [{command,
#       proven_on, break}], reason (when none)}. Always exit 0.
#   checks.sh list  [--file F | --dir D]
#       one recorded command per line. 16 when none (the reason on stderr).
#   checks.sh suite [--file F | --dir D]
#       one command for `sh -c` that runs every recorded check in order and
#       fails if any fails: the plan's suite_command. 16 when none.
#   checks.sh run   [--file F | --dir D] [--in DIR] [--out FILE] [--worker [--suite CMD]] [-- FOUND...]
#       runs every recorded check (sh -c, in DIR), all of them, in order, and
#       prints the results as JSON (the evidence record's "checks"):
#         {recorded: true, file, results: [{command, passed, exit_code,
#          result, log}], not_run: [each FOUND command, never run]}
#       With none recorded, runs the FOUND commands instead (what the caller
#       discovered) and says so:
#         {recorded: false, file, reason, fallback: "no recorded checks
#          (<reason>): found `a`, `b`", results: [...]}
#       --worker is for the implementing worker: a recorded check that is the
#       run's suite command (the command `checks.sh suite` prints, or --suite
#       CMD when the plan's suite_command differs) is not run: it stays for the
#       merge gate and is listed in not_run, "<command>: left to the merge
#       gate (it is the run's suite command)". The verifier and the merge gate
#       never pass --worker, so they still run it. A check is the suite when
#       its command equals that command exactly.
#       --out also writes the JSON to FILE (atomically) and each check's full
#       output beside it, in FILE's name with .logs/<n>.log.
#       Exit 0 every check passed, 7 a check failed, 16 nothing to run.
#
# F defaults to D/CODING_STANDARDS.md; D and DIR default to the top of the
# git checkout holding the current directory (or the current directory).
#
# Exit status: 0 ok, 1 error, 2 bad usage, 7 a check failed (run), 16 no
# checks recorded (list, suite) or nothing to run (run).
#
# Portable to bash 3.2 (macOS) and Linux. Needs python3 and jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'checks.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

top() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

FILE= IN= OUT= WORKER=0 SUITE=
FOUND=()
parse() { # the options shared by every command
  local dir=
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || usage; FILE=$2; shift 2 ;;
      --dir) [ $# -ge 2 ] || usage; dir=$2; shift 2 ;;
      --in) [ $# -ge 2 ] || usage; IN=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
      --worker) WORKER=1; shift ;;
      --suite) [ $# -ge 2 ] || usage; SUITE=$2; shift 2 ;;
      --) shift; FOUND=("$@"); break ;;
      *) usage ;;
    esac
  done
  [ -z "$FILE" ] || [ -z "$dir" ] || usage
  [ -z "$SUITE" ] || [ "$WORKER" = 1 ] || usage
  [ -n "$dir" ] || dir=$(top)
  [ -n "$FILE" ] || FILE="$dir/CODING_STANDARDS.md"
  case "$FILE" in /*) ;; *) FILE="$(pwd)/$FILE" ;; esac
  [ -n "$IN" ] || IN=$(top)
  [ -d "$IN" ] || die "no directory to run the checks in: $IN"
}

recorded_json() { python3 -I "$SCRIPT_DIR/lib/checks.py" "$FILE" || die "could not read $FILE"; }

commands_or_16() { # json -> the commands, or 16 with the reason
  local json=$1
  if [ "$(printf '%s' "$json" | jq -r .recorded)" != true ]; then
    printf 'checks.sh: no recorded checks (%s)\n' "$(printf '%s' "$json" | jq -r .reason)" >&2
    exit 16
  fi
  printf '%s' "$json" | jq -r '.checks[].command'
}

cmd_suite() {
  local json
  json=$(recorded_json)
  commands_or_16 "$json" >/dev/null
  # One check runs as it is; several each run in a subshell, so a check's own
  # ||, ; or & can't change what the && between them means.
  printf '%s' "$json" | jq -r '.checks | map(.command)
    | if length == 1 then .[0] else map("( " + . + " )") | join(" && ") end'
}

cmd_run() {
  local json recorded logs= i=0 rc cmd last results='[]' out suite= skipped='[]'
  json=$(recorded_json)
  recorded=$(printf '%s' "$json" | jq -r .recorded)
  local run=()
  if [ "$recorded" = true ]; then
    while IFS= read -r cmd; do run+=("$cmd"); done <<EOF
$(printf '%s' "$json" | jq -r '.checks[].command')
EOF
  else
    run=(${FOUND[@]+"${FOUND[@]}"})
  fi
  if [ "$WORKER" = 1 ] && [ "$recorded" = true ]; then
    suite=${SUITE:-$(cmd_suite)}
  fi
  if [ -n "$OUT" ]; then
    logs="${OUT%.json}.logs"
    mkdir -p "$(dirname "$OUT")" "$logs"
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/checks.XXXXXX")
  for cmd in ${run[@]+"${run[@]}"}; do
    if [ -n "$suite" ] && [ "$cmd" = "$suite" ]; then
      skipped=$(printf '%s' "$skipped" | jq -c --arg c "$cmd" '. + [$c + ": left to the merge gate (it is the run'"'"'s suite command)"]')
      continue
    fi
    i=$((i + 1))
    rc=0
    (cd "$IN" && sh -c "$cmd") >"$tmp" 2>&1 </dev/null || rc=$?
    last=$(awk 'NF { l = $0 } END { print l }' "$tmp" | cut -c1-200)
    local log=
    if [ -n "$logs" ]; then cp "$tmp" "$logs/$i.log"; log="$logs/$i.log"; fi
    results=$(printf '%s' "$results" | jq -c --arg c "$cmd" --argjson rc "$rc" --arg r "$last" --arg log "$log" \
      '. + [{command: $c, passed: ($rc == 0), exit_code: $rc, result: $r} + (if $log != "" then {log: $log} else {} end)]')
  done
  rm -f "$tmp"
  out=$(jq -n --argjson j "$json" --argjson res "$results" --argjson skipped "$skipped" --args '
    $ARGS.positional as $found
    | if $j.recorded then
        {recorded: true, file: $j.file, results: $res,
         not_run: ($skipped + [$found[] | select(. as $f | [$j.checks[].command] | index($f) | not)])}
      else
        {recorded: false, file: $j.file, reason: $j.reason,
         fallback: ("no recorded checks (\($j.reason)): found "
                    + (if ($found | length) == 0 then "nothing" else ($found | map("`" + . + "`") | join(", ")) end)),
         results: $res}
      end' ${FOUND[@]+"${FOUND[@]}"})
  if [ -n "$OUT" ]; then
    printf '%s\n' "$out" >"$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
  fi
  printf '%s\n' "$out"
  [ "$i" -gt 0 ] || [ "$skipped" != '[]' ] || exit 16
  [ "$(printf '%s' "$results" | jq 'all(.passed)')" = true ] || exit 7
}

[ $# -ge 1 ] || usage
cmd=$1
shift
parse "$@"
case "$cmd" in
  json) recorded_json ;;
  list) commands_or_16 "$(recorded_json)" ;;
  suite) cmd_suite ;;
  run) cmd_run ;;
  *) usage ;;
esac
