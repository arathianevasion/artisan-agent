# The context drain (#59): the three bands for both tiers, the context
# percentage from a transcript, the orchestrator's PreCompact hand-off marker
# and its hand-off to a fresh orchestrator that finishes the same wave, risk
# gates that hold only their dependents, and the run digest put back after
# compaction or /resume. Fake `claude` and fake `gh`; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"
. "$PLUGIN_ROOT/scripts/lib/state-lib.sh"   # state_pid_alive

DRAIN="$PLUGIN_ROOT/scripts/drain.sh"
DIGEST="$PLUGIN_ROOT/scripts/run-digest.sh"
HOOK="$PLUGIN_ROOT/scripts/compact-hook.sh"

decide() { "$DRAIN" decide "$@"; }

# ---------------------------------------------------------------- the bands

test_the_three_bands_for_the_orchestrator() {
  # Under 30%: normal, outstanding workers or not.
  assert_eq "normal 0% dispatch" "$(decide --tier orchestrator --percent 0 --outstanding 0)"
  assert_eq "normal 29% dispatch" "$(decide --tier orchestrator --percent 29 --outstanding 3)"
  # 30% up to 50%: dispatch nothing new, keep processing, hand off once idle.
  assert_eq "drain 30% process" "$(decide --tier orchestrator --percent 30 --outstanding 2)"
  assert_eq "drain 49% process" "$(decide --tier orchestrator --percent 49 --outstanding 1)"
  assert_eq "drain 30% handoff" "$(decide --tier orchestrator --percent 30 --outstanding 0)"
  # 50% and over: the same, and every merge processed gets a risk gate.
  assert_eq "review 50% process risk-gate" "$(decide --tier orchestrator --percent 50 --outstanding 1)"
  assert_eq "review 69% handoff risk-gate" "$(decide --tier orchestrator --percent 69 --outstanding 0)"
}

test_the_three_bands_for_the_chat() {
  # The chat's outstanding agent is an orchestrator.
  assert_eq "normal 12% dispatch" "$(decide --tier chat --percent 12 --outstanding 1)"
  assert_eq "normal 12% dispatch" "$(decide --tier chat --percent 12 --outstanding 0)"
  assert_eq "drain 35% process" "$(decide --tier chat --percent 35 --outstanding 1)"
  assert_eq "drain 35% handoff" "$(decide --tier chat --percent 35 --outstanding 0)"
  assert_eq "review 55% process risk-gate" "$(decide --tier chat --percent 55 --outstanding 1)"
  assert_eq "review 55% handoff risk-gate" "$(decide --tier chat --percent 55 --outstanding 0)"
}

test_never_a_hand_off_while_agents_are_outstanding() {
  local tier= p= n= out=
  for tier in chat orchestrator; do
    for p in 0 15 30 40 50 65 90; do
      for n in 1 2 5; do
        out=$(decide --tier "$tier" --percent "$p" --outstanding "$n")
        case "$out" in *handoff*) fail "$tier at $p% with $n outstanding hands off: $out" ;; esac
      done
    done
  done
}

test_the_marker_hands_an_orchestrator_off_at_once_but_never_a_chat() {
  # PreCompact blocked compaction: finish the step and go, workers or not.
  assert_eq "compact 20% handoff" "$(decide --tier orchestrator --percent 20 --outstanding 3 --marker)"
  assert_eq "compact 72% handoff risk-gate" "$(decide --tier orchestrator --percent 72 --outstanding 3 --marker)"
  assert_eq "compact - handoff" "$(decide --tier orchestrator --percent unknown --outstanding 0 --marker)"
  # The chat has no marker: it compacts out of sight.
  assert_eq "drain 40% process" "$(decide --tier chat --percent 40 --outstanding 1 --marker)"
}

test_no_reading_counts_as_normal() {
  assert_eq "unknown - dispatch" "$(decide --tier orchestrator --percent unknown --outstanding 0)"
  assert_eq "unknown - dispatch" "$(decide --tier chat --percent unknown --outstanding 1)"
}

test_the_thresholds_are_configurable() {
  assert_eq "normal 35% dispatch" "$(decide --tier orchestrator --percent 35 --outstanding 0 --drain 40 --review 60)"
  assert_eq "drain 45% handoff" "$(decide --tier orchestrator --percent 45 --outstanding 0 --drain 40 --review 60)"
  assert_eq "review 60% process risk-gate" "$(decide --tier chat --percent 60 --outstanding 1 --drain 40 --review 60)"
}

