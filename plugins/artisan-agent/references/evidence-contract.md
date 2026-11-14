# The verdict and the evidence contract

How every finished ticket is checked the same way, and how the tracker becomes the audit trail. A worker's evidence record (`evidence-record.md`) is its claim. A fresh **verifier** checks the claim against the diff and writes a **verdict**. From the two, `verify.sh judge` builds the ticket's **evidence contract** and writes it to the state file; `wave.sh close` posts the same contract on the ticket; the Engineering chat shows a **wave digest** of the contracts. The orchestrator reads only result files and one-line verdicts, never a transcript.

Skills cite this file rather than copying it.

## The flow

| Step | Who | Call | Reads | Writes |
|---|---|---|---|---|
| A worker's attempt returns | orchestrator | `sweep.sh` | the result and exit records | `returned` |
| Start a verifier | orchestrator | `verify.sh start <run> <t>` | the ticket's criteria (tracker or `ticket_path`) | a detached worktree at the worker's commit; a verifier session (`run-ticket.sh --role verifier`); event `verify` |
| Wait | orchestrator | `wait-any.sh` | the verifier's exit record | |
| Judge | orchestrator | `verify.sh judge <run> <t>` | the verdict file | the evidence contract in `tickets.<t>.evidence`; costs; event `verified`; a fail is a failed attempt (retried with the verifier's findings, or blocked after the last) and its contract is posted on the ticket |
| Merge | orchestrator | `wave.sh merge` | `tickets.<t>.evidence` | refuses (13) without a `pass` for this attempt at the branch tip; then the serial merge and the suite, as `skills/implement-plan/references/parallel-waves.md` says |
| Close | orchestrator | `wave.sh close` | `tickets.<t>.evidence` | the comment (`evidence.sh comment`), ticked criteria, closed |
| Report | chat | `evidence.sh digest <run>` | the state file | the wave digest |

A ticket that misses a criterion is never merged; it is a failed attempt like any other (two at most). A fail's evidence comment is posted on the ticket, which stays open. `judge` prints one line, which is all the orchestrator reads:

| Line | Exit | Means |
|---|---|---|
| `pass <met>/<total>` | 0 | every criterion met: merge it |
| `pass <met>/<total>, <k> to Human check #<n>` | 0 | every criterion met but `k` that need a human check, which moved to Human check `#<n>`: merge it (below) |
| `pass <met>/<total>, <k> need a human check (no tracker ticket to split them into)` | 0 | the same, for a ticket with a `ticket_path`: nothing is split, and its contract's `unsure` says to move them into a Human check by hand |
| `fail <met>/<total> retry: <first unmet>` | 6 | a failed attempt with attempts left: the ticket is `queued`; dispatch it again and the fresh worker's failure evidence lists what the verifier found unmet |
| `fail <met>/<total> blocked: <first unmet>` | 6 | a failed attempt, the last: blocked, with an exception decision for the Artisan |
| `error <reason>` | 14 | the verifier failed (crashed, ran out of budget, wrote no verdict): start it again; no attempt is used up |
| `error <reason>` | 6 | the verifier failed twice for this attempt: blocked |
| | 8 | the verifier is still running |

The verifier runs on `plan.verifier.model` (default `claude-sonnet-5-5`) with an estimate of `plan.verifier.estimate_usd` (default $0.50, so a $1.00 cap) and a deadline of twice `plan.verifier.minutes` (default 15). It is not a ticket, so it takes no slot under Max Agents.

## The verdict

The verifier's result file, `results/verify-<t>.<v>.result.json` (`<v>` counts the ticket's verifiers): the evidence format of `evidence-record.md`, judged.

| Field | Required | Values |
|---|---|---|
| `acceptance` | yes | one entry per criterion, in the ticket's order: `criterion` (verbatim), `met` (`true`, `false`, `"human"`: needs a human check, or `"gate"`: checked by the merge gate, both below), `evidence` (`tests`, `checks`, `diff`, and `why` when unmet), as in `evidence-record.md`; an unmet one may carry `guardrail`: the id of the guardrail it broke (`guardrails.sh resolve`), which `judge` logs as `guardrail-fired` for guardrail health |
| `verdict` | no | `pass` or `fail`; advisory, since the contract recomputes it |
| `unsure` | no | what the verifier was unsure of, one sentence each |
| `notes` | no | one paragraph |

