# Gate actions, exception gates and parking

How the Artisan answers a **gate** (GLOSSARY.md), what each answer leaves behind on the tracker and in the run, the **exception gate** a run raises when it gives up on a ticket, and **parking** when everything left waits behind open reviews. Built in #70; slice gates and their packet are `references/review-gates.md` (#65). `${CLAUDE_PLUGIN_ROOT}/scripts/gate-action.sh` does the work; `state.sh decide` marks any waiting decision decided. Tested in `tests/gate-actions.test.sh`, end to end with the fake `claude` and the fake `gh`.

Skills cite this file rather than copying it.

## Answering a review gate

Answering needs only the choice. Why, guardrail level, reach and confidence are optional, as in `references/decision-record.md`; `--by` defaults to `Artisan`. Each call is from either chat, on the Artisan's word, with the gate's `review-gate` issue number.

| The Artisan says | Call | The gate's issue | The dependents | Recorded |
|---|---|---|---|---|
| approve (keep all) | `gate-action.sh approve <run> <issue> [--why W] [--confidence firm\|provisional] [--level L --reach R [--area A]]` (calls `gate.sh approve`) | closed, the decisions posted | dispatch in the next wave | every card kept; the gate's job-13 decision with the optional fields |
| redirect: send it back with notes | `gate-action.sh redirect <run> <issue> --notes "…"` | closed, as `redirected` | wait for the rework ticket (a native blocker) | a rework ticket in this run, labelled `ready-for-agent` and `in-run`, its first criterion the notes; decision `redirect: notes` |
| redirect: I'll do it myself | `gate-action.sh redirect <run> <issue> --mine [--notes "…"]` | closed, as `redirected` | wait for the rework ticket | the rework ticket labelled `ready-for-human`: held for the Artisan (`skills/implement-plan/references/hands-on.md`), never dispatched; decision `redirect: self` |
| bypass | `gate-action.sh bypass <run> <issue> [--why W]` | closed unreviewed, a comment naming who | dispatch in the next wave | `bypass: {by, why, at}` on the gate; no card is kept or changed |
| defer | `gate-action.sh defer <run> <issue> [--why W]` | **stays open** until the end gate | dispatch now: the gate's native edge to them is removed | `deferral: {by, why, at, released}`; listed by `gate-action.sh deferred` |

A card can still be changed or made a guardrail one at a time with `gate.sh change` and `gate.sh guardrail` (`references/review-gates.md`).

