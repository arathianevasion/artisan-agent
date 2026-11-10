# What can carry a run on while the laptop is closed?

Research for [#41](https://github.com/arathianevasion/artisan-agent/issues/41). Builds on [cloud-session-runners.md](https://github.com/arathianevasion/artisan-agent/blob/research/cloud-session-runners/docs/research/cloud-session-runners.md) (#30) and [background-sessions.md](https://github.com/arathianevasion/artisan-agent/blob/research/background-sessions/docs/research/background-sessions.md) (#29) and does not repeat them. It reports facts and trade-offs; it does not choose.

The two options:

- **(A) Always-on host.** The same local pipeline (Engineering chat, then a `claude -p` orchestrator per wave, then capped `claude -p` workers in git worktrees) runs on a machine that stays on, steered from a phone with Remote Control.
- **(B) Cloud session.** The run moves into a claude.ai cloud session, with workers as in-session subagents (or as nested `claude -p` runs, see Q2).

Gathered 2026-11-10 against Claude Code v2.1.322 (installed), its `--help` output, and the docs as served that day. Docs, `--help` and read-only local checks only (`claude auth status`, `gh auth status`). No cloud session, Remote Control session, scheduled task or routine was started. **Unverified** marks anything no source states.

## Sources

| Key | Source |
| --- | --- |
| [RC] | https://code.claude.com/docs/en/remote-control |
| [CE] | https://code.claude.com/docs/en/cloud-environments |
| [WEB] | https://code.claude.com/docs/en/claude-code-on-the-web |
| [SK] | https://code.claude.com/docs/en/skills |
| [SA] | https://code.claude.com/docs/en/sub-agents |
| [TR] | https://code.claude.com/docs/en/tools-reference (Bash tool, background commands) |
| [HL] | https://code.claude.com/docs/en/headless |
| [CLI] | https://code.claude.com/docs/en/cli-reference |
| [AUTH] | https://code.claude.com/docs/en/authentication |
| [AV] | https://code.claude.com/docs/en/agent-view |
| [COST] | https://code.claude.com/docs/en/costs |
| [SEC] | https://code.claude.com/docs/en/security |
| [SH] | https://code.claude.com/docs/en/self-hosted-environments |
| [PROJ] | https://code.claude.com/docs/en/claude-projects |
| [DP] | https://code.claude.com/docs/en/discover-plugins |
| [PL] | https://code.claude.com/docs/en/plugins/loading |
| [CP] | https://claude.com/docs/plugins/overview |
| [PS] | https://claude.com/docs/plugins/platform-support |
| [CL x] | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md, entry under version x |
| [H] | `claude --help`, `claude remote-control --help` (v2.1.322) |
| [L] | Local read-only checks on the owner's laptop |

## Short answers

1. **Remote Control: yes, it can drive a chat on another machine.** It connects the Claude app or claude.ai/code to a `claude` process on whatever machine runs it; the phone is "a window into that local session" [RC]. Start it with `claude remote-control` (server mode), `claude --remote-control`, or `/remote-control` in a running chat [RC], [H]. The `claude` process and the machine must stay up: "Keep this computer awake and this command running, or the session stops" [H]. Headless children are ordinary processes on the host, so they keep running while the chat process runs, whether or not a phone is connected. If the chat process exits, Claude Code force-kills its background commands [CL 2.1.300]. The chat's own permission prompts and `AskUserQuestion` questions reach the phone and stay open until answered, with optional push notifications [RC]. The headless children's prompts never reach the phone: in `-p` with no permission host they are denied [HL]. Remote Control on the laptop itself does not help with the lid closed: a sleeping machine does no work, and the session only "reconnects automatically when your machine comes back online" [RC].
2. **Cloud VM: `claude -p` inside a cloud session is evidently supported, but only the CHANGELOG says so.** Several fixes describe "`claude -p` run inside a cloud ... session", including one for it "reporting 'Not logged in'" [CL 2.1.290, 2.1.306, 2.1.317]. The installed-tools table does not list `claude` [CE]. Caps and JSON output are CLI flags, so they should behave as they do locally (**unverified** in the cloud). In-session subagents "work the same way they do locally" [WEB]. No doc says `isolation: worktree` works or fails in a cloud session (**unverified**), though one fix mentions a cloud session where "Claude ... pushed from another worktree" [CL 2.1.314].
3. **Account-enabled skills and plugins: yes, with conditions.** Cloud sessions load "skills you enable on claude.ai" [CE], [SK]. A whole plugin can also be put on the account: **Customize > Plugins > Add marketplace** (a GitHub repo, private allowed through the Claude GitHub App) or **Upload plugin** (zip) [CP]. Account plugins reaching cloud sessions is stated only in the CHANGELOG [CL 2.1.287, 2.1.304, 2.1.314]; the cloud-environments page does not list them (**partly unverified**). Versioning: marketplace plugins update from their source; you can **Check for updates**, or turn on **Sync automatically** for a GitHub marketplace you added [CP]. A plugin from a claude.ai-hosted marketplace takes "the version claude.ai records", not the manifest `version` [PL]. A single skill uploaded on its own accepts only `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`, so `disable-model-invocation` fails the upload [SK].
4. **Always-on host** needs: a `/login` claude.ai sign-in (not `setup-token`, which "can't establish Remote Control sessions") [AUTH], [RC], renewed before it expires [AUTH]; `gh` signed in on the host; workspace trust granted once interactively [RC]; `claude remote-control` kept alive under `tmux`/`screen` or similar [RC], with the machine kept awake [H]; and usage drawn from the same plan as all other Claude use [WEB], [COST]. Security: outbound HTTPS only, no inbound ports; the transcript is stored on Anthropic servers; optional Trusted Devices [RC].

## 1. Remote Control

### What it is

- "Remote Control connects claude.ai/code or the Claude app for iOS and Android to a Claude Code session running on your machine" [RC].
- "Claude and its commands run on this computer; claude.ai and the app only show the session" [H].
- Unlike cloud sessions, "your computer has to stay on and the `claude` process has to keep running" [RC].
- The docs point always-on hosts at it directly: "To run Claude Code on your own always-on machine and drive it from other devices, use Remote Control, which is also available on Pro, Max, and Ultra plans" [SH].
- Plans: Pro, Max, Ultra, Team, Enterprise. "API keys are not supported" [RC]. The owner is on Max (`subscriptionType: max`) [L].

### How it is started

| Way | Command | Notes |
| --- | --- | --- |
| Server mode | `claude remote-control` (alias `claude rc`) | Persistent server; several concurrent sessions (`--capacity`, default 32); `--spawn same-dir \| worktree \| session`; `--permission-mode`; `--name` [RC], [H] |
| Interactive + RC | `claude --remote-control ["name"]` (`--rc`) | Normal terminal session also reachable remotely [RC], [H] |
| From a running chat | `/remote-control` (`/rc`) | Carries over the current conversation [RC] |
| Always on | `/config` → **Enable Remote Control for all sessions**, or `remoteControlAtStartup: true` in user settings | A project-level `true` is ignored [RC] |

- First use asks a one-time `Enable Remote Control? (y/n)` [RC].
- In an untrusted folder `claude remote-control` asks `Trust <directory>?`. With no terminal it exits with `Workspace not trusted`, so run `claude` there once first [RC], [H].
- Global flags placed before `remote-control` are not carried over. Most make it refuse to start (for example `--settings`); use the subcommand's own `--settings` instead [RC], [H].
- After Ctrl+C, `claude remote-control` (or `--continue` / `--session-id`) brings sessions back "for about four hours" [RC].

### Can a phone drive a chat on another machine?

Yes. Remote Control is tied to the machine running `claude`, not the device you view it from. You connect from "any browser", by QR code, or from the session list in the app (**Code** tab), where Remote Control sessions show "a computer icon with a green status dot when online" [RC]. Messages, files and photos can be sent from the phone [RC]. Some commands are local-only (`/plugin`, `/resume`). `/model`, `/effort`, `/compact`, `/clear`, `/usage`, `/config key=value` and others work from mobile [RC].

### Do the chat's headless child processes keep running?

- A `claude -p` the chat starts through the Bash tool is an ordinary OS process on the host. Remote Control only relays the conversation ("Execution and filesystem access stay on your machine" [RC]), so a phone connecting or disconnecting does not affect children. That they are unaffected is an inference from the architecture; no doc states it for `claude -p` children specifically.
- The device "shows any subagents and workflows the session already has running in the background. Stop one of them from the device, and Claude Code stops that task on your machine" [RC].
- If the chat process exits, children started as background commands die: "Changed exit to force-kill background commands still running 1.5 seconds after being asked to stop" [CL 2.1.300]. Detached commands (`setsid`, `timeout`) were also fixed to stop on exit [CL 2.1.257].
- Time limit on background commands [TR]:
  - "A local session you work in from a terminal, the desktop app, or the VS Code extension has no time limit on background commands."
  - In unattended sessions (a `-p` run, the Agent SDK, CI, a cloud session) the default is 30 minutes and the maximum 2 hours. In a `-p` run whose prompt is passed as text the default is 10 minutes. `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS` raise these.
  - So the **orchestrator** (`claude -p`) gets a 2-hour ceiling on each background worker it launches unless the variables are raised. This applies on any host, laptop included.
  - **Unverified:** whether a session spawned by `claude remote-control` server mode counts as "a local session you work in from a terminal" or as unattended. Server sessions have no interactive terminal (`/reload-plugins` "works only when the session runs in an interactive terminal; a session without one declines it" [RC]).
- A safer host for the chat is a background session under agent view's supervisor. There, "the background shell commands and background subagents Claude started in it carry over to its next process" across restarts, and sessions survive sleep [AV]. **Unverified:** whether a `--bg` / agent-view session can be connected to Remote Control. Neither page says.

### What has to stay running

- The `claude` process (server or interactive) and the machine, awake and online [RC], [H].
- "If you run `claude` from a terminal on a remote machine, start it inside `tmux` or `screen`" [RC].
- Network loss: server mode "gives up after roughly 10 minutes and the `claude remote-control` process exits". An interactive session retries for as long as the outage lasts [RC]. 403s from a VPN/proxy are retried for up to three minutes [RC].
- Sleep: interactive sessions reconnect on wake [RC]. One fix: "Fixed Remote Control sessions started with `claude remote-control` stopping mid-turn when the Mac went to idle sleep" [CL 2.1.287]. Whether Claude Code keeps a Mac awake while it works is **unverified** (a 2.1.83 entry mentions a `caffeinate` process, with no current doc). Lid-closed sleep is macOS behaviour outside these sources.
- A crashed server session comes back when you message it from a device [RC].
- Updates: if the binary is replaced, new sessions use the new version; restart the server to move it over [RC].
- The sign-in must stay valid: a Remote Control session "that outlives the login stops making progress once the credential expires" [AUTH].

### How permission prompts reach the phone

- "Claude Code keeps permission prompts and `AskUserQuestion` questions open until you answer them". Other forwarded dialogs expire after five minutes by default (`dialogExpiry`) [RC].
- Push: in `/config`, enable **Push when actions required** (permission prompts and questions) and/or **Push when Claude decides** [RC]. Pushes are skipped while you're at the terminal, and `CLAUDE_CLIENT_PRESENCE_FILE` extends that [RC].
- A viewer that connects after a prompt appeared still sees it [CL 2.1.217].
- Not forwarded: the Fable usage-credits consent prompt. Unanswered at the host, the turn ends [RC].
- Headless children: a `-p` run with no permission host denies anything that would prompt; `--permission-prompts none` also removes `AskUserQuestion` and tells Claude not to retry [HL]. **Only the Engineering chat's prompts can reach the phone.** Worker and orchestrator approvals have to be pre-decided by permission mode and rules.

## 2. Cloud VM

### Is `claude` present and authenticated?

- Claude Code itself runs in the VM: the setup script "runs when a new cloud session starts, before Claude Code launches" [CE].
- The **Installed tools** table (Python, Node, …, "git, gh, jq, yq, ripgrep, tmux, vim, nano") does not list `claude` [CE].
- The CHANGELOG treats a nested `claude -p` in a cloud session as supported:
  - "Fixed artifact operations failing in a Claude Code run started from inside a cloud session (for example `claude -p` run from the Bash tool)" [CL 2.1.290]
  - "Fixed `claude -p` inside cloud sessions reporting 'Not logged in' when started without the session's environment variables" [CL 2.1.306]. Auth comes from the session's environment, and the fix covers a child started without it.
  - "Fixed `claude -p` run inside a cloud or self-hosted runner session sharing that session's ID ..." and "... generating a title of its own and sending it to that session" [CL 2.1.317]
- Cloud sessions authenticate with OAuth only and ignore `ANTHROPIC_API_KEY` / `apiKeyHelper` [AUTH]. A nested run therefore bills the same plan [WEB], [COST] (inference).
- **Unverified:** that `claude` is on `PATH` (vs. an absolute path), and which version the VM runs. The docs give per-feature minimums "in the session's environment" [WEB], which implies it varies.

### Do caps and JSON output work there?

`--max-turns`, `--max-budget-usd`, `--output-format json` and `--json-schema` are print-mode CLI flags [CLI], [H]. Nothing documents a cloud-specific difference. **Unverified in a cloud VM.** Note: `--max-turns` is documented [CLI] but missing from v2.1.322's `claude --help` output [H].

Constraints that apply to nested runs in the cloud:

- Background commands: 30 min default, 2 h maximum, raisable with `BASH_*_TIMEOUT_MS` set as environment variables on the cloud environment [TR], [CE]. A worker running longer than that as a background command is stopped.
- The nested run does not get the owner's plugins unless it loads them: `--plugin-dir <path>` or `--plugin-url <url>` load a plugin "for this session only" [H]. Fetching a plugin from GitHub inside the VM goes through the GitHub proxy (REST/git only, attached repos only) [CE]. **Unverified** end to end.
- `gh issue` / `gh pr` get a GraphQL 403 through the proxy; use `gh api` REST [CE] (from #30).
- Whether the cloud session's auto-mode classifier lets Claude run `claude -p ... --permission-mode ...` from Bash is **unverified**.
- How a long-running nested child interacts with the cloud idle pause ("after a few minutes without activity" [CE]) is **unverified**.

### Can in-session subagents use worktrees there?

- "Subagents work the same way they do locally ... subagents defined in your repo's `.claude/agents/` load automatically" [WEB].
- `isolation: worktree` makes a temporary git worktree, branched by default from the remote default branch [SA]. Git and `origin` exist in the VM [CE]. Nothing on [CE] or [WEB] mentions worktree isolation either way. **Unverified.** Indirect evidence: "Fixed cloud sessions reporting uncommitted changes every turn after Claude moved a branch to a commit it had pushed from another worktree" [CL 2.1.314].
- Subagents in a cloud session lose the per-worker caps that `-p` gives (`--max-budget-usd`, `--max-turns`, result JSON); those flags are print-mode only [CLI]. A subagent's `maxTurns` frontmatter exists [SA], but no per-subagent dollar cap is documented.
- After a VM reclaim, running subagents are not restored [WEB] (from #30).

## 3. Account-enabled (claude.ai) skills and plugins

### Skills

- Cloud sessions and cloud scheduled tasks "load the skills enabled for your claude.ai account, synced at session start" [SK]. In a project's cloud threads this is the only route; repo `.claude/skills/` aren't loaded there [SK], [PROJ].
- Upload rules: an uploaded skill may only use `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`, and "If you include any field the spec doesn't allow, packaging or upload fails with a hard error" [SK]. Upstream `/implement` uses `disable-model-invocation: true` (#30), so it cannot be uploaded as a lone skill unchanged.
- Synced skills are named `anthropic-skills:<name>`, or `/<name>` while nothing else uses the short name [SK].
- Updating: "To change a synced skill, update it on claude.ai; the next sync downloads the new version". Synced copies are download-only [SK]. No version pinning is documented for account skills.

### Plugins (the better fit for "our plugin and upstream's")

- Add on claude.ai at **Customize > Plugins** by **Discover**, **Add > Add marketplace** (GitHub/GHE repos; a private GitHub repo needs the Claude GitHub App), or **Add > Upload plugin** (a zip containing one `.claude-plugin/plugin.json`) [CP]. Limits: 25 self-added marketplaces, 5,000 files / 200 MB per plugin [PS].
- Components: skills, commands, agents and hooks load in Claude Code. A plugin with a top-level `bin/` directory "Can't be installed" on claude.ai [PS], [PL].
- Terminal sessions pick up account plugins as `<name>@synced` [DP], [PL].
- Cloud sessions: the CHANGELOG says so, the cloud-environments page does not.
  - "runs in Anthropic's cloud now load the plugins enabled on your claude.ai account" (scheduled tasks) [CL 2.1.314]
  - "Fixed SessionStart hooks from synced plugins not running in new cloud sessions" [CL 2.1.287]
  - "a new conversation's first turn no longer waits for the local (stdio) MCP servers of plugins synced from claude.ai" [CL 2.1.304]
  - [CE]'s "what carries over" table lists only user-settings and repo-declared plugins (both "No") and is silent on account plugins. Project threads load plugins from **Project settings > Plugins** [PROJ].
- Updating:
  - "plugins from a marketplace or the directory update from their source ... you get it on your account automatically". For a marketplace you added, use **Check for updates**, or for a github.com marketplace turn on **Sync automatically** [CP].
  - For a claude.ai-hosted marketplace, "the version claude.ai records for the plugin is its version, and the manifest's `version` isn't read" [PL].
  - In a terminal, sync runs once per start in the background; mid-session changes need `/reload-plugins` or a restart [PL].
  - How an uploaded zip is updated (re-upload replaces it?) is **unverified**.
- Upstream plugins (e.g. `mattpocock-skills`) could be added the same way by adding their GitHub marketplace on claude.ai [CP]. **Unverified** that a third-party public marketplace syncs into cloud sessions the same way as one's own.

## 4. Always-on host (Mac mini or an owner-controlled VM)

### Auth

- Remote Control needs a full claude.ai sign-in via `/login` / `claude auth login`. "These tokens [from `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`] can only make model requests, so they can't establish Remote Control sessions" [RC], [AUTH]. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`, `ANTHROPIC_BASE_URL` gateways and Bedrock/Vertex/Foundry all block it [RC].
- Credential storage: macOS Keychain, falling back to `~/.claude/.credentials.json` (mode 0600) when the Keychain is locked, "such as when it's locked in an SSH session". On Linux it is always that file [AUTH].
- Expiry: a warning shows 3 days before; "Renewing early matters most for sessions that run unattended. A background session in agent view or a Remote Control session that outlives the login stops making progress once the credential expires" [AUTH]. The laptop's current login shows `loginExpiresAt` about 30 days out [L]. The login lifetime itself is not documented (**unverified**).
- `setup-token` (one year, model requests only) is fine for the `claude -p` orchestrator and workers, but not for the Remote Control chat [AUTH]. Synced skills and plugins don't sync for sessions using `CLAUDE_CODE_OAUTH_TOKEN` [SK], [PL]. Workers that need the plugin then need it installed locally or loaded with `--plugin-dir`.
- Trusted Devices (optional on Max): the CLI machine "receives its own credential automatically when the developer signs in"; viewing devices need a sign-in under 18 hours old or a biometric step-up [RC].

### gh credentials

- The pipeline uses the `gh` CLI (`CLAUDE.md`). The laptop's `gh` stores tokens in the OS keyring [L]. On a headless host, a locked or missing keyring would need `GH_TOKEN` or file storage. That is `gh` behaviour, outside these sources (**unverified** here).
- Unlike the cloud, a local host has no GitHub proxy, so `gh issue` / `gh pr` (GraphQL) work as on the laptop [CE] (contrast).

### Plan usage

- Everything draws on one plan: cloud sessions "share rate limits with all other Claude usage on the account" [WEB]. Local `claude -p` with a claude.ai login uses the subscription [AUTH]. A Max plan has session and weekly windows ("You've hit your session limit" / "weekly limit") [COST].
- `--max-budget-usd` checks "client-side cost estimate[s]", not plan quota [CLI]. It caps a run, not the plan.
- Projects have **Auto-continue when usage limits reset** [PROJ]. No equivalent is documented for a local Remote Control chat (**unverified**).

### Keeping sessions alive

- Run `claude remote-control` (or `claude --remote-control`) in `tmux`/`screen` [RC]. No doc covers launchd/systemd for it (**unverified**). Server mode exits after about 10 minutes offline, so a supervisor that restarts it would be needed [RC].
- Agent view's supervisor keeps `--bg` sessions alive with no terminal, carries background shells over restarts, survives sleep and auto-update. Shutdown stops sessions [AV]. Its interaction with Remote Control is **unverified** (see Q1).
- Background command ceilings (2 h in `-p`) apply on the host too; set `BASH_MAX_TIMEOUT_MS` where long workers are expected [TR].

### Security

- "Your local Claude Code session makes outbound HTTPS requests only and never opens inbound ports". It uses short-lived, single-purpose credentials [RC].
- "While Remote Control is connected, the session transcript ... is stored on Anthropic servers" [RC].
- Anyone holding the claude.ai account (or a signed-in phone) can steer the host. Trusted Devices narrows this to enrolled devices with recent sign-in [RC]. `disableRemoteControl` turns it off [RC].
- `claude remote-control --permission-mode` sets the starting mode for spawned sessions. `--settings` for spawned sessions should be kept "where sessions can't write" [H]. Sandboxing is via a settings file (the `--sandbox` flag was removed in 2.1.300) [RC].
- The host holds a full-scope claude.ai login plus `gh` credentials for the repos, and workers run with whatever permission mode the orchestrator gives them. On an always-on box that is a standing credential. No doc assesses this; it is a judgement for the decision.

## Trade-offs

| | (A) Always-on host + Remote Control | (B) Cloud session |
| --- | --- | --- |
| Pipeline changes | None: same plugin, same `claude -p` caps and JSON [CLI] | Plugin must be on the claude.ai account (CHANGELOG-only for cloud) or reloaded per nested run; `gh` GraphQL → REST [CE] |
| Per-worker caps and JSON result | Yes [CLI] | Only via nested `claude -p` (CHANGELOG-supported, unverified end to end); not for subagents |
| Worktrees | As today | Subagent `isolation: worktree` undocumented in cloud |
| Phone steering | Remote Control; chat prompts forwarded and push-notified [RC] | Native at claude.ai/code [WEB] |
| What must stay up | Host, `claude` process, network, valid `/login` [RC], [AUTH] | Nothing local [WEB]; but idle pause/reclaim and undocumented max length (#30) |
| Background worker ceiling | 2 h per command in `-p`, raisable [TR] | Same, raisable via environment variables [TR], [CE] |
| Cost | Hardware + same plan | Same plan [WEB] |
| Security | Standing credentials on a box you run | Credentials kept out of the VM by proxy [CE] |

## Open / unverified

1. Whether a `claude remote-control` server-mode session counts as interactive (no background-command limit) or unattended (30 min / 2 h) [TR].
2. Whether an agent-view `--bg` session can be put on Remote Control.
3. Whether Claude Code keeps a Mac awake while working (only an old `caffeinate` fix [CL 2.1.83]). Lid-closed behaviour is macOS, outside these sources.
4. `claude` on `PATH` in the cloud VM, its version, and a live `claude -p --max-turns --max-budget-usd --output-format json` run there. Only CHANGELOG fixes attest to it [CL 2.1.290, 2.1.306, 2.1.317].
5. Whether the cloud auto-mode classifier allows Bash to start nested `claude -p` runs, and how a long nested child interacts with idle pause.
6. Subagent `isolation: worktree` in a cloud session.
7. Account plugins in interactive cloud sessions: CHANGELOG yes [CL 2.1.287, 2.1.304, 2.1.314], cloud-environments page silent. Also how an uploaded-zip plugin is updated.
8. claude.ai login lifetime (about 30 days observed [L], not documented).
9. launchd/systemd supervision for `claude remote-control`. Not documented.

A cheap live test would close 1, 2, 4, 5 and 6, but this ticket forbade starting sessions.
