"""The arithmetic of /artisan-agent:to-plan: propose plans from a ticket graph,
edit them, check them, render the approval view. No tracker access here; the
tracker half is scripts/to-plan.sh. Standard-library Python 3, run as
`python3 -I to-plan.py <command> ...` (see scripts/to-plan.sh for usage).

Graph file:  {"tickets": {"<n>": {"title", "blocked_by": ["<n>"...],
              "acceptance": ["..."], "slice": "<name>", "estimate_usd": 1.5,
              or "model" + "expected": {"input_tokens", "output_tokens"},
              "external_blockers": ["<n>"...]}}}
              A Human check ticket also has "human_check_for": "<agent ticket>"
              and needs no estimate.
Plans file:  {"schema_version": 1, "budget_usd": 10,
              "plans": [{"slice": "...", "tickets": ["<n>"...], "issue": 7?}],
              "human_check_overrides": [{"ticket", "criterion", "why"}]?}
A plan's number is its position (1-based); the order is the order they run in.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PRICES = os.path.join(HERE, "..", "..", "references", "model-prices.json")
HUMAN_CHECKS = os.path.join(HERE, "..", "..", "references", "human-checks.md")
MARKER = "<!-- artisan-agent:human-check-for #%s -->"


class Refusal(Exception):
    """A request that cannot be honoured; the message names why."""


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Refusal("cannot read %s: %s" % (path, e))


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def key(n):
    return (0, int(n)) if str(n).isdigit() else (1, str(n))


def graph_tickets(graph):
    tickets = graph.get("tickets")
    if not isinstance(tickets, dict) or not tickets:
        raise Refusal("the graph has no tickets")
    out = {}
    for n, t in tickets.items():
        n = str(n).lstrip("#")
        out[n] = t
    for n, t in out.items():
        for b in t.get("blocked_by") or []:
            if str(b).lstrip("#") not in out:
                raise Refusal("#%s is blocked by #%s, which is not in the graph "
                              "(list it under external_blockers if it is outside this set)" % (n, str(b).lstrip("#")))
    return out


def blockers(tickets, n):
    return [str(b).lstrip("#") for b in tickets[n].get("blocked_by") or []]


def human_check_for(tickets, n):
    """The agent ticket a Human check ticket verifies, or None."""
    a = tickets[n].get("human_check_for")
    return str(a).lstrip("#") if a not in (None, "") else None


def estimate(tickets, n):
    t = tickets[n]
    if human_check_for(tickets, n):
        return 0.0   # a person's check, not agent work
    if t.get("estimate_usd") is not None:
        return float(t["estimate_usd"])
    model, exp = t.get("model"), t.get("expected") or {}
    if model and exp:
        models = load(PRICES).get("models", {})
        if model not in models:
            raise Refusal("#%s: model %s is not in references/model-prices.json" % (n, model))
        p = models[model]
        return (exp.get("input_tokens", 0) * p["input_per_mtok"]
                + exp.get("output_tokens", 0) * p["output_per_mtok"]) / 1e6
    raise Refusal("#%s has no estimate: give estimate_usd, or a model with expected tokens "
                  "(the plan step's estimate)" % n)


def find_cycle(tickets):
    state = {}

    def visit(n, path):
        state[n] = 1
        for b in blockers(tickets, n):
            if state.get(b) == 1:
                return path[path.index(b):] + [b] if b in path else [b, n, b]
            if b not in state:
                c = visit(b, path + [b])
                if c:
                    return c
        state[n] = 2
        return None

    for n in sorted(tickets, key=key):
        if n not in state:
            c = visit(n, [n])
            if c:
                return c
    return None


def sccs(nodes, edges):
    """Strongly connected components of {node: set(successors)} (Tarjan)."""
    index, low, on, stack, out, counter = {}, {}, set(), [], [], [0]

    def strong(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in sorted(edges.get(v, ())):
            if w not in index:
                strong(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for v in nodes:
        if v not in index:
            strong(v)
    return out


def slice_of(tickets, n):
    agent = human_check_for(tickets, n)
    if agent in tickets and agent != n:
        return slice_of(tickets, agent)   # a Human check goes where its agent ticket goes
    return str(tickets[n].get("slice") or "").strip() or "#" + n


def propose(graph, budget):
    tickets = graph_tickets(graph)
    cycle = find_cycle(tickets)
    if cycle:
        raise Refusal("the blocking edges form a cycle: " + " -> ".join("#" + c for c in cycle)
                      + " (a planning bug to fix in the tickets)")
    cost = {n: estimate(tickets, n) for n in tickets}
    # Slices are units: a plan is cut only between them. Slices that block each
    # other both ways cannot be ordered, so they become one unit.
    names = sorted({slice_of(tickets, n) for n in tickets})
    edges = {s: set() for s in names}
    for n in tickets:
        for b in blockers(tickets, n):
            if slice_of(tickets, b) != slice_of(tickets, n):
                edges[slice_of(tickets, n)].add(slice_of(tickets, b))
    comp_of = {}
    for comp in sccs(names, edges):
        for s in comp:
            comp_of[s] = tuple(sorted(comp))
    units = {}
    for n in tickets:
        units.setdefault(comp_of[slice_of(tickets, n)], []).append(n)
    uedges = {u: set() for u in units}
    for u, members in units.items():
        for n in members:
            for b in blockers(tickets, n):
                bu = comp_of[slice_of(tickets, b)]
                if bu != u:
                    uedges[u].add(bu)
    # Order units so blockers come first; ties by lowest ticket number.
    order, done = [], set()
    pending = sorted(units, key=lambda u: min(key(n) for n in units[u]))
    while pending:
        ready = [u for u in pending if uedges[u] <= done]
        u = ready[0]
        order.append(u)
        done.add(u)
        pending.remove(u)
    plans, cur, cur_cost = [], [], 0.0
    for u in order:
        c = sum(cost[n] for n in units[u])
        if cur and cur_cost + c > budget:
            plans.append(cur)
            cur, cur_cost = [], 0.0
        cur = cur + [u]
        cur_cost += c
    if cur:
        plans.append(cur)
    result = []
    for p in plans:
        members = [n for u in p for n in units[u]]
        members = ordered(tickets, members)
        result.append({"slice": slice_text(tickets, members), "tickets": members})
    return {"schema_version": 1, "budget_usd": budget, "plans": result}


def ordered(tickets, members):
    """Members with blockers first, ties by number."""
    left, out = set(members), []
    while left:
        ready = sorted((n for n in left if not (set(blockers(tickets, n)) & left)), key=key)
        out.append(ready[0])
        left.discard(ready[0])
    return out


def slice_text(tickets, members):
    seen = []
    for n in members:
        s = slice_of(tickets, n)
        if s not in seen:
            seen.append(s)
    return ", ".join(seen)


def validate(plans, graph):
    """Raise Refusal unless every ticket is in exactly one plan and no blocker
    sits in a later plan than the ticket it blocks."""
    tickets = graph_tickets(graph)
    where = {}
    for i, p in enumerate(plans["plans"]):
        if not p.get("tickets"):
            raise Refusal("plan %d has no tickets" % (i + 1))
        for n in p["tickets"]:
            n = str(n)
            if n in where:
                raise Refusal("#%s is in plans %d and %d" % (n, where[n] + 1, i + 1))
            if n not in tickets:
                raise Refusal("#%s is in plan %d but not in the graph" % (n, i + 1))
            where[n] = i
    missing = sorted(set(tickets) - set(where), key=key)
    if missing:
        raise Refusal("not in any plan: " + ", ".join("#" + n for n in missing))
    for n in tickets:
        for b in blockers(tickets, n):
            if where[b] > where[n]:
                raise Refusal("#%s (plan %d) would run before its blocker #%s (plan %d)"
                              % (n, where[n] + 1, b, where[b] + 1))
    for n in sorted(tickets, key=key):
        agent = human_check_for(tickets, n)
        if agent in where and where[agent] != where[n]:
            raise Refusal("Human check #%s (plan %d) belongs in plan %d, with its agent ticket #%s"
                          % (n, where[n] + 1, where[agent] + 1, agent))


def plan_deps(plans, graph):
    """For each plan index, the earlier plan indexes it depends on, with
    dependencies already implied by another dependency removed."""
    tickets = graph_tickets(graph)
    where = {str(n): i for i, p in enumerate(plans["plans"]) for n in p["tickets"]}
    direct = [set() for _ in plans["plans"]]
    for n, i in where.items():
        for b in blockers(tickets, n):
            if where[b] != i:
                direct[i].add(where[b])
    reach = []
    for i in range(len(direct)):
        r = set()
        for d in direct[i]:
            r |= {d} | reach[d]
        reach.append(r)
    return [sorted(d for d in direct[i] if not any(d in reach[o] for o in direct[i] if o != d))
            for i in range(len(direct))]


def renumbered(plans, tickets):
    for p in plans["plans"]:
        p["slice"] = slice_text(tickets, p["tickets"])
    return plans


def plan_no(plans, text):
    try:
        i = int(text)
    except ValueError:
        raise Refusal("%r is not a plan number" % text)
    if not 1 <= i <= len(plans["plans"]):
        raise Refusal("there is no plan %d (plans are 1 to %d)" % (i, len(plans["plans"])))
    return i - 1


def edit(plans, graph, op, args):
    tickets = graph_tickets(graph)
    ps = plans["plans"]
    if any("issue" in p for p in ps):
        raise Refusal("these plans are already published; edit the issues instead")
    if op == "split":
        if len(args) != 2:
            raise Refusal("split <plan> <ticket,ticket,...>")
        i = plan_no(plans, args[0])
        moved = [t.lstrip("#") for t in args[1].split(",") if t]
        bad = [t for t in moved if t not in ps[i]["tickets"]]
        if bad:
            raise Refusal("not in plan %d: %s" % (i + 1, ", ".join("#" + t for t in bad)))
        rest = [t for t in ps[i]["tickets"] if t not in moved]
        if not rest:
            raise Refusal("that would leave plan %d empty; to move the whole plan use reorder" % (i + 1))
        ps[i]["tickets"] = rest
        ps.insert(i + 1, {"slice": "", "tickets": ordered(tickets, moved)})
    elif op == "merge":
        if len(args) != 2:
            raise Refusal("merge <plan> <plan>")
        a, b = plan_no(plans, args[0]), plan_no(plans, args[1])
        if a == b:
            raise Refusal("merge needs two different plans")
        lo, hi = min(a, b), max(a, b)
        ps[lo]["tickets"] = ordered(tickets, ps[lo]["tickets"] + ps[hi]["tickets"])
        del ps[hi]
    elif op == "reorder":
        if len(args) != 1:
            raise Refusal("reorder <order>, such as 2,1,3")
        order = [plan_no(plans, x) for x in args[0].split(",") if x]
        if sorted(order) != list(range(len(ps))):
            raise Refusal("the order must name every plan once, such as 2,1,3")
        plans["plans"] = [ps[i] for i in order]
    elif op == "move":
        if len(args) != 2:
            raise Refusal("move <ticket> <plan>")
        t, i = args[0].lstrip("#"), plan_no(plans, args[1])
        src = [k for k, p in enumerate(ps) if t in p["tickets"]]
        if not src:
            raise Refusal("#%s is in no plan" % t)
        if src[0] == i:
            raise Refusal("#%s is already in plan %d" % (t, i + 1))
        ps[src[0]]["tickets"].remove(t)
        ps[i]["tickets"] = ordered(tickets, ps[i]["tickets"] + [t])
    else:
        raise Refusal("unknown edit %r" % op)
    plans["plans"] = [p for p in plans["plans"] if p["tickets"]]
    renumbered(plans, tickets)
    validate(plans, graph)   # refuses before the file is written
    return plans


# ---- Human checks (references/human-checks.md) ------------------------------

def phrases():
    """The phrases that make a criterion read as needing a person: the list in
    references/human-checks.md, plus a project's own (TO_PLAN_EXTRA_PHRASES, a
    JSON list, from config human_check_phrases)."""
    out, inside = [], False
    try:
        with open(HUMAN_CHECKS, encoding="utf-8") as f:
            for line in f:
                if line.startswith("## "):
                    inside = line.strip() == "## Phrases"
                    continue
                m = re.match(r"^- `([^`]+)`\s*$", line)
                if inside and m:
                    out.append(m.group(1))
    except OSError as e:
        raise Refusal("cannot read the phrase list %s: %s" % (HUMAN_CHECKS, e))
    if not out:
        raise Refusal("no phrases under \"## Phrases\" in %s" % HUMAN_CHECKS)
    extra = os.environ.get("TO_PLAN_EXTRA_PHRASES") or "[]"
    try:
        extra = json.loads(extra)
    except ValueError:
        raise Refusal("human_check_phrases must be a list of phrases, got %s" % extra)
    if not isinstance(extra, list):
        raise Refusal("human_check_phrases must be a list of phrases")
    return out + [str(x) for x in extra if str(x).strip()]


def needs_person(text, words):
    """The first phrase in `words` that `text` contains as whole words, or None."""
    low = str(text).lower()
    for w in words:
        if re.search(r"(?<![a-z0-9])" + re.escape(w.strip().lower()) + r"(?![a-z0-9])", low):
            return w
    return None


def overridden(overrides, n, criterion):
    return any(str(o.get("ticket", "")).lstrip("#") == n and o.get("criterion") == criterion
               for o in overrides or [])


def human_check_flags(tickets, overrides, words=None):
    """Each agent criterion that reads as needing a person and is not overridden:
    [{"ticket", "criterion", "phrase"}]. A Human check's own criteria are its job."""
    words = phrases() if words is None else words
    out = []
    for n in sorted(tickets, key=key):
        if human_check_for(tickets, n):
            continue
        for c in tickets[n].get("acceptance") or []:
            w = needs_person(c, words)
            if w and not overridden(overrides, n, c):
                out.append({"ticket": n, "criterion": c, "phrase": w})
    return out


