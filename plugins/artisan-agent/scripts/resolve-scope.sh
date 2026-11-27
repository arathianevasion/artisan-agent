#!/usr/bin/env bash
# Turn what the Artisan named for a run into the tickets it covers: a `plan`
# issue (its tickets), several, a single ticket, or any mix. implement-plan's
# plan step calls this first; the result is the run's scope once approved.
#
# Usage: resolve-scope.sh --repo owner/name <issue>...
#
# A `plan` issue stands for its tickets: its sub-issues, or, when it has none,
# the `- [ ] #<n>` task list in its body. Anything else is one ticket. Prints
# JSON on stdout:
#   tickets   [{number, title, from, blocked_by}] open tickets, each once, in the order named;
#             `from` is the plan issue it came through, or null when named itself;
#             `blocked_by` is the numbers of its open blockers (the tracker's native
#             dependencies; where the tracker has none (HTTP 404), the body's
#             "Blocked by: #n" line or "## Blocked by" section), whether or not they are in the scope. The plan
#             step copies it into the draft: the critical path reads it.
#   skipped   [{number, reason}] closed tickets, left out
#   outside_blockers  [{plan, blocker}] open plans blocking a named plan that are not
#             themselves named: their tickets may block this run's tickets
#   plans     [{number, title}] the plan issues named, in order (#189)
#   spec      {number, title} the first named issue's parent (a plan's parent is
#             its spec; for a ticket in a plan, the plan's parent), or null when
#             it has none or it can't be read. The plan
#             step copies plans and spec into the draft: they name the run's
#             orchestrator sessions (wave.sh launch).
# A `plan` issue with no tickets is a queued request (queue-plan.sh leaves
# them when a run holds the lock), not work to run: exit 3 naming it.
#
# A plan's `outside_blockers` are read the same way: native dependencies, or on a
# 404 the plan body's blockers. A blocker read that fails any other way exits 1
# naming the issue, never an empty list.
#
# A named plan's closed blocker plan whose work isn't on main (plan-done.sh)
# still blocks it: exit 4, naming the plan, the blocker, its tickets and the
# branch they are on (#431).
#
# Exit status: 0 ok, 1 an issue could not be read, 2 bad usage, 3 a plan issue
# with no tickets, 4 a blocker plan's work is not on main. Needs gh and jq. Bash 3.2-safe.

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'resolve-scope.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"
command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/plan-lib.sh"

REPO=
NAMED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    -*) usage ;;
    *) NAMED+=("${1#\#}"); shift ;;
  esac
done
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "--repo must be owner/name, got \"$REPO\""
[ "${#NAMED[@]}" -gt 0 ] || usage
for n in "${NAMED[@]}"; do
  printf '%s' "$n" | grep -Eq '^[0-9]+$' || die "\"$n\" is not an issue number"
done

