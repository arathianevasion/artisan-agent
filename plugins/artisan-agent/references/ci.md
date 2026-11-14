# The CI checklist

`/artisan-agent:setup` prints this checklist after it records a project's checks (`skills/setup/PROJECT.md`, question 4). `${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/ci-checklist.sh [repo]` reads the repo's GitHub Actions workflows (`.github/workflows`), its test configs, `.artisan-agent/config.yml` and `CODING_STANDARDS.md` `## Checks`, and prints one table: each item **present**, **missing** or **n/a** (nothing in the repo to judge), with a one-line how-to and a link to its entry below. The retro cites the entries by anchor.

It is **read-only**. It changes nothing in the repo, opens no ticket and decides nothing: the Artisan reads the table, picks the missing items worth doing, and only then does setup file each as a `needs-triage` ticket in the project's own tracker, in the tracker conventions (`docs/agents/issue-tracker.md`). It reads text, so it can be wrong about an unusual workflow; a row is a prompt to look, not a verdict.

Why it exists: riley ran e2e unsharded with `retries: 0`, and claudia ran every step on one 4-vCPU runner, and both were found by hand (claudia #1049–#1052, riley #283 and #284).

| Item | Marked present when |
|---|---|
| [Shard the slow suite](#shard) | a `shard` matrix, `--shard` or a split plugin is in a workflow or test config |
| [Cache dependencies and browsers](#cache) | `actions/cache`, a setup action's `cache:` or the browser directory is cached |
| [Cheap checks first, fail fast](#fail-fast) | a job `needs:` another, or the runner has a bail or max-failures flag |
| [Cancel superseded runs](#cancel-superseded) | `concurrency` with `cancel-in-progress: true` |
| [Skip a tree that already passed](#skip-passed-trees) | a workflow looks an artifact up by name (`actions/artifacts?name=`) |
| [Retry in the job, with a quarantine list](#retries-and-quarantine) | retries are set **and** a quarantine list exists |
| [One gate command](#one-gate-command) | the workflow runs a script that exists in the repo, or a recorded check |
| [No second run on main](#no-second-run-on-main) | no push trigger (n/a), or a push can skip a passed tree |
| [Docs-only changes run nothing](#docs-only) | a workflow path filter **and** `merge_gate_skip_paths` are both set |
| [Per-test timings kept](#timings) | a report with durations is uploaded with `actions/upload-artifact` |
| [The merge-gate time limit is recorded](#merge-gate-limit) | `merge_gate_minutes_limit` has a value in `.artisan-agent/config.yml` |

With no workflow in `.github/workflows`, every item is n/a.

## shard

Split the slow suite across runners: a `strategy.matrix.shard` and the runner's flag (`playwright test --shard=i/n`, `tests/run.sh --shard i/n`, pytest-split). **Trade-off:** each shard pays the install and setup cost again, so shards help only when the suite is much longer than that; an uneven split leaves the slowest shard setting the wall time (see [timings](#timings)); a matrix needs `fail-fast: false` if you want every shard's result, and a required check must be the job that gathers the shards.

## cache

Cache the package manager's store (`setup-node` with `cache: npm`) and large downloads such as the browser directory (`~/.cache/ms-playwright`), keyed on the lockfile hash. **Trade-off:** a cache restore isn't free (a large browser cache can cost nearly what it saves); a stale key hides a broken install; and a cache is scoped by ref, so it is never a place to keep a result (see [skip passed trees](#skip-passed-trees)).

## fail-fast

Run lint, typecheck and other cheap checks first, in a job the slow jobs `needs:`, so a typo costs seconds and not a whole suite. Have the runner stop early where it is safe (`--max-failures`). **Trade-off:** the slow suite starts later when the cheap job is slow; stopping at the first failure hides the other failures, so a developer fixes them one run at a time.

## cancel-superseded

`concurrency: {group: ci-${{ github.ref }}, cancel-in-progress: true}` cancels the run a newer push to the same ref makes useless. **Trade-off:** never put it on a workflow the merge gate dispatches or one that publishes (the gate's branches are unique, so its groups never collide, but a shared group would cancel a gate run); a cancelled run has no conclusion, which the gate treats as no verdict.

## skip-passed-trees

A run need not test a tree that has already passed. **`actions/cache` can't hold the record.** A cache saved by a pull request run is scoped to that pull request's merge ref, and GitHub's [dependency caching reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching) says it "cannot be restored by the base branch", so main never finds it.

What works:

1. When a run passes, it publishes the tree it tested as an **artifact named for that tree** (for example `passed-<tree sha>`, from `git rev-parse HEAD^{tree}`).
2. A later run looks the name up through the API, `gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=passed-<tree>"`, which is visible from any ref.
3. For a pull request, the tree tested is the **merge commit's**, not the head's: `actions/checkout` on `pull_request` checks out the merge ref, so take the tree from what was checked out.
4. A skip **names the run it relied on** (the artifact's `workflow_run.id`), and a failed lookup (API error, no match, an expired artifact) means **run in full**.

**Trade-off:** an artifact expires (`retention-days`), the lookup adds a call and a place to fail, and a skip trusts the earlier run's tree, not its environment, so a change to the workflow itself must change the name (include the workflow file's hash). The plugin's own merge gate has the same rule for its release skip and for reusing a worker's run (`references/checks.md`).

## retries-and-quarantine

Retry a failed test once or twice inside the job (`retries: 1`, `--reruns 1`, `run.sh --rerun-failed`), and keep a quarantine list of known-flaky tests that still run but can't fail the build, each with an open issue. **Trade-off:** retries hide real flakes unless they are reported, so pair them with a **flaky report** (a test that passed on retry is listed in the run summary) and the quarantine list, with an owner and an issue each so the list shrinks; retries also cost minutes and can mask a race the product really has. `tests/run.sh --rerun-failed` and `tests/quarantine.txt` are this repo's version.

## one-gate-command

CI calls the same command a person or a worker runs: claudia-kerman has `tools/gates/gates.sh`, this repo has `tests/run.sh`; riley's gate exists only as its workflow. **Trade-off:** a script is one more file to keep right, and a workflow that is only a call to it hides the job structure ([shard](#shard) and [fail-fast](#fail-fast) still need jobs); without one, a worker can't run what CI runs, and the recorded checks (`references/checks.md`) drift from the workflow.

## no-second-run-on-main

A push to main whose tree its pull request already passed doesn't run the suite again. Of riley's 64 concluded runs on main, 51 tested a tree that had already passed, and 11 of those went red; half of claudia's last 24 runs did the same. Use the artifact lookup in [skip passed trees](#skip-passed-trees), or drop the push trigger when a merge queue or the merge gate already tests the merge. **Trade-off:** main then has no run of its own, so a squash or rebase merge that changes the tree must still be tested (the tree name handles this: a different tree has no artifact).

## docs-only

Docs-only changes run nothing: a path filter in the workflow (`paths-ignore: ["**/*.md", "docs/**"]`) and **the same paths** in `merge_gate_skip_paths` in `.artisan-agent/config.yml` (`references/checks.md`, the release skip). A riley pull request that added one markdown file ran all 107 e2e tests and went red on a flaky one. **Trade-off:** a filtered workflow doesn't report a required check, so a protected branch waits forever unless a stub job reports it; and a path that looks like docs but is read by a test (a markdown fixture) would skip a run that mattered, so keep the list to paths nothing executes.

## timings

Every run leaves its per-test durations as an artifact (a junit or JSON report, `upload-artifact`), so slow tests and shard balance can be read later and the retro can cite them. **Trade-off:** artifacts use storage until they expire; reporters add a little run time. Without timings, [sharding](#shard) is guesswork.

## merge-gate-limit

`merge_gate_minutes_limit` (6, #200) in `.artisan-agent/config.yml` is how long one merge gate may take. The plan step says so when the expected minutes per merge are over it, and the retro when the median gate was; nothing refuses or fails over it. **Trade-off:** a limit nobody can act on is noise; set it to what the Artisan would call too slow, then use the items above to get back under it.
