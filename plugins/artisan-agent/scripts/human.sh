#!/usr/bin/env bash
# Hands-on tickets: the work the Artisan builds themselves so their skill
# doesn't erode, and which meets the same quality floor as a worker's. The
# rules and the flow: skills/implement-plan/references/hands-on.md.
#
# At plan approval (the Engineering chat):
#   human.sh suggest --draft FILE [--minutes N]
#       the tickets that could be the plan's one hands-on ticket without
#       delaying the run (off the critical path), as a markdown table with
#       each one's slack. Judging what the Artisan would learn, and naming
#       the focus it serves, is the chat's.
#   human.sh annotate --draft FILE
#       plan JSON on stdin, plan JSON on stdout: adds .hands_on (ticket,
#       focus, minutes, whether it is on the critical path, the delay it
#       costs the run, its dependents) from the draft's "hands_on" object.
#       plan.sh build calls it. 1: more than one hands-on ticket, an unknown
#       ticket or no focus.
#
# In a run (the orchestrator, and the chat between waves):
#   human.sh sync <run-dir>
#       setup, then take (below), one line per thing done.
#   human.sh setup <run-dir>
#       for every queued ticket in scope that is labelled ready-for-human on
#       the tracker or is the plan's hands-on ticket, and is not a Human
#       check (references/human-checks.md), whose blockers are all
#       merged: a worktree on the ticket's branch from the integration
#       branch's tip, recorded as the ticket's "human" record. The ticket is
#       not dispatched, and its dependents wait (dispatch refuses them until
#       it is merged). Prints "#<n> <worktree>".
#   human.sh start <run-dir> <ticket>      the same, for one ticket
#   human.sh done <run-dir> <ticket> [--notes TEXT]
#       the Artisan says it is done: refused (6) while the worktree has
#       uncommitted work or nothing was committed; otherwise a request is
#       filed and taken. 3: the state lock is held (a wave is running); the
#       request stays filed and the next sync takes it.
#   human.sh take <run-dir>
#       turn each filed request into a returned ticket, with a result file
#       describing the branch tip. From there it is a worker's ticket:
#       verify.sh, wave.sh merge (the suite) and wave.sh close, in that order.
#       A failed verdict does not start a worker: the ticket goes back to the
#       Artisan, with the verifier's findings (human.sh verdict).
#   human.sh verdict <run-dir> <ticket>
#       the verifier's feedback on the last round, as markdown for the Artisan.
#   human.sh status <run-dir>
#       a markdown table of every hands-on ticket and where it stands.
#   human.sh parked <run-dir> [--record]
#       exit 0 and one line when only a hands-on ticket, and work behind it,
#       is left: the run parks and names it. 1 otherwise. --record logs a
#       "parked" event once.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 4 outside
# the scope, 5 a blocker not merged, 6 refused (see done). Per command:
# scripts/README.md, "Waves: the two-tier run".
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

# The hands-on minutes assumed when the draft doesn't say: a person takes
# longer than a worker on the same ticket.
HUMAN_MINUTES_FACTOR=3

usage() { state_usage "$0"; }
die() { state_die 1 "human.sh: $*"; }

# ------------------------------------------------------------------ the plan

