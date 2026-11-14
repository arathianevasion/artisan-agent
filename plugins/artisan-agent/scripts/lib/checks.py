"""The one reader of a project's recorded checks: CODING_STANDARDS.md `## Checks`.

Setup (/artisan-agent:setup, project_edit.py section) writes one line per
check it proved can fail:

    - `<command>`: proven to fail on <YYYY-MM-DD>, breaking: <the break>

and, for a check that can't run on every machine (#194), ends the line with
" (runs_locally: mac)" or " (runs_locally: never)"; without it a check is
"always".

Usage: python3 -I checks.py <CODING_STANDARDS.md path>

Prints JSON on stdout, always exit 0 for a readable or missing file:
    {"recorded": true,  "file": ..., "checks": [{"command", "proven_on", "break", "runs_locally"}]}
    {"recorded": false, "file": ..., "checks": [], "reason": "..."}
A line in the section that isn't a "- `command`" bullet is ignored, as are
lines inside a fenced code block or an HTML comment. A command listed twice
counts once. A runs_locally other than always, mac or never: exit 1.
"""

import json
import os
import re
import sys

SETUP_LINE = re.compile(r"^[-*]\s+`(.+?)`:\s*proven to fail on\s+(\S+?),?\s+breaking:\s*(.*)$")
ANY_LINE = re.compile(r"^[-*]\s+`([^`]+)`(?::\s*(.*))?$")
HEADING = re.compile(r"^#{1,2}\s")
RUNS_LOCALLY = re.compile(r"\s*\(runs_locally:\s*([^)]*?)\s*\)\s*$")
RUNS_LOCALLY_VALUES = ("always", "mac", "never")


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
        runs_locally = "always"
        r = RUNS_LOCALLY.search(line)
        if r:
            runs_locally = r.group(1)
            if runs_locally not in RUNS_LOCALLY_VALUES:
                raise ValueError("runs_locally must be always, mac or never, not %r: %s" % (runs_locally, line))
            line = line[:r.start()]
        m = SETUP_LINE.match(line)
        if m:
            check = {"command": m.group(1), "proven_on": m.group(2), "break": m.group(3)}
        else:
            m = ANY_LINE.match(line)
            if not m:
                continue
            check = {"command": m.group(1), "proven_on": None, "break": None}
        check["runs_locally"] = runs_locally
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
    try:
        out = read(argv[1])
    except ValueError as e:
        sys.stderr.write("checks.py: %s\n" % e)
        return 1
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
