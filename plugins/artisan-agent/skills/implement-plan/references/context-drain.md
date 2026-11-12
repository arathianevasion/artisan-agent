# Context drain, hand-offs and resume

The Artisan experiences one continuous chat, and no session in a run ever stops to compact. Each tier watches its own context and hands off before it fills: an orchestrator to a fresh orchestrator for the same wave, the Engineering chat by Claude Code compacting it out of sight at 40%. Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/drain.sh`, `run-digest.sh` and `compact-hook.sh`; their usage is in `${CLAUDE_PLUGIN_ROOT}/scripts/README.md`, "Context drain and resume".

## The bands

The table is the orchestrator's (the Engineering chat has its own rule, below). An orchestrator's outstanding agents are its workers and its verifiers not yet judged.

| Context | Band | Does |
|---|---|---|
| under 30% | `normal` | as usual |
| 30% up to 50% | `drain` | dispatch nothing new, keep processing results, hand off once idle; never with agents outstanding |
| 50% and over | `review` | as `drain`, and every merge processed at this level gets a risk gate blocking only its dependents |

The thresholds are the run's `context.drain_percent` and `context.review_percent` (`.artisan-agent/config.yml`, overridable for one run at the plan step). Changing them for good is job 23.

`drain.sh check` prints one line, `<band> <percent>% <action>[ risk-gate]`:

| Action | Do |
|---|---|
| `dispatch` | carry on as usual |
| `process` | dispatch nothing new (no new ticket, no retry; for the chat, no new wave), keep processing what comes back |
| `handoff` | hand off now (below) |

`risk-gate` means a merge you process now gets a risk gate. Only an orchestrator merges, so for the chat it asks nothing more than its band does.

## Reading the context percentage

A headless session can't read its own context percentage from Claude Code (only the interactive status line is given it). So `drain.sh` uses the fallback: the session's transcript, its last main-thread record with usage (input, cache creation, cache read and output tokens), against the model's window. The window is 200,000 tokens, or 1,000,000 for a model id ending `[1m]` or once the context is past 200,000 (it can only be the larger one); `ARTISAN_CONTEXT_WINDOW` overrides it.

Each session learns its transcript from the plugin's `SessionStart` hook: an orchestrator's is written to `workers/<id>.<n>/transcript.path` in the run folder, and a chat is told its own in one line at start-up, after compaction and on `/resume` ("this chat's transcript is …"). With no transcript (a session run with `--no-session-persistence`) the reading is `unknown`, treated as `normal`; the `PreCompact` marker is then the only backstop.

## The orchestrator

After every event (a dispatch, a sweep that recorded something, a verdict, a merge), run `$S/drain.sh check $RUN` and act on its action:

- **`dispatch`:** as usual.
- **`process`:** no `wave.sh dispatch`, retries included; carry on waiting, sweeping, verifying, merging and closing. A failed attempt waits for the next orchestrator.
- **`handoff` (the `drain` or `review` band, nothing outstanding):** run `$S/drain.sh handoff $RUN`. It records why, launches the next orchestrator for the same wave (`wave.sh launch --handoff`, which takes the state lock over), writes the hand-off report to your result file and prints `handed-off …`. Then end your reply with the completion line and exit: no more writes, the lock is no longer yours. If it prints `none`, nothing in scope is left to do: write the wave report and exit as usual.
- **`handoff` in the `compact` band:** the `PreCompact` hook blocked a compaction and left the hand-off marker. Finish the step you are on (never half a merge), then `drain.sh handoff` as above, even with workers in flight: they are detached and the next orchestrator picks them up from the state file.
- **`risk-gate`:** after each merge you process in that band (`wave.sh merge` exit 0, or `resolved` 0), run `$S/drain.sh gate $RUN <ticket> <percent>` before `wave.sh close`. Its dependents don't dispatch until the Artisan clears it (`wave.sh dispatch` exit 5, and the reconciler leaves them off the frontier); nothing else waits.

**The marker.** The plugin's `PreCompact` hook (`compact-hook.sh pre-compact`) writes `workers/<id>.<n>/handoff.json` in an orchestrator's session and blocks the compaction. Claude Code's built-in autocompact, at about 70%, is the last resort: when it fires, the hook still writes the marker and blocks it. The orchestrator checks for the marker after each event, through `drain.sh check`.

**The next orchestrator** starts like any orchestrator for that wave: its prompt says the earlier one handed off and why, it reconciles, and it carries the same wave on from the state file, waiting on the workers already in flight rather than dispatching them again. The wave's guardrail commits are not read again: its workers were given that version.

## The Engineering chat

The chat never asks the Artisan to compact, and it has no `handoff` of its own: Claude Code compacts it on its own, out of sight. It checks with `drain.sh chat <run folder> --transcript <its transcript>` before it launches a wave, whenever it is woken, and before it sends a message. The output is `<state> <percent>%`:

| State | The chat does |
|---|---|
| `ok` | at or below `chat_context.warn_percent` (30): says nothing about context |
| `warn` | above it: ends the message with one line that needs no action, such as "Context at 34%. It will compact out of sight at 40%." (the numbers are the config's) |
| `warn ask` | past `chat_context.compact_percent` + 15 (55) with no compaction having fired: the warning, and once, in one line, "Type `/compact` and I'll carry on exactly where we are; nothing is lost." Printed once per climb; a reading back under the line (a compaction) arms it again |
| `unknown -` | no transcript or usage yet: says nothing |

It launches waves whatever the percentage: the chat's band never holds a wave back. (`drain.sh decide|check --tier chat` remain for the orchestrator's use of the shared table and are not the chat's rule.)

**Automatic compaction at 40%.** Project setup writes `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (Claude Code 2.1.322) into the project settings `env`, from `chat_context.compact_percent` (default 40), never over a value the project already set. The `env` block applies to every session in the project, orchestrators and workers included. An orchestrator's rules are unchanged: its `PreCompact` hook still blocks the compaction and leaves the marker, now often earlier, and it hands off as above.

**The window is not forced.** `CLAUDE_CODE_AUTO_COMPACT_WINDOW` would reach every session, including workers on smaller-window models, for which 40% of a forced 1M could pass their real window. The chat's expected window is the config's `chat_context.window_tokens` (1,000,000, Opus), which `drain.sh chat` reads its percentage against (`ARTISAN_CONTEXT_WINDOW` overrides). Force the window only if a live check shows Claude Code detecting the chat's wrongly, and then find a way to apply it to the chat alone.

**Compaction out of sight.** The chat's `PreCompact` hook steers the summary: it keeps the run, what the Artisan said about it in this chat and the step in progress, and leaves out tables and script output. The `SessionStart` hook with source `compact` then puts the run digest back into context. The Artisan does nothing; whether Claude Code compacts at 40% or they typed the fallback `/compact`, the chat carries on.

## Opening a session with a run open

`run-digest.sh` is the run digest: where the run is (its wave, the orchestrator's state, merged tickets, cost against the budget, a halt), a ticket table, the decisions waiting for the Artisan, and what changed since the chat last looked (the events since the last digest it showed). It only reads the state file.

| A new session reaches it through | How |
|---|---|
| `/artisan-agent:implement-plan` | it checks for an open run first and opens with the digest |
| `/artisan-agent:craft` | its open-run check hands over to `implement-plan` |
| Claude Code's `/resume` | the `SessionStart` hook (source `resume`) puts the digest into context |
| compaction | the `SessionStart` hook (source `compact`), as above |

At start-up the hook only says the run is open in one line; `implement-plan` shows the digest.
