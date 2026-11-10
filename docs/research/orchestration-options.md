# Orchestration options for dispatching ticket agents

Research for [#13](https://github.com/arathianevasion/watsonsoft-workflow/issues/13). Compares three ways an orchestrator can run one agent per ticket. It reports facts and trade-offs and does not pick a model; that is the separate ticket "Which orchestration model does version one use?".

Gathered 2026-11-10. Claude Code features named here change often, and several are marked research preview or beta in their own docs.

## Sources

Every claim below cites one of these. Short keys in square brackets point here.

| Key | Source |
| --- | --- |
| [IP] | `~/.claude/skills/implement-plan/SKILL.md` (owner's local skill) |
| [IP-D] | `~/.claude/skills/implement-plan/references/dispatch.md` |
| [IS] | `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.3.1/skills/engineering/implement-spec/SKILL.md` (installed 1.3.1) |
| [IS-UP] | https://github.com/mattpocock/skills/blob/main/skills/engineering/implement-spec/SKILL.md (main at `4ae2317`; last changed by `a496f55`, 2026-10-29) |
| [SF] | https://github.com/mattpocock/skills/blob/main/skills/in-progress/software-factory/SKILL.md (added in `4ae2317`, 2026-10-31; not in the installed 1.3.1 cache) |
| [SF-R] | https://github.com/mattpocock/skills/blob/main/skills/in-progress/software-factory/RUNNERS.md |
| [SF-O] | https://github.com/mattpocock/skills/blob/main/skills/in-progress/software-factory/OBSERVABILITY-PLATFORMS.md |
| [SF-T] | https://github.com/mattpocock/skills/blob/main/skills/in-progress/software-factory/EXAMPLE-TASKS.md |
| [CC-HL] | https://code.claude.com/docs/en/headless |
| [CC-CLI] | https://code.claude.com/docs/en/cli-reference |
| [CC-SA] | https://code.claude.com/docs/en/sub-agents |
| [CC-WT] | https://code.claude.com/docs/en/worktrees |
| [CC-SK] | https://code.claude.com/docs/en/skills |
| [CC-AG] | https://code.claude.com/docs/en/agents |
| [CC-AV] | https://code.claude.com/docs/en/agent-view |
| [CC-WEB] | https://code.claude.com/docs/en/claude-code-on-the-web |
| [CC-RT] | https://code.claude.com/docs/en/routines |
| [CC-PJ] | https://code.claude.com/docs/en/claude-projects |
| [CC-COST] | https://code.claude.com/docs/en/costs |
| [CC-SDKC] | https://code.claude.com/docs/en/agent-sdk/cost-tracking |

## Summary table

| | 1. `claude -p` per ticket in worktrees | 2. In-session subagents + merger subagent + integration branch | 3. Remote runs (software-factory style / Claude Code cloud) |
| --- | --- | --- | --- |
| Isolation | One git worktree and one OS process per ticket; fresh context per process [IP-D] | Each implementer subagent in its own worktree and branch [IS]; own context window [CC-SA] | Fresh disposable runner per run; only branch/PR survives [SF], [SF-R]; Anthropic cloud: isolated VM per session [CC-WEB] |
| Merging | Orchestrator merges serially into the integration base, full suite after each merge [IP], [IP-D] | Implementer merges integration tip into its branch, then a merger subagent merges it to the integration branch [IS] | Run pushes a branch/PR; merge is by a human or a later run [SF-T], [CC-RT] |
| Crash / failure | Result file required even on failure; mark blocked, keep worktree, no auto-retry [IP], [IP-D] | Not specified by the skill; Claude Code reports a failed background subagent with its last output [CC-SA] | Run ends; new run is triggered by a tracker/git-host change [SF]; routine history shows Failed/Cancelled/Succeeded [CC-RT] |
| Red gates | Agent reports `tests` in result; orchestrator re-runs suite on merged result, aborts and blocks on red [IP-D] | Not specified beyond implementer using `tdd` [IS] | "Automated checks" are a brake every run must pass [SF] |
| Merge conflict | `/resolving-merge-conflicts`; if unresolved, abort and mark blocked [IP], [IP-D] | Handled by the merger subagent; mechanics unspecified [IS] | Cloud auto-fix cannot see base-branch conflicts; ask the session to rebase [CC-WEB] |
| Retry cap | None: no automatic retry [IP] | Not specified [IS] | "Cap every loop of runs at a few tries before a human" [SF]; rework task stops after a set number of fails [SF-T] |
| Spend visibility / limits | `--output-format json` gives `total_cost_usd` (subagents included); `--max-budget-usd` hard-ish cap; both client-side estimates [CC-HL], [CC-CLI], [CC-SDKC] | Shared session: `/usage` attribution shows subagent share; no per-subagent dollar cap documented [CC-COST], [CC-SA] | Plan usage limits; routines 100 scheduled runs/hour; projects 500 new threads/day; usage credits optional [CC-RT], [CC-PJ], [CC-WEB] |
| What a human sees live | Log file per ticket and result JSON [IP-D]; or `claude agents` / `--json` if launched as `--bg` sessions [CC-AV] | `/tasks` list and subagent transcript; permission prompts surface in the main session [CC-SA], [CC-AG] | claude.ai/code session page, steer from any device [CC-WEB]; Projects Overview pane [CC-PJ]; CI run page [SF-O] |
| Orchestrator context cost | Small: reads ticket bodies and result files, never transcripts [IP] | Each subagent result returns into the main conversation [CC-SA] | Orchestrator is outside the agent loop (CI, server, routine); in Projects the coordinating conversation spends its own tokens [SF], [CC-PJ] |
| Human waits | Plan approval up front, then unattended [IP] | Not specified [IS] | "A run never waits for a human" [SF] |

## Option 1: `claude -p` headless process per ticket (owner's `implement-plan`)

**Why this substrate.** `implement-plan` states that `/implement` is user-invoked only (`disable-model-invocation: true`), so "an in-session subagent cannot reach `/implement` at all", while a separate `claude -p` process can because its prompt is a user turn [IP]. Claude Code docs confirm `disable-model-invocation: true` stops Claude invoking a skill and stops it being preloaded into subagents [CC-SK], and that a `-p` run can be started with `/<skill-name>` as its prompt [CC-HL].

**Isolation.**
- One worktree and one `claude -p` process per ticket, branch `agent/<ticket>` off `BASE`, worktrees outside the repo under `../<repo>-wt/` [IP-D].
- `BASE` is the merged tip after the previous wave, and the launcher refuses to dispatch if a blocker is not an ancestor of `BASE` [IP-D].
- `refs/stash` is shared across worktrees, so agents are told never to stash [IP-D].
- Without `--bare`, `-p` loads hooks, skills, plugins, MCP servers and CLAUDE.md like an interactive session; `--bare` skips them and needs `ANTHROPIC_API_KEY` rather than subscription login [CC-HL].
- `-p` runs get no worktree cleanup prompt, so Claude Code does not clean up their worktrees [CC-WT]. (Applies when using `--worktree`; `implement-plan` creates and removes its own worktrees with `git worktree` [IP-D].)

**Merging.** Orchestrator only. Verify the diff against the expected output, then `git merge --no-ff` serially in a measured order (widest blast radius first), run the full suite after each merge, then remove the worktree [IP], [IP-D]. Agents must not merge, push or close tickets [IP-D].

**Failure handling.**
- Crash: the agent must write its result file even on failure; "a missing file is indistinguishable from a crash" [IP-D]. Agents commit early because a rate-limit kill left ten uncommitted files that cost a second full dispatch [IP-D].
- Timeout: a per-process wall-clock timeout is advised; launcher pitfalls (bare `wait` on watchdogs, backgrounding inside `$(...)`) are documented, so completion is gated on result files, not script exit [IP-D].
- SIGTERM ends a `-p` run with exit 143 and no result for the in-progress turn [CC-HL].
- Red gate: the agent reports `suite_passed`/`typecheck_passed`; the orchestrator re-runs the suite on the merged result and, on failure, aborts, keeps the branch and worktree, and marks the ticket blocked [IP-D]. Every gate must first be proven able to fail [IP].
- Merge conflict: run `/resolving-merge-conflicts`; if it fails, abort and report blocked with conflicting paths [IP-D].
- Retry cap: zero. "Do not retry automatically" [IP]. If every ticket in a wave fails, halt the run [IP].
- Agent claims success but diff misses expected output: treated as blocked [IP].

**Cost and spend.**
- `--output-format json` includes `total_cost_usd` and a per-model breakdown; both are client-side estimates [CC-HL]. `total_cost_usd` includes subagent spend; `usage` does not [CC-SDKC].
- `--max-budget-usd` stops the run at an estimated spend; subagent spend counts; spend can pass the cap, so leave headroom [CC-CLI].
- `--max-turns` limits agentic turns; no limit by default [CC-CLI].
- `implement-plan`'s documented invocation uses `--model` and `--permission-mode acceptEdits` and writes text output to a log, not JSON, and sets no budget or turn cap [IP-D]. Model tiers are chosen per ticket in the approved plan [IP].

**What a human sees.** Per-ticket `.log` and `.json` files in `.scratch/<feature>/results/` [IP-D]; wave reports and a final run summary with blocked tickets first [IP]. Not shown in `claude agents`, because `--bg` cannot be combined with `-p` [CC-AV], [CC-CLI]. A `--bg` session would instead be visible and queryable via `claude agents --json` with states `working`, `blocked`, `done`, `failed`, `stopped` [CC-AV].

**Orchestrator context cost.** Designed to be small: read ticket bodies and result files, never transcripts; do not compact between waves [IP]. Logs stay out of the orchestrator's context unless something goes wrong [IP-D].

**Human interaction.** One approval of the plan before dispatch, then unattended; it stops only for an owed approval, a graph change that invalidates the plan, or a whole wave failing [IP]. A `-p` run in Manual mode denies calls that need approval [CC-HL], so it does not wait on a human mid-run.

## Option 2: `implement-spec`-style in-session subagents with a merger subagent

**Upstream status.** Installed 1.3.1 matches upstream except that upstream (commits `7739eae` and `a496f55`, 2026-10-29) adds "Start every subagent with a fresh context window", "a fresh implementer subagent for each ticket", and a fresh subagent for the final review fixes [IS], [IS-UP].

**Isolation.**
- Each implementer subagent works "in its own worktree on its own branch", confirms it is based on the integration branch, and resets onto it if not [IS].
- In Claude Code, `isolation: worktree` gives a subagent a temporary worktree branched by default from the default branch, not the parent's `HEAD`, and removes it if the subagent made no changes [CC-SA]. Claude Code refuses git commands it cannot verify stay inside the worktree [CC-SA].
- Each subagent has its own context window but its requests count toward the same usage limits as the main conversation [CC-SA].
- Background subagents get a reduced built-in tool set and surface every permission prompt in the main session [CC-SA].
- Implementers call the `tdd` skill rather than `/implement` [IS], which avoids the `disable-model-invocation` barrier that Option 1 is built around [IP], [CC-SK].
- Nesting is limited to three layers by default [CC-SA].

**Merging.** Implementer merges the integration branch tip into its own branch before reporting; a **merger subagent** then merges it to the integration branch; new frontier tickets dispatch immediately rather than in waves [IS]. After all tickets, run `code-review` on the integration branch and fix findings in one fresh implementer subagent; optionally a draft PR closes the spec [IS], [IS-UP].

**Failure handling.** The skill says nothing about crashes, red gates, conflicts the merger cannot resolve, or retry caps [IS], [IS-UP]. What Claude Code itself provides:
- A background subagent that ends on an API error is marked failed, and Claude receives the error and the subagent's last output [CC-SA].
- `maxTurns` in a subagent definition stops it and returns output marked partial; Claude can resume it [CC-SA].
- Ticket state is closed at the end, "the way the issue tracker closes work" [IS].

**Cost and spend.**
- No per-subagent dollar cap is documented for interactive sessions; `--max-budget-usd` exists only in print mode, where subagent spend counts toward it [CC-CLI].
- `/usage` shows attribution to subagents as a share of plan usage [CC-COST]. The prompt-cache line in `/usage` covers the main conversation only [CC-COST].
- Docs warn: "Running many subagents that each return detailed results can consume significant context, and each subagent spends tokens of its own" [CC-SA].

**What a human sees.** `/tasks` lists background work and lets you open a subagent's transcript; a finished subagent stays listed for about 30 seconds [CC-SA], [CC-AG]. Subagents are not listed as rows in `claude agents` [CC-AV]. Permission prompts from background subagents appear in the main session naming the subagent [CC-SA].

**Orchestrator context cost.** Every subagent's report returns into the orchestrating conversation [CC-SA]. `implement-spec` mitigates this by keeping communication "sparse" through context pointers [IS]. `implement-plan` argues against in-session fan-out on context and skill-reachability grounds [IP].

**Human interaction.** Not specified by the skill [IS]. Background subagent permission prompts wait for the human in the main session [CC-SA].

## Option 3: Remote runs (software-factory style) and Claude Code cloud options

### The software-factory model

`software-factory` is an in-progress upstream glossary skill for designing a factory, not an executable orchestrator [SF].

- **Rule: "A run never waits for a human: it ends, and the human's later change to the ticket tracker or git host triggers a new run."** [SF]
- A **runner** is disposable: "Nothing on it survives the run"; a run's only memory is the ticket tracker, git host and orchestrator [SF].
- The **orchestrator** receives triggers, starts runs on runners, and records which runs are queued, in flight or finished [SF].
- Three brakes: automated checks every run must pass, automated review as a separate run, and human review before merge. Throttle triggers at first and "cap every loop of runs at a few tries before a human" [SF].
- Each task must answer "what stops two runs doing the same work?" [SF]; CI runners use a concurrency group to keep two runs off one ticket [SF-R].
- Example tasks: implementer builds until checks pass and opens a draft PR; review run follows; rework run fixes only what review named, and after a set number of fails labels the PR as waiting for a human; a decompose-driven implementer picks the next ticket whose dependencies are closed and triggers itself again [SF-T].
- Runner types: CI runner, microVM API, bundled agent platform (Claude Code cloud, Managed Agents, Codex cloud, Copilot), bring-your-own worker, own VPS/containers. Choice can differ per run [SF-R].
- Observability: "none" (run page) is a valid start; agent tracing platforms give per-run token rollups; Claude Code exports OTel via `CLAUDE_CODE_ENABLE_TELEMETRY=1` [SF-O].

**Merging.** PRs, merged by a human after review, per the example tasks [SF-T]. Merge order and integration branches are not covered by the skill [SF].

**Failure handling.** A failed run is reported by the orchestrator; a "fix task" files the log as a ticket, and fixes never chain [SF-T]. Retry loops are capped at a few tries [SF].

### Claude Code cloud options

- **Cloud sessions (`claude --cloud`).** Each session runs in an isolated Anthropic-managed VM that clones the GitHub remote at the current branch (push first). Each `--cloud` call is an independent parallel session. No separate VM charge; counts toward plan usage limits and shares rate limits with all other usage [CC-WEB]. `claude -p "msg" --cloud <id>` queues a follow-up and returns `{ok, session_id, url}` with JSON output [CC-WEB]. Sessions stop after inactivity and the VM is reclaimed [CC-WEB]. Repo cloning and PR creation require GitHub [CC-WEB].
- **Auto-fix.** A cloud session can watch a PR and push fixes for CI failures and review comments; it asks before acting on ambiguous requests; it cannot react to base-branch merge conflicts on its own [CC-WEB].
- **Scheduled tasks (formerly routines).** Research preview. Triggers: schedule, API (`/fire` endpoint with a per-task bearer token), GitHub events including issue and PR events [CC-RT]. Each repo is cloned per run; work goes to `claude/`-prefixed branches unless told otherwise [CC-RT]. Runs start in auto mode, but still stop and wait on ask rules or repeated classifier blocks [CC-RT]. History marks runs Succeeded/Failed/Cancelled, which "say how the session ended, not whether Claude completed the work" [CC-RT]. Limits: 100 scheduled runs/hour per account, 30 fires/hour per task, 100 API fires/hour per account, GitHub events capped hourly with excess dropped; usage draws on the subscription and can continue on usage credits [CC-RT].
- **Projects.** Public beta on Pro, Max and Ultra; not in the terminal CLI. One coordinating conversation starts parallel cloud threads, each with its own context window and branch, opening a PR when the work calls for one [CC-PJ]. Overview pane shows threads by state; buttons send "Resolve conflicts", "Fix CI", "Merge it" to a thread [CC-PJ]. Thread counts you request are preferences, not caps; the enforced limit is 500 new threads/day; the conversation spends its own tokens reading thread reports; per-thread and per-model usage is in Project settings [CC-PJ]. Thread sandboxes pause between turns and may resume from a fresh clone, losing uncommitted changes [CC-PJ].
- **Self-hosted environments** route cloud sessions to the user's own infrastructure; isolation is then the deployment's responsibility [CC-WEB]; in beta as of 2026-10 [SF-R].
- **Local background agents (`claude --bg`, agent view).** Research preview. Not remote, but the same "dispatch and walk away" shape on the owner's machine: each session moves into its own worktree before editing; `claude agents --json` is the supported way for a supervising script to read `state` and `waitingFor`; `claude logs`, `claude stop`, `claude respawn` manage sessions; the row shows linked PR status [CC-AV].

**Orchestrator context cost.** In the factory model the orchestrator is a CI workflow, server or routine and is outside any agent's context [SF], [SF-R]. In Projects the coordinating conversation uses tokens to read reports and works from recent messages and project memory rather than full history [CC-PJ].

## Trade-offs worth carrying into the decision ticket

- **Skill reachability.** Option 1 exists because `/implement` cannot be model-invoked [IP], [CC-SK]. Option 2 sidesteps this by having subagents use `tdd` instead [IS]. Whichever is chosen fixes which skill each ticket agent runs.
- **Who merges.** Option 1: the orchestrator, serially, suite after each [IP-D]. Option 2: a merger subagent, continuously [IS]. Option 3: humans via PRs, after automated checks and review [SF], [SF-T].
- **Failure policy is explicit only in Options 1 and 3.** Option 1: no retries, block and keep the worktree [IP]. Option 3: a few tries then a human [SF]. Option 2's skill is silent [IS].
- **Hard spend caps.** Only `-p` has a per-run dollar cap (`--max-budget-usd`) [CC-CLI]. Cloud runs are bounded by plan limits and hourly run counts, with optional usage credits [CC-RT], [CC-PJ]. All dollar figures from Claude Code are client-side estimates [CC-SDKC].
- **Waiting on humans.** Option 1 waits once (plan approval) [IP]. software-factory forbids a run waiting [SF], but Claude Code cloud runs can still stop on a permission prompt or an ambiguous auto-fix request [CC-RT], [CC-WEB].
- **Visibility.** Option 1 as written gives files only [IP-D]; `--bg` sessions or cloud sessions give live UIs [CC-AV], [CC-WEB], [CC-PJ].

## Open questions not answered here

- Whether `claude --bg` sessions (which can't use `-p` [CC-AV]) could replace `-p` in Option 1 to gain agent-view visibility while keeping result files. Not tested.
- Whether a cloud session or routine can run `/implement` as its prompt, and how it reports a structured result back to an orchestrator. Docs read here do not say.
- Exact max run length and concurrency caps for Anthropic cloud sessions: [CC-WEB] defers time limits to the cloud-environments page, which was not read.
