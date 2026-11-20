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
