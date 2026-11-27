#!/usr/bin/env bash
# The tidy sweep (#427): once a run's PRs have merged on the origin, bring the
# main checkout up to date and remove the run's worktrees and branches.
#
# Usage: tidy.sh <run-dir>
#
# Nothing happens, and one line says so, until every PR the run cut (the
# end gate's prs, or the one PR that merged the whole branch,
# end_gate.merged_outside) is MERGED on the origin.
# Then:
#   1. The main checkout's default branch is fast-forwarded to origin/<default>
#      (git merge --ff-only, never a merge), only when it is the checked-out
#      branch, has no uncommitted change to a tracked file and has no commit
#      the origin lacks. Otherwise it is left alone with one "left alone:" line.
#   2. The run's worktrees are removed and their local branches deleted: the
#      integration branch (run/<id>), the PR branches (pr/<id>/<n>) and the
#      retro branch (retro/<id>). A branch counts as merged when its tip is on
#      origin/<default>, or gh reports a merged PR whose head is that tip (a
#      squash merge). A worktree with uncommitted work, or a branch that is not
#      merged, is kept, and a "kept <path>: <why>" line names it. A merged
#      branch with no worktree is deleted too.
# Running it again changes nothing. It is called by end-gate.sh finish, and
# can be run alone at any time; the retro's PR is judged the same way, so
# running it after that merges removes the retro worktree.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "tidy.sh: $*"; }

[ $# -eq 1 ] || usage
open_run "$1"

repo=$(get -r .repo)
base=${ARTISAN_MAIN_BRANCH:-}
[ -n "$base" ] || base=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo main)

# The run's PRs, all merged on the origin?
urls=$(get -r '(.end_gate.prs // [])[] | .url // empty')
outside=$(get -r '.end_gate.merged_outside // empty')
if [ -z "$urls" ] && [ -z "$outside" ]; then
  echo "tidy: run $RUN_ID has no PR yet; nothing removed, nothing fast-forwarded"
  exit 0
fi
for u in $urls; do
  st=$(gh pr view "$u" --json state -q .state 2>/dev/null || echo UNKNOWN)
  if [ "$st" != MERGED ]; then
    echo "tidy: $u is not merged ($st); nothing removed, nothing fast-forwarded"
    exit 0
  fi
done

ref=$base
if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
  git -C "$MAIN" fetch -q origin "$base" >&2 || die "could not fetch origin $base"
  ref="origin/$base"
fi

# 1. the main checkout
cur=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo "")
if [ "$ref" = "$base" ]; then :
elif [ "$cur" != "$base" ]; then
  echo "tidy: left alone: the main checkout is on ${cur:-a detached HEAD}, not $base"
elif [ -n "$(git -C "$MAIN" status --porcelain --untracked-files=no)" ]; then
  echo "tidy: left alone: main has uncommitted changes to tracked files"
elif git -C "$MAIN" merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
  if [ "$(git -C "$MAIN" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse "$ref")" ]; then
    echo "tidy: $base is already at $ref"
  else
    echo "tidy: left alone: main has local commits $ref lacks ($(git -C "$MAIN" rev-list --count "$ref..HEAD"))"
  fi
elif ! git -C "$MAIN" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
  echo "tidy: left alone: main has local commits $ref lacks ($(git -C "$MAIN" rev-list --count "$ref..HEAD")) and has diverged"
elif git -C "$MAIN" merge --ff-only -q "$ref" >/dev/null 2>&1; then
  echo "tidy: fast-forwarded $base to $(git -C "$MAIN" rev-parse --short HEAD)"
else
  echo "tidy: left alone: main could not fast-forward to $ref"
fi

# 2. the run's worktrees and branches
merged_branch() { # branch: its tip is on the origin's default branch, or a merged PR's head
  local tip= heads=
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$1^{commit}") || return 1
  git -C "$MAIN" merge-base --is-ancestor "$tip" "$ref" 2>/dev/null && return 0
  heads=$(gh pr list -R "$repo" --head "$1" --state all --json state,headRefOid \
    -q '.[] | "\(.state) \(.headRefOid)"' 2>/dev/null || true)
  printf '%s\n' "$heads" | grep -qx "MERGED $tip"
}

# branch<TAB>worktree (worktree empty when none), for the run's branches.
targets=$(git -C "$MAIN" for-each-ref --format='%(refname:short)' "refs/heads/run/$RUN_ID" "refs/heads/pr/$RUN_ID/" "refs/heads/retro/$RUN_ID")
wts=$(git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{sub("refs/heads/","",$2); print $2 "\t" p}')
for b in $targets; do
  wt=$(printf '%s\n' "$wts" | awk -F'\t' -v b="$b" '$1 == b {print $2; exit}')
  if [ -n "$wt" ] && [ "$wt" = "$MAIN" ]; then continue; fi
  where=${wt:-$b}
  if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "tidy: kept $where: uncommitted work"; continue
  fi
  if ! merged_branch "$b"; then
    echo "tidy: kept $where: $b is not on $ref"; continue
  fi
  if [ -n "$wt" ] && ! git -C "$MAIN" worktree remove "$wt" >/dev/null 2>&1; then
    echo "tidy: kept $where: git could not remove the worktree"; continue
  fi
  git -C "$MAIN" branch -D "$b" >/dev/null 2>&1 || echo "tidy: kept $b: could not delete the branch"
  echo "tidy: removed ${wt:+$wt and }branch $b"
done
exit 0
