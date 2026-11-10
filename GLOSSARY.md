# Watsonsoft Workflow

A reusable way of delivering software projects where agents do most of the delivery and people set the guardrails and supply product and engineering taste.

## Language

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

### Judgement

**Taste**:
A person's product or engineering judgement on a choice where several answers would work.
_Avoid_: preference, style

**Guardrail**:
A rule kept in a project that limits what agents may do there, usually capturing a past decision of taste.
_Avoid_: policy, constraint

### Packaging

**Cockpit**:
The owner's optional cmux layout that makes the workflow faster to drive from the terminal. The workflow never depends on it.
_Avoid_: dashboard, UI
