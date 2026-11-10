# Cloud sessions as ticket runners

Research for [#30](https://github.com/arathianevasion/watsonsoft-workflow/issues/30). Builds on [orchestration-options.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/orchestration-options/docs/research/orchestration-options.md) (#13) and does not repeat what it covers. It reports facts and trade-offs only; the choice belongs to #14.

Gathered 2026-11-10 by reading docs only. No cloud session, scheduled task or routine was started. Scheduled tasks and the `/fire` endpoint are labelled research preview / experimental by their own docs [RT], [RT-API].

## Sources

| Key | Source |
| --- | --- |
| [CE] | https://code.claude.com/docs/en/cloud-environments |
| [WEB] | https://code.claude.com/docs/en/claude-code-on-the-web |
| [RT] | https://code.claude.com/docs/en/routines |
| [RT-API] | https://platform.claude.com/docs/en/api/claude-code/routines-fire |
| [PM] | https://code.claude.com/docs/en/permission-modes |
| [SK] | https://code.claude.com/docs/en/skills |
| [XS] | https://code.claude.com/docs/en/cross-session-messaging |
| [CL] | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (version named per entry) |
| [IMPL] | `mattpocock-skills` 1.3.1 `skills/engineering/implement/SKILL.md` (installed plugin cache) |

## Short answer

- **Can a cloud run execute `/implement` for one ticket?** Not as the owner's setup stands. `/implement` is a plugin skill [IMPL], and plugins (user-enabled or declared in the repo's `.claude/settings.json`) do not load in cloud sessions [CE], [SK]. It would have to be committed to the repo's `.claude/skills/` or enabled on the claude.ai account [SK], [CE], along with the `tdd` and `code-review` skills it calls [IMPL]. Whether a cloud or scheduled-task prompt that *starts* with `/implement` runs a `disable-model-invocation: true` skill is **not documented** (see below).
- **Structured result back?** No result channel exists beyond what the run writes to GitHub. `/fire` and `claude --cloud` return only a session ID and URL; neither waits for completion, and there is no documented endpoint to read a session's status or output [RT-API], [WEB]. Run history status says how the session ended, not whether the work was done [RT].
- **Max run length:** no total session-length cap is documented. Documented limits are per command (2 min default, 10 min max foreground; +30 min once backgrounded), SessionStart hooks (600 s), setup-script caching (~5 min), and idle pause / reclaim [CE].
- **Concurrency:** no number is documented. An organization limit on "cloud sessions running at once" exists (a run that hits it does not start) [RT], [CL 2.1.302]. Documented numeric caps are hourly start limits for scheduled tasks and the `/fire` API [RT], [RT-API].
- **Never-waits rule:** broken by several documented stop conditions: ask rules, `AskUserQuestion`, critical-path `rm`, repeated auto-mode blocks, MCP connector approval/sign-in, ambiguous auto-fix requests, and `/implement`'s own "If the reference is ambiguous, ask" [PM], [RT], [WEB], [IMPL]. `dontAsk` and `bypassPermissions` from settings files are ignored in cloud sessions [PM].

## 1. Running `/implement` in a cloud session or scheduled task

### Skill availability

