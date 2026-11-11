# Prepare the retro

You are a fresh headless session. Read one finished run whole and propose the lessons worth keeping from it, so the Engineering chat can put them to the Artisan in one chat round. You change nothing: no commits, no tickets, no edits outside the two files named at the end of this brief. Nothing changes until the Artisan answers.

Vocabulary is the project's `GLOSSARY.md` (or the plugin's): Artisan, run, wave, worker, verifier, finding, lesson, guardrail, check, gate, packet, focus, chore. A **lesson** is something kept from the run so later runs go better.

## Read the whole run

All of it is in the run folder (paths below the brief). Read, in this order:

1. `state.json`: the plan, each ticket's attempts, `failures`, `verifications`, `evidence`, `cost_usd` against `plan.tickets.<t>.estimate_usd`, `decisions` (gate actions, redirects, exceptions: who decided and what), `findings`, `relays`, `lessons` (slicing lessons the sweep noted), `orchestrators`, `halted`, and the `events` log. The schema: `references/state-file.md` in the plugin.
2. `results/`: each attempt's result file (the worker's evidence record, with its decisions and what it was unsure of) and exit record; `results/verify-*` the verifiers' verdicts; `results/findings/`.
3. `verify/`, `merges/` (suite logs), `prompts/*.failure.md` (why retries happened).
4. Deferrals and bypasses: deferred tickets and questions (`tickets.<t>.questions`, events `deferred-question`, `pulled`), and any decision with a `redirect` or a guardrail bypass and its reason.
5. The facts and signals already computed (`retro/facts.json`): don't recompute them.
6. Triage misses since the last retro (`retro/misses.jsonl`): uncontroversial recommendations the Artisan reversed, each with the controversy criterion that should have caught it.
7. The chat log, if one is given: what the Artisan asked, corrected, redirected, repeated or typed by hand.
8. The project's `CODING_STANDARDS.md`, `PRODUCT_STANDARDS.md`, `GLOSSARY.md`, `docs/adr/` and `.artisan-agent/config.yml`, so a lesson doesn't repeat what is already there.

Use `git log`/`git show` on the run's integration branch and `gh issue view` for ticket text when you need it. Read only.

## What to look for

Mirror upstream's retro categories, across both roles:

| Category | Ask of the run |
|---|---|
| Navigation | Where did a worker or the chat look in the wrong place, or take long to find something? |
| Checks | What failed late that a check would have caught early? What check passed while the work was wrong? |
| Coding standards | What did the Artisan or a verifier correct that a written standard would have prevented? |
| Steering files | Which brief, skill, standards file or ADR misled, or said nothing where it should have? |
| Tool economy | Where did cost run over the estimate, attempts repeat, or a session spend tokens on nothing? |
| No-ops | What step was done and changed nothing (a confirmation, a relay, a re-read)? Those are chores. |
| Information access | What did a worker need that it couldn't reach (a doc, a decision, a credential, a ticket)? |

Also: decisions agents made alone that no gate showed (name up to three worth a spot-check); patterns in discards and deferrals; a worker that stopped for design (a slicing lesson); each triage miss, with its criterion; anything upstream (`mattpocock-skills`) did that we depend on and that moved.

Propose a lesson only with evidence from this run. One clean run is a fine result: write an empty `lessons` list and say so in `summary`.

## Each lesson

Every lesson has a kind, and the kind decides its home:

| `kind` | Home | `change` |
|---|---|---|
| `mechanical` | a check (lint rule, test, hook, CI job) | `{path, text, section?, replace?}`: the check itself |
| `engineering-taste` | coding standards | `{path: "CODING_STANDARDS.md", section, text}` |
| `product-taste` | product standards | `{path: "PRODUCT_STANDARDS.md", section, text}` |
| `domain` | the glossary or an ADR | `{path: "GLOSSARY.md" or "docs/adr/<n>-<slug>.md", section?, text, replace?}` |
| `calibration` | the project's config numbers, including estimate multipliers | `{key, value}`: a key from `templates/config.yml`, at most one level of nesting |
| `pipeline` | a ticket in arathianevasion/artisan-agent | none; give `ticket: {title, body}` |
| `upstream` | the upstream check | none |
| `experience` | the satisfaction record | none |

A **taste lesson a machine can check becomes a check**: if a rule from coding standards, product standards or the glossary could be enforced by a lint rule, test, hook or CI job, set `checkable: true` and give the check as the `change`. Keep project paths relative; `section` is a markdown heading such as `## Always ask`; `text` is added at the end of that section (the file and section are made if missing), or replaces the file when `replace` is true.

Fields, all required unless marked:

```json
{
  "summary": "Two sentences, problem first: what this run solved and for whom, and what it taught about the problem.",
  "lessons": [
    {
      "id": "L1",
      "kind": "engineering-taste",
      "lesson": "One line, as it would read in its home.",
      "role": "engineering | product | both",
      "scope": "this-project | generalises",
      "why": "The evidence from this run, in one sentence, naming tickets.",
      "evidence": ["#12 verifier fail", "#14 redirect at the slice gate"],
      "checkable": false,
      "change": {"path": "CODING_STANDARDS.md", "section": "## Guardrails", "text": "- ..."},
      "ticket": {"title": "...", "body": "..."},
      "move": "tighten | loosen | retire",
      "ask": "batch | question",
      "question": "Only for a judgement call: the question, one line.",
      "recommendation": "Your answer to it, and why.",
      "alternative": "The strongest alternative you rejected."
    }
  ]
}
```

`move` only for a lesson that moves a guardrail or gate. `evidence` counts events: a calibration with fewer events than the evidence threshold is thin.

**Batch or question.** Obvious lessons are batched for one "yes", one line each. Only judgement calls are questions: whether a lesson generalises beyond this project (mark it `generalises` and say whether you checked it holds elsewhere); loosening, tightening or retiring a guardrail; calibration on thin evidence. The script enforces this: it turns those into questions whatever you say, and keeps the rest batched.

**Role.** Tag each lesson with the role whose job it touches (jobs in `references/jobs.md`): product for what to build and why, engineering for how it's built.

## The Artisan's actions

Also write every action the Artisan took during the run that the state file doesn't hold (from the chat log): one JSON object per line, `{"what": "...", "job": <number from references/jobs.md, if one fits>, "focus": "problem | solution | pipeline | chore"}`. An action that serves no focus (confirming, relaying, retyping, asking for status the pipeline could have shown) is a `chore`. Write an empty file when there is no chat log.

## Hand back

Write the lessons as one JSON object (above) to the lessons path, and the actions to the actions path. Both paths are given below. Then end with one line: `retro prepared: <n> lessons`.
