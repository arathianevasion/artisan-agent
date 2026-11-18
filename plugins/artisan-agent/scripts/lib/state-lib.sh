# Shared functions for the run state file scripts (state.sh, sweep.sh,
# reconcile.sh). Sourced, never run. The file's shape is documented once, in
# ${CLAUDE_PLUGIN_ROOT}/references/state-file.md.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

ARTISAN_STATE_SCHEMA_VERSION=1

state_die() { # status message...
  local status="$1"
  shift
  printf '%s\n' "$*" >&2
  exit "$status"
}

state_is_uint() { # value: succeeds only for a non-empty run of digits
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
}

state_jq_row_def() { # prints the jq def that renders an array as a markdown table row
  printf '%s' 'def row: "| " + join(" | ") + " |";'
}

# The deferred gates the end gate lists and waits on, one jq selector for both
# readers (gate-action.sh deferred, end-gate.sh open_deferred): review, exception
# and overrun gates (#131). Emits {title, issue, kind, by, why, dependents}; an
# overrun gate keeps its deferral in .decision, the others in .deferral.
state_deferred_gates_jq() {
  printf '%s' '[((.review_gates // [])[], (.exception_gates // [])[]
      | select(.status == "deferred")
      | {title, issue, kind: (.kind // "slice"), by: .deferral.by, why: .deferral.why, dependents: (.dependents // [])}),
    ((.overrun_gates // [])[] | select(.status == "deferred")
      | {title, issue, kind: "overrun", by: .decision.by, why: .decision.why, dependents: []})]'
}

state_require_jq() {
  command -v jq >/dev/null 2>&1 || state_die 1 "jq is required but was not found on PATH"
}

state_now() {
  printf '%s\n' "${ARTISAN_NOW:-$(date +%s)}"
}

state_file() { printf '%s/state.json\n' "$1"; }
state_lock_path() { printf '%s/state.lock\n' "$1"; }

# The pid that owns writes from this call. A long-lived process (the
# orchestrator, or the chat between waves) takes the lock with its own pid and
# exports ARTISAN_WRITER_PID so every script call it makes writes under it.
state_writer_pid() {
  printf '%s\n' "${ARTISAN_WRITER_PID:-$$}"
}

# True when the pid names a live process. A zombie (exited, not yet reaped)
# counts as dead.
state_pid_alive() {
  local pid="$1" stat=
  state_is_uint "$pid" || return 1
  stat=$(ps -o stat= -p "$pid" 2>/dev/null) || return 1
  [ -n "$stat" ] || return 1
  case "$stat" in Z*) return 1 ;; esac
  return 0
}

# The run's waiter (#237): while `wave.sh wait` waits on an orchestrator it
# keeps "<pid> <orchestrator-id> <attempt>" in the run folder's waiter.pid.
state_waiter_path() { printf '%s/waiter.pid\n' "$1"; }

# True when a waiter is waiting on that orchestrator attempt: the pid file
# names it, and its pid is alive and is a wave.sh (not a reused pid).
state_waiter_running() { # run_dir orchestrator-id attempt
  local pid="" id="" attempt="" args=""
  read -r pid id attempt 2>/dev/null <"$(state_waiter_path "$1")" || return 1
  [ "$id" = "$2" ] && [ "$attempt" = "$3" ] || return 1
  state_pid_alive "$pid" || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in *wave.sh*) return 0 ;; esac
  return 1
}

# The lock is a symlink whose target is the holder's pid: creating it is one
# atomic step and carries the holder with it.
state_lock_holder() {
  readlink "$(state_lock_path "$1")" 2>/dev/null || true
}

# This machine's name in a moved run's `location` (move.sh). ARTISAN_MACHINE
# overrides it (two clones on one machine, in tests).
state_machine_id() {
  printf '%s\n' "${ARTISAN_MACHINE:-$(hostname -s 2>/dev/null || hostname)}"
}

# state_location_guard run_dir: 0 unless the run's `location` says it is not
# live here: moved away (in transit on its runs/<id> branch), or live on
# another machine. A run that never moved has no `location`. move.sh sets
# ARTISAN_MOVING=1 for its own writes. This is how the run lock travels with
# the state: every writer takes state_lock, so none writes a run that is
# somewhere else.
state_location_guard() {
  local run_dir="$1" file= status= machine=
  [ -z "${ARTISAN_MOVING:-}" ] || return 0
  file=$(state_file "$run_dir")
  [ -f "$file" ] || return 0
  # Both in one read (#185); a file jq can't read has no location.
  state_fields "$file" status machine -- '[.location.status // "", .location.machine // ""]' 2>/dev/null || return 0
  [ -n "$status" ] || return 0
  if [ "$status" = moved ]; then
    printf 'this run was moved away (pushed to its runs/ branch); it is not live here until move.sh in resumes it\n' >&2
    return 3
  fi
  if [ "$machine" != "$(state_machine_id)" ]; then
    printf 'this run is live on %s, not here (move.sh out there, then move.sh in here)\n' "$machine" >&2
    return 3
  fi
  return 0
}

# state_lock run_dir pid
# 0: taken (or already held by pid). 3: held by another live process, or the
# run is not live on this machine (state_location_guard).
state_lock() {
  local run_dir="$1" pid="$2" lock= holder= tries=0
  state_location_guard "$run_dir" || return 3
  lock=$(state_lock_path "$run_dir")
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if ln -s "$pid" "$lock" 2>/dev/null; then
      return 0
    fi
    holder=$(state_lock_holder "$run_dir")
    if [ "$holder" = "$pid" ]; then
      return 0
    fi
    if state_pid_alive "$holder"; then
      printf 'state file is locked by pid %s (%s)\n' "$holder" "$lock" >&2
      return 3
    fi
    # Stale: the holder is gone. Remove only if it still names that holder.
    if [ "$(state_lock_holder "$run_dir")" = "$holder" ]; then
      rm -f "$lock"
      printf 'recovered stale state lock from dead pid %s\n' "${holder:-?}" >&2
    fi
  done
  printf 'could not take state lock %s\n' "$lock" >&2
  return 3
}

