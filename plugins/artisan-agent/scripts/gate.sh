#!/usr/bin/env bash
# Slice gates: once every ticket of a slice in the approved plan has merged,
# a GitHub issue labelled review-gate holds the packet and natively blocks
# only the slice's dependents; the Artisan keeps every decision card or
# changes one (a rework ticket in the run), and approving closes the issue
# and releases the dependents. The rules, the packet and the state:
# ${CLAUDE_PLUGIN_ROOT}/references/review-gates.md.
#
# Usage, from the orchestrator (wave.sh close calls sync) and the chat
# (wave.sh status calls sync):
#   gate.sh sync <run-dir>
#       folds in gate actions recorded while another session held the state
#       lock, records an approval for a gate whose issue was closed on the
#       tracker, then opens every slice gate that is due. Prints
#       "opened #<issue> <gate-id>" per gate opened.
#   gate.sh due <run-dir>
#       the slice gates whose tickets have all merged and that have no
#       issue yet, one id per line.
#   gate.sh open <run-dir> <gate-id>
#       builds the packet, opens the review-gate issue (or finds the one a
#       crashed call opened), makes it a native blocker of each dependent
#       still to merge, records the gate and queues a "review-gate"
#       decision. Prints the issue number. Opening again prints it again.
#       A slice gate's packet lists the open Human checks of its slice and
#       those carried from an earlier gate; a Human check is never one of
#       the gate's tickets or dependents.
#
# Usage, from the Engineering chat (or the Product chat: the Artisan can act
# from either):
#   gate.sh list [<run-dir>]
#       the open review-gate issues on the tracker, batched by job and role, as
#       a Markdown table: every run and both chats' gates, not one run's state
#       file (chats.sh gates). The repository is the run's, or $ARTISAN_REPO.
#   gate.sh carried <run-dir>
#       the decision cards left undecided on gates closed by hand on GitHub,
#       as a Markdown table: what the end gate lists for the Artisan.
#   gate.sh chat <run-dir> [<issue>]
#       the compressed packet of every open gate (or one): a counts line, a
#       row per decision with low confidence in bold, then "Keep all, or name
#       one to change."
#   gate.sh packet <run-dir> <gate-id | issue>
#       the full packet (the issue body), as opened or as it would be now.
#   gate.sh change <run-dir> <issue> <card> <choice> [--why W] [--by NAME] [--bug]
#       "change" on one card: a rework ticket in this run (in scope, queued,
#       a native blocker of the slice's dependents), the decision recorded.
#       --bug: the Artisan found a bug in the card's ticket; a bug-found
#       event (tighten evidence in its areas) is logged in the same write.
#       Prints the rework ticket's number.
#   gate.sh bug <run-dir> <ticket> --gate <gate-id> [--why W] [--by NAME]
#       a bug the Artisan found in a ticket at a gate with no card to change
#       for it (the end gate "end", an urgent one "urgent-<t>"): logs
#       bug-found. 4 when the ticket is not in the run.
#   gate.sh guardrail <run-dir> <issue> <card> <team|product|individual>
#                     <ticket|area|everywhere> [--area A] [--why W] [--by NAME]
#       "make it a guardrail" on one card: kept, with a guardrail lesson
#       for the retro.
#   gate.sh approve <run-dir> <issue> [--by NAME] [--why W]
#                   [--confidence firm|provisional]
#                   [--level team|product|individual --reach ticket|area|everywhere [--area A]]
#       "keep all": every card not yet decided is kept, the decisions are
#       posted on the issue, the issue closes and the dependents are free to
#       dispatch in the next wave. It never passes a Human check: one left
#       unanswered carries to the next gate.
#   gate.sh check <run-dir> <ticket|all> pass|fail|later [--gate <issue|end>]
#                 [--notes T] [--why W] [--not-bug|--bug] [--by NAME]
#       a Human check (references/human-checks.md), on the open or deferred
#       review gate that lists it, or on the end gate while it is open.
#       pass: closes it with the result posted. fail (needs --why): a bug
#       in its agent ticket: a rework ticket in this run (blocking the open
#       gate's dependents and the check, as a redirect), bug-found unless
#       --not-bug (--bug, the default, says so); prints the rework ticket's
#       number; the check stays open. An answer kept in gates/pending/
#       while the lock is held counts: a second answer is refused (6).
#       A failed check whose rework hasn't merged (or left the run) refuses
#       every answer (6); then it is answered again at the next gate.
#       later: it carries to the next gate. "all pass --gate <issue>" passes
#       every check on that gate, skipping (and naming) one whose rework is
#       open. Events human-check-passed and human-check-failed. 6: not an
#       open Human check, its rework is open, or on no open gate.
#   gate.sh holds <run-dir> <ticket> [<dependent>]
#       prints "held" when the dependent, which depends on the ticket, waits
#       for a gate: the ticket is in a slice or risk gate not yet answered
#       (from plan approval, not only once it is due: #170) and the dependent
#       is not in that gate; else "free". With no dependent: one outside the
#       gate. A gate none of whose tickets merged holds nothing. A caller
#       treats anything else (an error) as held.
#
# Every decision recorded carries its job and who made it (--by, default
# Artisan); the card's own job for a card, job 13 for the gate.
#
# A deferred gate (gate-action.sh defer) is still answered here at the end
# gate: approve, change and guardrail take it as they take an open one, and a
# change on it opens a rework ticket without blocking the dependents, which
# already ran. Redirect, bypass, defer, exception gates and parking:
# gate-action.sh (references/gate-actions.md).
#
# Every gate-decision event carries outcome (keep or change), redirect
# (false here; gate-action.sh logs a redirect's) and areas (the card's
# ticket's; approve logs one keep event for the whole gate, its areas the
# union over the kept cards, card null, cards the number kept), for guardrail health (references/guardrail-health.md). A gate a
# guardrail opened (an area's risk gate) records it under `guardrails` and
# logs guardrail-fired when it opens.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held (sync and
# open only; the Artisan's actions are kept and folded in later), 4 not a
# ticket of the run (bug), 6 refused (no such open gate or card, or the card
# is already decided).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq, python3 and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
# shellcheck source=lib/gate-lib.sh
. "$SCRIPT_DIR/lib/gate-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "gate.sh: $*"; }

PACKET() { python3 -I "$SCRIPT_DIR/lib/packet.py" "$@"; }
gates_dir() { mkdir -p "$RUN_DIR/gates/pending"; printf '%s\n' "$RUN_DIR/gates"; }
jget() { local f="$1"; shift; jq -r "$@" "$STATE_JQ_DEFS $f" "$FILE"; } # filter [jq args]

