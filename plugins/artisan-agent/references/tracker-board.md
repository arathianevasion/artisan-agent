# The project's board

How issues the plugin opens follow a project's board convention (#146): which ones go on a GitHub Project, and which of its fields they get. The one place an issue is created is `scripts/tracker.sh`; tested in `tests/tracker.test.sh` and at each caller's tests.

## The setting

`tracker.board` in `.artisan-agent/config.yml`:

```yaml
tracker:
  board:
    owner: arathianevasion      # the project's owner (github.com/users/<owner>/projects/<number>)
    number: 1                   # the project number
    fields_at_filing: [Area]    # the fields whoever files an issue sets
```

Empty (`board: {}`, the default) means nothing goes on a board and every issue is created as before.

Project setup learns it from the project's tracker doc, `docs/agents/issue-tracker.md` (`skills/setup/PROJECT.md`). Scripts read only the setting, never the doc's prose.

## The four rules

1. **Setup learns the convention; scripts read config.** `project-setup.sh scan` prints a `board` line when the tracker doc links a GitHub Project (`github.com/users|orgs/<owner>/projects/<number>`), with the fields a table row says "whoever files the issue" sets. `apply` records it as `tracker.board` when the config has none, or the answers' `tracker_board` when given; a board already in the config is kept. A doc without a board writes nothing.
2. **One helper creates every plugin issue.** `tracker.sh new-issue --kind <kind> --from <ticket> -- <gh issue create args>` creates the issue, then, when `tracker.board` is set and the kind goes on the board, adds it to the project (`gh project item-add`) and sets each `fields_at_filing` field (`gh project item-edit`). A board step that fails (no `project` scope on the token, the network) never fails the issue: it warns on stderr, queues the add in `.artisan-agent/runs/.board/pending.jsonl`, records a `board-add-failed` event when a run is open (`--run-dir`, or `ARTISAN_RUN_DIR`), and the next sweep (`sweep.sh`, or `chats.sh sweep`) adds it with `tracker.sh board-retry`. `tests/tracker.test.sh` fails on any script that creates an issue with `gh` directly. The body goes to `gh` as a file (`--body-file F`, or `-` for stdin; no plugin script passes it as an argument, though `--body TEXT` still works): a body over GitHub's 65,536-character limit is posted whole, the issue body holding what fits and saying it continues in the comments, each further part a comment under the limit, in order (#209).
3. **Fields are inherited, not mapped.** The plugin's areas (`areas` in the config, path-based gate rules) and a project's Area field are separate vocabularies, so there is no mapping between them. A new issue takes each `fields_at_filing` value from the ticket it came from: a Human check from its agent ticket, a rework ticket from the ticket it reworks, a split ticket from the ticket it was split off, a finding from the ticket whose worker found it, a plan issue from its first ticket. A worker filing a finding may name the value itself, by the project's own rule for that field (its tracker doc): `"fields": {"Area": "..."}` in the finding's line (`references/findings.md`). When the source ticket has no value, the field is left empty for triage. The plugin never sets Priority, Status or any field not in `fields_at_filing`.
4. **Only work that outlives the run goes on the board.**

| Kind | Opened by | On the board |
|---|---|---|
| `plan` | `to-plan.sh publish`, `chats.sh send` | yes |
| `finding` | `findings.sh mark … triage`; the Engineering chat between waves | yes |
| `human-check` | `to-plan.sh split-human-check` (also at an exception gate); a Human check deferred past the run stays on it | yes |
| `rework` | `gate.sh change`, a failed Human check (`gate.sh check`), `gate-action.sh redirect` | yes |
| `split` | `gate-action.sh split` to a new ticket: criteria split off at an exception gate | yes |
| `gate` | review, risk, exception, overrun and end gates (`gate.sh`, `gate-action.sh`, `budget.sh`, `end-gate.sh`) | no |
| `question` | a worker's question (`questions.sh file`) | no |

An issue a chat files by hand that outlives the run goes through the helper too, with the kind it is: a finding filed between waves (`skills/implement-plan/SKILL.md`, step 7) is `--kind finding --from <ticket>`, and follow-up work the Artisan asks for at the end gate is `--kind split --from <ticket>`.

`skills/retro/scripts/retro.sh` and `scripts/upstream-check.sh` file issues to the pipeline's own repo (`PIPELINE_REPO`), never to the project, so they are not plugin issues in the project and don't use the helper.

## Field types

A single-select field is set by option name (an option the board lacks is warned about and left empty). `gh project field-list` gives text, number and date fields one type, so a value that reads as a date (`YYYY-MM-DD`) is set as a date, one that reads as a number as a number, anything else as text. An iteration field is warned about and left empty.

A queued add that fails `ARTISAN_BOARD_TRIES` retries (default 10) is dropped with a warning to add it by hand. The source ticket's values are read from the board's first 10000 items.

## Out of scope

Trackers other than GitHub Projects; Priority and Status; backfilling issues filed before the setting.
