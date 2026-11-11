#!/usr/bin/env bash
# A run's waves: its integration worktree, the orchestrator that runs each
# wave, and the orchestrator's steps for one ticket. The two tiers and who
# calls what: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/SKILL.md and
# references/orchestrator.md beside it. State file: references/state-file.md.
#
# Usage, from the Engineering chat:
#   wave.sh start <run-dir> [--base REF]
#       create the integration branch (from REF, default the main checkout's
#       branch) and the run's integration worktree beside the repo, at
#       <repo>-wt/run-<run-id>; record both. Prints the worktree. Idempotent.
#   wave.sh launch <run-dir> [--model M] [--estimate-usd N] [-- claude args...]
#       launch the next wave's orchestrator: a detached headless claude -p
#       under run-ticket.sh --role orchestrator, in the integration worktree.
#       The state lock passes to the orchestrator's runner for the wave.
#       Prints "orchestrator-w<wave> <attempt> <runner-pid>".
#   wave.sh status <run-dir>
#       how the run stands, from files only: the orchestrator's exit record
#       and classification, then (once it has ended) the reconciler (git, the
#       sweep, the tracker). First line "orchestrator: <state>", second
#       "next: <launch|wait|decide|blocked|done>", then a ticket table.
#
# Usage, from the orchestrator:
#   wave.sh dispatch <run-dir> <ticket> [--brief TEXT]
#       refuse unless the ticket is in scope (4), queued, every blocker is
#       merged into the integration branch or closed (5) and a slot is free
#       under Max Agents (9); then branch a worktree from the integration tip
#       and launch the worker with /artisan-agent:implement. Prints its pid.
#   wave.sh merge <run-dir> <ticket>
#       merge a completed worker's branch --no-ff into the integration
#       branch in the integration worktree, run the plan's suite command
#       there, record the merge and remove the worker's worktree. Prints the
#       merge commit. 8: the worker is still running. 6: refused or conflict,
#       7: suite red (both mark the ticket blocked and queue a decision).
#   wave.sh close <run-dir> <ticket>
#       post the evidence on the ticket, tick its met criteria, close it.
#   wave.sh report <run-dir>
#       the wave report (JSON) the orchestrator writes as its result file.
#
# Environment:
#   ARTISAN_WRITER_PID      the long-lived pid writing state (the chat's
#                           session between waves; set for the orchestrator)
#   ARTISAN_CLAUDE_ARGS     extra arguments, split on whitespace, added to
#                           every orchestrator and worker session
#   ARTISAN_MAX_BUDGET_USD  ceiling on any one session's --max-budget-usd
#                           (for trials; caps are otherwise twice the estimate)
#
# Exit status: 0 ok, 1 error, 2 usage, 3 lock held or an orchestrator still
# running, 4 outside the scope, 5 a blocker not merged, 6 merge refused or
# conflicted, 7 suite red, 8 worker still running, 9 no free slot.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

DEFAULT_ORCHESTRATOR_MODEL=claude-sonnet-5-5
DEFAULT_ORCHESTRATOR_ESTIMATE_USD=1
SESSION_TOOLS="Bash,Read,Write,Edit,Glob,Grep,Skill,Agent"

usage() { state_usage "$0"; }
die() { state_die 1 "wave.sh: $*"; }

# ----------------------------------------------------------------- helpers

RUN_DIR= FILE= RUN_ID= MAIN= WT_ROOT=
open_run() { # run-dir
  [ -n "${1:-}" ] || usage
  state_require_run_dir "$1"
  RUN_DIR=$(cd "$1" && pwd)
  FILE=$(state_file "$RUN_DIR")
  state_valid_file "$FILE" || die "unreadable or wrong schema version: $FILE"
  RUN_ID=$(basename "$RUN_DIR")
  local common
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
  local wt
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
                      question: "Ticket \($t) is blocked: \($r). Redirect, bypass or defer?",
                      status: "waiting", at: $now}]
    | event({event: "blocked", ticket: $t, reason: $r}; $now)' --arg t "$1" --arg r "$2"
}

# ------------------------------------------------------------------- start

