# Evidence record

The result file a worker writes when it finishes a ticket: each acceptance criterion with its evidence, what the worker was unsure of, the decisions it made alone, and the review it ran. The verifier checks it against the diff, and the evidence contract built from both goes into the state file and onto the ticket (`references/evidence-contract.md`); the packet is built from it. None of them read the worker's transcript.

Skills cite this file rather than copying it: "write the evidence record as in `${CLAUDE_PLUGIN_ROOT}/references/evidence-record.md`".

`/artisan-agent:implement` writes it. It is one JSON object, written even when the worker fails or is blocked, because a missing file is indistinguishable from a crash.

## Fields

| Field | Required | Values |
|---|---|---|
| `ticket` | yes | The ticket's id, as the orchestrator named it |
| `status` | yes | `complete` (committed, suite green, review ran), `blocked` (can't be finished as written; `findings` or `unsure` says why) or `failed` (the worker errored; `notes` says where) |
| `branch` | yes | The worker's branch |
| `commit` | yes | The branch tip the record describes; `null` only if nothing was committed |
| `base` | yes | The commit the branch started from |
| `acceptance` | yes | One entry per acceptance criterion, in the ticket's order (below) |
| `tests` | yes | `{"suite_passed": true, "command": "...", "summary": "..."}`: the full-suite run at the end, with the command and its result line. Add a `<check>_passed` boolean per other check (`typecheck_passed`, `lint_passed`) the project has |
| `unsure` | yes | What the worker was unsure of, one sentence each; `[]` if nothing |
| `decisions` | yes | The notable decisions the worker made alone, each a decision card (below); `[]` if none |
| `review` | yes | `{"ran": true, "remarks": [...]}`, every `mattpocock-skills:code-review` remark with what was done about it (below) |
| `findings` | yes | Work found outside the ticket: `{"title", "why", "blocks": [ticket ids]}`; `[]` if none |
| `notes` | no | Free text for late facts: anything the orchestrator should know that fits nowhere else. One paragraph |

Cost is not written by the worker. Whoever reads the session's `--output-format json` output adds the session's `total_cost_usd` as `cost_usd`.

### `acceptance` entries

```json
{
  "criterion": "The criterion's text, verbatim from the ticket",
  "met": true,
  "evidence": {
    "tests": ["tests/test_text.py: test_slugify_lowercases_and_hyphenates"],
    "checks": [{ "command": "python3 -m unittest", "result": "Ran 9 tests ... OK" }],
    "diff": "text.py +14 -0, tests/test_text.py +22 -0"
  }
}
```

`evidence` holds the tests that prove the criterion, the checks run and their result lines, and the diff stats for the files that meet it. Leave out a key that has nothing in it. A criterion not met says why in `evidence.why`.

### Decision cards

Each entry in `decisions` is a decision in the shape in `${CLAUDE_PLUGIN_ROOT}/references/decision-record.md` (`job`, `choice`, `by`, and its optional fields, `confidence` among them), with four card fields the packet needs:

| Field | Required | Values |
|---|---|---|
| `question` | yes | What had to be decided, as a question |
| `alternative` | yes | The strongest alternative the worker rejected |
| `kind` | yes | `product taste`, `engineering taste` or `engineering` |
| `criterion` | yes | The controversy criterion it meets, by number from `${CLAUDE_PLUGIN_ROOT}/references/controversy-criteria.md`, or `none` |

For a worker's decision, `by` is `worker <ticket>`. `job` is the job the decision would have been if a person had made it: a seam or other design question is job 3; a review remark left as is is job 13. A decision made alone is `provisional` unless a guardrail settles it.

```json
{
  "job": 3,
  "question": "Where should CSV export be tested?",
  "choice": "Add a public to_csv(invoices) function in export.py and test at it",
  "alternative": "Test through the CLI's stdout",
  "by": "worker 07",
  "why": "The ticket names no seam, and a pure function is the narrowest boundary that shows the format",
  "kind": "engineering taste",
  "criterion": "4",
  "reach": "ticket",
  "confidence": "provisional"
}
```

### `review.remarks` entries

| Field | Values |
|---|---|
| `axis` | `standards` or `spec` |
| `severity` | `bug`, `violation` (of a documented standard, naming the file and rule), `missing`, `scope` or `judgement` |
| `note` | The remark, in one sentence |
| `disposition` | `fixed`, `decision` (left unchanged; a card in `decisions` records it) or `not_acted` |
| `why` | Required for `not_acted`: why the remark was left |

## Example

```json
{
  "ticket": "07",
  "status": "complete",
  "branch": "agent/07",
  "commit": "a1b2c3d",
  "base": "9f8e7d6",
  "acceptance": [
    {
      "criterion": "Invoices export as CSV with a header row",
      "met": true,
      "evidence": {
        "tests": ["tests/test_export.py: test_header_row_comes_first"],
        "checks": [{ "command": "python3 -m unittest", "result": "Ran 12 tests ... OK" }],
        "diff": "export.py +31 -0, tests/test_export.py +40 -0"
      }
    }
  ],
  "tests": { "suite_passed": true, "command": "python3 -m unittest", "summary": "Ran 12 tests ... OK" },
  "unsure": ["Whether amounts should export in pence or pounds; the ticket doesn't say, so pence matches storage"],
  "decisions": [
    {
      "job": 3,
      "question": "Where should CSV export be tested?",
      "choice": "Add a public to_csv(invoices) function in export.py and test at it",
      "alternative": "Test through the CLI's stdout",
      "by": "worker 07",
      "kind": "engineering taste",
      "criterion": "4",
      "confidence": "provisional"
    }
  ],
  "review": {
    "ran": true,
    "remarks": [
      { "axis": "standards", "severity": "violation", "note": "CODING_STANDARDS.md: library code must not print", "disposition": "fixed" }
    ]
  },
  "findings": [],
  "notes": "Export reads every invoice into memory; fine at today's volumes."
}
```
