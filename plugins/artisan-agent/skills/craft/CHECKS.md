# Craft: verification record

Not loaded by the skill. Records how `/artisan-agent:craft` was checked for ticket #52.

## Live headless checks (done)

Run from throwaway git repos with a local-markdown tracker (`docs/agents/issue-tracker.md` pointing at `.scratch/issues/`), never `gh` and never real issues, each as `claude -p --plugin-dir plugins/artisan-agent --model claude-sonnet-5-5 --max-budget-usd 0.50 "/artisan-agent:craft <request>"`:

| Request | Proposal | Reason given |
| --- | --- | --- |
| "build a whole new customer onboarding experience… not sure what it should include or how we'd know it's done" | Effort | test 1 answered no; rejected Feature because scope is open |
| "Add user accounts with login, profile and password reset… I know exactly what I want" | Feature | test 1 yes, test 2 more than one ticket; rejected Effort, offered to switch |
| "Make greet() return an exclamation mark at the end" | Small change, with a drafted ticket and checkable criteria | one function, not broken |
| "initials('Ann  Lee') crashes with IndexError" | Bug | something broken; plans `diagnosing-bugs` then a failing-test ticket |
| "Make the greeting better." (unclear) | Effort (the bigger route) | "better" states no destination; offered a one-sentence shortcut to Small change |

Each proposal started nothing and ended by asking the Artisan to approve or change the route. Effort and Feature named `/mattpocock-skills:wayfinder` and `/mattpocock-skills:to-tickets` in full and our replacements as `/artisan-agent:*`.

With the route and ticket approved in the prompt:

- Small change: filed `ready-for-agent` + `enhancement`, no `needs-triage`, did not run it, offered alone / batch / larger run.
- Bug: ran `diagnosing-bugs`, reproduced, found the cause, filed `ready-for-agent` + `bug` with a failing-then-passing test as acceptance; did not touch code, did not run it.
- Open run (`.artisan-agent/runs/run-1/state.json`, status running): noticed it, offered to hand the ticket to `/artisan-agent:implement-plan` and did not read the run's state itself.

Observed limits: a one-shot `-p` session cannot show the Artisan *changing* the route mid-conversation; the skill's instruction to adopt their route is checked by reading, not live. The open-run check used an invented `state.json`; the real run folder layout is ticket #47's and the skill matches "a run folder under `.artisan-agent/runs/` that isn't finished", so it should be re-checked once #47 lands.

## Hand check moved to #78: does bare `/wayfinder` reach the plugin copy? (pilot prerequisite 4)

Not done here: it needs the Artisan's personal copy removed, which a worker must not do.

1. In an interactive Claude Code session with `artisan-agent` (and so `mattpocock-skills`) installed, confirm `~/.claude/skills/wayfinder` (the personal copy) exists, and note what typing `/wayfinder` loads (`/skills` or the first line it prints).
2. Move the personal copy aside (`mv ~/.claude/skills/wayfinder ~/.claude/skills-wayfinder.bak`), then restart the session.
3. Type bare `/wayfinder`. Record whether it resolves to the plugin copy, and what Claude Code calls it (for example `/mattpocock-skills:wayfinder`), or says it doesn't exist.
4. Also type `/mattpocock-skills:wayfinder` and confirm it loads.
5. Result decides whether craft's "always in full" rule is a fallback or just style. If bare `/wayfinder` works, nothing changes; if it doesn't, the full name is required and craft is already right. Restore the personal copy if you want it back.
