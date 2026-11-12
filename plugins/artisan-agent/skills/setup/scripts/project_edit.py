#!/usr/bin/env python3
"""File edits for project-setup.sh. Every edit only adds: nothing that exists is
changed or removed. Each prints "changed: ..." or "unchanged: ..." lines.

  project_edit.py settings FILE DENY_JSON [HOOK_JSON] [--compact-percent N]
      merge into .claude/settings.json: enable artisan-agent and mattpocock-skills,
      register our marketplace, add the Skill(...) deny rules from DENY_JSON (the
      output of guard.sh deny-json) and, only when given, the hooks from HOOK_JSON
      (guard.sh settings-json, the fallback). A value the project already set is
      kept, even when it differs ("kept: ..."). With --compact-percent, env gets
      CLAUDE_AUTOCOMPACT_PCT_OVERRIDE (a string) when the project hasn't set it.
  project_edit.py section FILE HEADING LINE...
      make sure FILE has "## HEADING" and that each LINE is in that section;
      a missing section is appended at the end, missing lines at the section's end.
      A line "- `cmd`: ..." counts as present when "- `cmd`" starts any line there.
  project_edit.py labels-doc FILE
      make sure the triage-labels doc records all ten labels, then print
      "<tracker label><TAB><meaning>" per label, after a "labels:" line.
"""
import json
import os
import re
import sys

ENABLED = ["artisan-agent@artisan-agent", "mattpocock-skills@claude-plugins-official"]
MARKETPLACE = ("artisan-agent", {"source": {"source": "github", "repo": "arathianevasion/artisan-agent"}})

# role -> meaning; upstream's five (the doc maps each to a tracker string), then ours.
UPSTREAM_LABELS = [
    ("needs-triage", "Maintainer needs to evaluate this issue"),
    ("needs-info", "Waiting on reporter for more information"),
    ("ready-for-agent", "Fully specified, ready for an AFK agent"),
    ("ready-for-human", "Requires human implementation"),
    ("wontfix", "Will not be actioned"),
]
OUR_LABELS = [
    ("review-gate", "A review gate: holds its packet and blocks its dependents"),
    ("plan", "A plan: a chunk of tickets approved to run together"),
    ("in-run", "Being worked by a run; never re-triaged, edited or relabelled"),
    ("urgent", "Goes ahead of everything else"),
    ("deferred", "Deferred by triage; returns on its recorded condition"),
]


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except ValueError as e:
        sys.exit("project-setup: %s is not valid JSON (%s); fix it and rerun" % (path, e))
    if not isinstance(data, dict):
        sys.exit("project-setup: %s is not a JSON object; fix it and rerun" % path)
    return data


def write_json(path, data):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def cmd_settings(path, deny_path, hook_path=None, compact_percent=None):
    data = load_json(path)
    before = json.dumps(data, sort_keys=True)
    out = []

    enabled = data.setdefault("enabledPlugins", {})
    for p in ENABLED:
        if p not in enabled:
            enabled[p] = True
            out.append("changed: enabled %s" % p)
        elif enabled[p] is not True:
            out.append("kept: %s is set to %s in %s; left as the project set it" % (p, json.dumps(enabled[p]), path))

    name, entry = MARKETPLACE
    markets = data.setdefault("extraKnownMarketplaces", {})
    if name not in markets:
        markets[name] = entry
        out.append("changed: registered marketplace %s" % name)

    with open(deny_path) as f:
        deny = json.load(f)["permissions"]["deny"]
    perms = data.setdefault("permissions", {})
    have = perms.setdefault("deny", [])
    added = [r for r in deny if r not in have]
    have.extend(added)
    if added:
        out.append("changed: added %d Skill deny rule(s)" % len(added))

    if compact_percent:
        env = data.setdefault("env", {})
        key = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
        if key not in env:
            env[key] = str(compact_percent)
            out.append("changed: %s=%s (the Engineering chat compacts out of sight)" % (key, compact_percent))
        elif str(env[key]) != str(compact_percent):
            out.append("kept: %s is %s in %s; left as the project set it" % (key, json.dumps(env[key]), path))

    if hook_path:
        with open(hook_path) as f:
            want = json.load(f)["hooks"]
        hooks = data.setdefault("hooks", {})
        for event, groups in want.items():
            mine = hooks.setdefault(event, [])
            for g in groups:
                if g not in mine:
                    mine.append(g)
                    out.append("changed: added the %s replaced-skill hook (fallback)" % event)

    if json.dumps(data, sort_keys=True) != before or not os.path.exists(path):
        write_json(path, data)
    if not [l for l in out if l.startswith("changed:")]:
        out.append("unchanged: %s" % path)
    print("\n".join(out))


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return f.read().splitlines()


