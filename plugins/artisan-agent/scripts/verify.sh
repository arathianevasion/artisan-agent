#!/usr/bin/env bash
# The verifier: a fresh, short-lived headless session per returned ticket
# that checks the worker's diff against the ticket's acceptance criteria and
# returns a verdict in the evidence format. The orchestrator reads only the
# one line this script prints, never the verifier's transcript. The
# verifier's brief: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/verifier.md.
# The verdict and the evidence contract: ${CLAUDE_PLUGIN_ROOT}/references/evidence-contract.md.
#
# Usage, from the orchestrator:
#   verify.sh start <run-dir> <ticket>
#       for a returned ticket whose attempt completed: read its acceptance
#       criteria from the tracker (or its ticket_path), check out the
#       worker's commit in a throwaway detached worktree and launch the
#       verifier there, detached (run-ticket.sh --role verifier). Prints
#       the verifier's runner pid. Idempotent per attempt: while the
#       attempt has a verifier running, ended but not judged, or passed (or
#       another call is starting one), it launches nothing and prints that
#       verifier's pid; only after an error (judge's 14) does it start the
#       next. The verifier is told the recorded checks (checks.sh, read from
#       the integration worktree's CODING_STANDARDS.md, not the worker's
#       branch) and the one command that runs them and writes their results
#       to verify/checks/<t>.<v>.json; with none recorded, to run what it
#       finds through the same command, which records the fallback.
#       8: the worker (or a verifier left from an earlier attempt) is
#       still running, or another call's verifier did not come up: call again. 6: the attempt did not complete (a failed attempt, as
#       wave.sh merge counts it) or the result does not describe the branch
#       tip (blocked).
#   verify.sh judge <run-dir> <ticket>
#       once the verifier has ended: read its verdict, build the ticket's
#       evidence contract, write it to the state file (one event,
#       "verified"), remove the verifier's worktree. Prints one line:
#         pass <met>/<total>                    every criterion met: merge it
#         pass <met>/<total>, <k> to Human check #<n>
#                                               every criterion met but k the
#                                               verifier marked "human" (only a
#                                               person can verify them): merge
#                                               it; those k moved to Human
#                                               check #n (to-plan.sh
#                                               split-human-check), in the
#                                               run's scope, for the next slice
#                                               gate. Never a failed attempt
#         pass <met>/<total>, <k> need a human check (no tracker ticket to split them into)
#                                               the same, for a ticket with a
#                                               ticket_path: its contract's
#                                               unsure says to move them by hand
#         fail <met>/<total> retry: <first unmet>   a failed attempt: queued
#                                               for a fresh worker given the
#                                               verifier's findings
#         fail <met>/<total> blocked: <first unmet> a failed attempt, the last:
#                                               blocked, with a decision
#         error <reason>                        the verifier itself failed
#       With checks recorded, a verdict without their results is an error (the
#       verifier did not run them), and a red one makes every criterion that
#       cites it unmet, or every criterion when none does.
#       An unmet criterion on which the verifier named a guardrail (its
#       `guardrail`, an id from guardrails.sh resolve) logs guardrail-fired
#       in the same write. A fail posts the evidence comment on the ticket.
#       A "human" criterion is neither met nor unmet: it never fails an
#       attempt, and a pass with some splits them off before anything is
#       recorded (logging human-check-split), so judging again, or after a
#       crash, makes no second Human check. A ticket with a ticket_path has
#       no tracker ticket to split: its contract says to move them by hand.
#       Exit 0 pass, 6 fail
#       or a second verifier failure (blocked), 8 the verifier is still
#       running, 14 the verifier failed once: start it again.
#
# Plan settings (state file, all optional): plan.verifier.model (default
# claude-sonnet-5-5), plan.verifier.estimate_usd (0.5), plan.verifier.minutes
# (15). ARTISAN_CLAUDE_ARGS and ARTISAN_MAX_BUDGET_USD apply as in wave.sh.
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 4 outside the scope, 6 not verified
# (a failed attempt, or blocked), 8 still running, 14 the verifier failed and
# may be started again. The numbers mean what they mean in wave.sh; one table
# of every code: scripts/README.md, "Exit status".
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3, gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

DEFAULT_MODEL=claude-sonnet-5-5
DEFAULT_ESTIMATE_USD=0.5
DEFAULT_MINUTES=15
VERIFIER_TOOLS="Bash,Read,Write,Glob,Grep"
VERIFIER_FAILURES_ALLOWED=2

