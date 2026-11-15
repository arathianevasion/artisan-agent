# Shared functions for the orchestrator's per-ticket scripts (wave.sh,
# verify.sh): opening a run, reading and writing its state file, blocking a
# ticket, and checking that a returned ticket's attempt can be judged. Sourced
# after lib/state-lib.sh, never run. The sourcing script defines die().
#
# Portable to bash 3.2 (macOS) and Linux. Needs git and jq.

RUN_DIR= FILE= RUN_ID= MAIN= WT_ROOT=
open_run() { # run-dir
  [ -n "${1:-}" ] || usage
  state_require_run_dir "$1"
  RUN_DIR=$(cd "$1" && pwd)
  FILE=$(state_file "$RUN_DIR")
  state_valid_file "$FILE" || die "$(state_version_message "$FILE")"
  RUN_ID=$(basename "$RUN_DIR")
  local common=
  common=$(git -C "$RUN_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "run folder $RUN_DIR is not inside a git repository"
  MAIN=$(dirname "$common")
  WT_ROOT="$(dirname "$MAIN")/$(basename "$MAIN")-wt"
}

get() { jq -r "$@" "$FILE"; }

# worktree_setup wt (#173): the project's worktree_setup command (config.yml),
# run once in a new worktree, with ARTISAN_MAIN set to the main checkout, so a
# worker, verifier, hands-on or end-gate worktree starts with its dependencies
# (npm ci, a node_modules symlink). Unset runs nothing and returns 0. A failing
# command returns 1 with SETUP_ERR = "setup: <command> exited N: <stderr tail>",
# so the caller records a setup failure, not a red test. Not for $(...): it
# sets SETUP_ERR.
#
# The command runs for at most worktree_setup_timeout seconds (#181; default
# 900). It runs in its own session (detach-lib's detach, so no `timeout`
# binary is needed on macOS); past the limit its whole process group gets
# TERM, then KILL two seconds later, and it returns 1 with SETUP_ERR =
# "setup: setup timeout after <n>s: <command> ...: <stderr tail>". A leader
# killed from outside has its group killed too; one that never came up (no
# setsid, perl failed) returns 1 with "... could not start ...", not a timeout.
#
# A failure also sets SETUP_CMD (the command), SETUP_RC (its exit status; 124
# for a timeout; empty when it never started) and SETUP_TAIL (the last lines of its stderr), for a caller
# that records them (end-gate.sh, #182).
SETUP_ERR=
SETUP_CMD=
SETUP_RC=
SETUP_TAIL=
worktree_setup() {
  local wt="$1" conf="" cmd="" limit="" dir="" rc="" tail_="" pgid="" bg="" deadline=0 i=0 timed_out="" starting=0 never_started=""
  SETUP_ERR= SETUP_CMD= SETUP_RC= SETUP_TAIL=
  conf=$( (cd "$MAIN" && "$SCRIPT_DIR/config.sh" show) 2>/dev/null) || conf='{}'
  cmd=$(jq -r '.worktree_setup // empty' <<<"$conf" 2>/dev/null) || cmd=
  [ -n "$cmd" ] || return 0
  limit=$(jq -r '.worktree_setup_timeout // empty' <<<"$conf" 2>/dev/null) || limit=
  if ! state_is_uint "$limit" || [ "$limit" -eq 0 ]; then limit=900; fi
  declare -F detach >/dev/null || . "$SCRIPT_DIR/lib/detach-lib.sh"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/worktree-setup.XXXXXX")
  # The session leader records its pid (the process group to kill), runs the
  # command and records its exit status.
  (cd "$wt" && ARTISAN_MAIN="$MAIN" detach bash -c \
    'echo $$ >"$1/pid.tmp" && mv "$1/pid.tmp" "$1/pid"; bash -c "$2"; echo $? >"$1/rc"' _ "$dir" "$cmd") \
    </dev/null >/dev/null 2>"$dir/err" &
  bg=$!
  # SECONDS counts whole seconds: the extra one keeps the limit from coming
  # up to a second early.
  deadline=$((SECONDS + limit + 1))
  while [ ! -s "$dir/rc" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then timed_out=1; break; fi
    if [ -s "$dir/pid" ]; then
      # A leader gone without an exit status was killed from outside.
      kill -0 "$(cat "$dir/pid")" 2>/dev/null || break
    elif ! kill -0 "$bg" 2>/dev/null; then
      # detach has returned (setsid forks when the caller leads its process
      # group) but the leader never wrote its pid: give it detach_start's ten
      # seconds, then it never started.
      starting=$((starting + 1))
      [ "$starting" -le 100 ] || { never_started=1; break; }
    fi
    sleep 0.1
  done
  [ -s "$dir/pid" ] || never_started=1
  if [ ! -s "$dir/rc" ] && [ -z "$never_started" ]; then
    # Timed out, or the leader was killed: its whole group goes.
    pgid=$(cat "$dir/pid" 2>/dev/null) || pgid=
    if state_is_uint "$pgid"; then
      kill -TERM "-$pgid" 2>/dev/null || true
      while kill -0 "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.1
        i=$((i + 1))
      done
      kill -KILL "-$pgid" 2>/dev/null || true
    fi
  fi
  wait "$bg" 2>/dev/null || true
  tail_=$(tail -n 10 "$dir/err" | cut -c1-300)
  if [ -n "$never_started" ] && [ ! -s "$dir/rc" ]; then
    SETUP_ERR="setup: \`$cmd\` could not start in $wt: ${tail_:-no stderr}"
    rc=1
  elif [ -n "$timed_out" ]; then
    SETUP_ERR="setup: setup timeout after ${limit}s: \`$cmd\` in $wt was killed: ${tail_:-no stderr}"
    rc=124
  else
    rc=$(cat "$dir/rc" 2>/dev/null) || rc=
    state_is_uint "$rc" || rc=1
    [ "$rc" -eq 0 ] || SETUP_ERR="setup: \`$cmd\` exited $rc in $wt: ${tail_:-no stderr}"
  fi
  rm -rf "$dir"
  [ "$rc" -ne 0 ] || return 0
  SETUP_CMD=$cmd SETUP_RC=$rc SETUP_TAIL=$tail_
  # One that never started has no exit status of its own.
  [ "${SETUP_ERR#*could not start in }" = "$SETUP_ERR" ] || SETUP_RC=
  return 1
}

writer() { printf '%s\n' "${ARTISAN_WRITER_PID:-$$}"; }

# apply filter [jq args]: one locked, one-step event write with the shared defs.
apply() {
  local filter="$1"
  shift
  state_with_lock "$RUN_DIR" state_apply "$RUN_DIR" "$STATE_JQ_DEFS$filter" \
    --argjson now "$(state_now)" "$@"
}

integration_branch() { get '.integration.branch'; }
# The integration branch's gated tip: while a merge gate runs (wave.sh merge,
# merge_gate in the state file) the branch already holds the merge commit the
# gate is judging, so new work branches from the commit before it; while a
# merge batch is settling (merge_batch), from its last green commit.
integration_tip() {
  local pre=""
  pre=$(get '.merge_gate.pre // .merge_batch.pre // ""')
  if [ -n "$pre" ]; then printf '%s\n' "$pre"
  else git -C "$MAIN" rev-parse -q --verify "refs/heads/$(integration_branch)"; fi
}
integration_worktree() {
  local wt=
  wt=$(get '.integration.worktree // ""')
  [ -n "$wt" ] && [ -d "$wt" ] || die "no integration worktree for run $RUN_ID; run wave.sh start first"
  printf '%s\n' "$wt"
}

# The estimate passed to run-ticket.sh, which caps the session at twice it.
clamp_estimate() { # usd
  if [ -n "${ARTISAN_MAX_BUDGET_USD:-}" ]; then
    awk -v e="$1" -v c="$ARTISAN_MAX_BUDGET_USD" 'BEGIN { h = c / 2; printf "%.2f", (e > h ? h : e) }'
  else
    printf '%s\n' "$1"
  fi
}

EXTRA=()
read_extra_args() {
  EXTRA=()
  [ -n "${ARTISAN_CLAUDE_ARGS:-}" ] || return 0
  read -r -a EXTRA <<<"$ARTISAN_CLAUDE_ARGS"
}

# block ticket reason: the ticket goes to the Artisan with an exception decision.
block() {
  apply '
    .tickets[$t] |= (.status = "blocked" | .pid = null | .blocked_reason = $r)
    | .decisions += [{id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
                      question: "Ticket \($t) is blocked: \($r). Retry with notes, reslice, take it myself or drop; or bypass or defer its exception gate?",
                      status: "waiting", at: $now}]
    | event({event: "blocked", ticket: $t, reason: $r}; $now)' --arg t "$1" --arg r "$2"
}

# queue_sync_decision urgent-ticket reason: main could not join the
# integration branch after the urgent ticket shipped (a conflict whose one
# resolve try failed or was already used, or a suite gone red). The urgent
# ticket is not blocked (its PR is merged); the Artisan gets a decision.
queue_sync_decision() {
  apply '.decisions += [{id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
      question: "Merging main into the integration branch after urgent #\($t) shipped did not land: \($r). Nothing changed; the integration branch is behind main. Resolve it by hand in the integration worktree (git merge main) and run end-gate.sh urgent-finish again, or take it yourself?",
      status: "waiting", at: $now}]
    | event({event: "main-sync-failed", ticket: $t, reason: $r}; $now)' --arg t "$1" --arg r "$2"
}

