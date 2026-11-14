#!/usr/bin/env bash
# Gate actions, exception gates and parking: how the Artisan answers a gate
# (approve, redirect, bypass, defer), the exception gate a run raises when it
# gives up on a ticket or a check won't go green (retry with notes, reslice,
# take it myself, drop; or bypass, defer), and the run parking when
# everything left waits behind open reviews. The rules and what each action
# leaves behind: ${CLAUDE_PLUGIN_ROOT}/references/gate-actions.md. Slice
# gates and their packet: references/review-gates.md (gate.sh).
#
# Usage, from either chat, on the Artisan's word (<issue> is the gate's
# review-gate issue):
#   gate-action.sh approve <run-dir> <issue> [--by NAME] [--why W]
#                  [--confidence firm|provisional]
#                  [--level team|product|individual --reach ticket|area|everywhere [--area A]]
#       a review gate: keep all and close it (gate.sh approve). Refused (6)
#       on an exception gate, which is bypassed or deferred, never approved.
#   gate-action.sh redirect <run-dir> <issue> (--notes TEXT | --mine [--notes TEXT])
#                  [--by NAME] [--why W] [--bug]
#       a review gate: send it back. --notes opens a rework ticket in this
#       run for an agent; --mine opens it ready-for-human, for the Artisan.
#       Either way it is a ticket of its own (its attempts are its own), it
#       natively blocks the gate's dependents, and the gate closes as
#       redirected. Prints the rework ticket's number. --bug: the Artisan
#       found a bug in the gate's tickets (bug-found, tighten evidence in
#       their areas, in the same write).
#   gate-action.sh bypass <run-dir> <issue> [--by NAME] [--why W]
#       either kind: the gate closes unreviewed and its dependents go ahead;
#       recorded with who bypassed it, for the retro. On an exception gate the
#       ticket leaves the run and no longer blocks its dependents. A gate a
#       guardrail opened (its `guardrails`) also logs guardrail-bypassed,
#       with the --why as its reason.
#   gate-action.sh defer <run-dir> <issue> [--by NAME] [--why W]
#       either kind: the dependents go ahead now; the gate stays open until
#       the end gate (gate-action.sh deferred lists it there), where its cards
#       can still be changed into rework tickets (gate.sh change).
#   gate-action.sh retry <run-dir> <issue> --notes TEXT [--by NAME] [--why W] [--bug]
#   gate-action.sh take <run-dir> <issue> [--by NAME] [--why W] [--bug]
#   gate-action.sh reslice|drop <run-dir> <issue> [--by NAME] [--why W]
#       an exception gate: the Artisan's call on the ticket. retry: queued
#       for a fresh worker given the notes, with one more attempt. reslice:
#       out of the run, labelled needs-triage, to be sliced again. take:
#       labelled ready-for-human, built by the Artisan (human.sh). drop: out
#       of the run, left open. The gate closes. reslice and drop first print
#       the impact (everything in scope that depends on the ticket, directly
#       or through others, and whether each slice can still be reviewed end
#       to end), then those dependents leave the run with it: back to
#       needs-triage with a comment, native blockers kept (status sent_back).
#   gate-action.sh repaired <run-dir> <issue> [--by NAME] [--why W]
#       an exception gate opened only because of the stream-json miscount
#       (#151): once sweep.sh repair has taken the ticket's failed attempts
#       back and returned it, the gate closes as resolved by the repair (its
#       status "resolved"), not bypassed: the ticket stays in the run and keeps
#       its own edges; only the gate's issue stops blocking the dependents.
#       Refused (6) unless the repair returned the ticket.
#   gate-action.sh send-back <run-dir> [--by NAME] [--why W]
#       without a gate: the tickets stranded behind a dropped or resliced one
#       (what an older run left) go back to triage the same way.
#   gate-action.sh stranded <run-dir>
#       exit 0 and one line per dropped or resliced blocker ("#12 dropped:
#       #14, #15 can't start") when tickets are stranded; 1 when none are.
#   gate-action.sh chat <run-dir>
#       every open or deferred exception gate, compressed, with its choices.
#   gate-action.sh list <run-dir>
#       every gate of the run, both kinds, as a Markdown table.
#   gate-action.sh deferred <run-dir>
#       the deferred gates, as a Markdown table, for the end gate.
#
# Usage, from wave.sh status:
#   gate-action.sh sync <run-dir>
#       opens an exception gate for every exception decision waiting without
#       one (a ticket the run gave up on, a red check, a blocked merge); a
#       decision carrying `guardrail` (and `area`), such as the scope floor's
#       "scope-floor", records it on the gate and logs guardrail-fired; and
#       bypasses one closed by hand on the tracker. Prints "opened #<issue>
#       <gate-id>" per gate. Exception gates are never in the plan's gates,
#       so nothing removes them.
#   gate-action.sh parked <run-dir> [--record]
#       exit 0 and one line ("parked: waiting on N reviews ...") when every
#       ticket left waits behind an open gate; 1 otherwise. --record logs a
#       "parked" event once.
#
# Every action takes the state lock before it touches the tracker; while a
# wave holds it, the action is refused (3) and nothing changes: answer again
# once wave.sh status says the wave has ended. (gate.sh approve keeps an
# answer given then and folds it in later.)
#
# Exit status: 0 ok, 1 error (stranded: none stranded), 2 usage, 3 the state lock is held, 6 refused
# (not a gate of this run, not open, or not an action this gate takes).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq and gh.

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
die() { state_die 1 "gate-action.sh: $*"; }
refuse() { state_die 6 "gate-action.sh: $*"; }

# ------------------------------------------------------------------ helpers

# hold: the state lock for this call's writer, taken before anything reaches
# the tracker, so an action is never half recorded. Child scripts write
# under the same pid.
hold() {
  local pid=
  pid=$(writer)
  export ARTISAN_WRITER_PID=$pid
  [ "$(state_lock_holder "$RUN_DIR")" != "$pid" ] || return 0
  state_lock "$RUN_DIR" "$pid" 2>/dev/null \
    || state_die 3 "gate-action.sh: the run's state lock is held (a wave is running); nothing changed. Answer again once wave.sh status says the wave has ended"
  trap 'state_unlock "'"$RUN_DIR"'" "'"$pid"'" || true' EXIT
  # Another chat may have answered the gate before the lock was ours.
  if [ -n "$GATE" ]; then
    local before=
    before=$(g .status)
    find_gate "$(g .issue)"
    [ "$(g .status)" = "$before" ] || refuse "gate #$(g .issue) was answered meanwhile; it is now $(g .status)"
  fi
}

