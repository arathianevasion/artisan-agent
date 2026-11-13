# budget.sh (#72): the budget projection and the defer-only overrun gate, the
# plan-window guard at both thresholds, and the stale-reading rule. Seeded
# costs and usage readings; fake `gh` (a folder tracker), nothing reaches
# GitHub, and no worker is launched: dispatch is refused before one would be.

. "$TESTS_DIR/helpers/run-state.sh"

B="$PLUGIN_ROOT/scripts/budget.sh"
W="$PLUGIN_ROOT/scripts/wave.sh"

cleanup() {
  kill_test_processes
  kill_workers
}

# Three tickets estimated at $0.50 each: estimate $1.50, budget $1.875 (25%).
setup_budget() {
  make_project
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  local n=
  for n in 1 2 3; do
    jq -n --argjson n "$n" '{number: $n, title: "Ticket \($n)", state: "open", labels: [{name: "in-run"}], body: "x"}' \
      >"$FAKE_GH_DIR/issue-$n.json"
  done
  jq -n '
    def t($n): {title: "Ticket \($n)", estimate_usd: 0.5, expected: {minutes: 5},
                caps: {max_budget_usd: 1, max_turns: 20, deadline_seconds: 600}};
    {run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1", "2", "3"],
     waves: [["1", "2"], ["3"]], max_agents: 3, attempts_per_ticket: 2,
     estimate_usd: 1.5, budget_usd: 1.875,
     config: {overrun_allowance_percent: 25, stale_usage_minutes: 10,
              usage_reserve: {five_hour_reserve_percent: 20, seven_day_ceiling_percent: 90}},
     tickets: {"1": t(1), "2": t(2), "3": t(3)}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap cleanup EXIT
}

# Seeded spend: #1 merged at $1.20 (+140% on its $0.50, after a failed
# attempt), #2 in flight on a live worker, #3 queued. Projected: 1.20 + 0.50
# (#2 still to come) + 0.50 (#3) = $2.20, over the $1.875 budget.
seed_overrun() {
  WORKER2=$(start_worker)
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["1"] |= (.status = "merged" | .attempts = 2 | .merge_commit = "abc1234"
      | .attempt_costs = {"1": 0.7, "2": 0.5} | .cost_usd = 1.2
      | .failures = [{attempt: 1, reason: "past deadline; stopped", at: 1}]
      | .evidence = {unsure: ["The parser needed a second pass for nested input"]})
    | .tickets["2"] |= (.status = "in_flight" | .attempts = 1 | .pid = $pid | .dispatched_at = 1 | .deadline_at = 9999999999)
    | .costs = {workers_usd: 1.2, orchestrator_usd: 0, total_usd: 1.2}' --argjson pid "$WORKER2"
}

# usage_reading five-hour-% seven-day-% [age-seconds]: the capture's file.
usage_reading() {
  local t=
  t=$(( $(date +%s) - ${3:-0} ))
  jq -nc --argjson t "$t" --argjson f "$1" --argjson s "$2" '{schema_version: 1, written_at: $t,
    rate_limits: {at: $t, five_hour: {used_percentage: $f, resets_at: ($t + 7200)},
                  seven_day: {used_percentage: $s, resets_at: ($t + 259200)}}}' >"$ARTISAN_USAGE_FILE"
}

