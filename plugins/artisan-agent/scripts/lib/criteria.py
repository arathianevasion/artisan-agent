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
  python3 -I criteria.py ticket < issue.json
      a ticket's criteria and where they came from, as JSON {criteria, source}
      from the issue as `gh issue view --json body,comments` prints it. The
      body's criteria win (source "body"). With none there, the newest
      comment that starts with the triage disclaimer and has an "Agent Brief"
      heading supplies them (source: that comment's url, else "comment").
      With none anywhere, criteria is [] and source null.
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
      counts as empty.
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


def extract(lines):
    found, inside, level, seen_heading = [], False, 0, False
    for line in lines:
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
            found.append(m.group(1))
    if seen_heading:
        return found
    return [m.group(1) for m in map(BOX.match, lines) if m]


# A criterion about CI, the merge gate or the PR (#174): a run can't judge
# it (workers never open PRs, and the merge gate runs after the verifier),
# so it is "gate": wave.sh merge's gate is what satisfies it. Only a whole
# criterion that states the outcome reads as one ("CI is green on the PR",
# "the run's merge gate is green", "the PR shows ..."); one about code that
# runs CI or a merge gate ("wave.sh merge blocks the ticket when CI is not
# green") never does: the verifier judges that, or marks it "gate" itself.
MERGE_GATE_OUTCOMES = [
    re.compile(r"^(the\s+)?(run'?s\s+)?(ci('s\s+(\S+\s+)?job)?|ci\s+run|merge\s+gate)\s+(is|are|goes|stays|turns)\s+green"
               r"(\s+(on|in)\s+the\s+(pr|pull\s+request))?\W*$", re.I),
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


def merge_gate_lines(lines):
    return [m.group(1) for m in map(BOX.match, lines) if m and merge_gate_criterion(m.group(1))]


TRIAGE_DISCLAIMER = "> *This was generated by AI during triage.*"
AGENT_BRIEF = re.compile(r"^#{1,6}\s+Agent Brief\s*$", re.I | re.M)


def ticket_criteria(issue):
    """{criteria, source} for an issue's body and comments (see the usage)."""
    issue = issue if isinstance(issue, dict) else {}
    found = extract(str(issue.get("body") or "").split("\n"))
    if found:
        return {"criteria": found, "source": "body"}
    comments = [c for c in issue.get("comments") or [] if isinstance(c, dict)]
    for c in reversed(comments):
        text = str(c.get("body") or "")
        if text.lstrip().startswith(TRIAGE_DISCLAIMER) and AGENT_BRIEF.search(text):
            found = extract(text.split("\n"))
            return {"criteria": found, "source": (c.get("url") or "comment") if found else None}
    return {"criteria": [], "source": None}


def entries(doc):
    """The acceptance entries of a verdict or record: dicts only."""
    acc = doc.get("acceptance") if isinstance(doc, dict) else None
    return [e for e in acc if isinstance(e, dict)] if isinstance(acc, list) else []


def find(items, criterion):
    key = norm(criterion)
    return next((e for e in items if norm(e.get("criterion", "")) == key), None)


def align(criteria, verdict, record):
    given, claims = entries(verdict), entries(record)
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
    elif cmd == "align" and len(argv) == 5:
        criteria = load(argv[2])
        if not isinstance(criteria, list):
            sys.exit("criteria.py: the criteria file is not a JSON array")
        print(json.dumps(align(criteria, load(argv[3]), load(argv[4]))))
    elif cmd == "merge-gate" and len(argv) == 2:
        print(json.dumps(merge_gate_lines(sys.stdin.read().split("\n"))))
    elif cmd == "tick" and len(argv) == 3:
        sys.stdout.write(tick(load(argv[2]), sys.stdin.read()))
    else:
        print(__doc__.split("Standard-library")[0].rstrip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
