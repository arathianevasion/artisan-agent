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
