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

- **Schema version.** `schema_version` is `1`. Every script refuses to read or write a file whose version is not the one it knows. Only a **breaking** change bumps it:
  - **No bump:** adding an optional field that older scripts ignore and newer scripts treat as defaulted when it is missing. Every field in "Optional fields" below was added this way.
  - **Bump:** removing or renaming a field, changing a field's meaning or type, or making an optional field required.
  - **A bump ships with one of two things:** a migration that brings an older run's state file forward on read, or a refusal that names the plugin version the run started on (the first entry of `waves` with a `plugin_version`, which `wave-start` records) and tells the Artisan to finish the run on that version. Never a bare "wrong schema version". `state_version_message` in `scripts/lib/state-lib.sh` writes that refusal for every script. A run with no wave recorded gets the same refusal without a version to name.

  Why additive changes must not bump: every script refuses any version but an exact match, and plugin auto-update applies a new version from a run's next wave, so a bump in an ordinary release would strand runs in progress between waves. `tests/state-compat.test.sh` holds the rule: a version-1 file with an unknown extra field is accepted, and one missing each optional field is read with the defaults below.
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
| verifier started | `verify.sh start <run-dir> <ticket>` | appends to `verifications`; event `verify` (`ticket`, `attempt`, `verifier`); once per verifier: while the attempt's verifier is running, is waiting to be judged, or has passed, starting again writes nothing |
| verified | `verify.sh judge <run-dir> <ticket>` | stores the evidence contract in `evidence` (`references/evidence-contract.md`), logs both sessions' cost; event `verified` (`ticket`, `attempt`, `verifier`, `verdict`, and `met`, `total` or `reason`; `gate`: the criteria checked by the merge gate, when there are any, #174) |
| evidence stored directly | `evidence <run-dir> <ticket> <evidence.json>` | stores the ticket's evidence |
| merge | `merge <run-dir> <ticket> <merge-commit>` | `merged`, merge commit recorded |
| closed on the tracker | `closed <run-dir> <ticket>` | `tracker_closed` set |
| any other event | `event <run-dir> <json>` | logged in `events` |
| decision waits | `decision <run-dir> <decision.json>` | adds to the decision queue |
| decision answered | `decide <run-dir> <id> <choice> [--by] [--job] [--why] [--level] [--reach] [--area] [--confidence] [--redirect]` | a waiting decision decided as a decision record; 6 when it is not waiting (`references/gate-actions.md`) |
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
| `relays` | top-level | each finding handled: `{from, seq, target, action: relay\|comment\|triage, issue, at}`, written by `findings.sh mark` (`references/findings.md`) |
| `lessons` | top-level | lessons noted during the run for the retro: `{kind: "slicing", ticket, note, at}`, written by the sweep when a worker stops for a design question; `{kind: "guardrail", gate, card, ticket, choice, guardrail_level, reach, area, by, at}`, when the Artisan makes a card a guardrail at a gate |
| `findings_read` | top-level | per ticket, how many complete lines of its findings file are already logged |
| `costs` | top-level | `workers_usd` (sum of tickets' `cost_usd`), `orchestrator_usd`, `total_usd` |
| `decisions` | top-level | the queue of decisions waiting for the Artisan: `{id, kind, ticket?, question, status: "waiting", at, ...}`; `kind` is `exception` (a ticket out of attempts or blocked; adds `issue` and `gate` once its exception gate is open) or `design` (a worker stopped for a design question; adds `recommendation`), `end-gate` and `pr-boundary` (`references/end-gate.md`) among others, including an `exception` with `reason: "guardrail-base"` (no ticket: `base`, `ref`, `product`, `fingerprint`, `base_only`, `ref_only`, `files`, `options`, and `applied` once a halt answer was carried out) and `overrun` (`gate`, `issue`, `gate_actions: ["defer"]`, `options`) and `usage` (`window`, `resets_at`, `options`) and `orchestrator-exit` (#171: the orchestrator exited without finishing its wave; `cause`: `nonzero-exit`, `error_max_turns`, `budget`, `deadline`, `not-completed`, `no-verdict` or `unmerged`; `wave`, `tickets` (its wave's unfinished tickets), `detail`, `orchestrator`, `attempt`, `options: ["resume", "retry", "halt"]`, and `applied` once `wave.sh status` or `launch` carried the answer out). Answered, it is `status: "decided"` with `decided_at` and the decision record's fields (`choice`, `by`, `job?`, `why?`, `guardrail_level?`, `reach?`, `area?`, `confidence?`, `redirect?`): `state.sh decide`, or the gate action that answered it |
| `waves` | top-level | per wave started: `{wave, started_at, plugin_version, guardrails: {team, product, individual}}`, each a source commit or `null` |
| `frontier` | top-level | tickets dispatchable now, as last computed by the reconciler |
| `review_gates` | top-level | every review gate opened: `{id, kind, slice, title, role, issue, tickets, dependents, cards, status: open\|approved\|redirected\|bypassed\|deferred\|empty, left_run?, opened_at, approved_at?, decisions, reworks, guardrails?}` (`guardrails`, `[{guardrail: "area:<name>", area}]`, on a risk gate an area's settings opened); each decision a decision record with its job and who made it (`references/review-gates.md`); a redirect, bypass or deferral adds `redirect`, `bypass` or `deferral` (`{by, at, why?, notes?, released?, mode?, ticket?}`) and `answered`, every action in order (`references/gate-actions.md`) |
| `exception_gates` | top-level | every exception gate opened (`scripts/gate-action.sh`): `{id: "exception-<decision id>", kind: "exception", reason: gave-up\|red-check\|blocked, title, headline, ticket, tickets, decision, dependents, issue, status: open\|decided\|bypassed\|deferred, downstream, opened_at, outcome?, bypass?, deferral?, answered, guardrails?}` (`references/gate-actions.md`); `guardrails` (`[{guardrail, area?}]`) when the exception decision named the guardrail that raised it |
| `halted` | top-level | `null`, or, once a wave failed whole (or the Artisan answered an `orchestrator-exit` decision `halt`), `{wave, tickets, reason, at}`. `wave.sh launch` refuses while it is set; `--resume` (the Artisan's decision) sets it back to `null` |
| `orchestrators` | top-level | every orchestrator launched, in order: `{id, wave, attempt, launched_at}`, plus `cost_usd` once `wave.sh status` has seen it end, `exit` once its exit was judged (#171: `{clean: true, at}`, or `{clean: false, cause, decision, at}` with an `orchestrator-exit` decision queued), and `handoff` (`{reason, percent, at}`) when it handed its wave to the next one (`drain.sh handoff`; `skills/implement-plan/references/context-drain.md`). Its pid is in `workers/<id>.<attempt>/runner.pid`, its files are named like a worker's |
| `overrun_gates` | top-level | every overrun gate opened (`budget.sh`, `references/cost-and-usage.md`): `{id: "overrun-<n>", kind: "exception", title, issue, status: open\|deferred, gate_actions: ["defer"], opened_at, budget_usd, spent_usd, projected_usd, tickets_over: [{ticket, estimate, spent, over_by}], guardrails: [{guardrail: "defer-only"}], action?, decision?: {card, option, choice, why, by, job, at}, deferred_at?}`. An open one holds every new dispatch (17) |
| `usage_park` | top-level | `null`, or while the plan-window guard has parked dispatch (18): `{window: five-hour\|seven-day\|unknown, used, limit, resets_at, why, at, resume: null\|{by, at, after, raised?}}` |
| `ci_park` | top-level | `null`, or while the run is parked on CI (19, #139): the merge gate on CI got no verdict for a merge (CI unreachable, none within `ci_gate.timeout_minutes`, or a run that concluded neither `success` nor `failure`/`timed_out`, such as `cancelled`), so the merge was undone and nothing merges or dispatches: `{ticket, attempt, pre, sha, minutes, at, workflow, branch, run_id, url, conclusion, why}`, with a `ci` decision waiting. `wave.sh unpark-ci` (the Artisan's word) clears it and gives the ticket a `ci_retry` |
| `merge_gate` | top-level | `null`, or while a merge gate is in progress (#142): `{ticket, attempt, gate, mode, pre, sha, result, pid_file, log, at}`, and on CI also `{workflow, branch, minutes, deadline}`, written before the gate starts and cleared with its outcome. The gate runs detached (`merge-gate.sh start`); `result` (`results/merge-<t>.<n>.g<gate>.json`) is where its outcome lands and `pid_file` names its runner. The next `wave.sh merge` finishes a gate with an outcome, waits on one whose runner lives, resumes a CI gate whose runner died but whose run was dispatched (same branch, same run; event `merge-gate-resumed`), and undoes any other dead gate, giving its ticket a `ci_retry` (event `ci-gate-abandoned` on CI, `merge-gate-abandoned` locally). Replaces `ci_gate` (`{ticket, attempt, pre, sha, branch, at}`, #139), which a state file from before may still hold: the next merge takes it as a dead CI gate |
| `usage_verdict` | top-level | `null` until the plan-window guard first runs, then the guard's current verdict `{ok, line, at}`, where `at` is when that verdict was first seen. `budget.sh guard` writes it only when the verdict (`ok` and `line`) changes, so a repeat reading leaves the file untouched and a second sweep changes nothing. `wave.sh status` only reads it (#120) |
| `merge_batch` | top-level | `null`, or while a merge batch is settling (#167, `wave.sh merge` with several tickets): `{id, tickets, attempts, pre, order, commits, red, red_record, rebuild, merged, red_tickets, left_out, gates, at}`. `tickets` and `attempts` (ticket → attempt) are the batch as asked; `pre` is its green base (the integration tip before it, then the last green prefix), which new work branches from meanwhile; `order` the tickets still to settle and `commits` their merge commits built on `pre`, in order; `red` the length of the shortest prefix of `order` known red (`null`: none yet) and `red_record` that gate's record; `rebuild` true while the tickets after a red one wait to be merged afresh; `merged` (`[{ticket, commit}]`), `red_tickets` and `left_out` (`[{ticket, paths}]`: a conflict while building) what became of the rest; `gates` how many gates it has run. While one of its gates runs, `merge_gate` carries `batch`, `tickets` (the prefix it judges) and `suite_log`, with `ticket` and `attempt` the prefix's first. Cleared when every ticket is settled, or when CI gives a gate no verdict (then `ci_park` has `tickets` and `batch`, and `unpark-ci` gives no ticket a `ci_retry`: the tickets are merged afresh) |
| `events` | top-level | the event log, in order: `{seq, at, event, ...}` (below) |

`plan`, copied from the approved plan by `state.sh init <run-dir> <plan.json>`. The plan file needs `run_id`, `repo`, `integration_branch` and `scope`; the rest default. `state.sh` never reads `config.yml` itself: the plan step (`plan.sh build`) reads it and puts its numbers into the plan.

| Field | Meaning |
|---|---|
| `scope` | the agreed scope: every ticket in the run, and the only tickets that dispatch. `state.sh dispatch` and `run-ticket.sh` refuse any other ticket with exit status 4. A ticket added later (triage-admitted, urgent) is added here, by its own approval, and the reconciler gives it a `tickets` entry |
| `waves` | the forecast waves, `[[ticket, ...], ...]`. A forecast only: the frontier never comes from it |
| `tickets` | per ticket: `model`, `caps` (`max_budget_usd`, `max_turns`, `deadline_seconds`), `branch` (default `agent/<ticket>`); from the plan step also `title`, `expected_output`, `expected` (`input_tokens`, `output_tokens`, `minutes`), `escalation` (an urgent ticket only: the escalation tests it meets, shown in its end gate packet), `expected_files` (paths the ticket will touch; a trailing `/` covers a directory; they bound the wave width), `estimate_usd` and `estimate_basis` |
| `gates` | the gates the Artisan approved for this run; a slice gate is `{kind: "slice", slice, tickets?, after?, problem?, solution?, role?}` (`references/review-gates.md`), a risk gate `{kind: "risk", after, tests}` and the end gate `{kind: "end", doubles_as_slice?, bug?}` (`references/end-gate.md`); exception gates are never here |
| `route` | optional: `feature`, `small-change` or `bug`, as the plan step proposed the gates |
| `max_agents` | Max Agents (default 5) |
| `budget_usd` | the run's approved budget; raised only at the overrun gate, each change in `budget_history` (`{from, to, gate, by, at}`) |
| `attempts_per_ticket` | failed attempts allowed before a ticket is blocked (default 2) |
| `estimate_usd` | the approved estimate, in estimated dollars (`budget_usd` adds the overrun allowance) |
| `config` | every config number this run uses: the project config with this run's overrides. The orchestrator reads its numbers here, not from `config.yml` |
| `overrides` | `{<key>: {value, project}}`, one per number overridden for this run, with the project's value it replaced |
| `suite_command` | the full suite, run with `sh -c` in the integration worktree after every merge |
| `suite_source` | where the suite came from (`plan.sh build`): `recorded` (the project's recorded checks), `changed` (the Artisan approved another command), `discovered` (no recorded checks; found by the chat) or `none` |
| `recorded_checks` | the recorded checks at plan time (`checks.sh json`): `{recorded, file, commands, suite}`, or `{recorded: false, reason}`; `references/checks.md` |
| `checks` | `[{command, covers, proven_to_fail}]`: the checks the plan step proved capable of failing, shown in each gate's packet |
| `orchestrator` | optional `model`, `estimate_usd` and `deadline_seconds` for the orchestrators (defaults: `claude-sonnet-5-5`, $1, the longest ticket deadline plus 30 minutes) |

`tickets.<n>`:

| Field | Meaning |
|---|---|
| `status` | `queued` (waiting for the frontier), `in_flight` (a worker is on it), `returned` (result in, awaiting verification and merge), `merged`, `blocked` (needs the Artisan or a decision), `closed` (closed on the tracker without a merge), `deferred` (pulled from the run with a deferred question, `references/worker-questions.md`, or its exception gate deferred), `dropped`, `resliced`, `bypassed` (taken out of the run at its exception gate, `references/gate-actions.md`), `sent_back` (left the run with its dropped or resliced blocker, back in `needs-triage`; `sent_back: {from, at}`) |
| `extra_attempts`, `notes` | attempts the Artisan added at an exception gate ("retry with notes"; failed attempts allowed are `attempts_per_ticket` plus these), and the notes given to the next worker, `[{note, issue, by, at}]` |
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
| `repaired` | `[{attempt, cost_usd, failures, at}]`, each attempt `sweep.sh repair` took back (#151): it completed but was counted as failed because `output.json` was empty; `failures` is the entries that left `failures` |
| `attempt_costs` | `{"<attempt>": usd, "verify.<v>": usd}`, each attempt's session cost, failed attempts included, and each verifier's |
| `worktree`, `base` | the current attempt's worktree and the integration commit it branched from (`wave.sh dispatch`) |
| `suite` | the merge gate's record from the last merge attempt: `{command, passed, mode}`. `mode` is `local` (the suite ran in the integration worktree; `log` is its output, `merges/<t>.<n>.suite.log`) or `ci` (it ran on CI, #139: `workflow`, `branch`, the merge commit `sha`, the run's `run_id`, `url` and overall `conclusion`, and `jobs: [{name, conclusion}]`). A record from before #139 has no `mode`: it was local |
| `ci_retry` | `{pre, sha, at}`: the merge gate (on CI, or since #142 a local one too) is retried on merge commit `sha` at this ticket's next merge, if the integration branch is still at `pre` (otherwise it is merged afresh). Set by `wave.sh unpark-ci` and by a gate that died with no outcome and nothing to wait on; cleared by that merge |
| `tracker_closed` | `true` once the ticket is closed on the tracker with its evidence posted |
| `wave` | the wave its last dispatch belonged to (the last orchestrator's wave; 0 before any) |
| `resolve` | its one conflict-resolution try: `{attempt, paths, pre, outcome, why?, at}`, `outcome` `pending` (the merge left in progress), `resolved`, `unresolved` or `abandoned` |
| `context_risk` | `{percent, at}` when it merged while the orchestrator was at the review band (`drain.sh gate`): the fact that raises the risk gate `risk-context-<t>`, which holds its dependents like any review gate |
| `risk_gate` | legacy, from before that gate was an issue: `{status, percent, at, cleared_at?}`; `waiting` still holds its dependents off the frontier and out of `wave.sh dispatch` until `cleared` (`drain.sh gate-cleared`). Nothing writes it now |
| `human_check` | a Human check only (`references/human-checks.md`, "In a run"): `{for, state: open\|passed\|deferred, gate?, shown?, answers?: [{verdict: pass\|fail\|later, gate, by, at, notes?, why?, rework?}], deferral?: {by, why, return, at}}`. `for` is the agent ticket, from the plan graph's `human_check_for` (`state.sh init`) and the body marker (the reconciler), which agree; `gate` the gate that lists it now, `shown` every gate that has. Passed, the ticket is `closed`; deferred past the run, `deferred`. It is never dispatched, never on the frontier and never waited on |
| `questions`, `answers` | the questions its worker filed for triage, `[{ticket, blocking, state: open|deferred|answered, answer?, at}]`, and the answers given to its next worker, `[{question, answer}]` (`questions.sh`, `references/worker-questions.md`) |
| `steering` | `[{attempt, note, at}]`, each time the Artisan stopped the worker and gave notes (`lever.sh steer`, `references/run-levers.md`). Not a failure: it is not in `failures` and uses none of the ticket's attempts; the notes go into the next worker's prompt |
| `urgent` | `true` for an urgent ticket (`lever.sh urgent`): dispatched on the one extra slot above Max Agents, from `main`, never on the frontier or merged into the integration branch; it ships through its own end gate (`urgent_gates`) |
| `shipped` | an urgent ticket once `end-gate.sh urgent-finish` has run: `{pr, main_merged_into, sync_commit, at}` |
| `gate_waits` | a `queued` ticket only, written by the reconciler: the gates not yet answered that hold it through a merged blocker, `[{id, kind, slice}]` (`gate_waits` in `lib/state-lib.sh`, #170). `wave.sh status` prints `queued: waiting on slice gate <slice>` (`risk gate #<t>` for a risk gate), and `gate-action.sh parked` counts it as held. Absent when nothing holds it |
| `blocked_reason` | why `wave.sh` or `verify.sh` blocked it (a conflict, a red suite, a result describing another commit, a verifier that failed twice); a ticket blocked after its last failed attempt has none, and its `failures` say why |

## Optional fields

Fields scripts treat as absent-means-default, so a state file from before the field (or from a newer plugin that adds more) is still version 1. Fields not listed here (`schema_version`, `run_id`, `repo`, `plan.scope`, `plan.tickets`, `tickets`, `integration.branch`, `costs`, `decisions`, `frontier`, `findings`, and each ticket's `status`, `attempts`, `branch`) are required.

| Field | Default when missing |
|---|---|
| `events` | `[]`; the first event written is `seq` 1 |
| `orchestrators` | `[]`; `current_wave` is 0 |
| `findings_read` | `{}`; no finding line is read yet |
| `relays` | `[]` |
| `lessons` | `[]` |
| `review_gates` | `[]` |
| `end_gate` | absent: the end gate is not open |
| `overrun_gates` | `[]`: no overrun gate opened |
| `usage_park` | `null`: dispatch is not parked on plan usage |
| `ci_park`, `merge_gate`, `merge_batch` | `null`: not parked on CI, no merge gate in progress, and no merge batch settling |
| `usage_verdict` | `null`: the guard has not run yet (absent in older files reads the same) |
| `halted` | `null`: the run is not halted |
| `urgent_gates` | `{}`: no urgent ticket's end gate opened. Per urgent ticket: `{status: open\|approved\|ended, issue, title, opened_at, approved_at?, by?, pr?: {url, branch, base, at}, ended_at?, sync_commit?}` (`end-gate.sh urgent-*`) |
| `plan.additions` | `[]`: nothing added mid-run. Per ticket added (`lever.sh add`, `urgent`): `{ticket, urgent, estimate_usd, budget_before, budget_after, by, at}`; the estimate and its overrun allowance are already in `plan.estimate_usd` and `plan.budget_usd` |
| `plan.tickets.<t>.priority` | `0`: a planned ticket. A ticket added mid-run has 1 (urgent 2); the frontier is ordered by priority, then number |
| `waves` | `[]`: no wave started, so no starting plugin version to name |
| `location` | absent: the run is live on this machine (`Where a run lives`) |
| `provisional_shown` | `[]` |
| `integration.worktree`, `integration.base` | absent until `wave.sh start` makes the integration worktree |
| `plan.gates` | `[]` |
| `plan.overrides` | `{}` |
| `plan.suite_command` | `null`: no suite is run after a merge |
| `plan.checks` | `[]` |
| `plan.orchestrator` | `{}`: the orchestrator defaults apply (`claude-sonnet-5-5`, $1, the longest ticket deadline plus 30 minutes) |
| `attempt_costs` | `{}` (ticket field) |
| `verifications` | `[]` (ticket field) |
| `worktree`, `base` | absent (ticket fields): no worktree for the current attempt |
| `suite` | absent (ticket field): no merge attempted. A `suite` without `mode` is `local` |
| `ci_retry` | absent (ticket field): no gate to retry |
| `tracker_closed` | `false` (ticket field) |
| `wave` | `0` (ticket field) |
| `resolve`, `risk_gate`, `context_risk`, `blocked_reason`, `gate_waits` | absent (ticket fields) |
| `questions`, `answers` | `[]` (ticket fields) |

#54 added `events`, `plan.suite_command`, `plan.orchestrator`, the ticket's `tracker_closed`, and (with the two-tier scripts) `integration.worktree`, `integration.base`, the ticket's `worktree`, `base` and `suite`. It also let a ticket's `cost_usd` fall back to the session's `total_cost_usd` when the result file has none. Reviewed in #96: none of these changed the meaning or type of a field that existed before (the cost fallback only fills a value that was `null`), so none needed a bump.

## The end gate

Once the end gate opens, the state file gains a top-level `end_gate` (absent until then; `scripts/end-gate.sh`, `references/end-gate.md`): `{status: open|approved|ended, issue, title, opened_at, approved_at, by, boundary: {value, source, level?, by?}, prs: [{n, branch, base, tickets, url, at}], ended_at}`.

## Where a run lives

A run is live on one machine at a time. Until it first moves, its state file has no `location`. `scripts/move.sh` (`skills/implement-plan/references/host-and-move.md`) writes `location: {status: "moved"|"live", machine, branch: "runs/<run-id>", at, commit?}`. `moved` means pushed to its `runs/<run-id>` branch and in transit; `live` names the machine that claimed it. `state_lock` (`scripts/lib/state-lib.sh`) refuses with exit 3 every writer on a copy that is `moved`, or `live` on another machine (`ARTISAN_MACHINE`, default `hostname -s`), so the lock travels with the state. `move.sh` writes under `ARTISAN_MOVING=1`, which skips that refusal. Its events: `moved-out` (`from`, `branch`) and `moved-in` (`to`, `branch`). `move.sh drain` sets `halted` with `move: true`, which `move.sh out` and `in` clear.

## The event log

Every event that changes a ticket is appended to `events` in the same one-step rewrite as the change, so the log and the fields can't disagree: `dispatch` (`ticket`, `attempt`, `pid`), `result` (`ticket`, `attempt`, `status`), `verify` and `verified` (above), `failed` (`ticket`, `attempt`, `reason`, `next`), `blocked` (`ticket`, `reason`), `merge` (`ticket`, `commit`, and `source: "reconcile"` when the reconciler found it in git), `closed` (`ticket`), `conflict` (`ticket`, `paths`, `next`), `resolve` (`ticket`, `outcome`, `why?`), `finding` (`from`, `seq`, `target`, `action`), `design-question` (`ticket`), plus `integration`, `orchestrator` and `guardrail-merge` (`wave`, `from`: `main`'s commit brought into the integration branch because a product guardrail changed, `by?`: who answered when the run's base was not in main; `references/guardrails.md`), `guardrail-base-kept` (`wave`, `ref_commit`, `in_force`, `decision`: the Artisan kept the guardrails as of the run's base) for the run's own steps, `halted` (`wave`, `tickets`; `reason: "orchestrator-exit"` when the Artisan answered an orchestrator-exit decision `halt`) and `resumed` (`wave`) for the run as a whole, `orchestrator-exit` (`id`, `attempt`, `wave`, `cause`, `tickets`, `detail`: an orchestrator exited without finishing its wave, #171), and `handoff` (`id`, `attempt`, `wave`, `reason`, `percent`), `handoff-failed` (`id`, `attempt`: the next orchestrator didn't launch, the hand-off record was taken back), `risk-gate` (`ticket`, `percent`) and `risk-gate-cleared` (`ticket`, `by`) for the context drain, and, for worker questions, `asked` (`ticket`, `question`), `answered` (`ticket`, `question`, `next`), `deferred-question`, `pulled` and `provisional-shown`, and, for slice gates, `gate-opened` (`gate`, `issue`, `tickets`, `dependents`), `gate-decision` (`gate`, `card`, `by`, `outcome`, `redirect`, `areas`, `cards?`), `rework` (`ticket`, `from`, `gate`, `card`) and `gate-approved` (`gate`, `issue`, `by`), and, for gate actions and exception gates (`scripts/gate-action.sh`), `gate-opened` with `kind: "exception"` (or `"end"`), the end gate's `end-gate-approved`, `pr-cut` and `run-ended` (`references/end-gate.md`), `gate-redirected`, `gate-bypassed`, `gate-deferred`, `gate-decided` and `gate-resolved` (`gate`, `issue`, `kind`, `choice`, `by`), `gate-empty` (the same, `issue: null`, plus `left_run`, `[{number, status, title}]`, and `why`: a slice gate whose tickets all left the run, closed by `gate.sh sync` with nothing to review, #164), `repaired` (`ticket`, `attempt`, `cost_usd`, `failures_taken_back`: `sweep.sh repair`, #151), `sent-back` (`ticket`, `from`, `by?`: a ticket left the run with its dropped or resliced blocker; `wave.sh status` says `next: stranded`, not `blocked`, when tickets are left waiting on one, `references/gate-actions.md`),  `decided` (`decision`, `kind`, `choice`, `by`) and `parked` (`reason: "reviews"`, `detail`), and, for Human checks (`references/human-checks.md`), `human-check-passed` (`ticket`, `agent_ticket`, `gate`, `by`, `notes?`), `human-check-failed` (the same, `why`, `rework`; with `bug-found` unless the Artisan said it was not a bug, and `rework` with `human_check`) and `human-check-deferred` (the same, `gate: "end"`, `why`) and `human-check-split` (`ticket`: the agent ticket, `attempt`, `criteria`, `human_check`: the Human check they moved to; `verify.sh judge` on a pass, #158), and, for hands-on tickets (`scripts/human.sh`), `human-start` (`ticket`, `worktree`, `base`), `human-done` (`ticket`, `attempt`, `commit`), `human-feedback` (`ticket`, `attempt`: the verifier failed it and it went back to the Artisan) and `parked` (`reason: "human"`, `detail`), and, for cost and usage limits (`scripts/budget.sh`, `references/cost-and-usage.md`), `overrun-gate` (`gate`, `budget`, `spent`, `projected`, `tickets_over`), `overrun-decision` (`gate`, `option`, `choice`, `by`, `action: "defer"`), `parked` (`reason: "usage"`, `window`, `detail`), and for the merge gate on CI (`scripts/merge-gate.sh`, #139) `parked` (`reason: "ci"`, `ticket`, `detail`), `unparked` (`reason: "ci"`, `ticket`, `how: "retry"`, `by`) and `ci-gate-abandoned` (`ticket`, `branch`), and for the detached merge gate (#142) `merge-gate` (`ticket`, `attempt`, `gate`, `mode`, `sha`: a gate started, between `verified` and `merge`), `merge-gate-resumed` (`ticket`, `branch`, `run_id`) and `merge-gate-abandoned` (`ticket`, `branch: null`), and for a merge batch (#167) `merge-batch` (`batch`, `tickets`: the batch asked, recorded before it is built), one `merge-gate` per gate it runs (`batch`, `tickets`: every ticket in the commit it judges, `gate`, `mode`, `sha`; no `ticket`, so it counts against no ticket), `merge-batch-ended` (`batch`, `tickets`, `merged`, `red`, `left_out`, `not_merged`, `gates`), and `batch` and `tickets` added to its `parked`, `unparked`, `merge-gate-resumed` and `*-gate-abandoned`, `resume-asked`, `ceiling-raised` (`key`, `value`, `by`), `unparked` (`reason: "usage"`, `window`, `how`, `by`) and `halted` (`reason: "overrun-stop"` or `"usage-stop"`). One `parked` event serves every park; its `reason` (`human`, `reviews`, `usage` or `ci`) says which. A ticket cut at the overrun gate is `deferred` with `cut: {gate, by, at}` and leaves `plan.scope`. A hands-on ticket carries `human: {worktree, branch, base, focus, started_at, done_at, rounds, feedback}`; each round the Artisan says "done" counts as an attempt, and a ticket with a `human` record is never dispatched or on the frontier. The retro's guardrail health reads `guardrail-fired` (`guardrail`, `area?`, `gate?`, `tickets?`; or from `sweep.sh` on a criterion-2 question finding, `guardrail: "scope-floor"`, `ticket`, `areas`, `question`; or from `verify.sh judge`, `ticket`, `attempt`, `criterion`, `by: "verifier"`), `guardrail-bypassed` (`guardrail`, `area?`, `gate?`, `reason`, `by`), `gate-decision` (its `outcome`, `redirect` and `areas`), `bug-found` (`ticket`, `areas`, `where: "gate"`, `gate`, `by`, `why?`: a bug the Artisan flagged at a review gate), an older run's `shipped-bug` (`area`, `ticket`) and `spot-check` (`ticket`, `card`, `answer`: `same` or `differently`, `area?`, written by `guardrail-health.sh spot-check-record`), as `references/guardrail-health.md` says. A top-level `provisional_shown` lists the tickets whose provisional cards a packet has shown. `seq` counts from 1; `at` is epoch seconds. A state file from before the log has no `events`; the first event starts it. Reading the log is how anyone checks that a ticket went dispatch, result, verify, verified, merge, closed, in that order.

## The sweep

`sweep.sh <run-dir>`, on every wake. The orchestrator wakes at least every ten minutes (`wait-any.sh --timeout 570`, one turn per wait, #175), so a worker past its deadline is stopped within that; the chats sweep at least every `plan.config.sweep_minutes` (default 5 minutes). For each `in_flight` ticket, reading only the current attempt's files (n = `attempts`), first match wins:

1. A result file: recorded. `complete` → `returned`; `blocked` → `blocked`; `failed` → a failed attempt.
2. An exit record and no result file: a failed attempt.
3. Past `deadline_at`: the worker and every process descended from it are stopped (TERM, then KILL after `ARTISAN_STOP_GRACE` seconds, default 5) and it is a failed attempt.
4. The pid is not alive: a failed attempt (a crash that wrote nothing).

A failed attempt appends to `failures` and sends the ticket back to `queued`, or, once `attempts` reaches `attempts_per_ticket`, to `blocked` with an `exception` decision queued for the Artisan. The sweep then logs new complete lines of every findings file and recomputes `costs`.

**Repair (#151).** Plugin 0.4.0 found a session's `result` event by the start of its line, and current `claude -p` writes `"type"` after other keys, so `output.json` came out empty: every finished worker was judged `failed crashed`, its cost was lost, and after two such attempts an exception gate opened. `sweep.sh repair <run-dir>` mends such a run, once, under the lock:

1. For every ended session (an exit record) whose `output.json` holds no `result` event, it rebuilds `output.json` from the saved `stream.jsonl` (the last whole `result` event, found by its parsed type).
2. Every attempt in a ticket's `failures` that now classifies as `completed` with a result file saying `complete` is taken back: its entries move from `failures` to `repaired`, the attempt it used is given back (`extra_attempts` + 1, as a retry grants one, so a real failure afterwards is a retry, not a new exception), its cost goes into `attempt_costs` (the result file's `cost_usd` or `total_cost_usd` first, else the session's, as the sweep reads it), and an event `repaired` (`ticket`, `attempt`, `cost_usd`, `failures_taken_back`) is logged. When it is the ticket's latest attempt and the ticket is `queued`, `blocked` by its failures (no `blocked_reason`) or `deferred` at its exception gate (no `cut`), the ticket is `returned` with its `result`, as the sweep would have left it, and goes on to verify and merge. An `exception` decision the miscount queued that no gate carries yet is decided (`choice: "resolved by repair"`, `by: "sweep.sh repair"`).
3. An ended orchestrator with no `cost_usd` gets its session's cost; then `costs` are recomputed.

An exception gate the miscount already opened is printed with the command that closes it: `gate-action.sh repaired <run-dir> <issue>` (`references/gate-actions.md`). Running the repair again changes nothing.

**Dry-run first (#154).** `sweep.sh repair <run-dir> --dry-run` takes no lock and writes nothing (no `output.json`, no state, no tracker call; it repairs a scratch copy, so a live run's lock doesn't stop it, and copying the run folder yourself carries that lock). Per attempt it prints the ticket, attempt, the rebuilt result status and cost, the failure that moves to `repaired`, the attempt given back, and the `gate-action.sh repaired` line for each exception gate it would make closable, then `dry run: nothing written`. The real repair afterwards prints exactly those lines. Check the dry-run, then repair.

## The reconciler

`reconcile.sh <run-dir>` is the first thing a new orchestrator runs, crashed predecessor or not. Under one lock:

1. **Git.** A ticket whose branch was merged into the integration branch is `merged`, with the merge commit. Merges are `--no-ff`, so the merge commit sits on the integration branch's first-parent line; a ticket branch still on that line (dispatched, nothing merged) does not count. This comes before the sweep, so a worker whose branch was merged before a crash is not counted as a failed attempt.
2. **Sweep.** As above.
3. **Tracker.** For each ticket in scope, `gh api repos/<repo>/issues/<n>` (open or closed, labels) and `gh api repos/<repo>/issues/<n>/dependencies/blocked_by` (native blockers). A failed read exits 1 with git's merges and the sweep kept and the frontier not recomputed. A `queued` ticket the tracker has closed becomes `closed`.
4. **Frontier.** Every `queued` ticket in scope, open on the tracker, not labelled `ready-for-human`, not a Human check (a body marker records `human_check.for`; a Human check in the run is never waited on as a blocker either), whose blockers are all merged into the integration branch (blockers in the run) or closed (blockers outside it, such as a `review-gate` issue), and none of whose blockers is in a slice or risk gate, not containing the ticket itself, that is not yet answered (`gate_holds(blocker; ticket)`: from plan approval, not only once the gate is due; a gate none of whose tickets merged holds nothing, #170). A `queued` ticket held that way through a merged blocker gets `gate_waits`; any other loses it. Printed one per line and stored in `frontier`.

Wave width (Max Agents, the ready tickets, overlapping file sets) is applied to the frontier by `scripts/wave-width.sh pick`, not by the reconciler; see `skills/implement-plan/references/parallel-waves.md`.

## Known limits

- A pid can be reused after its process dies; the sweep and the lock then see a live process. Deadlines bound how long that can mislead the sweep.
- Merged tickets are found by ticket branch. A merged branch that has since been deleted is found only through `merge_commit` already in the state file.
