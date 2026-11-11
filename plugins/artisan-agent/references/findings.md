# Findings shared between workers

How a fact one worker turns up reaches the workers it concerns, and why design never travels that way. Tested in `tests/findings.test.sh` and `tests/run-ticket.test.sh`; the commands are in `scripts/findings.sh`.

## The worker's side

- A worker is started with `--name worker-<ticket>` and `--settings '{"crossSessionInbound":"accept"}'` (`run-ticket.sh`). The setting has to be passed on the command line: a project-level one is ignored.
- It appends each finding, one JSON object per line, to `$ARTISAN_FINDINGS_FILE` (`results/findings/<ticket>.jsonl`) **the moment it finds it**, not at the end: `{"title", "why", "blocks": [ticket ids]}`, `blocks` naming the tickets the fact concerns. The wait script watches that folder, so the orchestrator hears at once.
- A message that starts `FINDING from #<n>` is a fact from another ticket's worker, relayed by the orchestrator. It arrives at the worker's next tool call. Take it as given, build on it, and don't reply to it.
- **Design never goes between workers.** A worker that needs a design or interface change to something another ticket owns stops, writes its question and recommendation in the result file's `design_question` (`references/evidence-record.md`), and finishes `blocked`.

## The orchestrator's side

After every wake, once the sweep has logged new findings (`wait-any.sh` reports `grew results/findings/<t>.jsonl`):

1. `findings.sh pending $RUN` lists each (finding, target ticket) not yet handled, with an action.
2. For `relay`: `SendMessage` the line's `message` to its `name`, then `findings.sh mark $RUN <from> <seq> <target> relay`. Only the in-flight workers a finding concerns get it.
3. For `comment` (the target hasn't started, or is blocked with the Artisan): `mark … comment`. The target's worker reads it on its ticket.
4. For `triage` (the target has finished): `mark … triage` files a `needs-triage` ticket, off every frontier, and comments on the finding's ticket. Nothing is relayed to a finished ticket.
5. `mark` comments on both tickets and writes the state file's `relays` and a `finding` event, once; marking again does nothing.
6. When a worker's result comes in, read its `notes` and `unsure` for facts it recorded but didn't act on. For each, `findings.sh add $RUN <from> "<title>" "<why>" <tickets it concerns>` logs it like any finding; then handle it as above.

A finding that names no ticket in `blocks` isn't listed; it goes to triage between waves (`implement-plan` step 7).

## Design stops

The sweep reads a blocked result with a `design_question`: the ticket stays `blocked`, a `design` decision (the question and recommendation) is queued for the Artisan, and `lessons` gets a `slicing` lesson (a ticket that needed design from another is a slicing fault, for the retro). The orchestrator posts the question on the ticket and does not retry it. Nobody negotiates the answer between workers.