`judge` trusts no count it can check. Each of the ticket's criteria takes the verdict entry with the same text (spaces and case aside), else the entry in its position when the counts agree; a criterion with no entry is unmet. The matching rule lives in one place, `scripts/lib/criteria.py` (`extract` reads the criteria from a body, `ticket` from an issue: the body's, else the newest triage "Agent Brief" comment's, the source kept in the plan as `acceptance_source`; `plan.sh build` lists a ticket with none in `criteria_missing` and `state.sh init` refuses that plan; `align` lines the verdict and the worker's claims up with them, the claims by the same rule: same text, else position when the worker's count matches the ticket's, else `claimed` stays null, never fuzzier, `tick` ticks the met ones on the ticket). The contract keeps the ticket's wording, so ticking the ticket's checkboxes always matches.

## Needs a human check

A criterion only a person can verify (in game, by eye, on a real device, with outside access) belongs in a Human check ticket (`references/human-checks.md`), not an agent ticket. When one slips into an agent ticket anyway, the verifier marks it `"met": "human"`, with `evidence.why` saying what only a person can do there. It is for a criterion that code, tests, checks and the diff can't show; never for one that is merely hard to test.

- It is neither met nor unmet: it never fails an attempt. The verdict passes when every other criterion is met; a ticket whose criteria all need a human check passes too, with a `note` in its contract. An unmet criterion still fails the attempt, `human` ones or not.
- A red recorded check that no criterion cites leaves none to a human check either: they are unmet, so a broken build is never handed to the Artisan to try.
- On a pass, `judge` first moves them into the agent ticket's Human check (`to-plan.sh split-human-check`: title, marker, `ready-for-human`, the criteria, blocked by the agent ticket), then records the verdict with the Human check in the run's scope (`tickets.<n>.human_check.for`) and logs `human-check-split` in the same write. Nothing is ticked for them on the agent ticket (they are no longer on it) and a comment there says where they went. The next slice gate lists the Human check (`references/human-checks.md`, "In a run"). A judge that stops part way records nothing and runs again; the split action finds the Human check it made, so there is never a second.

## Checked by the merge gate

