# Changelog

Every release of the `artisan-agent` plugin bumps `version` in `.claude-plugin/plugin.json` (semver) and adds an entry here, newest first. The script tests check that the two agree.

## 0.13.0 (2026-11-21)

Voice standards for everything the pipeline writes, a merge gate each project can place, and a suite that passes inside a Claude session.

- **Voice standards:** project setup seeds `VOICE_STANDARDS.md` from the plugin's default template (`voice-default v1`: rules R1–R19 and protections P1–P4, from unslop, MIT) and imports it beside the front-door pointer; a rerun adds only what's missing (#273). `ARTISAN.md` rule 7 says all prose a person reads follows the voice standards, resolved by who reads it (ADR 0003), and `implement`, `implement-plan` and `triage` cite them (#274). Machine setup seeds the individual voice file and offers its import in the user `CLAUDE.md` (#275).
- **Tuning the voice:** the retro proposes voice lessons and writes kept ones at the level you pick, in your own section, within a cap of about 1,500 tokens; the cap counts only kept lessons (#276, #300). Rule 5's "make this a guardrail?" can write a wording correction to the voice standards (`guardrails.sh voice`) (#278). A newer default arrives at the retro as one move per file, keeping rules you edited (#279). The upstream check covers rule 7 and flags upstream skills that now cover a default voice rule (#277).
- **Merge gate per project:** `merge_gate: local | ci` in a project's `.artisan-agent/config.yml` overrides the machine's `host.json`. `merge-gate.sh show` and the plan step name where the mode came from; a project `ci` with no gate workflow is refused (#343).
- **Suite inside a Claude session:** the test runner clears `CLAUDE_CODE_SESSION_ID` and `CLAUDE_SESSION_ID` for every test, three timing tests hold on work they control instead of wall-clock seconds, and no test writes outside its temp folder (#283).
- **Setup:** a section insert puts a list item after the section's list (#266), and setup passes `CLAUDE_CONFIG_DIR` to `claude` only when the caller set it (#267).

## 0.12.0 (2026-11-18)

Merge gates that ride out GitHub runner shortages, headless sessions kept out of `.claude/`, and run scripts that start half as many `jq` processes.

- **Runner shortages:** a CI merge gate whose only non-green jobs were cancelled because GitHub never assigned a runner ("not acquired by Runner") is no verdict. The gate reruns just those jobs after 15 minutes, then 30 (`ci_gate.runner_wait_minutes`), with no failed attempt charged and no base check. A shortage that outlasts both reruns parks the run on CI, naming the shortage and the jobs, instead of reading as a red suite. The suite record names the reruns (#258).
- **Write targets:** headless sessions can't write under a `.claude/` folder, so a run folder there would fail late. `state.sh init` now refuses one up front, `run-ticket.sh` checks every `--add-dir` it passes on, and the retro checks its work folder, each naming the protected folder. Reading under `.claude/` is still allowed (#249).
- **Fewer processes:** the run scripts read state with one `jq` call per step, not one per field or per ticket: `wave.sh` dispatch, merge, launch and status, `verify.sh`, `gate.sh sync`, `guardrails.sh wave-start`, `budget.sh guard`, `classify-worker.sh`, `reconcile.sh` and `sweep.sh`. Each state write is one `jq` call that checks, writes and makes the status line. On the ten slowest tests, `jq` starts fall by half and wall time by about 28%. Behaviour is unchanged; `tests/helpers/measure-procs.sh` measures it (#185).
- **Docs:** `scripts/README.md` says `wave.sh start` runs `worktree_setup` and exits 6 when it fails (#257).

## 0.11.0 (2026-11-18)

Runs that don't stall on overage-only accounts, setup that follows the run, a status file for the cockpit, and to-spec checking the spec against your motivation.

- **Usage guard:** on an account with no plan windows (overage billing only, or an API key), a worker's rate-limit events that carry no five-hour or seven-day window are recorded as a fresh "no plan windows" reading. `budget.sh verdict` is then ok, and the budget limits spend, instead of parking every wave down to one ticket at a time. A fresh plan-window reading from any source is still judged as before, and a worker that has seen a plan window never claims none (#251).
- **Worktree setup:** `worktree_setup` and its timeout come from the run's `plan.config`, so a `state.sh override` counts, and fall back to the project config. Dispatch, the verifier, hands-on, the end gate and now `wave.sh start` all read it in one place. `wave.sh start` sets up the integration worktree; a failing setup exits 6 and leaves no worktree or branch behind. The plan warns under Needs your attention when a project with a `package.json` has an empty `worktree_setup` (#252).
- **Run status file:** every state write and lock hand-over rewrites `status.json` in the run folder: wave, counts, cost against budget, `next`, waiting on the Artisan, the last event's time, the owning chat and the lock holder, and a text line under 100 characters. It is for display (the Agent Cockpit); nothing in the plugin reads it back. `wave.sh status` and the file share one chain for `next` (#192).
- **to-spec:** before showing the draft, to-spec reads the "Always ask" lines and, if present, `motivations/<repo>.md` in the individual home. Conflicts and sharpening points go under their own Motivation check heading beside the additions, answered in the same batch. The spec never carries text from the motivation, and scope never widens to match it without your yes (#250).

## 0.10.0 (2026-11-16)

Fewer gates that hold nothing, criteria a run can read and judge, a Run chat that wakes when a wave ends, working retro sessions, and local suites at background priority.

- **Folded risk gates:** a risk gate whose ticket no unmerged ticket in scope depends on opens no issue of its own. Its section goes into the next slice gate covering its ticket, else the end gate, and answering that gate answers it. The events still record it for guardrail health and the retro. At the plan step the gate table shows it as "folded into <gate>", and `gate-plan.sh keep` keeps it as its own gate (#241).
- **Criteria:** more wordings of a CI outcome for the merged work ("CI check job is green on the merged commit") are left to the merge gate. A fact measured on the run's PR or CI run after merge (a wall time, a run id) is flagged at the plan step as a Human check and never fails a verifier attempt (#244). The criteria reader takes a triage brief headed `Agent brief (…)` with or without the disclaimer, and the plan step refuses a ticket whose criteria it can't read (#225).
- **Run chat wake-up:** `wave.sh launch` prints the wait step. `wave.sh status` and the run digest say when an orchestrator runs with no `wave.sh wait` on it, so a chat holding older skill text still starts the wait (#237).
- **Retro:** the prices agent is granted the prices file, the pricing page and its answer file, and a check that writes nothing reports "price check failed" with the denied calls. The preparer reads the Artisan's turns from the run folder, and a denied tool marks the focus shares incomplete (#245).
- **Guardrail health:** the backstop limits PRs by `--since` and counts a run's own gate, plan, end-gate, urgent and retro issues and PRs as the run's (#246). The open-decision guardrail's loosen evidence counts only rulings on open decisions (#239).
- **Background priority:** every suite and recorded check the pipeline starts on this machine (`checks.sh run`, the local merge gate, `end-gate.sh urgent-finish`) runs at background priority: `taskpolicy -b` on macOS, `nice -n 10` (inside `ionice -c 3` where it works) on Linux. `local_suite_priority: normal` in `host.json` opts a machine out. A missing priority tool runs the command at normal priority with a note (#248).

## 0.9.0 (2026-11-15)

Open decisions: a worker, the verifier, the plan step or a gate can file a decision no ticket should settle on its own, and it reaches you in the Decision chat. The two chats are renamed the Decision chat and the Run chat.

- **Filing open decisions:** criterion 8 lets a worker file an open decision with its case, harm and recommendation (`questions.sh file --criterion 8`; `references/open-decisions.md`). A worker's own is blocking or split, never non-blocking (#227). The verifier names open decisions in its verdict without changing the outcome, and the sweep files each one split, once (#230). One a worker finds in another ticket sits on that ticket without blocking it (#231).
- **Rulings:** triage can rule Answer, Reject, Add ticket, Defer or Discard, and each ruling records both verdicts. An "Add the block:" ruling adds the blocking edge (#228, #231). A Defer or Discard on a non-blocking decision never pulls or redirects a ticket that already merged (#238).
- **Plan step and gates:** the plan step flags each draft ticket's open decisions under Needs your attention, and `state.sh init` refuses while one stands; `--override-open-decision` keeps a ticket with a reason, and `plan.sh drop` files its decisions and removes it with its dependents (#229). A gate packet numbers its uncertainties; `gate-action.sh triage` files a card or uncertainty as an open decision, and the end gate cuts no PR until each is ruled (#232).
- **Guardrail health:** a built-in open-decision guardrail. Decisions raised at a gate or after merge tighten it (#233).
- **Retro:** the balance between autonomous throughput and your leverage: each ruling counts as one of your actions, one that took the recommendation is a rubber stamp, and gate and open-decision waits are shown side by side, with a trend over five runs (#234).
- **Decision chat and Run chat:** every skill, reference, script message, template and the README use the new names. `chats.sh --chat decision|run` still accepts the old names, and a static test catches them (#235). The glossary and ADR 0002 define them.

## 0.8.1 (2026-11-15)

Fixes for large runs, leftover worktrees and branches, criteria in triage comments, merge-gate reuse, and named sessions.

- **Large runs:** JSON that grows with the run reaches jq on stdin, never as an argument past Linux's 128 KiB limit, with no temporary files left in the checkout or run folder (#208). A gate packet over GitHub's 65,536-character body limit opens as one issue whose body and numbered comments hold it whole, and every lookup for an existing issue reads all of them, not the first 30 (#209).
- **Criteria where they live:** `to-plan.sh graph`, `split-human-check`, `wave.sh close` and the unmeetable gate read and write a ticket's criteria in its body or its triage comment (#215). Criteria changed at an unmeetable gate show on the closed ticket: rewritten, or struck through as dropped or moved with the gate's number (#220). The plan step flags criteria that need CI, a PR or the full suite, which the merge gate already checks, and rework tickets no longer add "The full suite passes" (#213).
- **Cleanup:** a dispatch stopped after making its worktree leaves one the retry reuses, or blocks on if it holds work (#210). Ticket branches the plugin pushes are deleted from the remote once their ticket is done, unless someone else pushed to them; a failed delete is retried by the next sweep (#211).
- **Merge gate:** reusing a worker's green CI run checks the run itself: the gate workflow, dispatched with default inputs shown in its run name, on the same tree (#212).
- **Orchestrator:** its dollar cap scales with its turn limit (`orchestrator_usd_per_turn`, default 0.025: $2.00 at 40 turns, $6.50 at 130; #216). Orchestrator and verifier sessions are named by repo, wave and plan, such as "claudia-kerman · Wave 3 · Contract integration" (#189).
- **Headless steps:** the retro's upstream judge and price check launch with the headless permission arguments, and a test fails any `claude -p` launch without them (#214).
- **Docs:** README's Script tests section matches `tests/run.sh` and the CI jobs; the glossary defines merge-gate and unmeetable criteria; a tracked `.pyc` file is gone and ignored (#217).

## 0.8.0 (2026-11-15)

Headless steps that never hang on a prompt, exception gates for criteria no worker can meet, project boards for plugin issues, and setup and end-gate fixes.

- **Headless steps:** every headless `claude -p` step (orchestrator, workers, verifier, retro preparer) launches through one helper in `--permission-mode dontAsk` with its allowlist, so a tool outside the list is denied at once instead of waiting on a prompt, even under a `claude` wrapper with hooks (the cmux shim). The exit record counts `permission_denials`. The retro preparer's allowlist covers its read-only commands (#187).
- **Unmeetable criteria:** a worker may list a criterion no worker can meet. If the verifier agrees, the ticket goes to an exception gate instead of using another attempt: `split --human` or `--ticket`, `rewrite --as`, `drop-criterion --why`, or `retry`. After a change, a fresh verifier judges the same commit (#186).
- **Project boards:** one helper, `tracker.sh new-issue`, opens every plugin issue. With `tracker.board` set (setup reads it from the tracker doc), Human checks, findings, rework, plan and split tickets go on the project with the source ticket's Area. A board failure leaves the issue created and the next sweep adds it (#146).
- **`worktree_setup`:** a `worktree_setup_timeout` kills a hung setup command and its process group, failing the attempt with `setup timeout` (#181). At the end gate, a setup failure is recorded as a decision you can retry (#182).
- **Orchestrator exits:** `run-ticket.sh`'s exit hook records an unclean orchestrator exit itself, once, whether or not `wave.sh wait` is running (#184).
- **Main-checkout guard:** `main_checkout_runtime` lists folders sessions may write in the main checkout (this repo lists `.claude/orchestrator/`); `..` and symlinks can't escape them (#191).
- **Fixes:** `split-human-check` and `to-plan.sh graph` read criteria under the triage template's `**Acceptance criteria:**` label as well as the heading (#202). An unpark message says "merge batch" (#183). `state-file.md` and `scripts/README.md` keep one entry per line, with a test, so parallel tickets stop conflicting (#207).

## 0.7.1 (2026-11-14)

Fixes from riley's run p266-1114, and CI work: faster tests, flaky-test handling, smarter red merge gates and cheaper worker CI.

- **Fixes from riley's run:** a review gate is recorded however large the run state is; it was passed to jq as one argument, which Linux refuses over 128 KiB. `gate.sh sync` records a gate whose issue is already open without opening another (#203). `findings.sh pending` and `mark` skip a finding with no `blocks` list instead of failing for every finding (#204). An urgent ticket is dispatched when nothing else is in flight (#205), and reconcile no longer records it merged as soon as it is dispatched (#206).
- **Red merge gate:** reruns the failed jobs and runs the base. A rerun that passes merges and files a flaky finding; a base that fails the same tests parks the run (`base-red`, `wave.sh unpark-base`); only new failures cost an attempt. Each gate logs its CI wait (#195).
- **Worker CI:** each check says whether workers can run it (`runs_locally`: `always`, `mac`, `never`). A worker gets CI green on its branch for a check it can't run, and the merge gate reuses that run when the merged tree is the same (#194). The workflow has a `macos` input, so a worker's branch run can be Linux only (#197).
- **Costs and limits:** the retro and run summary show what the merge gates cost: gates per merged ticket, CI minutes, reds by cause, and time waiting on the Artisan (#199). A `merge_gate_minutes_limit` (default 6) adds a line to the plan approval and the retro when gates run over it (#200). Setup offers a read-only CI checklist, with each item's trade-off in `references/ci.md` (#196).
- **Tests:** settable poll intervals make the script tests 37% faster (CI Linux 6.3 to 3.2 minutes; #169). `tests/run.sh --rerun-failed` reports a test that passes on rerun as `FLAKY`, and `tests/quarantine.txt` lists tests that can't fail the suite while their issue is open (#198). The macOS deadline test no longer races a whole-second clock, and a deadline never fires early (#190).

## 0.7.0 (2026-11-14)

Fixes from riley's run on 0.5.0, merge batches, faster CI, and Human check and gate follow-ups.

- **Never fails silently:** an orchestrator that exits leaving tickets without a verdict (non-zero exit, max turns, budget, deadline, unmerged) queues an `orchestrator-exit` decision, wakes the chat and pushes a notification naming the cause; status never says launch (#171).
- **Criteria:** taken from the triage Agent Brief comment when the body has none, with the source recorded; a plan with a ticket that has no criteria anywhere is not approvable (#172). A criterion only the merge gate can show (PR or CI green) is `"met": "gate"`, checked by the merge gate, and the templates stop writing PR criteria (#174).
- **`worktree_setup`:** a project command (such as `npm ci`) runs in every worker, verifier, hands-on and end-gate worktree; a failure is reason `setup` (#173).
- **CI and the merge gate:** one-turn waits on CI gates and an orchestrator turn budget that scales with tickets and CI gates (#175); a red CI gate is a failed attempt, retried with the failing tests named, and an exception gate only when attempts run out (#176); a run halts only when a whole wave failed and none of it passed verification (#177).
- **Merge batches:** tickets ready together are gated with one CI run and split on red (`merge_batch`, default on; #167), set with `machine-setup.sh merge-batch` (#180); a release commit that only changes version and changelog files over a green commit skips CI (`merge_gate_skip_paths`; #168). Merge batch is in the glossary (#179).
- **Gates:** a slice gate holding a ticket that left the run comes due, or closes as empty (#164); a slice gate holds its outside dependents from plan approval (#170); the end gate's Human checks name their agent ticket (#163); a failed Human check refuses another answer until its rework merges (#165), and `defer-check` and the slice gates honour that (#178).
- **CI:** the macOS job runs as three shards, cutting a run from 10-12.5 to about 6 minutes (#166).

## 0.6.1 (2026-11-14)

Human checks follow-ups and a config fix.

- `plan.sh build` reads a ticket's acceptance criteria from its issue when the draft has none, so Human check flags see every ticket; a draft's own list wins, and an issue that can't be read is named on stderr as unchecked (#160).
- A Human check leaves the run with its dropped or resliced agent ticket: it goes back to needs-triage with a comment naming that ticket, the Impact line names it, the gates no longer list it, and `stranded`/`send-back` handle one left behind (#161).
- `state.sh init` records a planned Human check from the plan graph, so it is one from the first moment of the run; an end-to-end test fails a Human check at the end gate, with and without `--not-bug` (#162).
- `config.sh` outside a git repository, with no `--file`, exits 1 with nothing on stdout instead of printing `{}`; `plan.sh build` uses the defaults there (#159).

## 0.6.0 (2026-11-14)

Human checks: an acceptance criterion only a person can confirm no longer fails an agent's attempts.

- The plan step flags agent criteria that need a person; `split-human-check` moves them into a Human check ticket (ready-for-human) linked to its agent ticket, and an override with a reason keeps one on the agent ticket. Human check is in the glossary (#156).
- A run never dispatches or waits on a Human check. Slice gates list the open ones; answer with `gate.sh check <run> <n|all> pass|fail|later`. The end gate will not approve while one is open, and `defer-check` defers one there (#157).
- The verifier has a third state, "human", for a criterion only a person can verify: the judge passes the ticket on the rest and splits those criteria into one Human check in the run, and a retry worker is told which criteria are not its to meet. A hands-on ticket's verdict names its Human check, which it never waits on (#158).

## 0.5.1 (2026-11-14)

Pilot fixes for a run in progress.

- The run-start hook lets the chat that holds the run carry on with it, whatever it asks; another session's "continue", "carry on", "resume" or "pick up" the run passes as a resume, and a request naming the running run is never filed as a plan issue (#153).
- `sweep.sh repair --dry-run` shows what the repair would change without taking the lock or writing anything, so it runs on a live run (#154).
- A gate closed by hand on the tracker logs one keep decision, the same as "keep all"; tests now pin it (#155).

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
