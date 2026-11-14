---
name: to-plan
description: Plan-stage skill in the Product chat. Takes the published ticket graph and proposes plans: chunks of tickets, each ending at a slice reviewable end to end, each fitting a budget the Artisan would approve in one go, never putting a blocker after its dependent. The Artisan splits, merges and reorders until happy, sees every ticket's acceptance criteria, then approval creates one `plan` issue per plan with its tickets as sub-issues and native blocking between dependent plans. Use after /mattpocock-skills:to-tickets on an Effort, or when the Artisan wants chunks, says "plan these tickets", "chunk the tickets", "what runs together", or "group the backlog into plans".
---

# To Plan

Decide which work runs together. This skill is the Product chat's: it proposes, the Artisan decides (job 24, "decide which tickets go into which plan", is the Artisan's to approve; `${CLAUDE_PLUGIN_ROOT}/references/jobs.md`). It never starts a run: a plan runs when `/artisan-agent:implement-plan` is given it.

Wherever you put something in front of the Artisan (the proposal, a warning, a question), follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`: lead with the problem, arrive with a recommendation, show the reasoning and the strongest alternative you rejected. Use `GLOSSARY.md` vocabulary (its "Plan" entry names the words to avoid) and respect `docs/adr/`. Wherever tickets are shown, use a markdown table, never a list: one row per ticket, its number and a short plain description together (such as "#12 (retry failed uploads)").

The arithmetic is `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh` (usage in its header, tests in `tests/to-plan.test.sh`). You supply the judgement it can't: which tickets together make something reviewable, and what each costs.

## Preconditions

- Tickets are published on the tracker (`docs/agents/issue-tracker.md`). If not, route to `/mattpocock-skills:to-tickets` first.
- `gh`, `jq` and `python3` are on PATH, and the `plan` label exists in the repo. If creating a `plan` issue fails on the label, say so and stop; don't create it unlabelled.

## Process

### 1. Read the ticket graph

Decide the set: the open tickets of the spec or effort the Artisan names (or "the ready backlog"). Then read it from the tracker:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh graph --repo <owner/name> <ticket>... > <folder>/graph.json
```

It records each ticket's title, acceptance criteria and blockers within the set. A blocker outside the set that is still open becomes an `external_blockers` entry and is flagged in every view. Read the ticket bodies too: you need them for the next step.

### 2. Name the slices and estimate

Add two things to each ticket in `graph.json`, from its body:

- **`slice`**: a short name for what the ticket helps make reviewable end to end (a thing the Artisan could look at or try, such as "upload with progress"). Tickets that belong to one reviewable thing share a name. A ticket that is reviewable alone gets its own name, or none.
- **An estimate**: `estimate_usd`, or a `model` with `expected` `input_tokens` and `output_tokens`, sized the way the plan step sizes a ticket (`${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/SKILL.md`, step 2). Size each ticket on its own; there are no defaults.

Plans are cut only between slices, so a slice is never split unless the Artisan splits it.

### 3. Propose

