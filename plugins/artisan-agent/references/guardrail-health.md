# Guardrail health, moves and audits

The retro prunes as well as adds (#74). `${CLAUDE_PLUGIN_ROOT}/scripts/guardrail-health.sh` reads the run history (the state files' event logs, oldest run first) and **proposes**; the Artisan decides in the retro's one chat round, and a loosening is only written by `guardrails.sh loosen` (`references/guardrails.md`). Vocabulary: GLOSSARY.md. Tested in `tests/guardrail-health.test.sh`.

## Health

`guardrail-health.sh health --runs <run folder>... [--misses retro/misses.jsonl] [--bugs retro/bugs.jsonl] [--threshold 3] [--table]` shows every guardrail in force (`guardrails.sh resolve`) as **fired**, **bypassed** (with each reason) or **never fired**, with its origin. A move is proposed once its evidence reaches the threshold (default 3 events; the config's evidence threshold is passed as `--threshold`).

| Evidence | Counts toward | Event it reads |
|---|---|---|
| A bypass with a reason | loosen | `guardrail-bypassed` (`guardrail`, `reason`) |
| A gate in the guardrail's area approved unchanged | loosen | `gate-decision` with `outcome: keep` and no redirect |
| A guardrail that never fired | loosen (one per run that recorded guardrail events) | no `guardrail-fired` or `guardrail-bypassed` for it, in a run that recorded any |
| A card changed or a gate redirected in the area | tighten | `gate-decision` with `outcome: change` or `redirect: true` |
| A spot-check answered "I'd have decided differently" | tighten | `spot-check` with `answer: differently` |
| A counted triage miss | tighten | a line of `retro/misses.jsonl` |
| A bug traced to the area, caught at a gate or shipped | tighten | `bug-found` (`where: gate`), a line of `retro/bugs.jsonl` (`where: shipped`), or an older run's `shipped-bug` |

An event belongs to a guardrail when its `guardrail` is the guardrail's `id`, its `area` (or any of its `areas`) is the guardrail's `area`, or it names a built-in: `scope-floor` belongs to the guardrail keyed `scope-floor`, `defer-only` to one marked `defer_only`. Rules:

- **The scope floor and defer-only gates never loosen.** A guardrail is protected when its `key` is `scope-floor` or it has `defer_only: true`. Its loosen evidence is listed under `never_loosen`, with no proposal; `guardrails.sh loosen` refuses it (7).
- **Evidence both ways** (loosen and tighten both at the threshold) is raised as a `conflict` move: neither is proposed.
- **Guardrail conflicts** (`resolve`'s `conflicts` and `overridden`) are carried in the output for the retro to raise.
- Fewer events than the threshold propose nothing.

## Where the events come from

Each is written in the same one-step state write as the change it belongs to (`references/state-file.md`). A run from before these events has none, which already reads as "no evidence".

| Event | Written by | Fields |
|---|---|---|
| `guardrail-fired` | a gate a guardrail opened, when it opens: an area's risk gate (`gate.sh open`; `guardrail: "area:<name>"`, `area`), an exception gate whose exception decision names a guardrail (`gate-action.sh sync`; the scope floor's is `scope-floor`), the overrun gate (`budget.sh guard`; `defer-only`). Each such gate records them under `guardrails` (`[{guardrail, area?}]`) | `guardrail`, `area?`, `gate`, `tickets?` |
| `guardrail-fired` | `sweep.sh`, when it reads a worker's `question` finding (`questions.sh file`) with criterion 2, blocking or split: a worker filing a scope question is the scope floor firing. Once per question: the sweep reads each findings line once | `guardrail: "scope-floor"`, `ticket` (the asking worker's), `areas` (the ticket's), `question` (its number) |
| `guardrail-fired` | `verify.sh judge`, for each unmet criterion on which the verifier named a guardrail (`guardrail: <id>`) | `guardrail`, `ticket`, `attempt`, `criterion`, `by: "verifier"` |
| `guardrail-bypassed` | `gate-action.sh bypass` (or closing it by hand) of a gate with `guardrails`, one per guardrail; a gate no guardrail opened logs none. Also `guardrails.sh loosen --override-reason --run-dir` | `guardrail`, `area?`, `gate`, `reason` (the `--why`, or null), `by` |
| `gate-decision` | `gate.sh change` and `gate.sh guardrail` (a card), `gate.sh approve` ("keep all"; `gate.sh sync` logs the same event for a gate closed by hand, `by` "Artisan (closed on the tracker)": one for the whole gate, `card: null`, `cards`: the number kept; none when no card was left to keep), `gate-action.sh redirect` (the gate, `card: null`) | `gate`, `card`, `by`, `outcome` (`keep` or `change`), `redirect`, `areas` (every area of the card's ticket; the union over the kept cards' tickets for "keep all"; every area of the gate's tickets for a redirect), `cards?` |
| `bug-found` | the Artisan flagging a bug at any review gate: `--bug` on `gate.sh change`, `gate-action.sh redirect`, `retry` or `take`; `gate.sh bug <run> <ticket> --gate end` (or `urgent-<t>`, or any gate) where there is no card to change | `ticket`, `areas`, `where: "gate"`, `gate`, `by`, `why?` |

### Bugs found after shipping

At the retro, `guardrail-health.sh bugs --runs ... --since <the last retro's date> [--bugs <run>/retro/bugs.jsonl] [--table]` lists the `bug` issues opened since then whose title or body mentions (`#<n>`) a ticket a run closed, with that ticket's areas (`--issues FILE` stands in for `gh issue list --label bug --json number,title,body,createdAt,url`). A mention can be loose, so the Artisan confirms each one: `bug-confirm --runs ... --out <run>/retro/bugs.jsonl --issue N --ticket T [--by NAME]` appends `{issue, ticket, areas, where: "shipped", run, by, at}`, once per issue and ticket (6 when no run given closed the ticket). Only confirmed lines count, read by `health --bugs`; nothing is written into old runs' state files.

## Loosening follows a report

`health --record` keeps the report (`id` `health-<epoch>`, `date`, `runs`, `threshold`, `proposals`) as the latest one, in `ARTISAN_HEALTH_DIR` (default `<config dir>/artisan-agent-health/latest.json`). `guardrails.sh loosen` reads it: it proceeds only if the report proposes loosening that guardrail, and records `report: {id, date}` on the `loosen` move; otherwise it exits 8 saying whether no report exists or the latest one doesn't propose it. `--override-reason` proceeds without one and records `override: {reason, by}` on the move; with `--run-dir` it also appends a `guardrail-bypassed` event (`guardrail`, `reason: "loosened without a health report: <reason>"`, `by`) to that run's state file, which the next health report counts as loosen evidence.

## Audits

| Command | What it does |
|---|---|
| `spot-check --runs ... [--count 3]` | picks about three decisions a worker made alone (`tickets.<t>.evidence.decisions`) of tickets no slice gate showed (`review_gates[].tickets`, `provisional_shown`), provisional first. Ask the Artisan whether they would have decided differently; record each answer with `spot-check-record --run D --ticket T --card I --answer same\|differently [--area A]`. "Differently" is tighten evidence |
| `audit --runs ... [--misses FILE]` | each counted triage miss with the criterion that should have caught it (or a prompt to name one), and the run's discards and deferrals (`pulled`, `deferred-question`, tickets closed unmerged) grouped by area or reason: a group at the threshold gets a suggested guardrail or criterion |
| `hands-on --runs ...` | after a run with a hands-on ticket (`human-done`), the question to ask: "What did you decide that an agent would have needed? Which ADR or guardrail would have let an agent build it your way?" The answers become ADR lessons (`domain` lessons, `skills/retro/SKILL.md`). After 5 runs (`--nudge-after`) with none, a nudge |
| `backstop --runs ... [--repo-dir D] [--main REF] [--since DATE]` | flags commits straight to `main` (a first-parent commit that is neither a merged PR nor a run's merge), merges to `main` with no PR or run record, merged PRs whose branch no run opened (`integration.branch`, `tickets.<t>.branch`), and tickets closed outside a run (not merged or closed by any run). `--prs` and `--closed` take JSON files standing in for `gh pr list --json number,headRefName,mergeCommit` and `gh issue list --state closed --json number,closedAt` |

Every list shown to the Artisan is a markdown table (`--table`).
