"""The retro's computations: the run's facts and signals, the lesson check,
the chat round, the satisfaction record and its triggers, and the edits a
kept lesson makes. retro.sh calls it; nothing here touches git or the tracker.

Usage (python3 -I retro.py <command> ...):
  facts <state.json> <jobs.md> [<actions.jsonl>] [<misses.jsonl>]
      the run's facts and signals as JSON (below)
  check <lessons.json> <threshold>
      the preparer's lessons, checked and normalised: each gets its home,
      and judgement calls become questions. Exit 1 with one line per problem
  render <checked.json> <facts.json> <questions.md> [<motivation.md>]
      the chat round, as Markdown
  questions <ARTISAN.md>...
      the satisfaction questions from the first file that has a
      "## Retro questions" section, as JSON
  record <answers.json> <facts.json> <history.jsonl> <project> <run> <date>
      prints two lines: the satisfaction record line to append, then the
      triggers as JSON: {"why": [{question, reason}], "chores": [text]}
  apply <worktree> <lesson.json>
      makes a kept lesson's change in a checkout: text under a section of a
      file (the file and section made if missing), or a config number set
  promote <file> <section> <line>
      adds LINE under SECTION in an individual standards file

Standard-library Python 3.
"""
import json
import os
import re
import sys

# Lesson kind -> (home as shown, where it is delivered).
HOMES = {
    "mechanical": ("a check (lint rule, test, hook, CI job)", "project"),
    "engineering-taste": ("coding standards (CODING_STANDARDS.md)", "project"),
    "product-taste": ("product standards (PRODUCT_STANDARDS.md)", "project"),
    "domain": ("the glossary or an ADR", "project"),
    "calibration": ("the project's config numbers (.artisan-agent/config.yml)", "project"),
    "pipeline": ("a ticket in arathianevasion/artisan-agent", "pipeline"),
    "upstream": ("the upstream check", "individual"),
    "experience": ("the satisfaction record", "individual"),
}
TASTE = ("engineering-taste", "product-taste", "domain")
PROMOTABLE = ("mechanical", "engineering-taste", "product-taste")
APPROVALS = re.compile(r"^\s*(approve|approved|clear|cleared|pass|passed|yes|ok|accept|accepted)\b", re.I)
# Where prose lessons live; a check is never only a line in one of these.
PROSE_HOMES = r"^(CODING_STANDARDS\.md|PRODUCT_STANDARDS\.md|GLOSSARY\.md|docs/adr/)"
ROLES = ("product", "engineering", "both")
SCOPES = ("this-project", "generalises")
FOCUSES = ("problem", "solution", "pipeline", "chore")
# A decision with no job names one by its kind.
KIND_JOB = {"exception": 15, "design": 3, "risk-gate": 13, "gate": 13, "halted": 15, "conflict": 15}
GATE_KINDS = ("gate", "risk-gate", "slice", "end", "exception-gate")


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        if default is not None:
            return default
        raise


def lines(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def job_focuses(jobs_md):
    """Job number -> focus, read from the inventory table in jobs.md."""
    table = {}
    with open(jobs_md) as f:
        for line in f:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) == 5 and cells[0].isdigit():
                focus = cells[4].split("/")[0].strip().lower()
                if focus in FOCUSES:
                    table[int(cells[0])] = focus
    return table


def num(x):
    """A number rounded to two places, whole when it is whole."""
    x = round(float(x), 2)
    return int(x) if x == int(x) else x


def is_agent(by):
    by = (by or "").lower()
    return by in ("", "agent") or by.startswith(("orchestrator", "worker", "verifier", "agent"))


def action_focus(a, jobs):
    if a.get("focus") in FOCUSES:
        return a["focus"]
    job = a.get("job")
    if job is None:
        job = KIND_JOB.get(a.get("kind"))
    try:
        return jobs.get(int(job), "chore")
    except (TypeError, ValueError):
        return "chore"  # names no job, so serves no focus