test_decide_refuses_bad_usage() {
  assert_status 2 "$DRAIN" decide --tier host --percent 10 --outstanding 0
  assert_status 2 "$DRAIN" decide --tier chat --percent ten --outstanding 0
  assert_status 2 "$DRAIN" decide --tier chat --percent 10
}

# ------------------------------------------------------- context percentage

# usage_line tokens [model] [sidechain]: one transcript line, as Claude Code
# writes it, whose usage adds up to the given tokens.
usage_line() {
  jq -nc --argjson n "$1" --arg m "${2:-claude-sonnet-5-5}" --argjson side "${3:-false}" '{
    type: "assistant", isSidechain: $side,
    message: {model: $m, role: "assistant",
      usage: {input_tokens: 10, cache_creation_input_tokens: ($n - 1010),
              cache_read_input_tokens: 500, output_tokens: 500}}}'
}

test_the_percentage_comes_from_the_last_main_thread_usage_record() {
  local t="$TEST_TMPDIR/t.jsonl"
  {
    echo '{"type":"user","message":{"role":"user","content":"go"}}'
    usage_line 20000
    usage_line 70000
    echo 'not json at all'
    usage_line 190000 claude-sonnet-5-5 true   # a subagent's: not this context
    echo '{"type":"user","message":{"role":"user","content":"tool result"}}'
  } >"$t"
  assert_eq "35 70000 200000" "$("$DRAIN" percent --transcript "$t")"
  assert_eq "7 70000 1000000" "$(ARTISAN_CONTEXT_WINDOW=1000000 "$DRAIN" percent --transcript "$t")"
  assert_eq "70 70000 100000" "$("$DRAIN" percent --transcript "$t" --window 100000)"
}

test_the_window_is_the_large_one_for_1m_models_or_past_200k() {
  local t="$TEST_TMPDIR/t.jsonl"
  usage_line 300000 'claude-opus-5-5[1m]' >"$t"
  assert_eq "30 300000 1000000" "$("$DRAIN" percent --transcript "$t")"
  usage_line 250000 claude-opus-5-5 >"$t"
  assert_eq "25 250000 1000000" "$("$DRAIN" percent --transcript "$t")"
}

test_no_transcript_or_no_usage_is_unknown() {
  assert_eq unknown "$("$DRAIN" percent --transcript "$TEST_TMPDIR/none.jsonl")"
  echo '{"type":"user"}' >"$TEST_TMPDIR/t.jsonl"
  assert_eq unknown "$("$DRAIN" percent --transcript "$TEST_TMPDIR/t.jsonl")"
}

# ------------------------------------------------- check from the run's files

# A run r1 over tickets 10-12 with orchestrator-w1.1 recorded; its runner
# pid is a live stand-in unless told otherwise.
setup_run() {
  install_gh_stub
  init_run
  trap kill_workers EXIT
  ORCH_PID=$(start_worker)
  mkdir -p "$RUN_DIR/workers/orchestrator-w1.1" "$RUN_DIR/results"
  echo "$ORCH_PID" >"$RUN_DIR/workers/orchestrator-w1.1/runner.pid"
  "$SCRIPTS/state.sh" update "$RUN_DIR" \
    '.orchestrators = [{id: "orchestrator-w1", wave: 1, attempt: 1, launched_at: 1}]
     | .plan.config = {context: {drain_percent: 30, review_percent: 50}}'
}

test_check_reads_the_orchestrators_transcript_marker_and_workers() {
  setup_run
  local t="$TEST_TMPDIR/orch.jsonl" w=
  usage_line 80000 >"$t"
  echo "$t" >"$RUN_DIR/workers/orchestrator-w1.1/transcript.path"
  export ARTISAN_RESULT_FILE="$RUN_DIR/results/orchestrator-w1.1.result.json"
  # 40%, nothing outstanding: hand off.
  assert_eq "drain 40% handoff" "$("$DRAIN" check "$RUN_DIR")"
  # A worker in flight: keep processing.
  w=$(start_worker)
  "$SCRIPTS/state.sh" dispatch "$RUN_DIR" 10 "$w" "$(( $(date +%s) + 600 ))"
  assert_eq "drain 40% process" "$("$DRAIN" check "$RUN_DIR")"
  # A verifier not yet judged counts too.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["10"].status = "returned"
    | .tickets["10"].verifications = [{attempt: 1, verdict: null}]'
  assert_eq "drain 40% process" "$("$DRAIN" check "$RUN_DIR")"
  # The thresholds come from the run's config.
  "$SCRIPTS/state.sh" override "$RUN_DIR" context.drain_percent 45 >/dev/null
  assert_eq "normal 40% dispatch" "$("$DRAIN" check "$RUN_DIR")"
  # The PreCompact marker: hand off at once.
  echo '{}' >"$RUN_DIR/workers/orchestrator-w1.1/handoff.json"
  assert_eq "compact 40% handoff" "$("$DRAIN" check "$RUN_DIR")"
}

