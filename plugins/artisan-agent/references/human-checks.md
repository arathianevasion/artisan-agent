# Human checks

A `ready-for-agent` ticket's acceptance criteria hold only what an agent can show. Whatever only a person can verify (in game, by eye, on a real device, with outside access) goes into a separate **Human check** ticket (`GLOSSARY.md`). An agent criterion that needs a person can never be met by the verifier, so the ticket could never pass however good the build.

Skills cite this file rather than copying it. The script is `${CLAUDE_PLUGIN_ROOT}/scripts/to-plan.sh` (`check`, `render`, `split-human-check`, `publish --override-human-check`; usage in its header, tests in `tests/to-plan.test.sh`); `plan.sh build` flags the same criteria at the plan step.

## Writing an agent ticket

- Keep each criterion to something an agent can show: a test, a command's output, a file, a diff.
- Where a person will verify the result, an agent criterion can ask for the artefact they'll use, such as "a checklist entry for the in-game check", rather than for the check itself.
- Everything a person has to verify goes into the Human check ticket for that agent ticket.

## A Human check ticket

| Part | What it holds |
|---|---|
| Title | `Human check: <what> (#<agent ticket>)` |
| Marker | `<!-- artisan-agent:human-check-for #<agent ticket> -->` as the body's first line. It is the durable mark; there is no extra label |
| Label | `ready-for-human` |
| `## What to check` | What the person verifies, and on what (the build of #<agent ticket>) |
| `## Acceptance criteria` | The criteria only a person can check, as checkboxes |
| `## Blocked by` | `- #<agent ticket>`, and the native blocking edge: the agent ticket blocks the Human check |

A Human check is not a hands-on ticket: on a hands-on ticket the Artisan builds the work; a Human check verifies work an agent built. It belongs to the same plan as its agent ticket, is listed in that plan's view, and is not estimated as agent work.

## The plan check

`to-plan.sh check` and `render` flag each agent ticket's criterion that contains one of the phrases below (case-insensitive, whole words), under "Needs your attention", with the offer to split it into a Human check. `plan.sh build` flags the same in a draft's `acceptance` lists. A Human check ticket's own criteria are never flagged.

While a flag stands, the plan can't be approved: `check` exits 1, so `publish` refuses, and `state.sh init` refuses a plan with an open flag. Each flag is cleared one of two ways:

- **Split it**: `to-plan.sh split-human-check --repo <owner/name> --graph <graph.json> [--plans <plans.json>] <ticket> "<criterion>"` moves the criterion off the agent ticket into its Human check ticket, creating that ticket (title, marker, `ready-for-human`, blocking edge) or adding to the existing one. Running it again changes nothing.
- **Override it**: the Artisan decides the criterion stays, with a reason: `--override-human-check <ticket> "<criterion>" --why "<reason>"` on `to-plan.sh check` or `publish`, or on `plan.sh build`. It is recorded on the plan (`human_check_overrides` in `plans.json` and the plan issue's body; in `plan.json` at the plan step).

## Phrases

A criterion containing any of these reads as needing a person. A project adds its own in `.artisan-agent/config.yml` under `human_check_phrases`.

- `in game`
- `in-game`
- `by hand`
- `manually`
- `visually`
- `by eye`
- `on a real device`
- `the player checks`
- `the Artisan checks`
- `looks right`