cmd_start() {
  open_run "${1:-}"
  shift
  local base= ib wt sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || usage; base=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  ib=$(integration_branch)
  if [ -z "$base" ]; then
    base=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$MAIN" rev-parse HEAD)
  fi
  if ! git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib" >/dev/null; then
    git -C "$MAIN" branch "$ib" "$base" >/dev/null || die "could not create $ib from $base"
  fi
  wt="$WT_ROOT/run-$RUN_ID"
  if [ ! -d "$wt" ]; then
    mkdir -p "$WT_ROOT"
    git -C "$MAIN" worktree add -q "$wt" "$ib" >/dev/null 2>&1 \
      || die "could not add the integration worktree $wt for $ib"
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  apply '
    if .integration.worktree == $wt then .
    else .integration.worktree = $wt
         | .integration.base = (.integration.base // $sha)
         | event({event: "integration", branch: .integration.branch, worktree: $wt, base: $sha}; $now)
    end' --arg wt "$wt" --arg sha "$sha"
  printf '%s\n' "$wt"
}

# ------------------------------------------------------------------ launch

# Last orchestrator: "id attempt wave pid", or nothing. Its pid is its
# runner's, from the runner's own pid file ("-" before it has one).
last_orchestrator() {
  local line pid
  line=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt) \(.wave)"')
  [ -n "$line" ] || return 0
  set -- $line
  pid=$(cat "$RUN_DIR/workers/$1.$2/runner.pid" 2>/dev/null || echo -)
  printf '%s %s\n' "$line" "$pid"
}

orchestrator_state() { # id attempt -> classify-worker.sh's line
  "$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$1" "$2" 2>/dev/null || echo "failed vanished"
}

cmd_launch() {
  open_run "${1:-}"
  shift
  local model= estimate= args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
      --estimate-usd) [ $# -ge 2 ] || usage; estimate=$2; shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) usage ;;
    esac
  done
  local wt last id attempt wave pid cls me deadline minutes prompt runner version tip
  wt=$(integration_worktree)
  wave=1 attempt=1
  last=$(last_orchestrator)
  if [ -n "$last" ]; then
    set -- $last
    id=$1 attempt=$2 wave=$3 pid=$4
    cls=$(orchestrator_state "$id" "$attempt")
    case "$cls" in
      running*) state_die 3 "wave.sh: the orchestrator for wave $wave is still running (pid $pid)" ;;
      completed*) wave=$((wave + 1)) attempt=1 ;;
      *) attempt=$((attempt + 1)) ;;   # it ended without finishing: carry the same wave on
    esac
  fi
  id="orchestrator-w$wave"

  # The chat's writer pid holds the lock (or takes it now) until it hands it on.
  me=$(writer)
  state_lock "$RUN_DIR" "$me" || exit 3
  export ARTISAN_WRITER_PID=$me

  [ -n "$model" ] || model=$(get --arg d "$DEFAULT_ORCHESTRATOR_MODEL" '.plan.orchestrator.model // $d')
  [ -n "$estimate" ] || estimate=$(get --arg d "$DEFAULT_ORCHESTRATOR_ESTIMATE_USD" '.plan.orchestrator.estimate_usd // $d')
  estimate=$(clamp_estimate "$estimate")
  # The orchestrator outlives every worker it waits on: its deadline is the
  # longest worker deadline plus half an hour.
  deadline=$(get '.plan.orchestrator.deadline_seconds // (([.plan.tickets[]?.caps.deadline_seconds // 0] | max // 0) + 1800)')
  minutes=$(awk -v s="$deadline" 'BEGIN { printf "%d", (s / 120 < 1 ? 1 : s / 120) }')

  mkdir -p "$RUN_DIR/prompts"
  prompt="$RUN_DIR/prompts/$id.$attempt.md"
  cat >"$prompt" <<EOF
You are the orchestrator for wave $wave of run $RUN_ID. Follow $PLUGIN_DIR/skills/implement-plan/references/orchestrator.md exactly; it is your whole brief.

