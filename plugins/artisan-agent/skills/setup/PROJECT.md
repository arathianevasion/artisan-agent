# Project-level setup

How `/artisan-agent:setup` prepares one project. Setup is a skill, not a template repo: it works on new and existing repos, reads what's there, **never overwrites**, lands its changes as **one PR**, and a rerun after that PR merges changes nothing.

Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`. Every list of tickets, labels, checks or defaults you show is a markdown table.

The script is `${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/project-setup.sh` (run it with `bash`; `--help`-style usage is at its top). File edits go through `${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/project_edit.py`, which only ever adds: a missing file, a missing section, a missing line, a missing JSON key or array entry. A value the project already set is kept and reported as `kept:`.

## What a project gets

| Item | Where | Notes |
|---|---|---|
| Plugins enabled, our marketplace registered | `.claude/settings.json` | `enabledPlugins` for `artisan-agent@artisan-agent` and `mattpocock-skills@claude-plugins-official`; `extraKnownMarketplaces.artisan-agent`. Never a project-scope install. |
| `Skill(...)` deny rules | `.claude/settings.json` `permissions.deny` | from `${CLAUDE_PLUGIN_ROOT}/guard/guard.sh deny-json`, so they match the replaced-skill list |
| Automatic compaction for the Engineering chat | `.claude/settings.json` `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `"40"`, read from `chat_context.compact_percent` in the new config. A value the project set is kept. The window (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`) is never written: `env` reaches every session, workers on smaller windows included. See `skills/implement-plan/references/context-drain.md`. |
| Replaced-skill hook (fallback only) | `.claude/settings.json` `hooks`, `.claude/hooks/artisan-agent-block-replaced.sh` | only when `hook-probe` says plugin hooks are `silent`; generated from `guard.sh settings-json` with a self-contained hook script referenced by `"$CLAUDE_PROJECT_DIR"/...` (`${CLAUDE_PLUGIN_ROOT}` doesn't exist outside plugin hooks) |
| Config with every default | `.artisan-agent/config.yml` | a copy of `${CLAUDE_PLUGIN_ROOT}/templates/config.yml`; question 3 fills `team_guardrails_repo` only in a new copy. `.artisan-agent/runs/` is added to `.gitignore`. |
| Product and coding standards | `PRODUCT_STANDARDS.md`, `CODING_STANDARDS.md` | created if missing; each gets an `## Always ask` section, seeded from question 2 |
| PR boundaries guardrail | `CODING_STANDARDS.md` `## Guardrails`, line `` - `pr-boundaries`: one PR per <slice\|plan\|ticket> `` | product level; see question 1 for the other levels |
| The project's checks | `CODING_STANDARDS.md` `## Checks` | only checks proven to fail, with the date and the break used |
| The ten labels | the tracker, and `docs/agents/triage-labels.md` | upstream's five (the strings the doc maps them to) plus `review-gate`, `plan`, `in-run`, `urgent`, `deferred` |
| Who the Artisan is; agent tickets carry `needs-triage` | `docs/agents/issue-tracker.md` `## Conventions` | GitHub: `gh api user --jq .login` and the login at setup; local markdown: `git config user.name`, no `gh` call; GitLab: `glab api user` |
| Front-door pointer | `CLAUDE.md` (or `AGENTS.md` if only that exists) | "Start with `/artisan-agent:craft`." |
| Main-checkout protection fallback | the repo's git hooks dir | `${CLAUDE_PLUGIN_ROOT}/guard/install-pre-commit.sh`; local to the clone, not in the PR |

`GLOSSARY.md`, `docs/adr/` and `.out-of-scope/` are created only when needed, by the skills that first need them; setup doesn't create them.

The motivation never goes in the PR: it is committed to the individual home (`motivations/<repo>.md`, private, one per product identified by its `origin`).

## Steps

1. **Machine first.** If `scan` says `individual-home missing`, do the machine-level part (`SKILL.md`) first.
2. **Scan:** `bash "$ps" scan` (`ps` as in step 7). If it says `upstream missing`, tell the Artisan to type `/mattpocock-skills:setup-matt-pocock-skills` first, and stop. Otherwise note what's present, the tracker, the candidate `check` lines and whether a motivation is recorded.
3. **Ask the five questions** (below), conversationally, one at a time, each with your recommendation. Nothing else is a question.
4. **Prove each chosen check fails** before anything trusts it (below).
5. **Probe the hook:** `bash "$ps" hook-probe`. `fires` means plugin hooks work here and no hook goes in project settings; `silent` sets `hook_fallback`. It runs one headless `claude -p` capped at `--max-turns 1 --max-budget-usd 0.05`; when the hook fires the block happens before any model call and costs nothing.
6. **Show one defaults summary**, a single table: every setting from `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh defaults` with its value, plus the items in the table above that need no answer. The Artisan may change any of them, but this is not a sixth question; don't ask item by item.
7. **Write the answers file** (below), then:
   ```bash
   ps="${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/project-setup.sh"
   wt=$(bash "$ps" begin)          # branch artisan-agent/setup in <repo>-wt/artisan-agent-setup
   bash "$ps" apply "$wt" answers.json   # proves each check again; records only the proven ones
   bash "$ps" labels "$wt"         # GitHub only; creates just the missing labels
   bash "$ps" pre-commit
   bash "$ps" finish "$wt"         # push and open the PR, or "unchanged" and clean up
   ```
   `begin` refuses while an earlier setup PR is still open: merge or close it, then rerun. If the motivation was answered: `printf '%s' "<their words>" | bash "$ps" motivation set`. If question 1 chose the individual level: ``bash "$ps" individual Guardrails '- `pr-boundaries`: one PR per <choice> (set at setup).'``.
8. **Report** in one table: what was created, what was kept (`kept:` lines, such as a plugin the project disabled on purpose, or a foreign pre-commit hook), which checks were proven and which were not trusted, the PR link, and where the motivation went.

## The five questions

Ask exactly these five. Recommend an answer for each (ARTISAN.md rule 2).

1. **How are PRs cut: per slice, per plan or per ticket?** Recommend per slice. Then ask at what level it holds: product (this repo, in the PR), individual (every project of theirs, committed to the individual home) or team (the team guardrails repo: draft the line and tell the Artisan to land it there by PR; setup never edits another repo).
2. **What should always come back to you?** Seeds the `## Always ask` sections: product taste goes to `PRODUCT_STANDARDS.md`, engineering taste to `CODING_STANDARDS.md`. Offer examples from the project (pricing, schema changes, new dependencies, public APIs).
3. **Is there a team guardrails repo?** `owner/name`, or none (the default).
4. **Which of these commands are the project's checks?** Show the `check` lines from `scan` as a table (command, where it was found), recommending which to keep. Each one chosen is then proven to fail.
5. **Why does this product matter to you?** In their own words. Say it stays private in their individual home and never goes in the PR, and that skipping is fine. Skip the question entirely when `scan` says `motivation recorded`; a skip never blocks setup, and a skipped answer is simply asked again on a later run.

## Proving a check fails

```bash
bash "$ps" prove-check [--prepare "npm ci"] --break "<shell edit>" -- <check command>
```

It makes a throwaway detached worktree, runs the check (it must pass first), runs the break, and runs the check again. Pick a break that the check exists to catch, in the code the check covers. Never edit the check's own definition (the `Makefile` target, the `package.json` script, the CI file, the linter's config): a check that fails because its command was rewritten proves nothing. The live run of this skill did exactly that once for `make lint` (defined as `true`), caught it, and re-proved it honestly as `cannot-fail`.

| Check kind | Deliberate break |
|---|---|
| tests | flip the expected value in one existing assertion |
| typecheck | assign a string to a number-typed variable in a file the typecheck covers |
| lint | add an unused variable, or whatever rule the config enforces |
| CI | break what the CI job runs, by the same rules |

| Outcome (first column, exit status) | Meaning | What to do |
|---|---|---|
| `proven` (0) | failed after the break | add it to `checks` with the break command and a one-line description |
| `cannot-fail` (1) | still passed after the break | report it to the Artisan as **not trusted** (for example, a typecheck over an empty program); leave it out of `checks` |
| `already-failing` (3) | failed before any break | report it; it can't be proven until it passes |
| `no-break` (4) | the break changed no file | pick a real break and retry |
| `prepare-failed` (5) | `--prepare` failed | fix the preparation (dependencies) and retry |

The worktree is removed afterwards whatever happens; the main checkout is never touched.

## Answers file

```json
{
  "pr_boundary": "slice",
  "pr_level": "product",
  "always_ask": { "product": ["Pricing changes"], "coding": ["New dependencies"] },
  "team_repo": "",
  "checks": [{ "command": "npm test",
               "break_cmd": "sed -i.bak 's/toBe(3)/toBe(4)/' cart.test.ts && rm cart.test.ts.bak",
               "break": "flipped the expected total in cart.test.ts",
               "prepare": "npm ci" }],
  "hook_fallback": false
}
```

Every key is optional. `apply` proves each check again with its `break_cmd` (and `prepare`) before recording it, so a check is never recorded on the agent's say-so; an entry without `break_cmd`, or one that isn't `proven`, is reported and left out. `pr_boundary` is written to the PR only when `pr_level` is `product`. The motivation is never in this file.

## Rerun

A rerun reads what's there: questions whose answers are already recorded aren't asked again (the motivation, an existing `pr-boundaries` line), `apply` adds nothing that's present, `labels` creates nothing that exists, the pre-commit hook is left as it is, and `finish` sees no new commit, removes its worktree and branch, and reports `unchanged`. A check line is matched by its command, so re-proving a check doesn't add it twice.

## Tests

`${CLAUDE_PLUGIN_ROOT}/tests/project-setup.test.sh` runs only against throwaway repos under the test's scratch directory, with a local bare repo as `origin`, a stub `gh` (`GH_BIN`) that records label and PR calls, a stub `claude` (`ARTISAN_CLAUDE_BIN`) and a fake `HOME`/`CLAUDE_CONFIG_DIR`. It covers a fresh repo (one PR, every item, main checkout untouched), an existing repo with its own standards and settings (the diff only adds lines), a rerun after merging (no change, no tracker call), an open setup PR, the upstream-setup precondition, deny rules equal to the replaced-skill list, the ten labels including a renamed upstream one, the hook fallback (the generated project hook blocks a replaced skill), the hook probe, the motivation (individual home only, asked once, skippable), an individual-level guardrail, recorded checks, `prove-check`'s outcomes, the pre-commit hook, a local-markdown tracker and check discovery.
