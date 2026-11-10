# Does a deny rule hide a plugin skill from Claude?

Research for #28 (map #1). It follows up on the [plugin-layering research](https://github.com/arathianevasion/watsonsoft-workflow/blob/research/plugin-layering/docs/research/plugin-layering.md) (#21) and [ADR 0001](../adr/0001-layer-on-matt-pocock-skills.md).

Researched 2026-11-10 against Claude Code 2.1.322 (`claude --version`), the docs at code.claude.com, and live headless sessions. Documented facts cite a URL. Test results are reported as observed, with the exact command. **Unverified** marks anything not established by either.

## Short answer

- **(a) Does it block the skill from running? Yes, when Claude calls it.** With `"deny": ["Skill(mattpocock-skills:grilling)"]` in project settings, Claude's Skill-tool call returned `Skill execution blocked by permission rules`, and `permission_denials` recorded it.
- **(b) Does it remove the skill from the listing Claude picks from? No.** The denied skill stayed in Claude's skill listing, with its description. Claude picked it and was refused only when it tried to run it.
- **The deny rule does not stop the user typing the skill.** In the same project, `claude -p '/mattpocock-skills:grilling …'` expanded the skill and loaded its body into context. No denial was recorded.
- **Ticket's example skill is a special case.** Upstream `triage` already sets `disable-model-invocation: true`, so it is **never** in Claude's listing, with or without a deny rule. Claude's call to it fails with a `disable-model-invocation` error before any permission check. 16 of the 27 upstream skills behave like this; only 11 are model-invocable.
- **Turning the whole plugin off in project settings works.** `"enabledPlugins": {"mattpocock-skills@claude-plugins-official": false}` in a project's `.claude/settings.json` removed all 27 upstream skills from that session, even though the plugin is enabled at user scope.

## What the docs say

