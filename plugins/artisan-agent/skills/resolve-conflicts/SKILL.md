---
name: resolve-conflicts
description: Take the one try at a merge conflict in a run's integration worktree. Resolves each conflicted file so both sides keep what they meant, stages it and reports RESOLVED or UNRESOLVED; it never commits, adds behaviour, edits a file that isn't conflicted or makes a design choice. The orchestrator calls it once when `wave.sh merge` exits 11, then runs `wave.sh resolved`, which commits the resolved merge and runs the full suite. Use only on a merge already in progress; it is not a general merge tool.
---

# Resolve Conflicts

You are taking the **one try** a run gives a merge conflict before the ticket goes to the Artisan. `wave.sh merge` has stopped a `--no-ff` merge of a ticket's branch into the run's integration branch halfway, conflicts in place, in the integration worktree you are sitting in. Resolve it if both sides can keep what they meant. If they can't, say so: an honest UNRESOLVED costs the Artisan one look; a wrong resolution costs them a broken integration branch they never saw coming.

You do not commit, abort, continue the merge, run the suite or touch the tracker. `wave.sh resolved` does all of that once you finish, and it checks your work: a file still unmerged, a conflict marker left behind or a change left unstaged makes it UNRESOLVED anyway, and a red suite undoes the merge.

## Inputs

From the prompt or the caller: the run folder and the ticket being merged. If either is missing, use `git rev-parse MERGE_HEAD` for the incoming side and carry on without the run's records.

## 1. Read what each side meant

- **The conflict:** `git diff --name-only --diff-filter=U` lists the conflicted files. Read each one in full, markers included, and `git diff` for its three-way view.
- **Incoming, the ticket's intent:** its evidence record (`<run folder>/<.tickets[t].result.file>` in `state.json`), its expected output (`.plan.tickets[t].expected_output`), and `git log --oneline HEAD..MERGE_HEAD`.
- **Ours, the integration branch's intent:** `git log --first-parent --oneline -n 10` names the tickets already merged; read the evidence record of each one that touched a conflicted file (`git log --first-parent --format=%s -- <file>`).
- `GLOSSARY.md` and any ADR in `docs/adr/` that the conflicted code touches. Keep the glossary's words.

## 2. Decide, file by file

A conflict is yours to resolve only when both sides can keep their behaviour in one result, and you can say how in a sentence. That covers additions side by side (two imports, two list entries, two new functions, two test cases), one side's edit inside code the other side only moved or reformatted, and both sides making the same change.

It is **not** yours, and the try is UNRESOLVED, when:

- both sides change the same behaviour differently, so keeping both is impossible and choosing one drops a ticket's work;
- resolving means choosing an interface, a name, a data shape or anything else another ticket owns (design never passes between workers);
- you would need to edit a file that isn't conflicted, or write code neither side wrote beyond the glue that joins the two (a comma, an import order, a merged argument list);
- you can't tell what one side meant from its record and its commits.

Choosing a side to make a conflict go away is never a resolution.

## 3. Resolve and stage

For each file you can resolve: edit it to the joined result, with every `<<<<<<<`, `=======` and `>>>>>>>` line gone, then `git add <file>`. Don't stage anything else. If one file is not yours to resolve, stop: a merge is resolved whole or not at all, so leave the rest as they are.

You may run a quick check that touches only the conflicted files (a syntax check, the one test file that covers them) to catch a broken join. Don't run the full suite; `wave.sh resolved` runs it. Remove anything your check created (`__pycache__/`, build output): the integration worktree must hold only the merge, and `wave.sh resolved` counts any file left behind as UNRESOLVED.

## 4. Finish

End with exactly one line, so the orchestrator can act on it:

```
RESOLVED: <file>, <file>: <one sentence: how both sides were kept>
UNRESOLVED: <one sentence: what the two sides disagree on, in the tickets' words>
```

The orchestrator then runs `${CLAUDE_PLUGIN_ROOT}/scripts/wave.sh resolved <run folder> <ticket>` after RESOLVED, or the same with `--gave-up "<your sentence>"` after UNRESOLVED. That sentence becomes the blocked ticket's reason in front of the Artisan, so follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`: plain words, the disagreement and not the mechanics.
