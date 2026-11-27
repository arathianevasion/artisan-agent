#!/usr/bin/env bash
# The sweep: check every in-flight ticket and log new findings.
# Field meanings: ${CLAUDE_PLUGIN_ROOT}/references/state-file.md
#
# Usage: sweep.sh <run-dir> [--no-guard]
#        sweep.sh repair <run-dir> [--dry-run]
#
# First, a queued ticket with a wave whose next attempt has a runner
# (workers/<ticket>.<attempt>/runner.pid) was launched by a dispatch stopped
# before it recorded the launch: it is recorded now, as dispatched (#190).
# For each ticket whose status is in_flight, in this order:
#   1. a result file results/<ticket>.<attempt>.result.json -> the result is recorded
#        (status "complete" -> returned, "blocked" -> blocked, "failed" -> failed attempt)
#   2. an exit record results/<ticket>.<attempt>.exit.json and no result -> failed attempt
#   3. past its deadline -> the worker is stopped, failed attempt
#   4. its worker pid is no longer alive -> failed attempt
# Two requests are read from files the chat leaves while a wave holds the
# lock (scripts/lever.sh): an attempt the Artisan stopped
# (steering/<ticket>.<attempt>.json) is steering, not a failed attempt, and
# work they approved (levers/*.json) joins the run.
# A failed attempt sends the ticket back to queued, or, once it has used the
# run's attempts per ticket, to blocked with an exception decision queued for
# the Artisan. New lines in results/findings/<ticket>.jsonl join the findings
# log. Running it again on the same files changes nothing.
# Then it runs the plan-window and budget guard (budget.sh guard, #120): the
# orchestrator's sweep is where a usage park or the overrun gate is noticed.
# The reconciler and findings.sh pass --no-guard: wave.sh status reads only.
# The guard's refusal (12, 17, 18) is not the sweep's: it prints it and goes on.
# Between the two, it tries again every board add that failed when its issue
# was opened (tracker.sh board-retry, #146); its lines go to stderr. Then it
# deletes on the remote the ticket branches the run pushed whose tickets are
# done, retrying any delete that failed (pushed.sh prune, #211; stderr too).
# Then it files each open decision a verifier named in its verdict (#230;
# verify.sh judge keeps them on the verification) through questions.sh, split
# and raised by the verifier, once: the question's number is recorded on it,
# and one the same ticket's verifiers already filed (same case and harm) takes
# that number. The ticket is never blocked by it and its verdict stands. A
# filing that fails is said on stderr and tried again at the next sweep.
#
# repair (#151) mends a run hit by the stream-json miscount: the runner found
# a session's result event by the start of its line, current claude writes
# "type" after other keys, so output.json came out empty and every finished
# worker was judged crashed (a failed attempt, no cost). For every ended
# session (an exit record) whose output.json holds no result event, it
# rebuilds output.json from the saved stream.jsonl. Then every failed attempt
# that now classifies as completed, with a result file saying complete, is
# taken back: the failure leaves tickets.<t>.failures (kept under
# tickets.<t>.repaired), the attempt is given back (extra_attempts), its cost
# is recorded, and when it was the ticket's latest attempt and the ticket is
# queued, blocked by its failures or deferred at its exception gate, it is
# returned with its result, as the sweep would have left it. An
# exception decision the miscount queued and no gate carries yet is decided
# "resolved by repair"; an exception gate already open for the ticket is named
# with the command that closes it as resolved by the repair (gate-action.sh
# repaired), never as an Artisan bypass. An ended orchestrator with no cost
# gets its cost. Running it again changes nothing. It never runs the guard.
# --dry-run (#154) takes no lock and writes nothing: it runs the same repair
# on a scratch copy of the run (the copy leaves the lock behind) and prints
# the lines the real repair would print, then "dry run: nothing written".
# Run it first on a live run; the real repair prints exactly those lines.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the lock is held by another live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/stream-lib.sh
. "$SCRIPT_DIR/lib/stream-lib.sh"
state_require_jq

GUARD=1 guard_rc=0 guard_out= MODE=sweep DRY=0 scratch=
if [ "${1:-}" = repair ]; then
  MODE=repair GUARD=0
  shift
  if [ "${1:-}" = --dry-run ]; then DRY=1; shift
  elif [ "${2:-}" = --dry-run ]; then DRY=1; set -- "$1"; fi