test_check_for_the_chat_counts_a_running_orchestrator() {
  setup_run
  local t="$TEST_TMPDIR/chat.jsonl"
  usage_line 66000 >"$t"
  assert_eq "drain 33% process" "$("$DRAIN" check "$RUN_DIR" --tier chat --transcript "$t")"
  kill -KILL "$ORCH_PID"
  wait "$ORCH_PID" 2>/dev/null || true
  assert_eq "drain 33% handoff" "$("$DRAIN" check "$RUN_DIR" --tier chat --transcript "$t")"
  usage_line 120000 >"$t"
  assert_eq "review 60% handoff risk-gate" "$("$DRAIN" check "$RUN_DIR" --tier chat --transcript "$t")"
}

test_chat_warns_above_30_and_asks_once_past_55() {
  setup_run
  local t="$TEST_TMPDIR/chatctx.jsonl" pct=
  # The window is the config's 1,000,000: 1% is 10,000 tokens.
  for pct in 2 15 30; do
    usage_line $((pct * 10000)) >"$t"
    assert_eq "ok $pct%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")" "no warning at $pct%"
  done
  for pct in 31 34 40 50 55; do
    usage_line $((pct * 10000 + 500)) >"$t"
    assert_eq "warn $pct%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")" "warning, no ask at $pct%"
  done
  # Past 55% with no compaction: ask once, then never again while it stays there.
  usage_line 570000 >"$t"
  assert_eq "warn ask 57%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")"
  assert_eq "warn 57%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")" "asked twice"
  usage_line 620000 >"$t"
  assert_eq "warn 62%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")" "asked twice"
  # A compaction drops it under the line; a later climb may ask again.
  usage_line 90000 >"$t"
  assert_eq "ok 9%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")"
  usage_line 600000 >"$t"
  assert_eq "warn ask 60%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")"
  # No reading: say nothing. The thresholds are the run's config.
  assert_eq "unknown -" "$("$DRAIN" chat "$RUN_DIR" --transcript "$TEST_TMPDIR/none.jsonl")"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.plan.config.chat_context = {warn_percent: 70}' >/dev/null
  assert_eq "ok 60%" "$("$DRAIN" chat "$RUN_DIR" --transcript "$t")"
  assert_status 2 "$DRAIN" chat "$RUN_DIR"
}

test_only_the_running_orchestrator_hands_off() {
  setup_run
  export ARTISAN_WRITER_PID=$$
  assert_status 6 "$DRAIN" handoff "$RUN_DIR"
  # And wave.sh launch --handoff is refused from anyone else.
  assert_status 6 "$SCRIPTS/wave.sh" launch "$RUN_DIR" --handoff
}

test_an_idle_orchestrator_with_nothing_left_has_nothing_to_hand_off() {
  setup_run
  export ARTISAN_WRITER_PID=$ORCH_PID
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$ORCH_PID"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets |= map_values(.status = "merged")'
  assert_eq none "$("$DRAIN" handoff "$RUN_DIR")"
  assert_eq 0 "$(state_get '[.events[]? | select(.event == "handoff")] | length')"
}

# ---------------------------------------------------------------- risk gates

# A state file from before the context-band gate was an issue holds
# tickets.<t>.risk_gate = waiting; that still holds its dependents, and
# drain.sh gate-cleared still answers it. A new merge at the band opens a
# review-gate issue instead (tests/risk-gates.test.sh).
legacy_risk_gate() { # ticket percent
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets[$t].risk_gate = {status: "waiting", percent: ($p | tonumber), at: 1}
    | .decisions += [{id: ((.decisions | length) + 1), kind: "risk-gate", ticket: $t,
        question: "old", status: "waiting", at: 1}]' --arg t "$1" --arg p "$2"
}

