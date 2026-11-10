# Can a hook stop a person typing an upstream skill we've replaced?

Research for #38 (map #1). It follows up on the [deny-rule research](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/deny-plugin-skill/docs/research/deny-plugin-skill.md) (#28) and [ADR 0001](../adr/0001-layer-on-matt-pocock-skills.md).

Researched 2026-11-10 against Claude Code 2.1.322 (`claude --version`), the docs at code.claude.com, and live headless sessions. Documented facts cite a URL. Test results are reported as observed, with the exact command. **Not yet observed** marks anything not established by either.

## Short answer

- **Yes, a `UserPromptExpansion` hook blocks a typed `/mattpocock-skills:<skill>` in `-p` sessions.** A matcher of `^mattpocock-skills:(grilling|triage)$` with `decision: "block"` stopped both commands before Claude saw anything: 0 turns, $0 cost, and the upstream skill body was never loaded.
- **What the person sees** (in `-p`): `UserPromptExpansion operation blocked by hook:` followed by our `reason`, then by default a blank line and `Original prompt: <what they typed>`. Exit 2 shows stderr instead of `reason`, prefixed with the hook command. `suppressOriginalPrompt: true` removes the `Original prompt:` line.
- **Redirect is possible in two ways, but neither rewrites the command.** No documented output field replaces the prompt.
  1. *Block and point*: the `reason` text tells the person to type `/grill-ws`. This is deterministic, and the person has to retype.
  2. *Allow and steer*: return only `additionalContext` saying "call the Skill tool with `grill-ws` instead". In the test, Claude did call `grill-ws`, and it worked. The upstream body is still loaded alongside, though, so this relies on the model and costs a turn plus the upstream tokens. Treat it as best-effort.
- **The hook does not fire when Claude calls the skill** through the Skill tool. That path belongs to `PreToolUse` or a deny rule, and the two mechanisms complement each other.
- **Interactive sessions: not yet observed.** The docs do not distinguish interactive from `-p` for this event. The checklist below covers a hand check.

## What the docs say