# state_unlock run_dir pid
# Releases only a lock held by pid (or a stale one). 3 if another live pid holds it.
state_unlock() {
  local run_dir="$1" pid="$2" holder=
  holder=$(state_lock_holder "$run_dir")
  [ -n "$holder" ] || return 0
  if [ "$holder" != "$pid" ] && state_pid_alive "$holder"; then
    printf 'state file is locked by pid %s, not %s\n' "$holder" "$pid" >&2
    return 3
  fi
  rm -f "$(state_lock_path "$run_dir")"
}

# Runs "$@" with the state lock held by the writer pid. Takes the lock for the
# call if the writer does not already hold it, and releases only what it took.
# "$@" runs under the caller's errexit (never on the left of || or &&, where
# bash would switch it off): a failure ends the script and the EXIT trap
# releases the lock.
state_with_lock() {
  local run_dir="$1" pid=
  shift
  pid=$(state_writer_pid)
  if [ "$(state_lock_holder "$run_dir")" = "$pid" ]; then
    "$@"
    return 0
  fi
  state_lock "$run_dir" "$pid" || return $?
  trap 'state_unlock "'"$run_dir"'" "'"$pid"'" || true' EXIT
  "$@"
  state_unlock "$run_dir" "$pid" || true
  trap - EXIT
}

# state_hand_lock run_dir from to: give a lock held by pid "from" to pid "to"
# in one step (a rename over the symlink). "from" must be a live pid: a live
# holder's lock is never taken as stale, so no third writer gets in between. Used when the chat launches an orchestrator: the run stays locked
# and the orchestrator's long-lived runner becomes the writer. 3 if "from"
# does not hold it.
state_hand_lock() {
  local run_dir="$1" from="$2" to="$3" lock= tmp=
  lock=$(state_lock_path "$run_dir")
  [ "$(state_lock_holder "$run_dir")" = "$from" ] || {
    printf 'cannot hand over the state lock: pid %s does not hold it\n' "$from" >&2
    return 3
  }
  tmp="$run_dir/.state.lock.tmp.$$"
  rm -f "$tmp"
  ln -s "$to" "$tmp" && mv -f "$tmp" "$lock" || return $?
  state_status_write "$run_dir" "$to"
}

state_valid_file() { # path
  jq -e --argjson v "$ARTISAN_STATE_SCHEMA_VERSION" \
    'type == "object" and .schema_version == $v' "$1" >/dev/null 2>&1
}

# state_version_message path: why a file is refused, naming the plugin version
# the run started on (the first entry of its waves) so the Artisan can finish
# the run there. Never a bare "wrong schema version" (references/state-file.md,
# Schema version).
state_version_message() {
  local file="$1" found= started=
  if ! found=$(jq -r 'if type == "object" then (.schema_version // "none" | tostring) else "not an object" end' "$file" 2>/dev/null); then
    printf 'unreadable state file (not JSON): %s\n' "$file"
    return 0
  fi
  if [ "$found" = "not an object" ]; then
    printf 'unreadable state file (not a JSON object): %s\n' "$file"
    return 0
  fi
  started=$(jq -r '[.waves[]? | select(type == "object") | .plugin_version // empty][0] // empty' "$file" 2>/dev/null) || started=
  printf 'unreadable state file %s: it is schema version %s and this plugin reads only version %s.' \
    "$file" "$found" "$ARTISAN_STATE_SCHEMA_VERSION"
  if [ -n "$started" ]; then
    printf ' The run started on plugin version %s: finish it on that version.\n' "$started"
  else
    printf ' The file records no plugin version the run started on (no wave was recorded): finish it on the plugin version that created it.\n'
  fi
}

# state_commit run_dir tmp
# The one-step rewrite: validate the complete temp file, then rename it over
# the state file. An interrupted writer leaves only a stray temp file; the
# state file is either the old one or the new one, never a mix. Unchanged
# content is not rewritten, so repeated reconciling leaves the file untouched.
state_commit() {
  state_write "$1" "$2" commit .
}

state_refuse_write() { # tmp
  rm -f "$1"
  printf 'refusing to write: not a schema version %s state file\n' "$ARTISAN_STATE_SCHEMA_VERSION" >&2
}

# state_write run_dir input apply|commit filter [jq args...]: the one jq call
# behind every state write (#185). apply: input is the state file, checked to
# be a schema version state file (else exit 97). commit: input is a finished
# temp file. The filter's result is checked too (else 98), printed as jq
# prints it (state_pp, so the file is byte for byte what `jq` would write),
# and followed by the run status file's line, so neither the checks nor the
# status file (#192) cost a process of their own. The status line is display
# only: one that can't be made leaves the last status.json, as before.
state_write() {
  local run_dir="$1" input="$2" mode="$3" filter="$4" file= tmp= out= err= rc=0 state= status= old= in=
  shift 4
  file=$(state_file "$run_dir")
  tmp=$(state_tmp "$run_dir")
  state_status_inputs "$run_dir"
  local prog='def __state_ok: type == "object" and .schema_version == $__state_v;
    if $__state_mode == "commit" or __state_ok then ('"$filter"'
      ) | if __state_ok
          then (try (. as $__st | ($__st_lock) as $lock | ($__st_runners) as $runners
                 | ($__st_now) as $now | $__st | ('"$STATE_TITLE_JQ_DEFS$STATE_STATUS_JQ"'
                 ) | tojson) catch "") + "\n" + __state_pp("")
          else "" | halt_error(98) end
    else "" | halt_error(97) end'
  if [ "$mode" = commit ]; then
    # The temp file is the input and the output: read it first.
    in=
    IFS= read -r -d '' in <"$input" || true
    err=$(jq -r --argjson __state_v "$ARTISAN_STATE_SCHEMA_VERSION" --arg __state_mode "$mode" \
      --argjson __st_lock "$STATE_ST_LOCK" --argjson __st_runners "[$STATE_ST_RUNNERS]" --argjson __st_now "$(state_now)" \
      "$@" "$STATE_JQ_DEFS$STATE_PP_JQ$prog" 2>&1 >"$tmp" <<<"$in") || rc=$?
  else
    err=$(jq -r --argjson __state_v "$ARTISAN_STATE_SCHEMA_VERSION" --arg __state_mode "$mode" \
      --argjson __st_lock "$STATE_ST_LOCK" --argjson __st_runners "[$STATE_ST_RUNNERS]" --argjson __st_now "$(state_now)" \
      "$@" "$STATE_JQ_DEFS$STATE_PP_JQ$prog" "$input" 2>&1 >"$tmp") || rc=$?
  fi
  # The output: the status line (empty when it can't be made), then the
  # state. Read by the shell, never cut by a pattern: a state over a few
  # hundred KiB would take bash minutes to match.
  out=
  [ "$rc" -ne 0 ] || { { IFS= read -r status; IFS= read -r -d '' out; } <"$tmp" || true; }
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    if [ "$mode" = commit ]; then
      state_refuse_write "$tmp"
    elif [ "$rc" -eq 97 ] || ! state_valid_file "$input"; then
      rm -f "$tmp"
      state_version_message "$input" >&2
    elif [ "$rc" -eq 0 ] || [ "$rc" -eq 98 ]; then
      state_refuse_write "$tmp"
    else
      rm -f "$tmp"
      [ -z "$err" ] || printf '%s\n' "$err" >&2
    fi
    return 1
  fi
  state=$out
  # A commit writes the temp file as it is (state.sh write keeps stdin's
  # bytes); only an apply's result is printed by state_pp.
  [ "$mode" != commit ] || state=$in
  # Unchanged content is not rewritten, so repeated reconciling leaves the
  # file untouched.
  old=
  if [ -f "$file" ]; then IFS= read -r -d '' old <"$file" || true; fi
  if [ -f "$file" ] && [ "$old" = "$state" ]; then
    rm -f "$tmp"
  else
    printf '%s' "$state" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file" || return $?
  fi
  # The run status file follows every write, the lock's holder included (#192).
  [ -z "$status" ] || state_status_put "$run_dir" "$status"$'\n'
  return 0
}