# check_returned script ticket what: a returned ticket whose attempt completed
# and whose result file describes its branch tip. Sets ATTEMPT and TIP.
# Otherwise exits: 8 the worker is still running; 6 the attempt did not
# complete (a failed attempt: queued for a fresh worker, or blocked once it
# has used its attempts) or the result describes another commit (blocked).
# "what" ends the refusal: "not merged", "not verified".
ATTEMPT= TIP=
check_returned() {
  local who="$1" t="$2" what="$3" status= cls= branch= claimed=
  status=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ "$status" = returned ] || die "#$t is ${status:-not in the run}, not returned; run sweep.sh first"
  ATTEMPT=$(get --arg t "$t" '.tickets[$t].attempts')
  # A hands-on ticket the Artisan finished (human.sh) has no worker session.
  if [ "$(get --arg t "$t" '.tickets[$t].human.done_at // null | . != null')" = true ]; then
    cls="completed -"
  else
    # A classifier error is not a dead session: stop, and let the caller run it again.
    cls=$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$ATTEMPT") \
      || state_die 1 "$who: could not classify #$t attempt $ATTEMPT; nothing recorded, run it again"
  fi
  case "$cls" in
    running*) state_die 8 "$who: #$t's worker is still running; wait for its exit record" ;;
    completed*) ;;
    *)
      apply 'failed_attempt($t; $r; $now)' --arg t "$t" --arg r "attempt $ATTEMPT did not complete ($cls)"
      state_die 6 "$who: #$t $what: attempt $ATTEMPT is $cls; it is now $(get --arg t "$t" '.tickets[$t].status')" ;;
  esac
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  TIP=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch") || die "no branch $branch"
  claimed=$(get --arg t "$t" '.tickets[$t].result.commit // ""')
  if [ -n "$claimed" ] && [ "$(git -C "$MAIN" rev-parse -q --verify "$claimed^{commit}" 2>/dev/null)" != "$TIP" ]; then
    block "$t" "the result describes $claimed but $branch is at $TIP"
    state_die 6 "$who: #$t $what: the result file does not describe the branch tip"
  fi
}