# The body's blockers, one parser for tickets and plans: the refs on the first
# "Blocked by: #a, #b" line, or, when that line is a "## Blocked by" heading, the
# refs listed below it up to the next heading. Prints those in state want
# (default open) as a JSON array.
body_blockers() { # number what(ticket|plan) [want(open|closed)]
  local n=$1 what=$2 want=${3:-open} body= b= st= out='[]'
  body=$(gh issue view "$n" -R "$REPO" --json body --jq '.body // ""') || die "cannot read the blockers of $what #$n: cannot read its body"
  for b in $(printf '%s\n' "$body" | awk '
    !seen && tolower($0) ~ /^[[:space:]]*(#+[[:space:]]*)?blocked by:?/ { seen = 1; head = ($0 ~ /^[[:space:]]*#+[[:space:]]/); print; next }
    seen && head && /^[[:space:]]*#+[[:space:]]/ { exit }
    seen && head { print; next }
    seen { exit }' | grep -oE '#[0-9]+' | tr -d '#'); do
    st=$(gh issue view "$b" -R "$REPO" --json state --jq '.state | ascii_downcase') \
      || die "cannot read the blockers of $what #$n: cannot read #$b"
    [ "$st" != "$want" ] || out=$(jq -c --argjson b "$b" '. + [$b]' <<<"$out")
  done
  printf '%s\n' "$out"
}

tickets='[]' skipped='[]' outside='[]' plans='[]' undone='[]'
add_ticket() { # number title state from
  if [ "$3" != open ]; then
    skipped=$(jq -c --argjson n "$1" '. + [{number: $n, reason: "closed"}]' <<<"$skipped")
  elif ! jq -e --argjson n "$1" 'map(.number) | index($n)' <<<"$tickets" >/dev/null; then
    tickets=$(jq -c --argjson n "$1" --arg t "$2" --arg f "$4" \
      '. + [{number: $n, title: $t, from: (if $f == "" then null else ($f | tonumber) end)}]' <<<"$tickets")
  fi
}

for n in "${NAMED[@]}"; do
  issue=$(gh issue view "$n" -R "$REPO" --json number,title,body,state,labels) || die "cannot read #$n"
  if ! jq -e '.labels | map(.name) | index("plan")' <<<"$issue" >/dev/null; then
    add_ticket "$n" "$(jq -r .title <<<"$issue")" "$(jq -r '.state | ascii_downcase' <<<"$issue")" ""
    continue
  fi
  plan_ref=$(jq -c '{number, title}' <<<"$issue")
  plans=$(jq -c --argjson i "$plan_ref" '. + [$i]' <<<"$plans")
  members=$(plan_members "$REPO" "$n")
  if [ "$(jq length <<<"$members")" -eq 0 ]; then
    printf 'resolve-scope.sh: plan issue #%s has no tickets: it is a queued request, not a plan to run. Read it, then plan its work (/artisan-agent:to-plan) or name tickets instead.\n' "$n" >&2
    exit 3
  fi
  while IFS=$'\t' read -r num title state; do
    add_ticket "$num" "$title" "$state" "$n"
  done < <(jq -r '.[] | [.number, .title, .state] | @tsv' <<<"$members")
  if blockers=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>&1); then
    open_blockers=$(jq -r '.[] | select((.state | ascii_downcase) == "open") | .number' <<<"$blockers") \
      || die "cannot read the blockers of plan #$n: unreadable answer"
    closed_blockers=$(jq -r '.[] | select((.state | ascii_downcase) != "open") | .number' <<<"$blockers")
  else
    printf '%s' "$blockers" | grep -Eq 'HTTP 404|Not Found' \
      || die "cannot read the blockers of plan #$n: $blockers"
    open_blockers=$(body_blockers "$n" plan | jq -r '.[]') || exit 1
    closed_blockers=$(body_blockers "$n" plan closed | jq -r '.[]') || exit 1
  fi
  # A closed blocker plan whose work isn't on main still blocks (#431).
  for b in $closed_blockers; do
    labels=$(gh issue view "$b" -R "$REPO" --json labels) || die "cannot read #$b (a blocker of plan #$n)"
    jq -e '.labels | map(.name) | index("plan")' <<<"$labels" >/dev/null || continue
    rc=0; check=$("$SCRIPT_DIR/plan-done.sh" --repo "$REPO" "$b") || rc=$?
    case $rc in
      0) ;;
      3) undone=$(jq -c --argjson p "$n" --argjson c "$check" '. + [{plan: $p, blocker: $c}]' <<<"$undone") ;;
      *) die "cannot tell whether blocker plan #$b of plan #$n is on main" ;;
    esac
  done
  for b in $open_blockers; do
    named=0
    for m in "${NAMED[@]}"; do [ "$m" != "$b" ] || named=1; done
    [ "$named" -eq 1 ] || outside=$(jq -c --argjson p "$n" --argjson b "$b" '. + [{plan: $p, blocker: $b}]' <<<"$outside")
  done
done

# The plan step refuses a plan whose blocker plan is closed with work missing
# from main: its dependents would build on a main without it (#431).
if [ "$undone" != '[]' ]; then
  jq -r '.[] | "resolve-scope.sh: plan #\(.plan) is blocked by plan #\(.blocker.plan), whose work is not on \(.blocker.main)"
    + ([.blocker.open[] | "#\(.)"] | if length > 0 then "; open: \(join(", "))" else "" end)
    + (.blocker.not_on_main | group_by(.branch) | map("\(map("#\(.ticket)") | join(", ")) on \(.[0].branch)")
       | if length > 0 then "; not on main: \(join("; "))" else "" end)
    + ". Merge that run branch into main first."' <<<"$undone" >&2
  exit 4
fi

# Each ticket's open blockers.
ticket_blockers() { # number: prints a JSON array of open blocker numbers
  local n=$1 deps= err=
  if deps=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>&1); then
    jq -c '[.[] | select((.state | ascii_downcase) == "open") | .number]' <<<"$deps" \
      || die "cannot read the blockers of #$n: unreadable answer"
    return 0
  fi
  err=$deps
  printf '%s' "$err" | grep -Eq 'HTTP 404|Not Found' \
    || die "cannot read the blockers of #$n: $err"
  # No native dependencies here: the "Blocked by" line or section in the body.
  body_blockers "$n" ticket
}
for n in $(jq -r '.[].number' <<<"$tickets"); do
  bl=$(ticket_blockers "$n") || exit 1
  tickets=$(jq -c --argjson n "$n" --argjson b "$bl" 'map(if .number == $n then . + {blocked_by: $b} else . end)' <<<"$tickets")
done

# The spec: the first named issue's parent, or, when that is a plan (a ticket
# named alone), the plan's parent. Only a display name rides on it, so a
# failed read is no spec.
spec=null
parent=$(gh api "repos/$REPO/issues/${NAMED[0]}/parent" 2>/dev/null) || parent=
if [ -n "$parent" ] && jq -e '(.labels // []) | map(.name) | index("plan")' <<<"$parent" >/dev/null 2>&1; then
  parent=$(gh api "repos/$REPO/issues/$(jq -r .number <<<"$parent")/parent" 2>/dev/null) || parent=
fi
[ -z "$parent" ] || spec=$(jq -c '{number, title}' <<<"$parent" 2>/dev/null) || spec=null

jq -n --argjson t "$tickets" --argjson s "$skipped" --argjson o "$outside" --argjson p "$plans" --argjson sp "$spec" \
  '{tickets: $t, skipped: $s, outside_blockers: $o, plans: $p, spec: $sp}'
