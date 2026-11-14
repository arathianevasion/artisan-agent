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

## In a run

Runs don't wait on Human checks; the human stage gates validate them (the owner's ruling on #157). One can also join a run part way: a criterion the verifier marks as needing a human check is split off on a pass into the agent ticket's Human check, which joins the run's scope (`references/evidence-contract.md`, "Needs a human check"; the owner's decision on #158). A Human check in a run's scope is known by its body marker: the reconciler records it as `tickets.<t>.human_check.for` (a graph's `human_check_for` works too).

- **Never dispatched, never waited on.** It is never on the frontier, `wave.sh dispatch` refuses it, and `human.sh` never makes it a hands-on ticket. Its native "blocked by" edge to its agent ticket stays on the tracker, but the run's own dependency logic ignores Human checks both ways: no ticket waits on one, it is never a gate's dependent, and an open one never makes the run `blocked`, `stranded` or `parked`. `wave.sh status` says `done` without them and counts them: `Human checks: 3 open (next slice gate)`, or `(end gate)`.
- **Slice gates combine them.** A slice gate's packet (`gate.sh open`) has a **Human checks** section: one checklist of every open Human check whose agent ticket is in the slice, and of every one carried from an earlier gate, each with what to check, its criteria and the build to try (the integration branch's tip and the run's integration worktree). A risk gate lists none. The chat's compressed view names them.
- **Answers**, from either chat (`gate.sh check <run> <n|all> pass|fail|later [--gate <issue|end>] [--by NAME]`; a fail is a bug unless `--not-bug`, so `--bug` changes nothing). An answer given while a wave holds the lock counts at once: a second is refused (6).

| The Artisan says | Call | Effect |
|---|---|---|
| check N pass | `gate.sh check <run> N pass [--notes T]` | closes the Human check, with the result posted on it; event `human-check-passed` |
| pass all checks | `gate.sh check <run> all pass --gate <issue>` | the same for every open check on that gate |
| check N fail: why | `gate.sh check <run> N fail --why W [--not-bug]` | "change/redirect …, a bug": a rework ticket on the agent ticket joins the run (`Rework #<agent>: Human check #<n> failed`, `ready-for-agent`, `in-run`), natively blocking the gate's dependents while the gate is open, as a redirect does, and the check; events `human-check-failed`, `bug-found` (`where: "gate"`, #122; not with `--not-bug`) and `rework`. The check stays open, to be tried again on the rework's build |
| check N later | `gate.sh check <run> N later` | not done yet: it carries to the next gate |

  "Keep all" (`gate.sh approve`) never passes a Human check: one left unanswered carries to the next slice gate that opens, or to the end gate. An answer given while a wave holds the lock waits in `gates/pending/` like any other gate answer.
- **The end gate settles them.** Its packet lists every open Human check and every one deferred. `end-gate.sh approve` refuses (22) while one is open and not deferred: no PR is cut. Answer it with `gate.sh check` (the gate is `end`), or defer it past the run: `end-gate.sh defer-check <run> <n> --why W [--by NAME] [--return CONDITION]` leaves the ticket open, labelled `deferred` with a return condition, and logs `human-check-deferred`.

Each event names `ticket`, `agent_ticket`, `gate` and `by`. The state: `tickets.<t>.human_check` (`references/state-file.md`).

## The plan check

`to-plan.sh check` and `render` flag each agent ticket's criterion that contains one of the phrases below (case-insensitive, whole words), under "Needs your attention", with the offer to split it into a Human check. `plan.sh build` flags the same: in a draft ticket's `acceptance` list when it has one (the issue is then not read), otherwise in the criteria of the ticket's issue body (`scripts/lib/criteria.py extract`). When an issue can't be read (no gh, offline) the build still succeeds and names those tickets on stderr as unchecked. A Human check ticket's own criteria are never flagged.

While a flag stands, the plan can't be approved: `check` exits 1, so `publish` refuses, and `state.sh init` refuses a plan with an open flag. Each flag is cleared one of two ways:

- **Split it**: `to-plan.sh split-human-check --repo <owner/name> [--graph <graph.json> [--plans <plans.json>]] <ticket> "<criterion>"` moves the criterion off the agent ticket into its Human check ticket, creating that ticket (title, marker, `ready-for-human`, blocking edge) or adding to the existing one. Running it again changes nothing. It moves a checkbox under the agent ticket body's `## Acceptance criteria`; a criterion that sits only in a brief comment is written into the Human check by hand.
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
