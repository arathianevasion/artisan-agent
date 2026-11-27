# Coding standards

Product level: how code is written in this repo, changed by PR. Read by workers and verifiers at the point of use.

## Always ask

Things that must always come back to the Artisan. Only the Artisan changes this list (setup or a retro lesson).
- A new dependency: any tool beyond bash, jq, python3, gh, git and perl, or a new GitHub Action
- Changing a spend default (budgets, estimates, usage reserve, CI minutes) or editing an ADR

## Guardrails

- `pr-boundaries`: one PR per slice (set at setup).

## Checks

- `bash plugins/artisan-agent/tests/run.sh -j 8`: proven to fail on 2026-11-19, breaking: an `exit 1` appended to plugins/artisan-agent/scripts/state.sh (runs_locally: always)

## Conventions

Each rule here is enforced by the named test under `plugins/artisan-agent/tests/`; run it when unsure. Most red merge gates in this repo came from breaking one of these.

- Do not edit `CHANGELOG.md` or the plugin version: the release writes them, and an `## Unreleased` section fails `version`.
- In `references/state-file.md` and `scripts/README.md`, one entry per line: add a line, never extend a paragraph, and keep each line under 1,000 characters (`doc-layout`).
- A new state field is listed in `references/state-file.md` (and its Optional fields table, with its default) and written by `state.sh init` (`state`, `state-compat`).
- Every `local` gets a value: `local x=`, never bare `local x` (`bare-local`).
- Never pass JSON that grows with the run to `jq` as `--arg`/`--argjson`; use `--slurpfile`, `--rawfile` or stdin (`jq-args`).
- Issues are created only through `tracker.sh`, and an issue body never goes to `gh` as an argument: use `--body-file` (`tracker`).
- A new test that scans the whole tree goes in `tests/guard.txt`, as `guard` or `exclude` with a reason (`guard-list`).
- Every `claude -p` launch passes `headless_args` (`headless-args`).
- A script finds its sibling scripts from its own location, never through the main checkout (`script-lookup`).
- Code runs on macOS bash 3.2, which CI tests: no `mapfile`, associative arrays, `${x,,}` or `&>>`.
- `hooks.json` is generated: change the generator, not the file (`main-checkout`).
- Before hand-in, run `bash plugins/artisan-agent/tests/run.sh --guard` as well as the tests covering your change.
