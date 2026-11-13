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
  python3 -I criteria.py align <criteria.json> <verdict.json> <record.json>
      one entry per ticket criterion, in order, as JSON: {criterion, met,
      evidence, claimed}. Each takes the verdict entry with the same text,
      else the verdict entry in its position when the counts agree; with
      none it is unmet. "claimed" is the worker record's "met" by the same
      rule (the same text, else the entry in its position when the record's
      count matches the ticket's), or null. A record or verdict that is missing or unreadable
      counts as empty.
  python3 -I criteria.py tick <evidence.json> < body.md > body.md
      the body with "- [ ] <criterion>" turned into "- [x] <criterion>" for
      every criterion the evidence (a contract or a record) marks met.

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
        # The guardrail an unmet criterion broke, as the verifier named it.
        if not met and e and isinstance(e.get("guardrail"), str) and e["guardrail"]:
            entry["guardrail"] = e["guardrail"]
        out.append(entry)
    return out


def tick(evidence, body):
    met = {norm(e.get("criterion", "")) for e in entries(evidence) if e.get("met") is True}
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
    elif cmd == "align" and len(argv) == 5:
        criteria = load(argv[2])
        if not isinstance(criteria, list):
            sys.exit("criteria.py: the criteria file is not a JSON array")
        print(json.dumps(align(criteria, load(argv[3]), load(argv[4]))))
    elif cmd == "tick" and len(argv) == 3:
        sys.stdout.write(tick(load(argv[2]), sys.stdin.read()))
    else:
        print(__doc__.split("Standard-library")[0].rstrip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
