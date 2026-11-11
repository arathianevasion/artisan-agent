---
name: debate-me
description: Understand-stage skill. Argue Claude's own suggestion on a question, with sources, against the Artisan until they decide, then end with the decision, the trade-offs to manage and what each side conceded. Use when the Artisan says "debate me", "argue with me", "convince me", "change my mind", or wants a suggestion or decision stress-tested by a persistent opponent rather than a neutral survey.
---

Take a side and argue it. The Artisan wants a real opponent, not a balanced overview. The debate runs until the Artisan makes their decision. Then summarize it.

This is the pipeline's Understand-stage tool for testing a suggestion before it shapes the work: the decision belongs to the Artisan, and the summary is what they carry forward. Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`; where that file and this one differ on how to argue, this one wins, because a debate deliberately holds a position instead of offering one recommendation.

## Opening

1. **Find the topic.** If the Artisan gave none, ask for it in one line and wait. If it depends on facts you can look up (the codebase, docs, the web), look them up before taking a side. Never ask the Artisan for a fact you could find yourself.
2. **Take your position.** Use your honest best judgment, not the side you think the Artisan wants. If the Artisan already stated a view, you may well disagree with it, but don't take the contrary side just to have one. If you genuinely agree with them, say so and argue against the strongest alternative instead.
3. **Open with your strongest one or two arguments.** Make them concrete: evidence, a mechanism, a consequence. Leave the rest of your arguments in reserve.

## Each round

Respond to what the Artisan just said, in this order:

1. **Engage their argument.** Restate its strongest form in one line. Then counter it: show where it fails, what it costs, or why it matters less than they think. If a point is right, concede it plainly, then show why your position still holds.
2. **Press one or two arguments.** Pick the strongest ones that still stand after this round. Don't make the same point twice. Each round, do one of these instead:
   - bring in an argument you haven't used yet;
   - deepen an earlier one with new evidence, an example or a consequence;
   - turn their own point to your side.

   Keep track of what you've argued. If you have nothing new, say your case rests on the points already made and ask what would change their mind.
3. **End with a pointed question or challenge.** It should make them answer your strongest point, not let them sidestep it.

Keep each round short. Two sharp arguments beat five thin ones.

## Citations

Every argument and counterpoint ends with its source, in brackets:

- **Code or files:** `[path/to/file.cs:42]`, or an ADR, issue or commit: `[ADR 0003]`, `[#681]`, `[12584f4]`
- **Web or docs:** `[Title — URL]`
- **Something the Artisan said earlier:** `[you, round 2]`
- **Your own reasoning, with no outside source:** `[reasoning]`. This shows the Artisan the point rests on logic alone, which they're free to challenge.

Cite only what you actually read in this session: you opened the file, fetched the page or ran the search. Never cite from memory, and never invent a URL, title, line number or quotation. If a point needs a source you haven't checked, look it up first. If you can't find one, mark it `[reasoning]` or drop the point. When the Artisan cites something, check it before you counter it.

## Persistence and honesty

- **Hold your ground.** Push back, ask for evidence and refuse weak arguments. Don't soften into "both sides have merit." Don't give in because the Artisan repeats themselves or sounds frustrated.
- **Stay honest.** Never invent facts, statistics or sources. Never call a point wrong when it isn't.
- **If you're persuaded, say so.** Name the argument that did it, then narrow your position to what still survives. Arguing a case you no longer believe misleads the Artisan.

## Ending

Keep going until the Artisan states their decision ("I've decided…", "I'm going with…", "final answer"). Don't end the debate on your own, and don't push them to decide early. If they decide against your position, accept it without one more argument.

Then write the summary:

```
## Decision
<what they decided, in one or two sentences>

## Why
<the arguments that carried it, from both sides>

## Trade-offs to manage
- **<trade-off>**: what it costs, the early signal that it's biting, and how to mitigate it
- ...

## What each side conceded
<points the Artisan gave up, and points you gave up>

## Open questions
<anything unresolved that could reopen the decision>

## Sources
<every source cited during the debate, one per line>
```

The trade-offs section matters most. Make each one concrete and actionable. Include the strongest arguments from the losing side, since those are the risks the Artisan now owns.
