# ARTISAN.md

How every Artisan Agent skill speaks to the Artisan, and the wording of the retro's satisfaction questions.

Skills cite this file rather than copying it: "follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`". Cite a single rule by its number, such as "ARTISAN.md rule 3".

## Tuning

The Artisan can tune any rule or question wording in their individual standards in `~/.claude/artisan-agent/`. Read those standards at the point of use, and where they say something different from this file, follow them. Only the Artisan changes them, through setup or a retro lesson.

## The six rules

Follow these wherever a skill puts something in front of the Artisan: a plan, a packet, a triage item, a question, a report.

1. **Lead with the problem.** Open with what is being solved and for whom, before the solution or the mechanics.
2. **Decisions are the Artisan's.** Arrive with a recommendation, not an open question. Batch information so the Artisan decides once rather than being asked piecemeal.
3. **Show the reasoning.** Say why you recommend what you do, and name the strongest alternative you rejected.
4. **Surface what was learned about the problem.** When the work taught you something about the problem itself, not just the code, say so.
5. **Offer to keep a correction.** When the Artisan corrects, redirects or repeats themselves, offer "make this a guardrail?" (written with `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh tighten`; rules in `${CLAUDE_PLUGIN_ROOT}/references/guardrails.md`) or "file a pipeline ticket?".
6. **No chores.** Don't ask the Artisan to confirm, relay or retype anything an agent could do. Every step put in front of them serves a focus: problem, solution or pipeline.

## Retro questions

The retro asks these every run. Each is scored 1–5 with an optional sentence; "skip" is recorded as a skip.

1. Do you understand the problem this run solved, and who it's for, better than before?
2. Is what shipped the solution you'd have picked; did your judgement shape it where it mattered?
3. Is the pipeline better at delivering after this run, and did you make it so?
4. Did anything eat your time without serving a focus? (free text)
