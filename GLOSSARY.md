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

### People

**Job**:
A recurring piece of human judgement the workflow needs done, phrased as an outcome, such as "decide what's in scope" or "approve how work is sliced".
_Avoid_: task, duty

**Role**:
A bundle of jobs that one person holds. A role is never a job title.
_Avoid_: persona, position

**Product role**:
The role holding the jobs about what to build and why, including design.

**Engineering role**:
The role holding the jobs about how it's built, including QA.

**Lane**:
A strand of agent work in the flow, such as planning or triage. A lane is not a person or a role.
_Avoid_: swimlane (except when describing the diagram)

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
A guardrail carrying one person's taste, which follows them into every project they work on.

### Packaging

**Cockpit**:
The owner's optional cmux layout that makes the workflow faster to drive from the terminal. The workflow never depends on it.
_Avoid_: dashboard, UI