test_projection_crossing_stops_dispatch_lets_in_flight_finish_and_raises_the_overrun_gate() {
  setup_budget
  seed_overrun
  local out= st=0 p=
  p=$("$B" project "$RUN_DIR")
  assert_eq 2.2 "$(jq -r '(.projected * 100 | round) / 100' <<<"$p")" "projection: spent plus still to come"
  assert_eq true "$(jq -r .over <<<"$p")"

  out=$("$W" dispatch "$RUN_DIR" 3 2>&1) || st=$?
  assert_eq 17 "$st" "dispatch refused by the overrun gate"
  assert_contains "$out" "overrun #4"
  # The gate: a review-gate issue (the fourth in the tracker), a defer-only decision, the event.
  assert_eq "Exception gate: overrun (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-4.json")"
  assert_eq review-gate "$(jq -r '.labels[].name' "$FAKE_GH_DIR/issue-4.json")"
  assert_eq '["defer"]' "$(state_get '.decisions[] | select(.kind == "overrun") | .gate_actions | tostring')"
  assert_eq waiting "$(state_get '.decisions[] | select(.kind == "overrun") | .status')"
  assert_eq '["1"]' "$(state_get '.events[] | select(.event == "overrun-gate") | .tickets_over | tostring')"
  assert_eq queued "$(state_get '.tickets["3"].status')"

  # Work in flight is not stopped: #2's worker lives, and its result is still taken.
  kill -0 "$WORKER2" || fail "the in-flight worker was stopped"
  mkdir -p "$RUN_DIR/results"
  jq -n '{status: "complete", commit: "def5678", cost_usd: 0.4}' >"$RUN_DIR/results/2.1.result.json"
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null
  assert_eq returned "$(state_get '.tickets["2"].status')" "in-flight work finishes under the gate"

  # Asking again opens nothing new and still refuses.
  st=0; "$B" guard "$RUN_DIR" >/dev/null 2>&1 || st=$?
  assert_eq 17 "$st"
  [ ! -e "$FAKE_GH_DIR/issue-5.json" ] || fail "a second gate issue was opened"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "overrun-gate")] | length')"

  # The chat's status reports a decision, not a launch.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.frontier = ["3"]'
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "(overrun)"
}

test_within_budget_the_guard_lets_dispatch_through() {
  setup_budget
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"] |= (.status = "merged" | .cost_usd = 0.6) | .costs.total_usd = 0.6'
  local out=
  out=$("$B" guard "$RUN_DIR")
  assert_contains "$out" "ok: spent \$0.6, projected \$1.6 of \$1.875 budget"
  assert_eq 0 "$(state_get '(.overrun_gates // []) | length')"
}

test_overrun_gate_is_defer_only_with_options_complexity_and_spend_per_ticket() {
  setup_budget
  seed_overrun
  assert_status 17 "$B" guard "$RUN_DIR"
  local packet= body=
  packet=$("$B" packet "$RUN_DIR")
  body=$(jq -r .body "$FAKE_GH_DIR/issue-4.json")
  assert_eq "$packet" "$body" "the issue body is the packet"
  # Options as decision cards.
  assert_contains "$packet" "| 1 | Raise the budget | to \$2.75"
  assert_contains "$packet" "| 2 | Cut scope | #3 (\$0.50)"
  assert_contains "$packet" "| 3 | Stop |"
  # Discovered complexity as uncertainties.
  assert_contains "$packet" "## Uncertainties: discovered complexity"
  assert_contains "$packet" "#1 (Ticket 1) has cost \$1.20 against a \$0.50 estimate (+140%), 2 attempt(s); failed attempt 1: past deadline; stopped; unsure: The parser needed a second pass"
  # Spend per ticket as evidence.
  assert_contains "$packet" "| #1 | merged | \$0.50 | \$1.20 | \$0.00 | **\$0.70** |"
  assert_contains "$packet" "| #2 | in_flight | \$0.50 | \$0.00 | \$0.50 | - |"
  assert_contains "$packet" "projected \$2.20 of \$1.88"
  assert_contains "$packet" "**Defer** is the only action at this gate"

  # Only defer: approve, bypass and redirect are refused, and change nothing.
  local a= sum=
  sum=$(state_sum)
  for a in approve bypass redirect; do
    assert_status 6 "$B" overrun "$RUN_DIR" raise 3 --action "$a"
  done
  assert_eq "$sum" "$(state_sum)"
  # A raise that doesn't cover the projection is refused.
  assert_status 6 "$B" overrun "$RUN_DIR" raise 2

  local out=
  out=$("$B" overrun "$RUN_DIR" raise 2.75 --by Andrew --why "the parser was harder than sliced")
  assert_contains "$out" "deferred #4 overrun-1: raise the budget to \$2.75"
  assert_eq 2.75 "$(state_get .plan.budget_usd)"
  assert_eq '1.875 2.75' "$(state_get '.plan.budget_history[0] | "\(.from) \(.to)"')"
  assert_eq "deferred defer" "$(state_get '.overrun_gates[0] | "\(.status) \(.action)"')"
  assert_eq decided "$(state_get '.decisions[] | select(.kind == "overrun") | .status')"
  assert_eq Andrew "$(state_get '.events[] | select(.event == "overrun-decision") | .by')"
  # Deferred: the issue stays open, the decision posted on it.
  assert_eq open "$(jq -r .state "$FAKE_GH_DIR/issue-4.json")"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-4.md")" "Gate action: **defer**"
  # Dispatch carries on under the new budget.
  assert_status 0 "$B" guard "$RUN_DIR"
}

