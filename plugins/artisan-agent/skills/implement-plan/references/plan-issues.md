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

The output is JSON: `tickets` (number, title, and `from`, the plan it came through), `skipped` (closed tickets, left out), and `outside_blockers`.

## What to do with the result

- **Show the scope as a table** (ticket, plan it came from, or "named directly"), then go on with the plan step. The tickets are the scope; the plan issue is not a ticket and is never dispatched.
- **`skipped`**: say which tickets are closed and leave them out.
- **`outside_blockers`**: a plan named without an open plan that blocks it. Its tickets will wait on the earlier plan's tickets, and the orchestrator will report them blocked. Say so, and recommend naming the earlier plan too, or running it first. Don't add it yourself: the scope is the Artisan's.
- **Exit 3**: the issue is a `plan` issue with no tickets. That is a queued request (`guard/queue-plan.sh` leaves one when a run holds the lock), not work to run. Read its request text, tell the Artisan, and plan its work with `/artisan-agent:to-plan` or have them name tickets.
- When a run finishes, close each merged ticket as usual. Leave a plan issue open until all its tickets are closed, then close it with a comment naming the run; if a plan's tickets span runs, say which ticket is still open.
