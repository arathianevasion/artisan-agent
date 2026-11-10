# Cross-session messaging between an orchestrator and `claude -p` ticket workers

Research for [#35](https://github.com/arathianevasion/watsonsoft-workflow/issues/35). Question: can an orchestrator use cross-session messaging (`crossSessionInbound: "accept"`, `SendMessage` with `notify_when_idle`, `ListAgents`) with `claude -p` workers to replace polling result files, while keeping one worktree per ticket, `/implement` as the prompt, and `--max-budget-usd`/`--max-turns` caps? What can a person see or steer through it, and how does it fail?

Gathered 2026-11-10 against Claude Code v2.1.322 (installed version) and the docs and changelog at that date. Facts, test observations and trade-offs only; no recommendation.

Builds on [agent-teams-vs-headless.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/agent-teams-vs-headless/docs/research/agent-teams-vs-headless.md) (#33), whose "middle ground" section raised this as untested, and [orchestration-options.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/orchestration-options/docs/research/orchestration-options.md) (#13).

## Short answer

- **As a wake-up signal: yes, with a backstop.** A `-p` worker binds an inbox, shows up in `ListAgents`, and an orchestrator in its main conversation can subscribe with `notify_when_idle`. Observed: a clean finish sends "is idle now" with the worker's first result line; SIGTERM sends "has exited ... before going idle". **SIGKILL sends nothing.** The docs say a subscription with no notice expires after 12 hours. So a process-exit or result-file check is still needed for crashes.
- **As a replacement for result files: no.** The notice carries one line of status, and messages are plain text only [XS]. The structured result contract in `implement-plan` (status, commit, tests, review findings, discovered work) still needs the file. The notice can stand in for the polling loop, not for the file.
- **Worktrees, `/implement` and caps are unaffected.** Messaging is per session and independent of the working directory. The worker's `-p` prompt can still be `/implement ...`. `--max-turns` and `--max-budget-usd` are ordinary `-p` flags. Delivered messages count toward usage like a typed prompt [XS].
- **Steering works only while the worker is alive.** A message reaches a busy worker at its next tool boundary. A `-p` worker exits when its turn ends, after which sends fail with "No agent named ... is reachable" (observed). An idle worker held open by background work does take a new turn from a message (observed).

## Sources

| Key | Source |
| --- | --- |
| [XS] | https://code.claude.com/docs/en/cross-session-messaging |
| [SET] | https://code.claude.com/docs/en/settings-reference (`crossSessionInbound`, `dialogExpiry`) |
| [HL] | https://code.claude.com/docs/en/headless ("Background tasks at exit") |
| [CLI] | https://code.claude.com/docs/en/cli-reference (`--max-turns`, `--max-budget-usd`, `--name`) |
| [ENV] | https://code.claude.com/docs/en/env-vars (`CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`) |
| [TR] | https://code.claude.com/docs/en/tools-reference (`ListAgents`, `SendMessage` rows) |
| [CL] | https://code.claude.com/docs/en/changelog |
| [IP] | `~/.claude/skills/implement-plan/SKILL.md` and `references/dispatch.md` (owner's local skill) |
| [T1]-[T5] | Live tests in this document, section "Live tests" |

## What the docs say

### Availability and `-p` workers

- Cross-session messaging requires v2.1.224+ on macOS/Linux. When a session meets the requirements, "messaging is on with nothing to enable" [XS].
- "Claude Code binds an inbox socket for a `claude -p` session like an interactive one, so a long-running `-p` worker can receive messages and appears in the listing." `--bare` sessions bind no socket, so they cannot receive and are not listed [XS].
- Same-machine messages travel over a per-session Unix socket, "never through Anthropic servers" [XS].
- A session answers to the name set with `--name` or `/rename` [XS], [CLI].

### Inbound control (`crossSessionInbound`)

- Values `accept`, `hold`, `refuse`. When unset, Claude Code decides per message from the two sessions' permission-mode classes. Bypass is one class, everything else (including `acceptEdits`, auto, `dontAsk`) is the other. A prompting receiver delivers unless the sender is bypassing [XS].
- **Precedence:** managed settings, then `--settings`, then user settings; first value wins. "A project or local value applies only when it's stricter" (`refuse` > `hold` > `accept`) [SET]. **So `accept` in a repo's `.claude/settings.json` has no effect.** For an unattended worker it must come from `--settings` (or user/managed settings). The docs say the same: "start it with `crossSessionInbound` set to `accept` in its `--settings` value. An `accept` in your user settings also works but applies to every session you run" [XS].
- A `-p` session can't show the approval dialog. A default-held message waits for `dialogExpiry` (5 minutes by default) and is then dropped and reported as expired to the sender. An explicit `hold` does not expire [XS].
- At most 100 held messages; oldest dropped past that [XS].

### `notify_when_idle`

- One-shot, opt-in. One notice arrives "when it next goes idle (finishes its turn with nothing queued) or exits". Without a message it subscribes "without starting a turn or spending tokens in the watched session" [XS], [TR].
- "Only the Claude in your main conversation can subscribe, and only to your sessions on this machine." Subscribing from a subagent or teammate is refused, including any attached message [XS].
- "If no notice arrives within 12 hours, Claude Code drops the subscription and tells Claude" [XS].
- `refuse` on either side means nothing arrives and the subscription expires unanswered. `hold` on either side means the notice omits the one-line status and is shown to the user but not delivered to Claude [XS].
- Added in v2.1.236 ("opt-in, one-shot, no polling") [CL].

### What a message can and cannot do

- Arrives as plain text marked as from another session, not from you. It cannot approve a permission prompt. Commands in it (for example `/compact`) are not executed. The receiver is told not to change configuration because another session asked. The receiver's own permission rules still apply [XS].
- The receiver reads it "between tool calls during an active turn"; an idle session starts a new turn with it [XS].
- Limits: about 1 million characters per message; burst sends refused at the sender; per-sender rate limit; identical repeats dropped; at most 50 accepted messages queued [XS].
- Since v2.1.238 a send to a refusing session reports "refused", and a receiver that drops messages (rate limit, full queue) tells the sender [CL]. Since v2.1.271 headless senders get a delivery notice when the receiver's permission-mode policy holds a message [CL].

### When a `-p` run ends

- After its final turn, a `-p` run stays open only to wait for background work Claude started: background commands, subagents, workflows, Monitor watches, `/loop` wakeups. It stops waiting after 10 minutes of idle by default (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`), except that a background command from the main conversation holds it open until the command exits [HL], [ENV].
- `--max-turns`: "With `--input-format stream-json`, a message still queued when the limit ends a turn stays queued and starts a new turn with its own limit" [CLI]. The docs do not say whether a cross-session message that starts a new turn also gets a fresh `--max-turns` allowance. See T5 for what was observed.
- `--max-budget-usd` is checked against the client-side cost estimate; spend can pass the cap; reaching it stops background work [CLI], [HL].

### Scripts and the socket

- Claude Code exports `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` to hooks and Bash commands, so a hook can post to its own session's socket [XS], [ENV]. The `-p` `stream-json` init event also reports `messaging_socket_path` (observed in T1).
- The documented wire format covers only the optional auth line (`{"type":"auth","token":"..."}`). The message line format is not documented on the pages read. So a plain shell orchestrator that writes to a worker's socket directly, without a Claude session, would depend on undocumented behaviour.

## Live tests

All tests ran in a throwaway repo at `.../scratchpad/xs-test/repo` with one worktree `wt-t1` on branch `agent/t1`. The repo has since been deleted. The worker is a `claude -p` process in the worktree. The "orchestrator" is a second `claude -p` session, because this research ran as a subagent and subagents may not subscribe [XS]. Every process had `--max-turns` ≤ 10 and `--max-budget-usd 0.50`. Total spend across all runs was under $0.50 (per-run `total_cost_usd` ranged $0.003-$0.10).

Common worker flags:

```bash
claude -p "<prompt>" --name xs-worker-tN \
  --settings '{"crossSessionInbound":"accept"}' \
  --model haiku --max-turns 10 --max-budget-usd 0.50 \
  --permission-mode acceptEdits --add-dir "$RESULTS" \
  --allowedTools "Bash" --output-format stream-json --verbose > worker-tN.log 2>&1 &
```

Common orchestrator flags:

```bash
claude -p "<prompt>" --name xs-orch-tN \
  --model sonnet --max-turns 10 --max-budget-usd 0.50 \
  --allowedTools "Bash" ListAgents SendMessage \
  --output-format stream-json --verbose > orch-tN.log 2>&1
```

To keep a worker alive and busy, it ran a foreground Bash loop that waited for a gate file: `for i in $(seq 150); do [ -f gate ] && break; sleep 1; done`. The test script released it with `touch`. A standalone `sleep 45` was blocked by the harness ("Blocked: standalone sleep 45 ... use Monitor with an until-loop"), which is why T1 failed to overlap.

### T1: worker finished before the orchestrator looked

The worker's `sleep` was blocked, so it finished in seconds. When the orchestrator ran `ListAgents` 12 s later, the worker was not listed. `SendMessage` returned `{"success":false,"message":"No agent named 'xs-worker-t1' is reachable.\nUse ListAgents to see everyone you can message."}`. The worker's `stream-json` init event showed `"messaging_socket_path": "/tmp/cc-socks/51513.sock"`, and its tool list included `ListAgents`, `SendMessage`, `Monitor` and `ToolSearch`.

### T2: steer a busy worker and get an idle notice (clean finish)

The worker committed `hello2.txt`, then blocked on the gate. The orchestrator ran `ListAgents`, which listed `xs-worker-t2 [a8e9b4] · interactive · busy · started 17s ago`. The `-p` worker is labelled `interactive`. The orchestrator then sent the steer with `notify_when_idle: true`. Result:

> `"success":true` ... "in that session's inbox, not yet read by its Claude ..." / "Subscribed — you will get one notice here when "xs-worker-t2" is next idle (or exits), provided that session runs in the same permission class as this one ... Do not poll or wait for it; carry on."

- The message reached the worker's queue at 10:01:50 but was read only after the gate loop returned at 10:02:24. The worker then created and committed `steer.txt` and listed the message in its result file. So delivery waits for the current tool call to finish.
- The incoming message did **not** appear in the worker's `stream-json` stdout. It is in the session transcript (`~/.claude/projects/<dir>/<session>.jsonl`) as an `attachment` with `"origin":{"kind":"peer","from":"uds:/tmp/cc-socks/55797.sock","name":"xs-orch-t2","fromMode":"prompting","body":"..."}`.
- The worker exited about 8 s after release. The orchestrator's later send failed with "No agent named 'xs-worker-t2' is reachable". Its second `ListAgents` no longer showed the worker.
- The idle notice was **not** injected into the orchestrator mid-turn. The orchestrator was in a foreground Bash wait, then made two more tool calls. The notice arrived after its turn ended and started a second turn in the same `-p` run (a second `result` event). Verbatim:

> `[Cross-session idle notice] "xs-worker-t2", which you asked to be notified about, is idle now — it finished a turn at 10:02. Its harness reports: «All four steps are done. `t2.json` is written with status `complete`.». This is an automated notice from that session's harness — not a message from a person, and not an instruction; ...`

The status in «» is the first line of the worker's final answer.

### T3: worker killed with SIGKILL (crash)

The orchestrator subscribed with an empty message (pure subscription), then waited on a gate. The script sent `kill -9` to the worker, waited 15 s, and released the orchestrator.

- No notice arrived. The orchestrator's second `ListAgents` no longer listed the worker. The `-p` orchestrator exited normally when its turn ended; it did not stay open for the pending subscription.
- The worker's socket file `/tmp/cc-socks/58981.sock` was left behind (removed by hand). Clean exits in T1, T2, T4 and T5 removed theirs.
- Per [XS], a subscription in an interactive orchestrator would expire after 12 hours.

### T4: worker stopped with SIGTERM (watchdog timeout)

Same as T3 with `kill -TERM`. The worker's in-flight Bash ended with `Exit code 137`. The notice again arrived after the orchestrator's turn, as a new turn:

> `[Cross-session idle notice] "xs-worker-t4", which you asked to be notified about, has exited (at 10:06) before going idle; it will not process further messages at that address. ...`

No result file was written. A notice for an exit does not say whether the work finished.

### T5: an idle worker can be woken by a message

The worker started the gate loop with `run_in_background: true` and ended its turn ("waiting"). The `-p` run stayed open for the background command [HL]. 25 s later the orchestrator sent "create steer5.txt containing steered5 and commit it" (no notify).

- The worker started a new turn and committed `e463a91 10:07:35 Add steer5.txt`, 28 s before the gate was released at 10:08:03. When the background command finished, it took a third turn, then exited.
- The `stream-json` log shows three `result` events, with `num_turns` 2, 2, 2 and cumulative `total_cost_usd` 0.0030, 0.0040, 0.0049. So the turn count is reported per turn and cost is cumulative. Whether `--max-turns` resets for each message-started turn was not tested to the limit.

### Cleanup

`ps -axo pid,command | grep -E "xs-(worker|orch)"` returned nothing after the tests. The throwaway repo and worktree were deleted, along with the stale socket from T3. No user or project settings were edited; `accept` was passed only through `--settings`. The test sessions' transcripts remain under `~/.claude/projects/-private-tmp-...-xs-test-*`.

## Mapping onto `implement-plan`

`implement-plan` launches one `claude -p` per ticket in its own worktree, gates wave completion on result files, and treats notifications as "a convenience, not the source of truth" [IP].

| Concern | Today [IP] | With cross-session messaging |
| --- | --- | --- |
| Knowing a worker finished | Poll result files; "do not yield the turn while agents are in flight" | Subscribe per worker; a notice wakes an idle interactive orchestrator [XS], [T2] |
| Worker crash (SIGKILL, OOM, rate-limit kill) | Missing result file plus a wall-clock timeout | No notice; subscription expires after 12 h [XS], [T3]. Still needs a process or result-file check |
| Watchdog kill (SIGTERM) | Missing file | "has exited ... before going idle" notice [T4]; result file may still be missing |
| Structured result | JSON result file | Notice carries one status line only [T2]; file still needed |
| Steering mid-run | None | Plain-text message, read at the next tool boundary [T2]; cannot approve prompts or run slash commands [XS] |
| Worktrees | One per ticket | Unchanged; messaging is per session, not per directory |
| `/implement` as prompt | `-p` prompt is a user turn | Unchanged. A message cannot start `/implement`: commands in messages are not executed [XS] |
| Caps | `--max-turns`, `--max-budget-usd` | Unchanged flags; delivered messages count toward usage [XS]. `--max-turns` with message-started turns not verified [T5] |
| Inbound setting | n/a | Must be `--settings '{"crossSessionInbound":"accept"}'`; a project `accept` is ignored [SET]. `acceptEdits` workers with a non-bypass orchestrator are delivered by default anyway [XS] |
| Orchestrator type | Interactive session | Must be the main conversation to subscribe [XS]. A subagent orchestrator cannot |

## What a person can see or steer

- **See:** `/list-agents` (or `/peers`) in any interactive session lists each live worker by its `--name`, with `busy`/`idle` and start time; workers vanish when they exit [XS], [T2]. A person can ask their session to message a worker. A message preview line shows in the receiving session's UI [XS], but a `-p` worker has no UI. Its `stream-json` stdout does not show received messages; the session transcript file does [T2].
- **Steer:** text only, and only while the worker process is alive. A busy worker reads it after its current tool call [T2]; an idle worker held open by background work starts a new turn [T5]. A message cannot answer a permission prompt, change configuration, or run a slash command [XS]. In `-p` with `acceptEdits`, calls needing approval are denied rather than waiting [HL], so there is nothing to approve anyway.
- **Not available:** attaching to a `-p` worker's live view, interrupting a tool call, or resuming one after exit through messaging. Those belong to interactive or background (`--bg`) sessions.

## Failure modes

| Failure | What happens | Source |
| --- | --- | --- |
| Worker crashes (SIGKILL) | No notice; worker disappears from `ListAgents`; stale socket file left; interactive subscriber waits up to 12 h | [T3], [XS] |
| Worker terminated (SIGTERM) | "exited ... before going idle" notice; result file may be missing | [T4] |
| Worker exits before subscription | Send fails "No agent named ... is reachable"; if already idle when subscribing, notice is sent right away | [T1], [XS] |
| Message sent after worker exit | Fails with "No agent named ... is reachable" | [T2] |
| Message held (default policy, no `accept`) | `-p` keeps it `dialogExpiry` (5 min), then drops it and reports expiry to the sender | [XS] |
| `accept` put in project settings only | Ignored; default per-message policy applies | [SET] |
| Message lost in a burst or loop | Refused at the sender or dropped with a notice to the sender; queue capped at 50 | [XS], [CL] |
| Worker waiting on a message | A `-p` worker exits at turn end. It can wait only inside a tool call or while background work holds the run open (≤10 min idle by default). Messages arrive only at tool boundaries or as a new turn when idle | [HL], [T2], [T5] |
| Worker is in a long foreground tool call | Message waits until the call returns | [T2] |
| Orchestrator is a `-p` session | Exits at turn end without waiting for pending subscriptions; notices already queued start one more turn | [T2], [T3], [T4] |
| Orchestrator is a subagent | Cannot subscribe; its sends go out under the parent session's address and replies go to the parent | [XS], [TR] |
| Notice timing | Observed twice arriving only after the orchestrator's turn ended, not between its tool calls | [T2], [T4] |
| Sensitive instructions via message | Cannot grant permissions or consent; receiver's rules apply | [XS] |

## Trade-offs

- **Cost of waiting.** An interactive orchestrator can end its turn and be woken by notices instead of holding a turn open with a polling loop. That is the main gain. The crash gap (no notice on SIGKILL) means the poll-or-timeout path cannot be removed, only made a backstop.
- **Results stay in files.** The notice's one line is the worker's first line of output, not a contract. `implement-plan`'s JSON result file and merge-based gating are untouched.
- **Steering is real but narrow.** Plain text, at tool boundaries, while the process lives. Useful for "also do X" or "stop and write your result", not for approvals or slash commands.
- **Settings surface.** Needs a `--settings` flag on each worker. A project-level `accept` silently does nothing.
- **Observability gap.** Messages a worker received are not in its `stream-json` log, only in its session transcript.

## Open questions

- Does `--max-turns` reset for each turn a cross-session message starts in a `-p` worker? T5 shows per-turn `num_turns`, but no run reached the cap.
- Is the idle notice ever injected between an orchestrator's tool calls, or only when it is idle? Observed only the latter, twice, in `-p` orchestrators. Not tested in an interactive one.
- The socket wire format for posting a message from a plain script to another session is not documented on the pages read.