test_cut_scope_takes_queued_tickets_out_and_must_fit_the_budget() {
  setup_budget
  seed_overrun
  assert_status 17 "$B" guard "$RUN_DIR"
  assert_status 6 "$B" overrun "$RUN_DIR" cut 2      # in flight: it finishes, it can't be cut
  assert_status 6 "$B" overrun "$RUN_DIR" cut 1      # merged
  "$B" overrun "$RUN_DIR" cut 3 >/dev/null
  assert_eq '["1","2"]' "$(state_get '.plan.scope | tostring')"
  assert_eq deferred "$(state_get '.tickets["3"].status')"
  assert_eq overrun-1 "$(state_get '.tickets["3"].cut.gate')"
  assert_contains "$(cat "$FAKE_GH_DIR/comments-3.md")" "Cut from run r1 at its overrun gate (#4)"
  assert_eq "" "$(jq -r '.labels[].name | select(. == "in-run")' "$FAKE_GH_DIR/issue-3.json")"
  assert_status 0 "$B" guard "$RUN_DIR"
}

test_stop_at_the_overrun_gate_halts_the_run() {
  setup_budget
  seed_overrun
  assert_status 17 "$B" guard "$RUN_DIR"
  "$B" overrun "$RUN_DIR" stop >/dev/null
  assert_contains "$(state_get .halted.reason)" "stopped at the overrun gate"
  assert_status 12 "$B" guard "$RUN_DIR"
  assert_status 12 "$W" dispatch "$RUN_DIR" 3
  kill -0 "$WORKER2" || fail "stop must let work in flight finish"
  assert_status 6 "$B" overrun "$RUN_DIR" stop   # answered once
}

test_a_reading_older_than_ten_minutes_is_unknown_and_stops_dispatch() {
  setup_budget
  seed_running_worker
  usage_reading 10 20 $((11 * 60))
  local out= st=0
  out=$("$W" dispatch "$RUN_DIR" 1 2>&1) || st=$?
  assert_eq 18 "$st" "a stale reading stops dispatch"
  assert_contains "$out" "parked unknown"
  assert_contains "$out" "11 minutes old"
  assert_eq unknown "$(state_get .usage_park.window)"
  assert_eq '["resume","stop"]' "$(state_get '.decisions[] | select(.kind == "usage") | .options | tostring')"
  assert_eq usage "$(state_get '.events[] | select(.event == "parked") | .reason')"
  assert_eq queued "$(state_get '.tickets["1"].status')"
  # A missing file is unknown too.
  rm -f "$ARTISAN_USAGE_FILE"
  out=$("$B" usage "$RUN_DIR" || true)
  assert_contains "$out" "park unknown: no usage reading"
  # The chat's status says parked.
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked unknown"
  # Resume waits for a fresh reading under the limits, then dispatch carries on.
  "$B" park "$RUN_DIR" resume >/dev/null
  assert_status 18 "$B" guard "$RUN_DIR"
  usage_reading 10 20 $((9 * 60))
  assert_status 0 "$B" guard "$RUN_DIR"
  assert_eq null "$(state_get .usage_park)"
  assert_eq resume "$(state_get '.events[] | select(.event == "unparked") | .how')"
}

