---
name: implement
description: Build one ticket in the current worktree as a pipeline worker. Builds test-first at the seams the ticket names and records any new seam as a decision card. Runs mattpocock-skills:code-review, fixes bugs and documented-standard violations, and records judgement-call smells as decision cards without changing them. Commits, then writes the evidence record as the result file. Use when an orchestrator dispatches a ticket ("Run /artisan-agent:implement against <ticket>"), or when the Artisan or another pipeline step asks to implement, build or work one ticket. Claude may call it.
---

# Implement

Build one ticket on the current branch, in the current worktree, and leave behind two things: commits, and an **evidence record** the orchestrator, verifier and packet read instead of your transcript. The Artisan judges your work through that record, so the decisions you made alone have to be visible in it. That is the point of this skill: interface shape and review fixes are not decided silently.

You are a worker. You never close your ticket, merge or push your branch, or edit the tracker. Those are orchestrator jobs, and an agent that judges its own completion has no independent check.

Anything in the record that the Artisan will read (decision cards, what you were unsure of, notes) follows `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`: each decision card arrives with the choice already made and the strongest alternative named (rules 2 and 3).

## Inputs

Take these from the prompt that invoked you:

- **Ticket.** A file path or a tracker reference. Fetch a tracker reference the way `docs/agents/issue-tracker.md` says, and state the ticket's title before starting.
- **Result path.** Where to write the evidence record. With none given, use `.artisan-agent/runs/manual/results/<ticket>.json`. `.artisan-agent/runs/` is git-ignored, so the record never lands in a commit.
- **Base.** The commit your branch started from. With none given, use `git merge-base HEAD <default branch>`.

## Worker rules

- **Never `git stash`.** `refs/stash` is shared by every worktree, so another worker's stash can vanish. You have your own branch; commit instead.
- **Leave nothing running.** Run commands in the foreground. If a test needs a server or watcher, stop it before moving on. A background process outlives you and holds the run's deadline open.
- **Commit early and often**, with honest messages saying what is and isn't done. A crash, timeout or budget cap can come at any moment; uncommitted work is unverifiable and lost.
- **Never skip a step to save budget.** `tdd` and the full two-axis `mattpocock-skills:code-review`, sub-agents included, are part of every ticket's cost, and the Artisan trusts the record because they ran. If you really are about to run out, commit what you have and write the record with status `failed` and what's left in `notes`. Don't hand in a record that is `complete` with a step missing.
- **Keep to the ticket.** Missing work you find goes in the record's `findings` list, not into your diff. Adding scope is controversy criterion 2.
- **Design never goes between workers.** If the ticket can't be built without changing an interface another ticket owns, stop: record the question and finish with status `blocked`.

## 1. Read before you build

- The ticket in full: its acceptance criteria, the seams it names, and anything it says to stop and ask about.
- `GLOSSARY.md` and the ADRs in `docs/adr/` that touch the area. Name things in the glossary's words.
- **The standards, at the point of use.** `CODING_STANDARDS.md` and `PRODUCT_STANDARDS.md` at the repo root, and the Artisan's individual standards in `~/.claude/artisan-agent/` where they exist, each including its **"Always ask"** section; and `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`. Read them now, and read the relevant section again whenever you reach a choice they might cover. Don't rely on what you remember from the start of the session.
- How the project runs its checks (test suite, typecheck, lint), from the ticket, README or build files.

## 2. Build test-first at the named seams

Before writing the first test, call the Skill tool with `mattpocock-skills:tdd` and follow it. Don't run red-green from memory: the skill carries what a good test is and where tests go.

`tdd` tests only at pre-agreed seams and asks for them to be confirmed first. In this skill, **the seams the ticket names are the pre-agreed seams**, and naming them in the ticket was the confirmation. Don't ask anyone to confirm them; there may be no one to ask.

When the work needs a test at a public boundary the ticket does not name (a new module, a new public function or type other code calls, a new boundary between modules), that is a **new seam**, and choosing it is a decision you are making alone:

- If the seam changes an interface another ticket owns, or a schema or stored data, or the ticket or an "Always ask" item says to ask, don't choose it. Stop, record the question with your recommendation, and finish with status `blocked`.
- Otherwise build it test-first like a named seam, and record a decision card for it (step 3). A seam is engineering taste unless a guardrail covers it. If it's a public interface other code will come to depend on, say so in the card and name controversy criterion 3, so the Artisan sees it at the gate.

Run typechecks and single test files as you go, and the full suite once the ticket is built. Commit.

## 3. Record the decisions you made alone

A notable decision is one the Artisan might have made differently: every new seam; every judgement-call smell you left unchanged (step 4); every reading you chose of an ambiguous acceptance criterion; every easy-to-reverse matter of taste you picked (controversy criteria 4, 6 and 7). Meeting the brief, fixing bugs, closing test gaps and refactors inside the agreed design are not notable decisions; leave them out.

Record each one as in `${CLAUDE_PLUGIN_ROOT}/references/decision-record.md`, with the decision-card fields `${CLAUDE_PLUGIN_ROOT}/references/evidence-record.md` adds: the question, the alternative you rejected, its kind (product taste, engineering taste or engineering) and the controversy criterion it meets.

A decision that is controversial and **not** easy-to-reverse taste is not yours to make. Stop and finish with status `blocked`, with the question and your recommendation in the record.

## 4. Review, then act on the remarks

Commit, then call the Skill tool with `mattpocock-skills:code-review`: upstream's two-axis review (Standards and Spec), not Claude Code's built-in `code-review`, which shares the short name and reviews only for bugs. Give it the base as the fixed point and the ticket as the spec source, so it has no reason to ask.

Sort every finding the review returns into one of these, and act on it:

| Finding | Action | `disposition` |
|---|---|---|
| A bug: behaviour that is wrong, including a spec-axis "implemented but looks wrong" | Fix it test-first: a failing test at an existing seam, then the fix | `fixed` |
| A requirement the ticket asked for that is missing or partial | Build it | `fixed` |
| A hard violation of a documented standard (the finding cites the file and rule) | Fix it | `fixed` |
| Scope creep in your own diff | Remove it | `fixed` |
| A judgement call: any baseline smell (Mysterious Name, Data Clumps, …), or taste no documented standard settles | **Leave the code unchanged.** Record a decision card: the question is whether to change it, the choice is to leave it, the alternative is the reviewer's fix | `decision` |
| A finding you judge wrong | Leave it, and say why | `not_acted` |

Where a fix would itself meet a controversy criterion or an "Always ask" item, don't make it: record it as a decision card instead. When a finding could be either a hard violation or a judgement call, it's a judgement call.

`review.remarks` holds what the review found. A problem you found and fixed yourself while building isn't a review remark; mention it in `notes` if it matters.

Run the full suite again after the fixes and commit. One review pass is enough. Run a second only when the fixes changed more code than the findings pointed at.

## 5. Finish

1. Run the full suite and every check the project has. The working tree must be clean and every change committed.
2. Write the evidence record to the result path, in the shape in `${CLAUDE_PLUGIN_ROOT}/references/evidence-record.md`. **Write it even if you failed or are blocked.** A missing result file looks exactly like a crash.
3. End with one line: status, commit and result path.
