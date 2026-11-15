"""A ticket's acceptance criteria: read them, match them, tick them.

The one place the matching rule lives: a criterion matches another when
their text is the same once spaces and case are normalised; failing that,
the entry in the same position when the counts agree (never fuzzier).

Usage:
  python3 -I criteria.py extract < body.md
      the criteria as a JSON array of strings: the checkbox lines
      ("- [ ] ..." or "- [x] ...") under an "Acceptance criteria" heading,
      up to the next heading of the same or a higher level. A body with no
      such heading gives every checkbox line in it. Text is kept verbatim.
      This is the one rule for which checkboxes are a ticket's criteria:
      to-plan.sh graph and split-human-check read a body by it too
      (extract_lines, which also gives each criterion's line index).
  python3 -I criteria.py ticket < issue.json
      a ticket's criteria and where they came from, as JSON {criteria, source}
      from the issue as `gh issue view --json body,comments` prints it. The
      body's criteria win (source "body"). With none there, the newest
      comment that starts with the triage disclaimer and has an "Agent Brief"
      heading supplies them (source: that comment's url, else "comment").
      With none anywhere, criteria is [] and source null.
  python3 -I criteria.py where < issue.json
      where a ticket's criteria live, by ticket's rule, so a caller can edit
      them there (#215): {criteria, source, text, comment_id}, where text is
      the body or that comment's body, and comment_id that comment's node id
      ("id" in gh's --json comments; null for the body). With no criteria
      anywhere, text is the body. lib/criteria-lib.sh reads and writes by it.
  python3 -I criteria.py align <criteria.json> <verdict.json> <record.json>
      one entry per ticket criterion, in order, as JSON: {criterion, met,
      evidence, claimed}, plus "human": true where the verdict's "met"
      is "human" (only a person can verify it; met stays false), and "gate":
      true where it is "gate" or the criterion reads as one only the merge
      gate can check (merge_gate_criterion; met stays false). Each takes the verdict entry with the same text,
      else the verdict entry in its position when the counts agree; with
      none it is unmet. "claimed" is the worker record's "met" by the same
      rule (the same text, else the entry in its position when the record's
      count matches the ticket's), or null. A record or verdict that is missing or unreadable
      counts as empty. A criterion the worker's record lists in
      "unmeetable" (no worker could meet it here, #186), by the same text,
      gets "unmeetable": {why, verifier_agrees}: the worker's why, and
      whether the verifier agrees (it is unmet and the verdict entry says
      "unmeetable": true); never on one that is "human" or "gate".
  python3 -I criteria.py change <changes.json> < criteria.json
      the criteria (a JSON array) with the changes the Artisan made at an
      exception gate applied in order (#186): each {action, criterion, as?};
      "drop" and "split" take the criterion off, "rewrite" puts "as" in its
      place. A change naming no criterion here changes nothing.
  python3 -I criteria.py mark <changes.json> < body.md > body.md
      the body (or triage comment) with those changes written onto its
      criterion lines (extract's rule), in order and matched as change
      matches them (#220): a "rewrite" line keeps its box and reads "as"; a
      "drop" or "split" line loses its box and is struck through, saying
      where it went: "- ~~<criterion>~~ (dropped at exception gate #<gate>:
      <why>)" or "(moved to #<to> at exception gate #<gate>)", "gate" being
      the gate's issue number ("an exception gate" without one). A struck
      line is no longer a criterion, so marking twice changes nothing more.
      wave.sh close marks a ticket's criteria_changes, then ticks it.
  python3 -I criteria.py tick <evidence.json> < body.md > body.md
      the body with "- [ ] <criterion>" turned into "- [x] <criterion>" for
      every criterion the evidence (a contract or a record) marks met, or
      marks "gate": true (wave.sh close ticks a merged ticket's, whose merge
      gate was green).
  python3 -I criteria.py merge-gate < body.md
      every checkbox line in the body, under any heading, that reads as a
      criterion only the merge gate can check, as a JSON array of strings:
      the whole criterion states the outcome (CI or the merge gate is green,
      on the PR or not; the PR shows or lists ...), and it names no script
      and no condition (when, if, blocks, fails), so one about code that
      runs CI is not one. Quoted or backticked text is read as one word: a
      criterion quoting one is about it, not one itself.

Standard-library Python 3.
"""
import json
import re
import sys