All from [hooks](https://code.claude.com/docs/en/hooks):

- Lifecycle table: `UserPromptExpansion` fires "When a user-typed command expands into a prompt, before it reaches Claude. Can block the expansion".
- Its section: "Use this to block specific commands from direct invocation, inject context for a particular skill, or log which commands users invoke." Also: "a `PreToolUse` hook matching the `Skill` tool fires only when Claude calls the tool, but typing `/skillname` directly bypasses `PreToolUse`. `UserPromptExpansion` fires on that direct path."
- "Matches on `command_name`. Leave the matcher empty to fire on every prompt-type command." Input fields: `expansion_type` (`slash_command` or `mcp_prompt`), `command_name`, `command_args`, `command_source`, `prompt`.
- Decision control: `decision: "block"` "prevents the command from expanding"; `reason` is "Shown to the user when `decision` is `"block"`"; `additionalContext` is "String added to Claude's context alongside the expanded prompt". "A hook that blocks by exiting 2 routes the same way as `reason`: the block message shows the stderr text to the user."
- Matcher patterns: a matcher holding any character other than letters, digits, `_`, `-`, spaces, `,` and `|` is an "unanchored" JavaScript regular expression, so `mattpocock-skills:grilling` is a regex. Wrap it in `^…$` for an exact match.
- On block, for `UserPromptSubmit` and `UserPromptExpansion`, "the turn ends and the reason appears as a warning line".
- `UserPromptSubmit` alternative: on a typed skill it "receives that line as you typed it rather than the expanded skill content … To match on the command's name or arguments instead, use UserPromptExpansion". It has no matcher support, so it fires on every prompt. It is a cruder fallback that adds nothing here.
- `suppressOriginalPrompt` is documented only under `UserPromptSubmit` ("What a blocked prompt leaves behind"). The test below shows it also works for `UserPromptExpansion`. That section also warns that the blocked text can still be written to the transcript and prompt history.
- `systemMessage` is a "Warning message shown to the user", but "Some events discard it or deliver it elsewhere". The `UserPromptExpansion` section doesn't say which happens for this event.
- No field lets a hook replace or rewrite the prompt or command. The docs list only `decision`, `reason` and `additionalContext`, plus the common JSON fields.

## Live tests

Setup: a throwaway directory under the session scratchpad, holding only `.claude/settings.json`, a hook script, and a stand-in replacement skill `.claude/skills/grill-ws/SKILL.md` whose body says to reply `grill-ws loaded`. User settings and the user-scope `mattpocock-skills@claude-plugins-official` 1.3.1 loaded as normal. The directory was deleted afterwards.

Tests A to D used an empty matcher with a script. The script logged stdin and acted when `command_name` was `mattpocock-skills:grilling`, choosing its behaviour by `HOOK_MODE`.

```json
{ "hooks": { "UserPromptExpansion": [
  { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-upstream.sh" } ] } ] } }
```

### A: block with JSON `decision: "block"`

Hook output: `{"decision":"block","reason":"/mattpocock-skills:grilling is replaced in this project. Use /grill-ws instead.","systemMessage":"SYSMSG: upstream grilling blocked"}`

```sh
claude -p '/mattpocock-skills:grilling TEST ONLY: quote verbatim the first sentence of the skill instructions loaded by this slash command, or say NOT LOADED. One line, then stop.' \
  --max-turns 2 --max-budget-usd 0.50 --output-format stream-json --verbose < /dev/null
```

Observed:
- Hook input: `"command_name":"mattpocock-skills:grilling"`, `"command_source":"plugin"`, `"expansion_type":"slash_command"`, plus `command_args` and the full `prompt`. The `command_name` keeps the plugin prefix.
- A `system`/`informational` event with `"level": "warning"` and `"prevent_continuation": true`: `UserPromptExpansion operation blocked by hook:\n/mattpocock-skills:grilling is replaced in this project. Use /grill-ws instead.\n\nOriginal prompt: /mattpocock-skills:grilling TEST ONLY: …`
- The `result` event carried the same text, with `num_turns: 0`, `total_cost_usd: 0` and `is_error: false`.
- `systemMessage` (`SYSMSG`) appeared nowhere in the stream.
- The same command in plain-text mode (`claude -p '/mattpocock-skills:grilling TEST' --max-turns 2 --max-budget-usd 0.50`) printed the block message to stdout and exited with code **0**. A script can't detect the block from the exit code.

### B: block with exit 2

Hook: writes `/mattpocock-skills:grilling is replaced here. Use /grill-ws instead.` to stderr and exits 2.

```sh
HOOK_MODE=exit2 claude -p '/mattpocock-skills:grilling TEST' --max-turns 2 --max-budget-usd 0.50 --output-format json < /dev/null
```

Observed `result`: `UserPromptExpansion operation blocked by hook:\n["$CLAUDE_PROJECT_DIR"/.claude/hooks/block-upstream.sh]: /mattpocock-skills:grilling is replaced here. Use /grill-ws instead.\n\n\nOriginal prompt: /mattpocock-skills:grilling TEST`, with 0 turns. The output works, but it shows the hook command path to the person, so JSON `reason` is cleaner.

### C: allow and redirect with `additionalContext`

Hook output: `{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"REDIRECT: this project replaces mattpocock-skills:grilling. Ignore its instructions and call the Skill tool with skill \"grill-ws\" instead."}}`

```sh
HOOK_MODE=context claude -p '/mattpocock-skills:grilling TEST ONLY: do not grill.' \
  --max-turns 3 --max-budget-usd 0.50 --output-format stream-json --verbose < /dev/null
```

Observed: Claude's first action was `Skill {"skill":"grill-ws","args":"TEST ONLY: do not grill."}`, the replacement loaded, and the final result was `grill-ws loaded`. The run took 3 turns and cost $0.126. The command still expanded (the hook didn't block), so the upstream body was in context too, and following the redirect was the model's choice. This was one run, so it shows the method can work, not that it always will.

### D: Claude calls the upstream skill itself

