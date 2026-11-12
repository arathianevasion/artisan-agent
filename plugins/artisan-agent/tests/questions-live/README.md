# Proving that a worker files a question (#61)

`questions.test.sh` (run by `tests/run.sh`) checks the scripts for free. The skill side, that a worker meeting a decision it may not make files a ticket instead of deciding, is proven by one capped headless worker, run by hand with `live.sh` whenever `/artisan-agent:implement` or `references/worker-questions.md` changes. See the header of `live.sh` for the scenario: a ticket whose second criterion needs a persistence format, which the repo's `CODING_STANDARDS.md` "Always ask" section reserves for the Artisan.

```bash
UPSTREAM_PLUGIN_DIR=/path/to/mattpocock-skills/1.3.1 live.sh run "$SB/live"
live.sh verify "$SB/live"
```

## Run on 2026-11-11

`claude-sonnet-5-5`, $0.29, 12 turns, all ten checks passed: the worker built `todo.done` test-first, filed a `needs-triage` ticket (three options for the format, a recommendation, the "Always ask" item as criterion, split off), logged the finding, left the second criterion unmet and picked no format.

Not covered here, because it needs a real run: a worker ending `blocked` with `--blocking`, which `tests/questions.test.sh` covers with scripted workers.

## Hooks and user settings (#105)

`live.sh` runs with the flags from `tests/helpers/live-hooks.sh`: the plugin's hooks are active and the Artisan's user settings stay out. It fails unless a SessionStart hook left its line in `ARTISAN_HOOK_PROOF`.