def add_overrides(plans, tickets, new):
    """Record the Artisan's overrides on the plan: each must name a criterion of
    the ticket and carry a reason. A repeat replaces the reason."""
    have = plans.setdefault("human_check_overrides", [])
    for o in new:
        n, c, why = str(o.get("ticket", "")).lstrip("#"), o.get("criterion", ""), str(o.get("why") or "").strip()
        if not why:
            raise Refusal("an override of #%s needs --why: the reason the criterion stays" % n)
        if n not in tickets:
            raise Refusal("#%s is not in the graph" % n)
        c = match_criterion(tickets[n].get("acceptance") or [], c, n)
        have[:] = [h for h in have if not (str(h.get("ticket")) == n and h.get("criterion") == c)]
        have.append({"ticket": n, "criterion": c, "why": why})
    return plans


def match_criterion(criteria, text, n):
    """The criterion `text` names: exactly, else the one criterion containing it."""
    text = str(text).strip()
    if text in criteria:
        return text
    hits = [c for c in criteria if text and text.lower() in c.lower()]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        raise Refusal("%r matches %d criteria of #%s; give one exactly" % (text, len(hits), n))
    raise Refusal("#%s has no criterion %r" % (n, text))


CHECKBOX = re.compile(r"^(\s*[-*]\s+\[[ xX]\]\s+)(.*?)\s*$")


