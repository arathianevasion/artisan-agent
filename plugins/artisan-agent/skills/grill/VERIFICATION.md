# Verifying `/artisan-agent:grill` and `/artisan-agent:to-spec`

## Automated (script tests)

`tests/grill-to-spec.test.sh` checks both skills' text: frontmatter, that `grill` loads `grilling` and `domain-modeling` together, the question format, the debate/research/prototype offers, that `to-spec` shows the draft and an additions list before publishing, that its template and seam check match upstream's `to-spec` byte for byte (when the upstream cache is present), that cited `${CLAUDE_PLUGIN_ROOT}` files exist, and that neither skill presents `grill-me` or `grill-with-docs` as a step. Each check was proven to fail by breaking a skill on purpose.

## Live headless checks: not yet run (hand check)

Behaviour under a real model was not verified when this was built: a headless session needs a login, and an isolated `CLAUDE_CONFIG_DIR` has none. Run these once with a login, in a throwaway repo with a local-markdown tracker (`docs/agents/issue-tracker.md` saying issues are files in `.scratch/`), never against real GitHub. Cap each at `--max-budget-usd 0.50 --model claude-sonnet-5-5`, use `--plugin-dir` for this plugin and for `mattpocock-skills`, and judge by result text, not exit code.

1. **grill**: `claude -p "/artisan-agent:grill a CLI that prints a greeting; I haven't decided flags or output" ...`. Expect: both `grilling` and `domain-modeling` loaded; each question shows options, a recommendation and why the strongest alternative lost; a one-line offer of `/artisan-agent:debate-me` or a prototype where taste is at stake. With a pre-seeded answer settling a term, expect `GLOSSARY.md` updated in the same session.
2. **to-spec**: after a short conversation (or a transcript pasted in the prompt) that omits a topic the spec template invites (say, accessibility), run `/artisan-agent:to-spec`. Expect the seam check, then the whole draft, then "Additions to accept or cut" listing inferred lines, and no file written to the tracker. Reply "cut 1" and expect the published local file to lack that line.