test_a_risk_gate_from_an_older_state_file_still_holds_only_its_dependents() {
  setup_run
  # 11 depends on 10; 12 depends on nothing.
  stub_issue 10 open; stub_issue 11 open; stub_issue 12 open
  stub_blocked_by 11 "10:open"
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 10 deadbeef
  legacy_risk_gate 10 55
  assert_status 6 "$DRAIN" gate "$RUN_DIR" 11 55   # not merged
  # The frontier keeps 12 and holds 11 back.
  assert_eq "12" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
  # Cleared: 11 joins the frontier.
  "$DRAIN" gate-cleared "$RUN_DIR" 10
  assert_eq cleared "$(state_get '.tickets["10"].risk_gate.status')"
  assert_eq decided "$(state_get '.decisions[-1].status')"
  assert_eq "11 12" "$("$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
  assert_status 6 "$DRAIN" gate-cleared "$RUN_DIR" 10
}

# ------------------------------------------------------------------- hooks

hook_input() { # event extra-json
  jq -nc --arg cwd "${HOOK_CWD:-$PWD}" --argjson x "${2:-{\}}" \
    '{session_id: "s-1", transcript_path: "/tmp/s-1.jsonl", cwd: $cwd, hook_event_name: $ARGS.positional[0]} + $x' --args "$1"
}

test_an_orchestrators_pre_compact_blocks_and_leaves_the_marker() {
  setup_run
  local rc=0 err=
  err=$(hook_input PreCompact '{"trigger":"auto"}' | ARTISAN_ROLE=orchestrator ARTISAN_RUN_DIR="$RUN_DIR" \
    ARTISAN_RESULT_FILE="$RUN_DIR/results/orchestrator-w1.1.result.json" "$HOOK" pre-compact 2>&1 >/dev/null) || rc=$?
  assert_eq 2 "$rc" "a blocking exit"
  assert_contains "$err" "hand-off marker"
  assert_eq auto "$(jq -r .trigger "$RUN_DIR/workers/orchestrator-w1.1/handoff.json")"
  assert_eq /tmp/s-1.jsonl "$(jq -r .transcript_path "$RUN_DIR/workers/orchestrator-w1.1/handoff.json")"
}

test_an_orchestrators_session_start_records_its_transcript() {
  setup_run
  local out=
  out=$(hook_input SessionStart '{"source":"startup"}' | ARTISAN_ROLE=orchestrator ARTISAN_RUN_DIR="$RUN_DIR" \
    ARTISAN_RESULT_FILE="$RUN_DIR/results/orchestrator-w1.1.result.json" "$HOOK" session-start)
  assert_eq "" "$out"
  assert_eq /tmp/s-1.jsonl "$(cat "$RUN_DIR/workers/orchestrator-w1.1/transcript.path")"
}

test_workers_and_verifiers_compact_as_usual() {
  setup_run
  local role= out=
  for role in worker verifier; do
    out=$(hook_input PreCompact '{"trigger":"auto"}' | ARTISAN_ROLE=$role ARTISAN_RUN_DIR="$RUN_DIR" \
      ARTISAN_RESULT_FILE="$RUN_DIR/results/10.1.result.json" "$HOOK" pre-compact 2>&1)
    assert_eq "" "$out" "$role"
  done
  [ ! -e "$RUN_DIR/workers/10.1/handoff.json" ] || fail "a worker left a marker"
}

test_the_chats_pre_compact_steers_the_summary_while_a_run_is_open() {
  setup_run
  local out=
  out=$(cd "$PROJECT" && HOOK_CWD="$PROJECT" hook_input PreCompact '{"trigger":"auto"}' | "$HOOK" pre-compact)
  assert_contains "$out" "Engineering chat"
  assert_contains "$out" "run r1 is open"
  assert_contains "$out" "Leave out: ticket tables"
  # No open run: nothing.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets |= map_values(.status = "merged")'
  out=$(HOOK_CWD="$PROJECT" hook_input PreCompact '{"trigger":"auto"}' | "$HOOK" pre-compact)
  assert_eq "" "$out"
}

