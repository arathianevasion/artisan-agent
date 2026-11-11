# Jobs

The recurring pieces of human judgement the pipeline needs done, with who does each and which focus it serves.

Skills cite this file rather than copying it: "job 10 in `${CLAUDE_PLUGIN_ROOT}/references/jobs.md`". Job numbers are stable: a removed job keeps its number and stays in the table, struck through.

## The colour test

Ask three questions of a job:

- **R**: is it hard to reverse?
- **D**: does it shape many tickets downstream?
- **T**: is it a matter of taste?

Then:

- **Human-led** (drawn red): R or T, and an agent can't usefully draft the answer.
- **Approved** (drawn blue): R, D or T, and an agent can draft the answer for the Artisan to approve.
- **Autonomous** (drawn black): none of R, D or T; or a proven check decides; or a guardrail covers the taste.

A job that is autonomous because a guardrail covers it returns to a person whenever an agent wants to break that guardrail. With no guardrail yet, it is approved.

## The scope floor

Anything that adds scope is never autonomous. The scope floor never loosens.

## Focus

Each human-led or approved step names its focus: **problem**, **solution** or **pipeline**. A step serving none of them is a chore, to be automated or removed.

## Inventory

| # | Job | Colour | Role | Focus |
|---|---|---|---|---|
| 1 | Decide what the project is for and what success looks like | Human-led | Product | Problem |
| 2 | Decide an effort's destination and scope | Human-led | Product | Problem |
| 3 | Resolve open design questions | Human-led | either, by topic | Problem / solution |
| 4 | React to a prototype | Human-led | Product (design) or Engineering | Solution |
| 5 | Find the facts a decision needs | Autonomous (the Artisan can add facts) | — | — |
| 6 | Settle a term in the glossary | Approved | either | Problem |
| 7 | Judge the map complete | Approved | Product | Problem |
| 8 | Approve the spec | Approved | Product | Problem |
| 9 | Approve how work is sliced | Approved | Engineering | Solution |
| 10 | Set a run's scope, review gates, Max Agents and budget | Human-led | Engineering | Solution |
| 11 | Group tickets into waves and choose each agent's model | Autonomous within the run's limits | — | — |
| 12 | Run tickets and merge them once their checks pass | Autonomous | — | — |
| 13 | Check a finished slice at a review gate | Approved | Engineering (QA) | Solution |
| 14 | Decide whether a finding becomes new work | Approved | Product | Problem |
| 15 | Decide what happens after a run gives up | Human-led | Engineering | Solution |
| 16 | ~~Pause for compaction~~ | Removed | — | — |
| 17 | Set PR boundaries | Approved until a guardrail covers them, then autonomous | Engineering | Solution |
| 18 | Sort incoming tickets and recommend an outcome | Agent sorts; every outcome approved in version one | Product | Problem |
| 19 | Rule on a controversial ticket: Do, Defer, Discard or take it myself | Human-led | Product | Problem |
| 20 | Check that the shipped work achieved its purpose | Human-led; **open question, no step built** | Product | Problem |
| 21 | Decide which lessons become guardrails, and at which level | Human-led | either | Pipeline |
| 22 | Approve taking an upstream skill update | Approved | Engineering | Pipeline |
| 23 | Loosen or tighten a guardrail or gate | Human-led | either | Pipeline |
| 24 | Decide which tickets go into which plan | Approved | Product | Problem |
| — | Choose the route | Approved | Product | Problem |

## Notes

- **Job 16** is removed: the pipeline never pauses for compaction. Runs drain and hand off instead.
- **Job 20** is an open question. It can't be answered on the day of the run, so it isn't part of the retro, and no step is built for it in version one.
- **Route choice** has no number. It is the front door's proposal of Effort, Feature, Small change or Bug, which the Artisan approves or changes.
- Only a person moves a job between colours, through job 23.
