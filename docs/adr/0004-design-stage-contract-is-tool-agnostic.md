# The design stage's contract is screenshots, links and git, never a design tool's format

The design stage's fixed points work in every design tool. It takes in the user journeys a change touches, the design standards, and screenshots of those journey steps captured from a running build of main. It hands spec writing a design package: the journey diff on the feature branch, a high-fidelity screenshot of each changed step, a link to the functional prototype when one was built, and the design tool's file link. Nothing in the pipeline depends on a tool's own format.

Research on Figma, Figma Make, Claude Design, Sketch and Penpot (#288) found that only screenshots in and a share link plus PNG out are common to all five. Live-URL capture, running code, token export and branching each exist in some tools and not others. Git is the only place every product can branch from prod, so the journey diff lives there.

Tool adapters are optional extras on top of the contract. Version one ships one, for Figma, through Figma's own MCP server. Agents use it to read a design, to capture main's journey steps into a Figma file as the designer's starting point, and to write designs. A design made without any adapter still produces a complete design package.

## Considered Options

- **Adopt one tool's format (Figma):** the richest design data, but it makes the pipeline depend on one vendor's plans and seats, and teams using Sketch, Penpot or Claude Design are left out.
- **Require running code out:** matches the goal of functional prototypes, but only Figma Make and Claude Design produce it. A functional prototype is recommended when behaviour changes, and the designer may skip it.
- **Screenshots, links and git, with optional adapters (chosen).**

## Consequences

- Every adapter is its own decision. The contract never grows a requirement only one tool can meet.
- Screenshots carry the design for agents without an adapter, so their quality and coverage of each changed step matter.
- Prototype links break once a prototype is retired at ship, so the spec and tickets rely on the screenshots and the journey diff, not the link.