# A gate the Artisan decides is opened by gate-opened and closed by the first
# of these with its gate id (end-gate-approved without one closes "end").
GATE_CLOSERS = ("gate-approved", "gate-decided", "gate-redirected", "gate-bypassed", "gate-deferred",
                "gate-resolved", "gate-empty", "end-gate-approved")
# What ends a local merge gate: its merge, its block, or the next gate.
LOCAL_GATE_ENDS = ("merge", "failed", "blocked", "merge-gate", "merge-gate-abandoned", "merge-batch-ended")


def concerns(e, g):
    """Whether event e is about the same ticket or merge batch as gate g."""
    if g.get("ticket") is not None:
        return e.get("ticket") == g["ticket"]
    if g.get("batch") is not None:
        return e.get("batch") == g["batch"] or e.get("ticket") in (g.get("tickets") or [])
    return False


def per(x, n):
    return num(float(x) / n) if n else None


def merge_gate_costs(s, merged):
    """What the run's merge gates cost, from its events (references/state-file.md).
    Every figure is None for a run with no merge-gate or ci-wait event: no gate,
    or a state file from before #142 and #195 recorded them."""
    events = s.get("events") or []
    starts = [(i, e) for i, e in enumerate(events) if e.get("event") == "merge-gate"]
    waits = [e for e in events if e.get("event") == "ci-wait"]
    if not starts and not waits:
        return {"run": None, "run_per_merged": None, "minutes": None, "minutes_per_merged": None,
                "red": {"total": None, "own": None, "base": None, "flaky": None, "no_verdict": None},
                "not_run": {"skipped": None, "reused": None}}
    skipped = len([e for e in events if e.get("event") == "merge-gate-skipped"])
    # A gate #194 reuses records green with reused: <run id> on the suite
    # record; flaky (#195) is on the suite record of the gate that merged.
    suites = [t.get("suite") for t in (s.get("tickets") or {}).values() if isinstance(t.get("suite"), dict)]
    def distinct(rows):
        return len(set(json.dumps([r.get("run_id"), r.get("sha"), r.get("batch")]) for r in rows))
    reused = distinct([r for r in suites if r.get("reused")])
    flaky = distinct([r for r in suites if (r.get("base_check") or {}).get("verdict") == "flaky"])

    minutes = sum(float(e.get("minutes") or 0) for e in waits)
    local_red = 0
    for i, g in starts:
        if g.get("mode") != "local":
            continue
        end = next((e for e in events[i + 1:] if e.get("event") in LOCAL_GATE_ENDS and concerns(e, g)), None)
        if end is None or "at" not in end or "at" not in g:
            continue
        minutes += max(0, end["at"] - g["at"]) / 60.0
        if end.get("event") in ("failed", "blocked"):
            local_red += 1
    base = len([e for e in events if e.get("event") == "parked" and e.get("reason") == "base"])
    ci_red = len([e for e in waits if e.get("outcome") == "red"])
    no_verdict = len([e for e in waits if e.get("outcome") == "no-verdict"])
    own = max(0, ci_red - base) + local_red
    run = len(starts) - skipped
    return {"run": run, "run_per_merged": per(run, merged),
            "minutes": num(minutes), "minutes_per_merged": per(minutes, merged),
            "red": {"total": own + base + flaky + no_verdict, "own": own, "base": base,
                    "flaky": flaky, "no_verdict": no_verdict},
            "not_run": {"skipped": skipped, "reused": reused}}


def artisan_wait(s):
    """Minutes gates waited on the Artisan: gate-opened to the event that
    closed it. None when the run opened no gate that was decided."""
    events = s.get("events") or []
    waits = []
    for i, o in enumerate(events):
        if o.get("event") != "gate-opened" or "at" not in o:
            continue
        for e in events[i + 1:]:
            if e.get("event") in GATE_CLOSERS and e.get("gate", "end") == o.get("gate") and "at" in e:
                waits.append(max(0, e["at"] - o["at"]) / 60.0)
                break
    if not waits:
        return {"decisions": 0, "minutes": None, "longest_minutes": None}
    return {"decisions": len(waits), "minutes": num(sum(waits)), "longest_minutes": num(max(waits))}