**A redirect's rework ticket is a ticket of its own.** It joins `plan.scope` with its own `tickets` entry (attempts 0), the first gate ticket's model, caps and estimate, and `rework_of`. Its attempts never count against the original's, and the original's never against it. It is not a new scope decision: the gate's answer is the approval, as with `gate.sh change`. Its cost counts against the approved budget; raising the budget is the overrun gate's (#72).

**On the work ticket or on a rework ticket?** A slice gate's tickets are already merged and closed, so "ready-for-human on the work ticket" lands on the rework ticket that carries the work back: the original's evidence and merge stay as they were. At an exception gate the work ticket is still open, and "take it myself" labels it directly (below).

**A deferred gate at the end gate.** The issue stays open with its packet. `gate-action.sh deferred <run>` lists every deferred gate for the end gate (#71). There the Artisan answers it as any open gate: `gate.sh approve`, or `gate.sh change` on a card, which turns that finding into a rework ticket (it doesn't hold the dependents, which already ran).

## Exception gates

An exception gate covers what has no ticket to triage. It opens for every `exception` decision the run queues for a ticket still `blocked`:

| Why | The gate's title | `reason` |
|---|---|---|
| the ticket failed its attempts (the sweep, `verify.sh judge` or `wave.sh merge` counted the last) | `Exception gate: run <id> gave up on #<t> after <n> attempts` | `gave-up` |
| the suite went red after merging it (a check that won't go green) | `Exception gate: #<t>'s check won't go green (run <id>)` | `red-check` |
| anything else that blocked it (an unresolved conflict, a result describing another commit, a diff missing its expected output) | `Exception gate: #<t> is blocked (run <id>)` | `blocked` |

The overrun gate, the third kind of exception, is #72's.

`gate-action.sh sync`, run by `wave.sh status` before `gate.sh sync`, opens it: a `review-gate` issue (no per-kind label) with the ticket, why it stopped, its attempts, the suite log for a red check, its cost and the six choices; a native blocker of the in-run tickets the ticket blocks; recorded in `exception_gates` and on its `exception` decision (`issue`, `gate`). A repeat opens nothing new.

**Exception gates can't be removed.** They are never in `plan.gates`, so no gate placement touches them, and `sync` opens one whatever the plan says.

**An exception gate holds only its dependents.** The rest of the run carries on: `wave.sh status` doesn't count an exception decision with its gate as a reason to stop (`next: launch` while the frontier has work).

### The Artisan's call

| The Artisan says | Call | The ticket | Its dependents | The gate |
|---|---|---|---|---|
| retry with notes | `gate-action.sh retry <run> <issue> --notes "…"` | `queued`, with one more attempt (`extra_attempts`) and the notes in `notes`; the next `wave.sh dispatch` is a fresh worker on the same branch whose prompt carries the notes and the failure evidence | wait for it to merge | closed |
| reslice | `gate-action.sh reslice <run> <issue>` | out of the run as `resliced`, labelled `needs-triage`, `in-run` removed; its replacements join a run through their own plan step | **leave with it** (see below) | closed |
| take it myself | `gate-action.sh take <run> <issue>` | `queued` and labelled `ready-for-human`: the Artisan builds it in their own worktree (`human.sh`; the last worker's clean worktree is removed to free the branch), then the same verifier, suite and merge | wait for it to merge | closed |
| drop | `gate-action.sh drop <run> <issue>` | out of the run as `dropped`, `in-run` removed, left open, no new label | **leave with it** (see below) | closed |
| bypass | `gate-action.sh bypass <run> <issue>` | out of the run as `bypassed`, `in-run` removed | **go ahead**: its native edges to them are removed (kept in `bypass.released`) | closed, who recorded |
| defer | `gate-action.sh defer <run> <issue>` | `deferred`, still in the run's record | **go ahead** now, as for bypass | open until the end gate |

**An exception gate the stream-json miscount opened (#151)** is not the Artisan's call: the ticket's attempts completed, but plugin 0.4.0 couldn't read their result. First run `sweep.sh repair <run>` (`references/state-file.md`): it returns the ticket with its cost and prints each such gate. Then close each with `gate-action.sh repaired <run> <issue>` (`--by`, `--why`): the gate closes as `resolved`, its record under `resolution`, its decision decided as "resolved by repair" and the event `gate-resolved`. It is not a bypass: no `gate-bypassed` or `guardrail-bypassed`, the ticket stays in the run and keeps its own edges, and only the gate's issue stops blocking the dependents. It is refused (6) unless the repair returned the ticket. Don't close such a gate by hand on the tracker: `sync` would record that as a bypass.

An exception gate is never approved or redirected (6): its redirects are "retry with notes" and "take it myself". A gate closed by hand on the tracker is bypassed by "Artisan (closed on the tracker)" at the next `sync`. A ticket that fails again after a retry raises a new exception gate.

Each of these decides the gate's `exception` decision as job 15 ("Decide what happens after a run gives up") with `choice`, `by`, `why`, and `redirect` (`notes` for retry, `self` for take). Show `gate-action.sh chat <run>` as printed, then your recommendation, following `ARTISAN.md`.

## Parking behind reviews

The run **parks** when every ticket left (not merged, closed, or taken out of the run) waits behind an open review, and nothing else can move: nothing in flight or returned, an empty frontier, and no waiting decision that isn't a gate. A ticket waits behind a review when it is the ticket of an open exception gate, or a tracker blocker of it is an open gate's issue, a ticket with a waiting risk gate, a ticket in a slice whose gate is due, or a ticket that itself waits behind a review.

`wave.sh status` then says `next: parked` and the line `gate-action.sh parked` prints:

```
parked: waiting on 2 reviews: Slice gate: greeting (run r1) #5, Exception gate: run r1 gave up on #3 after 2 attempts #6; 3 tickets wait behind them: #2, #3, #4
```

followed by the decisions waiting. A `parked` event (`reason: "reviews"`, `detail`) is logged once per distinct line. Nothing launches until the Artisan answers one of the gates; the next `wave.sh status` carries on. Parking behind a hands-on ticket is `human.sh parked` (`skills/implement-plan/references/hands-on.md`).

A deferred gate never parks the run: its dependents already went ahead.

## Dependents leave with a dropped or resliced ticket

Everything in scope still to run (`queued` or `blocked`) that depends on the ticket, directly or through others (the tracker's native edges), leaves the run with it. The reply opens with `Impact: …` before anything changes: who goes, and which slices can no longer be reviewed end to end. The exception gate's table row for drop and reslice lists the same tickets (`downstream` on the gate). Then each dependent is labelled `needs-triage`, loses `in-run`, gets a comment naming the run and the ticket and saying it needs grilling again, keeps its native blockers, and becomes `sent_back` (`sent_back: {from, at}`, a `sent-back` event, and `outcome.sent_back` on the gate). They come back through triage and their own plan step; they are not re-added to this run. Bypass is unchanged: its dependents go ahead.

**Stranded.** A state written before this (or an edge case) can leave dropped or resliced tickets with dependents still `queued` behind them. `wave.sh status` then says `next: stranded` instead of `blocked`, with one line per blocker (`#12 dropped: #14, #15 can't start`) and the command: `gate-action.sh send-back <run>` (no gate needed; `--by`, `--why`), which does to the stranded tickets what the drop does to dependents. `gate-action.sh stranded <run>` prints the lines (exit 0) or exits 1 when none. A stranded ticket is never finished, so the run is never `done` while one remains.

## Done, with tickets out of the run

`wave.sh status` says `done` when every ticket in scope is merged, closed, or out of the run (`dropped`, `resliced`, `bypassed`, `deferred` at a gate, or `sent_back` with its blocker: `out_of_run` in `scripts/lib/state-lib.sh`). The run summary puts those first, and the end gate lists the deferred gates.

## Kept for the retro

Every answer stays on its gate in the state file: `review_gates[]` and `exception_gates[]` carry `status`, the record under `bypass`, `deferral`, `redirect`, `outcome` or `resolution` (`{by, at, why?, notes?, released?, mode?, ticket?}`), and `answered`, every action in order. The gate's decision is decided as a decision record, and the event log has `gate-bypassed`, `gate-deferred`, `gate-redirected`, `gate-decided` or `gate-resolved` (`gate`, `issue`, `kind`, `choice`, `by`), plus `decided` for any `state.sh decide`. The retro reads bypasses and deferrals, with their reasons, from these (`skills/retro/PREPARE.md`).

**For guardrail health** (`references/guardrail-health.md`), in the same write: bypassing a gate a guardrail opened (its `guardrails`: an area's risk gate, or an exception gate whose exception decision named a guardrail, such as the scope floor's `scope-floor`) logs `guardrail-bypassed` per guardrail (`guardrail`, `area?`, `gate`, `reason`: the `--why`, `by`); a gate no guardrail opened logs nothing extra. A redirect logs `gate-decision` (`card: null`, `outcome: "change"`, `redirect: true`, `areas`: every area of the gate's tickets). `redirect`, `retry` and `take` take `--bug` when the Artisan found a bug in the gate's tickets: `bug-found` (`ticket`, `areas`, `where: "gate"`, `gate`, `by`), one per ticket.

## `state.sh decide`

The general way any waiting decision is answered:

```
state.sh decide <run-dir> <decision-id> <choice> [--by NAME] [--job N] [--why W]
  [--level team|product|individual] [--reach ticket|area|everywhere] [--area A]
  [--confidence firm|provisional] [--redirect self|notes]
```

It merges the decision record into the decision (`status: decided`, `decided_at`), logs `decided` (`decision`, `kind`, `choice`, `by`), and refuses (6) a decision that is not waiting. A reach of `area` needs `--area`. The gate actions above decide their gate's decision the same way, in the same write as the rest of the action.

## Lock

Every gate action takes the state lock before it touches the tracker. While a wave's orchestrator holds it, the action is refused (3) and nothing changes: answer again once `wave.sh status` says the wave has ended. (`gate.sh approve`, `change` and `guardrail` keep an answer given then and fold it in later.)
