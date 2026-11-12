# Labels and the envelope approval (#124)

Two calls wire `chats.sh` (from #73) into the plan step. Which chat does what is in `${CLAUDE_PLUGIN_ROOT}/references/two-chats.md`.

| When | Call | Notes |
|---|---|---|
| Run start: right after `state.sh init`, before the first `wave.sh launch` | `chats.sh label-run --repo R <run folder>` | labels every in-scope ticket `in-run`, one comment naming the run; repeating changes nothing. Exit 1 means a ticket couldn't be labelled: say which, and carry on |
| The Artisan approved the envelope, but the run lock is held and the plan waits | `chats.sh approve-envelope --repo R <plan issue>` | records `<!-- artisan-agent:envelope-approved -->` on the plan issue |
| The Artisan approved the envelope and the run starts at once | no call | nothing is queued, so there is nothing to record |

## A queued, approved plan starts later

The Engineering chat's sweep prints `ACTION start-plan <issue> envelope-approved`. Rebuild the plan from the plan issue (`resolve-scope.sh`), show the envelope as information in a table, and go to `state.sh init` without asking for approval again. `ACTION start-plan <issue> approve-envelope` means no approval was recorded: ask as usual.

The same rule applies to `/artisan-agent:to-plan`'s approval step when the Artisan approves a plan's envelope there (see that skill's step 5).
