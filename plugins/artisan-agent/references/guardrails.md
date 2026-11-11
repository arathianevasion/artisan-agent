# Guardrail levels

A guardrail holds at one of three levels, each with one home. Skills read them at the point of use, never from memory. `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh` does the reading, recording and writing; this page is the rules. Vocabulary: GLOSSARY.md. The pair convention: `${CLAUDE_PLUGIN_ROOT}/WORKING-AS-A-PAIR.md`.

| Level | Lives in | Changes by | Read at |
|---|---|---|---|
| Product | the repo: checks, `CODING_STANDARDS.md`, `PRODUCT_STANDARDS.md`, glossary, ADRs, `.artisan-agent/config.yml`, `.artisan-agent/guardrails.jsonl` | PR | the repo's `main` |
| Individual | the Artisan's individual home (`~/.claude/artisan-agent/`, or `ARTISAN_HOME`), its own git repo, `guardrails.jsonl` | a commit straight to its `main`, optionally pushed to a private remote | the home's committed `HEAD` (uncommitted edits are ignored and reported) |
| Team | a separate repo named by `team_guardrails_repo` in config, `guardrails.jsonl` | PR | that repo's `main`, no pin |

## The ledger

Standards files are prose and checks are code; the machine-readable guardrails (the ones that can contradict each other) are `guardrails.jsonl`, one JSON object per line, at each level:

| Field | Meaning |
|---|---|
| `id` | unique within the level |
| `key`, `value` | the topic and what is decided. Two guardrails conflict when they share a `key` and differ in `value` |
| `rule` | the rule in words |
| `strict` | how strict, a whole number (default 0); higher is stricter. Orders a tightening and decides the stricter-individual-review case |
| `scope` | optional; `own-reviews` marks an individual guardrail about the Artisan's own reviews |
| `role` | optional, individual only; `product` or `engineering`, for a pair |
| `origin` | `{run?, date, reason, who}`: where it came from |
| `moves` | `[{date, kind, evidence, who, from, to}]`: every tightening. Only a person moves a guardrail; agents propose |

## At the start of each wave

`wave.sh launch` calls `guardrails.sh wave-start`, which:

1. fetches all three sources (the team repo is cloned and fetched into a cache; the product's `origin`; the individual home is read as committed);
2. if `main` changed a product guardrail (config, standards files, glossary, ADRs, workflows, the ledger), merges `main` into the integration branch in its worktree. A conflict queues a decision and the wave does not start. Merged work isn't re-checked;
3. records the plugin version and each source's commit in the state file (`waves[]`, `references/state-file.md`);
4. workers are told the version and how to read the guardrails in force (`guardrails.sh resolve --run-dir`), which reads each source **at the commit the wave recorded**. A change committed mid-wave therefore applies from the next wave.

## Precedence

1. **Product beats team, which beats individual.** For a `key` with different values, the highest level's guardrail applies; the others are listed as overridden.
2. **Individual fills gaps.** An individual guardrail applies where no shared level has the key.
3. **A stricter individual guardrail about one's own reviews** (`scope: own-reviews`, `strict` above the shared one's) applies to the gates that Artisan holds. It is listed as `own_reviews`; for everyone else the shared guardrail stands.
4. **In a pair,** an individual guardrail with a `role` applies only to that role's jobs (`resolve --role`).

Every conflict is in `conflicts` and `overridden`; the plan step surfaces them for approval and the retro raises them.

## Tightening

The Artisan can tighten at any time, including mid-run in the chat: `guardrails.sh tighten --level <level> --who <name> --reason <why> ...`. A new guardrail records its origin; an existing one (`--id`, a higher `--strict`) records the move with its evidence and who. Individual is committed directly; product and team become a branch and commit in a throwaway worktree (`--pr` pushes it and opens the PR). It applies from the next wave once merged. Loosening is refused (exit 5): only a retro, with evidence, loosens.

## The packet

A packet lists the guardrails applied and their versions: `guardrails.sh table --run-dir <run folder>` prints the section (a markdown table: guardrail, level, version, what it says, then what was overridden). The version is the source commit's short hash.
