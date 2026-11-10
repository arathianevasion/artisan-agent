# Agent teams compared with headless sessions per ticket

Research for [#33](https://github.com/arathianevasion/watsonsoft-workflow/issues/33). Compares Claude Code **agent teams** (a lead session that spawns teammates it can message) with the owner's current approach: one headless `claude -p` process per ticket in its own git worktree, as run by `implement-plan`. It reports facts and trade-offs and does not choose; that is [#34](https://github.com/arathianevasion/watsonsoft-workflow/issues/34).

Gathered 2026-11-10 against Claude Code docs and changelog at v2.1.322 (the installed version). Agent teams are experimental and change often.

This builds on [orchestration-options.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/orchestration-options/docs/research/orchestration-options.md) (#13). Facts about the headless path that are already there (failure contract, SIGTERM, `--bare`, result files, merge order) are not repeated; see its "Option 1" section.

## Sources

| Key | Source |
| --- | --- |
| [AT] | https://code.claude.com/docs/en/agent-teams |
| [SA] | https://code.claude.com/docs/en/sub-agents |
| [SK] | https://code.claude.com/docs/en/skills |
| [HL] | https://code.claude.com/docs/en/headless |
| [CLI] | https://code.claude.com/docs/en/cli-reference |
| [TR] | https://code.claude.com/docs/en/tools-reference |
| [WT] | https://code.claude.com/docs/en/worktrees |
| [AG] | https://code.claude.com/docs/en/agents |
| [COST] | https://code.claude.com/docs/en/costs |
| [HK] | https://code.claude.com/docs/en/hooks |
| [XS] | https://code.claude.com/docs/en/cross-session-messaging |
| [CL] | https://code.claude.com/docs/en/changelog |
| [IP] | `~/.claude/skills/implement-plan/SKILL.md` (owner's local skill) |
| [OO] | [orchestration-options.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/orchestration-options/docs/research/orchestration-options.md) |

## Summary table

| | Agent team (lead + teammates) | `claude -p` per ticket in a worktree (`implement-plan`) |
| --- | --- | --- |
| Status | Experimental, off by default; `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` [AT] | Stable, documented CLI mode [HL] |
| Where it runs | Interactive lead session only; `-p` and Agent SDK sessions never spawn teammates [AT] | Any shell or script; no terminal needed [HL] |
| How started | Lead's Agent tool call with a `name`; no confirmation asked [AT] | Orchestrator launches one OS process per ticket [IP] |
| Addressing | By name via `SendMessage`; you via the agent panel or split panes [AT] | None by default; a `-p` worker can receive cross-session messages [XS] |
| Shared context | Each teammate has its own window; loads CLAUDE.md, MCP, skills; gets spawn prompt only, not lead history [AT] | Fresh session per process, same project loading unless `--bare` [HL] |
| Shared task list | Yes, with dependencies and file-locked claiming, but only where the Task tools exist [AT], [TR] | None; the tracker and result files are the shared state [IP] |
| Files / isolation | Shared working directory; "Agent teams don't isolate teammates in worktrees" [AG] | One worktree and branch per ticket [IP] |
| Results back | Idle notification carries the teammate's final answer into the lead [AT] | Result file per ticket, read by the orchestrator [IP] |
| Permissions | Teammates start in the lead's mode; prompts surface in the lead [AT] | Per-process `--permission-mode`; Manual mode denies instead of waiting [HL] |
| Spend / turn caps | No documented per-teammate dollar or turn cap; `--max-budget-usd` and `--max-turns` are print-mode only [CLI] | `--max-budget-usd`, `--max-turns` per process [CLI] |
| Live visibility / steering | Agent panel or panes; open any transcript, message, interrupt, stop [AT] | Log files; no live steering in `implement-plan` as written [IP] |
| Concurrency | No hard teammate limit; 3-5 suggested; one team per session; no nesting [AT] | Limited by the machine and plan rate limits (no Claude Code cap documented for separate processes) |
| `/implement` (`disable-model-invocation: true`) | A teammate cannot invoke it; a person typing it into the teammate view can (see below) [SK], [AT] | Works: `/implement` in the `-p` prompt is a user turn [HL], [IP] |
| Lead context cost | Every teammate's final answer and messages land in the lead [AT] | Small: orchestrator reads result files, never transcripts [IP] |

## Agent teams in detail

### Enabling and status

- "Agent teams are experimental and disabled by default." Enable with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the environment or in `settings.json` `env` [AT].
- Added as a "research preview" in v2.1.32 (2026-02-05) [CL]. In v2.1.178 (2026-06-15) the `TeamCreate`/`TeamDelete` tools were removed: every session has one implicit team and teammates are spawned with the Agent tool's `name` parameter [CL].
- Enabling it changes ordinary delegation: any subagent Claude *names* launches as a teammate, "so teams can form even when you didn't ask for one" [AT].
- On this machine the variable is not set in `~/.claude/settings.json` or the shell (checked read-only, 2026-11-10).

### How teammates start and are addressed

- Claude launches a teammate when it calls the Agent tool with a `name` while teams are enabled, unless the call is a fork or passes `isolation` on the call itself. "Claude Code doesn't ask you to confirm the launch." [AT]
- **Interactive only.** "In non-interactive mode with the `-p` flag, including Agent SDK sessions, Claude doesn't spawn teammates" [AT]. So a team cannot be the inner unit of an unattended `-p` orchestrator.
- The lead names each teammate; any teammate can message any other by name. There is no broadcast: "send one message per recipient" [AT].
- Teammates can be spawned from a subagent definition. Applied: `tools`, `model`, `disallowedTools`, `effort`, `autoCompactWindow`, body, and (split-pane only) `mcpServers`. Not applied: `skills` [AT]. `maxTurns`, `permissionMode` and `isolation` are not in the applied list (inferred from the list; not stated as excluded except `isolation`, below).
- Model per teammate: spawn prompt, then definition `model`, then `CLAUDE_CODE_SUBAGENT_MODEL`, then lead's model; fixed at spawn [AT].
- Limits: one team per session; no nested teams; the lead is fixed; in-process teammates cannot run background subagents [AT].

### Context, task list and files

- Each teammate has its own context window, loads CLAUDE.md, MCP servers and skills, and receives the spawn prompt; "The lead's conversation history does not carry over." [AT]
- **Task list.** Shared, three states (pending, in progress, completed), dependencies that block and auto-unblock, self-claim or lead-assign, file locking on claims [AT]. Stored at `~/.claude/tasks/{team-name}/`, which survives the session; team config at `~/.claude/teams/{team-name}/config.json` is removed at session end [AT].
- **Caveat on the task list.** It exists only for "agents that have the Task tools"; otherwise agents "coordinate through messages instead" [AT]. The Task tools are on by default only on Opus 4.7, Sonnet 4.6, Haiku 4.5 and earlier; newer models need `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, `--allowedTools TaskCreate`, or `--tools` [TR]. So on current default models a team may have no shared task list unless opted in.
- Known limitation: "Task status can lag": teammates sometimes fail to mark tasks complete, blocking dependents [AT].
- **Files.** Teammates share the lead's working directory. "Agent teams don't isolate teammates in worktrees, so partition the work so each teammate owns a different set of files" [AG]. "Two teammates editing the same file leads to overwrites." [AT]
- Passing `isolation` on the Agent call makes it an ordinary subagent, not a teammate; an `isolation` value in the definition's frontmatter "doesn't prevent it, and the teammate then runs in the main session's working directory" [SA].
- **Unverified:** whether a teammate can move itself into a worktree with the `EnterWorktree` tool [TR], [WT]. Docs neither list it for teammates nor exclude it.

### How results and messages come back

- Messages are delivered automatically; the lead does not poll [AT].
- "When a teammate finishes and stops, it automatically notifies the lead and includes its final answer in the notification. A teammate whose turn ends on an API error notifies the lead that it failed and includes the error text." [AT]
- Mailboxes are JSON files at `~/.claude/teams/{team-name}/inboxes/{agent-name}.json`; a send is reported only when the write succeeds [AT].
- Hooks give gates: `TeammateIdle` (exit 2 keeps the teammate working), `TaskCreated`, `TaskCompleted` (exit 2 blocks completion) [AT], [HK]. `TaskCompleted` also fires when a teammate finishes its turn with in-progress tasks [HK].

### Permissions

- No per-teammate mode at spawn. A new teammate starts in the lead's mode, including `bypassPermissions`; a lead in `dontAsk` gives teammates Manual [AT].
- An in-process teammate follows the lead's mode while the lead is in `acceptEdits`, `auto` or `bypassPermissions`, even if switched to Manual [AT].
- "Teammate permission prompts appear in the lead session, so approve them there yourself." [AT] The docs suggest pre-approving common operations to cut prompts [AT].
- `permissions.denyInsteadOfPrompting` (added v2.1.319) denies a call that would wait on a prompt and lets the turn continue, including in teammates [CL].
- A message from another agent is marked as not from you; a teammate "can't approve a permission prompt or supply consent on your behalf" [AT].

### Spend and turn limits

- "Agent teams use significantly more tokens than a single session"; usage scales with active teammates and "roughly proportional to team size" [AT], [COST].
- `--max-budget-usd` and `--max-turns` are "print mode only" [CLI], and teams do not run in print mode [AT]. No per-team or per-teammate dollar cap is documented. **Unverified:** whether a definition's `maxTurns` applies to a teammate (not in the applied list [AT]).
- Teammates in-process fall outside the lead's cache TTL bucket: 5-minute cache by default; `subagentPromptCacheTtl: "1h"` extends it at a higher write rate [AT].
- Cost advice: use Sonnet for teammates, keep teams small, focused spawn prompts, shut down finished teammates since "each active teammate continues consuming tokens until it exits or the session ends" [COST].

### What a person can see and steer

- Default in-process mode: agent panel under the prompt; arrows select, Enter opens transcript and lets you message it, Escape interrupts its turn, `x` stops it, Ctrl+T toggles the task list [AT].
- Split panes (tmux or iTerm2 with `it2`) show every teammate at once; not supported in VS Code's terminal, Windows Terminal or Ghostty [AT].
- You can put a running teammate into plan mode with Shift+Tab; teammates spawned while the lead is in plan mode send plan approvals, auto-approved unless you changed that teammate's mode [AT].
- Docs: "Letting a team run unattended for too long increases the risk of wasted effort." [AT]

### Failure handling

- API-error ends are reported to the lead with error text [AT].
- "Teammates may stop after encountering errors instead of recovering"; remedy is to message them or spawn a replacement. The lead "can stop early too" [AT].
- Messaging a stopped in-process teammate brings it back with its saved conversation [AT].
- `/resume` and `/rewind` do not restore in-process teammates; the lead may then message teammates that no longer exist [AT]. Docs say a teammate's background work "can't outlive the lead's process" [AT]; that in-process teammates themselves end with the lead is inferred, not stated.
- Shutdown is a request the teammate may reject; it can be slow [AT]. Orphaned tmux sessions may need manual `tmux kill-session` [AT].
- No built-in retry cap; any retry policy would live in the lead's instructions or hooks (inferred; nothing documented).

### Concurrency

- "There's no hard limit on the number of teammates"; start with 3-5; "5-6 tasks per teammate" [AT].
- The 20-concurrent-subagent default does not apply: teammates "follow their own limits instead" [SA].
- All teammates share the lead's plan usage and rate limits (inferred from "separate Claude instance" on one account; not stated as a number).

### Can a teammate run `/implement`?

- `disable-model-invocation: true` means "Claude can't invoke the skill on its own"; the description is not in Claude's context; "If Claude tries anyway, Claude Code blocks the call and instructs it not to reproduce the deploy steps another way" [SK]. A teammate is a Claude session, so it cannot call `/implement` itself, whether asked in its spawn prompt or by a `SendMessage` from the lead.
- A lead's message is marked as from another Claude session, not from you [AT], so it is not a user turn.
- **What does work:** "While you're viewing an in-process teammate, plain text and skills go to that teammate" [AT]. A person can open each teammate and type `/implement <ticket>`. That needs a human per teammate, which breaks the unattended run `implement-plan` relies on [IP].
- **Unverified:** whether an Agent-tool spawn prompt that begins with `/implement` is expanded as a slash command. Nothing in [AT], [SA] or [SK] says spawn prompts expand skills; `-p` prompts do [HL].
- Workarounds that keep the skill guard: make `/implement` model-invocable (owner's choice; changes the composition rule in [IP]), or give teammates a model-invocable skill such as `tdd` (as `implement-spec` does [OO]). A definition's `skills` preload does not apply to teammates [AT], and preloading is barred for `disable-model-invocation` skills anyway [SK].

### Context cost to the lead

- Every teammate's final answer arrives in the lead as an idle notification, plus any messages teammates send [AT]. The lead is an ordinary interactive conversation, so this accumulates (compaction applies; not measured here).
- Contrast: `implement-plan` keeps the orchestrator's context small by reading result files only and never transcripts [IP].
- Mitigation available in both: instruct workers to keep final answers short and put detail in files (practice, not a documented feature).

## A middle ground worth knowing: cross-session messaging with `-p` workers

Not agent teams, but relevant to the decision:

- A `claude -p` session binds an inbox socket like an interactive one, so "a long-running `-p` worker can receive messages and appears in the listing"; `--bare` sessions do not [XS].
- A `-p` worker can't show the approval dialog; to accept messages unattended, start it with `crossSessionInbound: "accept"` in `--settings` [XS].
- A session can ask another for one notice when it next goes idle or exits (`SendMessage` `notify_when_idle`), without spending tokens in the watched session [XS].
- So an orchestrator session could keep per-ticket worktrees, `/implement` as a user prompt and `--max-budget-usd`, and still message or be notified by workers. **Not tested.**

## Trade-offs to carry into #34

- **Unattended vs interactive.** Teams need an interactive lead and work best watched [AT]. `implement-plan` runs unattended after one approval [IP].
- **Skill reachability.** Teams cannot run `/implement` without a person typing it per teammate [SK], [AT]. Headless can [HL].
- **Isolation.** Teams share one checkout; headless gets a worktree per ticket. For code-writing tickets that touch overlapping files this is the largest gap [AG], [IP].
- **Spend control.** Only headless has hard-ish per-run dollar and turn caps [CLI].
- **Coordination.** Teams give live messaging, a shared task list (when Task tools are on), hooks on idle/completion, and a person can steer any worker mid-run [AT]. Headless workers are isolated and silent unless cross-session messaging is set up [XS].
- **Fit per the docs.** Teams' strongest cases are research, review, competing-hypothesis debugging and cross-layer work with partitioned files; for "sequential tasks, same-file edits, or work with many dependencies" a single session or subagents are more effective [AT].
- **Stability.** Teams are experimental, with known limits on resume, task status and shutdown [AT].

## Open questions

- Can a teammate call `EnterWorktree` to isolate itself? Docs don't say.
- Does a teammate honour `maxTurns` from its subagent definition? Not in the applied list.
- Does a spawn prompt beginning with `/skill` expand for a teammate? Not documented.
- Could a `-p` orchestrator built on cross-session messaging replace polling result files? Not tested.
