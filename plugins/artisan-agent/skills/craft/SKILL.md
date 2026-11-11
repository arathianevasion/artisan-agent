---
name: craft
description: The pipeline's front door. Takes any request in plain words, proposes one of four routes (Effort, Feature, Small change, Bug) by the route test with the reason, and lets the Artisan approve or change it before anything starts. Drafts the ticket for a Small change or Bug; names the exact command to type for typed-only steps. With an open run, hands over to /artisan-agent:implement-plan. Use when the Artisan says what they need and doesn't name a skill, e.g. "I want to add...", "this is broken", "where do I start", "craft this".
disable-model-invocation: true
---

# Craft

The front door. The Artisan says what they need in plain words; you propose a **route**, they approve or change it, and only then does anything start. Every underlying skill stays directly usable without you: you are a convenience, not a requirement.

Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`: lead with the problem, arrive with a recommendation, show the reasoning and the strongest rejected alternative. Use `GLOSSARY.md` vocabulary ("pipeline", never "workflow") and respect `docs/adr/`. Tracker commands come from `docs/agents/issue-tracker.md`; label strings from `docs/agents/triage-labels.md`.

## 1. Check for an open run first

Look for a run that is open in this repo: a run folder under `.artisan-agent/runs/` that isn't finished, or an open `plan` issue the Artisan has approved. If one exists, tell the Artisan in one line ("run <id> is open: <where it is>") and ask whether this request is about that run or new work. For the run, hand over to `/artisan-agent:implement-plan`, which owns resume and the digest; don't summarize its state yourself. A new request then continues below, and an approved small item may be added to that run (section 4).

## 2. Propose a route by the route test

Take the request as given. Read what you need from the repo and tracker to answer the test; never ask the Artisan for a fact you can look up. Apply the test **in this order** and stop at the first answer:

1. **Can the destination and the acceptance criteria be stated now?** If not: **Effort**.
2. **Does it need more than one ticket?** If yes: **Feature**.
3. **Otherwise**, one ticket: a **Bug** if something is broken (it did work, or should, and doesn't), else a **Small change**.

**When unclear, propose the bigger route** (Effort over Feature, Feature over Small change) and say why. A request that is partly clear is not clear. Don't ask a string of questions to resolve it: pick, state the reason, let the Artisan correct you.

Put the proposal in front of the Artisan as one message:

- the route and **why**, naming which test answer decided it and the part of the request that decided it (rule 3 in ARTISAN.md);
- the strongest alternative route and why it lost;
- the steps of the route with the **exact command** for each (below);
- a prompt to approve or change the route. If they change it, adopt their route without argument; if the change looks costly (a Feature sent down as a Small change), say so once.

Start nothing before they answer.

## 3. The routes

Name our replacements as `/artisan-agent:<name>` always, even when the skill ships in a later release. Name upstream skills that are typed-only in full as `/mattpocock-skills:<name>`. When you name a step, give the command the Artisan types, not a description of it.

**Effort** (foggy; no statable destination):

1. `/mattpocock-skills:wayfinder`: map the effort. Typed only; the Artisan types it.
2. `/artisan-agent:to-spec`: turn the decisions into a spec.
3. `/mattpocock-skills:to-tickets`: slice the spec into tickets. Typed only; the Artisan iterates the slicing until happy, so approval of the slices happens there.
4. `/artisan-agent:to-plan`: chunk the tickets into plans.
5. `/artisan-agent:implement-plan`: run them.

**Feature** (clear, more than one ticket):

1. `/artisan-agent:grill`: settle the decisions, writing terms and ADRs as they settle.
2. `/artisan-agent:to-spec`
3. `/mattpocock-skills:to-tickets` (typed only; the Artisan iterates the slicing).
4. `/artisan-agent:implement-plan`. Offer `/artisan-agent:to-plan` between 3 and 4 only if the Artisan wants chunks; don't push it.

**Small change** (clear, one ticket): draft one ticket with acceptance criteria, section 4.

**Bug** (one ticket, something is broken): run `diagnosing-bugs` (the Skill tool, `mattpocock-skills:diagnosing-bugs`) to reproduce it and find the cause, then draft one ticket whose acceptance is a failing test, section 4.

For Effort and Feature, you hand the Artisan the first command and stop. You don't run `wayfinder`, `to-tickets`, `grill` or `to-spec` for them. At each step the Artisan finishes, if they come back to you, name the next command again.

## 4. Drafting a ticket (Small change and Bug)

Draft the ticket as the Artisan would want to approve it, following the durable-brief guidance in `${CLAUDE_PLUGIN_ROOT}/skills/triage/AGENT-BRIEF.md`: what to build and why (the problem first), no file paths or line numbers that will rot, and acceptance criteria as a checklist an agent can verify.

- **Small change:** the problem, the behaviour wanted, and acceptance criteria that can each be checked. If you can't write checkable criteria, the destination isn't statable: go back to section 2 and propose the bigger route.
- **Bug:** after `diagnosing-bugs` finishes, the ticket carries the **reproduction** (the exact steps or command and what is observed against what is expected), the **cause** found, and acceptance written as a **failing test**: "a test that reproduces the bug fails before the fix and passes after, and the suite stays green". Name the seam the test belongs at. If diagnosis can't reproduce the bug or find a cause, say so and propose the way forward (more evidence, or a bigger route); don't draft an unprovable ticket.

Show the draft and wait for approval or edits. Don't file anything first.

**Once the Artisan approves it**, create the issue and apply `ready-for-agent` (plus `bug` or `enhancement` as the category) in one step. A ticket the Artisan approved **skips triage**: don't apply `needs-triage` and don't ask them to approve it twice. Don't start running it.

Then say it is filed and waiting, and offer the ways to run it:

- **alone:** `/artisan-agent:implement-plan #<n>`;
- **as a batch** with other `ready-for-agent` tickets: `/artisan-agent:implement-plan` naming them;
- **added to a larger run:** if a run is open (section 1), hand over to `/artisan-agent:implement-plan` with the ticket for it to add to that run's scope.

Nothing runs until the Artisan picks one. If a run is open and they pick it, or ask you to "just run it", invoke `/artisan-agent:implement-plan` through the Skill tool with the ticket so it opens or extends the run through its own plan approval.

## Boundaries

- Never skip the route approval, even for an obvious request. One line is enough when the route is obvious, but the Artisan still says yes.
- Never touch an issue the Artisan didn't approve you to file.
- Don't start implementing anything yourself. You route, diagnose (Bug) and draft.
- If the Artisan corrects your route or repeats themselves, offer to keep it: "make this a guardrail?" (ARTISAN.md rule 5).