BOX = re.compile(r"^\s*[-*]\s+\[[ xX]\]\s+(.*\S)\s*$")
OPEN_BOX = re.compile(r"^(\s*[-*]\s+)\[ \](\s+)(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")


def norm(text):
    return " ".join(str(text).split()).casefold()


def extract_lines(lines):
    """(line index, criterion) for each of a body's criteria (see extract)."""
    found, inside, level, seen_heading = [], False, 0, False
    for i, line in enumerate(lines):
        h = HEADING.match(line)
        if h:
            depth = len(h.group(1))
            if "acceptance criteria" in h.group(2).casefold():
                inside, level, seen_heading = True, depth, True
                continue
            if inside and depth <= level:
                inside = False
            continue
        m = BOX.match(line)
        if m and inside:
            found.append((i, m.group(1)))
    if seen_heading:
        return found
    return [(i, m.group(1)) for i, m in enumerate(map(BOX.match, lines)) if m]


def extract(lines):
    return [c for _, c in extract_lines(lines)]


# A criterion about CI, the merge gate or the PR (#174): a run can't judge
# it (workers never open PRs, and the merge gate runs after the verifier),
# so it is "gate": wave.sh merge's gate is what satisfies it. Only a whole
# criterion that states the outcome reads as one ("CI is green on the PR",
# "the run's merge gate is green", "the PR shows ..."); one about code that
# runs CI or a merge gate ("wave.sh merge blocks the ticket when CI is not
# green") never does: the verifier judges that, or marks it "gate" itself.
_GATE_SUBJECT = r"^(the\s+)?(run'?s\s+)?(ci|merge\s+gate)('s)?(\s+[\w'-]+){0,2}\s+"
# The merged work (#244): "on the merged commit", "for the merged change",
# "on the merge commit". A ticket's branch is not it: a worker's branch is
# the verifier's to judge, or the plan step's to flag (#213).
_MERGED = r"(on|in|for)\s+(the|this|its)\s+(merged?\s+(commit|change|work|branch|result)s?|merge)"
_ON_PR = r"(on|in)\s+the\s+(pr|pull\s+request)"
MERGE_GATE_OUTCOMES = [
    re.compile(_GATE_SUBJECT + r"(is|are|goes|stays|turns)\s+green(\s+(" + _ON_PR + "|" + _MERGED + r"))?\W*$", re.I),
    re.compile(_GATE_SUBJECT + r"(pass(es)?|succeeds?|(is|are)\s+passing)\s+" + _MERGED + r"\W*$", re.I),
    re.compile(r"^(the\s+)?(pr|pull\s+request)\s+(shows|lists)\b", re.I),
]
IMPLEMENTATION = re.compile(r"\.(sh|py)\b|\b(when|if|unless|blocks?|fails?)\b", re.I)
QUOTED = re.compile(r'"[^"]*"|`[^`]*`|\u201c[^\u201d]*\u201d')


def merge_gate_criterion(text):
    """True when the criterion states an outcome only the merge gate can check."""
    bare = " ".join(QUOTED.sub("x", str(text)).split())
    if IMPLEMENTATION.search(bare):
        return False
    return any(p.search(bare) for p in MERGE_GATE_OUTCOMES)


# A criterion that reads as needing CI, a pull request or the whole suite but
# that merge_gate_criterion doesn't recognize (#213): the verifier would judge
# it, and a worker can't meet it (it runs no CI, opens no PR, runs only the
# tests covering its change). The plan step flags it; the merge gate already
# checks it on every merge. Each pattern names what the criterion needs, and
# each states an outcome (green, passes, succeeds) of CI, on a PR or of the
# whole suite. One that names a script, or a condition, is about code (the
# same rule as merge_gate_criterion's), and one that names CI, a PR or the
# suite in passing ("the script's CI mode prints ...", "the merge gate runs
# the full suite", "the PR is merged at the end gate") states no such
# outcome, so neither is one.
_PASSES = r"(is\s+|are\s+|goes\s+|stays\s+|turns\s+)?(green|pass(es|ing)?|succeeds?)\b"
_PASSED = r"\b(pass(es|ing)?|green|succeeds?)\s+(on|in)\s+"
NEEDS_MERGE_GATE = [
    ("the full suite", re.compile(r"\b(full|whole|entire|complete)\s+(test\s+)?suite\s+" + _PASSES
                                  + r"|^(the\s+)?(test\s+)?suite\s+" + _PASSES
                                  + r"|^(all|every)\s+(the\s+)?(tests?|checks?)\s+" + _PASSES + r"\W*$", re.I)),
    ("CI", re.compile(r"\bci\s+((run|runs|job|jobs|checks?|build)\s+)?" + _PASSES
                      + r"|" + _PASSED + r"(the\s+)?ci\b", re.I)),
    ("a pull request", re.compile(_PASSED + r"(the|this|its|a)\s+(pr|pull\s+request)\b", re.I)),
]
SCRIPT = re.compile(r"\.(sh|py)\b", re.I)


