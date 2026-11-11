#!/usr/bin/env bash
# How a chat changes a doc without touching the main checkout: a short-lived
# branch worktree, merged by fast-forward. Rules: references/main-checkout.md.
#
# Usage:
#   doc-change.sh start <name>    make branch doc/<name> in a worktree beside the
#                                 repo (<repo>-wt/doc-<name>) and print its path
#   doc-change.sh finish <name>   fast-forward the main checkout to the branch
#                                 (rebasing it first if the main checkout moved),
#                                 then remove the worktree and the branch
#
# Run from anywhere in the repo. Commit your change in the worktree before
# finishing. finish refuses when the main checkout has uncommitted changes,
# the branch has no commits, git has no identity for the rebase, or the rebase conflicts (nothing is lost; the
# worktree stays). Exit status: 0 ok, 1 refused or failed, 2 usage.

set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
[ $# -eq 2 ] || { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cmd=$1 name=$2
case "$name" in ''|*[!A-Za-z0-9._-]*) die "name must be letters, digits, . _ - only" ;; esac

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
main=$(dirname "$common")
branch="doc/$name"
wt="$(dirname "$main")/$(basename "$main")-wt/doc-$name"

case "$cmd" in
  start)
    [ ! -e "$wt" ] || die "worktree already exists: $wt"
    git -C "$main" worktree add -q -b "$branch" "$wt" HEAD >&2
    printf '%s\n' "$wt"
    ;;
  finish)
    [ -d "$wt" ] || die "no worktree at $wt (run start first)"
    [ -z "$(git -C "$wt" status --porcelain)" ] || die "uncommitted changes in $wt; commit them first"
    [ -z "$(git -C "$main" status --porcelain --untracked-files=no)" ] \
      || die "the main checkout has uncommitted changes; nothing is merged"
    [ "$(git -C "$main" rev-list --count "HEAD..$branch")" -gt 0 ] || die "$branch has no new commits"
    if ! git -C "$main" merge --ff-only -q "$branch" 2>/dev/null; then
      git -C "$wt" var GIT_COMMITTER_IDENT >/dev/null 2>&1 \
        || die "git has no committer identity, which the rebase needs; set one (git config --global user.name/user.email), then finish again"
      base=$(git -C "$main" rev-parse HEAD)
      git -C "$wt" rebase -q "$base" >/dev/null 2>&1 \
        || { git -C "$wt" rebase --abort >/dev/null 2>&1 || true; die "$branch conflicts with the main checkout; resolve in $wt, then finish again"; }
      git -C "$main" merge --ff-only -q "$branch" || die "fast-forward failed after rebase"
    fi
    git -C "$main" worktree remove "$wt" || die "merged, but could not remove $wt (ignored or untracked files?); remove it and the branch by hand"
    git -C "$main" branch -q -d "$branch"
    printf 'fast-forwarded %s to %s\n' "$main" "$(git -C "$main" rev-parse --short HEAD)"
    ;;
  *) die "unknown command $cmd" ;;
esac
