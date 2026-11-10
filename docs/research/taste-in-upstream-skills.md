# Taste decisions inside upstream mattpocock-skills

Research for ticket #22, "Which of Matt's skills decide taste inside their own steps?" (map #1). It applies the test in [ADR 0001](../adr/0001-layer-on-matt-pocock-skills.md): replace an upstream skill only where an agent decides a matter of **Taste** inside the skill's own steps and no **Guardrail** or human checkpoint can reach the decision.

## Answer

Most of the library already puts taste in front of a person. The decisions with no seam sit in **`implement-spec`**: it merges branches, applies review fixes, and runs `tdd` in background subagents that cannot reach the user. Two smaller gaps exist: `to-spec` publishes the spec without showing it to the user, and `to-tickets` publishes acceptance criteria that the user never saw.

One correction to the brief. `docs/wayfinder-brief.md:60` says "`/to-tickets` is black, but slicing work is a matter of engineering taste." Upstream `to-tickets` already has a human checkpoint on slicing: "Iterate until the user approves the breakdown." (`to-tickets/SKILL.md:56`).

### Category (c) replacement candidates

| # | Skill | Taste decision | Source |
|---|---|---|---|
| 1 | `implement-spec` | Merge conflicts between ticket branches are resolved by an agent | `implement-spec/SKILL.md:32` |
| 2 | `implement-spec` | An agent decides how to fix every code-review finding, including judgement-call smells | `implement-spec/SKILL.md:36` |
| 3 | `implement-spec` | Background implementers run `tdd`, whose seam checkpoint cannot reach a person, so seams and interface shape are picked by the agent | `implement-spec/SKILL.md:17`, `:29`; `tdd/SKILL.md:22` |
| 4 | `to-spec` | Implementation decisions, user stories, and out-of-scope items are written and published `ready-for-agent` without review | `to-spec/SKILL.md:7`, `:19` |
| 5 | `to-tickets` (minor) | Acceptance criteria are written at publish time and never shown in the quiz | `to-tickets/SKILL.md:44-48` vs `:94-97` |
| 6 | `implement` (minor) | What to do with code-review findings is unspecified before the commit | `implement/SKILL.md:15-17` |

Candidates 1 to 3 are one skill, and the owner already has a replacement for it (`implement-plan`). Candidates 4 to 6 are narrow enough that a guardrail or the owner's own `/to-plan` step may cover them without a replacement. That is a decision for a later ticket.

## Method and sources

- **Installed copy:** `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.3.1/`. Every skill listed in `.claude-plugin/plugin.json` (27 skills) was read in full, including the reference files each one links to. The paths below are relative to `skills/` in that copy, so `to-tickets/SKILL.md` means `skills/engineering/to-tickets/SKILL.md`, and productivity skills are named `productivity/...`.
- **Upstream:** `github.com/mattpocock/skills`, fetched with `gh api` on 2026-11-10 at tags `v1.3.1` and `v1.3.2` and on `main`.
- **Version note:** the installed "1.3.1" cache matches neither tag. It differs from the `v1.3.1` tag in 14 skill files and from `v1.3.2` in 10. It already has the v1.3.2 text for `to-tickets`, `tdd`, `implement`, `diagnosing-bugs` and `ask-matt`.
- **Installed compared with `main`:** the differences are in 10 files. None of them adds or removes a taste checkpoint:
  - "Start every sub-agent with a fresh context window" or similar wording, added to `code-review`, `research`, `wayfinder`, `improve-codebase-architecture`, `codebase-design/DESIGN-IT-TWICE.md`, `implement-spec` and `grilling`.
  - `implement-spec` step 4 becomes "Use a fresh **implementer subagent** for each ticket" (`main`, commit set `.changeset/implementer-fresh-per-ticket.md`).
  - `setup-matt-pocock-skills` gains a legacy `CONTEXT.md` to `GLOSSARY.md` migration offer and repo-remote wiring.
  - `main` lists the same 27 skills in `plugin.json`.
