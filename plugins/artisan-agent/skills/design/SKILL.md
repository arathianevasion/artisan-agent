---
name: design
description: Design-stage skill in the Decision chat. Designs a change to the experience before it is specified - reads the design standards, starts a design (design ticket, feature branch, prototype branch, "before" screenshots of the journey steps captured from origin's main), and resumes one that takes days. Writes no product code. Use when the Artisan says "design this", "start a design", "where was that design", "resume design #<n>", runs /artisan-agent:design, or when a Feature or Effort route reaches the design stage.
---

# Design

The design stage designs a change to the experience before `to-spec` writes it down. It runs in the Decision chat. Nothing here writes product code: a prototype is written by a dispatched worker on the prototype branch, never by this chat. No step commits from the Decision chat: `design.sh` makes its commits in its own checkout of the branch, and the prototype worker in its own worktree.

`${CLAUDE_PLUGIN_ROOT}/skills/design/scripts/design.sh` does the mechanical parts. Run it from the product repo.

## 1. Read the design standards

Before anything else, read the design standards in force: run `${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh design`. It lists each level's `DESIGN_STANDARDS.md`, product first, then team, then individual (product wins a contradiction). Read each with `git -C <dir> show <commit>:<path>`. They hold the personas, where the design system lives, the UX patterns to follow and avoid, the accessibility floor, and the choices that must come back to the Artisan. Point to them; never copy them into the design ticket.

## 2. Start or resume

- **Start**: settle with the Artisan the design's name and the journey steps it touches, then run `design.sh start --name "<name>" --step <step> [--step <step>]... [--designer <who>] [--no-fetch]`. A design starts from prod: with an origin it fetches origin first and works from `origin/<default branch>`; with none, from the local default branch. It captures a "before" screenshot of each step from that base with the recorded capture command, cuts `feature/<slug>` and `prototype/<slug>` from it, and opens the design ticket (label `design`) recording both branches, the tool link, the designer, the steps and the base it was cut from. It never touches the main checkout. If the fetch fails it stops and says why: retry, or, with the Artisan's say-so, pass `--no-fetch` to start from origin as last fetched (the ticket records that). With no capture command recorded it stops: project setup records one.
- **What is in progress**: `design.sh status` lists the open design tickets.
- **Resume**: `design.sh resume <n>` prints a design ticket's branches, links, designer, steps and screenshots' folder. Pick up from there.

## 3. Write the journey diff

Journeys live in the product's `docs/journeys/` folder, one Markdown file per journey, `docs/journeys/<journey-slug>.md`. A journey file names its persona (one from the design standards) and lists ordered steps, each with its goal, its action (what the user does and sees) and its next step (where they go next):

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

A product with no journeys yet gets only the steps the change touches, written from main first: the feature branch is cut from main, so those steps are the journey's first version, and journeys grow one feature at a time. For a product that has journeys, read the journey's file first, then give every step of it with the design's changes made: the file written replaces the old one, so a step you leave out is deleted. The feature branch's difference from main is the journey diff. It merges when the feature ships, so the journeys on main always describe prod. A change to a user journey always comes back to the Artisan.

## 4. Prototype

When a step's behaviour changes, recommend a functional prototype; the Artisan decides. A look-only change needs only screenshots, no prototype.

- **Build it**: `design.sh prototype --design <design slug> --change "<what the prototype shows>" [--model <model>]`. It dispatches a headless prototype worker into its own worktree, `<repo>-wt/prototype-<slug>`, on the prototype branch only, never the feature branch or main, and returns at once with the worktree, the brief, the worker's pid and its log. Its brief names the product's real components as the building blocks: the pointers under "Where the design system lives" in the design standards. So the prototype is as close to prod as it can be. With no pointer recorded it warns: offer to add one to `DESIGN_STANDARDS.md` before dispatching. For a CLI the prototype is the commands working on the prototype branch. Direct the worker with the Artisan: to change course, run `design.sh prototype` again with the new `--change`; it reuses the worktree.
- **Skip it**: when the Artisan skips a recommended prototype, record it on the design ticket, `gh issue comment <n> --body "**Prototype:** skipped by the Artisan: <why>"`, so the skip is on record when the design is approved.

The prototype branch is never merged.

## 5. High-fidelity design (optional)

The designer may design in a tool. Record its file link on the design ticket. Skip this step when no tool is used.

**Check for Figma's MCP server** first: look for its tools among the ones you have (ToolSearch for `figma`). Its remote server is `https://mcp.figma.com/mcp`. Without it, work from screenshots and links alone: the designer's screenshots and the file link they give you are the whole of the tool's part, and the three adapter steps below don't apply. The contract stays screenshots, links and git either way (ADR 0004); the adapter only saves the designer steps.

With the server connected, the adapter does three things, each only when the Artisan or designer asks for it:

- **Read a design**: for a Figma link on the design ticket, `get_design_context` reads the frames and `get_screenshot` renders one, so the journey diff and the prototype brief can follow the design.
- **Capture main into Figma**: `generate_figma_design` captures the running product's journey steps into a Figma file as the designer's starting point. It needs the remote Figma MCP server and a client that supports it (Figma lists it for select clients only); with the local server or an unsupported client, skip the capture and the designer starts from the "before" screenshots. Capture from main as the "before" screenshots were, never from a checkout with other work in it.
- **Write a design**: `use_figma` writes and edits frames on the canvas. Writing is remote-server only.

With or without the server, the Figma file's link is the tool link: comment it on the design ticket (`gh issue comment <n> --body "**Tool link:** <figma link>"`) and pass `--tool-link <figma link>` at approval. Figma's tool names change: when one named here is missing, check Figma's current MCP docs and use its replacement.

## 6. Approve

`design.sh approve --design <design slug> --ticket <n> [--tool-link <url>] [--no-fetch]` records the design package on the design ticket: the journey diff, a screenshot per changed step (read from `docs/journeys/screenshots/<step>.<ext>` on the feature branch, beside the journey files; nothing is copied at approval), the prototype branch when there is one and the tool link when there is one. A design with neither approves on its screenshots alone, and a tool link never replaces a step's screenshot: a Figma design still commits a screenshot per changed step (export the frame, or `get_screenshot` with the server connected). It refuses while the prototype branch is behind the default branch, naming the rebase, and while a step has no screenshot. Then hand the package to `to-spec`.

## 7. Retire at ship

Retire runs after the merge, not at the cut: cutting a PR isn't shipping it, and a held or rejected PR still needs the prototype branch and the screenshots. Once the PR that carries the design's tickets has merged into `main` (with every PR under it in the stack), `end-gate.sh finish` runs `design.sh retire --design <design slug> --ticket <n> --merge <PR url>` for each design whose feature the run ships; you don't run it by hand. A design whose PR hasn't merged is listed as waiting and left alone; `end-gate.sh finish` again, after the merge, retires it. It deletes the prototype branch and its worktree, deletes the package's screenshots (`docs/journeys/screenshots` on the feature branch, and the "before" folder), and closes the design ticket with the merge it shipped in. The journey diff stays. A run ships a design when a ticket in its scope has a `Design: #<n>` line in its body, so put that line in each ticket that builds the design.