usage() { state_usage "$0"; }
die() { state_die 1 "verify.sh: $*"; }

# A classifier error is never a dead session: it stops the command, and the
# caller runs it again. Callers assign the result first (cls=$(classify ...)),
# so the stop is not swallowed inside another command.
classify() {
  local out= err=
  err=$(mktemp) || die "no temp file to classify $1 attempt $2"
  out=$("$SCRIPT_DIR/classify-worker.sh" "$RUN_DIR" "$1" "$2" 2>"$err") \
    || { local msg=; msg=$(cat "$err"); rm -f "$err"; die "could not classify $1 attempt $2 ($msg); nothing recorded, run it again"; }
  rm -f "$err"
  printf '%s\n' "$out"
}

# The ticket's acceptance criteria, verbatim, as a JSON array.
read_criteria() { # ticket
  local path= body=
  path=$(get --arg t "$1" '.plan.tickets[$t].ticket_path // ""')
  if [ -n "$path" ]; then
    case "$path" in /*) ;; *) path="$MAIN/$path" ;; esac
    [ -f "$path" ] || die "no ticket file $path for #$1"
    body=$(cat "$path")
  else
    body=$(gh issue view "$1" -R "$(get .repo)" --json body -q .body) \
      || die "could not read #$1 from the tracker; not verifying blind"
  fi
  printf '%s' "$body" | python3 -I "$SCRIPT_DIR/lib/criteria.py" extract
}

session_cost() { # id attempt -> the session's total_cost_usd, or nothing
  jq -r '.total_cost_usd // empty' "$RUN_DIR/workers/$1.$2/output.json" 2>/dev/null || true
}

remove_worktree() { # path: a throwaway detached checkout of a committed sha
  [ -n "$1" ] && [ -d "$1" ] || return 0
  git -C "$MAIN" worktree remove --force "$1" >/dev/null 2>&1 \
    || echo "verify.sh: could not remove the verifier's worktree $1" >&2
}

# ------------------------------------------------------------------- start

# The runner pid of verifier v, once it is up (up to 10s, as run-ticket.sh
# waits). 8 when it will not come up: its launch failed, or the start that
# claimed it ended before recording it (its claim is then cleared). Call again.
started_pid() { # ticket v
  local f="$RUN_DIR/workers/verify-$1.$2/runner.pid" claim="$RUN_DIR/verify/claims/$1.$2" i=0 rec= owner=
  while [ ! -s "$f" ]; do
    rec=$(get --arg t "$1" --argjson v "$2" '[(.tickets[$t].verifications // [])[] | select(.attempt == $v)] | last | if . == null then "none" else (.verdict // "-") end')
    [ "$rec" != error ] || state_die 8 "verify.sh: #$1's verifier $2 could not launch; start again"
    if [ "$rec" = none ]; then
      owner=$(cat "$claim/pid" 2>/dev/null || true)
      if [ ! -d "$claim" ] || { [ -n "$owner" ] && ! state_pid_alive "$owner"; }; then
        rm -rf "$claim"
        state_die 8 "verify.sh: the start that claimed #$1's verifier $2 ended without launching it; start again"
      fi
    fi
    i=$((i + 1))
    [ "$i" -le 100 ] || state_die 8 "verify.sh: #$1's verifier $2 has not come up yet; start again, or judge it"
    sleep 0.1
  done
  cat "$f"
}

cmd_start() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  "$SCRIPT_DIR/state.sh" in-scope "$RUN_DIR" "$t" || exit $?
  local n= tip=
  check_returned verify.sh "$t" "not verified"
  n=$ATTEMPT tip=$TIP

  # Idempotent per attempt: while this attempt has a verifier running, ended
  # but not judged, or judged pass, starting again launches nothing and
  # prints that verifier's runner pid. Only an error (14) starts the next.
  local last= v=
  last=$(get --arg t "$t" '(.tickets[$t].verifications // []) | last // empty
    | "\(.attempt) \(.worker_attempt) \(.verdict // "-")"')
  v=1
  if [ -n "$last" ]; then
    set -- $last
    case "$3" in
      -|pass)
        if [ "$2" = "$n" ]; then
          echo "verify.sh: #$t attempt $n already has verifier $1 (verdict $3); not starting another" >&2
          started_pid "$t" "$1"
          return 0
        fi
        if [ "$3" = - ]; then # left over from an earlier attempt, not judged
          cls=$(classify "verify-$t" "$1")
          [ "$cls" != "running -" ] || state_die 8 "verify.sh: #$t's verifier $1 is still running"
          die "#$t's verifier $1 has ended but is not judged yet; run verify.sh judge"
        fi
        ;;
    esac
    v=$(($1 + 1))
  fi
  # Two starts at once (an orchestrator's parallel Bash calls share one
  # writer pid, so the state lock does not part them): the first to claim
  # this verifier launches it; the other waits for its pid.
  # The claim holds the claimer's pid and is cleared if it ends before the
  # verifier is recorded; once recorded, the state file answers instead.
  local claim="$RUN_DIR/verify/claims/$t.$v"
  mkdir -p "$RUN_DIR/verify/claims"
  if ! mkdir "$claim" 2>/dev/null; then
    echo "verify.sh: #$t's verifier $v is being started by another call; not starting another" >&2
    started_pid "$t" "$v"
    return 0
  fi
  echo $$ >"$claim/pid"
  trap 'rm -rf "'"$claim"'"' EXIT

  local criteria= base= ib= wt= id= prompt= cfile= repo= title= path= expected= result= model= estimate= minutes= ref= suite=
  local std= checks= cout= leave= gate=
  criteria=$(read_criteria "$t")
  [ "$(printf '%s' "$criteria" | jq length)" -gt 0 ] \
    || die "#$t has no acceptance criteria (checkbox lines) to verify against"
  ib=$(get '.integration.branch')
  base=$(get --arg t "$t" '.tickets[$t].base // ""')
  [ -n "$base" ] || base=$(git -C "$MAIN" merge-base "refs/heads/$ib" "$tip") || die "no merge base between $ib and #$t's commit"
  id="verify-$t"
  wt="$WT_ROOT/$RUN_ID-$id.$v"
  mkdir -p "$WT_ROOT" "$RUN_DIR/prompts"
  [ ! -e "$wt" ] || die "the verifier's worktree $wt already exists"
  git -C "$MAIN" worktree add -q --detach "$wt" "$tip" >/dev/null 2>&1 || die "could not add the verifier's worktree $wt"

  cfile="$RUN_DIR/prompts/$id.$v.criteria.json"
  printf '%s\n' "$criteria" >"$cfile"
  repo=$(get '.repo')
  title=$(get --arg t "$t" '.plan.tickets[$t].title // "untitled"')
  path=$(get --arg t "$t" '.plan.tickets[$t].ticket_path // ""')
  expected=$(get --arg t "$t" '.plan.tickets[$t].expected_output // "see the acceptance criteria"')
  suite=$(get '.plan.suite_command // ""')
  # The recorded checks, read at the point of use from what the run has
  # merged (the integration worktree), so a worker's branch can't change the
  # checks it is judged by. Only checks.sh reads them.
  std=$(get '.integration.worktree // ""')
  [ -n "$std" ] && [ -d "$std" ] || std=$MAIN
  std="$std/CODING_STANDARDS.md"
  checks=$("$SCRIPT_DIR/checks.sh" json --file "$std") || die "could not read the recorded checks in $std"
  cout="$RUN_DIR/verify/checks/$t.$v.json"
  # On a machine whose merge gate runs on CI (merge-gate.sh), the verifier
  # leaves a recorded check that is the run's suite command to that gate, as a
  # worker does (checks.sh run --worker); it runs every other recorded check.
  gate=$("$SCRIPT_DIR/merge-gate.sh" mode) || die "could not tell this machine's merge gate mode (merge-gate.sh show)"
  if [ -n "$suite" ] && [ "$gate" = ci ]; then leave=$suite; fi
  result="$RUN_DIR/$(get --arg t "$t" '.tickets[$t].result.file // ""')"
  if [ -n "$path" ]; then ref="$path (ticket $t)"; else ref="#$t on $repo"; fi
  prompt="$RUN_DIR/prompts/$id.$v.md"
  {
    printf 'You are the verifier for ticket %s, %s: %s (attempt %s, run %s). Follow %s exactly; it is your whole brief.\n\n' \
      "$t" "$ref" "$title" "$n" "$RUN_ID" "$PLUGIN_DIR/skills/implement-plan/references/verifier.md"
    printf -- '- You are in a detached checkout of the worker'"'"'s commit %s.\n' "$tip"
    printf -- '- The diff to verify: git diff %s...%s\n' "$base" "$tip"
    printf -- '- Guardrails that apply to this ticket (an area-scoped one only if the ticket touches its area): run %s resolve --run-dir %s --ticket %s\n' \
      "$SCRIPT_DIR/guardrails.sh" "$RUN_DIR" "$t"
    printf -- '- Expected output (from the plan): %s\n' "$expected"
    printf -- '- Dependencies (such as node_modules) are installed by the project'"'"'s worktree_setup before you start. "Not found" or a missing module is a setup failure, not a code failure: say so in notes and never mark a criterion unmet for it.\n'
    [ -z "$suite" ] || printf -- '- The full suite: %s\n' "$suite"
    printf -- '- The worker'"'"'s evidence record (a claim to check, not proof): %s\n' "$result"
    if [ "$(printf '%s' "$checks" | jq -r .recorded)" = true ]; then
      printf -- '- The recorded checks (%s, `## Checks`; each proven to fail at setup). Run exactly these, from your checkout, with this one command. It writes their results where the judge reads them; a verdict without them is an error:\n' "$std"
      printf '    $ %q run%s --file %q --out %q\n' "$PLUGIN_DIR/scripts/checks.sh" \
        "$([ -z "$leave" ] || printf ' --worker --suite %q' "$leave")" "$std" "$cout"
      printf '%s' "$checks" | jq -r --arg l "$leave" '.checks[] | "    - `\(.command)`"
        + (if .command == $l then ": left to the merge gate, which runs on CI from this machine; the command skips it" else "" end)'
      printf '  A red one makes every criterion it bears on unmet: cite it in that criterion'"'"'s evidence.checks. If you can'"'"'t tie it to any criterion, every criterion is unmet.\n'
    else
      printf -- '- No recorded checks (%s). Find the project'"'"'s checks yourself (the ticket, README, build files) and run them with this command followed by -- and each command you found, one quoted argument each. It writes their results where the judge reads them and says you fell back:\n' \
        "$(printf '%s' "$checks" | jq -r .reason)"
      printf '    $ %q run --file %q --out %q\n' "$PLUGIN_DIR/scripts/checks.sh" "$std" "$cout"
      printf '  Begin your notes with "no recorded checks: found <the commands>".\n'
    fi
    printf -- '- A criterion only a person can verify (play, eyes, a real device, outside access; never one merely hard to test): mark it "met": "human" with evidence.why saying what only a person can do. It moves to a Human check and does not fail the ticket.\n'
    printf -- '- The acceptance criteria, verbatim and in order (also in %s):\n' "$cfile"
    printf '%s' "$criteria" | jq -r 'to_entries[] | "  \(.key + 1). \(.value)"'
  } >"$prompt"

  model=$(get --arg d "$DEFAULT_MODEL" '.plan.verifier.model // $d')
  estimate=$(clamp_estimate "$(get --arg d "$DEFAULT_ESTIMATE_USD" '.plan.verifier.estimate_usd // $d')")
  minutes=$(get --arg d "$DEFAULT_MINUTES" '.plan.verifier.minutes // $d')
  # Recorded before it launches, so no verifier ever runs unrecorded.
  apply '
    .tickets[$t].verifications = ((.tickets[$t].verifications // [])
      + [{attempt: $v, worker_attempt: $n, commit: $c, base: $b, model: $m, worktree: $wt, started_at: $now, verdict: null,
          checks: ($ck | {recorded, file, reason, commands: [.checks[].command | select(. != $leave)], results: $co}
                   + (if $leave != "" and ([.checks[].command] | index($leave)) != null
                      then {left_to_merge_gate: [$leave]} else {} end))}])
    | event({event: "verify", ticket: $t, attempt: $n, verifier: $v}; $now)' \
    --arg t "$t" --argjson v "$v" --argjson n "$n" --arg c "$tip" --arg b "$base" --arg m "$model" --arg wt "$wt" \
    --argjson ck "$checks" --arg co "verify/checks/$t.$v.json" --arg leave "$leave"
  trap - EXIT   # recorded: the claim stays, and the state file speaks for it
  local pid=
  # The project's worktree_setup (#173) runs before the verifier starts. A
  # failure is an error verdict with the reason "setup", not a red check.
  if ! worktree_setup "$wt"; then
    remove_worktree "$wt"
    apply '.tickets[$t].verifications[-1] |= (.verdict = "error" | .reason = $r)' --arg t "$t" --arg r "$SETUP_ERR"
    die "the verifier's worktree for #$t: $SETUP_ERR"
  fi
  read_extra_args
  if ! pid=$("$SCRIPT_DIR/run-ticket.sh" --role verifier --run-dir "$RUN_DIR" --ticket "$id" --attempt "$v" \
    --prompt-file "$prompt" --workdir "$wt" --model "$model" \
    --estimate-usd "$estimate" --expected-minutes "$minutes" \
    -- --permission-mode acceptEdits --allowedTools "$VERIFIER_TOOLS" --add-dir "$RUN_DIR" \
    ${EXTRA[@]+"${EXTRA[@]}"}); then
    remove_worktree "$wt"
    apply '.tickets[$t].verifications[-1] |= (.verdict = "error" | .reason = "could not launch")' --arg t "$t"
    die "could not launch the verifier for #$t"
  fi
  printf '%s\n' "$pid"
}

# ------------------------------------------------------------------- judge

# Moves the criteria (a JSON array) off ticket $1 into its Human check, one
# split-human-check call each; prints the Human check's number.
split_human_check() { # ticket criteria-json
  local c="" out="" hc="" n=0 i=0
  n=$(printf '%s' "$2" | jq length)
  while [ "$i" -lt "$n" ]; do
    c=$(printf '%s' "$2" | jq -r --argjson i "$i" '.[$i]')
    out=$("$SCRIPT_DIR/to-plan.sh" split-human-check --repo "$(get .repo)" "$1" "$c") \
      || die "could not split \"$c\" off #$1 into its Human check; nothing recorded, judge again"
    hc=$(printf '%s\n' "$out" | sed -n 's/^Human check #\([0-9][0-9]*\) for .*/\1/p' | tail -1)
    [ -n "$hc" ] || die "split-human-check named no Human check for #$1 ($out); judge again"
    i=$((i + 1))
  done
  printf '%s\n' "$hc"
}

