# Hand checklist: the guard in a live session (pilot prerequisites 2 and 3)

Done by a person, in a **throwaway directory**, not a real project. Needs a logged-in Claude Code and the plugin installed (`claude plugin install artisan-agent@artisan-agent --scope user`). Write down exactly what you see; the answers feed the guard README. Tracked in #78.

## Prerequisite 2: the hook blocks typed replaced skills

1. `mkdir /tmp/guard-check && cd /tmp/guard-check && claude`, accept the trust prompt.
2. Type `/hooks`; confirm a `UserPromptExpansion` entry from `artisan-agent` is listed.
3. **Namespaced name, interactive.** Type `/mattpocock-skills:implement hello`. Expect a warning line `UserPromptExpansion operation blocked by hook:` then `Blocked by the artisan-agent replaced-skill guard: ... Use /artisan-agent:implement instead.`, no model reply, and no `Original prompt:` line. Note where the line appears, whether your text stays in the input box, and whether Up-arrow recalls it.
4. Repeat for each other name: `implement-spec`, `to-spec`, `retro`, `triage`, and `grill-with-docs` (must say `/artisan-agent:grill`).
5. **Bare name.** Type `/implement hello`, `/triage hello` and `/grill-with-docs hello`. Record whether each is blocked, resolves to a different skill, or is unknown, and which `command_name` the event reports (to see it, temporarily point the hook at a script that logs stdin). The matcher only has the `mattpocock-skills:` prefix; if the bare name reaches the upstream skill, widen the matcher in `guard.sh` and add a test.
6. **Control.** Type `/mattpocock-skills:tdd hello`; it must expand normally (Esc to stop it).
7. **Headless.** `claude -p '/mattpocock-skills:implement hello' --max-turns 2 --max-budget-usd 0.50 --output-format json </dev/null`; expect exit 0, `num_turns` 0, and the marker text in `result`. Repeat with the bare name.
8. **Fallback.** Run `guard/guard.sh settings-json --hook-command <absolute path to guard/block-replaced.sh>` into `.claude/settings.json` of a directory, disable the plugin there (`claude plugin disable artisan-agent`, or `enabledPlugins` false) but keep `mattpocock-skills` enabled, and repeat step 3; it must block the same way. Re-enable afterwards.

## Prerequisite 3: a deny rule stops Claude calling a replaced skill

The replaced skills are typed-only upstream, so Claude cannot call them anyway; this check finds out whether the deny rule adds anything.

1. In the throwaway directory, `guard/guard.sh deny-json` into `.claude/settings.json`.
2. Start `claude` and ask: `Call the Skill tool with skill "mattpocock-skills:implement" and quote the result verbatim.` Record the result text: a `disable-model-invocation` refusal (flag wins, no permission check) or `Skill execution blocked by permission rules`.
3. If upstream has meanwhile made a replaced skill model-invocable, use that one: expect `Skill execution blocked by permission rules`, and that the skill still shows in Claude's listing (research: deny rules do not hide it).
4. Outcome: if the deny rule blocks the call, prerequisite 3 is met. If Claude can still call a replaced skill, rely on the fallback: typed-only flag plus the flag watch (`guard.sh flag-watch`), and note it in the guard README.
