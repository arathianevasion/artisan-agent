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
#   gate.sh change <run-dir> <issue> <card> <choice> [--why W] [--by NAME]
#       "change" on one card: a rework ticket in this run (in scope, queued,
#       a native blocker of the slice's dependents), the decision recorded.
#       Prints the rework ticket's number.
#   gate.sh guardrail <run-dir> <issue> <card> <team|product|individual>
#                     <ticket|area|everywhere> [--area A] [--why W] [--by NAME]
#       "make it a guardrail" on one card: kept, with a guardrail lesson
#       for the retro.
#   gate.sh approve <run-dir> <issue> [--by NAME] [--why W]
#                   [--confidence firm|provisional]
#       "keep all": every card not yet decided is kept, the decisions are
#       posted on the issue, the issue closes and the dependents are free to
#       dispatch in the next wave.
#   gate.sh holds <run-dir> <ticket>
#       prints "held" when the ticket is in a slice gate that is due and not
#       yet approved (its dependents wait), else "free". A caller treats
#       anything else (an error) as held.
#
# Every decision recorded carries its job and who made it (--by, default
# Artisan); the card's own job for a card, job 13 for the gate.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held (sync and
# open only; the Artisan's actions are kept and folded in later), 6 refused
# (no such open gate or card, or the card is already decided).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq, python3 and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
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
  [ $# -eq 2 ] || usage
  open_run "$1"
  case "$(jget 'gate_holds($t)' --arg t "$2")" in
    true) echo held ;;
    false) echo free ;;
    *) die "could not read the gates of #$2" ;;
  esac
}

# --------------------------------------------------------------------- open

# The gate's view for packet.py: the gate, its dependents, the state, and the
# guardrails and other provisional cards as their scripts print them.
build_view() { # id dependents-json
  local def="$1" deps="$2" guard prov t
  gates_dir >/dev/null
  guard=$("$SCRIPT_DIR/guardrails.sh" table --run-dir "$RUN_DIR" 2>"$RUN_DIR/gates/.guardrails.err") \
    || guard="Could not be read: $(tr '\n' ' ' <"$RUN_DIR/gates/.guardrails.err")"
  prov=$("$SCRIPT_DIR/questions.sh" provisional "$RUN_DIR" 2>/dev/null) || prov=""
  # The slice's own decisions are its cards; the listing keeps the rest.
  for t in $(jq -r '.tickets[]' <<<"$def"); do
    prov=$(printf '%s\n' "$prov" | grep -v "^| #$t |" || true)
  done
  jq -n --argjson g "$def" --argjson deps "$deps" --slurpfile s "$FILE" \
    --arg guard "$guard" --arg prov "$prov" --arg run "$RUN_ID" '
    {gate: ($g + {kind: "slice", title: "Slice gate: \($g.slice) (run \($run))", dependents: $deps}),
     state: $s[0], guardrails: $guard, provisional: $prov}'
}

# The in-run tickets still to merge that a ticket of the gate blocks natively.
dependents() { # def
  local def="$1" repo t blockers out='[]'
  repo=$(get '.repo')
  for t in $(get '.plan.scope[]'); do
    jq -e --arg t "$t" '.tickets | index($t)' <<<"$def" >/dev/null && continue
    case "$(get --arg t "$t" '.tickets[$t].status // ""')" in merged|closed|deferred) continue ;; esac
    blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
      || die "could not read the blockers of #$t from the tracker"
    if jq -e --argjson d "$def" 'any(.[]; (.number | tostring) as $n | $d.tickets | index($n))' <<<"$blockers" >/dev/null; then
      out=$(jq -c --arg t "$t" --arg title "$(get --arg t "$t" '.plan.tickets[$t].title // ""')" \
        '. + [{number: $t, title: (if $title == "" then null else $title end)}]' <<<"$out")
    fi
  done
  printf '%s\n' "$out"
}

issue_id() { local j; j=$(gh api "repos/$(get '.repo')/issues/$1") && jq -er .id <<<"$j"; }

# blocker blocks ticket natively, once.
add_blocker() { # ticket blocker-issue blocker-id
  local repo
  repo=$(get '.repo')
  gh api "repos/$repo/issues/$1/dependencies/blocked_by" \
    | jq -e --arg b "$2" 'any(.[]; (.number | tostring) == $b)' >/dev/null && return 0
  gh api --method POST "repos/$repo/issues/$1/dependencies/blocked_by" -F "issue_id=$3" >/dev/null \
    || die "could not make #$2 a blocker of #$1"
}

