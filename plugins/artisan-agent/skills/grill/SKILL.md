---
name: grill
description: Understand-stage skill. Grill the Artisan about a plan, design or decision until you share an understanding, writing glossary terms and ADRs as each decision settles. Each question arrives with options, one recommendation and why the strongest alternative lost. Offers /artisan-agent:debate-me, autonomous research and prototype variants. Use when the Artisan says "grill me", "stress-test this", "interview me about this plan", or when the pipeline reaches Understand.
---

Interview the Artisan until you reach a shared understanding of the problem and the solution. This is the pipeline's single grilling step. It replaces the upstream grill-me and grill-with-docs steps; don't offer or mention either one.

Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`. Decisions are the Artisan's: you recommend, they decide.

## Load both upstream skills, every time

At the start, call the Skill tool twice, before your first question:

1. `grilling` (the round-by-round design-tree interview).
2. `domain-modeling` (glossary terms and ADRs).

Always both, together. Don't ask whether to load them and don't skip either. Follow `grilling` for how rounds work (the design tree, the frontier, facts found by you rather than asked of the Artisan) with the question format below in place of its default.

## Question format

Every question in a round shows:

```
❓ **Q<n>** - **<title>**: <the question, in the Artisan's problem terms>

Options:
- **A. <option>**: <what it means, in one line>
- **B. <option>**: <what it means, in one line>

➡️ **Recommend <letter>**: <why, in one or two lines>

↔️ **Strongest alternative, <letter>, lost because**: <the one reason it loses>
```

- Options are real: ones you would defend, each different in consequence. No straw options, no "other" as filler (the Artisan can always say something else).
- Word the question so "yes" or the recommended letter accepts your recommendation.
- If you can't name why the strongest alternative lost, you haven't understood the question. Look more into it before asking.
- Ask the whole frontier in a round, as `grilling` says.

## Record decisions as they settle

When an answer settles a decision, record it in the same session, before the next round, as `domain-modeling` directs:

- A term was settled or sharpened: update `GLOSSARY.md`. Use the term from then on.
- A decision is hard to reverse, surprising without its context, and the result of a real trade-off: write an ADR in `docs/adr/`.

Tell the Artisan in one line what you wrote and where. Settling a term is an approved job (job 6 in `${CLAUDE_PLUGIN_ROOT}/references/jobs.md`): the Artisan's answer is the approval; if you coined the wording, put it in the question. Respect existing ADRs; when an answer conflicts with one, say so and ask whether to supersede it. Don't decide an ADR-worthy matter yourself: ask, per `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`.

## Offer these tools

Offer each at the moment it helps, in one line, and let the Artisan choose. Don't run the first two on your own.

- **Debate.** When the Artisan doubts your recommendation, or the decision is hard to reverse or shapes many tickets, offer `/artisan-agent:debate-me`. It argues your recommendation against their view until they decide; carry its decision summary back into the tree.
- **Research.** When a question needs facts you can't get from the codebase, run the upstream `research` skill without asking approval: finding facts is autonomous (job 5). Say what you're researching and carry on with the rest of the frontier. The Artisan can add or correct a fact at any time; take it as given, without asking them to approve it, and rework anything downstream of it.
- **Prototype.** When a question is a matter of taste that words can't settle (how it should look, feel or flow), offer to build a throwaway prototype with the upstream `prototype` skill and show variants. The Artisan reacts to what they see and that answers the question. Throw the prototype away afterwards; keep a snippet only if it encodes a decision, and record the decision.

## Done

The session is done when the frontier is empty and the Artisan confirms the shared understanding, as `grilling` says. Don't write a spec yourself. Say the next step is `/artisan-agent:to-spec`, and name which terms and ADRs you recorded.