Ask for the budget if the Artisan hasn't given one: the amount they would approve in one go. Recommend a number with a reason (what they have approved before, what the run's reserve allows); never assume one. Then:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh propose --graph <graph.json> --budget <usd> > <folder>/plans.json
${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh render <plans.json> --graph <graph.json>
```

Show the render as printed: a table of plans (slice each ends at, tickets, estimate against the budget, which plans each runs after), then each plan's tickets in a table with their blockers, estimates and **acceptance criteria**, then anything under "Needs your attention". The proposal guarantees these, and `check` re-proves them after every edit:

- every ticket is in exactly one plan;
- no blocker is in a later plan than the ticket it blocks (slices that block each other both ways become one unit);
- each plan ends at a slice, and says which;
- every plan carries an estimate.

Each plan's tickets look like this:

| Ticket | Blocked by | Estimate | Acceptance criteria |
|---|---|---|---|
| #12 (retry failed uploads) | none | $2.00 | ☐ a failed upload retries three times<br>☐ the user sees the last error |

Under the tables, say in a few lines why you cut where you did and the strongest alternative (a bigger plan, a different slice boundary). If a plan is over budget because one slice is, say so and recommend: raise the budget or split the slice and accept that neither half is reviewable alone.

**Human checks.** An agent ticket's criterion that reads as needing a person (in game, by hand, by eye, on a real device; the list is in `${CLAUDE_PLUGIN_ROOT}/references/human-checks.md`, plus the project's `human_check_phrases`) is flagged under "Needs your attention", and `check` refuses approval while it stands: the verifier could never pass it. For each one, recommend the split and offer the override:

| Artisan says | Run |
|---|---|
| "split it" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh split-human-check --repo <owner/name> --graph <graph.json> --plans <plans.json> <ticket> "<criterion>"` |
| "keep it, because …" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh check <plans.json> --graph <graph.json> --override-human-check <ticket> "<criterion>" --why "<their reason>"` |

The split moves the criterion off the agent ticket into its **Human check** ticket (created with title, marker, `ready-for-human` and the blocking edge, or added to the one that exists); running it again changes nothing. The override is recorded on the plan, in `plans.json` and the plan issue's body. Never override without the Artisan's reason. A Human check sits in its agent ticket's plan, listed in the view as "not estimated": it is a person's work, not agent work.

If the graph has a cycle, the script refuses and names it. Show it: it is a planning bug in the tickets, not something to route around.

### 4. Iterate until the Artisan is happy

The Artisan can ask for any of these, in any order, as many times as they like. Each rewrites `plans.json`, renumbers the plans, and is **refused with the reason, leaving the file untouched,** if it would put a blocker after its dependent:

| Artisan says | Run |
|---|---|
| "split plan 2: move #5 out" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh split <plans.json> --graph <graph.json> 2 5` |
| "merge plans 1 and 2" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh merge <plans.json> --graph <graph.json> 1 2` |
| "run plan 3 before plan 2" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh reorder <plans.json> --graph <graph.json> 1,3,2` |
| "put #4 in plan 3" | `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh move <plans.json> --graph <graph.json> 4 3` |

After each edit, render again and show only what changed in one line, then the new tables. When an edit is refused, tell the Artisan which blocking edge stopped it and what would make it possible (for example, moving the blocker too). Changing a ticket's slice or estimate goes into `graph.json`; propose again only if the Artisan asks. A correction the Artisan repeats ("I always want plans this small") is offered as a guardrail (ARTISAN.md rule 5).

### 5. Get approval

Open with the ADR and guardrail check for each plan, then the loop if the Artisan wants an ADR changed, as `${CLAUDE_PLUGIN_ROOT}/references/adr-check.md` describes. Any ADR edit lands before the plans are created.

The Artisan's approval is the only thing that creates anything. Show the final render once more, with every ticket's acceptance criteria, and ask for approval of the plans as shown. Nothing is created from silence, or from a plan the Artisan has seen only in an earlier version.

When the Artisan also approves a plan's run envelope here (waves, models, estimates, budget) and that plan will wait behind the run lock rather than start, record it once the plan issue exists: `${CLAUDE_PLUGIN_ROOT}/scripts/chats.sh approve-envelope --repo <owner/name> <plan issue>`. The chat that got the approval records it, so the Engineering chat doesn't ask again. Approving only the plans' tickets and grouping, as above, is not an envelope approval: don't call it then.

### 6. Create the plan issues

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh publish <plans.json> --graph <graph.json> --repo <owner/name> --approved
```

It creates one issue per plan, labelled `plan`, titled "Plan N: <slice>", whose body lists its tickets; adds each ticket as a sub-issue of its plan; and blocks each plan natively by the earlier plans it depends on. It writes the issue numbers back into `plans.json`, so after a failure the same command carries on without creating duplicates.

A GitHub issue has one parent. A ticket that already sits under its spec stays there unless the Artisan agrees to move it (`--replace-parent`), because moving it takes it out of the spec's child list; it is still listed in its plan's body, which `implement-plan` reads. The script says which tickets stayed. Tell the Artisan which, and ask once whether to move them.

Finish with a table of the plans (number, issue, tickets, estimate, blocked by) and the next step: `/artisan-agent:implement-plan` on one plan, several, or plans mixed with single tickets. Published plans are edited on the tracker, not here.

## Rules

- Never create an issue before approval, and never create a plan the script's `check` refuses, including for a criterion that needs a person.
- Never split a blocker after its dependent, and never resolve it silently if the Artisan asks for it: explain and offer the nearest valid alternative.
- Estimates come from the plan step's method, never from a guess at what fits the Artisan's attention.
- A plan is not a run: the run's envelope (models, gates, Max Agents) is approved at `implement-plan`'s plan step.
