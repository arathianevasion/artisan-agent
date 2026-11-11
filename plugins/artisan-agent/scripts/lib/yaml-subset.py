"""Read the plain YAML subset config.yml uses and print it as JSON.

Run, never imported: python3 -I yaml-subset.py <file>. Standard library only.

Supported: block maps nested by indentation, scalars (numbers, true/false,
null, ~, empty, quoted or bare strings), flow lists [a, b] and flow maps
{a: 1} of scalars, "- item" block lists of scalars, and # comments.
Anything else is an error naming the line, so a config never half-reads.
Exit status: 0 ok, 1 unreadable or unsupported.
"""

import json
import re
import sys


class Bad(Exception):
    pass


def strip_comment(line):
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def scalar(text, lineno):
    t = text.strip()
    if t in ("", "~", "null", "Null", "NULL"):
        return None
    if t in ("true", "True", "TRUE"):
        return True
    if t in ("false", "False", "FALSE"):
        return False
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "'\"":
        return t[1:-1]
    if re.fullmatch(r"-?[0-9]+", t):
        return int(t)
    if re.fullmatch(r"-?[0-9]*\.[0-9]+", t):
        return float(t)
    if t[0] in "[{":
        return flow(t, lineno)
    if t[0] in "&*!|>@`":
        raise Bad("line %d: unsupported YAML: %s" % (lineno, t))
    return t


def split_items(body):
    items, depth, cur, quote = [], 0, [], None
    for ch in body:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "," and depth == 0:
            items.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    if "".join(cur).strip():
        items.append("".join(cur))
    return items


def flow(t, lineno):
    if t[0] == "[" and t[-1] == "]":
        return [scalar(i, lineno) for i in split_items(t[1:-1])]
    if t[0] == "{" and t[-1] == "}":
        out = {}
        for item in split_items(t[1:-1]):
            if ":" not in item:
                raise Bad("line %d: expected key: value in %s" % (lineno, t))
            k, v = item.split(":", 1)
            out[scalar(k, lineno)] = scalar(v, lineno)
        return out
    raise Bad("line %d: unbalanced flow value: %s" % (lineno, t))


def parse(text):
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise Bad("line %d: indent with spaces, not tabs" % n)
        line = strip_comment(raw)
        if line.strip() in ("", "---"):
            continue
        lines.append((n, len(line) - len(line.lstrip(" ")), line.strip()))
    value, i = block(lines, 0, 0)
    if i != len(lines):
        raise Bad("line %d: unexpected indentation" % lines[i][0])
    return {} if value is None else value


def block(lines, i, indent):
    if i >= len(lines):
        return None, i
    if lines[i][2].startswith("- ") or lines[i][2] == "-":
        out = []
        while i < len(lines) and lines[i][1] == indent and (lines[i][2] + " ").startswith("- "):
            n, _, content = lines[i]
            item = content[1:].strip()
            if re.match(r"^[^'\"\[{][^:]*:(\s|$)", item):
                raise Bad("line %d: lists of maps are not supported" % n)
            out.append(scalar(item, n))
            i += 1
        return out, i
    out = {}
    while i < len(lines) and lines[i][1] == indent:
        n, _, content = lines[i]
        m = re.match(r"^([A-Za-z0-9_.\-/]+|\"[^\"]*\"|'[^']*'):(?:\s+(.*))?$", content)
        if not m:
            raise Bad("line %d: expected key: value, got %s" % (n, content))
        key = scalar(m.group(1), n)
        if key in out:
            raise Bad("line %d: duplicate key %s" % (n, key))
        rest = m.group(2)
        i += 1
        if rest is None or rest == "":
            if i < len(lines) and lines[i][1] > indent:
                out[key], i = block(lines, i, lines[i][1])
            else:
                out[key] = None
        else:
            out[key] = scalar(rest, n)
    return out, i


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: yaml-subset.py <file>\n")
        return 2
    try:
        with open(sys.argv[1]) as f:
            value = parse(f.read())
        if not isinstance(value, dict):
            raise Bad("the top level must be a map of settings")
    except (OSError, Bad) as e:
        sys.stderr.write("%s: %s\n" % (sys.argv[1], e))
        return 1
    json.dump(value, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
