# Dispatch mechanics

What both tiers share: where everything lives, how a worker is launched, what it hands back, and how its work is merged and closed. The scripts are `${CLAUDE_PLUGIN_ROOT}/scripts/wave.sh` (this run's steps), `run-ticket.sh`, `wait-any.sh`, `classify-worker.sh`, `sweep.sh` and `reconcile.sh`; `${CLAUDE_PLUGIN_ROOT}/scripts/README.md` has their usage and `${CLAUDE_PLUGIN_ROOT}/references/state-file.md` the state file.

## Why worktrees

A tracer-bullet ticket is a vertical slice through schema, API, UI and tests, and `/artisan-agent:implement` commits to the current branch. Two workers in one checkout race on the same files and the same git index. Subagents in one session share the working directory too: isolation of context is not isolation of filesystem.

A worktree gives each worker its own checkout and branch off the same repository, with shared object storage, so setup is cheap; a separate process per worktree gives each ticket a fresh context window. Field reports from several sessions in one checkout describe a `git commit --amend` landing on another session's commit, a stash vanishing from `refs/stash`, and commits landing on the wrong branch, all in one afternoon.

**Worktrees don't fix all of it.** `refs/stash` is shared across worktrees, so two workers stashing at once can still lose each other's work. Every worker is told not to stash: it has its own branch, so committing is always right.

## Layout

| Where | What | Made by |
|---|---|---|
| `<repo>/` | the main checkout: never edited, only fast-forwarded | |
| `<repo>/.artisan-agent/runs/<run-id>/` | the run folder (git-ignored): `state.json`, `results/`, `workers/`, `prompts/`, `merges/` | `state.sh init` |
| `<repo>-wt/run-<run-id>/` | the run's integration worktree, on the integration branch `run/<run-id>`; every merge happens here | `wave.sh start` |
| `<repo>-wt/<run-id>-<ticket>.<attempt>/` | a worker's worktree, on `agent/<ticket>`, branched from the integration tip | `wave.sh dispatch` |

Worktrees sit beside the repo, never in it, so they never appear in a glob, a test run or a build in the main checkout.

## Dispatch only on merged work

`wave.sh dispatch` is a hard refusal, not a check to remember. Before it creates anything it reads the ticket's blockers from the tracker and refuses with exit 5 unless each one is merged into the integration branch (a blocker in the run: `merged` in the state file, and its merge commit an ancestor of the integration tip) or closed (a blocker outside the run). It also refuses a ticket outside the approved scope (4) or with no free slot under Max Agents (9).

The failure it prevents is silent. In one run a ticket was dispatched the moment its blocker's result said `complete`, before the merge landed. The worker noticed its base lacked the blocker, merged the blocker's branch itself (a fast-forward, since both branched from the same base) and built on top. The work was right; what broke was the measurement: diffing that branch against a base still missing the blocker showed 23 shared files, which read exactly like a re-derivation and triggered an unneeded reconciliation dispatch.

So:

- Every worker branches from the integration tip at dispatch, and that tip contains every blocker.
- **Measure collisions against a base that contains all merged work.** A three-dot diff against a stale tip attributes the blocker's files to the dependent. If one ticket looks wholly contained in another, check `git merge-base --is-ancestor` before believing it.
- A blocker and its dependent are never in flight together. "Dispatch B if A succeeds" means merge A first and put B in the next wave.

## The worker's prompt

`wave.sh dispatch` writes it to `prompts/<ticket>.<attempt>.md`, and `run-ticket.sh` adds its own notes (the result and findings file paths, no background commands, the completion line):

```
/artisan-agent:implement #<ticket> on <owner/repo>: <title>

You are the worker for ticket <ticket>, attempt <n>, in run <run-id>.
- Base: <sha> (the integration branch run/<run-id>). Your branch: agent/<ticket>, already checked out here.
- Expected output: <from the plan>
- Write the evidence record to the result file named below, as in references/evidence-record.md.
- Do not close the ticket, edit the tracker, merge or push. Do not use git stash; commit instead.
- Brief: <the plan's brief, if any>
- This is a retry. The last attempt failed: <reason>      (attempt 2 only)
```

A ticket kept as a local file (`plan.tickets.<t>.ticket_path`) is named by its path instead of `#<ticket> on <repo>`.

The worker session runs in its worktree with `--model` from the plan, `--max-budget-usd` (twice the estimate), `--max-turns`, its deadline, `--permission-mode acceptEdits`, the tools it needs, and `--add-dir` for the run's `results/`. `ARTISAN_CLAUDE_ARGS` adds arguments to every session (for a trial: `--plugin-dir`, the flags from `tests/helpers/live-hooks.sh` (a bare `--setting-sources project,local` stops the plugin's hooks running), `--no-session-persistence`), and `ARTISAN_MAX_BUDGET_USD` caps any one session's budget.

