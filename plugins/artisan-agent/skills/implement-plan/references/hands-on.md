# Hands-on tickets

Hands-on work keeps the Artisan's skill from eroding and meets the same quality floor as a worker's. The script is `${CLAUDE_PLUGIN_ROOT}/scripts/human.sh`; the tests are `tests/human.test.sh`.

## At plan approval (the Engineering chat)

1. Show the candidates: `human.sh suggest --draft <draft.json>` prints a table of each ticket's slack and the delay it would cost if built by hand. **Suggest at most one** hands-on ticket per plan, off the critical path (delay none), chosen for what the Artisan would learn, and **name the focus it serves**: understanding the problem, finding the best solution, or improving the pipeline (`GLOSSARY.md`, Focus). If none qualifies, suggest none.
2. A pick goes into the draft as `hands_on: {"ticket": "12", "focus": "…", "minutes": N}` (`minutes` optional: the time by hand, three times the worker's expected minutes if left out), with `blocked_by` (blockers inside the scope) on each ticket so the critical path can be found. `plan.sh build` refuses more than one, a ticket outside the scope, or no focus.
3. **If the Artisan picks a critical-path ticket**, `plan.sh render` shows its row in the "Hands-on ticket" table with the delay ("about 17 min later") and a line naming the tickets that will wait. Show it as printed and have the Artisan confirm the delay or choose another before the plan is approved.
4. After approval, label the ticket `ready-for-human` on the tracker (`gh issue edit <n> --add-label ready-for-human`).

## In the run

- The orchestrator runs `human.sh sync $RUN` after each reconcile, and `wave.sh status` runs it between waves. For each queued ticket in scope that is labelled `ready-for-human` (or is the plan's pick) and whose blockers are all merged, it adds a worktree `<repo>-wt/<run-id>-<ticket>.human` on the ticket's branch from the integration branch's tip, and records it in the ticket's `human` field. The ticket is **never dispatched**: the frontier leaves it out, and `wave.sh dispatch` refuses it. Its dependents wait, because dispatch refuses a ticket whose blocker isn't merged.
- Tell the Artisan the worktree path and that the ticket is theirs. `human.sh status <run-dir>` is the table of hands-on tickets.
- When the Artisan says it's **done**: `human.sh done <run-dir> <ticket>`. It refuses while the worktree has uncommitted work or no commit (exit 6). Otherwise the ticket becomes `returned`, with a result file describing the branch tip, and goes through the same steps as a worker's: `verify.sh start` and `judge`, `wave.sh merge` (the full suite, `--no-ff`, serially) and `wave.sh close`. If a wave is running (exit 3), the request stays filed and the next `sync` takes it; run `wave.sh launch` so an orchestrator verifies and merges it.
- **Show the Artisan the verdict:** `human.sh verdict <run-dir> <ticket>` prints the verifier's table (each criterion, met or not, the evidence, its notes). On `fail`, no worker is started and no attempt is used: the ticket goes back to the Artisan in the same worktree with what the verifier found, and they say "done" again. A second round is verified afresh.

## Parking

When the only work left is a hands-on ticket and what waits behind it (nothing in flight, nothing returned, no decision waiting, an empty frontier), `wave.sh status` says `next: parked` with a line naming the ticket and how many wait behind it, and logs one `parked` event. Say so to the Artisan: the run is waiting on them, not stuck. The dependency edges come from `blocked_by` in the plan; a plan without them is reported `blocked` as before. When the Artisan finishes, `done`, then `wave.sh launch` carries the run on.

## Retro

After a hands-on ticket, the retro asks what the Artisan decided that an agent would have needed (`${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`, retro wording).
