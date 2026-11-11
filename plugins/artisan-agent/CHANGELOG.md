# Changelog

Every release of the `artisan-agent` plugin bumps `version` in `.claude-plugin/plugin.json` (semver) and adds an entry here, newest first. The script tests check that the two agree.

## 0.4.0 (2026-11-11)

Wave 4: parallel waves, independent verification, worker questions and the context drain.

- Fresh verifier (#57): a separate session judges each result against the ticket's own criteria, posts the evidence on the ticket and adds it to the wave digest.
- Parallel waves (#58): tickets in a wave run side by side and merge one at a time; conflicts go through `/artisan-agent:resolve-conflicts`, and each ticket gets two attempts.
- Context drain (#59): the orchestrator never compacts. Its `PreCompact` blocks compaction and hands off to a fresh orchestrator, which finishes the wave from the state file. The chat gets the run digest back after compacting, on `/resume`, and in a new session. `verify.sh start` is idempotent per attempt (#106).
- Shared findings (#60): workers' findings reach the other workers, and a design question stops the worker and becomes a decision.
- Worker questions (#61): a decision a worker may not make is filed as a question; the ticket waits while the wave carries on, then goes out again with the answer.
- Guardrail levels (team, product, individual) are read at the point of use (#62).
- `/artisan-agent:to-plan` (#63) files plans as `plan` issues.
- `/artisan-agent:setup` for a project (#64), including proving each check can fail.

## 0.3.0 (2026-11-10)

Wave 3: the first two-tier run, the plan step and main-checkout protection.

- Tracer bullet: `/artisan-agent:implement-plan` runs a ticket end to end. The Engineering chat launches a detached orchestrator (`scripts/wave.sh`, `orchestrator.md`), which dispatches a worker, merges `--no-ff` into the run's own integration worktree, closes the ticket and logs each event in the state file. Ticket listings are tables.
- Project config (`templates/config.yml`) and the plan step (`scripts/plan.sh`): one approval with estimates and every setting. Overrides apply to one run only, and a ticket outside the approved set never dispatches.
- Main-checkout protection and the one-run-per-repo lock, with the pre-commit and lock-check fallbacks and `scripts/doc-change.sh` for doc edits.
- The worker skill stops only for an interface another ticket owns; a new seam becomes a decision card.
- The evidence record uses `findings` and `review.remarks`.
- Kept upstream skills are named in full where a built-in shares the name (`mattpocock-skills:code-review`).
- Triage defects fixed; machine setup removes stray installs whose folder is gone and checks for `jq` and `perl`.

## 0.2.0 (2026-11-10)

Wave 2: the parts a run is built from, and the Understand, Specify and Product-chat skills.

- `/artisan-agent:implement`: the worker skill. Builds one ticket test-first at its named seams, turns new seams and judgement-call smells into decision cards, and hands back an evidence record (`references/evidence-record.md`).
- Ticket runner, wait and classify scripts: workers launch detached with budget, turn and deadline caps, always leave an exit record, and are judged by their result text, never the exit code alone.
- Run state file (`references/state-file.md`): versioned, locked, rewritten in one step, with an idempotent sweep and a reconciler that recovers the frontier from git and the tracker.
- Replaced-skill guard: one list generates the `UserPromptExpansion` hook, the `Skill(...)` deny rules and the upstream flag watch.
- `/artisan-agent:triage`: uncontroversial items first, each naming its controversy criterion; every outcome approved; discard, defer with a return condition, misses recorded; the backlog-review prompt.
- `/artisan-agent:grill` and `/artisan-agent:to-spec`: replace `grill-with-docs` and `to-spec`.
- `/artisan-agent:craft`: the front door, proposing a route and naming the next command.
- `/artisan-agent:setup`: machine-level setup (individual home, marketplace auto-update, offered clean-ups).

## 0.1.0 (2026-11-10)

First release: the plugin skeleton.

- `artisan-agent` is served from its own private marketplace, `artisan-agent`, and depends on `mattpocock-skills@claude-plugins-official` (unversioned; compatibility is ensured by the upstream check, not a version range).
- `/artisan-agent:implement-plan` moves in from personal skills. It is Claude-callable, runs any defined set of work including a single ticket, and names skills by their pipeline names.
- `/artisan-agent:debate-me` moves in from personal skills as the Understand-stage skill. It ends with the decision, the trade-offs to manage and what each side conceded.
- Shared references for later skills to cite: `ARTISAN.md`, the job inventory, the decision-record shape and the seven controversy criteria.
- A script test harness for the pipeline's scripts, run on macOS and Linux.