# human_checks_view checks-json: the part of a gate's view packet.py's Human
# checks section reads (references/human-checks.md). checks-json is a list of
# {ticket, for, carried_from?, state?, deferral?}; each gains its title and
# its issue body (what to check, its criteria) from the tracker. The build to
# try is the integration branch's tip and the run's integration worktree.
human_checks_view() {
  local list="$1" t="" issue="" out="" tip="" ib=""
  # Each check carries its issue's whole body, one per line: the issue and
  # the checks reach jq on stdin, never as an argument (#208).
  for t in $(jq -r '.[].ticket' <<<"$list"); do
    issue=$(gh api "repos/$(get '.repo')/issues/$t") || die "could not read Human check #$t from the tracker"
    out=$out$(jq -c --argjson l "$list" --arg t "$t" --arg title "$(get --arg t "$t" '.plan.tickets[$t].title // ""')" '
      . as $i | ($l[] | select(.ticket == $t))
      + {title: (if $title == "" then ($i.title // null) else $title end), body: ($i.body // "")}' <<<"$issue")$'\n'
  done
  ib=$(integration_branch)
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib" 2>/dev/null || true)
  jq -sc --arg tip "$tip" --arg wt "$(get '.integration.worktree // ""')" --arg b "$ib" \
    '{human_checks: ., build: {commit: $tip, worktree: $wt, branch: $b}}' <<<"$out"
}
