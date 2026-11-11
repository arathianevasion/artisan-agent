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
  local ticket= criterion= question= rec= repo= mode=
  local options=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ticket) ticket=${2:-}; shift 2 ;;
      --criterion) criterion=${2:-}; shift 2 ;;
      --question) question=${2:-}; shift 2 ;;
      --option) options+=("${2:-}"); shift 2 ;;
      --recommendation) rec=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --blocking) mode=blocking; shift ;;
      --split) mode=split; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$ticket" ] && [ -n "$question" ] && [ -n "$rec" ] && [ -n "$mode" ] || usage
  [ "${#options[@]}" -ge 2 ] || die "a question needs at least two options"
  case "$criterion" in
    [1-7]|always-ask) ;;
    *) die "--criterion is 1-7 or always-ask" ;;
  esac
  ticket=${ticket#\#}
  local opt body title url num i crit_text effect run_note=
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

$criterion: $crit_text (the plugin's controversy criteria, 1-7, plus the project's \"Always ask\" items).

## Effect on #$ticket

$effect

Answer by commenting \`Answer: <the decision>\` and closing this ticket. Deferring it asks whether to pull #$ticket from the run or let it carry on."
  local rargs=()
  [ -z "$repo" ] || rargs=(-R "$repo")
  url=$(gh issue create ${rargs[@]+"${rargs[@]}"} --title "$title" --body "$body" --label needs-triage) \
    || die "could not file the question ticket"
  num=${url##*/}
  case "$num" in ''|*[!0-9]*) die "gh gave no issue number: $url" ;; esac
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

# ---------------------------------------------------------------- tracker

repo_of() { get .repo; }

issue_id() { gh api "repos/$(repo_of)/issues/$1" | jq -r .id; }

add_blocker() { # blocked blocker
  local id err
  id=$(issue_id "$2") || die "could not read #$2 from the tracker"
  if ! err=$(gh api --method POST "repos/$(repo_of)/issues/$1/dependencies/blocked_by" -F "issue_id=$id" 2>&1 >/dev/null); then
    case "$err" in *already*|*422*) ;; *) die "could not mark #$1 blocked by #$2: $err" ;; esac
  fi
}

remove_blocker() { # blocked blocker
  local id
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
  local qs q
  qs=$(get --arg t "$t" '
    [.findings[]? | select(.from == $t and .kind == "question" and .blocking == true) | .ticket] as $f
    | (.tickets[$t].questions // [] | map(.ticket)) as $have
    | [$f[] | select(. as $x | $have | index($x) | not)] | unique[]')
  if [ -z "$qs" ]; then
    [ "$(get --arg t "$t" '[.tickets[$t].questions[]? | select(.state != "answered")] | length')" -gt 0 ] && return 0
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

# The text after "Answer:" in the last comment that has such a line.
answer_of() { # json array of comments
  jq -r '[.[] | .body | select(test("(^|\n)Answer:"))] | last // "" | split("Answer:")[1:] | join("Answer:") | sub("^[ \t]+"; "") | sub("[ \t\n]+$"; "")' <<<"$1"
}

cmd_sync() {
  open_run "${1:-}"
  local pairs t q view state ans
  pairs=$(get '.tickets | to_entries[] | .key as $t | (.value.questions // [])[] | select(.state == "open" or .state == "deferred") | "\($t) \(.ticket)"')
  [ -n "$pairs" ] || return 0
  while read -r t q; do
    view=$(gh issue view "$q" -R "$(repo_of)" --json state,labels,comments) || die "could not read #$q from the tracker"
    state=$(jq -r '.state | ascii_downcase' <<<"$view")
    if [ "$state" = closed ]; then
      ans=$(answer_of "$(jq -c '.comments' <<<"$view")")
      if [ -n "$ans" ]; then
        record_answer "$t" "$q" "$ans"
        echo "answered #$t #$q"
      else
        apply '
          if ([.decisions[] | select(.kind == "question" and .ticket == $t and .question_ticket == $q and .status == "waiting" and .closed_unanswered == true)] | length) > 0 then .
          else .decisions += [{id: ((.decisions | length) + 1), kind: "question", ticket: $t, question_ticket: $q, closed_unanswered: true,
            question: "#\($q) was closed with no Answer: line, so ticket \($t) has no answer. Answer it, or redirect or defer ticket \($t)?",
            status: "waiting", at: $now}] end' --arg t "$t" --arg q "$q"
        echo "closed #$t #$q"
      fi
    elif jq -e '.labels | map(.name) | index("deferred")' <<<"$view" >/dev/null; then
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
  done <<<"$pairs"
}

# record_answer ticket question answer: the answer is kept for the next
# worker; once every question of the ticket is answered it is queued again.
record_answer() {
  apply '
    .tickets[$t].questions |= map(if .ticket == $q then .state = "answered" | .answer = $a else . end)
    | .tickets[$t].answers = ((.tickets[$t].answers // []) | map(select(.question != $q)) + [{question: $q, answer: $a}])
    | .decisions |= map(if .ticket == $t and .question_ticket == $q and .status == "waiting"
                          and (.kind == "question" or .kind == "defer-question") then .status = "resolved" else . end)
    | if ([.tickets[$t].questions[] | select(.state != "answered")] | length) == 0 and .tickets[$t].status == "blocked"
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
  local qs q
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
  local mark=0 rows
  [ "${2:-}" != --shown ] || mark=1
  rows=$(get '
    (.provisional_shown // []) as $seen
    | [.tickets | to_entries[] | select(.value.status == "merged" and (.key as $k | $seen | index($k) | not))
       | .key as $t | (.value.evidence.decisions // [])[]
       | select(.confidence == "provisional" and ((.criterion // "" | tostring) as $c | ["4", "6", "7"] | index($c)))
       | {t: $t} + .]
    | .[] | "| #\(.t) | \(.question // "-" | gsub("\\|"; "/")) | \(.choice // "-" | gsub("\\|"; "/")) | \(.alternative // "-" | gsub("\\|"; "/")) | \(.criterion) | provisional |"')
  local shown_tickets
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
