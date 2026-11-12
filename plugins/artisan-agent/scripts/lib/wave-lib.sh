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
writer() { printf '%s\n' "${ARTISAN_WRITER_PID:-$$}"; }

# apply filter [jq args]: one locked, one-step event write with the shared defs.
apply() {
  local filter="$1"
  shift
  state_with_lock "$RUN_DIR" state_apply "$RUN_DIR" "$STATE_JQ_DEFS$filter" \
    --argjson now "$(state_now)" "$@"
}

integration_branch() { get '.integration.branch'; }
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
