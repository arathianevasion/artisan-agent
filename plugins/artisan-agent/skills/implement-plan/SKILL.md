---
name: implement-plan
description: Run a defined set of work to completion — a plan, several plans, individual tickets, a single ticket, or any mix. Reads published tickets and their blocking edges, plans a purpose-built agent for each one (model, brief, expected output), gets the plan approved, then dispatches tickets in dependency waves across isolated git worktrees where each agent runs /artisan-agent:implement, and closes tickets, resolves merge conflicts, and files discovered work for triage as results come back. Use this whenever the Artisan wants tickets built — "run this ticket", "work the backlog", "run the plan", "implement these tickets", "fan out the tickets", "run them in parallel", "kick this off overnight", "burn down the frontier" — and whenever they ask to orchestrate, dispatch, or parallelize agents over one or more issues, even if they do not say the word "ticket". Claude may call it, for example when another pipeline step hands an approved ticket or plan on to be built.
---

# Implement Plan

Run a defined set of work to done: a plan, several plans, individual tickets, a single ticket, or any combination. That set is the run's scope; anything outside it waits.

`/artisan-agent:implement` runs one ticket in the session that invokes it. It has no completion step: it ends at the commit and never touches the work item, does not act on `/code-review` findings, and does not tick acceptance criteria. Even for a single ticket that leaves the work unverified and the ticket open, and for a queue it is fatal, because `to-tickets` defines the frontier as tickets whose blockers are all **closed**. If nothing closes, nothing ever unblocks, and an unattended run re-picks the same ticket forever.

This skill is the missing layer above `/artisan-agent:implement`: it owns the dependency graph, the agent design, the dispatch, and — critically — the reconciliation. It never implements anything itself.

Wherever this skill puts something in front of the Artisan (the plan, a wave report, a question), follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`.

## Preconditions

Stop and tell the Artisan which is missing rather than working around it:

- Tickets are published — either `.scratch/<feature>/issues/NN-slug.md` or issues on a configured tracker. If not, route to `/to-tickets` first.
- `/setup-matt-pocock-skills` has run for this repo.
- The working tree is clean and `git worktree` is available.
- `/artisan-agent:implement`, `/tdd`, `/code-review`, `/artisan-agent:resolve-conflicts` and `/artisan-agent:triage` are installed, because this skill and its agents all reach for them.
- **Every gate the agents will report on has been proven capable of failing.** Run each one — test suite, typecheck, lint — against a deliberately broken file and confirm a non-zero exit, then revert. A gate that cannot fail turns every agent's report into noise for the length of the run, and nothing downstream will reveal it: the results all say "clean", the merges all stay green, and you find out only when someone reads the config. Report what each gate actually covers, in the plan, alongside the tier mapping.

The last one is not ceremony. In a real run, `npm run typecheck` was `tsc --noEmit` against a root `tsconfig.json` with `"files": []` and only project references — `tsc` does not follow references, so it compiled an empty program and exited 0 unconditionally. Thirty tickets reported "typecheck clean" and every one of those claims was vacuous.

Anything the agents cannot verify, say so in the plan rather than discovering it at the end. A gate whose coverage you have not measured is a gate you are entitled to distrust.

## Composition

Skills split on who can invoke them. A typed-only skill (`disable-model-invocation: true`) runs only when a person types it; a Claude-callable skill can also be called by Claude, including from another skill.

This skill is Claude-callable, so another pipeline step can hand it work. Dispatch still never happens in-session: an in-session subagent shares this session's working directory and cannot give a ticket a fresh context window. Each ticket gets a separate `claude -p` process in its own worktree, where the prompt runs `/artisan-agent:implement` explicitly in a fresh session. Do not attempt an in-session fan-out.

## Process

### 1. Read the queue and build the graph

Read every ticket body in full — not just titles. Extract for each: id, title, its `Blocked by` edges (native tracker links or the `## Blocked by` body section), its acceptance criteria, and the layers it touches.

Compute **waves** by topological level: wave 1 is every ticket with no open blockers, wave 2 is everything unblocked once wave 1 closes, and so on. Tickets within a wave run in parallel; waves run in series.

If the graph has a cycle, stop and show it. A cycle means `to-tickets` produced edges that cannot be satisfied, and that is a planning bug to fix, not something to route around.

Watch for the expand–contract shape. Migrate batches from a wide refactor look independent but often touch overlapping call sites; when two tickets in a wave name the same package or directory, put them in separate waves and say why.

### 2. Design an agent per ticket

