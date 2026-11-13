# Review gates: the slice gate and its packet

A **gate** is a point where the Artisan reviews work before what depends on it continues (GLOSSARY.md). This page covers the **slice gate**, the first of the four kinds (slice, risk, exception, end), built in #65. A gate is never triggered by context size, time or ticket count: a slice gate opens when, and only when, every ticket of a slice in the approved plan has merged. `${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh` does the work; `scripts/lib/packet.py` renders the packet. Tested in `tests/gate.test.sh`.

Skills cite this file rather than copying it.

A **risk gate** placed on a ticket (an escalation test, or a worker's new-seam card) is opened, held and answered exactly as a slice gate of that one ticket, with kind `risk` and its own title; placement, risk gates and the end gate are `references/end-gate.md` (#71).

## Slices in the plan

The plan's `gates` lists the slice gates the Artisan approved. A slice gate names its tickets one of three ways:

| Entry | Tickets |
|---|---|
| `{"kind": "slice", "slice": "export", "tickets": ["12", "13"]}` | the ones listed |
| `{"kind": "slice", "slice": "export"}` | every plan ticket whose `slice` is `export` (the `slice` the to-plan graph gives each ticket) |
| `{"kind": "slice", "after": "12"}` | that ticket alone |

Optional: `problem` and `solution` (one line each, for the packet's summary; without them the packet names the slice's tickets and their expected outputs) and `role` (default `Engineering (QA)`: job 13, "Check a finished slice at a review gate"). Gates are numbered by their place in `gates`: the first is `slice-1`. The plan's `checks`, `[{command, covers, proven_to_fail}]`, records the checks the plan step proved capable of failing; the packet shows them.

## The flow

| Step | Who | Call | Effect |
|---|---|---|---|
| The slice's last ticket closes | orchestrator | `wave.sh close` (calls `gate.sh sync`) | the gate opens before anything else dispatches |
| Open | `gate.sh open <run> <gate-id>` | | builds the packet, opens a GitHub issue labelled `review-gate` (no per-kind label; the kind is in the title, `Slice gate: <slice> (run <id>)`), makes it a native blocker (`dependencies/blocked_by`) of every in-run ticket still to merge that a slice ticket blocks, records the gate, queues a `review-gate` decision; event `gate-opened` |
| Between opening and approval | reconciler, `wave.sh dispatch` | | the dependents are off the frontier and refused (5); every other ticket carries on. The native edge does this on the tracker; `gate_holds` in `lib/state-lib.sh` does it from the state file too, so a gate that is due but not yet open (a crash between the merge and the issue) holds the same tickets |
| Report | Engineering chat | `wave.sh status` (calls `gate.sh sync`) | `next: launch` while the frontier has work (a waiting `review-gate` decision doesn't stop the run, like a risk gate); `next: parked` ("waiting on N reviews", `references/gate-actions.md`) once only gated work is left |
| Show | Engineering chat | `gate.sh chat <run>` | the compressed packet (below) |
| Answer | Engineering chat, on the Artisan's word | `gate.sh approve`, `change`, `guardrail` | below |
| Release | next `wave.sh status` | | the closed issue no longer blocks; the dependents are on the frontier for the next wave |

The issue is the durable record: its body is the packet, and every decision made at the gate is posted on it before it closes. A gate the Artisan closes by hand on GitHub is approved at the next `sync`, recorded as by "Artisan (closed on the tracker)", every undecided card kept.

## The packet (variant B)

The issue body, top to bottom:

1. **Header.** The title with the gate kind; a table of the kind, the role needed, the slice's tickets and the tickets blocked.
2. **Summary line.** Counts of decisions (low confidence counted) and uncertainties, then one line each: **Problem**, **Solution**, **Verification** (criteria verified, how many proven by a test or check and how many need the Artisan, whether the suite passed after every merge).
3. **Decision cards**, one per decision a worker of the slice made alone (`tickets.<t>.evidence.decisions`, the cards of `references/evidence-record.md`): question, choice, alternative considered, confidence (`provisional` is low, shown in bold), kind (product taste, engineering taste or engineering), who made it under which job, and the actions keep, change, make it a guardrail (level and reach). Under them, provisional cards from other merged tickets no gate has shown yet (`questions.sh provisional`, `references/worker-questions.md`); every ticket whose cards the packet shows is added to `provisional_shown`.
4. **Uncertainties**: what each worker and verifier was unsure of.

**Low confidence is `provisional`.** The decision record keeps two confidences, `firm` and `provisional`; there is no third value. A card is low confidence, and highlighted, when it is `provisional` (or gives none). What a worker was unsure of without deciding anything stays in its evidence record's `unsure` list and is read into the Uncertainties section, not onto a card (#48's question, settled here).
5. **Evidence by criterion**: each criterion `proven` (met, with a test or check) or **needs you** (unmet, or met on judgement alone); the guardrails applied with their versions and the wave's plugin version (`guardrails.sh table`); the checks proven to fail; cost against estimate per ticket and for the slice; each merge with the command that opens its diff. Verification is behaviour, not a line-by-line review: per-diff checks stay with the verifiers.
6. **Overall action**: what each answer does.

The packet is built once and kept (`gates/<gate-id>.md`, with the view it was built from), so opening again, after a crash, opens nothing new.

## The chat's compressed view

`gate.sh chat <run> [<issue>]`, for every open gate:

```
Slice gate: export (run r1) #41: 3 decisions (1 low confidence), 2 uncertainties. Blocks #14 (billing tab).

| Card | Ticket | Decision | Confidence |
|---|---|---|---|
| 1 | #12 | Where should CSV export be tested? → to_csv() | **provisional (low)** |

Keep all, or name one to change.
```

## Answers

Answering needs only the choice. Why, confidence, guardrail level, reach and redirect are optional, as in `references/decision-record.md`.

| The Artisan says | Call | Effect |
|---|---|---|
| keep all | `gate.sh approve <run> <issue> [--by NAME] [--why W] [--confidence firm\|provisional]` | every card not yet decided is kept; the decisions are posted on the issue as a table and as JSON; the issue closes; the `review-gate` decision is decided; event `gate-approved`. The dependents dispatch in the next wave |
| change card N to X | `gate.sh change <run> <issue> N "X" [--why W]` | a rework ticket (`Rework #<t>: <question>`, labelled `ready-for-agent` and `in-run`, its criterion the new choice) joins the run: in scope, `queued`, the original's model, caps and estimate. Its cost counts against the approved budget, which the change doesn't raise (raising it is the overrun gate's, #72). A repeat after a crash reuses the open rework ticket rather than opening a second. It natively blocks the slice's dependents too, so they wait for the rework as well as the gate. It is a ticket of its own, so it never counts against the original's attempts. Event `rework`. The gate stays open; approving keeps the other cards |
| make card N a guardrail | `gate.sh guardrail <run> <issue> N <team\|product\|individual> <ticket\|area\|everywhere> [--area A]` | the card is kept with `guardrail_level` and `reach`, and a `guardrail` lesson is noted for the retro, where `guardrails.sh tighten` writes it (job 21) |

A card is decided once: a second answer on it is refused (6). Redirect, bypass and defer, the optional fields on approve, and answering a deferred gate at the end gate: `references/gate-actions.md` (`gate-action.sh`).

**Every decision recorded at a gate keeps its job and who made it.** A card's decision is the decision record with the card's own `job` (the job it would have been had a person made it), `choice`, `by` (the Artisan), and `card`, `ticket`, `gate`, `outcome` (`keep` or `change`) and `original` (`{choice, by}`: the worker's choice and the worker). The gate's own decision is job 13, `approve the slice`.

**Answers while a wave runs.** The orchestrator holds the state lock for its wave, so an answer given then goes on the tracker at once (the issue closes, the rework ticket opens) and waits as a file in `gates/pending/`; the next `gate.sh sync` (the orchestrator's next close, or the chat's next status) folds it into the state file. A pending answer already counts: the same card can't be answered twice.

## State

`review_gates`: `[{id, kind, slice, title, role, issue, tickets, dependents: [{number, title}], cards, status: open|approved|redirected|bypassed|deferred, opened_at, approved_at?, decisions, reworks: [{card, ticket}]}]` (the last three statuses, and the records they carry: `references/gate-actions.md`). A `review-gate` entry in `decisions` (`gate`, `issue`). `plan.checks`. `lessons` entries of kind `guardrail`. Events `gate-opened`, `gate-decision`, `rework`, `gate-approved`. Details in `references/state-file.md`.
