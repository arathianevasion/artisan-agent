#!/usr/bin/env bash
# Decisions a worker may not make: the question ticket, what it does to the
# worker's ticket, and how the answer comes back. The rules, the ticket's
# shape and the orchestrator's steps:
# ${CLAUDE_PLUGIN_ROOT}/references/worker-questions.md. State file:
# references/state-file.md.
#
# Usage, from a worker:
#   questions.sh file --ticket T --criterion C --question Q --option O
#                [--option O ...] --recommendation R (--blocking | --split)
#                [--repo owner/name]
#       file a needs-triage ticket (question, options, recommendation and the
#       criterion that triggered it: 1-7, or always-ask for a project
#       "Always ask" item) and log it as a "question" finding in
#       $ARTISAN_FINDINGS_FILE (when set). --blocking: the worker's own ticket
#       can't finish without the answer; --split: the worker finishes
#       the rest. Prints the new ticket's number.
#   questions.sh file --ticket T --criterion 8 --case C --harm H
#                --recommendation R (--blocking | --split | --non-blocking)
#                [--raised-by plan|worker|verifier|gate|finding] [--from F]
#                [--run <run-dir>] [--at WHERE] [--repo owner/name]
#       an open decision in ticket T (references/open-decisions.md): the case
#       (incomplete, misaligned, invented or adr), the concrete harm and one
#       recommendation, nothing more; refused without a case or a harm. The
#       body records where it was raised ("Raised at:", default worker;
#       --at names the place, as a gate's triage names the gate and item).
#       --blocking only from T's own worker; --non-blocking files it without
#       blocking T, as --raised-by finding (with --from, the ticket whose
#       worker found it) must. Works with no run (the plan step). --run logs
#       guardrail-fired "open-decision"; a worker's findings line carries
#       case, raised_by and about, and the sweep logs it.
#
# Usage, from the orchestrator and the Engineering chat:
#   questions.sh block <run-dir> <ticket>
#       a blocked ticket whose worker filed a blocking question: add the
#       question ticket as a native blocker of the worker's ticket on the
#       tracker, record it on the ticket, queue a "question" decision. The
#       wave carries on. 1: no blocking question was filed for it.
#   questions.sh sync <run-dir>
#       read the tracker for every open question. Prints one line each:
#       "answered #<t> #<q>" (its Answer: comment; once every question of
#       a ticket is answered the ticket is queued again and its next worker
#       is told the answers), "deferred #<t> #<q>" (triage deferred it:
#       a "defer-question" decision asks the Artisan whether to pull the
#       ticket from the run or let it carry on), "closed #<t> #<q>" (closed
#       with no Answer: line: a "question" decision), "open #<t> #<q>".
#       An open decision's rulings too: "rejected #<t> #<q>" (Reject: the
#       ticket leaves the run back to needs-triage, in-run off, status
#       sent_back, its dependents waiting), "rejected #<t> #<q> follow-up
#       #<n>" (Reject after its work merged: a follow-up needs-triage ticket,
#       nothing pulled; closed without a merge, only the record changes),
#       "reject-waits #<t> #<q>" (an attempt still going),
#       "added #<t> #<q> #<n>" (Add ticket: unblocked and queued with the
#       answer "not covered here"). An open decision a finding raised in
#       <t> (filed --non-blocking; the sweep puts it on <t>) holds <t> only
#       once a comment line "Add the block:" asks: "blocked #<t> #<q>" (the
#       native edge on, a queued <t> blocked, a question decision), once;
#       until then a Defer only marks it deferred and a Discard prints
#       "discarded #<t> #<q>", nothing queued for the Artisan. Every ruling's two verdicts ("Took the
#       recommendation:", "Needed the Decision chat:") go on the question
#       and in a "ruled" event, once per ruling.
#   questions.sh deferred <run-dir> <ticket> (pull | carry)
#       the Artisan's answer to a defer-question decision. pull: the ticket
#       defers with the question (label deferred, Return condition:
#       blocked-by #<q>, off the run's scope, status "deferred"). carry: the
#       blocking edge comes off, "not now" is the answer, the ticket is
#       queued again.
#   questions.sh list <run-dir>
#       the run's questions as a Markdown table.
#   questions.sh provisional <run-dir> [--shown]
#       the "provisional" decision cards (easy-to-reverse taste, criteria 4, 6
#       and 7) from tickets merged in this run, as a Markdown table, for the
#       next slice gate's packet. Only cards not yet shown; --shown records
#       them as shown, so the next gate doesn't repeat them.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held by another
# live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "questions.sh: $*"; }

