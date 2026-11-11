# Parallel waves

Real parallelism with bounded failure: how wide a wave is, how its tickets merge, what happens to a conflict, how often a ticket is tried, and when the run stops. The orchestrator follows this page within its brief (`orchestrator.md`); the plan step supplies each ticket's expected files. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/wave-width.sh` and `wave.sh`; their usage is in `${CLAUDE_PLUGIN_ROOT}/scripts/README.md`.

## Wave width

A wave is as wide as the **smallest** of:

| Limit | From |
|---|---|
| Max Agents, less the tickets already in flight | `plan.max_agents` |
| The ready tickets | the frontier the reconciler computed: queued, open, every blocker merged into the integration branch |
| The tickets whose expected file sets don't overlap | `plan.tickets.<t>.expected_files` |

`wave-width.sh pick <run folder>` applies all three to the frontier, in ticket order, and prints the tickets to dispatch now; each one it holds back gets a line on stderr (`held #14: overlaps #12: both expect src/export/`). Dispatch exactly what it prints.

**Expected files.** The plan step writes, per ticket, the paths it expects the ticket to touch, from the repo root: `"expected_files": ["src/export/", "tests/test_export.py"]`. A path ending in `/` covers everything under it. Two tickets overlap when a path of one equals, or lies under a directory of, the other's. A ticket with no `expected_files` is taken to overlap everything and runs alone in its wave: an undeclared ticket may touch anything, and parallelism that costs merge rework isn't worth having.

**Never in the same wave.** Overlapping tickets never share a wave, even after one of them has merged: `wave.sh dispatch` refuses (exit 10) a ticket whose expected files overlap a ticket in flight or one already dispatched in this wave. The held ticket goes in a later wave. A blocker and its dependent are never in flight together: the dependent isn't ready until its blocker is merged (`wave.sh dispatch` exit 5).

Expected files are a forecast. A worker that strays outside its set can still conflict, which is what the conflict rule below is for; a retro that sees it happen learns to slice or declare better.

## Merges

One ticket at a time, into the integration branch, in the integration worktree: `wave.sh merge`, a `--no-ff` merge followed by the plan's full `suite_command`. The suite runs after **every** merge, on the integration branch exactly as that merge left it, so a break is always attributable to one ticket. Never start a merge while another is unfinished.

| `wave.sh merge` exit | Means | Do |
|---|---|---|
| 0 | merged, suite green | `wave.sh close` |
| 7 | the suite went red | nothing: the merge was undone and only this ticket is blocked; carry on merging the rest |
| 11 | a conflict, left in progress | the one resolution try, below |
| 6 | refused, or a conflict whose try is used | nothing: blocked. If the ticket is `queued` again instead, its attempt didn't complete and it is retried (below) |
| 8 | its worker is still ending | wait, then merge again |

## A conflict: one try, then the Artisan

On exit 11 the merge is stopped halfway in the integration worktree, conflicts in place. Take the one try, in your own session (no merger subagent, no extra session):

1. Call the Skill tool with `artisan-agent:resolve-conflicts`, giving it the run folder and the ticket.
2. It ends with `RESOLVED: …` or `UNRESOLVED: …`. Then run `wave.sh resolved <run folder> <ticket>`, adding `--gave-up "<its sentence>"` after UNRESOLVED.

`wave.sh resolved` checks the work rather than trusting it: a file still unmerged, a conflict marker left, a change left unstaged or `--gave-up` aborts the merge and blocks the ticket (6). Otherwise it commits the merge and runs the full suite, as `merge` does: green merges it (0), red undoes it and blocks it (7). A blocked ticket's branch and worktree are always kept for the Artisan.

**Once per ticket.** The try is recorded (`tickets.<t>.resolve`) the moment the conflict is left in progress. Any later conflict for that ticket blocks it at once, and a try that never came back (the orchestrator ended mid-try) is aborted and blocked by the next `wave.sh merge`. Never run the skill twice on one ticket, and never resolve a conflict by hand.

## Two attempts

Each ticket gets at most `plan.attempts_per_ticket` attempts (2). An attempt fails when the worker reports `failed`, exits without a result, passes its deadline, vanishes, or ends without completing (no completion line, a cap hit); the sweep, or `wave.sh merge` for an attempt that returned but didn't complete, counts it.

- **First failure:** the ticket goes back to `queued`. Dispatch it again in the same wave with `wave.sh dispatch`. That is a **fresh worker**: a new session in a new worktree on the same branch, so the first attempt's commits are there to build on, and its prompt carries the failure evidence (`prompts/<t>.<n>.failure.md`): why the attempt counted as failed, how it ended, what its evidence record said (unmet criteria, what it was unsure of, its notes), its commits, and the end of its last reply and its stderr. Exit 8 means the failed session is still ending: wait and dispatch again.
- **Second failure:** the ticket is blocked with an exception decision for the Artisan. Never dispatch it a third time.

A conflict the try couldn't resolve, a red suite and a worker's `blocked` (a design question) are not failed attempts: they block at once and go to the Artisan.

## A wave that fails whole halts the run

When nothing in the wave is in flight, returned or waiting for its retry, and **every** ticket dispatched in it is blocked, the run halts: `wave.sh report` (or `wave.sh status`, if the orchestrator ended early) sets `halted`, logs a `halted` event and queues a `halt` decision. Something upstream is likely wrong (a bad spec, a broken base, a missing setup step), and the next wave would fail the same way.

`wave.sh status` then says `next: halted` with the reason, and `wave.sh launch` refuses (exit 12) until the Artisan decides. If they choose to carry on, `wave.sh launch --resume` records their decision and launches. One ticket merging is enough for a wave not to have failed.