# The schedule of a draft: per ticket its earliest finish, latest finish and
# slack in minutes, from each ticket's expected.minutes and blocked_by (the
# blockers inside the scope). No edges means every ticket is independent.
SCHEDULE_JQ='
  def sched($scope; $tk):
    ($scope | length) as $n
    | def mins($t): ($tk[$t].expected.minutes // 0);
      def deps($t): [($tk[$t].blocked_by // [])[] | tostring | select(. as $b | $scope | index($b))];
      def succs($t): [$scope[] | select(. as $s | deps($s) | index($t))];
    (reduce range(0; $n + 1) as $_ ({};
        . as $ef | reduce $scope[] as $t ($ef;
          .[$t] = (mins($t) + ([deps($t)[] | $ef[.] // 0] | max // 0)))) ) as $ef
    | ([$ef[]] | max // 0) as $total
    | (reduce range(0; $n + 1) as $_ ({};
        . as $lf | reduce $scope[] as $t ($lf;
          .[$t] = ([succs($t)[] | ($lf[.] // $total) - mins(.)] | min // $total)))) as $lf
    | { total: $total,
        tickets: ($scope | map({key: ., value: {finish: $ef[.], slack: ($lf[.] - $ef[.])}}) | from_entries) };
'

cmd_suggest() {
  local draft= minutes=
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) [ $# -ge 2 ] || usage; draft=$2; shift 2 ;;
      --minutes) [ $# -ge 2 ] || usage; minutes=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$draft" ] || die "no draft: ${draft:-<none>}"
  jq -r --arg fac "$HUMAN_MINUTES_FACTOR" --arg mins "$minutes" "$SCHEDULE_JQ"'
    (.scope | map(tostring)) as $scope | .tickets as $tk
    | sched($scope; $tk) as $s
    | [ $scope[] | . as $t
        | ($tk[$t].expected.minutes // 0) as $w
        | (if $mins == "" then ($w * ($fac | tonumber)) else ($mins | tonumber) end) as $h
        | {t: $t, title: ($tk[$t].title // "untitled"), slack: $s.tickets[$t].slack, worker: $w, human: $h,
           delay: ([($h - $w) - $s.tickets[$t].slack, 0] | max)} ] as $rows
    | "At most one hands-on ticket per plan, off the critical path. Run length about \($s.total) minutes.",
      "",
      "| Ticket | Slack (min) | Worker (min) | Hands-on (min) | Delay if taken (min) |",
      "|---|---|---|---|---|",
      ($rows | sort_by(-.slack, (.t | tonumber? // 0))[]
        | "| #\(.t) (\(.title)) | \(.slack) | \(.worker) | \(.human) | \(.delay) |"),
      "",
      (if ([$rows[] | select(.delay == 0)] | length) > 0
       then "Eligible (delay 0): \([$rows[] | select(.delay == 0) | "#" + .t] | join(", ")). Pick the one the Artisan would learn most from, and name the focus it serves."
       else "No ticket can be taken without delaying the run; suggest none, or show the delay." end)' "$draft"
}

# annotate: plan JSON on stdin and the draft named: adds .hands_on.
cmd_annotate() {
  local draft=
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) [ $# -ge 2 ] || usage; draft=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$draft" ] || die "no draft: ${draft:-<none>}"
  local plan= out=
  plan=$(cat)
  out=$(jq -n --argjson plan "$plan" --slurpfile d "$draft" --arg fac "$HUMAN_MINUTES_FACTOR" "$SCHEDULE_JQ"'
    $d[0] as $d | $plan as $plan
    | if ($d.hands_on // null) == null then $plan
      else
        $d.hands_on as $h
        | if ($h | type) != "object" then error("hands_on is one object: at most one hands-on ticket per plan")
          else . end
        | ($h.ticket | tostring) as $t
        | if ($plan.scope | index($t)) == null then error("the hands-on ticket \($t) is not in the scope") else . end
        | if (($h.focus // "") | type) != "string" or ($h.focus // "") == "" then
            error("the hands-on ticket needs the focus it serves (understanding the problem, finding the best solution, or improving the pipeline)")
          else . end
        | ($plan.scope) as $scope | ($d.tickets // {}) as $tk
        | sched($scope; $tk) as $s
        | ($tk[$t].expected.minutes // 0) as $w
        | ($h.minutes // ($w * ($fac | tonumber))) as $hm
        | $s.tickets[$t].slack as $slack
        | ([$scope[] | select(. as $x | ($tk[$x].blocked_by // []) | map(tostring) | index($t))]) as $direct
        | ( reduce range(0; ($scope | length)) as $_ ($direct;
              . as $r | ($r + [$scope[] | select(. as $x | ($tk[$x].blocked_by // []) | map(tostring) | any(. as $b | $r | index($b)))]) | unique)) as $deps
        | $plan + {hands_on: {
            ticket: $t, focus: $h.focus, minutes: $hm, worker_minutes: $w,
            on_critical_path: ($slack <= 0), slack_minutes: $slack,
            delay_minutes: ([($hm - $w) - $slack, 0] | max),
            dependents: ($deps | sort_by(tonumber? // 0))}}
      end' 2>&1) || die "$(printf '%s' "$out" | sed 's/^jq: error[^:]*: //; s/ (at <[^>]*>)$//')"
  printf '%s\n' "$out"
}

# --------------------------------------------------------------------- a run

# Blockers of the ticket from the tracker: every one in the run merged into
# the integration branch, every one outside it closed. 5 when not.
blockers_merged() { # ticket
  local t="$1" repo= ib= tip= blockers= b= state= status= sha=
  repo=$(get '.repo')
  ib=$(integration_branch)
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib") || die "no integration branch $ib"
  blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
    || die "could not read the blockers of #$t from the tracker"
  for b in $(printf '%s' "$blockers" | jq -r '.[] | "\(.number)=\(.state | ascii_downcase)"'); do
    state=${b#*=} b=${b%%=*}
    # A Human check in the run never holds anything up (references/human-checks.md).
    [ "$(get --arg b "$b" "$STATE_JQ_DEFS"' is_human_check($b)')" = false ] || continue
    status=$(get --arg b "$b" '.tickets[$b].status // ""')
    if [ -n "$status" ]; then
      sha=$(get --arg b "$b" '.tickets[$b].merge_commit // ""')
      if [ "$status" != merged ] || [ -z "$sha" ] || ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        return 5
      fi
    elif [ "$state" != closed ]; then
      return 5
    fi
  done
}

# A Human check (its body marker, references/human-checks.md) is never a
# hands-on ticket: it verifies work an agent built, at a gate.
HUMAN_CHECK_MARK='<!-- artisan-agent:human-check-for #'
is_hands_on() { # ticket: labelled ready-for-human on the tracker, or the plan's pick; never a Human check
  local t="$1" issue=""
  [ "$(get --arg t "$t" "$STATE_JQ_DEFS"' is_human_check($t)')" = false ] || return 1
  [ "$(get --arg t "$t" '(.plan.hands_on.ticket // "" | tostring) == $t')" != true ] || return 0
  issue=$(gh api "repos/$(get '.repo')/issues/$t") || die "could not read #$t from the tracker"
  jq -e --arg m "$HUMAN_CHECK_MARK" '(.body // "") | contains($m) | not' <<<"$issue" >/dev/null || return 1
  jq -e '[.labels[]? | (.name? // .)] | index("ready-for-human") != null' <<<"$issue" >/dev/null
}

start_one() { # ticket: sets WORKTREE
  local t="$1" status= ib= base= branch= wt= focus=
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$t" || exit $?
  status=$(get --arg t "$t" '.tickets[$t].status')
  [ "$status" = queued ] || die "#$t is $status, not queued"
  WORKTREE=$(get --arg t "$t" '.tickets[$t].human.worktree // ""')
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then return 0; fi
  is_hands_on "$t" || die "#$t is not a hands-on ticket (no ready-for-human label, not the plan's hands-on pick, or a Human check)"
  blockers_merged "$t" || state_die 5 "human.sh: #$t waits: a blocker is not merged into $(integration_branch) yet"
  ib=$(integration_branch)
  base=$(integration_tip)
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  wt="$WT_ROOT/$RUN_ID-$t.human"
  mkdir -p "$WT_ROOT"
  if git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git -C "$MAIN" worktree add -q "$wt" "$branch" >/dev/null 2>&1 || die "could not add worktree $wt for $branch"
  else
    git -C "$MAIN" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 || die "could not add worktree $wt"
  fi
  # The project's worktree_setup (#173). A hands-on ticket is the Artisan's, so
  # no attempt is spent: the worktree goes and the ticket stays queued.
  if ! worktree_setup "$wt"; then
    git -C "$MAIN" worktree remove --force "$wt" >/dev/null 2>&1 || true
    state_die 6 "human.sh: #$t: $SETUP_ERR"
  fi
  focus=$(get --arg t "$t" '(.plan.hands_on | if . != null and (.ticket | tostring) == $t then .focus else "" end)')
  apply '.tickets[$t].worktree = $wt
    | .tickets[$t].human = {worktree: $wt, branch: $branch, base: $base, focus: $focus,
          started_at: $now, done_at: null, rounds: 0, feedback: []}
    | event({event: "human-start", ticket: $t, worktree: $wt, base: $base}; $now)' \
    --arg t "$t" --arg wt "$wt" --arg branch "$branch" --arg base "$base" --arg focus "$focus"
  WORKTREE=$wt
}

WORKTREE=
cmd_start() {
  open_run "${1:-}"
  [ -n "${2:-}" ] || usage
  start_one "$2"
  printf '#%s %s\n' "$2" "$WORKTREE"
}

cmd_setup() {
  open_run "${1:-}"
  local t= rc=
  for t in $(get "$STATE_JQ_DEFS"' . as $s | .plan.scope[] as $t
               | select(.tickets[$t].status == "queued" and .tickets[$t].human == null and ($s | is_human_check($t) | not)) | $t'); do
    rc=0
    (start_one "$t" >/dev/null 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || continue
    printf '#%s %s\n' "$t" "$(get --arg t "$t" '.tickets[$t].human.worktree')"
  done
}

cmd_done() {
  open_run "${1:-}"
  local t="${2:-}" notes=
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --notes) [ $# -ge 2 ] || usage; notes=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$t" || exit $?
  local wt= base= tip=
  wt=$(get --arg t "$t" '.tickets[$t].human.worktree // ""')
  [ -n "$wt" ] && [ -d "$wt" ] || die "#$t has no hands-on worktree; run human.sh setup first"
  [ "$(get --arg t "$t" '.tickets[$t].status')" = queued ] || die "#$t is $(get --arg t "$t" '.tickets[$t].status'), not with the Artisan"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || state_die 6 "human.sh: #$t has uncommitted work in $wt; commit it, then say it is done"
  base=$(get --arg t "$t" '.tickets[$t].human.base')
  tip=$(git -C "$wt" rev-parse HEAD)
  [ "$tip" != "$base" ] || state_die 6 "human.sh: #$t has no commit on top of $base; there is nothing to verify"
  mkdir -p "$RUN_DIR/human"
  jq -n --arg tip "$tip" --arg notes "$notes" '{commit: $tip, notes: $notes}' >"$RUN_DIR/human/$t.done"
  echo "#$t filed as done at $tip"
  local rc=0
  (state_with_lock "$RUN_DIR" take_locked) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "human.sh: the state lock is held (a wave is running); the next human.sh sync takes #$t" >&2
    exit 3
  fi
  echo "#$t is awaiting its verifier: it goes through verify.sh, the suite and the merge like any worker's ticket"
}

# take_locked: every filed request becomes a returned ticket. Holds the lock.
take_locked() {
  local f= t= n= tip= base= notes= res=
  for f in "$RUN_DIR"/human/*.done; do
    [ -e "$f" ] || continue
    t=$(basename "$f" .done)
    if [ "$(get --arg t "$t" '.tickets[$t].status // ""')" != queued ] \
       || [ "$(get --arg t "$t" '.tickets[$t].human != null')" != true ]; then
      rm -f "$f"; continue
    fi
    base=$(get --arg t "$t" '.tickets[$t].human.base')
    # The Artisan may have committed more since saying so: the tip is the work.
    tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$(get --arg t "$t" '.tickets[$t].branch')") || continue
    notes=$(jq -r '.notes // ""' "$f")
    n=$(( $(get --arg t "$t" '.tickets[$t].attempts') + 1 ))
    res="results/$t.$n.result.json"
    mkdir -p "$RUN_DIR/results"
    jq -n --arg t "$t" --arg b "$(get --arg t "$t" '.tickets[$t].branch')" --arg c "$tip" --arg base "$base" --arg notes "$notes" '{
        ticket: $t, status: "complete", branch: $b, commit: $c, base: $base,
        acceptance: [], tests: null,
        unsure: ["Built by the Artisan by hand: no worker evidence record; the verifier checked each criterion against the diff"],
        decisions: [], review: {ran: false, remarks: []}, findings: [],
        notes: (if $notes == "" then "Built by the Artisan." else "Built by the Artisan. " + $notes end)}' >"$RUN_DIR/$res"
    apply '.tickets[$t] |= (.attempts = $n | .status = "returned" | .pid = null
        | .result = {status: "complete", commit: $c, notes: null, file: $res}
        | .human.done_at = $now | .human.rounds += 1)
      | event({event: "human-done", ticket: $t, attempt: $n, commit: $c}; $now)' \
      --arg t "$t" --argjson n "$n" --arg c "$tip" --arg res "$res"
    rm -f "$f"
    echo "#$t returned at $tip (round $n)"
  done
}

cmd_take() {
  open_run "${1:-}"
  state_with_lock "$RUN_DIR" take_locked
}

cmd_sync() {
  open_run "${1:-}"
  cmd_setup "$RUN_DIR"
  cmd_take "$RUN_DIR"
}

cmd_verdict() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  [ "$(get --arg t "$t" '.tickets[$t].human != null')" = true ] || die "#$t is not a hands-on ticket"
  [ "$(get --arg t "$t" '.tickets[$t].evidence != null')" = true ] || die "#$t has no verdict yet"
  get --arg t "$t" '.tickets[$t].evidence as $e
    | "## Verifier on #\($t) (\($e.title // "untitled")): \($e.verdict), \($e.criteria_met)/\($e.criteria_total) criteria met",
      "",
      "| Criterion | Met | Evidence |",
      "|---|---|---|",
      ($e.acceptance[] | "| \(.criterion) | \(if .met then "yes" elif .gate == true then "checked by the merge gate" elif .human == true then "needs a human check\(if $e.human_check then " (#\($e.human_check))" else "" end)" else "no" end) | \(
         if .met then ([(.evidence.checks // [])[] | "\(.command): \(.result)"] + (.evidence.tests // []) | join("; "))
         else (.evidence.why // "not shown") end) |"),
      "",
      (if $e.note then "Note: \($e.note)" else empty end),
      (if $e.verifier.notes then "Verifier notes: \($e.verifier.notes)" else empty end),
      (if ($e.verifier.unsure | length) > 0 then "Verifier unsure: \($e.verifier.unsure | join("; "))" else empty end),
      (if $e.verdict == "pass" then "Next: it merges, behind the suite, in the orchestrator'"'"'s next step."
       else "Next: fix what is marked no in the same worktree, commit, and say it is done again. No worker is started." end)'
}

cmd_status() {
  open_run "${1:-}"
  echo "| Ticket | State | Worktree | Verdict |"
  echo "|---|---|---|---|"
  get '.plan.scope[] as $t | .tickets[$t] as $k | select($k.human != null)
    | "| #\($t) (\(.plan.tickets[$t].title // "untitled")) | \(
        if $k.status == "merged" or $k.status == "closed" then "merged"
        elif $k.status == "returned" then "done, awaiting its verifier or merge"
        elif $k.status == "blocked" then "blocked: \($k.blocked_reason // "see the decisions")"
        elif ($k.human.feedback | length) > 0 and $k.human.done_at == null then "needs changes after the verifier"
        else "with the Artisan" end) | \($k.human.worktree) | \(
        if $k.evidence then "\($k.evidence.verdict) \($k.evidence.criteria_met)/\($k.evidence.criteria_total)" else "-" end) |"'
}

cmd_parked() {
  open_run "${1:-}"
  local record=0
  [ "${2:-}" != --record ] || record=1
  local line=
  line=$(get "$STATE_JQ_DEFS"'
    . as $s | ($s.plan.tickets // {}) as $pt
    | $s.plan.scope as $scope
    | [$scope[] | select($s.tickets[.].status != "merged" and $s.tickets[.].status != "closed")
        | select(. as $t | $s | is_human_check($t) | not)] as $open
    | [$open[] | select($s.tickets[.].human != null or (($s.plan.hands_on.ticket // "" | tostring) == .))] as $hum
    | def blk($t): [($pt[$t].blocked_by // [])[] | tostring];
      (reduce range(0; ($scope | length) + 1) as $_ ($hum;
        . as $r | ($r + [$open[] | select(. as $t | blk($t) | any(. as $b | $r | index($b)))]) | unique)) as $held
    | [$open[] | select(. as $t | $held | index($t) | not)] as $loose
    | if ($hum | length) == 0 or ($loose | length) > 0
         or ([$open[] | select($s.tickets[.].status == "in_flight" or $s.tickets[.].status == "returned")] | length) > 0
         or ($s.frontier | length) > 0
         or ([$s.decisions[] | select(.status == "waiting" and .kind != "risk-gate" and .kind != "review-gate")] | length) > 0
      then empty
      else
        ($open | map(select(. as $t | $hum | index($t) | not))) as $behind
        | "parked: waiting on the Artisan'"'"'s hands-on ticket \($hum | map("#" + . + " (" + ($pt[.].title // "untitled") + ")") | join(", "))"
          + (if ($behind | length) > 0 then "; \($behind | length) ticket(s) wait behind it: \($behind | map("#" + .) | join(", "))" else "; nothing else waits behind it" end)
      end')
  [ -n "$line" ] || return 1
  echo "$line"
  if [ "$record" -eq 1 ]; then
    apply '(.events | last | .event) as $last
      | if $last == "parked" then . else event({event: "parked", reason: "human", detail: $line}; $now) end' --arg line "$line"
  fi
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  suggest) cmd_suggest "$@" ;;
  annotate) cmd_annotate "$@" ;;
  sync) cmd_sync "$@" ;;
  setup) cmd_setup "$@" ;;
  start) cmd_start "$@" ;;
  done) cmd_done "$@" ;;
  take) cmd_take "$@" ;;
  verdict) cmd_verdict "$@" ;;
  status) cmd_status "$@" ;;
  parked) cmd_parked "$@" ;;
  *) usage ;;
esac
