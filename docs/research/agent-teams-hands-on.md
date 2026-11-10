# Agent teams: hands-on test of three open points

Research for [#36](https://github.com/arathianevasion/watsonsoft-workflow/issues/36). Follows [agent-teams-vs-headless.md](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/agent-teams-vs-headless/docs/research/agent-teams-vs-headless.md) (#33), which left three points unconfirmed:

1. Can a teammate isolate itself with `EnterWorktree`?
2. Does a teammate honour `maxTurns` from its subagent definition?
3. Is a spawn prompt that starts with `/skill` expanded?

Gathered 2026-11-10 with Claude Code v2.1.322 (`claude --version`).

## Results

| Test | Result |
| --- | --- |
| 1. `EnterWorktree` from a teammate | **Not yet observed.** Needs the hand-run checklist below. |
| 2. `maxTurns` from the definition | **Not yet observed.** Needs the hand-run checklist below. |
| 3. `/skill` at the start of a spawn prompt | **Not yet observed.** Needs the hand-run checklist below. |

None of the three can be tested from an unattended process, because a team cannot form in `-p` mode (confirmed below). Driving an interactive TUI from a script was ruled out for this ticket. The owner has to run the checklist by hand.

## Sources

| Key | Source |
| --- | --- |
| [AT] | https://code.claude.com/docs/en/agent-teams |
| [SA] | https://code.claude.com/docs/en/sub-agents |
| [TR] | https://code.claude.com/docs/en/tools-reference |

## Confirmed: `-p` sessions don't spawn teammates

The docs say: "Spawning teammates also requires an interactive session. In non-interactive mode with the `-p` flag, including Agent SDK sessions, Claude doesn't spawn teammates, and a subagent that Claude names runs as an ordinary subagent even with agent teams enabled." [AT]

**Observed.** I ran one capped attempt in an empty throwaway directory, with the variable set only for that one command:

```bash
cd <scratch>/at-test
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude -p "Spawn one agent teammate named probe (use the Agent tool with name \"probe\", subagent_type general-purpose) whose only task is to reply with the word PONG. Then tell me in one line whether it ran as an agent team teammate or as an ordinary subagent, and quote any text the Agent tool returned." \
  --max-turns 5 --max-budget-usd 0.50 --model sonnet --output-format stream-json --verbose > out.jsonl
```

What the stream showed:

- The lead called `Agent` with `{"name": "probe", "subagent_type": "general-purpose", ...}`.
- The `task_started` event had `"task_type": "local_agent"`, `"is_backgrounded": true` and `"spawn_depth": 1`. That is an ordinary background subagent.
- `probe` finished by calling `SubagentHandback`, which is the subagent's report tool, not `SendMessage` to a lead.
- No `~/.claude/teams/` directory was created (`ls ~/.claude/teams` gave "No such file or directory"). A real team writes its config to `~/.claude/teams/{team-name}/config.json` [AT].
- Exit 0, total cost about $0.11.

This matches the docs. The throwaway directory was then deleted. No settings file was changed.

## What the docs already say about each test

### 1. `EnterWorktree`

- `EnterWorktree` "Creates an isolated git worktree and switches into it, or switches into an existing worktree" [TR].
- Restrictions listed: from inside a worktree, or in "a subagent with a pinned working directory, such as `isolation: worktree`", only the `path` form works, and the target must be under `.claude/worktrees/`. The tool is removed once `permissions.blockWritesOutsideWorkingDirectories` is on [TR]. Teammates are not mentioned.
- Teammates run in the lead's working directory. A definition's `isolation` field doesn't stop the teammate from launching, "and the teammate then runs in the main session's working directory" [SA].
- An in-process teammate runs inside the lead's process [AT]. **Open risk (inferred, not documented):** if `EnterWorktree` changes the process working directory, it might move the lead or other teammates too. The checklist below looks for this.

### 2. `maxTurns`

- `maxTurns`: "Maximum number of agentic turns before the subagent stops. When the subagent reaches the limit, Claude Code returns its output marked as partial" [SA].
- The list of definition parts applied to a teammate is `tools`, `model`, `disallowedTools`, `effort`, `autoCompactWindow`, body, `skills` (explicitly not applied) and `mcpServers` (split-pane only). `maxTurns` is not in the list [AT].

### 3. `/skill` in a spawn prompt

- "A teammate also receives the spawn prompt from the lead." [AT] Nothing says whether that prompt is processed for commands or skills.
- The only documented place where an agent's prompt gets command and skill processing is `initialPrompt`, and only "when this agent runs as the main session agent (via `--agent` or the `agent` setting)" [SA].
- Typing does work: "While you're viewing an in-process teammate, plain text and skills go to that teammate" [AT].

## Checklist for the owner

This takes about 15 minutes and should cost less than $1 on Sonnet. Run it in a real terminal, not inside another Claude session. The variable is set only on the `claude` command, and no settings file is touched.

### Setup

```bash
mkdir -p ~/tmp/at-hands-on && cd ~/tmp/at-hands-on
git init -q && git commit -q --allow-empty -m init
mkdir -p .claude/agents .claude/skills/canary

cat > .claude/agents/turn-capped.md <<'EOF'
---
name: turn-capped
description: Test agent for maxTurns. Only use when asked by name.
tools: Bash
model: sonnet
maxTurns: 2
---
Follow the spawn prompt exactly. Run each command as its own Bash call, one per turn.
EOF

cat > .claude/skills/canary/SKILL.md <<'EOF'
---
name: canary
description: Test skill for spawn-prompt expansion.
disable-model-invocation: true
---
Reply with exactly the text CANARY-EXPANDED-7731 and then stop.
EOF

CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model sonnet
```

Accept the folder-trust prompt. Project agent definitions apply only in a trusted folder [AT]. `canary` uses `disable-model-invocation: true`, the same setting as `/implement`, so the model cannot reach it through the Skill tool. Its marker text can only appear if the prompt was expanded or a person typed it.

Run the tests in this order. Test 1 goes last because it may move the working directory.

For each test, check that a **teammate** formed and not a subagent. The agent panel shows both, so the panel alone isn't proof [AT]. In a second terminal, run:

```bash
cat ~/.claude/teams/session-*/config.json
```

The new name should appear in `members`.

### Test 3: `/skill` in the spawn prompt

Prompt the lead:

> Spawn one agent teammate named sk, general-purpose, with a spawn prompt that is exactly the text `/canary` and nothing else. Do not add words, do not pass isolation, do not run the skill yourself.

Check the Agent call in the lead's transcript (Ctrl+O) to confirm the `prompt` was exactly `/canary`. Then open `sk` with the arrow keys and Enter, and read its transcript.

| You see | Meaning |
| --- | --- |
| `sk` replies `CANARY-EXPANDED-7731`, and its transcript shows the skill content loaded as its first turn | **Expanded.** A spawn prompt can run a `disable-model-invocation` skill. |
| `sk` treats `/canary` as plain text, tries the Skill tool and is blocked, or says it doesn't know the command; no marker | **Not expanded.** A teammate can't start `/implement` from its spawn prompt. |
| The lead rewrote the prompt | Inconclusive. Repeat and insist on the exact text. |

Control: while viewing `sk`, type `/canary` yourself. The docs say this goes to the teammate [AT], so the marker should appear. That confirms the skill itself works.

### Test 2: `maxTurns` from the definition

Prompt the lead:

> Spawn one agent teammate named capped using the turn-capped agent type, with this prompt: "Run these six commands as six separate Bash calls, one per turn, never batched: echo step1, echo step2, echo step3, echo step4, echo step5, echo step6. After all six, reply DONE."

Check that `config.json` shows `capped` with agent type `turn-capped`. Then watch the transcript and the lead's notification.

| You see | Meaning |
| --- | --- |
| `capped` stops after about 2 tool calls; the lead's notification is marked partial or names a turn limit; no DONE | **Honoured.** |
| All six echoes run and it replies DONE | **Not honoured.** A teammate has no turn cap from its definition. |
| It batched the echoes into one call | Inconclusive. Repeat with clearer wording. |

Optional control: ask the lead to run the same prompt as an ordinary subagent with no name, using the turn-capped agent type. It should stop as partial [SA].

### Test 1: `EnterWorktree` from a teammate

Before you start, run `pwd` in the lead (`! pwd`) and note the result. Then prompt the lead:

> Spawn one agent teammate named wt, general-purpose, without isolation, with this prompt: "Run pwd. Then call the EnterWorktree tool to create a new worktree. Then run pwd, git rev-parse --show-toplevel and git branch --show-current. Report all outputs verbatim, plus the exact EnterWorktree tool result or error text."

When `wt` reports, run `! pwd` and `! git branch --show-current` in the lead. In a second terminal, run:

```bash
git -C ~/tmp/at-hands-on worktree list
```

| You see | Meaning |
| --- | --- |
| `wt`'s second `pwd` is under `.claude/worktrees/...` on a new branch; the lead's `pwd` hasn't changed; `worktree list` shows the new worktree | **Works and is isolated.** A teammate can put itself in a worktree. |
| Same as above, but the lead's `pwd` or branch also changed | **Works but leaks.** Unsafe with in-process teammates. If you can, retry with `claude --teammate-mode tmux` (split panes, separate processes) [AT]. |
| `wt` says it has no `EnterWorktree` tool | **Not available** to teammates. |
| The call returns an error | **Refused.** Record the exact error text. |

### Cleanup

```text
Ask the sk, capped and wt teammates to shut down
/exit
```

```bash
git -C ~/tmp/at-hands-on worktree list   # remove any extra entries with: git -C ~/tmp/at-hands-on worktree remove --force <path>
rm -rf ~/tmp/at-hands-on
```

Claude Code removes `~/.claude/teams/session-*` when the session ends. `~/.claude/tasks/session-*` stays until cleanup [AT]. You can delete it by hand.

### Record the results

Paste each row's outcome and any error text into #36, and update the Results table above.
