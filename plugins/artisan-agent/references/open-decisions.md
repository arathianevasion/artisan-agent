# Open decisions

Controversy criterion 8 (`${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`). Execution agents (the Run chat's plan step, workers, verifiers and gate reviewers) make judgement calls on requirements and design and record them as decision cards. That is the default. An **open decision** is the exception, and only an open decision goes to the Decision chat, as a `needs-triage` ticket. The rule and why: `docs/adr/0002-open-decisions-go-to-the-decision-chat.md`.

Skills cite this file rather than copying it.

## The four cases

A decision is open only when **any** answer an execution agent could give would do one of these. Each has the name `questions.sh` takes as `--case`:

| `--case` | Any answer would |
|---|---|
| `incomplete` | Ship something a user can reach that doesn't do what it offers: the feature is incomplete |
| `misaligned` | Fit no reading of the criteria to the spec's user story, or contradict the spec, another ticket or a recorded decision: the feature is misaligned |
| `invented` | Invent user-facing behaviour the ticket doesn't describe |
| `adr` | Settle something that needs an ADR: hard to reverse, surprising without its context, and a real trade-off. An ADR-worthy engineering seam, one other code will come to depend on, counts |

If one answer the agent could give avoids all four, the decision isn't open: give that answer and record a card.

## The named-harm bar

**When in doubt, it's the execution agent's call.** An agent raises an open decision only when it can name the case and the concrete harm:

- `incomplete` and `invented`: what a user would meet.
- `misaligned`: the spec, ticket or decision the work contradicts.
- `adr`: how it passes the three ADR tests.

If it can't name both, it decides and records a card. Raising one costs a few lines: the case, the harm and one recommendation, nothing more. No options and no research: researching the options is the Decision chat's work.

## Not an open decision

These stay the execution agent's call, recorded as decision cards:

- Picking between readings of a criterion that all fit the user story.
- Keeping existing behaviour for a case the ticket doesn't cover.
- How a criterion is met: seams, structure and names that don't need an ADR.
- Wording, naming and other taste no guardrail covers.

## Filing one

Every raiser files the same way (`${CLAUDE_PLUGIN_ROOT}/scripts/questions.sh`, usage in its header):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/questions.sh file --ticket <the ticket it is in> --criterion 8 \
  --case <incomplete|misaligned|invented|adr> --harm "<the concrete harm>" \
  --recommendation "<one recommendation>" (--blocking | --split | --non-blocking) \
  [--raised-by plan|worker|verifier|gate|finding] [--from <ticket>] [--run <run-dir>]
```

It refuses a filing with no case or no harm, or with a `--question` or `--option`, and files nothing. Otherwise it files a `needs-triage` ticket holding the case, the harm and the recommendation, records where it was raised (`Raised at:`), and prints its number.

| Raiser | `--raised-by` | Mode |
|---|---|---|
| A worker, in its own ticket | `worker` (the default) | `--blocking` when the answer changes what its ticket builds; `--split` when it is a case beside its ticket. Either way as a worker question (`${CLAUDE_PLUGIN_ROOT}/references/worker-questions.md`) |
| A worker, in another ticket | `finding`, with `--from <its own ticket>` | `--non-blocking` only: one execution window never stops another's ticket. A block is the Decision chat's ruling (`Add the block:`), which `questions.sh sync` adds. Never also a finding to relay or comment (`${CLAUDE_PLUGIN_ROOT}/references/findings.md`) |
| The plan step | `plan` | `--non-blocking`, with no run, through `plan.sh drop --draft <draft.json> <ticket>`: it files each open decision the draft's `open_decisions` records on the ticket and its dependents, and takes them out of the draft's scope. Until then `plan.sh build` lists it under "Needs your attention" and `state.sh init` refuses the plan; `--override-open-decision <ticket> --why <reason>` on the build keeps the ticket in |
| A verifier | `verifier` | Never files itself: it names the open decision in its verdict's `open_decisions` (`${CLAUDE_PLUGIN_ROOT}/references/evidence-contract.md`), and the sweep files it `--split` with `--run`, once. Never blocking, and the verdict doesn't change |
| A gate reviewer | `gate` | `--split` or `--non-blocking`; the gate stays approvable |

Only a worker's own ticket blocks on one. Criterion 8 is never picked provisionally: an open decision is filed, and a card that only records one is never a provisional card.

**For guardrail health.** Each filing in a run logs `guardrail-fired` with `guardrail: "open-decision"`, `ticket`, `raised_by`, `case`, `question`, `areas` and, for a finding, `from`. With `--run <run-dir>` (the Run chat, a gate, the orchestrator for a verifier) `questions.sh` logs it itself; a worker's filing reaches its findings file (`$ARTISAN_FINDINGS_FILE`) and the sweep logs it once. With no run (the plan step) nothing is logged.
