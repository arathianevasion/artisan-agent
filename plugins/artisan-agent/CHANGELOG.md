# Changelog

Every release of the `artisan-agent` plugin bumps `version` in `.claude-plugin/plugin.json` (semver) and adds an entry here, newest first. The script tests check that the two agree.

## 0.5.0 (2026-11-14)

Wave 5: review gates, budgets and guardrail health, steering a running run, and a merge gate that can wait on CI.

- Review gates (#65, #70, #71): a slice gate is a `review-gate` issue with a decisions-first packet; gate actions (approve, redirect, bypass, defer) and the exception gate for a run giving up; risk gates, gate placement, the end gate and PRs to `main`. The 50% context risk gate opens a real review issue (#132); the end gate lists and waits on deferred overrun gates (#131); a deferred gate closed by hand is picked up at the next sync (#117).
- Budget and usage (#72): run budget, the overrun gate, the usage guard and status-line capture. `wave.sh status` only reads, and `park raise` is one write (#120). Model prices for estimates are kept current (#91); a small plan estimate no longer starves workers (#95).
- Steering (#76): add work to a running run, steer a worker, and urgent tickets, which ship through their own end gate and PR. An urgent ticket's end gate packet names the escalation tests it meets (#144); a conflict in `urgent-finish` gets one resolve try, then a decision (#143).
- Areas (#77): a ticket's expected files place it in areas, which set its gates. The plan step asks for expected files (#100) and records `blocked_by` (#113).
- Hands-on tickets (#66), plan approval's ADR and guardrail check (#67), and two chats working through the tracker (#73).
- Retro (#68, #74): lessons into their homes, the satisfaction record, and guardrail health, moves and audits. Guardrails now emit `guardrail-fired`, `guardrail-bypassed`, `gate-decision` (outcome, redirect, areas) and `bug-found`: a bug the Artisan catches at any review gate counts as tighten evidence, the same as a shipped one (#122). The scope floor fires on a worker's scope question (#148); "keep all" logs one decision per gate (#149).
- Host mode (#69): the login-expiry check and moving a run between machines. `move.sh out` is crash-safe (#107) and waits for a running merge gate (#150); a host is detected by `host.json` alone (#108).
- Merge gate on CI (#139): on a CI machine a merge waits for the CI run on that exact commit instead of the local suite; red blocks the ticket, no verdict parks the run. The gate runs detached, so no call outlives the orchestrator's time cap, and a cut-off gate resumes on the same CI run (#142).
- Wave start asks before merging `main` into a run whose base `main` lacks: merge, keep the base's guardrails, or halt (#152).
- Upstream-updates check (#75).
- Fixes: evidence records quote acceptance criteria exactly (#94); setup's checks and PR-boundary guardrail are read (#98); hook commands are escaped (#99) and quote the plugin path, so a path with a space works (#147); conflicted paths with spaces (#101); `gh api` failures surface (#102, #103); the Engineering chat's drain no longer asks the Artisan to type `/compact` (#104); a worker that waits on a background command (#111); a finished worker reported as vanished (#114); a dropped ticket's dependents say why they wait (#116).
- Tests and CI: tests get no `ARTISAN_*` variable from the caller (#121); the fake `gh` handles an empty tracker (#125); every `local` is declared with a value (#127); `state_is_uint` everywhere (#128); duplicated gate tables and filters have one definition (#118); setup cleanups (#133); tests cannot reach the main checkout's scripts or leave processes behind (#137, #145); live tests run with plugin hooks (#105); CI runs on pull requests and on demand (#141). Schema rule for additive state fields (#96).

## 0.4.1 (2026-11-14)

Pilot fix: workers were all counted as crashed, because stream-json events were found by line prefix.

- `run-ticket.sh` finds stream-json events by parsed type, not by the start of the line, so a result event with `type` after other keys is read (#151).
- `sweep.sh repair` and `gate-action.sh repaired` (#151): the repair rebuilds `output.json` from the saved stream and takes back the attempts the miscount failed; `repaired` closes the exception gate the miscount opened as resolved.
- The fake `claude`'s rate-limit reset dates move to 2100, so the usage guard no longer reads the window as already reset.
- This release also carries the work merged to main since 0.4.0 (#116 to #150); its full notes come with 0.5.0.

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
