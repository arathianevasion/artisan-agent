#!/usr/bin/env bash
# Gate placement at the plan step (#71): propose the run's gates into the
# draft plan, show them, and take the Artisan's moves and removals. The rules:
# ${CLAUDE_PLUGIN_ROOT}/references/end-gate.md, "Gate placement".
#
# Usage, from the Engineering chat at the plan step:
#   gate-plan.sh propose <draft.json> [--config FILE]
#       writes the draft's `gates`: one slice gate per slice (a ticket with no
#       `slice` is its own), a risk gate per ticket whose `escalation` names
#       an escalation test, and the end gate. For `route` "small-change" or
#       "bug" there is no slice gate: the end gate doubles as one (and, for a
#       bug, leads with the failing test). Prints the table, as render does.
#       Areas (#77): a ticket belongs to every area in the config (`areas.<name>`:
#       `paths`, `gates`) that a path in its draft `paths` falls under (a path
#       equal to, or inside, an area path). The ticket's `areas` is written to
#       the draft and named under the table. An area's `gates` list says what
#       its tickets get: `slice` (a slice gate of the ticket alone) and/or
#       `risk` (a risk gate, test `area:<name>`). A ticket in several areas gets
#       the union, the strictest setting. With no areas configured, nothing
#       changes. --config reads FILE instead of the project's config.yml.
#   gate-plan.sh render <draft.json>
#       the gates as a Markdown table, numbered as the run will number them
#       (slice-<n>, risk-<n>, end).
#   gate-plan.sh remove <draft.json> <gate-id>
#       removes a slice, risk or end gate. An exception gate is refused (6):
#       exception gates are never placed in the plan and can't be removed.
#   gate-plan.sh move <draft.json> <gate-id> (--after T | --tickets T,T...)
#       a slice gate opens once those tickets merge; a risk gate (--after
#       only) once that ticket does. The end gate has one place and is
#       refused (6); remove it instead.
#
# Draft fields read: scope, route (feature, small-change or bug; default
# feature), tickets.<t>.title, .slice, .paths (the files it touches, for areas),
# .escalation (any of new-seam, tracer-bullet, vocabulary-adr,
# judgement-criteria). Every command except
# render rewrites the draft in place and prints the table.
#
# Exit status: 0 ok, 1 error, 2 usage (or an unknown escalation test), 4 a
# ticket outside the plan's scope, 6 refused (an exception gate, an unknown
# gate, moving the end gate).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
die() { echo "gate-plan.sh: $*" >&2; exit "${2:-1}"; }
command -v jq >/dev/null 2>&1 || die "jq is required"

TESTS='["new-seam","tracer-bullet","vocabulary-adr","judgement-criteria"]'