Each ticket gets its own agent spec with three parts. Design them from the ticket body, not from a template.

**Model.** Implementation mostly follows context and tolerates a cheaper model; the expensive reasoning already happened during grilling. So default every ticket to the mid tier and escalate deliberately. Escalate when the ticket introduces a new seam or module boundary, is the first tracer bullet through a layer that does not exist yet, changes domain vocabulary or an ADR, or has acceptance criteria that read as judgment rather than as behaviour. Use the fast tier only for mechanical migrate batches in an expand–contract sequence.

Map tiers to concrete model ids once, in the plan, so the mapping is visible and can be changed in one place rather than being buried per ticket.

**Brief.** A short prompt that names the ticket path, the seams the agent should test at if the ticket already pre-agreed them, and any GLOSSARY.md vocabulary or ADRs it must respect. Keep it under a paragraph. The ticket is the spec; the brief is orientation, and duplicating the ticket into the brief just spends context twice.

**Expected output.** What "done" looks like for this specific ticket in one or two lines, drawn from its acceptance criteria. This is what the reconciliation step in 5 checks against — a vague expected output makes the whole loop unverifiable, so if you cannot write a concrete one, the ticket is underspecified and should go back to `/to-tickets`.

### 3. Get the plan approved

Present the whole plan before dispatching anything. Use this structure:

```
## Wave 1 (parallel)
| Ticket | Description | Model | Expected output |
|---|---|---|---|
| #01 | Short plain description of the ticket | mid | ... |

## Wave 2 (blocked by #01 short description, #02 short description)
...

Tier mapping: frontier=<id>, mid=<id>, fast=<id>
Worktrees: <N> under ../<repo>-wt/
```

Wherever a plan, report or status update names a ticket, give its number and a short plain description together, such as "#01 (retry failed uploads)". A number or slug alone means nothing to a reader who hasn't memorised the queue.

Then wait. Iterate on wave composition, tier choices and briefs until the Artisan approves. Dispatch nothing before approval — an unattended run that starts from a wrong graph is far more expensive to unwind than one that starts late.

### 4. Dispatch a wave

One worktree and one `claude -p` process per ticket in the wave, running concurrently. Full mechanics, commands and the result contract are in `references/dispatch.md` — read it before the first dispatch.

The essential shape: each agent gets its own branch and checkout, is told to run `/artisan-agent:implement` against its ticket path, and writes a structured result file into the shared results directory when it finishes. Results go in files rather than stdout because a crashed or truncated process still leaves whatever it wrote, and stdout parsing turns an agent's prose into a coin flip.

Never let an agent close its own ticket or merge its own branch. Both are orchestrator jobs, and an agent that judges its own completion has no independent check.

**Dispatch on merged, never on reported.** A ticket is dispatchable only when every one of its blockers is **merged into the integration branch** — not when the blocker's agent reported `complete`. Agents branch from the integration branch, so a ticket dispatched against an unmerged blocker gets a base without it and silently re-derives the blocker's work. Gate on the branch, not on a status field:

```bash
git merge-base --is-ancestor "${BLOCKER_MERGE_SHA}" "${BASE}" || echo "not dispatchable yet"
```

A result file is a claim; the merge is the fact, and the gap between them is where this goes wrong.

The observed failure is subtler than plain duplication, and worth knowing in its exact shape. A ticket was dispatched the moment its blocker's result said `complete` but before the merge landed. The agent noticed its base lacked the blocker and merged the blocker's branch itself — which fast-forwarded, because both branched from the same base — then built on top. The work was correct. What broke was the **orchestrator's own measurement**: diffing that branch against a `main` still missing the blocker showed 23 shared files, which reads exactly like an independent re-derivation. That reading triggered an unnecessary reconciliation dispatch.

So the rule has two halves:

- Verify `BASE` contains every blocker before dispatching, so an agent never has to rescue you.
- **Measure collisions against a base that contains all merged work.** A three-dot diff against a stale tip attributes the blocker's files to the dependent, and the conclusion you draw from it — duplication, conflict risk, merge order — will be wrong. If a collision set looks like one ticket wholly containing another, check `git merge-base --is-ancestor` before believing it.

The stronger form of the same rule: **a blocker and its dependent are never concurrently in flight.** Not in the same wave, and not via a conditional dispatch at the end of one. If you find yourself writing "dispatch B if A succeeded", the answer is to merge A first and put B in the next wave.

### 5. Reconcile the wave

For each returned result, in this order:

