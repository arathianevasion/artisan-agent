# Wayfinder brief: an agentic delivery workflow people are glad to use

Input for charting the first `/wayfinder` map in this repo. Written 2026-11-09.

The brief separates what the owner has decided from what is only recommended. Grill the recommendations. Don't treat them as settled.

## The idea

Build a reusable delivery workflow for the owner's projects, on top of Matt Pocock's skills, with the owner's own skills and system prompts capturing what past projects taught.

Agents do most of the delivery. Humans set the guardrails and supply product and engineering taste. An engineer or product manager using it should come away with satisfaction and self-worth, so the design is grounded in **autonomy, mastery and purpose**.

The starting point is the owner's diagram: `docs/source/agentic-delivery-workflow.png` (the PDF beside it is the original).

## Proposed destination

A version-one spec, ready for `/to-spec` and `/to-tickets`, for a plugin and project template that:

- runs the diagram's flow on a real project;
- names who decides what at each step, and why that step needs a person;
- turns lessons from each run into lasting guardrails.

Settle this first, as wayfinder requires. The map plans; it doesn't build.

## Decided by the owner

- Box colours mean: **red** human-led, **blue** agent-led and human-approved, **black** fully autonomous.
- Matt Pocock's skills are the base, supplemented by the owner's skills and system prompts.
- Human involvement is what establishes guardrails and taste. It isn't a formality.
- The test of the design includes how it feels to use: satisfaction and self-worth, through autonomy, mastery and purpose.
- This work lives in this repo, private, under `arathianevasion`.

## The diagram as drawn

- **Planning Session:** Setup, then `/wayfinder`, then a loop over `/grilling` or `/debate-me` (red), `/research` (blue), `/prototype` (red) and `/domain-modeling` (blue) until the map is complete (blue). Then `/to-spec` (blue), `/to-tickets` (black), `/to-plan` (blue).
- **Engineering Claude:** `/implement-plan` sets scope, human-review gates and max agents (red). Ticket Intake (black), then waves and models (blue), then a loop: review gate, context check, dispatch `claude -p` agents, review results, file out-of-scope findings. When the bucket empties: `/raise-prs` (blue), `/pr` (blue), `/retro` (red).
- **Product Claude:** a black `/triage` listener sorts tickets by controversy. Uncontroversial ones become ready-for-agent. Controversial ones wait in a Human Triage Bucket for a human session (`/grill-me`, `/debate-me`) with outcomes Do, Defer or Discard. Then `/retro` (red).

## Recommended changes from the first review

These are the reviewer's proposals. The owner hasn't accepted them yet.

**Flow defects**

1. There is no merge, full-gate or ticket-close step after "No Findings". Closing tickets is what opens the next ones.
2. A finding can travel filed, triaged, ready-for-agent and into Ticket Intake through black boxes alone, so a run can widen its own scope. Proposal: `/implement-plan` sets a scope envelope, and anything outside it waits for the next plan.
3. The in-scope findings loop has no retry cap, and nothing handles a crash, red gates or a merge conflict.
4. "File Triage Ticket" has no arrow back into the engineering flow.
5. Product Claude's closing checks look inverted or unfinished: "Bucket Empty?" has no "no" branch, there is no compaction path, and the listener path never checks context.
6. Context thresholds disagree across the diagram (30/50, 40). The owner's `implement-plan` skill also says "Do not compact between waves", which the diagram contradicts.
7. `/to-plan`, `/implement-plan` and "Determine Wave" appear to overlap.
8. Every project enters through `/wayfinder`, which Matt reserves for huge, foggy efforts. Small features and bugs need their own way in.

**Against autonomy, mastery and purpose**

- "Pause for compaction" is a chore in a red box. Red should mean a person's judgement is needed.
- Reviews triggered by context size arrive at arbitrary moments. A finished slice of work or a named risk is a better trigger.
- The Outcome step lets a person send work to an agent but not take it themselves, even though the `ready-for-human` role exists.
- "Controversial Decision?" decides what humans ever see, and it is black, with no feedback.
- `/to-tickets` is black, but slicing work is a matter of engineering taste.
- Approvals risk becoming rubber stamps unless each one presents the few decisions that matter and what the agent was unsure of.
- Nothing separates the engineer's role from the product manager's. Both review gates sit in the Product lane.
- No step checks whether the shipped work achieved what Setup set out to do.
- `/retro` has no output arrow. Lessons need a destination.
- Discard and deferral reasons are not kept, and deferred tickets have no way back in.

## Evidence from the claudia-kerman project

Claudia-kerman (`~/Claude-Projects/claudia-kermin`) is the main proving ground for this workflow. Later sessions in this repo can't see that project's agent memory, so its lessons are recorded here.