def facts(state_path, jobs_md, actions_path=None, misses_path=None):
    s = load(state_path)
    jobs = job_focuses(jobs_md)
    plan = s.get("plan") or {}
    tickets = s.get("tickets") or {}
    events = s.get("events") or []
    by_status = {}
    for t in tickets.values():
        by_status[t.get("status")] = by_status.get(t.get("status"), 0) + 1
    merged = [n for n, t in tickets.items() if t.get("status") == "merged"]

    starts = [e["at"] for e in events if e.get("event") == "dispatch" and "at" in e]
    starts += [t["dispatched_at"] for t in tickets.values() if t.get("dispatched_at")]
    ends = [e["at"] for e in events if e.get("event") == "merge" and "at" in e]
    hours = None
    if starts and ends and max(ends) > min(starts):
        hours = num((max(ends) - min(starts)) / 3600.0)

    costs = s.get("costs") or {}
    total = costs.get("total_usd")
    if total is None:
        total = sum(float(t.get("cost_usd") or 0) for t in tickets.values()) + float(costs.get("orchestrator_usd") or 0)
    per_ticket = []
    for n, t in sorted(tickets.items(), key=lambda kv: kv[0]):
        est = ((plan.get("tickets") or {}).get(n) or {}).get("estimate_usd")
        act = t.get("cost_usd")
        row = {"ticket": n, "status": t.get("status"), "estimate_usd": est, "cost_usd": act,
               "attempts": t.get("attempts", 0)}
        if est and act is not None:
            row["ratio"] = num(float(act) / float(est))
        per_ticket.append(row)

    # The Artisan's actions: decisions a person made, triage reversals, and
    # what the preparer found in the chat log.
    actions = []
    for d in s.get("decisions") or []:
        if d.get("status") == "decided" and not is_agent(d.get("by")):
            actions.append({"what": d.get("kind", "decision"), "source": "decision", "kind": d.get("kind"),
                            "job": d.get("job"), "focus": d.get("focus"), "redirect": d.get("redirect"),
                            "choice": d.get("choice")})
    misses = [m for m in (lines(misses_path) if misses_path else [])]
    for m in misses:
        actions.append({"what": "reversed a triage recommendation", "source": "triage-miss", "job": 18})
    if actions_path:
        for a in lines(actions_path):
            a.setdefault("source", "chat")
            actions.append(a)
    counts = dict((f, 0) for f in FOCUSES)
    for a in actions:
        a["focus"] = action_focus(a, jobs)
        counts[a["focus"]] += 1
    n = len(actions)
    shares = dict((f, (round(100.0 * c / n) if n else None)) for f, c in counts.items())

    gates = [a for a in actions if a.get("kind") in GATE_KINDS or a.get("job") == 13 or a.get("gate")]
    stamped = [g for g in gates if not g.get("redirect") and not g.get("changed")
               and APPROVALS.match(str(g.get("choice") or ""))]
    rubber = {"gates": len(gates), "unchanged": len(stamped),
              "rate": (round(100.0 * len(stamped) / len(gates)) if gates else None)}

    return {
        "run_id": s.get("run_id"), "repo": s.get("repo"),
        "tickets": len(plan.get("scope") or tickets), "by_status": by_status,
        "merged": len(merged), "hours": hours,
        "throughput_per_hour": (num(len(merged) / hours) if hours else None),
        "cost_usd": round(float(total), 2),
        "estimate_usd": plan.get("estimate_usd"), "budget_usd": plan.get("budget_usd"),
        "cost_per_merged_usd": (num(float(total) / len(merged)) if merged else None),
        "per_ticket": per_ticket,
        "failed_attempts": sum(len(t.get("failures") or []) for t in tickets.values()),
        "findings": len(s.get("findings") or []),
        "decisions_waiting": len([d for d in s.get("decisions") or [] if d.get("status") == "waiting"]),
        "slicing_lessons": len(s.get("lessons") or []),
        "triage_misses": len(misses),
        "actions": {"total": n, "counts": counts, "shares_percent": shares},
        "rubber_stamp": rubber,
        "merge_gates": merge_gate_costs(s, len(merged)),
        "artisan_wait": artisan_wait(s),
    }


