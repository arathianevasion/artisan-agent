# Worker scripts

How an orchestrator starts a worker, waits on it and judges it. Files are the truth: each script is tested through the files it writes and reads (`tests/run-ticket.test.sh`, `tests/wait-any.test.sh`, `tests/classify-worker.test.sh`), with a fake `claude` in `tests/fixtures/fake-claude/`. Skills cite them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>`.

| Script | Does | Returns |
|---|---|---|
| `run-ticket.sh` | Launches one capped headless worker (or, with `--role orchestrator`, a wave's orchestrator; with `--role verifier`, a ticket's verifier) detached; always leaves an exit record. Refuses to launch into a run folder with no state file (exit 4) | the runner's PID, at once |
| `wait-any.sh` | Blocks in the foreground until a run's files change, or a timeout | `new`, `grew` or `changed <path>` lines; 124 on timeout, 2 on bad usage |
| `classify-worker.sh` | Judges one attempt from its files | `<status> <reason>` |
| `questions.sh` | A worker's filed question, the ticket that waits on it, the answer's way back, pull-or-carry-on for a deferral, provisional cards ([`references/worker-questions.md`](../references/worker-questions.md); `tests/questions.test.sh`) | a ticket number, or lines and tables |
| `verify.sh`, `evidence.sh` | A fresh verifier per ticket, and the evidence contract shown on the ticket and in the wave digest ("Verification and evidence", below) | one verdict line; Markdown |

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
| `results/verify-<t>.<v>.result.json`, `.exit.json` | the verifier, the runner | the verdict and the verifier's exit record |
| `prompts/verify-<t>.<v>.md`, `.criteria.json` | `verify.sh start` | the verifier's prompt and the criteria it was given |
| `verify/claims/<t>.<v>/` | `verify.sh start` | the claim on verifier `<v>`: one start launches it, however many run at once |
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
| `resolve-scope.sh --repo <o/n> <issue>...` | plan issues and tickets in, the run's tickets out | 0, 1, 2, 3 |

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
| `wave.sh status <run-dir>` | Engineering chat | the orchestrator's state from its exit record; once it has ended, takes the lock back, reconciles and says what's next (`launch`, `wait`, `halted`, `decide`, `blocked`, `done`), with a ticket table | 0 |
| `wave.sh dispatch <run-dir> <ticket>` | orchestrator | refuses unless in scope (4), queued, every blocker merged into the integration branch or closed (5), a slot free under Max Agents (9) and its expected files overlap nothing in flight or in this wave (10); then a worktree from the integration tip and a worker running `/artisan-agent:implement`. A retry waits for the failed session to end (8) and carries its failure evidence | 0, 1, 4, 5, 8, 9, 10 |
| `wave.sh merge <run-dir> <ticket>` | orchestrator | refuses unless the record's commit is the branch tip and a fresh verifier passed this attempt at that commit (13, nothing changed; `verify.sh`); an attempt that didn't complete is a failed attempt (retried, or blocked after the last); merges `--no-ff` in the integration worktree, runs `plan.suite_command`, records the merge, removes the worker's worktree | 6 refused or conflict after its try, 7 suite red (both undo and block), 8 worker still running, 11 conflict left for its one try, 13 not verified |
| `wave.sh resolved <run-dir> <ticket> [--gave-up WHY]` | orchestrator | after `/artisan-agent:resolve-conflicts`: aborts and blocks if anything is still conflicted, marked or unstaged (or it gave up), else commits the merge and runs the suite as `merge` does | 0, 6, 7 |
| `wave-width.sh pick <run-dir>` / `check <run-dir> <ticket>` | orchestrator | the tickets to dispatch now: the smallest of Max Agents less those in flight, the frontier, and tickets with non-overlapping `expected_files`; `check` is dispatch's overlap refusal | 0, 10 |
| `wave.sh block <run-dir> <ticket> <reason>` | orchestrator | blocks a returned ticket it won't merge (the diff misses its expected output): an exception decision for the Artisan and a `blocked` event | 0, 4 |
| `wave.sh close <run-dir> <ticket>` | orchestrator | merged tickets only: posts the evidence contract (`evidence.sh comment`), ticks the criteria the verifier found met (`lib/criteria.py tick`), closes the ticket | 0, 1 |
| `wave.sh report <run-dir>` | orchestrator | halts the run if every ticket dispatched in the wave ended blocked, then the wave report, JSON, for its result file | 0 |

Wave width, serial merges, the one conflict try, two attempts and the halt are described in `skills/implement-plan/references/parallel-waves.md` and tested end to end in `tests/parallel-waves.test.sh`, with a scripted orchestrator that follows that page and a stand-in for the resolve skill.

The orchestrator's files sit beside its workers' in the run folder, named `orchestrator-w<wave>.<attempt>`: `results/…exit.json`, `results/…result.json` (the wave report) and `workers/…/`. So `classify-worker.sh <run-dir> orchestrator-w<wave> <attempt>` judges it, and `wait-any.sh` wakes on its exit record.

**The lock passes with the work.** The chat holds the state lock between waves with its own session's pid. `wave.sh launch` records the orchestrator, then `run-ticket.sh --lock-from` makes the orchestrator's runner take the lock over before its session starts and export its pid to the session as `ARTISAN_WRITER_PID`. When the orchestrator exits, the lock is stale, and `wave.sh status` takes it back for the chat. A worker never gets a writer pid.

**Environment for trials.** `ARTISAN_CLAUDE_ARGS` (split on whitespace) is added to every orchestrator and worker session, for example `--plugin-dir … --setting-sources project,local --no-session-persistence`. `ARTISAN_MAX_BUDGET_USD` caps any one session's `--max-budget-usd`.

## Exit status

Every exit code `wave.sh` and `verify.sh` use, in one table: a number means the same thing in both, so an orchestrator can act on it without knowing which script it came from. Codes 0 to 12 are as they were before the verifier; 13 and 14 are the verifier's (#57).

| Code | Means | From | Do |
| :- | :- | :- | :- |
| 0 | done | all | carry on |
| 1 | error (a missing file, a bad state, a tracker that can't be read) | all | read the one-line message |
| 2 | bad usage | all | fix the call |
| 3 | the state lock is held, or an orchestrator is still running | `launch`, `status`, any write | wait |
| 4 | the ticket is outside the approved scope | `dispatch`, `block`, `verify.sh start` | nothing: it isn't this run's |
| 5 | a blocker is not merged into the integration branch, or merged under a risk gate not yet cleared (`drain.sh gate`) | `dispatch` | leave it for a later wave |
| 6 | refused: blocked, or a failed attempt (`queued` again if it has attempts left); for `launch --handoff`, not the orchestrator that recorded a hand-off | `dispatch`, `merge`, `resolved`, `verify.sh start`, `verify.sh judge`, `launch --handoff` | if `queued`, dispatch the retry; if blocked, leave it for the Artisan; `launch --handoff` only through `drain.sh handoff` |
| 7 | the suite went red after the merge (undone, blocked) | `merge`, `resolved` | carry on with the rest |
| 8 | a worker or verifier is still running or ending (from `verify.sh start`, also: another call's verifier could not launch or has not come up yet) | `dispatch`, `merge`, `verify.sh start`, `verify.sh judge` | wait, then call again |
| 9 | no free slot under Max Agents | `dispatch` | wait for a ticket to finish |
| 10 | its expected files overlap a ticket in flight or in this wave | `dispatch`, `wave-width.sh check` | leave it for a later wave |
| 11 | a merge conflict, left in progress for its one try | `merge` | `/artisan-agent:resolve-conflicts`, then `wave.sh resolved` |
| 12 | the run is halted | `launch` | the Artisan decides; `launch --resume` |
| 13 | not verified: no passing verdict for this attempt at this commit | `merge` | `verify.sh start`, then `judge` |
| 14 | the verifier itself failed (no attempt used) | `verify.sh judge` | `verify.sh start` once more |

# Verification and evidence

A fresh verifier per returned ticket, and the evidence contract it produces: in the state file, on the ticket, and in the chat's wave digest. The flow, the verdict and the contract: `references/evidence-contract.md`; the verifier's brief: `skills/implement-plan/references/verifier.md`. Tested in `tests/verify.test.sh` (and end to end in `tests/wave.test.sh` and `tests/parallel-waves.test.sh`), with the fake `claude` scripting the verifier (`FAKE_CLAUDE_SCRIPT_VERIFIER`).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `verify.sh start <run-dir> <ticket>` | orchestrator | for a returned ticket whose attempt completed and whose record names its branch tip (the same check as `wave.sh merge`, in `lib/wave-lib.sh`): reads its criteria (`lib/criteria.py extract` over the tracker body, or `ticket_path`), checks out the worker's commit in a detached worktree, `<repo>-wt/<run-id>-verify-<t>.<v>`, and launches the verifier there (`run-ticket.sh --role verifier`, id `verify-<t>`). Idempotent per attempt: while the attempt has a verifier running, ended but not judged, or passed, or another call is starting one (claimed with `mkdir verify/claims/<t>.<v>`, cleared if that start ends before recording the verifier), it launches nothing and prints that verifier's pid; only after judge's 14 does it start the next | 0, 1, 4, 6, 8 |
| `verify.sh judge <run-dir> <ticket>` | orchestrator | once the verifier has ended: lines its verdict up with the criteria (`lib/criteria.py align`), builds the evidence contract and writes it (`tickets.<t>.evidence`, event `verified`), logs the worker's and verifier's cost, removes the verifier's worktree. A fail is a failed attempt (retried with the verifier's findings, or blocked after the last) and posts the contract on the ticket. Prints one line: `pass m/n`, `fail m/n retry: <first unmet>`, `fail m/n blocked: <first unmet>` or `error <reason>`. Judging again repeats the line and writes nothing | 0, 1, 6, 8, 14 |
| `evidence.sh comment <run-dir> <ticket>` | orchestrator (via `wave.sh close`, `verify.sh judge`) | the ticket's evidence comment, from the state file's contract, ending in the contract as JSON | 0, 1 no contract |
| `evidence.sh digest <run-dir> [--wave N \| --all]` | Engineering chat | the wave digest: one table row per ticket dispatched in the wave (default the last), then cost against the budget | 0 |

`run-ticket.sh --role verifier` launches like a worker (detached, capped, always an exit record) but needs an id starting `verify-`, skips the scope check and never gets a writer pid. A verifier is not a ticket and takes no slot under Max Agents.

## Guardrails

`guardrails.sh` reads the three guardrail levels at the point of use; the rules are `references/guardrails.md`. Tested in `tests/guardrails.test.sh` with a local team repo and a throwaway individual home (`ARTISAN_HOME`, `ARTISAN_TEAM_CACHE`, `ARTISAN_TEAM_URL_BASE`).

| Command | Does | Returns |
|---|---|---|
| `guardrails.sh wave-start <run-dir> <wave>` | called by `wave.sh launch`: fetches the team, product and individual sources, brings `main` into the integration branch if a product guardrail changed, records the plugin version and each source's commit in the state file | one JSON line; 6 on a conflict (decision queued, wave not recorded) |
| `guardrails.sh resolve [--run-dir D] [--role R]` | the guardrails in force by the stated precedence, read at the commits the latest wave recorded | JSON: `applied`, `own_reviews`, `overridden`, `conflicts` |
| `guardrails.sh table [--run-dir D]` | the packet's "Guardrails applied" section | a markdown table |
| `guardrails.sh tighten --level L --who NAME --reason TEXT ...` | writes or tightens a guardrail with its origin or move: individual by commit, product and team as a branch (`--pr` opens the PR) | 5 on a loosening, 2 on a `--who` that names an agent |
| `guardrails.sh sources` | each source's current commit | JSON |

## The fake tracker

`tests/fixtures/fake-gh/gh` answers the `gh` calls the run makes (`api` issue and blocked-by reads, `issue view`, `list`, `comment`, `edit`, `close`) from a folder (`FAKE_GH_DIR`) of `issue-<n>.json` and `blocked_by-<n>.json` files, so tests and live trials never reach GitHub.

## Live proof

`tests/live-run/live.sh` runs the whole two-tier run for real (a chat, an orchestrator and a worker, each a capped `claude -p` loading the plugin with `--plugin-dir` under the normal login) in a throwaway repo with the fake tracker. See `tests/live-run/README.md` for what it proves and its last result.

# Context drain and resume

Neither tier ever stops to compact (#59). `drain.sh` reads a session's context and applies the drain bands, the orchestrator hands its wave to a fresh orchestrator, and `run-digest.sh` puts the run in front of a compacted, resumed or new chat. The rules for both tiers: `skills/implement-plan/references/context-drain.md`. Tested in `tests/drain.test.sh`, the hand-off end to end with the fake `claude` (an orchestrator compacted with its worker in flight; the next one finishes the wave).

| Command | Tier | Does | Exit status |
| :- | :- | :- | :- |
| `drain.sh percent --transcript F [--window N]` | either | the context used, from the transcript's last main-thread usage record against the model's window: `<percent> <used> <window>`, or `unknown` | 0, 2 |
| `drain.sh decide --tier T --percent P --outstanding N [--marker] [--drain P] [--review P]` | either | the bands alone: `<band> <percent>% <dispatch\|process\|handoff>[ risk-gate]` | 0, 2 |
| `drain.sh check <run-dir> [--tier orchestrator\|chat] [--transcript F]` | either | `decide` from the run's files: the thresholds in `plan.config.context`, the orchestrator's transcript and marker in its `workers/` folder, its workers in flight and verifiers not yet judged; for the chat, a running orchestrator | 0, 1 |
| `drain.sh handoff <run-dir>` | orchestrator | records the hand-off, launches the next orchestrator for the same wave (`wave.sh launch --handoff`), writes the hand-off report as the result file: `handed-off <id> <attempt> <pid>`, or `none` when nothing is left | 0, 1, 6 not the running orchestrator |
| `drain.sh gate <run-dir> <ticket> <percent>` | orchestrator | a risk gate on a merge processed at the review band: its dependents wait for it (`wave.sh dispatch` 5, off the frontier), nothing else does; a `risk-gate` decision | 0, 4, 6 not merged |
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
