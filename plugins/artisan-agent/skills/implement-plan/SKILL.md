---
name: implement-plan
description: Run a defined set of work to completion — a plan, several plans, individual tickets, a single ticket, or any mix. The Engineering chat reads the published tickets and their blocking edges, plans a worker for each one (model, brief, expected output), gets the plan approved, then launches a detached headless orchestrator per wave. The orchestrator dispatches workers that each run /artisan-agent:implement in their own worktree, merges their work into the run's integration branch, runs the suite and closes the tickets; the chat reports each wave and files findings for triage. Use this whenever the Artisan wants tickets built — "run this ticket", "work the backlog", "run the plan", "implement these tickets", "fan out the tickets", "run them in parallel", "kick this off overnight", "burn down the frontier" — and whenever they ask to orchestrate, dispatch, or parallelize work over one or more issues, even if they do not say the word "ticket". Claude may call it, for example when another pipeline step hands an approved ticket or plan on to be built.
---

# Implement Plan

Run a defined set of work to done: a plan, several plans, individual tickets, a single ticket, or any combination. That set is the run's scope; anything outside it waits.

`/artisan-agent:implement` builds one ticket and ends at the commit and its evidence record. It never closes the ticket or merges, and for a queue that is fatal on its own: the frontier is tickets whose blockers are all **merged**, so if nothing merges, nothing ever unblocks. This skill is the layer above it. It owns the dependency graph, the plan, the dispatch and the reconciliation. It never implements anything itself.