- **Merge conflicts upstream:** the dedicated merge skill is gone. `docs/engineering/resolving-merge-conflicts.md:1` says: "**Archived.** This skill was removed from the plugin in v1.3.0 … Nothing replaces it: the agent works through a merge or rebase conflict without a dedicated skill."

## Classification key

- **(a) Human checkpoint:** a person sees or approves the decision before it counts.
- **(b) Guardrail seam:** the step reads a project guardrail (`CLAUDE.md`, `docs/agents/*`, ADRs, `GLOSSARY.md`, hooks), or says "unless instructed otherwise", so a guardrail can steer it.
- **(c) No seam:** a replacement candidate.

## Per-skill findings

### Planning and specs

**`to-spec`**
- **Test seams (a).** "Sketch out the seams at which you're going to test the feature." (`to-spec/SKILL.md:15`) and "Check with the user that these seams match their expectations." (`:17`)
- **Vocabulary and prior decisions (b).** "Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching." (`:13`)
- **Everything else in the spec (c).** "Do NOT interview the user; just synthesize what you already know." (`:7`) and "publish it to the project issue tracker. Apply the `ready-for-agent` triage label - no need for additional triage." (`:19`). The template asks for "Architectural decisions", "Schema changes" and "API contracts" (`:50-52`) and an "Out of Scope" list (`:67-69`). Anything the conversation left open is filled in by the agent and published with no review. The wording "implementation decisions that were made" (`:45`) means the spec should record decisions already taken, but no step checks that it does.

**`to-tickets`**
- **Slicing, granularity and blocking edges (a).** "Ask the user: Does the granularity feel right? … Should any tickets be merged or split further? Iterate until the user approves the breakdown." (`to-tickets/SKILL.md:50-56`)
- **Prefactoring (a).** "Look for opportunities to prefactor the code" (`:23`). The prefactor tickets go through the same quiz.
- **Wide refactors (a).** Wide refactors are sequenced as expand-contract (`:40`). The sequence is part of the breakdown the user approves.
- **Vocabulary and prior decisions (b).** "Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs" (`:21`).
- **Label (b).** "Apply the `ready-for-agent` triage label unless instructed otherwise" (`:63`).
- **Acceptance criteria (c, minor).** The quiz shows only "**Title** … **Blocked by** … **What it delivers**" (`:46-48`). The published template adds "## Acceptance criteria" (`:94-97`), which the agent writes after approval. Acceptance criteria define "done", so they carry taste.

**`wayfinder`**
- **Destination and frontier (a).** These are charted by grilling: "Call the Skill tool twice, for 'grilling' and 'domain-modeling'" (`wayfinder/SKILL.md:111-112`).
- **Human-in-the-loop tickets (a).** "A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it" (`:75`).
- **Standing preferences (b).** The map's Notes block holds "standing preferences for this effort" (`:38`). Each session must "call the Skill tool for whichever skills the `## Notes` block names" (`:124`).
- **Map edits after an AFK ticket (b).** After a Research (AFK) or Task (AFK) ticket, step 5 lets the agent "graduate any fog", "rule it out of scope", and "update or delete those tickets" (`:126`) with no person present. The Notes block is the seam for steering this. Scoping is a taste act, so this is a borderline (c).

**`triage`**
- **Category and state (a).** "Tell the maintainer your category and state recommendation with reasoning … Wait for direction." (`triage/SKILL.md:72`)
- **Shaping the request (a).** "call the Skill tool twice, for 'grilling' and 'domain-modeling'" (`:76`).
- **Rejection (a).** "Maintainer decides a feature request is out of scope" (`triage/OUT-OF-SCOPE.md:92`). Prior rejections are surfaced as "Do you still feel the same way?" (`:76`).
- **Vocabulary and prior decisions (b).** "Explore the codebase using the project's domain glossary, respecting ADRs in the area." (`triage/SKILL.md:70`)
- **Agent brief text (a, with a caveat).** The brief is posted at step 5 (`:79`) after the maintainer gave direction, but the brief text itself is not shown before posting.
- **Downstream note.** The brief tells the implementer that "The agent will explore the codebase fresh and make its own implementation decisions." (`triage/AGENT-BRIEF.md:21`). Those decisions then fall to `implement` or `implement-spec`.

