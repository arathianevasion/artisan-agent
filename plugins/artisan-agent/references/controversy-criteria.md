# Controversy criteria

When an agent may decide alone, and when a decision must come back to the Artisan. These apply anywhere an agent would otherwise decide alone: triage, a worker's decisions mid-ticket, and findings filed during a run.

Skills cite this file rather than copying it: "criterion 3 in `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`". The numbers are stable; name the triggering criterion by number whenever you record a controversial decision, or "none".

## The eight default criteria

A decision is controversial when it:

1. **Contradicts a recorded decision**: a grilled ticket, an ADR, the glossary or a guardrail.
2. **Adds scope**, unless the addition is minimal and reversible, or there are only one or a few sensible ways to do the work and the addition is moderate.
3. **Is hard to reverse**: schema or data changes, a public interface, a new dependency, anything shipping irreversibly.
4. **Is taste no guardrail covers.**
5. **Is a "stop and ask"** named in the ticket.
6. **Can only be judged by using the thing.**
7. **Is a priority call, a wontfix, or a choice between two reasonable designs.**
8. **Is an open decision**: any answer an execution agent could give would leave the feature incomplete or misaligned, invent user-facing behaviour the ticket doesn't describe, or settle something that needs an ADR. The four cases, the named-harm bar and what isn't an open decision: `${CLAUDE_PLUGIN_ROOT}/references/open-decisions.md`. Only an open decision goes to the Decision chat (ADR 0002).

**When in doubt, it's controversial.** That holds for criteria 1 to 7. For criterion 8 the rule is reversed, for criterion 8 only: **When in doubt, it's the execution agent's call.** An agent raises an open decision only when it can name the case and the concrete harm; otherwise it decides and records a card.

## Not controversial

- Meeting the brief.
- Fixing bugs.
- Closing test gaps.
- Refactors inside the agreed design.
- Already-scoped follow-ups.
- Taste a guardrail covers.
- Scope additions within the exceptions in criterion 2.

## Project additions

Each project adds its own items in the "Always ask" section of `PRODUCT_STANDARDS.md` and `CODING_STANDARDS.md`. Team and individual items go in the same sections at those levels. Read them at the point of use, alongside this list. Only the Artisan changes the lists, through setup and retro lessons.

## Provisional picks

Easy-to-reverse taste (criteria 4, 6 and 7) may instead be picked provisionally and shown as a "provisional" decision card at the next slice gate. Criterion 8 is never picked provisionally: an open decision is filed with `questions.sh file --criterion 8`, never chosen for now.
