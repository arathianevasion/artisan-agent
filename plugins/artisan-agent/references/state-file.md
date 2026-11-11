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
        <ticket>.<n>.result.json   attempt n's result file: the worker's evidence record (references/evidence-record.md)
        <ticket>.<n>.exit.json     attempt n's exit record: the worker ended (written by run-ticket.sh, even on a crash)
        orchestrator-w<w>.<n>.*    the same two files for wave w's orchestrator; its result file is the wave report
        findings/<ticket>.jsonl    the worker's findings, one JSON object per line
      workers/<id>.<n>/            per session: runner.pid, prompt.md, output.json, logs (scripts/README.md)
      prompts/<id>.<n>.md          the prompt wave.sh or verify.sh wrote for each session (verify-<t>.<v>.criteria.json: a verifier's criteria)
      prompts/<ticket>.<n>.failure.md  a retry's failure evidence from attempt n-1, also in its prompt
      verify/<ticket>.<n>.evidence.json  the evidence contract verify.sh judge built for attempt n; <ticket>.<n>.comment.md, posted on a fail
      merges/<ticket>.<n>.suite.log  the full suite's output after merging; <ticket>.comment.md, the evidence posted
      workers/orchestrator-w<w>.<n>/transcript.path  the orchestrator's transcript (its SessionStart hook), for drain.sh check
      workers/orchestrator-w<w>.<n>/handoff.json     the hand-off marker its PreCompact hook left
      .digest-seen                 the last event seq the chat was shown in the run digest (run-digest.sh)
```

Beside the repo, never inside it: `<repo>-wt/run-<run-id>/` is the run's integration worktree (the integration branch checked out; every merge happens here) and `<repo>-wt/<run-id>-<ticket>.<n>/` each worker's worktree, removed once its ticket merges. `scripts/wave.sh` makes and removes them.

The run folder is always in the main checkout, never a worktree: `state.sh run-dir <run-id>` prints it from anywhere in the repo. `state.sh init` refuses a run folder git does not ignore.

## Rules

- **Schema version.** `schema_version` is `1`. Every script refuses to read or write a file with another version. A change to the shape bumps it and updates this page.
- **One writer.** A writer holds `state.lock`, a symlink whose target is its pid. The orchestrator holds it while a wave runs, the chat between waves. `wave.sh launch` hands the chat's lock to the orchestrator's runner (`run-ticket.sh --lock-from`) before the orchestrator's session starts, the runner exports its own pid to that session as `ARTISAN_WRITER_PID`, and once the orchestrator exits the lock is stale and `wave.sh status` takes it back for the chat. Otherwise: take it with `state.sh lock <run-dir> <pid>` using a long-lived pid (the session's process, not a one-off shell) and export `ARTISAN_WRITER_PID=<pid>` so every script call writes under it. A call with no lock held takes it for itself and releases it. Anyone else is refused with exit status `3` and the holder's pid. A lock whose pid is dead is stale; the next writer removes it and carries on.
- **One-step rewrite.** Every write produces the whole new file as a temp file in the run folder, checks it is valid JSON of this schema version, and renames it over `state.json`. An interrupted writer leaves a stray `.state.json.tmp.<pid>` and the previous state file untouched. A write that changes nothing is skipped, so the file is only rewritten when an event happened.
- **Files are the truth, git and the tracker are the facts.** Result files, exit records and findings files say what workers did; git says what is merged; the tracker says what is open and what blocks what. The state file is rebuilt from them by the sweep and the reconciler, and running either twice on the same inputs changes nothing.

## Events

Each event is one `state.sh` call (the file is rewritten once per event):

| Event | Call | Effect |
|---|---|---|
| wave starts | `wave-start <run-dir> <wave> <plugin-version> <team> <product> <individual>` (called by `scripts/guardrails.sh wave-start`, which fetches the sources) | records the wave's plugin version and guardrail source commits (`-` for a level with no source) |
| dispatch | `dispatch <run-dir> <ticket> <worker-pid> [deadline-epoch]` | `in_flight`, attempts + 1, pid, deadline (default: now + the ticket's `caps.deadline_seconds`; a dispatch with neither is refused). Attempt n's files are named `<ticket>.<n>.*`, with n the ticket's `attempts` after dispatch, so a retry never reads an earlier attempt's files |
| result | `sweep.sh <run-dir>` | reads result files, exit records, deadlines and pids; logs findings |
| verifier started | `verify.sh start <run-dir> <ticket>` | appends to `verifications`; event `verify` (`ticket`, `attempt`, `verifier`) |
| verified | `verify.sh judge <run-dir> <ticket>` | stores the evidence contract in `evidence` (`references/evidence-contract.md`), logs both sessions' cost; event `verified` (`ticket`, `attempt`, `verifier`, `verdict`, and `met`, `total` or `reason`) |
| evidence stored directly | `evidence <run-dir> <ticket> <evidence.json>` | stores the ticket's evidence |
| merge | `merge <run-dir> <ticket> <merge-commit>` | `merged`, merge commit recorded |
| closed on the tracker | `closed <run-dir> <ticket>` | `tracker_closed` set |
| any other event | `event <run-dir> <json>` | logged in `events` |
| decision waits | `decision <run-dir> <decision.json>` | adds to the decision queue |
| orchestrator spend | `cost <run-dir> <usd>` | adds to `costs` |
| number overridden for this run | `override <run-dir> <key> <value>` | changes `plan.config` and records `plan.overrides`; `.artisan-agent/config.yml` is never written |
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
| `integration` | top-level | `branch`: the run's integration branch; `merges`: `[{ticket, commit}]` in merge order; `worktree` and `base`, once `wave.sh start` has made the integration worktree |
| `findings` | top-level | the findings log: each line of each findings file, as `{from, seq, ...the worker's object}` (`{from, seq, raw}` if the line is not a JSON object) |
| `findings_read` | top-level | per ticket, how many complete lines of its findings file are already logged |
| `costs` | top-level | `workers_usd` (sum of tickets' `cost_usd`), `orchestrator_usd`, `total_usd` |
| `decisions` | top-level | the queue of decisions waiting for the Artisan: `{id, kind, ticket?, question, status: "waiting", at, ...}` |
| `waves` | top-level | per wave started: `{wave, started_at, plugin_version, guardrails: {team, product, individual}}`, each a source commit or `null` |
| `frontier` | top-level | tickets dispatchable now, as last computed by the reconciler |
| `halted` | top-level | `null`, or, once a wave failed whole, `{wave, tickets, reason, at}`. `wave.sh launch` refuses while it is set; `--resume` (the Artisan's decision) sets it back to `null` |
| `orchestrators` | top-level | every orchestrator launched, in order: `{id, wave, attempt, launched_at}`, plus `cost_usd` once `wave.sh status` has seen it end, and `handoff` (`{reason, percent, at}`) when it handed its wave to the next one (`drain.sh handoff`; `skills/implement-plan/references/context-drain.md`). Its pid is in `workers/<id>.<attempt>/runner.pid`, its files are named like a worker's |
| `events` | top-level | the event log, in order: `{seq, at, event, ...}` (below) |

`plan`, copied from the approved plan by `state.sh init <run-dir> <plan.json>`. The plan file needs `run_id`, `repo`, `integration_branch` and `scope`; the rest default. `state.sh` never reads `config.yml` itself: the plan step (`plan.sh build`) reads it and puts its numbers into the plan.

| Field | Meaning |
|---|---|
| `scope` | the agreed scope: every ticket in the run, and the only tickets that dispatch. `state.sh dispatch` and `run-ticket.sh` refuse any other ticket with exit status 4. A ticket added later (triage-admitted, urgent) is added here, by its own approval, and the reconciler gives it a `tickets` entry |
| `waves` | the forecast waves, `[[ticket, ...], ...]`. A forecast only: the frontier never comes from it |
| `tickets` | per ticket: `model`, `caps` (`max_budget_usd`, `max_turns`, `deadline_seconds`), `branch` (default `agent/<ticket>`); from the plan step also `title`, `expected_output`, `expected` (`input_tokens`, `output_tokens`, `minutes`), `expected_files` (paths the ticket will touch; a trailing `/` covers a directory; they bound the wave width), `estimate_usd` and `estimate_basis` |
| `gates` | the gates the Artisan approved for this run |
| `max_agents` | Max Agents (default 5) |
| `budget_usd` | the run's approved budget |
| `attempts_per_ticket` | failed attempts allowed before a ticket is blocked (default 2) |
| `estimate_usd` | the approved estimate, in estimated dollars (`budget_usd` adds the overrun allowance) |
| `config` | every config number this run uses: the project config with this run's overrides. The orchestrator reads its numbers here, not from `config.yml` |
| `overrides` | `{<key>: {value, project}}`, one per number overridden for this run, with the project's value it replaced |
| `suite_command` | the full suite, run with `sh -c` in the integration worktree after every merge |
| `orchestrator` | optional `model`, `estimate_usd` and `deadline_seconds` for the orchestrators (defaults: `claude-sonnet-5-5`, $1, the longest ticket deadline plus 30 minutes) |

`tickets.<n>`:

| Field | Meaning |
|---|---|
| `status` | `queued` (waiting for the frontier), `in_flight` (a worker is on it), `returned` (result in, awaiting verification and merge), `merged`, `blocked` (needs the Artisan or a decision), `closed` (closed on the tracker without a merge), `deferred` (pulled from the run with a deferred question, `references/worker-questions.md`) |
| `attempts` | dispatches so far |
| `pid` | the worker's pid while `in_flight`, else `null` |
| `branch` | the ticket's branch |
| `dispatched_at`, `deadline_at` | epoch seconds of the last dispatch and its wall-clock deadline |
| `result` | from the current attempt's result file: `{status, commit, notes, file}` |
| `evidence` | the ticket's evidence contract, written by `verify.sh judge` (`references/evidence-contract.md`); `wave.sh merge` needs its `verdict` to be `pass` for the current attempt and commit |
| `verifications` | `[{attempt, worker_attempt, commit, base, model, worktree, started_at, verdict, reason?}]`, one per verifier started; `verdict` is `null` until judged, then `pass`, `fail` or `error` |
| `merge_commit` | the merge commit on the integration branch |
| `cost_usd` | the sum of `attempt_costs`: per attempt, from the result file's `cost_usd`, else the session's `total_cost_usd` in its JSON output (recorded by the sweep, and again by `verify.sh judge` and `wave.sh merge` once the session has ended); verifiers included |
| `failures` | `[{attempt, reason, at}]`, one per failed attempt |
| `attempt_costs` | `{"<attempt>": usd, "verify.<v>": usd}`, each attempt's session cost, failed attempts included, and each verifier's |
| `worktree`, `base` | the current attempt's worktree and the integration commit it branched from (`wave.sh dispatch`) |
| `suite` | `{command, passed, log}` from the last merge attempt |
| `tracker_closed` | `true` once the ticket is closed on the tracker with its evidence posted |
| `wave` | the wave its last dispatch belonged to (the last orchestrator's wave; 0 before any) |
| `resolve` | its one conflict-resolution try: `{attempt, paths, pre, outcome, why?, at}`, `outcome` `pending` (the merge left in progress), `resolved`, `unresolved` or `abandoned` |
| `risk_gate` | `{status, percent, at, cleared_at?}` when it merged while the orchestrator was at the review band (`drain.sh gate`): `waiting` holds its dependents off the frontier and out of `wave.sh dispatch` until `cleared` |
| `questions`, `answers` | the questions its worker filed for triage, `[{ticket, blocking, state: open|deferred|answered, answer?, at}]`, and the answers given to its next worker, `[{question, answer}]` (`questions.sh`, `references/worker-questions.md`) |
| `blocked_reason` | why `wave.sh` or `verify.sh` blocked it (a conflict, a red suite, a result describing another commit, a verifier that failed twice); a ticket blocked after its last failed attempt has none, and its `failures` say why |

## The event log

Every event that changes a ticket is appended to `events` in the same one-step rewrite as the change, so the log and the fields can't disagree: `dispatch` (`ticket`, `attempt`, `pid`), `result` (`ticket`, `attempt`, `status`), `verify` and `verified` (above), `failed` (`ticket`, `attempt`, `reason`, `next`), `blocked` (`ticket`, `reason`), `merge` (`ticket`, `commit`, and `source: "reconcile"` when the reconciler found it in git), `closed` (`ticket`), `conflict` (`ticket`, `paths`, `next`), `resolve` (`ticket`, `outcome`, `why?`), plus `integration`, `orchestrator` and `guardrail-merge` (`wave`, `from`: `main`'s commit brought into the integration branch because a product guardrail changed, `references/guardrails.md`) for the run's own steps, `halted` (`wave`, `tickets`) and `resumed` (`wave`) for the run as a whole, and `handoff` (`id`, `attempt`, `wave`, `reason`, `percent`), `handoff-failed` (`id`, `attempt`: the next orchestrator didn't launch, the hand-off record was taken back), `risk-gate` (`ticket`, `percent`) and `risk-gate-cleared` (`ticket`, `by`) for the context drain, and, for worker questions, `asked` (`ticket`, `question`), `answered` (`ticket`, `question`, `next`), `deferred-question`, `pulled` and `provisional-shown`. A top-level `provisional_shown` lists the tickets whose provisional cards a packet has shown. `seq` counts from 1; `at` is epoch seconds. A state file from before the log has no `events`; the first event starts it. Reading the log is how anyone checks that a ticket went dispatch, result, verify, verified, merge, closed, in that order.

## The sweep

`sweep.sh <run-dir>`, on every wake and at least every sweep interval (`plan.config.sweep_minutes`, default 5 minutes). For each `in_flight` ticket, reading only the current attempt's files (n = `attempts`), first match wins:

1. A result file: recorded. `complete` → `returned`; `blocked` → `blocked`; `failed` → a failed attempt.
2. An exit record and no result file: a failed attempt.
3. Past `deadline_at`: the worker and every process descended from it are stopped (TERM, then KILL after `ARTISAN_STOP_GRACE` seconds, default 5) and it is a failed attempt.
4. The pid is not alive: a failed attempt (a crash that wrote nothing).

A failed attempt appends to `failures` and sends the ticket back to `queued`, or, once `attempts` reaches `attempts_per_ticket`, to `blocked` with an `exception` decision queued for the Artisan. The sweep then logs new complete lines of every findings file and recomputes `costs`.

## The reconciler

`reconcile.sh <run-dir>` is the first thing a new orchestrator runs, crashed predecessor or not. Under one lock:

1. **Git.** A ticket whose branch was merged into the integration branch is `merged`, with the merge commit. Merges are `--no-ff`, so the merge commit sits on the integration branch's first-parent line; a ticket branch still on that line (dispatched, nothing merged) does not count. This comes before the sweep, so a worker whose branch was merged before a crash is not counted as a failed attempt.
2. **Sweep.** As above.
3. **Tracker.** For each ticket in scope, `gh api repos/<repo>/issues/<n>` (open or closed, labels) and `gh api repos/<repo>/issues/<n>/dependencies/blocked_by` (native blockers). A failed read exits 1 with git's merges and the sweep kept and the frontier not recomputed. A `queued` ticket the tracker has closed becomes `closed`.
4. **Frontier.** Every `queued` ticket in scope, open on the tracker, not labelled `ready-for-human`, whose blockers are all merged into the integration branch (blockers in the run) or closed (blockers outside it). Printed one per line and stored in `frontier`.

Wave width (Max Agents, the ready tickets, overlapping file sets) is applied to the frontier by `scripts/wave-width.sh pick`, not by the reconciler; see `skills/implement-plan/references/parallel-waves.md`.

## Known limits

- A pid can be reused after its process dies; the sweep and the lock then see a live process. Deadlines bound how long that can mislead the sweep.
- Merged tickets are found by ticket branch. A merged branch that has since been deleted is found only through `merge_commit` already in the state file.