def needs_merge_gate(text):
    """What the criterion reads as needing ("CI", "a pull request" or "the full
    suite") when #174's rule doesn't already leave it to the merge gate, else None."""
    if merge_gate_criterion(text) or SCRIPT.search(str(text)):
        return None
    bare = " ".join(QUOTED.sub("x", str(text)).split())
    if IMPLEMENTATION.search(bare):
        return None
    return next((what for what, p in NEEDS_MERGE_GATE if p.search(bare)), None)


def merge_gate_lines(lines):
    return [m.group(1) for m in map(BOX.match, lines) if m and merge_gate_criterion(m.group(1))]


TRIAGE_DISCLAIMER = "> *This was generated by AI during triage.*"
AGENT_BRIEF = re.compile(r"^#{1,6}\s+Agent Brief\s*$", re.I | re.M)


def criteria_source(issue):
    """{criteria, source, text, comment_id}: where an issue's criteria live (see the usage)."""
    issue = issue if isinstance(issue, dict) else {}
    body = str(issue.get("body") or "")
    found = extract(body.split("\n"))
    if found:
        return {"criteria": found, "source": "body", "text": body, "comment_id": None}
    comments = [c for c in issue.get("comments") or [] if isinstance(c, dict)]
    for c in reversed(comments):
        text = str(c.get("body") or "")
        if text.lstrip().startswith(TRIAGE_DISCLAIMER) and AGENT_BRIEF.search(text):
            found = extract(text.split("\n"))
            if found:
                return {"criteria": found, "source": c.get("url") or "comment", "text": text,
                        "comment_id": c.get("id") or None}
            break
    return {"criteria": [], "source": None, "text": body, "comment_id": None}


def ticket_criteria(issue):
    """{criteria, source} for an issue's body and comments (see the usage)."""
    where = criteria_source(issue)
    return {"criteria": where["criteria"], "source": where["source"]}


def entries(doc):
    """The acceptance entries of a verdict or record: dicts only."""
    acc = doc.get("acceptance") if isinstance(doc, dict) else None
    return [e for e in acc if isinstance(e, dict)] if isinstance(acc, list) else []


def find(items, criterion):
    key = norm(criterion)
    return next((e for e in items if norm(e.get("criterion", "")) == key), None)


def unmeetable_claims(record):
    """The worker record's "unmeetable" entries: dicts only."""
    listed = record.get("unmeetable") if isinstance(record, dict) else None
    return [u for u in listed if isinstance(u, dict)] if isinstance(listed, list) else []


def change(criteria, changes):
    out = list(criteria)
    for ch in changes if isinstance(changes, list) else []:
        if not isinstance(ch, dict):
            continue
        key = norm(ch.get("criterion", ""))
        at = next((i for i, c in enumerate(out) if norm(c) == key), None)
        if at is None:
            continue
        if ch.get("action") == "rewrite" and str(ch.get("as") or "").strip():
            out[at] = str(ch["as"]).strip()
        elif ch.get("action") in ("drop", "split"):
            del out[at]
    return out


BOXED = re.compile(r"^(\s*[-*]\s+)(\[[ xX]\]\s+)(.*\S)(\s*)$")


def marked(text, ch):
    """A struck-through criterion saying where it went (see mark)."""
    gate = str(ch.get("gate") or "").strip()
    at = f"exception gate #{gate}" if gate else "an exception gate"
    if ch.get("action") == "split":
        to = str(ch.get("to") or "").strip()
        note = (f"moved to #{to} at " if to else "moved off at ") + at
    else:
        why = str(ch.get("why") or "").strip()
        note = f"dropped at {at}" + (f": {why}" if why else "")
    return f"~~{text}~~ ({note})"