# seed_running_worker: ticket 2 is in flight on a live worker (nothing else).
seed_running_worker() {
  WORKER2=$(start_worker)
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["2"] |= (.status = "in_flight" | .attempts = 1 | .pid = $pid | .dispatched_at = 1 | .deadline_at = 9999999999)' \
    --argjson pid "$WORKER2"
}

# worker_reading ticket five-hour-% seven-day-% [age-seconds]: what a worker's
# runner records (run-ticket.sh), each window stamped with its own time.
worker_reading() {
  local t= d=$RUN_DIR/workers/$1.1
  t=$(( $(date +%s) - ${4:-0} ))
  mkdir -p "$d"
  jq -nc --argjson t "$t" --argjson f "$2" --argjson s "$3" --arg k "$1" '{source: "worker", ticket: $k, attempt: 1,
    received_at: $t, rate_limits: {five_hour: {used_percentage: $f, resets_at: ($t + 7200), at: $t},
                                   seven_day: {used_percentage: $s, resets_at: ($t + 259200), at: $t}}}' >"$d/usage.json"
}

test_a_fake_workers_rate_limit_events_are_the_guards_reading_with_no_status_line() {
  setup_budget
  rm -f "$ARTISAN_USAGE_FILE"
  printf 'Build.\n' >"$TEST_TMPDIR/prompt.md"
  mkdir -p "$TEST_TMPDIR/wt"
  local rpid= i=0
  rpid=$(PATH="$TESTS_DIR/fixtures/fake-claude:$PATH" FAKE_CLAUDE_MODE=stream FAKE_CLAUDE_SLEEP=20 \
    "$SCRIPTS/run-ticket.sh" --run-dir "$RUN_DIR" --ticket 1 --prompt-file "$TEST_TMPDIR/prompt.md" \
    --workdir "$TEST_TMPDIR/wt" --estimate-usd 0.5 --expected-minutes 5)
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["1"] |= (.status = "in_flight" | .attempts = 1 | .pid = $pid | .dispatched_at = 1 | .deadline_at = 9999999999)' --argjson pid "$rpid"
  while ! jq -e '.rate_limits.seven_day' "$RUN_DIR/workers/1.1/usage.json" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the runner recorded no reading"; sleep 0.1
  done
  local out=
  out=$("$B" usage "$RUN_DIR")
  assert_contains "$out" "ok 5h 0% 7d 29%"
  assert_eq 0 "$(state_get '.usage_park != null | if . then 1 else 0 end')"
  kill "$rpid" 2>/dev/null || true
}

test_the_freshest_reading_wins_whichever_source_it_comes_from() {
  setup_budget
  seed_running_worker
  # Status line older than the worker's reading: the worker's 85% parks.
  usage_reading 10 20 $((5 * 60))
  worker_reading 2 85 20 60
  local out= st=0
  out=$("$B" usage "$RUN_DIR") || st=$?
  assert_eq 18 "$st"
  assert_contains "$out" "park five-hour 85%"
  # The other way round: the status line is newer, so its 10% carries on.
  usage_reading 10 20 30
  worker_reading 2 85 20 $((5 * 60))
  out=$("$B" usage "$RUN_DIR")
  assert_contains "$out" "ok 5h 10% 7d 20%"
  # A stale reading from one source doesn't count while the other is fresh.
  usage_reading 99 20 $((11 * 60))
  worker_reading 2 30 40 60
  out=$("$B" usage "$RUN_DIR")
  assert_contains "$out" "ok 5h 30% 7d 40%"
}

