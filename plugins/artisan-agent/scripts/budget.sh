#!/usr/bin/env bash
# The run's spending limits: the budget with its projection and the overrun
# gate, and the plan-window guard on the usage reading the status-line capture
# writes (statusline.sh). The rules, the packet and the answers:
# ${CLAUDE_PLUGIN_ROOT}/references/cost-and-usage.md. State file:
# references/state-file.md.
#
# Usage, from the orchestrator (wave.sh dispatch calls guard) and the chat
# (wave.sh status calls guard):
#   budget.sh guard <run-dir>
#       may anything new dispatch? First the plan-window guard, then the
#       budget. Prints one line: "ok ...", "parked <window> ..." (18) or
#       "overrun #<issue> ..." (17). On the first park it records the park,
#       queues a "usage" decision and logs "parked"; on the first projected
#       crossing it opens the overrun gate (a review-gate issue holding the
#       packet), queues an "overrun" decision and logs "overrun-gate". Work in
#       flight is never stopped. Refuses with 12 while the run is halted.
#   budget.sh usage <run-dir>
#       the plan-window verdict alone, read-only: "ok 5h <p>% 7d <p>%",
#       "park five-hour|seven-day <p>% ...resets <time>" or "park unknown <why>"
#       (exit 18 for either park).
#   budget.sh project <run-dir>
#       the projection as JSON, read-only: budget, spent, still to come,
#       projected total, and per ticket estimate, spent, still to come, over by.
#   budget.sh packet <run-dir>
#       the latest overrun gate's packet (Markdown), read-only.
#
# Usage, from the Engineering chat, on the Artisan's word:
#   budget.sh overrun <run-dir> raise <usd> | cut <ticket>... | stop
#           [--action defer] [--by NAME] [--why TEXT]
#       the overrun gate's answer: one option (a decision card), and the gate
#       is deferred, the only action it has (--action anything else: 6). The
#       issue stays open until the end gate. raise: the new budget, at least
#       the projected total. cut: queued tickets leave the run's scope, and
#       what is left must fit the budget. stop: the run halts; work in flight
#       finishes. 6: no open overrun gate, or the option doesn't bring the
#       projection within the budget.
#   budget.sh park <run-dir> resume | raise <percent> | stop [--by NAME]
#       the answer to a usage park. resume: dispatch carries on once a fresh
#       reading is under the limits (at once if it already is; otherwise
#       after the reset). raise: the new ceiling for the window that parked
#       the run (seven-day: seven_day_ceiling_percent; five-hour: the reserve
#       becomes 100 - percent), a run override; 6 for an unknown reading.
#       stop: the run halts. 6: not parked.
#
# Environment: ARTISAN_USAGE_FILE, ARTISAN_HOME, CLAUDE_CONFIG_DIR place the
# usage file (statusline.sh path). The reading's age is measured on the real
# clock, the one the capture writes with; ARTISAN_NOW is the run's clock for
# everything else.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 6 refused,
# 12 the run is halted, 17 the overrun gate holds dispatch, 18 parked on plan
# usage.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq and, to open the gate
# issue, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "budget.sh: $*"; }

usage_file() { "$SCRIPT_DIR/statusline.sh" path; }

# --------------------------------------------------------------- projection

