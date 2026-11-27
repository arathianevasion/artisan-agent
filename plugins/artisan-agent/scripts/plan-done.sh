#!/usr/bin/env bash
# Is this plan's work on main? The one check for whatever closes a plan issue
# or reports one done, and for the plan step deciding whether a blocker plan
# still blocks (resolve-scope.sh). A plan is done only when every ticket is
# closed and each ticket a run merged has its work on main (#431).
#
# Usage: plan-done.sh --repo owner/name [--runs DIR] <plan>
#
# A ticket's work is on main when, in a run of this repo that merged it (a
# state.json under DIR whose .repo is the repo and whose .tickets[t] has a
# merge_commit), the run's integration branch or the ticket's merge commit is
# an ancestor of origin's main branch, fetched now. With no origin, the local
# main branch. Main is $ARTISAN_MAIN_BRANCH, else origin's HEAD, else "main".
# A squash- or rebase-merged run is not recognised (#409).
# DIR defaults to <main checkout>/.artisan-agent/runs.
#
# Prints JSON on stdout:
#   plan         the plan's number
#   done         true or false
#   main         the ref read, e.g. origin/main
#   open         [n] tickets still open
#   not_on_main  [{ticket, branch, run}] closed tickets a run merged whose work
#                isn't on main, with the run's integration branch holding it
#   unrecorded   [n] closed tickets no run of this repo merged (closed by hand,
#                a human check): they don't hold the plan back
#
# Exit status: 0 done, 3 not done, 1 an issue, the repo or origin could not be
# read (or the issue is not a plan), 2 bad usage. Needs git, gh and jq.
# Bash 3.2-safe.

set -euo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'plan-done.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"
command -v gh >/dev/null 2>&1 || die "gh is required but was not found on PATH"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/plan-lib.sh"

REPO= RUNS= PLAN=
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --runs) [ $# -ge 2 ] || usage; RUNS=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$PLAN" ] || usage; PLAN=${1#\#}; shift ;;
  esac
done
[ -n "$PLAN" ] || usage
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "--repo must be owner/name, got \"$REPO\""
printf '%s' "$PLAN" | grep -Eq '^[0-9]+$' || die "\"$PLAN\" is not an issue number"

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
MAIN=$(dirname "$common")
[ -n "$RUNS" ] || RUNS="$MAIN/.artisan-agent/runs"

# The ref main is read from: origin's, fetched now, else the local branch.
main_name=${ARTISAN_MAIN_BRANCH:-}
if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
  if [ -z "$main_name" ]; then
    main_name=$(git -C "$MAIN" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || main_name=
    main_name=${main_name#origin/}
    [ -n "$main_name" ] || main_name=main
  fi
  git -C "$MAIN" fetch -q origin "+refs/heads/$main_name:refs/remotes/origin/$main_name" 2>/dev/null \
    || die "cannot fetch $main_name from origin: whether the plan's work is on main is unknown"
  main_ref="origin/$main_name"
else
  [ -n "$main_name" ] || main_name=main
  main_ref=$main_name
fi
git -C "$MAIN" rev-parse -q --verify "$main_ref^{commit}" >/dev/null || die "no $main_ref in $MAIN"

issue=$(gh issue view "$PLAN" -R "$REPO" --json labels) || die "cannot read #$PLAN"
jq -e '.labels | map(.name) | index("plan")' <<<"$issue" >/dev/null || die "#$PLAN is not a plan issue"
members=$(plan_members "$REPO" "$PLAN")

# Every run of this repo's merges: {ticket, run, branch, commit}, oldest run first.
records='[]'
for f in "$RUNS"/*/state.json; do
  [ -f "$f" ] || continue
  r=$(jq -c --arg repo "$REPO" --arg dir "$(basename "$(dirname "$f")")" '
      select(.repo == $repo) | (.run_id // $dir) as $run | (.integration.branch // "") as $b
      | [(.tickets // {}) | to_entries[] | select(.value.merge_commit // "" | . != "")
         | {ticket: (.key | tonumber), run: $run, branch: $b, commit: .value.merge_commit}]' "$f") \
    || die "cannot read run state $f"
  [ -z "$r" ] || records=$(jq -c --argjson r "$r" '. + $r' <<<"$records")
done

on_main() { # commit-or-ref: is it an ancestor of main?
  [ -n "$1" ] && git -C "$MAIN" merge-base --is-ancestor "$1" "$main_ref" 2>/dev/null
}

open='[]' not_on_main='[]' unrecorded='[]'
for t in $(jq -r '.[] | select(.state == "open") | .number' <<<"$members"); do
  open=$(jq -c --argjson t "$t" '. + [$t]' <<<"$open")
done
for t in $(jq -r '.[] | select(.state != "open") | .number' <<<"$members"); do
  mine=$(jq -c --argjson t "$t" 'map(select(.ticket == $t))' <<<"$records")
  if [ "$(jq length <<<"$mine")" -eq 0 ]; then
    unrecorded=$(jq -c --argjson t "$t" '. + [$t]' <<<"$unrecorded")
    continue
  fi
  found=0
  while IFS=$'\t' read -r commit branch; do
    if on_main "$commit" || on_main "$branch"; then found=1; break; fi
  done < <(jq -r '.[] | [.commit, .branch] | @tsv' <<<"$mine")
  [ "$found" -eq 1 ] || not_on_main=$(jq -c --argjson m "$mine" '. + [$m | last | {ticket, branch, run}]' <<<"$not_on_main")
done

jq -n --argjson p "$PLAN" --arg main "$main_ref" --argjson o "$open" --argjson n "$not_on_main" --argjson u "$unrecorded" \
  '{plan: $p, done: ($o == [] and $n == []), main: $main, open: $o, not_on_main: $n, unrecorded: $u}'
[ "$open" = '[]' ] && [ "$not_on_main" = '[]' ] || exit 3