cmd_open() {
  [ $# -eq 2 ] || usage
  open_run "$1"
  local id="$2" def rec dir view body title repo num url d gid
  rec=$(recorded "$id")
  if [ -n "$rec" ]; then jq -r .issue <<<"$rec"; return 0; fi
  def=$(gate_def "$id")
  [ -n "$def" ] || state_die 6 "gate.sh: no slice gate $id in the plan"
  [ "$(jget 'gate_due($g)' --argjson g "$def")" = true ] \
    || state_die 6 "gate.sh: $id is not due: not every ticket of its slice has merged"
  dir=$(gates_dir)
  repo=$(get '.repo')
  # Built once and kept, so a call that crashed after opening the issue
  # opens nothing new and shows the same packet.
  view="$dir/$id.view.json"
  if [ ! -s "$view" ]; then
    build_view "$def" "$(dependents "$def")" >"$view.tmp"
    jq --argjson cards "$(PACKET cards <"$view.tmp")" '.gate.cards = $cards' "$view.tmp" >"$view.tmp2"
    mv "$view.tmp2" "$view"
    rm -f "$view.tmp"
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
  apply '
    if any((.review_gates // [])[]; .id == $v.gate.id) then .
    else
      ($v.gate.cards | length) as $n
      | ([$v.gate.tickets[] as $t | $v.state.tickets[$t].evidence.unsure[]?] | length) as $u
      | ($v.provisional | split("\n") | map(capture("^\\| #(?<t>[^ |]+) \\|").t) ) as $other
      | .review_gates = ((.review_gates // []) + [{
          id: $v.gate.id, kind: "slice", slice: $v.gate.slice, title: $v.gate.title,
          role: $v.gate.role, issue: $num, tickets: $v.gate.tickets,
          dependents: $v.gate.dependents, cards: $v.gate.cards,
          status: "open", opened_at: $now, decisions: [], reworks: []}])
      | .provisional_shown = (((.provisional_shown // []) + $v.gate.tickets + $other) | unique)
      | .decisions += [{id: ((.decisions | length) + 1), kind: "review-gate", gate: $v.gate.id, issue: $num,
          question: "\($v.gate.title) is #\($num): \($n) decision(s), \($u) uncertaint\(if $u == 1 then "y" else "ies" end); it holds \(if $v.gate.dependents == [] then "nothing" else ($v.gate.dependents | map("#" + .number) | join(", ")) end). Keep all, or name one to change (gate.sh chat).",
          status: "waiting", at: $now}]
      | event({event: "gate-opened", gate: $v.gate.id, issue: $num, tickets: $v.gate.tickets,
               dependents: ($v.gate.dependents | map(.number))}; $now)
      | event({event: "provisional-shown"}; $now)
    end' --argjson num "$num" --argjson v "$(cat "$view")"
  echo "$num"
}

# ------------------------------------------------------------ the Artisan acts

# An open gate by issue number: sets GATE (its recorded JSON).
GATE=
open_gate() { # issue
  GATE=$(recorded "$1")
  [ -n "$GATE" ] || state_die 6 "gate.sh: #$1 is not a gate of this run"
  [ "$(jq -r .status <<<"$GATE")" = open ] || state_die 6 "gate.sh: gate #$1 is $(jq -r .status <<<"$GATE"), not open"
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
  local c
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
  ((.review_gates // []) | map(.id) | index($a.gate)) as $i
  | if $i == null or any(.review_gates[$i].decisions[]; .action == $a.key) then .
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
          | event({event: "rework", ticket: $r, from: $f, gate: $a.gate, card: $a.decisions[0].card}; $now)
        elif $a.type == "approve" then
          .review_gates[$i].status = "approved" | .review_gates[$i].approved_at = $now
          | .decisions |= map(if .kind == "review-gate" and .gate == $a.gate and .status == "waiting"
              then .status = "decided" | .choice = "approve" | .by = $a.by | .job = 13 | .decided_at = $now
              else . end)
          | (if $a.closed_on_tracker then
               .review_gates[$i].closed_on_tracker = true | .review_gates[$i].carried = $a.carried
             else . end)
          | event({event: "gate-approved", gate: $a.gate, issue: .review_gates[$i].issue, by: $a.by}
                  + (if $a.closed_on_tracker then {closed_on_tracker: true, carried: $a.carried} else {} end); $now)
        else
          event({event: "gate-decision", gate: $a.gate, card: $a.decisions[0].card, by: $a.by}; $now)
        end
    end'

# record action-file: into the state file now if the lock can be had, else
# kept in gates/pending/ for the next sync (the orchestrator may hold it).
# fold action-file: one locked, one-step write of the action; the file goes
# once it is in. Returns the write's status (3: the lock is held).
fold() {
  local f="$1" st=0
  ( apply "$ACTION_FILTER" --argjson a "$(cat "$f")" ) 2>"$f.err" || st=$?
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
  local dir f
  dir=$(gates_dir)
  f="$dir/pending/$1.$(date +%s).$$.$RANDOM.json"
  printf '%s\n' "$f"
}

parse_opts() { # sets BY WHY CONF AREA
  BY=Artisan WHY= CONF= AREA=
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; BY=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; WHY=$2; shift 2 ;;
      --confidence) [ $# -ge 2 ] || usage; CONF=$2; shift 2 ;;
      --area) [ $# -ge 2 ] || usage; AREA=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$BY" ] || usage
  case "$CONF" in ""|firm|provisional) ;; *) usage ;; esac
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
  local issue="$2" n="$3" choice="$4" card repo dec num url gid t f title
  shift 4
  parse_opts "$@"
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
  for d in $(jq -r '.dependents[].number' <<<"$GATE"); do add_blocker "$d" "$num" "$gid"; done
  dec=$(decision_from "$card" change "$choice" | jq -c --argjson r "$num" '. + {rework: ($r | tostring)}')
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
  local issue="$2" n="$3" level="$4" reach="$5" card dec f
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
  local issue="$2" gid decided keeps f repo
  shift 2
  parse_opts "$@"
  open_gate "$issue"
  gid=$(jq -r .id <<<"$GATE")
  repo=$(get '.repo')
  decided=$(decided_cards "$gid" | jq -R 'tonumber? // empty' | jq -sc .)
  keeps=$(jq -c --argjson done "$decided" --arg by "$BY" --arg g "$gid" '
    [.cards[] | select(.card as $c | $done | index($c) | not)
     | {job: (.job // 13), choice, by: $by, card, ticket, gate: $g, outcome: "keep", original: {choice, by}}]' <<<"$GATE")
  f=$(new_action "$gid")
  jq -n --arg key "$(basename "$f" .json)" --arg g "$gid" --arg by "$BY" --argjson keeps "$keeps" \
    --arg why "$WHY" --arg conf "$CONF" '
    {key: $key, type: "approve", gate: $g, by: $by,
     decisions: ($keeps + [{job: 13, choice: "approve the slice", by: $by, gate: $g, outcome: "approve"}
       + (if $why != "" then {why: $why} else {} end) + (if $conf != "" then {confidence: $conf} else {} end)])}' >"$f.tmp"
  mv "$f.tmp" "$f.new"
  decisions_comment "$gid" "$f.new" >"$f.comment.md"
  gh issue comment "$issue" -R "$repo" --body-file "$f.comment.md" >/dev/null || die "could not comment on #$issue"
  gh issue close "$issue" -R "$repo" >/dev/null || die "could not close #$issue"
  mv "$f.new" "$f"
  rm -f "$f.comment.md"
  record "$f"
  echo "approved #$issue: $(jq -r 'if .dependents == [] then "nothing in the run waited on it" else (.dependents | map("#" + .number) | join(", ")) + " can dispatch in the next wave" end' <<<"$GATE")"
}

# --------------------------------------------------------------------- sync

cmd_sync() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local f st id issue repo state carried
  # Actions the Artisan took while the lock was held.
  for f in "$RUN_DIR"/gates/pending/*.json; do
    [ -f "$f" ] || continue
    fold "$f" || { st=$?; cat "$f.err" >&2; exit "$st"; }
  done
  # A gate closed on the tracker by hand is approved by whoever closed it.
  repo=$(get '.repo')
  for issue in $(get '(.review_gates // [])[] | select(.status == "open") | .issue'); do
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

<!-- artisan-agent:gate-closed-by-hand carried=$carried -->" >/dev/null 2>&1 || true
    fi
  done
  local num
  for id in $(cmd_due "$RUN_DIR"); do
    num=$(cmd_open "$RUN_DIR" "$id") || exit $?
    echo "opened #$num $id"
  done
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
  local n
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
  local g="$1" f
  f="$RUN_DIR/gates/$(jq -r .id <<<"$g").view.json"
  if [ -f "$f" ]; then
    jq --slurpfile s "$FILE" --argjson g "$g" '.state = $s[0] | .gate.issue = $g.issue' "$f"
  else
    jq -n --slurpfile s "$FILE" --argjson g "$g" '{gate: ($g + {kind: "slice"}), state: $s[0], guardrails: "", provisional: ""}'
  fi
}

cmd_chat() {
  open_run "${1:-}"
  local g first=1
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
  local rec def
  rec=$(recorded "$2")
  if [ -n "$rec" ] && [ -f "$RUN_DIR/gates/$(jq -r .id <<<"$rec").md" ]; then
    cat "$RUN_DIR/gates/$(jq -r .id <<<"$rec").md"
    return 0
  fi
  def=$(gate_def "$2")
  [ -n "$def" ] || state_die 6 "gate.sh: no gate $2"
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
  *) usage ;;
esac
