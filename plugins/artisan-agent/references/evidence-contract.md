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
| `acceptance` | yes | one entry per criterion, in the ticket's order: `criterion` (verbatim), `met`, `evidence` (`tests`, `checks`, `diff`, and `why` when unmet), as in `evidence-record.md` |
| `verdict` | no | `pass` or `fail`; advisory, since the contract recomputes it |
| `unsure` | no | what the verifier was unsure of, one sentence each |
| `notes` | no | one paragraph |

`judge` trusts no count it can check. Each of the ticket's criteria takes the verdict entry with the same text (spaces and case aside), else the entry in its position when the counts agree; a criterion with no entry is unmet. The matching rule lives in one place, `scripts/lib/criteria.py` (`extract` reads the criteria, `align` lines the verdict and the worker's claims up with them, `tick` ticks the met ones on the ticket). The contract keeps the ticket's wording, so ticking the ticket's checkboxes always matches.

## The evidence contract

`tickets.<t>.evidence` in the state file, and the JSON at the foot of the ticket's evidence comment: the same object.

| Field | Values |
|---|---|
| `ticket`, `title`, `attempt`, `commit`, `base` | which work was verified: the worker's attempt, its commit and the integration commit it branched from |
| `verdict` | `pass` when every criterion is met, else `fail` |
| `criteria_met`, `criteria_total` | the counts |
| `acceptance` | per criterion: `criterion` (the ticket's text), `met` (the verifier's), `evidence` (the verifier's), `claimed` (the worker's `met`, or `null` if its record left the criterion out) |
| `tests` | the worker's full-suite run: `{suite_passed, command, summary}` |
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

Reviews and blocked tickets will come to the Artisan as full packets once gates exist; until then a blocked ticket's decision is in `wave.sh status`'s decision table.
