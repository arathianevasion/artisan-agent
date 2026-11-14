# Two chats through the tracker

The **Engineering chat** drives runs. The **Product chat** runs triage and holds requirements discussion and writing. They share nothing but the tracker: a direct message is only a **doorbell** naming an issue, and never carries content. `${CLAUDE_PLUGIN_ROOT}/scripts/chats.sh` does the work; `tests/chats.test.sh` and `tests/gate.test.sh` test it against the fake `gh`. Skills cite this file rather than copying it.

## Who writes what

| Thing | Written by | The other chat may |
|---|---|---|
| Incoming tickets: triage labels, outcomes, `ready-for-agent` | Product | read; Engineering files findings as new tickets |
| `plan` issues: their tickets | Product | read |
| `plan` issues: the plan step | Engineering | read and approve |
| Runs: state files, integration branches, merges | Engineering (via orchestrators) | read the digest |
| `review-gate` issues | Engineering (via orchestrators) | read and act on |

Either chat can approve a plan or act on a gate. The Product chat never reads a run's state file: what it needs from a run is on the tracker.

## In-run tickets

| Step | Who | Call |
|---|---|---|
| Mark every ticket in the approved scope `in-run`, with one comment naming the run (`<!-- artisan-agent:run <id> -->`) | Engineering chat, right after `state.sh init` | `chats.sh label-run --repo R <run folder>` (once; repeating changes nothing) |
| Before triaging, editing or relabelling any ticket | Product chat | `chats.sh guard --repo R <issue>`: exit 6 and a line naming the run if the ticket is `in-run`. Refuse, say so in one line, and offer a comment or a new ticket instead |

A ticket leaves the run by its own rules (`deferred`, closed); the label is not the Product chat's to remove.

## Sending work to Engineering

"Send #345 and #346 to engineering" in the Product chat: `chats.sh send --repo R 345 346`. It creates a `plan` issue (title `Plan: send #345, #346 to engineering`) with those tickets as sub-issues and nothing else: no models, estimate or gates, because the plan step is Engineering's. It refuses (6) a ticket that is `in-run`, closed or missing, and reuses the open plan with the same title. Tell the Artisan the plan's number and ring the doorbell if the Engineering chat is awake ("plan #347 waits for you").

## The sweep

Each chat runs `chats.sh sweep --repo R --chat engineering|product` on every wake and at least every `sweep_minutes` (default 5; `chats.sh due` says when). It is a few `gh` queries and local files, never a transcript. A chat with no wake of its own sets a recurring wake-up for `sweep_minutes` when it starts. A wake that came from the clock, not the Artisan typing, passes `--idle`.

It prints, in order:

| Section | Both chats | Content |
|---|---|---|
| Review gates | yes | open `review-gate` issues from the tracker, batched by job and role (`--role` keeps one role's, for a pair) |
| Gates closed on GitHub | yes | the one-line announcement below, once per chat |
| Changes | yes | a changed guardrail source (team, product or individual) or a newly installed plugin version, as "applies from the next wave". The first sweep records the baseline and announces nothing |
| Plans waiting for Engineering | Engineering | `plan` issues not yet in a run, oldest first |
| Decisions waiting | Engineering | the waiting decisions in a run's state file |

Then `ACTION` lines for the chat to act on (`gates`, `announce-changes`, `start-plan <issue> approve-envelope|envelope-approved`), and, with `--idle`, a `notify: <text>` line when a decision waits that no earlier sweep notified (a gate, a plan needing its envelope approved, a run's decision). An orchestrator that exited without finishing its wave (an `orchestrator-exit` decision, #171) is notified at once, `--idle` or not, the text naming its cause and tickets. Send the text with the PushNotification tool. The sweep remembers what it has notified in `.artisan-agent/runs/.chat/<chat>.json` (git-ignored, each chat's own) and forgets it once the decision is answered.

## Plans queued behind the run lock

A run request that arrives while a run holds the lock waits as a `plan` issue (`guard/queue-plan.sh`, or the Product chat's `send`). When the lock frees, **the first sweep** of the Engineering chat names the oldest plan that is startable (not blocked by an open plan, with a ticket not yet in a run) and prints `ACTION start-plan`; younger plans show "queued behind #N". The chat starts the plan step for it (`${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/SKILL.md`, step 3; `resolve-scope.sh` reads the plan back) and puts **the run envelope** (waves, models, estimates, budget) in front of the Artisan to approve, as a table. Only one plan starts per lock.

A queued plan skips that approval only if its envelope was approved before it was queued: the chat that got the approval records it with `chats.sh approve-envelope --repo R <plan issue>` (a comment, `<!-- artisan-agent:envelope-approved -->`); the sweep then prints `envelope-approved` and the chat goes straight to starting the run. A plan from the Product chat, or a plan left by the run-lock hook, never has it.

## A plan approved in the other chat

Plan approval is on the tracker, so either chat can give it, and the other honours it. The chat that approves a plan's envelope records `approve-envelope`; the Engineering chat's sweep treats that as given. It never asks the Artisan the same question twice.

## Gates closed by hand

A gate (`review-gate` issue) the Artisan closes on GitHub is approved at the next `gate.sh sync` (the Engineering chat's sweep calls it for each run with an open gate), by "Artisan (closed on the tracker)", every undecided card kept. The sync records which cards were undecided (`review_gates[].closed_on_tracker`, `carried`; event `gate-approved` carries both) and comments once on the issue:

```
Gate #41 closed on GitHub: treated as approved; 3 undecided cards carried to the end gate
```

Either chat's sweep announces that line from the tracker, once. `gate.sh carried <run folder>` is the table of those cards, which **the end gate lists** for the Artisan to decide.

## The gate listing

`gate.sh list [<run folder>]` and the sweep's gate section both read open `review-gate` issues from the tracker (`chats.sh gates`), replacing #65's listing from one run's state file, so it works for both chats and several runs. A gate's role is read from its packet's header table; its job is 13 for a slice gate and `unassigned` for a kind that doesn't name one.