- Cloud sessions "start from a fresh clone of your repository. Anything you commit to the repo is available. Anything you've installed or configured only on your own machine isn't available" [CE].
- Loaded: repo `CLAUDE.md`, repo `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, repo `.claude/settings.json` hooks and permission rules (single-repo sessions), repo `.mcp.json` (single-repo), server-managed settings [CE].
- Not loaded: `~/.claude/CLAUDE.md`, `~/.claude/skills/`, plugins enabled in user settings, and plugins declared in the repo's `enabledPlugins` / `extraKnownMarketplaces` [CE], [SK].
- Cloud sessions do load "skills you enable on claude.ai" [CE], [SK]. A skill that exists only locally is reported "not found" when a cloud scheduled task invokes it [SK].
- `/implement` is installed from the `mattpocock-skills` plugin, with `disable-model-invocation: true`, and calls the `tdd` and `code-review` skills [IMPL]. All three would need to reach the cloud session by one of the two routes above.
- This repo currently has no `.claude/` directory (checked in the worktree), so nothing is committed for cloud sessions to pick up.

### Invoking a user-only skill without a human typing it

- A message that starts with `/name` runs the skill directly; via `claude -p` or the Agent SDK only the first skill on the line loads [SK].
- `disable-model-invocation: true` also stops the skill "from running when a session-scoped scheduled task fires with the skill as its prompt" [SK]. That sentence is about session-scoped tasks (`/loop` and cron tools), not cloud scheduled tasks.
- **Unverified:** whether a cloud scheduled task's saved prompt, a `/fire`, or a `claude --cloud "/implement 30"` start counts as the user typing `/implement`. The docs read do not say. A cheap test would settle it, but this ticket forbids starting sessions; see "New tickets".
- A fired prompt "is therefore not live user input and can't act as approval or consent for actions during the run" [RT], which suggests scheduled-task prompts are treated differently from typed input. Inference only.

### Passing the ticket number

- `claude --cloud "<task>"` takes a free-text task; the VM clones the GitHub remote at the current branch, so the branch must be pushed [WEB].
- `/fire` accepts an optional `text` field (max 65,536 chars), passed "alongside its saved prompt" [RT-API]. It arrives wrapped in a `<routine-fire-payload>` block labelled untrusted, and the saved prompt must explicitly opt in to acting on it [RT]. So a per-ticket number would be data the saved prompt reads, not a `/implement 30` command line.
- Each successful `/fire` creates a new session; there is no idempotency key, so a retried webhook creates duplicate runs [RT-API].

### GitHub access inside the run

- Built-in GitHub tools and `gh api` work through the GitHub proxy without a token in the VM [CE].
- The proxy rejects GraphQL, so `gh issue` and `gh pr` subcommands get a 403; REST via `gh api repos/{owner}/{repo}/...` works [CE]. This repo's issue-tracker instructions use the `gh` CLI (`CLAUDE.md`), so any `gh issue ...` step would fail in the cloud unless rewritten to `gh api` or a `GH_TOKEN` is set (a set token still gets the GraphQL 403 through the proxy [CE]).
- The proxy only serves repositories attached to the session; others get 403 [CE]. It rejects branch deletions and tag pushes but does not limit which branch is pushed [CE].

## 2. Run length and concurrency (the cloud-environments page)

### Time limits [CE]

| Limit | Value |
| --- | --- |
| Foreground command | 2 min default, up to 10 min on request (Bash tool defaults) |
| Command after timeout | Moved to background, may run up to 30 more minutes, then stopped; `BASH_DEFAULT_TIMEOUT_MS` above 1,800,000 ms lengthens this |
| Raise defaults | `BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS` as environment variables |
| SessionStart `command` hook | Cancelled after 600 s unless `timeout` set; `async: true` hooks not enforced |
| Setup script | Not cached if longer than ~5 min; cache expires ~7 days |
| Idle | "After a few minutes without activity" the VM pauses with files saved; a paused VM "can later be reclaimed" |

- **No overall maximum session or run duration is stated** on [CE], [WEB] or [RT]. Treat as unverified rather than unlimited.
- Waiting for approval of an MCP connector call or MCP sign-in counts as inactive, and the session "can expire during that wait" [WEB].
- If a question sits idle, the human can still answer "up to environment expiry" [WEB].
- After reclaim, reopening restores conversation history but not running shell commands, subagents, or session-scoped scheduled tasks [WEB].
- Auto-compaction triggers earlier than locally because cloud sessions set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` themselves [WEB].

### Resource limits [CE]

Approximate, "may change over time": 4 vCPUs, 16 GB RAM, 30 GB disk, Ubuntu 24.04 x86_64. The VM may stop tasks that need significantly more memory.

### Concurrency and rate caps

- Each `claude --cloud` creates an independent session; several "will all run simultaneously" [WEB]. No per-user number is given.
- Organization limit on concurrent cloud sessions: exists, number not documented. A scheduled run that hits it shows "The last run didn't start because your organization had reached its limit on cloud sessions running at once" and needs no change [RT], [CL 2.1.302].
- `Session creation failed` means no VM could be allocated; "capacity is provisioned on demand", retry after a minute [WEB].
- Cloud sessions share rate limits with all other Claude usage on the account; parallel tasks consume them proportionately [WEB].
- Scheduled-task hourly start limits (no overage) [RT]: 100 scheduled runs/account (over: run waits); 30 Run-now/API/re-arm per task; 100 Run-now per account; 100 API fires per account (over: action fails, `/fire` returns 429 with `Retry-After` [RT-API]). GitHub-event triggers have per-task and per-account hourly caps; excess events are dropped [RT].
- At the subscription usage limit, runs are rejected unless usage credits are on [RT].
- GitHub connection missing when a run is due: runs skipped up to 72 h, then the task turns off [RT].

## 3. Stop conditions versus "a run never waits for a human"

Scheduled-task runs start in auto mode unless it is unavailable [RT]. Sessions started with `claude --cloud` or in the browser use whatever mode is picked in the mode dropdown [WEB].

| Condition | Waits for a human? | Source |
| --- | --- | --- |
| Action matches an ask rule | Yes, even in auto mode | [RT], [PM] |
| `AskUserQuestion`, MCP tools marked `requiresUserInteraction` | Always prompt, no mode auto-approves | [PM] |
| Connector tools the org set to `ask` | Always prompt | [PM] |
| Recognized critical-path `rm`/`rmdir`, "Dangerous rm operation not ruled out" | Always prompt | [PM] |
| First read outside the working directories | Prompts in auto mode | [PM] |
| Classifier blocks 3 in a row or 20 total (not configurable) | Yes: auto mode pauses, a prompt appears in the run and "waits until someone answers it" | [RT], [PM] |
| Single classifier block | No: Claude gets the reason and continues | [RT], [PM] |
| Auto mode unavailable (org disabled it, or model unsupported) | Run keeps its launch mode, so ordinary prompts can wait | [RT], [PM] |
| MCP connector approval or MCP sign-in | Yes, and the session may expire while waiting | [WEB] |
| Auto-fix: ambiguous or architecturally significant review comment | Yes: "Claude asks you before acting" | [WEB] |
| Auto-fix: base-branch merge conflict | No event at all; a human must ask the session to rebase | [WEB] |
| `/implement`: ambiguous ticket reference | Yes: "If the reference is ambiguous, ask" | [IMPL] |
| Artifact publish in runs started by API or GitHub triggers | Asks first | [RT] |
| `dontAsk` / `bypassPermissions` in repo settings | Ignored silently in cloud sessions; cannot be used to avoid prompts | [PM] |

