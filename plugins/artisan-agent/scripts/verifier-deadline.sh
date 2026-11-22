#!/usr/bin/env bash
# The verifier's wall-clock deadline (#347): the measured time of the recorded
# checks it will run, plus an allowance for its criteria. A fixed deadline
# can't fit a project whose recorded check is the full suite: ten verifiers
# ended on it before judging anything.
#
# Usage:
#   verifier-deadline.sh [--file F | --dir D] [--history RUNS_DIR]
#                        [--leave SUITE_CMD] --criteria N
#       Prints one JSON object:
#         {deadline_seconds, measured_seconds, allowance_seconds, criteria,
#          source, runs, note}
#       source is "measured" (every check the verifier will run has a
#       measured time) or "default" (the fixed 30 minutes: some such check
#       has none, so the deadline is the fixed value, not a guess).
#
# The checks the verifier will run are the recorded ones (checks.sh json),
# less SUITE_CMD (--leave: the check that is the run's suite command, which
# a verifier on a CI machine leaves to the merge gate) and the checks
# checks.sh ci-only lists. Their measured time is the slowest `seconds` each
# command took in any earlier verifier's checks output,
# RUNS_DIR/*/verify/checks/*.json (checks.sh run records it), summed.
#
# allowance = max(15 minutes, 3 minutes x criteria); deadline = measured +
# allowance. A plan sets its own with plan.verifier.minutes (verify.sh).
#
# Exit status: 0 ok, 1 error, 2 usage.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

FIXED_SECONDS=1800
ALLOWANCE_FLOOR_SECONDS=900
PER_CRITERION_SECONDS=180

usage() { sed -n '2,/^set /p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'verifier-deadline.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

where=() history="" leave="" criteria=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file|--dir) [ $# -ge 2 ] || usage; where=("$1" "$2"); shift 2 ;;
    --history) [ $# -ge 2 ] || usage; history=$2; shift 2 ;;
    --leave) [ $# -ge 2 ] || usage; leave=$2; shift 2 ;;
    --criteria) [ $# -ge 2 ] || usage; criteria=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$criteria" in ''|*[!0-9]*) usage ;; esac

json=$("$SCRIPT_DIR/checks.sh" json ${where[@]+"${where[@]}"}) || exit 1
ci=$("$SCRIPT_DIR/checks.sh" ci-only ${where[@]+"${where[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))') || exit 1

# Every earlier verifier's measured results, one {command, seconds} per line.
hist='[]'
files=()
if [ -n "$history" ] && [ -d "$history" ]; then
  for f in "$history"/*/verify/checks/*.json; do [ -f "$f" ] && files+=("$f"); done
fi
if [ ${#files[@]} -gt 0 ]; then
  hist=$(jq -sc '[.[] | objects | (.results // [])[] | select((.seconds // null) != null) | {command, seconds}]' "${files[@]}" 2>/dev/null) || hist='[]'
fi
runs=${#files[@]}

jq -n --argjson j "$json" --argjson ci "$ci" --argjson hist "$hist" --arg leave "$leave" \
  --argjson crit "$criteria" --argjson runs "$runs" --argjson fixed "$FIXED_SECONDS" \
  --argjson floor "$ALLOWANCE_FLOOR_SECONDS" --argjson per "$PER_CRITERION_SECONDS" '
  ([$crit * $per, $floor] | max) as $allow
  | (if $j.recorded then [$j.checks[].command | select(. != $leave and (. as $c | $ci | index($c) | not))] else [] end) as $run
  | ($run | map(. as $c | [$hist[] | select(.command == $c) | .seconds] | if length == 0 then null else max end)) as $times
  | if ($j.recorded | not) then
      {deadline_seconds: $fixed, measured_seconds: 0, allowance_seconds: $allow, criteria: $crit, source: "default", runs: $runs,
       note: "no recorded checks: the fixed deadline"}
    elif ($run | length) == 0 then
      {deadline_seconds: ([$fixed, $allow] | max), measured_seconds: 0, allowance_seconds: $allow, criteria: $crit, source: "measured", runs: $runs,
       note: "no recorded check to run: the criteria allowance alone (the fixed deadline at least)"}
    elif ($times | index(null)) != null then
      {deadline_seconds: $fixed, measured_seconds: null, allowance_seconds: $allow, criteria: $crit, source: "default", runs: $runs,
       note: "no measured time for \($run[$times | index(null)]): the fixed deadline"}
    else
      ($times | add) as $m
      | {deadline_seconds: ($m + $allow), measured_seconds: $m, allowance_seconds: $allow, criteria: $crit, source: "measured", runs: $runs,
         note: "measured checks \($m) s + criteria allowance \($allow) s"}
    end'