# Positional ids, as scripts/lib/state-lib.sh numbers them in the run.
JQ_DEFS='
  def test_label: {"new-seam": "new seam or module boundary", "tracer-bullet": "first tracer bullet through a new layer",
              "vocabulary-adr": "change to vocabulary or an ADR", "judgement-criteria": "judgement-like acceptance criteria"}[.]
              // (if startswith("area:") then "area \(.[5:]) gate setting" else . end);
  def ids: [.gates // [] | to_entries[] | (if .value.kind == "end" then "end" else "\(.value.kind)-\(.key + 1)" end)];
  def tref($d): "#\(.)" + (($d.tickets[.].title // null) | if . then " (\(.))" else "" end);
'

write() { # draft filter [jq args]: rewrite the draft in one step
  local f="$1" filter="$2" tmp=
  shift 2
  tmp="$f.tmp.$$"
  jq "$JQ_DEFS $filter" "$@" "$f" >"$tmp" || { rm -f "$tmp"; die "could not rewrite $f"; }
  mv "$tmp" "$f"
}

need_draft() { [ -f "${1:-}" ] || die "no draft at ${1:-}"; jq -e 'type == "object"' "$1" >/dev/null 2>&1 || die "$1 is not a JSON object"; }

cmd_render() {
  [ $# -eq 1 ] || usage
  need_draft "$1"
  jq -r "$JQ_DEFS"'
    . as $d | ids as $ids
    | "| Gate | Kind | Opens after | Why | Can be removed |", "|---|---|---|---|---|",
      (.gates // [] | to_entries[] | .key as $k | .value as $g
       | ($g.tickets // (if $g.after then [$g.after] else null end)
          // [$d.scope[] | select($d.tickets[.].slice? == $g.slice)]) as $ts
       | "| \($ids[$k]) | \($g.kind) | "
         + (if $g.kind == "end" then "every ticket in scope is done"
            else ($ts | map(tref($d)) | join(", ")) + (if ($ts | length) == 1 then " merges" else " merge" end) end)
         + " | "
         + (if $g.kind == "slice" then "the slice \($g.slice // $ts[0] | tostring) is reviewable end to end"
            elif $g.kind == "risk" then ($g.tests // [] | map(test_label) | join(", "))
            elif $g.doubles_as_slice then "the end gate, doubling as the slice gate" + (if $g.bug then "; it leads with the failing test" else "" end)
            else "the end gate, before the PRs to main" end)
         + " | yes |"),
      "",
      ([$d.scope // [] | .[] | tostring | select(($d.tickets[.].areas // []) | length > 0)] as $in
       | if ($in | length) == 0 then empty
         else "| Ticket | Areas |", "|---|---|",
              ($in[] | . as $t | "| \($t | tref($d)) | \($d.tickets[$t].areas | join(", ")) |"), "" end),
      "Exception gates are never placed here: the run opens one whenever it gives up on a ticket or a check won'"'"'t go green, and none can be removed."' "$1"
}

cmd_propose() {
  local f="" config="" cfg="" areas="{}" a=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) [ $# -ge 2 ] || usage; config=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$f" ] || usage; f=$1; shift ;;
    esac
  done
  [ -n "$f" ] || usage
  set -- "$f"
  need_draft "$1"
  if [ -n "$config" ]; then cfg=$("$SCRIPT_DIR/config.sh" show --file "$config") || exit 1
  elif git rev-parse --git-common-dir >/dev/null 2>&1; then cfg=$("$SCRIPT_DIR/config.sh" show) || exit 1
  else cfg='{}'; fi # outside a repository there is no project config: no areas
  areas=$(jq -c '.areas // {}' <<<"$cfg")
  a=$(jq -r '[.[] | (.gates // [])[] | select(. != "slice" and . != "risk")] | unique | join(", ")' <<<"$areas")
  [ -z "$a" ] || die "an area's gates may be slice or risk, not: $a" 2
  local bad=""
  bad=$(jq -r --argjson ok "$TESTS" '[.tickets // {} | to_entries[] | .value.escalation // [] | .[] | select(. as $e | $ok | index($e) | not)] | unique | join(", ")' "$1")
  [ -z "$bad" ] || die "unknown escalation test: $bad (one of new-seam, tracer-bullet, vocabulary-adr, judgement-criteria)" 2
  case "$(jq -r '.route // "feature"' "$1")" in feature|small-change|bug) ;; *) die "route must be feature, small-change or bug" 2 ;; esac
  write "$1" '
    def under($p; $f): ($p | tostring | sub("/+$"; "")) as $b | ($f == $b or ($f | startswith($b + "/")));
    def areas_of($paths): [$areas | to_entries[] | select(.value.paths // [] | any(. as $p | $paths | any(. as $f | under($p; $f)))) | .key];
    def has_gate($names; $g): [$names[] | $areas[.].gates // [] | .[]] | index($g) != null;
    . as $orig | (.route // "feature") as $route
    | [(.scope // [])[] | tostring] as $scope
    | (reduce $scope[] as $t (.; areas_of(($orig.tickets[$t].paths // []) | map(tostring)) as $a
                              | if $a == [] then del(.tickets[$t].areas) else .tickets[$t].areas = $a end)) as $d
    | (if $route == "feature" then
         [$scope[] as $t | ($d.tickets[$t].slice // null) as $s
          | if $s == null or has_gate($d.tickets[$t].areas // []; "slice") then {kind: "slice", after: $t} else {kind: "slice", slice: $s} end]
         | reduce .[] as $g ([]; if index([$g]) then . else . + [$g] end)
       else [] end) as $slices
    | [$scope[] as $t
       | (($d.tickets[$t].escalation // [])
          + [($d.tickets[$t].areas // [])[] | select(has_gate([.]; "risk")) | "area:" + .]) as $e
       | select($e != [])
       | {kind: "risk", after: $t, tests: $e}] as $risks
    | ({kind: "end"} + (if $route == "feature" then {} else {doubles_as_slice: true} end)
       + (if $route == "bug" then {bug: true} else {} end)) as $end
    | $d | .gates = $slices + $risks + [$end]' --argjson areas "$areas"
  cmd_render "$1"
}

gate_index() { # draft id: the index in .gates, or exit 6
  local i=
  i=$(jq -r "$JQ_DEFS"' ids | index($id) // empty' --arg id "$2" "$1")
  [ -n "$i" ] || die "no gate $2 in the plan (gate-plan.sh render lists them)" 6
  printf '%s\n' "$i"
}

refuse_exception() {
  case "$1" in exception*)
    die "exception gates can't be removed or moved: they are never placed in the plan, and the run opens one whenever it gives up on a ticket" 6 ;;
  esac
}

cmd_remove() {
  [ $# -eq 2 ] || usage
  need_draft "$1"
  refuse_exception "$2"
  local i=
  i=$(gate_index "$1" "$2")
  write "$1" '.gates |= (to_entries | map(select(.key != $i)) | map(.value))' --argjson i "$i"
  cmd_render "$1"
}

cmd_move() {
  [ $# -ge 4 ] || usage
  local f="$1" id="$2" after= tickets= i= kind= t=
  shift 2
  need_draft "$f"
  refuse_exception "$id"
  while [ $# -gt 0 ]; do
    case "$1" in
      --after) [ $# -ge 2 ] || usage; after=$2; shift 2 ;;
      --tickets) [ $# -ge 2 ] || usage; tickets=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$after$tickets" ] && { [ -z "$after" ] || [ -z "$tickets" ]; } || usage
  [ "$id" != end ] || die "the end gate has one place: after every ticket in scope, before the PRs to main; remove it instead" 6
  i=$(gate_index "$f" "$id")
  kind=$(jq -r --argjson i "$i" '.gates[$i].kind' "$f")
  [ "$kind" != risk ] || [ -z "$tickets" ] || die "a risk gate is on one ticket: use --after" 2
  for t in $after $(printf '%s' "$tickets" | tr , ' '); do
    jq -e --arg t "$t" '(.scope // []) | map(tostring) | index($t)' "$f" >/dev/null \
      || die "#$t is not in the plan's scope" 4
  done
  if [ -n "$after" ]; then
    write "$f" '.gates[$i] |= (del(.tickets) | .after = $t)' --argjson i "$i" --arg t "$after"
  else
    write "$f" '.gates[$i] |= (del(.after) | .tickets = ($t | split(",")))' --argjson i "$i" --arg t "$tickets"
  fi
  cmd_render "$f"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  propose) cmd_propose "$@" ;;
  render) cmd_render "$@" ;;
  remove) cmd_remove "$@" ;;
  move) cmd_move "$@" ;;
  *) usage ;;
esac
