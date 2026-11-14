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
#   wave.sh launch <run-dir> [--resume] [--handoff] [--model M] [--estimate-usd N] [-- claude args...]
#       launch the next wave's orchestrator: a detached headless claude -p
#       under run-ticket.sh --role orchestrator, in the integration worktree.
#       The state lock passes to the orchestrator's runner for the wave.
#       Prints "orchestrator-w<wave> <attempt> <runner-pid>". 12: the run
#       halted (a whole wave failed); --resume is the Artisan's decision to
#       carry on, and clears the halt. --handoff is for drain.sh handoff
#       only: the running orchestrator, having recorded its hand-off, launches
#       the next attempt of the same wave and hands it the lock (6 from anyone
#       else); the wave's guardrails are not read again. Launch runs the usage
#       guard first (budget.sh guard), the guard's step between waves, when no
#       orchestrator's sweep is running: 18 parked on plan usage, 17 the
#       overrun gate; nothing launches. Not on --handoff (the sweep covers it).
#       First it judges the last orchestrator's exit, as status does, and
#       carries out the Artisan's answer to an orchestrator-exit decision
#       (resume, retry, halt); 23 while one waits (--resume answers it
#       "resume").
#   wave.sh wait <run-dir> [--timeout SECONDS]
#       block until the last orchestrator has ended (default at most 6600
#       seconds, then 3: wait again), then print "orchestrator: <state>". The
#       chat runs it as a background task so the orchestrator's exit wakes it.
#   wave.sh status <run-dir>
#       how the run stands, from files only: the orchestrator's exit record
#       and classification, then (once it has ended) the reconciler (git, the
#       sweep, the tracker). First line "orchestrator: <state>", second
#       "next: <launch|wait|halted|decide|parked|stranded|blocked|done>", then a
#       ticket table, after a "Human checks: N open (next slice gate, end
#       gate, or how many at each)" line when any is open (references/human-checks.md: a Human
#       check is never waited on, so the run can be done with it open).
#       "parked" (with a line naming it) means the merge gate
#       on CI got no verdict ("parked ci: ...", cleared with unpark-ci), or only a hands-on
#       ticket the Artisan is building, and work behind it, is left
#       (human.sh parked), or everything left waits behind open reviews
#       ("waiting on N reviews", gate-action.sh parked), or dispatch is
#       parked on plan usage (budget.sh parked, the guard's last word: a "parked <window>" line,
#       printed with the reviews line when both hold; each logs one "parked"
#       event whose reason says which). "stranded" means only tickets that
#       wait for good behind a dropped or resliced one are left: one line per
#       blocker ("#12 dropped: #14, #15 can't start") and the command that
#       sends them back to triage (gate-action.sh send-back); "blocked" is
#       any other cause. A waiting risk gate (drain.sh gate) holds only its
#       ticket's dependents: next is still launch while the frontier has work.
#       Status never writes the usage guard's state and never touches the
#       tracker for it: the guard runs in the orchestrator's sweep and in
#       launch, and a "usage guard: <verdict>, since <time>" line says
#       what it last found.
#       The orchestrator never fails silently (#171): once it has ended, its
#       exit is judged once. A clean end leaves every ticket its wave
#       dispatched with a final status; anything else (a nonzero exit,
#       error_max_turns, a budget or deadline limit, no completion line, a
#       ticket with no verdict, or verified but not merged) queues an
#       orchestrator-exit decision and event, and next is "decide" (after
#       "halted" only), with an "orchestrator-exit: <cause> in wave <n>
#       (<tickets>): <detail>" line.
#
# Usage, from the orchestrator:
#   wave.sh dispatch <run-dir> <ticket> [--brief TEXT]
#       refuse a Human check (1: it is answered at a gate, never built), and
#       ignore one as a blocker; refuse unless the ticket is in scope (4), queued, every blocker is
#       merged into the integration branch or closed (5), a slot is free
#       under Max Agents (9) and its expected files overlap no ticket in
#       flight or in this wave (10, wave-width.sh check), and budget.sh
#       guard passes (12 halted, 17 the overrun gate, 18 parked on plan
#       usage); then branch a
#       worktree from the integration tip and launch the worker with
#       /artisan-agent:implement. A retry is a fresh worker on the same
#       branch, given the failed attempt's evidence, and only once the
#       failed attempt's session has ended (8 until then). Prints its pid.
#       An urgent ticket (lever.sh urgent) takes the one extra slot above Max
#       Agents (9 while another urgent ticket holds it), skips the blocker and
#       overlap checks and branches from main; keeps the guard and its cost cap.
#       A ticket the Artisan stopped and steered (lever.sh steer) is dispatched
#       again like a retry, with their notes in its prompt.
#   wave.sh merge <run-dir> <ticket>... [--wait SECONDS]
#       several tickets, ready together, are a merge batch (#167; merge_batch
#       in host.json, merge-gate.sh batch, default on): each is checked as
#       below, they are merged --no-ff in order and the tip is gated once.
#       Green merges them all; red is split (the first half's tip is gated,
#       a green half merges, a red one is halved again) until the ticket
#       whose merge turns a green tip red is found: it alone is undone and
#       blocked, and the tickets after it are merged afresh without it and
#       gated again. A ticket that conflicts while building is left out, to
#       be merged alone (the conflict path below). Prints one line per
#       ticket: "#<t> merged <commit>", "#<t> red" or "#<t> left out:
#       conflict in <paths>; merge it alone (...)". 0 none red, 7 one red,
#       19 parked on CI (the tickets not merged stay returned; merge them
#       again after unpark-ci), 20 a gate still running: merge again naming
#       any of the merge batch's tickets. With merge_batch off, only the first
#       ticket merges, alone. One ticket is a merge batch of one:
#       merge a completed worker's branch --no-ff into the integration
#       branch in the integration worktree, run the merge gate (the plan's
#       suite command there, or on a machine whose merge gate runs on CI,
#       merge-gate.sh, the project's gate workflow on the merge commit; never
#       the suite here), record the merge with the gate's record and remove
#       the worker's worktree. Prints the merge commit. The gate runs
#       detached (merge-gate.sh start) and writes its outcome under results/;
#       this call waits for it at most SECONDS (default 60), so no call nears
#       a 2-minute Bash timeout. 20: the gate is still running (or another
#       ticket's gate is in progress, named): wait-any.sh, then merge again,
#       which finishes that same gate, waits on it again, resumes a CI gate
#       whose runner died on its same run and branch, or (a gate that died
#       with nothing to wait on) undoes it and gates the merge commit again. 8: the worker is still running. 13: not verified (no
#       passing verdict from verify.sh for this attempt and commit; nothing
#       changes). 11: a conflict, left in
#       progress for its one /artisan-agent:resolve-conflicts try (then
#       wave.sh resolved; the conflicted paths are a JSON array in the state
#       file's conflict event, exactly as git reports them). 6: refused, or a conflict after that try was used,
#       7: suite red, or CI red: failure or timed_out (both mark the ticket
#       blocked and queue a decision). 19: parked on CI: CI gave no verdict
#       (none in time, unreachable, or a run cancelled or the like), so the
#       merge is undone, the ticket stays returned and nothing merges or
#       dispatches until unpark-ci; a gate a crash cut short is undone here
#       and gated again.
#       While a gate runs, new work branches from the commit before its merge.
#       An attempt that did not complete is a failed attempt: queued for a
#       fresh worker, or blocked once it has used its attempts (6).
#   wave.sh resolved <run-dir> <ticket> [--gave-up REASON] [--wait SECONDS]
#       after /artisan-agent:resolve-conflicts: commit the resolved merge and
#       run the gate as merge does (20: still running; merge finishes it). 6: still conflicted, markers, unstaged
#       changes or untracked files left, or gave up (the merge is aborted
#       and the untracked files removed); 7: suite red, or CI red. Either way
#       the ticket is blocked with its branch and worktree kept. 19: parked on
#       CI, as merge (the resolved merge commit is the one retried).
#   wave.sh unpark-ci <run-dir> [--by NAME]
#       the Artisan clears a park on CI: the parked ticket's next merge
#       retries the gate on the same merge commit. 6: not parked on CI.
#   wave.sh block <run-dir> <ticket> <reason>
#       block a returned ticket the orchestrator won't merge (its diff misses
#       the expected output): queues an exception decision, logs the event.
#   wave.sh close <run-dir> <ticket>
#       post the evidence contract on the ticket (evidence.sh comment), tick
#       its met criteria, close it.
#   wave.sh report <run-dir>
#       the wave report (JSON) the orchestrator writes as its result file.
#       Halts the run first if every ticket dispatched in this wave failed.
#
# Environment:
#   ARTISAN_WRITER_PID      the long-lived pid writing state (the chat's
#                           session between waves; set for the orchestrator)
#   ARTISAN_CLAUDE_ARGS     extra arguments, split on whitespace, added to
#                           every orchestrator and worker session
#   ARTISAN_MAX_BUDGET_USD  ceiling on any one session's --max-budget-usd
#                           (for trials; caps are otherwise twice the estimate)
#   ARTISAN_WAIT_INTERVAL   seconds between wave.sh wait's looks (default 5)
#
# Exit status: 0 ok, 1 error, 2 usage, 3 lock held or an orchestrator still
# running, 4 outside the scope, 5 a blocker not merged, 6 merge refused or
# conflicted, 7 suite red, 8 worker still running, 9 no free slot, 10
# expected files overlap, 11 conflict awaiting its one resolution try,
# 12 the run is halted, 13 not verified, 15 the login would expire mid-run,
# 17 the overrun gate holds dispatch, 18 parked on plan usage, 19 parked on
# CI, 20 the merge gate is still running, 21 launch: main changed a product
# guardrail but the run's base is not in it, a decision is waiting, 23 launch:
# an orchestrator-exit decision is waiting. One table of every code, with
# verify.sh's: scripts/README.md, "Exit status".
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
# shellcheck source=lib/config-lib.sh
. "$SCRIPT_DIR/lib/config-lib.sh"   # the template's defaults (orchestrator_turns)
state_require_jq

DEFAULT_ORCHESTRATOR_MODEL=claude-sonnet-5-5
DEFAULT_ORCHESTRATOR_ESTIMATE_USD=1
SESSION_TOOLS="Bash,Read,Write,Edit,Glob,Grep,Skill,Agent"

usage() { state_usage "$0"; }
die() { state_die 1 "wave.sh: $*"; }

# ----------------------------------------------------------------- helpers

# orchestrator_max_turns: the --max-turns launch gives a wave's orchestrator
# (#175): base + per_ticket x T + per_ci_gate x G. T is the tickets the wave
# can take: the scope's tickets not merged or blocked, at most Max Agents, at
# least 1. G is T when this machine's merge gate runs on CI, else 0. The three
# numbers are the plan's config orchestrator_turns, else templates/config.yml's.
orchestrator_max_turns() {
  local defaults="" mode="" ci=0
  defaults=$(config_yaml_json "$CONFIG_TEMPLATE" | jq -c '.orchestrator_turns') \
    || die "unreadable defaults: $CONFIG_TEMPLATE"
  mode=$("$SCRIPT_DIR/merge-gate.sh" mode 2>/dev/null) || mode=local
  [ "$mode" != ci ] || ci=1
  get --argjson d "$defaults" --argjson ci "$ci" '
    ($d + (.plan.config.orchestrator_turns // {})) as $k
    | ([.plan.scope[] as $t | .tickets[$t].status // "queued"
        | select(. != "merged" and . != "blocked")] | length) as $open
    | ([[$open, (.plan.max_agents // 5)] | min, 1] | max) as $t
    | $k.base + $k.per_ticket * $t + $k.per_ci_gate * $t * $ci | ceil'
}

# halt_if_wave_failed: once nothing in the current wave is still in flight,
# returned or waiting to retry, and every ticket dispatched in it (two or
# more) failed, the run halts: a decision for the Artisan, and no wave
# launches until they resume it. A ticket failed when it is blocked for any
# reason but its worker's own design question (result status "blocked"); a
# one-ticket wave failing is that ticket's own exception decision. Idempotent.
halt_if_wave_failed() {
  apply '
    current_wave as $w
    | [.tickets | to_entries[] | select(.value.wave != null and .value.wave == $w)] as $d
    | if $w == 0 or .halted != null or ($d | length) < 2
         or ([$d[] | select(.value.status != "blocked" or .value.result.status? == "blocked")] | length) > 0 then .
      else ([$d[].key]) as $ts
        | .halted = {wave: $w, tickets: $ts, at: $now,
                     reason: "every ticket dispatched in wave \($w) failed"}
        | .decisions += [{id: ((.decisions | length) + 1), kind: "halt",
            question: "Wave \($w) failed whole (\($ts | map("#" + .) | join(", "))): something upstream is likely wrong. Recommended: look at the blocked tickets for a shared cause (a broken base, a missing setup step, a bad spec) and fix it before resuming; resume as is, reslice or end the run?",
            status: "waiting", at: $now}]
        | event({event: "halted", wave: $w, tickets: $ts}; $now)
      end'
}

# ------------------------------------------------- the orchestrator's exit

# The orchestrator never fails silently (#171). Once it has ended, its exit is
# judged once: a clean end to its wave leaves every ticket the wave dispatched
# with a final status (merged, blocked with a decision, parked, or requeued
# with a reason); anything else queues an `orchestrator-exit` decision for the
# Artisan (resume, retry the tickets, or halt) and logs the event.

# exit_cause: classify-worker.sh's line for an ended orchestrator -> the cause
# of an unclean exit, or nothing when the session itself ended cleanly.
exit_cause() { # classification
  case "$1" in
    completed*) ;;
    "failed turns") echo error_max_turns ;;
    "failed budget") echo budget ;;
    "failed deadline") echo deadline ;;
    not-completed*) echo not-completed ;;
    *) echo nonzero-exit ;;   # error, crashed, vanished, stopped
  esac
}