- Run folder: $RUN_DIR
- Integration worktree: $wt (branch $(integration_branch)); you are in it.
- Scripts: $PLUGIN_DIR/scripts
- Your state-writer pid is already exported as ARTISAN_WRITER_PID, and you hold the state lock.
EOF

  version=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)
  tip=$(git -C "$wt" rev-parse HEAD)
  "$SCRIPT_DIR/state.sh" wave-start "$RUN_DIR" "$wave" "$version" - "$tip" - >/dev/null

  apply '
    .orchestrators = ((.orchestrators // []) + [{id: $id, wave: $w, attempt: $a, launched_at: $now}])
    | event({event: "orchestrator", id: $id, wave: $w, attempt: $a}; $now)' \
    --arg id "$id" --argjson w "$wave" --argjson a "$attempt"

  # The runner takes the lock over from this writer before its session
  # starts: the orchestrator is the writer for the wave.
  read_extra_args
  runner=$("$SCRIPT_DIR/run-ticket.sh" --role orchestrator --lock-from "$me" --run-dir "$RUN_DIR" --ticket "$id" \
    --attempt "$attempt" --prompt-file "$prompt" --workdir "$wt" --model "$model" \
    --estimate-usd "$estimate" --expected-minutes "$minutes" --deadline-seconds "$deadline" \
    -- --permission-mode acceptEdits --allowedTools "$SESSION_TOOLS" \
    --add-dir "$MAIN" --add-dir "$WT_ROOT" \
    ${EXTRA[@]+"${EXTRA[@]}"} ${args[@]+"${args[@]}"}) || die "could not launch $id"

  [ "$(state_lock_holder "$RUN_DIR")" = "$runner" ] \
    || die "$id started (pid $runner) but did not take the state lock; see $RUN_DIR/workers/$id.$attempt/runner.log"
  printf '%s %s %s\n' "$id" "$attempt" "$runner"
}

# ------------------------------------------------------------------ status

ticket_table() {
  jq -r '
    . as $s
    | ($s.plan.waves // []) as $w
    | "| Ticket | Wave | Model | Status |",
      "|---|---|---|---|",
      ( $s.plan.scope[] as $t | $s.tickets[$t] as $k | $s.plan.tickets[$t] as $p
        | ([$w | to_entries[] | select(.value | index($t)) | .key + 1] | first // "-") as $wave
        | "| #\($t) (\($p.title // "untitled")) | \($wave) | \($p.model // "-") | \($k.status)"
          + (if $k.status == "merged" then " as \($k.merge_commit[0:7])"
                + (if $k.tracker_closed then ", closed" else ", not closed yet" end)
             elif $k.status == "blocked" then ": \($k.blocked_reason // ($k.failures | last | .reason) // "see decisions")"
             elif $k.status == "in_flight" then " (attempt \($k.attempts))"
             else "" end) + " |" )' "$FILE"
}

cmd_status() {
  open_run "${1:-}"
  local last id attempt wave pid cls next reconciled=1 waiting
  last=$(last_orchestrator)
  if [ -z "$last" ]; then
    echo "orchestrator: none"
  else
    set -- $last
    id=$1 attempt=$2 wave=$3 pid=$4
    cls=$(orchestrator_state "$id" "$attempt")
    echo "orchestrator: $cls (wave $wave, attempt $attempt, pid $pid)"
  fi
  case "${cls:-}" in
    running*) next=wait ;;
    *)
      # Ended (or never started): this tier writes again. Between waves the
      # chat holds the lock with its own long-lived pid.
      if [ -n "${ARTISAN_WRITER_PID:-}" ]; then
        state_lock "$RUN_DIR" "$ARTISAN_WRITER_PID" || exit 3
      fi
      "$SCRIPT_DIR/reconcile.sh" "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.status.err" || {
        reconciled=0
        "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" >/dev/null
      }
      waiting=$(get '[.decisions[] | select(.status == "waiting")] | length')
      if [ "$waiting" -gt 0 ]; then next=decide
      elif [ "$reconciled" -eq 0 ]; then next=blocked
      elif [ "$(get '.frontier | length')" -gt 0 ]; then next=launch
      elif [ "$(get '[.plan.scope[] as $t | .tickets[$t].status | select(. == "merged" or . == "closed")] | length')" \
             = "$(get '.plan.scope | length')" ]; then next=done
      else next=blocked
      fi
      ;;
  esac
  echo "next: $next"
  [ "$reconciled" -eq 1 ] || echo "tracker: unreadable, frontier not recomputed ($(tr '\n' ' ' <"$RUN_DIR/.status.err"))"
  echo
  ticket_table
  if [ "${next}" = decide ]; then
    echo
    echo "| Decision | Ticket | Question |"
    echo "|---|---|---|"
    get '.decisions[] | select(.status == "waiting") | "| \(.id) (\(.kind)) | #\(.ticket // "-") | \(.question) |"'
  fi
}

# ---------------------------------------------------------------- dispatch

# Every blocker of the ticket must be merged into the integration branch (a
# blocker in the run) or closed (one outside it). The tracker says what blocks
# what; git says what is merged. Refuses with 5, or 1 if either can't be read.
check_blockers() { # ticket
  local t="$1" repo ib tip blockers b state status sha
  repo=$(get '.repo')
  ib=$(integration_branch)
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib") || die "no integration branch $ib"
  blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
    || die "could not read the blockers of #$t from the tracker; not dispatching blind"
  for b in $(printf '%s' "$blockers" | jq -r '.[] | "\(.number)=\(.state | ascii_downcase)"'); do
    state=${b#*=} b=${b%%=*}
    status=$(get --arg b "$b" '.tickets[$b].status // ""')
    if [ -n "$status" ]; then
      sha=$(get --arg b "$b" '.tickets[$b].merge_commit // ""')
      if [ "$status" != merged ] || [ -z "$sha" ] || ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        state_die 5 "wave.sh: refusing #$t: its blocker #$b is not merged into $ib (status $status); dispatch only on merged work"
      fi
    elif [ "$state" != closed ]; then
      state_die 5 "wave.sh: refusing #$t: its blocker #$b, outside this run, is still open"
    fi
  done
}

cmd_dispatch() {
  open_run "${1:-}"
  local t="${2:-}" brief=
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) [ $# -ge 2 ] || usage; brief=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$t" || exit $?
  local status in_flight max
  status=$(get --arg t "$t" '.tickets[$t].status')
  [ "$status" = queued ] || die "#$t is $status, not queued"
  in_flight=$(get '[.tickets[] | select(.status == "in_flight")] | length')
  max=$(get '.plan.max_agents // 5')
  [ "$in_flight" -lt "$max" ] || state_die 9 "wave.sh: no free slot: $in_flight of Max Agents $max in flight"
  check_blockers "$t"

  local ib base branch n wt prev repo title path expected estimate minutes model turns deadline prompt pid ref
  ib=$(integration_branch)
  base=$(git -C "$MAIN" rev-parse "refs/heads/$ib")
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  n=$(( $(get --arg t "$t" '.tickets[$t].attempts') + 1 ))
  wt="$WT_ROOT/$RUN_ID-$t.$n"
  prev=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$prev" ] && [ -d "$prev" ]; then
    # A retry continues the same branch in a fresh worktree; the old one must be clean.
    git -C "$MAIN" worktree remove "$prev" 2>/dev/null \
      || die "the previous attempt's worktree $prev has uncommitted work; look at it before a retry"
  fi
  mkdir -p "$WT_ROOT"
  if git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git -C "$MAIN" worktree add -q "$wt" "$branch" >/dev/null 2>&1 || die "could not add worktree $wt for $branch"
  else
    git -C "$MAIN" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 || die "could not add worktree $wt"
  fi

  repo=$(get '.repo')
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  path=$(get --arg t "$t" '.plan.tickets[$t].ticket_path // ""')
  expected=$(get --arg t "$t" '.plan.tickets[$t].expected_output // "see the ticket'"'"'s acceptance criteria"')
  estimate=$(clamp_estimate "$(get --arg t "$t" '.plan.tickets[$t].estimate_usd // 1')")
  minutes=$(get --arg t "$t" '.plan.tickets[$t].expected.minutes // 30')
  model=$(get --arg t "$t" '.plan.tickets[$t].model // ""')
  turns=$(get --arg t "$t" '.plan.tickets[$t].caps.max_turns // ""')
  deadline=$(get --arg t "$t" '.plan.tickets[$t].caps.deadline_seconds // ""')
  if [ -n "$path" ]; then ref="$path (ticket $t)"; else ref="#$t on $repo"; fi

  mkdir -p "$RUN_DIR/prompts"
  prompt="$RUN_DIR/prompts/$t.$n.md"
  cat >"$prompt" <<EOF
/artisan-agent:implement $ref: $title

You are the worker for ticket $t, attempt $n, in run $RUN_ID.
- Base: $base (the integration branch $ib). Your branch: $branch, already checked out here.
- Expected output: $expected
- Write the evidence record to the result file named below, as in $PLUGIN_DIR/references/evidence-record.md.
- Do not close the ticket, edit the tracker, merge or push. Do not use git stash; commit instead.
EOF
  [ -z "$brief" ] || printf -- '- Brief: %s\n' "$brief" >>"$prompt"
  if [ "$n" -gt 1 ]; then
    printf -- '- This is a retry. The last attempt failed: %s\n' \
      "$(get --arg t "$t" '.tickets[$t].failures | last | "\(.reason)"')" >>"$prompt"
  fi

  read_extra_args
  local caps=()
  [ -z "$turns" ] || caps+=(--max-turns "$turns")
  [ -z "$deadline" ] || caps+=(--deadline-seconds "$deadline")
  [ -z "$model" ] || caps+=(--model "$model")
  pid=$("$SCRIPT_DIR/run-ticket.sh" --run-dir "$RUN_DIR" --ticket "$t" --attempt "$n" \
    --prompt-file "$prompt" --workdir "$wt" --estimate-usd "$estimate" --expected-minutes "$minutes" \
    ${caps[@]+"${caps[@]}"} \
    -- --permission-mode acceptEdits --allowedTools "$SESSION_TOOLS" --add-dir "$RUN_DIR/results" \
    ${EXTRA[@]+"${EXTRA[@]}"}) || die "could not launch the worker for #$t"

  if [ -n "$deadline" ]; then
    "$SCRIPT_DIR/state.sh" dispatch "$RUN_DIR" "$t" "$pid"
  else
    "$SCRIPT_DIR/state.sh" dispatch "$RUN_DIR" "$t" "$pid" "$(( $(state_now) + minutes * 120 ))"
  fi
  apply '.tickets[$t] |= (.worktree = $wt | .base = $base)' --arg t "$t" --arg wt "$wt" --arg base "$base"
  printf '%s\n' "$pid"
}

# ------------------------------------------------------------------- merge

cmd_merge() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local status n cls branch tip claimed wt ib suite pre sha log title worker_wt
  status=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ "$status" = returned ] || die "#$t is ${status:-not in the run}, not returned; run sweep.sh first"
  n=$(get --arg t "$t" '.tickets[$t].attempts')
  cls=$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$n" 2>/dev/null || echo "failed vanished")
  case "$cls" in
    running*) state_die 8 "wave.sh: #$t's worker is still running; wait for its exit record" ;;
    completed*) ;;
    *) block "$t" "attempt $n did not complete ($cls)"; state_die 6 "wave.sh: #$t not merged: attempt $n is $cls" ;;
  esac
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch") || die "no branch $branch"
  claimed=$(get --arg t "$t" '.tickets[$t].result.commit // ""')
  if [ -n "$claimed" ] && [ "$(git -C "$MAIN" rev-parse -q --verify "$claimed^{commit}" 2>/dev/null)" != "$tip" ]; then
    block "$t" "the result describes $claimed but $branch is at $tip"
    state_die 6 "wave.sh: #$t not merged: the result file does not describe the branch tip"
  fi
  suite=$(get '.plan.suite_command // ""')
  [ -n "$suite" ] || die "the plan has no suite_command; the full suite must run after every merge"
  wt=$(integration_worktree)
  ib=$(integration_branch)
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "the integration worktree $wt has uncommitted changes"
  pre=$(git -C "$wt" rev-parse HEAD)
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  if ! git -C "$wt" merge --no-ff --no-edit -m "Merge #$t ($title) into $ib" "$branch" >/dev/null 2>&1; then
    local paths
    paths=$(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')
    git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
    block "$t" "merge conflict in ${paths:-unknown paths}"
    state_die 6 "wave.sh: #$t not merged: conflict in ${paths:-unknown paths}"
  fi
  mkdir -p "$RUN_DIR/merges"
  log="$RUN_DIR/merges/$t.$n.suite.log"
  if ! (cd "$wt" && sh -c "$suite") >"$log" 2>&1; then
    git -C "$wt" reset -q --hard "$pre"
    apply '.tickets[$t].suite = {command: $c, passed: false, log: $l}' --arg t "$t" --arg c "$suite" --arg l "merges/$t.$n.suite.log"
    block "$t" "the suite failed after merging (merges/$t.$n.suite.log); the merge was undone"
    state_die 7 "wave.sh: #$t not merged: the suite failed after the merge; see $log"
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  "$SCRIPT_DIR/state.sh" merge "$RUN_DIR" "$t" "$sha"
  apply '.tickets[$t].suite = {command: $c, passed: true, log: $l}' --arg t "$t" --arg c "$suite" --arg l "merges/$t.$n.suite.log"
  worker_wt=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$worker_wt" ] && [ -d "$worker_wt" ]; then
    git -C "$MAIN" worktree remove "$worker_wt" 2>/dev/null \
      || echo "wave.sh: left $worker_wt in place (it has changes); the merge stands" >&2
  fi
  printf '%s\n' "$sha"
}

