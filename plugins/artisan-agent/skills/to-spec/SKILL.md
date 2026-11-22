---
name: to-spec
description: Specify-stage skill. Turn the current conversation into a spec, show the draft to the Artisan, flag every user story, decision or out-of-scope line that did not come from the conversation as an addition to accept or cut, then publish what was accepted to the issue tracker. Use when the Artisan says "write the spec", "turn this into a spec", or after /artisan-agent:grill.
---

Take the current conversation and codebase understanding and synthesize a spec. Do NOT interview the Artisan; the conversation is your source. This replaces the upstream `to-spec`, which published without review. The template and the seam check are upstream's, unchanged. The review is new: nothing is published until the Artisan has seen the draft and decided on every addition.

Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`. Approving the spec is the Artisan's job (job 8 in `${CLAUDE_PLUGIN_ROOT}/references/jobs.md`), and anything that adds scope is never autonomous (the scope floor).

The issue tracker and triage label vocabulary should have been provided to you (see `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`). If not, tell the Artisan to run `/artisan-agent:setup`.

## Process

1. **Explore the repo** to understand the current state of the codebase, if you haven't already. Use the project's `GLOSSARY.md` vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. **Sketch the seams** at which the feature will be tested. Existing seams are preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better; the ideal number is one. Check with the Artisan that these seams match their expectations before drafting.

3. **Draft the spec** with the template below, plus an Experience section when a design package exists (see "Experience section" below). As you write, keep a running list of every addition: any user story, implementation decision, testing decision or out-of-scope line that did not come from the conversation (something you inferred, filled in for completeness, or took from the codebase). A line that restates something the Artisan said or agreed to is not an addition. When unsure, count it as an addition.

4. **Check the draft against the motivation.** Before showing it, read the individual and project `PRODUCT_STANDARDS.md` "Always ask" lines, as `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md` "Tuning" says to read standards at the point of use. Then read `motivations/<repo>.md` in the individual home (`~/.claude/artisan-agent/`), if it exists. List each place the motivation conflicts with a user story, decision or out-of-scope line, or could sharpen the spec's wording or boundaries, and each line that trips an "Always ask" item, for step 5. With no motivation file, nothing changes: skip the motivation check and step 5 shows only the additions.

5. **Show the draft before publishing.** Show the whole spec, then, under it, the additions:

   ```
   ## Additions to accept or cut
   Nothing here came from our conversation. Each joins the spec only if you accept it.

   1. **<section>, <story or decision number>**: "<the line>": <why I added it>
   ...
   ```

   Recommend accept or cut for each, with the reason (ARTISAN.md rule 3). Lines not in the list came from the conversation. If there are no additions, say so explicitly.

   Under that, when step 4 found anything, its own heading:

   ```
   ## Motivation check
   1. **<section, number>**: <conflict or sharpening point>: recommend <change or keep>, because <reason>; strongest alternative: <the other option>
   ```

   When the spec has an Experience section, its own heading under that, as the last thing before the Artisan answers:

   ```
   ## Always ask: journey diff
   A change to a user journey is always your call. Approving the spec approves this design package; there's no second approval.

   <the journey diff, as recorded in the design package>
   Changed steps: <step name>: <one line on what changes>, ...
   ```

   The journey diff is an Always ask item whatever the standards files say, so it is shown in every review of a spec with an Experience section, never summarised away. Approving the spec approves the design package with it (job 8 in `${CLAUDE_PLUGIN_ROOT}/references/jobs.md`).

   Each item carries a recommendation and the strongest alternative you rejected (ARTISAN.md rules 2 and 3). Say what conflicts or sharpens, not the motivation's own words: the published spec contains no text from the motivation, quoted or paraphrased, because the motivation is private and the spec may be public. Scope never widens to match the motivation without the Artisan's yes. Batch both lists: the Artisan answers once ("accept all, apply 1", "cut 2 and 5"), not piecemeal.

6. **Apply their answers.** Remove every line the Artisan cut, renumber, and fix any other line that depended on a cut one. If they asked for other edits, make them, and show again only what changed. Anything newly added counts as an addition and goes through the same list. Don't publish until the Artisan says the spec is approved.

7. **Publish** the approved spec to the project issue tracker and apply the `ready-for-agent` triage label; no further triage is needed. A line the Artisan cut must not appear anywhere in what you publish, including Further Notes. Give the Artisan the link, and that the next step is `/mattpocock-skills:to-tickets`. When the spec has an Experience section, tell the Artisan, and whoever writes the tickets, that each ticket building a changed step cites journey steps by name, as the Experience section names them (`Steps: <journey>: <step>`), and carries a `Design: #<design ticket>` line so the end gate retires the design at ship.

## Experience section

Write it only when a design package exists: the design stage approved one for this change (`/artisan-agent:design`, step 6), recorded on the design ticket as a "Design package: approved" comment. With no design package, there is no Experience section: don't write an empty one or a placeholder.

Read the package from the design ticket, and put the section after "Solution" in the spec, with:

- **Affected journeys**: each user journey the change touches, by name, with its persona.
- **Journey diff**: a link to the journey diff on the feature branch, the `docs/journeys/<journey>.md` files the package names.
- **Changed steps**: each journey step that changes, by its name in the journey, with its design screenshot from the package (a terminal transcript for a CLI) and the prototype or tool link when the package has one.
- **Whys**: for each changed step, why the experience changes this way, in the Artisan's words from the design stage. A why you inferred is an addition (step 3).

The step names here are the names tickets cite, so use them exactly as the journey files write them.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts, not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
