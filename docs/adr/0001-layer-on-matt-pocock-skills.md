# Layer on Matt Pocock's skills; don't fork them

Version one installs alongside the upstream `mattpocock-skills` plugin and adds the owner's own skills (`implement-plan`, triage, `/to-plan`, a retro wrapper; PRs are cut with upstream `pr`, so the once-planned `/raise-prs` was dropped) rather than forking the upstream library. Upstream releases every two to three weeks and has renamed files and skills without aliases, and the owner's September copies of seven skills had already drifted (`CONTEXT.md` vs `GLOSSARY.md`) within two months. The owner's need to put human taste into technical design is met through orchestrators the owner already owns and through project guardrails, which upstream skills already read.

## Considered Options

- **Fork the whole library:** full control, but every upstream release becomes a manual merge of prose prompts across 27 skills.
- **Layer by default (chosen):** replace an individual upstream skill only where it decides a matter of taste inside its own steps, where no project guardrail can reach it. Each replacement takes its own name, so it never collides with the upstream skill, and is recorded as its own decision.

## Consequences

- The retro step owns checking each upstream release against what the owner's skills depend on (labels, `docs/agents/*`, skill names).
- Stale local copies of upstream skills in `~/.claude/skills` are a known source of the wrong version loading.

## Amendment: how a replacement takes over (2026-11-10)

Our skills can't invoke an upstream skill marked `disable-model-invocation: true`. Where the pipeline must call such a skill automatically, we replace it. Where a person is present anyway, the front door names the command to type. Version one replaces `implement-spec` (with `implement-plan`), `implement`, `to-spec`, `retro`, `triage` and `grill-with-docs`, each under the `artisan-agent` name.

A replaced skill is kept out of use in three ways, all built from one replaced-skill list in the plugin:
- A `UserPromptExpansion` hook blocks anyone typing it and names our skill instead.
- A `Skill(...)` deny rule stops Claude calling it, even if upstream later drops the typed-only flag.
- The upstream-updates check watches the flag.

The retro flags any work that still gets past these. Disabling the whole upstream plugin was rejected, because we keep using most of its skills.
