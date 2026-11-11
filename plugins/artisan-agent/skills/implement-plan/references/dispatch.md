# Dispatch mechanics

Read this before the first wave. It covers worktree setup, the agent invocation, the result contract, and cleanup.

## Why worktrees

A tracer-bullet ticket is a vertical slice through schema, API, UI and tests, and `/artisan-agent:implement` ends by committing to the current branch. Two agents in one checkout therefore race on the same files and the same git index. Subagents in a single session share the working directory, so they hit this too — isolation of context is not isolation of filesystem.

A worktree gives each agent its own checkout and its own branch off the same repository, with shared object storage so setup is cheap. A separate process per worktree also means a genuinely fresh context window per ticket, which is what `to-tickets` sized the tickets for in the first place.

Field reports from running several sessions in one checkout describe a `git commit --amend` landing on another session's commit, a stash disappearing from `refs/stash`, and commits landing on the wrong branch — all inside one afternoon across three issues.

**Worktrees do not fix all of it.** `refs/stash` is shared across worktrees, so two agents stashing concurrently can still lose each other's work. Tell every agent explicitly not to stash: it has its own branch and nothing to protect, so committing is always the correct move.

## Layout

```
<repo>/                      # orchestrator stays here, never dirty
../<repo>-wt/<ticket-id>/    # one worktree per in-flight ticket
.scratch/<feature>/results/  # result files, in the main repo, git-ignored
```

Keep worktrees outside the repo directory so they never appear in a glob, a test run, or a build in the main checkout.

## Per-ticket setup

```bash
TICKET=01-add-billing-tab
git worktree add -b "agent/${TICKET}" "../${REPO}-wt/${TICKET}" "${BASE}"
```

`BASE` is the merged tip after the previous wave, not `main` from the start of the run. Branching a later wave off a stale base reintroduces exactly the conflicts the wave ordering was supposed to avoid.

`BASE` is also what makes the merged-not-reported rule in `SKILL.md` mechanical: since every agent branches from `BASE`, a ticket whose blocker has not been merged into `BASE` gets a checkout without it. Verify before dispatching, not after:

```bash
for blocker in ${BLOCKERS}; do
  git merge-base --is-ancestor "${blocker}" "${BASE}" \
    || { echo "REFUSING ${TICKET}: blocker ${blocker} not in BASE"; exit 1; }
done
```

Make this a hard refusal in the launcher rather than a check you remember to run. The failure it prevents is silent — the agent produces a plausible, green, well-tested re-implementation of its own blocker.

### Choosing merge order

Measure it; do not reason about it. Before merging a wave, compute the actual file overlap between branches:

```bash
for b in ${BRANCHES}; do git diff --name-only "${BASE}...${b}" | sed "s|^|${b} |"; done \
  | awk '{print $2" "$1}' | sort \
  | awk '{f[$1]=f[$1]" "$2} END{for(k in f){n=split(f[k],a," "); if(n>1) print n" "k f[k]}}' \
  | sort -rn
```

Merge the branch with the widest blast radius first, and the ones that only touch its edges after. This predicts conflicts accurately enough to be worth the thirty seconds, and it turns "which order?" from a judgment call into a measurement.

If the project needs installed dependencies, run the install in each worktree before dispatch. Node projects usually need a fresh `node_modules`; a symlink to the main checkout's copy will break on any ticket that changes a dependency.

## Invocation

```bash
cd "../${REPO}-wt/${TICKET}"
claude -p "$(cat <<EOF
Run /artisan-agent:implement against ${TICKET_PATH}.

${BRIEF}

When /artisan-agent:implement has committed, write your result to
${RESULTS_DIR}/${TICKET}.json using the contract in the ticket comment.
Write the file even if you fail — a missing file is indistinguishable
from a crash and forces a manual check.

Do not close the ticket. Do not merge or push your branch.
Do not use git stash — refs/stash is shared across worktrees and
another agent's stash can vanish. Commit instead; you have your own branch.

Commit early and often. As soon as any coherent slice compiles — even a
partial one — commit it with an honest message saying what is and is not
done. You cannot predict a crash, a timeout, or an account rate limit. A
wip commit you later build on costs nothing; an uncommitted tree at the
moment you are killed costs everything.

Run /code-review over your own diff before writing your result, and record
what it says in review.remarks — including anything it finds that you
disagree with or chose not to act on.
EOF
)" \
  --model "${MODEL}" \
  --permission-mode acceptEdits \
  > "${RESULTS_DIR}/${TICKET}.log" 2>&1 &
```

