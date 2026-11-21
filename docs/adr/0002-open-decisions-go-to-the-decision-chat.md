# Open decisions go to the Decision chat; every other call is the execution agent's

The two chats differ by what happens in them, not by role. The **Decision chat** researches and makes decisions. The **Run chat** plans and drives runs. There are two so the Artisan can decide while a run goes on, and so a run's packets and digests never crowd a decision's reasoning out of context, or the other way round. They were the Product and Engineering chats. Those names made agents read architecture as Engineering's call and the Product chat as "requirements only". The Product and Engineering roles keep their names, because they say who owns which jobs.

Execution agents (the Run chat's plan step, workers, verifiers and gate reviewers) make judgement calls on requirements and design, and record them as decision cards. That is the default, and the pipeline must not stop for anything less than an **open decision**. Only an open decision goes to the Decision chat, as a `needs-triage` ticket. A decision is open only when any answer an execution agent could give would do one of these:

1. Ship something a user can reach that doesn't do what it offers (the feature is **incomplete**).
2. Fit no reading of the criteria to the spec's user story, or contradict the spec, another ticket or a recorded decision (the feature is **misaligned**).
3. Invent user-facing behaviour the ticket doesn't describe.
4. Settle something that needs an ADR: hard to reverse, surprising without its context, and a real trade-off. This covers engineering decisions too, such as a new seam other code will depend on. These are made before they are built.

**When in doubt, it's the execution agent's call.** This reverses the rule for the other controversy criteria. An agent raises an open decision only when it can name which case applies and the concrete harm: what a user would meet, the spec, ticket or decision the work contradicts, or the ADR tests it passes. If it can't, it decides and records a card. Raising one costs the execution window a few lines: the case, the harm and one recommendation. Researching the options is the Decision chat's work.

We chose this line because sending every unclear requirement to the Decision chat would make each one a stop, while settling everything in execution let incomplete and misaligned features through. In claudia-kerman run 1049, a card offered a part test that nothing could stage yet, and nobody who decides heard about it.

## Not an open decision

These stay the execution agent's call, recorded as decision cards:

- Picking between readings of a criterion that all fit the user story.
- Keeping existing behaviour for a case the ticket doesn't cover.
- How a criterion is met: seams, structure and names that don't need an ADR.
- Wording, naming and other taste no guardrail covers.

## Considered options

- **Every unclear requirement goes to the Decision chat:** the pipeline stops on every trivial reading. Rejected.
- **Execution settles everything, shown at gates:** gates show the work after it is built, and they sit in the Run chat. Rejected after run 1049.
- **One chat:** orchestrators and workers already run outside the chat, so its run work is lighter than it was. But in one chat a wave's report or a gate packet lands mid-decision, and the two kinds of context push each other out. Rejected.
- **Chats named Artisan and Agent:** "Artisan" already names the person who approves gates and plans, and the Artisan works in both chats. Rejected.

## Consequences

- The cheapest place to catch an open decision is the plan step, before a ticket is dispatched. Workers, verifiers and gate reviewers may still raise one, but none of them adds a stop beyond its own ticket. A verifier files only split decisions, and a decision found in another ticket is filed without blocking it. A block there is the Decision chat's ruling.
- Nothing an open decision touches reaches main unruled. A decision raised at a gate after merge never reverts the merge, but the end gate holds until it is ruled on. Add ticket never leaves an incomplete feature shipping with its fix filed for later.
- The aim is to give the Artisan the highest leverage on product outcomes, not the most decisions. The retro shows the balance: the share of the Artisan's decisions that changed the outcome, beside throughput and how long the run waited on them, as a trend over runs.
- The line is a guardrail, and guardrail health tracks it both ways. Only an explicit "didn't need the Decision chat" verdict is loosen evidence. A decision first raised at a gate or after merge is tighten evidence.

## Amendment: one chat by default, a second chat optional (2026-11-21)

The "one chat" option above is now the default. Its rejection rested on run reports and gate packets landing mid-decision. Since then, each wave runs in a detached orchestrator, and the chat waits on it as a background task, so it wakes only when the wave ends and learns what happened from files. A report arrives at a turn boundary, not mid-reply. The run's state shows outside any chat, in the run digest's one-line form and the cockpit. A required second chat cost more than it saved: each handoff needed a sweep every few minutes (hundreds of idle turns in a day) or a message to a session name that wasn't unique, and four projects meant eight sessions.

- Every step works in one chat, which holds both decisions and runs. Open decisions still go to the Decision chat's work (triage) as `needs-triage` tickets, and the rule above for what counts as one is unchanged.
- An Artisan who wants to decide while a run goes on opens a second chat. The chats connect by a doorbell message, never a recurring sweep: the tracker stays the record, and the doorbell rings only when exactly one live session matches the other chat's name, and otherwise says it couldn't.
- Without a second chat, tickets filed during a run appear in the wave and run reports, and the same chat offers triage.

The cost we accept is crowding: a long grill and a run's reports share one context. A report that arrives during a grill waits until the grill pauses, and a project with heavy decision work during a run is the signal to open a second chat.