test_workers_running_and_no_fresh_reading_parks_unknown_but_nothing_running_does_not() {
  setup_budget
  # Nothing running: a stale status line, a stale worker reading, or none at
  # all, is not a reason to park.
  usage_reading 10 20 $((30 * 60))
  worker_reading 2 10 20 $((30 * 60))
  local out=
  out=$("$B" usage "$RUN_DIR")
  assert_contains "$out" "ok no fresh usage reading"
  assert_status 0 "$B" guard "$RUN_DIR"
  rm -f "$ARTISAN_USAGE_FILE"
  assert_status 0 "$B" guard "$RUN_DIR"
  assert_eq null "$(state_get .usage_park)"
  # A worker running and every reading stale: unknown, parked.
  seed_running_worker
  out=$("$B" usage "$RUN_DIR" || true)
  assert_contains "$out" "park unknown"
  assert_contains "$out" "30 minutes old"
  assert_status 18 "$B" guard "$RUN_DIR"
  assert_eq unknown "$(state_get .usage_park.window)"
  # A worker that ended no longer counts as running.
  kill "$WORKER2"; wait "$WORKER2" 2>/dev/null || true
  rm -f "$RUN_DIR"/workers/*/usage.json
  out=$("$B" usage "$RUN_DIR")
  assert_contains "$out" "ok no fresh usage reading"
}

test_a_nine_minute_old_reading_is_fresh() {
  setup_budget
  usage_reading 10 20 $((9 * 60))
  assert_status 0 "$B" guard "$RUN_DIR"
}

test_five_hour_window_within_the_reserve_parks_with_resume_time_raise_and_stop() {
  setup_budget
  usage_reading 79.9 20
  assert_status 0 "$B" guard "$RUN_DIR"
  usage_reading 80 20
  local out= st=0 when=
  out=$("$B" guard "$RUN_DIR") || st=$?
  assert_eq 18 "$st"
  when=$(jq -r '.rate_limits.five_hour.resets_at | strflocaltime("%a %d %b %H:%M %Z")' "$ARTISAN_USAGE_FILE")
  assert_contains "$out" "parked five-hour 80% (limit 80%): the five-hour window is within the 20% reserve; resets $when"
  assert_eq '["resume","raise","stop"]' "$(state_get '.decisions[] | select(.kind == "usage") | .options | tostring')"
  assert_contains "$(state_get '.decisions[] | select(.kind == "usage") | .question')" "Resume after the reset ($when), raise the ceiling, or stop?"
  # Resume: still over, so it waits for the reset; a fresh low reading carries on.
  out=$("$B" park "$RUN_DIR" resume)
  assert_contains "$out" "the window resets $when"
  assert_status 18 "$B" guard "$RUN_DIR"
  usage_reading 5 20
  assert_status 0 "$B" guard "$RUN_DIR"
  # Parked again, then the ceiling raised: a run override, carries on at once.
  usage_reading 85 20
  assert_status 18 "$B" guard "$RUN_DIR"
  assert_status 6 "$B" park "$RUN_DIR" raise 75
  out=$("$B" park "$RUN_DIR" raise 95)
  assert_contains "$out" "resumed: ok 5h 85%"
  assert_eq 5 "$(state_get .plan.config.usage_reserve.five_hour_reserve_percent)"
  assert_eq 20 "$(state_get .plan.overrides.\"usage_reserve.five_hour_reserve_percent\".project)"
  assert_status 0 "$B" guard "$RUN_DIR"
}

test_seven_day_window_past_ninety_parks_and_stop_halts_the_run() {
  setup_budget
  usage_reading 10 90
  assert_status 0 "$B" guard "$RUN_DIR"
  usage_reading 10 90.5
  local out= st=0 when=
  out=$("$W" dispatch "$RUN_DIR" 1 2>&1) || st=$?
  assert_eq 18 "$st"
  when=$(jq -r '.rate_limits.seven_day.resets_at | strflocaltime("%a %d %b %H:%M %Z")' "$ARTISAN_USAGE_FILE")
  assert_contains "$out" "parked seven-day 90% (limit 90%): the seven-day window passed 90%; resets $when"
  assert_contains "$(state_get '.decisions[] | select(.kind == "usage") | .question')" "Resume after the reset ($when), raise the ceiling, or stop?"
  "$B" park "$RUN_DIR" stop >/dev/null
  assert_contains "$(state_get .halted.reason)" "stopped at the usage guard"
  assert_eq stop "$(state_get '.decisions[] | select(.kind == "usage") | .choice')"
  assert_status 12 "$B" guard "$RUN_DIR"
}

test_seven_day_raise_ceiling_resumes() {
  setup_budget
  usage_reading 10 93
  assert_status 18 "$B" guard "$RUN_DIR"
  assert_status 6 "$B" park "$RUN_DIR" raise 90
  "$B" park "$RUN_DIR" raise 95 >/dev/null
  assert_eq 95 "$(state_get .plan.config.usage_reserve.seven_day_ceiling_percent)"
  assert_eq ceiling-raised "$(state_get '.events[] | select(.event == "ceiling-raised") | .event')"
  assert_status 0 "$B" guard "$RUN_DIR"
}

test_a_window_past_its_reset_counts_as_empty() {
  setup_budget
  local t=
  t=$(date +%s)
  jq -nc --argjson t "$t" '{rate_limits: {at: $t, five_hour: {used_percentage: 99, resets_at: ($t - 5)}, seven_day: null}}' \
    >"$ARTISAN_USAGE_FILE"
  assert_status 0 "$B" guard "$RUN_DIR"
}

# ---------------------------------------------- the guard's home (#120)

# tracker_sum: a checksum of every file the fake tracker holds.
# (Not the call log: reading is allowed, and test_status... checks for writes.)
tracker_sum() { (cd "$FAKE_GH_DIR" && find . -type f ! -name calls | sort | xargs cat | cksum); }

test_status_only_reads_with_a_guard_condition_that_would_park_or_open_the_gate() {
  setup_budget
  seed_overrun
  usage_reading 85 20
  # Both the usage park and the overrun gate are due; status must do neither.
  local before= tb= out=
  "$W" status "$RUN_DIR" >/dev/null 2>&1 || true   # settle whatever the reconciler normalises
  before=$(cat "$RUN_DIR/state.json")
  tb=$(tracker_sum)
  out=$("$W" status "$RUN_DIR" 2>&1 || true)
  assert_eq "$before" "$(cat "$RUN_DIR/state.json")" "status left the state file unchanged"
  assert_eq "$tb" "$(tracker_sum)" "status left the tracker unchanged"
  assert_not_contains "$(cat "$FAKE_GH_DIR/calls")" "--method" "status made no write call on the tracker"
  assert_eq null "$(state_get .usage_park)"
  assert_eq 0 "$(state_get '(.overrun_gates // []) | length')"
  assert_contains "$out" "usage guard: not run yet"
  assert_not_contains "$out" "next: parked"
}

test_the_sweep_runs_the_guard_and_parks_and_status_then_shows_its_last_verdict() {
  setup_budget
  usage_reading 85 20
  local out= when=
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null 2>"$TEST_TMPDIR/sweep.err"
  assert_contains "$(cat "$TEST_TMPDIR/sweep.err")" "parked five-hour 85%"
  assert_eq five-hour "$(state_get .usage_park.window)"
  assert_eq usage "$(state_get '.events[] | select(.event == "parked") | .reason')"
  assert_eq waiting "$(state_get '.decisions[] | select(.kind == "usage") | .status')"
  # Status reads what the sweep left: parked, and the verdict with its time.
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked five-hour: the five-hour window is within the 20% reserve"
  when=$(state_get '.usage_verdict.at | strflocaltime("%a %d %b %H:%M %Z")')
  assert_contains "$out" "usage guard: last verdict \"park five-hour 85%"
  assert_contains "$out" "taken $when"
  # Status itself neither unparks nor re-parks: one park, one event.
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked")] | length')"
}

test_the_sweep_opens_the_overrun_gate_as_before() {
  setup_budget
  seed_overrun
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null 2>"$TEST_TMPDIR/sweep.err"
  assert_contains "$(cat "$TEST_TMPDIR/sweep.err")" "overrun #4"
  assert_eq "Exception gate: overrun (run r1)" "$(jq -r .title "$FAKE_GH_DIR/issue-4.json")"
  assert_eq waiting "$(state_get '.decisions[] | select(.kind == "overrun") | .status')"
}

test_the_reconciler_and_findings_sweeps_do_not_run_the_guard() {
  setup_budget
  usage_reading 85 20
  "$SCRIPTS/reconcile.sh" "$RUN_DIR" >/dev/null 2>&1 || true
  assert_eq null "$(state_get .usage_park)"
}

# A mv that logs each write of the state file and can fail the nth and later.
mv_shim() { # dir fail-after
  mkdir -p "$1"
  cat >"$1/mv" <<SH
#!/bin/sh
for a in "\$@"; do last=\$a; done
case "\$last" in
  */state.json)
    n=\$(cat "$1/count" 2>/dev/null || echo 0)
    if [ "\$n" -ge "$2" ]; then echo "mv: simulated failure" >&2; exit 1; fi
    echo \$((n + 1)) >"$1/count"; echo "\$@" >>"$1/log" ;;
