---
name: retro
description: The retro after every run, in the Engineering chat. A fresh headless session reads the whole run and prepares lessons; the Artisan answers one chat round (obvious lessons batched for one "yes", only judgement calls as questions, the run's signals, their motivation for the product and the satisfaction questions). Kept lessons go to their homes - one project PR, individual-home commits with origin, pipeline tickets, upstream notes - and the answers to the private satisfaction record. Replaces upstream retro. Use after a run ends, or when the Artisan says "retro", "what did we learn", or runs /artisan-agent:retro.
---

# Retro

One joint retro per run, for Product and Engineering, run from the Engineering chat once a run has ended (done or halted). It keeps what the run taught while it is fresh and asks how the run felt. It replaces upstream `retro` and mirrors its categories: navigation, checks, coding standards, steering files, tool economy, no-ops, information access.

Follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md` for everything you put in front of the Artisan. Every list of tickets is a markdown table. Use `GLOSSARY.md` vocabulary (lesson, check, gate, guardrail, focus, chore, individual home, motivation, satisfaction record) and respect `docs/adr/`.

**Nothing changes until the Artisan answers.** The preparer only proposes; the script delivers only lessons the Artisan kept. There is no retro issue: the project PR is the record, and merging it is the approval.

The script is `${CLAUDE_PLUGIN_ROOT}/skills/retro/scripts/retro.sh` (usage at its top; run it with `bash`). Below, `retro` means `bash "${CLAUDE_PLUGIN_ROOT}/skills/retro/scripts/retro.sh"` and `<run>` the run folder (`${CLAUDE_PLUGIN_ROOT}/scripts/state.sh run-dir <run-id>`).

## Steps

1. **Prepare, headless.** `retro prepare <run> --chat-log <this chat's transcript>` (the transcript is the one the plugin's start-up line named). It runs a fresh capped `claude -p` (default `claude-sonnet-5-5`, `--max-budget-usd 1.00`) with `PREPARE.md` as its brief, which reads the whole run (state file, packets and gate actions, redirects, bypasses, deferrals, exit records, verifier results, findings, cost against estimate, triage misses since the last retro, the chat log) and writes `retro/lessons.json` and the Artisan's actions. Then the script computes the facts and checks the lessons. Run it as a background command; it takes a few minutes. Don't read the run yourself: your context is for the Artisan's answers. If the check reports problems, run `prepare` once more; if it fails again, tell the Artisan in one line and carry on with the satisfaction questions alone.
2. **Ask, in one chat round.** `retro render <run>`, shown as printed. It leads with what the run solved, then:
   - **Lessons to keep**: the obvious ones in one table, one line each, with home, role and reach (this-project or generalises), for one "yes".
   - **Judgement calls**, as questions with a recommendation: whether a lesson generalises; loosening, tightening or retiring a guardrail; calibration on thin evidence.
   - **Guardrail health and audits** (`${CLAUDE_PLUGIN_ROOT}/references/guardrail-health.md`): run `guardrail-health.sh health --table`, `audit --table` and `backstop --table` over the run history and show them as printed: each guardrail fired, bypassed or never fired with its origin, the loosen or tighten moves at the threshold (a judgement call each, with the evidence shown), counted misses and repeated discards with a suggested criterion or guardrail, and anything the backstop flagged. Spot-check about three unshown decisions (`spot-check`), recording each answer. After a hands-on ticket ask the `hands-on` question; show its nudge when it has one. A kept loosening is delivered with `guardrails.sh loosen`; the scope floor and defer-only gates are never offered.
   - **Signals**: shares of the Artisan's actions by focus (problem, solution, pipeline, chores), the rubber-stamp rate at gates, throughput, and cost per merged ticket against the estimate.
   - **How did this run feel?**: the Artisan's motivation for this product, when one is recorded, above the satisfaction questions (`ARTISAN.md`, "Retro questions", or the individual home's `ARTISAN.md` where it tunes them): three 1–5 scores with an optional sentence, "skip" kept as a skip, and the free-text chore question. With no motivation recorded the questions run unchanged.

   On a smooth run (no lessons) it says **"Nothing to learn from this run."** and goes straight to the signals and the satisfaction questions.
3. **Write down the answers**, from the Artisan's one reply, in the run folder:
   - `retro/decisions.json`: `{"<id>": "yes" | "no" | "this-project"}` for every lesson. "Yes to all" is `yes` for every batched lesson. For a generalises question, `yes` keeps and promotes it, `this-project` keeps it here only.
   - `retro/answers.json`: `{"problem": {"score": 1-5 or "skip", "comment": "..."}, "solution": {...}, "pipeline": {...}, "chores": "..."}`.