REPO=
repo() { [ -n "$REPO" ] || REPO=$(get '.repo'); printf '%s\n' "$REPO"; }
issue_id() { local j=; j=$(gh api "repos/$(repo)/issues/$1") && jq -er .id <<<"$j"; }
blockers_of() { gh api "repos/$(repo)/issues/$1/dependencies/blocked_by"; }

# blocks ticket blocker: 0 when the blocker natively blocks the ticket, 1 when
# it doesn't. A tracker that can't be read ends the call: never act blind.
blocks() {
  local b=
  b=$(blockers_of "$1") || die "could not read the blockers of #$1 from the tracker"
  jq -e --arg b "$2" 'any(.[]; (.number | tostring) == $b)' <<<"$b" >/dev/null
}

add_blocker() { # ticket blocker-issue
  local id=
  ! blocks "$1" "$2" || return 0
  id=$(issue_id "$2") || die "could not read #$2"
  gh api --method POST "repos/$(repo)/issues/$1/dependencies/blocked_by" -F "issue_id=$id" >/dev/null \
    || die "could not make #$2 a blocker of #$1"
}

# remove_blocker ticket blocker: the native edge goes. 0 when it removed one,
# 1 when there was none.
remove_blocker() {
  local id=
  blocks "$1" "$2" || return 1
  id=$(issue_id "$2") || die "could not read #$2"
  gh api --method DELETE "repos/$(repo)/issues/$1/dependencies/blocked_by/$id" >/dev/null \
    || die "could not remove #$2 as a blocker of #$1"
}

comment() { # issue body
  gh issue comment "$1" -R "$(repo)" --body "$2" >/dev/null || die "could not comment on #$1"
}

# GATE (recorded JSON) and KIND (exception, or the review gate's kind) of the
# gate whose issue this is.
GATE= KIND= LIST=
find_gate() { # issue
  GATE=$(jq -c --arg k "$1" '(.review_gates // [])[] | select((.issue | tostring) == $k)' "$FILE")
  LIST=review_gates
  if [ -z "$GATE" ]; then
    GATE=$(jq -c --arg k "$1" '(.exception_gates // [])[] | select((.issue | tostring) == $k)' "$FILE")
    LIST=exception_gates
  fi
  [ -n "$GATE" ] || refuse "#$1 is not a gate of this run"
  KIND=$(jq -r '.kind // "slice"' <<<"$GATE")
  case "$(jq -r .status <<<"$GATE")" in
    open | deferred) ;;
    *) refuse "gate #$1 is $(jq -r .status <<<"$GATE"), not open" ;;
  esac
}

g() { jq -r "$@" <<<"$GATE"; }

BY=Artisan WHY= NOTES= MINE=0 BUG=0
parse_opts() { # --bug only where BUG_OK=1 (redirect, retry, take)
  BY=Artisan WHY= NOTES= MINE=0 BUG=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --bug) [ "${BUG_OK:-0}" = 1 ] || usage; BUG=1; shift ;;
      --by) [ $# -ge 2 ] && [ -n "$2" ] || usage; BY=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; WHY=$2; shift 2 ;;
      --notes) [ $# -ge 2 ] && [ -n "$2" ] || usage; NOTES=$2; shift 2 ;;
      --mine) MINE=1; shift ;;
      *) usage ;;
    esac
  done
}

