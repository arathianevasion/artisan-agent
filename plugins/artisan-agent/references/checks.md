# The recorded checks

The checks setup proved are the checks the run uses. `/artisan-agent:setup` proves each chosen check fails on a deliberate break and records only the proven ones in `CODING_STANDARDS.md` under `## Checks`, one line each:

```
- `<command>`: proven to fail on <YYYY-MM-DD>, breaking: <the break>
```

**One reader.** Nothing parses that section except `${CLAUDE_PLUGIN_ROOT}/scripts/checks.sh` (`json`, `list`, `suite`, `run`; usage at its top, tested in `tests/checks.test.sh` on what setup really writes). The worker, the verifier and the plan step all go through it.

| Who | With checks recorded | With none recorded |
|---|---|---|
| Worker (`/artisan-agent:implement`) | runs exactly the recorded checks with `checks.sh run` before writing its evidence, and puts the output in the record's `checks`. A discovered command that isn't recorded is not run as a check; pass it after `--` and it is listed in `not_run` | discovers checks as before (ticket, README, build files), runs them through `checks.sh run -- '<found command>'...` (one quoted argument per command), and the record's `checks.fallback` says `no recorded checks (<reason>): found <commands>` |
| Verifier (`verify.sh`) | `verify.sh start` gives it the recorded checks, read from the integration worktree (what the run merged, not the worker's branch), and the one `checks.sh run --out verify/checks/<t>.<v>.json` command. `verify.sh judge` treats a verdict without those results as the verifier failing (14), and a red check makes each criterion marked met that cites it unmet (every one, when no criterion cites it) | it runs what it finds through the same command; the contract's `checks.fallback` names what it found, or says it ran none |
| Plan step (`plan.sh build`) | a draft without `suite_command` gets `checks.sh suite` (every recorded check, in order, red if any is), `suite_source: recorded`. A different command stays, as `changed`, and the approval shows it as a change the Artisan approves | the draft's own command is `discovered` and the approval says `No recorded checks (<reason>): found <command>` (and where, from the draft's optional `suite_found`); no command at all is `none`, flagged |

A fallback is never silent: its text always starts `no recorded checks`, with the reason (`no CODING_STANDARDS.md`, no `## Checks` section, or the section lists none).

Out of scope here: reading `pr-boundaries` (#71), proving checks fail (setup, `skills/setup/PROJECT.md`), team- or individual-level checks.
