# Live proof: context drain, hand-off and resume (#59)

Not part of `tests/run.sh`: these runs use real `claude -p` sessions under the normal login, with this plugin loaded by `--plugin-dir` for that session only. Nothing installs, enables or writes any setting, and nothing reaches GitHub (the fake tracker, or a `gh` that always fails).

## The hand-off: `live.sh <workdir>`

A real orchestrator, with fake workers and verifiers (`tests/fixtures/fake-claude`), gets the hand-off marker while its worker is in flight. It sees the marker at its next `drain.sh check`, hands off, and a fresh real orchestrator finishes the same wave from the state file. The script's header says why the marker comes from running the plugin's `PreCompact` hook rather than from a compaction on cue.

Last result, 2026-11-11, Claude Code 2.1.322, `claude-sonnet-5-5` orchestrators: all 11 checks ok. Events `integration orchestrator dispatch result verify handoff orchestrator verified merge closed`; the hand-off was `{"reason":"compaction blocked: hand-off marker","percent":17}`. The first orchestrator handed off after starting the verifier, and the second judged, merged and closed the ticket. Cost: $0.134 and $0.138. The first orchestrator ended without its completion line (`not-completed`), which is harmless: it is no longer the run's last orchestrator.

## One-off checks, same day

Each was run by hand in a throwaway repo with an open run `r1`, the plugin loaded by `--plugin-dir`, and the session capped at $0.50.

| Check | Command | Seen |
|---|---|---|
| A headless session reads its own context percentage (pilot prerequisite 6) | an orchestrator-role `claude -p` running `drain.sh percent --transcript "$(cat workers/orchestrator-w1.1/transcript.path)"` | `13 26377 200000`; its `SessionStart` hook had written the transcript path |
| An orchestrator's `PreCompact` blocks compaction and leaves the marker (prerequisite 1) | `claude -p "/compact" --resume <that session>` with the orchestrator's environment | result `Compaction blocked by PreCompact hook: … Artisan Agent: an orchestrator never compacts …`, 0 turns; `handoff.json` written with `trigger: "manual"` |
| After the chat compacts, the run digest is back | a chat session (`Reply OK`), then `claude -p "/compact" --resume <it>`, then `--resume` asking without tools what run is open | the transcript has `SessionStart:compact` with `## Run r1 is open` after the compact boundary; the model answered "Run r1 is open with 2 tickets (#1 Add hello, #2 Add goodbye), and nothing is waiting for you." |
| `/resume` | `claude -p --resume <id>` | `SessionStart:resume` fired, with the digest |
| `/artisan-agent:implement-plan` in a new session, the lock held by a live pid | `claude -p "/artisan-agent:implement-plan"` | passed the run-lock hook (before the fix, a bare call was refused and queued as a plan issue) and opened with the run, its ticket table and $0 of $5 |
| `/artisan-agent:craft` | `claude -p "/artisan-agent:craft where are we with the open run?"` | opened with the digest as printed: `## Run r1 is open`, the table, "Nothing is waiting for you, and nothing has changed since you last looked." |

## What these runs found

- With `--setting-sources project,local`, Claude Code loads a `--plugin-dir` plugin's skills but never runs its hooks. `tests/live-run/live.sh` used that flag; since #105 every live harness gets its hooks from `tests/helpers/live-hooks.sh` (a `--settings` file) and fails if no hook fired.
- `claude -p` didn't autocompact even with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set (context at 14 to 18%, threshold set lower). So whether a headless orchestrator's automatic compaction fires the hook (the "autocompact at 70%" backstop) is a hand check for #78. Every compaction runs the same `PreCompact` hook path, and the manual one is proven above.
