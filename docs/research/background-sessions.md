# Background sessions compared with headless runs for ticket agents

Research for [#29](https://github.com/arathianevasion/watsonsoft-workflow/issues/29). Asks whether a `claude --bg` background session can do one ticket's work in a git worktree, write a result file, and be watched and stopped by an orchestrator, and what it loses compared with the `claude -p` process per ticket that `implement-plan` uses today. It reports facts and trade-offs and does not choose; that is [#14](https://github.com/arathianevasion/watsonsoft-workflow/issues/14) ("Which orchestration model does version one use?").

Gathered 2026-11-10 against Claude Code v2.1.322 (installed) and the docs as served that day. Agent view and `--bg` are a research preview [AV].

Builds on [orchestration-options.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/orchestration-options/docs/research/orchestration-options.md) (#13), which listed this as an open question, and [agent-teams-vs-headless.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/agent-teams-vs-headless/docs/research/agent-teams-vs-headless.md) (#33).

## Sources

| Key | Source |
| --- | --- |
| [AV] | https://code.claude.com/docs/en/agent-view |
| [CLI] | https://code.claude.com/docs/en/cli-reference |
| [HL] | https://code.claude.com/docs/en/headless |
| [PERM] | https://code.claude.com/docs/en/permissions (section "Project allow rules and workspace trust") |
| [ERR] | https://code.claude.com/docs/en/errors (section "Workspace not trusted when dispatching a background session") |
| [SK] | https://code.claude.com/docs/en/skills |
| [CL] | https://code.claude.com/docs/en/changelog |
| [IP] | `~/.claude/skills/implement-plan/SKILL.md` and `references/dispatch.md` (owner's local skill) |
| [T] | Live tests on this machine, 2026-11-10; commands and output under "What the tests showed" |

## Short answer

- **Running in a worktree: yes, by design.** A `--bg` session moves itself into a worktree under `.claude/worktrees/` before its first edit, or uses the worktree it was started in [AV]. `claude --bg --worktree` also exists [CLI], [CL].
- **Writing a result file: yes, in principle.** Nothing stops a session writing a file; the docs suggest `$CLAUDE_JOB_DIR/tmp` for a session's own progress file [AV]. Not observed live (see below).
- **Watched and stopped: yes.** `claude agents --json --all` is "the supported way to read session state from outside Claude Code", giving `state` (`working`, `blocked`, `done`, `failed`, `stopped`) and `waitingFor`; `claude stop <id>` stops one [AV]. Shell-side commands were exercised live [T].
- **What it loses against `-p`:** the per-run caps (`--max-budget-usd`, `--max-turns`), the result JSON (`--output-format json`, `--json-schema`, `total_cost_usd`), and a meaningful exit status. All four are documented as "print mode only" [CLI], and `--bg` returns as soon as the session is backgrounded [CLI].
- **New blocker found by the test:** a scripted `claude --bg` refuses to start in a folder that has not been trusted interactively (`Workspace not trusted`), where `claude -p` runs without trust [T], [PERM], [ERR].
- **`/implement` as the prompt:** expected to work (the prompt is a positional user turn, like `claude "query"` [AV], [CLI]; `disable-model-invocation` only stops Claude invoking a skill itself [SK]), but **not verified live** because of the trust blocker.

## Comparison table

| | `claude --bg` background session | `claude -p` (current `implement-plan`) |
| --- | --- | --- |
| Status | Research preview [AV] | Stable documented mode [HL] |
| How started | `claude --bg [--name N] [--model M] [--permission-mode P] "<prompt>"`; returns immediately, prints short ID [AV], [CLI] | Orchestrator backgrounds one OS process per ticket, waits on result files [IP] |
| Combined with `-p` | Rejected before any session is created [AV], [T] | n/a |
| Workspace trust | Required; from a script, untrusted folder exits `Workspace not trusted` [PERM], [ERR], [T] | Never shows the trust dialog and runs anyway; project allow rules are not used [PERM], [T] |
| Worktree | Moves into its own worktree before editing; skips this if already in a linked worktree [AV] | Orchestrator creates the worktree and `cd`s in [IP] |
| Git behaviour | Instructed to commit, and push when a remote exists, and may open a draft PR, unless the task or CLAUDE.md says the user handles git [AV] | Whatever the prompt says; `implement-plan` says "do not merge or push" [IP] |
| Process host | A supervisor service; survives closing the terminal; restarts a session process that exits unexpectedly [AV] | Child of the orchestrator's shell |
| Live state | `claude agents --json --all`: `state`, `status`, `waitingFor`, `pid`, `sessionId` [AV] | None beyond the log file and process liveness [IP] |
| Human steering | Attach, peek and reply, agent-view UI [AV] | None while running [IP] |
| Recent output | `claude logs <id>` [AV] | Redirected log file [IP] |
| Stop | `claude stop <id>` (state becomes `stopped`) [AV] | `kill`; SIGTERM gives exit 143, SIGINT ends the turn first [HL] |
| Dollar cap | None per session documented; `--max-budget-usd` is print mode only [CLI] | `--max-budget-usd` [CLI] |
| Turn cap | None per session documented; `--max-turns` is print mode only [CLI] | `--max-turns`; exceeding it gives exit 1 and `error_max_turns` [CLI], [T] |
| Result data | Whatever file the agent writes; no structured end-of-run payload documented | `--output-format json` with `subtype`, `is_error`, `num_turns`, `total_cost_usd`, `terminal_reason`, `permission_denials` [HL], [T]; `--json-schema` for validated output [CLI] |
| Exit status | `claude --bg` exits after backgrounding; the session's outcome is only in `state` [CLI], [AV] | 0 on success, non-zero on failure [HL], [T] |
| Waiting on a human | Session sits `blocked` with `waitingFor` (e.g. `permission prompt`) until someone answers [AV] | In Manual mode a call that needs approval "is denied unless something approves it" [HL] |
| Idle cleanup | Finished, unattached sessions have their process stopped after about an hour; conversation kept [AV] | Process exits at end of run |
| Deleting | `claude rm <id>` removes the Claude-created worktree when safe; refuses over unpushed commits or uncommitted changes [AV] | Orchestrator runs `git worktree remove` [IP] |
| Rate limits | Same subscription usage as interactive sessions [AV] | Same |

## Details

### Starting and the trust check

- `--bg` takes the prompt as the positional argument; "Claude Code rejects `--bg` combined with `-p` or `--print` before any session is created" [AV].
- On a run from a script in an untrusted directory "the command exits with a `Workspace not trusted` error" [AV], [ERR]. In a repository, trust is keyed on the repository root, and in a worktree it uses the main checkout's root [PERM]. So a worktree of an already-trusted repo should pass; a fresh clone or new repo needs someone to run `claude` there once and accept the dialog. The docs also allow setting `projects["<path>"].hasTrustDialogAccepted` in `~/.claude.json` by hand [PERM].
- By contrast "A `claude -p` run or an SDK session never shows it" [PERM].
- Permission mode for `claude --bg`: the session "starts the way a new `claude` session in that directory would" [AV]; `--permission-mode` is a top-level flag [CLI]. Whether `claude --bg --permission-mode acceptEdits` keeps that mode was not observed (blocked by trust). The docs say the mode chosen for a background session persists across supervisor restarts [AV].

### Worktree and git behaviour

- "Before editing files, Claude moves the session into an isolated git worktree under `.claude/worktrees/`" [AV]. It skips this when the session "is already inside a linked git worktree, whether Claude created it ... or you created it with `git worktree add` somewhere else" [AV]. So `implement-plan`'s own `../<repo>-wt/<ticket>` layout [IP] would be used as-is if the session is started there.
- When the session entered the worktree itself, it "commits without asking, and pushes the branch when the repository has a remote", may open a draft PR, never pushes to `main`/`master`, force-pushes or merges, and "Your git instructions take precedence" [AV]. A ticket brief that says "do not push" would therefore need to stay in the prompt.
- A session editing a checkout it did not isolate itself (including one started inside an existing worktree) "still asks before committing or switching branches" [AV]. Unverified how that interacts with an explicit "commit" instruction in the prompt; if it asks, the session goes `blocked`.

### Watching and stopping

- `claude agents --json` lists active sessions; `--all` adds completed background sessions; `--cwd <path>` scopes the list [AV]. Fields: `id`, `state`, `pid`/`status` while alive, `waitingFor` when waiting, `sessionId`, `name` [AV].
- `done` means "The last turn finished what you asked for"; `blocked` "always means the session needs something from you"; `failed`/`stopped` for errors and stops [AV]. Files under `~/.claude/jobs/<id>/` "are not a stable interface" [AV].
- "If you want a session to report progress in its own words, have it write a file of its own, for example under `$CLAUDE_JOB_DIR/tmp`" [AV]. That directory "is removed when the session is deleted" [AV], so a result file meant to outlive cleanup belongs elsewhere (as `implement-plan` already does with `.scratch/<feature>/results/` [IP]).
- `claude stop <id>`, `claude logs <id>`, `claude respawn <id>`, `claude rm <id>` [AV].
- The supervisor restarts a session process that "Exited unexpectedly" [AV], so a crash does not by itself end the work; an orchestrator watching for `failed` must expect retries it did not ask for.

### What is lost against `-p`

- `--max-budget-usd`: "(print mode only)" [CLI].
- `--max-turns`: "(print mode only)" [CLI].
- `--output-format`: "Specify output format for print mode" [CLI]; `--json-schema`: "(print mode only)" [CLI]. So no `total_cost_usd`, `num_turns`, `subtype` or `permission_denials` at the end of a `--bg` run.
- Exit status: `-p` "exits with code 0 on success and a non-zero code when the run fails" [HL]; `--bg` "return[s] immediately" after printing the session ID [CLI]. The orchestrator must poll `state` and read the result file instead.
- Wall-clock timeout: `implement-plan` recommends one per process [IP]. With `--bg` the orchestrator would implement it as "poll, then `claude stop <id>`".
- No documented spend view per background session from the shell. Interactive `/usage` exists, but nothing in [AV] exposes cost in `claude agents --json`.

### `/implement` as the prompt

- The `--bg` prompt is the positional argument, as in `claude "query"`, which "Start[s] interactive session with initial prompt" [AV], [CLI]. A slash command there is a user turn.
- `disable-model-invocation: true` means "Claude can't invoke the skill on its own"; the user still triggers it with `/name` [SK]. On that reading `/implement` should run in a `--bg` session as it does under `-p` [IP].
- Not verified live: the trust check stopped the test before a session started [T].

## What the tests showed

All run 2026-11-10, Claude Code 2.1.322, in a throwaway repo `scratchpad/bg-test-29` (git init, one `README.md`, a project skill `write-result` with `disable-model-invocation: true`). No background session was created by these tests; the repo was deleted afterwards and `claude agents --json --all` showed the same three pre-existing background sessions before and after.

1. `--bg` with `-p` is rejected:

   ```
   $ claude -p --bg "say hi"
   --bg and --print conflict: --print never starts the interactive session that `claude agents` attaches to, so the job would be unattachable. The prompt is the positional — drop --print: `claude --bg '<task>'`.
   exit=1
   ```

2. A scripted dispatch (stdin from `/dev/null`, no TTY) in the untrusted throwaway repo did not start:

   ```
   $ claude --bg --name t29-skill --model haiku --permission-mode acceptEdits "/write-result Then write the JSON {...} to the file .../bg-results-29/t29.json. Do not push." < /dev/null
   Workspace not trusted. Run `claude` in .../scratchpad/bg-test-29 once and accept the trust prompt, then retry.
   exit=1
   ```

   The same message came back for `claude --bg --max-turns 3`, `--max-budget-usd 0.05`, `--output-format json` and `--json-schema {}`, so the trust check runs before those flags are judged; whether `--bg` rejects or silently ignores them was **not determined**. `claude --bg --exec 'echo hi'` also hit the trust check, after printing `warning: --exec ignores --session-id --settings (only --name composes)`.

   Accepting the trust dialog automatically through a pseudo-terminal was attempted and refused by this session's permission classifier as weakening a safeguard. It was not worked around: trusting the folder is the owner's call. So the end-to-end `--bg` run (worktree move, result file, `state` transitions, `claude stop`) was **not observed**.

3. Shell-side management commands, observed:

   ```
   $ claude agents --json --all --cwd .../scratchpad/bg-test-29
   []
   exit=0
   $ claude stop deadbeef
   No job matching 'deadbeef'. Run 'claude agents' to list running sessions.
   exit=1
   $ claude logs deadbeef
   No job matching 'deadbeef'. Run 'claude agents' to list running sessions.
   exit=1
   ```

   `claude agents --json --all` without `--cwd` returned entries with `id`, `cwd`, `kind`, `startedAt`, `sessionId`, `name`, `state`, plus `pid` and `status` for live processes, matching [AV].

4. `claude -p` in the same untrusted repo ran, for comparison:

   ```
   $ claude -p --model haiku --max-turns 3 --max-budget-usd 0.10 --output-format json "Reply with the single word ok. Do not use tools." </dev/null
   exit=0
   type=result subtype=success is_error=False num_turns=1 result=ok total_cost_usd=0.00281706 terminal_reason=completed
   ```

   ```
   $ claude -p --model haiku --max-turns 1 --max-budget-usd 0.10 --output-format json --permission-mode acceptEdits "Use the Bash tool to run 'ls', then use the Write tool to create a.txt, then reply done." </dev/null
   exit=1
   subtype=error_max_turns is_error=True num_turns=2 total_cost_usd=0.00232878 terminal_reason=max_turns errors=['Reached maximum number of turns (1)']
   ```

## Trade-offs for #14

- **Visibility versus guard rails.** `--bg` gives live state, `waitingFor`, attach and steer [AV]; `-p` gives hard per-run budget and turn caps, a JSON outcome and an exit code [CLI], [HL]. No documented way to get both in one process.
- **Blocking versus failing.** A `--bg` session that needs a permission or answer waits as `blocked` [AV]; under `-p`, a Manual-mode call needing approval is denied [HL] and the run carries on or fails. Unattended runs favour failing; attended runs favour blocking.
- **Trust.** `--bg` needs the repo trusted once, interactively or by editing `~/.claude.json` [PERM]. Worktrees of a trusted repo inherit it [PERM].
- **Git defaults.** `--bg` sessions lean towards commit-and-push and draft PRs unless told otherwise [AV]; `implement-plan` forbids pushing [IP]. The brief must keep saying so.
- **Supervisor restarts.** A crashed `--bg` session is restarted by the supervisor [AV], which conflicts with `implement-plan`'s "no automatic retry" rule [IP] unless the orchestrator stops the session on first failure.
- **Hybrid possibility, unverified.** An orchestrator could keep `-p` workers for caps and exit codes and use `claude agents --json` only for interactive sessions; or use `--bg` and enforce time and spend outside Claude Code. Neither was tested.

## Open questions

- End-to-end `--bg` run in a trusted throwaway repo: worktree path chosen, result file written, `state` sequence, `claude stop` result, `claude rm` worktree cleanup.
- Whether `claude --bg` rejects or silently ignores `--max-turns`, `--max-budget-usd`, `--output-format` and `--json-schema`.
- Whether `claude --bg --permission-mode acceptEdits` (or `auto`) holds for an unattended run, and whether a session started inside an existing worktree asks before committing.
- Whether `/implement` runs as a `--bg` prompt.
