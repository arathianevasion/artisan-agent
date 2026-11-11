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

# state_lock run_dir pid
# 0: taken (or already held by pid). 3: held by another live process.
state_lock() {
  local run_dir="$1" pid="$2" lock holder tries=0
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

state_valid_file() { # path
  jq -e --argjson v "$ARTISAN_STATE_SCHEMA_VERSION" \
    'type == "object" and .schema_version == $v' "$1" >/dev/null 2>&1
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
  state_valid_file "$file" || { printf 'unreadable or wrong schema version: %s\n' "$file" >&2; return 1; }
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
STATE_JQ_DEFS='
  def new_ticket($t): {
    status: "queued", attempts: 0, pid: null,
    branch: (.plan.tickets[$t].branch // ("agent/" + $t)),
    dispatched_at: null, deadline_at: null, result: null, evidence: null,
    merge_commit: null, cost_usd: 0, failures: []
  };
  def merged($t; $sha):
    .tickets[$t] |= (.status = "merged" | .merge_commit = $sha | .pid = null)
    | .integration.merges |= (map(select(.ticket != $t)) + [{ticket: $t, commit: $sha}]);
'
