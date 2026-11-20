# Voice standards resolve by who reads the text

Voice standards exist at the team, product and individual levels, like the other standards. Other standards resolve product, then team, then individual. Voice standards don't. Prose only the Artisan reads (chat turns, grill rounds, wave reports) follows the individual level first. Prose others read (tickets, specs, plans, comments, PR bodies, commit messages, ADRs, glossary entries) follows product, then team, then individual.

This keeps a rule that already exists. `ARTISAN.md` "Tuning" lets the Artisan's individual standards override how the pipeline speaks to them, and the glossary puts "how the pipeline speaks to them" inside individual standards. Resolving voice in the product-first order everywhere would let a team or product voice rule set the voice of chat no one else reads, with no way to opt out short of changing it for everyone.

## Considered Options

- **Product, then team, then individual everywhere:** one order for every standard, with no judgement about the reader. Rejected: it overturns the existing Tuning rule for chat.
- **Individual everywhere:** the Artisan's voice wins even in shared text. Rejected: a ticket or PR is read by the team, so the team's voice should govern it.
- **By reader (chosen).**

## Consequences

- Every voice standards file states this order at its top, because sessions that import more than one level see them side by side.
- An agent has to tell who reads the text. Chat is the Artisan's; anything published to the tracker or git is shared. A case that is truly ambiguous takes the shared order.