test_the_digest_is_back_in_context_after_compaction_and_resume() {
  setup_run
  local src= out=
  mkdir -p "$PROJECT/sub"
  for src in compact resume; do
    out=$(HOOK_CWD="$PROJECT/sub" hook_input SessionStart "{\"source\":\"$src\"}" | "$HOOK" session-start)
    assert_contains "$out" "this chat's transcript is /tmp/s-1.jsonl" "$src"
    assert_contains "$out" "## Run r1 is open" "$src"
    assert_contains "$out" "| #10 (untitled) | 1 | - | queued |" "$src"
    assert_contains "$out" "### Waiting for you" "$src"
  done
  # A new session: one line pointing at implement-plan.
  out=$(HOOK_CWD="$PROJECT" hook_input SessionStart '{"source":"startup"}' | "$HOOK" session-start)
  assert_contains "$out" "run r1 is open: wave 1 running"
  assert_contains "$out" "/artisan-agent:implement-plan opens with its digest"
}

test_session_start_is_silent_outside_a_set_up_repo() {
  mkdir -p "$TEST_TMPDIR/plain"
  git_quiet -C "$TEST_TMPDIR/plain" init
  local out=
  out=$(HOOK_CWD="$TEST_TMPDIR/plain" hook_input SessionStart '{"source":"compact"}' | "$HOOK" session-start)
  assert_eq "" "$out"
  out=$(HOOK_CWD="$TEST_TMPDIR/nowhere" hook_input SessionStart '{"source":"compact"}' | "$HOOK" session-start)
  assert_eq "" "$out"
}

# --------------------------------------------------------------- the digest

test_the_digest_says_where_the_run_is_whats_waiting_and_what_changed() {
  setup_run
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 10 abcdef1234
  jq -n '{kind: "exception", ticket: "11", question: "Bypass or defer?"}' >"$TEST_TMPDIR/d.json"
  "$SCRIPTS/state.sh" decision "$RUN_DIR" "$TEST_TMPDIR/d.json"
  local out=
  out=$(cd "$PROJECT" && "$DIGEST")
  assert_contains "$out" "Where it is: wave 1 running (orchestrator attempt 1); 1 of 3 merged"
  assert_contains "$out" "| #10 (untitled) | 1 | - | merged as abcdef1, not closed yet |"
  assert_contains "$out" "| Decision | Ticket | Question |"
  assert_contains "$out" "(exception) | #11 | Bypass or defer? |"
  assert_contains "$out" "| # | Event | Ticket | Detail |"
  assert_contains "$out" "| merge | #10 | abcdef1 |"
  # Seen once: nothing new the second time, until something happens.
  out=$("$DIGEST" --repo "$PROJECT")
  assert_contains "$out" "Nothing new since you last looked."
  "$SCRIPTS/state.sh" closed "$RUN_DIR" 10
  out=$("$DIGEST" --repo "$PROJECT" --peek)
  assert_contains "$out" "| closed | #10 |"
  out=$("$DIGEST" --repo "$PROJECT")
  assert_contains "$out" "| closed | #10 |"
}

test_the_digest_line_and_no_open_run() {
  setup_run
  assert_contains "$("$DIGEST" --repo "$PROJECT" --line)" "run r1 is open: wave 1 running (orchestrator attempt 1); 0 of 3 merged, \$0 of \$20 budget; nothing waiting for you"
  [ ! -e "$RUN_DIR/.digest-seen" ] || fail "--line marked the digest seen"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets |= map_values(.status = "merged")'
  assert_eq "" "$("$DIGEST" --repo "$PROJECT")"
  assert_eq "" "$("$DIGEST" --repo "$TEST_TMPDIR")"
}

# ------------------------------------------- hand-off, end to end (two tiers)

# A one-ticket run (as wave.test.sh's) whose first orchestrator is compacted
# while its worker is in flight: the PreCompact hook blocks and leaves the
# marker, drain.sh check says hand off, drain.sh handoff launches the next
# orchestrator for the same wave and exits; the fresh one finishes the wave
# from the state file.
setup_handoff() {
  make_project
  printf '#!/bin/sh\necho "suite ok"\n' >"$PROJECT/check.sh"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "suite"
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  jq -n '{number: 1, title: "Add hello", state: "open", labels: [],
          body: "## Acceptance criteria\n- [ ] hello.txt exists"}' >"$FAKE_GH_DIR/issue-1.json"
  jq -n '{run_id: "r1", repo: "local/sample", integration_branch: "run/r1", scope: ["1"],
    waves: [["1"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh",
    orchestrator: {estimate_usd: 0.25},
    tickets: {"1": {title: "Add hello", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 5},
                    caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 120}}}}' >"$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  PATH="$TESTS_DIR/fixtures/fake-claude:$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH FAKE_CLAUDE_MODE=script FAKE_CLAUDE_LOG="$TEST_TMPDIR/fake-claude.log"

  export FAKE_CLAUDE_SCRIPT_WORKER="$TEST_TMPDIR/worker.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
