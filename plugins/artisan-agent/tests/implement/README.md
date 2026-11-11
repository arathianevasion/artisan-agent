# Proving `/artisan-agent:implement`

`implement.test.sh` (run by `tests/run.sh`) checks what can be checked for free: the skill is Claude-callable and cites the shared references, the documented evidence-record example passes `check-evidence-record.sh`, the checker rejects malformed records, each sample ticket sets up a repo whose suite passes with its seeds in place, and `live.sh verify` fails on every sample before a worker has run.

The skill itself is proven by headless workers on the sample tickets in `../fixtures/implement/`, which spend money and are run by hand with `live.sh` whenever the skill changes:

| Sample | Ticket | What `live.sh verify` checks beyond the shared checks |
|---|---|---|
| `named-seam` | 01: add `slugify`, seam named | the ticket's examples pass; tested at the named seam; no Write/Edit to the code before the test; a test run failed before the first commit |
| `unnamed-seam` | 02: CSV export, no seam named | the CSV and `list` outputs; the seam the worker chose is a decision card |
| `review-seeds` | 03: a stopped first attempt with a boundary bug (`>` for "or more"), a `print()` that `CODING_STANDARDS.md` rule 1 forbids, and a Data Clump (`street, city, postcode`) | the bug and the violation are fixed; both signatures are unchanged; a finding is left as a `decision` and the clump is a decision card |

The shared checks: a result file exists and is an evidence record, status `complete`, a commit on `agent/<id>` that the record names, a clean tree, no stash, a green suite, every criterion met, and `mattpocock-skills:tdd` and `mattpocock-skills:code-review` both loaded.

```bash
SB=/some/scratch/dir
UPSTREAM_PLUGIN_DIR=/path/to/mattpocock-skills \
  plugins/artisan-agent/tests/implement/live.sh run review-seeds "$SB/review-seeds"
plugins/artisan-agent/tests/implement/live.sh verify review-seeds "$SB/review-seeds"
```

Each session is capped at `--max-budget-usd 0.50` on `claude-sonnet-5-5`, loads both plugins with `--plugin-dir`, reads no user settings and saves no session. It still authenticates through the normal login: an isolated `CLAUDE_CONFIG_DIR` or a fake `HOME` reports "Not logged in".

## Runs on 2026-11-10

Each change to the skill was followed by another run of the samples. The early runs found these defects in the skill, which are now fixed:

- `code-review` resolved to Claude Code's built-in review, not upstream's two-axis one, and the worker never loaded `tdd`. The skill now names `mattpocock-skills:tdd` and `mattpocock-skills:code-review`.
- Workers skipped `tdd` and the review, or ran the review without its sub-agents, "to save budget" with under $0.20 spent. The skill now says never to skip a step to save budget.
- The first `unnamed-seam` ticket could be met without any new seam (the worker tested through `cli.main` and carded *not* extracting one). The ticket now needs the CSV produced outside the command line, and `verify` checks a public function was added and carded as job 3.

The last run, after the code-review fixes, passed every check on all three samples:

| Sample | Cost | Decision cards |
|---|---|---|
| `named-seam` | $0.28 | ASCII-only "letters" (product taste) |
| `unnamed-seam` | $0.30 | new seam `export.to_csv(invoices)` (job 3); LF line endings; three review smells left as is (command table, `Invoice` type, fixture rows in tests) |
| `review-seeds` | $0.30 | leave the `street, city, postcode` clump; keep the name `check_address` |

In `review-seeds` the `print()` violation was fixed after `code-review` reported it. The boundary bug breaks an acceptance criterion, so the worker caught it test-first and committed the fix before the review ran. The review reported it again and the record lists it as fixed. A seed only a review could find would need to sit outside every criterion.
