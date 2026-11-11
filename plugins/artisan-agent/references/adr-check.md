# The ADR and guardrail check, and the ADR adjustment loop

Plan approval opens with this check, so the Artisan steers through decisions rather than by taking tickets. Two places run it, and both follow this page:

- `/artisan-agent:to-plan`, before it asks for approval of the plans (one check per plan);
- `/artisan-agent:implement-plan`'s plan step, **when the route skipped `to-plan`**: a Small change, a Bug, or a Feature without chunks. A one-ticket Small change gets the same check as a ten-ticket plan.

Where the check is shown, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md` and the vocabulary in `GLOSSARY.md`. Tickets are always shown in a markdown table, one row per ticket with its number and a short description together.

## 1. Gather

1. **The ADRs:** `${CLAUDE_PLUGIN_ROOT}/scripts/adr-check.sh list` (from the repo; `--adr-dir` to point elsewhere). Read each ADR a ticket or the plan could touch; for a small repo, read them all.
2. **Each ticket's ADRs:** the ones its body cites (`gh issue view <n> | ${CLAUDE_PLUGIN_ROOT}/scripts/adr-check.sh refs` lists the ADRs it names) plus any you judge it touches without naming. Don't trust the citations alone.
3. **The guardrails across the three levels:** `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh resolve > <folder>/resolve.json` (no run exists yet, so no `--run-dir`). Its `conflicts` and `overridden` say which guardrails disagree across product, team and individual levels and which one applies (rules in `${CLAUDE_PLUGIN_ROOT}/references/guardrails.md`). Pass `--role` when a pair's Artisan holds one role.

## 2. Judge, and write the check file

Write `<folder>/adr-check.json` (shape in the header of `scripts/adr-check.sh`):

- **`plan_adrs`:** the ADRs the plan touches and, for each, how the plan complies (`complies`, or `tension` with the reason).
- **`tickets`:** each ticket's ADRs, with `tension: true` and a note where the ticket works against an ADR, or the ADR is out of date for it. Tension is a call you make from the text; when in doubt, flag it.
- **`gaps`:** important decisions the plan or tickets make that no ADR covers yet (a new seam, a dependency, a data shape that is hard to reverse), with the tickets involved and a suggested ADR. Be selective: a gap is a decision the Artisan would want recorded, not every choice.

## 3. Show it

`${CLAUDE_PLUGIN_ROOT}/scripts/adr-check.sh render <folder>/adr-check.json --guardrails <folder>/resolve.json` prints, in order: the plan against its ADRs, each ticket against its ADRs with `TENSION` flagged, the gaps, then every guardrail conflict with the level that applies. It refuses an ADR number that has no file, so a mis-cited ADR is caught before the Artisan sees it. Show the output as printed, then your recommendation for each tension and gap (resolve it by changing the ticket, by changing the ADR, or by accepting it) and the strongest alternative you rejected.

This view comes **before** the approval of the plan itself. Nothing is created or dispatched from a plan whose check the Artisan hasn't seen.

## 4. The ADR adjustment loop

When the Artisan says what changes in an ADR (or asks to record a gap as a new one):

1. **Draft the edit.** Draft it as the change to `docs/adr/<file>` (or a new ADR, following `docs/adr/`'s existing shape and `mattpocock-skills:domain-modeling`). Show the diff, not a description of it.
2. **The Artisan approves.** Revise until they do. Nothing is written to the repo before.
3. **Land it by a short PR, before dispatch.** Without touching the main checkout (`${CLAUDE_PLUGIN_ROOT}/references/main-checkout.md`): `wt=$(${CLAUDE_PLUGIN_ROOT}/scripts/doc-change.sh start adr-<n>)`, commit the edit in `$wt`, cut the PR with `mattpocock-skills:pr` as an approved step following the PR guardrail, and when it merges, `${CLAUDE_PLUGIN_ROOT}/scripts/doc-change.sh finish adr-<n>`. No ticket is dispatched, and no run starts, until the edit has landed.
4. **Re-check the affected tickets.** `${CLAUDE_PLUGIN_ROOT}/scripts/adr-check.sh affected <check.json> --adr <n>` names the tickets that cite the edited ADR; add any you now judge affected. Re-read them against the new text, update the check file, and render it again. Show the affected tickets in a table (ticket, tension before, tension now), then the full view. A tension that remains goes back to the Artisan.

The loop repeats until the Artisan accepts the check. Changing an ADR is the Artisan's decision: agents draft and never merge their own edit.

## Rules

- The check is shown even when it is clean: "no tension, no gaps, no conflicts" is the answer, not silence.
- A guardrail conflict is surfaced, never resolved here: the level that applies is the one `guardrails.sh resolve` reports. Moving a guardrail is the Artisan's, at a retro.
- A route that skipped `to-plan` is not exempt. If you find the check wasn't run, run it before the plan step's approval.