def ac_lines(body):
    """(index, criterion) for each checkbox under ## Acceptance criteria."""
    out, inside = [], False
    for i, line in enumerate(body.split("\n")):
        if re.match(r"^##\s", line):
            inside = bool(re.match(r"^##\s+[Aa]cceptance [Cc]riteria", line))
            continue
        m = CHECKBOX.match(line)
        if inside and m:
            out.append((i, m.group(2)))
    return out


def split_human_check(req):
    """The text half of split-human-check. In: {agent, agent_title, agent_body,
    criterion, hc_body (or null), what (or null)}. Out: {criterion, title,
    agent_body, hc_body}, where a body is null when it needs no change. Moving
    a criterion that has already moved changes nothing."""
    agent, abody = str(req["agent"]), req.get("agent_body") or ""
    hbody = req.get("hc_body")
    on_agent = [c for _, c in ac_lines(abody)]
    on_hc = [c for _, c in ac_lines(hbody)] if hbody else []
    try:
        crit = match_criterion(on_agent, req["criterion"], agent)
    except Refusal:
        if not on_hc:
            raise
        crit = match_criterion(on_hc, req["criterion"], "%s's Human check" % agent)
    what = (req.get("what") or req.get("agent_title") or "#" + agent).strip()
    out = {"criterion": crit, "title": "Human check: %s (#%s)" % (what, agent),
           "agent_body": None, "hc_body": None}
    if hbody is None:
        out["hc_body"] = "\n".join([
            MARKER % agent,
            "## What to check", "",
            "By hand, on the result of #%s (%s): the criteria below, which only a person can verify."
            % (agent, req.get("agent_title") or what), "",
            "## Acceptance criteria", "",
            "- [ ] " + crit, "",
            "## Blocked by", "",
            "- #" + agent, ""])
    elif crit not in on_hc:
        lines = hbody.split("\n")
        found = ac_lines(hbody)
        if found:
            lines.insert(found[-1][0] + 1, "- [ ] " + crit)
        else:
            lines += ["", "## Acceptance criteria", "", "- [ ] " + crit]
        out["hc_body"] = "\n".join(lines)
    gone = [i for i, c in ac_lines(abody) if c == crit]
    if gone:
        lines = abody.split("\n")
        del lines[gone[0]]
        out["agent_body"] = "\n".join(lines)
    return out