# projection: spend so far (costs.total_usd: workers, verifiers and
# orchestrators) plus, for each ticket in scope, what is still to come: its
# whole estimate while queued (a retry pays again) or in flight (its session
# cost is logged when it ends), nothing once it has returned, merged, closed,
# deferred or blocked.
PROJECTION_JQ='
  def r2: (. * 100 | round) / 100;
  def projection:
    . as $s
    | [($s.plan.scope // [])[] as $t
       | ($s.tickets[$t] // {status: "queued", cost_usd: 0}) as $k
       | ($s.plan.tickets[$t].estimate_usd // 0) as $e
       | {ticket: $t, title: ($s.plan.tickets[$t].title // null), status: $k.status,
          attempts: ($k.attempts // 0), estimate: $e, spent: ($k.cost_usd // 0),
          to_come: (if $k.status == "queued" or $k.status == "in_flight" then $e else 0 end)}
       | .over_by = (if .spent > .estimate then .spent - .estimate else 0 end)] as $rows
    | (($s.costs.total_usd // ([$s.tickets[].cost_usd // 0] | add) // 0)) as $spent
    | ([$rows[].to_come] | add // 0) as $come
    | {budget: ($s.plan.budget_usd // null), estimate: ($s.plan.estimate_usd // null),
       allowance_percent: ($s.plan.config.overrun_allowance_percent // 25),
       spent: $spent, to_come: $come, projected: ($spent + $come),
       orchestrators: ($s.costs.orchestrator_usd // 0),
       over: ($s.plan.budget_usd != null and ($spent + $come) > ($s.plan.budget_usd + 0.000001)),
       tickets: $rows};'

project() { get "$PROJECTION_JQ projection"; }

# ---------------------------------------------------------- the usage guard

# running_workers: how many in-flight tickets have a live worker (a runner
# pid that is still there). Nothing running means nothing is spending.
running_workers() {
  local pid= n=0
  for pid in $(get -r '[.tickets[] | select(.status == "in_flight") | .pid // empty] | .[]'); do
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

# worker_readings: a JSON array of every worker's usage.json in this run
# (run-ticket.sh writes it: the latest rate_limit_event, with its own time).
worker_readings() {
  local f=
  for f in "$RUN_DIR"/workers/*/usage.json; do
    [ -s "$f" ] && jq -c 'if type == "object" then . else empty end' "$f" 2>/dev/null
  done | jq -sc '.'
}

# verdict: the plan-window verdict as JSON {ok, window, used, limit,
# resets_at, why} from the freshest reading per window across the status-line
# capture and every worker, and this run's thresholds. With no fresh reading
# from any source: unknown (park) while workers run, and no park while none
# does (nothing is spending); ok then carries idle: true.
verdict() {
  local f= reading= reserve= ceiling= stale= workers= running=
  f=$(usage_file)
  reserve=$(get '.plan.config.usage_reserve.five_hour_reserve_percent // 20')
  ceiling=$(get '.plan.config.usage_reserve.seven_day_ceiling_percent // 90')
  stale=$(get '.plan.config.stale_usage_minutes // 10')
  reading=null
  [ -s "$f" ] && reading=$(jq -c 'if type == "object" then . else null end' "$f" 2>/dev/null || echo null)
  workers=$(worker_readings)
  running=$(running_workers)
  jq -nc --argjson u "$reading" --argjson w "$workers" --argjson running "$running" --arg f "$f" \
    --argjson now "$(date +%s)" \
    --argjson reserve "$reserve" --argjson ceiling "$ceiling" --argjson stale "$stale" '
    def unknown($why): {ok: false, window: "unknown", why: $why, used: null, limit: null, resets_at: null};
    # A window Claude Code dropped (its reset passed) or past its own reset is empty.
    def used($w): if $w == null or (($w.resets_at // 0) > 0 and $w.resets_at <= $now) then 0
                  else ($w.used_percentage // 0) end;
    # Every reading of one window: {source, at, w}. The status line stamps both
    # windows with its capture time; a worker stamps each window it saw.
    def cands($k):
      [(if ($u.rate_limits.at // null) != null then {source: "status-line", at: $u.rate_limits.at, w: ($u.rate_limits[$k] // null)} else empty end),
       ($w[] | select((.rate_limits[$k] // null) != null)
        | {source: "worker", at: (.rate_limits[$k].at // .received_at), w: .rate_limits[$k]})];
    def freshest($k): [cands($k)[] | select(($now - .at) <= ($stale * 60))] | max_by(.at);
    (cands("five_hour") + cands("seven_day")) as $all
    | (freshest("five_hour")) as $f5 | (freshest("seven_day")) as $f7
    | if $f5 == null and $f7 == null then
        if $running == 0 then
          {ok: true, idle: true, window: null, five_hour: 0, seven_day: 0, age_seconds: null,
           why: "no fresh usage reading, and no worker is running, so nothing is spending"}
        elif ($all | length) == 0 then
          if $u == null and ($w | length) == 0 then
            unknown("no usage reading at \($f): the status-line capture is not installed or has not run (statusline.sh install), and no worker has reported one")
          else
            unknown("the usage reading has no plan usage: the status line has not seen rate limits (a claude.ai login, after a first response), and no worker has reported one")
          end
        else
          ($all | max_by(.at)) as $n
          | unknown("the freshest usage reading (\($n.source)) is \((($now - $n.at) / 60) | floor) minutes old; older than \($stale) counts as unknown while \($running) worker(s) run (is a chat with the status line open?)")
        end
      else
        ($f5.w) as $r5 | ($f7.w) as $r7
        | if used($r5) >= (100 - $reserve) then
            {ok: false, window: "five-hour", used: used($r5), limit: (100 - $reserve),
             resets_at: $r5.resets_at, why: "the five-hour window is within the \($reserve)% reserve"}
          elif used($r7) > $ceiling then
            {ok: false, window: "seven-day", used: used($r7), limit: $ceiling,
             resets_at: $r7.resets_at, why: "the seven-day window passed \($ceiling)%"}
          else {ok: true, window: null, five_hour: used($r5), seven_day: used($r7),
                source: ([$f5, $f7] | map(select(. != null)) | max_by(.at) | .source),
                age_seconds: ($now - ([$f5, $f7] | map(select(. != null) | .at) | max))} end
      end'
}

# when epoch -> a local time the Artisan can read, or "unknown".
WHEN_JQ='def when: if . == null then "unknown" else (strflocaltime("%a %d %b %H:%M %Z")) end;'

verdict_line() { # verdict-json
  jq -r "$WHEN_JQ"'
    if .ok and .idle then "ok \(.why)"
    elif .ok then "ok 5h \(.five_hour | floor)% 7d \(.seven_day | floor)%"
    elif .window == "unknown" then "park unknown: \(.why)"
    else "park \(.window) \(.used | floor)% (limit \(.limit)%): \(.why); resets \(.resets_at | when)" end' <<<"$1"
}

cmd_usage() {
  open_run "${1:-}"
  local v=
  v=$(verdict)
  verdict_line "$v"
  [ "$(jq -r .ok <<<"$v")" = true ] || exit 18
}

# park verdict-json: record the park once, with its decision and event.
record_park() {
  apply "$WHEN_JQ"'
    if .usage_park != null then .
    else
      .usage_park = {window: $v.window, used: $v.used, limit: $v.limit, resets_at: $v.resets_at,
                     why: $v.why, at: $now, resume: null}
      | .decisions += [{id: ((.decisions | length) + 1), kind: "usage", window: $v.window,
          resets_at: $v.resets_at,
          options: (if $v.window == "unknown" then ["resume", "stop"] else ["resume", "raise", "stop"] end),
          question: (if $v.window == "unknown"
            then "Dispatch is parked: \($v.why). Resume once a fresh reading is under the limits, or stop?"
            else "Dispatch is parked: \($v.why) (\($v.used | floor)% used). Resume after the reset (\($v.resets_at | when)), raise the ceiling, or stop?" end),
          status: "waiting", at: $now}]
      | event({event: "parked", reason: "usage", window: $v.window, detail: $v.why}; $now)
    end' --argjson v "$1"
}

# unpark how by: the park ends, its decision decided.
clear_park() {
  apply '
    if .usage_park == null then .
    else event({event: "unparked", reason: "usage", window: .usage_park.window, how: $how, by: $by}; $now)
      | .decisions |= map(if .kind == "usage" and .status == "waiting"
                          then .status = "decided" | .choice = $how | .by = $by | .decided_at = $now else . end)
      | .usage_park = null
    end' --arg how "$1" --arg by "$2"
}

# usage_guard: 0 to carry on; otherwise prints the park and exits 18.
usage_guard() {
  local v=
  v=$(verdict)
  if [ "$(get '.usage_park != null')" = true ]; then
    # Parked: only the Artisan's resume (or a raised ceiling) lets dispatch
    # carry on, and then only on a fresh reading under the limits.
    if [ "$(jq -r .ok <<<"$v")" = true ] && [ "$(get '.usage_park.resume != null')" = true ]; then
      clear_park resume "$(get -r '.usage_park.resume.by')"
      return 0
    fi
    get "$WHEN_JQ"'"parked \(.usage_park.window): \(.usage_park.why)"
      + (if .usage_park.resets_at then "; resets \(.usage_park.resets_at | when)" else "" end)
      + (if .usage_park.resume then "; the Artisan said resume: waiting for a fresh reading under the limits" else "; waiting for the Artisan (budget.sh park)" end)'
    exit 18
  fi
  [ "$(jq -r .ok <<<"$v")" = true ] && return 0
  record_park "$v"
  printf 'parked %s\n' "$(verdict_line "$v" | sed 's/^park //')"
  exit 18
}

# ------------------------------------------------------- the overrun gate

open_gate_json() { get -c '[(.overrun_gates // [])[] | select(.status == "open")] | last // empty'; }

# The packet, from the state file and a gate record.
packet() { # gate-json
  jq -r --argjson g "$1" --arg run "$RUN_ID" "$PROJECTION_JQ"'
    def usd: (. * 100 | round) as $c | "$" + (($c / 100 | floor) | tostring) + "." + (($c % 100) | tostring | if length == 1 then "0" + . else . end);
    . as $s | projection as $p
    | [$p.tickets[] | select(.over_by > 0)] as $over
    | ([$p.tickets[] | select(.status == "queued")] | sort_by(-.estimate)) as $queued
    | (($p.projected * (1 + $p.allowance_percent / 100)) * 100 | ceil / 100) as $suggest
    | ($over | map(. as $o
        | "- #\($o.ticket)\(if $o.title then " (" + $o.title + ")" else "" end) has cost \($o.spent | usd) against a \($o.estimate | usd) estimate (\(if $o.estimate > 0 then "+" + (($o.over_by / $o.estimate * 100) | round | tostring) + "%" else "no estimate" end)), \($o.attempts) attempt(s)"
          + ([$s.tickets[$o.ticket].failures[]? | "attempt \(.attempt): \(.reason)"] | if length > 0 then "; failed " + join(", ") else "" end)
          + ([$s.tickets[$o.ticket].evidence.unsure[]?, $s.tickets[$o.ticket].result.notes? // empty | strings] | if length > 0 then "; unsure: " + join("; ") else "" end))) as $uncert
    | "# \($g.title)\n\n"
    + "| Kind | Role needed | Tickets | Blocks |\n|---|---|---|---|\n"
    + "| exception: overrun | Engineering (the Artisan): job 10, the run'"'"'s budget | \($p.tickets | map("#" + .ticket) | join(", ")) | every new dispatch in run \($run); work in flight finishes |\n\n"
    + "**3 decisions, \($uncert | length) uncertaint\(if ($uncert | length) == 1 then "y" else "ies" end).** "
    + "**Problem:** the projected total \($g.projected_usd | usd) crosses the budget \($g.budget_usd | usd) (the estimate \($p.estimate // 0 | usd) plus the \($p.allowance_percent)% overrun allowance). "
    + "**Solution:** choose one option below; dispatch carries on under it. "
    + "**Verification:** spent \($g.spent_usd | usd) when the gate opened (orchestrators \($p.orchestrators | usd)); dollar figures are client-side estimates.\n\n"
    + "## Decisions\n\n"
    + "| Card | Option | Choice | What it does | Answer |\n|---|---|---|---|---|\n"
    + "| 1 | Raise the budget | to \($suggest | usd) (the projection plus the allowance) | dispatch carries on under the new budget | `budget.sh overrun <run> raise <usd>` |\n"
    + "| 2 | Cut scope | \(if $queued == [] then "nothing is queued to cut" else ($queued | map("#" + .ticket + " (" + (.estimate | usd) + ")") | join(", ")) end) | the tickets leave the run (still open on the tracker); what is left must fit the budget | `budget.sh overrun <run> cut <ticket>...` |\n"
    + "| 3 | Stop | end the run | no more dispatch; work in flight finishes, then the run halts | `budget.sh overrun <run> stop` |\n\n"
    + "Each card is product taste, the Artisan'"'"'s alone; no agent chose for you. Alternatives considered: the other two cards.\n\n"
    + "## Uncertainties: discovered complexity\n\n"
    + (if $uncert == [] then "- No ticket has yet cost more than its estimate: the crossing is the projection of what is still to come (\($p.to_come | usd)).\n" else ($uncert | join("\n")) + "\n" end)
    + "\n## Evidence: spend per ticket\n\n"
    + "| Ticket | Status | Estimate | Spent | Still to come | Over by |\n|---|---|---|---|---|---|\n"
    + ($p.tickets | map("| #\(.ticket) | \(.status) | \(.estimate | usd) | \(.spent | usd) | \(.to_come | usd) | \(if .over_by > 0 then "**" + (.over_by | usd) + "**" else "-" end) |") | join("\n"))
    + "\n| orchestrators | | | \($p.orchestrators | usd) | | |\n"
    + "| **run** | | \($p.estimate // 0 | usd) | \($p.spent | usd) | \($p.to_come | usd) | projected \($p.projected | usd) of \($p.budget // 0 | usd) |\n\n"
    + "## Overall action\n\n"
    + "**Defer** is the only action at this gate: it can'"'"'t be approved, bypassed or redirected. Answer with one card; the run carries on under it and this issue stays open until the end gate, where the overrun is reviewed with the run.\n"' "$FILE"
}

# open_overrun projection-json: record the gate once and open its issue.
open_overrun() {
  local p="$1" n= id= title=
  n=$(( $(get '(.overrun_gates // []) | length') + 1 ))
  id="overrun-$n"
  title="Exception gate: overrun (run $RUN_ID)"
  [ "$n" -eq 1 ] || title="Exception gate: overrun $n (run $RUN_ID)"
  apply '
    .overrun_gates = ((.overrun_gates // []) + [{id: $id, kind: "exception", title: $title, issue: null,
        status: "open", gate_actions: ["defer"], opened_at: $now,
        budget_usd: $p.budget, spent_usd: $p.spent, projected_usd: $p.projected,
        tickets_over: [$p.tickets[] | select(.over_by > 0) | {ticket, estimate, spent, over_by}]}])
    | .decisions += [{id: ((.decisions | length) + 1), kind: "overrun", gate: $id, gate_actions: ["defer"],
        options: ["raise", "cut", "stop"],
        question: "\($title): the projected total $\(($p.projected * 100 | round) / 100) crosses the budget $\($p.budget). New dispatch has stopped; work in flight finishes. Raise the budget, cut scope, or stop? (budget.sh packet)",
        status: "waiting", at: $now}]
    | event({event: "overrun-gate", gate: $id, budget: $p.budget, spent: $p.spent, projected: $p.projected,
             tickets_over: [$p.tickets[] | select(.over_by > 0) | .ticket]}; $now)' \
    --arg id "$id" --arg title "$title" --argjson p "$p"
  ensure_issue
}

# ensure_issue: the open gate's review-gate issue, opened once (again after a
# failed open). The packet is kept in gates/<id>.md.
ensure_issue() {
  local g= id= title= dir= body= repo= num= url=
  g=$(open_gate_json)
  [ -n "$g" ] || return 0
  [ "$(jq -r '.issue // empty' <<<"$g")" = "" ] || return 0
  id=$(jq -r .id <<<"$g")
  title=$(jq -r .title <<<"$g")
  dir="$RUN_DIR/gates"
  mkdir -p "$dir"
  body="$dir/$id.md"
  [ -s "$body" ] || packet "$g" >"$body"
  repo=$(get '.repo')
  num=$(gh issue list -R "$repo" --state open --label review-gate --json number,title 2>/dev/null \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty' 2>/dev/null || true)
  if [ -z "$num" ]; then
    url=$(gh issue create -R "$repo" --title "$title" --label review-gate --body "$(cat "$body")" 2>/dev/null) || {
      echo "budget.sh: could not open the overrun gate's issue; the gate holds dispatch all the same and the next guard tries again" >&2
      return 0
    }
    num=${url##*/}
  fi
  apply '.overrun_gates |= map(if .id == $id then .issue = $num else . end)
         | .decisions |= map(if .kind == "overrun" and .gate == $id then .issue = $num else . end)' \
    --arg id "$id" --argjson num "$num"
}

overrun_line() { # gate-json
  jq -r '"overrun \(if .issue then "#" + (.issue | tostring) else "(issue not yet open)" end): projected $\((.projected_usd * 100 | round) / 100) crosses the budget $\(.budget_usd); no new dispatch until the Artisan answers the overrun gate (budget.sh overrun)"' <<<"$1"
}

budget_guard() {
  local g= p=
  g=$(open_gate_json)
  if [ -n "$g" ]; then
    ensure_issue
    overrun_line "$(open_gate_json)"
    exit 17
  fi
  p=$(project)
  [ "$(jq -r .over <<<"$p")" = true ] || return 0
  open_overrun "$p"
  overrun_line "$(open_gate_json)"
  exit 17
}

cmd_guard() {
  open_run "${1:-}"
  [ "$(get '.halted != null')" = false ] \
    || state_die 12 "budget.sh: the run is halted: $(get '.halted.reason'); nothing dispatches"
  usage_guard
  budget_guard
  get "$PROJECTION_JQ"'projection as $p | "ok: spent $\($p.spent | r2), projected $\($p.projected | r2) of $\($p.budget // "?") budget"'
}

# ------------------------------------------------------ the Artisan answers

parse_by() { # sets BY WHY ACTION from the remaining args; ARGS gets the rest
  BY=Artisan WHY= ACTION=defer ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; BY=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; WHY=$2; shift 2 ;;
      --action) [ $# -ge 2 ] || usage; ACTION=$2; shift 2 ;;
      --*) usage ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
}

is_usd() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }

cmd_overrun() {
  open_run "${1:-}"
  local opt="${2:-}" g= id= issue= p= new= t= status= repo=
  [ -n "$opt" ] || usage
  shift 2
  parse_by "$@"
  [ "$ACTION" = defer ] \
    || state_die 6 "budget.sh: the overrun gate can only be deferred; '$ACTION' is not an action it has (answer with raise, cut or stop)"
  g=$(open_gate_json)
  [ -n "$g" ] || state_die 6 "budget.sh: no overrun gate is open in run $RUN_ID"
  id=$(jq -r .id <<<"$g")
  issue=$(jq -r '.issue // empty' <<<"$g")
  case "$opt" in
    raise)
      [ "${#ARGS[@]}" -eq 1 ] && is_usd "${ARGS[0]}" || usage
      new=${ARGS[0]}
      p=$(project)
      [ "$(jq -r --argjson b "$new" '.projected <= $b + 0.000001' <<<"$p")" = true ] \
        || state_die 6 "budget.sh: \$$new is still under the projected total \$$(jq -r '(.projected * 100 | round) / 100' <<<"$p"); raise to at least that, cut scope, or stop"
      apply '.plan.budget_history = ((.plan.budget_history // []) + [{from: .plan.budget_usd, to: $new, gate: $id, by: $by, at: $now}])
             | .plan.budget_usd = $new' --argjson new "$new" --arg id "$id" --arg by "$BY"
      ;;
    cut)
      [ "${#ARGS[@]}" -ge 1 ] || usage
      for t in "${ARGS[@]}"; do
        status=$(get --arg t "$t" 'if (.plan.scope | index($t)) == null then "outside" else (.tickets[$t].status // "queued") end')
        [ "$status" = queued ] \
          || state_die 6 "budget.sh: #$t is $status; only a queued ticket can be cut (work in flight finishes)"
      done
      p=$(get --argjson cut "$(printf '%s\n' "${ARGS[@]}" | jq -R . | jq -s .)" \
            "$PROJECTION_JQ"'.plan.scope -= $cut | projection')
      [ "$(jq -r .over <<<"$p")" = false ] \
        || state_die 6 "budget.sh: without $(printf '#%s ' "${ARGS[@]}")the projection is still \$$(jq -r '(.projected * 100 | round) / 100' <<<"$p") of \$$(jq -r .budget <<<"$p"); cut more, raise the budget, or stop"
      apply '.plan.scope -= $cut
             | reduce $cut[] as $t (.; .tickets[$t] = ((.tickets[$t] // new_ticket($t)) + {status: "deferred", cut: {gate: $id, by: $by, at: $now}}))
             | .frontier = ((.frontier // []) - $cut)' \
        --argjson cut "$(printf '%s\n' "${ARGS[@]}" | jq -R . | jq -s .)" --arg id "$id" --arg by "$BY"
      repo=$(get '.repo')
      for t in "${ARGS[@]}"; do
        gh issue comment "$t" -R "$repo" --body "Cut from run $RUN_ID at its overrun gate${issue:+ (#$issue)} by $BY. The ticket stays open for a later run." >/dev/null 2>&1 \
          || echo "budget.sh: could not comment on #$t" >&2
        gh issue edit "$t" -R "$repo" --remove-label in-run >/dev/null 2>&1 || true
      done
      ;;
    stop)
      [ "${#ARGS[@]}" -eq 0 ] || usage
      apply '.halted = {wave: current_wave, tickets: [], at: $now, reason: "stopped at the overrun gate (\($id)) by \($by)"}
             | event({event: "halted", wave: current_wave, tickets: [], reason: "overrun-stop"}; $now)' \
        --arg id "$id" --arg by "$BY"
      ;;
    *) usage ;;
  esac
  local choice= card=
  case "$opt" in
    raise) choice="raise the budget to \$${ARGS[0]}" card=1 ;;
    cut) choice="cut $(printf '#%s ' "${ARGS[@]}" | sed 's/ $//')" card=2 ;;
    *) choice="stop the run" card=3 ;;
  esac
  apply '
    .overrun_gates |= map(if .id == $id then .status = "deferred" | .action = "defer"
        | .decision = {card: $card, option: $opt, choice: $choice, why: (if $why == "" then null else $why end),
                       by: $by, job: 10, at: $now} | .deferred_at = $now else . end)
    | .decisions |= map(if .kind == "overrun" and .gate == $id and .status == "waiting"
        then .status = "decided" | .choice = $choice | .by = $by | .decided_at = $now else . end)
    | event({event: "overrun-decision", gate: $id, option: $opt, choice: $choice, by: $by, action: "defer"}; $now)' \
    --arg id "$id" --arg opt "$opt" --arg choice "$choice" --arg by "$BY" --arg why "$WHY" \
    --argjson card "$card"
  if [ -n "$issue" ]; then
    gh issue comment "$issue" -R "$(get '.repo')" --body "$(printf '%s\n\n| Card | Choice | By | Why |\n|---|---|---|---|\n| %s | %s | %s | %s |\n\nGate action: **defer** (the only one this gate has). This issue stays open until the end gate.\n\n```json\n%s\n```' \
      "Overrun gate answered." "$opt" "$choice" "$BY" "${WHY:--}" \
      "$(get -c --arg id "$id" '.overrun_gates[] | select(.id == $id) | .decision')")" >/dev/null 2>&1 \
      || echo "budget.sh: could not post the decision on #$issue" >&2
  fi
  echo "deferred ${issue:+#$issue }$id: $choice"
}

cmd_park() {
  open_run "${1:-}"
  local opt="${2:-}" window= pct= v= key= value= cur=
  [ -n "$opt" ] || usage
  shift 2
  parse_by "$@"
  [ "$(get '.usage_park != null')" = true ] || state_die 6 "budget.sh: run $RUN_ID is not parked on plan usage"
  window=$(get -r '.usage_park.window')
  case "$opt" in
    resume)
      [ "${#ARGS[@]}" -eq 0 ] || usage
      apply '.usage_park.resume = {by: $by, at: $now, after: .usage_park.resets_at}
             | event({event: "resume-asked", reason: "usage", by: $by}; $now)' --arg by "$BY"
      ;;
    raise)
      [ "${#ARGS[@]}" -eq 1 ] || usage
      pct=${ARGS[0]}
      state_is_uint "$pct" || usage
      [ "$pct" -le 100 ] || usage
      case "$window" in
        seven-day)
          key=usage_reserve.seven_day_ceiling_percent value=$pct
          cur=$(get '.plan.config.usage_reserve.seven_day_ceiling_percent // 90')
          [ "$pct" -gt "$cur" ] || state_die 6 "budget.sh: the seven-day ceiling is already $cur%; raise it above that"
          ;;
        five-hour)
          key=usage_reserve.five_hour_reserve_percent value=$((100 - pct))
          cur=$(get '.plan.config.usage_reserve.five_hour_reserve_percent // 20')
          [ "$value" -lt "$cur" ] || state_die 6 "budget.sh: the five-hour ceiling is already $((100 - cur))%; raise it above that"
          ;;
        *) state_die 6 "budget.sh: the reading is unknown, so there is no ceiling to raise; resume (once a fresh reading is under the limits) or stop" ;;
      esac
      "$SCRIPT_DIR/state.sh" override "$RUN_DIR" "$key" "$value" >/dev/null
      apply '.usage_park.resume = {by: $by, at: $now, after: null, raised: {key: $key, value: $value}}
             | event({event: "ceiling-raised", key: $key, value: $value, by: $by}; $now)' \
        --arg by "$BY" --arg key "$key" --argjson value "$value"
      ;;
    stop)
      [ "${#ARGS[@]}" -eq 0 ] || usage
      apply '.halted = {wave: current_wave, tickets: [], at: $now, reason: "stopped at the usage guard by \($by)"}
             | event({event: "halted", wave: current_wave, tickets: [], reason: "usage-stop"}; $now)' --arg by "$BY"
      clear_park stop "$BY"
      echo "stopped: the run halts; work in flight finishes"
      return 0
      ;;
    *) usage ;;
  esac
  v=$(verdict)
  if [ "$(jq -r .ok <<<"$v")" = true ]; then
    clear_park "$opt" "$BY"
    echo "resumed: $(verdict_line "$v")"
  else
    get "$WHEN_JQ"'"resume recorded: dispatch carries on once a fresh reading is under the limits"
      + (if .usage_park.resets_at then " (the window resets \(.usage_park.resets_at | when))" else "" end)'
  fi
}

# --------------------------------------------------------------------- main

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  guard) [ $# -eq 1 ] || usage; cmd_guard "$1" ;;
  usage) [ $# -eq 1 ] || usage; cmd_usage "$1" ;;
  project) [ $# -eq 1 ] || usage; open_run "$1"; project ;;
  packet)
    [ $# -eq 1 ] || usage
    open_run "$1"
    g=$(get -c '(.overrun_gates // []) | last // empty')
    [ -n "$g" ] || state_die 1 "budget.sh: run $RUN_ID has no overrun gate"
    if [ -s "$RUN_DIR/gates/$(jq -r .id <<<"$g").md" ]; then cat "$RUN_DIR/gates/$(jq -r .id <<<"$g").md"; else packet "$g"; fi
    ;;
  overrun) cmd_overrun "$@" ;;
  park) cmd_park "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