# --------------------------------------------------------------------- file

cmd_file() {
  local ticket="" criterion="" question="" rec="" repo="" mode="" case_="" harm="" raised_by="" from="" run_dir=""
  local -a options=()
  local harm_set=0
  local at=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ticket) ticket=${2:-}; shift 2 ;;
      --criterion) criterion=${2:-}; shift 2 ;;
      --question) question=${2:-}; shift 2 ;;
      --option) options+=("${2:-}"); shift 2 ;;
      --recommendation) rec=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --case) case_=${2:-}; shift 2 ;;
      --harm) harm=${2:-}; harm_set=1; shift 2 ;;
      --raised-by) raised_by=${2:-}; shift 2 ;;
      --from) from=${2:-}; shift 2 ;;
      --run) run_dir=${2:-}; shift 2 ;;
      --at) at=${2:-}; shift 2 ;;
      --blocking) mode=blocking; shift ;;
      --split) mode=split; shift ;;
      --non-blocking) mode=non-blocking; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$ticket" ] && [ -n "$mode" ] || usage
  if [ "$criterion" = 8 ]; then
    file_open_decision
    return
  fi
  [ -n "$question" ] && [ -n "$rec" ] || usage
  [ "${#options[@]}" -ge 2 ] || die "a question needs at least two options"
  case "$criterion" in
    [1-7]|always-ask) ;;
    *) die "--criterion is 1-8 or always-ask" ;;
  esac
  [ -z "$case_$raised_by$from$run_dir" ] && [ "$harm_set" -eq 0 ] \
    || die "--case, --harm, --raised-by, --from and --run are criterion 8's (an open decision)"
  [ -z "$at" ] || die "--at is criterion 8's (an open decision)"
  [ "$mode" != non-blocking ] || die "--non-blocking is criterion 8's (an open decision); a question is --blocking or --split"
  ticket=${ticket#\#}
  local opt="" body="" title="" i=0 crit_text="" effect="" run_note="" num=""
  if [ "$criterion" = always-ask ]; then crit_text="an \"Always ask\" item"; else crit_text="criterion $criterion"; fi
  if [ "$mode" = blocking ]; then
    effect="Blocked by this question until it is answered."
  else
    effect="The worker finished the rest; this question was split off."
  fi
  [ -z "${ARTISAN_RUN_ID:-}" ] || run_note=" (run $ARTISAN_RUN_ID)"
  title="Question from #$ticket: $question"
  body="> *Filed by a worker during a run: an agent-filed question, not yet triaged.*

Asked by the worker of #$ticket$run_note.

## Question

$question

## Options
"
  i=0
  for opt in "${options[@]}"; do
    i=$((i + 1))
    body="$body
$i. $opt"
  done
  body="$body

## Recommendation

$rec

## Criterion

$criterion: $crit_text (the plugin's controversy criteria, 1-8, plus the project's \"Always ask\" items).

## Effect on #$ticket

$effect

Answer by commenting \`Answer: <the decision>\` and closing this ticket. Deferring it asks whether to pull #$ticket from the run or let it carry on."
  new_question_ticket
  if [ -n "${ARTISAN_FINDINGS_FILE:-}" ]; then
    mkdir -p "$(dirname "$ARTISAN_FINDINGS_FILE")"
    jq -cn --arg t "$num" --arg by "$ticket" --arg c "$criterion" --arg q "$question" \
      --argjson blocking "$([ "$mode" = blocking ] && echo true || echo false)" \
      '{kind: "question", ticket: $t, asked_by: $by, criterion: $c, blocking: $blocking,
        title: ("Question #" + $t + ": " + $q), why: ("needs the Artisan'"'"'s decision (criterion " + $c + ")"), blocks: []}' \
      >>"$ARTISAN_FINDINGS_FILE"
  fi
  printf '%s\n' "$num"
}

# new_question_ticket: files $title and $body as a needs-triage ticket (in
# $repo when set) and sets num to its number.
new_question_ticket() {
  local url=""
  local -a rargs=()
  [ -z "$repo" ] || rargs=(-R "$repo")
  url=$("$SCRIPT_DIR/tracker.sh" new-issue --kind question -- ${rargs[@]+"${rargs[@]}"} --title "$title" --body-file - <<<"$body" --label needs-triage) \
    || die "could not file the question ticket"
  num=${url##*/}
  state_is_uint "$num" || die "gh gave no issue number: $url"
}

# file_open_decision: criterion 8 (references/open-decisions.md). The case,
# the harm and one recommendation, nothing more; where it was raised; logs
# guardrail-fired "open-decision" when --run names the run (a worker's is
# logged by the sweep, from its finding). Reads cmd_file's locals.
file_open_decision() {
  local case_text="" raiser="" effect="" run_note="" run_id="" short="" title="" body="" num=""
  [ -n "$case_" ] || die "an open decision names its case: --case incomplete, misaligned, invented or adr"
  # Blank is none: a harm or recommendation of only spaces names nothing.
  case "$harm" in *[![:space:]]*) ;; *) harm="" ;; esac
  case "$rec" in *[![:space:]]*) ;; *) rec="" ;; esac
  [ -n "$harm" ] || die "an open decision names its concrete harm (--harm); without one it is the execution agent's call"
  [ -n "$rec" ] || die "an open decision carries one recommendation (--recommendation)"
  [ -z "$question" ] && [ "${#options[@]}" -eq 0 ] \
    || die "an open decision holds the case, the harm and one recommendation, nothing more: no --question or --option"
  case "$case_" in
    incomplete) case_text="the feature would be incomplete: a user could reach something that doesn't do what it offers" ;;
    misaligned) case_text="the feature would be misaligned: no reading fits the spec's user story, or it contradicts the spec, another ticket or a recorded decision" ;;
    invented) case_text="it would invent user-facing behaviour the ticket doesn't describe" ;;
    adr) case_text="it settles something that needs an ADR" ;;
    *) die "--case is incomplete, misaligned, invented or adr" ;;
  esac
  [ -n "$raised_by" ] || raised_by=worker
  ticket=${ticket#\#}
  from=${from#\#}
  case "$raised_by" in
    worker) raiser="the worker of #$ticket" ;;
    plan) raiser="the plan step" ;;
    verifier) raiser="the verifier of #$ticket" ;;
    gate) raiser="a gate reviewer" ;;
    finding)
      [ -n "$from" ] || die "--raised-by finding names the ticket whose worker found it: --from <ticket>"
      raiser="the worker of #$from, in another ticket" ;;
    *) die "--raised-by is plan, worker, verifier, gate or finding" ;;
  esac
  [ "$raised_by" = finding ] || [ -z "$from" ] || die "--from is for --raised-by finding"
  [ "$mode" != blocking ] || [ "$raised_by" = worker ] \
    || die "only a worker blocks on an open decision, and only its own ticket; file it --split or --non-blocking"
  [ "$raised_by" != finding ] || [ "$mode" = non-blocking ] \
    || die "an open decision found in another ticket is filed --non-blocking: it never blocks that ticket"
  [ "$raised_by" != worker ] || [ "$mode" != non-blocking ] \
    || die "a worker's open decision in its own ticket is --blocking or --split; one in another ticket is --raised-by finding --from <yours> --non-blocking"
  case "$mode" in
    blocking) effect="Blocked by this open decision until it is ruled on." ;;
    split) effect="The rest of #$ticket carries on; this open decision was split off." ;;
    non-blocking) effect="Filed without blocking #$ticket; a ruling that needs the block adds it." ;;
  esac
  if [ -n "$run_dir" ]; then
    open_run "$run_dir"
    run_id=$(get .run_id)
  else
    run_id=${ARTISAN_RUN_ID:-}
  fi
  [ -z "$run_id" ] || run_note=" (run $run_id)"
  short=$(printf '%s' "$harm" | head -n 1)
  [ "${#short}" -le 100 ] || short="${short:0:97}..."
  title="Open decision in #$ticket: $short"
  body="> *Filed by $raiser: an open decision, not yet triaged.*

Raised at: $raised_by, by $raiser$run_note${at:+, at $at}.

## Case

$case_: $case_text.

## Harm

$harm

## Recommendation

$rec

## Criterion

8: an open decision (the plugin's controversy criteria; the cases and the harm bar: references/open-decisions.md).

## Effect on #$ticket

$effect

Answer by commenting \`Answer: <the decision>\` and closing this ticket."
  new_question_ticket
  if [ -n "$run_dir" ]; then
    apply 'event({event: "guardrail-fired", guardrail: "open-decision", ticket: $t, raised_by: $r, case: $c,
             question: $q, areas: ticket_areas([$t])} + (if $f == "" then {} else {from: $f} end); $now)' \
      --arg t "$ticket" --arg r "$raised_by" --arg c "$case_" --arg q "$num" --arg f "$from"
  fi
  if [ -n "${ARTISAN_FINDINGS_FILE:-}" ]; then
    mkdir -p "$(dirname "$ARTISAN_FINDINGS_FILE")"
    jq -cn --arg t "$num" --arg by "${from:-$ticket}" --arg about "$ticket" --arg c "$case_" --arg r "$raised_by" \
      --arg h "$short" --argjson blocking "$([ "$mode" = blocking ] && echo true || echo false)" \
      --argjson logged "$([ -n "$run_dir" ] && echo true || echo false)" \
      '{kind: "question", ticket: $t, asked_by: $by, about: $about, criterion: "8", case: $c, raised_by: $r,
        blocking: $blocking, guardrail_logged: $logged,
        title: ("Open decision #" + $t + ": " + $h), why: "an open decision for the Decision chat (criterion 8)", blocks: []}' \
      >>"$ARTISAN_FINDINGS_FILE"
  fi
  printf '%s\n' "$num"
}

# ---------------------------------------------------------------- tracker

repo_of() { get .repo; }

issue_id() { gh api "repos/$(repo_of)/issues/$1" | jq -r .id; }

add_blocker() { # blocked blocker
  local id= err=
  id=$(issue_id "$2") || die "could not read #$2 from the tracker"
  if ! err=$(gh api --method POST "repos/$(repo_of)/issues/$1/dependencies/blocked_by" -F "issue_id=$id" 2>&1 >/dev/null); then
    case "$err" in *already*|*422*) ;; *) die "could not mark #$1 blocked by #$2: $err" ;; esac
  fi
}

remove_blocker() { # blocked blocker
  local id=
  id=$(issue_id "$2") || die "could not read #$2 from the tracker"
  gh api --method DELETE "repos/$(repo_of)/issues/$1/dependencies/blocked_by/$id" >/dev/null 2>&1 \
    || die "could not take #$2 off #$1's blockers"
}

# ------------------------------------------------------------------- block

cmd_block() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  [ "$(get --arg t "$t" '.tickets[$t].status // "none"')" = blocked ] || die "#$t is not blocked"
  local qs= q=
  qs=$(get --arg t "$t" '
    [.findings[]? | select(.from == $t and .kind == "question" and .blocking == true) | .ticket] as $f
    | (.tickets[$t].questions // [] | map(.ticket)) as $have
    | [$f[] | select(. as $x | $have | index($x) | not)] | unique[]')
  if [ -z "$qs" ]; then
    [ "$(get --arg t "$t" '[.tickets[$t].questions[]? | select(.blocking == true and .state != "answered")] | length')" -gt 0 ] && return 0
    die "#$t has no blocking question filed; it is blocked for another reason"
  fi
  for q in $qs; do
    add_blocker "$t" "$q"
    apply '
      .tickets[$t].questions = ((.tickets[$t].questions // []) + [{ticket: $q, blocking: true, state: "open", at: $now}])
      | .tickets[$t].blocked_reason = "waiting on the answer to #\($q)"
      | .decisions += [{id: ((.decisions | length) + 1), kind: "question", ticket: $t, question_ticket: $q,
          question: "Ticket \($t) waits on #\($q), a question its worker filed for triage. Answer it in the Product chat; the ticket is redispatched with the answer.",
          status: "waiting", at: $now}]
      | event({event: "asked", ticket: $t, question: $q}; $now)' --arg t "$t" --arg q "$q"
  done
}

# -------------------------------------------------------------------- sync

# The Decision chat's ruling, read from the question ticket's comments (a
# JSON array on stdin): {kind, text, took, needed}. kind is "answer",
# "reject" or "add-ticket" from the first ruling line ("Answer:", "Reject:",
# "Add ticket:") of the last comment holding one, else null; text is what
# follows it, the verdict lines left out. took and needed are the verdicts
# "Took the recommendation: yes|no" and "Needed the Decision chat: yes|no"
# (true, false, or null when not given), from the ruling's comment, or with
# no ruling line (a Defer or a Discard) from the last comment holding one.
RULING_JQ='
  def verdict_line: test("^(Took the recommendation|Needed the Decision chat):"; "i");
  def verdict($name):
    [.[] | split("\n")[] | sub("\r$"; "") | select(test("^" + $name + ":"; "i"))
     | sub("^[^:]*:[ \t]*"; "") | ascii_downcase] | last
    | if . == null then null elif test("^yes\\b") then true elif test("^no\\b") then false else null end;
  def ruling_line: test("^(Answer|Reject|Add ticket):");
  [.[] | .body // "" | gsub("\r"; "")] as $all
  | ([$all[] | select(split("\n") | any(ruling_line))] | last) as $c
  | (if $c == null then [$all[] | select(split("\n") | any(verdict_line))] | last else $c end) as $v
  | ($c // "" | split("\n") | map(select(verdict_line | not))) as $ls
  | ([$ls | to_entries[] | select(.value | ruling_line) | .key] | first) as $i
  | (if $i == null then null else $ls[$i] | capture("^(?<k>Answer|Reject|Add ticket):(?<r>.*)$") end) as $m
  | {kind: (if $m == null then null else $m.k | ascii_downcase | gsub(" "; "-") end),
     text: (if $m == null then "" else [$m.r] + $ls[($i + 1):] | join("\n") | sub("^[ \t\n]+"; "") | sub("[ \t\n]+$"; "") end),
     took: ([$v // empty] | verdict("Took the recommendation")),
     needed: ([$v // empty] | verdict("Needed the Decision chat"))}'

cmd_sync() {
  open_run "${1:-}"
  local pairs="" t="" q="" view="" state="" ruling="" kind="" text="" added="" unread=""
  pairs=$(get '.tickets | to_entries[] | .key as $t | (.value.questions // [])[] | select(.state == "open" or .state == "deferred") | "\($t) \(.ticket)"')
  [ -n "$pairs" ] || return 0
  # On fd 3: nothing the loop runs can read the list away.
  while read -r t q <&3; do
    view=$(gh issue view "$q" -R "$(repo_of)" --json state,labels,comments) || die "could not read #$q from the tracker"
    state=$(jq -r '.state | ascii_downcase' <<<"$view")
    ruling=$(jq -c '.comments // []' <<<"$view" | jq -c "$RULING_JQ")
    kind=$(jq -r '.kind // ""' <<<"$ruling")
    text=$(jq -r '.text' <<<"$ruling")
    if [ "$state" = closed ]; then
      added=""
      unread=""
      case "$kind" in
        answer) [ -n "$text" ] || kind="" ;;
        add-ticket)
          added=$(printf '%s\n' "$text" | sed -n '1s/^#\{0,1\}\([0-9][0-9]*\).*/\1/p')
          if [ -z "$added" ]; then kind=""; unread="an Add ticket: line that names no ticket"; fi ;;
      esac
      case "$kind" in
        answer)
          record_ruling "$t" "$q" answer "$ruling"
          record_answer "$t" "$q" "$text"
          echo "answered #$t #$q" ;;
        reject)
          record_ruling "$t" "$q" reject "$ruling"
          reject_question "$t" "$q" "$text" ;;
        add-ticket)
          record_ruling "$t" "$q" add-ticket "$ruling"
          add_ticket "$t" "$q" "$added" ;;
        *)
          # A ruling line sync can't read is not a Discard: no ruling is recorded.
          [ -n "$unread" ] || record_ruling "$t" "$q" discard "$ruling"
          if [ -z "$unread" ] && ! is_blocking "$t" "$q"; then
            # Discarding one that never blocked its ticket leaves nothing to decide.
            apply '.tickets[$t].questions |= map(if .ticket == $q then .state = "discarded" else . end)' --arg t "$t" --arg q "$q"
            echo "discarded #$t #$q"
            continue
          fi
          apply '
            if ([.decisions[] | select(.kind == "question" and .ticket == $t and .question_ticket == $q and .status == "waiting" and .closed_unanswered == true)] | length) > 0 then .
            else .decisions += [{id: ((.decisions | length) + 1), kind: "question", ticket: $t, question_ticket: $q, closed_unanswered: true,
              question: "#\($q) was closed with \(if $u == "" then "no Answer: line" else $u end), so ticket \($t) has no answer. Answer it, or redirect or defer ticket \($t)?",
              status: "waiting", at: $now}] end' --arg t "$t" --arg q "$q" --arg u "$unread"
          echo "closed #$t #$q" ;;
      esac
    elif ! is_blocking "$t" "$q" && jq -e "$BLOCK_RULING_JQ" <<<"$view" >/dev/null; then
      add_the_block "$t" "$q"
    elif jq -e '.labels | map(.name) | index("deferred")' <<<"$view" >/dev/null; then
      record_ruling "$t" "$q" defer "$ruling"
      if ! is_blocking "$t" "$q"; then
        # Its ticket was never held: deferring the decision leaves it going.
        apply '.tickets[$t].questions |= map(if .ticket == $q then .state = "deferred" else . end)' --arg t "$t" --arg q "$q"
        echo "deferred #$t #$q"
        continue
      fi
      apply '
        .tickets[$t].questions |= map(if .ticket == $q then .state = "deferred" else . end)
        | if ([.decisions[] | select(.kind == "defer-question" and .ticket == $t and .question_ticket == $q and .status == "waiting")] | length) > 0 then .
          else .decisions += [{id: ((.decisions | length) + 1), kind: "defer-question", ticket: $t, question_ticket: $q,
            question: "Triage deferred #\($q), which blocks ticket \($t) in this run. Pull ticket \($t) from the run (it defers with #\($q), back to the plan queue), or let it carry on (redispatched with \"not now\" as the answer)?",
            status: "waiting", at: $now}]
          | event({event: "deferred-question", ticket: $t, question: $q}; $now) end' --arg t "$t" --arg q "$q"
      echo "deferred #$t #$q"
    else
      echo "open #$t #$q"
    fi
  done 3<<<"$pairs"
}

# A non-blocking open decision (one a worker found in another ticket, #231)
# holds its ticket only once the Decision chat asks for the block: a comment
# line "Add the block: <why>", the question left open (the --jq for its view).
BLOCK_RULING_JQ='[.comments[]?.body // "" | split("\n")[] | sub("\r$"; "") | select(test("^Add the block:"; "i"))] | length > 0'

is_blocking() { # ticket question
  [ "$(get --arg t "$1" --arg q "$2" '[.tickets[$t].questions[]? | select(.ticket == $q and .blocking == true)] | length')" -gt 0 ]
}

# add_the_block ticket question: the native edge, the question now blocking,
# a queued ticket blocked (one in flight finishes its attempt; the edge holds
# its dependents), and a "question" decision as `block` queues; once. A
# merged or closed ticket gets nothing: the question stays open.
add_the_block() {
  local t="$1" q="$2"
  case "$(get --arg t "$t" '.tickets[$t].status // ""')" in
    # Its work is done: nothing left to hold.
    merged|closed) echo "open #$t #$q"; return 0 ;;
  esac
  add_blocker "$t" "$q"
  apply '
    .tickets[$t].questions |= map(if .ticket == $q then .blocking = true | .block_added = $now else . end)
    | if .tickets[$t].status == "queued"
      then .tickets[$t].status = "blocked" | .tickets[$t].blocked_reason = "waiting on the answer to #\($q)" else . end
    | .decisions += [{id: ((.decisions | length) + 1), kind: "question", ticket: $t, question_ticket: $q,
        question: "Ticket \($t) waits on #\($q), an open decision another worker found in it; the Decision chat asked for the block. It is redispatched with the ruling.",
        status: "waiting", at: $now}]
    | event({event: "block-added", ticket: $t, question: $q, status: .tickets[$t].status}; $now)' --arg t "$t" --arg q "$q"
  echo "blocked #$t #$q"
}

# record_ruling ticket question kind ruling-json: the ruling and both its
# verdicts on the question, and a "ruled" event; one event per ruling (a
# deferred question answered later records the answer too). A verdict
# written after the ruling (a deferral comment posted after the label) is
# filled in on the question and on that ruling's event, not logged again.
record_ruling() {
  apply '
    ([.tickets[$t].questions[]? | select(.ticket == $q)] | first | .ruling) as $had
    | {took_recommendation: (if $took == null then $had.took_recommendation else $took end),
       needed_decision_chat: (if $needed == null then $had.needed_decision_chat else $needed end)} as $v
    | if ($had.kind // null) == $k then
        if $had.took_recommendation == $v.took_recommendation and $had.needed_decision_chat == $v.needed_decision_chat then .
        else .tickets[$t].questions |= map(if .ticket == $q then .ruling += $v else . end)
          | ([.events | to_entries[] | select(.value.event == "ruled" and .value.ticket == $t and .value.question == $q) | .key] | last) as $i
          | if $i == null then . else .events[$i] += $v end
        end
      else .tickets[$t].questions |= map(if .ticket == $q
             then .ruling = {kind: $k, took_recommendation: $took, needed_decision_chat: $needed, at: $now} else . end)
        | event({event: "ruled", ticket: $t, question: $q, ruling: $k, took_recommendation: $took, needed_decision_chat: $needed}; $now)
      end' --arg t "$1" --arg q "$2" --arg k "$3" \
    --argjson took "$(jq -c '.took' <<<"$4")" --argjson needed "$(jq -c '.needed' <<<"$4")"
}

# resolve_waiting: the filter that settles ticket $t's waiting decisions on
# question $q.
RESOLVE_WAITING='.decisions |= map(if .ticket == $t and .question_ticket == $q and .status == "waiting"
                    and (.kind == "question" or .kind == "defer-question") then .status = "resolved" else . end)'

# reject_question ticket question ruling-text: Reject. Before the ticket's
# work merged it leaves the run as `deferred … pull` takes one: back to
# needs-triage with the open decision noted on it, in-run off, off the
# scope (status sent_back), its native edges kept, so its dependents wait.
# After its work merged nothing is pulled: a follow-up needs-triage ticket
# corrects it; closed without a merge, nothing is done but the record.
# While an attempt is still going it waits for the next sync.
reject_question() {
  local t="$1" q="$2" text="$3" st="" title="" body="" url="" num="" ruling_note=""
  st=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ -z "$text" ] || ruling_note="

The ruling: $text"
  case "$st" in
    in_flight|returned)
      echo "reject-waits #$t #$q" ;;
    closed)
      # Closed without a merge: out of the run, nothing shipped to correct.
      apply '
        .tickets[$t].questions |= map(if .ticket == $q then .state = "rejected" else . end)
        | '"$RESOLVE_WAITING"'
        | event({event: "rejected", ticket: $t, question: $q, pulled: false}; $now)' --arg t "$t" --arg q "$q"
      echo "rejected #$t #$q" ;;
    merged)
      title="Follow-up to #$t: correct it for open decision #$q"
      body="> *Filed during run $RUN_ID when the Decision chat rejected open decision #$q after #$t's work merged: an agent-filed follow-up, not yet triaged.*

#$t merged before open decision #$q was ruled on, and the Decision chat ruled Reject. A ruling never reverts merged work, so this ticket corrects #$t instead.

## The ruling

${text:-Reject (no reason given on #$q).}

## The open decision

#$q"
      url=$("$SCRIPT_DIR/tracker.sh" new-issue --kind finding --from "$t" --run-dir "$RUN_DIR" -- -R "$(repo_of)" \
        --title "$title" --body-file - <<<"$body" --label needs-triage) || die "could not file the follow-up to #$t"
      num=${url##*/}
      state_is_uint "$num" || die "gh gave no issue number: $url"
      apply '
        .tickets[$t].questions |= map(if .ticket == $q then .state = "rejected" | .follow_up = $n else . end)
        | '"$RESOLVE_WAITING"'
        | event({event: "rejected", ticket: $t, question: $q, pulled: false, follow_up: $n}; $now)' \
        --arg t "$t" --arg q "$q" --arg n "$num"
      echo "rejected #$t #$q follow-up #$num" ;;
    *)
      gh issue edit "$t" -R "$(repo_of)" --add-label needs-triage --remove-label in-run >/dev/null \
        || die "could not label #$t on the tracker"
      gh issue comment "$t" -R "$(repo_of)" --body-file - >/dev/null <<EOF || die "could not comment on #$t"
> *This was generated by AI during a run.*

Taken out of run $RUN_ID: the Decision chat rejected open decision #$q, so this ticket goes back to needs-triage to be rewritten with it. Its blockers are kept, and its dependents wait for it.$ruling_note
EOF
      apply '
        .tickets[$t] |= (.status = "sent_back" | .pid = null | .blocked_reason = null
                         | .sent_back = {from: $q, ruling: "reject", at: $now}
                         | .questions |= map(if .ticket == $q then .state = "rejected" else . end))
        | .plan.scope |= map(select(. != $t))
        | '"$RESOLVE_WAITING"'
        | event({event: "rejected", ticket: $t, question: $q, pulled: true}; $now)' --arg t "$t" --arg q "$q"
      echo "rejected #$t #$q" ;;
  esac
}

# add_ticket ticket question added: Add ticket. The case is its own ticket
# (#added, triaged as usual); the original is unblocked and carries on with
# the answer "not covered here".
add_ticket() {
  local t="$1" q="$2" n="$3"
  if [ "$(get --arg t "$t" --arg q "$q" '[.tickets[$t].questions[]? | select(.ticket == $q and .blocking == true)] | length')" -gt 0 ]; then
    remove_blocker "$t" "$q"
  fi
  apply '.tickets[$t].questions |= map(if .ticket == $q then .added = $n else . end)' --arg t "$t" --arg q "$q" --arg n "$n"
  record_answer "$t" "$q" "not covered here"
  echo "added #$t #$q #$n"
}

# record_answer ticket question answer: the answer is kept for the next
# worker; once every blocking question of the ticket is answered it is
# queued again (one a finding raised that never blocked it doesn't hold it).
record_answer() {
  apply '
    .tickets[$t].questions |= map(if .ticket == $q then .state = "answered" | .answer = $a else . end)
    | .tickets[$t].answers = ((.tickets[$t].answers // []) | map(select(.question != $q)) + [{question: $q, answer: $a}])
    | .decisions |= map(if .ticket == $t and .question_ticket == $q and .status == "waiting"
                          and (.kind == "question" or .kind == "defer-question") then .status = "resolved" else . end)
    | if ([.tickets[$t].questions[] | select(.blocking == true and .state != "answered")] | length) == 0 and .tickets[$t].status == "blocked"
      then .tickets[$t].status = "queued" | .tickets[$t].blocked_reason = null
           | event({event: "answered", ticket: $t, question: $q, next: "queued"}; $now)
      else event({event: "answered", ticket: $t, question: $q, next: .tickets[$t].status}; $now) end' \
    --arg t "$1" --arg q "$2" --arg a "$3"
}

# ---------------------------------------------------------------- deferred

cmd_deferred() {
  open_run "${1:-}"
  local t="${2:-}" choice="${3:-}"
  [ -n "$t" ] && { [ "$choice" = pull ] || [ "$choice" = carry ]; } || usage
  local qs= q=
  qs=$(get --arg t "$t" '.tickets[$t].questions[]? | select(.state == "deferred") | .ticket')
  [ -n "$qs" ] || die "#$t has no deferred question; run sync first"
  for q in $qs; do
    if [ "$choice" = carry ]; then
      remove_blocker "$t" "$q"
      record_answer "$t" "$q" "not now"
    else
      gh issue edit "$t" -R "$(repo_of)" --add-label deferred --remove-label in-run >/dev/null \
        || die "could not label #$t on the tracker"
      gh issue comment "$t" -R "$(repo_of)" --body "> *This was generated by AI during a run.*

Pulled from run $RUN_ID: it was blocked by #$q, which triage deferred, and the Artisan chose to take it out of the run. It goes back to the plan queue with its branch kept.

Return condition: blocked-by #$q" >/dev/null || die "could not comment on #$t"
      apply '
        .tickets[$t].status = "deferred" | .tickets[$t].pid = null
        | .plan.scope |= map(select(. != $t))
        | .decisions |= map(if .ticket == $t and .kind == "defer-question" and .status == "waiting" then .status = "resolved" else . end)
        | event({event: "pulled", ticket: $t, question: $q}; $now)' --arg t "$t" --arg q "$q"
    fi
  done
}

# -------------------------------------------------------------------- list

cmd_list() {
  open_run "${1:-}"
  echo "| Question | Asked by | Effect | State | Answer |"
  echo "|---|---|---|---|---|"
  get '.tickets | to_entries[] | .key as $t | (.value.questions // [])[]
       | "| #\(.ticket) | #\($t) | \(if .blocking then "blocks it" else "split off" end) | \(.state) | \(.answer // "-") |"'
}

# ------------------------------------------------------------- provisional

cmd_provisional() {
  open_run "${1:-}"
  local mark=0 rows=
  [ "${2:-}" != --shown ] || mark=1
  rows=$(get '
    (.provisional_shown // []) as $seen
    | [.tickets | to_entries[] | select(.value.status == "merged" and (.key as $k | $seen | index($k) | not))
       | .key as $t | (.value.evidence.decisions // [])[]
       | select(.confidence == "provisional" and ((.criterion // "" | tostring) as $c | ["4", "6", "7"] | index($c)))
       | {t: $t} + .]
    | .[] | "| #\(.t) | \(.question // "-" | gsub("\\|"; "/")) | \(.choice // "-" | gsub("\\|"; "/")) | \(.alternative // "-" | gsub("\\|"; "/")) | \(.criterion) | provisional |"')
  local shown_tickets=
  shown_tickets=$(printf '%s\n' "$rows" | sed -n 's/^| #\([^ ]*\) |.*/\1/p' | jq -R . | jq -sc 'unique')
  echo "| Ticket | Question | Picked | Alternative | Criterion | Confidence |"
  echo "|---|---|---|---|---|---|"
  [ -z "$rows" ] || printf '%s\n' "$rows"
  if [ "$mark" -eq 1 ]; then
    # Only the tickets whose cards were printed: one merged since is for the next gate.
    apply '.provisional_shown = (((.provisional_shown // []) + $shown) | unique)
           | event({event: "provisional-shown"}; $now)' --argjson shown "$shown_tickets"
  fi
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  file) cmd_file "$@" ;;
  block) cmd_block "$@" ;;
  sync) cmd_sync "$@" ;;
  deferred) cmd_deferred "$@" ;;
  list) cmd_list "$@" ;;
  provisional) cmd_provisional "$@" ;;
  *) usage ;;
esac
