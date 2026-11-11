# Worker scripts

How an orchestrator starts a worker, waits on it and judges it. Files are the truth: each script is tested through the files it writes and reads (`tests/run-ticket.test.sh`, `tests/wait-any.test.sh`, `tests/classify-worker.test.sh`), with a fake `claude` in `tests/fixtures/fake-claude/`. Skills cite them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>`.

| Script | Does | Returns |
|---|---|---|
| `run-ticket.sh` | Launches one capped headless worker detached; always leaves an exit record | the runner's PID, at once |
| `wait-any.sh` | Blocks in the foreground until a run's files change, or a timeout | `new`, `grew` or `changed <path>` lines; 124 on timeout, 2 on bad usage |
| `classify-worker.sh` | Judges one attempt from its files | `<status> <reason>` |

Each script's header has its full usage.

## Files in a run folder

All paths are inside `.artisan-agent/runs/<run-id>/`. `<t>` is the ticket, `<n>` the attempt (1 unless `--attempt` says otherwise).

| Path | Written by | What |
|---|---|---|
| `results/<t>.<n>.exit.json` | runner, last, atomically | the exit record |
| `results/<t>.<n>.result.json` | the worker (path in `$ARTISAN_RESULT_FILE`) | the worker's result file; its shape belongs to the worker skill |
| `results/findings/<t>.jsonl` | the worker (path in `$ARTISAN_FINDINGS_FILE`) | one finding per line, appended across attempts |
| `workers/<t>.<n>/runner.pid` | runner | the runner's PID, for the sweep |
| `workers/<t>.<n>/output.json` | `claude --output-format json` | the session's JSON output, including its result text |
| `workers/<t>.<n>/prompt.md`, `stderr.log`, `runner.log` | runner | the full prompt as sent, and logs |
| `.wait-any.seen` | `wait-any.sh` | what the waiting caller has already seen |

`wait-any.sh` watches only `results/`. Anything starting with a dot is a write in progress and is skipped.

The exit record:

```json
{"ticket":"46","attempt":1,"exit_code":0,"reason":"exited","runner_pid":123,
 "started_at":"2026-11-10T19:38:48Z","finished_at":"2026-11-10T19:39:14Z",
 "max_budget_usd":"3.00","max_turns":60,"deadline_seconds":3600,
 "output":"workers/46.1/output.json","result_file":"results/46.1.result.json"}
```

`reason` is `exited` (claude ended by itself, including a crash or being killed from outside), `deadline` (the runner stopped it at its deadline), `stopped` (the runner got TERM or INT and stopped it) or `runner-error` (the runner itself failed). `exit_code` is claude's, so 128 + the signal number when it was killed (137 for SIGKILL, 139 for SIGSEGV). If the runner itself gets SIGKILL, it can't write the record; `classify-worker.sh` reports that as `failed vanished`, because the runner PID is gone and there is no exit record.

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
| `plan.sh render` | Prints the one approval: waves, model and estimate per ticket, total, Max Agents and every config number | Markdown |

## The project config

`.artisan-agent/config.yml` is committed. Every setting and its default is in `templates/config.yml`, the one place defaults are written; `/artisan-agent:setup` copies it into a project. A key left out or left empty falls back to its default; a value of the wrong type stops the read with the key named. The file is plain YAML: maps, scalars, `[flow, lists]` and `- item` lists of scalars (`scripts/lib/yaml-subset.py`, standard-library `python3`).

| Setting (ticket #55) | Key | Default |
|---|---|---|
| Max Agents | `max_agents` | 5 |
| sweep | `sweep_minutes` | 5 |
| context drain | `context.drain_percent` | 30 |
| context review | `context.review_percent` | 50 |
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
| host configured | `host_configured` | false |

## Overrides are for this run only

`plan.sh build --set key=value` and, once the run has started, `state.sh override <run-dir> <key> <value>` change a number in the plan's `config` and record `{value, project}` in its `overrides`. Neither writes `config.yml`; a lasting change is job 23, made by PR. The key must be a setting above (dotted), or `estimate_multipliers.<model>`, and the value must have the setting's type. `max_agents` and `attempts_per_ticket` are kept in step at the top of the plan, where `state.sh` and the sweep read them.

## Estimates

In estimated dollars, per ticket, then summed; the budget is the total plus the overrun allowance.

- **History.** When state files of other runs (`.artisan-agent/runs/*/state.json`, or `--history DIR`) hold merged tickets on the same model with a logged `cost_usd`: their mean cost, times `estimate_multipliers.<model>`, else `estimate_multipliers.all`, else 1.
- **Price.** Otherwise: the model's price in `references/model-prices.json` times the ticket's expected size (`expected.input_tokens`, `expected.output_tokens`). There are no per-tier defaults: a model missing from the price table, with no history, is refused. Keep the table current; it says the date its prices were taken.

Caps follow `run-ticket.sh`: `max_budget_usd` twice the estimate, `max_turns` 40 per estimated dollar (at least 20), `deadline_seconds` twice `expected.minutes`.

## Scope

The run's scope is exactly the approved `scope`. `state.sh in-scope <run-dir> <ticket>` exits 0 or 4; `state.sh dispatch` and `run-ticket.sh` (whenever its run folder holds a state file) refuse a ticket outside it with exit status 4 before anything starts.