Contrast: a local `claude -p` run without `--permission-prompt-tool` has no prompt to fall back to, so on repeated blocks "the action doesn't run and Claude keeps working" [PM]. Cloud runs do not have that property.

Related fixes worth knowing: auto mode in cloud sessions no longer stops for approval on some Artifact tool actions [CL 2.1.317]; cloud sessions now keep session-scoped deny/ask rules across a move to a new worker, but may drop session-scoped allow rules there, "so you may be asked again" [CL 2.1.319].

## 4. How results get back

| Channel | What arrives | Structured? | Source |
| --- | --- | --- | --- |
| `/fire` response | `{type, claude_code_session_id, claude_code_session_url}` at creation; does not wait for completion | Only the session handle | [RT-API] |
| `claude --cloud <task>` | New session on claude.ai; CLI shows setup checklist | No result | [WEB] |
| `claude -p "msg" --cloud <id> --output-format json` | `{ok, session_id, url}` for a queued follow-up | Only send status | [WEB] |
| Git branch | Scheduled tasks push to `claude/`-prefixed branches unless the prompt names another | Whatever the run commits (e.g. a result file) | [RT] |
| Pull request | Created from the session UI or by Claude; PR body includes the session URL | PR metadata | [WEB], [CE] |
| Commit trailer | `Claude-Session: <url>` on every commit; session can read its own ID from `CLAUDE_CODE_REMOTE_SESSION_ID` | Traceable link | [CE] |
| Issue comment | Built-in GitHub tools can post comments; `gh api` REST works | Whatever the run writes | [CE] |
| Run history | Succeeded / Failed / Cancelled; "say how the session ended, not whether Claude completed the work" | Coarse, UI only | [RT] |
| `/schedule` in CLI | Lists recent runs with status and reads a run's log to explain it | Conversational, not an API | [RT] |
| Push / failure notifications | Scheduled tasks have push notifications and failure notifications | Human-facing | [CL 2.1.292], [CL 2.1.285] |
| Connectors (MCP) | Run can write to external services (e.g. Slack, Linear) | Whatever the run writes | [RT] |
| Cross-session messaging | A local session can message a cloud session, but a cloud session "can't use `SendMessage` to answer a message from another machine" | No return path | [XS] |
| Teleport | `claude --teleport <id>` pulls branch and conversation to a terminal | Interactive | [WEB] |

So an orchestrator would get the result by polling GitHub: a branch, a committed result file, a PR, or an issue comment that the run's prompt tells it to write. Nothing documented lets the orchestrator query a cloud session's state or final message by API. The `/fire` token "grants no read access" [RT-API].

## Trade-offs for #14

- **Skill packaging cost.** Cloud runners need `implement`, `tdd` and `code-review` committed to `.claude/skills/` or enabled on the claude.ai account; local `-p` runners get them from the plugin [CE], [SK], [IMPL].
- **Invocation is unproven.** Whether a non-typed prompt can trigger a `disable-model-invocation` skill in the cloud is undocumented. A local `-p` run is documented to accept `/<skill>` as its prompt (from #13).
- **No result API.** The result contract must be "write it to GitHub" (branch file, PR body, issue comment), polled by the orchestrator. Local `-p` gives a JSON result and exit code directly (from #13).
- **Waits are possible.** Unlike `-p`, cloud runs can stop on a prompt after repeated blocks, ask rules, connector approvals, or skill-level questions, and may then expire [PM], [RT], [WEB]. Mitigations: no ask rules in the repo settings, no `AskUserQuestion`-style steps, unambiguous ticket references, and an orchestrator timeout that treats silence as blocked.
- **GraphQL is blocked.** Ticket tooling that relies on `gh issue`/`gh pr` must switch to `gh api` REST in the cloud [CE].
- **Caps are opaque.** No per-run duration or concurrency number is published; the org concurrency limit shows up only as a failed start [RT]. Local `-p` is bounded only by the machine and rate limits.
- **Gains.** Runs survive a closed laptop, are viewable and steerable from any device, need no local worktrees, and attribute every commit to a session URL [WEB], [CE].
- **Hourly start limits** (30 fires per task, 100 per account) are far above a wave of a few tickets [RT].

## Open / unverified

- Whether `/implement` (user-only) runs when it is the start of a cloud task, scheduled-task prompt, or `/fire`-started session. Not documented.
- Maximum total cloud session duration. Not documented.
- The organization's concurrent cloud session limit value. Not documented.
- How long a paused VM survives before reclaim ("a few minutes" to pause; reclaim time unstated) [CE].