def check(lessons_path, threshold):
    doc = load(lessons_path)
    problems, out, seen = [], [], set()
    lessons = doc.get("lessons")
    if not isinstance(lessons, list):
        print("lessons: missing or not a list", file=sys.stdout)
        return 1
    for i, l in enumerate(lessons):
        lid = str(l.get("id") or "L%d" % (i + 1))
        where = "lesson %s" % lid
        if lid in seen:
            problems.append("%s: duplicate id" % where)
        seen.add(lid)
        l["id"] = lid
        text = (l.get("lesson") or "").strip()
        if not text or "\n" in text:
            problems.append("%s: needs a one-line 'lesson'" % where)
        kind = l.get("kind")
        if kind not in HOMES:
            problems.append("%s: kind must be one of %s" % (where, ", ".join(HOMES)))
            continue
        if l.get("role") not in ROLES:
            problems.append("%s: role must be product, engineering or both" % where)
        if l.get("scope") not in SCOPES:
            problems.append("%s: scope must be this-project or generalises" % where)
        if not (l.get("why") or "").strip():
            problems.append("%s: needs 'why' (the evidence from the run)" % where)
        # A taste lesson a machine can check becomes a check.
        if l.get("checkable") and kind in TASTE:
            l["rehomed_from"] = kind
            kind = l["kind"] = "mechanical"
        l["home"], l["delivery"] = HOMES[kind]
        ch = l.get("change") or {}
        if kind == "calibration":
            if not (ch.get("key") and "value" in ch):
                problems.append("%s: a calibration lesson needs change.key and change.value" % where)
        elif l["delivery"] == "project":
            if not (ch.get("path") and (ch.get("text") or "").strip()):
                problems.append("%s: needs change.path and change.text for %s" % (where, l["home"]))
            elif os.path.isabs(ch["path"]) or ".." in ch["path"].split("/"):
                problems.append("%s: change.path must be inside the repo" % where)
            elif kind == "mechanical" and re.match(PROSE_HOMES, ch["path"]):
                problems.append("%s: a check's change must be the check itself (a test, lint rule, hook or CI job), not %s"
                                % (where, ch["path"]))
        if kind == "pipeline":
            t = l.get("ticket") or {}
            t.setdefault("title", text)
            t.setdefault("body", l.get("why", ""))
            l["ticket"] = t
        # Only judgement calls are questions.
        reasons = []
        # Taste and checks are promoted to the individual level; pipeline lessons
        # generalise as tickets; domain and calibration stay with the project.
        l["promotable"] = l.get("scope") == "generalises" and kind in PROMOTABLE
        if l["promotable"]:
            reasons.append("does it generalise beyond this project?")
        if l.get("move") in ("loosen", "tighten", "retire"):
            reasons.append("%s a guardrail" % l["move"])
        if kind == "calibration" and len(l.get("evidence") or []) < threshold:
            reasons.append("calibration on thin evidence (%d of %d events)" % (len(l.get("evidence") or []), threshold))
        if l.get("ask") == "question" and not reasons:
            reasons.append("the preparer judged it a judgement call")
        if l.get("source") == "artisan":
            reasons = []  # the Artisan's own words: kept as said
        l["ask"] = "question" if reasons else "batch"
        l["judgement"] = reasons
        if reasons and not (l.get("question") or "").strip():
            l["question"] = "Keep this lesson (%s)?" % "; ".join(reasons)
        out.append(l)
    if problems:
        print("\n".join(problems))
        return 1
    doc["lessons"] = out
    doc["smooth"] = not out
    print(json.dumps(doc, indent=2))
    return 0


def money(x):
    return "n/a" if x is None else "$%.2f" % float(x)


