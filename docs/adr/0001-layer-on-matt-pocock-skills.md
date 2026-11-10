# Layer on Matt Pocock's skills; don't fork them

Version one installs alongside the upstream `mattpocock-skills` plugin and adds the owner's own skills (`implement-plan`, triage, `/to-plan`, `/raise-prs`, a retro wrapper) rather than forking the upstream library. Upstream releases every two to three weeks and has renamed files and skills without aliases, and the owner's September copies of seven skills had already drifted (`CONTEXT.md` vs `GLOSSARY.md`) within two months. The owner's need to put human taste into technical design is met through orchestrators the owner already owns and through project guardrails, which upstream skills already read.

## Considered Options

- **Fork the whole library:** full control, but every upstream release becomes a manual merge of prose prompts across 27 skills.
- **Layer by default (chosen):** replace an individual upstream skill only where it decides a matter of taste inside its own steps, where no project guardrail can reach it. Each replacement takes its own name, so it never collides with the upstream skill, and is recorded as its own decision.

## Consequences

- The retro step owns checking each upstream release against what the owner's skills depend on (labels, `docs/agents/*`, skill names).
- Stale local copies of upstream skills in `~/.claude/skills` are a known source of the wrong version loading.
