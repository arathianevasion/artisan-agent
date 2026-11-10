# Measuring orchestrator context and resuming from saved state

Research for [#12](https://github.com/arathianevasion/watsonsoft-workflow/issues/12), part of map #1.

**Question.** What does Claude Code support today for (a) measuring an orchestrator session's context-window usage programmatically, and (b) handing off to a fresh orchestrator session from saved state, so that no person has to run compaction by hand?

**Checked against:** Claude Code docs at code.claude.com, fetched 2026-11-10. The newest changelog entry was v2.1.322 (November 10, 2026), and the installed CLI reported `2.1.322 (Claude Code)`. Every fact below links to the page it came from. Anything not stated in those pages is marked **unverified**.

## Short answer

- **Measuring is solved, through three official channels.** They are the status line's `context_window` JSON, the Agent SDK's `getContextUsage()` (or sending `/context` as a prompt), and the `usage` / `modelUsage` blocks in `claude -p --output-format json|stream-json`. Hooks do **not** receive context usage, with one exception: `SessionStart` on resume or fork.
- **The owner's `context-gauge.sh` works, but it parses a format the docs call internal.** It reads the transcript JSONL, which the docs say "changes between versions". It also adds output tokens, which `used_percentage` leaves out.
- **No built-in "hand off to a fresh session" command exists.** I found none in the commands reference. The pieces to build one do exist: `claude -p --resume/--session-id`, `SessionStart` hooks that inject `additionalContext`, `PreCompact`, which can block or steer compaction, and `PostCompact`, which receives the summary.
- **Recommended shape:** an external driver script, not the orchestrator itself, decides when to hand off. The orchestrator writes its state to files at each wave boundary. The driver starts a fresh `claude -p` session that reads that state. Auto-compaction stays on as a backstop.

## Where the owner's setup is today

What I read locally:

- `~/.claude/skills/implement-plan/SKILL.md`, line 162: "Do not compact between waves. Results are files; the orchestrator's working state should be small enough that it never needs to." Line 126 says the run is unattended once approved, and line 130 says "Do not yield the turn while agents are in flight."
- `~/.claude/scripts/context-gauge.sh` finds `~/.claude/projects/*/<session-id>.jsonl`, using `$CLAUDE_CODE_SESSION_ID`. It walks the file backwards to the newest non-sidechain assistant `message.usage`, and reports `input + cache_creation + cache_read + output` against a window that defaults to 1,000,000. It reports 0 if a `compact_boundary` comes first.
- `~/.claude/settings.json` sets `"autoCompactEnabled": true` and no `autoCompactWindow`. So the backstop is the model's default auto-compaction, which fires at about 967K tokens on a native-1M model ([model-config: default thresholds](https://code.claude.com/docs/en/model-config#default-auto-compact-thresholds)). Its `statusLine` runs `~/.config/cmux/cockpit/usage-capture.py`, which saves only `rate_limits` and drops `context_window`.
- There is also a file named `~/.claude/setting.local.json`, missing the "s". The docs name the local file `settings.local.json`, so this file is probably never loaded. That is **unverified**; I did not test it.

## (a) Measuring context usage

### 1. Status line JSON (interactive sessions)

The status line command gets session JSON on stdin ([statusline](https://code.claude.com/docs/en/statusline)). These are the fields that matter:

| Field | Meaning (from the docs) |
| - | - |
| `context_window.used_percentage` / `remaining_percentage` | "Pre-calculated percentage of context window used". "calculated from input tokens only: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. It does not include `output_tokens`." |
| `context_window.context_window_size` | "200000 by default, or 1000000 for models with extended context" |
| `context_window.total_input_tokens`, `total_output_tokens` | "Token counts currently in the context window, from the most recent API response" |
| `context_window.current_usage` | Per-category counts from the last API call. "`null` before the first API call in a session, and again immediately after `/compact` until the next API call repopulates it" |
| `session_id`, `transcript_path` | Session identifier and transcript path |

**When it runs.** The script runs at session start or resume, on each new assistant message, after `/compact`, and on a `refreshInterval` timer if one is set. Updates are debounced at 300ms ([statusline: when it updates](https://code.claude.com/docs/en/statusline#when-the-status-line-updates)). The docs warn that "event-driven triggers can go quiet when the main session is idle, for example while a coordinator waits on background subagents". `refreshInterval` fixes that.

**Caveat.** When `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is set, "`used_percentage` measures against the model's full context window, so while the variable is set, that percentage doesn't indicate when compaction will run" ([model-config: set the auto-compact window](https://code.claude.com/docs/en/model-config#set-the-auto-compact-window)).

The status line differs from `/context`: "The status line reports the counts from the last API response, while `/context` adds an estimate for messages added since that response" ([statusline](https://code.claude.com/docs/en/statusline)).

The status line is display-only. To use it as a gauge, the script has to write the number somewhere the orchestrator or a driver can read, for example a file keyed by `session_id`. The docs do not describe this pattern, but nothing in them forbids it.

### 2. Agent SDK and `claude -p`

- **`getContextUsage()`** on the SDK `Query` object returns `totalTokens`, `maxTokens`, and `percentage`, with a per-category breakdown. "`maxTokens` is the window that usage is measured against. That window is the model's context window, or the lower auto-compaction window when one applies." `{ detail: 'summary' }` answers from the last response's usage without sending extra token-count requests ([agent-sdk/typescript: SDKControlGetContextUsageResponse](https://code.claude.com/docs/en/agent-sdk/typescript#sdkcontrolgetcontextusageresponse)). Unlike `used_percentage`, this measures against the **compaction** window.
- **Sending `/context` as a prompt** in an SDK or stream session makes Claude Code attach a structured `context_usage` payload to the assistant message that delivers the report (Agent SDK v0.3.232+) ([agent-sdk/typescript: SDKContextUsage](https://code.claude.com/docs/en/agent-sdk/typescript#sdkcontextusage)).
- **`claude -p --output-format json`** returns `result`, `session_id`, `usage`, and cost ([headless: get structured output](https://code.claude.com/docs/en/headless#get-structured-output)). `ModelUsage` in result messages includes `contextWindow` ([agent-sdk/typescript: ModelUsage](https://code.claude.com/docs/en/agent-sdk/typescript#modelusage)).
- **Compaction events in the stream.** `SDKCompactBoundaryMessage` (`subtype: "compact_boundary"`) carries `compact_metadata.trigger` (`manual` or `auto`) and `pre_tokens` ([agent-sdk/typescript](https://code.claude.com/docs/en/agent-sdk/typescript#sdkcompactboundarymessage)).

### 3. Hooks

Hooks receive no context-usage fields in general. The common input fields are `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, and a few more ([hooks: common input fields](https://code.claude.com/docs/en/hooks#common-input-fields)). There are two exceptions:

- **`SessionStart`** with `source` `resume` or `fork` gets `context_tokens`, defined as "Tokens the first request of the resumed session re-sends as its prompt", plus `prompt_cache_likely_expired` and `estimated_cache_write_usd` (v2.1.251+) ([hooks: SessionStart](https://code.claude.com/docs/en/hooks#sessionstart)).
- For the Agent tool, `PreToolUse` and `PostToolUse` input carries `totalTokens` for a subagent's final request ([hooks](https://code.claude.com/docs/en/hooks)).

So a hook that wants the main session's current usage has to read `transcript_path` itself. That is exactly what `context-gauge.sh` does.

### 4. Parsing the transcript (what `context-gauge.sh` does)

The docs say transcripts live at `~/.claude/projects/<project>/<session-id>.jsonl`, and: "The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release. To build on session data, use `/export` or the script interfaces instead" ([sessions: where transcripts are stored](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored)).

The hooks page adds that "the transcript file is written asynchronously and may lag the in-memory conversation" ([hooks: common input fields](https://code.claude.com/docs/en/hooks#common-input-fields)).

`CLAUDE_CODE_SESSION_ID` is set in Bash tool and hook subprocesses and "is updated on `/clear`". On `--continue` or `--resume` without an explicit ID, it "may receive the initial startup ID instead" ([env-vars](https://code.claude.com/docs/en/env-vars)). That edge case could point the gauge at the wrong file.

How the gauge compares with the official figure:

- **Formula.** The gauge adds `output_tokens`; `used_percentage` does not. On a single reading the gap is small, since it is one response's output.
- **Window.** The gauge's default window is 1,000,000, the full model window. The real trigger is lower, about 967K by default, or whatever `autoCompactWindow` is set to.

## (b) Handing off to a fresh orchestrator without manual compaction

### Built-in pieces

| Need | What exists | Source |
| - | - | - |
| Start a fresh session from a script | `claude -p "<prompt>"`, optionally `--session-id <uuid>`, `--name`, `--append-system-prompt-file`, `--output-format json` | [cli-reference](https://code.claude.com/docs/en/cli-reference), [headless](https://code.claude.com/docs/en/headless) |
| Continue a specific session | `claude -p --resume <id\|name\|path-to-.jsonl>`; `--continue` for the most recent in the directory; `--fork-session` to branch under a new ID | [cli-reference](https://code.claude.com/docs/en/cli-reference), [headless: continue conversations](https://code.claude.com/docs/en/headless#continue-conversations) |
| Seed a new session's context automatically | `SessionStart` hook; `source` is one of `startup`, `resume`, `clear`, `compact`, `fork`; output `additionalContext`, or plain stdout, is added to Claude's context. `CLAUDE_ENV_FILE` persists env vars | [hooks: SessionStart](https://code.claude.com/docs/en/hooks#sessionstart) |
| Control when auto-compaction fires | `autoCompactWindow` setting (100K–1M tokens), `--autocompact <tokens>` per launch, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env var (highest precedence), `/autocompact`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (can only lower the threshold) | [model-config: set the auto-compact window](https://code.claude.com/docs/en/model-config#set-the-auto-compact-window), [settings-reference](https://code.claude.com/docs/en/settings-reference#autocompactwindow), [env-vars](https://code.claude.com/docs/en/env-vars) |
| Turn compaction off | `autoCompactEnabled: false` or `DISABLE_AUTO_COMPACT=1` stops auto and idle compaction while leaving `/compact` available. `DISABLE_COMPACT=1` stops all compaction | [settings-reference: autoCompactEnabled](https://code.claude.com/docs/en/settings-reference#autocompactenabled), [env-vars](https://code.claude.com/docs/en/env-vars) |
| Intercept compaction | `PreCompact` (matcher `manual` or `auto`): exit 2 or `decision: "block"` blocks it. "If compaction was triggered proactively before the context limit, Claude Code skips it and the conversation continues uncompacted"; if it was recovering from a context-limit error, "the current request fails". On exit 0, its stdout becomes "instructions for the compaction summary" (capped at 10,000 chars) | [hooks: PreCompact](https://code.claude.com/docs/en/hooks#precompact) |
| Capture the summary | `PostCompact` receives `compact_summary`; it has no decision control | [hooks: PostCompact](https://code.claude.com/docs/en/hooks#postcompact) |
| Keep a session going instead of stopping | `Stop` hook `decision: "block"` with `reason`, or `additionalContext`. There is an "8-consecutive-continuation cap", raised with `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. `/goal` is a built-in shortcut for this | [hooks: Stop](https://code.claude.com/docs/en/hooks#stop) |
| Compact from a script | A `-p` / SDK turn can be `/compact`. The result message's `local_command` field names "a command completed without entering the agent loop, such as `/compact`" | [agent-sdk/typescript](https://code.claude.com/docs/en/agent-sdk/typescript) (result fields) |
| Know what survives compaction | System prompt, project-root CLAUDE.md, auto memory, skill descriptions, and up to 5 recent files are restored. Invoked skill bodies come back capped at 5,000 tokens each and 25,000 tokens total; "Truncation keeps the start of the file" | [context-window: what survives compaction](https://code.claude.com/docs/en/context-window#what-survives-compaction) |

### Not found

- **No first-class "handoff" command.** The [commands reference](https://code.claude.com/docs/en/commands) lists `/clear`, `/compact`, `/branch`, `/fork`, `/resume`, and `/rewind`. None of them starts a fresh session seeded from a state file. `/fork` copies the whole conversation, which is the opposite of what we want.
- **No documented way for the model to run `/clear` or `/compact` on its own session mid-turn.** Built-in commands are typed by the user, or sent as a prompt by an SDK or `-p` driver. **Unverified** whether any tool lets the model trigger them itself; I found no such tool documented.
- **No hook gets a push when usage crosses a threshold.** The closest options are `PreCompact` with `auto`, which fires only at the compaction window, and the status line, which runs on every assistant message.

### Gotcha: idle compaction

Idle compaction is on by default in interactive terminal sessions. It runs when the conversation is over 200K tokens and about an hour has passed since the last request ([settings-reference: idleCompaction](https://code.claude.com/docs/en/settings-reference#idlecompaction)). An orchestrator that yields its turn and waits more than an hour would be compacted without anyone asking, which silently breaks "Do not compact between waves". `PreCompact` with matcher `auto` also fires for idle compaction, so a hook can block it. Setting `idleCompaction: false` also stops it.

## Options for the orchestrator

1. **External driver plus state file (recommended).** A small shell loop runs `claude -p "/implement-plan resume from <state.md>" --output-format json`. At each wave boundary the orchestrator writes its state to a file (frontier, merged tickets, blocked tickets, open findings) and ends its run. The driver reads `usage` from the JSON result, or simply starts a fresh `-p` session for every wave. Each wave then gets a clean context, no one compacts anything, and auto-compaction is only a backstop. Everything this needs is documented above. It fits the skill's existing "results are files" rule and "recompute the frontier from the tracker".
2. **In-session gauge plus self-handoff.** The orchestrator runs `context-gauge.sh`, or reads a file the status line writes, at each wave boundary. Over a threshold, it writes state and ends. A `Stop` hook or the driver then starts the fresh session. This depends on the internal transcript format, or on adding the status-line-to-file step, and it still needs an outside process to start the new session.
3. **Let auto-compaction do it, but steer it.** Set `autoCompactWindow` low (for example 300K). Add a `PreCompact` hook whose stdout tells the summary to keep the state, and a `SessionStart` hook with matcher `compact` that re-injects the state file. This needs no driver, but it is still compaction, and lossy. It contradicts the skill's current rule.
4. **Agent SDK driver.** Same as option 1, but in TypeScript or Python. It can use `getContextUsage()` for an exact, compaction-window-aware percentage and react to `compact_boundary` messages. It is more capable than option 1, at the cost of more code.

## Open questions and possible new tickets

- Decide between options 1 and 4, and define the orchestrator state-file format. That format is the real handoff contract.
- Fix or replace `context-gauge.sh`. One way is to have the status line script also write `context_window` keyed by `session_id`, so the gauge reads official numbers instead of the internal JSONL. Also align its formula (drop output tokens) and its window (use the compaction window, not 1M).
- Decide whether the implement-plan skill should disable idle compaction for its sessions, or block it with a `PreCompact` hook.
- Check `~/.claude/setting.local.json`: it is probably a misnamed `settings.local.json` that never loads (**unverified**).