fi
if [ "$MODE" = sweep ] && [ "${2:-}" = --no-guard ]; then GUARD=0; set -- "$1"; fi
[ $# -eq 1 ] || state_usage "$0"
RUN_DIR=$1
state_require_run_dir "$RUN_DIR"
SHOWN_DIR=$RUN_DIR   # the run as the Artisan names it, in printed commands
RESULTS="$RUN_DIR/results"

# The pid and every process descended from it.
process_tree() {
  local pid="$1" child=
  printf '%s\n' "$pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    process_tree "$child"
  done
}

# Stop a worker and everything it started (run-ticket.sh -> claude -> tools):
# TERM the whole tree, then KILL whatever is left after the grace period.
stop_worker() {
  local pid="$1" tree= p= alive= waited=0
  state_pid_alive "$pid" || return 0
  tree=$(process_tree "$pid")
  for p in $tree; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$waited" -lt "${ARTISAN_STOP_GRACE:-5}" ]; do
    alive=0
    for p in $tree; do state_pid_alive "$p" && alive=1; done
    [ "$alive" -eq 1 ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  for p in $tree; do kill -KILL "$p" 2>/dev/null || true; done
}

# A failed attempt for ticket $t; jq args: --arg t, --arg reason, --argjson now.
FAIL_FILTER="$STATE_JQ_DEFS"'failed_attempt($t; $reason; $now)'

# An environment failure (#423): the worker's record says the machine it
# depends on broke (the suite host's build, a tool not on PATH there), not
# its code. Another attempt would fail the same way, so none is queued and
# none is counted: the ticket is blocked with an exception decision (reason
# "environment") for the Artisan, who fixes the host and retries it
# (gate-action.sh retry gives the attempt back). jq args as FAIL_FILTER, and
# --arg why.
ENV_FILTER="$STATE_JQ_DEFS"'
  ("environment failure: " + $why) as $r
  | .tickets[$t] |= (.status = "blocked" | .pid = null | .blocked_reason = $r
      | .environment = {status: "open", attempt: .attempts, why: $why})
  | .decisions += [{id: ((.decisions | length) + 1), kind: "exception", reason: "environment", ticket: $t,
      question: "Ticket \($t) stopped on its environment, not its code: \($why). No attempt was counted. Fix it and retry, take it myself or drop; or bypass or defer its exception gate?",
      status: "waiting", at: $now}]
  | event({event: "environment-failure", ticket: $t, attempt: .tickets[$t].attempts, why: $why}; $now)'

RESULT_FILTER="$STATE_JQ_DEFS"'
  $rs[0] as $r
  | ($r.status // "complete") as $s
  | .tickets[$t] |= (
      .result = {status: $s, commit: ($r.commit // null), notes: ($r.notes // null),
                 file: $file}
      | .pid = null)
  | attempt_cost($t; .tickets[$t].attempts; ($r.cost_usd // $r.total_cost_usd // $session_cost))
  | event({event: "result", ticket: $t, attempt: .tickets[$t].attempts, status: $s}; $now)
  | if $s == "failed" then .
    elif $s == "blocked" then
      .tickets[$t].status = "blocked"
      # A worker that needed a design or interface change stopped and recorded
      # the question: it goes to the Artisan, and the run notes a slicing lesson.
      | if ($r.design_question | type) == "object" then
          .decisions += [{id: ((.decisions | length) + 1), kind: "design", ticket: $t,
                          question: ($r.design_question.question // "a design question"),
                          recommendation: ($r.design_question.recommendation // null),
                          status: "waiting", at: $now}]
          | .lessons = ((.lessons // []) + [{kind: "slicing", ticket: $t, at: $now,
              note: "Ticket \($t) could not be built without a design or interface change owned elsewhere: \($r.design_question.question // "see its result"). Slice so the design settles before the work that needs it."}])
          | event({event: "design-question", ticket: $t}; $now)
        else . end
    else .tickets[$t].status = "returned" end'

# The in-flight tickets as the sweep's loop reads them: a line each.
IN_FLIGHT_ROWS='([.tickets | to_entries[] | select(.value.status == "in_flight")
    | "\(.key)\u001f\(.value.pid // "")\u001f\(.value.attempts)\u001f\(.value.deadline_at // "")\n"] | add // "")'

sweep() {
  local file= tmp= now= tickets= t= status= pid= attempt= deadline= result= exit_record= session_cost=
  file=$(state_file "$RUN_DIR")
  # The check goes with the first read below when no lever request comes
  # first (#185); with one, it is checked here, before the request is applied.
  local levers=""
  for levers in "$RUN_DIR"/levers/*.json; do [ -f "$levers" ] && break; levers=""; done
  [ -z "$levers" ] || state_valid_file "$file" || state_die 1 "$(state_version_message "$file")"
  tmp=$(state_tmp "$RUN_DIR")
  cp "$file" "$tmp"
  now=$(state_now)

  step() { state_step "$tmp" "$@"; }

  # Work the Artisan approved while a wave held the lock (lever.sh add and
  # urgent leave a request in levers/): it joins the run now.
  local req=
  for req in "$RUN_DIR"/levers/*.json; do
    [ -f "$req" ] || continue
    step "$STATE_JQ_DEFS"'scope_add($r[0]; $now)' --slurpfile r "$req" --argjson now "$now"
  done

  # A launch never recorded (#190): wave.sh dispatch writes the ticket's wave
  # before it starts the worker and records the launch after, so a stop in
  # between (the orchestrator stopped at its deadline) leaves a queued ticket
  # with a wave whose next attempt has a runner. That attempt is taken in as
  # dispatched, so the checks below see it.
  # One read for the loop (#185): ticket and attempts, a line each. A step
  # here changes only its own ticket.
  # The in-flight rows below come with this read, unless a launch is taken in.
  local next="" runner="" rows="" n="" ok="" flying="" flown=""
  if ! state_fields "$tmp" ok rows flying -- 'if type == "object" and .schema_version == $v
      then [true, ([.tickets | to_entries[] | select(.value.status == "queued" and (.value.wave // 0) > 0)
        | "\(.key)\u001f\(.value.attempts)\n"] | add // ""), '"$IN_FLIGHT_ROWS"'] else [false, "", ""] end' \
      --argjson v "$ARTISAN_STATE_SCHEMA_VERSION" 2>/dev/null || [ "$ok" != true ]; then
    state_valid_file "$file" || { rm -f "$tmp"; state_die 1 "$(state_version_message "$file")"; }
    # A state file of this version whose tickets can't be listed: none to take in.
    rows=
  else
    flown=1
  fi
  while IFS=$'\x1f' read -r t n; do
    [ -n "$t" ] || continue
    next=$(( $n + 1 ))
    runner=$(cat "$RUN_DIR/workers/$t.$next/runner.pid" 2>/dev/null) || runner=""
    state_is_uint "$runner" || continue
    step "$STATE_JQ_DEFS"'
      # The deadline wave.sh dispatch would have recorded: the cap, else twice
      # the expected minutes (every dispatch has one, state.sh dispatch).
      ($now + (.plan.tickets[$t].caps.deadline_seconds // ((.plan.tickets[$t].expected.minutes // 30) * 120))) as $deadline
      | .tickets[$t] |= (.status = "in_flight" | .attempts += 1 | .pid = $pid
          | .dispatched_at = $now | .deadline_at = $deadline | .result = null)
      | event({event: "dispatch", ticket: $t, attempt: .tickets[$t].attempts, pid: $pid, unrecorded: true}; $now)' \
      --arg t "$t" --argjson pid "$runner" --argjson now "$now"
    flown=
  done <<<"$rows"

  # The in-flight tickets with their pid, attempt and deadline, in one read
  # (#185); a step below changes only its own ticket.
  local result_status=""
  if [ -n "$flown" ]; then rows=$flying
  else state_fields "$tmp" rows -- '['"$IN_FLIGHT_ROWS"']'; fi
  while IFS=$'\x1f' read -r t pid attempt deadline <&3; do
    [ -n "$t" ] || continue
    result="$RESULTS/$t.$attempt.result.json"
    exit_record="$RESULTS/$t.$attempt.exit.json"
    # The result's status comes with the check that it is an object.
    if [ -f "$result" ] && state_fields "$result" result_status -- \
      'if type == "object" then [.status // "complete"] else error end' 2>/dev/null; then
      # The worker does not write its cost; its session's JSON output does.
      session_cost=$(jq -c '.total_cost_usd // null' "$RUN_DIR/workers/$t.$attempt/output.json" 2>/dev/null || echo null)
      [ -n "$session_cost" ] || session_cost=null
      step "$RESULT_FILTER" --arg t "$t" --slurpfile rs "$result" --arg file "results/$t.$attempt.result.json" \
        --argjson now "$now" --argjson session_cost "$session_cost"
      status=$result_status
      if [ "$status" = "failed" ]; then
        local env_why=""
        env_why=$(jq -r 'if (.environment | type) == "object" then (.environment.why // "no reason given") | tostring
                         else "" end' "$result" 2>/dev/null) || env_why=""
        if [ -n "$env_why" ]; then
          step "$ENV_FILTER" --arg t "$t" --arg why "$env_why" --argjson now "$now"
        else
          step "$FAIL_FILTER" --arg t "$t" --arg reason "worker reported failed" --argjson now "$now"
        fi
      fi
    elif [ -f "$exit_record" ]; then
      session_cost=$(jq -c '.total_cost_usd // null' "$RUN_DIR/workers/$t.$attempt/output.json" 2>/dev/null || echo null)
      [ -n "$session_cost" ] || session_cost=null
      step "$STATE_JQ_DEFS"'attempt_cost($t; .tickets[$t].attempts; $usd)' --arg t "$t" --argjson usd "$session_cost"
      if [ -f "$RUN_DIR/steering/$t.$attempt.json" ]; then
        # The Artisan stopped this attempt (lever.sh steer): steering, not a failure.
        step "$STATE_JQ_DEFS"'steered($t; $note; $now)' --arg t "$t" --argjson now "$now" \
          --arg note "$(jq -r '.note // ""' "$RUN_DIR/steering/$t.$attempt.json")"
      else
        step "$FAIL_FILTER" --arg t "$t" --arg reason "exited without a result" --argjson now "$now"
      fi
    elif [ -n "$deadline" ] && [ "$now" -gt "$deadline" ]; then
      [ -n "$pid" ] && stop_worker "$pid"
      step "$FAIL_FILTER" --arg t "$t" --arg reason "past deadline; stopped" --argjson now "$now"
    elif ! state_pid_alive "$pid" && [ ! -f "$exit_record" ] && [ ! -f "$result" ]; then
      # Gone, and still no record on a second look (the runner writes its
      # exit record and then exits, so a first look can be too early).
      step "$FAIL_FILTER" --arg t "$t" --arg reason "worker gone without a result or exit record" --argjson now "$now"
    fi
  done 3<<<"$rows"

  # Findings: append lines beyond what has been read, per ticket.
  local f= ticket= total= seen=
  for f in "$RESULTS"/findings/*.jsonl; do
    [ -f "$f" ] || continue
    ticket=$(basename "$f" .jsonl)
    # Complete lines only: a line still being written has no newline yet.
    total=$(wc -l <"$f" | tr -d ' ')
    seen=$(jq -r --arg t "$ticket" '.findings_read[$t] // 0' "$tmp")
    [ "$total" -gt "$seen" ] || continue
    # The new lines reach jq on stdin (--rawfile raw /dev/stdin), not as an
    # argument: they grow with the worker's findings (#264).
    step "$STATE_JQ_DEFS"'
      ($raw | rtrimstr("\n") | split("\n")) as $lines
      | .findings += ($lines | to_entries | map(
        {from: $t, seq: ($seen + .key + 1)}
        + ((.value | try fromjson catch null) as $j
           | if ($j | type) == "object" then $j else {raw: .value} end)))
      | .findings_read[$t] = $total
      # A worker filing a criterion-2 question is the scope floor firing
      # (#148). The read counter makes this once per question, not per sweep.
      | reduce ($lines | map(try fromjson catch null)[]
                | select(type == "object" and .kind == "question" and ((.criterion // "") | tostring) == "2")) as $q (.;
          event({event: "guardrail-fired", guardrail: "scope-floor", ticket: $t,
                 areas: ticket_areas([$t]), question: ($q.ticket | tostring)}; $now))
      # A worker filing an open decision (criterion 8, #227), unless
      # questions.sh logged it itself (--run).
      | reduce ($lines | map(try fromjson catch null)[]
                | select(type == "object" and .kind == "question" and ((.criterion // "") | tostring) == "8"
                         and .guardrail_logged != true)) as $q (.;
          (($q.about // $t) | tostring) as $a
          | event({event: "guardrail-fired", guardrail: "open-decision", ticket: $a,
                   raised_by: ($q.raised_by // "worker"), case: $q.case, question: ($q.ticket | tostring),
                   areas: ticket_areas([$a])} + (if $a == $t then {} else {from: $t} end); $now))
      # One a worker found in another ticket of the run (#231) sits on that
      # ticket, not blocking it, so questions.sh sync reads its ruling.
      | reduce ($lines | map(try fromjson catch null)[]
                | select(type == "object" and .kind == "question" and ((.criterion // "") | tostring) == "8"
                         and .raised_by == "finding" and .ticket != null)) as $q (.;
          (($q.about // "") | tostring) as $a | ($q.ticket | tostring) as $n
          | if $a == "" or $a == $t or .tickets[$a] == null
               or any(.tickets[$a].questions[]?; .ticket == $n) then .
            else .tickets[$a].questions = ((.tickets[$a].questions // [])
                   + [{ticket: $n, blocking: false, state: "open", raised_by: "finding", from: $t, at: $now}]) end)' \
      --arg t "$ticket" --argjson seen "$seen" --argjson total "$total" --argjson now "$now" \
      --rawfile raw /dev/stdin < <(awk -v from="$seen" -v to="$total" 'NR > from && NR <= to' "$f")
  done

  state_finish "$RUN_DIR" "$tmp" '.costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
        | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)'
}

# A failed attempt taken back by the repair: its failure entries move to
# tickets.<t>.repaired, the attempt it used is given back (extra_attempts, as
# a retry grants one), its cost is recorded (the result file's own first, as
# the sweep does), and the latest attempt of a ticket its failures queued,
# blocked or left deferred at its exception gate is returned with its result.
REPAIR_FILTER="$STATE_JQ_DEFS"'
  ([.tickets[$t].failures[]? | select(.attempt == $n)]) as $taken
  | $rs[0] as $r
  | ($r.cost_usd // $r.total_cost_usd // $usd) as $usd
  | .tickets[$t].failures |= map(select(.attempt != $n))
  | .tickets[$t].extra_attempts = ((.tickets[$t].extra_attempts // 0) + 1)
  | attempt_cost($t; $n; $usd)
  | .tickets[$t].repaired = ((.tickets[$t].repaired // []) + [{attempt: $n, cost_usd: $usd, failures: $taken, at: $now}])
  | event({event: "repaired", ticket: $t, attempt: $n, cost_usd: $usd, failures_taken_back: ($taken | length)}; $now)
  | .tickets[$t] as $tk
  | if $n == $tk.attempts and ($tk.status == "queued"
        or ($tk.status == "blocked" and $tk.blocked_reason == null)
        or ($tk.status == "deferred" and $tk.cut == null)) then
      .tickets[$t] |= (.status = "returned" | .pid = null
          | .result = {status: "complete", commit: ($r.commit // null), notes: ($r.notes // null), file: $file})
      | reduce ([.decisions[] | select(.kind == "exception" and .ticket == $t and .status == "waiting" and .issue == null) | .id][]) as $id
          (.; decide($id; {job: 15, choice: "resolved by repair", by: "sweep.sh repair"}; $now))
    else . end'

repair() {
  local file="" tmp="" now="" d="" key="" out="" pair="" t="" n="" cls="" usd="" result="" id="" a="" gates="" failed_why=""
  local -a returned=()
  file=$(state_file "$RUN_DIR")
  # The check goes with the first read below when no lever request comes
  # first (#185); with one, it is checked here, before the request is applied.
  local levers=""
  for levers in "$RUN_DIR"/levers/*.json; do [ -f "$levers" ] && break; levers=""; done
  [ -z "$levers" ] || state_valid_file "$file" || state_die 1 "$(state_version_message "$file")"
  tmp=$(state_tmp "$RUN_DIR")
  cp "$file" "$tmp"
  now=$(state_now)

  step() { state_step "$tmp" "$@"; }

  # 1. output.json from the saved stream, for every ended session left without one.
  for d in "$RUN_DIR"/workers/*/; do
    d=${d%/}
    key=$(basename "$d")
    [ -f "$d/stream.jsonl" ] && [ -f "$RESULTS/$key.exit.json" ] || continue
    ! jq -e 'type == "object" and .type == "result"' "$d/output.json" >/dev/null 2>&1 || continue
    out=$(stream_result "$d/stream.jsonl")
    [ -n "$out" ] || continue
    printf '%s\n' "$out" >"$d/output.json"
    echo "rebuilt workers/$key/output.json"
  done

  # 2. Failed attempts that in fact completed are taken back.
  for pair in $(jq -r '.tickets | to_entries[] | .key as $t | [.value.failures[]?.attempt] | unique[] | "\($t):\(.)"' "$tmp"); do
    t=${pair%:*} n=${pair##*:}
    cls=$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$n" 2>/dev/null) || continue
    [ "$cls" = "completed -" ] || continue
    result="$RESULTS/$t.$n.result.json"
    [ "$(jq -r '.status // "complete"' "$result" 2>/dev/null)" = complete ] || continue
    usd=$(jq -c '.total_cost_usd // null' "$RUN_DIR/workers/$t.$n/output.json" 2>/dev/null || echo null)
    [ -n "$usd" ] || usd=null
    failed_why=$(jq -r --arg t "$t" --argjson n "$n" '[.tickets[$t].failures[]? | select(.attempt == $n) | .reason] | join("; ")' "$tmp")
    step "$REPAIR_FILTER" --arg t "$t" --argjson n "$n" --argjson usd "$usd" --slurpfile rs "$result" \
      --arg file "results/$t.$n.result.json" --argjson now "$now"
    if [ "$(jq -r --arg t "$t" '.tickets[$t].status' "$tmp")" = returned ]; then
      returned+=("$t")
      echo "#$t attempt $n completed: result $(jq -r '.status // "complete"' "$result"), cost $usd recorded; failure moves to repaired ($failed_why); attempt given back; #$t returned"
    else
      echo "#$t attempt $n completed: result $(jq -r '.status // "complete"' "$result"), cost $usd recorded; failure moves to repaired ($failed_why); attempt given back"
    fi
  done

  # 3. An ended orchestrator whose cost the empty output.json hid.
  for pair in $(jq -r '(.orchestrators // [])[] | select(.cost_usd == null) | "\(.id):\(.attempt)"' "$tmp"); do
    id=${pair%:*} a=${pair##*:}
    [ -f "$RESULTS/$id.$a.exit.json" ] || continue
    usd=$(jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$id.$a/output.json" 2>/dev/null || true)
    [ -n "$usd" ] || continue
    step '(.orchestrators | map(.id == $id and .attempt == $a) | index(true)) as $i
      | .orchestrators[$i].cost_usd = $usd | .costs.orchestrator_usd += $usd' \
      --arg id "$id" --argjson a "$a" --argjson usd "$usd"
    echo "orchestrator $id attempt $a: cost $usd recorded"
  done

  step '.costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
        | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)'

  # 4. The exception gates the miscount opened, with the way to close them.
  for t in ${returned[@]+"${returned[@]}"}; do
    gates=$(jq -r --arg t "$t" '(.exception_gates // [])[] | select(.ticket == $t and (.status == "open" or .status == "deferred")) | .issue' "$tmp")
    for id in $gates; do
      echo "exception gate #$id was opened by the miscount: close it as resolved by the repair with gate-action.sh repaired $SHOWN_DIR $id"
    done
  done

  state_commit "$RUN_DIR" "$tmp"
}

# The open decisions verifiers named and the sweep has not filed (#230), one
# per line: ticket, verifier attempt, index, then the case, harm and
# recommendation as JSON strings. Each is filed split, raised by the
# verifier, with the run named so questions.sh logs guardrail-fired; then its
# number is recorded. A crash between the two files it again next sweep.
file_verifier_open_decisions() {
  local file="" pending="" t="" v="" k="" cj="" hj="" rj="" c="" h="" r="" q="" repo="" how=""
  file=$(state_file "$RUN_DIR")
  # The repo and the pending lines in one read (#185).
  state_fields "$file" repo pending -- '[.repo // "",
    ([.tickets | to_entries[] | .key as $t | (.value.verifications // [])[] | .attempt as $v
      | (.open_decisions // []) | to_entries[] | select(.value.question == null)
      | [$t, ($v | tostring), (.key | tostring), (.value.case | tojson), (.value.harm | tojson), (.value.recommendation | tojson)]
      | join("\t") + "\n"] | add // "")]' || return 0
  [ -n "$pending" ] || return 0
  # Each line is read on fd 3, so nothing the filing runs can eat the rest.
  while IFS="$(printf '\t')" read -r t v k cj hj rj <&3; do
    c=$(printf '%s' "$cj" | jq -r .) h=$(printf '%s' "$hj" | jq -r .) r=$(printf '%s' "$rj" | jq -r .)
    # The same open decision from an earlier verifier of the ticket: its
    # number (compared as JSON, so a trailing newline still matches).
    q=$(jq -r --arg t "$t" --arg c "$c" --arg hj "$hj" '[(.tickets[$t].verifications // [])[] | (.open_decisions // [])[]
        | select(.question != null and .case == $c and (.harm | tojson) == $hj) | .question] | first // ""' "$file")
    how="already filed as #$q"
    if [ -z "$q" ]; then
      how="filed as"
      q=$(ARTISAN_FINDINGS_FILE='' "$SCRIPT_DIR/questions.sh" file --ticket "$t" --criterion 8 --case "$c" --harm "$h" \
            --recommendation "$r" --split --raised-by verifier --run "$RUN_DIR" ${repo:+--repo "$repo"} </dev/null) \
        || { echo "sweep.sh: could not file the open decision #$t's verifier named; the next sweep tries again" >&2; continue; }
    fi
    state_with_lock "$RUN_DIR" state_apply "$RUN_DIR" '.tickets[$t].verifications |= map(if .attempt == $v
        then .open_decisions[$k].question = $q else . end)' \
      --arg t "$t" --argjson v "$v" --argjson k "$k" --arg q "$q" \
      || { echo "sweep.sh: #$t's open decision is #$q but could not be recorded; the next sweep may file it again" >&2; continue; }
    [ "$how" = "filed as" ] && how="filed as #$q"
    echo "sweep.sh: #$t's verifier named an open decision; $how, split" >&2
  done 3<<<"$pending"
}

if [ "$MODE" = repair ] && [ "$DRY" -eq 1 ]; then
  # A scratch copy, without the lock: the repair writes there, never to the run.
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/sweep-dry.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  cp -R "$RUN_DIR/." "$scratch/"
  rm -f "$(state_lock_path "$scratch")"
  RUN_DIR=$scratch RESULTS="$scratch/results"
  repair
  echo "dry run: nothing written"
  exit 0
fi
if [ "$MODE" = repair ]; then
  state_with_lock "$RUN_DIR" repair
  exit 0
fi
state_with_lock "$RUN_DIR" sweep
# Board adds that failed when their issue was opened (#146): tried again here.
"$SCRIPT_DIR/tracker.sh" board-retry --run-dir "$RUN_DIR" >&2 || echo "sweep.sh: the board retry failed; the next sweep tries again" >&2
# Pushed ticket branches whose tickets are done, and deletes that failed (#211).
"$SCRIPT_DIR/pushed.sh" prune "$RUN_DIR" >&2 || echo "sweep.sh: pruning the pushed branches failed; the next sweep tries again" >&2
# Open decisions verifiers named (#230): filed split, once.
file_verifier_open_decisions
if [ "$GUARD" -eq 1 ]; then
  guard_rc=0
  guard_out=$("$SCRIPT_DIR/budget.sh" guard "$RUN_DIR" 2>&1) || guard_rc=$?
  case "$guard_rc" in
    0) ;;
    12 | 17 | 18) printf '%s\n' "$guard_out" >&2 ;;
    *) printf '%s\n' "$guard_out" >&2; exit "$guard_rc" ;;
  esac
fi