# Still in flight when the first orchestrator hands off: done once drain.sh
# handoff has printed its outcome (the redirect makes the file before) (#169).
i=0
while [ ! -s "$ARTISAN_RUN_DIR/../handoff-1" ] && [ "$i" -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
echo hi >hello.txt
git add -A && git commit -q -m "worker"
jq -n --arg c "$(git rev-parse HEAD)" '{ticket: "1", status: "complete", commit: $c,
  acceptance: [{criterion: "hello.txt exists", met: true, evidence: {tests: ["check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
EOF
  export FAKE_CLAUDE_SCRIPT_VERIFIER="$TEST_TMPDIR/verifier.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
set -e
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
jq '{verdict: "pass", acceptance: [.[] | {criterion: ., met: true,
    evidence: {checks: [{command: "sh check.sh", result: "suite ok"}]}}], unsure: [], notes: "ok"}' \
  "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF
  export FAKE_CLAUDE_SCRIPT_ORCHESTRATOR="$TEST_TMPDIR/orchestrator.sh"
  cat >"$FAKE_CLAUDE_SCRIPT_ORCHESTRATOR" <<EOF
set -euo pipefail
S="$SCRIPTS"
R="\$ARTISAN_RUN_DIR"
key=\$(basename "\$ARTISAN_RESULT_FILE" .result.json)
echo "\$key" >>"\$R/../orchestrators-ran"
inflight() { jq '[.tickets[] | select(.status == "in_flight")] | length' "\$R/state.json"; }
for t in \$("\$S/reconcile.sh" "\$R"); do "\$S/wave.sh" dispatch "\$R" "\$t" >/dev/null; done
if [ "\$key" = orchestrator-w1.1 ]; then
  # Context fills; Claude Code runs the PreCompact hook before compacting.
  rc=0
  echo '{"session_id":"s-1","transcript_path":"","cwd":"'"\$PWD"'","hook_event_name":"PreCompact","trigger":"auto"}' \\
    | "$PLUGIN_ROOT/scripts/compact-hook.sh" pre-compact 2>/dev/null || rc=\$?
  echo "\$rc" >"\$R/../precompact-rc"
  # After the event: check, finish the step, hand off, exit.
  "\$S/drain.sh" check "\$R" >"\$R/../check-1"
  "\$S/drain.sh" handoff "\$R" >"\$R/../handoff-1"
  exit 0
fi
while [ "\$(inflight)" -gt 0 ]; do
  "\$S/wait-any.sh" "\$R" --timeout 5 >/dev/null || true
  "\$S/sweep.sh" "\$R"
done
"\$S/drain.sh" check "\$R" >"\$R/../check-2"
for t in \$(jq -r '.tickets | to_entries[] | select(.value.status == "returned") | .key' "\$R/state.json"); do
  n=\$(jq -r --arg t "\$t" '.tickets[\$t].attempts' "\$R/state.json")
  while [ "\$("\$S/classify-worker.sh" "\$R" "\$t" "\$n")" = "running -" ]; do sleep 0.2; done
  "\$S/verify.sh" start "\$R" "\$t" >/dev/null
  rc=8
  while [ \$rc -eq 8 ]; do rc=0; "\$S/verify.sh" judge "\$R" "\$t" >/dev/null 2>&1 || rc=\$?; [ \$rc -ne 8 ] || sleep 0.2; done
  "\$S/wave.sh" merge "\$R" "\$t" && "\$S/wave.sh" close "\$R" "\$t"
done
"\$S/wave.sh" report "\$R" >"\$ARTISAN_RESULT_FILE"
EOF
  CHAT=$(start_worker)
  export ARTISAN_WRITER_PID=$CHAT
  trap handoff_cleanup EXIT
}

handoff_cleanup() {
  kill_test_processes
  kill_workers
}

wait_for() { # path [seconds]
  local i=0 limit=$((${2:-30} * 10))
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

test_a_compacted_orchestrator_hands_off_and_a_fresh_one_finishes_the_same_wave() {
  setup_handoff
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  "$SCRIPTS/wave.sh" launch "$RUN_DIR" >/dev/null
  wait_for "$RUN_DIR/results/orchestrator-w1.2.exit.json" 60
  local runs="$TEST_TMPDIR/project/.artisan-agent/runs"
  # The first: compaction blocked, the marker left, a hand-off with its worker still in flight.
  assert_eq 2 "$(cat "$runs/precompact-rc")"
  [ -f "$RUN_DIR/workers/orchestrator-w1.1/handoff.json" ] || fail "no hand-off marker"
  assert_eq "compact - handoff" "$(cat "$runs/check-1")"
  assert_contains "$(cat "$runs/handoff-1")" "handed-off orchestrator-w1 2 "
  assert_eq "orchestrator-w1" "$(jq -r .handoff.to "$RUN_DIR/results/orchestrator-w1.1.result.json")"
  assert_eq "compaction blocked: hand-off marker" "$(state_get '.orchestrators[0].handoff.reason')"
  # The second: the same wave, told why, finished it from the state file.
  assert_eq "1 1" "$(state_get '[.orchestrators[].wave | tostring] | join(" ")')"
  assert_contains "$(cat "$RUN_DIR/prompts/orchestrator-w1.2.md")" "handed off to you (compaction blocked"
  assert_eq "completed -" "$("$SCRIPTS/classify-worker.sh" "$RUN_DIR" orchestrator-w1 2)"
  assert_eq merged "$(state_get '.tickets["1"].status')"
  assert_eq 1 "$(state_get '.tickets["1"].attempts')" "the worker in flight was never dispatched again"
  assert_eq "integration orchestrator dispatch handoff orchestrator result verify verified merge-gate merge closed" \
    "$(state_get '[.events[].event] | join(" ")')"
  # The guardrails were read once, for the wave, not again at the hand-off.
  assert_eq 1 "$(state_get '.waves | length')"
  # The chat: done, the lock back, both orchestrators' spend counted.
  local out=
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "orchestrator: completed - (wave 1, attempt 2"
  assert_contains "$out" "next: done"
  assert_eq "$CHAT" "$(readlink "$RUN_DIR/state.lock")"
  assert_eq "0.01 0.01" "$(state_get '[.orchestrators[].cost_usd | tostring] | join(" ")')"
}

test_a_waiting_risk_gate_does_not_stop_the_chat_launching() {
  setup_run
  kill -KILL "$ORCH_PID"; wait "$ORCH_PID" 2>/dev/null || true
  stub_issue 10 open; stub_issue 11 open; stub_issue 12 open
  stub_blocked_by 11 "10:open"
  "$SCRIPTS/state.sh" merge "$RUN_DIR" 10 deadbeef
  legacy_risk_gate 10 52
  local out=
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: launch"
  assert_contains "$out" "(risk-gate) | #10 |"
  # Nothing else to dispatch: the run parks on the Artisan's review (#70).
  stub_issue 12 closed
  out=$("$SCRIPTS/wave.sh" status "$RUN_DIR")
  assert_contains "$out" "next: parked"
  assert_contains "$out" "parked: waiting on 1 review: risk gate on #10; 1 ticket waits behind it: #11"
}

test_a_hand_off_whose_launch_fails_is_taken_back() {
  setup_run
  export ARTISAN_WRITER_PID=$ORCH_PID
  "$SCRIPTS/state.sh" lock "$RUN_DIR" "$ORCH_PID"
  # A halted run refuses every launch, so the next orchestrator can't start.
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.halted = {wave: 1, tickets: [], reason: "test", at: 1}'
  assert_status 1 "$DRAIN" handoff "$RUN_DIR"
  assert_eq null "$(state_get '.orchestrators[0].handoff')"
  assert_eq "handoff handoff-failed" "$(state_get '[.events[].event] | join(" ")')"
  assert_eq 1 "$(state_get '.orchestrators | length')"
}

test_the_thresholds_default_from_the_template() {
  assert_eq "drain 30% handoff" "$("$DRAIN" decide --tier chat --percent 30 --outstanding 0)"
  assert_eq "review 50% handoff risk-gate" "$("$DRAIN" decide --tier chat --percent 50 --outstanding 0)"
}