4. **Record the satisfaction answers:** `retro satisfaction <run> retro/answers.json`. It appends one line to `satisfaction.jsonl` in the individual home (date, project, run, scores, comments, chores and the run's facts) and commits it there; it never touches the project. It prints:
   - `why <question> <reason>`: a score of 2 or less, or a fall of 1 or more over three runs. Ask "why?" for all of them in one message, then add each answer as a lesson in their words: `retro add-lesson <run> '{"kind": "...", "lesson": "...", "role": "...", "scope": "this-project", "why": "<question> scored <n>"}'`, choosing the kind (and so the home) from what they said; `experience` when it is about how the run felt.
   - `chore <text>`: each chore named becomes a pipeline lesson, kept without asking again (ARTISAN.md rule 6: they already said it).
5. **Offer to update the motivation** only when the answers suggest it has changed (a comment about why they care that no longer matches the recorded words). Propose the new wording, with your reason. Only on yes: `printf '%s' "<their words>" | retro motivation <run> update`, which commits it to the individual home.
6. **Prove each new check fails.** For every kept `mechanical` lesson, first `retro deliver <run> retro/decisions.json` (no `--pr`): it makes the branch `retro/<run-id>` in a worktree beside the repo, `<repo>-wt/retro-<run-id>`. Then prove each check there with `bash ${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/project-setup.sh prove-check --ref retro/<run-id> --break "<edit>" -- <check>` (PROJECT.md, "Proving a check fails"). A check that can't fail isn't trusted: tell the Artisan and leave it out (`git revert` its commit in the worktree).
7. **Deliver:** `retro deliver <run> retro/decisions.json --pr`. Kept lessons land in their homes (below), each with its origin (run, date, role, the evidence). Rerunning it delivers nothing twice.
8. **Report** in one table: lesson, home, where it landed (the PR link, the individual-home commit, the ticket link). Then the satisfaction triggers handled and the motivation, if updated.

## Homes

| Kind | Home | Delivered as |
|---|---|---|
| Mechanical | a check (lint rule, test, hook, CI job) | a commit in the project PR |
| Engineering taste | coding standards | a commit in the project PR |
| Product taste | product standards | a commit in the project PR |
| Domain | the glossary or an ADR | a commit in the project PR |
| Calibration | the project's config numbers, including estimate multipliers | a commit in the project PR (`.artisan-agent/config.yml`) |
| Pipeline | a ticket in arathianevasion/artisan-agent | a `needs-triage` ticket there |
| Upstream | the upstream check | a note in the individual home's `upstream-notes.md`, committed |
| Artisan experience | the satisfaction record | a `lesson` line in `satisfaction.jsonl`, committed |

A taste lesson a machine can check becomes a check: the script moves an engineering-taste, product-taste or domain lesson marked `checkable` to the check home. A taste or check lesson marked generalises that the Artisan confirms is also promoted: a commit with its origin in the individual home, under `## Lessons` in `CODING_STANDARDS.md` or `PRODUCT_STANDARDS.md`, or, for a check, under `## Checks` in `CODING_STANDARDS.md` naming the check's file so the next project can take it. Pipeline lessons generalise as tickets already; domain and calibration lessons stay with the project. Team-level promotion is by PR to the team guardrails repo with `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh tighten --level team ... --pr`, when the Artisan asks for it.

## Pairs

Lessons are tagged by role. In a pair, each person keeps or drops their own role's lessons, and the product PR is merged by the role that owns it (`${CLAUDE_PLUGIN_ROOT}/WORKING-AS-A-PAIR.md`). Satisfaction answers stay private: each person records their own, in their own individual home.

## Files

In the run folder's `retro/` (git-ignored with the run folder):

| File | Written by | What |
|---|---|---|
| `facts.json` | `facts` | the run's facts and signals |
| `misses.jsonl` | `facts` | triage misses newer than the last retro |
| `prompt.md`, `session.json`, `session.err` | `prepare` | the preparer's prompt and output |
| `lessons.json`, `actions.jsonl` | the preparer | proposed lessons (shape in `PREPARE.md`) and the Artisan's actions from the chat log |
| `added.jsonl` | `add-lesson`, `satisfaction` | lessons in the Artisan's own words: "why?" answers and chores |
| `checked.json` | `check` | every lesson with its home, delivery, and batch or question |
| `decisions.json`, `answers.json` | the chat | the Artisan's answers |
| `triggers.json` | `satisfaction` | the "why?" prompts and chores |
| `delivered.jsonl` | `deliver` | what landed where; a rerun skips these |

In the main checkout, `.artisan-agent/retro/last` (ignored by its own `.gitignore`) is when the last retro delivered: the next one reads only triage misses newer than it.

How the signals are counted (`retro.py facts`): the Artisan's actions are the decisions a person made in the state file (not an agent's), each triage miss (job 18), and the actions the preparer found in the chat log. Each counts for the focus of its job in `${CLAUDE_PLUGIN_ROOT}/references/jobs.md` (a decision with no job takes its kind's: exception 15, design 3, risk gate 13); one that names no job serves no focus and counts as a chore. A gate decision approved (its choice approve, clear or pass) with no redirect and no change is a rubber stamp. Throughput is merged tickets over the hours from the first dispatch to the last merge. Cost per merged ticket is the run's total cost over its merged tickets.

Tests: `tests/retro.test.sh`, on a seeded sample run with a throwaway individual home, the fake tracker and a stub `claude`.