state_tmp() { # run_dir
  printf '%s/.state.json.tmp.%s\n' "$1" "$$"
}

# state_apply run_dir filter [jq args...]
# Read, transform with jq, rewrite in one step (state_write). Caller holds
# the lock.
state_apply() {
  local run_dir="$1" filter="$2" file=
  shift 2
  file=$(state_file "$run_dir")
  [ -f "$file" ] || { printf 'no state file at %s\n' "$file" >&2; return 1; }
  state_write "$run_dir" "$file" apply "$filter" "$@"
}

# state_require_run_dir run_dir: exits unless a state file exists there.
# (Its schema version is checked when it is read.)
state_require_run_dir() {
  [ -n "${1:-}" ] || state_die 2 "missing run folder argument"
  [ -f "$(state_file "$1")" ] || state_die 1 "no state file in $1"
}

# state_step tmp filter [jq args...]: transform a working copy in place.
# Used by the sweep and the reconciler, which build up one rewrite in steps.
state_step() {
  local tmp="$1" filter="$2"
  shift 2
  jq "$@" "$filter" "$tmp" >"$tmp.next" || { rm -f "$tmp" "$tmp.next"; state_die 1 "jq step failed"; }
  mv -f "$tmp.next" "$tmp"
}

# The state file printed as jq prints it (two-space indent, keys in their
# order, scalars as tojson writes them), so state_write can put it and the
# status line in one jq call's output (#185).
STATE_PP_JQ='
  def __state_pp($i):
    if type == "object" then
      if length == 0 then "{}"
      else ($i + "  ") as $j
        | "{\n" + ([to_entries[] | $j + (.key | tojson) + ": " + (.value | __state_pp($j))] | join(",\n")) + "\n" + $i + "}" end
    elif type == "array" then
      if length == 0 then "[]"
      else ($i + "  ") as $j
        | "[\n" + ([.[] | $j + __state_pp($j)] | join(",\n")) + "\n" + $i + "]" end
    else tojson end;'