Wherever this skill puts something in front of the Artisan (the plan, a wave report, a question, the run summary), follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`. Wherever it lists tickets, use a markdown table, never a numbered list: one row per ticket, with its number and a short plain description together (such as "#12 (retry failed uploads)"), its wave or blockers, its model, and its expected output or status.

## Two tiers

You are the **Engineering chat**. You stay light: you hold the plan, show progress, take the Artisan's decisions and start each wave. You never dispatch a worker, merge or close a ticket yourself.

Each wave runs in a fresh headless **orchestrator** that you launch detached and then leave alone. It dispatches the wave's **workers** (one headless `claude -p` per ticket, each running `/artisan-agent:implement` in its own worktree), waits on their files, merges their work into the run's integration branch, runs the full suite after each merge, closes each merged ticket, writes the state file after every event, and exits. Its brief is `references/orchestrator.md`; the mechanics both tiers share are in `references/dispatch.md`.

| Who | Holds the state lock | Does | Learns what happened from |
|---|---|---|---|
| Engineering chat | between waves | plan step, `wave.sh start`, `wave.sh launch`, reports, decisions, findings for triage | the orchestrator's exit record and result file, and `wave.sh status` (sweep and reconciler) |
| Orchestrator | for its wave | `wave.sh dispatch`, `wait-any.sh`, `sweep.sh`, `wave.sh merge`, `wave.sh close`, `wave.sh report` | result files, exit records, git and the tracker |
| Worker | never | `/artisan-agent:implement` on one ticket in its own worktree | its ticket |

Both the orchestrator and its workers are launched by `${CLAUDE_PLUGIN_ROOT}/scripts/run-ticket.sh`, detached in their own session under `nohup`, never as a tool background command. So neither the 2-hour cap on background commands, nor your turn ending, nor this chat being closed or killed, stops a wave. Nobody reads a transcript: completion is judged from files.

## Preconditions

Stop and tell the Artisan which is missing rather than working around it:

- Tickets are published on the tracker that `docs/agents/issue-tracker.md` describes. If not, route to `/to-tickets` first.
- `/setup-matt-pocock-skills` has run for this repo.
- **No other run holds the run lock.** Before anything else, run `${CLAUDE_PLUGIN_ROOT}/scripts/run-lock.sh check`. Exit 3 means another run holds this repo's lock (it prints the run id and pid): do not start. Leave the request as a `plan` issue (`${CLAUDE_PLUGIN_ROOT}/guard/queue-plan.sh "<request>"`), tell the Artisan which run holds the lock, and stop. A repo has one run at a time; the rule is in `${CLAUDE_PLUGIN_ROOT}/references/main-checkout.md`.
- **No session edits the main checkout.** You may sit in it, but you change nothing tracked there: the run's files go in its run folder (`.artisan-agent/runs/<run-id>/`, git-ignored), merges happen only in the run's own integration worktree, and workers work in their own worktrees. `${CLAUDE_PLUGIN_ROOT}/references/main-checkout.md` has the rule.
- **On the always-on host, the login outlasts the run.** `wave.sh launch` runs `${CLAUDE_PLUGIN_ROOT}/scripts/login-check.sh` before each wave launch and refuses (exit 15) when the claude.ai login would expire mid-run; tell the Artisan to log in again and `login-check.sh stamp`. To move a run between the host and the laptop (`implement-plan move`), follow `${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/host-and-move.md`.
- `git worktree` is available, and `jq`, `python3`, `perl` (macOS) and `gh` are on PATH.
- **Every check the workers will report on has been proven capable of failing.** Run each one (test suite, typecheck, lint) against a deliberately broken file in a scratch worktree and confirm a non-zero exit, then throw the worktree away. A check that can't fail turns every worker's evidence into noise for the length of the run, and nothing downstream reveals it: the results all say "clean", the merges all stay green. In one real run, `npm run typecheck` was `tsc --noEmit` against a root `tsconfig.json` with `"files": []`; it compiled an empty program and exited 0, so thirty tickets reported "typecheck clean" and every claim was vacuous. Say in the plan what each check actually covers, and say what the workers can't verify.

## Composition

This skill is Claude-callable, so another pipeline step can hand it work. Dispatch still never happens in this session: an in-session subagent shares its working directory and cannot give a ticket a fresh context window. Each ticket gets its own `claude -p` worker in its own worktree. Agent teams are not used for code.

## Process

**An open run first.** Before step 1, run `${CLAUDE_PLUGIN_ROOT}/scripts/run-digest.sh`. If it prints a digest, a run is open in this repo: open with the digest as printed and carry that run on from step 6; plan nothing new until the Artisan asks. Neither tier ever stops to compact: before each launch and whenever woken, check your context with `${CLAUDE_PLUGIN_ROOT}/scripts/drain.sh check <run folder> --tier chat --transcript <this chat's transcript, named by the plugin's start-up line>`, as `references/context-drain.md` says.

### 1. Read the queue and build the graph

If the Artisan named a plan issue (labelled `plan`), several, or plans mixed with tickets, resolve them to tickets first: `${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/plan-issues.md`, using `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-scope.sh`.

Read every ticket body in full, not just titles. Extract for each: its number, title, blockers (native tracker links or the `## Blocked by` body section), acceptance criteria, and the layers it touches.

Compute **waves** by topological level: wave 1 is every ticket with no open blockers, wave 2 is everything unblocked once wave 1 merges, and so on. Tickets within a wave run in parallel; waves run in series. The waves are a forecast: each orchestrator recomputes the frontier from the tracker and git.

If the graph has a cycle, stop and show it: it is a planning bug to fix, not something to route around.

Watch for the expand–contract shape. Migrate batches from a wide refactor look independent but often touch overlapping call sites; when two tickets in a wave name the same package or directory, put them in separate waves and say why.

### 2. Design a worker per ticket

Each ticket gets its own worker spec, designed from the ticket body, not a template.

**Model.** Implementation mostly follows context and tolerates a cheaper model; the expensive reasoning happened during grilling. Default every ticket to the mid tier and escalate deliberately: when the ticket introduces a new seam or module boundary, is the first tracer bullet through a layer that doesn't exist yet, changes domain vocabulary or an ADR, or has acceptance criteria that read as judgement rather than behaviour. Use the fast tier only for mechanical migrate batches. Map tiers to model ids once, in the plan.

**Expected size.** Input tokens, output tokens and minutes, judged from the body: how much it reads, how much it writes, how many layers it touches. With no history these make the estimate, so size each ticket on its own; there are no per-tier defaults. A tiny ticket's estimate is raised to its model's minimum (`minimum_estimates`, shown in the approval as "minimum for <model>"; see Estimates in `${CLAUDE_PLUGIN_ROOT}/scripts/README.md`).

**Brief.** Under a paragraph: the seams to test at if the ticket names them, and any `GLOSSARY.md` vocabulary or ADRs it must respect. The ticket is the spec; don't copy it into the brief.

**Expected files.** The paths the ticket will touch (`expected_files` in the draft); they set how wide each wave can be (`references/parallel-waves.md`).

**Expected output.** What "done" looks like for this ticket in one or two lines, from its acceptance criteria. The orchestrator checks the worker's diff against it before merging. If you can't write a concrete one, the ticket is underspecified and goes back to `/to-tickets`.

### 3. Get the plan approved

Open with the ADR and guardrail check, as `${CLAUDE_PLUGIN_ROOT}/references/adr-check.md` describes it: it is part of this approval, and it is run here when the route skipped `/artisan-agent:to-plan` (a Small change, a Bug, or a Feature without chunks), including a one-ticket run. It also holds the ADR adjustment loop.

The plan step sets the run's envelope in one approval: scope, waves, a model per ticket, the estimate per ticket and in total, Max Agents, gates and every config number. Proposing the waves is yours (job 11); the rest is the Artisan's to approve or change.

1. **Write the draft** as JSON in the run folder (`$(${CLAUDE_PLUGIN_ROOT}/scripts/state.sh run-dir <run-id>)/draft.json`): `run_id`, `repo` (`owner/name` on the tracker, as `docs/agents/issue-tracker.md` names it), `integration_branch` (`run/<run-id>`), `scope` (exactly the defined set of work), `waves`, `gates`, `suite_command` (the full suite, as the project runs it), and per ticket `title`, `model`, `expected_output` and `expected` (`input_tokens`, `output_tokens`, `minutes`). Shape and rules: `${CLAUDE_PLUGIN_ROOT}/scripts/README.md`, "Config and the plan step".
2. **Build the plan:** `${CLAUDE_PLUGIN_ROOT}/scripts/plan.sh build --draft <draft.json> > <run folder>/plan.json`. It reads the project config (`.artisan-agent/config.yml`), estimates each ticket in estimated dollars and sets each ticket's caps, the total and the budget.
3. **Show it:** `${CLAUDE_PLUGIN_ROOT}/scripts/plan.sh render <plan.json>`, as printed: a table per wave with each ticket's number and description, wave, model, estimate and expected output, then every number the run uses. Underneath, add your tier mapping, the suite command, and what each check actually covers (from the preconditions).
4. **Iterate until approved.** A change to the scope, waves, a model or an expected size goes into the draft; a number the Artisan overrides for this run is a `--set key=value` on the build (for example `--set max_agents=3`). Rebuild and show it again. Never edit `config.yml` for an override: it holds the project's numbers, and changing them for good is job 23, by PR.
5. **Start the run:** `${CLAUDE_PLUGIN_ROOT}/scripts/state.sh init <run folder> <plan.json>`. From here the run's numbers come from the state file's `plan.config`; a number overridden mid-run goes through `state.sh override`.

The approved scope is the run's scope, exactly: `state.sh dispatch` and `run-ticket.sh` refuse any ticket outside it (exit 4), and `run-ticket.sh` refuses to launch anything into a run folder with no state file. A ticket that should join gets its own plan step and approval first. Review capacity comes from Max Agents and the gates the Artisan approved; never size waves by guessing what the Artisan can review. Dispatch nothing before approval.

### 4. Take the lock and start the integration branch

1. **Hold the run.** Your session's process is the long-lived pid that holds the state lock between waves. In every Bash call that runs a run script, set `ARTISAN_WRITER_PID=$(ps -o ppid= -p $$ | tr -d ' ')` (the tool shell's parent is this session), and take the lock once: `ARTISAN_WRITER_PID=… ${CLAUDE_PLUGIN_ROOT}/scripts/state.sh lock <run folder> "$ARTISAN_WRITER_PID"`. While you hold it, `run-lock.sh check` refuses a second run in this repo.
2. **Start the integration branch:** `${CLAUDE_PLUGIN_ROOT}/scripts/wave.sh start <run folder>`. It creates `run/<run-id>` from the main checkout's branch and checks it out in the run's own integration worktree, `<repo>-wt/run-<run-id>`, beside the repo. Every merge in this run happens there; the main checkout is never touched.

### 5. Launch a wave and yield

`ARTISAN_WRITER_PID=… ${CLAUDE_PLUGIN_ROOT}/scripts/wave.sh launch <run folder>` launches the next wave's orchestrator, detached, in the integration worktree, with `references/orchestrator.md` as its brief. It hands the state lock to the orchestrator for the wave and prints `orchestrator-w<wave> <attempt> <pid>`. Launching also reads the guardrail levels afresh and records their commits for the wave; the rules are in `${CLAUDE_PLUGIN_ROOT}/references/guardrails.md`, and the packet's guardrails table comes from `scripts/guardrails.sh table --run-dir <run folder>`.

Then tell the Artisan in two or three lines what is running and that you'll report when the wave ends, and **end your turn**. Don't poll, sleep, wait on the orchestrator or start a monitor: the wave runs without you, and a chat that waits spends its context on nothing.

### 6. When you're woken: check, report, carry on

You learn what happened from files alone. Whenever you are woken (the Artisan writes, a task notification or `notify_when_idle` notice arrives, or the session resumes), run:

```bash
ARTISAN_WRITER_PID=… ${CLAUDE_PLUGIN_ROOT}/scripts/wave.sh status <run folder>
```

The first line is the orchestrator's state from its exit record (`running`, `completed`, or `failed`/`not-completed` with a reason), the second is what to do next, then a ticket table. Once the orchestrator has ended, `status` takes the lock back for you and runs the reconciler (git, the sweep, the tracker) before printing. Notices are a convenience that may wake you sooner; nothing depends on them, and messaging can be off entirely.

| `next:` | Do |
|---|---|
| `wait` | The wave is still running. Say so in one line, with the table if asked, and end your turn. |
| `launch` | Report the wave (below), then launch the next wave (step 5) without asking: the Artisan approved the plan. |
| `halted` | A whole wave failed and the run stopped (`references/parallel-waves.md`). Report it with the decisions waiting, each with your recommendation, and wait for the Artisan; `wave.sh launch --resume` only on their say-so. |
| `decide` | Report the wave with the decisions waiting (the table `status` prints), each with your recommendation, and wait for the Artisan. |
| `blocked` | Nothing is dispatchable but tickets remain (a blocker outside the run, a `ready-for-human` ticket, or the tracker was unreadable). Report it and recommend what unblocks it. |
| `done` | Every ticket in scope is merged or closed: give the run summary (step 8). |

If the orchestrator ended `failed` or `not-completed` (crash, budget, deadline), launch again: the next orchestrator reconciles from the state file and carries the same wave on.

**The wave report** is a table, never a list:

| Ticket | Wave | Model | Status |
|---|---|---|---|
| #12 (retry failed uploads) | 1 | claude-sonnet-5-5 | merged as `a1b2c3d`, closed |
| #13 (billing tab) | 1 | claude-opus-5-5 | blocked: the suite failed after merging |

Under it, one line each for: cost so far against the budget (`.costs`, `.plan.budget_usd`), findings logged, review remarks not acted on, and what runs next.

Then the wave digest, as printed: `${CLAUDE_PLUGIN_ROOT}/scripts/evidence.sh digest <run folder>` (a table naming each ticket with its verdict, unsure and decision counts, and cost against its estimate; the contract behind it is in `${CLAUDE_PLUGIN_ROOT}/references/evidence-contract.md`).

### 7. Findings filed for triage

A finding is a fact a worker turned up that may matter to other work (its evidence record's `findings`, logged by the sweep). Between waves, file each finding that names missing work as a new ticket on the tracker, citing the ticket that found it, **off the frontier**: no blocking edges, no wave. Then run `/artisan-agent:triage` on it before it can join any run. A ticket a worker invented mid-run hasn't been grilled, sized or checked, and an untriaged finding entering the dispatch queue is how one worker's guess becomes three more workers' work. Only once triage admits it does it get edges, and it joins a run only through its own plan step and approval. If that changes the waves, show what moved before continuing.

Questions a worker filed for triage are not findings to file again: `${CLAUDE_PLUGIN_ROOT}/references/worker-questions.md` says how a blocked ticket waits on its question while the wave carries on, how `questions.sh sync` (run it whenever `wave.sh status` says `decide`, and between waves) redispatches it with the answer, and the "pull from the run or carry on" ask when triage defers one.

### 8. The run summary

When `status` says `done`, or the run halts, report:

| Ticket | Wave | Model | Outcome |
|---|---|---|---|
| #12 (retry failed uploads) | 1 | claude-sonnet-5-5 | merged, closed |
| #14 (export CSV) | 2 | claude-sonnet-5-5 | blocked: merge conflict in `export.py`; branch `agent/14` kept |

Blocked tickets and unmerged branches go at the top of the table, not buried: the value of an unattended run is knowing exactly where it stopped. Below the table: findings filed for triage (a second table: finding, from ticket, triage outcome), review remarks not acted on (count, by ticket), cost against the budget, and the integration branch ready for its PR to `main`. Release the state lock (`state.sh unlock <run folder> "$ARTISAN_WRITER_PID"`) once the run has ended.

## Failure handling

- **A worker fails or runs out of time.** The sweep counts the failed attempt; the orchestrator dispatches it once more with the failure evidence (two attempts in all by default), then it is blocked with a decision for the Artisan.
- **A worker reports success but the diff misses the expected output.** The orchestrator blocks it rather than merging. A result file is a claim; the merge is the fact.
- **A merge conflicts or the suite goes red after a merge.** `wave.sh merge` undoes the merge, blocks the ticket and queues a decision; the branch and worktree stay for inspection.
- **Everything in a wave fails.** The run halts: something upstream is wrong (a bad spec, a broken base, a missing setup step) and the next wave would fail the same way. Report it and wait for the Artisan.
- **A finding invalidates the graph.** Show the Artisan the new graph before the next wave. A silently reshuffled plan is one the Artisan never approved.

## Rules

- One worker, one ticket. Never batch tickets into one worker.
- Dispatch only on merged work. A ticket is dispatchable only when every blocker is merged into the integration branch, never when its worker merely reported `complete`; a blocker and its dependent are never in flight together. `wave.sh dispatch` enforces this.
- Neither tier writes product code. A conflict the orchestrator can't merge comes to the Artisan as a blocked ticket.
- Keep the chat's context small: read the status, result summaries and the tracker; never a worker's or orchestrator's transcript.
