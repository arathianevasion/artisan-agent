"""A gate's packet, from the run's state file: the full packet for the
`review-gate` issue (variant B) and the compressed view for the chat.

The rules: ${CLAUDE_PLUGIN_ROOT}/references/review-gates.md.

Usage:
  python3 -I packet.py header
      the slice gate body's table header, which chats.sh finds the role by.
  python3 -I packet.py cards < view.json
      the gate's decision cards as a JSON array: every decision the workers
      of the gate's tickets made alone (tickets.<t>.evidence.decisions), in
      ticket order, numbered from 1, each with its ticket.
  python3 -I packet.py body < view.json
      the issue body, top to bottom: header, summary line, decision cards,
      uncertainties, evidence by criterion (with guardrails applied, checks
      proven to fail, cost against estimate and the diffs), overall action.
  python3 -I packet.py chat < view.json
      the compressed packet: a counts line, one table row per decision
      (low confidence in bold), then "Keep all, or name one to change."

view.json is what gate.sh assembles:
  {"gate": {kind, slice, title, issue?, role, tickets: [t...],
            dependents: [{number, title}], problem?, solution?, cards?},
   "state": <the state file>,
   "guardrails": "<guardrails.sh table output, or an empty string>",
   "provisional": "<questions.sh provisional output, or an empty string>"}

Standard-library Python 3.
"""
import json
import sys

# The decision record has two confidences; provisional is the low one.
LOW = {"provisional"}


def cell(text):
    """One table cell: no pipes, no line breaks."""
    if text is None or text == "":
        return "-"
    return " ".join(str(text).replace("|", "/").split())


def money(usd):
    return "-" if usd is None else "$%.2f" % float(usd)


def is_low(card):
    return str(card.get("confidence", "provisional")) in LOW


def ticket_label(state, t):
    title = state.get("plan", {}).get("tickets", {}).get(t, {}).get("title")
    return "#%s (%s)" % (t, title) if title else "#%s" % t


def evidence_of(state, t):
    return (state.get("tickets", {}).get(t, {}) or {}).get("evidence") or {}


def cards(view):
    gate, state = view["gate"], view["state"]
    out = []
    for t in gate["tickets"]:
        for d in evidence_of(state, t).get("decisions") or []:
            if not isinstance(d, dict):
                continue
            card = dict(d)
            card["card"] = len(out) + 1
            card["ticket"] = t
            card.setdefault("by", "worker %s" % t)
            out.append(card)
    return out


def uncertainties(view):
    gate, state = view["gate"], view["state"]
    rows = []
    for t in gate["tickets"]:
        ev = evidence_of(state, t)
        for u in ev.get("unsure") or []:
            rows.append((t, "worker", u))
        for u in (ev.get("verifier") or {}).get("unsure") or []:
            rows.append((t, "verifier", u))
    return rows


def proven(entry):
    """A criterion is proven when it is met and a test or check shows it."""
    ev = entry.get("evidence") or {}
    return bool(entry.get("met")) and bool(ev.get("tests") or ev.get("checks"))


def criteria(view):
    gate, state = view["gate"], view["state"]
    rows = []
    for t in gate["tickets"]:
        for a in evidence_of(state, t).get("acceptance") or []:
            rows.append((t, a))
    return rows


def headline(view, the_cards, unsure):
    low = sum(1 for c in the_cards if is_low(c))
    n = len(the_cards)
    line = "%d decision%s" % (n, "" if n == 1 else "s")
    if low:
        line += " (%d low confidence)" % low
    u = len(unsure)
    return line + ", %d uncertaint%s" % (u, "y" if u == 1 else "ies")


def blocked_list(gate):
    deps = gate.get("dependents") or []
    if not deps:
        return "none"
    return ", ".join(
        "#%s (%s)" % (d["number"], d["title"]) if d.get("title") else "#%s" % d["number"] for d in deps
    )