esac
exec /bin/mv "\$@"
SH
  chmod +x "$1/mv"
}

test_park_raise_is_one_state_write_and_a_failure_leaves_the_state_as_it_was() {
  setup_budget
  usage_reading 85 20
  assert_status 18 "$B" guard "$RUN_DIR"
  local before= out= st=0 p=$PATH
  before=$(cat "$RUN_DIR/state.json")
  # A write that fails: nothing of the raise lands, neither override nor answer.
  mv_shim "$TEST_TMPDIR/shim-fail" 0
  PATH="$TEST_TMPDIR/shim-fail:$p" "$B" park "$RUN_DIR" raise 95 >/dev/null 2>&1 || st=$?
  [ "$st" -ne 0 ] || fail "the raise should fail when its write fails"
  assert_eq "$before" "$(cat "$RUN_DIR/state.json")" "a failed raise leaves the state as it was"
  # A write that fails after the first: the raise needs only one, so it lands whole.
  mv_shim "$TEST_TMPDIR/shim-one" 1
  out=$(PATH="$TEST_TMPDIR/shim-one:$p" "$B" park "$RUN_DIR" raise 95)
  assert_eq 1 "$(cat "$TEST_TMPDIR/shim-one/count")" "exactly one state write"
  assert_contains "$out" "resumed: ok 5h 85%"
  assert_eq 5 "$(state_get .plan.config.usage_reserve.five_hour_reserve_percent)"
  assert_eq null "$(state_get .usage_park)"
  assert_eq ceiling-raised "$(state_get '.events[] | select(.event == "ceiling-raised") | .event')"
  assert_eq raise "$(state_get '.events[] | select(.event == "unparked") | .how')"
}