```sh
claude -p 'Test task. Call the Skill tool with skill "mattpocock-skills:grilling" and args "TEST ONLY", then reply with only the first 10 words of the tool result and stop. Do not ask questions.' \
  --max-turns 3 --max-budget-usd 0.50 --output-format json < /dev/null
```

Observed: `Launching skill: mattpocock-skills:grilling`, and the hook log was empty. As documented, `UserPromptExpansion` does not cover model invocation. A `Skill(...)` deny rule (#28) or a `PreToolUse` hook is still needed for that path.

### E: declarative matcher, no script

```json
{ "hooks": { "UserPromptExpansion": [ {
  "matcher": "^mattpocock-skills:(grilling|triage)$",
  "hooks": [ { "type": "command", "command": "echo '{\"decision\":\"block\",\"reason\":\"Replaced here: use /grill-ws instead.\",\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptExpansion\",\"suppressOriginalPrompt\":true}}'" } ] } ] } }
```

```sh
for s in triage grilling; do claude -p "/mattpocock-skills:$s TEST" --max-turns 2 --max-budget-usd 0.50 --output-format json < /dev/null; done
claude -p '/grill-ws TEST' --max-turns 2 --max-budget-usd 0.50 --output-format json < /dev/null
```

Observed:
- Both `triage` (which is `disable-model-invocation: true`) and `grilling` returned `UserPromptExpansion operation blocked by hook:\nReplaced here: use /grill-ws instead.` with 0 turns and $0. There was **no** `Original prompt:` line, so `suppressOriginalPrompt` works for this event.
- `/grill-ws` (not matched) ran normally: `grill-ws loaded`.

## Interactive session: hand-check checklist (not yet observed)

The docs describe `UserPromptExpansion` without any interactive or `-p` distinction, and say that a block's reason "appears as a warning line". Nobody has watched this in an interactive session yet. Run this by hand in a **throwaway** directory, not a real project:

1. `mkdir -p /tmp/upe-check/.claude && cd /tmp/upe-check`
2. Write `.claude/settings.json` with the Test E JSON above.
3. Start `claude` and accept the workspace trust prompt. Hooks in a project file may wait for trust.
4. Type `/mattpocock-skills:grilling hello` and press Enter. Expect a warning line `UserPromptExpansion operation blocked by hook: Replaced here: use /grill-ws instead.`, no model response, and no `Original prompt:` line. Note exactly what appears and where.
5. Check whether the typed text stays in the input box or is cleared, and whether Up-arrow recalls it.
6. Type `/mattpocock-skills:tdd hello`, which is not matched. It should expand normally. Press Esc to stop it.
7. In the same session, type `/hooks` and confirm that the `UserPromptExpansion` entry is listed.
8. Optional: remove `suppressOriginalPrompt` and repeat step 4 to see the `Original prompt:` line.
9. Exit, then `rm -rf /tmp/upe-check`.

## What this means for ADR 0001

- **The full per-skill recipe is complete without disabling the plugin.** For each upstream skill we replace:
  - Use a `UserPromptExpansion` hook (matcher `^mattpocock-skills:(<names>)$`, JSON `decision: "block"`, a `reason` naming our replacement, and `suppressOriginalPrompt: true`) to block what people type.
  - Use a `Skill(mattpocock-skills:<name>)` deny rule to block what Claude calls. That rule is only needed for model-invocable upstream skills.
  - Both can live in the committed project `.claude/settings.json`, or ship in our plugin's hooks.
- **"Redirect" means the block message names the replacement.** Steering with `additionalContext` worked once, but it still loads the upstream body and depends on the model, so it should not be the default.
- In headless runs, the block exits 0 with `is_error: false`. A script that drives `claude -p` must check the result text, not the exit code.

## Suggested new tickets

1. **Ship the block-typed-upstream hook.** Decide whether it lives in the owner's plugin (`hooks/hooks.json`) or in each project's `.claude/settings.json`, and generate its matcher from the list of replaced skills, so the list is kept in one place.
2. **Owner hand check of the interactive case** using the checklist above (unless the map tracks it some other way).
