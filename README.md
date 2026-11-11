# Artisan Agent

A Claude Code plugin, `artisan-agent`, for delivering software where agents do most of the delivery and the Artisan sets the guardrails and supplies the product and engineering taste. It layers on [`mattpocock-skills`](https://github.com/mattpocock/skills) and never forks it ([ADR 0001](docs/adr/0001-layer-on-matt-pocock-skills.md)).

The end-to-end path work takes, from a request to merged code and the lessons kept from it, is the **pipeline**. Vocabulary is in [GLOSSARY.md](GLOSSARY.md).

## Flow reference

The revised-flow prototype is the reference for how the pipeline flows: seven stages (Enter, Understand, Specify, Plan, Run, Ship, Learn) plus the Product chat lane, each step with its colour, job, focus and reason, and the levers on a running run. It lives on its own branch and is not part of `main`:

[`prototypes/revised-flow/index.html` on `prototype/revised-flow`](https://github.com/arathianevasion/artisan-agent/blob/prototype/revised-flow/prototypes/revised-flow/index.html)

To open it locally: `git fetch origin prototype/revised-flow && git show origin/prototype/revised-flow:prototypes/revised-flow/index.html > /tmp/revised-flow.html && open /tmp/revised-flow.html`.

## What you need

The pipeline runs in a bare terminal with Claude Code, `git` and `gh`. **cmux and the Cockpit (Agent Development Cockpit) are never required.** The Cockpit is a separate, optional product in its own repo.

## Install

This repo is a private plugin marketplace serving one plugin. Install it once, at user scope; projects only enable it, and nothing is installed at project scope.

```bash
claude plugin marketplace add arathianevasion/artisan-agent
claude plugin install artisan-agent@artisan-agent --scope user
```

Installing `artisan-agent` also installs `mattpocock-skills@claude-plugins-official`, which it declares as an unversioned dependency. The marketplace allows that through `allowCrossMarketplaceDependenciesOn: ["claude-plugins-official"]`. Compatibility with upstream is kept by the upstream check, not a version range.

The dependency resolves through the `claude-plugins-official` marketplace, which Claude Code normally registers by default. If `claude plugin marketplace list` doesn't show it, add it first with `claude plugin marketplace add anthropics/claude-plugins-official`; otherwise the install succeeds but `artisan-agent` won't load until `mattpocock-skills` is installed.

Turn auto-update **on** for the `artisan-agent` marketplace (in `/plugin`, under Marketplaces), so a new release reaches every project; each run picks it up from its next wave. Keep auto-update **off** for `claude-plugins-official`: upstream changes only when the Artisan approves an update after the upstream check.

Then, from any project:

- `/artisan-agent:craft`: the front door. Say what you want in plain words; it proposes a route (Effort, Feature, Small change, Bug) and names the next command.
- `/artisan-agent:grill`: understand the work. Grilling and domain modeling together, with `debate-me`, research and prototype variants on offer.
- `/artisan-agent:debate-me`: in the Understand stage, have an agent argue its suggestion, with sources, until you decide.
- `/artisan-agent:to-spec`: write the spec, showing the draft and every addition that didn't come from the conversation.
- `/artisan-agent:triage`: sort incoming tickets in the Product chat; every outcome is yours to approve.
- `/artisan-agent:implement-plan`: run a defined set of work (a plan, several plans, individual tickets or a single ticket) to done.
- `/artisan-agent:implement`: the worker skill each worker runs on one ticket (Claude-callable; you rarely type it).
- `/artisan-agent:setup`: machine-level setup, once per machine (project-level setup comes later).

Typing a replaced upstream skill (such as `/mattpocock-skills:implement`) is blocked with a message naming ours.

## Layout

```
.claude-plugin/marketplace.json        the marketplace (name: artisan-agent)
plugins/artisan-agent/
  .claude-plugin/plugin.json           manifest: semver version, dependency on mattpocock-skills
  CHANGELOG.md                         one entry per release
  ARTISAN.md                           how every skill speaks to the Artisan; retro question wording
  references/                          shared references skills cite
    jobs.md                            job inventory, colour test, scope floor
    decision-record.md                 the shape of a recorded decision
    controversy-criteria.md            when an agent may not decide alone
    evidence-record.md                 what a worker hands back for one ticket
    state-file.md                      a run's state file: schema, lock, rewrite rules
  skills/<name>/SKILL.md               one directory per skill, invoked as /artisan-agent:<name>
  scripts/                             run scripts: ticket runner, wait, classify, state, sweep, reconcile (see scripts/README.md)
  guard/                               replaced-skill guard: the one list and what it generates (see guard/README.md)
  hooks/hooks.json                     generated from guard/; never edit by hand
  tests/                               script test harness, script tests and helpers
.github/workflows/script-tests.yml     runs the script tests on macOS and Linux
```

## Conventions

- **Cite, don't copy.** A skill points at a shared reference by path from the plugin root, for example "follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`" or "criterion 3 in `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`". Numbers in the references are stable.
- **Vocabulary** comes from [GLOSSARY.md](GLOSSARY.md). "Workflow" is never a technical term; say "pipeline".
- **Skills name skills by their pipeline names**: our replacements as `/artisan-agent:<name>`, kept upstream skills by their upstream names, in full as `mattpocock-skills:<name>` wherever a Claude Code built-in shares the short name (today only `code-review`; a bare `code-review` resolves to the built-in). `tests/skill-names.test.sh` fails on a bare clashing name.
- **Runtime state stays out of git.** `.artisan-agent/runs/` is ignored; `.artisan-agent/config.yml` is committed. No secrets are committed.

## Script tests

The pipeline's scripts are tested on macOS and Linux. Tests are `test_*` functions in `plugins/artisan-agent/tests/*.test.sh`, using the assertions in `tests/lib.sh`. Each test runs in its own bash process under `set -euo pipefail`, in a fresh scratch directory (`$TEST_TMPDIR`), with `$PLUGIN_ROOT` pointing at the plugin.

```bash
plugins/artisan-agent/tests/run.sh          # every test in tests/
plugins/artisan-agent/tests/run.sh <dir>    # every test in another directory
```

The scripts need `jq`, `python3`, `perl` (to detach workers on macOS, which has no `setsid`) and git 2.31 or later.

It exits 0 when every test passes, 1 when any fails, and 2 when it finds no tests. Scripts must run on macOS's `/bin/bash` 3.2 as well as Linux, so avoid bash 4 features (`mapfile`, associative arrays, `${var,,}`) and GNU-only flags. The [Script tests workflow](.github/workflows/script-tests.yml) runs the suite on `ubuntu-latest` and `macos-latest`, and again under `/bin/bash` 3.2 on macOS.

## Releasing

Every release bumps `version` in `plugins/artisan-agent/.claude-plugin/plugin.json` (semver) and adds an entry at the top of `plugins/artisan-agent/CHANGELOG.md`. The script tests check that the two agree.