# check_orchestrator_exit: judge the ended orchestrator's exit, once (it marks
# the orchestrator's `exit`). A handed-off one is not judged: its wave carries
# on in the next attempt. Unfinished: a ticket dispatched in its wave, or in
# an earlier one and left over, still in flight,
# returned with no passing verdict ("no-verdict"), or verified but not merged
# ("unmerged"; not while the run is parked on CI, whose own decision holds it).
check_orchestrator_exit() { # id attempt wave classification
  local code="" cause=""
  [ "$(get --arg id "$1" --argjson a "$2" '[(.orchestrators // [])[] | select(.id == $id and .attempt == $a)]
        | last | . != null and .exit == null and .handoff == null')" = true ] || return 0
  code=$(jq -r '.exit_code // "none"' "$RUN_DIR/results/$1.$2.exit.json" 2>/dev/null || echo none)
  cause=$(exit_cause "$4")
  apply '
    [.tickets | to_entries[] | select((.value.wave // 0) > 0 and .value.wave <= $w) | .key as $t | .value as $k
     | ($k.evidence != null and $k.evidence.verdict == "pass" and $k.evidence.attempt == $k.attempts) as $passed
     | if $k.status == "in_flight" then {ticket: $t, why: "in flight, no verdict", cause: "no-verdict"}
       elif $k.status != "returned" then empty
       elif ($passed | not) then {ticket: $t, why: "returned, no verdict", cause: "no-verdict"}
       elif .ci_park == null then {ticket: $t, why: "verified, not merged", cause: "unmerged"}
       else empty end] as $u
    | (if $cause != "" then $cause
       elif any($u[]; .cause == "no-verdict") then "no-verdict"
       elif ($u | length) > 0 then "unmerged"
       else "" end) as $c
    | (.orchestrators | map(.id == $id and .attempt == $a) | index(true)) as $i
    | if $c == "" then .orchestrators[$i].exit = {clean: true, at: $now}
      else
        ((.decisions | length) + 1) as $d
        | ($u | map(.ticket)) as $ts
        | ("\($id) attempt \($a) ended \($cls) (exit code \($code))"
           + (if ($u | length) > 0 then "; " + ($u | map("#\(.ticket) \(.why)") | join(", ")) else "" end)) as $detail
        | .orchestrators[$i].exit = {clean: false, cause: $c, decision: $d, at: $now}
        | .decisions += [{id: $d, kind: "orchestrator-exit", cause: $c, wave: $w, tickets: $ts,
            detail: $detail, orchestrator: $id, attempt: $a, options: ["resume", "retry", "halt"],
            question: "The orchestrator for wave \($w) exited without finishing its wave (\($c)): \($detail). Recommended: resume (the next orchestrator reconciles and carries the wave on, keeping the work already done); retry \(if ($ts | length) > 0 then ($ts | map("#" + .) | join(", ")) else "its tickets" end) with fresh workers only if that work looks wrong, as it throws it away; halt only if the cause looks shared and would fail the next orchestrator too. Resume, retry or halt?",
            status: "waiting", at: $now}]
        | event({event: "orchestrator-exit", id: $id, attempt: $a, wave: $w, cause: $c, tickets: $ts, detail: $detail}; $now)
      end' --arg id "$1" --argjson a "$2" --argjson w "$3" --arg cls "$4" --arg code "$code" --arg cause "$cause"
}

# The waiting orchestrator-exit decision's id, or nothing.
exit_decision_waiting() {
  get '[.decisions[] | select(.kind == "orchestrator-exit" and .status == "waiting")] | last | .id // empty'
}

# "orchestrator-exit: <cause> in wave <w> (<tickets>): <detail>; decision <id>",
# one line per waiting decision, for status.
exit_decision_lines() {
  get '.decisions[] | select(.kind == "orchestrator-exit" and .status == "waiting")
       | "orchestrator-exit: \(.cause) in wave \(.wave)\(if (.tickets | length) > 0 then " (" + (.tickets | map("#" + .) | join(", ")) + ")" else "" end): \(.detail); decision \(.id) waits (resume, retry or halt)"'
}

# apply_exit_answers: carry out the Artisan's answers to orchestrator-exit
# decisions (state.sh decide <run-dir> <id> resume|retry|halt), once each:
# resume carries the wave on; retry sends the decision's tickets still
# returned back to queued for fresh workers, like steering (no attempt used);
# halt halts the run, so launch refuses (12) until --resume.
apply_exit_answers() {
  apply '
    . as $s0
    | reduce (.decisions[] | select(.kind == "orchestrator-exit" and .status == "decided" and .applied != true)) as $d (.;
      (if $d.choice == "retry" then
         reduce ($d.tickets[] | select(. as $t | $s0.tickets[$t].status == "returned")) as $t (.;
           steered($t; "retry after the orchestrator for wave \($d.wave) exited (\($d.cause))"; $now))
       elif $d.choice == "halt" and .halted == null then
         .halted = {wave: $d.wave, tickets: $d.tickets, at: $now,
                    reason: "the Artisan halted the run after the orchestrator for wave \($d.wave) exited (\($d.cause))"}
         | event({event: "halted", wave: $d.wave, tickets: $d.tickets, reason: "orchestrator-exit"}; $now)
       else . end)
      | .decisions |= map(if .id == $d.id then .applied = true else . end))'
}

# settle_orchestrator_exit: launch's step. Judge the last orchestrator's exit;
# a waiting decision refuses the launch (23) unless --resume answers it
# "resume"; then carry out any answers.
settle_orchestrator_exit() { # id attempt wave classification resume
  local d=""
  [ -z "$1" ] || check_orchestrator_exit "$1" "$2" "$3" "$4"
  d=$(exit_decision_waiting)
  if [ -n "$d" ]; then
    [ "$5" -eq 1 ] || state_die 23 "wave.sh: $(exit_decision_lines | tail -1); nothing launches until the Artisan answers: state.sh decide $RUN_DIR $d resume|retry|halt (or wave.sh launch --resume)"
    apply 'decide($d; {choice: "resume", by: "Artisan"}; $now)
      | event({event: "decided", decision: $d, kind: "orchestrator-exit", choice: "resume", by: "Artisan"}; $now)' \
      --argjson d "$d"
  fi
  apply_exit_answers
}

# wave.sh wait: block until the last orchestrator has ended, for the chat to
# run as a background task so the exit wakes it.
cmd_wait() {
  open_run "${1:-}"
  shift
  local timeout=6600 last="" cls="" waited=0 interval="${ARTISAN_WAIT_INTERVAL:-5}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] && state_is_uint "$2" || usage; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  last=$(last_orchestrator)
  [ -n "$last" ] || { echo "orchestrator: none"; return 0; }
  set -- $last
  while :; do
    cls=$(orchestrator_state "$1" "$2")
    case "$cls" in
      running*) ;;
      *) echo "orchestrator: $cls (wave $3, attempt $2); run wave.sh status"; return 0 ;;
    esac
    [ "$waited" -lt "$timeout" ] \
      || state_die 3 "wave.sh: the orchestrator for wave $3 is still running after ${waited}s; wait again"
    sleep "$interval"
    waited=$((waited + interval))
  done
}

# ------------------------------------------------------------------- start

cmd_start() {
  open_run "${1:-}"
  shift
  local base= ib= wt= sha=
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || usage; base=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  ib=$(integration_branch)
  get '.repo' | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    || die "the plan's repo must be owner/name on the tracker (as docs/agents/issue-tracker.md names it), not $(get .repo)"
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
  local line= pid=
  line=$(get '(.orchestrators // []) | last // empty | "\(.id) \(.attempt) \(.wave)"')
  [ -n "$line" ] || return 0
  set -- $line
  pid=$(cat "$RUN_DIR/workers/$1.$2/runner.pid" 2>/dev/null || echo -)
  printf '%s %s\n' "$line" "$pid"
}

orchestrator_state() { # id attempt -> classify-worker.sh's line
  # An error is not a dead session: it stops the command, and the caller runs it again.
  "$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$1" "$2" || state_die 1 "wave.sh: could not classify $1 attempt $2; run it again"
}

cmd_launch() {
  open_run "${1:-}"
  shift
  local model= estimate= args=() resume=0 handoff=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) resume=1; shift ;;
      --handoff) handoff=1; shift ;;
      --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
      --estimate-usd) [ $# -ge 2 ] || usage; estimate=$2; shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) usage ;;
    esac
  done
  local wt= last= id= attempt= wave= pid= cls= me= deadline= minutes= prompt= runner= turns=
  local -a ended=("" "" "")
  wave=1 attempt=1
  last=$(last_orchestrator)
  if [ -n "$last" ]; then
    set -- $last
    id=$1 attempt=$2 wave=$3 pid=$4
    cls=$(orchestrator_state "$id" "$attempt")
    ended=("$id" "$attempt" "$wave")
    # A hand-off (drain.sh handoff): the running orchestrator, which recorded
    # why, launches the next one for the same wave before it exits.
    if [ "$handoff" -eq 1 ]; then
      [ "$(writer)" = "$pid" ] && [ "$(get '(.orchestrators | last | .handoff) != null')" = true ] \
        || state_die 6 "wave.sh: --handoff is for the running orchestrator that recorded its hand-off (drain.sh handoff)"
      cls=handoff
    fi
    case "$cls" in
      handoff) attempt=$((attempt + 1)) ;;
      running*) state_die 3 "wave.sh: the orchestrator for wave $wave is still running (pid $pid)" ;;
      completed*) wave=$((wave + 1)) attempt=1 ;;
      *) attempt=$((attempt + 1)) ;;   # it ended without finishing: carry the same wave on
    esac
  fi
  id="orchestrator-w$wave"
  wt=$(integration_worktree)

  # A run on the always-on host must not outlive the claude.ai login (#69):
  # checked before every orchestrator launch but a hand-off (exit 15, nothing
  # launched), so a run moved onto the host is checked there too, against the
  # tickets it has left. A machine with no host record is not checked.
  if [ "$handoff" -eq 0 ]; then
    "$SCRIPT_DIR/login-check.sh" check --run-dir "$RUN_DIR" >&2 || exit $?
  fi

  # The chat's writer pid holds the lock (or takes it now) until it hands it on.
  me=$(writer)
  state_lock "$RUN_DIR" "$me" || exit 3
  export ARTISAN_WRITER_PID=$me

  # The last orchestrator's exit is judged, and the Artisan's answer carried
  # out, before anything launches: an unclean exit never passes silently (#171).
  if [ "$handoff" -eq 0 ]; then
    settle_orchestrator_exit "${ended[0]}" "${ended[1]}" "${ended[2]}" "${cls:-}" "$resume"
    # An orchestrator that exited 0 without finishing its wave: the next one
    # carries that same wave on, as after any other unclean exit.
    if [ -n "${ended[0]}" ] && [ "$(get --arg id "${ended[0]}" --argjson a "${ended[1]}" \
         '[.orchestrators[] | select(.id == $id and .attempt == $a)] | last | .exit.clean == false')" = true ]; then
      wave=${ended[2]} attempt=$((ended[1] + 1)) id="orchestrator-w${ended[2]}"
    fi
  fi

  local was_halted=0
  [ "$(get '.halted != null')" = false ] || was_halted=1
  if [ "$(get '.halted != null')" = true ]; then
    [ "$resume" -eq 1 ] || state_die 12 "wave.sh: the run is halted: $(get '.halted.reason'); nothing launches until the Artisan decides (wave.sh launch --resume carries on)"
    apply '
      .decisions |= map(if .kind == "halt" and .status == "waiting"
                        then .status = "decided" | .choice = "resume" | .by = "Artisan" | .decided_at = $now
                        else . end)
      | event({event: "resumed", wave: .halted.wave}; $now)
      | .halted = null'
  fi

  # The usage guard between waves (#120): no sweep runs now, and launch is the
  # chat's step that already writes state. A park or the overrun gate refuses.
  # A launch that clears a halt (--resume) is the Artisan's own decision; the
  # halt is already gone by here, and the sweep and dispatch guard the wave.
  if [ "$handoff" -eq 0 ] && [ "$was_halted" -eq 0 ]; then
    "$SCRIPT_DIR/budget.sh" guard "$RUN_DIR" >&2 || exit $?
  fi

  [ -n "$model" ] || model=$(get --arg d "$DEFAULT_ORCHESTRATOR_MODEL" '.plan.orchestrator.model // $d')
  [ -n "$estimate" ] || estimate=$(get --arg d "$DEFAULT_ORCHESTRATOR_ESTIMATE_USD" '.plan.orchestrator.estimate_usd // $d')
  estimate=$(clamp_estimate "$estimate")
  # The orchestrator outlives every worker it waits on: its deadline is the
  # longest worker deadline plus half an hour.
  deadline=$(get '.plan.orchestrator.deadline_seconds // (([.plan.tickets[]?.caps.deadline_seconds // 0] | max // 0) + 1800)')
  minutes=$(awk -v s="$deadline" 'BEGIN { printf "%d", (s / 120 < 1 ? 1 : s / 120) }')
  turns=$(orchestrator_max_turns)

  mkdir -p "$RUN_DIR/prompts"
  prompt="$RUN_DIR/prompts/$id.$attempt.md"
  cat >"$prompt" <<EOF
