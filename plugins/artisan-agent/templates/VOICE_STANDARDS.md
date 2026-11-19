# Voice standards

How agents write prose a person reads. Code, code comments and briefs written for agents are out of scope.

## Which level wins

It depends on who reads the text (ADR 0003 in artisan-agent):

- Chat only the Artisan reads (chat turns, grill rounds, wave reports) follows the individual file first.
- Shared text (tickets, specs, plans, comments, PR bodies, commit messages, ADRs, glossary entries) follows product, then team, then individual.
- When it's unclear who reads it, take the shared order.

The product file is `VOICE_STANDARDS.md` at the repo root, the team file sits at the root of the team guardrails repo, and the individual file lives in the Artisan's individual home.

<!-- voice-default v1 start: the plugin's default rules. A newer default arrives at the retro as a move. A rule you edit here counts as yours. -->
## Default rules

Phrases:

- **R1** Start with the answer or finding. No openers that restate the question or announce what comes next.
- **R2** No emphasis crutches: really, truly, actually, importantly, "worth noting", bold for stress.
- **R3** No significance inflation (critical, powerful, robust, seamless, "the real X is") unless it's measured.
- **R4** Name who acts. No false agency.
- **R5** No "not X, but Y" for effect.
- **R6** No questions you then answer yourself.
- **R7** No vague attribution: cite the source or drop the claim.
- **R8** No flattery or chatbot residue.
- **R9** Plain words: use, help, start.
- **R10** At most one em-dash per paragraph.

Structure:

- **R11** Vary sentence length. No runs of three fragments.
- **R12** Don't open a paragraph with Additionally, Furthermore or Moreover.
- **R13** Bold-label lists belong in reference material only, never in chat prose.
- **R14** No closing recap, summary or moral.
- **R15** One idea per sentence. Two semicolons means split it.
- **R16** Say a fact once.

Arrangement:

- **R17** Lead with what the reader acts on.
- **R18** Skip a template section that has nothing to say.
- **R19** The first time you mention a run id, ticket or file, say what it is.

Protections:

- **P1** Keep hedges and negations that carry meaning, and contrasts that state a decision.
- **P2** Keep quotes, code, commands, numbers, names and dates exactly.
- **P3** Keep genre conventions: brief fields, tables, checklists, ADR sections.
- **P4** Concise never means packed. If cutting words makes a sentence harder to read, keep them.

R1–R14, R17, R18 and P1–P3 are adapted from the pattern catalogue in theclaymethod/unslop (https://github.com/theclaymethod/unslop), used under the MIT License. R15, R16, R19 and P4 come from the pipeline's own text.
<!-- voice-default end -->

## Your own rules

<!-- Add your rules below. They win over the default block above, and a new default version never touches this section. -->