# record_answer status choice field extra-filter [jq args]: one locked,
# one-step write of the gate's answer: its status, the record kept for the
# retro under "field", the gate's waiting decision decided as a decision
# record, and the event. extra-filter runs first, for the ticket changes.
# The events guardrail health reads go in the same write (#122): a bypass
# of a gate a guardrail opened logs guardrail-bypassed per guardrail; a
# redirect logs gate-decision (outcome change, redirect true, the tickets'
# areas); --bug logs bug-found for each of the gate's tickets.
record_answer() {
  local status="$1" choice="$2" field="$3" extra="$4" job=13
  shift 4
  [ "$KIND" != exception ] || job=15
  apply '
    '"$extra"'
    | ($rec + {by: $by, at: $now} + (if $why != "" then {why: $why} else {} end)
       + (if $notes != "" then {notes: $notes} else {} end)) as $r
    | (.[$list] | map(.issue | tostring) | index($issue)) as $x
    | .[$list][$x].status = $status
    | .[$list][$x][$field] = $r
    | .[$list][$x].answered = ((.[$list][$x].answered // []) + [$r + {action: $choice}])
    | ({job: $job, choice: $choice, by: $by, gate: .[$list][$x].id}
       + (if $why != "" then {why: $why} else {} end)
       + (if $redirect != "" then {redirect: $redirect} else {} end)) as $d
    | ([.decisions[] | select(.status == "waiting" and (.issue | tostring) == $issue) | .id]) as $ids
    | reduce $ids[] as $id (.; decide($id; $d; $now))
    | event({event: "gate-\($status)", gate: .[$list][$x].id, issue: ($issue | tonumber),
             kind: .[$list][$x].kind, choice: $choice, by: $by}; $now)
    | .[$list][$x] as $gt
    | (if $status == "bypassed" then
         reduce ($gt.guardrails // [])[] as $gr (.;
           event({event: "guardrail-bypassed", guardrail: $gr.guardrail} + (if $gr.area then {area: $gr.area} else {} end)
                 + {gate: $gt.id, reason: (if $why == "" then null else $why end), by: $by}; $now))
       else . end)
    | (if $choice == "redirect" then
         event({event: "gate-decision", gate: $gt.id, card: null, by: $by, outcome: "change", redirect: true,
                areas: ticket_areas($gt.tickets // [])}; $now)
       else . end)
    | (if $bug == 1 then reduce ($gt.tickets // [])[] as $bt (.; bug_found($bt; $gt.id; $by; $why; $now)) else . end)' \
    --arg list "$LIST" --arg issue "$(g .issue)" --arg status "$status" --arg choice "$choice" \
    --arg field "$field" --argjson job "$job" --arg by "$BY" --arg why "$WHY" --arg notes "$NOTES" \
    --arg redirect "$REDIRECT" --argjson bug "$BUG" "$@"
}
REDIRECT=

# The dependents a gate holds that are still to run, one per line.
open_dependents() {
  local d= st=
  for d in $(g '.dependents[]?.number'); do
    st=$(get --arg d "$d" '.tickets[$d].status // ""')
    case "$st" in merged | closed) continue ;; esac
    printf '%s\n' "$d"
  done
}


# downstream ticket...: the in-scope tickets still to run (queued or blocked),
# Human checks aside, that depend on any of these, directly or through others, one per line, in
# ticket order. The tracker's native edges say who depends on whom.
downstream() {
  local seen=" $* " d= st= b= changed=1 found=
  while [ "$changed" -eq 1 ]; do
    changed=0
    for d in $(get '.plan.scope[]'); do
      case "$seen" in *" $d "*) continue ;; esac
      st=$(get --arg d "$d" '.tickets[$d].status // ""')
      case "$st" in queued | blocked) ;; *) continue ;; esac
      # A Human check is no dependent in the run (references/human-checks.md).
      [ "$(get --arg d "$d" "$STATE_JQ_DEFS"' is_human_check($d)')" = false ] || continue
      for b in $seen; do
        if blocks "$d" "$b"; then
          seen="$seen$d "
          found="$found $d"
          changed=1
          break
        fi
      done
    done
  done
  [ -z "$found" ] || printf '%s\n' $found | sort -n
}

# json_list word...: the words as a JSON array of strings.
json_list() { printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'; }

# checks_of ticket...: the open Human checks in scope (references/human-checks.md)
# whose agent ticket is one of these, as "<check> <agent ticket>", one per
# line in check order: they leave the run with their ticket (#161).
checks_of() {
  get --argjson ts "$(json_list "$@")" "$STATE_JQ_DEFS"'
    . as $s | [open_human_checks[] as $c | {c: $c, a: ($s | human_check_for($c))} | select(.a as $a | $ts | index($a) != null)]
    | sort_by(.c | tonumber? // 0) | .[] | "\(.c) \(.a)"'
}

# checks_json check-pair...: checks_of's lines as JSON [{ticket, for}].
checks_json() { printf '%s\n' "$@" | jq -Rc 'select(. != "") | split(" ") | {ticket: .[0], for: .[1]}' | jq -sc .; }

# impact ticket dependents...: what taking the ticket out of the run does to
# the rest of it: who goes with it, and whether each slice can still be
# reviewed end to end.
impact() {
  local t="$1" ds= hc=
  shift
  ds=$(json_list "$@")
  hc=$(checks_json "$(checks_of "$t" "$@")")
  get --arg t "$t" --argjson ds "$ds" --argjson hc "$hc" "$STATE_JQ_DEFS"'
    ([$t] + $ds) as $out
    | ((if $ds == [] then "Nothing else in the run depends on #\($t)."
        else "\($ds | map("#" + .) | join(", ")) depend on #\($t), directly or through others, so they leave the run with it and go back to needs-triage." end)
       + ($hc | map(" Human check #\(.ticket) follows #\(.for), so it leaves the run with it and goes back to needs-triage.") | join(""))) as $who
    | ([slice_gates[] | select(.tickets | any(. as $x | $out | index($x)))
        | "slice \"\(.slice)\" loses \([.tickets[] | select(. as $x | $out | index($x))] | map("#" + .) | join(", "))"]) as $slices
    | $who + " " + (if $slices == [] then "Every slice can still be reviewed end to end."
        else "Not every slice survives (" + ($slices | join("; ")) + "), so it cannot be reviewed end to end as planned." end)'
}

# stranded: JSON [{blocker, status, waiting: [tickets], checks: [{ticket, for}]}],
# one per dropped or resliced ticket that still holds tickets in the run that
# can never start, or open Human checks (#161) of it, of those tickets or of
# the tickets already sent back with it.
stranded() {
  local out='[]' b="" w="" ws="" hc="[]" sb=""
  for b in $(get '.plan.scope[] as $t | select(.tickets[$t].status == "dropped" or .tickets[$t].status == "resliced") | $t'); do
    ws=$(downstream "$b" | tr '\n' ' ')
    # shellcheck disable=SC2086
    w=$(json_list $ws)
    sb=$(get --arg b "$b" '[.tickets | to_entries[] | select(.value.status == "sent_back" and (.value.sent_back.from? | tostring) == $b) | .key] | join(" ")')
    # shellcheck disable=SC2086
    hc=$(checks_json "$(checks_of "$b" $ws $sb)")
    [ "$w" != "[]" ] || [ "$hc" != "[]" ] || continue
    out=$(jq -c --arg b "$b" --arg s "$(get --arg b "$b" '.tickets[$b].status')" --argjson w "$w" --argjson hc "$hc" \
      '. + [{blocker: $b, status: $s, waiting: $w, checks: $hc}]' <<<"$out")
  done
  printf '%s\n' "$out"
}

# send_back blocker how dependent...: each dependent leaves the run and goes
# back to needs-triage with a comment, keeping its native blockers.
send_back() {
  local from="$1" how="$2" d=
  shift 2
  for d in "$@"; do
    gh issue edit "$d" -R "$(repo)" --add-label needs-triage --remove-label in-run >/dev/null \
      || die "could not relabel #$d"
    comment "$d" "Taken out of run $RUN_ID: it depends on #$from, which $how. It goes back to needs-triage to be grilled again and keeps its blockers; it is not re-added to this run.${WHY:+ Why: $WHY}"
  done
}

# send_checks_back blocker how checks: each Human check (checks_of's lines)
# leaves the run with the ticket it follows: back to needs-triage with a
# comment naming that ticket. $how says what became of the blocker itself.
send_checks_back() {
  local from="$1" how="$2" c="" a="" what=""
  while read -r c a; do
    [ -n "$c" ] || continue
    if [ "$a" = "$from" ]; then what="which $how"; else what="which depends on #$from, which $how, and went back to needs-triage"; fi
    gh issue edit "$c" -R "$(repo)" --add-label needs-triage --remove-label in-run >/dev/null \
      || die "could not relabel #$c"
    comment "$c" "Taken out of run $RUN_ID: it is the Human check for #$a, $what. There is no work of #$a in this run to check, so it goes back to needs-triage with it; it is not re-added to this run.${WHY:+ Why: $WHY}"
  done <<<"$3"
}

# The jq that marks checks_json's Human checks ($hc) sent back with the ticket they follow.
CHECKS_SENT_BACK='reduce $hc[] as $h (.; .tickets[$h.ticket] |= (.status = "sent_back" | .pid = null | .sent_back = {from: $h.for, at: $now})
  | event({event: "sent-back", ticket: $h.ticket, from: $h.for, human_check_for: $h.for}; $now))'

# checks_named checks-json: "Human check #a" or "Human checks #a, #b".
checks_named() { jq -r '"Human check\(if length > 1 then "s" else "" end) \(map("#" + .ticket) | join(", "))"' <<<"$1"; }

# hashes word...: "#a, #b" for the words.
hashes() { printf '%s\n' "$@" | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g'; }

# ------------------------------------------------------ review-gate actions

cmd_approve() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  find_gate "$2"
  [ "$KIND" != exception ] \
    || refuse "#$2 is an exception gate: it is bypassed or deferred, never approved. Choose retry with notes, reslice, take it myself or drop (gate-action.sh chat)"
  shift
  exec "$SCRIPT_DIR/gate.sh" approve "$RUN_DIR" "$@"
}

cmd_redirect() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" label= mode= title= num= url= r= from= d= body=
  shift 2
  BUG_OK=1 parse_opts "$@"
  find_gate "$issue"
  [ "$KIND" != exception ] \
    || refuse "#$issue is an exception gate: send it back with gate-action.sh retry --notes, or take it yourself with gate-action.sh take"
  if [ "$MINE" -eq 1 ]; then label=ready-for-human mode=self
  else
    [ -n "$NOTES" ] || usage
    label=ready-for-agent mode=notes
  fi
  REDIRECT=$mode
  hold
  title="Rework: $(g .title)"
  # A call that crashed after opening the rework ticket left it open: reuse it.
  num=$(gh issue list -R "$(repo)" --state open --label in-run --json number,title,body \
          | jq -r --arg t "$title" --arg mark "Redirected at review gate #$issue." \
              '[.[] | select(.title == $t and (.body | contains($mark)))] | first | .number // empty')
  if [ -z "$num" ]; then
    body=$(jq -rn --arg issue "$issue" --arg run "$RUN_ID" --arg notes "$NOTES" --arg why "$WHY" --arg by "$BY" \
      --arg mode "$mode" --argjson gate "$GATE" '
"## Parent

Redirected at review gate #\($issue). In run \($run).

## What to build

\($by) sent the \($gate.kind // "slice") gate on \($gate.tickets | map("#" + .) | join(", ")) back"
+ (if $mode == "self" then " to build it themselves." else " with notes." end) + "

" + (if $notes != "" then "> \($notes | gsub("\n"; "\n> "))\n\n" else "" end)
+ (if $why != "" then "Why: \($why)\n\n" else "" end) + "## Acceptance criteria

- [ ] " + (if $notes != "" then $notes | split("\n") | first else "The slice is as the Artisan wants it, by their own judgement" end) + "
- [ ] The full suite passes
"')
    url=$(gh issue create -R "$(repo)" --title "$title" --label "$label" --label in-run --body "$body") \
      || die "could not open the rework ticket"
    num=${url##*/}
  fi
  for d in $(open_dependents); do add_blocker "$d" "$num"; done
  comment "$issue" "Redirected by $BY$( [ "$mode" = self ] && echo ": they will build it themselves" || echo " with notes"). Rework ticket #$num joins this run; $( [ -n "$(g '.dependents[]?')" ] && g '.dependents | map("#" + .number) | join(", ")' || echo nothing) wait(s) for it.${WHY:+ Why: $WHY}"
  gh issue close "$issue" -R "$(repo)" >/dev/null || die "could not close #$issue"
  from=$(g '.tickets[0]')
  record_answer redirected "redirect" redirect '
    ($num | tostring) as $r
    | .plan.scope = ((.plan.scope + [$r]) | unique)
    | .plan.tickets[$r] = ((.plan.tickets[$from] // {}) | del(.branch, .slice, .ticket_path)
        + {title: $title, rework_of: $from, gate: $gid})
    | (if .tickets[$r] == null then .tickets[$r] = new_ticket($r) else . end)
    | ((.review_gates // []) | map(.id) | index($gid)) as $i
    | .review_gates[$i].reworks = ((.review_gates[$i].reworks // []) + [{card: null, ticket: $r}] | unique)
    | event({event: "rework", ticket: $r, from: $from, gate: $gid, card: null}; $now)' \
    --argjson num "$num" --arg from "$from" --arg title "$title" --arg gid "$(g .id)" \
    --argjson rec "{\"mode\": \"$mode\", \"ticket\": \"$num\"}"
  echo "$num"
}

# ----------------------------------------------------------- either kind

# release: the dependents go ahead. A review gate's issue stops blocking
# them; an exception gate's ticket and issue do. Prints the edges removed as
# JSON, kept on the gate so the retro and the end gate can see them.
release() {
  local d= b= out='[]' blockers=
  blockers=$(g .issue)
  [ "$KIND" != exception ] || blockers="$blockers $(g .ticket)"
  for d in $(open_dependents); do
    for b in $blockers; do
      if remove_blocker "$d" "$b"; then
        out=$(jq -c --arg d "$d" --arg b "$b" '. + [{dependent: $d, blocker: $b}]' <<<"$out")
      fi
    done
  done
  printf '%s\n' "$out"
}

# The bypass sequence, shared by cmd_bypass and an exception gate closed by
# hand (cmd_sync). bypass_release: a review gate's closed issue no longer
# blocks; an exception gate's ticket leaves the run, so its own edges to the
# dependents go too, and it loses the in-run label. bypass_record: the
# answer, and the ticket's status. BYPASS_RELEASED is the edges removed (JSON).
BYPASS_RELEASED='[]'
bypass_release() {
  BYPASS_RELEASED='[]'
  [ "$KIND" != exception ] || BYPASS_RELEASED=$(release)
  [ "$KIND" != exception ] \
    || gh issue edit "$(g .ticket)" -R "$(repo)" --remove-label in-run >/dev/null 2>&1 || true
}

bypass_record() {
  local extra='.'
  [ "$KIND" != exception ] || extra='.tickets[$t] |= (.status = "bypassed" | .pid = null)'
  record_answer bypassed bypass bypass "$extra" --arg t "$(g '.ticket // ""')" \
    --argjson rec "{\"released\": $BYPASS_RELEASED}"
}

cmd_bypass() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2"
  shift 2
  parse_opts "$@"
  find_gate "$issue"
  REDIRECT=
  hold
  bypass_release
  if [ "$KIND" = exception ]; then
    comment "$(g .ticket)" "Taken out of run $RUN_ID at exception gate #$issue: bypassed by $BY. Its dependents go ahead without it.${WHY:+ Why: $WHY}"
  fi
  comment "$issue" "Bypassed by $BY: closed without review.${WHY:+ Why: $WHY} Recorded for the retro."
  gh issue close "$issue" -R "$(repo)" >/dev/null || die "could not close #$issue"
  bypass_record
  echo "bypassed #$issue by $BY; $(dependents_line) go(es) ahead"
}

cmd_defer() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" released= extra='.'
  shift 2
  parse_opts "$@"
  find_gate "$issue"
  [ "$(g .status)" = open ] || refuse "gate #$issue is already deferred"
  REDIRECT=
  hold
  released=$(release)
  if [ "$KIND" = exception ]; then
    extra='.tickets[$t] |= (.status = "deferred" | .pid = null)'
  fi
  comment "$issue" "Deferred by $BY: $(dependents_line) go(es) ahead now; this gate stays open until the end gate.${WHY:+ Why: $WHY}"
  record_answer deferred defer deferral "$extra" --arg t "$(g '.ticket // ""')" \
    --argjson rec "{\"released\": $released}"
  echo "deferred #$issue by $BY; it stays open until the end gate"
}

dependents_line() {
  local d=
  d=$(g 'if (.dependents // []) == [] then "" else .dependents | map("#" + .number) | join(", ") end')
  printf '%s\n' "${d:-nothing}"
}

# -------------------------------------------------- exception-gate choices

exception_only() { # issue
  find_gate "$1"
  [ "$KIND" = exception ] \
    || refuse "#$1 is a $KIND gate: answer it with approve, redirect, bypass or defer"
}

close_exception() { # issue what
  comment "$1" "$2"
  gh issue close "$1" -R "$(repo)" >/dev/null || die "could not close #$1"
}

cmd_retry() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" t=
  shift 2
  BUG_OK=1 parse_opts "$@"
  [ -n "$NOTES" ] || usage
  exception_only "$issue"
  t=$(g .ticket)
  REDIRECT=notes
  hold
  close_exception "$issue" "Retry with notes, by $BY: #$t goes to a fresh worker with one more attempt.
> $NOTES"
  record_answer decided "retry with notes" outcome '
    .tickets[$t] |= (.status = "queued" | .pid = null | del(.blocked_reason)
      | .extra_attempts = ((.extra_attempts // 0) + 1)
      | .notes = ((.notes // []) + [{note: $notes, issue: ($issue | tonumber), by: $by, at: $now}]))' \
    --arg t "$t" --argjson rec '{}'
  echo "#$t queued for a fresh worker with your notes (attempt $(( $(get --arg t "$t" '.tickets[$t].attempts') + 1 )))"
}

cmd_take() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" t= prev=
  shift 2
  BUG_OK=1 parse_opts "$@"
  exception_only "$issue"
  t=$(g .ticket)
  REDIRECT=self
  hold
  gh issue edit "$t" -R "$(repo)" --add-label ready-for-human --remove-label ready-for-agent >/dev/null \
    || die "could not label #$t ready-for-human"
  # The last worker's worktree has the branch checked out; free it for the
  # Artisan's own worktree (human.sh). One with uncommitted work stays.
  prev=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$prev" ] && [ -d "$prev" ]; then
    git -C "$MAIN" worktree remove "$prev" 2>/dev/null \
      || echo "gate-action.sh: $prev has uncommitted work and stays; human.sh needs the branch free" >&2
  fi
  close_exception "$issue" "Taken by $BY: #$t is ready-for-human; they build it in their own worktree from the integration branch, and it goes through the same verifier, suite and merge.${WHY:+ Why: $WHY}"
  record_answer decided "take it myself" outcome '
    .tickets[$t] |= (.status = "queued" | .pid = null | del(.blocked_reason))' --arg t "$t" --argjson rec '{}'
  echo "#$t is yours: human.sh sets up its worktree at the next wave.sh status"
}

leave_run() { # choice status label-to-add tracker-note
  local issue="$1" choice="$2" status="$3" label="$4" note="$5" t= ds= dl= say= d= hcs="" hc="[]"
  t=$(g .ticket)
  ds=$(downstream "$t" | tr '\n' ' ')
  # shellcheck disable=SC2086
  hcs=$(checks_of "$t" $ds)
  hc=$(checks_json "$hcs")
  # The impact first, before anything changes.
  # shellcheck disable=SC2086
  echo "Impact: $(impact "$t" $ds)"
  REDIRECT=
  hold
  if [ -n "$label" ]; then
    gh issue edit "$t" -R "$(repo)" --add-label "$label" --remove-label in-run >/dev/null || die "could not relabel #$t"
  else
    gh issue edit "$t" -R "$(repo)" --remove-label in-run >/dev/null || die "could not relabel #$t"
  fi
  comment "$t" "Taken out of run $RUN_ID at exception gate #$issue by $BY: $note${WHY:+ Why: $WHY}"
  # shellcheck disable=SC2086
  send_back "$t" "was $status" $ds
  send_checks_back "$t" "was $status" "$hcs"
  close_exception "$issue" "$choice, by $BY: #$t leaves the run. $note"
  # The gate is closed, so it no longer holds the dependents sent back with the ticket.
  for d in $ds; do remove_blocker "$d" "$issue" || true; done
  # shellcheck disable=SC2086
  dl=$(json_list $ds)
  record_answer decided "$choice" outcome '.tickets[$t] |= (.status = $st | .pid = null)
    | reduce $ds[] as $d (.; .tickets[$d] |= (.status = "sent_back" | .pid = null | .sent_back = {from: $t, at: $now})
        | event({event: "sent-back", ticket: $d, from: $t}; $now))
    | '"$CHECKS_SENT_BACK" \
    --arg t "$t" --arg st "$status" --argjson ds "$dl" --argjson hc "$hc" \
    --argjson rec "$(jq -c --argjson ds "$dl" '{sent_back: $ds} + (if . == [] then {} else {human_checks_sent_back: map(.ticket)} end)' <<<"$hc")"
  say="#$t $status: it leaves the run"
  # shellcheck disable=SC2086
  [ -z "${ds// /}" ] || say="$say; $(hashes $ds) go back to needs-triage with it"
  [ "$hc" = "[]" ] || say="$say; $(checks_named "$hc") $(jq -r 'if length > 1 then "go" else "goes" end' <<<"$hc") back to needs-triage with it"
  echo "$say"
}

cmd_reslice() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2"
  shift 2
  parse_opts "$@"
  exception_only "$issue"
  leave_run "$issue" reslice resliced needs-triage "labelled needs-triage to be sliced again; the new tickets join a run through their own plan step."
}

cmd_drop() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2"
  shift 2
  parse_opts "$@"
  exception_only "$issue"
  leave_run "$issue" drop dropped "" "dropped from the run; the ticket stays open."
}

# repaired: the miscount (#151) opened this gate, and sweep.sh repair has
# since returned the ticket. Close it as resolved, not as an Artisan bypass.
cmd_repaired() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local issue="$2" t="" out='[]' d=""
  shift 2
  parse_opts "$@"
  exception_only "$issue"
  t=$(g .ticket)
  [ "$(get --arg t "$t" '.tickets[$t].status == "returned" and ((.tickets[$t].repaired // []) | length) > 0')" = true ] \
    || refuse "#$t was not returned by sweep.sh repair; answer gate #$issue with retry, reslice, take, drop, bypass or defer"
  REDIRECT=
  hold
  # Only the gate's issue stops blocking: the ticket is back in the run.
  for d in $(open_dependents); do
    if remove_blocker "$d" "$issue"; then
      out=$(jq -c --arg d "$d" --arg b "$issue" '. + [{dependent: $d, blocker: $b}]' <<<"$out")
    fi
  done
  close_exception "$issue" "Resolved by the repair, recorded by $BY: #$t's attempts completed but were counted as failed because the runner could not read claude's stream-json result (#151). sweep.sh repair took the failed attempts back and recorded #$t as returned with its cost; this gate is closed as resolved, not bypassed.${WHY:+ Why: $WHY}"
  record_answer resolved "resolved by repair" resolution '.' --arg t "$t" --argjson rec "{\"released\": $out}"
  echo "resolved #$issue: #$t is returned and goes on to verify and merge"
}

# send-back: the stranded tickets (what an older run left behind when it
# dropped or resliced a ticket) go back to triage, as a drop's dependents do.
cmd_send_back() {
  [ $# -ge 1 ] || usage
  open_run "$1"
  shift
  parse_opts "$@"
  local st= n= b= w= d= all=" " dl= hcs="" c="" a="" hc="[]" what="" how=""
  st=$(stranded)
  if [ "$st" = "[]" ]; then echo "No ticket is stranded."; return 0; fi
  hold
  for n in $(jq -r 'keys[]' <<<"$st"); do
    b=$(jq -r ".[$n].blocker" <<<"$st")
    w=
    for d in $(jq -r ".[$n].waiting[]" <<<"$st"); do
      case "$all" in *" $d "*) ;; *) w="$w $d"; all="$all$d " ;; esac
    done
    hcs=
    while read -r c a; do
      [ -n "$c" ] || continue
      case "$all" in *" $c "*) ;; *) hcs="$hcs$c $a"$'\n'; all="$all$c " ;; esac
    done <<<"$(jq -r ".[$n].checks[]? | \"\(.ticket) \(.for)\"" <<<"$st")"
    [ -n "$w" ] || [ -n "$hcs" ] || continue
    how="was $(get --arg b "$b" '.tickets[$b].status')"
    # shellcheck disable=SC2086
    [ -z "$w" ] || send_back "$b" "$how" $w
    send_checks_back "$b" "$how" "$hcs"
    # shellcheck disable=SC2086
    dl=$(json_list $w)
    hc=$(checks_json "$hcs")
    apply 'reduce $ds[] as $d (.; .tickets[$d] |= (.status = "sent_back" | .pid = null | .sent_back = {from: $b, at: $now})
        | event({event: "sent-back", ticket: $d, from: $b, by: $by}; $now))
      | '"$CHECKS_SENT_BACK" \
      --arg b "$b" --argjson ds "$dl" --arg by "$BY" --argjson hc "$hc"
    # shellcheck disable=SC2086
    what=$([ -z "$w" ] || hashes $w)
    [ "$hc" = "[]" ] || what="${what:+$what and }$(checks_named "$hc")"
    echo "sent back to needs-triage, out of the run: $what (stranded behind #$b)"
  done
}

# stranded <run-dir>: exit 0 with one line per dropped or resliced blocker
# when tickets in the run wait on it for good; 1 when none do.
cmd_stranded() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local st=
  st=$(stranded)
  [ "$st" != "[]" ] || return 1
  jq -r '.[] | "#\(.blocker) \(.status): "
    + ([(if .waiting == [] then empty else "\(.waiting | map("#" + .) | join(", ")) can'"'"'t start" end),
        ((.checks // [])[] | "Human check #\(.ticket) has no work of #\(.for) to check")] | join("; "))' <<<"$st"
  echo "send them back to triage: gate-action.sh send-back $RUN_DIR"
}

# ------------------------------------------------------- opening, syncing

# Why a ticket stopped, as the exception gate's kind of exception.
reason_of() { # ticket
  get --arg t "$1" '.tickets[$t] as $k
    | if ($k.blocked_reason // "") | test("suite failed") then "red-check"
      elif ($k.failures | length) >= (.plan.attempts_per_ticket + ($k.extra_attempts // 0)) then "gave-up"
      else "blocked" end'
}

exception_body() { # gate-json
  jq -rn --argjson gt "$1" --slurpfile s "$FILE" --arg tbl "$(exception_choices_table body)" '
    $s[0] as $s | $gt.ticket as $t | $s.tickets[$t] as $k | $s.plan.tickets[$t] as $p
    | ($gt.downstream // ($gt.dependents | map(.number))) as $dn
    | (if $dn == [] then "" else "; " + ($dn | map("#" + .) | join(", ")) + " (everything that depends on it, directly or through others) leave(s) the run with it and go back to `needs-triage`" end) as $leaves
    | "| Gate | Role needed | Ticket | Tickets blocked |",
    "|---|---|---|---|",
    "| exception | Engineering | #\($t) (\($p.title // "untitled")) | \(if $gt.dependents == [] then "nothing" else $gt.dependents | map("#" + .number + " (" + (.title // "untitled") + ")") | join(", ") end) |",
    "",
    "**\($gt.headline)**",
    "",
    "- **Problem:** \($p.expected_output // $p.title // "see the ticket")",
    "- **Why it stopped:** \($k.blocked_reason // ($k.failures | last | .reason) // "see the run")",
    "- **Cost so far:** $\($k.cost_usd // 0) against an estimate of $\($p.estimate_usd // "?")",
    "",
    "## Attempts",
    "",
    "| Attempt | Why it failed |",
    "|---|---|",
    (if ($k.failures // []) == [] then "| - | none failed: it was blocked |" else ($k.failures[] | "| \(.attempt) | \(.reason | gsub("\\|"; "/")) |") end),
    "",
    (if $k.suite.log then "The suite log: `\($k.suite.log)` in the run folder.\n" else empty end),
    "## Your call",
    "",
    "Exception gates are never removed. Decide what happens to the ticket, or bypass or defer the gate.",
    "",
    ($tbl | gsub("\\{\\{leaves\\}\\}"; $leaves) | split("\n") | map(select(. != "")) | .[])'
}

open_exception() { # decision-json
  local downstream_t= dec="$1" did= t= reason= title= headline= deps='[]' d= st= gate= num= url= body= attempts=
  did=$(jq -r .id <<<"$dec")
  t=$(jq -r .ticket <<<"$dec")
  [ "$(get --arg id "exception-$did" '[(.exception_gates // [])[] | select(.id == $id)] | length')" -eq 0 ] || return 0
  reason=$(reason_of "$t")
  attempts=$(get --arg t "$t" '.tickets[$t].attempts')
  case "$reason" in
    gave-up) title="Exception gate: run $RUN_ID gave up on #$t after $attempts attempts"
             headline="The run gave up on #$t after $attempts attempts." ;;
    red-check) title="Exception gate: #$t's check won't go green (run $RUN_ID)"
               headline="A check on #$t won't go green." ;;
    *) title="Exception gate: #$t is blocked (run $RUN_ID)"
       headline="#$t is blocked: $(get --arg t "$t" '.tickets[$t].blocked_reason // "see the run"')." ;;
  esac
  downstream_t=$(json_list $(downstream "$t"))
  # The in-run tickets still to run that #t blocks natively.
  for d in $(get '.plan.scope[]'); do
    [ "$d" != "$t" ] || continue
    st=$(get --arg d "$d" '.tickets[$d].status // ""')
    case "$st" in queued | blocked) ;; *) continue ;; esac
    if blocks "$d" "$t"; then
      deps=$(jq -c --arg d "$d" --arg title "$(get --arg d "$d" '.plan.tickets[$d].title // ""')" \
        '. + [{number: $d, title: (if $title == "" then null else $title end)}]' <<<"$deps")
    fi
  done
  # A guardrail that raised the exception (the decision's `guardrail`, and
  # `area`: the scope floor's is "scope-floor") is the one that opened it.
  gate=$(jq -nc --arg id "exception-$did" --arg t "$t" --arg title "$title" --arg headline "$headline" \
    --arg reason "$reason" --argjson deps "$deps" --argjson did "$did" --argjson dn "$downstream_t" --argjson dec "$dec" \
    '{id: $id, kind: "exception", reason: $reason, title: $title, headline: $headline, ticket: $t,
      tickets: [$t], decision: $did, dependents: $deps, downstream: $dn, cards: []}
     + (if ($dec.guardrail // "") == "" then {}
        else {guardrails: [{guardrail: $dec.guardrail} + (if ($dec.area // "") == "" then {} else {area: $dec.area} end)]} end)')
  num=$(gh issue list -R "$(repo)" --state open --label review-gate --json number,title \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  if [ -z "$num" ]; then
    body=$(exception_body "$gate")
    url=$(gh issue create -R "$(repo)" --title "$title" --label review-gate --body "$body") \
      || die "could not open the exception gate for #$t"
    num=${url##*/}
  fi
  for d in $(jq -r '.[].number' <<<"$deps"); do add_blocker "$d" "$num"; done
  apply '
    if any((.exception_gates // [])[]; .id == $g.id) then .
    else .exception_gates = ((.exception_gates // []) + [$g + {issue: $num, status: "open", opened_at: $now}])
      | .decisions |= map(if .id == $g.decision then . + {issue: $num, gate: $g.id} else . end)
      | event({event: "gate-opened", gate: $g.id, kind: "exception", issue: $num, tickets: [$g.ticket],
               dependents: ($g.dependents | map(.number))}; $now)
      | guardrails_fired($g; $now)
    end' --argjson g "$gate" --argjson num "$num"
  echo "opened #$num exception-$did"
}

cmd_sync() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local issue= state= dec=
  hold
  # An exception gate closed by hand on the tracker is bypassed by whoever closed it.
  for issue in $(get '(.exception_gates // [])[] | select(.status == "open" or .status == "deferred") | .issue'); do
    state=$(gh api "repos/$(repo)/issues/$issue" 2>/dev/null | jq -r '.state // empty' | tr 'A-Z' 'a-z') || continue
    [ "$state" = closed ] || continue
    find_gate "$issue"
    BY="Artisan (closed on the tracker)" WHY= NOTES= REDIRECT=
    bypass_release
    bypass_record
  done
  # Every exception decision waiting without its gate, for a ticket still blocked.
  while IFS= read -r dec; do
    [ -n "$dec" ] || continue
    open_exception "$dec"
  done < <(jq -c '. as $s | .decisions[] | select(.kind == "exception" and .status == "waiting"
                    and .issue == null and .ticket != null and $s.tickets[.ticket].status == "blocked")' "$FILE")
}

# ------------------------------------------------------------------ parking

cmd_parked() {
  open_run "${1:-}"
  local record=0 t= tracker='{}' line=
  [ "${2:-}" != --record ] || record=1
  # Quick refusals from the state file alone: work still moving, work ready,
  # a decision that isn't a gate, or no gate open.
  [ "$(get "$STATE_JQ_DEFS"'
    ([.tickets[] | select(.status == "in_flight" or .status == "returned")] | length) == 0
    and ((.frontier // []) | length) == 0
    and (waiting_non_gate_decisions | map(select(.kind != "usage")) | length) == 0
    and ([(.review_gates // [])[], (.exception_gates // [])[] | select(.status == "open")]
         + [.tickets[] | select(.risk_gate.status? == "waiting")] | length) > 0')" = true ] || return 1
  for t in $(get "$STATE_JQ_DEFS"' . as $s | .plan.scope[] as $t | select(.tickets[$t].status == "queued" and ($s | is_human_check($t) | not)) | $t'); do
    tracker=$(jq -c --arg t "$t" --argjson b "$(blockers_of "$t" || echo null)" \
      '. + {($t): ($b // null | if . == null then null else [.[] | select((.state | ascii_downcase) == "open") | .number | tostring] end)}' <<<"$tracker")
  done
  line=$(get "$STATE_JQ_DEFS"'
    . as $s
    | [($s.review_gates // [])[], ($s.exception_gates // [])[] | select(.status == "open")] as $open
    | ($open | map(.issue | tostring)) as $gi
    | [$s.tickets | to_entries[] | select(.value.risk_gate.status? == "waiting") | .key] as $risk
    | out_of_run as $o
    | [$s.plan.scope[] | select(($s.tickets[.].status) as $st | $st != "merged" and $st != "closed" and ($o | index($st) | not))
        | select(. as $t | $s | is_human_check($t) | not)] as $left
    | [($s.exception_gates // [])[] | select(.status == "open") | .ticket] as $held0
    | (reduce range(0; ($left | length) + 1) as $_ ($held0;
        . as $h | ($h + [$left[] | select(. as $t | $s.tickets[$t].status == "queued" and $tr[$t] != null
            and any($tr[$t][]; . as $b | ($gi | index($b)) or ($h | index($b)) or ($risk | index($b))
                                         or ($s | gate_holds($b)))) ]) | unique)) as $held
    | if $tr | any(.[]; . == null) then empty
      elif ($left | length) == 0 or any($left[]; . as $t | $held | index($t) | not) then empty
      else
        # Only the reviews that hold a ticket left count.
        ([$left[] | $tr[.] // [] | .[]] | unique) as $bl
        | [$open[] | select((.kind == "exception" and (.ticket as $t | $held0 | index($t)))
                           or ((.issue | tostring) as $i | $bl | index($i)))] as $holding
        | [$risk[] | select(. as $r | $bl | index($r))] as $riskh
        | (($holding | length) + ($riskh | length)) as $n
        | "parked: waiting on \($n) review\(if $n == 1 then "" else "s" end): "
          + ([$holding[] | "\(.title) #\(.issue)"] + [$riskh[] | "risk gate on #\(.)"] | join(", "))
          + "; \($left | length) ticket\(if ($left | length) == 1 then " waits" else "s wait" end) behind \(if $n == 1 then "it" else "them" end): "
          + ($left | map("#" + .) | join(", "))
      end' --argjson tr "$tracker")
  [ -n "$line" ] || return 1
  echo "$line"
  if [ "$record" -eq 1 ]; then
    # The last event that is not the usage park's own (#72 shares the "parked"
    # event, with a reason): a usage park logged in between must not make the
    # same review park log again.
    apply '([.events[] | select(.reason != "usage" and .event != "resume-asked" and .event != "ceiling-raised")] | last) as $last
      | if $last.event == "parked" and $last.detail == $line then .
        else event({event: "parked", reason: "reviews", detail: $line}; $now) end' --arg line "$line"
  fi
}

# --------------------------------------------------------- chat and lists

cmd_chat() {
  open_run "${1:-}"
  local any=
  any=$(get '[(.exception_gates // [])[] | select(.status == "open" or .status == "deferred")] | length')
  if [ "$any" -eq 0 ]; then echo "No exception gate is open."; return 0; fi
  get '(.exception_gates // [])[] | select(.status == "open" or .status == "deferred")
    | "\(.title) #\(.issue)\(if .status == "deferred" then " (deferred)" else "" end): \(.headline) Holds \(if .dependents == [] then "nothing" else .dependents | map("#" + .number) | join(", ") end)."'
  echo
  exception_choices_table chat
}

cmd_list() {
  open_run "${1:-}"
  echo "| Gate | Issue | Kind | Tickets | Status | Holds |"
  echo "|---|---|---|---|---|---|"
  get '[(.review_gates // [])[], (.exception_gates // [])[]] | sort_by(.opened_at // 0)[]
    | "| \(.title) | #\(.issue) | \(.kind // "slice") | \(.tickets | map("#" + .) | join(", ")) | \(.status) | \(if (.dependents // []) == [] then "-" else (.dependents | map("#" + .number) | join(", ")) end) |"'
}

cmd_deferred() {
  open_run "${1:-}"
  local sel=""
  sel=$(state_deferred_gates_jq)
  if [ "$(get "$sel | length")" -eq 0 ]; then
    echo "No gate is deferred."
    return 0
  fi
  echo "| Gate | Issue | Kind | Deferred by | Why | Went ahead |"
  echo "|---|---|---|---|---|---|"
  get "$sel"'[]
    | "| \(.title) | #\(.issue) | \(.kind) | \(.by) | \(.why // "-") | \(if .dependents == [] then "-" else (.dependents | map("#" + .number) | join(", ")) end) |"'
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  approve) cmd_approve "$@" ;;
  redirect) cmd_redirect "$@" ;;
  bypass) cmd_bypass "$@" ;;
  defer) cmd_defer "$@" ;;
  retry) cmd_retry "$@" ;;
  reslice) cmd_reslice "$@" ;;
  take) cmd_take "$@" ;;
  drop) cmd_drop "$@" ;;
  repaired) cmd_repaired "$@" ;;
  send-back) cmd_send_back "$@" ;;
  stranded) cmd_stranded "$@" ;;
  sync) cmd_sync "$@" ;;
  parked) cmd_parked "$@" ;;
  chat) cmd_chat "$@" ;;
  list) cmd_list "$@" ;;
  deferred) cmd_deferred "$@" ;;
  *) usage ;;
esac
