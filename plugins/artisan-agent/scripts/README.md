# Worker scripts

How an orchestrator starts a worker, waits on it and judges it. Files are the truth: each script is tested through the files it writes and reads (`tests/run-ticket.test.sh`, `tests/wait-any.test.sh`, `tests/classify-worker.test.sh`), with a fake `claude` in `tests/fixtures/fake-claude/`. Skills cite them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>`.

| Script | Does | Returns |
|---|---|---|
| `run-ticket.sh` | Launches one capped headless worker (or, with `--role orchestrator`, a wave's orchestrator; with `--role verifier`, a ticket's verifier) detached; always leaves an exit record. Refuses to launch into a run folder with no state file (exit 4) | the runner's PID, at once |
| `wait-any.sh` | Blocks in the foreground until a run's files change, or a timeout | `new`, `grew` or `changed <path>` lines; 124 on timeout, 2 on bad usage |
| `classify-worker.sh` | Judges one attempt from its files | `<status> <reason>` |
| `questions.sh` | A worker's filed question, the ticket that waits on it, the answer's way back, pull-or-carry-on for a deferral, provisional cards ([`references/worker-questions.md`](../references/worker-questions.md); `tests/questions.test.sh`) | a ticket number, or lines and tables |
| `checks.sh` | The one reader of the recorded checks (`CODING_STANDARDS.md` `## Checks`): `json`, `list`, `suite` (the plan's `suite_command`), `run` (the evidence's `checks`; `--worker` skips the check that is the suite, left to the merge gate). Worker, verifier and plan step read checks only through it ([`references/checks.md`](../references/checks.md); `tests/checks.test.sh`) | JSON or lines; 7 a check red, 16 none recorded / nothing to run |
| `verify.sh`, `evidence.sh` | A fresh verifier per ticket, and the evidence contract shown on the ticket and in the wave digest ("Verification and evidence", below) | one verdict line; Markdown |
| `move.sh` | Moves an idle run between laptop and always-on host through its `runs/<id>` branch; the run lock travels with the state; `out` marks the local copy moved before the push and undoes it if the push fails, so the run is never live twice (`skills/implement-plan/references/host-and-move.md`; `tests/move.test.sh`) | lines; 3 not live here, 4 not idle, 5 live elsewhere, 6 a push refused |
| `upstream-check.sh` | The retro's upstream-updates check: refresh, compare, mechanical check, judgement agent, report, port tickets (`skills/retro/SKILL.md`, "Upstream check"; `tests/upstream-check.test.sh`) | lines and tables; 10 moved |
| `model-prices.sh` | The retro's price check (#91): a capped agent reads Anthropic's published pricing, compare against `references/model-prices.json`, offer the update; nothing changes until `apply` (`skills/retro/PRICES.md`; `tests/model-prices.test.sh`) | "no price change"; a table, 10 differ |
| `login-check.sh` | The login-expiry check before a run on the host; `stamp` records the login in `login.json` (never `host.json`); `legacy` and `cleanup` fix a `host.json` an old stamp made (`skills/setup/HOST.md`; `tests/host.test.sh`) | 15 refused |
| `host-notice.sh` | Before a run starts: does this project's `host_configured` send it to a host this machine is not? Prints the one-line notice and offer (`skills/setup/HOST.md`; `tests/host.test.sh`) | 0 run here, 10 offer the host first (this script's own; not `wave.sh`'s 10) |

Each script's header has its full usage.

## Files in a run folder

All paths are inside `.artisan-agent/runs/<run-id>/`. `<t>` is the ticket, `<n>` the attempt (1 unless `--attempt` says otherwise).

| Path | Written by | What |
|---|---|---|
| `results/<t>.<n>.exit.json` | runner, last, atomically | the exit record |
| `results/<t>.<n>.result.json` | the worker (path in `$ARTISAN_RESULT_FILE`) | the worker's result file; its shape belongs to the worker skill |
| `results/findings/<t>.jsonl` | the worker (path in `$ARTISAN_FINDINGS_FILE`) | one finding per line, appended across attempts |
| `workers/<t>.<n>/runner.pid` | runner | the runner's PID, for the sweep |
| `workers/<t>.<n>/output.json` | the runner | the stream's final `result` event (what `--output-format json` printed), including its result text |
| `workers/<t>.<n>/stream.jsonl` | `claude --output-format stream-json --verbose` | the session's whole event stream |
| `workers/<t>.<n>/usage.json` | the runner | the latest `rate_limit_event`, per window, with the time the runner received it (the usage guard reads it) |
| `workers/<t>.<n>/prompt.md`, `stderr.log`, `runner.log` | runner | the full prompt as sent, and logs |
| `results/verify-<t>.<v>.result.json`, `.exit.json` | the verifier, the runner | the verdict and the verifier's exit record |
| `prompts/verify-<t>.<v>.md`, `.criteria.json` | `verify.sh start` | the verifier's prompt and the criteria it was given |
| `verify/claims/<t>.<v>/` | `verify.sh start` | the claim on verifier `<v>`: one start launches it, however many run at once |
| `verify/checks/<t>.<v>.json`, `.logs/` | the verifier, through `checks.sh run --out` | the checks it ran (recorded, or its fallback) and their full output |
| `verify/<t>.<n>.evidence.json`, `.comment.md` | `verify.sh judge` | the evidence contract as built (also in the state file), and the comment posted on a fail |
| `.wait-any.seen` | `wait-any.sh` | what the waiting caller has already seen |

`wait-any.sh` watches only `results/`. Anything starting with a dot is a write in progress and is skipped.

The exit record:

```json
{"ticket":"46","attempt":1,"exit_code":0,"reason":"exited","runner_pid":123,
 "started_at":"2026-11-10T19:38:48Z","finished_at":"2026-11-10T19:39:14Z",
 "max_budget_usd":"3.00","max_turns":60,"deadline_seconds":3600,
 "output":"workers/46.1/output.json","result_file":"results/46.1.result.json"}
```

`reason` is `exited` (claude ended by itself, including a crash or being killed from outside), `deadline` (the runner stopped it at its deadline), `stopped` (the runner got TERM or INT and stopped it) or `runner-error` (the runner itself failed). `exit_code` is claude's, so 128 + the signal number when it was killed (137 for SIGKILL, 139 for SIGSEGV). If the runner itself gets SIGKILL, it can't write the record; `classify-worker.sh` reports that as `failed vanished`, because the runner PID is gone and there is still no exit record on a second look (the runner writes the record in its exit trap and then exits, so a dead PID alone proves nothing). A runner pid file that is empty or unreadable is an error, exit 3, never `vanished`: callers (`verify.sh`, `wave.sh`, `sweep.sh`) stop and run again instead of treating it as a dead session.