gate_def() { # id: the plan's slice gate, as JSON, or empty
  jq -c --arg id "$1" "$STATE_JQ_DEFS"' slice_gates[] | select(.id == $id)' "$FILE"
}

recorded() { # id-or-issue: the recorded gate, as JSON, or empty
  jq -c --arg k "$1" '(.review_gates // [])[] | select(.id == $k or (.issue | tostring) == $k)' "$FILE"
}

# ---------------------------------------------------------------- due/holds

cmd_due() {
  open_run "${1:-}"
  jget '. as $s | slice_gates[] | select(. as $g | $s | gate_due($g))
        | select(.id as $id | ($s.review_gates // []) | all(.id != $id)) | .id'
}

cmd_holds() {
  [ $# -eq 2 ] || [ $# -eq 3 ] || usage
  open_run "$1"
  case "$(jget 'gate_holds($t; $d)' --arg t "$2" --argjson d "$(jq -n --arg d "${3:-}" 'if $d == "" then null else $d end')")" in
    true) echo held ;;
    false) echo free ;;
    *) die "could not read the gates of #$2" ;;
  esac
}

# --------------------------------------------------------------------- open

# The gate's view for packet.py: the gate, its dependents, the state, and the
# guardrails and other provisional cards as their scripts print them.
build_view() { # id dependents-json
  local def="$1" deps="$2" guard= prov= t=
  gates_dir >/dev/null
  guard=$("$SCRIPT_DIR/guardrails.sh" table --run-dir "$RUN_DIR" --ticket "$(jq -r '.tickets | map(tostring) | join(",")' <<<"$def")" 2>"$RUN_DIR/gates/.guardrails.err") \
    || guard="Could not be read: $(tr '\n' ' ' <"$RUN_DIR/gates/.guardrails.err")"
  prov=$("$SCRIPT_DIR/questions.sh" provisional "$RUN_DIR" 2>/dev/null) || prov=""
  # The slice's own decisions are its cards; the listing keeps the rest.
  for t in $(jq -r '.tickets[]' <<<"$def"); do
    prov=$(printf '%s\n' "$prov" | grep -v "^| #$t |" || true)
  done
  jq -n --argjson g "$def" --argjson deps "$deps" --slurpfile s "$FILE" \
    --arg guard "$guard" --arg prov "$prov" --arg run "$RUN_ID" "$STATE_JQ_DEFS"'
    {gate: ($g + {kind: ($g.kind // "slice"), dependents: $deps, title: ($s[0] | gate_title($g; $run))}),
     state: $s[0], guardrails: $guard, provisional: $prov}'
}

# The Human checks a slice gate lists (references/human-checks.md): every one
# still open whose agent ticket is in the slice, and every one carried from a
# gate that is no longer open (answered "later", or left unanswered there).
# A risk gate lists none. A check whose failed answer's rework is still open
# (#178) can't be answered: checks_for_gate leaves it out, and
# waiting_checks_for_gate names it ({ticket, for, waiting_on, failed_at}), so
# the packet says "waiting on rework #<r>". JSON for human_checks_view.
gate_checks() { # def waiting(true|false)
  jq -c --argjson g "$1" --argjson w "$2" "$STATE_JQ_DEFS"'
    . as $s
    | if ($g.kind // "slice") != "slice" then []
      else [open_human_checks[] as $c
        | ($s | human_check_for($c)) as $a
        | ($s.tickets[$c].human_check.gate // null) as $hg
        | ($s | check_rework($c)) as $open
        | select(($open != null) == $w)
        | select($hg != $g.id)
        | select(($g.tickets | index($a)) != null
                 or ($hg != null and all(($s.review_gates // [])[]; .id != $hg or .status != "open")))
        | {ticket: $c, for: $a} + (if $hg != null then {carried_from: $hg} else {} end)
          + (if $open != null then {waiting_on: ($open | split(" ")[1]), failed_at: ($open | split(" ")[0])} else {} end)]
      end' "$FILE"
}
checks_for_gate() { gate_checks "$1" false; } # def
waiting_checks_for_gate() { gate_checks "$1" true; } # def

# The in-run tickets still to merge that a ticket of the gate blocks natively.
dependents() { # def
  local def="$1" repo= t= blockers= out='[]'
  repo=$(get '.repo')
  for t in $(get '.plan.scope[]'); do
    jq -e --arg t "$t" '.tickets | index($t)' <<<"$def" >/dev/null && continue
    # Merged, closed or out of the run (#164): nothing to hold.
    case "$(get --arg t "$t" '.tickets[$t].status // ""')" in merged|closed|deferred|dropped|resliced|bypassed|sent_back) continue ;; esac
    # A Human check is no dependent: it verifies the slice, never waits on it.
    [ "$(get --arg t "$t" "$STATE_JQ_DEFS"' is_human_check($t)')" = false ] || continue
    blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
      || die "could not read the blockers of #$t from the tracker"
    if jq -e --argjson d "$def" 'any(.[]; (.number | tostring) as $n | $d.tickets | index($n))' <<<"$blockers" >/dev/null; then
      out=$(jq -c --arg t "$t" --arg title "$(get --arg t "$t" '.plan.tickets[$t].title // ""')" \
        '. + [{number: $t, title: (if $title == "" then null else $title end)}]' <<<"$out")
    fi
  done
  printf '%s\n' "$out"
}

issue_id() { local j=; j=$(gh api "repos/$(get '.repo')/issues/$1") && jq -er .id <<<"$j"; }

# blocker blocks ticket natively, once.
add_blocker() { # ticket blocker-issue blocker-id
  local repo=
  repo=$(get '.repo')
  gh api "repos/$repo/issues/$1/dependencies/blocked_by" \
    | jq -e --arg b "$2" 'any(.[]; (.number | tostring) == $b)' >/dev/null && return 0
  gh api --method POST "repos/$repo/issues/$1/dependencies/blocked_by" -F "issue_id=$3" >/dev/null \
    || die "could not make #$2 a blocker of #$1"
}

# A ticket that left the run (#164) is no ticket of the review: the gate's
# left_run names it ({number, status, title}), so the packet can say the slice
# can't be reviewed end to end.
without_left() { # def
  jget 'gate_left($g) as $l | gate_left_run($g) as $r | $g | .tickets -= $l | .left_run = $r' --argjson g "$1" -c
}

cmd_open() {
  [ $# -eq 2 ] || usage
  open_run "$1"
  local id="$2" def= rec= dir= view= body= title= repo= num= url= d= gid=
  rec=$(recorded "$id")
  if [ -n "$rec" ]; then jq -r .issue <<<"$rec"; return 0; fi
  def=$(gate_def "$id")
  [ -n "$def" ] || state_die 6 "gate.sh: no slice gate $id in the plan"
  [ "$(jget 'gate_due($g)' --argjson g "$def")" = true ] \
    || state_die 6 "gate.sh: $id is not due: not every ticket of its slice has merged"
  def=$(without_left "$def")
  dir=$(gates_dir)
  repo=$(get '.repo')
  # Built once and kept, so a call that crashed after opening the issue
  # opens nothing new and shows the same packet.
  view="$dir/$id.view.json"
  if [ ! -s "$view" ]; then
    build_view "$def" "$(dependents "$def")" >"$view.tmp"
    PACKET cards <"$view.tmp" >"$view.cards"
    jq --slurpfile cards "$view.cards" --argjson hc "$(human_checks_view "$(jq -sc 'add' <(checks_for_gate "$def") <(waiting_checks_for_gate "$def"))")" \
      '.gate.cards = $cards[0] | . + $hc' "$view.tmp" >"$view.tmp2"
    mv "$view.tmp2" "$view"
    rm -f "$view.tmp" "$view.cards"
  fi
  body="$dir/$id.md"
  PACKET body <"$view" >"$body"
  title=$(jq -r .gate.title "$view")
  num=$(gh issue list -R "$repo" --state open --label review-gate --json number,title,labels \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  if [ -z "$num" ]; then
    url=$(gh issue create -R "$repo" --title "$title" --label review-gate --body "$(cat "$body")") \
      || die "could not open the review-gate issue for $id"
    num=${url##*/}
  fi
  gid=$(issue_id "$num") || die "could not read #$num"
  for d in $(jq -r '.gate.dependents[].number' "$view"); do
    add_blocker "$d" "$num" "$gid"
  done
  # The view holds the whole state, so it reaches jq as a file, never as an
  # argument (#203: Linux refuses one over 128 KiB).
  apply '
    $view[0] as $v
    | if any((.review_gates // [])[]; .id == $v.gate.id) then .
    else
      ($v.gate.cards | length) as $n
      | ([$v.gate.tickets[] as $t | $v.state.tickets[$t].evidence.unsure[]?] | length) as $u
      | ($v.provisional | split("\n") | map(capture("^\\| #(?<t>[^ |]+) \\|").t) ) as $other
      | .review_gates = ((.review_gates // []) + [{
          id: $v.gate.id, kind: $v.gate.kind, slice: $v.gate.slice, title: $v.gate.title,
          role: $v.gate.role, issue: $num, tickets: $v.gate.tickets,
          dependents: $v.gate.dependents, cards: $v.gate.cards,
          human_checks: [($v.human_checks // [])[].ticket],
          left_run: ($v.gate.left_run // []),
          status: "open", opened_at: $now, decisions: [], reworks: []}
          + (if $v.gate.guardrails then {guardrails: $v.gate.guardrails} else {} end)])
      | .provisional_shown = (((.provisional_shown // []) + $v.gate.tickets + $other) | unique)
      | .decisions += [{id: ((.decisions | length) + 1), kind: "review-gate", gate: $v.gate.id, issue: $num,
          question: "\($v.gate.title) is #\($num): \($n) decision(s), \($u) uncertaint\(if $u == 1 then "y" else "ies" end); it holds \(if $v.gate.dependents == [] then "nothing" else ($v.gate.dependents | map("#" + .number) | join(", ")) end). Keep all, or name one to change (gate.sh chat).",
          status: "waiting", at: $now}]
      | event({event: "gate-opened", gate: $v.gate.id, issue: $num, tickets: $v.gate.tickets,
               dependents: ($v.gate.dependents | map(.number))}; $now)
      | event({event: "provisional-shown"}; $now)
      | reduce ($v.human_checks // [])[] as $h (.;
          .tickets[$h.ticket].human_check = ((.tickets[$h.ticket].human_check // {state: "open", for: $h.for})
            | .gate = $v.gate.id | .shown = ((.shown // []) + [$v.gate.id])))
      | guardrails_fired($v.gate; $now)
    end' --argjson num "$num" --slurpfile view "$view"
  echo "$num"
}

# ------------------------------------------------------------ the Artisan acts

# An open gate by issue number: sets GATE (its recorded JSON).
GATE=
open_gate() { # issue
  GATE=$(recorded "$1")
  [ -n "$GATE" ] || state_die 6 "gate.sh: #$1 is not a gate of this run"
  case "$(jq -r .status <<<"$GATE")" in open|deferred) ;;
    *) state_die 6 "gate.sh: gate #$1 is $(jq -r .status <<<"$GATE"), not open" ;; esac
}

# Cards already decided: in the state file, or in an action not yet folded in.
decided_cards() { # gate-id
  {
    jq -r --arg g "$1" '(.review_gates // [])[] | select(.id == $g) | .decisions[] | .card // empty' "$FILE"
    for f in "$RUN_DIR"/gates/pending/*.json; do
      [ -f "$f" ] || continue
      jq -r --arg g "$1" 'select(.gate == $g) | .decisions[] | .card // empty' "$f"
    done
  } | sort -u
}

card_json() { # card-number
  local c=
  c=$(jq -c --argjson n "$1" '.cards[] | select(.card == $n)' <<<"$GATE")
  [ -n "$c" ] || state_die 6 "gate.sh: gate #$(jq -r .issue <<<"$GATE") has no card $1"
  if decided_cards "$(jq -r .id <<<"$GATE")" | grep -qx "$1"; then
    state_die 6 "gate.sh: card $1 is already decided"
  fi
  printf '%s\n' "$c"
}

# The one filter that writes an action into the state file. Applying the same
# action twice changes nothing (its key is recorded on its decisions).
ACTION_FILTER='
  # The gate-decision event health reads (#122): the outcome, never a
  # redirect here (gate-action.sh logs those), and every area of the card'"'"'s
  # ticket; a card flagged as a bug also logs bug-found.
  def decision_events($a):
    $a.decisions[0] as $d
    | event({event: "gate-decision", gate: $a.gate, card: $d.card, by: $a.by,
             outcome: $d.outcome, redirect: false, areas: ticket_areas([$d.ticket])}; $now)
    | if $d.bug == true then bug_found($d.ticket; $a.gate; $a.by; ($d.why // ""); $now) else . end;
  # "Keep all" logs one gate-decision for the gate, not one per kept card
  # (#149): the cards at a gate aren'"'"'t independent judgements. Its areas are
  # the union of the kept cards'"'"' tickets'"'"'; a gate with no card left to keep
  # (every card was changed first) logs none.
  def keep_event($a):
    ([$a.decisions[] | select(.outcome == "keep")]) as $k
    | if ($k | length) == 0 then .
      else event({event: "gate-decision", gate: $a.gate, card: null, by: $a.by, outcome: "keep",
                  redirect: false, areas: ticket_areas([$k[].ticket]), cards: ($k | length)}; $now) end;
  # A Human check answered at a gate (gate.sh check): pass closes it, fail
  # sends its agent ticket to rework (and logs bug-found unless the Artisan
  # said it is not a bug), later carries it to the next gate. The answer is
  # kept on the check; its key makes a second fold change nothing.
  def check_answer($a; $i):
    ($a.ticket) as $t
    | if any((.tickets[$t].human_check.answers // [])[]; .action == $a.key) then .
      else
        ({ticket: $t, agent_ticket: $a.agent, gate: $a.gate, by: $a.by}) as $e
        | .tickets[$t].human_check.answers = ((.tickets[$t].human_check.answers // [])
            + [{verdict: $a.verdict, gate: $a.gate, by: $a.by, at: $now, action: $a.key}
               + (if ($a.notes // "") != "" then {notes: $a.notes} else {} end)
               + (if ($a.why // "") != "" then {why: $a.why} else {} end)
               + (if $a.rework then {rework: ($a.rework.number | tostring)} else {} end)])
        | if $a.verdict == "pass" then
            .tickets[$t].status = "closed" | .tickets[$t].human_check.state = "passed"
            | event($e + (if ($a.notes // "") != "" then {notes: $a.notes} else {} end) + {event: "human-check-passed"}; $now)
          elif $a.verdict == "fail" then
            ($a.rework.number | tostring) as $r | ($a.agent) as $f
            | .plan.scope = ((.plan.scope + [$r]) | unique)
            | .plan.tickets[$r] = ((.plan.tickets[$f] // {}) | del(.branch, .slice, .ticket_path)
                + {title: $a.rework.title, rework_of: $f, gate: $a.gate, human_check: $t})
            | (if .tickets[$r] == null then .tickets[$r] = new_ticket($r) else . end)
            | (if $i == null then .
               else .review_gates[$i].reworks = ((.review_gates[$i].reworks // []) + [{card: null, ticket: $r, human_check: $t}]) end)
            | event($e + {event: "human-check-failed", why: $a.why, rework: $r}; $now)
            | (if $a.bug == true then bug_found($f; $a.gate; $a.by; $a.why; $now) else . end)
            | event({event: "rework", ticket: $r, from: $f, gate: $a.gate, card: null, human_check: $t}; $now)
          else . end
      end;
  . as $s0
  | ((.review_gates // []) | map(.id) | index($a.gate)) as $i
  | if $a.type == "check" then check_answer($a; $i)
    elif $i == null or any(.review_gates[$i].decisions[]; .action == $a.key) then .
    else
      .review_gates[$i].decisions += ($a.decisions | map(. + {action: $a.key}))
      | .lessons = ((.lessons // []) + [$a.decisions[] | select(.guardrail_level != null)
          | {kind: "guardrail", gate: $a.gate, card, ticket, choice, guardrail_level, reach,
             area: (.area // null), by, at: $now}])
      | if $a.type == "change" then
          ($a.rework.number | tostring) as $r | ($a.rework.from | tostring) as $f
          | .plan.scope = ((.plan.scope + [$r]) | unique)
          | .plan.tickets[$r] = ((.plan.tickets[$f] // {}) | del(.branch, .slice)
              + {title: $a.rework.title, rework_of: $f, gate: $a.gate})
          | (if .tickets[$r] == null then .tickets[$r] = new_ticket($r) else . end)
          | .review_gates[$i].reworks += [{card: $a.decisions[0].card, ticket: $r}]
          | decision_events($a)
          | event({event: "rework", ticket: $r, from: $f, gate: $a.gate, card: $a.decisions[0].card}; $now)
        elif $a.type == "approve" then
          .review_gates[$i].status = "approved" | .review_gates[$i].approved_at = $now
          | .decisions |= map(if .kind == "review-gate" and .gate == $a.gate and .status == "waiting"
              then .status = "decided" | .choice = "approve" | .by = $a.by | .job = 13 | .decided_at = $now
                | .changed = (any($s0.review_gates[$i].decisions[]; .outcome? == "change") or ($s0.review_gates[$i].reworks // []) != [])
              else . end)
          | (if $a.closed_on_tracker then
               .review_gates[$i].closed_on_tracker = true | .review_gates[$i].carried = $a.carried
             else . end)
          | keep_event($a)
          | event({event: "gate-approved", gate: $a.gate, issue: .review_gates[$i].issue, by: $a.by}
                  + (if $a.closed_on_tracker then {closed_on_tracker: true, carried: $a.carried} else {} end); $now)
        else decision_events($a)
        end
    end'

# record action-file: into the state file now if the lock can be had, else
# kept in gates/pending/ for the next sync (the orchestrator may hold it).
# fold action-file: one locked, one-step write of the action; the file goes
# once it is in. Returns the write's status (3: the lock is held).
fold() {
  local f="$1" st=0
  ( apply '$action[0] as $a | '"$ACTION_FILTER" --slurpfile action "$f" ) 2>"$f.err" || st=$?
  if [ "$st" -eq 0 ]; then rm -f "$f" "$f.err"; fi
  return "$st"
}

record() {
  local f="$1" st=0
  fold "$f" || st=$?
  if [ "$st" -eq 3 ]; then
    rm -f "$f.err"
    echo "gate.sh: the run's state lock is held (a wave is running); recorded on the tracker and in $f, folded into the state file at the next sync" >&2
  elif [ "$st" -ne 0 ]; then
    die "could not record the action in the state file (kept in $f): $(tr '\n' ' ' <"$f.err")"
  fi
}

new_action() { # gate-id type by: a fresh action file's path
  local dir= f=
  dir=$(gates_dir)
  f="$dir/pending/$1.$(date +%s).$$.$RANDOM.json"
  printf '%s\n' "$f"
}

parse_opts() { # sets BY WHY CONF AREA LEVEL REACH BUG (--bug only where BUG_OK=1)
  BY=Artisan WHY= CONF= AREA= LEVEL= REACH= BUG=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --bug) [ "${BUG_OK:-0}" = 1 ] || usage; BUG=1; shift ;;
      --by) [ $# -ge 2 ] || usage; BY=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; WHY=$2; shift 2 ;;
      --confidence) [ $# -ge 2 ] || usage; CONF=$2; shift 2 ;;
      --area) [ $# -ge 2 ] || usage; AREA=$2; shift 2 ;;
      --level) [ $# -ge 2 ] || usage; LEVEL=$2; shift 2 ;;
      --reach) [ $# -ge 2 ] || usage; REACH=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$BY" ] || usage
  case "$CONF" in ""|firm|provisional) ;; *) usage ;; esac
  case "$LEVEL" in ""|team|product|individual) ;; *) usage ;; esac
  case "$REACH" in ""|ticket|area|everywhere) ;; *) usage ;; esac
}

# A decision in the shape of references/decision-record.md, from a card.
decision_from() { # card-json action choice
  jq -c --arg action "$2" --arg choice "$3" --arg by "$BY" --arg why "$WHY" --arg conf "$CONF" \
    --arg gate "$(jq -r .id <<<"$GATE")" '
    {job: (.job // 13), choice: $choice, by: $by, card: .card, ticket: .ticket, gate: $gate,
     outcome: $action, original: {choice, by}}
    + (if $why != "" then {why: $why} else {} end)
    + (if $conf != "" then {confidence: $conf} else {} end)' <<<"$1"
}

cmd_change() {
  [ $# -ge 4 ] || usage
  open_run "$1"
  local issue="$2" n="$3" choice="$4" card= repo= dec= num= url= gid= t= f= title=
  shift 4
  BUG_OK=1 parse_opts "$@"
  open_gate "$issue"
  card=$(card_json "$n")
  repo=$(get '.repo')
  t=$(jq -r .ticket <<<"$card")
  title="Rework #$t: $(jq -r '.question // "a decision"' <<<"$card")"
  # A call that crashed after opening the rework ticket left it open: reuse it.
  num=$(gh issue list -R "$repo" --state open --label in-run --json number,title,body \
          | jq -r --arg t "$title" --arg mark "Review gate #$issue, card $n," \
              '[.[] | select(.title == $t and (.body | contains($mark)))] | first | .number // empty')
  [ -z "$num" ] || url="/$num"
  [ -n "$num" ] || url=$(gh issue create -R "$repo" --title "$title" --label ready-for-agent --label in-run --body "$(
    jq -r --arg choice "$choice" --arg why "$WHY" --arg issue "$issue" --arg run "$RUN_ID" '
"## Parent

Review gate #\($issue), card \(.card), on #\(.ticket). In run \($run).

## What to build

At the slice gate the Artisan changed a decision #\(.ticket) made alone.

| | |
|---|---|
| Question | \(.question // "-") |
| Was | \(.choice // "-") |
| Change to | \($choice) |
" + (if $why != "" then "| Why | \($why) |\n" else "" end) + "
## Acceptance criteria

- [ ] \($choice), replacing: \(.choice // "the earlier choice")
- [ ] The full suite passes
"' <<<"$card")") || die "could not open the rework ticket"
  num=${url##*/}
  gid=$(issue_id "$num") || die "could not read #$num"
  # A deferred gate's dependents already ran: the rework doesn't hold them.
  if [ "$(jq -r .status <<<"$GATE")" = open ]; then
    for d in $(jq -r '.dependents[].number' <<<"$GATE"); do add_blocker "$d" "$num" "$gid"; done
  fi
  dec=$(decision_from "$card" change "$choice" | jq -c --argjson r "$num" --argjson bug "$BUG" \
    '. + {rework: ($r | tostring)} + (if $bug == 1 then {bug: true} else {} end)')
  gh issue comment "$issue" -R "$repo" --body "Card $n changed by $BY: \"$choice\". Rework ticket #$num, in this run; the slice's dependents wait for it too." >/dev/null \
    || echo "gate.sh: could not comment on #$issue" >&2
  f=$(new_action "$(jq -r .id <<<"$GATE")")
  jq -n --arg key "$(basename "$f" .json)" --arg g "$(jq -r .id <<<"$GATE")" --argjson d "$dec" --arg by "$BY" \
    --argjson r "$num" --arg from "$t" --arg title "$title" \
    '{key: $key, type: "change", gate: $g, by: $by, decisions: [$d], rework: {number: $r, from: $from, title: $title}}' >"$f"
  record "$f"
  echo "$num"
}

cmd_guardrail() {
  [ $# -ge 5 ] || usage
  open_run "$1"
  local issue="$2" n="$3" level="$4" reach="$5" card= dec= f=
  shift 5
  case "$level" in team|product|individual) ;; *) usage ;; esac
  case "$reach" in ticket|area|everywhere) ;; *) usage ;; esac
  parse_opts "$@"
  [ "$reach" != area ] || [ -n "$AREA" ] || state_die 2 "gate.sh: a reach of area needs --area NAME"
  open_gate "$issue"
  card=$(card_json "$n")
  dec=$(decision_from "$card" keep "$(jq -r .choice <<<"$card")" \
    | jq -c --arg l "$level" --arg r "$reach" --arg a "$AREA" \
      '. + {guardrail_level: $l, reach: $r} + (if $a != "" then {area: $a} else {} end)')
  f=$(new_action "$(jq -r .id <<<"$GATE")")
  jq -n --arg key "$(basename "$f" .json)" --arg g "$(jq -r .id <<<"$GATE")" --argjson d "$dec" --arg by "$BY" \
    '{key: $key, type: "guardrail", gate: $g, by: $by, decisions: [$d]}' >"$f"
  record "$f"
  echo "card $n kept; a $level guardrail ($reach) is noted for the retro"
}

# The decisions recorded at a gate, as the comment on its issue.
decisions_comment() { # gate-id action-file
  {
    jq -r --arg g "$1" '(.review_gates // [])[] | select(.id == $g) | .decisions[]' "$FILE"
    for f in "$RUN_DIR"/gates/pending/*.json "$2"; do
      [ -f "$f" ] || continue
      jq -c --arg g "$1" 'select(.gate == $g) | .decisions[]' "$f"
    done
  } | jq -s -r '
    "Decisions recorded at this gate (the decision record: job, choice, who).",
    "",
    "| Card | Ticket | Job | Decision | By | Was decided by |",
    "|---|---|---|---|---|---|",
    (unique_by(.card // "gate") | sort_by(.card // 0)[] |
      "| \(.card // "gate") | \(if .ticket then "#" + .ticket else "-" end) | \(.job) | \(.outcome // "approve"): \(.choice | gsub("\\|"; "/"))\(if .guardrail_level then " (guardrail: \(.guardrail_level), \(.reach))" else "" end)\(if .why then "; why: " + .why else "" end) | \(.by) | \(.original.by // "-") |"),
    "",
    "```json", (map(del(.action)) | tojson), "```"'
}

cmd_approve() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" gid= decided= keeps= f= repo=
  shift 2
  parse_opts "$@"
  [ "$REACH" != area ] || [ -n "$AREA" ] || state_die 2 "gate.sh: a reach of area needs --area NAME"
  open_gate "$issue"
  gid=$(jq -r .id <<<"$GATE")
  repo=$(get '.repo')
  decided=$(decided_cards "$gid" | jq -R 'tonumber? // empty' | jq -sc .)
  keeps=$(jq -c --argjson done "$decided" --arg by "$BY" --arg g "$gid" '
    [.cards[] | select(.card as $c | $done | index($c) | not)
     | {job: (.job // 13), choice, by: $by, card, ticket, gate: $g, outcome: "keep", original: {choice, by}}]' <<<"$GATE")
  f=$(new_action "$gid")
  jq -n --arg key "$(basename "$f" .json)" --arg g "$gid" --arg by "$BY" --argjson keeps "$keeps" \
    --arg why "$WHY" --arg conf "$CONF" --arg level "$LEVEL" --arg reach "$REACH" --arg area "$AREA" '
    {key: $key, type: "approve", gate: $g, by: $by,
     decisions: ($keeps + [{job: 13, choice: "approve the slice", by: $by, gate: $g, outcome: "approve"}
       + (if $why != "" then {why: $why} else {} end) + (if $conf != "" then {confidence: $conf} else {} end)
       + (if $level != "" then {guardrail_level: $level} else {} end)
       + (if $reach != "" then {reach: $reach} else {} end)
       + (if $area != "" then {area: $area} else {} end)])}' >"$f.tmp"
  mv "$f.tmp" "$f.new"
  decisions_comment "$gid" "$f.new" >"$f.comment.md"
  gh issue comment "$issue" -R "$repo" --body-file "$f.comment.md" >/dev/null || die "could not comment on #$issue"
  gh issue close "$issue" -R "$repo" >/dev/null || die "could not close #$issue"
  mv "$f.new" "$f"
  rm -f "$f.comment.md"
  record "$f"
  echo "approved #$issue: $(jq -r 'if .dependents == [] then "nothing in the run waited on it" else (.dependents | map("#" + .number) | join(", ")) + " can dispatch in the next wave" end' <<<"$GATE")"
}

# A bug the Artisan found in a ticket at a review gate that has no card to
# change for it: the end gate, an urgent end gate, or any gate by name.
cmd_bug() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local t="$2" gate=""
  shift 2
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --gate) [ $# -ge 2 ] && [ -n "$2" ] || usage; gate=$2; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [ -n "$gate" ] || usage
  parse_opts ${rest[@]+"${rest[@]}"}
  [ "$(get --arg t "$t" '.plan.tickets[$t] != null')" = true ] || state_die 4 "gate.sh: #$t is not a ticket of this run"
  apply 'bug_found($t; $g; $by; $why; $now)' --arg t "$t" --arg g "$gate" --arg by "$BY" --arg why "$WHY"
  echo "bug in #$t recorded at $gate"
}

# ------------------------------------------------------------ Human checks

# A Human check failed and waiting on its rework (#165): its last answer is a
# fail whose rework ticket hasn't merged. Prints "<gate> <rework>", or
# nothing; once the rework merges (or leaves the run) the check is answered
# again at the next gate that lists it.
check_rework_open() { # ticket -> "<gate> <rework>"
  jget 'check_rework($t) // empty' --arg t "$1"
}

# The gate a Human check is answered at: the open or deferred review gate
# that lists it, else the end gate while it is open. Prints its id; 6 when
# the check is on no gate the Artisan can answer now.
check_gate() { # ticket
  local t="$1" hg="" f="" open=""
  [ "$(jget 'is_human_check($t)' --arg t "$t")" = true ] || state_die 6 "gate.sh: #$t is not a Human check of this run"
  [ "$(get --arg t "$t" '.tickets[$t].status')" = queued ] \
    || state_die 6 "gate.sh: Human check #$t is $(get --arg t "$t" '.tickets[$t].human_check.state // .tickets[$t].status'), not open"
  open=$(check_rework_open "$t") || exit $?
  [ -z "$open" ] || state_die 6 "gate.sh: Human check #$t already failed at ${open% *}; rework #${open#* } is open"
  # An answer given while the lock was held counts already (gates/pending/).
  for f in "$RUN_DIR"/gates/pending/*.json; do
    [ -f "$f" ] || continue
    ! jq -e --arg t "$t" '.type == "check" and .ticket == $t and .verdict != "later"' "$f" >/dev/null \
      || state_die 6 "gate.sh: Human check #$t is already answered ($(jq -r .verdict "$f")); the answer is folded in at the next sync"
  done
  hg=$(get --arg t "$t" '.tickets[$t].human_check.gate // ""')
  if [ -n "$hg" ] && [ "$(get --arg g "$hg" 'any((.review_gates // [])[]; .id == $g and (.status == "open" or .status == "deferred"))')" = true ]; then
    printf '%s\n' "$hg"
  elif [ "$(get '.end_gate.status // ""')" = open ]; then
    echo end
  else
    state_die 6 "gate.sh: Human check #$t is on no open gate yet; it is answered at the slice gate after #$(jget 'human_check_for($t)' --arg t "$t") merges, or at the end gate"
  fi
}

# One Human check answered: the tracker first (close it, or open its rework
# ticket), then the action, recorded or kept for the next sync.
check_one() { # ticket verdict notes not-bug want-gate
  local t="$1" verdict="$2" notes="$3" not_bug="$4" want="$5" gid="" agent="" repo="" f="" num="" url="" title="" gid_num="" rework='null' d=""
  gid=$(check_gate "$t") || exit $?
  [ -z "$want" ] || [ "$want" = "$gid" ] || state_die 6 "gate.sh: Human check #$t is on $gid, not on $want"
  agent=$(jget 'human_check_for($t)' --arg t "$t")
  repo=$(get '.repo')
  case "$verdict" in
    pass)
      gh issue close "$t" -R "$repo" --comment "Human check passed at $gid by $BY, on the build of #$agent.${notes:+ Notes: $notes}" >/dev/null \
        || die "could not close Human check #$t"
      ;;
    fail)
      title="Rework #$agent: Human check #$t failed"
      num=$(gh issue list -R "$repo" --state open --label in-run --json number,title,body \
              | jq -r --arg t "$title" --arg mark "Human check #$t failed at $gid." \
                  '[.[] | select(.title == $t and (.body | contains($mark)))] | first | .number // empty')
      if [ -z "$num" ]; then
        url=$(gh issue create -R "$repo" --title "$title" --label ready-for-agent --label in-run --body "## Parent

Human check #$t failed at $gid. In run $RUN_ID.

## What to build

$BY checked the build of #$agent by hand and it failed:

> $(printf '%s' "$WHY" | sed 's/^/> /; 1s/^> //')

## Acceptance criteria

- [ ] #$agent's work no longer fails Human check #$t: $(printf '%s' "$WHY" | head -1)
- [ ] The full suite passes
") || die "could not open the rework ticket"
        num=${url##*/}
      fi
      gid_num=$(issue_id "$num") || die "could not read #$num"
      # As a redirect: an open gate's dependents wait for the rework too; the
      # check itself is tried again on the rework's build.
      if [ "$gid" != end ] && [ "$(get --arg g "$gid" '.review_gates[] | select(.id == $g) | .status')" = open ]; then
        for d in $(get --arg g "$gid" '.review_gates[] | select(.id == $g) | .dependents[].number'); do
          add_blocker "$d" "$num" "$gid_num"
        done
      fi
      add_blocker "$t" "$num" "$gid_num"
      gh issue comment "$t" -R "$repo" --body "Human check failed at $gid by $BY: $WHY. Rework ticket #$num joins this run; try this check again on its build." >/dev/null \
        || echo "gate.sh: could not comment on #$t" >&2
      rework=$(jq -nc --argjson n "$num" --arg title "$title" '{number: $n, title: $title}')
      echo "$num"
      ;;
  esac
  f=$(new_action "$gid")
  jq -n --arg key "$(basename "$f" .json)" --arg g "$gid" --arg t "$t" --arg agent "$agent" --arg v "$verdict" \
    --arg by "$BY" --arg notes "$notes" --arg why "$WHY" --argjson bug "$([ "$not_bug" = 1 ] && echo false || echo true)" \
    --argjson rework "$rework" '
    {key: $key, type: "check", gate: $g, ticket: $t, agent: $agent, verdict: $v, by: $by, notes: $notes, why: $why,
     bug: ($v == "fail" and $bug), rework: $rework}' >"$f"
  record "$f"
  case "$verdict" in
    pass) echo "Human check #$t passed and closed" ;;
    later) echo "Human check #$t carries to the next gate" ;;
  esac
}

cmd_check() {
  [ $# -ge 3 ] || usage
  open_run "$1"
  local which="$2" verdict="$3" want="" notes="" not_bug=0 t="" list="" g="" open=""
  shift 3
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --gate) [ $# -ge 2 ] && [ -n "$2" ] || usage; want=$2; shift 2 ;;
      --notes) [ $# -ge 2 ] || usage; notes=$2; shift 2 ;;
      --not-bug) not_bug=1; shift ;;
      --bug) not_bug=0; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  parse_opts ${rest[@]+"${rest[@]}"}
  case "$verdict" in
    pass|later) ;;
    fail) [ -n "$WHY" ] && [ "$which" != all ] || usage ;;
    *) usage ;;
  esac
  # --gate names a gate by its issue (or "end"): the check must be on it.
  if [ -n "$want" ] && [ "$want" != end ]; then
    g=$(recorded "$want")
    [ -n "$g" ] || state_die 6 "gate.sh: #$want is not a gate of this run"
    want=$(jq -r .id <<<"$g")
  fi
  if [ "$which" = all ]; then
    for t in $(jget 'open_human_checks[]'); do
      open=$(check_rework_open "$t") || exit $?
      if [ -n "$open" ]; then
        # Named, not answered: the failed answer stands until the rework
        # merges. With --gate, named when it failed at that gate, is listed
        # on it now (carried), or the gate is the end gate.
        case "$want" in
          ""|end|"${open% *}"|"$(get --arg t "$t" '.tickets[$t].human_check.gate // ""')") ;;
          *) continue ;;
        esac
        echo "gate.sh: skipped Human check #$t: it already failed at ${open% *}; rework #${open#* } is open"
        continue
      fi
      g=$( (check_gate "$t") 2>/dev/null) || continue
      [ -z "$want" ] || [ "$g" = "$want" ] || continue
      list="$list $t"
    done
    [ -n "$list" ] || state_die 6 "gate.sh: no Human check is waiting on ${want:-an open gate}"
  else
    list=$which
  fi
  for t in $list; do
    check_one "$t" "$verdict" "$notes" "$not_bug" "$want"
  done
}

# --------------------------------------------------------------------- sync

cmd_sync() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local f= st= id= issue= repo= state= carried=
  # Actions the Artisan took while the lock was held.
  for f in "$RUN_DIR"/gates/pending/*.json; do
    [ -f "$f" ] || continue
    fold "$f" || { st=$?; cat "$f.err" >&2; exit "$st"; }
  done
  # A gate closed on the tracker by hand is approved by whoever closed it.
  repo=$(get '.repo')
  for issue in $(get '(.review_gates // [])[] | select(.status == "open" or .status == "deferred") | .issue'); do
    state=$(gh api "repos/$repo/issues/$issue" 2>/dev/null | jq -r '.state // empty') || continue
    if [ "$(printf '%s' "$state" | tr 'A-Z' 'a-z')" = closed ]; then
      GATE=$(recorded "$issue")
      id=$(jq -r .id <<<"$GATE")
      f=$(new_action "$id")
      jq -n --arg key "$(basename "$f" .json)" --arg g "$id" --argjson gate "$GATE" '
        {key: $key, type: "approve", gate: $g, by: "Artisan (closed on the tracker)", closed_on_tracker: true,
         carried: [$gate.cards[] | select(.card as $c | [$gate.decisions[].card] | index($c) | not) | .card],
         decisions: ([$gate.cards[] | select(.card as $c | [$gate.decisions[].card] | index($c) | not)
           | {job: (.job // 13), choice, by: "Artisan (closed on the tracker)", card, ticket, gate: $g,
              outcome: "keep", original: {choice, by}}]
           + [{job: 13, choice: "approve the slice", by: "Artisan (closed on the tracker)", gate: $g, outcome: "approve"}])}' >"$f"
      carried=$(jq -r '.carried | length' "$f")
      fold "$f" || { st=$?; cat "$f.err" >&2; exit "$st"; }
      # One line on the tracker, so either chat announces it on its next sweep.
      gh issue comment "$issue" -R "$repo" --body "Gate #$issue closed on GitHub: treated as approved; $carried undecided card$([ "$carried" = 1 ] || echo s) carried to the end gate

<!-- $GATE_CLOSED_MARK carried=$carried -->" >/dev/null 2>&1 || true
    fi
  done
  local num=
  for id in $(cmd_due "$RUN_DIR"); do
    num=$(cmd_open "$RUN_DIR" "$id") || exit $?
    echo "opened #$num $id"
  done
  close_empty
}

# A gate none of whose tickets merged (they all left the run or were closed,
# #164) has nothing to review: it is
# recorded as answered ("empty", with the reason and a gate-empty event),
# never opened on the tracker, and holds nothing. One line per gate closed.
close_empty() {
  local ids=""
  ids=$(jget '. as $s | slice_gates[] | select(. as $g | $s | gate_empty($g)) | .id')
  [ -n "$ids" ] || return 0
  apply '. as $s
    | reduce (slice_gates[] | select(. as $g | $s | gate_empty($g))) as $g (.;
        ($s | gate_left_run($g)) as $left
        | ([$g.tickets[] | "#\(.) \($s.tickets[.].status | sub("_"; " "))"] | join(", ")) as $who
        | {by: "run", at: $now, why: ("none of its tickets merged (" + $who + "): nothing to review")} as $r
        | .review_gates = ((.review_gates // []) + [{
            id: $g.id, kind: $g.kind, slice: $g.slice,
            title: ($s | gate_title($g; $run)),
            role: $g.role, issue: null, tickets: [], left_run: $left, dependents: [], cards: [],
            human_checks: [], status: "empty", opened_at: null, decisions: [], reworks: [],
            empty: $r, answered: [$r + {action: "nothing to review"}]}])
        | event({event: "gate-empty", gate: $g.id, issue: null, kind: $g.kind, choice: "nothing to review",
                 by: "run", left_run: $left, why: $r.why}; $now))' --arg run "$RUN_ID"
  jget '(.review_gates // [])[] | select(.status == "empty" and (.id as $id | $ids | index($id)))
    | "closed \(.id): \(.empty.why)"' --argjson ids "$(printf '%s\n' "$ids" | jq -R . | jq -sc .)"
}

# ------------------------------------------------------------- list/chat/packet

cmd_list() {
  local repo=${ARTISAN_REPO:-}
  if [ -n "${1:-}" ]; then
    open_run "$1"
    repo=$(get '.repo')
  fi
  [ -n "$repo" ] || usage
  "$SCRIPT_DIR/chats.sh" gates --repo "$repo"
}

cmd_carried() {
  open_run "${1:-}"
  local n=
  n=$(get '[(.review_gates // [])[] | select(.closed_on_tracker == true) | .carried | length] | add // 0')
  if [ "$n" -eq 0 ]; then
    echo "No gate was closed by hand with cards left undecided."
    return 0
  fi
  echo "| Gate | Card | Ticket | Decision | Chosen by |"
  echo "|---|---|---|---|---|"
  get '(.review_gates // [])[] | select(.closed_on_tracker == true) | . as $g
       | $g.cards[] | select(.card as $c | $g.carried | index($c))
       | "| #\($g.issue) (closed on GitHub) | \(.card) | #\(.ticket) | \(.question // "-") → \(.choice | gsub("\\|"; "/")) | \(.by // "-") |"'
}

view_of() { # recorded-gate-json: its view, with the cards and dependents recorded
  local g="$1" f=
  f="$RUN_DIR/gates/$(jq -r .id <<<"$g").view.json"
  if [ -f "$f" ]; then
    jq --slurpfile s "$FILE" --argjson g "$g" '.state = $s[0] | .gate.issue = $g.issue' "$f"
  else
    jq -n --slurpfile s "$FILE" --argjson g "$g" '{gate: ($g + {kind: ($g.kind // "slice")}), state: $s[0], guardrails: "", provisional: ""}'
  fi
}

cmd_chat() {
  open_run "${1:-}"
  local g= first=1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    [ "$first" -eq 1 ] || echo
    first=0
    view_of "$g" | PACKET chat
  done < <(jq -c --arg k "${2:-}" '(.review_gates // [])[]
             | select(if $k == "" then .status == "open" else (.issue | tostring) == $k end)' "$FILE")
  [ "$first" -eq 0 ] || echo "No review gate is open."
}

cmd_packet() {
  [ $# -eq 2 ] || usage
  open_run "$1"
  local rec= def=
  rec=$(recorded "$2")
  if [ -n "$rec" ] && [ -f "$RUN_DIR/gates/$(jq -r .id <<<"$rec").md" ]; then
    cat "$RUN_DIR/gates/$(jq -r .id <<<"$rec").md"
    return 0
  fi
  def=$(gate_def "$2")
  [ -n "$def" ] || state_die 6 "gate.sh: no gate $2"
  def=$(without_left "$def")
  build_view "$def" "$(dependents "$def")" | PACKET body
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  sync) cmd_sync "$@" ;;
  due) cmd_due "$@" ;;
  open) cmd_open "$@" ;;
  holds) cmd_holds "$@" ;;
  list) cmd_list "$@" ;;
  carried) cmd_carried "$@" ;;
  chat) cmd_chat "$@" ;;
  packet) cmd_packet "$@" ;;
  change) cmd_change "$@" ;;
  guardrail) cmd_guardrail "$@" ;;
  approve) cmd_approve "$@" ;;
  bug) cmd_bug "$@" ;;
  check) cmd_check "$@" ;;
  *) usage ;;
esac