test_a_raise_that_does_not_clear_the_reading_records_the_answer_in_one_write() {
  setup_budget
  usage_reading 85 20
  assert_status 18 "$B" guard "$RUN_DIR"
  mv_shim "$TEST_TMPDIR/shim-one" 1
  local out=
  out=$(PATH="$TEST_TMPDIR/shim-one:$PATH" "$B" park "$RUN_DIR" raise 84 2>&1) || fail "raise: $out"
  assert_eq 1 "$(cat "$TEST_TMPDIR/shim-one/count")"
  assert_contains "$out" "resume recorded"
  assert_eq 16 "$(state_get .plan.config.usage_reserve.five_hour_reserve_percent)"
  assert_eq true "$(state_get '.usage_park.resume != null')"
}

test_launch_runs_the_guard_between_waves_and_a_park_refuses_it() {
  setup_budget
  "$W" start "$RUN_DIR" >/dev/null
  usage_reading 85 20
  local out= st=0
  out=$("$W" launch "$RUN_DIR" 2>&1) || st=$?
  assert_eq 18 "$st" "launch is where the guard runs when no orchestrator's sweep does"
  assert_contains "$out" "parked five-hour 85%"
  assert_eq five-hour "$(state_get .usage_park.window)"
  assert_eq usage "$(state_get '.events[] | select(.event == "parked") | .reason')"
  assert_eq 0 "$(state_get '(.orchestrators // []) | length')" "no orchestrator was launched"
}