You are the orchestrator for wave $wave of run $RUN_ID. Follow $PLUGIN_DIR/skills/implement-plan/references/orchestrator.md exactly; it is your whole brief.

- Run folder: $RUN_DIR
- Integration worktree: $wt (branch $(integration_branch)); you are in it.
- Scripts: $PLUGIN_DIR/scripts
- Your state-writer pid is already exported as ARTISAN_WRITER_PID, and you hold the state lock.
EOF
  if [ "$attempt" -gt 1 ]; then
    printf -- '- An earlier orchestrator for this wave %s. Carry the same wave on from the state file: reconcile first.\n' \
      "$(get '(.orchestrators | last | .handoff) as $h | if $h then "handed off to you (\($h.reason))" else "ended without finishing" end')" >>"$prompt"
  fi

  # Guardrails are read at the point of use: fetch the team, product and
  # individual sources, bring main in if a product guardrail changed, record
  # each commit and the plugin version for this wave (references/guardrails.md).
  # A hand-off carries the wave on with the guardrails its workers were given.
  if [ "$handoff" -eq 0 ]; then
    local gs=0
    "$SCRIPT_DIR/guardrails.sh" wave-start "$RUN_DIR" "$wave" >/dev/null || gs=$?
    case "$gs" in
      0) ;;
      9) exit 21 ;;   # the run's base is not in main: a decision is waiting (guardrails.sh said so)
      10) exit 12 ;;  # the Artisan answered halt: the run is halted
      *) die "could not read the guardrails for wave $wave (guardrails.sh wave-start failed)" ;;
    esac
  fi

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
    --max-turns "$turns" \
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
             elif $k.status == "queued" and ($k.gate_waits // []) != [] then
               ": waiting on " + ($k.gate_waits | map("\(.kind) gate \(.slice)") | join(", "))
             else "" end) + " |" )' "$FILE"
}

# An ended orchestrator's spend, from its session's output, counted once.
record_orchestrator_cost() { # id attempt
  local usd=
  usd=$(jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$1.$2/output.json" 2>/dev/null || true)
  [ -n "$usd" ] || return 0
  apply '(.orchestrators | map(.id == $id and .attempt == $a) | index(true)) as $i
    | if $i == null or .orchestrators[$i].cost_usd != null then .
      else .orchestrators[$i].cost_usd = $usd
        | .costs.orchestrator_usd += $usd
        | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd) end' \
    --arg id "$1" --argjson a "$2" --argjson usd "$usd"
}

