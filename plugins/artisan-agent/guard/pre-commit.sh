#!/bin/bash
# Git pre-commit hook: refuses a commit in the repo's main checkout. The
# fallback for the plugin hook (guard/protect.sh): it works with the plugin
# disabled, because it is plain git. Installed by guard/install-pre-commit.sh.
# A linked worktree (a worker's, a run's integration worktree, a doc-change
# branch worktree) commits normally. Merges that fast-forward make no commit,
# so fast-forwarding the main checkout is unaffected. Escape hatch for a person
# who really means it: git commit --no-verify.
gitdir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[ "$gitdir" = "$common" ] || exit 0
cat >&2 <<EOT
artisan-agent: commit refused. This is the main checkout, and no session commits in it.
Work in a worktree instead: scripts/doc-change.sh start <name> (from the artisan-agent
plugin) makes a short-lived branch worktree; finish fast-forwards this checkout.
EOT
exit 1