test_launch_opens_the_overrun_gate_and_refuses() {
  setup_budget
  "$W" start "$RUN_DIR" >/dev/null
  seed_overrun
  local st=0
  "$W" launch "$RUN_DIR" >/dev/null 2>&1 || st=$?
  assert_eq 17 "$st"
  assert_eq 1 "$(state_get '(.overrun_gates // []) | length')"
}

# A run parked on usage while it also waits behind an open review (#70, #72):
# one `parked` event per reason, both reasons in status, and clearing one
# leaves the run parked on the other.
seed_waiting_on_a_review() {
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["1"] |= (.status = "merged" | .merge_commit = "abc1234")
    | .frontier = []
    | .review_gates = [{id: "g1", kind: "slice", title: "Slice gate: greeting (run r1)", issue: 9, status: "open"}]'
  jq -n '{number: 9, title: "Slice gate: greeting (run r1)", state: "open", labels: [{name: "review-gate"}], body: "x"}' \
    >"$FAKE_GH_DIR/issue-9.json"
  echo '[9]' >"$FAKE_GH_DIR/blocked_by-2.json"
  echo '[9]' >"$FAKE_GH_DIR/blocked_by-3.json"
}

test_a_run_parked_on_usage_and_on_reviews_names_both_logs_each_once_and_clears_one_at_a_time() {
  setup_budget
  seed_waiting_on_a_review
  local out= n=
  # Reviews alone first.
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked: waiting on 1 review: Slice gate: greeting (run r1) #9"
  # The usage park arrives (the sweep's guard).
  usage_reading 85 20
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null 2>&1
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "parked five-hour: the five-hour window is within the 20% reserve"
  assert_contains "$out" "parked: waiting on 1 review: Slice gate: greeting (run r1) #9"
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)   # asking again adds nothing
  "$W" status "$RUN_DIR" >/dev/null 2>&1 || true
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked" and .reason == "usage")] | length')" "one usage park event"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked" and .reason == "reviews")] | length')" "one reviews park event"
  # Clear the usage park (a lower reading and a resume): still parked on the review.
  "$B" park "$RUN_DIR" resume >/dev/null
  usage_reading 5 20
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null 2>&1
  assert_eq null "$(state_get .usage_park)"
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "next: parked"
  assert_not_contains "$out" "parked five-hour"
  assert_contains "$out" "parked: waiting on 1 review"
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked" and .reason == "reviews")] | length')" "the review park is not logged again"
  # And the other way: usage again, then the review closes: parked on usage alone.
  usage_reading 85 20
  "$SCRIPTS/sweep.sh" "$RUN_DIR" >/dev/null 2>&1
  jq '.state = "closed"' "$FAKE_GH_DIR/issue-9.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-9.json"
  out=$("$W" status "$RUN_DIR" 2>/dev/null || true)
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked five-hour"
  assert_not_contains "$out" "waiting on 1 review"
}