A criterion about CI, the merge gate or the PR ("CI's `check` job is green on the PR", "the PR shows the review notes", "the run's merge gate is green") can't be judged inside a run: workers never open PRs (they come at the end gate) and the merge gate runs after the verifier. The verifier marks it `"met": "gate"` and doesn't judge it (#174).

- `judge` reads one as `gate` whatever the verifier said when the whole criterion states the outcome (`scripts/lib/criteria.py`, `merge_gate_criterion`: "CI is green", "CI's `check` job is green on the PR", "the run's merge gate is green", "the PR shows / lists …"), so two verifiers on the same criterion give the same answer. One that names a script or a condition (when, if, blocks, fails) is about code that runs CI or a merge gate, and the verifier judges it ("wave.sh merge blocks the ticket when CI is not green"); a quoted criterion inside one is read as a single word, so a criterion about one is not one.
- It is neither met nor unmet: it never fails an attempt, and the verdict passes when every other criterion is met (or needs a human check). The `verified` event lists them (`gate`), and the judge's line adds `, <g> to the merge gate`.
- `wave.sh merge`'s gate (the suite here, or CI) is what satisfies it. Green: the ticket merges and `wave.sh close` ticks the criterion with the met ones. Red: the merge is undone and the ticket blocked, as for any red merge gate; nothing about it passes on the verifier's word.
- A red recorded check that no criterion cites leaves none to the merge gate: they are unmet, as for a human check.
- The slice gate's packet shows each one as "checked by the merge gate (run <id>)" with the gate's result (green, with the CI run when there is one; red; or not run yet), from `tickets.<t>.suite`; the ticket's comment says "checked by the merge gate" with it.
- Ticket-writing guidance doesn't write them: a criterion a run can check says what the work leaves behind, such as "review notes committed at docs/review/<n>/" instead of "the PR shows the review notes", and there is no line about CI on the PR (`references/human-checks.md`, "Writing an agent ticket").

## The evidence contract

`tickets.<t>.evidence` in the state file, and the JSON at the foot of the ticket's evidence comment: the same object.

| Field | Values |
|---|---|
| `ticket`, `title`, `attempt`, `commit`, `base` | which work was verified: the worker's attempt, its commit and the integration commit it branched from |
| `verdict` | `pass` when every criterion is met, needs a human check or is checked by the merge gate, else `fail` |
| `criteria_met`, `criteria_human`, `criteria_gate`, `criteria_total` | the counts: met, needing a human check, checked by the merge gate, all |
| `human_check` | the Human check the `human` criteria moved to, when there are any (a ticket with a `ticket_path` has none: its `unsure` says to move them by hand) |
| `note` | only when no criterion is met and the verdict passes: says the work passed on the Human check, the merge gate, or both, alone |
| `acceptance` | per criterion: `criterion` (the ticket's text), `met` (the verifier's; `false` for one needing a human check), `human` (`true` only on one needing a human check), `gate` (`true` only on one checked by the merge gate), `evidence` (the verifier's), `claimed` (the worker's `met`, or `null` if its record left the criterion out) |
| `tests` | the worker's run of the test files covering its change: `{suite_passed, files, full_suite, command, summary}`; the full suite is left to the merge gate |
| `checks` | the checks the verifier ran through `checks.sh run`: the recorded checks with their results, or `{recorded: false, fallback: "no recorded checks (…): found …"}`. With checks recorded, `worker_matches` says whether the worker's evidence listed exactly them (`worker_listed`), and the comment flags it when not. A red recorded check makes each criterion that cites it unmet (all of them when none does); `references/checks.md` |
| `diff` | `summary` (`git diff --shortstat`) and `files` (`<path> +<added> -<deleted>`, comma-separated), base to commit |
| `unsure` | what the worker was unsure of |
| `decisions` | the decisions the worker made alone: its decision cards, as in `evidence-record.md` |
| `cost` | `worker_usd` (every attempt, failed ones included), `verifier_usd` (every verifier), `total_usd` (the ticket's `cost_usd`), `estimate_usd` (the plan's) |
| `verifier` | `attempt`, `model`, `unsure`, `notes` |
| `verified_at` | epoch seconds |

Each ticket's cost is logged in the state file: the worker's and verifier's sessions are both in `tickets.<t>.attempt_costs` (keys `<attempt>` and `verify.<v>`), summed into `cost_usd`, and so into `costs.workers_usd` and `costs.total_usd`. Actual against `estimate_usd` is a retro input.

## The ticket's comment

`evidence.sh comment <run> <t>` prints it from the state file; `wave.sh close` posts it on the ticket before closing, and `verify.sh judge` posts it on a ticket that failed. (A ticket whose verifier failed twice has no contract to post; its decision says why.) Top to bottom: the verdict line and the merge; a table of criteria (met, evidence); the suite, diff stats and cost against the estimate; what the worker (and the verifier) was unsure of; a table of the decisions made alone; the verifier's notes; then the contract itself as JSON, folded, so the tracker holds exactly what the state file holds.

## The wave digest

`evidence.sh digest <run> [--wave N | --all]`, the Engineering chat's report after each wave: a heading line, a table with one row per ticket dispatched in that wave, and one line of cost against the budget (and one naming the blocked tickets, if any).

| Ticket | Outcome | Criteria | Unsure / decisions | Cost |
|---|---|---|---|---|
| #12 (retry failed uploads) | merged as `a1b2c3d`, closed | 3/3 verified | 1 unsure, 2 decisions | $0.42 of $0.50 |
| #13 (billing tab) | blocked: the verifier found 1 of 4 criteria unmet, first: … | 3/4 verified | 0 unsure, 1 decision | $0.61 of $0.80 |

A finished slice comes to the Artisan as a packet built from these contracts at its slice gate (`references/review-gates.md`). Blocked tickets will once the exception gate exists (#70); until then a blocked ticket's decision is in `wave.sh status`'s decision table.
