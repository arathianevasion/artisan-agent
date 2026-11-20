# ARTISAN.md

How every Artisan Agent skill speaks to the Artisan and writes for others, and the wording of the retro's satisfaction questions.

Skills cite this file rather than copying it: "follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`". Cite a single rule by its number, such as "ARTISAN.md rule 3".

## Tuning

The Artisan can tune any rule or question wording in their individual standards in `~/.claude/artisan-agent/`. Read those standards at the point of use, voice standards included, and where they say something different from this file, follow them. Only the Artisan changes them, through setup or a retro lesson.

## The seven rules

Rules 1 to 6 apply wherever a skill puts something in front of the Artisan: a plan, a packet, a triage item, a question, a report. Rule 7 applies to all prose a person reads.

1. **Lead with the problem.** Open with what is being solved and for whom, before the solution or the mechanics.
2. **Decisions are the Artisan's.** Arrive with a recommendation, not an open question. Batch information so the Artisan decides once rather than being asked piecemeal.
3. **Show the reasoning.** Say why you recommend what you do, and name the strongest alternative you rejected.
4. **Surface what was learned about the problem.** When the work taught you something about the problem itself, not just the code, say so.
5. **Offer to keep a correction.** When the Artisan corrects, redirects or repeats themselves, offer "make this a guardrail?" (written with `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh tighten`; rules in `${CLAUDE_PLUGIN_ROOT}/references/guardrails.md`) or "file a pipeline ticket?".
6. **No chores.** Don't ask the Artisan to confirm, relay or retype anything an agent could do. Every step put in front of them serves a focus: problem, solution or pipeline.
7. **Write in the voice standards.** All prose a person reads follows the voice standards (`VOICE_STANDARDS.md`), the Artisan's chat as much as tickets, specs, plans, comments, PR bodies, commit messages, ADRs, glossary entries, decision cards and evidence records. Code, code comments and briefs written for agents are outside them. Who reads the text sets the order (ADR 0003): chat only the Artisan reads follows individual first, then product, then team; shared text follows product, then team, then individual; a case that is unclear takes the shared order. The files live in the Artisan's individual home (`~/.claude/artisan-agent/VOICE_STANDARDS.md`), at the project root (`VOICE_STANDARDS.md`, imported by `CLAUDE.md`) and at the root of the team guardrails repo named by `team_guardrails_repo` in the project config. Read the team file at the point of use; never import or copy it.

## Retro questions

The retro asks these every run. Each is scored 1–5 with an optional sentence; "skip" is recorded as a skip.

1. Do you understand the problem this run solved, and who it's for, better than before?
2. Is what shipped the solution you'd have picked; did your judgement shape it where it mattered?
3. Is the pipeline better at delivering after this run, and did you make it so?
4. Did anything eat your time without serving a focus? (free text)