Launch every ticket in the wave, then wait on all of them. Keep the log alongside the result file — when a run fails, the log is the only evidence, and it stays out of the orchestrator's context unless something actually goes wrong.

The commit-early instruction earns its place the first time a wave dies mid-flight. An agent killed by an account rate limit left ten modified files uncommitted and therefore unverifiable — the orchestrator cannot merge work it cannot vouch for, so recovering it cost a second full dispatch. Agents left to their own judgment hold a clean tree until the end.

The `/code-review` instruction is the highest-value line in the whole prompt. Agents that review their own diff catch their own unmet acceptance criteria, and — more usefully — sometimes report that a test they wrote passes for the wrong reason. Neither is visible in a green suite.

A per-process wall-clock timeout is worth setting. An agent that hangs on a prompt it cannot answer will otherwise hold up the whole wave indefinitely.

### Two ways the launcher silently eats agents

Both of these look like an agent that died instantly, and both cost real time to diagnose:

- **A bare `wait` also waits on the watchdog.** If the timeout is implemented as `( sleep "$TIMEOUT"; kill "$pid" ) &`, a bare `wait` blocks on that subshell too — so the dispatch script stays alive for the full timeout after every agent has finished. Collect agent PIDs and wait on those only, then reap the watchdogs.
- **Backgrounding inside `$(...)` kills the child.** Launching an agent from inside command substitution puts it in a subshell that exits immediately and takes its children with it. The symptom is a log containing only the startup banner. Launch from a script that backgrounds directly.

Because of both, **gate wave completion on result files appearing, never on the dispatch script exiting.**

## Result contract

Give the agent this shape explicitly. Parsing prose out of a transcript is unreliable in a way that shows up only under load.

```json
{
  "ticket": "01-add-billing-tab",
  "status": "complete",
  "branch": "agent/01-add-billing-tab",
  "commit": "a1b2c3d",
  "tests": { "suite_passed": true, "typecheck_passed": true },
  "review": {
    "ran": true,
    "remarks": [
      { "axis": "standards", "severity": "minor", "note": "..." }
    ]
  },
  "findings": [
    {
      "title": "Billing tab needs a paginated invoice endpoint",
      "why": "Ticket assumed one existed; it does not",
      "blocks": ["04-invoice-history"]
    }
  ],
  "notes": "One paragraph maximum."
}
```

`status` is one of `complete`, `blocked`, `failed`.

- `complete` — committed, suite green, review ran.
- `blocked` — the ticket cannot be finished as written. Something in `findings` should explain why.
- `failed` — the agent errored. `notes` says where.

`findings` is the mechanism for outstanding requirements. An agent that finds missing work records it here and keeps its own slice narrow, rather than expanding scope to cover it. Scope creep inside a ticket is what breaks the single-context-window guarantee.

## Reconciliation and cleanup

Merge serially in wave order, running the full suite after each merge so a failure is attributable:

```bash
git -C "${REPO}" merge --no-ff "agent/${TICKET}"
```

On success, remove the worktree and delete the branch:

```bash
git worktree remove "../${REPO}-wt/${TICKET}"
git branch -d "agent/${TICKET}"
```

On conflict, run `/artisan-agent:resolve-conflicts` rather than hand-editing. Running waves in parallel makes conflicts an expected cost of the approach, not an anomaly, so they get the same discipline as any other work. If it cannot be resolved, or the suite fails on the merged result, abort the merge and keep both the worktree and the branch. Report the ticket as blocked with the conflicting paths. Silently patching source in the orchestrator turns a reviewable ticket into an unreviewed one.

Run `git worktree prune` at the end of the run to clear any stale registrations from crashed processes.

## Tracker operations

Closing and filing are orchestrator-only.

- **Close:** close the work item and tick its acceptance criteria. Both matter — an open criterion on a closed ticket makes the audit trail lie.
- **File discovered work:** create the new ticket with a body that names the discovering ticket, and file it with no blocking edges — off the frontier. On a local tracker that is a new numbered file in the same issues directory; on a real tracker, a new issue carrying the triage label vocabulary from `docs/agents/`.
- **Triage it:** run `/artisan-agent:triage` before the ticket is eligible for a wave. Agent-discovered work has not been grilled or sized, so it does not get the agent-ready status that `to-tickets` output has. Edges and wave placement come after triage admits it, not before.

After any filing that adds an edge, recompute the graph before dispatching the next wave.
