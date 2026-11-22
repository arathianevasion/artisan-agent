---
name: design
description: Design-stage skill in the Decision chat. Designs a change to the experience before it is specified - reads the design standards, starts a design (design ticket, feature branch, prototype branch, "before" screenshots of the journey steps captured from origin's main), and resumes one that takes days. Writes no product code. Use when the Artisan says "design this", "start a design", "where was that design", "resume design #<n>", runs /artisan-agent:design, or when a Feature or Effort route reaches the design stage.
---

# Design

The design stage designs a change to the experience before `to-spec` writes it down. It runs in the Decision chat. Nothing here writes product code: a prototype is written by a dispatched worker on the prototype branch, never by this chat.

`${CLAUDE_PLUGIN_ROOT}/skills/design/scripts/design.sh` does the mechanical parts. Run it from the product repo.

## 1. Read the design standards

Before anything else, read the design standards in force: run `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh design`. It lists each level's `DESIGN_STANDARDS.md`, product first, then team, then individual (product wins a contradiction). Read each with `git -C <dir> show <commit>:<path>`. They hold the personas, where the design system lives, the UX patterns to follow and avoid, the accessibility floor, and the choices that must come back to the Artisan. Point to them; never copy them into the design ticket.

## 2. Start or resume

- **Start**: settle with the Artisan the design's name and the journey steps it touches, then run `design.sh start --name "<name>" --step <step> [--step <step>]... [--designer <who>] [--no-fetch]`. A design starts from prod: with an origin it fetches origin first and works from `origin/<default branch>`; with none, from the local default branch. It captures a "before" screenshot of each step from that base with the recorded capture command, cuts `feature/<slug>` and `prototype/<slug>` from it, and opens the design ticket (label `design`) recording both branches, the tool link, the designer, the steps and the base it was cut from. It never touches the main checkout. If the fetch fails it stops and says why: retry, or, with the Artisan's say-so, pass `--no-fetch` to start from origin as last fetched (the ticket records that). With no capture command recorded it stops: project setup records one.
- **What is in progress**: `design.sh status` lists the open design tickets.
- **Resume**: `design.sh resume <n>` prints a design ticket's branches, links, designer, steps and screenshots' folder. Pick up from there.

## 3. Write the journey diff

Journeys live in the product's `journeys/` folder, one Markdown file per journey, `journeys/<journey-slug>.md`. A journey file names its persona (one from the design standards) and lists ordered steps, each with its goal, its action (what the user does and sees) and its next step (where they go next):

```
# Journey: <name>
**Persona:** <persona>
## Steps
### 1. <goal>
- **Goal:** <goal>
- **Action:** <what the user does and sees>
- **Next:** <where they go next>
```

Write each journey with `design.sh journey --design <design slug> --name "<journey>" --persona "<persona>" --goal <g> --action <a> --next <n> [--goal ...]...`. A `--goal` starts a step; the `--action` and `--next` after it belong to it. It writes the file on the feature branch only, in its own checkout, and commits it there; the main checkout and main are untouched.

A product with no journeys yet gets only the steps the change touches, written from main first: the feature branch is cut from main, so those steps are the journey's first version, and journeys grow one feature at a time. For a product that has journeys, give the journey again with the steps as the design changes them; the file written replaces the old one. The feature branch's difference from main is the journey diff. It merges when the feature ships, so the journeys on main always describe prod. A change to a user journey always comes back to the Artisan.

## 4. Prototype

Recommended when a step's behaviour changes. A dispatched prototype worker builds it from the product's real components on the prototype branch, in its own worktree. The prototype branch is never merged. For a CLI the prototype is the commands working on that branch.

## 5. High-fidelity design (optional)

The designer may design in a tool. Record its file link on the design ticket. Skip this step when no tool is used.

## 6. Approve

Not built yet. Approval records the design package on the design ticket and hands it to `to-spec`.

## 7. Retire at ship

Not built yet. At ship the prototype branch and the package screenshots are deleted; the journey diff stays.
