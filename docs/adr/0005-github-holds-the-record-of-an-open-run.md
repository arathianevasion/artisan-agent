# GitHub, not one machine, holds the record of an open run

An open run is recorded on GitHub, not only in one machine's run folder. Its integration branch `run/<id>`, a state snapshot on `runs/<id>` pushed after every wave, and its tickets' `in-run` labels together say that a run is open and where it stands. The run lock and a plan's "done" read that record: `run-lock.sh check` refuses a run while another machine holds one (#430), a plan is done only when its run branch is on main (#431), and each wave pushes its snapshot (#429).

Run p432-1126 started after the move from the cmux VM to the home PC (2026-11-25). The run folders from earlier runs stayed behind on the VM, so this machine's backstop and run lock could not see them. A run held, or left half-merged, on another machine looked like no run at all.

## Considered Options

- **The run folder on one machine (status quo):** simple, but a lost or replaced machine loses the record of every open run, and two machines can start runs in the same repo.
- **A shared filesystem or service for run folders:** one copy, but it adds infrastructure every machine must reach.
- **GitHub holds the record (chosen):** every machine that can run the pipeline already reaches GitHub, and branches, labels and pushes are durable and visible.

## Consequences

- `run-lock.sh check` makes network calls in implement-plan's precondition; hooks and sweeps use `--local` to stay on this machine.
- A remote-less project has no such record; its runs are known only to the machine that holds them.
- The local run folder is still the working copy; GitHub is the record when machines disagree.