def summary_lines(view):
    gate, state = view["gate"], view["state"]
    tickets = gate["tickets"]
    plan_tickets = state.get("plan", {}).get("tickets", {})
    problem = gate.get("problem") or "Build the %s slice: %s." % (
        gate.get("slice", "this"), ", ".join(ticket_label(state, t) for t in tickets))
    solution = gate.get("solution")
    if not solution:
        outs = [plan_tickets.get(t, {}).get("expected_output") for t in tickets]
        outs = [o for o in outs if o]
        solution = " ".join(outs) if outs else "Merged as %s." % ", ".join(
            "#%s at `%s`" % (t, str((state["tickets"].get(t) or {}).get("merge_commit") or "-")[:7]) for t in tickets)
    rows = criteria(view)
    met = sum(1 for _, a in rows if a.get("met"))
    prov = sum(1 for _, a in rows if proven(a))
    suites = [(state["tickets"].get(t) or {}).get("suite") or {} for t in tickets]
    suite_ok = all(s.get("passed") for s in suites) and suites
    verification = "%d of %d criteria verified across %d ticket%s: %d proven by a test or check, %d need%s you. %s" % (
        met, len(rows), len(tickets), "" if len(tickets) == 1 else "s", prov, len(rows) - prov,
        "s" if len(rows) - prov == 1 else "",
        "The full suite passed after every merge." if suite_ok else "The full suite's result after a merge is missing; see the evidence.")
    return problem, solution, verification


def card_block(c):
    low = is_low(c)
    conf = str(c.get("confidence", "provisional"))
    conf_cell = "**%s (low)**" % conf if low else conf
    made = "%s, job %s, on #%s" % (c.get("by"), c.get("job", "-"), c["ticket"])
    if c.get("criterion") not in (None, "", "none"):
        made += ", controversy criterion %s" % c["criterion"]
    n = c["card"]
    lines = [
        "### Card %d: %s%s" % (n, cell(c.get("question")), " (low confidence)" if low else ""),
        "",
        "| | |",
        "|---|---|",
        "| Choice | %s |" % cell(c.get("choice")),
        "| Alternative considered | %s |" % cell(c.get("alternative")),
        "| Confidence | %s |" % conf_cell,
        "| Kind | %s |" % cell(c.get("kind")),
        "| Made by | %s |" % cell(made),
        "| Actions | keep · change (`change %d to <choice>`) · make it a guardrail (`guardrail %d <team, product or individual> <ticket, area <name> or everywhere>`) |" % (n, n),
    ]
    if c.get("why"):
        lines.insert(8, "| Why | %s |" % cell(c["why"]))
    return lines


GATE_HEADER = "| Gate | Role needed | Slice | Tickets blocked |"  # `packet.py header`


