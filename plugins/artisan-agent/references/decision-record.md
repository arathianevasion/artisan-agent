# Decision record

The shape every recorded decision takes, wherever it is made: at a gate, in triage, at plan approval, at the retro or in a debate.

Skills cite this file rather than copying it: "record it as in `${CLAUDE_PLUGIN_ROOT}/references/decision-record.md`".

## Fields

| Field | Required | Values |
|---|---|---|
| `job` | yes | The job number from `references/jobs.md`, or `route` for route choice |
| `choice` | yes | What was decided, in one sentence |
| `by` | yes | Who made it: the Artisan's name, or the agent that decided alone |
| `why` | no | The reason, in one sentence |
| `guardrail_level` | no | `team`, `product` or `individual`, when the decision becomes a guardrail |
| `reach` | no | `ticket` (this ticket), `area` (this area, named) or `everywhere` |
| `confidence` | no | `firm`, or `provisional` (revisited at the retro) |
| `redirect` | no | `self` ("I'll do this myself") or `notes` ("send it back with notes", with the notes) |

Leave an optional field out rather than filling it with a placeholder. A missing field means it wasn't given.

## Example

```json
{
  "job": 13,
  "choice": "Keep the retry limit at three",
  "by": "Artisan",
  "why": "Matches the upstream API's own retry budget",
  "guardrail_level": "product",
  "reach": "area",
  "area": "uploads",
  "confidence": "provisional"
}
```

When `reach` is `area`, name the area in `area`.
