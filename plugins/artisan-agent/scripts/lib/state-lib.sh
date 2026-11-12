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
  local pid="$1" stat
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  stat=$(ps -o stat= -p "$pid" 2>/dev/null) || return 1
  [ -n "$stat" ] || return 1
  case "$stat" in Z*) return 1 ;; esac
  return 0
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
  local run_dir="$1" file status machine
  [ -z "${ARTISAN_MOVING:-}" ] || return 0
  file=$(state_file "$run_dir")
  [ -f "$file" ] || return 0
  status=$(jq -r '.location.status // empty' "$file" 2>/dev/null) || return 0
  [ -n "$status" ] || return 0
  machine=$(jq -r '.location.machine // empty' "$file")
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
  local run_dir="$1" pid="$2" lock holder tries=0
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
  local run_dir="$1" pid="$2" holder
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
  local run_dir="$1" pid
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
  local run_dir="$1" from="$2" to="$3" lock tmp
  lock=$(state_lock_path "$run_dir")
  [ "$(state_lock_holder "$run_dir")" = "$from" ] || {
    printf 'cannot hand over the state lock: pid %s does not hold it\n' "$from" >&2
    return 3
  }
  tmp="$run_dir/.state.lock.tmp.$$"
  rm -f "$tmp"
  ln -s "$to" "$tmp" && mv -f "$tmp" "$lock"
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
  local file="$1" found started
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
  local run_dir="$1" tmp="$2" file
  file=$(state_file "$run_dir")
  if ! state_valid_file "$tmp"; then
    rm -f "$tmp"
    printf 'refusing to write: not a schema version %s state file\n' "$ARTISAN_STATE_SCHEMA_VERSION" >&2
    return 1
  fi
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$file"
}

state_tmp() { # run_dir
  printf '%s/.state.json.tmp.%s\n' "$1" "$$"
}

# state_apply run_dir filter [jq args...]
# Read, transform with jq, rewrite in one step. Caller holds the lock.
state_apply() {
  local run_dir="$1" filter="$2" tmp file
  shift 2
  file=$(state_file "$run_dir")
  [ -f "$file" ] || { printf 'no state file at %s\n' "$file" >&2; return 1; }
  state_valid_file "$file" || { state_version_message "$file" >&2; return 1; }
  tmp=$(state_tmp "$run_dir")
  if ! jq "$@" "$filter" "$file" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  state_commit "$run_dir" "$tmp"
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
#   slice_gates: the plan's slice gates, each {id, slice, role, problem,
#     solution, tickets} (references/review-gates.md)
#   gate_due(g): every ticket of gate g merged (or closed) and the gate not
#     yet answered (approved, bypassed, deferred or redirected: gate-action.sh)
#   decide(id; d; at): waiting decision id decided, with the decision record d
#     (references/decision-record.md); unchanged when it is not waiting
#   out_of_run: the statuses that take a ticket out of the run without a
#     merge (references/gate-actions.md); with merged and closed, it is done
#   gate_holds(t): t is in a slice gate that is due: its dependents wait
STATE_JQ_DEFS='
  def attempt_cost($t; $n; $usd):
    if $usd == null then .
    else .tickets[$t].attempt_costs[($n | tostring)] = $usd
      | .tickets[$t].cost_usd = ([.tickets[$t].attempt_costs[]] | add) end;
  def event($e; $at):
    .events = ((.events // []) as $log | $log + [{seq: (($log | length) + 1), at: $at} + $e]);
  def new_ticket($t): {
    status: "queued", attempts: 0, pid: null,
    branch: (.plan.tickets[$t].branch // ("agent/" + $t)),
    dispatched_at: null, deadline_at: null, result: null, evidence: null,
    merge_commit: null, cost_usd: 0, failures: []
  };
  def current_wave: ((.orchestrators // []) | last | .wave) // 0;
  def failed_attempt($t; $reason; $at):
    (.plan.attempts_per_ticket + (.tickets[$t].extra_attempts // 0)) as $max
    | .tickets[$t] as $tk
    | .tickets[$t] |= (
        .failures += [{attempt: .attempts, reason: $reason, at: $at}]
        | .pid = null
        | .status = (if .attempts >= $max then "blocked" else "queued" end))
    | if $tk.attempts >= $max then
        .decisions += [{
          id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
          question: "Ticket \($t) failed \($tk.attempts) attempts (last: \($reason)). Retry with notes, reslice, take it myself or drop; or bypass or defer its exception gate?",
          status: "waiting", at: $at
        }]
      else . end
    | event({event: "failed", ticket: $t, attempt: $tk.attempts, reason: $reason,
             next: .tickets[$t].status}; $at);
  def merged($t; $sha):
    .tickets[$t] |= (.status = "merged" | .merge_commit = $sha | .pid = null)
    | .integration.merges |= (map(select(.ticket != $t)) + [{ticket: $t, commit: $sha}]);
  def slice_gates:
    . as $s
    | [($s.plan.gates // []) | to_entries[] | select((.value.kind? // "") == "slice")
       | .key as $k | .value as $g
       | {id: "slice-\($k + 1)",
          slice: ($g.slice // "slice \($k + 1)"),
          role: ($g.role // "Engineering (QA)"),
          problem: ($g.problem // null), solution: ($g.solution // null),
          tickets: ([($g.tickets // (if $g.after != null then [$g.after] else null end)
                      // [$s.plan.tickets | to_entries[] | select($g.slice != null and .value.slice? == $g.slice) | .key])
                     | .. | scalars | tostring] | unique_by(tonumber? // .))}
       | select(.tickets != [])];
  def gate_due($g):
    . as $s
    | all($g.tickets[]; ($s.tickets[.].status // "") as $st | $st == "merged" or $st == "closed")
      and any($g.tickets[]; $s.tickets[.].status? == "merged")
      and ([($s.review_gates // [])[] | select(.id == $g.id and .status != "open")] == []);
  def decide($id; $d; $at):
    .decisions |= map(if .id == $id and .status == "waiting"
      then . + $d + {status: "decided", decided_at: $at} else . end);
  def out_of_run: ["dropped", "resliced", "bypassed", "deferred"];
  def gate_holds($t):
    . as $s | any(slice_gates[]; (.tickets | index($t)) != null and (. as $g | $s | gate_due($g)));
'
