# Watsonsoft Workflow

A reusable way of delivering software projects where agents do most of the delivery and people set the guardrails and supply product and engineering taste.

## Language

### The product

**Watsonsoft Workflow**:
The product's name. Inside the skills, "workflow" is never a technical term.
_Avoid_: workflow (as a technical term), factory

**Pipeline**:
The end-to-end path work takes, from a request to merged code and the lessons kept from it.
_Avoid_: workflow, process

**Route**:
One of the four ways work enters the pipeline: Effort, Feature, Small change or Bug, chosen by how clear and how big the work is.
_Avoid_: lane, track

**Cockpit**:
The owner's optional cmux layout that makes the pipeline faster to drive from the terminal. The pipeline never depends on it.
_Avoid_: dashboard, UI

### People

**Artisan**:
The person who holds the roles in a project and instils taste in how its problems are solved.
_Avoid_: user, human orchestrator, owner (as a role), craftsman

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

**Lesson**:
Something a retro keeps from a run so later runs go better.
_Avoid_: learning, takeaway

**Retro**:
The step after every run where agents propose lessons from the run and the Artisan decides which to keep and where they go.
_Avoid_: retrospective (in skills), post-mortem
