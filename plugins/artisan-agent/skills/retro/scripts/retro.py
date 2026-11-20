"""The retro's computations: the run's facts and signals, the lesson check,
the chat round, the satisfaction record and its triggers, and the edits a
kept lesson makes. retro.sh calls it; nothing here touches git or the tracker.

Usage (python3 -I retro.py <command> ...):
  facts <state.json> <jobs.md> [<actions.jsonl>] [<misses.jsonl>] [<satisfaction.jsonl>] [<denied.json>]
      the run's facts and signals as JSON; the leverage trend reads earlier
      runs' facts from the satisfaction record; a non-empty denied.json (the
      tools the preparer was denied) marks the focus shares incomplete
  chat-turns <chat log>
      the turns the Artisan typed in a Claude Code transcript, as Markdown
      (one "### Turn" heading each); a log that is not a transcript is kept as it is
  gate-costs <state.json>
      what the merge gates cost and how long gates waited on the Artisan,
      as the Markdown table the retro's Signals show (the run summary's)
  check <lessons.json> <threshold> [individual=<voice file>] [product=<voice file>]
      the preparer's lessons, checked and normalised: each gets its home,
      and judgement calls become questions. A voice lesson is checked against
      the voice file at its level, when given, for the cap. Exit 1 with one
      line per problem
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
      file (the file and section made if missing), or a config number set;
      a voice lesson's rule goes at the end of the Artisan's own section of
      the checkout's VOICE_STANDARDS.md (the individual home is a checkout too)
  voice-line <lesson.json>
      the rule line a voice lesson adds (a team lesson's drafted line)
  voice-levels <checked.json>
      the checked lessons with each voice lesson's home and delivery set
      again from its level (after the Artisan picks another level)
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
    "voice": ("voice standards (VOICE_STANDARDS.md)", "by level"),
}
# A voice lesson's level -> (home as shown, where it is delivered). The
# default level follows who reads the text (ADR 0003): chat only the Artisan
# reads is individual; shared text, and a reader left unclear, is product.
VOICE_LEVELS = {
    "individual": ("voice standards, individual level (VOICE_STANDARDS.md in the individual home)", "individual"),
    "product": ("voice standards, product level (VOICE_STANDARDS.md in the project)", "project"),
    "team": ("voice standards, team level (a drafted line for the team guardrails repo)", "team"),
}
VOICE_READERS = {"chat": "individual", "shared": "product"}
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


def median(xs):
    if not xs:
        return None
    xs = sorted(xs)
    mid = len(xs) // 2
    return num(xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2.0)


def gate_limit(s, costs):
    """The run's median merge-gate minutes against merge_gate_minutes_limit
    (#200), from the plan's config (config.sh fills the default from
    templates/config.yml): the limit, and whether the median is over it. None
    when the run has no gate minutes, or its plan has no limit (a plan from
    before #200). Says so; never blocks anything."""
    limit = ((s.get("plan") or {}).get("config") or {}).get("merge_gate_minutes_limit")
    if not isinstance(limit, (int, float)) or isinstance(limit, bool):
        limit = None
    med = costs.get("median_minutes")
    over = None if med is None or limit is None else med > float(limit)
    return dict(costs, limit_minutes=limit, over_limit=over)


def merge_gate_costs(s, merged):
    """What the run's merge gates cost, from its events (references/state-file.md).
    Every figure is None for a run with no merge-gate or ci-wait event: no gate,
    or a state file from before #142 and #195 recorded them."""
    events = s.get("events") or []
    starts = [(i, e) for i, e in enumerate(events) if e.get("event") == "merge-gate"]
    waits = [e for e in events if e.get("event") == "ci-wait"]
    if not starts and not waits:
        return {"run": None, "run_per_merged": None, "minutes": None, "minutes_per_merged": None,
                "median_minutes": None,
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
    # Each gate that ran, for the median: a gate skipped (#168) or reused
    # (#194) logs a ci-wait with its sha but ran nothing.
    not_ran = set(e.get("sha") for e in events
                  if e.get("event") in ("merge-gate-skipped", "merge-gate-reused") and e.get("sha"))
    each = [float(e.get("minutes") or 0) for e in waits if not (e.get("sha") and e.get("sha") in not_ran)]
    local_red = 0
    for i, g in starts:
        if g.get("mode") != "local":
            continue
        end = next((e for e in events[i + 1:] if e.get("event") in LOCAL_GATE_ENDS and concerns(e, g)), None)
        if end is None or "at" not in end or "at" not in g:
            continue
        minutes += max(0, end["at"] - g["at"]) / 60.0
        each.append(max(0, end["at"] - g["at"]) / 60.0)
        if end.get("event") in ("failed", "blocked"):
            local_red += 1
    base = len([e for e in events if e.get("event") == "parked" and e.get("reason") == "base"])
    ci_red = len([e for e in waits if e.get("outcome") == "red"])
    no_verdict = len([e for e in waits if e.get("outcome") == "no-verdict"])
    own = max(0, ci_red - base) + local_red
    run = len(starts) - skipped
    if not waits and any(g.get("mode") != "local" for _, g in starts):
        # CI gates from before #195 logged no ci-wait: their minutes and red
        # causes are unknown, not zero.
        return {"run": run, "run_per_merged": per(run, merged), "minutes": None, "minutes_per_merged": None,
                "median_minutes": None, "red": {"total": None, "own": None, "base": None, "flaky": None, "no_verdict": None},
                "not_run": {"skipped": skipped, "reused": reused}}
    return {"run": run, "run_per_merged": per(run, merged),
            "minutes": num(minutes), "minutes_per_merged": per(minutes, merged),
            "median_minutes": median(each), "red": {"total": own + base + flaky + no_verdict, "own": own, "base": base,
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


def rulings(s):
    """The Decision chat's rulings on open decisions: one per "ruled" event
    questions.sh sync logged (references/state-file.md)."""
    return [e for e in s.get("events") or [] if e.get("event") == "ruled"]


def open_decision_wait(s):
    """Minutes open decisions waited on the Artisan: each question from its
    filing (the first "guardrail-fired" open-decision or "asked" event naming
    it, else its record on the ticket) to its first ruling. None when the run
    has no ruling it can time."""
    events = s.get("events") or []
    filed = {}
    for e in events:
        if "at" in e and e.get("question") is not None and (
                e.get("event") == "asked"
                or (e.get("event") == "guardrail-fired" and e.get("guardrail") == "open-decision")):
            key = (str(e.get("ticket")), str(e["question"]))
            filed[key] = min(filed.get(key, e["at"]), e["at"])
    for n, t in (s.get("tickets") or {}).items():
        for q in t.get("questions") or []:
            if isinstance(q.get("at"), (int, float)) and q.get("ticket") is not None:
                filed.setdefault((str(n), str(q["ticket"])), q["at"])
    waits, seen = [], set()
    for e in rulings(s):
        key = (str(e.get("ticket")), str(e.get("question")))
        if key in seen or key not in filed or "at" not in e:
            continue
        seen.add(key)
        waits.append(max(0, e["at"] - filed[key]) / 60.0)
    if not waits:
        return {"rulings": 0, "minutes": None, "longest_minutes": None}
    return {"rulings": len(waits), "minutes": num(sum(waits)), "longest_minutes": num(max(waits))}


# The leverage trend: this run and the most recent earlier ones.
TREND_RUNS = 5


def earlier_leverage(f):
    """An earlier run's leverage from its facts in the satisfaction record:
    (decisions, changed). Facts from before #234 have gate decisions only."""
    l = f.get("leverage")
    if isinstance(l, dict) and isinstance(l.get("decisions"), int):
        return l["decisions"], int(l.get("changed") or 0)
    r = f.get("rubber_stamp")
    if isinstance(r, dict) and isinstance(r.get("gates"), int):
        return r["gates"], r["gates"] - int(r.get("unchanged") or 0)
    return None


def leverage_trend(history_path, project, run, leverage):
    """The leverage line over this run and the earlier runs of the same
    project in the satisfaction record, oldest first, with the share over all
    of them pooled so one odd run doesn't move the line."""
    rows = []
    for h in lines(history_path) if history_path else []:
        if h.get("type", "answers") != "answers" or h.get("project") != project or h.get("run") == run:
            continue
        got = earlier_leverage(h.get("facts") or {})
        if got:
            rows.append({"run": h.get("run"), "decisions": got[0], "changed": got[1]})
    rows = rows[-(TREND_RUNS - 1):] + [{"run": run, "decisions": leverage["decisions"], "changed": leverage["changed"]}]
    for r in rows:
        r["rate"] = round(100.0 * r["changed"] / r["decisions"]) if r["decisions"] else None
    decisions = sum(r["decisions"] for r in rows)
    changed = sum(r["changed"] for r in rows)
    return {"runs": rows, "rate": (round(100.0 * changed / decisions) if decisions else None)}


def facts(state_path, jobs_md, actions_path=None, misses_path=None, history_path=None, denied_path=None):
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
    # Each ruling on an open decision is one, resolving an open design question.
    for r in rulings(s):
        actions.append({"what": "ruled on an open decision", "source": "ruling", "kind": "ruling",
                        "job": 3, "ruling": r.get("ruling"), "question": r.get("question"),
                        "took_recommendation": r.get("took_recommendation")})
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
    # A preparer denied a tool may have missed the chat's actions: its shares
    # are not measured ones (#245).
    denied = load(denied_path, []) if denied_path else []

    gates = [a for a in actions if a.get("kind") in GATE_KINDS or a.get("job") == 13 or a.get("gate")]
    stamped = [g for g in gates if not g.get("redirect") and not g.get("changed")
               and APPROVALS.match(str(g.get("choice") or ""))]
    # A ruling that took the raiser's recommendation is a rubber stamp; one
    # that changed it changed the outcome. One with no verdict is neither.
    ruled = [a for a in actions if a.get("source") == "ruling" and isinstance(a.get("took_recommendation"), bool)]
    took = [a for a in ruled if a["took_recommendation"]]
    decided = len(gates) + len(ruled)
    unchanged = len(stamped) + len(took)
    rubber = {"gates": len(gates), "rulings": len(ruled), "unchanged": unchanged, "decisions": decided,
              "rate": (round(100.0 * unchanged / decided) if decided else None)}
    leverage = {"decisions": decided, "changed": decided - unchanged,
                "rate": (round(100.0 * (decided - unchanged) / decided) if decided else None),
                "gates_changed": len(gates) - len(stamped), "rulings_changed": len(ruled) - len(took),
                "rulings_unknown": len([a for a in actions if a.get("source") == "ruling"]) - len(ruled)}

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
        "actions": {"total": n, "counts": counts, "shares_percent": shares,
                    "incomplete": bool(denied), "denied": denied},
        "rubber_stamp": rubber,
        "leverage": dict(leverage, trend=leverage_trend(history_path, s.get("repo") or "unknown", s.get("run_id"), leverage)),
        "merge_gates": gate_limit(s, merge_gate_costs(s, len(merged))),
        "artisan_wait": artisan_wait(s),
        "open_decision_wait": open_decision_wait(s),
    }


def check(lessons_path, threshold, voice_files=None):
    doc = load(lessons_path)
    # The voice files as they stand, by level; each kept-by-default voice
    # lesson is applied in turn, so the cap counts every lesson before it.
    voice = {}
    for level, path in (voice_files or {}).items():
        if os.path.isfile(path):
            with open(path) as fh:
                voice[level] = fh.read()
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
        if kind == "voice":
            problems += voice_lesson(l, where)
            problem = voice_mode_problem(l)
            if not problem and l.get("level") in voice:
                voice[l["level"]], problem = voice_edit(voice[l["level"]], l)
            if problem:
                problems.append("%s: %s" % (where, problem))
        elif kind == "calibration":
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


def voice_lesson(l, where):
    """Gives a voice lesson its level, home and delivery; returns its problems."""
    reader, level = l.get("reader"), l.get("level")
    if reader is not None and reader not in VOICE_READERS:
        return ["%s: reader must be chat or shared" % where]
    if level is not None and level not in VOICE_LEVELS:
        return ["%s: level must be individual, product or team" % where]
    l["level"] = level or VOICE_READERS.get(reader, "product")
    l["home"], l["delivery"] = VOICE_LEVELS[l["level"]]
    return []


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
    if a.get("incomplete"):
        focus = "incomplete: the preparer was denied %s, so actions from the chat log may be missing (counted so far: %s)" % (
            ", ".join(a.get("denied") or []), focus)
    r = f["rubber_stamp"]
    decisions = r.get("decisions", r["gates"])  # facts from before #234 count gates only
    if not decisions:
        rubber = lev = "no gate decisions or rulings this run"
    else:
        l = f.get("leverage") or {"gates_changed": r["gates"] - r["unchanged"], "rulings_changed": 0}
        rulings = r.get("rulings", 0)
        rubber = ("%d of %d decisions unchanged (%d%%): %d of %d gate decisions approved unchanged, "
                  "%d of %d rulings took the recommendation" % (
                      r["unchanged"], decisions, r["rate"], r["gates"] - l["gates_changed"], r["gates"],
                      rulings - l["rulings_changed"], rulings))
        lev = leverage_cell(f)
    tp = ("%d merged in %s h (%s per hour)" % (f["merged"], f["hours"], f["throughput_per_hour"])
          if f["hours"] else "%d merged" % f["merged"])
    cost = "%s per merged ticket (run %s against an estimate of %s)" % (
        money(f["cost_per_merged_usd"]), money(f["cost_usd"]), money(f["estimate_usd"]))
    rows = [("Focus shares", focus), ("Rubber-stamp rate", rubber), ("Leverage", lev),
            ("Throughput", tp), ("Waited on the Artisan", waited_cell(f)), ("Cost per merged ticket", cost)]
    return "| Signal | This run |\n|---|---|\n" + "\n".join("| %s | %s |" % r for r in rows)


def leverage_cell(f):
    """The leverage line: the share of the Artisan's decisions that changed
    the outcome, and its trend over earlier runs when the record has any."""
    l = f.get("leverage")
    if not l:
        return "-"
    out = "%d%% of %d decisions changed the outcome (gates %d · rulings %d" % (
        l["rate"], l["decisions"], l["gates_changed"], l["rulings_changed"])
    if l["rulings_unknown"]:
        out += "; %d ruling%s with no verdict not counted" % (l["rulings_unknown"], "" if l["rulings_unknown"] == 1 else "s")
    out += ")"
    t = l.get("trend")
    if t and len(t["runs"]) > 1 and t["rate"] is not None:
        out += " · trend %d%% over %d runs (%s)" % (t["rate"], len(t["runs"]), " → ".join(
            "-" if x["rate"] is None else "%d%%" % x["rate"] for x in t["runs"]))
    return out


def waited_cell(f):
    """How long gates and open decisions waited on the Artisan, each on its
    own; a dash when neither did."""
    g = f.get("artisan_wait") or {}
    o = f.get("open_decision_wait") or {}
    if g.get("minutes") is None and o.get("minutes") is None:
        return "-"
    parts = []
    if g.get("minutes") is not None:
        parts.append("gates %s min over %d" % (g["minutes"], g["decisions"]))
    if o.get("minutes") is not None:
        parts.append("open decisions %s min over %d (longest %s min)" % (o["minutes"], o["rulings"], o["longest_minutes"]))
    return " · ".join(parts)  # not summed: the two waits can overlap


def dash(x):
    return "-" if x is None else str(x)


def gate_costs_table(g, w):
    """The merge gates' costs and the waits on the Artisan as a Markdown table;
    a figure the run can't have is a dash."""
    run = wait = red = not_run = "-"
    if g["run"] is not None:
        run = "%s (%s per merged ticket)" % (g["run"], dash(g["run_per_merged"]))
        not_run = "skipped %s · reused %s" % (g["not_run"]["skipped"], g["not_run"]["reused"])
    if g["minutes"] is not None:
        wait = "%s min (%s per merged ticket)" % (g["minutes"], dash(g["minutes_per_merged"]))
    r = g["red"]
    if r["total"] is not None:
        red = "%s: own failure %s · red base %s · flaky %s · no verdict %s" % (
            r["total"], r["own"], r["base"], r["flaky"], r["no_verdict"])
    artisan = ("%s min over %d decision%s (longest %s min)" % (
        w["minutes"], w["decisions"], "" if w["decisions"] == 1 else "s", w["longest_minutes"])
               if w["minutes"] is not None else "-")
    rows = [("Merge gates run", run), ("Waiting on merge gates", wait), ("Red gates by cause", red),
            ("Gates not run", not_run), ("Waiting on the Artisan", artisan)]
    return "| Merge gates | This run |\n|---|---|\n" + "\n".join("| %s | %s |" % r for r in rows)


def over_limit_lines(g):
    """The packet's line when the run's median merge gate was over the limit
    (#200), with the ticket it proposes; nothing at or under it."""
    if not g.get("over_limit"):
        return []
    return ["**The merge gate is over its time limit:** a median of %s minutes per gate this run, against a "
            "limit of %s (`merge_gate_minutes_limit`). Proposed: a ticket in this project to bring the merge "
            "gate back under %s minutes. Nothing was blocked by it." % (g["median_minutes"], g["limit_minutes"],
                                                                       g["limit_minutes"]), ""]


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
        out += over_limit_lines(f["merge_gates"])
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


VOICE_FILE = "VOICE_STANDARDS.md"
VOICE_OWN_SECTION = "## Your own rules"
VOICE_CAP_TOKENS = 1500
VOICE_MODES = ("append", "merge", "replace")


def voice_line(l):
    """The rule line a voice lesson adds: its change.text, else its lesson as a list item."""
    text = ((l.get("change") or {}).get("text") or "").strip() or l["lesson"].strip()
    return text if text.startswith("- ") else "- " + text


def voice_tokens(text):
    """The cap's token estimate: characters / 4."""
    return len(text) // 4


def own_rules(text):
    """The lines of the Artisan's own section of a voice file."""
    ls, out, inside = text.splitlines(), [], False
    for ln in ls:
        if re.match(r"^#{1,2}\s", ln):
            inside = ln.strip() == VOICE_OWN_SECTION
            continue
        if inside:
            out.append(ln.strip())
    return out


def voice_mode_problem(l):
    """What is wrong with a voice lesson's change.mode and change.rule, or None."""
    ch = l.get("change") or {}
    mode = ch.get("mode", "append")
    if mode not in VOICE_MODES:
        return "change.mode must be append, merge or replace"
    if mode != "append" and not (ch.get("rule") or "").strip():
        return "a %s needs change.rule: the rule in the Artisan's own section it takes the place of" % mode
    return None


def voice_edit(text, l):
    """(TEXT with a voice lesson's rule in the Artisan's own section, problem).
    An append goes at the end of the section and is refused when it would push
    the file past the cap; a merge or replace takes the place of change.rule,
    which must be a rule in that section, and is never refused for size."""
    problem = voice_mode_problem(l)
    if problem:
        return text, problem
    ch = l.get("change") or {}
    line = voice_line(l)
    if ch.get("mode", "append") == "append":
        new = under_section(text, VOICE_OWN_SECTION, line)
        if voice_tokens(new) > VOICE_CAP_TOKENS:
            return text, ("would bring the voice file to about %d tokens, past the cap of about %d: "
                          "keep it as a merge or replace of an existing rule (change.mode, change.rule)"
                          % (voice_tokens(new), VOICE_CAP_TOKENS))
        return new, None
    rule = ch["rule"].strip()
    if rule not in own_rules(text):
        return text, "change.rule %r is not a rule in the Artisan's own section (%s); the default block is never edited" % (
            rule, VOICE_OWN_SECTION)
    ls = text.splitlines()
    start = next(i for i, ln in enumerate(ls) if ln.strip() == VOICE_OWN_SECTION)
    at = next(i for i in range(start + 1, len(ls)) if ls[i].strip() == rule)
    ls[at] = line
    return "\n".join(ls) + "\n", None


def voice_apply(root, l):
    """Adds a voice lesson's rule at the end of the Artisan's own section of
    ROOT's voice file. The default block is never edited."""
    path = os.path.join(root, VOICE_FILE)
    if not os.path.isfile(path):
        print("no %s in %s: setup seeds it" % (VOICE_FILE, root), file=sys.stderr)
        return 1
    with open(path) as fh:
        text = fh.read()
    new, problem = voice_edit(text, l)
    if problem:
        print("%s: %s" % (path, problem), file=sys.stderr)
        return 1
    with open(path, "w") as fh:
        fh.write(new)
    print(VOICE_FILE)
    return 0


def apply(worktree, lesson_path):
    l = load(lesson_path)
    ch = l.get("change") or {}
    if l.get("kind") == "voice":
        return voice_apply(worktree, l)
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


# Text the Artisan didn't type: a command's output, a reminder, a notification.
NOT_TYPED = re.compile(r"^\s*<(local-command-stdout|local-command-stderr|local-command-caveat|bash-stdout|bash-stderr|"
                       r"system-reminder|task-notification|user-prompt-submit-hook)>")
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
COMMAND = re.compile(r"<command-name>(.*?)</command-name>", re.S)
COMMAND_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)


def typed_text(entry):
    """What the Artisan typed in one transcript line, or None when it holds
    nothing of theirs (the assistant, a tool result, a meta line, output)."""
    if not isinstance(entry, dict) or entry.get("type") != "user" or entry.get("isMeta") or entry.get("isCompactSummary"):
        return None
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, list):
        content = "\n".join(b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str) or NOT_TYPED.match(content):
        return None
    name = COMMAND.search(content)
    if name:
        args = COMMAND_ARGS.search(content)
        content = (name.group(1).strip() + " " + (args.group(1).strip() if args else "")).strip()
    content = REMINDER.sub("", content).strip()
    return content or None


def chat_turns(path):
    """The Artisan's turns from a chat log, as Markdown, so the preparer reads
    one file in its run folder rather than the transcript (#245)."""
    with open(path, errors="replace") as f:
        raw = f.read()
    entries = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            entries.append(json.loads(line))
        except ValueError:
            entries = None
            break
    print("# The Artisan's turns\n\nFrom the chat log `%s`." % path)
    if entries is None:  # not a transcript: kept as it is
        print("\n" + raw.rstrip("\n"))
        return 0
    n = 0
    for e in entries:
        text = typed_text(e)
        if text is None:
            continue
        n += 1
        print("\n### Turn %d%s\n\n%s" % (n, (" (%s)" % e["timestamp"]) if e.get("timestamp") else "", text))
    if not n:
        print("\nNo turns typed by the Artisan.")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "facts" and 2 <= len(args) <= 6:
        print(json.dumps(facts(*(args + [None] * (6 - len(args)))), indent=2))
        return 0
    if cmd == "chat-turns" and len(args) == 1:
        return chat_turns(args[0])
    if cmd == "gate-costs" and len(args) == 1:
        s = load(args[0])
        merged = len([t for t in (s.get("tickets") or {}).values() if t.get("status") == "merged"])
        print(gate_costs_table(merge_gate_costs(s, merged), artisan_wait(s)))
        return 0
    if cmd == "check" and len(args) >= 2:
        files = dict(a.split("=", 1) for a in args[2:])
        return check(args[0], int(args[1]), files)
    if cmd == "render" and len(args) in (3, 4):
        return render(*args)
    if cmd == "questions" and args:
        return questions(args)
    if cmd == "record" and len(args) == 6:
        return record(*args)
    if cmd == "apply" and len(args) == 2:
        return apply(*args)
    if cmd == "voice-line" and len(args) == 1:
        print(voice_line(load(args[0])))
        return 0
    if cmd == "voice-levels" and len(args) == 1:
        doc = load(args[0])
        for l in doc.get("lessons") or []:
            if l.get("kind") == "voice" and voice_lesson(l, l["id"]):
                return 1
        print(json.dumps(doc, indent=2))
        return 0
    if cmd == "promote" and len(args) == 3:
        return promote(*args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
