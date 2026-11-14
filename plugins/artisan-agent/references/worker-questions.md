# Decisions a worker may not make

Nothing joins scope without the Artisan, and one question doesn't stall the run. When a worker would decide something that meets a controversy criterion, it files a question instead of deciding. The criteria are the seven in `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md` plus every "Always ask" item at each level (`PRODUCT_STANDARDS.md`, `CODING_STANDARDS.md`, the individual standards), **read again at the point of use**, not remembered from the start of the session.

Skills cite this file rather than copying it. The script is `${CLAUDE_PLUGIN_ROOT}/scripts/questions.sh` (usage in its header; tests in `tests/questions.test.sh`).

## What a worker does

| The decision | The worker |
|---|---|
| Meets criterion 1, 2, 3 or 5, or an "Always ask" item (not a new seam it introduces, which `/artisan-agent:implement` builds and records) | Files a question (below). Doesn't make the choice |
| Easy-to-reverse taste: criterion 4, 6 or 7 | May pick it **provisionally**: a decision card with `confidence: "provisional"` and the criterion (`references/evidence-record.md`). It comes to the Artisan as a "provisional" card at the next slice gate, in the packet |
| Anything else | Decides, as `/artisan-agent:implement` says |

A worker may also file a question for taste it would rather not pick; when in doubt, it's controversial.

### Filing a question

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/questions.sh file --ticket <its ticket> --criterion <1-7|always-ask> \
  --question "<the question>" --option "<first>" --option "<second>" \
  --recommendation "<what it would choose, and why>" (--blocking | --split)
```

It files a ticket labelled `needs-triage` holding the question, the options, the recommendation and the criterion that triggered it, and logs a `question` finding in the worker's findings file (`$ARTISAN_FINDINGS_FILE`). It prints the new ticket's number. A criterion-2 question is the scope floor firing: the sweep reads that finding once and logs `guardrail-fired` for `scope-floor` (ticket, areas, question number), for guardrail health (`references/guardrail-health.md`); other criteria log no guardrail event.

- `--blocking`: the worker's own ticket can't finish without the answer. The worker stops, commits what is safe, and ends with result status `blocked`; `unsure` names the question ticket.
- `--split`: the question can be split off. The worker finishes every other criterion and ends `complete`, naming the question ticket in `unsure`. The ticket is **not** blocked.

The worker doesn't wait, doesn't ask the Artisan in its transcript (nobody is there) and never picks a controversial option "for now".

## What the orchestrator does

A worker's `blocked` result is the cue. After the sweep records it:

1. `questions.sh block $RUN <ticket>` marks the ticket blocked by the question ticket (GitHub's native dependency), records the question on the ticket and queues a `question` decision. It is not a failed attempt, not an exception and not a reason to halt the wave. Exit 1 means the ticket is blocked for another reason: leave it to the exception path.
2. The wave carries on: the other tickets are dispatched, verified and merged as usual. Dependents of the blocked ticket wait, as they would for any blocker.
3. Don't act on a `question` finding as work to file: the question ticket exists already. The relay and the triage item for other findings skip `kind: "question"`.

## Once triage decides

The Engineering chat runs `questions.sh sync $RUN` between waves (it is cheap: a read of each open question). Triage rules on the question ticket in the Product chat (`skills/triage/SKILL.md`, "Worker questions"):

| Ruling | What `sync` sees | What happens |
|---|---|---|
| Answered | the ticket closed, with a comment line `Answer: <the decision>` | prints `answered #<t> #<q>`. Once every question of the ticket is answered it is `queued` again and `wave.sh dispatch` tells the new worker the answers (it is a continuation on the same branch, not a retry, and uses no attempt of the failed kind) |
| Closed with no `Answer:` | the ticket closed without one | prints `closed …`, queues a `question` decision: the Artisan answers, redirects or defers the ticket |
| Deferred | the ticket labelled `deferred` (its `Return condition:` is triage's, `skills/triage/SKILL.md`, "Defer") | prints `deferred …` and queues a `defer-question` decision |

### Deferring a finding that blocks a running ticket

Ask the Artisan, in a table (owner preference), once per decision:

| Ticket | Blocked by | Pull from the run | Carry on |
|---|---|---|---|
| #12 Billing tab | #31 (deferred) | defers with #31, back to the plan queue | redispatched with "not now" as the answer |

Then `questions.sh deferred $RUN <ticket> pull` or `carry`:

| Answer | The ticket ends up |
|---|---|
| **pull** | labelled `deferred` (the `in-run` label off), with a comment holding the reason and the same contract triage writes, `Return condition: blocked-by #<q>` (read by `deferred-due.sh` and the backlog review); status `deferred` in the state file; off the run's scope; still blocked by #<q> on the tracker; its branch kept. Dependents wait |
| **carry on** | unblocked (the native edge comes off), `queued`, with the answer `not now` for its next worker, which finishes what it can without the deferred decision |

## Provisional cards

`questions.sh provisional $RUN` prints, as a table, every provisional card (criteria 4, 6 and 7) from tickets merged in the run that no gate has shown yet. `gate.sh open` puts it in the slice gate's packet, under the slice's own decision cards, and records the tickets it showed in `provisional_shown` itself, so the next gate doesn't repeat them (`references/review-gates.md`). Outside a gate, `--shown` does that recording. The Artisan can approve each card or send it back.

## State

`tickets.<n>.questions`: `[{ticket, blocking, state: open|deferred|answered, answer?, at}]`. `tickets.<n>.answers`: `[{question, answer}]`, given to every later worker. Decisions of kind `question` and `defer-question`. Events `asked`, `answered`, `deferred-question`, `pulled`, `provisional-shown`. `deferred` joins the ticket statuses. Details in `references/state-file.md`.
