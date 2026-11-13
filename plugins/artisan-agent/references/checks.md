# The recorded checks

The checks setup proved are the checks the run uses. `/artisan-agent:setup` proves each chosen check fails on a deliberate break and records only the proven ones in `CODING_STANDARDS.md` under `## Checks`, one line each:

```
- `<command>`: proven to fail on <YYYY-MM-DD>, breaking: <the break>
```

**One reader.** Nothing parses that section except `${CLAUDE_PLUGIN_ROOT}/scripts/checks.sh` (`json`, `list`, `suite`, `run`; usage at its top, tested in `tests/checks.test.sh` on what setup really writes). The worker, the verifier and the plan step all go through it.

| Who | With checks recorded | With none recorded |
|---|---|---|
| Worker (`/artisan-agent:implement`) | runs exactly the recorded checks with `checks.sh run --worker` before writing its evidence, and puts the output in the record's `checks`. A discovered command that isn't recorded is not run as a check; pass it after `--` and it is listed in `not_run`. A recorded check that is the run's suite command is not run (see below) | discovers checks as before (ticket, README, build files), runs them through `checks.sh run -- '<found command>'...` (one quoted argument per command), and the record's `checks.fallback` says `no recorded checks (<reason>): found <commands>` |
| Verifier (`verify.sh`) | `verify.sh start` gives it the recorded checks, read from the integration worktree (what the run merged, not the worker's branch), and the one `checks.sh run --out verify/checks/<t>.<v>.json` command. `verify.sh judge` treats a verdict without those results as the verifier failing (14), and a red check makes each criterion marked met that cites it unmet (every one, when no criterion cites it) | it runs what it finds through the same command; the contract's `checks.fallback` names what it found, or says it ran none |
| Plan step (`plan.sh build`) | a draft without `suite_command` gets `checks.sh suite` (every recorded check, in order, red if any is), `suite_source: recorded`. A different command stays, as `changed`, and the approval shows it as a change the Artisan approves | the draft's own command is `discovered` and the approval says `No recorded checks (<reason>): found <command>` (and where, from the draft's optional `suite_found`); no command at all is `none`, flagged |

**A suite check is left to the merge gate.** A recorded check is the suite when its command equals, exactly, the run's suite command: what `checks.sh suite` prints (with one check recorded, that check), or the plan's `suite_command` when it differs, passed as `--suite <command>`. Nothing in `## Checks` marks it; the commands are compared, so no setup change is needed. With `checks.sh run --worker` a worker skips such a check (it is the slow run the merge gate already does) and `checks.not_run` lists it as `<command>: left to the merge gate (it is the run's suite command)`; nothing else changes in the output. With several checks recorded the suite is all of them joined, which is none of them alone, so a worker still runs each. The merge gate never passes `--worker`. The verifier doesn't either, except on a machine whose merge gate runs on CI (below): there it passes `--worker --suite <the plan's suite_command>`, so it leaves the suite to the merge gate exactly as a worker does, runs every other recorded check, and its `not_run` says so. On a local machine it runs every recorded check, the suite included.

## The merge gate on CI

The merge gate is the full suite after every merge (`wave.sh merge`, `wave.sh resolved`). **The machine chooses where it runs, not the project** (#139): `merge_gate: auto | local | ci` in `host.json` in the individual home, written by machine setup (`machine-setup.sh merge-gate`) and read only through `${CLAUDE_PLUGIN_ROOT}/scripts/merge-gate.sh`. `auto`, the default, is `local` on macOS and `ci` on Linux, so a shared always-on host never spends its CPU on the suite; a Linux laptop can set `local`.

| Mode | After a merge | Green | Red | No verdict |
|---|---|---|---|---|
| `local` | `plan.suite_command` runs in the integration worktree, as before | the merge is recorded | the merge is undone and the ticket blocked (7) | - |
| `ci` | no suite runs on this machine. The merge commit is pushed to a unique `ci/<run>-<ticket>-<attempt>-<ts>` branch on `origin` and the project's **gate workflow** (`ci_gate.workflow` in `.artisan-agent/config.yml`, recorded by project setup, which refuses one without a `workflow_dispatch` trigger) is dispatched there | that run's overall conclusion is `success` and its head SHA is the merge commit: the merge is recorded. A run for any other commit never counts | `failure` or `timed_out` (the suite failed or hung): the merge is undone and the ticket blocked (7), the run's URL in the reason | CI never judged the commit: CI unreachable, no conclusion within `ci_gate.timeout_minutes` (30), or the run concluded anything else (`cancelled`, `skipped`, `stale`, `startup_failure`, `action_required`, or a conclusion not known here): the merge is undone and the run **parks** with reason `ci` (19), the park line naming the conclusion (if any) and the run's URL. The ticket is not at fault, so it is not blocked; nothing merges or dispatches until the Artisan clears the park (`wave.sh unpark-ci`), and that ticket's next merge retries the gate on the same merge commit |

A CI machine **never falls back to the local suite**. With no gate workflow recorded it merges nothing and says so; the plan step says so first.

- **Branches.** Each gate's branch is unique, so a workflow's concurrency group never cancels a gate run, and it is deleted after the gate, pass, fail or park. The gate runs detached (#142), so a merge call cut off never cuts the gate off: the next merge waits on it. A gate whose own process died is resumed on the same run when its run was dispatched, and otherwise undone at the next merge, which gates it again (the state file's `merge_gate`), and the next gate and the end gate (`end-gate.sh open`) delete the run's leftover `ci/<run>-*` branches. The project's workflow chooses its own runners; the plugin passes no runner input.
- **Evidence.** The ticket's `suite` record names the `mode`; for `ci` it holds the workflow, branch, merge commit, the run's id, URL and overall conclusion, and each job's name and conclusion (`references/state-file.md`).
- **The verifier** on a CI machine leaves the check that is the run's suite command to the merge gate (above).
- **The plan step** on a CI machine shows the expected CI minutes per merge, from the gate workflow's recent completed runs (`merge-gate.sh minutes`), and the total for the run's merges. Dollar cost is not shown yet.

A fallback is never silent: its text always starts `no recorded checks`, with the reason (`no CODING_STANDARDS.md`, no `## Checks` section, or the section lists none).

Out of scope here: reading `pr-boundaries` (#71), proving checks fail (setup, `skills/setup/PROJECT.md`), team- or individual-level checks.
