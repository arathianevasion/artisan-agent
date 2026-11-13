# Cost and usage limits: the budget, the overrun gate and the plan-window guard

Cost surprises come with an explanation, and usage limits never waste work (#72; spec #44, "Cost and usage limits"). Two limits hold back new dispatch, and neither ever stops work already in flight:

- **The budget**, in estimated dollars: the approved estimate plus the overrun allowance (`overrun_allowance_percent`, 25%). Crossing it raises the **overrun gate**.
- **Plan usage**, the limit that really stops work: the five-hour and seven-day windows of the Artisan's claude.ai plan. Getting close to either, or not knowing, **parks** the run.

`${CLAUDE_PLUGIN_ROOT}/scripts/budget.sh` does the work and `${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh` captures the readings. Tested in `tests/budget.test.sh` and `tests/statusline.test.sh`. Skills cite this file rather than copying it.

## Where it is checked

`wave.sh dispatch` runs `budget.sh guard` before every dispatch, retries included, after the scope, status and slot checks. `wave.sh status` runs it too once the orchestrator has ended, so the chat sees a park or an overrun before it launches the next wave. The guard checks, in order:

| Check | Refuses with | Prints |
|---|---|---|
| the run is halted | 12 | why |
| the plan-window guard (below) | 18 | `parked <window> …` |
| the overrun gate is open, or the projection crosses the budget | 17 | `overrun #<issue> …` |
| none of these | 0 | `ok: spent $…, projected $… of $… budget` |

The orchestrator treats 17 and 18 like 9 (no free slot): it dispatches nothing new, keeps waiting on, verifying, merging and closing what is in flight, and reports. The state file says why.

## The budget and the projection

`budget.sh project <run-dir>` prints the projection as JSON. Spent is `costs.total_usd`: every worker, verifier and orchestrator session logged so far (the session's `total_cost_usd`, `references/state-file.md`). Still to come, per ticket in scope:

| Ticket status | Still to come |
|---|---|
| `queued` (a retry included: it pays again) | its whole estimate |
| `in_flight` (its session's cost is logged only when it ends) | its whole estimate |
| `returned`, `merged`, `closed`, `deferred`, `blocked` | nothing |

The projected total is spent plus still to come. When it crosses `plan.budget_usd`, the guard opens the overrun gate. A ticket **ran over** when what it has cost passes its estimate. Orchestrators' spend counts against the budget; their own future cost isn't projected.

Dollar figures are client-side estimates, a consistent proxy rather than a bill.

## The overrun gate

An exception gate, in packet shape (`references/review-gates.md`, "The packet"), opened once per crossing:

- a GitHub issue labelled `review-gate`, titled `Exception gate: overrun (run <id>)` (`overrun 2`, … for later crossings), its body the packet, kept in `gates/overrun-<n>.md`;
- `overrun_gates` in the state file, an `overrun` decision (`gate_actions: ["defer"]`), event `overrun-gate`.

If the issue can't be opened, the gate holds dispatch all the same and the next guard tries again.

**The packet.** Header (kind, role, tickets, what it blocks); summary line (3 decisions, the count of uncertainties; Problem: the projection against the budget; Solution: choose an option; Verification: the spend when it opened); **decision cards**, the options: 1 raise the budget (suggested: the projection plus the allowance), 2 cut scope (the queued tickets, largest first), 3 stop; **uncertainties**, the discovered complexity: each ticket that ran over, by how much, its attempts and failures and what its worker was unsure of; **evidence**, the spend per ticket: estimate, spent, still to come, over by, then orchestrators and the run; the **overall action**.

**Defer only.** The overrun gate can't be approved, bypassed or redirected (spec #44, "Gates and packets"). The Artisan's answer is one card, and the gate is deferred: the run carries on under that card and the issue stays open until the end gate, where the overrun is reviewed with the run. In the chat, show `budget.sh packet <run-dir>` and wait for the Artisan's choice.

| The Artisan says | Call | Effect |
|---|---|---|
| raise the budget to $X | `budget.sh overrun <run-dir> raise <usd> [--by NAME] [--why W]` | `plan.budget_usd` becomes X (refused, 6, under the projection), the change kept in `plan.budget_history`; dispatch carries on |
| cut #a #b | `budget.sh overrun <run-dir> cut <ticket>...` | only queued tickets (6 otherwise), and what's left must fit the budget (6 otherwise): they leave `plan.scope`, status `deferred` with `cut: {gate, by, at}`, a comment on each and its `in-run` label removed; they stay open on the tracker |
| stop | `budget.sh overrun <run-dir> stop` | the run halts (`halted`); work in flight finishes; nothing launches or dispatches again |

Each answer is recorded on the gate (`status: deferred`, `action: defer`, `decision: {card, option, choice, why, by, job: 10}`), decides the `overrun` decision, logs `overrun-decision`, and is posted on the issue. `--action` anything but `defer` is refused with 6 and changes nothing.

## The status-line capture

Claude Code shows plan usage and the context window only to the interactive status line (no plugin can set one: a plugin's settings take only `agent` and `subagentStatusLine`). So the plugin ships a capture and setup installs it:

- `statusline.sh install` copies the capture to `~/.claude/artisan-agent/statusline.sh` (stable across plugin updates; run install again after one) and sets the user's `statusLine` to it with `refreshInterval: 60`. A status line already there is kept and chained (`statusline-next.json`), so its line still shows.
- On every run, Claude Code passes the session's JSON. The capture writes `~/.claude/artisan-agent/usage.json` (`rate_limits.five_hour` and `.seven_day`: `used_percentage`, `resets_at`; `rate_limits.at`, when they were read; the session's `model` and `context_window.size`) and `sessions/<session-id>.json` (the session's model, window and transcript). Input without rate limits (an API-key login, or before the session's first response) leaves the last reading, and its age, as they were.
- **The context window is the session's own** (pilot prerequisite 7): Claude Code's `context_window.context_window_size` (200,000, or 1,000,000 for an extended-context model), else 1,000,000 for a `[1m]` model id and 200,000 otherwise. `drain.sh chat` reads the window captured for its own transcript (`statusline.sh window --transcript F`) before falling back to `chat_context.window_tokens`; the cockpit's context gauge reads `usage.json`.

## The plan-window guard

`budget.sh usage <run-dir>` gives the verdict alone. From the plan's config (`usage_reserve`, `stale_usage_minutes`):

| Reading | Verdict |
|---|---|
| the freshest reading of a window, from the status line or any worker | the one used (each window takes its own freshest reading) |
| no reading newer than 10 minutes (real clock), a worker running | unknown |
| no reading newer than 10 minutes, no worker running | ok, no park: nothing is spending |
| five-hour window at or over 100 − reserve (80%) | park, five-hour, resets at its `resets_at` |
| seven-day window over the ceiling (90%) | park, seven-day |
| a window absent, or past its own `resets_at` | that window counts as empty |
| otherwise | ok |

Unknown stops dispatch exactly like a window near its limit. The first time the guard parks, it records `usage_park` (`window`, `used`, `limit`, `resets_at`, `why`, `resume`), queues a `usage` decision with its options and logs `parked` (`reason: "usage"`). `wave.sh status` then says `next: parked` with the `parked …` line. Offer the Artisan the options, with the reset time as printed:

| The Artisan says | Call | Effect |
|---|---|---|
| resume after the reset | `budget.sh park <run-dir> resume` | at once if a fresh reading is already under the limits; otherwise dispatch carries on once one is (the next guard after the reset) |
| raise the ceiling to P% | `budget.sh park <run-dir> raise <percent>` | a run override (`state.sh override`): seven-day ceiling P, or five-hour reserve 100 − P; refused (6) for an unknown reading or a lower ceiling |
| stop | `budget.sh park <run-dir> stop` | the run halts; work in flight finishes |

Ending a park decides the `usage` decision and logs `unparked` (`how`, `by`); a raise logs `ceiling-raised`.

**Workers report usage too.** The ticket runner starts each session with `--output-format stream-json --verbose`, which emits `rate_limit_event`s (plain `--output-format json` does not). Seen live, one per window, e.g. `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1794610800,"rateLimitType":"seven_day","unifiedWindows":{"seven_day":{"utilization":0.29,"resetsAt":1794610800,"status":"allowed"}}}}`. The runner keeps the stream (`workers/<t>.<n>/stream.jsonl`), turns the latest event into `workers/<t>.<n>/usage.json` (`source: "worker"`, `received_at`, and per window `used_percentage` (utilisation × 100), `resets_at` and `at`, when the runner saw it) and, when the session ends, writes `output.json` as the stream's final `result` event, so everything that reads `output.json` is unchanged. The guard takes each window's freshest reading across the status line and every worker. The time is the runner's own, so a limit Claude Code resends cannot pass as fresh later. A "worker running" is an in-flight ticket whose runner is alive.