def write_lines(path, lines):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def section_bounds(lines, heading):
    """(start, end) of '## heading' (end exclusive, before the next ## or #), or None."""
    want = "## " + heading
    for i, l in enumerate(lines):
        if l.strip() == want:
            j = i + 1
            while j < len(lines) and not re.match(r"^#{1,2} ", lines[j]):
                j += 1
            return i, j
    return None


def insert_in_section(lines, start, end, new):
    """Insert new lines after the last non-blank line of the section at start..end,
    keeping one blank line between the heading and its body and before the next heading."""
    k = end
    while k > start + 1 and not lines[k - 1].strip():
        k -= 1
    block = list(new)
    if k == start + 1:
        block = [""] + block
    if k < len(lines) and lines[k].strip():
        block.append("")
    lines[k:k] = block


def cmd_section(path, heading, items):
    lines = read_lines(path)
    b = section_bounds(lines, heading)
    changed = []
    if b is None:
        while lines and not lines[-1].strip():
            lines.pop()
        if lines:
            lines.append("")
        lines.append("## " + heading)
        lines.append("")
        b = (len(lines) - 2, len(lines))
        changed.append("section %s" % heading)
    start, end = b
    body = [l.strip() for l in lines[start:end]]

    def present(item):
        # "- `cmd`: ..." (a check) counts as present when its command is listed at all
        m = re.match(r"^(- `[^`]+`)", item.strip())
        if m:
            return any(l.startswith(m.group(1)) for l in body)
        return item.strip() in body

    new = [i for i in items if not present(i)]
    if new:
        insert_in_section(lines, start, end, new)
        changed.append("%d line(s) under %s" % (len(new), heading))
    if changed:
        write_lines(path, lines)
        print("changed: %s: %s" % (path, ", ".join(changed)))
    else:
        print("unchanged: %s (%s)" % (path, heading))


def mapped_label(lines, role):
    """The tracker string the doc maps an upstream role to (column 2 of its row)."""
    for l in lines:
        cells = [c.strip() for c in l.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] == "`%s`" % role:
            m = re.match(r"^`([^`]+)`$", cells[1])
            if m:
                return m.group(1)
    return None


def cmd_labels_doc(path):
    lines = read_lines(path)
    created = not lines
    if created:
        lines = [
            "# Triage Labels",
            "",
            "The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.",
            "",
            "| Label in mattpocock/skills | Label in our tracker | Meaning |",
            "| -------------------------- | -------------------- | ------- |",
        ] + ["| `%s` | `%s` | %s |" % (r, r, m) for r, m in UPSTREAM_LABELS] + [
            "",
            "When a skill mentions a role (e.g. \"apply the AFK-ready triage label\"), use the corresponding label string from this table.",
        ]
    missing_up = [(r, m) for r, m in UPSTREAM_LABELS if mapped_label(lines, r) is None]
    text = "\n".join(lines)
    missing_ours = [(r, m) for r, m in OUR_LABELS if "`%s`" % r not in text]
    if missing_up:
        rows = ["| `%s` | `%s` | %s |" % (r, r, m) for r, m in missing_up]
        # an edited doc missing a role: record it in a table of its own, never rewrite theirs
        lines += ["", "## Upstream roles added by Artisan Agent setup", "",
                  "| Label in mattpocock/skills | Label in our tracker | Meaning |",
                  "| -------------------------- | -------------------- | ------- |"] + rows
    if missing_ours:
        b = section_bounds(lines, "Artisan Agent labels")
        rows = ["| `%s` | %s |" % (r, m) for r, m in missing_ours]
        if b is None:
            lines += ["", "## Artisan Agent labels", "",
                      "Labels the Artisan Agent pipeline adds to upstream's five. They are used as written.", "",
                      "| Label | Meaning |", "| ----- | ------- |"] + rows
        else:
            insert_in_section(lines, b[0], b[1], rows)
    if created or missing_up or missing_ours:
        write_lines(path, lines)
        print("changed: %s records the ten labels" % path)
    else:
        print("unchanged: %s" % path)
    print("labels:")
    for r, m in UPSTREAM_LABELS:
        print("%s\t%s" % (mapped_label(lines, r) or r, m))
    for r, m in OUR_LABELS:
        print("%s\t%s" % (r, m))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == "settings":
        pct = None
        if "--compact-percent" in args:
            i = args.index("--compact-percent")
            pct = args[i + 1] if i + 1 < len(args) else None
            args = args[:i] + args[i + 2:]
        if len(args) in (2, 3):
            cmd_settings(*args, compact_percent=pct)
            return
        sys.exit(__doc__)
    elif cmd == "section" and len(args) >= 2:
        cmd_section(args[0], args[1], args[2:])
    elif cmd == "labels-doc" and len(args) == 1:
        cmd_labels_doc(args[0])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
