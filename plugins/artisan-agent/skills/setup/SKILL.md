---
name: setup
description: Set up Artisan Agent. Machine-level setup, done once per machine - creates the Artisan's individual home (a git repo holding individual standards and the satisfaction record), sets plugin auto-update (off for claude-plugins-official, on for artisan-agent), and offers to clean up stray project-scope installs, stale personal copies of upstream skills, hiding skillOverrides and the personal implement-plan and debate-me. Use when the Artisan says "set up Artisan Agent", "setup", or runs /artisan-agent:setup on a new machine.
---

Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`.

This skill is rerunnable and never overwrites. This file covers the **machine-level** part, done once per machine so later projects skip it. Project-level setup is added to this skill by its own ticket; if the individual home already exists and the scan below offers nothing, machine-level setup is already done: say so in one line and move on.

The script is `${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/machine-setup.sh`. It works under `CLAUDE_CONFIG_DIR` (default `~/.claude`), never deletes (skill copies move to `<config>/skills/.trash`), and never removes anything unless you pass it that offer's id. Run it with `bash`.

## Steps

1. **Run `init`.** It creates `~/.claude/artisan-agent/` as a git repo holding `CODING_STANDARDS.md` and `PRODUCT_STANDARDS.md` (each with an "Always ask" section, for the Artisan's individual taste) and an empty `satisfaction.jsonl`, committing only the files it created. It then sets auto-update off for `claude-plugins-official` and on for `artisan-agent`. It first runs `check`: if `jq` (read by `classify-worker.sh`) or `perl` (detaches workers on macOS, which has no `setsid`) is missing, it prints a `missing:` line with an install hint, still does the setup, and exits non-zero. Tell the Artisan to install the missing tool; `bash machine-setup.sh check` re-checks alone. Lines starting `changed:` are what it did; `unchanged:` means a rerun found nothing to do. Existing files are never overwritten.
2. **Run `scan`.** Each output line is `ID<TAB>KIND<TAB>description`, one offer each:
   - `project-install`: a stray project-scope (or local-scope) install of `artisan-agent` or `mattpocock-skills`, such as the stale 1.2.3 install. Projects only enable the plugins; they never install them.
   - `stale-upstream-skill`: a personal copy of an upstream `mattpocock-skills` skill that now shadows or duplicates it.
   - `hiding-override`: a `skillOverrides` entry (`off` or `user-invocable-only`) that only hides one of the skills above or a personal copy being moved.
   - `personal-plugin-skill`: the personal `implement-plan` or `debate-me`, which now live in the plugin.
3. **Offer the removals in one batch.** Recommend yes for all of them, give the reason per kind in a line, and say that nothing is deleted: skill copies go to the skills trash and can be moved back. If the personal copy of an upstream skill was customised on purpose, the Artisan says no for that one. A no leaves the item alone; it will be offered again on the next run.
4. **Apply only the yeses:** `machine-setup.sh remove ID...` with the ids the Artisan approved. A project-install is removed with `claude plugin uninstall <plugin> --scope <scope>` run in that project's path. If the project folder is gone, the script recreates it, uninstalls from there and removes it again (see Stray install whose project is gone).
5. **Report in one summary:** what was created, what changed, what was removed and where it went, and what the Artisan declined.

## Auto-update

There is no CLI command for marketplace auto-update (`claude plugin marketplace` has only add, list, remove and update), so the script writes the documented setting. Per Claude Code's plugin-loading reference ("Which marketplaces and plugins auto-update"), the first of these that is set wins: `autoUpdate` on the marketplace's `extraKnownMarketplaces` entry in a settings file; `autoUpdate` on its `known_marketplaces.json` entry (what the `/plugin` Marketplaces "Enable auto-update" toggle writes); the default (on for `claude-plugins-official`, off for third-party marketplaces). The script sets `extraKnownMarketplaces.<name>.autoUpdate` in the user's `settings.json`, reusing the marketplace's recorded source, and mirrors the value into `known_marketplaces.json` when that entry exists. Docs: https://code.claude.com/docs/en/plugins/loading.md#when-auto-update-runs and https://code.claude.com/docs/en/plugins/install.md#keep-plugins-updated. `DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` switch the whole pass off unless `FORCE_AUTOUPDATE_PLUGINS=1`; tell the Artisan if one is set in their environment.

`skillOverrides` only affects personal, project and local skills, never plugin skills (https://code.claude.com/docs/en/skills.md), which is why a hiding entry for a skill that now ships in a plugin is dead weight.

## Stray install whose project is gone

`claude plugin uninstall --scope project` (and `local`) finds the install by the current directory, so it must run inside the recorded `projectPath`. Checked with the real CLI against an isolated `CLAUDE_CONFIG_DIR`: from any other directory it fails with `Plugin ... is not installed in project scope` (exit 1) and the record stays; run from a recreated, empty folder at the old path it succeeds, drops the record from `plugins/installed_plugins.json` and writes nothing into the folder.

The script therefore **recreates the missing folder, runs the CLI's own uninstall there, and removes only the levels it created**, and only if they are empty (anything the CLI wrote is kept and reported as `kept:`). It reports a failed uninstall as a failure. Rejected: editing `installed_plugins.json` directly. That file's shape, and what else an uninstall touches (settings, the plugin's data directory), belong to the CLI and can change with versions; a hand edit would leave those half-done, whereas a temporary folder lets the supported command do all of it. A record with no `projectPath` is reported as failed, since there is nowhere to run the uninstall.

## Tests

`tests/machine-setup.test.sh` runs only against a fake home and `CLAUDE_CONFIG_DIR` under the test's scratch directory, with a stub `claude` (`ARTISAN_CLAUDE_BIN`), seeded with a stale project-scope install, a stale personal upstream copy, a hiding override and personal `implement-plan` and `debate-me` copies. The stub only succeeds when run from inside the recorded project path, like the real CLI; tests cover a project path that is gone (nested, with a space), the recreated folders being removed afterwards, files the CLI wrote being kept, and a failing uninstall still failing.

`tests/upstream-skills.test.sh` keeps `upstream-skills.txt` equal to the newest installed `mattpocock-skills` cache (skipping when there is none, as in CI). The list deliberately includes skills we replace (`implement`, `triage`, `to-spec`): the scan looks for stale personal copies of the *upstream* skill, which is as stale for a replaced skill as for a kept one, and our replacements are namespaced so they never collide. The `check` tests use a PATH holding only stub tools.