# "Human checks: N open (<where they are answered>)", when any is open
# (references/human-checks.md): at a slice gate when one lists it now, or one
# still to open will (its agent ticket is in that slice, or it is carried from
# a gate that has closed); else at the end gate.
human_checks_line() {
  local n="" at_slice=""
  n=$(get "$STATE_JQ_DEFS"' open_human_checks | length')
  [ "$n" -gt 0 ] || return 0
  at_slice=$(get "$STATE_JQ_DEFS"' . as $s | ($s.review_gates // []) as $rg
    | [slice_gates[] | select(.kind == "slice") | select(.id as $id | $rg | all(.id != $id))] as $unopened
    | [open_human_checks[] as $c | ($s | human_check_for($c)) as $a
       | ($s.tickets[$c].human_check.gate // null) as $hg
       | select(any($rg[]; .id == $hg and (.status == "open" or .status == "deferred"))
                or any($unopened[]; .tickets | index($a))
                or ($hg != null and ($unopened | length) > 0))] | length')
  if [ "$at_slice" -eq 0 ]; then
    echo "Human checks: $n open (end gate)"
  elif [ "$at_slice" -eq "$n" ]; then
    echo "Human checks: $n open (next slice gate)"
  else
    echo "Human checks: $n open ($at_slice at the next slice gate, $((n - at_slice)) at the end gate)"
  fi
}

cmd_status() {
  open_run "${1:-}"
  local last= id= attempt= wave= pid= cls= next= reconciled=1 waiting= o= parked= usage_park= reviews= stranded=
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
      # Every ended orchestrator's spend, a handed-off one's included.
      for o in $(get '(.orchestrators // [])[] | select(.cost_usd == null) | "\(.id).\(.attempt)"'); do
        record_orchestrator_cost "${o%.*}" "${o##*.}"
      done
      # The Artisan's answers to an orchestrator's unclean exit (#171), before
      # the reconciler, so a retried ticket is back on the frontier.
      apply_exit_answers
      # A hands-on ticket the Artisan finished, and any that can now start (human.sh).
      "$SCRIPT_DIR/human.sh" sync "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.human.err" \
        || echo "human.sh sync failed: $(tr '\n' ' ' <"$RUN_DIR/.human.err")" >&2
      # Exception gates for tickets the run gave up on (gate-action.sh, #70).
      "$SCRIPT_DIR/gate-action.sh" sync "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.gate-action.err" \
        || echo "gate-action.sh sync failed: $(tr '\n' ' ' <"$RUN_DIR/.gate-action.err")" >&2
      # The Artisan's gate actions taken while the lock was held, a gate
      # closed on the tracker, and any slice gate due (gate.sh, #65).
      "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.gate.err" \
        || echo "gate.sh sync failed: $(tr '\n' ' ' <"$RUN_DIR/.gate.err")" >&2
      "$SCRIPT_DIR/reconcile.sh" "$RUN_DIR" >/dev/null 2>"$RUN_DIR/.status.err" || {
        reconciled=0
        "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" --no-guard >/dev/null
      }
      [ -z "${id:-}" ] || halt_if_wave_failed
      # The ended orchestrator's exit, judged once (#171).
      [ -z "${id:-}" ] || check_orchestrator_exit "$id" "$attempt" "$wave" "$cls"
      # A usage park, as the guard last left it (budget.sh parked reads only).
      # The guard itself runs from the orchestrator's sweep and from launch,
      # never from here: status writes no guard state and opens no gate (#120).
      usage_park=
      [ "$(get '.halted != null')" = true ] \
        || usage_park=$("$SCRIPT_DIR/budget.sh" parked "$RUN_DIR" 2>/dev/null || true)
      # A risk gate or a review gate holds only its tickets' dependents
      # (drain.sh gate, gate.sh): the run carries on while the frontier has work.
      # An exception gate (an exception decision with its issue) holds only
      # its ticket's dependents too.
      waiting=$(get "$STATE_JQ_DEFS"'waiting_non_gate_decisions | length')
      [ "$(get '.frontier | length')" -gt 0 ] \
        || waiting=$(get '[.decisions[] | select(.status == "waiting")] | length')
      if [ "$(get '.halted != null')" = true ]; then next=halted
      # An orchestrator that exited without finishing its wave: never launch.
      elif [ -n "$(exit_decision_waiting)" ]; then next=decide
      elif [ "$(get '.ci_park != null')" = true ]; then next=parked
        parked=$(get -r '.ci_park | "parked ci: \(if .tickets then "merge batch \(.batch) (\(.tickets | map("#" + .) | join(", ")))" else "#\(.ticket)" end)'"'"'s merge gate got no verdict from CI: \(.why)\(if .url then " (\(.url))" else "" end); clear it with wave.sh unpark-ci to retry the gate"')
      elif [ -n "$usage_park" ]; then next=parked parked=$usage_park
        # Parked on usage and behind open reviews too: both reasons show.
        if [ "$reconciled" -eq 1 ] && reviews=$("$SCRIPT_DIR/gate-action.sh" parked "$RUN_DIR" --record 2>/dev/null); then
          parked="$parked
$reviews"
        fi
      elif [ "$reconciled" -eq 1 ] && parked=$("$SCRIPT_DIR/gate-action.sh" parked "$RUN_DIR" --record 2>/dev/null); then next=parked
      elif [ "$waiting" -gt 0 ]; then next=decide
      elif [ "$reconciled" -eq 0 ]; then next=blocked
      elif [ "$(get '.frontier | length')" -gt 0 ]; then next=launch
      # A hands-on ticket the Artisan finished waits for its verifier and merge.
      elif [ "$(get '[.tickets[] | select(.status == "returned")] | length')" -gt 0 ]; then next=launch
      # A ticket the Artisan took out of the run at a gate (dropped, resliced,
      # bypassed, deferred) is finished for this run.
      # A Human check is not work the run waits on: the gates settle it. One
      # whose ticket left the run without it is stranded (#161), not done.
      elif [ "$(get "$STATE_JQ_DEFS"' . as $s | out_of_run as $o | [.plan.scope[] as $t
               | select((($s | is_human_check($t)) and ($s.tickets[$t].status? != "queued"
                          or ((["dropped", "resliced", "sent_back"] | index($s.tickets[$s | human_check_for($t)].status? // "")) == null)))
                        or (.tickets[$t].status | . as $st
                        | $st == "merged" or $st == "closed" or ($o | index($st))))] | length')" \
             = "$(get '.plan.scope | length')" ]; then next=done
      elif parked=$("$SCRIPT_DIR/human.sh" parked "$RUN_DIR" --record 2>/dev/null); then next=parked
      # Tickets left waiting for good behind a dropped or resliced one (#116).
      elif stranded=$("$SCRIPT_DIR/gate-action.sh" stranded "$RUN_DIR" 2>/dev/null); then next=stranded
      else next=blocked
      fi
      ;;
  esac
  echo "next: $next"
  [ "$next" != decide ] || exit_decision_lines
  [ "$next" != parked ] || echo "$parked"
  [ "$next" != done ] || echo "run the end gate: end-gate.sh open $RUN_DIR"
  human_checks_line
  [ "$next" != stranded ] || echo "$stranded"
  [ "$reconciled" -eq 1 ] || echo "tracker: unreadable, frontier not recomputed ($(tr '\n' ' ' <"$RUN_DIR/.status.err"))"
  [ "$next" != halted ] || get '"halted: \(.halted.reason) (\(.halted.tickets | map("#" + .) | join(", "))); nothing more launches until the Artisan decides"'
  "$SCRIPT_DIR/budget.sh" last "$RUN_DIR" 2>/dev/null || true
  echo
  ticket_table
  if [ "${next}" = decide ] || [ "${next}" = halted ] || [ "${next}" = parked ] \
     || { [ "$next" = launch ] && [ "$(get '[.decisions[] | select(.status == "waiting")] | length')" -gt 0 ]; }; then
    echo
    echo "| Decision | Ticket | Question |"
    echo "|---|---|---|"
    get '.decisions[] | select(.status == "waiting") | "| \(.id) (\(.kind)) | \(if .ticket then "#" + .ticket else "-" end) | \(.question) |"'
  fi
}

# ---------------------------------------------------------------- dispatch

# Every blocker of the ticket must be merged into the integration branch (a
# blocker in the run) or closed (one outside it). The tracker says what blocks
# what; git says what is merged. Refuses with 5, or 1 if either can't be read.
check_blockers() { # ticket
  local t="$1" repo= ib= tip= blockers= b= state= status= sha=
  repo=$(get '.repo')
  ib=$(integration_branch)
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib") || die "no integration branch $ib"
  blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
    || die "could not read the blockers of #$t from the tracker; not dispatching blind"
  for b in $(printf '%s' "$blockers" | jq -r '.[] | "\(.number)=\(.state | ascii_downcase)"'); do
    state=${b#*=} b=${b%%=*}
    # A Human check in the run never holds anything up (references/human-checks.md).
    [ "$(get --arg b "$b" "$STATE_JQ_DEFS"' is_human_check($b)')" = false ] || continue
    status=$(get --arg b "$b" '.tickets[$b].status // ""')
    if [ -n "$status" ]; then
      sha=$(get --arg b "$b" '.tickets[$b].merge_commit // ""')
      if [ "$status" != merged ] || [ -z "$sha" ] || ! git -C "$MAIN" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        state_die 5 "wave.sh: refusing #$t: its blocker #$b is not merged into $ib (status $status); dispatch only on merged work"
      fi
      [ "$(get --arg b "$b" '.tickets[$b].risk_gate.status? // ""')" != waiting ] \
        || state_die 5 "wave.sh: refusing #$t: its blocker #$b merged under a risk gate the Artisan hasn't cleared (drain.sh gate)"
      [ "$("$SCRIPT_DIR/gate.sh" holds "$RUN_DIR" "$b" "$t" 2>/dev/null)" = free ] \
        || state_die 5 "wave.sh: refusing #$t: its blocker #$b is in a slice whose review gate the Artisan hasn't answered (gate.sh)"
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
  [ "$(get --arg t "$t" "$STATE_JQ_DEFS"' is_human_check($t)')" = false ] \
    || die "#$t is a Human check: the Artisan answers it at a gate (gate.sh check); it is never dispatched to a worker"
  local status= in_flight= max= urgent=
  status=$(get --arg t "$t" '.tickets[$t].status')
  [ "$status" = queued ] || die "#$t is $status, not queued"
  [ "$(get --arg t "$t" '.tickets[$t].human == null')" = true ] \
    || die "#$t is a hands-on ticket, held for the Artisan (human.sh); it is never dispatched to a worker"
  max=$(get '.plan.max_agents // 5')
  urgent=$(get --arg t "$t" '.tickets[$t].urgent // false')
  if [ "$urgent" = true ]; then
    # The one extra slot above Max Agents (lever.sh urgent): a second urgent
    # ticket waits until the first has left it.
    in_flight=$(get --arg t "$t" '[.tickets | to_entries[] | select(.key != $t and .value.status == "in_flight" and (.value.urgent // false))] | length')
    [ "$in_flight" -lt 1 ] || state_die 9 "wave.sh: the urgent slot is taken: another urgent ticket is in flight; #$t waits"
  else
    in_flight=$(get '[.tickets[] | select(.status == "in_flight" and ((.urgent // false) | not))] | length')
    [ "$in_flight" -lt "$max" ] || state_die 9 "wave.sh: no free slot: $in_flight of Max Agents $max in flight"
  fi
  # The plan-window guard and the budget (budget.sh, #72): 18 parked, 17 the
  # overrun gate, 12 halted. Work already in flight is never stopped.
  "$SCRIPT_DIR/budget.sh" guard "$RUN_DIR" >&2 || exit $?
  # Parked on CI (the merge gate got no conclusion): nothing new starts.
  [ "$(get '.ci_park != null')" = false ] \
    || state_die 19 "wave.sh: parked on CI: $(get -r '.ci_park.why'); nothing dispatches until the park is cleared (wave.sh unpark-ci)"
  # An urgent ticket was approved by being marked urgent: it dispatches at
  # once, whatever blocks it or runs beside it.
  if [ "$urgent" != true ]; then
    check_blockers "$t"
    "$SCRIPT_DIR/wave-width.sh" check "$RUN_DIR" "$t" || exit $?
  fi

  local ib= base= branch= n= wt= prev= repo= title= path= expected= estimate= minutes= model= turns= deadline= prompt= pid= ref=
  ib=$(integration_branch)
  base=$(integration_tip)
  # An urgent ticket branches from main, not from the integration branch.
  [ "$urgent" != true ] || base=$(git -C "$MAIN" rev-parse "refs/heads/$(main_branch)") || die "no main branch to branch #$t from"
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  n=$(( $(get --arg t "$t" '.tickets[$t].attempts') + 1 ))
  wt="$WT_ROOT/$RUN_ID-$t.$n"
  prev=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  # A fresh worker never starts while the last attempt's session is still
  # ending in its worktree (a worker can report failed before it exits).
  if [ "$n" -gt 1 ]; then
    # Exit 2 is "no such attempt" (a ticket held for a question never started
    # one): nothing is running. Any other error stops the dispatch.
    prev_rc=0
    prev_cls=$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$((n - 1))" 2>/dev/null) || prev_rc=$?
    case "$prev_rc" in 0 | 2) ;; *) state_die 1 "wave.sh: could not classify #$t attempt $((n - 1)); run it again" ;; esac
    case "$prev_cls" in
      running*) state_die 8 "wave.sh: #$t's attempt $((n - 1)) is still ending; dispatch the retry once it has" ;;
    esac
  fi
  if [ -n "$prev" ] && [ -d "$prev" ]; then
    # A retry continues the same branch in a fresh worktree; the old one must be clean.
    if ! git -C "$MAIN" worktree remove "$prev" 2>/dev/null; then
      block "$t" "attempt $((n - 1))'s worktree $prev has uncommitted work, so no fresh worker can take the branch"
      state_die 6 "wave.sh: #$t blocked: the previous attempt's worktree $prev has uncommitted work"
    fi
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
- Base: $base ($([ "$urgent" = true ] && echo "main, because this ticket is urgent and ships on its own PR to main" || echo "the integration branch $ib")). Your branch: $branch, already checked out here.
- Expected output: $expected
- Plugin version this wave: $(get '.waves | last | .plugin_version // "unknown"'). Guardrails in force for this wave, with their versions: run $SCRIPT_DIR/guardrails.sh resolve --run-dir $RUN_DIR --ticket $t (an area-scoped guardrail is listed only if this ticket touches its area; plugin version and source commits are in the state file's latest wave). Follow them; product beats team beats individual.
- Write the evidence record to the result file named below, as in $PLUGIN_DIR/references/evidence-record.md.
- Do not close the ticket, edit the tracker, merge or push. Do not use git stash; commit instead.
EOF
  [ -z "$brief" ] || printf -- '- Brief: %s\n' "$brief" >>"$prompt"
  # The Artisan's answers to the questions an earlier worker filed (questions.sh).
  if [ "$(get --arg t "$t" '(.tickets[$t].answers // []) | length')" -gt 0 ]; then
    printf -- '- The Artisan has answered what blocked an earlier attempt; treat each answer as decided, and continue from the branch:\n' >>"$prompt"
    get --arg t "$t" '.tickets[$t].answers[] | "  - #\(.question): \(.answer)"' >>"$prompt"
  fi
  # Notes the Artisan gave at an exception gate ("retry with notes", gate-action.sh).
  if [ "$(get --arg t "$t" '(.tickets[$t].notes // []) | length')" -gt 0 ]; then
    printf -- '- The Artisan sent this ticket back with notes at its exception gate; follow them:\n' >>"$prompt"
    get --arg t "$t" '.tickets[$t].notes[] | "  - \(.note) (exception gate #\(.issue))"' >>"$prompt"
  fi
  # Steering (lever.sh steer): the Artisan stopped the last attempt and gave notes.
  if [ "$(get --arg t "$t" '(.tickets[$t].steering // []) | length')" -gt 0 ]; then
    printf -- '- The Artisan stopped an earlier attempt to steer you. This is not a failed attempt: continue from the branch, and follow their notes:\n' >>"$prompt"
    get --arg t "$t" '.tickets[$t].steering[] | "  - \(.note) (attempt \(.attempt))"' >>"$prompt"
  fi
  if [ "$n" -gt 1 ] && [ "$(get --arg t "$t" '.tickets[$t].failures | length')" -gt 0 ]; then
    printf -- '- This is a retry, attempt %s of %s. The last attempt failed: %s\n' "$n" \
      "$(get --arg t "$t" '(.plan.attempts_per_ticket // 2) + (.tickets[$t].extra_attempts // 0)')" \
      "$(get --arg t "$t" '.tickets[$t].failures | last | "\(.reason)"')" >>"$prompt"
    failure_evidence "$t" "$((n - 1))" >"$RUN_DIR/prompts/$t.$n.failure.md"
    { echo; cat "$RUN_DIR/prompts/$t.$n.failure.md"; } >>"$prompt"
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
    "$SCRIPT_DIR/state.sh" dispatch "$RUN_DIR" "$t" "$pid" \
      "$(awk -v now="$(state_now)" -v m="$minutes" 'BEGIN { printf "%d", now + m * 120 }')"
  fi
  apply 'current_wave as $w | .tickets[$t] |= (.worktree = $wt | .base = $base | .wave = $w)' \
    --arg t "$t" --arg wt "$wt" --arg base "$base"
  printf '%s\n' "$pid"
}

# The branch the Artisan's PRs go to (and an urgent ticket branches from).
main_branch() {
  [ -z "${ARTISAN_MAIN_BRANCH:-}" ] || { printf '%s\n' "$ARTISAN_MAIN_BRANCH"; return; }
  git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo main
}

# failure_evidence ticket attempt: what a retry's fresh worker is told about
# the attempt that failed, from that attempt's files and its branch. Bounded:
# a few lines from each source, never a transcript.
failure_evidence() {
  local t="$1" p="$2" w="$RUN_DIR/workers/$1.$2" res="$RUN_DIR/results/$1.$2.result.json"
  local exitf="$RUN_DIR/results/$1.$2.exit.json" branch= base= log=
  echo "## Failure evidence from attempt $p"
  echo
  get --arg t "$t" --argjson p "$p" '.tickets[$t].failures[] | select(.attempt == $p) | "- Why it counted as failed: \(.reason)"'
  echo "- Judged from its files: $("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$t" "$p" 2>/dev/null || echo "unknown")"
  [ ! -f "$exitf" ] || jq -r '"- Exit record: \(.reason), exit code \(.exit_code)"' "$exitf" 2>/dev/null || true
  [ ! -f "$w/output.json" ] || jq -r '"- Session: \(.subtype // "-"), is_error \(.is_error | tostring), \(.num_turns // "-") turns"' "$w/output.json" 2>/dev/null || true
  if [ -f "$res" ]; then
    jq -r '
      "- Its evidence record said: status \(.status // "-")"
        + (if .tests then ", covering tests \((.tests.files // []) | join(" ")) \(if .tests.suite_passed == true then "passed" else "failed" end) (\(.tests.summary // "-"))" else "" end),
      ((.acceptance // [])[] | select(.met != true) | "- Not met: \(.criterion) (\(.evidence.why // "no reason given"))"),
      ((.unsure // [])[] | "- Unsure: \(.)"),
      (if .notes then "- Notes: \(.notes)" else empty end)' "$res" 2>/dev/null || true
  else
    echo "- It wrote no evidence record."
  fi
  # A verifier's fail: what it found unmet, from the contract it judged.
  if [ -f "$RUN_DIR/verify/$t.$p.evidence.json" ]; then
    jq -r '
      "- The verifier found \(.criteria_met) of \(.criteria_total) criteria met:",
      (.acceptance[] | select(.met != true and .human != true) | "- Unmet (verifier): \(.criterion) (\(.evidence.why // "no reason given"))"),
      (.acceptance[] | select(.human == true) | "- Needs a human check, not yours to meet (verifier): \(.criterion) (\(.evidence.why // "no reason given"))"),
      ((.verifier.unsure // [])[] | "- The verifier was unsure: \(.)")' "$RUN_DIR/verify/$t.$p.evidence.json" 2>/dev/null || true
  fi
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  base=$(get --arg t "$t" '.tickets[$t].base // ""')
  if [ -n "$base" ] && log=$(git -C "$MAIN" log --oneline -n 10 "$base..refs/heads/$branch" 2>/dev/null) && [ -n "$log" ]; then
    echo "- Its commits, already on $branch (build on them or replace them):"
    printf '%s\n' "$log" | sed 's/^/    /'
  else
    echo "- It left no commits on $branch."
  fi
  if [ -f "$w/output.json" ] && [ -n "$(jq -r '.result // empty' "$w/output.json" 2>/dev/null)" ]; then
    echo "- The end of its last reply:"
    jq -r '.result' "$w/output.json" | tail -n 8 | sed 's/^/    /'
  fi
  if [ -s "$w/stderr.log" ]; then
    echo "- The end of its stderr:"
    tail -n 8 "$w/stderr.log" | sed 's/^/    /'
  fi
}

# ------------------------------------------------------------------- merge

# The sweep can record a result before the session has written its JSON
# output; once the attempt has ended, take its cost from there.
record_session_cost() { # ticket attempt
  local usd=
  usd=$(jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$1.$2/output.json" 2>/dev/null || true)
  [ -n "$usd" ] || return 0
  apply 'attempt_cost($t; $n; $usd)
    | .costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
    | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)' --arg t "$1" --argjson n "$2" --argjson usd "$usd"
}

# Paths stay a list end to end: git's -z output (no quoting, no splitting on
# spaces) becomes a JSON array, and only messages join it for display.
unmerged_json() { # worktree
  git -C "$1" diff -z --name-only --diff-filter=U | jq -Rs 'split("\u0000")[:-1]'
}
join_paths() { # JSON array -> "a b c" for messages
  jq -r 'join(" ")' <<<"$1"
}

# An urgent ticket reaching a merge gate is main joining the integration
# branch after its PR merged (end-gate.sh urgent-finish), never the ticket's
# own branch (#143). Its failures queue a decision instead of blocking it.
is_urgent_sync() { [ "$(get --arg t "$1" '.tickets[$t].urgent // false')" = true ]; }

# gate_failed ticket reason: the merge was undone. A ticket is blocked; an
# urgent ticket's main sync queues a decision (its PR is merged already).
gate_failed() {
  if is_urgent_sync "$1"; then
    # Its resolve try is spent on a merge that was undone: the next urgent-finish starts afresh.
    apply '.tickets[$t].resolve = null' --arg t "$1"
    queue_sync_decision "$1" "$2"
  else
    block "$1" "$2"
  fi
}

# ship_urgent ticket sha: the full suite is green with main in the
# integration branch; record the urgent ticket shipped (as urgent-finish does).
ship_urgent() {
  local t="$1" sha="$2" url= oid= ib= repo=
  url=$(get -r --arg t "$t" '.urgent_gates[$t].pr.url // ""')
  oid=$(get -r --arg t "$t" '.tickets[$t].resolve.sync.oid // ""')
  ib=$(integration_branch)
  repo=$(get -r .repo)
  apply '
    .tickets[$t] |= (.status = "merged" | .pid = null | .merge_commit = (if $oid == "" then $sha else $oid end)
      | .suite = $r
      | .shipped = {pr: $url, main_merged_into: $ib, sync_commit: $sha, at: $now})
    | .urgent_gates[$t] += {status: "ended", ended_at: $now, sync_commit: $sha}
    | event({event: "urgent-shipped", ticket: $t, pr: $url, sync_commit: $sha}; $now)' \
    --arg t "$t" --arg oid "$oid" --arg sha "$sha" --arg url "$url" --arg ib "$ib" --argjson r "$3"
  gh issue edit "$t" -R "$repo" --remove-label in-run >/dev/null 2>&1 || echo "wave.sh: could not remove in-run from #$t" >&2
}

# Seconds wave.sh merge (and resolved) waits on a running merge gate before
# returning 20, so no call comes near the orchestrator's 2-minute Bash
# timeout (#142). --wait overrides it; 0 returns at once.
DEFAULT_GATE_WAIT_SECONDS=60

gate_wait_arg() { # value -> validated seconds
  printf '%s' "$1" | grep -Eq '^[0-9]+$' || usage
  printf '%s\n' "$1"
}

cmd_merge() {
  open_run "${1:-}"
  shift
  local wait=$DEFAULT_GATE_WAIT_SECONDS list='[]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) [ $# -ge 2 ] || usage; wait=$(gate_wait_arg "$2"); shift 2 ;;
      -*) usage ;;
      *) list=$(jq -c --arg t "$1" 'if index($t) then . else . + [$t] end' <<<"$list"); shift ;;
    esac
  done
  [ "$(jq length <<<"$list")" -ge 1 ] || usage
  # A merge batch in progress is finished first, whichever of its tickets is named.
  if [ "$(get '.merge_batch != null')" = true ]; then
    [ "$(get --argjson l "$list" '[.merge_batch.tickets[] | select(. as $t | $l | index($t))] | length > 0')" = true ] \
      || state_die 20 "wave.sh: not merged yet: merge batch $(get '.merge_batch.id') ($(get -r '.merge_batch.tickets | map("#" + .) | join(", ")')) is in progress; finish it first (wave.sh merge $RUN_DIR $(get -r '.merge_batch.tickets | join(" ")'))"
    # Tickets named beside it are not in it: its report names them, to merge next.
    BATCH_EXTRA=$(get -c --argjson l "$list" '[$l[] | select(. as $t | $b.tickets | index($t) | not)]' \
      --argjson b "$(get -c '.merge_batch')")
    batch_run "$wait"
    return 0
  fi
  if [ "$(jq length <<<"$list")" -gt 1 ]; then
    if [ "$("$SCRIPT_DIR/merge-gate.sh" batch)" = on ]; then
      batch_start "$wait" "$list"
      return 0
    fi
    echo "wave.sh: merge batching is off (merge-gate.sh show): #$(jq -r '.[0]' <<<"$list") merges alone; merge $(jq -r '.[1:] | map("#" + .) | join(", ")' <<<"$list") after it" >&2
  fi
  merge_one "$(jq -r '.[0]' <<<"$list")" "$wait"
}

# merge_one ticket wait: a merge batch of one, the merge as it always was.
merge_one() {
  local t="$1" wait="$2"
  local n= branch= wt= ib= suite= pre= title=
  wt=$(integration_worktree)
  # A gate already started: finish it, wait on it, resume it, or (dead, with
  # nothing to wait on) undo it for a retry below. First of all: a gate whose
  # merge was recorded just before a crash leaves its ticket merged, not
  # returned, and only finishing it clears the record.
  settle_gate "$t" "$wait" "$wt"
  # (An urgent ticket's own gate to retry, after its runner died or a CI park
  # cleared, is the one merge it may take: main joining the integration branch.)
  [ "$(get --arg t "$t" '.tickets[$t].urgent // false')" != true ] || [ "$(get --arg t "$t" '.tickets[$t].ci_retry != null')" = true ] \
    || state_die 6 "wave.sh: #$t is urgent: it ships through its own end gate and PR to main (end-gate.sh urgent-open), never into the integration branch"
  check_returned wave.sh "$t" "not merged"
  n=$ATTEMPT
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  # Only verified work merges: a fresh verifier's pass for this attempt at
  # this commit (verify.sh, references/evidence-contract.md).
  [ "$(get --arg t "$t" --argjson n "$n" --arg tip "$TIP" \
        '.tickets[$t].evidence | if . != null and .verdict == "pass" and .attempt == $n and .commit == $tip then "pass" else "" end')" = pass ] \
    || state_die 13 "wave.sh: #$t not merged: no passing verdict for attempt $n at $TIP; run verify.sh start, then verify.sh judge"
  suite=$(get '.plan.suite_command // ""')
  [ -n "$suite" ] || die "the plan has no suite_command; the full suite must run after every merge"
  ib=$(integration_branch)
  [ "$(get '.ci_park != null')" = false ] \
    || state_die 19 "wave.sh: #$t not merged: the run is parked on CI ($(get -r '.ci_park.why')); nothing merges until the park is cleared (wave.sh unpark-ci)"
  abandon_pending_resolution "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "the integration worktree $wt has uncommitted changes"
  pre=$(git -C "$wt" rev-parse HEAD)
  # A gate to retry (a cleared CI park, or a gate that died with no outcome):
  # the same merge commit, if nothing has merged since; otherwise merged afresh.
  if [ "$(get --arg t "$t" '.tickets[$t].ci_retry != null')" = true ]; then
    local rpre= rsha=
    rpre=$(get -r --arg t "$t" '.tickets[$t].ci_retry.pre') rsha=$(get -r --arg t "$t" '.tickets[$t].ci_retry.sha')
    apply '.tickets[$t].ci_retry = null' --arg t "$t"
    if [ "$rpre" = "$pre" ] && git -C "$wt" reset -q --hard "$rsha" 2>/dev/null; then
      finish_merge "$t" "$n" "$wt" "$pre" "$wait"
      return 0
    fi
  fi
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  if ! git -C "$wt" merge --no-ff --no-edit -m "Merge #$t ($title) into $ib" "$branch" >/dev/null 2>&1; then
    local paths= pjson=
    pjson=$(unmerged_json "$wt")
    paths=$(join_paths "$pjson")
    if [ "$(get --arg t "$t" '.tickets[$t].resolve != null')" = true ] || [ -z "$paths" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
      block "$t" "merge conflict in ${paths:-unknown paths}; its one /artisan-agent:resolve-conflicts try is used"
      state_die 6 "wave.sh: #$t not merged: conflict in ${paths:-unknown paths}"
    fi
    # Left in progress for the one try at resolving it.
    apply '.tickets[$t].resolve = {attempt: $n, paths: $p, pre: $pre, outcome: "pending", at: $now}
      | event({event: "conflict", ticket: $t, paths: $p, next: "resolve-conflicts"}; $now)' \
      --arg t "$t" --argjson n "$n" --argjson p "$pjson" --arg pre "$pre"
    state_die 11 "wave.sh: #$t conflicts in $paths; run /artisan-agent:resolve-conflicts once in $wt, then wave.sh resolved $RUN_DIR $t"
  fi
  finish_merge "$t" "$n" "$wt" "$pre" "$wait"
}

# finish_merge ticket attempt worktree pre wait: the merge gate for the merge
# commit at the worktree's HEAD. Where it runs is the machine's merge gate
# mode (merge-gate.sh): local runs the plan's suite in the worktree; ci gates
# on the project's gate workflow for this exact commit, on a unique
# ci/<run>-<ticket>-<attempt>-<ts> branch. Either way the gate runs detached
# (merge-gate.sh start), recorded first as merge_gate, and writes its outcome
# to results/merge-<ticket>.<attempt>.g<k>.json; this call waits up to `wait`
# seconds for it (await_gate), then 20 if it is still running. Green records
# the merge; red undoes it and blocks the ticket (7); a CI that gives no
# verdict undoes it and parks the run (19) (finish_gate).
finish_merge() {
  local t="$1" n="$2" wt="$3" pre="$4" wait="$5" mode= sha= k= key= ci='{}'
  mode=$("$SCRIPT_DIR/merge-gate.sh" mode) || {
    git -C "$wt" reset -q --hard "$pre"
    die "could not tell this machine's merge gate mode (merge-gate.sh show); #$t not merged"
  }
  sha=$(git -C "$wt" rev-parse HEAD)
  if [ "$mode" = ci ]; then
    ci=$(gate_ci_json "$t-$n") || {
      git -C "$wt" reset -q --hard "$pre"
      die "#$t not merged: $NO_GATE_WORKFLOW"
    }
  fi
  k=$(( $(get --arg t "$t" '[.events[] | select(.event == "merge-gate" and .ticket == $t)] | length') + 1 ))
  key="$t.$n.g$k"
  mkdir -p "$RUN_DIR/merges" "$RUN_DIR/results"
  apply '.merge_gate = ({ticket: $t, attempt: $n, gate: $k, mode: $mode, pre: $pre, sha: $sha,
        result: "results/merge-\($key).json", pid_file: "merges/\($key).gate.pid",
        log: "merges/\($key).gate.log", at: $now} + $ci)
    | event({event: "merge-gate", ticket: $t, attempt: $n, gate: $k, mode: $mode, sha: $sha}; $now)' \
    --arg t "$t" --argjson n "$n" --argjson k "$k" --arg key "$key" --arg mode "$mode" \
    --arg pre "$pre" --arg sha "$sha" --argjson ci "$ci"
  if ! launch_gate; then
    git -C "$wt" reset -q --hard "$pre"
    apply '.merge_gate = null'
    die "#$t not merged: its merge gate did not start; see $RUN_DIR/merges/$key.gate.log"
  fi
  await_gate "$t" "$wait" "$wt"
}

# launch_gate [--resume]: start the recorded gate's detached runner
# (merge-gate.sh start). Its command line names the run folder, so a test's
# cleanup finds it.
launch_gate() {
  local g= mode= p= args=()
  g=$(get -c '.merge_gate')
  mode=$(jq -r .mode <<<"$g")
  if [ "$mode" = ci ]; then
    args=(ci --repo "$(get '.repo')" --workflow "$(jq -r .workflow <<<"$g")" --branch "$(jq -r .branch <<<"$g")"
          --sha "$(jq -r .sha <<<"$g")" --dir "$(integration_worktree)" --deadline "$(jq -r .deadline <<<"$g")")
    # The release allowlist (#168): a merge that only changes these paths over
    # a green commit is recorded green without a dispatch.
    while IFS= read -r p; do args+=(--skip-path "$p"); done < <(skip_paths)
    [ "${1:-}" != --resume ] || args+=(--resume)
  else
    args=(local --dir "$(integration_worktree)" --command "$(get '.plan.suite_command')"
          --log "$RUN_DIR/$(jq -r '.suite_log // "merges/\(.ticket).\(.attempt).suite.log"' <<<"$g")")
  fi
  "$SCRIPT_DIR/merge-gate.sh" start --result "$RUN_DIR/$(jq -r .result <<<"$g")" \
    --pid-file "$RUN_DIR/$(jq -r .pid_file <<<"$g")" --log "$RUN_DIR/$(jq -r .log <<<"$g")" \
    -- "${args[@]}" >/dev/null
}

gate_pid() { cat "$RUN_DIR/$(get '.merge_gate.pid_file')" 2>/dev/null || true; }

# The recorded gate's runner is alive: its pid is live and still the runner,
# never a recycled pid.
gate_alive() {
  local pid=
  pid=$(gate_pid)
  state_pid_alive "$pid" || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -qF "merge-gate.sh run --result $(gate_result)"
}

gate_result() { printf '%s/%s\n' "$RUN_DIR" "$(get '.merge_gate.result')"; }

# settle_gate ticket wait worktree: what to do with a gate recorded in
# progress. None: return. One with an outcome or a live runner: this ticket's
# is awaited and finished (await_gate exits); another ticket's is named (20).
# One whose runner died with no outcome: on CI, if its run was dispatched, a
# fresh runner waits on that same run (same branch, same run id, no new
# dispatch); otherwise the gate is undone for a retry (abandon_gate). A
# ci_gate record from before #142 has no runner, so it is a dead gate.
settle_gate() {
  local t="$1" wait="$2" wt="$3" gt=
  if [ "$(get '.ci_gate != null')" = true ]; then
    apply '.merge_gate = (.merge_gate // (.ci_gate + {mode: "ci", deadline: (.ci_gate.at + 1800)})) | .ci_gate = null'
  fi
  [ "$(get '.merge_gate != null')" = true ] || return 0
  gt=$(get '.merge_gate.ticket')
  if gate_dead && ! revive_gate "$wt"; then
    abandon_gate "$wt"
    return 0
  fi
  [ "$gt" = "$t" ] \
    || state_die 20 "wave.sh: #$t not merged yet: #$gt's merge gate is in progress; finish it first (wave.sh merge $RUN_DIR $gt)"
  await_gate "$t" "$wait" "$wt"
}

# The recorded gate's runner died with no outcome (read twice around the
# liveness check: an outcome written meanwhile is not a death).
gate_dead() { [ ! -f "$(gate_result)" ] && ! gate_alive && [ ! -f "$(gate_result)" ]; }

# revive_gate worktree: a dead CI gate whose run was dispatched gets a fresh
# runner that waits on that same run (same branch, same run id, no new
# dispatch). 1 when there is nothing to wait on (a local gate, or a CI gate
# cut off before its dispatch).
revive_gate() {
  local wt="$1" run=
  [ "$(get '.merge_gate.mode')" = ci ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$(get '.merge_gate.sha')" ] || return 1
  run=$("$SCRIPT_DIR/merge-gate.sh" find --repo "$(get '.repo')" --workflow "$(get '.merge_gate.workflow')" \
          --branch "$(get '.merge_gate.branch')" --sha "$(get '.merge_gate.sha')" 2>/dev/null) || return 1
  launch_gate --resume || return 1
  apply 'event({event: "merge-gate-resumed", ticket: .merge_gate.ticket, branch: .merge_gate.branch, run_id: $id}
      + (if .merge_gate.batch then {batch: .merge_gate.batch, tickets: .merge_gate.tickets} else {} end); $now)' \
    --argjson id "$(jq '.databaseId // null' <<<"$run")"
}

# await_gate ticket wait worktree: wait up to `wait` seconds for the gate's
# outcome and finish it (exits: 0 merged, 7 red, 19 parked); 20 while it runs.
await_gate() {
  local t="$1" wait="$2" wt="$3" result= end=0
  result=$(gate_result)
  end=$((SECONDS + wait))
  while [ ! -f "$result" ] && [ "$SECONDS" -lt "$end" ] && gate_alive; do
    sleep 0.5
  done
  if [ -f "$result" ]; then
    finish_gate "$t" "$wt" "$result"
    exit 0
  fi
  if gate_alive; then
    state_die 20 "wave.sh: #$t's merge gate is running ($(get '.merge_gate | if .mode == "ci" then "CI on \(.branch)" else "the suite here" end')); wait (wait-any.sh), then run wave.sh merge $RUN_DIR $t again"
  fi
  state_die 20 "wave.sh: #$t's merge gate ended without an outcome; run wave.sh merge $RUN_DIR $t again to resume or retry it"
}

# finish_gate ticket worktree result-file: act on the gate's outcome. Green
# records the merge; red undoes it and blocks the ticket (7); on CI, no
# verdict undoes it and parks the run (19). Undo first, then clear the gate's
# record: a crash between the two leaves the record, never an ungated merge.
GATE_JSON=
finish_gate() {
  local t="$1" wt="$2" result="$3" n= pre= sha= mode= rc= suite= record= log= worker_wt= url= why= minutes=
  n=$(get '.merge_gate.attempt') pre=$(get '.merge_gate.pre') sha=$(get '.merge_gate.sha') mode=$(get '.merge_gate.mode')
  suite=$(get '.plan.suite_command')
  # Finished before (a crash after recording it): only the record is left.
  if [ "$(get --arg t "$t" --arg s "$sha" '.tickets[$t] | .status == "merged" and (.merge_commit == $s or .shipped.sync_commit? == $s)')" = true ]; then
    apply '.merge_gate = null'
    printf '%s\n' "$sha"
    return 0
  fi
  rc=$(jq -r '.exit_code // 1' "$result")
  # Not green, and already undone by a call cut off before it cleared the record.
  [ "$rc" -eq 0 ] || [ "$(git -C "$wt" rev-parse HEAD)" != "$pre" ] || git -C "$wt" reset -q --hard "$sha"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$sha" ] \
    || die "the integration worktree $wt is at $(git -C "$wt" rev-parse --short HEAD), not the merge commit #$t's gate judged ($sha); left as it is for the Artisan"
  log="merges/$t.$n.suite.log"
  if [ "$mode" = local ]; then
    if [ "$rc" -ne 0 ]; then
      git -C "$wt" reset -q --hard "$pre"
      apply '.tickets[$t].suite = {command: $c, passed: false, log: $l, mode: "local"} | .merge_gate = null' \
        --arg t "$t" --arg c "$suite" --arg l "$log"
      gate_failed "$t" "the suite failed after merging ($log); the merge was undone"
      state_die 7 "wave.sh: #$t not merged: the suite failed after the merge; see $RUN_DIR/$log"
    fi
    record=$(jq -nc --arg c "$suite" --arg l "$log" '{command: $c, passed: true, log: $l, mode: "local"}')
  else
    GATE_JSON=$(jq -c '.record' "$result")
    jq -e 'type == "object"' <<<"$GATE_JSON" >/dev/null 2>&1 \
      || GATE_JSON=$(get -c '.merge_gate | {mode: "ci", workflow, branch, sha, run_id: null, url: null, conclusion: null, jobs: [], why: "merge-gate.sh gave no record"}')
    if [ "$rc" -ne 0 ]; then
      git -C "$wt" reset -q --hard "$pre"
      apply '.merge_gate = null'
      url=$(jq -r '.url // "no run"' <<<"$GATE_JSON")
      if [ "$rc" -eq 7 ]; then
        apply '.tickets[$t].suite = ({command: $c, passed: false}
            + ($g | {mode, workflow, branch, sha, run_id, url, conclusion, jobs}))' \
          --arg t "$t" --arg c "$suite" --argjson g "$GATE_JSON"
        gate_failed "$t" "CI went red after merging ($(jq -r '.conclusion' <<<"$GATE_JSON") on $url); the merge was undone"
        state_die 7 "wave.sh: #$t not merged: CI concluded $(jq -r '.conclusion' <<<"$GATE_JSON") for the merge ($url)"
      fi
      why=$(jq -r '.why // "no conclusion from CI"' <<<"$GATE_JSON")
      minutes=$(ci_setting timeout_minutes)
      [ -n "$minutes" ] || minutes=30
      apply '.ci_park = ({ticket: $t, attempt: $n, pre: $pre, sha: $sha, minutes: $m, at: $now}
            + ($g | {workflow, branch, run_id, url, conclusion, why}))
        | .decisions += [{id: ((.decisions | length) + 1), kind: "ci", ticket: $t,
            question: "The merge gate for #\($t) got no verdict from CI: \($g.why)\(if $g.url then " (\($g.url))" else "" end). The ticket is not at fault and nothing new merges or dispatches. Recommended: once CI is back, clear the park to retry the gate (wave.sh unpark-ci); or set this machine'"'"'s merge_gate to local?",
            status: "waiting", at: $now}]
        | event({event: "parked", reason: "ci", ticket: $t, detail: $g.why}; $now)' \
        --arg t "$t" --argjson n "$n" --arg pre "$pre" --arg sha "$sha" --argjson m "$minutes" --argjson g "$GATE_JSON"
      state_die 19 "wave.sh: #$t not merged: $why; the run is parked on CI (wave.sh unpark-ci retries the gate)"
    fi
    record=$(jq -c --arg c "$suite" '{command: $c, passed: true}
      + {mode, workflow, branch, sha, run_id, url, conclusion, jobs}
      + (if .skipped then {skipped, relied_on, why} else {} end)' <<<"$GATE_JSON")
  fi
  if is_urgent_sync "$t"; then
    apply '.merge_gate = null'
    ship_urgent "$t" "$sha" "$record"
    printf '%s\n' "$sha"
    return 0
  fi
  "$SCRIPT_DIR/state.sh" merge "$RUN_DIR" "$t" "$sha"
  record_session_cost "$t" "$n"
  apply '.tickets[$t].suite = $r | .merge_gate = null' --arg t "$t" --argjson r "$record"
  note_skipped_gate "$record" "$(jq -nc --arg t "$t" '{ticket: $t}')"
  worker_wt=$(get --arg t "$t" '.tickets[$t].worktree // ""')
  if [ -n "$worker_wt" ] && [ -d "$worker_wt" ]; then
    git -C "$MAIN" worktree remove "$worker_wt" 2>/dev/null \
      || echo "wave.sh: left $worker_wt in place (it has changes); the merge stands" >&2
  fi
  printf '%s\n' "$sha"
}

# ------------------------------------------------------------- merge batch

# A merge batch (#167): tickets ready together are merged in order onto the
# integration branch and their tip is gated once. Green merges them all. Red
# is split: the gate runs on the tip of the first half (a prefix of the
# merge batch, its merge commits already built); a green prefix merges and the
# split goes on in what is left, a red one is halved again, until one
# ticket's merge turns a green tip red. That ticket alone gets the red
# handling (finish_gate's), and the tickets after it are merged afresh
# without it and gated as the merge batch's next round. A conflict while building
# leaves its ticket out, for the existing conflict path (merge it alone). A
# merge batch run counts against no ticket's attempts. Recorded as merge_batch:
#   {id, tickets, attempts, pre, order, commits, red, red_record, rebuild,
#    merged, red_tickets, left_out, gates, at}
# pre is always green (the integration tip before the merge batch, or the last
# green prefix); order are the tickets still to settle, commits their merge
# commits built on pre; red is the shortest prefix of order known red.

# batch_start wait tickets-json: check every ticket as a merge does, build
# the merge batch and run it.
batch_start() {
  local wait="$1" list="$2" t= wt= pre= gt= attempts='{}' id=
  wt=$(integration_worktree)
  if [ "$(get '.merge_gate != null')" = true ]; then
    gt=$(get '.merge_gate.ticket')
    state_die 20 "wave.sh: not merged yet: #$gt's merge gate is in progress; finish it first (wave.sh merge $RUN_DIR $gt)"
  fi
  [ "$(get '.ci_park != null')" = false ] \
    || state_die 19 "wave.sh: not merged: the run is parked on CI ($(get -r '.ci_park.why')); nothing merges until the park is cleared (wave.sh unpark-ci)"
  [ -n "$(get '.plan.suite_command // ""')" ] || die "the plan has no suite_command; the full suite must run after every merge"
  for t in $(jq -r '.[]' <<<"$list"); do
    [ "$(get --arg t "$t" '.tickets[$t].urgent // false')" != true ] \
      || state_die 6 "wave.sh: #$t is urgent: it ships through its own end gate and PR to main (end-gate.sh urgent-open), never in a merge batch"
    check_returned wave.sh "$t" "not merged"
    [ "$(get --arg t "$t" --argjson n "$ATTEMPT" --arg tip "$TIP" \
          '.tickets[$t].evidence | if . != null and .verdict == "pass" and .attempt == $n and .commit == $tip then "pass" else "" end')" = pass ] \
      || state_die 13 "wave.sh: #$t not merged: no passing verdict for attempt $ATTEMPT at $TIP; run verify.sh start, then verify.sh judge"
    attempts=$(jq -c --arg t "$t" --argjson n "$ATTEMPT" '. + {($t): $n}' <<<"$attempts")
  done
  abandon_pending_resolution "$wt"
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "the integration worktree $wt has uncommitted changes"
  pre=$(git -C "$wt" rev-parse HEAD)
  id=$(( $(get '[.events[] | select(.event == "merge-batch")] | length') + 1 ))
  # Recorded before anything is merged, to be built (rebuild) by batch_run:
  # a crash mid-build leaves a merge batch whose next call builds it again on pre,
  # never merge commits nothing records.
  apply '.merge_batch = {id: $id, tickets: $l, attempts: $a, pre: $pre, order: $l, commits: [],
          red: null, red_record: null, rebuild: true, merged: [], red_tickets: [], left_out: [], gates: 0, at: $now}
    | reduce $l[] as $t (.; .tickets[$t].ci_retry = null)
    | event({event: "merge-batch", batch: $id, tickets: $l}; $now)' \
    --argjson id "$id" --argjson l "$list" --argjson a "$attempts" --arg pre "$pre"
  batch_run "$wait"
}

# batch_build pre tickets-json: reset the integration worktree to pre and
# merge each ticket --no-ff in order; a ticket that conflicts is left out
# (its merge aborted). Sets BUILT to {order, commits, left_out}.
BUILT=
batch_build() {
  local pre="$1" list="$2" wt= ib= t= branch= title= pjson= order='[]' commits='[]' left='[]'
  wt=$(integration_worktree)
  ib=$(integration_branch)
  git -C "$wt" reset -q --hard "$pre"
  for t in $(jq -r '.[]' <<<"$list"); do
    branch=$(get --arg t "$t" '.tickets[$t].branch')
    title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
    if git -C "$wt" merge --no-ff --no-edit -m "Merge #$t ($title) into $ib" "$branch" >/dev/null 2>&1; then
      order=$(jq -c --arg t "$t" '. + [$t]' <<<"$order")
      commits=$(jq -c --arg c "$(git -C "$wt" rev-parse HEAD)" '. + [$c]' <<<"$commits")
    else
      pjson=$(unmerged_json "$wt")
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      git -C "$wt" reset -q --hard "$(jq -r --arg p "$pre" 'last // $p' <<<"$commits")"
      left=$(jq -c --arg t "$t" --argjson p "$pjson" '. + [{ticket: $t, paths: $p}]' <<<"$left")
    fi
  done
  BUILT=$(jq -nc --argjson o "$order" --argjson c "$commits" --argjson l "$left" '{order: $o, commits: $c, left_out: $l}')
}

# batch_run wait: settle the merge batch, gate by gate, within `wait` seconds:
# exits 0 (all merged), 7 (a ticket red), 19 (parked on CI), 20 (a gate
# still running).
batch_run() {
  local end=$((SECONDS + $1)) red= n= p=
  while :; do
    if [ "$(get '.merge_gate != null')" = true ]; then
      if batch_await "$end"; then
        batch_outcome
      elif [ "$SECONDS" -ge "$end" ]; then
        state_die 20 "wave.sh: merge batch $(get '.merge_batch.id')'s gate ended without an outcome and was undone; run wave.sh merge $RUN_DIR $(get -r '.merge_batch.tickets | join(" ")') again to gate it again"
      fi
      continue
    fi
    if [ "$(get '.merge_batch.rebuild')" = true ]; then
      batch_build "$(get '.merge_batch.pre')" "$(get -c '.merge_batch.order')"
      apply '.merge_batch |= (.order = $b.order | .commits = $b.commits | .left_out += $b.left_out | .rebuild = false)' \
        --argjson b "$BUILT"
      continue
    fi
    n=$(get '.merge_batch.order | length')
    [ "$n" -gt 0 ] || batch_end
    red=$(get '.merge_batch.red // 0')
    if [ "$red" -eq 1 ]; then
      batch_red_ticket
      continue
    fi
    if [ "$red" -eq 0 ]; then p=$n; else p=$((red / 2)); fi
    batch_gate "$p"
  done
}

# batch_gate p: gate the tip of the merge batch's first p tickets (the merge
# commit of order[p-1]), recorded as merge_gate with the tickets it judges.
batch_gate() {
  local p="$1" wt= mode= sha= pre= id= k= key= ci='{}' tickets=
  wt=$(integration_worktree)
  pre=$(get '.merge_batch.pre')
  id=$(get '.merge_batch.id')
  sha=$(get --argjson p "$p" '.merge_batch.commits[$p - 1]')
  tickets=$(get -c --argjson p "$p" '.merge_batch.order[:$p]')
  git -C "$wt" reset -q --hard "$sha"
  mode=$("$SCRIPT_DIR/merge-gate.sh" mode) || {
    git -C "$wt" reset -q --hard "$pre"
    die "could not tell this machine's merge gate mode (merge-gate.sh show); merge batch $id not gated"
  }
  k=$(( $(get '.merge_batch.gates') + 1 ))
  if [ "$mode" = ci ]; then
    ci=$(gate_ci_json "b$id-g$k") || {
      git -C "$wt" reset -q --hard "$pre"
      die "merge batch $id not merged: $NO_GATE_WORKFLOW"
    }
  fi
  key="batch-$id.g$k"
  mkdir -p "$RUN_DIR/merges" "$RUN_DIR/results"
  apply '.merge_batch.gates = $k
    | .merge_gate = ({batch: $id, tickets: $ts, ticket: $ts[0], attempt: .merge_batch.attempts[$ts[0]],
        gate: $k, mode: $mode, pre: $pre, sha: $sha, result: "results/merge-\($key).json",
        pid_file: "merges/\($key).gate.pid", log: "merges/\($key).gate.log",
        suite_log: "merges/\($key).suite.log", at: $now} + $ci)
    | event({event: "merge-gate", batch: $id, tickets: $ts, gate: $k, mode: $mode, sha: $sha}; $now)' \
    --argjson id "$id" --argjson ts "$tickets" --argjson k "$k" --arg key "$key" --arg mode "$mode" \
    --arg pre "$pre" --arg sha "$sha" --argjson ci "$ci"
  if ! launch_gate; then
    git -C "$wt" reset -q --hard "$pre"
    apply '.merge_gate = null'
    die "merge batch $id not merged: its merge gate did not start; see $RUN_DIR/merges/$key.gate.log"
  fi
}

# batch_await end: 0 once the merge batch's gate has an outcome; 1 when its runner
# died with nothing to wait on (undone: batch_run gates it again); 20 while
# it runs past `end`.
batch_await() {
  local end="$1" wt= result=
  wt=$(integration_worktree)
  if gate_dead && ! revive_gate "$wt"; then
    abandon_gate "$wt"
    return 1
  fi
  result=$(gate_result)
  while [ ! -f "$result" ] && [ "$SECONDS" -lt "$end" ] && gate_alive; do
    sleep 0.5
  done
  [ ! -f "$result" ] || return 0
  state_die 20 "wave.sh: merge batch $(get '.merge_batch.id')'s gate is running on $(get -r '.merge_gate | "\(.tickets | map("#" + .) | join(", ")) (\(if .mode == "ci" then "CI on \(.branch)" else "the suite here" end))"'); wait (wait-any.sh), then run wave.sh merge $RUN_DIR $(get -r '.merge_batch.tickets | join(" ")') again"
}

# batch_outcome: act on the merge batch gate's outcome. Green merges the prefix it
# judged; red marks it the shortest red prefix; no verdict from CI parks the
# run (batch_park). The integration worktree ends at the merge batch's green pre.
batch_outcome() {
  local wt= result= rc= mode= sha= pre= p= suite= record= head= who=
  wt=$(integration_worktree)
  result=$(gate_result)
  mode=$(get '.merge_gate.mode') sha=$(get '.merge_gate.sha') pre=$(get '.merge_gate.pre')
  p=$(get '.merge_gate.tickets | length')
  suite=$(get '.plan.suite_command')
  rc=$(jq -r '.exit_code // 1' "$result")
  head=$(git -C "$wt" rev-parse HEAD)
  [ "$head" = "$sha" ] || [ "$head" = "$pre" ] \
    || die "the integration worktree $wt is at $(git -C "$wt" rev-parse --short HEAD), not the commit merge batch $(get '.merge_batch.id')'s gate judged ($sha); left as it is for the Artisan"
  if [ "$mode" = local ]; then
    record=$(jq -nc --arg c "$suite" --arg l "$(get '.merge_gate.suite_log')" --argjson p "$([ "$rc" -eq 0 ] && echo true || echo false)" \
      '{command: $c, passed: $p, log: $l, mode: "local"}')
    [ "$rc" -eq 0 ] || rc=7
  else
    GATE_JSON=$(jq -c '.record' "$result")
    jq -e 'type == "object"' <<<"$GATE_JSON" >/dev/null 2>&1 \
      || GATE_JSON=$(get -c '.merge_gate | {mode: "ci", workflow, branch, sha, run_id: null, url: null, conclusion: null, jobs: [], why: "merge-gate.sh gave no record"}')
    record=$(jq -c --arg c "$suite" --argjson p "$([ "$rc" -eq 0 ] && echo true || echo false)" '{command: $c, passed: $p}
      + {mode, workflow, branch, sha, run_id, url, conclusion, jobs}
      + (if .skipped then {skipped, relied_on, why} else {} end)' <<<"$GATE_JSON")
  fi
  record=$(jq -c --argjson b "$(get '.merge_batch.id')" --argjson ts "$(get -c '.merge_gate.tickets')" \
    '. + {batch: $b, batch_tickets: $ts}' <<<"$record")
  case "$rc" in
    0) who=$(get -c '{batch: .merge_batch.id, tickets: .merge_gate.tickets}')
       batch_merge_prefix "$p" "$record"
       note_skipped_gate "$record" "$who" ;;
    7)
      git -C "$wt" reset -q --hard "$pre"
      apply '.merge_batch |= (.red = $p | .red_record = $r) | .merge_gate = null' --argjson p "$p" --argjson r "$record" ;;
    *)
      git -C "$wt" reset -q --hard "$pre"
      batch_park ;;
  esac
}

# batch_merge_prefix p record: the merge batch's first p tickets passed their gate:
# record each merged at its own merge commit, with the gate's record as its
# suite, and move the merge batch's green pre up to the last of them.
batch_merge_prefix() {
  local p="$1" record="$2" wt= i=0 t= c= worker_wt=
  wt=$(integration_worktree)
  git -C "$wt" reset -q --hard "$(get --argjson p "$p" '.merge_batch.commits[$p - 1]')"
  while [ "$i" -lt "$p" ]; do
    t=$(get --argjson i "$i" '.merge_batch.order[$i]')
    c=$(get --argjson i "$i" '.merge_batch.commits[$i]')
    i=$((i + 1))
    # Merged already by a call cut off before it moved the merge batch on: the
    # rest (cost, suite record, worktree) is done again, harmlessly.
    [ "$(get --arg t "$t" '.tickets[$t].status')" = merged ] || "$SCRIPT_DIR/state.sh" merge "$RUN_DIR" "$t" "$c"
    record_session_cost "$t" "$(get --arg t "$t" '.merge_batch.attempts[$t]')"
    apply '.tickets[$t].suite = $r' --arg t "$t" --argjson r "$record"
    worker_wt=$(get --arg t "$t" '.tickets[$t].worktree // ""')
    if [ -n "$worker_wt" ] && [ -d "$worker_wt" ]; then
      git -C "$MAIN" worktree remove "$worker_wt" 2>/dev/null \
        || echo "wave.sh: left $worker_wt in place (it has changes); the merge stands" >&2
    fi
  done
  apply '.merge_batch |= (.merged += [range(0; $p) as $i | {ticket: .order[$i], commit: .commits[$i]}]
      | .pre = .commits[$p - 1] | .order = .order[$p:] | .commits = .commits[$p:]
      | .red = (if .red == null then null else .red - $p end))
    | .merge_gate = null' --argjson p "$p"
}

# batch_red_ticket: the merge batch's first ticket turned its green pre red. It
# alone gets the red handling, as finish_gate gives a single merge (its suite
# record, then blocked with a decision); the tickets after it are merged
# afresh on pre without it (batch_run, rebuild).
batch_red_ticket() {
  local t= record= why= url=
  t=$(get '.merge_batch.order[0]')
  record=$(get -c '.merge_batch.red_record')
  # Blocked first, once: a call cut off after it only moves the merge batch on.
  if [ "$(get --arg t "$t" '.tickets[$t].status')" != blocked ]; then
    if [ "$(jq -r .mode <<<"$record")" = local ]; then
      why="the suite failed after merging ($(jq -r .log <<<"$record"), merge batch $(get '.merge_batch.id')); the merge was undone"
    else
      url=$(jq -r '.url // "no run"' <<<"$record")
      why="CI went red after merging ($(jq -r .conclusion <<<"$record") on $url, merge batch $(get '.merge_batch.id')); the merge was undone"
    fi
    apply '.tickets[$t].suite = $r' --arg t "$t" --argjson r "$record"
    gate_failed "$t" "$why"
  fi
  apply '.merge_batch |= (.red_tickets += [.order[0]] | .order = .order[1:] | .commits = []
      | .rebuild = (.order | length > 0) | .red = null | .red_record = null)'
}

# batch_park: CI gave the merge batch's gate no verdict. The tickets not yet merged
# stay returned, the merge batch ends, and the run parks on CI as for one merge;
# unpark-ci clears it and they are merged afresh.
batch_park() {
  local minutes=
  GATE_JSON=$(jq -c '.record' "$(gate_result)")
  jq -e 'type == "object"' <<<"$GATE_JSON" >/dev/null 2>&1 \
    || GATE_JSON=$(get -c '.merge_gate | {mode: "ci", workflow, branch, sha, run_id: null, url: null, conclusion: null, jobs: [], why: "merge-gate.sh gave no record"}')
  minutes=$(ci_setting timeout_minutes)
  [ -n "$minutes" ] || minutes=30
  apply '.merge_gate as $mg | .merge_batch as $b
    | .ci_park = ({ticket: $b.order[0], tickets: $b.order, batch: $b.id, attempt: $b.attempts[$b.order[0]],
          pre: $mg.pre, sha: $mg.sha, minutes: $m, at: $now} + ($g | {workflow, branch, run_id, url, conclusion, why}))
    | .decisions += [{id: ((.decisions | length) + 1), kind: "ci", ticket: $b.order[0],
        question: "The merge gate for merge batch \($b.id) (\($b.order | map("#" + .) | join(", "))) got no verdict from CI: \($g.why)\(if $g.url then " (\($g.url))" else "" end). The tickets are not at fault and nothing new merges or dispatches. Recommended: once CI is back, clear the park and merge them again (wave.sh unpark-ci); or set this machine'"'"'s merge_gate to local?",
        status: "waiting", at: $now}]
    | event({event: "parked", reason: "ci", ticket: $b.order[0], tickets: $b.order, batch: $b.id, detail: $g.why}; $now)
    | .merge_gate = null' --argjson m "$minutes" --argjson g "$GATE_JSON"
  batch_report
  batch_close
  state_die 19 "wave.sh: merge batch not merged: $(jq -r '.why // "no conclusion from CI"' <<<"$GATE_JSON"); the run is parked on CI (wave.sh unpark-ci, then merge them again)"
}

# batch_end: every ticket settled. One line per ticket, the merge batch cleared.
# 0 all merged (or left out for their own merge); 7 a ticket went red.
batch_end() {
  local red=
  red=$(get '.merge_batch.red_tickets | length')
  batch_report
  batch_close
  [ "$red" -eq 0 ] || state_die 7 "wave.sh: not merged: $(get -r '[.events[] | select(.event == "merge-batch-ended")] | last | .red | map("#" + .) | join(", ")') went red in its merge batch; blocked, with a decision queued"
  exit 0
}

# batch_report: what became of each ticket, in the merge batch's order:
#   #<t> merged <commit> | #<t> red | #<t> left out: conflict in <paths>; merge it alone
# then each ticket named beside the merge batch (BATCH_EXTRA): #<t> not merged: ...
BATCH_EXTRA='[]'
batch_report() {
  get -r --arg rd "$RUN_DIR" '.merge_batch as $b | $b.tickets[] as $t
    | if ([$b.merged[] | select(.ticket == $t)] | length) > 0 then "#\($t) merged \([$b.merged[] | select(.ticket == $t)][0].commit)"
      elif ($b.red_tickets | index($t)) then "#\($t) red"
      elif ([$b.left_out[] | select(.ticket == $t)] | length) > 0
        then "#\($t) left out: conflict in \([$b.left_out[] | select(.ticket == $t)][0].paths | join(" ")); merge it alone (wave.sh merge \($rd) \($t))"
      else "#\($t) not merged" end,
    ($x[] | "#\(.) not merged: not in merge batch \($b.id); merge it next")' --argjson x "$BATCH_EXTRA"
}

# batch_close: log the merge batch's end and clear it.
batch_close() {
  apply '.merge_batch as $b
    | event({event: "merge-batch-ended", batch: $b.id, tickets: $b.tickets, merged: [$b.merged[].ticket],
             red: $b.red_tickets, left_out: [$b.left_out[].ticket], not_merged: $b.order, gates: $b.gates}; $now)
    | .merge_batch = null'
}

# ------------------------------------------------------------ CI merge gate

NO_GATE_WORKFLOW="this machine gates merges on CI (merge-gate.sh show), but the project records no gate workflow (ci_gate.workflow in .artisan-agent/config.yml, which project setup records); record it, or set this machine's merge_gate to local (machine-setup.sh merge-gate local)"

# skip_paths: the release allowlist (merge_gate_skip_paths), one pattern per
# line: the plan's snapshot of the config, else the project's.
skip_paths() {
  local v=
  v=$(get -c '.plan.config.merge_gate_skip_paths // empty')
  [ -n "$v" ] || v=$( (cd "$MAIN" && "$SCRIPT_DIR/config.sh" get merge_gate_skip_paths) 2>/dev/null) || v='[]'
  jq -r '.[]?' <<<"$v"
}

# note_skipped_gate record who-json: a gate that CI never ran, because only
# release paths changed over a green commit, leaves an event naming the green
# run it relied on (#168). Any other record leaves nothing.
note_skipped_gate() {
  [ "$(jq -r '.skipped // false' <<<"$1")" = true ] || return 0
  apply 'event({event: "merge-gate-skipped", sha: $g.sha, run_id: $g.relied_on.run_id, url: $g.relied_on.url,
      relied_on_sha: $g.relied_on.sha, why: $g.why} + $who; $now)' --argjson g "$1" --argjson who "$2"
}

# gate_ci_json label: the CI part of a merge gate's record, on a unique
# ci/<run>-<label>-<ts> branch: {workflow, branch, minutes, deadline}. 1 when
# the project records no gate workflow. Sweeps the leftovers of a gate that
# died first (its record is cleared at the next merge).
gate_ci_json() {
  local wf= minutes= branch= deadline=
  wf=$(ci_setting workflow)
  [ -n "$wf" ] || return 1
  minutes=$(ci_setting timeout_minutes)
  [ -n "$minutes" ] || minutes=30
  branch="ci/$RUN_ID-$1-$(state_now)"
  deadline=$(( $(date +%s) + minutes * 60 ))
  "$SCRIPT_DIR/merge-gate.sh" sweep --prefix "ci/$RUN_ID-" --dir "$(integration_worktree)" >/dev/null 2>&1 || true
  jq -nc --arg wf "$wf" --arg b "$branch" --argjson m "$minutes" --argjson d "$deadline" \
    '{workflow: $wf, branch: $b, minutes: $m, deadline: $d}'
}

# A ci_gate setting (workflow, timeout_minutes): the plan's config, which
# carries this run's overrides, else the project config as it is now.
ci_setting() { # key
  local v=
  v=$(get --arg k "$1" '.plan.config.ci_gate[$k] // empty')
  [ -n "$v" ] || v=$( (cd "$MAIN" && "$SCRIPT_DIR/config.sh" show) | jq -r --arg k "$1" '.ci_gate[$k] // empty')
  printf '%s\n' "$v"
}

# abandon_gate worktree: a gate whose runner died with no outcome and nothing
# to wait on (a local suite cut off, or a CI gate cut off before its run was
# dispatched): stop anything left in its runner's group, undo its merge
# commit and keep it for the ticket's next merge to gate again (ci_retry;
# a merge batch's gate is gated again by the merge batch).
# A CI gate's branch goes at the next gate's sweep.
abandon_gate() {
  local wt="$1" pid= sha=
  pid=$(gate_pid)
  # What its runner left in its group: a pid can't be reused while its group
  # lives, so a live pid that isn't the runner is someone else's (skip it).
  if state_is_uint "$pid" && ! state_pid_alive "$pid"; then kill -KILL "-$pid" 2>/dev/null || true; fi
  sha=$(get '.merge_gate.sha')
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$sha" ]; then git -C "$wt" reset -q --hard "$(get '.merge_gate.pre')"; fi
  # A merge batch's gate is gated again by the merge batch itself (batch_run), on its
  # own recorded commits: no ticket keeps a retry.
  apply '.merge_gate as $g
    | if $g.batch then . else .tickets[$g.ticket].ci_retry = {pre: $g.pre, sha: $g.sha, at: $now} end
    | event({event: (if $g.mode == "ci" then "ci-gate-abandoned" else "merge-gate-abandoned" end),
             ticket: $g.ticket, branch: ($g.branch // null)}
            + (if $g.batch then {batch: $g.batch, tickets: $g.tickets} else {} end); $now)
    | .merge_gate = null'
}

# A conflict left in progress whose resolution never came back (the
# orchestrator ended mid-try): abort it, and block its ticket, whose one try
# is used. Runs before any other merge.
abandon_pending_resolution() { # integration worktree
  local wt="$1" t=
  t=$(get '[.tickets | to_entries[] | select(.value.resolve.outcome? == "pending") | .key] | first // ""')
  [ -n "$t" ] || return 0
  git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$(get --arg t "$t" '.tickets[$t].resolve.pre')"
  apply '.tickets[$t].resolve.outcome = "abandoned"' --arg t "$t"
  if is_urgent_sync "$t"; then
    queue_sync_decision "$t" "main's conflict in $(join_paths "$(get --arg t "$t" '.tickets[$t].resolve.paths')") was never resolved (the merge was aborted); its one /artisan-agent:resolve-conflicts try is used"
    return 0
  fi
  block "$t" "its conflict resolution never finished (the merge was aborted); its one /artisan-agent:resolve-conflicts try is used"
}

# --------------------------------------------------------------- resolved

cmd_resolved() {
  open_run "${1:-}"
  local t="${2:-}" gave_up= wait=$DEFAULT_GATE_WAIT_SECONDS
  [ -n "$t" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --gave-up) [ $# -ge 2 ] || usage; gave_up=$2; shift 2 ;;
      --wait) [ $# -ge 2 ] || usage; wait=$(gate_wait_arg "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  local wt= ib= n= pre= branch= paths= pjson= left= markers= title= why= p=
  [ "$(get --arg t "$t" '.tickets[$t].resolve.outcome? // ""')" = pending ] \
    || die "#$t has no conflict waiting on its resolution"
  wt=$(integration_worktree)
  ib=$(integration_branch)
  n=$(get --arg t "$t" '.tickets[$t].resolve.attempt')
  pre=$(get --arg t "$t" '.tickets[$t].resolve.pre')
  branch=$(get --arg t "$t" '.tickets[$t].branch')
  local sync= expect=
  sync=$(get -r --arg t "$t" '.tickets[$t].resolve.sync.ref // ""')
  expect=$(get -r --arg t "$t" '.tickets[$t].resolve.sync.head // ""')
  pjson=$(get --arg t "$t" '.tickets[$t].resolve.paths')
  paths=$(join_paths "$pjson")
  why=$gave_up
  if [ -z "$why" ]; then
    if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null; then
      why="the merge is no longer in progress"
    elif [ -n "$sync" ] && [ "$(git -C "$wt" rev-parse MERGE_HEAD)" != "$expect" ]; then
      why="the merge in progress is not $sync"
    elif [ -z "$sync" ] && [ "$(git -C "$wt" rev-parse MERGE_HEAD)" != "$(git -C "$MAIN" rev-parse "refs/heads/$branch")" ]; then
      why="the merge in progress is not $branch"
    else
      left=$(join_paths "$(unmerged_json "$wt")")
      markers=
      # Each recorded path, quoted: no word splitting, no glob expansion.
      while IFS= read -r -d '' p; do
        if grep -q -E '^(<<<<<<<|>>>>>>>)( |$)' -- "$wt/$p" 2>/dev/null; then markers="$markers$p "; fi
      done < <(jq -j '.[] + "\u0000"' <<<"$pjson")
      if [ -n "$left" ]; then why="still conflicted: $left"
      elif [ -n "$markers" ]; then why="conflict markers left in ${markers% }"
      elif ! git -C "$wt" diff --quiet; then why="changes left unstaged: $(git -C "$wt" diff --name-only | tr '\n' ' ')"
      elif [ -n "$(git -C "$wt" ls-files --others --exclude-standard)" ]; then
        why="files left behind: $(git -C "$wt" ls-files --others --exclude-standard --directory | tr '\n' ' ')"
      fi
    fi
  fi
  if [ -n "$why" ]; then
    git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
    # The integration worktree holds nothing but the integration branch.
    git -C "$wt" clean -q -fd >/dev/null 2>&1 || true
    apply '.tickets[$t].resolve |= (.outcome = "unresolved" | .why = $w)
      | event({event: "resolve", ticket: $t, outcome: "unresolved", why: $w}; $now)' --arg t "$t" --arg w "$why"
    if [ -n "$sync" ]; then
      queue_sync_decision "$t" "main's conflict in $paths that /artisan-agent:resolve-conflicts could not resolve: $why"
      state_die 6 "wave.sh: main not merged into $ib after urgent #$t: $why; merge aborted, a decision is queued"
    fi
    block "$t" "merge conflict in $paths that /artisan-agent:resolve-conflicts could not resolve: $why"
    state_die 6 "wave.sh: #$t not merged: $why; blocked, with $branch and its worktree kept"
  fi
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  local msg="Merge #$t ($title) into $ib"
  [ -z "$sync" ] || msg="Merge $(main_branch) into $ib (urgent #$t shipped)"
  git -C "$wt" commit -q --no-verify -m "$msg" \
    -m "Conflicts in $paths resolved by /artisan-agent:resolve-conflicts." >/dev/null \
    || die "could not commit the resolved merge of #$t"
  apply '.tickets[$t].resolve.outcome = "resolved"
    | event({event: "resolve", ticket: $t, outcome: "resolved"}; $now)' --arg t "$t"
  finish_merge "$t" "$n" "$wt" "$pre" "$wait"
}

# ------------------------------------------------------------- unpark-ci

# The Artisan clears a CI park: the parked ticket's next merge retries the
# gate on the same merge commit, and dispatch carries on.
cmd_unpark_ci() {
  open_run "${1:-}"
  shift
  local by=Artisan
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$(get '.ci_park != null')" = true ] || state_die 6 "wave.sh: run $RUN_ID is not parked on CI"
  # A merge batch's park retries nothing in place: its tickets are merged afresh.
  apply '.ci_park as $p
    | if $p.batch then . else .tickets[$p.ticket].ci_retry = {pre: $p.pre, sha: $p.sha, at: $now} end
    | .decisions |= map(if .kind == "ci" and .status == "waiting"
                        then .status = "decided" | .choice = "retry" | .by = $by | .decided_at = $now else . end)
    | event({event: "unparked", reason: "ci", ticket: $p.ticket, how: "retry", by: $by}
            + (if $p.batch then {tickets: $p.tickets, batch: $p.batch} else {} end); $now)
    | .ci_park = null' --arg by "$by"
  get -r '[.events[] | select(.event == "unparked" and .reason == "ci")] | last
    | if .tickets then "unparked: merge \(.tickets | map("#" + .) | join(", ")) again (their batch is merged and gated afresh)"
      else "unparked: #\(.ticket) merges next with the gate retried" end'
}

# ------------------------------------------------------------------- close

cmd_close() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local status= repo= body= newbody=
  status=$(get --arg t "$t" '.tickets[$t].status // ""')
  [ "$status" = merged ] || die "#$t is ${status:-not in the run}, not merged; only merged work closes"
  if [ "$(get --arg t "$t" '.tickets[$t].tracker_closed // false')" = true ]; then
    "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null || die "#$t is closed, but its slice gate could not be opened (gate.sh sync)"
    return 0
  fi
  repo=$(get '.repo')
  mkdir -p "$RUN_DIR/merges"
  # The comment is the evidence contract in the state file, shown.
  body="$RUN_DIR/merges/$t.comment.md"
  "$SCRIPT_DIR/evidence.sh" comment "$RUN_DIR" "$t" >"$body" || die "no evidence contract for #$t"
  gh issue comment "$t" -R "$repo" --body-file "$body" >/dev/null || die "could not comment on #$t"
  newbody="$RUN_DIR/merges/$t.body.md"
  get --arg t "$t" '.tickets[$t].evidence' >"$newbody.evidence.json"
  if gh issue view "$t" -R "$repo" --json body -q .body >"$newbody.orig" 2>/dev/null \
    && python3 -I "$SCRIPT_DIR/lib/criteria.py" tick "$newbody.evidence.json" <"$newbody.orig" >"$newbody" \
    && ! cmp -s "$newbody.orig" "$newbody"; then
    gh issue edit "$t" -R "$repo" --body-file "$newbody" >/dev/null || die "could not tick the criteria on #$t"
  fi
  gh issue close "$t" -R "$repo" >/dev/null || die "could not close #$t"
  "$SCRIPT_DIR/state.sh" closed "$RUN_DIR" "$t"
  # The last merge of a slice opens its review gate before anything else
  # dispatches (gate.sh, references/review-gates.md).
  "$SCRIPT_DIR/gate.sh" sync "$RUN_DIR" >/dev/null || die "#$t is closed, but its slice gate could not be opened (gate.sh sync)"
}

# ------------------------------------------------------------------ report

cmd_report() {
  open_run "${1:-}"
  halt_if_wave_failed
  jq '{
    run_id, wave: ((.orchestrators // []) | last | .wave // null),
    integration: .integration,
    tickets: [.plan.scope[] as $t | .tickets[$t] as $k | {
      ticket: $t, title: (.plan.tickets[$t].title // null), status: $k.status,
      attempts: $k.attempts, merge_commit: $k.merge_commit,
      tracker_closed: ($k.tracker_closed // false), cost_usd: $k.cost_usd,
      verdict: ($k.evidence.verdict // null),
      blocked_reason: ($k.blocked_reason // null), resolve: ($k.resolve // null)}],
    decisions_waiting: [.decisions[] | select(.status == "waiting")],
    halted: (.halted // null),
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
  wait) cmd_wait "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  merge) cmd_merge "$@" ;;
  resolved) cmd_resolved "$@" ;;
  unpark-ci) cmd_unpark_ci "$@" ;;
  close) cmd_close "$@" ;;
  block)
    [ $# -eq 3 ] || usage
    open_run "$1"
    "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$2" || exit $?
    block "$2" "$3"
    ;;
  report) cmd_report "$@" ;;
  *) usage ;;
esac
