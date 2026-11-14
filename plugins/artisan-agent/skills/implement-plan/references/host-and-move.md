# Moving a run between machines

A run lives on one machine at a time: the always-on host once one is configured (`host_configured` in the config; `${CLAUDE_PLUGIN_ROOT}/skills/setup/HOST.md`), otherwise the laptop. `implement-plan move` sends a run to the other machine, in either direction, once it is idle. The script is `${CLAUDE_PLUGIN_ROOT}/scripts/move.sh`; the files it writes are in `${CLAUDE_PLUGIN_ROOT}/references/state-file.md` ("Where a run lives"). Tested in `tests/move.test.sh` with two clones and a bare remote.

## The steps

| Step | Machine | Do |
|---|---|---|
| 1. Drain | where the run is | `move.sh drain <run-dir>`, then launch no more waves: it halts the run for the move, so `wave.sh launch` is refused (12). Let the running orchestrator finish its wave; its workers end on their own. Do not interrupt a worker |
| 2. Push | where the run is | `move.sh out <run-dir> [--wait SECONDS]`. It refuses (4) until nothing is running: no ticket in flight, no live runner, no other holder of the run lock. Then it pushes the integration branch, each unmerged ticket branch, and the run's state folder to the `runs/<run-id>` branch, and marks this copy **moved** |
| 3. Resume | the other machine, in a clone of the repo | `move.sh in <run-id>`. It claims the run, puts the state folder, the integration branch with its worktree and the ticket branches in place, and prints the run folder. Then carry on as for any open run (step "An open run first" in `SKILL.md`): the run digest, then the next wave |

## Why a run is never live on two machines

The run's `location` travels with its state. `out` writes `moved` into this copy and into the pushed copy, and every writer takes the state lock, which refuses (exit 3) a run that is moved away or live elsewhere. `out` is two-phase, so the run is never live in two places: after the branches are pushed it marks this copy moved with a `pending` flag (and the snapshot's commit), and only then pushes `runs/<run-id>`. A refused push puts this copy back to live (a `move-out-undone` event) and exits 6. If `out` dies in between, this copy is moved and the remote is not yet claimed, so the run is live nowhere; running `out` again pushes the stored snapshot, or, if the push had already landed, just clears the flag. Another machine can `in` the run as soon as the push lands, whether or not `out` lived to finish. `in` claims the run by pushing one commit on top of `runs/<run-id>`, **fast-forward only**: of two machines resuming at once, exactly one push lands and the other is refused (6). A machine that finds the branch live on another machine refuses (5). To bring it back, the machine holding it does `out`, and the first does `in`. The run folder is git-ignored, so the branch carries it as a snapshot commit on top of the integration tip; `.artisan-agent/runs/` stays out of the working trees.

## Rules

- A running merge gate (`.merge_gate` set, its process alive or dead) makes the run not idle: `move.sh out` waits for it (`--wait`) or refuses with exit 4, since the integration branch holds an ungated merge commit. Let the gate finish and `wave.sh merge` record it.
- Never move a run that is not idle, and never copy a run folder by hand: the lock and the location would not travel.
- Ticket worktrees are never moved; the receiving machine makes the integration worktree (`wave.sh start`) and each ticket gets a fresh worktree when it is next dispatched.
- A context hand-off while draining is refused like any launch; let the orchestrator finish its wave in place.
- The run's cost, events and decisions are in the state file and move with it, with `moved-out` and `moved-in` events.
