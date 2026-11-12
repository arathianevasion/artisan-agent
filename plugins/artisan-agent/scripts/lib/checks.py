"""The one reader of a project's recorded checks: CODING_STANDARDS.md `## Checks`.

Setup (/artisan-agent:setup, project_edit.py section) writes one line per
check it proved can fail:

    - `<command>`: proven to fail on <YYYY-MM-DD>, breaking: <the break>

Usage: python3 -I checks.py <CODING_STANDARDS.md path>

Prints JSON on stdout, always exit 0 for a readable or missing file:
    {"recorded": true,  "file": ..., "checks": [{"command", "proven_on", "break"}]}
    {"recorded": false, "file": ..., "checks": [], "reason": "..."}
A line in the section that isn't a "- `command`" bullet is ignored, as are
lines inside a fenced code block or an HTML comment. A command listed twice
counts once.
"""

import json
import os
import re
import sys

SETUP_LINE = re.compile(r"^[-*]\s+`(.+?)`:\s*proven to fail on\s+(\S+?),?\s+breaking:\s*(.*)$")
ANY_LINE = re.compile(r"^[-*]\s+`([^`]+)`(?::\s*(.*))?$")
HEADING = re.compile(r"^#{1,2}\s")


def section(lines, heading):
    """The lines under '## heading', up to the next # or ## heading, or None."""
    want = "## " + heading
    for i, line in enumerate(lines):
        if line.strip() == want:
            j = i + 1
            while j < len(lines) and not HEADING.match(lines[j]):
                j += 1
            return lines[i + 1:j]
    return None


def read(path):
    out = {"recorded": False, "file": path, "checks": []}
    if not os.path.isfile(path):
        out["reason"] = "no %s" % os.path.basename(path)
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    body = section(lines, "Checks")
    if body is None:
        out["reason"] = "%s has no ## Checks section" % os.path.basename(path)
        return out
    seen = set()
    fenced = comment = False
    for raw in body:
        line = raw.strip()
        if line.startswith("```") or line.startswith("~~~"):
            fenced = not fenced
            continue
        if comment:
            comment = "-->" not in line
            continue
        if line.startswith("<!--"):
            comment = "-->" not in line
            continue
        if fenced:
            continue
        m = SETUP_LINE.match(line)
        if m:
            check = {"command": m.group(1), "proven_on": m.group(2), "break": m.group(3)}
        else:
            m = ANY_LINE.match(line)
            if not m:
                continue
            check = {"command": m.group(1), "proven_on": None, "break": None}
        if check["command"].strip() and check["command"] not in seen:
            seen.add(check["command"])
            out["checks"].append(check)
    if out["checks"]:
        out["recorded"] = True
    else:
        out["reason"] = "## Checks in %s lists no checks" % os.path.basename(path)
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: checks.py <CODING_STANDARDS.md>\n")
        return 2
    json.dump(read(argv[1]), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
