# Live proof: the two-tier run (#54)

`live.sh` runs a whole one-ticket run for real: an Engineering chat, an orchestrator and a worker, each a headless `claude -p` on `claude-sonnet-5-5` capped at `--max-budget-usd 0.50`. Each loads this plugin and `mattpocock-skills` with `--plugin-dir` under the normal login, with `--setting-sources project,local` and `--no-session-persistence`. It runs in a throwaway repo, and the fake tracker (`tests/fixtures/fake-gh`) stands in for GitHub, so nothing reaches a real tracker and no settings are touched. It is not part of `tests/run.sh` because it spends money.

```bash
SB=<a throwaway folder>
UPSTREAM_PLUGIN_DIR=~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/<version> \
  plugins/artisan-agent/tests/live-run/live.sh "$SB/live"
```

What it proves, against #54's criteria:

| Check | Criterion |
|---|---|
| A chat runs `/artisan-agent:implement-plan` on ticket #1: plan step with a `--set` override, state file, integration worktree, orchestrator launched | the run starts from the plan step |
| The chat's whole process group is killed the moment the orchestrator is up; the orchestrator and worker carry on; the orchestrator exits after writing state | detached tiers; killing the chat stops neither |
| A second chat, with no messages or notices, reports the ticket merged from `wave.sh status` (exit record plus sweep) | completion learned with messaging off |
| `run/live1`'s tip is a `--no-ff` merge of `agent/1`, the evidence record names that commit, the suite is green there, the ticket is closed with its evidence | merged, green, closed |
| The events run dispatch, result, merge, closed, in order | the state file reflects each event in order |
| A fresh verifier passed the ticket before the merge (events verify, verified), and the JSON folded into the ticket's evidence comment is the state file's contract (#57) | verifier per ticket; evidence on the ticket matching the state file |
| The main checkout's HEAD and tree never change | no session edits the main checkout |

The refusal of a ticket whose blocker isn't merged is proved at script level (`tests/wave.test.sh`).

## Last results (2026-11-11)

| Run | Outcome | Cost |
|---|---|---|
| live1 | 20 of 20 checks passed. It showed that the chat wrote the repo as a filesystem path, and that the costs were $0 because the sweep read the result before the session's output existed. Both are now fixed and tested. | worker $0.27, orchestrator $0.12, status chat $0.09; launching chat unknown (killed), capped at $0.50 |
| live2 | The chat sized the ticket at $0.10, so the worker's cap was $0.20 and both attempts ran out. The failure path worked live: retry with the failure evidence, then blocked, a decision queued, and the status chat reporting it as a table. `live.sh` now gives the chat the sample's expected size. | — |
| live3 | 22 of 22 checks passed | worker $0.29, orchestrator $0.11, status chat $0.10; launching chat capped at $0.50 |
| live4 (#57, 2026-11-10) | 24 of 24 checks passed: the real orchestrator followed the new brief (verify.sh start, wait, judge, then merge and close) and a real verifier passed the ticket | worker $0.26, verifier $0.08, orchestrator $0.21, status chat $0.10; launching chat capped at $0.50 |