1. **Verify against expected output.** Read the diff on the agent's branch against the expected output from step 2 and the ticket's acceptance criteria. An agent reporting success is a claim, not evidence.
2. **Merge** the branch, run the full test suite on the merged result, and remove the worktree. Merge serially, testing after each, so a break is attributable to one ticket. On a conflict, run `/artisan-agent:resolve-conflicts` — parallel waves make conflicts routine rather than exceptional, and the repo already has the discipline for them. If that does not resolve it, or the suite fails on the merged result, abort, leave the branch and worktree in place, mark the ticket blocked, and carry it into the report.
3. **Close the ticket** and tick its acceptance criteria. This is what advances the frontier.
4. **File discovered work, then triage it.** Where a result names outstanding requirements, create a new ticket on the same tracker with a body citing the ticket that discovered it — and file it **off the frontier**, with no blocking edges and no wave assignment.

   Tickets from `to-tickets` are agent-ready by construction and should never be triaged; triage is for work that arrived from someone else. A ticket an agent invented mid-run is exactly that. It has not been grilled, sized to a context window, or checked for whether it is really a tracer bullet. Run `/artisan-agent:triage` on it before it is eligible for any wave, and never let an untriaged discovery enter the dispatch queue — that is how an unattended run turns one agent's guess into three more agents' work.

   Only once triage has admitted it do you add blocking edges and recompute the graph. If that changes the wave structure, say so and show what moved before continuing. If triage rejects or reshapes it, that is a fine outcome and belongs in the report.
5. **Surface review findings.** `/code-review` findings arrive with the result and nobody acts on them by default. Collect them into the wave report rather than silently discarding them.

Only after every ticket in the wave is closed or explicitly marked blocked, recompute the frontier and dispatch the next wave.

**Recompute the frontier from the tracker and the branch, not from the plan.** The wave structure from step 3 is a forecast. What actually dispatches next is whatever is open, untriaged-free, and has every blocker merged *right now*. Re-derive it each time rather than working down the approved list — a blocked ticket, a discovered edge, or a wave that lands out of order all invalidate the forecast without invalidating the run.

### 5a. Keep going

Once the plan is approved the run is **unattended**. Continue through every wave without pausing for the Artisan's input: reconcile, recompute, dispatch, repeat, until the queue is empty or genuinely blocked. Report at wave boundaries — but a report is not a stopping point, and neither is a status question from the Artisan.

Two specific failure modes to avoid, both observed:

- **Do not yield the turn while agents are in flight.** Poll the result files. Notifications and monitors are a convenience, not the source of truth: a monitor whose stream ends looks exactly like a wave still running, and work can sit finished and unreconciled for as long as it takes someone to ask.
- **Do not treat "I have something to report" as "I am done."** If the next action is knowable — a merge, a close, a dispatch — take it, then report what happened including the part you just did.

Stop only for: an approval the Artisan actually owes you, a graph change that invalidates the plan they approved, or every ticket in a wave failing.

### 6. Report

After the final wave:

```
## Run summary
Completed: N of M tickets
Blocked: #<number> (<description>) — <one line why>
Discovered, awaiting triage: #<number> (<description>), from #<number> (<description>)
Review findings not acted on: <count, grouped by ticket, each with number and description>
Branches left unmerged: <branch, with ticket number and description>
```

Blocked tickets and unmerged branches go at the top, not buried. The value of an unattended run is knowing precisely where it stopped.

## Failure handling

- **An agent fails or times out.** Mark the ticket blocked, keep the worktree for inspection, and continue the rest of the wave. Do not retry automatically — a repeat failure usually means the ticket is wrong, and a retry loop burns tokens proving that slowly.
- **An agent reports success but the diff does not meet the expected output.** Treat as blocked, not complete. Say what was missing.
- **A discovered dependency invalidates the graph.** Recompute waves, stop, and show the Artisan the new graph before continuing. A silently reshuffled plan is one the Artisan never approved.
- **Everything in a wave fails.** Halt the run entirely. Something upstream is wrong — a bad spec, a broken main branch, a missing setup step — and the next wave will fail the same way.

## Rules

- One agent, one ticket. Never batch tickets into a single agent to save processes; that is exactly the context blow-up the ticket sizing exists to prevent.
- The orchestrator never writes product code. If you find yourself fixing a merge conflict by editing source, stop and hand it back as a blocked ticket.
- Keep the orchestrator's own context small: read ticket bodies and result files, never agent transcripts.
- Do not compact between waves. Results are files; the orchestrator's working state should be small enough that it never needs to.