def signals_table(f):
    a = f["actions"]
    if a["total"]:
        sh = a["shares_percent"]
        focus = "problem %s%% · solution %s%% · pipeline %s%% · chores %s%% (%d actions)" % (
            sh["problem"], sh["solution"], sh["pipeline"], sh["chore"], a["total"])
    else:
        focus = "no actions recorded"
    r = f["rubber_stamp"]
    rubber = ("%d of %d gate decisions approved unchanged (%d%%)" % (r["unchanged"], r["gates"], r["rate"])
              if r["gates"] else "no gate decisions this run")
    tp = ("%d merged in %s h (%s per hour)" % (f["merged"], f["hours"], f["throughput_per_hour"])
          if f["hours"] else "%d merged" % f["merged"])
    cost = "%s per merged ticket (run %s against an estimate of %s)" % (
        money(f["cost_per_merged_usd"]), money(f["cost_usd"]), money(f["estimate_usd"]))
    rows = [("Focus shares", focus), ("Rubber-stamp rate at gates", rubber),
            ("Throughput", tp), ("Cost per merged ticket", cost)]
    return "| Signal | This run |\n|---|---|\n" + "\n".join("| %s | %s |" % r for r in rows)


def dash(x):
    return "-" if x is None else str(x)


def gate_costs_table(g, w):
    """The merge gates' costs and the waits on the Artisan as a Markdown table;
    a figure the run can't have is a dash."""
    if g["run"] is None:
        run = wait = red = not_run = "-"
    else:
        run = "%s (%s per merged ticket)" % (g["run"], dash(g["run_per_merged"]))
        wait = "%s min (%s per merged ticket)" % (g["minutes"], dash(g["minutes_per_merged"]))
        r = g["red"]
        red = "%s: own failure %s · red base %s · flaky %s · no verdict %s" % (
            r["total"], r["own"], r["base"], r["flaky"], r["no_verdict"])
        not_run = "skipped %s · reused %s" % (g["not_run"]["skipped"], g["not_run"]["reused"])
    artisan = ("%s min over %d decisions (longest %s min)" % (w["minutes"], w["decisions"], w["longest_minutes"])
               if w["minutes"] is not None else "-")
    rows = [("Merge gates run", run), ("Waiting on merge gates", wait), ("Red gates by cause", red),
            ("Gates not run", not_run), ("Waiting on the Artisan", artisan)]
    return "| Merge gates | This run |\n|---|---|\n" + "\n".join("| %s | %s |" % r for r in rows)


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def render(checked_path, facts_path, questions_path, motivation_path=None):
    doc = load(checked_path)
    f = load(facts_path)
    qs = load(questions_path)
    lessons = doc.get("lessons") or []
    out = ["## Retro: run %s" % f.get("run_id"), ""]
    if doc.get("summary"):
        out += [doc["summary"].strip(), ""]
    if not lessons:
        out += ["**Nothing to learn from this run.** It ran smoothly: no redirects, bypasses, failed "
                "attempts or misses worth a lesson.", ""]
    batch = [l for l in lessons if l["ask"] == "batch"]
    asks = [l for l in lessons if l["ask"] == "question"]
    if batch:
        out += ["### Lessons to keep: one \"yes\" keeps them all", "",
                "| # | Lesson | Home | Role | Reach | Why |", "|---|---|---|---|---|---|"]
        for l in batch:
            home = l["home"] + (" (taste a machine can check: was %s)" % l["rehomed_from"].replace("-", " ") if l.get("rehomed_from") else "")
            out.append("| %s | %s | %s | %s | %s | %s |" % (l["id"], cell(l["lesson"]), cell(home), l["role"],
                                                       l["scope"], cell(l["why"])))
        out += ["", "Recommend: yes to all. Say which to drop, if any.", ""]
    if asks:
        out += ["### Judgement calls", ""]
        for i, l in enumerate(asks, 1):
            out.append("%d. **%s** %s" % (i, l["id"], l["question"]))
            out.append("   Lesson: %s. Home: %s. Role: %s. Reach: %s." % (l["lesson"].rstrip("."), l["home"], l["role"], l["scope"]))
            if l.get("recommendation"):
                out.append("   Recommend: %s" % l["recommendation"])
            out.append("   Why: %s" % l["why"])
            if l.get("alternative"):
                out.append("   Strongest alternative: %s" % l["alternative"])
        out.append("")
    out += ["### Signals", "", signals_table(f), ""]
    if "merge_gates" in f:  # facts from before #199 have none
        out += [gate_costs_table(f["merge_gates"], f["artisan_wait"]), ""]
    out += ["### How did this run feel?", ""]
    if motivation_path and os.path.isfile(motivation_path):
        with open(motivation_path) as fh:
            body = fh.read().splitlines()
        # The Artisan's words follow the header block that ends with "Private:".
        at = next((i for i, ln in enumerate(body) if ln.startswith("Private:")), None)
        text = "\n".join(body[at + 1:] if at is not None else body).strip()
        out += ["Why this product matters to you, as you put it:", ""]
        out += ["> " + ln for ln in text.splitlines()]
        out += ["", "Read the first two scores against that.", ""]
    for i, q in enumerate(qs, 1):
        hint = "free text" if i == len(qs) else "1–5, an optional sentence, or \"skip\""
        out.append("%d. %s (%s)" % (i, q, hint))
    print("\n".join(out))
    return 0


