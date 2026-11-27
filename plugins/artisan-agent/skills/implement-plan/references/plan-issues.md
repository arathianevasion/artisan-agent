# Plan issues as a run's scope

A **plan** that `/artisan-agent:to-plan` created is an issue labelled `plan`. `implement-plan` accepts one, several, or plans mixed with single tickets as the run's scope. `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-scope.sh` turns what the Artisan named into tickets; the plan step then works on tickets as always.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/resolve-scope.sh --repo <owner/name> <issue>...
```

| What was named | Becomes |
|---|---|
| a `plan` issue | its tickets: its sub-issues, or, when it has none, the `- [ ] #<n>` list in its body |
| a ticket | itself |
| several | each ticket once, in the order named (a ticket named twice, or reached by two plans, appears once) |

The output is JSON: `tickets` (number, title, and `from`, the plan it came through), `skipped` (closed tickets, left out), `outside_blockers`, and `plans` and `spec` (the plan issues named and the spec they came from, copied into the draft: they name the run's orchestrator sessions).

## What to do with the result

- **Show the scope as a table** (ticket, plan it came from, or "named directly"), then go on with the plan step. The tickets are the scope; the plan issue is not a ticket and is never dispatched.
- **`skipped`**: show which tickets are closed in the same table (status "closed, left out") and leave them out.
- **`outside_blockers`**: a plan named without an open plan that blocks it. Its tickets will wait on the earlier plan's tickets, and the orchestrator will report them blocked. Show them in a table (plan, open blocking plan) and recommend naming the earlier plan too, or running it first. Don't add it yourself: the scope is the Artisan's.
- **Exit 4**: a named plan is blocked by a closed plan whose work isn't on main (`plan-done.sh`, below). The plan step refuses it: show the message (the plan, its blocker plan, and each ticket with the branch it is on) and recommend merging that run branch into main first. Don't start the plan.
- **Exit 3**: the issue is a `plan` issue with no tickets. That is a queued request (`guard/queue-plan.sh` leaves one when a run holds the lock), not work to run. Read its request text, tell the Artisan, and plan its work with `/artisan-agent:to-plan` or have them name tickets.
- When a run finishes, close each merged ticket as usual. A plan is done only when its tickets' work is on main, not when its tickets are closed (#431). Before closing a plan issue, or reporting one done, run the check:

  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/plan-done.sh --repo <owner/name> <plan issue>
  ```

  Exit 0 (`done: true`): close it with a comment naming the run. Exit 3: leave it open, and say why in a table: each ticket in `open` (still open) and in `not_on_main` (closed, but its run's integration branch, named in `branch`, isn't merged into main). If a plan's tickets span runs, `not_on_main` names each run's branch. `unrecorded` lists closed tickets no run merged (closed by hand or a human check); they don't hold the plan back. A squash- or rebase-merged run isn't recognised yet (#409).