### Building

**`implement`**
- **Test seams (a/b).** "Call the Skill tool with 'tdd' where possible, at pre-agreed seams." (`implement/SKILL.md:11`)
- **Review findings (c, minor).** "Once done, call the Skill tool with 'code-review' to review the work. Commit your work to the current branch." (`:15-17`). The skill does not say who decides which findings to act on. In practice the agent decides.

**`implement-spec`**
- **Seams in background implementers (c).** "**Implementer subagents** should be run in the background where possible" (`implement-spec/SKILL.md:17`). Each one "calls the Skill tool with `tdd` to build the ticket" (`:29`). `tdd` demands "Before writing any test, write down the seams under test and confirm them with the user." (`tdd/SKILL.md:22`), but a background subagent has no user to confirm with. Unless `to-spec` already recorded the seams, the implementer picks seams and interface shape itself.
- **Merging (c).** "Once an **implementer subagent** completes, merge its work to the integration branch with a **merger subagent**." (`implement-spec/SKILL.md:32`). Conflict resolution chooses between two intents. No guardrail is read, there is no checkpoint, and upstream archived the merge skill (`docs/engineering/resolving-merge-conflicts.md:1`).
- **Review fixes (c).** "Fix all issues raised by the code review in a single **implementer subagent**." (`implement-spec/SKILL.md:36`). `code-review` says its smells are "Always a judgement call" (`code-review/SKILL.md:41`), yet `implement-spec` fixes them all with no person choosing.
- **Final review (a, after the fact).** "If a draft PR exists, mark it ready for review." (`implement-spec/SKILL.md:38`). This gives a human review, but only once the decisions are already in the code. Without a PR the skill instead resolves "each ticket the way the issue tracker closes work", with no human step.

**`tdd`**
- **Test seams (a when a person is present, c inside `implement-spec`).** "No test is written at an unconfirmed seam." (`tdd/SKILL.md:22`)
- **Interface shape (b).** "When the shape of that interface is itself in question … call the Skill tool with 'codebase-design' for the vocabulary … a reference to consult, not a session to run." (`:26`). The agent decides the shape alone. The guardrail seam is "read `GLOSSARY.md` … and respect ADRs in the area you're touching" (`:10`).

**`diagnosing-bugs`**
- **Hypothesis ranking (a, partial).** "**Show the ranked list to the user before testing.** … Don't block on it; proceed with your ranking if the user is AFK." (`diagnosing-bugs/SKILL.md:98`)
- **Fix design and regression-test seam (b).** These are covered by "read `GLOSSARY.md` … and check ADRs in the area you're touching" (`:10`). "If no correct seam exists, that itself is the finding. Note it." (`:120`)

**`code-review`**
- **No decision (b).** The skill reports and does not decide: "Do **not** merge or rerank findings" (`code-review/SKILL.md:78`). Its smell baseline yields to the project: "**The repo overrides.** A documented repo standard always wins" (`:40`).
- **Inputs (a).** The fixed point and spec source are asked for when missing (`:19`, `:32`).

**`pr`**
- **Summary visuals and merge danger (a).** The agent uses judgement for the summary visuals ("Use your judgement", `pr/SKILL.md:156`) and for the door call (`:168`). The PR is written for a human reviewer, which is the checkpoint.
- **Vocabulary (b).** "Use the user's domain language from `GLOSSARY.md`" (`:37`).

### Design and architecture

**`improve-codebase-architecture`**
- **Where to look (no checkpoint, low stakes).** If the user gave no direction, the agent picks where to look from `git log` hot spots (`improve-codebase-architecture/SKILL.md:22-23`). It only produces a report.
- **Candidates and top recommendation (a).** "Do NOT propose interfaces yet. After the file is written, ask the user: 'Which of these would you like to explore?'" (`:60`)
- **Prior decisions (b).** "ADRs in `docs/adr/` record decisions this command should not re-litigate" (`:14`). See also `:25` and `:56`.
- **Shape of the deepened module (a).** This is decided in a grilling loop: "call the Skill tool with 'grilling' to walk the decision tree with them" (`:64`).