## Caps

| Cap | Value | Override |
|---|---|---|
| `--max-budget-usd` | twice `--estimate-usd` | none |
| `--max-turns` | 40 per estimated dollar, rounded up, at least 20 | `--max-turns` |
| wall-clock deadline | twice `--expected-minutes` | `--deadline-seconds` |

Because `--max-turns` limits each turn rather than the whole run, the budget cap and the deadline are what really bound a worker. Hitting any cap is a failed attempt.

## Completion

A worker's session is judged by its result text, never by its exit code alone: a session blocked by a hook exits 0 with `is_error: false`. The runner adds notes to every prompt that give the worker its file paths, tell it not to leave background commands running, and ask it to end its final reply with this line, only once the ticket is done and the result file is written:

```
ARTISAN-WORKER: complete
```

An attempt is `completed` only when the JSON output is a `success` with `is_error: false`, the last non-empty line of its result text is the completion line, and the result file exists. A clean exit without the line is `not-completed`. Every `failed` reason (`deadline`, `stopped`, `budget`, `turns`, `error`, `crashed`, `vanished`) is a failed attempt.

## Detachment

The runner starts a new session (`setsid`, or perl's `POSIX::setsid` on macOS, which has no `setsid` command) under `nohup`, with stdin from `/dev/null`. It doesn't belong to the launcher's process group or terminal, so the launcher exiting, a hang-up, or the Bash tool's 2-hour cap on background commands won't stop it. The worker runs in its own process group under the runner, so the runner can stop it, and anything it left running, without stopping itself. When the worker exits, the runner stops anything still running in that group.

## Needs

`bash` 3.2 or later, `awk`, `perl` (macOS, where `setsid` is missing) and `jq` (`classify-worker.sh`). All ship with macOS and with GitHub's Ubuntu runners.

## Hand check

Not covered by the script tests; to do once by hand on the machine that will run workers:

1. In a throwaway repo, launch a real logged-in worker with `run-ticket.sh --estimate-usd 1 --expected-minutes 150 --max-turns 60 -- --no-session-persistence --model haiku`. Use a prompt that keeps it busy cheaply for more than 2 hours, for example a foreground `sleep 540` repeated about 15 times with a file check between each. That gives a $2.00 budget and 60 turns, enough room that neither cap ends the run before the 2 hours.
2. Close the launching terminal or chat at once.
3. After 2 hours, check that `workers/<t>.1/runner.pid` is still alive. When it ends, check that `results/<t>.1.exit.json` exists and that `classify-worker.sh` gives the expected status.

# Config and the plan step

How the plan step reads the project config, estimates a run and records the numbers the Artisan approved. Tested in `tests/config-plan.test.sh`.

| Script | Does | Returns |
|---|---|---|
| `config.sh` | Reads `.artisan-agent/config.yml` with every missing key filled from its default | the effective config as JSON, or one setting |
| `plan.sh build` | Turns a draft plan into the run envelope: config with this run's overrides, estimates, caps, total and budget | the plan JSON for `state.sh init` |
| `plan.sh render` | Prints the one approval: waves, model, estimate and expected files per ticket (a warning for each ticket with none, which runs alone), total, Max Agents, the suite command (the recorded checks, a change from them, or the fallback) and every config number | Markdown |

**The draft's shape.** Per ticket in scope: `title`, `model`, `blocked_by`, `expected_output` and `expected` (`input_tokens`, `output_tokens`, `minutes`). `blocked_by` is required: the ticket numbers of its open blockers, copied from `resolve-scope.sh`'s `tickets[].blocked_by` (native dependencies, or the body's "Blocked by" line where the tracker has none; a blocker outside the scope is kept). `[]` is valid; a ticket with no `blocked_by` field makes `plan.sh build` exit 1. The critical path, a hands-on pick's delay and parking all read it. `plan.sh` makes no tracker calls.

## The project config

`.artisan-agent/config.yml` is committed. Every setting and its default is in `templates/config.yml`, the one place defaults are written; `/artisan-agent:setup` copies it into a project. A key left out or left empty falls back to its default; a value of the wrong type stops the read with the key named. The file is plain YAML: maps, scalars, `[flow, lists]` and `- item` lists of scalars (`scripts/lib/yaml-subset.py`, standard-library `python3`).

| Setting (ticket #55) | Key | Default |
|---|---|---|
| Max Agents | `max_agents` | 5 |
| sweep | `sweep_minutes` | 5 |
| context drain | `context.drain_percent` | 30 |
| context review | `context.review_percent` | 50 |
| chat warning | `chat_context.warn_percent` | 30 |
| chat automatic compaction | `chat_context.compact_percent` | 40 |
| chat expected window (tokens) | `chat_context.window_tokens` | 1000000 |
| overrun allowance | `overrun_allowance_percent` | 25 |
| usage reserve | `usage_reserve.five_hour_reserve_percent`, `usage_reserve.seven_day_ceiling_percent` | 20, 90 |
| stale usage reading | `stale_usage_minutes` | 10 |
| attempts per ticket | `attempts_per_ticket` | 2 |
| deferral review | `deferral_review_days` | 30 |
| evidence threshold | `evidence_threshold` | 3 |
| hands-on nudge | `hands_on_nudge_runs` | 5 |
| areas, per-area gates | `areas` (`<name>: {paths, gates}`) | none |
| team guardrails repo | `team_guardrails_repo` | none |
| estimate multipliers | `estimate_multipliers` (`<model id>` or `all`: number) | none |
| minimum estimates | `minimum_estimates` (`<model id>` or `all`: dollars) | Fable $2.00, Opus $1.00, Sonnet $0.50, Haiku $0.10, all $0.50 (source in `templates/config.yml`) |
| host configured | `host_configured` | false |

## Overrides are for this run only

`plan.sh build --set key=value` and, once the run has started, `state.sh override <run-dir> <key> <value>` change a number in the plan's `config` and record `{value, project}` in its `overrides`. Neither writes `config.yml`; a lasting change is job 23, made by PR. The key must be a setting above (dotted), or `estimate_multipliers.<model>` or `minimum_estimates.<model>`, and the value must have the setting's type. `max_agents` and `attempts_per_ticket` are kept in step at the top of the plan, where `state.sh` and the sweep read them.

## Estimates

In estimated dollars, per ticket, then summed; the budget is the total plus the overrun allowance.

- **History.** When state files of other runs (`.artisan-agent/runs/*/state.json`, or `--history DIR`) hold merged tickets on the same model with a logged `cost_usd`: their mean cost, times `estimate_multipliers.<model>`, else `estimate_multipliers.all`, else 1.
- **Price.** Otherwise: the model's price in `references/model-prices.json` times the ticket's expected size (`expected.input_tokens`, `expected.output_tokens`). There are no per-tier defaults: a model missing from the price table, with no history, is refused. Keep the table current; it says the date its prices were taken.
- **Minimum.** Whichever of the two gives an estimate below `minimum_estimates.<model>` (else `.all`) is raised to it, before caps, total and budget are derived. The ticket's `estimate_basis` becomes `{mode: "minimum", model, minimum_usd, estimated_usd, was}` and the approval table's From column reads "minimum for <model>". The defaults cover every model in `references/model-prices.json`; their source is the comment in `templates/config.yml`. Override for one run with `plan.sh build --set minimum_estimates.<model>=N`.

Caps follow `run-ticket.sh`: `max_budget_usd` twice the estimate, `max_turns` 40 per estimated dollar (at least 20), `deadline_seconds` twice `expected.minutes`.

## Scope

The run's scope is exactly the approved `scope`. `state.sh in-scope <run-dir> <ticket>` exits 0 or 4; `state.sh dispatch` and `run-ticket.sh` (whenever its run folder holds a state file) refuse a ticket outside it with exit status 4 before anything starts.

## Run lock and doc changes

| Script | Does | Returns |
| :- | :- | :- |
| `run-lock.sh check [dir]` | one run per repo: looks for a `runs/*/state.lock` naming a live pid in the repo's main checkout (stale locks ignored) | 0 free; 3 held, printing `<run-id> <pid>`; 1 not a repo |
| `doc-change.sh start <name>` / `finish <name>` | a chat's doc change: a short-lived `doc/<name>` branch worktree beside the repo, then a fast-forward of the main checkout (rebasing first if it moved) | the worktree path / 0; 1 when refused (dirty main, empty branch, conflict) |

The rules, the plugin hook and the fallbacks: `references/main-checkout.md`, `guard/README.md`. Tests: `tests/main-checkout.test.sh`.

# Plans: `/artisan-agent:to-plan` and plan issues

`to-plan.sh` is the arithmetic and the tracker calls behind `skills/to-plan/SKILL.md`; `resolve-scope.sh` is how `implement-plan` reads plan issues back. Tested in `tests/to-plan.test.sh`, with the fake `gh` (which also answers `issue create`, sub-issue and blocked-by writes).

| Command | Does | Exit status |
| :- | :- | :- |
| `to-plan.sh graph --repo <o/n> <ticket>...` | reads the tickets: title, acceptance criteria (the checkboxes under `## Acceptance criteria`), blockers within the set, open blockers outside it as `external_blockers` | 0, 1 |
| `to-plan.sh propose --graph F --budget USD` | proposes plans (JSON) | 0, 1 |
| `to-plan.sh split\|merge\|reorder\|move <plans> --graph F ...` | edits the plans file in place, renumbering; refused, file untouched, when a blocker would follow its dependent | 0, 1 |
| `to-plan.sh check <plans> --graph F` | every ticket in exactly one plan, no blocker in a later plan | 0, 1 |
| `to-plan.sh render <plans> --graph F` | the approval view: a table of plans, then each plan's tickets with blockers, estimates and acceptance criteria, then warnings | 0, 1 |
| `to-plan.sh publish <plans> --graph F --repo <o/n> --approved [--replace-parent]` | creates the `plan` issues, sub-issues and blocking | 0, 1 |
| `resolve-scope.sh --repo <o/n> <issue>...` | plan issues and tickets in, the run's tickets out, each with its open `blocked_by` (a failed blocker read exits 1 naming the ticket) | 0, 1, 2, 3 |

**The graph** is a JSON file the chat completes after `graph`: per ticket `slice` (what reviewable thing it helps make; none means its own slice) and an estimate, either `estimate_usd` or `model` with `expected.input_tokens` and `expected.output_tokens` priced from `references/model-prices.json` (the plan step's method). No estimate is refused; there are no defaults. The budget has no default either.

**How a proposal is cut.** Tickets are grouped by slice; slices that block each other both ways become one unit; units are put in order, blockers first (ties by lowest ticket number); then packed in that order, starting a new plan when the next unit would take the plan over the budget. So a plan boundary is only ever between slices, every blocker is in the same or an earlier plan, and a single slice bigger than the budget gets a plan of its own, flagged in the view. A cycle in the tickets is refused with the cycle named. Edits may split a slice (the Artisan's call); the view then warns that neither plan ends at a slice reviewable end to end.

**Plans file** (`plans.json`): `{"schema_version": 1, "budget_usd": 6, "plans": [{"slice": "...", "tickets": ["1", "2"], "issue": 71}]}`. A plan's number is its position. `issue` appears once published; published plans refuse edits, and a repeat `publish` skips plans that already have an issue, so a failed publish resumes without duplicates.

**Plan issues.** Labelled `plan`, titled `Plan <n>: <slice>`, the body listing its tickets as a task list. Each ticket is added as a sub-issue (`POST issues/<plan>/sub_issues`); a plan depending on earlier plans (through its tickets' blockers, with implied dependencies removed) is blocked natively by them (`dependencies/blocked_by`). GitHub allows one parent per issue: a ticket already under its spec is kept there, with a notice, unless `--replace-parent` is given, and stays in its plan's body either way. `resolve-scope.sh` reads sub-issues first and the body's task list second.

# Waves: the two-tier run

`wave.sh` is the run's own steps, split by tier as `skills/implement-plan/SKILL.md` describes. Tested in `tests/wave.test.sh`, end to end, with the fake `claude` running a scripted orchestrator and worker (`FAKE_CLAUDE_MODE=script`) and a fake `gh` over a folder tracker.

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `wave.sh start <run-dir> [--base REF]` | Engineering chat | creates the integration branch and the run's integration worktree, `<repo>-wt/run-<run-id>` | 0, 1 |
| `wave.sh launch <run-dir> [--resume] [--handoff]` | Engineering chat (`--handoff`: the orchestrator, through `drain.sh handoff`) | refuses while the run is halted (12) unless `--resume` records the Artisan's decision to carry on; launches the next wave's orchestrator detached (`run-ticket.sh --role orchestrator --lock-from <chat pid>`), in the integration worktree, briefed by `skills/implement-plan/references/orchestrator.md`; the next wave once the last orchestrator completed, the same wave again if it failed | 3 while an orchestrator runs; 6 a `--handoff` from anyone but the running orchestrator that recorded it |
| `wave.sh status <run-dir>` | Engineering chat | the orchestrator's state from its exit record; once it has ended, takes the lock back, reconciles and says what's next (`launch`, `wait`, `halted`, `decide`, `parked`, `blocked`, `done`), with a ticket table | 0 |
| `wave.sh dispatch <run-dir> <ticket>` | orchestrator | refuses unless in scope (4), queued, every blocker merged into the integration branch or closed (5), a slot free under Max Agents (9), its expected files overlap nothing in flight or in this wave (10) and `budget.sh guard` passes (12, 17, 18); then a worktree from the integration tip and a worker running `/artisan-agent:implement`. A retry waits for the failed session to end (8) and carries its failure evidence | 0, 1, 4, 5, 8, 9, 10, 12, 17, 18 |
| `wave.sh merge <run-dir> <ticket>` | orchestrator | refuses unless the record's commit is the branch tip and a fresh verifier passed this attempt at that commit (13, nothing changed; `verify.sh`); an attempt that didn't complete is a failed attempt (retried, or blocked after the last); merges `--no-ff` in the integration worktree, runs `plan.suite_command`, records the merge, removes the worker's worktree | 6 refused or conflict after its try, 7 suite red (both undo and block), 8 worker still running, 11 conflict left for its one try, 13 not verified |
| `wave.sh resolved <run-dir> <ticket> [--gave-up WHY]` | orchestrator | after `/artisan-agent:resolve-conflicts`: aborts and blocks if anything is still conflicted, marked or unstaged (or it gave up), else commits the merge and runs the suite as `merge` does | 0, 6, 7 |
| `wave-width.sh pick <run-dir>` / `check <run-dir> <ticket>` | orchestrator | the tickets to dispatch now: the smallest of Max Agents less those in flight, the frontier, and tickets with non-overlapping `expected_files`; `check` is dispatch's overlap refusal | 0, 10 |
| `wave.sh block <run-dir> <ticket> <reason>` | orchestrator | blocks a returned ticket it won't merge (the diff misses its expected output): an exception decision for the Artisan and a `blocked` event | 0, 4 |
| `wave.sh close <run-dir> <ticket>` | orchestrator | merged tickets only: posts the evidence contract (`evidence.sh comment`), ticks the criteria the verifier found met (`lib/criteria.py tick`), closes the ticket | 0, 1 |
| `wave.sh report <run-dir>` | orchestrator | halts the run if every ticket dispatched in the wave ended blocked, then the wave report, JSON, for its result file | 0 |
| `human.sh suggest --draft F` / `annotate --draft F` | Engineering chat (`annotate`: `plan.sh build`) | the one hands-on candidate table, off the critical path; the plan's `hands_on` with its focus and delay (1: more than one, outside the scope, no focus) | 0, 1 |
| `human.sh sync\|setup\|start\|take <run-dir>` | orchestrator, chat | worktrees from the integration tip for `ready-for-human` tickets, which are never dispatched; takes the ones the Artisan finished as `returned` | 0, 1, 4, 5 |
| `human.sh done <run-dir> <ticket>` | chat | the Artisan says it's done: refused (6) with uncommitted work or no commit; filed, and taken unless the lock is held (3) | 0, 3, 6 |
| `human.sh verdict\|status <run-dir>` | chat | the verifier's feedback as a table; every hands-on ticket and where it stands | 0, 1 |
| `human.sh parked <run-dir> [--record]` | `wave.sh status` | 0 and a line when only a hands-on ticket and its dependents are left (`next: parked`); 1 otherwise | 0, 1 |

Hands-on tickets: `skills/implement-plan/references/hands-on.md`. Tested in `tests/human.test.sh`.

Wave width, serial merges, the one conflict try, two attempts and the halt are described in `skills/implement-plan/references/parallel-waves.md` and tested end to end in `tests/parallel-waves.test.sh`, with a scripted orchestrator that follows that page and a stand-in for the resolve skill.

The orchestrator's files sit beside its workers' in the run folder, named `orchestrator-w<wave>.<attempt>`: `results/…exit.json`, `results/…result.json` (the wave report) and `workers/…/`. So `classify-worker.sh <run-dir> orchestrator-w<wave> <attempt>` judges it, and `wait-any.sh` wakes on its exit record.

**The lock passes with the work.** The chat holds the state lock between waves with its own session's pid. `wave.sh launch` records the orchestrator, then `run-ticket.sh --lock-from` makes the orchestrator's runner take the lock over before its session starts and export its pid to the session as `ARTISAN_WRITER_PID`. When the orchestrator exits, the lock is stale, and `wave.sh status` takes it back for the chat. A worker never gets a writer pid.

**Environment for trials.** `ARTISAN_CLAUDE_ARGS` (split on whitespace) is added to every orchestrator and worker session, for example `--plugin-dir …`, the flags from `tests/helpers/live-hooks.sh` and `--no-session-persistence`. `ARTISAN_MAX_BUDGET_USD` caps any one session's `--max-budget-usd`. `ARTISAN_HOOK_PROOF` (a file path) makes `compact-hook.sh` append one line per hook run, so a live harness can prove a plugin hook fired (#105).

## Exit status

Every exit code `wave.sh` and `verify.sh` use (and `checks.sh`'s 7 and 16, `budget.sh`'s 17 and 18), in one table: a number means the same thing in both, so an orchestrator can act on it without knowing which script it came from. Codes 0 to 12 are as they were before the verifier; 13 and 14 are the verifier's (#57).

| Code | Means | From | Do |
| :- | :- | :- | :- |
| 0 | done | all | carry on |
| 1 | error (a missing file, a bad state, a tracker that can't be read) | all | read the one-line message |
| 2 | bad usage | all | fix the call |
| 3 | the state lock is held, or an orchestrator is still running | `launch`, `status`, any write | wait |
| 4 | the ticket is outside the approved scope | `dispatch`, `block`, `verify.sh start` | nothing: it isn't this run's |
| 5 | a blocker is not merged into the integration branch, or merged under a risk gate not yet cleared (`drain.sh gate`), or in a slice whose review gate is not yet approved (`gate.sh`) | `dispatch` | leave it for a later wave |
| 6 | refused: blocked, or a failed attempt (`queued` again if it has attempts left); for `launch --handoff`, not the orchestrator that recorded a hand-off | `dispatch`, `merge`, `resolved`, `verify.sh start`, `verify.sh judge`, `launch --handoff` | if `queued`, dispatch the retry; if blocked, leave it for the Artisan; `launch --handoff` only through `drain.sh handoff` |
| 7 | the suite went red after the merge (undone, blocked); for `checks.sh run`, a check failed | `merge`, `resolved`, `checks.sh run` | carry on with the rest |
| 8 | a worker or verifier is still running or ending (from `verify.sh start`, also: another call's verifier could not launch or has not come up yet) | `dispatch`, `merge`, `verify.sh start`, `verify.sh judge` | wait, then call again |
| 9 | no free slot under Max Agents | `dispatch` | wait for a ticket to finish |
| 10 | its expected files overlap a ticket in flight or in this wave | `dispatch`, `wave-width.sh check` | leave it for a later wave |
| 11 | a merge conflict, left in progress for its one try | `merge` | `/artisan-agent:resolve-conflicts`, then `wave.sh resolved` |
| 12 | the run is halted | `launch` | the Artisan decides; `launch --resume` |
| 13 | not verified: no passing verdict for this attempt at this commit | `merge` | `verify.sh start`, then `judge` |
| 14 | the verifier itself failed (no attempt used) | `verify.sh judge` | `verify.sh start` once more |
| 15 | the claude.ai login would expire mid-run, or the host has no login stamp | `launch` (a wave launch, on a host) | log in again, `login-check.sh stamp` |
| 16 | no checks recorded (`list`, `suite`), or nothing to run (`run`) | `checks.sh` | fall back to discovery and say so (`references/checks.md`) |
| 17 | the overrun gate holds new dispatch: the projection crossed the budget | `dispatch`, `budget.sh guard` | dispatch nothing new; finish what is in flight; the Artisan answers the gate |
| 18 | parked on plan usage: a window near its limit, or the reading unknown | `dispatch`, `budget.sh guard`, `budget.sh usage` | dispatch nothing new; finish what is in flight; the Artisan resumes, raises the ceiling or stops |

`dispatch` (through `budget.sh guard`) also refuses with 12 while the run is halted.

# Verification and evidence

A fresh verifier per returned ticket, and the evidence contract it produces: in the state file, on the ticket, and in the chat's wave digest. The flow, the verdict and the contract: `references/evidence-contract.md`; the verifier's brief: `skills/implement-plan/references/verifier.md`. Tested in `tests/verify.test.sh` (and end to end in `tests/wave.test.sh` and `tests/parallel-waves.test.sh`), with the fake `claude` scripting the verifier (`FAKE_CLAUDE_SCRIPT_VERIFIER`).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `verify.sh start <run-dir> <ticket>` | orchestrator | for a returned ticket whose attempt completed and whose record names its branch tip (the same check as `wave.sh merge`, in `lib/wave-lib.sh`): reads its criteria (`lib/criteria.py extract` over the tracker body, or `ticket_path`), checks out the worker's commit in a detached worktree, `<repo>-wt/<run-id>-verify-<t>.<v>`, and launches the verifier there (`run-ticket.sh --role verifier`, id `verify-<t>`). Idempotent per attempt: while the attempt has a verifier running, ended but not judged, or passed, or another call is starting one (claimed with `mkdir verify/claims/<t>.<v>`, cleared if that start ends before recording the verifier), it launches nothing and prints that verifier's pid; only after judge's 14 does it start the next | 0, 1, 4, 6, 8 |
| `verify.sh judge <run-dir> <ticket>` | orchestrator | once the verifier has ended: lines its verdict up with the criteria (`lib/criteria.py align`), builds the evidence contract and writes it (`tickets.<t>.evidence`, event `verified`), logs the worker's and verifier's cost, removes the verifier's worktree. A fail is a failed attempt (retried with the verifier's findings, or blocked after the last) and posts the contract on the ticket. Prints one line: `pass m/n`, `fail m/n retry: <first unmet>`, `fail m/n blocked: <first unmet>` or `error <reason>`. Judging again repeats the line and writes nothing | 0, 1, 6, 8, 14 |
| `evidence.sh comment <run-dir> <ticket>` | orchestrator (via `wave.sh close`, `verify.sh judge`) | the ticket's evidence comment, from the state file's contract, ending in the contract as JSON | 0, 1 no contract |
| `evidence.sh digest <run-dir> [--wave N \| --all]` | Engineering chat | the wave digest: one table row per ticket dispatched in the wave (default the last), then cost against the budget | 0 |

`run-ticket.sh --role verifier` launches like a worker (detached, capped, always an exit record) but needs an id starting `verify-`, skips the scope check and never gets a writer pid. A verifier is not a ticket and takes no slot under Max Agents.

## Findings

`findings.sh` relays what one worker found to the workers it concerns, and files it when they have finished. The flow: `references/findings.md`. Tested in `tests/findings.test.sh`. `run-ticket.sh` starts every worker with `--name worker-<ticket>` and `--settings '{"crossSessionInbound":"accept"}'` so a relay reaches it.

| Command | Does | Exit status |
| :- | :- | :- |
| `findings.sh pending <run-dir>` | one JSON line per (finding, ticket in its `blocks`) not yet handled: `relay` (target in flight; has `name` and `message` for `SendMessage`), `comment` (queued or blocked) or `triage` (finished or outside the run) | 0, 1 |
| `findings.sh mark <run-dir> <from> <seq> <target> <action>` | comments on both tickets (or files a `needs-triage` ticket), then records it in `relays` and the event log; once | 0, 1, 3 |
| `findings.sh add <run-dir> <from> <title> <why> [target...]` | a late fact from a worker's result notes, appended to its findings file once per title, then swept | 0, 1, 3 |

The sweep also reads a blocked result's `design_question`: a `design` decision for the Artisan and a `slicing` entry in `lessons`.

## Guardrails

`guardrails.sh` reads the three guardrail levels at the point of use; the rules are `references/guardrails.md`. Tested in `tests/guardrails.test.sh` with a local team repo and a throwaway individual home (`ARTISAN_HOME`, `ARTISAN_TEAM_CACHE`, `ARTISAN_TEAM_URL_BASE`; `ARTISAN_HEALTH_DIR` for the recorded health report).

| Command | Does | Returns |
|---|---|---|
| `guardrails.sh wave-start <run-dir> <wave>` | called by `wave.sh launch`: fetches the team, product and individual sources, brings `main` into the integration branch if a product guardrail changed, records the plugin version and each source's commit in the state file | one JSON line; 6 on a conflict (decision queued, wave not recorded) |
| `guardrails.sh resolve [--run-dir D] [--role R]` | the guardrails in force by the stated precedence, read at the commits the latest wave recorded | JSON: `applied`, `own_reviews`, `overridden`, `conflicts` |
| `guardrails.sh table [--run-dir D]` | the packet's "Guardrails applied" section | a markdown table |
| `guardrails.sh tighten --level L --who NAME --reason TEXT ...` | writes or tightens a guardrail with its origin or move: individual by commit, product and team as a branch (`--pr` opens the PR) | 5 on a loosening, 2 on a `--who` that names an agent |
| `guardrails.sh loosen --level L --who NAME --reason TEXT --id ID --strict N --evidence TEXT` | the retro's loosening path: lowers an existing guardrail's strictness and records a `loosen` move with its evidence, who and run | 2 with no evidence or an agent `--who`, 5 when `--strict` isn't lower, 7 for the scope floor (`key: scope-floor`) or a defer-only gate (`defer_only: true`), 8 when the latest `health --record` report doesn't propose it (or there is none); `--override-reason TEXT [--run-dir D]` proceeds and records the reason and who as a bypass |
| `guardrail-health.sh health\|spot-check\|spot-check-record\|audit\|hands-on\|backstop --runs DIR...` | the retro's guardrail health (fired, bypassed or never fired, with origin), loosen and tighten proposals at the threshold, the spot-check, miss and discard audits, the hands-on question and nudge, and the backstop scan. Reads run history, changes nothing but the `spot-check` event and, with `health --record`, the latest report `loosen` follows (`ARTISAN_HEALTH_DIR`). Rules and event shapes: `references/guardrail-health.md`; tested in `tests/guardrail-health.test.sh` | JSON, or a markdown table with `--table` |
| `guardrails.sh sources` | each source's current commit | JSON |

## Slice gates

`gate.sh` opens a slice's review gate once every ticket of the slice has merged, and takes the Artisan's answers; `lib/packet.py` renders the packet. The rules, the packet and the answers: `references/review-gates.md`. Tested in `tests/gate.test.sh`, end to end with the fake `claude` and the fake `gh`.

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `gate.sh sync <run-dir>` | both (`wave.sh close`, `wave.sh status`) | folds in answers given while the lock was held, approves a gate closed by hand on the tracker, opens every gate that is due: `opened #<issue> <gate-id>` | 0, 1, 3 |
| `gate.sh due <run-dir>` / `open <run-dir> <gate-id>` | orchestrator | the gates due; open one: the packet, the `review-gate` issue natively blocking only the slice's dependents, a `review-gate` decision; prints the issue (again, on a repeat) | 0, 1, 6 not due |
| `gate.sh holds <run-dir> <ticket>` | `wave.sh dispatch` | `held` when the ticket's slice gate is due and not approved, else `free`; dispatch refuses its dependents (5) on anything but `free`, so an error holds | 0, 1 |
| `gate.sh chat <run-dir> [<issue>]` / `packet` / `list` | Engineering chat | the compressed packet; the full one; a table of the run's gates | 0 |
| `gate.sh approve <run-dir> <issue>` | Engineering chat | "keep all": the remaining cards kept, the decisions posted, the issue closed | 0, 1, 6 |
| `gate.sh change <run-dir> <issue> <card> <choice>` | Engineering chat | a rework ticket in the run; prints its number | 0, 1, 6 |
| `gate.sh guardrail <run-dir> <issue> <card> <level> <reach>` | Engineering chat | keeps the card as a guardrail to make, noted for the retro | 0, 1, 2, 6 |

## Gate actions, exception gates and parking

`gate-action.sh` answers a gate (approve, redirect, bypass, defer), opens an exception gate for a ticket the run gave up on or a check that won't go green (retry with notes, reslice, take it myself, drop), and parks the run when everything left waits behind open reviews; `state.sh decide` answers any waiting decision. The rules and what each action leaves behind: `references/gate-actions.md`. Tested in `tests/gate-actions.test.sh`, end to end with the fake `claude` and the fake `gh`.

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `gate-action.sh approve <run-dir> <issue>` | either chat | a review gate: `gate.sh approve`, with optional `--why`, `--confidence`, `--level`, `--reach`, `--area`; an exception gate is refused | 0, 1, 2, 6 |
| `gate-action.sh redirect <run-dir> <issue> --notes T \| --mine` | either chat | a rework ticket in the run (`ready-for-agent`, or `ready-for-human` with `--mine`), natively blocking the dependents; the gate closes; prints the ticket | 0, 1, 2, 3, 6 |
| `gate-action.sh bypass\|defer <run-dir> <issue>` | either chat | bypass: closed unreviewed, who recorded; defer: the dependents go ahead, the gate stays open until the end gate. Either kind of gate | 0, 1, 2, 3, 6 |
| `gate-action.sh retry <run-dir> <issue> --notes T`, `reslice`, `take`, `drop` | either chat | an exception gate: the ticket queued with the notes and one more attempt, or out of the run (`needs-triage`), or `ready-for-human`, or dropped; the gate closes. reslice and drop print the impact first, and their dependents leave the run with them (`sent_back`, `needs-triage`). `send-back <run-dir>` does that for tickets stranded by an older run; `stranded <run-dir>` lists them | 0, 1, 2, 3, 6 |
| `gate-action.sh sync <run-dir>` | `wave.sh status` | opens an exception gate per `exception` decision waiting without one; bypasses one closed by hand: `opened #<issue> <gate-id>` | 0, 1, 3 |
| `gate-action.sh parked <run-dir> [--record]` | `wave.sh status` | 0 and `parked: waiting on N reviews: …` when every ticket left waits behind an open gate (`next: parked`); 1 otherwise | 0, 1 |
| `gate-action.sh chat\|list\|deferred <run-dir>` | either chat | the open exception gates with their choices; every gate; the deferred gates, for the end gate | 0 |
| `state.sh decide <run-dir> <id> <choice> [options]` | either chat | a waiting decision decided as a decision record | 0, 1, 2, 3, 6 |

## The fake tracker

`tests/fixtures/fake-gh/gh` answers the `gh` calls the run makes (`api` issue and blocked-by reads, `issue view`, `list`, `comment`, `edit`, `close`) from a folder (`FAKE_GH_DIR`) of `issue-<n>.json` and `blocked_by-<n>.json` files, so tests and live trials never reach GitHub.

## Live proof

`tests/live-run/live.sh` runs the whole two-tier run for real (a chat, an orchestrator and a worker, each a capped `claude -p` loading the plugin with `--plugin-dir` under the normal login) in a throwaway repo with the fake tracker. See `tests/live-run/README.md` for what it proves and its last result.

# Context drain and resume

Neither tier ever stops to compact (#59); the chat is compacted by Claude Code at 40% and never asks the Artisan to (#104). `drain.sh` reads a session's context and applies the drain bands, the orchestrator hands its wave to a fresh orchestrator, and `run-digest.sh` puts the run in front of a compacted, resumed or new chat. The rules for both tiers: `skills/implement-plan/references/context-drain.md`. Tested in `tests/drain.test.sh`, the hand-off end to end with the fake `claude` (an orchestrator compacted with its worker in flight; the next one finishes the wave).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `drain.sh percent --transcript F [--window N]` | either | the context used, from the transcript's last main-thread usage record against the model's window: `<percent> <used> <window>`, or `unknown` | 0, 2 |
| `drain.sh decide --tier T --percent P --outstanding N [--marker] [--drain P] [--review P]` | either | the bands alone: `<band> <percent>% <dispatch\|process\|handoff>[ risk-gate]` | 0, 2 |
| `drain.sh check <run-dir> [--tier orchestrator\|chat] [--transcript F]` | either | `decide` from the run's files: the thresholds in `plan.config.context`, the orchestrator's transcript and marker in its `workers/` folder, its workers in flight and verifiers not yet judged; for the chat tier, a running orchestrator (the chat itself uses `drain.sh chat`) | 0, 1 |
| `drain.sh chat <run-dir> --transcript F` | chat | the chat's context: `ok <percent>%` (30 or under), `warn <percent>%` (the chat ends its message with a one-line warning), `warn ask <percent>%` (past 55% with no compaction: also the one fallback `/compact` ask, printed once; the marker `chat-compact-asked` in the run folder is cleared by a reading back under the line), `unknown -`. Thresholds and window: `chat_context.*` in the plan config (defaults 30, 40, 1,000,000) | 0, 2 |
| `drain.sh handoff <run-dir>` | orchestrator | records the hand-off, launches the next orchestrator for the same wave (`wave.sh launch --handoff`), writes the hand-off report as the result file: `handed-off <id> <attempt> <pid>`, or `none` when nothing is left | 0, 1, 6 not the running orchestrator |
| `drain.sh gate <run-dir> <ticket> <percent>` | orchestrator | a merge processed at the review band: records `context_risk` and opens a risk gate issue (`gate.sh open`, id `risk-context-<t>`) that blocks only its dependents, its packet saying the merge happened at N% context; a `review-gate` decision | 0, 4, 6 not merged |
| `drain.sh gate-cleared <run-dir> <ticket> [--by NAME]` | chat | the Artisan cleared it | 0, 6 no gate waiting |
| `run-digest.sh [--repo D \| --run-dir D] [--line] [--peek]` | chat, hooks | the open run's digest: where it is, what's waiting, what changed since last shown; nothing when no run is open; read-only on the state file | 0, 2 |
| `compact-hook.sh pre-compact\|session-start` | hooks | below | 0, 2 (the orchestrator's block) |

**The hooks** (`hooks/hooks.json`, generated by `guard/guard.sh hooks-json`). Who a session is comes from `ARTISAN_ROLE`, which `run-ticket.sh` sets; a session without it is a chat.

| Hook | Session | Does |
|---|---|---|
| `PreCompact` | orchestrator | writes the hand-off marker `workers/<id>.<n>/handoff.json` and blocks the compaction (exit 2). Autocompact (about 70%) is blocked the same way, marker written |
| `PreCompact` | chat, a run open | prints the instructions that steer the summary (Claude Code adds a `PreCompact` hook's output to the compaction's instructions) |
| `SessionStart` (`startup\|resume\|compact\|clear`) | orchestrator | records its transcript's path in `workers/<id>.<n>/transcript.path` |
| `SessionStart` | chat, in a repo with `.artisan-agent/` | names the chat's transcript; with a run open, the run digest after `compact` or `resume`, one line at `startup` |
| either | worker, verifier | nothing |

**The fallback for the context percentage** (pilot prerequisite 6). Claude Code gives a session's context percentage only to the interactive status line; a headless `claude -p` has no way to ask. So the percentage is computed: the last main-thread assistant record in the session's transcript that carries `usage`, summing `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` and `output_tokens`, over the window (200,000; 1,000,000 for a `[1m]` model id or once the sum passes 200,000; `ARTISAN_CONTEXT_WINDOW` overrides). Subagent (sidechain) records are skipped. A session without a transcript (`--no-session-persistence`) reads `unknown`, treated as normal: the `PreCompact` marker is its only backstop.

**Resuming past the run lock.** `guard/protect.sh run-start` lets `/artisan-agent:implement-plan` through with no arguments, `resume` or the open run's id, so a new or resumed chat can open the run's digest while an orchestrator holds the lock. Anything else is still a second run: refused and left as a `plan` issue.

# The ADR and guardrail check at plan approval

`adr-check.sh` is the mechanical half of the check that opens plan approval, in `/artisan-agent:to-plan` and in `implement-plan`'s plan step when the route skipped `to-plan`; the procedure and the ADR adjustment loop are `references/adr-check.md`. An agent judges (which ADRs a ticket touches, where there is tension, which decisions no ADR covers) and writes `adr-check.json`; the script validates it against the ADR files and prints the view. Tested in `tests/adr-check.test.sh`.

| Command | Does | Exit status |
| :- | :- | :- |
| `adr-check.sh list [--adr-dir D]` | the ADRs as JSON: number, file, title | 0, 1, 2 |
| `adr-check.sh refs [--adr-dir D]` | reads text on stdin; prints the number of each existing ADR it cites | 0, 1, 2 |
| `adr-check.sh render <check.json> [--adr-dir D] [--guardrails resolve.json]` | the approval view: plan compliance, each ticket's ADRs with `TENSION` flagged, ADR gaps, then guardrail conflicts and the level that applies (from `guardrails.sh resolve`); an ADR number with no file is refused | 0, 1, 2 |
| `adr-check.sh affected <check.json> --adr N` | the tickets citing ADR N: the ones to re-check after it is edited | 0, 1, 2 |

The edit itself is not scripted: the Artisan approves a drafted diff, it lands by a short PR (`doc-change.sh`, upstream `pr`) before dispatch, then `affected` names the tickets to re-check.

# Cost and usage limits

`budget.sh` holds back new dispatch when the projected spend crosses the budget (the overrun gate) or plan usage nears its limits (the plan-window guard); `statusline.sh` is the status-line capture that writes the usage reading and the context window. Never stops work in flight. The rules, the packet and the answers: `references/cost-and-usage.md`. Tested in `tests/budget.test.sh` (seeded costs and readings, the fake `gh`) and `tests/statusline.test.sh` (an isolated `CLAUDE_CONFIG_DIR`).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `budget.sh guard <run-dir>` | both (`wave.sh dispatch`, `wave.sh status`) | the plan-window guard, then the budget: records a park (`usage` decision, `parked`) or opens the overrun gate (`review-gate` issue with the packet, `overrun` decision, `overrun-gate`) the first time | 0, 12, 17, 18 |
| `budget.sh usage <run-dir>` / `project <run-dir>` / `packet <run-dir>` | either | read-only: the plan-window verdict; the projection as JSON; the latest overrun gate's packet | 0, 18 / 0 / 0, 1 |
| `budget.sh overrun <run-dir> raise <usd> \| cut <t>... \| stop` | Engineering chat | the overrun gate's answer, one card; the gate is deferred, its only action (`--action` anything else: 6) | 0, 2, 6 |
| `budget.sh park <run-dir> resume \| raise <percent> \| stop` | Engineering chat | the answer to a usage park | 0, 2, 6 |
| `statusline.sh` | Claude Code's status line | writes `<home>/usage.json` and `<home>/sessions/<id>.json`, prints the line (a chained one's, if any) | 0 |
| `statusline.sh install [--refresh S]` | setup | copies the capture into the individual home and points the user's `statusLine` at it, every 60 seconds, chaining a status line already there | 0, 1 |
| `statusline.sh window --transcript F` / `path` | `drain.sh chat`, `budget.sh` | the window captured for that session; the usage file's path | 0, 1 |

`ARTISAN_USAGE_FILE` overrides the usage file (`tests/lib.sh` points every test at a fresh, low reading of its own).

# Two chats

`chats.sh` is how the Engineering chat and the Product chat work through the tracker alone; the rules and the ownership table are in `${CLAUDE_PLUGIN_ROOT}/references/two-chats.md`. Tested in `tests/chats.test.sh` (and `tests/gate.test.sh` for closing a gate by hand), with the fake `gh`.

| Command | Chat | Does | Exit status |
| :- | :- | :- | :- |
| `chats.sh send --repo R <issue>...` | Product | "send #N and #M to engineering": a `plan` issue with those tickets as sub-issues | 0, 6 a ticket is `in-run`, closed or missing |
| `chats.sh guard --repo R <issue>` | Product | before triaging, editing or relabelling: refuses an `in-run` ticket, naming its run | 0 free, 6 in a run |
| `chats.sh label-run --repo R <run-dir>` | Engineering | labels every ticket in scope `in-run`, with one comment naming the run | 0, 1 |
| `chats.sh approve-envelope --repo R <plan>` | either | records on a plan that its run envelope was approved, so queued behind the lock it starts without asking again | 0, 1 |
| `chats.sh gates --repo R [--role R]` | either | open `review-gate` issues from the tracker, batched by job and role (`gate.sh list` calls it) | 0 |
| `chats.sh sweep --repo R [--chat C] [--idle]` | either | gates, gates closed by hand, guardrail and plugin-version changes, the plan to start when the lock is free, waiting decisions; `ACTION` lines and, idle, a `notify:` line | 0, 1 |
| `chats.sh due [--chat C]` | either | exit 0 when the last sweep was at least `sweep_minutes` ago | 0 due, 1 not yet |
| `gate.sh carried <run-dir>` | Engineering | the cards left undecided on gates closed by hand, for the end gate | 0 |

# Gate placement, risk gates and the end gate

`gate-plan.sh` places the run's gates at the plan step; `gate.sh` opens risk gates as it opens slice gates; `end-gate.sh` runs the end gate, cuts the PRs to `main` and ends the run. The rules: `references/end-gate.md`. Tested in `tests/gate-plan.test.sh`, `tests/risk-gates.test.sh` and `tests/end-gate.test.sh`, with the fake `gh` (which also answers `pr create`).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `gate-plan.sh propose <draft>` | Engineering chat | writes the draft's `gates`: a slice gate per slice, a risk gate per ticket with an `escalation`, the end gate (doubling as the slice gate for a `small-change` or `bug` route); prints the table | 0, 1, 2 |
| `gate-plan.sh render\|remove\|move <draft> ...` | Engineering chat | the table; remove a slice, risk or end gate; move a slice or risk gate (`--after T`, `--tickets T,T`). An exception gate, or moving the end gate, is refused | 0, 1, 2, 6 |
| `gate.sh sync\|due\|open` | both | as for slice gates; also opens a risk gate (`risk-<n>` from the plan, `risk-seam-<t>` from a new-seam card) once its ticket merges | as above |
| `end-gate.sh status <run-dir>` | Engineering chat | `not-due`, `due`, `open`, `removed`, `approved` or `ended` | 0 |
| `end-gate.sh packet\|open <run-dir>` | Engineering chat | the packet (failing test first for a bug, deferred gates, carried cards, PR boundary); the `review-gate` issue and an `end-gate` decision | 0, 1, 6 |
| `end-gate.sh boundary <run-dir>` | Engineering chat | the PR boundary as JSON: from the `pr-boundaries` guardrail (product, team, individual), approved, or proposed | 0 |
| `end-gate.sh approve <run-dir> [--boundary B]` | Engineering chat | refused while a gate is deferred, or with no boundary recorded and none given; decides the end gate (job 13) and the boundary (job 17) | 0, 1, 2, 3, 6 |
| `end-gate.sh prs <run-dir> [--json]` / `cut <run-dir> <n> --body-file F` | Engineering chat | the stacked PRs; builds `pr/<run-id>/<n>`, pushes it when there is an `origin`, opens the PR with the body upstream `pr` wrote | 0, 1, 6 |
| `end-gate.sh finish <run-dir>` | Engineering chat | every PR cut: `in-run` off every ticket in scope, `run-ended`, the retro offer | 0, 1, 6 |
