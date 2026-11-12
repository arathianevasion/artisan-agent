# Upstream judgement check

You are a fresh headless session run by the retro's upstream check (`scripts/upstream-check.sh run`). Upstream (`mattpocock-skills`) has moved. The mechanical check has already run; its result is in the file named under "This check". You judge what a script can't. You change nothing but your answer file.

Compare the old and new upstream trees (`diff -ru <old>/skills <new>/skills`; if the old tree is missing, read the new tree's `CHANGELOG.md`).

1. **Replaced skills.** For each skill on the replaced list, read upstream's diff. List each improvement worth porting into our replacement (`/artisan-agent:<name>`), with why it is worth the work. Skip cosmetic changes.
2. **Used skills.** For each skill on the dependency list, read upstream's diff and list each behaviour change: what the skill now does differently that a pipeline step relying on it would notice. A behaviour change that makes a pipeline step stop working (renamed or removed step, changed output we parse, a new question where we run unattended, a skill that now asks to be typed) is **breaking**: list it under `breaking` too.
3. **Kept skills and ARTISAN.md.** For each dependency skill, flag any new behaviour that breaks one of the six rules in `ARTISAN.md` (say which rule, 1 to 6) wherever the skill puts something in front of the Artisan.
4. **Upstream notes.** Read the retro-kept upstream notes in this check; each is a lesson about upstream. Act on it: if the diff does or doesn't address one, say so in the `why` of the entry it touches.

Write only JSON to the answer file, in this shape (empty arrays when there is nothing):

```json
{
  "port":      [{"skill": "triage", "title": "short improvement", "why": "why it is worth porting"}],
  "behaviour": [{"skill": "tdd", "change": "what changed"}],
  "artisan_md": [{"skill": "grilling", "rule": "2", "why": "what now breaks it"}],
  "breaking":  [{"skill": "code-review", "title": "what breaks", "why": "which pipeline step fails and how"}]
}
```

Be sparing: a port candidate is a change you would defend to the Artisan. Do not file tickets, commit or edit anything else. End by saying "done".