# state_fields file name... -- filter [jq args...]
# Several values from one jq read of a JSON file (#185): the filter yields an
# array, and each name is set to one element, in order, as `$(jq -r ...)` of
# that element alone gives it: a string raw, anything else as compact JSON
# (null as "null"), trailing newlines cut. Fails, setting nothing, when jq does
# (its message on stderr, as a lone `jq -r` would print it) or yields another
# number of values (none, for an empty file).
state_fields() {
  local _sf_file="$1" _sf_filter="" _sf_out="" _sf_v="" _sf_name=""
  local -a _sf_names=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do _sf_names+=("$1"); shift; done
  [ $# -ge 2 ] || { printf 'state_fields: usage: file name... -- filter [jq args...]\n' >&2; return 2; }
  _sf_filter=$2
  shift 2
  _sf_out=$(jq -j "$@" '('"$_sf_filter"'
    ) | .[] | (if type == "string" then . else tojson end) + "\u001e"' "$_sf_file") || return $?
  # One value per name, or none set (an empty file gives jq nothing to read).
  _sf_v=${_sf_out//[!$'\x1e']/}
  if [ "${#_sf_v}" -ne "${#_sf_names[@]}" ]; then
    printf 'state_fields: %s values for %s names from %s\n' "${#_sf_v}" "${#_sf_names[@]}" "$_sf_file" >&2
    return 1
  fi
  for _sf_name in ${_sf_names[@]+"${_sf_names[@]}"}; do
    _sf_v=${_sf_out%%$'\x1e'*}
    _sf_out=${_sf_out:${#_sf_v}+1}
    while [ "${_sf_v%$'\n'}" != "$_sf_v" ]; do _sf_v=${_sf_v%$'\n'}; done
    printf -v "$_sf_name" '%s' "$_sf_v"
  done
}

# state_usage script: print the script's header comment as its usage, exit 2.
state_usage() {
  sed -n '2,/^$/p' "$1" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# jq definitions shared by every writer, so a ticket's shape and the merge
# event live in one place. Prepend to a filter: "$STATE_JQ_DEFS | ...".
#   new_ticket(t): a queued ticket entry; reads .plan.tickets for its branch
#   merged(t; sha): the ticket merged at sha, recorded in integration.merges
#   attempt_cost(t; n; usd): attempt n of ticket t cost usd (cost_usd is the sum)
#   event(e; at): append e to the event log, numbered, with its time (epoch)
#   current_wave: the last orchestrator's wave (0 before any); a dispatch is part of it
#   failed_attempt(t; reason; at): attempt .attempts of ticket t failed; back to
#     queued for a fresh worker, or blocked with an exception decision once it
#     has used the run's attempts per ticket
#   ticket_areas(ts): the areas of tickets ts (plan.tickets.<t>.areas), one list
#   join_human_check(h; t; title): Human check h of agent ticket t joins the
#     run's scope, open (verify.sh judge's split, gate-action.sh split --human)
#   bug_found(t; gate; by; why; at): log a bug the Artisan found in ticket t at
#     a review gate (#122): event bug-found, with t's areas and where "gate"
#   guardrails_fired(gate; at): one guardrail-fired event per guardrail that
#     opened the gate (its `guardrails`, [{guardrail, area?}])
#   human_check_for(t): the agent ticket Human check t verifies, as a string
#     (tickets.<t>.human_check.for, which the reconciler reads from the body
#     marker, or plan.tickets.<t>.human_check_for), else null
#   is_human_check(t): t is a Human check (references/human-checks.md): never
#     dispatched, never a blocker or a dependent in the run's own logic
#   open_human_checks: the Human checks in scope still to be answered (queued)
#   slice_gates: the review gates placed on tickets: the plan's slice and
#     risk gates (their Human checks left out), and a risk gate per ticket whose evidence holds a new-seam
#     card (criterion 3) no planned risk gate covers; each {id, kind, why,
#     slice, role, problem, solution, guardrails, tickets}; guardrails is
#     [{guardrail: "area:<name>", area}] for an area's risk gate, else null (references/review-gates.md,
#     references/end-gate.md)
#   gate_done(g; t): ticket t of gate g is done for the gate: merged, closed
#     or out of the run (out_of_run, sent_back included: #164)
#   gate_left(g): the tickets of gate g that left the run (out_of_run)
#   gate_left_run(g): the same as [{number, status, title}], status in words
#     ("sent back"), for the packet and the recorded gate's left_run
#   gate_due(g): every ticket of gate g done (gate_done), at least one merged,
#     and the gate not yet answered (approved, bypassed, deferred or
#     redirected: gate-action.sh)
#   gate_title(g; run): the review-gate issue's title for gate g of run run
#   gate_empty(g): every ticket of gate g done, none merged, and the gate not
#     recorded: nothing to review, so gate.sh sync closes it as "empty"
#   decide(id; d; at): waiting decision id decided, with the decision record d
#     (references/decision-record.md); unchanged when it is not waiting
#   out_of_run: the statuses that take a ticket out of the run without a
#     merge (references/gate-actions.md), sent_back (left with its dropped or
#     resliced blocker) included; with merged and closed, it is done
#   waiting_non_gate_decisions: the decisions waiting for the Artisan that no
#     gate carries: not a risk or review gate, nor an exception with its gate open
#   gate_answered(g): gate g is recorded and no longer open: approved,
#     bypassed, deferred, redirected or closed as empty
#   gate_pending(g): gate g still holds: not answered, and not a gate with
#     every ticket done and none merged (gate_empty: nothing to review). From
#     plan approval, not only once it is due (#170)
#   gate_holds(t; d): ticket d, which depends on t, waits for a gate: t is in
#     a slice or risk gate that is pending and d is not in it (a ticket is
#     never held by its own gate). d null: any dependent outside the gate
#   gate_holds(t): gate_holds(t; null)
#   answer_folded(into; status; by; changed; at): the risk gates folded into
#     gate `into` (#241: status "folded", folded_into) answered with it:
#     status (approved, redirected or bypassed), answered_with, a decided
#     review-gate decision (job 13, changed when `changed` or a card of its
#     tickets was changed at that gate), a gate-decision event (outcome keep
#     or change, cards, folded_into) for guardrail health and a
#     gate-<status> event; one already answered changes nothing
#   gate_waits(d; bs): the pending gates that hold d through its blockers bs
#     (ticket numbers as strings), each {id, kind, slice}
STATE_JQ_DEFS='
  def attempt_cost($t; $n; $usd):
    if $usd == null then .
    else .tickets[$t].attempt_costs[($n | tostring)] = $usd
      | .tickets[$t].cost_usd = ([.tickets[$t].attempt_costs[]] | add) end;
  def event($e; $at):
    .events = ((.events // []) as $log | $log + [{seq: (($log | length) + 1), at: $at} + $e]);
  def ticket_areas($ts): [$ts[] as $t | (.plan.tickets[$t | tostring].areas // [])[]] | unique;
  def bug_found($t; $gate; $by; $why; $at):
    event({event: "bug-found", ticket: ($t | tostring), areas: ticket_areas([$t]), where: "gate", gate: $gate, by: $by}
          + (if ($why // "") == "" then {} else {why: $why} end); $at);
  def guardrails_fired($gate; $at):
    reduce ($gate.guardrails // [])[] as $g (.;
      event({event: "guardrail-fired", guardrail: $g.guardrail} + (if $g.area then {area: $g.area} else {} end)
            + {gate: $gate.id, tickets: ($gate.tickets // [])}; $at));
  def new_ticket($t): {
    status: "queued", attempts: 0, pid: null,
    branch: (.plan.tickets[$t].branch // ("agent/" + $t)),
    dispatched_at: null, deadline_at: null, result: null, evidence: null,
    merge_commit: null, cost_usd: 0, failures: []
  };
  def current_wave: ((.orchestrators // []) | last | .wave) // 0;
  # On a ticket: a verifier pass for its current attempt (verify.sh judge).
  def verified_pass: .evidence != null and .evidence.verdict == "pass" and .evidence.attempt == .attempts;
  def failed_attempt($t; $reason; $at):
    (.plan.attempts_per_ticket + (.tickets[$t].extra_attempts // 0)) as $max
    | .tickets[$t] as $tk
    | .tickets[$t] |= (
        .failures += [{attempt: .attempts, reason: $reason, at: $at}]
        | .pid = null
        | .status = (if (.attempts - ((.steering // []) | length)) >= $max then "blocked" else "queued" end))
    | if ($tk.attempts - (($tk.steering // []) | length)) >= $max then
        .decisions += [{
          id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
          question: "Ticket \($t) failed \($tk.attempts) attempts (last: \($reason)). Retry with notes, reslice, take it myself or drop; or bypass or defer its exception gate?",
          status: "waiting", at: $at
        }]
      else . end
    | event({event: "failed", ticket: $t, attempt: $tk.attempts, reason: $reason,
             next: .tickets[$t].status}; $at);
  def join_human_check($h; $t; $title):
    .plan.scope = ((.plan.scope + [$h]) | unique)
    | .plan.tickets[$h] = ((.plan.tickets[$h] // {}) + {title: $title, human_check_for: $t})
    | (if .tickets[$h] == null then .tickets[$h] = new_ticket($h) else . end)
    | .tickets[$h].human_check = ((.tickets[$h].human_check // {state: "open"}) + {for: $t});
  def merged($t; $sha):
    .tickets[$t] |= (.status = "merged" | .merge_commit = $sha | .pid = null)
    | .integration.merges |= (map(select(.ticket != $t)) + [{ticket: $t, commit: $sha}]);
  def escalation_label:
    {"new-seam": "new seam or module boundary", "tracer-bullet": "first tracer bullet through a new layer",
     "vocabulary-adr": "change to vocabulary or an ADR", "judgement-criteria": "judgement-like acceptance criteria",
     "seam-card": "new seam (decision card)"}[.]
    // (if startswith("area:") then "area \(.[5:]) gate setting" else . end);
  def seam_card: ((.criterion? // "") | tostring) == "3";
  def human_check_for($t):
    (.tickets[$t | tostring].human_check.for? // .plan.tickets[$t | tostring].human_check_for? // null)
    | if . == null then null else tostring end;
  def is_human_check($t): human_check_for($t) != null;
  def open_human_checks:
    . as $s | [.plan.scope[] | tostring
      | select(. as $t | ($s | is_human_check($t)) and $s.tickets[$t].status? == "queued")];
  def slice_gates:
    . as $s
    | [($s.plan.gates // []) | to_entries[] | select((.value.kind? // "") == "slice" or (.value.kind? // "") == "risk")
       | .key as $k | .value as $g
       | {id: "\($g.kind)-\($k + 1)", kind: $g.kind,
          why: (if $g.kind == "risk" then (($g.tests // []) | map(escalation_label) | join(", ")) else null end),
          slice: ($g.slice // (if $g.kind == "risk" and $g.after != null then "#\($g.after)" else "slice \($k + 1)" end)),
          role: ($g.role // "Engineering (QA)"),
          problem: ($g.problem // null), solution: ($g.solution // null), own: ($g.own // false),
          guardrails: ([($g.tests // [])[] | select(startswith("area:")) | {guardrail: ., area: .[5:]}]
                       | if . == [] then null else . end),
          tickets: ([($g.tickets // (if $g.after != null then [$g.after] else null end)
                      // [$s.plan.tickets | to_entries[] | select($g.slice != null and .value.slice? == $g.slice) | .key])
                     | .. | scalars | tostring] | unique_by(tonumber? // .)
                    | map(select(. as $x | $s | is_human_check($x) | not)))}
       | select(.tickets != [])]
    | . as $planned
    # A new-seam card (controversy criterion 3) in a ticket evidence raises a
    # risk gate the plan did not place: one per ticket, none where a planned
    # risk gate already covers it.
    | $planned + [$s.tickets | to_entries[]
        | select(any(.value.evidence.decisions[]?; seam_card))
        | .key as $t
        | select(all($planned[]; .kind != "risk" or (.tickets | index($t)) == null))
        | {id: "risk-seam-\($t)", kind: "risk", why: ("seam-card" | escalation_label), slice: "#\($t)",
           role: "Engineering (QA)", problem: null, solution: null, tickets: [$t]}]
    # A merge processed at the review band (drain.sh gate) raises one too:
    # tickets.<t>.context_risk is the fact that it happened, the gate is the hold.
    | . as $withseam
    | $withseam + [$s.tickets | to_entries[]
        | select(.value.context_risk.percent? != null)
        | .key as $t | .value.context_risk.percent as $pct
        | {id: "risk-context-\($t)", kind: "risk", context_percent: $pct,
           why: "merged at \($pct)% context, the review band", slice: "#\($t)",
           role: "Engineering (QA)", tickets: [$t],
           problem: "#\($t) merged while the orchestrator was at \($pct)% context, the review band.",
           solution: "Look over what merged before its dependents start on it: the cards, the uncertainties and the diff below. Only its dependents wait; nothing else does."}];
  def out_of_run: ["dropped", "resliced", "bypassed", "deferred", "sent_back"];
  def gate_done($t):
    (.tickets[$t].status // "") as $st
    | $st == "merged" or $st == "closed" or (out_of_run | index($st)) != null;
  # A failed Human check whose rework has not merged (#165, #178): its last
  # answer is a fail with a rework not yet done. "<gate> <rework>", or null.
  def check_rework($t):
    . as $s | ((.tickets[$t].human_check.answers // []) | last
    | select(. != null and .verdict == "fail" and (.rework // null) != null)
    | .rework as $r | select($s | gate_done($r) | not) | "\(.gate) \($r)") // null;
  def gate_left($g):
    . as $s | [$g.tickets[] | select(($s.tickets[.].status // "") as $st | out_of_run | index($st))];
  def gate_left_run($g):
    . as $s | [gate_left($g)[] | {number: ., status: ($s.tickets[.].status | sub("_"; " ")),
                                  title: ($s.plan.tickets[.].title // null)}];
  def gate_title($g; $run):
    . as $s
    | if $g.kind == "risk"
      then "Risk gate: \($g.tickets | map(. as $t | "#\($t)" + ($s.plan.tickets[$t].title // null | if . then " (\(.))" else "" end)) | join(", ")), \($g.why) (run \($run))"
      else "Slice gate: \($g.slice) (run \($run))" end;
  def gate_due($g):
    . as $s
    | all($g.tickets[]; . as $t | $s | gate_done($t))
      and any($g.tickets[]; $s.tickets[.].status? == "merged")
      and ([($s.review_gates // [])[] | select(.id == $g.id and .status != "open")] == []);
  def gate_empty($g):
    . as $s
    | all($g.tickets[]; . as $t | $s | gate_done($t))
      and all($g.tickets[]; $s.tickets[.].status? != "merged")
      and all(($s.review_gates // [])[]; .id != $g.id);
  def decide($id; $d; $at):
    .decisions |= map(if .id == $id and .status == "waiting"
      then . + $d + {status: "decided", decided_at: $at} else . end);
  # Steering (#76): the Artisan stopped this attempt and gave notes. The ticket
  # goes back to queued with the notes kept; it is not a failed attempt, so it
  # costs none of the attempts_per_ticket allowance.
  def steered($t; $note; $at):
    .tickets[$t] |= (
      .steering = ((.steering // []) + [{attempt: .attempts, note: $note, at: $at}])
      | .pid = null | .status = "queued")
    | event({event: "steered", ticket: $t, attempt: .tickets[$t].attempts, note: $note}; $at);
  # Work added to a running run (#76): the ticket joins the scope with its
  # estimate, and the run budget grows by the estimate plus the overrun
  # allowance. $r is the approved request: ticket, model, estimate_usd, title?,
  # minutes?, expected_files?, escalation?, priority?, urgent?, by?. Idempotent.
  def r2: (. * 100 | round) / 100;
  def scope_add($r; $at):
    ($r.ticket | tostring) as $t
    | if (.plan.scope | map(tostring) | index($t)) != null then .
      else
        (.plan.config.overrun_allowance_percent // 25) as $pct
        | ($r.estimate_usd | r2) as $est
        | (($est * (1 + $pct / 100)) | r2) as $inc
        | (.plan.budget_usd) as $before
        | .plan.scope += [$t]
        | .plan.tickets[$t] = ({model: $r.model, estimate_usd: $est,
              priority: ($r.priority // (if $r.urgent == true then 2 else 1 end)),
              expected: {minutes: ($r.minutes // 30)},
              caps: {max_budget_usd: ($est * 2 | r2), max_turns: ([($est * 40 | ceil), 20] | max),
                     deadline_seconds: (($r.minutes // 30) * 120 | ceil)}}
            + (if $r.title then {title: $r.title} else {} end)
            + (if $r.expected_files then {expected_files: $r.expected_files} else {} end)
            + (if $r.escalation then {escalation: $r.escalation} else {} end)
            + (if $r.urgent == true then {urgent: true} else {added: true} end))
        | .plan.estimate_usd = (if .plan.estimate_usd == null then null else (.plan.estimate_usd + $est | r2) end)
        | .plan.budget_usd = (if $before == null then null else ($before + $inc | r2) end)
        | .tickets[$t] = new_ticket($t)
        | (if $r.urgent == true then .tickets[$t].urgent = true else . end)
        | .plan.additions = ((.plan.additions // []) + [{ticket: $t, urgent: ($r.urgent == true), estimate_usd: $est,
            budget_before: $before, budget_after: .plan.budget_usd, by: ($r.by // "Artisan"), at: $at}])
        | event({event: (if $r.urgent == true then "urgent-added" else "work-added" end), ticket: $t,
                 estimate_usd: $est, budget_usd: .plan.budget_usd}; $at)
      end;
  def waiting_non_gate_decisions:
    [.decisions[] | select(.status == "waiting" and .kind != "risk-gate" and .kind != "review-gate"
                           and .kind != "base-red"
                           and (.kind != "exception" or .issue == null))];
  # The minutes each merge waited on CI (ci-wait events, #195): per merge
  # (a ticket, or a merge batch with every gate it ran) and in total.
  def ci_wait:
    [(.events // [])[] | select(.event == "ci-wait")] as $w
    | {merges: ($w | group_by(if .batch then "b\(.batch)" else "t\(.ticket)" end)
        | map({ticket: (if .[0].batch then null else .[0].ticket end), batch: (.[0].batch // null),
               tickets: (if .[0].batch then (map(.tickets) | add | unique) else [.[0].ticket] end),
               gates: length, minutes: ((map(.minutes) | add) * 10 | round / 10)})),
       total_minutes: (($w | map(.minutes) | add // 0) * 10 | round / 10)};
  def gate_answered($g):
    any((.review_gates // [])[]; .id == $g.id and .status != "open");
  def gate_pending($g):
    . as $s
    | (gate_answered($g) | not)
      and ((all($g.tickets[]; . as $t | $s | gate_done($t))
            and all($g.tickets[]; $s.tickets[.].status? != "merged")) | not);
  def gate_waits($d; $bs):
    . as $s
    | [slice_gates[] | select((.tickets | index($d)) == null)
       | select(.tickets as $gt | any($bs[]; . as $b | $gt | index($b) != null))
       | select(. as $g | $s | gate_pending($g)) | {id, kind, slice}];
  def gate_holds($t; $d):
    . as $s
    | any(slice_gates[]; (.tickets | index($t)) != null
          and ($d == null or (.tickets | index($d)) == null)
          and (. as $g | $s | gate_pending($g)));
  def gate_holds($t): gate_holds($t; null);
  def answer_folded($into; $status; $by; $changed; $at):
    . as $s0
    | ([($s0.review_gates // [])[] | select(.id == $into)] | first // {}) as $tg
    | reduce ([(.review_gates // []) | to_entries[]
               | select(.value.status == "folded" and .value.folded_into == $into) | .key][]) as $i (.;
        .review_gates[$i] as $f
        | ($changed or $status == "redirected"
           or any(($tg.decisions // [])[]; ((.ticket // "") | tostring) as $x
                  | .outcome? == "change" and ($f.tickets | index($x)) != null)) as $ch
        | .review_gates[$i] += {status: $status, answered_with: $into, approved_at: $at}
        | .decisions += [{id: ((.decisions | length) + 1), kind: "review-gate", gate: $f.id, issue: null,
            folded_into: $into, question: "\($f.title), folded into \($into)", status: "decided", at: $at,
            decided_at: $at, choice: (if $status == "approved" then "approve" else $status end), by: $by,
            job: 13, changed: $ch}]
        | event({event: "gate-decision", gate: $f.id, card: null, by: $by,
                 outcome: (if $ch then "change" else "keep" end), redirect: ($status == "redirected"),
                 areas: ticket_areas($f.tickets), cards: ($f.cards // [] | length), folded_into: $into}; $at)
        | event({event: "gate-\($status)", gate: $f.id, issue: null, kind: "risk", folded_into: $into, by: $by}; $at));
'

# How the run stands, from the state file, for `wave.sh status` and the run
# status file (status.json, below), so both say the same thing (#192):
#   urgent_queued: the urgent tickets still to dispatch (lever.sh urgent)
#   run_all_done: every ticket in scope merged, closed or out of the run, a
#     Human check counting once it is answered or its ticket stayed in the run
#   review_park_possible: the state-file half of gate-action.sh parked: no
#     work moving or ready, no decision that isn't a gate, and a gate open
#   human_park_line: human.sh parked's line (only a hands-on ticket, and the
#     work behind it, is left), or null
#   stranded_possible: a ticket in scope was dropped or resliced, the
#     state-file half of gate-action.sh stranded (which reads the tracker)
#   run_next($p): the run's next step, {next, why} or {probe}. $p holds what
#     the state file cannot say: reconciled (the reconciler read the tracker),
#     wait (an orchestrator is running: its next, e.g. "wait") and the
#     probes reviews, human and stranded (true, false, or absent to be asked
#     for: {probe: "<name>"} names the first one the chain reaches, so a
#     probe with side effects runs only where the chain needs it). why is
#     running, halted, orchestrator-exit, ci, usage, reviews, base,
#     decisions, tracker, frontier, urgent, returned, done, human, stranded
#     or blocked
#   run_counts: the scope's agent tickets by where they are: merged, in
#     flight, verifying (returned), at the merge gate, queued, blocked, other
#     (closed on the tracker or out of the run) and total
STATE_JQ_DEFS="$STATE_JQ_DEFS"'
  def urgent_queued: [.tickets | to_entries[] | select(.value.urgent == true and .value.status == "queued") | .key];
  def run_all_done:
    . as $s | out_of_run as $o
    | [.plan.scope[] as $t
       | select((($s | is_human_check($t)) and ($s.tickets[$t].status? != "queued"
                  or ((["dropped", "resliced", "sent_back"] | index($s.tickets[$s | human_check_for($t)].status? // "")) == null)))
                or (.tickets[$t].status | . as $st
                    | $st == "merged" or $st == "closed" or ($o | index($st))))] | length
    | . == ($s.plan.scope | length);
  def review_park_possible:
    ([.tickets[] | select(.status == "in_flight" or .status == "returned")] | length) == 0
    and ((.frontier // []) | length) == 0
    and (waiting_non_gate_decisions | map(select(.kind != "usage")) | length) == 0
    and ([(.review_gates // [])[], (.exception_gates // [])[] | select(.status == "open")]
         + [.tickets[] | select(.risk_gate.status? == "waiting")] | length) > 0;
  def human_park_line:
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
      then null
      else
        ($open | map(select(. as $t | $hum | index($t) | not))) as $behind
        | "parked: waiting on the Artisan'"'"'s hands-on ticket \($hum | map("#" + . + " (" + ($pt[.].title // "untitled") + ")") | join(", "))"
          + (if ($behind | length) > 0 then "; \($behind | length) ticket(s) wait behind it: \($behind | map("#" + .) | join(", "))" else "; nothing else waits behind it" end)
      end;
  def stranded_possible:
    . as $s | any(.plan.scope[]; $s.tickets[.].status? == "dropped" or $s.tickets[.].status? == "resliced");
  def run_next($p):
    ((.frontier // []) | length) as $front
    | (if $front > 0 or (urgent_queued | length) > 0 then waiting_non_gate_decisions | length
       else [.decisions[] | select(.status == "waiting")] | length end) as $waiting
    | ($p.reconciled != false) as $rec
    | if $p.wait != null then {next: $p.wait, why: "running"}
      elif .halted != null then {next: "halted", why: "halted"}
      # An orchestrator that exited without finishing its wave: never launch.
      elif any(.decisions[]; .kind == "orchestrator-exit" and .status == "waiting") then {next: "decide", why: "orchestrator-exit"}
      elif .ci_park != null then {next: "parked", why: "ci"}
      elif .usage_park != null then {next: "parked", why: "usage"}
      elif $rec and $p.reviews == null then {probe: "reviews"}
      elif $rec and $p.reviews then {next: "parked", why: "reviews"}
      # A red base pauses merging only: parked once nothing else can run.
      elif .base_park != null and $front == 0 then {next: "parked", why: "base"}
      elif $waiting > 0 then {next: "decide", why: "decisions"}
      elif ($rec | not) then {next: "blocked", why: "tracker"}
      elif $front > 0 then {next: "launch", why: "frontier"}
      # An urgent ticket to dispatch, or waiting for the extra slot (#205).
      elif (urgent_queued | length) > 0 then {next: "launch", why: "urgent"}
      # A hands-on ticket the Artisan finished waits for its verifier and merge.
      elif any(.tickets[]; .status == "returned") then {next: "launch", why: "returned"}
      elif run_all_done then {next: "done", why: "done"}
      elif $p.human == null then {probe: "human"}
      elif $p.human then {next: "parked", why: "human"}
      # Tickets left waiting for good behind a dropped or resliced one (#116).
      elif $p.stranded == null then {probe: "stranded"}
      elif $p.stranded then {next: "stranded", why: "stranded"}
      else {next: "blocked", why: "blocked"} end;
  def merge_gate_tickets:
    [(.merge_gate // {}), (.ci_gate // {}), (.merge_batch // {}) | (.tickets // [.ticket // empty])[] | tostring] | unique;
  def run_counts:
    . as $s | merge_gate_tickets as $mg
    | [.plan.scope[] | tostring | select(. as $t | $s | is_human_check($t) | not)
       | . as $t | ($s.tickets[$t].status // "queued")
       | if . == "returned" then (if ($mg | index($t)) then "merge_gate" else "verifying" end)
         elif . == "merged" or . == "in_flight" or . == "queued" or . == "blocked" then .
         else "other" end] as $k
    | reduce ("merged", "in_flight", "verifying", "merge_gate", "queued", "blocked", "other") as $c ({};
        .[$c] = ([$k[] | select(. == $c)] | length))
    | .total = ($k | length);
'

# The run's title (#189), for session names (lib/wave-lib.sh) and the run
# status file: the first plan issue's title without its "Plan: " prefix
# (plan.plans), " +N" for the other plans in more, else the spec's title
# (plan.spec.title), else "run <id>". repo_short is the repo after the slash.
STATE_TITLE_JQ_DEFS='
  def repo_short: (.repo // "" | split("/") | last) // "";
  def run_title: ((.plan.plans // []) | map(.title // "" | sub("^ *[Pp]lan: *"; "") | select(. != ""))) as $p
    | if ($p | length) > 0 then {title: $p[0], more: (if ($p | length) > 1 then " +\(($p | length) - 1)" else "" end)}
      elif (.plan.spec.title // "") != "" then {title: .plan.spec.title, more: ""}
      else {title: "run \(.run_id)", more: ""} end;
'

# The run status file (#192): status.json beside the state file, one line of
# JSON for a display (the Agent Cockpit) to read without a session. Its shape
# is in references/state-file.md, "The run status file". Display only: nothing in
# the plugin reads it back. Rewritten by every state write (state_commit) and
# when the lock is handed on (state_hand_lock), under the state lock, as a
# temp file then a rename.
#
# $lock is the lock's holder when it is a long-lived writer (the chat, or an
# orchestrator's runner), else null; $runners the pids of the run's
# orchestrator runners. While a runner holds the lock the wave is the
# orchestrator's, and the owning chat is the one that launched it
# (orchestrators[].chat_pid); next is "wait" until its exit is judged.
# Otherwise the owning chat is the lock holder, and next is run_next with what
# only the tracker could add left to the state file (review_park_possible,
# human_park_line, stranded_possible).
STATE_STATUS_JQ='
  def usd: (. * 100 | round) as $c | "$" + (($c / 100 | floor) | tostring) + "."
    + (($c % 100) | tostring | if length == 1 then "0" + . else . end);
  ((.orchestrators // []) | last) as $o
  | ($o != null and $lock != null and ($runners | index($lock)) != null) as $in_wave
  | ($in_wave and $o.exit == null) as $running
  | (if (.end_gate.status? // "") == "ended" and .halted == null then {next: "done"}
     else run_next({wait: (if $running then "wait" else null end), reconciled: true,
                    reviews: review_park_possible, human: (human_park_line != null),
                    stranded: stranded_possible}) end) as $n
  | run_counts as $c
  | ((.events // []) | last) as $e
  | run_title as $t
  | current_wave as $w
  | ([((.plan.waves // []) | length), $w] | max) as $ws
  | (.costs.total_usd // 0) as $cost
  | (.plan.budget_usd // null) as $budget
  | (" · " + ($cost | usd) + (if $budget == null then "" else "/" + ($budget | usd) end)) as $tail
  | "\($c.merged)/\($c.total) merged" as $first
  | " run \(.run_id) · Wave \($w)/\($ws) · " as $rest
  # A repo name too long for the line is cut, ending in "…".
  | (100 - ($rest + $first + $tail | length)) as $room
  | (repo_short | if length <= $room then . elif $room > 1 then .[0:$room - 1] + "…" else "…" end) as $repo
  | ($repo + $rest) as $head
  | [$first,
     (if $c.in_flight > 0 then "\($c.in_flight) in flight" else empty end),
     (if $c.verifying > 0 then "\($c.verifying) verifying" else empty end),
     (if $c.merge_gate > 0 then "\($c.merge_gate) \(if (.merge_gate.mode? // "") == "ci" then "in CI" else "merging" end)" else empty end),
     (if $c.blocked > 0 then "\($c.blocked) blocked" else empty end)] as $parts
  | (reduce $parts[1:][] as $x ($parts[0];
       if (($head + . + ", " + $x + $tail) | length) <= 100 then . + ", " + $x else . end)) as $counts
  | {v: 1, run: .run_id, repo: .repo, plan: ($t.title + $t.more), wave: $w, waves: $ws,
     counts: $c, cost_usd: ($cost | r2), budget_usd: $budget,
     next: $n.next, waiting_on_artisan: ([.decisions[] | select(.status == "waiting")] | length),
     last_event: ($e.event // null), last_event_at: ($e.at // $now),
     owner: {chat_pid: (if $in_wave then ($o.chat_pid // null) else $lock end),
             chat_session: (.chat_session // null), lock_pid: $lock},
     text: ($head + $counts + $tail)}
'

# state_chat_session: the Claude session id of the chat running this call,
# from its environment (CLAUDE_CODE_SESSION_ID, else CLAUDE_SESSION_ID), or
# nothing. state.sh init and wave.sh launch record it as chat_session.
state_chat_session() {
  printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
}

state_status_path() { printf '%s/status.json\n' "$1"; }

# state_status_write run_dir [runner-pid]: rewrite status.json from the state
# file, the caller holding the lock. runner-pid is the orchestrator runner the
# lock was just handed to (state_hand_lock), and the holder. Otherwise the
# holder is the lock's, unless it is this call's own pid with no long-lived
# writer (ARTISAN_WRITER_PID), which holds it only for the call. Display only,
# so it never fails a state write: a failure leaves the last status.json.
state_status_write() {
  local run_dir="$1" file="" out="" new=""
  file=$(state_file "$run_dir")
  [ -f "$file" ] || return 0
  state_status_inputs "$@"
  new=$(jq -c --argjson lock "$STATE_ST_LOCK" --argjson runners "[$STATE_ST_RUNNERS]" --argjson now "$(state_now)" \
    "$STATE_JQ_DEFS$STATE_TITLE_JQ_DEFS$STATE_STATUS_JQ" "$file" 2>/dev/null) || return 0
  state_status_put "$run_dir" "$new"$'\n'
}

# state_status_inputs run_dir [runner-pid]: what the status line is made
# with, as state_status_write says: STATE_ST_LOCK (the holder, or null) and
# STATE_ST_RUNNERS (the runner pids, comma separated).
STATE_ST_LOCK=null STATE_ST_RUNNERS=
state_status_inputs() {
  local run_dir="$1" holder="" runners="" f="" p=""
  for f in "$run_dir"/workers/orchestrator-*/runner.pid; do
    [ -f "$f" ] || continue
    p=
    read -r p <"$f" || true
    if state_is_uint "$p"; then runners="$runners,$p"; fi
  done
  if [ $# -ge 2 ]; then
    holder=$2
    runners="$runners,$2"
  else
    holder=$(state_lock_holder "$run_dir")
    [ -n "${ARTISAN_WRITER_PID:-}" ] || [ "$holder" != "$$" ] || holder=
  fi
  state_is_uint "$holder" || holder=null
  STATE_ST_LOCK=$holder
  STATE_ST_RUNNERS=${runners#,}
}

# state_status_put run_dir content: status.json gets content, unless it
# already has it (compared by the shell, no process).
state_status_put() {
  local out="" tmp="" old=""
  out=$(state_status_path "$1")
  if [ -f "$out" ]; then
    IFS= read -r -d '' old <"$out" || true
    [ "$old" != "$2" ] || return 0
  fi
  tmp="$1/.status.json.tmp.$$"
  printf '%s' "$2" >"$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$out" || rm -f "$tmp"
  return 0
}