def split_into_files(graph_path, plans_path, agent, hc, criterion, title):
    """After split-human-check: the graph and plans files follow the tracker."""
    graph = load(graph_path)
    tickets = graph.get("tickets") or {}
    if agent in tickets:
        t = tickets[agent]
        t["acceptance"] = [c for c in t.get("acceptance") or [] if c != criterion]
    h = tickets.setdefault(hc, {"title": title, "acceptance": []})
    h["title"] = title
    h["human_check_for"] = agent
    if criterion not in h.setdefault("acceptance", []):
        h["acceptance"].append(criterion)
    h["blocked_by"] = sorted(set([str(b) for b in h.get("blocked_by") or []] + ([agent] if agent in tickets else [])), key=key)
    graph["tickets"] = tickets
    save(graph_path, graph)
    if plans_path:
        plans = load(plans_path)
        if not any(hc in p["tickets"] for p in plans["plans"]):
            for p in plans["plans"]:
                if agent in p["tickets"]:
                    if "issue" in p:
                        raise Refusal("plan %s is published; add #%s to it on the tracker" % (p["issue"], hc))
                    p["tickets"] = ordered(graph_tickets(graph), p["tickets"] + [hc])
        save(plans_path, plans)


def money(x):
    return "$%.2f" % x


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def describe(tickets, n):
    return "#%s (%s)" % (n, cell(tickets[n].get("title", "")))