def mark(changes, body):
    lines = body.split("\n")
    live = [i for i, _ in extract_lines(lines)]
    for ch in changes if isinstance(changes, list) else []:
        if not isinstance(ch, dict) or ch.get("action") not in ("rewrite", "drop", "split"):
            continue
        key = norm(ch.get("criterion", ""))
        at = next((i for i in live if norm(BOXED.match(lines[i]).group(3)) == key), None)
        if at is None:
            continue
        bullet, box, text, tail = BOXED.match(lines[at]).groups()
        if ch["action"] == "rewrite":
            if str(ch.get("as") or "").strip():
                lines[at] = bullet + box + str(ch["as"]).strip() + tail
        else:
            lines[at] = bullet + marked(text, ch)
            live.remove(at)
    return "\n".join(lines)


def align(criteria, verdict, record):
    given, claims = entries(verdict), entries(record)
    listed = unmeetable_claims(record)
    out = []
    for i, c in enumerate(criteria):
        e = find(given, c)
        if e is None and len(given) == len(criteria):
            e = given[i]
        w = find(claims, c)
        if w is None and len(claims) == len(criteria):
            w = claims[i]
        met = bool(e) and e.get("met") is True
        entry = {
            "criterion": c,
            "met": met,
            "evidence": (e.get("evidence") or {}) if e else {"why": "the verifier gave no verdict on this criterion"},
            "claimed": None if w is None else w.get("met") is True,
        }
        # Only the merge gate can check it (#174): neither met nor unmet;
        # wave.sh merge's gate satisfies it, whatever the verifier said.
        if merge_gate_criterion(c) or (e and e.get("met") == "gate"):
            entry["met"] = False
            entry["gate"] = True
        # Only a person can verify it (references/human-checks.md): not met,
        # and not unmet either; verify.sh judge splits it into a Human check.
        elif e and e.get("met") == "human":
            entry["human"] = True
        # The guardrail an unmet criterion broke, as the verifier named it.
        elif not met and e and isinstance(e.get("guardrail"), str) and e["guardrail"]:
            entry["guardrail"] = e["guardrail"]
        # The worker said no worker could meet it here (#186): kept with
        # whether the verifier agrees, which only an unmet one can.
        u = find(listed, c)
        if u is not None and not entry.get("human") and not entry.get("gate"):
            entry["unmeetable"] = {
                "why": str(u.get("why") or ""),
                "verifier_agrees": not met and bool(e) and e.get("unmeetable") is True,
            }
        out.append(entry)
    return out


def tick(evidence, body):
    met = {norm(e.get("criterion", "")) for e in entries(evidence) if e.get("met") is True or e.get("gate") is True}
    out = []
    for line in body.split("\n"):
        m = OPEN_BOX.match(line)
        if m and norm(m.group(3)) in met:
            line = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"
        out.append(line)
    return "\n".join(out)


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "extract" and len(argv) == 2:
        print(json.dumps(extract(sys.stdin.read().split("\n"))))
    elif cmd == "ticket" and len(argv) == 2:
        try:
            issue = json.load(sys.stdin)
        except ValueError:
            sys.exit("criteria.py: stdin is not a JSON issue")
        print(json.dumps(ticket_criteria(issue)))
    elif cmd == "where" and len(argv) == 2:
        try:
            issue = json.load(sys.stdin)
        except ValueError:
            sys.exit("criteria.py: stdin is not a JSON issue")
        print(json.dumps(criteria_source(issue)))
    elif cmd == "align" and len(argv) == 5:
        criteria = load(argv[2])
        if not isinstance(criteria, list):
            sys.exit("criteria.py: the criteria file is not a JSON array")
        print(json.dumps(align(criteria, load(argv[3]), load(argv[4]))))
    elif cmd == "change" and len(argv) == 3:
        try:
            criteria = json.load(sys.stdin)
        except ValueError:
            sys.exit("criteria.py: stdin is not a JSON array of criteria")
        if not isinstance(criteria, list):
            sys.exit("criteria.py: stdin is not a JSON array of criteria")
        print(json.dumps(change(criteria, load(argv[2]))))
    elif cmd == "merge-gate" and len(argv) == 2:
        print(json.dumps(merge_gate_lines(sys.stdin.read().split("\n"))))
    elif cmd == "mark" and len(argv) == 3:
        sys.stdout.write(mark(load(argv[2]), sys.stdin.read()))
    elif cmd == "tick" and len(argv) == 3:
        sys.stdout.write(tick(load(argv[2]), sys.stdin.read()))
    else:
        print(__doc__.split("Standard-library")[0].rstrip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
