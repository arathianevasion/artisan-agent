# Working as a pair

Two Artisans can share one product by convention; no tooling splits the roles. One holds **Product** (what and why, product taste), the other **Engineering** (how, engineering taste). Everything else works as it does for one Artisan. Vocabulary is in the repo's GLOSSARY.md.

| Convention | In practice |
|---|---|
| Each person runs their role's chat | Product runs the Product chat (specs, triage), Engineering runs the Engineering chat (plans, runs, waves). Neither needs the other's session open |
| The tracker is the only channel | Handoffs, questions and decisions go on tickets, specs and PRs, never in a private message the other can't see |
| Gates and triage are batched by job | Each person sees the decisions their role owns (job inventory: `references/jobs.md`), batched, so neither waits on the other's queue |
| Every decision records who made it | The decision record's `by` names the person, so the retro and later readers know whose taste it was |
| One joint retro | Both attend. Lessons are tagged by role, and each person approves their own |
| Satisfaction answers stay private | Each person answers for themselves; the retro never shows one person's answers to the other |
| The product guardrail's owner merges its PR | Product taste by Product, engineering taste by Engineering |

## Guardrails in a pair

The conflict rules in `references/guardrails.md` apply unchanged: **product beats team, which beats individual**; an individual guardrail fills a gap where nothing shared has an opinion; a stricter individual guardrail about one's own reviews applies to the gates that Artisan holds.

- Each Artisan's individual guardrails apply only to their own role's jobs. Mark a guardrail with `role: product` or `role: engineering` and `guardrails.sh resolve --role <role>` keeps it for that role only; an unmarked one applies to both.
- Anything both should follow is **promoted**: made a product guardrail (or a team one) by PR, so it applies to everyone the same way.
- Conflicts are surfaced at plan approval and raised at the retro, never resolved silently.