def warnings(plans, graph):
    tickets = graph_tickets(graph)
    budget = plans.get("budget_usd")
    out = []
    where = {str(n): i for i, p in enumerate(plans["plans"]) for n in p["tickets"]}
    for i, p in enumerate(plans["plans"]):
        total = sum(estimate(tickets, n) for n in p["tickets"])
        if budget is not None and total > budget:
            solo = len({slice_of(tickets, n) for n in p["tickets"]}) == 1
            out.append(("Plan %d" % (i + 1), "estimated at %s, over the %s budget%s." % (
                money(total), money(budget),
                " (one slice that cannot be cut smaller without ending mid-slice)" if solo else
                "; split it, or raise the budget")))
    slices = {}
    for n in tickets:
        slices.setdefault(slice_of(tickets, n), set()).add(where[n])
    for s in sorted(slices):
        if len(slices[s]) > 1:
            out.append(("Slice \"%s\"" % s, "split across plans %s: neither of them ends at a slice reviewable end to end."
                        % ", ".join(str(i + 1) for i in sorted(slices[s]))))
    for n in sorted(tickets, key=key):
        ext = [str(x).lstrip("#") for x in tickets[n].get("external_blockers") or []]
        if ext:
            out.append((describe(tickets, n), "waits on #%s, which is outside these tickets and still open." % ", #".join(ext)))
    out += human_check_warnings(plans, tickets)
    return out


def human_check_warnings(plans, tickets):
    return [(describe(tickets, f["ticket"]),
             "criterion \"%s\" reads as needing a person (\"%s\"): an agent can't show it. "
             "Split it into a Human check (`to-plan.sh split-human-check %s \"<criterion>\"`), "
             "or override it with a reason (`--override-human-check %s \"<criterion>\" --why ...`). "
             "The plan can't be approved while this stands." % (f["criterion"], f["phrase"], f["ticket"], f["ticket"]))
            for f in human_check_flags(tickets, plans.get("human_check_overrides"))]


def check(plans, graph):
    """validate, then refuse approval while an agent criterion needs a person;
    the flags go to stdout under "Needs your attention"."""
    validate(plans, graph)
    warn = human_check_warnings(plans, graph_tickets(graph))
    if warn:
        print("\n".join(["## Needs your attention", "", "| About | Problem |", "|---|---|"]
                        + ["| %s | %s |" % (cell(a), cell(b)) for a, b in warn]))
        raise Refusal("not ready to approve: %d agent criteria read as needing a person; "
                      "split each into a Human check or override it with --why" % len(warn))


