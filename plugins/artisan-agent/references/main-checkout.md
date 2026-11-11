# The main checkout and the run lock

Two rules keep `main` free of uncommitted surprises and runs from colliding. This page is their one definition; the hook and the fallbacks below enforce them.

1. **No session edits the main checkout directly.** The main checkout is the repo's own working directory (its `.git` is the real git directory, not a linked worktree's). Workers use their own worktrees, each run merges in its own integration worktree, and a chat that changes docs works in a short-lived branch worktree and merges it. The main checkout is only fast-forwarded.
2. **One run per repo.** A run holds the run lock while its `state.lock` (`${CLAUDE_PLUGIN_ROOT}/references/state-file.md`) names a live pid. A request to start a run while one holds the lock is refused and left as a `plan` issue, which waits for the run to end.

## Enforcement

| Layer | What it does | Works with the plugin hook disabled? |
|---|---|---|
| Plugin hook (`guard/protect.sh`, wired in `hooks/hooks.json`) | refuses `Edit`, `Write`, `MultiEdit` and `NotebookEdit` on a file in a repo's main checkout, saying where to work; refuses `implement-plan` (typed, or called by Claude) while a run holds the lock and leaves the request as a `plan` issue | n/a |
| Git pre-commit hook (`guard/pre-commit.sh`, installed by `guard/install-pre-commit.sh`; setup runs it) | refuses a commit in the main checkout | yes: plain git |
| `implement-plan`'s own check (`scripts/run-lock.sh check`, its preconditions) | refuses to start while another run holds the lock, and leaves the request as a `plan` issue | yes: part of the skill |

The edit rule applies to repos that have adopted the pipeline (a committed `.artisan-agent/config.yml`) and skips git-ignored paths such as `.artisan-agent/runs/`. A person can still use `git commit --no-verify`; the rule is a guardrail for agents, not a lock on the owner.

## A chat changes a doc

From any chat, without touching the main checkout:

```bash
wt=$(${CLAUDE_PLUGIN_ROOT}/scripts/doc-change.sh start glossary-fix)   # branch doc/glossary-fix in <repo>-wt/doc-glossary-fix
# edit and commit in "$wt" (cd there, or use absolute paths inside it)
${CLAUDE_PLUGIN_ROOT}/scripts/doc-change.sh finish glossary-fix        # fast-forwards the main checkout, removes worktree and branch
```

`finish` rebases the branch onto the main checkout's current commit if it moved, then fast-forwards. It refuses, leaving the worktree for you, when the main checkout has uncommitted changes, the branch has no commits, or the rebase conflicts. Push from the main checkout afterwards if the change should reach the remote. If a run is in progress the main checkout still only gets fast-forwards; a doc change never collides with a run's integration worktree.
