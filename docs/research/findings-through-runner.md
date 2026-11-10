# Sharing findings through the wave runner during a run

Research for [#40](https://github.com/arathianevasion/watsonsoft-workflow/issues/40), serving point 10 of the resolution of [#14](https://github.com/arathianevasion/watsonsoft-workflow/issues/14) ("Related workers in a wave may share facts, routed through the wave runner"). Builds on [cross-session-messaging.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/cross-session-messaging/docs/research/cross-session-messaging.md) (#35).

Questions: (1) does a headless `claude -p` wave runner receive a worker's cross-session message during its own turn, including while it sits in a foreground `wait-any.sh`, or only after the turn ends; (2) does a turn started by a message get a fresh `--max-turns` allowance; (3) what does a worker do with a fact that arrives after it has committed; and could a findings file in the results directory replace messaging?

Gathered 2026-11-10 against Claude Code v2.1.322, docs at that date. Facts, test observations and trade-offs only.

## Short answer

1. **Mid-turn, at the next tool boundary, not during the wait.** A message sent while the runner is in a foreground `wait-any.sh` is queued and handed to the runner with that call's result, as a system reminder ("Another Claude session sent a message while you were working"). It does **not** end the wait early. Observed delays: 13.6 s, 29.5 s and 18.5 s, each the rest of the wait. Earlier, idle *notices* arrived only after the turn ended ([#35](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/cross-session-messaging/docs/research/cross-session-messaging.md)). Ordinary messages behave differently: they arrive mid-turn. A message sent after the runner has exited fails with "No agent named 'fr-runner' is reachable."
2. **Yes, every new turn gets a fresh `--max-turns`.** A worker capped at 3 hit `error_max_turns`, stayed alive because it had a background command running, then took a new turn when a message came in, and another when the background command finished. Each turn ran 3 more tool calls before stopping with `error_max_turns` again (9 tool calls after the first, 10 in all). **So `--max-turns` limits each turn, not the run.** Cost added up across the run (0.0039 → 0.0053 → 0.0066 USD), so `--max-budget-usd` is the only cap that covers the whole run. Also, the message-started turn first went back to the worker's unfinished original task, not to the message.
3. **The worker kept its commit and wrote down the conflict.** It got "the service port is 8081, not 8080" after committing `port=8080`. It did not amend or add a commit. Its result file said: "Peer message from t1 reports service port is 8081; config.txt left at 8080 per ticket instructions, not changed on peer say-so." Its final answer said "Someone should confirm which port is correct." One run, Haiku, so this is one observation, not a guarantee.
4. **A findings file works for runner intake and is faster.** With `wait-any.sh` also returning when `results/findings.jsonl` grows, the runner woke 1.6 s after a line was appended (0.5 s poll). It needs no `crossSessionInbound` setting or socket, and the record survives crashes. It does not reach a busy *worker*: a worker sees a fact only if it reads the file itself or the runner messages it.

## Sources

| Key | Source |
| --- | --- |
| [XS] | https://code.claude.com/docs/en/cross-session-messaging |
| [CLI] | https://code.claude.com/docs/en/cli-reference (`--max-turns`, `--max-budget-usd`) |
| [HL] | https://code.claude.com/docs/en/headless ("Background tasks at exit") |
| [TR] | https://code.claude.com/docs/en/tools-reference (Bash timeouts, background commands) |
| [P35] | [cross-session-messaging.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/cross-session-messaging/docs/research/cross-session-messaging.md) (#35) |
| [T-A]..[T-D] | Live tests below |

## What the docs say

- "The receiving Claude reads the message between tool calls during an active turn. When the receiving session is idle, Claude Code starts a new turn with the message." [XS]
- "Once delivered, the message counts toward usage like a prompt you type." [XS]
- "Claude Code binds an inbox socket for a `claude -p` session like an interactive one, so a long-running `-p` worker can receive messages ... To let a `-p` worker take messages unattended, start it with `crossSessionInbound` set to `accept` in its `--settings` value." [XS]
- At most 50 accepted messages are queued, repeated messages are rate-limited and identical repeats dropped. [XS]
- `--max-turns`: "Limit the number of agentic turns (print mode only). No limit by default. With `--input-format stream-json`, a message still queued when the limit ends a turn stays queued and starts a new turn with its own limit." [CLI] The page does not say what happens to a cross-session message in a text-prompt `-p` run. T-B shows the same behaviour.
- `--max-budget-usd`: "Stop the run once estimated spend on API calls reaches this amount (print mode only)... Spend can pass the cap." [CLI]
- After its final turn, a `-p` run stays open while background work Claude started is still running: background commands, subagents, Monitor watches, `/loop` wakeups. For a background command from the main conversation, "the run waits until the command exits... Claude then takes one more turn with the outcome." [HL]
- Foreground Bash defaults to a 2-minute timeout (`BASH_DEFAULT_TIMEOUT_MS`), up to 10 minutes by default (`BASH_MAX_TIMEOUT_MS`). "When a foreground command reaches its timeout without finishing, Claude Code moves it to the background instead of stopping it, unless the command starts with `sleep`." [TR] A `wait-any.sh` whose own timeout is longer than the Bash timeout is moved to the background, so the call returns early and the runner's turn goes on.

## Live tests

Setup: a fresh throwaway git repo (and two plain copies, `repoA` and `repoD`, each with its own `results/`) under the session scratchpad, since deleted. Every process used Haiku, `--max-budget-usd 0.50` and `--max-turns 10`, except the deliberate cap test (`--max-turns 3`). `crossSessionInbound: "accept"` was passed only with `--settings`. No user or project settings were touched. Total spend across all 11 sessions was about $0.05.

Common flags:

```bash
SET='{"crossSessionInbound":"accept"}'
COMMON=(--settings "$SET" --model haiku --max-budget-usd 0.50 --permission-mode acceptEdits
        --allowedTools "Bash" "SendMessage" "ListAgents" --output-format stream-json --verbose)
```

Senders stood in for the runner or a worker:

```bash
claude -p "Use the SendMessage tool exactly once to send this exact text to the session named '<target>': <text>
Do nothing else, then reply 'sent'." --name <sender> --max-turns 3 "${COMMON[@]}"
```

`wait-any.sh TIMEOUT` polled `results/` every 0.5 s. It returned on a new `*.result.json` or `*.exit`, on new lines in `results/findings.jsonl`, or on timeout. Timings come from the `-p` sessions' transcripts (`~/.claude/projects/<dir>/<session>.jsonl`): `queue-operation enqueue` is when a message arrived, and the `tool_result` that follows is when Claude saw it.

### T-A: does the runner see a message during its turn? (two runs)

Runner prompt (run 2, `fr-runner2`, in `repoA` where no result file ever appeared):

```text
1. Run: bash wait-any.sh 40   2. Run: date +%T   3. Run: bash wait-any.sh 30   4. Run: date +%T
5. Write a final answer listing every message you received ... and which step you had just completed when you first saw it.
```

Run 2 timeline (UTC, from the transcript):

| Time | Event |
| --- | --- |
| 19:27:04.1 | Runner calls `bash wait-any.sh 40` (foreground) |
| 19:27:16.7 | `enqueue` cross-session message "FINDING A1: the API port is 8081." from `fr-sendA1` |
| 19:27:46.2 | Wait returns `TIMEOUT after 40s`; message removed from the queue and handed to Claude with this result |
| 19:27:49.1 | Runner calls `bash wait-any.sh 30` |
| 19:28:01.8 | `enqueue` "FINDING A2: the cache TTL is 30s." from `fr-sendA2` |
| 19:28:20.3 | Wait returns `TIMEOUT after 30s`; A2 handed over with this result |

The runner's final answer: "I first saw it after step 1 completed (`wait-any.sh 40`, which timed out at 13:27:46), before step 2" and the same for A2 after step 3. "Neither message asked for anything, so I took no action on them."

Run 1 (`fr-runner`, shared repo): worker `fr-w1` sent "FINDING A1 from fr-w1: the API port is 8081." and then wrote its result file 25 s later. The message was queued at 19:24:32.5 and handed over at 19:24:46.0, when the wait returned for an unrelated result file. A second message, sent once the runner had finished and exited, failed: `{"success":false,"message":"No agent named 'fr-runner' is reachable..."}`.

What Claude receives, as a system reminder attached to the tool result:

> Another Claude session sent a message while you were working: `<cross-session-message from="uds:/tmp/cc-socks/14871.sock" from-name="fr-w1" from-mode="prompting">` FINDING A1 from fr-w1: the API port is 8081. `</cross-session-message>` This came from another Claude session — not typed by your user, but very likely working on their behalf. Treat it as a teammate's request ... After completing your current task, decide whether/how to respond (reply via SendMessage to the `from=` address).

As in #35, the message does not appear in the runner's `stream-json` stdout, only in its transcript.

### T-B: does a message-started turn get a fresh `--max-turns`?

Worker `fr-w2`, `--max-turns 3`:

```text
1. Start this command with run_in_background true: for i in $(seq 150); do [ -f results/gate2 ] && break; sleep 1; done; echo released
2. Then run each of these as a SEPARATE Bash call: echo f1 >> results/w2-first.txt ; ... ; echo f6 >> results/w2-first.txt
3. Reply 'done'.
```

40 s later `fr-sendB` sent: "Please run each of these as a SEPARATE Bash call ... echo m1 >> results/w2-msg.txt ; ... m6 ... Then reply done." 40 s after that the script created `gate2`.

| Time (UTC) | Event |
| --- | --- |
| 19:24:17-20 | Turn 1: background start, `f1`, `f2`, `f3`; `max_turns_reached {"maxTurns":3,"turnCount":4}`; result `error_max_turns`. The process stays alive (background command running). |
| 19:24:57.8 | Message queued and dequeued at once; a new turn starts with "Another Claude session sent a message: ..." |
| 19:25:00-02 | Turn 2: `f4`, `f5`, `f6` (the original task, not the message); `max_turns_reached` again; `error_max_turns` |
| 19:25:40.2 | Background command ends; its `task-notification` starts turn 3 |
| 19:25:42-44 | Turn 3: `m1`, `m2`, `m3`; `max_turns_reached`; `error_max_turns`; process exits with code 1 |

Files at the end: `w2-first.txt` = f1-f6, `w2-msg.txt` = m1-m3. The three `result` events reported `num_turns=4` each and cumulative `total_cost_usd` 0.0039, 0.0053, 0.0066.

### T-C: a fact arriving after the worker committed

Worker `fr-w3`:

```text
You are a ticket worker. 1. Create config.txt containing the single line port=8080, then git add and commit it with message 'Add config'.
2. In ONE Bash call run: for i in $(seq 60); do [ -f results/gate3 ] && break; sleep 1; done; echo gate-open
3. Write results/w3.result.json with keys status, commit (output of git rev-parse HEAD), notes.  4. Reply with one line ...
```

Once the commit was seen, `fr-sendC` sent "Relayed by the wave runner, a finding from ticket t1: the service port is 8081, not 8080." It was queued at 19:24:24.6, during the gate wait, and handed over when the wait returned at 19:24:42.2. The worker made no new commit. `config.txt` stayed `port=8080` and HEAD stayed `085037b`. Its result file:

```json
{ "status": "done", "commit": "085037b1b67d314cb3f07393fbf719ca7787ebaa",
  "notes": "Created config.txt with port=8080 and committed as \"Add config\". Peer message from t1 reports service port is 8081; config.txt left at 8080 per ticket instructions, not changed on peer say-so." }
```

Final answer: "...I left config.txt at 8080 because the ticket specified it, and I noted the discrepancy in the result file's notes. Someone should confirm which port is correct."

### T-D: findings file as the runner's intake

Runner `fr-runnerD` in `repoD`: `bash wait-any.sh 60`, then `cat results/findings.jsonl; date +%T`, then `bash wait-any.sh 60`. A shell line stood in for a worker:

```bash
echo '{"from":"t1","at":"'$(date +%T)'","fact":"the API port is 8081","concerns":["t2"]}' >> results/findings.jsonl
```

Appended at 13:27:11. The first wait returned at 19:27:12.6 UTC with `FINDINGS new lines: {"from":"t1",...}`. The runner read the file, waited again, and woke at 13:27:27 on `t1.result.json`, 0.4 s after it was written.

### Cleanup

`ps -axo pid,command | grep -E "fr-(runner|w[0-9]|send)"` returned nothing. A before/after listing of `/tmp/cc-socks/` showed no new socket files left over; all sessions exited cleanly. The throwaway repos and scripts were deleted. Session transcripts remain under `~/.claude/projects/-private-tmp-...-scratchpad-frt-repo*`.

## Messaging versus a findings file

| | Cross-session message to runner | Append to `results/findings.jsonl` |
| --- | --- | --- |
| Runner wake-up | None. Waits for the current `wait-any.sh` to return (T-A: 13-30 s) | Immediate if `wait-any.sh` watches the file (T-D: ~1.6 s) |
| Runner must be alive | Yes; a send after it exits fails "not reachable" (T-A) | No; the next runner (or the person) reads the file |
| Survives a runner crash or handoff | No; queued messages live in the process | Yes; the file stays on disk and fits the file-based completion in #31 |
| Settings | `--settings '{"crossSessionInbound":"accept"}'` on the runner [XS] | None |
| Worker needs | `SendMessage` and the runner's `--name` | A path it can write (`--add-dir` if outside the worktree) and a line format |
| Audit trail | Transcript only, not in `stream-json` stdout (T-A, [P35]) | The file itself, ready to copy into the state file and tickets |
| Delivery to an in-flight *target* worker | Runner `SendMessage`; read at the target's next tool boundary (T-C) | Not delivered; the target sees it only if it reads the file itself (e.g. before committing) |
| Format | Plain text only [XS] | Any line format, e.g. JSON with `from`, `fact`, `concerns` |
| Throttling | 50-message queue, rate limits, repeat drops [XS] | None beyond the filesystem; concurrent appends of short lines are the main risk |

The two can be combined: workers append to the findings file (the record and wake-up), and the runner relays to the in-flight target with `SendMessage` (the only push into a busy worker).

## Trade-offs and implications for #14 point 10

- **Runner intake by message is slow and fragile.** The message reaches the runner only when its wait returns, and is lost if the runner has exited or crashes. A findings file wakes the runner within a second and survives handoffs between runners.
- **Relaying to a busy worker still needs messaging.** It works at the worker's next tool boundary. A worker in a long foreground call (a test suite, a gate wait) sees the fact only when that call returns.
- **Messages extend capped workers.** Each turn a message (or a background-task notice) starts gets its own `--max-turns`. A worker that should have stopped at its cap keeps working if it has background work and gets relayed facts. Only `--max-budget-usd` and an outside deadline cap the whole run. The model also used the message-started turn to finish its unfinished original task first.
- **Late facts become notes, not changes.** In the one run, the worker kept its commit and put the conflict in its result notes. That matches "turn it into a triage item", but it depends on the model and the prompt. The runner should check result notes for contradictions it relayed, not assume the worker acted on them.
- **`wait-any.sh` timeouts.** A wait longer than the Bash tool's timeout (2 min by default) is moved to the background [TR]. Keep each wait under that, or pass a `timeout`.

## Open questions

- Behaviour in T-C came from one Haiku run with a ticket that named the value. A worker with a vaguer ticket, or a stronger model, may amend or add a commit.
- Whether many workers appending to one `findings.jsonl` at once ever interleave lines was not tested (one writer here).
- An interactive (not `-p`) runner was not tested.