**`codebase-design`** (reference only, model-invoked)
- **Design options (a).** It holds no step of its own except Design It Twice. There, the agent frames the problem: "Show this to the user, then immediately proceed to Step 2." (`codebase-design/DESIGN-IT-TWICE.md:17`). It then recommends: "Be opinionated: the user wants a strong read, not a menu." (`:44`). The user receives the comparison and decides.
- **Taste fixed by upstream.** The principles are Matt's own taste, written into the skill, for example "One adapter means a hypothetical seam. Two adapters means a real one." (`codebase-design/SKILL.md:65`). They are not an agent's decision, but no line lets a project ADR override them. That gap matters only if the owner's taste differs.

**`prototype`**
- **Which branch to build (a, with a fallback).** "If the question is genuinely ambiguous and the user isn't reachable, default to whichever branch better matches the surrounding code … and state the assumption at the top of the prototype." (`prototype/SKILL.md:17`)
- **Folding the result in (a).** The winner is chosen by the user: "The user flips between variants in the browser, picks one" (`prototype/UI.md:3`). Only "any validated decision" folds into real code (`prototype/SKILL.md:26`).

**`domain-modeling`** and **`grill-with-docs`**
- **Terms (a).** Terms are put to the user: "propose a precise canonical term" (`domain-modeling/SKILL.md:50`). The glossary is updated "When a term is resolved" (`:62`).
- **ADRs (a).** ADRs are offered, never imposed: "Only offer to create an ADR when all three are true" (`:68`).
- **Wrapper.** `grill-with-docs` is only "Call the Skill tool twice, for 'grilling' and 'domain-modeling'." (`grill-with-docs/SKILL.md:7`)

**`grilling`** and **`grill-me`**
- **Decisions (a).** "The _decisions_ are the user's: put each to them and wait." (`productivity/grilling/SKILL.md:28`) and "Do not act on it until the user confirms" (`:30`).

### Setup, environment and other skills

**`setup-matt-pocock-skills`**
- **Configuration (a).** "Explore, present what you found, confirm with the user, then write." (`setup-matt-pocock-skills/SKILL.md:15`)

**`retro`**
- **Improvement candidates (a).** "Present these candidates to the user, in order of severity." (`retro/SKILL.md:25`)

**`wizard`**
- **Stages (a).** "show the user the ordered list of stages … and confirm: they may add, drop, or reorder." (`wizard/SKILL.md:23`)

**`research`**
- **No taste decision.** The skill gathers facts only.
- **Where the notes go (b).** "Save it where the repo already keeps such notes; match the existing convention" (`research/SKILL.md:12`).

**`ask-matt`**
- **No decision.** It is a router, and the user asks it a question. It names its own content as taste for the user to apply: "These are judgement calls" (`ask-matt/PHASE-BOUNDARIES.md:53-55`).

**`handoff`**, **`teach`**, **`to-questionnaire`**, **`wait-what`** and **`writing-for-agents`**
- **No product or engineering taste is decided.**
  - `teach` confirms before changing the mission ("Confirm with the user before changing the mission.", `productivity/teach/SKILL.md:79`).
  - `to-questionnaire` grills the user about the send (`productivity/to-questionnaire/SKILL.md:9`).
  - The other three are summaries or reference material.

## Observations for later tickets

- **The decisions with no seam are all at build time, not planning time.** They are merging, applying review fixes, and choosing seams with no person present. Upstream planning skills (grilling, `to-tickets`, wayfinder, triage) consistently hand decisions to a person.
- **`tdd` assumes a person is present, and `implement-spec` assumes none is.** Any orchestrator the owner writes needs to settle seams before dispatch, for example in the spec or the ticket, or carry them as a guardrail.
- **`codebase-design` principles cannot be overridden by the project.** If the owner disagrees with one of them, an ADR will not override it, because the skill reads no project file. That would need an override line or a replacement.