# ------------------------------------------------------------------- close

cmd_close() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local status repo ib sha result body newbody
  status=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ "$status" = merged ] || die "#$t is ${status:-not in the run}, not merged; only merged work closes"
  [ "$(get --arg t "$t" '.tickets[$t].tracker_closed // false')" != true ] || return 0
  repo=$(get '.repo')
  ib=$(integration_branch)
  sha=$(get --arg t "$t" '.tickets[$t].merge_commit')
  result=$(get --arg t "$t" '.tickets[$t].result.file // ""')
  [ -z "$result" ] || result="$RUN_DIR/$result"
  mkdir -p "$RUN_DIR/merges"
  body="$RUN_DIR/merges/$t.comment.md"
  {
    printf 'Merged into `%s` as %s by run %s; the full suite passed after the merge.\n\n' "$ib" "$sha" "$RUN_ID"
    if [ -n "$result" ] && [ -f "$result" ]; then
      jq -r '
        def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
        def ev: if type == "object" then
            ([(.tests // [])[]] + [(.checks // [])[] | "\(.command): \(.result)"]
             + (if .diff then [.diff] else [] end) + (if .why then [.why] else [] end)) | join("; ")
          else tostring end;
        "| Criterion | Met | Evidence |", "|---|---|---|",
        ((.acceptance // [])[] | "| \(.criterion | cell) | \(if .met then "yes" else "no" end) | \(.evidence | ev | cell) |"),
        "",
        "Suite: \(.tests.command // "-") → \(.tests.summary // "-" | cell)",
        "Unsure: \(if (.unsure // []) == [] then "nothing" else (.unsure | join(" ")) end)",
        "Decisions made alone: \((.decisions // []) | length). Review remarks: \((.review.remarks // []) | length)."' "$result"
    fi
  } >"$body"
  gh issue comment "$t" -R "$repo" --body-file "$body" >/dev/null || die "could not comment on #$t"
  if [ -n "$result" ] && [ -f "$result" ]; then
    newbody="$RUN_DIR/merges/$t.body.md"
    if gh issue view "$t" -R "$repo" --json body -q .body >"$newbody.orig" 2>/dev/null \
      && python3 -I "$SCRIPT_DIR/lib/tick-criteria.py" "$result" <"$newbody.orig" >"$newbody" \
      && ! cmp -s "$newbody.orig" "$newbody"; then
      gh issue edit "$t" -R "$repo" --body-file "$newbody" >/dev/null || die "could not tick the criteria on #$t"
    fi
  fi
  gh issue close "$t" -R "$repo" >/dev/null || die "could not close #$t"
  "$SCRIPT_DIR/state.sh" closed "$RUN_DIR" "$t"
}

# ------------------------------------------------------------------ report

cmd_report() {
  open_run "${1:-}"
  jq '{
    run_id, wave: ((.orchestrators // []) | last | .wave // null),
    integration: .integration,
    tickets: [.plan.scope[] as $t | .tickets[$t] as $k | {
      ticket: $t, title: (.plan.tickets[$t].title // null), status: $k.status,
      attempts: $k.attempts, merge_commit: $k.merge_commit,
      tracker_closed: ($k.tracker_closed // false), cost_usd: $k.cost_usd,
      blocked_reason: ($k.blocked_reason // null)}],
    decisions_waiting: [.decisions[] | select(.status == "waiting")],
    findings: (.findings | length),
    costs: .costs,
    events: (.events // [] | length)
  }' "$FILE"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  start) cmd_start "$@" ;;
  launch) cmd_launch "$@" ;;
  status) cmd_status "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  merge) cmd_merge "$@" ;;
  close) cmd_close "$@" ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
