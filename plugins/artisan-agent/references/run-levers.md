# Levers on a running run

How the Artisan changes a run that is already going (#76): **steering** a worker, **adding work**, and **urgent** tickets. Script: `${CLAUDE_PLUGIN_ROOT}/scripts/lever.sh`, with `wave.sh dispatch` and `end-gate.sh urgent-*`. Tested in `tests/levers.test.sh` and `tests/main-checkout.test.sh`. Skills cite this file rather than copying it.

## Steering

In version one, steering is stopping a worker and dispatching it again with the Artisan's notes.

```bash
lever.sh steer <run> <ticket> --note "what to do differently"
```

It stops the ticket's worker, commits what it had not committed to its branch as WIP, and puts the ticket back to `queued` with the notes kept in `tickets.<t>.steering`. The next `wave.sh dispatch` is a fresh worker on the same branch with the notes in its prompt. **It is steering, not a failed attempt:** `failures` does not grow, the event is `steered`, and the ticket keeps its attempts under `attempts_per_ticket`.

While a wave's orchestrator holds the state lock, the chat can't write the state file. `steer` leaves `steering/<ticket>.<attempt>.json`, stops the worker, and the orchestrator's next sweep (`sweep.sh`) records the steering from that file instead of a failed attempt.

## Adding work

A higher-priority ticket gets its own plan step, shown as one line, which is the scope gate:

```bash
lever.sh add <run> <ticket> --model M --estimate-usd N [--title T] [--minutes N] [--expected-files a/,b.sh] [--priority P]
# Add #12 (Title): claude-sonnet-5-5, estimate $0.5, run budget $6.25 -> $6.88 (estimate plus the 25% overrun allowance)
lever.sh add … --approve       # the Artisan's yes
```

Without `--approve` nothing is recorded. Approved, the ticket joins `plan.scope` with its caps (as the plan step sets them), `plan.estimate_usd` and `plan.budget_usd` grow by the estimate and its overrun allowance (`plan.additions` records each, with the budget before and after), and it carries `priority` (default 1; planned tickets are 0). The reconciler orders the frontier by priority, then number, so the ticket dispatches in the next wave ahead of lower-priority work. Work in flight is untouched.

## Urgent tickets

Marking a ticket `urgent` is its scope approval:

```bash
lever.sh urgent <run> <ticket> --model M --estimate-usd N [--title T] [--escalation a,b]
```

- It joins the scope at once and its estimate joins the run budget, as for an addition.
- **Escalation tests.** The chat works out which escalation tests the ticket meets as for a planned ticket (`references/end-gate.md`, "Gate placement") and passes them as `--escalation` (`new-seam`, `tracer-bullet`, `vocabulary-adr`, `judgement-criteria`; with `--expected-files`, the config's area settings add `area:<name>`). `lever.sh` runs them through `gate-plan.sh propose`, so the names and the unknown-test refusal (exit 2) are the plan step's, and records them as `plan.tickets.<t>.escalation`. The ticket gets **no** slice or risk gate (a risk gate holds dependents, and it has none in the run); its own end gate packet shows them instead.
- It dispatches at once (`lever.sh pending <run>` lists the urgent tickets waiting; the orchestrator dispatches them after every sweep) on **one extra slot above Max Agents**: urgent tickets are counted apart from Max Agents, one at a time. A second urgent ticket gets exit 9 from `wave.sh dispatch` and waits for the slot.
- It **branches from `main`**, not the integration branch, and skips the blocker and overlap checks. It **keeps its gates and cost cap**: the usage and budget guard, its caps, the verifier.
- It is never on the frontier, never merges into the integration branch (`wave.sh merge` refuses, 6), and is left out of the run's own PRs.
- It ships through **its own end gate and PR**, the same `end-gate.sh` as the run's, scoped to that one ticket and based on `main`:

  | Step | Call |
  |---|---|
  | its packet | `end-gate.sh urgent-packet <run> <t>` |
  | open the gate (once returned with a passing verdict) | `end-gate.sh urgent-open <run> <t>` |
  | the Artisan approves | `end-gate.sh urgent-approve <run> <t> [--why W]` |
  | cut the PR to `main` (body written with upstream `pr`) | `end-gate.sh urgent-cut <run> <t> --body-file F` |
  | the Artisan merges the PR; then | `end-gate.sh urgent-finish <run> <t>` |

  `urgent-finish` merges `main` into the integration branch, runs the plan's **full suite** there (red undoes the merge, queues a decision, exit 7), marks the ticket merged and removes `in-run`. Then `wave.sh close <run> <t>` closes it on the tracker. A merge conflict with `main` gets the one `/artisan-agent:resolve-conflicts` try every merge gets: `urgent-finish` leaves the merge in progress, records it (`tickets.<t>.resolve`, with a `sync` block) and exits 11 naming the paths; then `wave.sh resolved <run> <t>` (adding `--gave-up` after UNRESOLVED) commits it and runs the full suite through the detached merge gate (exit 20 while it runs; `wave.sh merge <run> <t>` finishes it). Green marks the ticket shipped as above. A failed or already-used try, or a red suite, aborts or undoes the merge and queues an `exception` decision naming the ticket and paths (`wave.sh status` lists it); the urgent ticket is not blocked, its PR being merged.

## Starting `/implement-plan` while a run holds the lock

The run-start hook (`guard/protect.sh run-start`) refuses a second plan and leaves it as a `plan` issue. It lets two requests through to the add-work flow instead, because they are not a second run: a request whose first word is `add` (or `add-work`) and that names the tickets to add (`#45`), and one whose first word is `urgent` (or `--urgent`) and names the urgent ticket. `add login page` names no ticket, so it is a new plan and is refused as before. The chat then follows `skills/implement-plan/SKILL.md`, "Adding to a running run".