- Skill permission syntax: "`Skill(name)` for exact match, `Skill(name *)` for prefix match with any arguments". "**Disable all skills** by denying the Skill tool". ([skills](https://code.claude.com/docs/en/skills), "Restrict Claude's skill access")
- The deny table there covers aliases, unqualified names, synced claude.ai skills (`Skill(anthropic-skills:deploy)`), and the parameter form `Skill(skill:deploy)`, which blocks "the skill whichever of its names Claude calls it by, including its alias and display name". It has no row for marketplace plugin skills ([skills](https://code.claude.com/docs/en/skills)).
- Bare-name versus scoped deny rules: "A bare tool name like `Bash` removes the tool from Claude's context entirely, so Claude never sees it. … A scoped rule like `Bash(rm *)` leaves the tool available and blocks matching calls when Claude attempts them." ([permissions](https://code.claude.com/docs/en/permissions)). `Skill(x)` is a scoped rule, so this predicts the observed result: the skill stays visible and only the call is refused. The docs never say outright how the listing behaves.
- The only documented way to remove a skill "from Claude's context entirely" is `disable-model-invocation: true` in its frontmatter ([skills](https://code.claude.com/docs/en/skills), "Restrict Claude's skill access").
- "Plugin skills are not affected by `skillOverrides`. Manage those through `/plugin` instead." ([skills](https://code.claude.com/docs/en/skills), "Override skill visibility from settings")
- Removing a plugin skill: "disable or uninstall the plugin that provides it, from the `/plugin` menu or with `/plugin uninstall <plugin-name>@<marketplace-name>`" ([skills](https://code.claude.com/docs/en/skills), "Remove a skill").
- Settings precedence is managed > command line > project local > shared project > user ([settings](https://code.claude.com/docs/en/settings), "Settings precedence"). The shared project file is for "Team permissions, hooks, plugins". `deny` rules from a committed project file "apply right away", without waiting for workspace trust ([settings](https://code.claude.com/docs/en/settings), "A committed key doesn't reach teammates").
- Hooks: `UserPromptExpansion` fires "When a user-typed command expands into a prompt, before it reaches Claude. Can block the expansion". `PreToolUse` matches on tool name (for example `Skill`) and can return `permissionDecision: "deny"` ([hooks](https://code.claude.com/docs/en/hooks)).

## Live test

Setup: a throwaway directory under the session scratchpad, holding only `.claude/settings.json`. User settings and the user-scope install of `mattpocock-skills@claude-plugins-official` 1.3.1 loaded as normal. The directory was deleted afterwards.

### Test 1: deny `triage` (the ticket's example)

Settings: `{"permissions": {"deny": ["Skill(mattpocock-skills:triage)"]}}`

```sh
claude -p 'Test task. 1) Look at the skill listing in your context ... Print, verbatim, every entry whose name starts with "mattpocock-skills:". 2) State explicitly whether "mattpocock-skills:triage" appears in that listing. 3) Then call the Skill tool with skill "mattpocock-skills:triage" and report the exact tool result text verbatim. Do nothing else.' \
  --max-turns 4 --max-budget-usd 0.50 --output-format json
```

Observed:
- 11 `mattpocock-skills:*` entries listed. `triage` was **not** among them.
- Tool result: `Skill mattpocock-skills:triage cannot be used with Skill tool due to disable-model-invocation. Ask the user to run /mattpocock-skills:triage themselves …`
- `permission_denials: []`. The deny rule never came into play.
- Cause: upstream `skills/engineering/triage/SKILL.md` has `disable-model-invocation: true`. This test therefore can't isolate the deny rule, so Test 2 uses a model-invocable skill instead.

### Test 2: deny `grilling` (model-invocable)

Settings: `{"permissions": {"deny": ["Skill(mattpocock-skills:grilling)"]}}`

```sh
claude -p 'Test task. Answer in ONE single message before any tool call: (1) the names only of every entry in your skill listing whose name starts with "mattpocock-skills:"; (2) yes/no: does "mattpocock-skills:grilling" appear in the listing. Then call the Skill tool with skill "mattpocock-skills:grilling" and quote its result. Do nothing else.' \
  --max-turns 4 --max-budget-usd 0.50 --output-format stream-json --verbose
```

(An earlier `--output-format json` run gave the same block result, but its final message left out the listing answer. This stream-json run captures every message.)

Observed:
- Claude listed 11 entries **including `mattpocock-skills:grilling`** and answered "Yes, … is in the listing."
- Skill tool call `{"skill": "mattpocock-skills:grilling"}` returned `Skill execution blocked by permission rules`.
- `permission_denials` recorded `{"tool_name": "Skill", "tool_input": {"skill": "mattpocock-skills:grilling"}}`.
- The `init` event's `skills` and `slash_commands` arrays still contained all 27 upstream names, including `grilling` and `triage`.

### Test 3: user-typed invocation under the same deny rule

```sh
claude -p '/mattpocock-skills:grilling TEST ONLY: do not grill. Instead quote verbatim the first sentence of the skill instructions that were loaded into your context by this slash command, or say NOT LOADED if none were. One line, then stop.' \
  --max-turns 2 --max-budget-usd 0.50 --output-format json < /dev/null
```

Observed: the result was `Interview the user relentlessly until you reach a shared understanding.`, the first line of upstream grilling's SKILL.md body. `permission_denials: []`. **The deny rule did not block the typed command.** An earlier typed run also answered in grilling's `❓` question format.

**Unverified:** whether an interactive (non-`-p`) session behaves the same for typed commands.

### Test 4: disable the plugin at project scope

Settings: `{"enabledPlugins": {"mattpocock-skills@claude-plugins-official": false}}`

```sh
claude -p 'Reply with the single word OK.' --max-turns 1 --max-budget-usd 0.50 --output-format stream-json --verbose < /dev/null
```

Observed: the `init` event's `skills` held **no** `mattpocock-skills:*` entries, and `mattpocock-skills` was missing from `plugins`. A project-level `false` overrides the user-level enable.

## Ways to keep an upstream plugin skill from loading

| Mechanism | Claude can't call it | Hidden from Claude's listing | User can't type it | Granularity | Status |
| :- | :- | :- | :- | :- | :- |
| `permissions.deny: ["Skill(<plugin>:<skill>)"]` in user or project settings | Yes | **No** | **No** | One skill | Tested (2, 3) |
| Upstream frontmatter already sets `disable-model-invocation: true` (16 of 27 skills, triage included) | Yes | Yes | No | One skill, upstream's choice | Tested (1) |
| `enabledPlugins: { "mattpocock-skills@claude-plugins-official": false }` in project `.claude/settings.json`, or `/plugin` disable | Yes | Yes | Yes | Whole plugin | Tested (4); [skills](https://code.claude.com/docs/en/skills), "Remove a skill" |
| `UserPromptExpansion` hook that blocks `/mattpocock-skills:<skill>` | n/a | No | Yes | One skill | Documented ([hooks](https://code.claude.com/docs/en/hooks)), untested |
| `PreToolUse` hook on `Skill` that returns `deny` for a given `skill` input | Yes | No | No | One skill | Documented ([hooks](https://code.claude.com/docs/en/hooks)), untested; adds nothing over a deny rule |
| `skillOverrides` | — | — | — | — | Doesn't work: "Plugin skills are not affected" ([skills](https://code.claude.com/docs/en/skills)) |
| Vendor the kept upstream skills into the owner's plugin and disable upstream | Yes | Yes | Yes | Per skill, at the cost of a partial fork | Follows from row 3 |

No documented mechanism hides a single model-invocable plugin skill from Claude's listing while keeping the rest of the plugin.

## What this means for ADR 0001

- **For the skills the owner plans to replace, the problem is mostly moot.** Upstream `triage`, `to-tickets`, `to-spec`, `implement`, `implement-spec`, `retro`, `wayfinder` and `grill-with-docs` are already `disable-model-invocation: true`. Claude can never pick them, so an owner skill under a new name won't compete with them in model selection. The only remaining risk is a human typing the upstream name, and a `UserPromptExpansion` hook could block that.
- **For a model-invocable upstream skill (grilling, research, tdd, code-review, pr, prototype, …), a deny rule is a half-measure.** The upstream skill stays in Claude's listing, so Claude may still pick it, burn a turn on the refusal, and then fall back. Its description also keeps costing listing budget. Full removal means disabling the whole upstream plugin and vendoring, which is the partial fork the ADR rejected. Layering is still workable, but replacing a model-invocable skill should be either avoided or accepted with a deny rule plus the leftover listing noise.
- `Skill(skill:<name>)` (the parameter form) is the documented way to catch every alias of a skill. For plugin skills that have no alias, `Skill(<plugin>:<skill>)` was enough in testing.

## Suggested new tickets

1. **Decide the replacement recipe per kind of upstream skill.** For user-only upstream skills, rename and optionally block the typed upstream name with a `UserPromptExpansion` hook. For model-invocable ones, either use a deny rule and accept the listing noise, or don't replace at all. Record it as an amendment to ADR 0001.
2. **Test a `UserPromptExpansion` hook that blocks `/mattpocock-skills:<name>`.** It is documented but untested here. Check it in both `-p` and interactive sessions.
3. **Watch upstream `disable-model-invocation` flags in the retro step.** If upstream flips a skill from user-only to model-invocable, a replaced skill starts competing with the owner's copy without anyone noticing.