- **Merges:** almost every ticket edited the same central file, and parallel branches broke each other semantically. One merge went in with tests failing because a shell pipeline reported `tail`'s exit status instead of the gate's.
- **Gates** (recorded in the `implement-plan` skill, from a TypeScript project): a gate must be shown to fail before anyone trusts it. A real run reported "typecheck clean" for 30 tickets against a typecheck that compiled nothing.
- **Dispatch** (also from `implement-plan`): dispatch on merged, never on reported. A result file is a claim; the merge is the fact.
- **Controversy criteria already tried** (2026-11-07 standing orders): grilled decisions, ADRs, glossary changes, prompt or library growth, the product's judgement, new scope, stop-and-ask points and flight-only tuning. A held ticket got "Decision needed" and a push notification. Plan: `.scratch/v1/PLAN-2026-11-07.md` in that repo. That setup was modelled on a "Don't Be A Riley" project; ask the owner where it lives.
- **Keeping humans in charge:** an agent proposed a small per-ticket allowance on a line limit, and the owner rejected it, because small additions pile up as debt. A limit now rises only on the owner's word.
- **Approval:** a relay from another session doesn't count as approval. The plan must be shown to the person.
- **Concurrent sessions:** the triage session pre-empted the implementation session twice, and sessions left uncommitted edits on `main`.
- **Human validation:** a 141-check page was rejected as far too detailed. It became five end-to-end flights with about 19 key checks; unit tests carry the rest, and agents mark the log-based checks.
- **Compaction:** long runs bloated context. Breaks were then planned into runs, with state saved first. `~/.claude/scripts/context-gauge.sh` measures context, with a backstop in settings.
- **Guardrails that worked:** `tools/gates/kerboscript-loc.sh` and `BlockDocsSnapshotTests` turn taste into a check that fails.

## Upstream, as of 2026-11-09

`mattpocock/skills`, MIT licence. Latest release v1.3.2 (2026-10-29); `main` is 3 commits ahead. The owner has 1.3.1 installed, and `strength-app` pins 1.2.3.

- `implement-spec` runs a ticket graph with fresh subagents, a merger subagent and an integration branch. It has no plan approval, human gates or triage.
- `retro` improves the agent's environment: navigation, automated checks, coding standards, steering files, tool economy and information access. It sends mechanical lessons to deterministic checks and keeps written standards for judgement calls. It doesn't cover product taste or the human's experience.
- `skills/in-progress/software-factory` is a vocabulary for this design space. Its "start slow" section names three brakes (automated checks, automated review, human review), caps every loop of runs at a few tries before a human, and says a run never waits for a human: it ends, and a later human change triggers a new run. That last rule differs from the diagram's sessions that pause, so it is a real design choice.
- The diagram's `/to-plan` and `/raise-prs` don't exist yet. `/retro` and `/pr` do.

The owner's own skills are in `~/.claude/skills`. The main one is `implement-plan/SKILL.md`; `debate-me` is also theirs. Some others are older copies of Matt's skills.

## Open decisions to chart

A starting list, for the breadth-first pass. Suggested types are in brackets.

**People**

- Who is this for: a solo owner, an engineer and product manager pair, or a team? Does each lane belong to a role? [grilling]
- What decision rights does each role hold, box by box? What test earns a box its red? [grilling]
- Autonomy, mastery and purpose come from Daniel Pink. The research behind them (self-determination theory) has relatedness where Pink has purpose. Does a shared engineer and product manager workflow need something for working together? [grilling]
- How will we know it is satisfying to use, not just productive? What gets asked or measured, and when? [grilling]

**Gates and judgement**

- What makes a decision controversial, who writes that down, and how does a person audit what the agent decided alone? [grilling]
- What triggers a human review? [grilling]
- Can gates loosen or tighten by area as trust is earned, and who moves them? [grilling]
- What should a human review packet contain? [prototype]
- Where does a person deliberately keep hands-on work, so that skill doesn't erode? [grilling]

**Orchestration**

- `claude -p` per ticket, `implement-spec`-style subagents, or remote runs in the software-factory style? The reviewer leans towards keeping `claude -p` and borrowing the merger subagent and integration branch. [research, then grilling]
- What can Claude Code do today about measuring context and resuming a fresh orchestrator from saved state, so a person needn't run compaction? [research]
- How do Engineering and Product sessions talk, and how do we stop them overwriting each other? Is the tracker the only channel? [grilling]
- What spending limit sits beside Max Agents? [grilling]

**Learning**

- Where does each kind of lesson go, and how does a lesson from one project reach the others? [grilling]
- What does the retro wrapper add to upstream `/retro`, and is there one joint retro or two? [prototype]
- What happens to discard and deferral reasons? [grilling]

**Packaging**

- How does this layer on Matt's plugin without forking it? Covers version pinning, upgrades, and the older local copies. [research, then grilling]
- What does a project template hold, and what does setup ask? [grilling]
- Which project pilots version one? [grilling]
- What vocabulary do we use? `software-factory` avoids "workflow" and "session", and this repo is named Workflow. Record the outcome in a glossary. [grilling]

## Probably out of scope

Confirm these when naming the destination.

- Building the skills. This map ends at a spec.
- Hosted, remote factory infrastructure, unless the orchestration decision calls for it.
- Harnesses other than Claude Code.
- Reworking claudia-kerman's process during this effort.

## Notes for the map

- Consult `grilling` and `domain-modeling` on every grilling ticket, and `/debate-me` where the owner wants a decision stress-tested.
- Refer to tickets by name, never by a bare number.
- Weigh each proposal against autonomy, mastery and purpose, and say which it serves.
- Keep hard-won lessons from claudia-kerman, but check that each one generalises before making it a rule.