`/artisan-agent:implement` already tells the worker to commit early and often (a worker killed by a rate limit with ten uncommitted files cost a second full dispatch), to run `mattpocock-skills:code-review` over its own diff and record every remark, and to write its record even when it fails, since a missing file looks exactly like a crash.

## What a worker hands back

Two files, judged together:

- **The evidence record**, `results/<ticket>.<n>.result.json`: each acceptance criterion with its evidence, what the worker was unsure of, its decisions made alone, its review remarks and its findings. The one definition is `${CLAUDE_PLUGIN_ROOT}/references/evidence-record.md`. The worker doesn't write its cost; the sweep takes `total_cost_usd` from the session's JSON output.
- **The exit record**, `results/<ticket>.<n>.exit.json`, written by the runner when the session ends, however it ends.

An attempt is complete only when `classify-worker.sh` says `completed`: the session's result text ends with `ARTISAN-WORKER: complete` and the evidence record exists. A session blocked by a hook exits 0, so the exit code alone means nothing. `wave.sh merge` refuses anything else (exit 8 while the worker is still running).

Two launcher failures look like a worker that died instantly, which is why the runner detaches and waiting is on files: a bare `wait` also waits on a watchdog subshell, so a dispatcher stays alive for the full timeout; and backgrounding inside `$(...)` kills the child when the subshell exits, leaving a log with only the startup banner. Gate completion on result files and exit records appearing, never on a launcher exiting.

## Merging

`wave.sh merge <run folder> <ticket>`, one ticket at a time, so a break is attributable:

1. Refuses unless the ticket is `returned`, the attempt `completed`, the evidence record's `commit` is the branch tip, and a fresh verifier passed that attempt at that commit (`verify.sh`; exit 13 otherwise). A ticket that misses a criterion is never merged: `verify.sh judge` counts it a failed attempt, retried by a fresh worker given the verifier's findings, or blocked after the last. The flow is in `${CLAUDE_PLUGIN_ROOT}/references/evidence-contract.md`.
2. `git merge --no-ff` in the integration worktree. Always `--no-ff`: the reconciler finds merged tickets by merge commits on the integration branch's first-parent line, so a fast-forward looks as if nothing merged.
3. Runs the plan's `suite_command` there; its output goes to `merges/<ticket>.<n>.suite.log`.
4. Green: records the merge (an event in the state file) and removes the worker's worktree. The branch stays, so the reconciler can still find the merge.
5. A conflict (11) gets one `/artisan-agent:resolve-conflicts` try before anything else (`parallel-waves.md`). A conflict it can't resolve (6) or a red local suite (7): the merge is undone, the ticket is blocked with an exception decision for the Artisan, and the branch and worktree stay. A red CI merge gate (7) is a failed attempt instead (#176): requeued with the failing tests in its notes, or blocked once its attempts are used up. Never hand-edit source to make a merge go through: that turns a reviewable ticket into an unreviewed one.

When several tickets returned in one wave, measure before choosing the order: list each branch's files against the integration tip (`git diff --name-only <tip>...<branch>`), and merge the branch with the widest blast radius first.

## Closing and findings

Closing is the orchestrator's alone, and only on merged work. `wave.sh close` posts the evidence contract on the ticket (`evidence.sh comment`: each criterion with the verifier's evidence, the suite, diff stats, cost against the estimate, what the worker was unsure of, its decisions made alone, and the contract as JSON, exactly as in the state file), ticks the criteria the verifier found met, and closes it. An open criterion on a closed ticket makes the audit trail lie, so an unmet one stays unticked and shows "no" in the comment.

Findings are filed for triage by the Engineering chat between waves (`SKILL.md`, step 7), never by a worker or the orchestrator, and never straight into a wave.

## Cleanup

Merged tickets' worktrees go as they merge. At the end of the run, blocked tickets' worktrees and branches stay for the Artisan; run `git worktree prune` to clear registrations left by crashed processes.
