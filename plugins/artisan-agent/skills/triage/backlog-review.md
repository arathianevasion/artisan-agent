# Backlog review

A periodic review of outstanding tickets. It is not automatic and has no skill in version one; a dedicated backlog-review skill arrives only as a retro lesson. The Artisan runs it in the **Product chat**, pasting the prompt below.

It sorts every open ticket into **the next plan**, **closed**, or **left open**, and points out deferred tickets whose return condition has been met. It changes nothing until the Artisan approves each sort; triage rules still apply (nothing reaches `ready-for-agent` without approval).

## The prompt

Paste this into the Product chat. A pasted prompt runs outside a skill, so `${CLAUDE_PLUGIN_ROOT}` is empty there; the prompt resolves the plugin's install path itself (from `claude plugin list --json`, or the variable if set).

````text
Run a backlog review of this repo's open tickets. First find the plugin: run the line below once and use $ROOT for every plugin path that follows. If it prints nothing, stop and tell me; don't search the disk.

   ROOT=${CLAUDE_PLUGIN_ROOT:-$(claude plugin list --json | python3 -I -c 'import json,sys; print(next(p["installPath"] for p in json.load(sys.stdin) if p["id"].startswith("artisan-agent@") and p.get("enabled")))')}; echo "$ROOT"

Follow $ROOT/ARTISAN.md and use GLOSSARY.md vocabulary. Don't touch tickets labelled in-run, and don't change anything until I approve it.

1. Returning deferrals first. Run $ROOT/skills/triage/scripts/deferred-due.sh. It lists open `deferred` tickets whose return condition is met: a date that has passed (including "next review" dates) or a blocking event whose tickets have all closed. For each, show the reason it deferred and what has changed, and recommend: bring into the next plan (remove `deferred`), defer again with a new return condition, or discard. Also list any `deferred` ticket with no readable "Return condition:" line as a gap.

2. Then sort every other open ticket, with a recommendation and reasoning for each:
   - next plan: ready to be built soon; say what makes it ready and what it depends on;
   - closed: already built, superseded or no longer wanted; point to the evidence (and for a rejected enhancement, say so, since discarding writes an .out-of-scope record);
   - left open: still wanted, but not yet; say why.
   Tickets still labelled `needs-triage` go to /artisan-agent:triage, not here. Name the controversy criterion ($ROOT/references/controversy-criteria.md) for anything that is a priority call.

3. Present it as one batch: returning deferrals, then next plan, then close, then leave open. Ask me to approve or change each group. Apply only what I approve, with the AI-generated disclaimer on every comment.
````

## Inputs it relies on

- `deferred-due.sh` reads the `Return condition:` line written by `/artisan-agent:triage` when it defers (forms listed in the triage skill). It needs `gh` and prints `none due` when nothing has returned.
- `.out-of-scope/` for rejection history; `GLOSSARY.md` and `docs/adr/` for taste.