def questions(paths):
    for p in paths:
        try:
            with open(p) as fh:
                text = fh.read()
        except OSError:
            continue
        m = re.search(r"^## Retro questions\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
        if not m:
            continue
        qs = [re.sub(r"\s*\(free text\)\s*$", "", q.strip()) for q in re.findall(r"^\d+\.\s+(.+)$", m.group(1), re.M)]
        if len(qs) >= 4:
            print(json.dumps(qs[:4]))
            return 0
    print("no '## Retro questions' with four questions in: %s" % " ".join(paths), file=sys.stderr)
    return 1


SCORED = ("problem", "solution", "pipeline")


def score_of(v):
    if isinstance(v, dict):
        v = v.get("score")
    if isinstance(v, str) and v.strip().lower() == "skip":
        return "skip"
    try:
        n = int(v)
    except (TypeError, ValueError):
        return None
    return n if 1 <= n <= 5 else None


def record(answers_path, facts_path, history_path, project, run, date):
    a = load(answers_path)
    f = load(facts_path)
    scores, comments = {}, {}
    for q in SCORED:
        v = a.get(q)
        s = score_of(v)
        if s is None:
            print("answers: %s needs a score 1-5 or \"skip\"" % q, file=sys.stderr)
            return 1
        scores[q] = s
        c = (v.get("comment") if isinstance(v, dict) else "") or ""
        if c.strip():
            comments[q] = c.strip()
    raw = a.get("chores") or ""
    chores = raw if isinstance(raw, list) else re.split(r"[;\n]+", raw)
    chores = [c.strip() for c in chores if c and c.strip() and c.strip().lower() not in ("none", "no", "nothing", "skip")]
    rec = {"type": "answers", "date": date, "project": project, "run": run,
           "scores": scores, "comments": comments, "chores": chores, "facts": f}

    past = [h for h in lines(history_path) if h.get("type", "answers") == "answers" and h.get("project") == project
            and h.get("run") != run]
    why = []
    for q in SCORED:
        s = scores[q]
        if s == "skip":
            continue
        if s <= 2:
            why.append({"question": q, "reason": "scored %d" % s})
            continue
        # A fall of 1 or more over three runs: this run against the one two before it
        # (a skip there means no comparison).
        first = score_of((past[-2].get("scores") or {}).get(q)) if len(past) >= 2 else None
        if isinstance(first, int) and first - s >= 1:
            why.append({"question": q, "reason": "fell from %d to %d over three runs" % (first, s)})
    print(json.dumps(rec, separators=(",", ":")))
    print(json.dumps({"why": why, "chores": chores}))
    return 0


def under_section(text, section, line):
    """TEXT with LINE added at the end of SECTION (a markdown heading), the
    section added at the end if missing. Unchanged if LINE is already there."""
    ls = text.splitlines()
    if line.strip() in [l.strip() for l in ls]:
        return text
    if not section:
        return "\n".join(ls + [line]) + "\n"
    heads = [l.strip() for l in ls]
    if section.strip() not in heads:
        while ls and not ls[-1].strip():
            ls.pop()
        return "\n".join(ls + ([""] if ls else []) + [section.strip(), "", line]) + "\n"
    start = heads.index(section.strip())
    level = len(section.strip()) - len(section.strip().lstrip("#"))
    end = len(ls)
    for i in range(start + 1, len(ls)):
        m = re.match(r"^(#+)\s", ls[i])
        if m and len(m.group(1)) <= level:
            end = i
            break
    j = end
    while j > start + 1 and not ls[j - 1].strip():
        j -= 1
    ls[j:j] = [line]
    return "\n".join(ls) + "\n"


def yaml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def config_set(path, key, value):
    """Set KEY (one level of nesting at most) in a plain YAML config, keeping
    every other line and comment."""
    parts = key.split(".")
    if len(parts) > 2:
        raise ValueError("config keys nest one level at most: %s" % key)
    try:
        with open(path) as fh:
            ls = fh.read().splitlines()
    except OSError:
        ls = []
    val = yaml_scalar(value)
    top = parts[0]
    idx = next((i for i, l in enumerate(ls) if re.match(r"^%s:(\s|$)" % re.escape(top), l)), None)
    if len(parts) == 1:
        line = "%s: %s" % (top, val)
        if idx is None:
            ls.append(line)
        else:
            ls[idx] = line
    else:
        child = parts[1]
        line = "  %s: %s" % (child, val)
        if idx is None:
            ls += ["%s:" % top, line]
        else:
            rest = ls[idx].split(":", 1)[1].split("#")[0].strip()
            if rest in ("{}", ""):
                ls[idx] = "%s:" % top
                end = idx + 1
                while end < len(ls) and (ls[end].startswith(" ") or not ls[end].strip()):
                    if re.match(r"^\s+%s:(\s|$)" % re.escape(child), ls[end]):
                        ls[end] = line
                        break
                    end += 1
                else:
                    ls.insert(idx + 1, line)
            else:
                raise ValueError("%s is not a map in %s" % (top, path))
    with open(path, "w") as fh:
        fh.write("\n".join(ls) + "\n")


def apply(worktree, lesson_path):
    l = load(lesson_path)
    ch = l.get("change") or {}
    if l.get("kind") == "calibration":
        config_set(os.path.join(worktree, ".artisan-agent", "config.yml"), ch["key"], ch["value"])
        print(".artisan-agent/config.yml")
        return 0
    path = os.path.join(worktree, ch["path"])
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    text = ""
    if os.path.isfile(path):
        with open(path) as fh:
            text = fh.read()
    if ch.get("replace"):
        new = ch["text"].rstrip("\n") + "\n"
    else:
        new = under_section(text, ch.get("section"), ch["text"].rstrip("\n"))
    with open(path, "w") as fh:
        fh.write(new)
    print(ch["path"])
    return 0


def promote(path, section, line):
    text = ""
    if os.path.isfile(path):
        with open(path) as fh:
            text = fh.read()
    with open(path, "w") as fh:
        fh.write(under_section(text, section, line))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "facts" and 2 <= len(args) <= 4:
        print(json.dumps(facts(*(args + [None] * (4 - len(args)))), indent=2))
        return 0
    if cmd == "check" and len(args) == 2:
        return check(args[0], int(args[1]))
    if cmd == "render" and len(args) in (3, 4):
        return render(*args)
    if cmd == "questions" and args:
        return questions(args)
    if cmd == "record" and len(args) == 6:
        return record(*args)
    if cmd == "apply" and len(args) == 2:
        return apply(*args)
    if cmd == "promote" and len(args) == 3:
        return promote(*args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
