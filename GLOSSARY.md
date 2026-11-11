# Artisan Agent

A reusable way of delivering software projects where agents do most of the delivery and people set the guardrails and supply product and engineering taste.

## Language

### The product

**Artisan Agent**:
The product's name: a Claude Code plugin (`artisan-agent`) and project template. Inside the skills, "workflow" is never a technical term.
_Avoid_: watsonsoft (former name), workflow (as a technical term), factory

**Pipeline**:
The end-to-end path work takes, from a request to merged code and the lessons kept from it.
_Avoid_: workflow, process

**Route**:
One of the four ways work enters the pipeline: Effort, Feature, Small change or Bug, chosen by how clear and how big the work is.
_Avoid_: lane, track

**Cockpit**:
Agent Development Cockpit, a separate product in its own repo: an optional cmux layout that makes the pipeline faster to drive from the terminal. The pipeline never depends on it.
_Avoid_: dashboard, UI

### People

**Artisan**:
The person who holds the roles in a project and instils taste in how its problems are solved.
_Avoid_: user, human orchestrator, owner (as a role), craftsman

**Individual home**:
The Artisan's own store, outside any project, for what follows them between projects: their individual standards, their motivation for each product, and their satisfaction record. Set up once per machine.
_Avoid_: personal config, dotfiles

**Motivation**:
An Artisan's personal reason for caring about a product they work on: their own connection to it, separate from the product's purpose. One per product, kept in their individual home and private unless they choose to share it.
_Avoid_: purpose, mission (those belong to the product, not the Artisan)

**Focus**:
One of the three things an Artisan's attention is for: understanding the problem, finding the best solution, or improving the pipeline. Every human step serves one.
_Avoid_: priority, concern

**Chore**:
Something that takes the Artisan's time without serving a focus, such as confirming, relaying or retyping. A chore is automated or removed.
_Avoid_: toil, admin

**Job**:
A recurring piece of human judgement the pipeline needs done, phrased as an outcome, such as "decide what's in scope" or "approve how work is sliced".
_Avoid_: task, duty

**Role**:
A bundle of jobs that one Artisan holds. A role is never a job title.
_Avoid_: persona, position

**Product role**:
The role holding the jobs about what to build and why, including design.

**Engineering role**:
The role holding the jobs about how it's built, including QA.

**Lane**:
A strand of agent work in the pipeline, such as planning or triage. A lane is not a person or a role.
_Avoid_: swimlane (except when describing the diagram)

### Who acts at each step

**Human-led step**:
A step only a person can do, because it needs their judgement. Drawn red.
_Avoid_: manual step, red box (except when describing the diagram)

**Approved step**:
A step an agent leads and a person approves before its result counts. Drawn blue.
_Avoid_: reviewed step, blue box

**Autonomous step**:
A step an agent completes with no person involved. Drawn black.
_Avoid_: automatic step, black box

### Sessions and agents