def body(view):
    gate, state = view["gate"], view["state"]
    the_cards = gate.get("cards") or cards(view)
    unsure = uncertainties(view)
    problem, solution, verification = summary_lines(view)
    out = [
        "# %s" % gate["title"],
        "",
        GATE_HEADER,
        "|---|---|---|---|",
        "| %s | %s | %s | %s |" % (
            gate["kind"], cell(gate.get("role")),
            cell(", ".join(ticket_label(state, t) for t in gate["tickets"])), cell(blocked_list(gate))),
        "",
        "**%s.**" % headline(view, the_cards, unsure).capitalize(),
        "",
        "- **Problem:** %s" % cell(problem),
        "- **Solution:** %s" % cell(solution),
        "- **Verification:** %s" % cell(verification),
        "",
        "## Decisions",
        "",
    ]
    if the_cards:
        for c in the_cards:
            out += card_block(c) + [""]
    else:
        out += ["No agent made a decision alone in this slice.", ""]
    prov = (view.get("provisional") or "").strip().splitlines()
    if len(prov) > 2:
        out += ["Provisional cards from earlier tickets, not yet shown at a gate:", ""] + prov + [""]

    out += ["## Uncertainties", ""]
    if unsure:
        out += ["| Ticket | From | Unsure of |", "|---|---|---|"]
        out += ["| #%s | %s | %s |" % (t, who, cell(u)) for t, who, u in unsure]
    else:
        out += ["None recorded."]
    out += ["", "## Evidence", "", "### By criterion", ""]
    rows = criteria(view)
    if rows:
        out += ["| Ticket | Criterion | Status | Evidence |", "|---|---|---|---|"]
        for t, a in rows:
            ev = a.get("evidence") or {}
            shown = "; ".join(
                [str(x) for x in ev.get("tests") or []]
                + ["%s: %s" % (c.get("command"), c.get("result")) for c in ev.get("checks") or [] if isinstance(c, dict)]
                + ([ev["why"]] if ev.get("why") else []))
            out.append("| #%s | %s | %s | %s |" % (
                t, cell(a.get("criterion")), "proven" if proven(a) else "**needs you**", cell(shown)))
    else:
        out += ["No criteria recorded."]
    out += ["", "### Guardrails applied", ""]
    waves = state.get("waves") or []
    version = waves[-1].get("plugin_version") if waves else None
    if version:
        out += ["Plugin version %s." % version, ""]
    guard = (view.get("guardrails") or "").strip()
    out += [guard if guard.count("\n") >= 2 or guard.startswith("Could not") else "None in force."]
    out += ["", "### Checks proven to fail", ""]
    checks = state.get("plan", {}).get("checks") or []
    if checks:
        out += ["| Check | Covers | Proven to fail |", "|---|---|---|"]
        for c in checks:
            out.append("| `%s` | %s | %s |" % (
                cell(c.get("command")), cell(c.get("covers")),
                "yes" if c.get("proven_to_fail") else "**no: its results prove nothing**"))
    else:
        out += ["**None recorded at the plan step**: no check's passing result can be trusted until it has been seen to fail."]
    out += ["", "### Cost against estimate", "", "| Ticket | Cost | Estimate |", "|---|---|---|"]
    total_c = total_e = 0.0
    for t in gate["tickets"]:
        k = state["tickets"].get(t) or {}
        cost = k.get("cost_usd")
        est = state.get("plan", {}).get("tickets", {}).get(t, {}).get("estimate_usd")
        total_c += float(cost or 0)
        total_e += float(est or 0)
        out.append("| #%s | %s | %s |" % (t, money(cost), money(est)))
    out.append("| **Slice** | **%s** | **%s** |" % (money(total_c), money(total_e)))
    out += ["", "### Diffs", "", "Verification is behaviour, not a line-by-line review; open any diff you want to see.", "",
            "| Ticket | Merged as | Open it |", "|---|---|---|"]
    for t in gate["tickets"]:
        sha = (state["tickets"].get(t) or {}).get("merge_commit")
        out.append("| #%s | %s | %s |" % (
            t, "`%s`" % sha[:7] if sha else "-",
            "`git diff %s^1 %s`" % (sha[:7], sha[:7]) if sha else "-"))
    out += ["", "## Overall action", "",
            "Answer with the choice alone; why, confidence, guardrail level and reach are optional.", "",
            "| Say | Does |", "|---|---|",
            "| `keep all` | approves the slice: every card kept and this issue closed; %s |" % (
                "%s can then dispatch in the next wave" % blocked_list(gate) if gate.get("dependents")
                else "nothing in the run waits on it"),
            "| `change <card> to <choice>` | a rework ticket in this run for that card; the rest are kept when you approve |",
            "| `guardrail <card> <level> <reach>` | keeps the card and records it as a guardrail to make (level team, product or individual; reach ticket, area or everywhere) |"]
    return "\n".join(out) + "\n"


def chat(view):
    gate, state = view["gate"], view["state"]
    the_cards = gate.get("cards") or cards(view)
    unsure = uncertainties(view)
    ref = "#%s" % gate["issue"] if gate.get("issue") else "(not opened)"
    out = ["%s %s: %s. Blocks %s." % (gate["title"], ref, headline(view, the_cards, unsure), blocked_list(gate)), ""]
    if the_cards:
        out += ["| Card | Ticket | Decision | Confidence |", "|---|---|---|---|"]
        for c in the_cards:
            conf = str(c.get("confidence", "provisional"))
            out.append("| %d | #%s | %s → %s | %s |" % (
                c["card"], c["ticket"], cell(c.get("question")), cell(c.get("choice")),
                "**%s (low)**" % conf if is_low(c) else conf))
        out.append("")
    out.append("Keep all, or name one to change.")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "header":
        print(GATE_HEADER)
        return
    if len(sys.argv) != 2 or sys.argv[1] not in ("cards", "body", "chat"):
        sys.stderr.write(__doc__)
        sys.exit(2)
    view = json.load(sys.stdin)
    cmd = sys.argv[1]
    if cmd == "cards":
        json.dump(cards(view), sys.stdout)
        sys.stdout.write("\n")
    elif cmd == "body":
        sys.stdout.write(body(view))
    else:
        sys.stdout.write(chat(view))


if __name__ == "__main__":
    main()
