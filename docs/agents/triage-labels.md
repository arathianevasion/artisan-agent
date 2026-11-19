# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the "Label in our tracker" column to match whatever vocabulary you actually use.

## Artisan Agent labels

Labels the Artisan Agent pipeline adds to upstream's five. They are used as written.

| Label | Meaning |
| ----- | ------- |
| `review-gate` | A review gate: holds its packet and blocks its dependents |
| `plan` | A plan: a chunk of tickets approved to run together |
| `in-run` | Being worked by a run; never re-triaged, edited or relabelled |
| `urgent` | Goes ahead of everything else |
| `deferred` | Deferred by triage; returns on its recorded condition |