# The evidence contract, from the criteria lined up with the verdict and the
# worker's claims ($acc, lib/criteria.py align), the worker's evidence record
# ($record), the verdict ($verdict) and the state file.
CONTRACT_FILTER='
  def nums: [to_entries[] | select(.key | test("^[0-9]+$")) | .value] | add // 0;
  def vers: [to_entries[] | select(.key | startswith("verify.")) | .value] | add // 0;
  . as $s | $s.tickets[$t] as $k
  | ([$acc[] | select(.met)] | length) as $met
  | ([$acc[] | select(.human == true)] | length) as $human
  | { ticket: $t,
      title: ($s.plan.tickets[$t].title // null),
      attempt: $n,
      commit: $commit,
      base: $base,
      verdict: (if $met + $human == ($acc | length) then "pass" else "fail" end),
      checks: $checks,
      criteria_met: $met,
      criteria_human: $human,
      criteria_total: ($acc | length),
      acceptance: $acc,
      tests: ($record.tests // null),
      diff: {summary: $shortstat, files: $files},
      unsure: ($record.unsure // []),
      decisions: ($record.decisions // []),
      cost: { worker_usd: (($k.attempt_costs // {}) | nums),
              verifier_usd: (($k.attempt_costs // {}) | vers),
              total_usd: ($k.cost_usd // 0),
              estimate_usd: ($s.plan.tickets[$t].estimate_usd // null) },
      verifier: { attempt: $v, model: $model,
                  unsure: ($verdict.unsure // []), notes: ($verdict.notes // null) },
      verified_at: $now }
  | if $human == 0 then .
    elif $met == 0 and .verdict == "pass"
    then .note = "Every criterion needs a human check: the verifier could show none of them, so this work passed on the Human check alone"
    else . end'

# The line judge prints for a judged verifier, and its exit status.
say_again() { # ticket
  local t="$1" line=
  line=$(get --arg t "$t" '.tickets[$t] as $k | $k.verifications[-1] as $x
    | if $x.verdict == "error" then "error \($x.reason)"
      else $k.evidence as $e
        | "\($e.verdict) \($e.criteria_met)/\($e.criteria_total)"
          + (if $e.verdict != "pass" then " \($x.next // "blocked"): \([$e.acceptance[] | select((.met | not) and .human != true) | .criterion] | first)"
             elif ($e.criteria_human // 0) == 0 then ""
             elif $e.human_check then ", \($e.criteria_human) to Human check #\($e.human_check)"
             else ", \($e.criteria_human) need a human check (no tracker ticket to split them into)" end)
      end')
  echo "$line"
  case "$line" in
    pass*) return 0 ;;
    fail*) exit 6 ;;
  esac
  [ "$(get --arg t "$t" '.tickets[$t].status')" != blocked ] || exit 6
  exit 14
}

cmd_judge() {
  open_run "${1:-}"
  local t="${2:-}"
  [ -n "$t" ] || usage
  local entry= v= n= done_verdict=
  entry=$(get --arg t "$t" '(.tickets[$t].verifications // []) | last // empty | "\(.attempt) \(.worker_attempt) \(.verdict // "-")"')
  [ -n "$entry" ] || die "no verifier has been started for #$t; run verify.sh start"
  set -- $entry
  v=$1 n=$2 done_verdict=$3
  if [ "$done_verdict" != - ]; then # judged already: say it again
    say_again "$t"
    return 0
  fi
  local id="verify-$t" cls= verdict= wt=
  cls=$(classify "$id" "$v")
  case "$cls" in running*) state_die 8 "verify.sh: #$t's verifier is still running" ;; esac
  verdict="$RUN_DIR/results/$id.$v.result.json"
  wt=$(get --arg t "$t" '.tickets[$t].verifications[-1].worktree // ""')

  local vcost= wcost=
  vcost=$(session_cost "$id" "$v")
  wcost=$(session_cost "$t" "$n")
  # Both sessions have ended: log what each cost, once.
  apply 'attempt_cost($t; $n; $w) | attempt_cost($t; "verify.\($v)"; $vc)
    | .costs.workers_usd = ([.tickets[].cost_usd // 0] | add // 0)
    | .costs.total_usd = (.costs.workers_usd + .costs.orchestrator_usd)' \
    --arg t "$t" --argjson n "$n" --argjson v "$v" \
    --argjson w "${wcost:-null}" --argjson vc "${vcost:-null}"

  local why=
  case "$cls" in
    completed*)
      jq -e '(.acceptance | type) == "array" and (.acceptance | length) > 0' "$verdict" >/dev/null 2>&1 \
        || why="the verdict is not in the evidence format"
      ;;
    *) why="the verifier ended $cls" ;;
  esac
  # The checks the verifier ran, through checks.sh run. Recorded checks it
  # didn't run make the verdict an error; with none recorded, what it found.
  local ck= cres=
  ck=$(get -c --arg t "$t" '.tickets[$t].verifications[-1].checks // {recorded: false, reason: "not read for this verifier"}')
  cres="$RUN_DIR/$(printf '%s' "$ck" | jq -r --arg d "verify/checks/$t.$v.json" '.results // $d')"
  if [ -z "$why" ] && [ "$(printf '%s' "$ck" | jq -r .recorded)" = true ] \
    && ! jq -e --argjson ck "$ck" '.recorded == true and (.results | type) == "array"
          and [.results[].command] == $ck.commands' "$cres" >/dev/null 2>&1; then
    why="the verifier did not run the recorded checks"
  fi
  if jq -e '(.results | type) == "array"' "$cres" >/dev/null 2>&1; then
    cres=$(jq -c . "$cres")
    # What the worker's evidence listed, beside what the verifier ran, so a
    # worker that ran other checks than the recorded ones is visible.
    local wrec="$RUN_DIR/$(get --arg t "$t" '.tickets[$t].result.file // ""')"
    cres=$(printf '%s' "$cres" | jq -c --slurpfile w <(jq -c '[.checks.results // [] | .[] | .command?]' "$wrec" 2>/dev/null || echo null) '
      ($w[0] // null) as $listed
      | . + {worker_listed: $listed}
      + (if .recorded and $listed != null then {worker_matches: ($listed == [.results[].command])} else {} end)')
  else
    cres=$(printf '%s' "$ck" | jq -c '{recorded: false, reason, results: [],
      fallback: "no recorded checks (\(.reason)): the verifier ran none it found"}')
  fi
  if [ -n "$why" ]; then
    remove_worktree "$wt"
    apply '.tickets[$t].verifications[-1] |= (.verdict = "error" | .reason = $r)
      | event({event: "verified", ticket: $t, attempt: $n, verifier: $v, verdict: "error", reason: $r}; $now)' \
      --arg t "$t" --argjson n "$n" --argjson v "$v" --arg r "$why"
    local errors=
    errors=$(get --arg t "$t" --argjson n "$n" '[.tickets[$t].verifications[] | select(.worker_attempt == $n and .verdict == "error")] | length')
    # The worker's work is not at fault: a verifier that keeps failing goes
    # to the Artisan, without using up an attempt.
    [ "$errors" -lt "$VERIFIER_FAILURES_ALLOWED" ] || block "$t" "the verifier failed $errors times ($why)"
    say_again "$t"
  fi

  local commit= base= record= shortstat= files= contract= acc=
  commit=$(get --arg t "$t" '.tickets[$t].verifications[-1].commit')
  base=$(get --arg t "$t" '.tickets[$t].verifications[-1].base')
  record="$RUN_DIR/$(get --arg t "$t" '.tickets[$t].result.file // ""')"
  local record_json='{"unsure": ["The worker'"'"'s evidence record was missing or unreadable, so its uncertainties and decisions are unknown"]}'
  [ ! -f "$record" ] || record_json=$(jq -c 'if type == "object" then . else error("not an object") end' "$record" 2>/dev/null || echo "$record_json")
  acc=$(python3 -I "$SCRIPT_DIR/lib/criteria.py" align "$RUN_DIR/prompts/$id.$v.criteria.json" "$verdict" "$record") \
    || die "could not line the verdict up with #$t's criteria"
  # A red recorded check: every criterion marked met that cites it is unmet;
  # one no criterion cites leaves no criterion shown met, nor any left to a
  # Human check (a broken build is not passed on to the Artisan to try).
  acc=$(printf '%s' "$acc" | jq -c --argjson res "$cres" '
    def cited: [(.evidence | objects | .checks // []) | if type == "array" then .[] else . end | objects | .command];
    if ($res.recorded | not) then . else
      [$res.results[] | select(.passed | not)] as $red
      | if ($red | length) == 0 then . else
          ([.[] | cited[]]) as $all
          | [$red[] | select(.command as $c | $all | index($c))] as $named
          | map(if .human == true and ($named | length) == 0
              then del(.human) | .evidence = ((.evidence | objects // {})
                + {why: ($red | map("recorded check `\(.command)` is red: \(.result)") | join("; "))})
            elif .met | not then . else
              cited as $mine
              | (if ($named | length) == 0 then $red else [$named[] | select(.command as $c | $mine | index($c))] end) as $hit
              | if ($hit | length) == 0 then .
                else .met = false
                  | .evidence = ((.evidence | objects // {})
                      + {why: ($hit | map("recorded check `\(.command)` is red: \(.result)") | join("; "))})
                end
            end)
        end
    end') || die "could not apply the recorded checks to #$t's criteria"
  shortstat=$(git -C "$MAIN" diff --shortstat "$base...$commit" | sed 's/^ *//')
  files=$(git -C "$MAIN" diff --numstat "$base...$commit" \
    | awk -F '\t' '{ printf "%s%s +%s -%s", (NR > 1 ? ", " : ""), $3, $1, $2 }')
  mkdir -p "$RUN_DIR/verify"
  contract="$RUN_DIR/verify/$t.$n.evidence.json"
  jq -n --arg t "$t" --argjson n "$n" --argjson v "$v" --arg commit "$commit" --arg base "$base" \
    --arg shortstat "$shortstat" --arg files "$files" --argjson now "$(state_now)" \
    --arg model "$(get --arg t "$t" '.tickets[$t].verifications[-1].model // ""')" \
    --slurpfile st "$FILE" --slurpfile verdict "$verdict" \
    --argjson acc "$acc" --argjson record "$record_json" --argjson checks "$cres" \
    '$st[0] | ($verdict[0]) as $verdict | '"$CONTRACT_FILTER" >"$contract" \
    || die "could not build the evidence contract for #$t"

  # A pass with criteria only a person can verify: they move to the agent
  # ticket's Human check first (to-plan.sh split-human-check: created, or the
  # open one added to; a repeat changes nothing) and the agent ticket says
  # so, then the verdict is recorded with it. A split or comment that fails
  # records nothing: judge again (a crash just after the comment repeats it).
  local hc="" hcrit=""
  hcrit=$(jq -c '[.acceptance[] | select(.human == true) | .criterion]' "$contract")
  if [ "$(jq -r .verdict "$contract")" = pass ] && [ "$hcrit" != "[]" ]; then
    if [ -n "$(get --arg t "$t" '.plan.tickets[$t].ticket_path // ""')" ]; then
      jq '.unsure += ["Only a person can verify \(.criteria_human) of its criteria, and it has no tracker ticket to split them from: move them into a Human check by hand"]' \
        "$contract" >"$contract.tmp" && mv "$contract.tmp" "$contract"
    else
      hc=$(split_human_check "$t" "$hcrit") || exit 1
      jq --arg hc "$hc" '.human_check = $hc' "$contract" >"$contract.tmp" && mv "$contract.tmp" "$contract"
    fi
  fi

  if [ -n "$hc" ]; then
    # Said on the agent ticket before the verdict is recorded, so a comment
    # that fails stops here and judging again posts it. Nothing is ticked for
    # them: they are the Human check's now.
    gh issue comment "$t" -R "$(get .repo)" --body "$(jq -r --arg hc "$hc" '
      "The verifier marked \(.criteria_human) of this ticket'"'"'s criteria as needing a human check (only a person can verify them), so they moved to Human check #\($hc), for the next slice gate:",
      "", (.acceptance[] | select(.human == true) | "- \(.criterion): \(.evidence.why // "no reason given")")' "$contract")" >/dev/null 2>&1 \
      || die "could not comment on #$t that its criteria moved to Human check #$hc; nothing recorded, judge again"
  fi

  apply '.tickets[$t].evidence = $ev[0]
    | .tickets[$t].verifications[-1] |= (.verdict = $ev[0].verdict)
    | event({event: "verified", ticket: $t, attempt: $n, verifier: $v, verdict: $ev[0].verdict,
             met: $ev[0].criteria_met, total: $ev[0].criteria_total}; $now)
    | reduce ($ev[0].acceptance[] | select((.met | not) and (.guardrail // "") != "")) as $c (.;
        event({event: "guardrail-fired", guardrail: $c.guardrail, ticket: $t, attempt: $n,
               criterion: $c.criterion, by: "verifier"}; $now))
    | if ($ev[0].human_check // null) == null then . else
        ($ev[0].human_check) as $h
        | .plan.scope = ((.plan.scope + [$h]) | unique)
        | .plan.tickets[$h] = ((.plan.tickets[$h] // {}) + {title: $title, human_check_for: $t})
        | (if .tickets[$h] == null then .tickets[$h] = new_ticket($h) else . end)
        | .tickets[$h].human_check = ((.tickets[$h].human_check // {state: "open"}) + {for: $t})
        | event({event: "human-check-split", ticket: $t, attempt: $n, human_check: $h,
                 criteria: [$ev[0].acceptance[] | select(.human == true) | .criterion]}; $now)
      end' \
    --arg t "$t" --argjson n "$n" --argjson v "$v" --slurpfile ev "$contract" \
    --arg title "Human check: $(get --arg t "$t" '.plan.tickets[$t].title // "#\($t)"') (#$t)"
  remove_worktree "$wt"

  if [ "$(jq -r .verdict "$contract")" = fail ]; then
    # A criterion missed is a failed attempt: a fresh worker gets the
    # verifier's findings (wave.sh dispatch), or, after the last attempt,
    # the Artisan gets the ticket.
    # The next step is kept with the verdict, so judging again says the same.
    if [ "$(get --arg t "$t" '.tickets[$t].human != null')" = true ]; then
      # A hands-on ticket is the Artisan's: no fresh worker, no attempt used.
      # It goes back to them with what the verifier found (human.sh verdict).
      apply '.tickets[$t] |= (.status = "queued" | .human.done_at = null
          | .human.feedback += [{round: $n, unmet: [$e[0].acceptance[] | select((.met | not) and .human != true) | .criterion]}])
        | .tickets[$t].verifications[-1].next = "human"
        | event({event: "human-feedback", ticket: $t, attempt: $n}; $now)' \
        --arg t "$t" --argjson n "$n" --slurpfile e "$contract"
    else
    apply 'failed_attempt($t; $r; $now)
      | .tickets[$t].verifications[-1].next = (if .tickets[$t].status == "queued" then "retry" else "blocked" end)' --arg t "$t" --arg r "$(jq -r '"the verifier found \(.criteria_total - .criteria_met - (.criteria_human // 0)) of \(.criteria_total) criteria unmet, first: \([.acceptance[] | select((.met | not) and .human != true) | .criterion] | first)"' "$contract")"
    fi
    # Work that failed is on the audit trail too: the same contract, on the ticket.
    local body="$RUN_DIR/verify/$t.$n.comment.md"
    if ! "$SCRIPT_DIR/evidence.sh" comment "$RUN_DIR" "$t" >"$body" \
      || ! gh issue comment "$t" -R "$(get .repo)" --body-file "$body" >/dev/null 2>&1; then
      echo "verify.sh: could not post the evidence on #$t; it is in the state file" >&2
    fi
  fi
  say_again "$t"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  start) cmd_start "$@" ;;
  judge) cmd_judge "$@" ;;
  *) usage ;;
esac
