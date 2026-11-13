#!/usr/bin/env bash
# Wave width: which frontier tickets the orchestrator dispatches now. The
# width is the smallest of Max Agents (less what is in flight), the ready
# tickets, and the tickets whose expected file sets don't overlap. The rules:
# ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/parallel-waves.md.
#
# Usage:
#   wave-width.sh pick <run-dir>
#       the tickets to dispatch now, one per line, from the frontier the
#       reconciler last stored, in its order. Each ticket held back gets one
#       line on stderr: "held #<t>: <why>".
#   wave-width.sh check <run-dir> <ticket>
#       0 when the ticket may join the current wave; 10, with the reason on
#       stderr, when its expected files overlap a ticket in flight or one
#       already dispatched in this wave. wave.sh dispatch calls it.
#
# A ticket's expected file set is plan.tickets.<t>.expected_files: paths from
# the repo root, a path ending in "/" meaning everything under it. Two sets
# overlap when a path in one equals, or lies under a directory in, the other.
# A ticket with no expected_files is assumed to overlap everything, so it
# runs alone in its wave rather than risk merge rework.
#
# Exit status: 0 ok, 1 error, 2 usage, 10 overlap (check).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }

# jq: the current wave (the last orchestrator's, 0 before any) and, for a
# candidate ticket, the first ticket in the way: {ticket, why} or null.
WIDTH_JQ="$STATE_JQ_DEFS"'
  def files($t): .plan.tickets[$t].expected_files // null;
  def under($a; $b): $a == $b or ($b | endswith("/")) and ($a | startswith($b));
  def overlap($x; $y):
    if $x == null or $y == null then "unknown"
    else first($x[] as $a | $y[] as $b | select(under($a; $b) or under($b; $a))
               | if under($a; $b) then $a else $b end) // null end;
  # Tickets the candidate must not share a wave with: in flight, or
  # dispatched in this wave (merged, blocked or waiting to retry).
  def peers($t): current_wave as $w
    | [.tickets | to_entries[] | select(.key != $t)
       | select(.value.status == "in_flight" or (.value.wave != null and .value.wave == $w))
       | .key];
  def in_the_way($t; $others):
    . as $s
    | first($others[] as $o | overlap($s | files($t); $s | files($o)) as $hit
            | select($hit != null)
            | {ticket: $o,
               why: (if $hit == "unknown"
                     then "#\(if ($s | files($t)) == null then $t else $o end) declares no expected_files"
                     else "both expect \($hit)" end)}) // null;
'

cmd_check() {
  local file="$1" t="$2" hit=
  hit=$(jq -r --arg t "$t" "$WIDTH_JQ"'
    in_the_way($t; peers($t)) | if . == null then "" else "overlaps #\(.ticket): \(.why)" end' "$file")
  [ -z "$hit" ] || state_die 10 "wave-width.sh: #$t can't join this wave: it $hit"
}

cmd_pick() {
  local file="$1"
  jq -r "$WIDTH_JQ"'
    . as $s
    | ($s.plan.max_agents // 5) as $max
    | ([$s.tickets[] | select(.status == "in_flight" and ((.urgent // false) | not))] | length) as $busy
    | reduce ($s.frontier // [])[] as $t ({picked: [], held: []};
        if ($s.tickets[$t].status // "") != "queued" then .
        elif ((.picked | length) + $busy) >= $max then
          .held += ["held #\($t): no free slot (Max Agents \($max), \($busy) in flight)"]
        else .picked as $p | ($s | in_the_way($t; peers($t) + $p)) as $hit
          | if $hit == null then .picked += [$t]
            else .held += ["held #\($t): overlaps #\($hit.ticket): \($hit.why)"] end
        end)
    | (.picked[] | "pick " + .), (.held[] | "held " + .)' "$file" \
  | while IFS= read -r line; do
      case "$line" in
        "pick "*) printf '%s\n' "${line#pick }" ;;
        "held "*) printf '%s\n' "${line#held }" >&2 ;;
      esac
    done
}

[ $# -ge 2 ] || usage
cmd=$1
state_require_run_dir "$2"
FILE=$(state_file "$2")
state_valid_file "$FILE" || state_die 1 "wave-width.sh: $(state_version_message "$FILE")"
case "$cmd" in
  pick) [ $# -eq 2 ] || usage; cmd_pick "$FILE" ;;
  check) [ $# -eq 3 ] || usage; cmd_check "$FILE" "$3" ;;
  *) usage ;;
esac
