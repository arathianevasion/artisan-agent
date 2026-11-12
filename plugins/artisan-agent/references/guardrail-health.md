# Guardrail health, moves and audits

The retro prunes as well as adds (#74). `${CLAUDE_PLUGIN_ROOT}/scripts/guardrail-health.sh` reads the run history (the state files' event logs, oldest run first) and **proposes**; the Artisan decides in the retro's one chat round, and a loosening is only written by `guardrails.sh loosen` (`references/guardrails.md`). Vocabulary: GLOSSARY.md. Tested in `tests/guardrail-health.test.sh`.

## Health

`guardrail-health.sh health --runs <run folder>... [--misses retro/misses.jsonl] [--threshold 3] [--table]` shows every guardrail in force (`guardrails.sh resolve`) as **fired**, **bypassed** (with each reason) or **never fired**, with its origin. A move is proposed once its evidence reaches the threshold (default 3 events; the config's evidence threshold is passed as `--threshold`).

| Evidence | Counts toward | Event it reads |
|---|---|---|
| A bypass with a reason | loosen | `guardrail-bypassed` (`guardrail`, `reason`) |
| A gate in the guardrail's area approved unchanged | loosen | `gate-decision` with `outcome: keep` and no redirect |
| A guardrail that never fired | loosen (one per run examined) | no `guardrail-fired` or `guardrail-bypassed` |
| A redirect at a gate in the area | tighten | `gate-decision` with `outcome: change` or a `redirect` |
| A spot-check answered "I'd have decided differently" | tighten | `spot-check` with `answer: differently` |
| A counted triage miss | tighten | a line of `retro/misses.jsonl` |
| A shipped bug traced to the area | tighten | `shipped-bug` |

An event belongs to a guardrail when its `guardrail` is the guardrail's `id`, or its `area` is the guardrail's `area`. Rules:

- **The scope floor and defer-only gates never loosen.** A guardrail is protected when its `key` is `scope-floor` or it has `defer_only: true`. Its loosen evidence is listed under `never_loosen`, with no proposal; `guardrails.sh loosen` refuses it (7).
- **Evidence both ways** (loosen and tighten both at the threshold) is raised as a `conflict` move: neither is proposed.
- **Guardrail conflicts** (`resolve`'s `conflicts` and `overridden`) are carried in the output for the retro to raise.
- Fewer events than the threshold propose nothing.

## Audits

| Command | What it does |
|---|---|
| `spot-check --runs ... [--count 3]` | picks about three decisions a worker made alone (`tickets.<t>.evidence.decisions`) of tickets no slice gate showed (`review_gates[].tickets`, `provisional_shown`), provisional first. Ask the Artisan whether they would have decided differently; record each answer with `spot-check-record --run D --ticket T --card I --answer same\|differently [--area A]`. "Differently" is tighten evidence |
| `audit --runs ... [--misses FILE]` | each counted triage miss with the criterion that should have caught it (or a prompt to name one), and the run's discards and deferrals (`pulled`, `deferred-question`, tickets closed unmerged) grouped by area or reason: a group at the threshold gets a suggested guardrail or criterion |
| `hands-on --runs ...` | after a run with a hands-on ticket (`human-done`), the question to ask: "What did you decide that an agent would have needed? Which ADR or guardrail would have let an agent build it your way?" The answers become ADR lessons (`domain` lessons, `skills/retro/SKILL.md`). After 5 runs (`--nudge-after`) with none, a nudge |
| `backstop --runs ... [--repo-dir D] [--main REF] [--since DATE]` | flags commits straight to `main` (a first-parent commit that is neither a merged PR nor a run's merge), merges to `main` with no PR or run record, merged PRs whose branch no run opened (`integration.branch`, `tickets.<t>.branch`), and tickets closed outside a run (not merged or closed by any run). `--prs` and `--closed` take JSON files standing in for `gh pr list --json number,headRefName,mergeCommit` and `gh issue list --state closed --json number,closedAt` |

Every list shown to the Artisan is a markdown table (`--table`).
