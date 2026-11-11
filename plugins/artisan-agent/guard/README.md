# Replaced-skill guard

The Artisan never runs the wrong version by habit. `replaced-skills.list` names each upstream `mattpocock-skills` skill the pipeline replaces and its `artisan-agent` replacement (`grill-with-docs` -> `/artisan-agent:grill`). `dependencies.list` beside it names the upstream skills the pipeline uses and keeps. A skill is on one list or the other, never both.

The replaced-skill list is the single source. `guard.sh` generates three things from it; never edit them by hand.

| Output | Command | Where it goes |
| :- | :- | :- |
| `UserPromptExpansion` hook | `guard.sh hooks-json` | `../hooks/hooks.json`, shipped in the plugin (a test fails if it is stale) |
| `Skill(...)` deny rules | `guard.sh deny-rules` / `deny-json` | project settings, written by setup (#53) |
| Upstream flag watch | `guard.sh flag-watch` | read by the upstream check, which compares each skill's `disable-model-invocation` flag with the last one it saw |

To replace another skill: add a line to `replaced-skills.list`, run `guard.sh hooks-json > ../hooks/hooks.json`, and run `tests/run.sh`.

## The hook

Matcher `^mattpocock-skills:(<names>)$`; `block-replaced.sh` answers `decision: "block"`, a reason that begins `Blocked by the artisan-agent replaced-skill guard:` and names the replacement, and `suppressOriginalPrompt: true`. It fires only on what a person types; it does not fire when Claude calls the Skill tool. Research: `research/hook-block-typed-skill` and `research/deny-plugin-skill` on `origin`.

**A blocked headless run exits 0** with `is_error: false` and 0 turns. Detect it from the result text (the marker above), never the exit code.

Proof (2026-11-10, Claude Code 2.1.322): with the plugin installed from this worktree into a throwaway `CLAUDE_CONFIG_DIR`, `claude -p '/mattpocock-skills:implement TEST' --max-budget-usd 0.50 --output-format json` returned exit 0, 0 turns, $0 and the result `UserPromptExpansion operation blocked by hook: Blocked by the artisan-agent replaced-skill guard: /mattpocock-skills:implement is replaced in this pipeline. Use /artisan-agent:implement instead.` `grill-with-docs` named `/artisan-agent:grill`. The block happens before any model call, so it needs no login.

## Fallback: project settings

If a plugin-shipped hook ever fails to fire, setup writes the hook and the deny rules into the project's `.claude/settings.json`:

```bash
guard.sh settings-json --hook-command "<absolute path to guard/block-replaced.sh>" > .claude/settings.json   # merge into an existing file
```

Proof: in a throwaway config with only `mattpocock-skills` installed, a project `settings.json` generated this way blocked `/mattpocock-skills:triage` with the same message, and an unmatched skill (`tdd`) passed through to the model. Setup must write an absolute or `$CLAUDE_PROJECT_DIR`-based path, since `${CLAUDE_PLUGIN_ROOT}` only exists for plugin hooks. Plugin hooks can be added; project hooks can be added; both firing is harmless (the same block).

## Deny rules and the flag watch

Every replaced upstream skill we replace today is typed-only upstream (`disable-model-invocation: true`), so Claude cannot call it. The deny rules are belt and braces in case upstream drops that flag; a `Skill(...)` deny rule blocks Claude's call but leaves the skill in its listing and does not stop a typed command (hence the hook). If prerequisite 3's hand check shows a deny rule does not stop Claude calling a plugin skill, the fallback is typed-only today plus the flag watch, which flags the day upstream changes it.

## Hand checks

Not done by the builder: see `interactive-checklist.md` (pilot prerequisites 2 and 3; tracked in #78).

## Main-checkout protection and the run lock

The same generator wires two more hooks into `hooks/hooks.json` (the shared rules are in `../references/main-checkout.md`):

| Hook | Event and matcher | What it does |
|---|---|---|
| `protect.sh main-edit` | `PreToolUse` on `Edit\|Write\|MultiEdit\|NotebookEdit` | denies an edit to a file in a repo's main checkout (`git-dir` equals `git-common-dir`) when the repo has a committed `.artisan-agent/config.yml` and the path is not git-ignored; the reason says to work in a worktree (`scripts/doc-change.sh`) |
| `protect.sh run-start` | `UserPromptExpansion` for `^(artisan-agent:)?implement-plan$`, and `PreToolUse` on `Skill` (Claude calling it) | while `scripts/run-lock.sh check` reports a live holder, blocks the start and runs `queue-plan.sh`, which leaves the request as a `plan` issue via `gh` (reusing an open one with the same title) |

Both fail open when they cannot tell (no `jq`, not a git repo, `gh` failing: the block message then says the issue was not filed). Their tests stub `gh`: `tests/main-checkout.test.sh`.

Fallbacks, each tested with the plugin hook never invoked: `pre-commit.sh` (installed per repo by `install-pre-commit.sh`; setup's project-level step is to call it, which is not wired yet, see discovered work on the ticket; it copies the hook into the repo's shared hooks dir, never overwrites a hook it did not install, and is idempotent), and `implement-plan`'s own `run-lock.sh check` precondition. `settings-json` still carries only the replaced-skill hook.

To add a hook or matcher, change `json_plugin_hooks_body` in `guard.sh`, run `guard.sh hooks-json > ../hooks/hooks.json`, and run `tests/run.sh`.

Proof (2026-11-10, headless, `claude -p --plugin-dir <this plugin>` in a throwaway repo with a committed `.artisan-agent/config.yml`, `gh` stubbed on PATH): asking Claude to Edit `doc.md` was denied by the `PreToolUse` hook (the file stayed unchanged, the model quoted the "main checkout ... work in a worktree" reason and the `doc-change.sh` route). Typing `/artisan-agent:implement-plan run tickets 5 and 6` while `runs/r1/state.lock` named a live pid returned `UserPromptExpansion operation blocked by hook: Blocked by the artisan-agent run lock: run r1 (pid ...) holds the lock ...`, 0 turns, $0, and the stub `gh` saw `issue create --title "Plan: run tickets 5 and 6" ... --label plan`. The interactive half (pilot prerequisite 5) is in `interactive-checklist.md`, tracked in #78.
