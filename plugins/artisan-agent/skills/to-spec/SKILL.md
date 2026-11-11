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

3. **Draft the spec** with the template below. As you write, keep a running list of every addition: any user story, implementation decision, testing decision or out-of-scope line that did not come from the conversation (something you inferred, filled in for completeness, or took from the codebase). A line that restates something the Artisan said or agreed to is not an addition. When unsure, count it as an addition.

4. **Show the draft before publishing.** Show the whole spec, then, under it, the additions:

   ```
   ## Additions to accept or cut
   Nothing here came from our conversation. Each joins the spec only if you accept it.

   1. **<section>, <story or decision number>**: "<the line>": <why I added it>
   ...
   ```

   Recommend accept or cut for each, with the reason (ARTISAN.md rule 3). Lines not in the list came from the conversation. If there are no additions, say so explicitly. Batch it: the Artisan answers once ("accept all", "cut 2 and 5"), not piecemeal.

5. **Apply their answers.** Remove every line the Artisan cut, renumber, and fix any other line that depended on a cut one. If they asked for other edits, make them, and show again only what changed. Anything newly added counts as an addition and goes through the same list. Don't publish until the Artisan says the spec is approved.

6. **Publish** the approved spec to the project issue tracker and apply the `ready-for-agent` triage label; no further triage is needed. A line the Artisan cut must not appear anywhere in what you publish, including Further Notes. Give the Artisan the link, and that the next step is `/mattpocock-skills:to-tickets`.

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