def render(plans, graph):
    tickets = graph_tickets(graph)
    validate(plans, graph)
    deps = plan_deps(plans, graph)
    budget = plans.get("budget_usd")
    lines = ["# Proposed plans", ""]
    lines += ["| Plan | Ends at slice | Tickets | Estimate | Runs after |", "|---|---|---|---|---|"]
    grand = 0.0
    for i, p in enumerate(plans["plans"]):
        total = sum(estimate(tickets, n) for n in p["tickets"])
        grand += total
        after = ", ".join("Plan %d" % (d + 1) for d in deps[i]) or "nothing"
        lines.append("| Plan %d | %s | %d | %s of %s | %s |" % (
            i + 1, cell(p["slice"]), len(p["tickets"]), money(total),
            money(budget) if budget is not None else "no budget", after))
    lines += ["", "Total estimate %s across %d tickets." % (money(grand), len(tickets)), ""]
    for i, p in enumerate(plans["plans"]):
        lines += ["## Plan %d: %s" % (i + 1, p["slice"]), "",
                  "| Ticket | Blocked by | Estimate | Acceptance criteria |", "|---|---|---|---|"]
        for n in p["tickets"]:
            t = tickets[n]
            crit = "<br>".join("☐ " + cell(c) for c in t.get("acceptance") or []) or "none listed"
            blocked = ", ".join("#" + b for b in blockers(tickets, n)) or "none"
            cost = ("not estimated (Human check for #%s)" % human_check_for(tickets, n)
                    if human_check_for(tickets, n) else money(estimate(tickets, n)))
            lines.append("| %s | %s | %s | %s |" % (describe(tickets, n), blocked, cost, crit))
        lines.append("")
    overrides = plans.get("human_check_overrides") or []
    if overrides:
        lines += ["## Human-check overrides", "", "| Ticket | Criterion kept on the agent ticket | Why |", "|---|---|---|"]
        lines += ["| #%s | %s | %s |" % (cell(o["ticket"]), cell(o["criterion"]), cell(o["why"])) for o in overrides] + [""]
    warn = warnings(plans, graph)
    if warn:
        lines += ["## Needs your attention", "", "| About | Problem |", "|---|---|"]
        lines += ["| %s | %s |" % (cell(a), cell(b)) for a, b in warn] + [""]
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        raise Refusal("usage: to-plan.py propose|edit|check|render|deps|override|flags|overrides|split-text|split-files ...")
    cmd, rest = argv[1], argv[2:]
    if cmd == "propose":
        graph, budget = load(rest[0]), float(rest[1])
        print(json.dumps(propose(graph, budget), indent=2))
    elif cmd == "check":
        check(load(rest[0]), load(rest[1]))
    elif cmd == "override":
        # override <plans> <graph> <overrides.json>: record them on the plan.
        path, graph = rest[0], load(rest[1])
        plans = add_overrides(load(path), graph_tickets(graph), json.loads(rest[2]))
        save(path, plans)
    elif cmd == "flags":
        # stdin {"tickets", "human_check_overrides"?}: the open flags (plan.sh build).
        data = json.load(sys.stdin)
        tickets = {str(n).lstrip("#"): t for n, t in (data.get("tickets") or {}).items()}
        print(json.dumps(human_check_flags(tickets, data.get("human_check_overrides"))))
    elif cmd == "overrides":
        # stdin {"tickets"}, argv overrides.json: checked overrides (plan.sh build).
        data = json.load(sys.stdin)
        tickets = {str(n).lstrip("#"): t for n, t in (data.get("tickets") or {}).items()}
        print(json.dumps(add_overrides({}, tickets, json.loads(rest[0]))["human_check_overrides"]))
    elif cmd == "split-text":
        print(json.dumps(split_human_check(json.load(sys.stdin))))
    elif cmd == "split-files":
        graph_path, plans_path, agent, hc, criterion, title = rest[:6]
        split_into_files(graph_path, plans_path, agent, hc, criterion, title)
    elif cmd == "render":
        print(render(load(rest[0]), load(rest[1])))
    elif cmd == "edit":
        path, gpath, op = rest[0], rest[1], rest[2]
        save(path, edit(load(path), load(gpath), op, rest[3:]))
    elif cmd == "deps":
        print(json.dumps(plan_deps(load(rest[0]), load(rest[1]))))
    else:
        raise Refusal("unknown command %r" % cmd)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Refusal as e:
        sys.stderr.write("to-plan: %s\n" % e)
        sys.exit(1)