**Chat**:
An interactive session an Artisan talks to. There are two: the Engineering chat and the Product chat.
_Avoid_: session (except in Claude Code's technical sense), console

**Engineering chat**:
The chat that drives runs and holds the Engineering role's jobs.

**Product chat**:
The chat that runs triage and holds requirements discussion and writing, keeping the Engineering chat's context free for building.

**Orchestrator**:
A fresh headless session that runs one wave of a run: it dispatches workers, merges their work and records the run's state, then exits.
_Avoid_: wave runner, dispatcher, scheduler

**Worker**:
A headless session that implements one ticket in its own worktree.
_Avoid_: agent (when a worker is meant), implementer

**Verifier**:
A short-lived session that checks one ticket's changes against its acceptance criteria.
_Avoid_: reviewer

**Doorbell**:
A message from one chat to the other that only names an issue to look at, and carries no content.
_Avoid_: notification, ping

### Planning and running

**Plan**:
A chunk of tickets the Artisan has approved to run together.
_Avoid_: batch, milestone, sprint

**Run**:
One execution of the pipeline's build stage over a defined set of work: one or more plans, individual tickets, or a mix.
_Avoid_: session, job, execution

**Wave**:
A batch of tickets dispatched together within a run, none of which depends on another in the same wave.
_Avoid_: round, phase

**Urgent ticket**:
A ticket the Artisan marks to join the current run and start at once, ahead of the queue.
_Avoid_: hotfix, quick fix

**Backlog review**:
The Artisan's periodic sort of open tickets into the next plan, closed, or left open. Deferred tickets come back here.
_Avoid_: sweep (a chat's regular check of runs and gates), grooming

**Finding**:
A fact a worker turns up during a run that may matter to other work.
_Avoid_: discovery, note

**State file**:
The record of a run's plan, progress and evidence that lets any fresh session carry the run on.
_Avoid_: checkpoint, memory

**Integration branch**:
The branch a run merges each finished ticket into, kept apart from `main` until the end gate approves the run's PRs.
_Avoid_: staging branch, run branch

**Integration worktree**:
The run's own checkout of its integration branch, where merges and the full suite run, so no session changes the main checkout.
_Avoid_: merge worktree

**Wave digest**:
What the Artisan sees after each wave: each ticket's status and verdict, what it cost against its estimate, and what runs next.
_Avoid_: wave report, wave summary

**Run digest**:
Where an open run stands, read first by any chat that picks the run up, after compaction, on resume or in a new session.
_Avoid_: run summary (that's the end-of-run report)

### Judgement

**Taste**:
A person's product or engineering judgement on a choice where several answers would work.
_Avoid_: preference, style

**Guardrail**:
A standing rule that limits what agents may do, usually capturing a past decision of taste. It holds at one of three levels: team, product or individual.
_Avoid_: policy, constraint

**Team guardrail**:
A guardrail for everyone who works together, across all their products.

**Product guardrail**:
A guardrail for one product and its repo.

**Individual guardrail**:
A guardrail carrying one Artisan's taste, which follows them into every project they work on.

**Individual standards**:
The Artisan's written taste that applies in every project: their individual guardrails, what should always come back to them, and how the pipeline speaks to them. Kept in their individual home.
_Avoid_: personal standards, preferences

**Area**:
A named part of a project, defined by its paths, that guardrails and gates can apply to separately. A ticket belongs to every area it touches, and the strictest setting wins.
_Avoid_: module, zone

**Check**:
An automated test of the work, such as a test suite, typecheck or lint, which must be shown to fail before anyone trusts it.
_Avoid_: gate (for automated checks)

**Gate**:
A point where the Artisan reviews work before what depends on it continues: a slice, risk, exception or end gate.
_Avoid_: checkpoint, approval step, gate (for automated checks)

**Packet**:
What the Artisan sees at a gate: the decisions agents made, what they were unsure of, and the evidence, framed as problem, solution and verification.
_Avoid_: report, summary

**Evidence**:
For each acceptance criterion, what shows it was met, together with what the agent was unsure of and what the work cost.
_Avoid_: proof, results

**Evidence record**:
A worker's own account of one ticket: its evidence for each acceptance criterion, what it was unsure of and the decisions it made alone. The verifier checks it; it is the worker's claim, not the verdict.
_Avoid_: result file, report

**Evidence contract**:
The verified evidence for one ticket: each acceptance criterion with the verifier's verdict and its evidence. It is posted on the ticket and is what the packet and wave digest are built from.
_Avoid_: verdict file

**Lesson**:
Something a retro keeps from a run so later runs go better.
_Avoid_: learning, takeaway

**Retro**:
The step after every run where agents propose lessons from the run and the Artisan decides which to keep and where they go.
_Avoid_: retrospective (in skills), post-mortem

**Satisfaction record**:
An Artisan's private history of their answers to the satisfaction questions asked at every retro (problem, solution, pipeline and chores), kept with each run's facts. Shared only if the Artisan chooses.
_Avoid_: survey, scores, feedback log
