"""Tick the acceptance criteria an evidence record says were met.

Usage: python3 -I tick-criteria.py <evidence-record.json> < body.md > body.md

Reads a ticket body on stdin and prints it with "- [ ] <criterion>" turned
into "- [x] <criterion>" for every criterion the record marks met. A
criterion matches a checkbox line when their text is the same once spaces
and case are normalised (the record copies criteria verbatim from the
ticket). Anything else is printed unchanged. Standard-library Python 3.
"""
import json
import re
import sys


def norm(text):
    return " ".join(str(text).split()).casefold()


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        record = json.load(f)
    met = {norm(a.get("criterion", "")) for a in record.get("acceptance") or [] if a.get("met") is True}
    box = re.compile(r"^(\s*[-*]\s+)\[ \](\s+)(.*)$")
    out = []
    for line in sys.stdin.read().split("\n"):
        m = box.match(line)
        if m and norm(m.group(3)) in met:
            line = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"
        out.append(line)
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
