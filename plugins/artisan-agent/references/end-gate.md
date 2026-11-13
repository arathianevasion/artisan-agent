# Gate placement, risk gates, the end gate and PRs to `main`

How the plan step places a run's **gates** (GLOSSARY.md), when a **risk gate** fires, and how a run ends: the **end gate**, the PRs to `main` along the PR-boundary guardrail, the `in-run` labels coming off and the retro. Built in #71, on the slice gate (#65, `references/review-gates.md`), the gate actions and exception gates (#70, `references/gate-actions.md`) and the context drain's risk gate (#59). Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/gate-plan.sh`, `gate.sh` and `end-gate.sh`. Tested in `tests/gate-plan.test.sh`, `tests/risk-gates.test.sh` and `tests/end-gate.test.sh`, with the fake `gh`.

Skills cite this file rather than copying it.

## Gate placement (the plan step)

The plan proposes one slice gate per slice, a risk gate for every ticket meeting an escalation test, and the end gate. The Artisan approves, moves or removes them in the same approval as the rest of the plan (job 10).

1. While designing each worker (step 2 of `skills/implement-plan/SKILL.md`), record in the draft, per ticket, the escalation tests it meets, as `escalation`: the same tests that decide its model.

   | `escalation` | The test |
   |---|---|
   | `new-seam` | a new seam or module boundary |
   | `tracer-bullet` | the first tracer bullet through a new layer |
   | `vocabulary-adr` | a change to vocabulary or an ADR |
   | `judgement-criteria` | acceptance criteria that read as judgement rather than behaviour |

   Also record the draft's `route` (`feature`, `small-change` or `bug`; default `feature`), each ticket's `slice` (from the to-plan graph; none means its own slice) and `plan` (its plan issue, for a per-plan PR boundary), and, for a bug, the ticket's `failing_test` (the test named in its acceptance criteria).
   For areas (#77) nothing more is recorded: they come from each ticket's `expected_files`, which the plan step already writes (`skills/implement-plan/SKILL.md`, "Expected files").
2. `gate-plan.sh propose <draft.json>` writes the draft's `gates` and prints them as a table: gate, kind, when it opens, why, and whether it can be removed.
3. Show the table under `plan.sh render`'s. The Artisan's changes:

   | The Artisan says | Call |
   |---|---|
   | remove a gate | `gate-plan.sh remove <draft.json> <gate-id>` (slice, risk or end) |
   | move a slice gate | `gate-plan.sh move <draft.json> slice-N --after T` or `--tickets T,T` |
   | move a risk gate | `gate-plan.sh move <draft.json> risk-N --after T` |

   Each prints the table again. Ids are positional, as the run numbers them (`slice-<n>`, `risk-<n>`, `end`), so read them from the last table shown.

**Areas.** Config `areas.<name>` has `paths` and `gates` (`slice`, `risk` or both). `propose` puts a ticket in every area an entry of its `expected_files` overlaps (the entry equals the area path, lies inside it, or is a directory holding it; matched as `parallel-waves.md` matches overlap, through `scripts/lib/paths-lib.sh`; an area path with no trailing `/` also counts as a directory), writes `tickets.<t>.areas` (which the plan, and so the packet's "Areas" section, carries) and names them under the table. An area's `gates` is what its tickets get: `slice` a slice gate of the ticket alone, `risk` a risk gate (test "area <name> gate setting", joined with any escalation tests into the ticket's one risk gate). A ticket in several areas gets the union: the strictest setting wins. A ticket with no `expected_files` may touch anything (`parallel-waves.md` runs it alone for that reason), so it is in every area and gets the strictest settings; the Artisan can remove a gate it did not need. An empty list touches nothing. With no areas configured nothing changes.

**Exception gates can't be removed or moved.** They are never placed in the plan: the run opens one whenever it gives up on a ticket, its check won't go green or the budget overruns (`references/gate-actions.md`), whatever `plan.gates` says. `gate-plan.sh` refuses any `exception*` id (6).

**The end gate has one place**, after every ticket in scope and before the PRs to `main`; `move end` is refused (6). Removing it means the PRs are cut without that review, but the boundary is still approved first (below).

**A Small change or Bug** gets no slice gate: the end gate doubles as one (`doubles_as_slice`), carrying the workers' decision cards and the evidence. A ticket meeting an escalation test still gets its risk gate. For a bug the end gate's packet leads with the failing test, the core of its verification (`bug: true`).

The plan's `gates` entries:

| Entry | Gate |
|---|---|
| `{kind: "slice", slice, tickets?, after?, ...}` | a slice gate (`references/review-gates.md`) |
| `{kind: "risk", after: "<t>", tests: [...]}` | a risk gate on ticket `<t>` |
| `{kind: "end", doubles_as_slice?, bug?}` | the end gate |

## Risk gates

A risk gate holds only the dependents of one merged ticket, until the Artisan answers it. Nothing else in the run waits. Three things raise one:

| Raised by | When | How it is held and answered |
|---|---|---|
| a planned risk gate (an escalation test) | the ticket merges | a `review-gate` issue, `Risk gate: #<t> (<title>), <test> (run <id>)`, opened by `gate.sh sync` (from `wave.sh close` and `wave.sh status`) like a slice gate of one ticket: the same packet, native blocking of the dependents, `gate_holds` before it opens, and every answer (`gate.sh approve`, `change`, `guardrail`; `gate-action.sh redirect`, `bypass`, `defer`) |
| a new-seam card: a decision card in the ticket's evidence naming controversy criterion 3 (#87) | the ticket merges | the same, id `risk-seam-<t>`, `Risk gate: …, new seam (decision card) …`; none where a planned risk gate already covers the ticket |
| a merge processed at the review band (50% context or more) | the orchestrator runs `drain.sh gate` after the merge (`skills/implement-plan/references/context-drain.md`) | `tickets.<t>.context_risk` (the percentage), then a `risk-context-<t>` review gate and a `review-gate` decision, as for any risk gate. A state file from before this holds `tickets.<t>.risk_gate`, which still holds dependents and is cleared with `drain.sh gate-cleared` |

The first two are computed from the plan and the evidence alone (`slice_gates` in `scripts/lib/state-lib.sh`), so a crash between the merge and the issue still holds the dependents. A gate the Artisan removed at the plan step still fires on a new-seam card: new seams are never left unreviewed.

**For the retro**, every risk-gate answer records its job (13) and whether the Artisan changed anything: `changed` on the `review-gate` decision (a card changed or a rework ticket made), `changed: false` on a legacy `risk-gate` decision cleared with `drain.sh gate-cleared`.

## The end gate

When `wave.sh status` says `done`, run `end-gate.sh status <run>`. It says `due` once every ticket in scope is merged, closed or out of the run at a gate.

1. **Open it:** `end-gate.sh open <run>`: a `review-gate` issue, `End gate: run <id>`, holding the packet, and an `end-gate` decision. Show the Artisan `end-gate.sh packet <run>`.
2. **The packet**, top to bottom:
   - for a bug, **the failing test**: each ticket's `failing_test`, `proven` when a met criterion's evidence names it, else **needs you**;
   - when it doubles as the slice gate, the slice packet over every merged ticket (decision cards, uncertainties, evidence by criterion); otherwise the tickets and their outcomes;
   - **the deferred gates** of both kinds, still waiting here (`gate-action.sh deferred`);
   - **the cards carried from gates closed on GitHub** (`gate.sh carried`, #73);
   - **the PRs to `main`**: the boundary and where it came from;
   - the overall action.
3. **Deferred gates first.** `end-gate.sh approve` is refused (6) while any gate is still deferred. Answer each where it is: a review gate with `gate.sh approve` or `gate.sh change` (a finding becomes a rework ticket), an exception gate with `gate-action.sh` (`references/gate-actions.md`).
4. **Approve:** `end-gate.sh approve <run> [--boundary slice|plan|ticket] [--why W] [--changed]`. It closes the issue with the decision, decides the `end-gate` decision (job 13, `by`, `changed`) and records `end_gate.boundary`.

## PR boundaries

Job 17, "Set PR boundaries", is approved until a guardrail covers it, then autonomous. `end-gate.sh boundary <run>` reads the `pr-boundaries` guardrail as setup (#64) records it, at whichever level it was set, by the precedence in `references/guardrails.md` (product, then team, then individual):

| Level | Where |
|---|---|
| product | `CODING_STANDARDS.md` in the main checkout's `HEAD`, the line `` - `pr-boundaries`: one PR per <slice\|plan\|ticket> `` |
| team | the same line in `CODING_STANDARDS.md` of the team guardrails repo (`team_guardrails_repo`), as cloned in `ARTISAN_TEAM_CACHE` by `guardrails.sh` |
| individual | the same line in `CODING_STANDARDS.md` in the individual home (`ARTISAN_HOME`) |

**With a guardrail**, the boundary is applied without asking. **With none**, the end gate proposes one PR per slice (each reviewable end to end) as an approved step: `approve` is refused without `--boundary`, and the Artisan's choice is recorded as a `pr-boundary` decision (job 17, `changed` when it differs from the proposal). A `--boundary` given over a guardrail is the Artisan's override, recorded the same way.

## Cutting the PRs

After approval:

1. `end-gate.sh prs <run>`: the PRs as a table. Merged tickets are grouped by the boundary (a ticket; its `slice`, else its own; its `plan`, else the run), a rework ticket with what it reworks. Groups are ordered by their last merge and **stacked**: PR 1 into `main`, PR n into PR n-1's branch, `pr/<run-id>/<n>`.
2. For each PR in order, write its body with upstream `pr` (`/mattpocock-skills:pr`) into a file, then `end-gate.sh cut <run> <n> --body-file F [--title T]`. When a group's merges are consecutive on the integration branch, its branch is the integration branch's own merge commit; otherwise the group's merges are cherry-picked onto the previous PR's branch, and a merge that won't apply on its own is refused (6) with the advice to choose another boundary. The branch is pushed when the repo has an `origin`. Cutting again prints the same URL.
3. `end-gate.sh finish <run>`, once every PR is cut: removes `in-run` from every ticket in scope, records `run-ended`, and prints the retro offer. Then give the run summary and offer `/artisan-agent:retro`.

## State

`end_gate`: `{status: open|approved|ended, issue, title, opened_at, approved_at, by, boundary: {value, source: guardrail|approved, level?, by?}, prs: [{n, branch, base, tickets, url, at}], ended_at}`. Decisions of kind `end-gate` (job 13) and `pr-boundary` (job 17). Events `gate-opened` (`kind: "end"`), `end-gate-approved` (`by`, `boundary`, `source`, `changed`), `pr-cut` (`n`, `branch`, `base`, `tickets`, `url`) and `run-ended` (`prs`). `review_gates[].kind` is `slice` or `risk`. Details in `references/state-file.md`.
