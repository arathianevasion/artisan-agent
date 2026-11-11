# The run state file

The state file is the record of a run's plan, progress and evidence that lets any fresh session carry the run on. This page is its one definition. The scripts that read and write it are in `${CLAUDE_PLUGIN_ROOT}/scripts/`: `state.sh` (create, lock, record events), `sweep.sh` and `reconcile.sh`. They need `bash` (3.2 is enough), `git`, `jq`, and `gh` for the reconciler.

## Where it lives

```
<main checkout>/.artisan-agent/
  config.yml                       committed: the project's settings
  runs/                            gitignored: working state
    <run-id>/
      state.json                   the state file
      state.lock                   the writer lock, while held (a symlink to the holder's pid)
      results/
        <ticket>.json              a worker's result file (the result contract in implement-plan's dispatch.md)
        <ticket>.exit.json         an exit record: the worker process ended (written by the runner, even on a crash)
        findings/<ticket>.jsonl    the worker's findings, one JSON object per line
```

The run folder is always in the main checkout, never a worktree: `state.sh run-dir <run-id>` prints it from anywhere in the repo. `state.sh init` refuses a run folder git does not ignore.

## Rules

- **Schema version.** `schema_version` is `1`. Every script refuses to read or write a file with another version. A change to the shape bumps it and updates this page.
- **One writer.** A writer holds `state.lock`, a symlink whose target is its pid. The orchestrator holds it while a wave runs, the chat between waves: take it with `state.sh lock <run-dir> <pid>` using a long-lived pid (the session's process, not a one-off shell) and export `ARTISAN_WRITER_PID=<pid>` so every script call writes under it. A call with no lock held takes it for itself and releases it. Anyone else is refused with exit status `3` and the holder's pid. A lock whose pid is dead is stale; the next writer removes it and carries on.
- **One-step rewrite.** Every write produces the whole new file as a temp file in the run folder, checks it is valid JSON of this schema version, and renames it over `state.json`. An interrupted writer leaves a stray `.state.json.tmp.<pid>` and the previous state file untouched. A write that changes nothing is skipped, so the file is only rewritten when an event happened.
- **Files are the truth, git and the tracker are the facts.** Result files, exit records and findings files say what workers did; git says what is merged; the tracker says what is open and what blocks what. The state file is rebuilt from them by the sweep and the reconciler, and running either twice on the same inputs changes nothing.

## Events

Each event is one `state.sh` call (the file is rewritten once per event):

| Event | Call | Effect |
|---|---|---|
| wave starts | `wave-start <run-dir> <wave> <plugin-version> <team> <product> <individual>` | records the wave's plugin version and guardrail source commits (`-` for a level with no source) |
| dispatch | `dispatch <run-dir> <ticket> <worker-pid> [deadline-epoch]` | `in_flight`, attempts + 1, pid, deadline (default: now + the ticket's `caps.deadline_seconds`) |
| result | `sweep.sh <run-dir>` | reads result files, exit records, deadlines and pids; logs findings |
| verified | `evidence <run-dir> <ticket> <evidence.json>` | stores the ticket's evidence |
| merge | `merge <run-dir> <ticket> <merge-commit>` | `merged`, merge commit recorded |
| decision waits | `decision <run-dir> <decision.json>` | adds to the decision queue |
| orchestrator spend | `cost <run-dir> <usd>` | adds to `costs` |
| anything else | `update <run-dir> <jq-filter> [jq args...]` | a locked, one-step jq rewrite |

## Fields

Top level:

| Field | Level | Meaning |
|---|---|---|
| `schema_version` | top-level | `1` |
| `run_id` | top-level | the run's id, also its folder name |
| `repo` | top-level | `owner/name` on the tracker |
| `plan` | top-level | the approved plan, as approved (below) |
| `tickets` | top-level | per-ticket progress, keyed by ticket number as a string (below) |
| `integration` | top-level | `branch`: the run's integration branch; `merges`: `[{ticket, commit}]` in merge order |
| `findings` | top-level | the findings log: each line of each findings file, as `{from, seq, ...the worker's object}` (`{from, seq, raw}` if the line is not a JSON object) |
| `findings_read` | top-level | per ticket, how many complete lines of its findings file are already logged |
| `costs` | top-level | `workers_usd` (sum of tickets' `cost_usd`), `orchestrator_usd`, `total_usd` |
| `decisions` | top-level | the queue of decisions waiting for the Artisan: `{id, kind, ticket?, question, status: "waiting", at, ...}` |
| `waves` | top-level | per wave started: `{wave, started_at, plugin_version, guardrails: {team, product, individual}}`, each a source commit or `null` |
| `frontier` | top-level | tickets dispatchable now, as last computed by the reconciler |

`plan`, copied from the approved plan by `state.sh init <run-dir> <plan.json>`. The plan file needs `run_id`, `repo`, `integration_branch` and `scope`; the rest default.

| Field | Meaning |
|---|---|
| `scope` | the agreed scope: every ticket in the run. A ticket added later (triage-admitted, urgent) is added here and the reconciler gives it a `tickets` entry |
| `waves` | the forecast waves, `[[ticket, ...], ...]`. A forecast only: the frontier never comes from it |
| `tickets` | per ticket: `model`, `caps` (`max_budget_usd`, `max_turns`, `deadline_seconds`), `branch` (default `agent/<ticket>`) |
| `gates` | the gates the Artisan approved for this run |
| `max_agents` | Max Agents (default 5) |
| `budget_usd` | the run's approved budget |
| `attempts_per_ticket` | failed attempts allowed before a ticket is blocked (default 2) |

`tickets.<n>`:

| Field | Meaning |
|---|---|
| `status` | `queued` (waiting for the frontier), `in_flight` (a worker is on it), `returned` (result in, awaiting verification and merge), `merged`, `blocked` (needs the Artisan or a decision), `closed` (closed on the tracker without a merge) |
| `attempts` | dispatches so far |
| `pid` | the worker's pid while `in_flight`, else `null` |
| `branch` | the ticket's branch |
| `dispatched_at`, `deadline_at` | epoch seconds of the last dispatch and its wall-clock deadline |
| `result` | from the result file: `{status, commit, notes, file}` |
| `evidence` | the ticket's evidence, written after verification |
| `merge_commit` | the merge commit on the integration branch |
| `cost_usd` | from the result file (`cost_usd`, or `claude -p`'s `total_cost_usd`) |
| `failures` | `[{attempt, reason, at}]`, one per failed attempt |

## The sweep

`sweep.sh <run-dir>`, on every wake and at least every sweep interval (`config.yml`, default 5 minutes). For each `in_flight` ticket, first match wins:

1. A result file: recorded. `complete` → `returned`; `blocked` → `blocked`; `failed` → a failed attempt.
2. An exit record and no result file: a failed attempt.
3. Past `deadline_at`: the worker and its children are stopped (TERM, then KILL after `ARTISAN_STOP_GRACE` seconds, default 5) and it is a failed attempt.
4. The pid is not alive: a failed attempt (a crash that wrote nothing).

A failed attempt appends to `failures` and sends the ticket back to `queued`, or, once `attempts` reaches `attempts_per_ticket`, to `blocked` with an `exception` decision queued for the Artisan. The sweep then logs new complete lines of every findings file and recomputes `costs`.

## The reconciler

`reconcile.sh <run-dir>` is the first thing a new orchestrator runs, crashed predecessor or not. Under one lock:

1. **Git.** A ticket whose branch was merged into the integration branch is `merged`, with the merge commit. Merges are `--no-ff`, so the merge commit sits on the integration branch's first-parent line; a ticket branch still on that line (dispatched, nothing merged) does not count. This comes before the sweep, so a worker whose branch was merged before a crash is not counted as a failed attempt.
2. **Sweep.** As above.
3. **Tracker.** For each ticket in scope, `gh api repos/<repo>/issues/<n>` (open or closed, labels) and `gh api repos/<repo>/issues/<n>/dependencies/blocked_by` (native blockers). A failed read exits 1 with git's merges and the sweep kept and the frontier not recomputed. A `queued` ticket the tracker has closed becomes `closed`.
4. **Frontier.** Every `queued` ticket in scope, open on the tracker, not labelled `ready-for-human`, whose blockers are all merged into the integration branch (blockers in the run) or closed (blockers outside it). Printed one per line and stored in `frontier`.

Wave width (Max Agents, overlapping file sets) is the orchestrator's choice from the frontier, not the reconciler's.

## Known limits

- A pid can be reused after its process dies; the sweep and the lock then see a live process. Deadlines bound how long that can mislead the sweep.
- Merged tickets are found by ticket branch. A merged branch that has since been deleted is found only through `merge_commit` already in the state file.
