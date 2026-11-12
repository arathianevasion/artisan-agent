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
#             "Blocked by: #n" line), whether or not they are in the scope. The plan
#             step copies it into the draft: the critical path reads it.
#   skipped   [{number, reason}] closed tickets, left out
#   outside_blockers  [{plan, blocker}] open plans blocking a named plan that are not
#             themselves named: their tickets may block this run's tickets
# A `plan` issue with no tickets is a queued request (queue-plan.sh leaves
# them when a run holds the lock), not work to run: exit 3 naming it.
#
# A blocker read that fails any other way exits 1 naming the ticket, never an
# empty list.
#
# Exit status: 0 ok, 1 an issue could not be read, 2 bad usage, 3 a plan issue
# with no tickets. Needs gh and jq. Bash 3.2-safe.

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'resolve-scope.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"
command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"

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

tickets='[]' skipped='[]' outside='[]'
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
  subs=$(gh api "repos/$REPO/issues/$n/sub_issues") || die "cannot read the sub-issues of plan #$n"
  members=$(jq -c '[.[] | {number, title, state: (.state | ascii_downcase)}]' <<<"$subs")
  if [ "$(jq length <<<"$members")" -eq 0 ]; then
    # No sub-issues: the task list in the body, each ticket read in turn.
    members='[]'
    for t in $(jq -r '.body // ""' <<<"$issue" | sed -n 's/^[[:space:]]*[-*][[:space:]]*\[[ xX]\][[:space:]]*#\([0-9][0-9]*\).*/\1/p'); do
      m=$(gh issue view "$t" -R "$REPO" --json number,title,state) || die "cannot read #$t (listed in plan #$n)"
      members=$(jq -c --argjson m "$m" '. + [$m | {number, title, state: (.state | ascii_downcase)}]' <<<"$members")
    done
  fi
  if [ "$(jq length <<<"$members")" -eq 0 ]; then
    printf 'resolve-scope.sh: plan issue #%s has no tickets: it is a queued request, not a plan to run. Read it, then plan its work (/artisan-agent:to-plan) or name tickets instead.\n' "$n" >&2
    exit 3
  fi
  while IFS=$'\t' read -r num title state; do
    add_ticket "$num" "$title" "$state" "$n"
  done < <(jq -r '.[] | [.number, .title, .state] | @tsv' <<<"$members")
  blockers=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by") || die "cannot read the blockers of plan #$n"
  for b in $(jq -r '.[] | select(.state == "open") | .number' <<<"$blockers"); do
    named=0
    for m in "${NAMED[@]}"; do [ "$m" != "$b" ] || named=1; done
    [ "$named" -eq 1 ] || outside=$(jq -c --argjson p "$n" --argjson b "$b" '. + [{plan: $p, blocker: $b}]' <<<"$outside")
  done
done

# Each ticket's open blockers.
ticket_blockers() { # number: prints a JSON array of open blocker numbers
  local n=$1 deps err body b st out='[]'
  if deps=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>&1); then
    jq -c '[.[] | select((.state | ascii_downcase) == "open") | .number]' <<<"$deps" \
      || die "cannot read the blockers of #$n: unreadable answer"
    return 0
  fi
  err=$deps
  printf '%s' "$err" | grep -Eq 'HTTP 404|Not Found' \
    || die "cannot read the blockers of #$n: $err"
  # No native dependencies here: the "Blocked by" line at the top of the body.
  body=$(gh issue view "$n" -R "$REPO" --json body --jq '.body // ""') || die "cannot read the blockers of #$n: cannot read its body"
  for b in $(printf '%s\n' "$body" | grep -iE '^[[:space:]]*blocked by:?' | head -1 | grep -oE '#[0-9]+' | tr -d '#'); do
    st=$(gh issue view "$b" -R "$REPO" --json state --jq '.state | ascii_downcase') \
      || die "cannot read the blockers of #$n: cannot read #$b"
    [ "$st" != open ] || out=$(jq -c --argjson b "$b" '. + [$b]' <<<"$out")
  done
  printf '%s\n' "$out"
}
for n in $(jq -r '.[].number' <<<"$tickets"); do
  bl=$(ticket_blockers "$n") || exit 1
  tickets=$(jq -c --argjson n "$n" --argjson b "$bl" 'map(if .number == $n then . + {blocked_by: $b} else . end)' <<<"$tickets")
done

jq -n --argjson t "$tickets" --argjson s "$skipped" --argjson o "$outside" \
  '{tickets: $t, skipped: $s, outside_blockers: $o}'
