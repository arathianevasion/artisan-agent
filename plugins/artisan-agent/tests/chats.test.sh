# chats.sh: the Engineering and Product chats through the tracker (#73).
# A fake `gh` over a folder tracker; nothing reaches GitHub.

. "$TESTS_DIR/helpers/run-state.sh"

C="$SCRIPTS/chats.sh"

setup_chats() {
  init_run '["1","2"]' '{"1": {"caps": {"deadline_seconds": 3600}}, "2": {"caps": {"deadline_seconds": 3600}}}'
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH
  # Guardrails and the plugin cache are throwaway, never the machine's.
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/teamcache"
  export ARTISAN_PLUGIN_VERSIONS_DIR="$TEST_TMPDIR/plugin-cache"
  mkdir -p "$ARTISAN_HOME" "$ARTISAN_PLUGIN_VERSIONS_DIR"
  git_quiet -C "$ARTISAN_HOME" init
  git -C "$ARTISAN_HOME" symbolic-ref HEAD refs/heads/main
  : >"$ARTISAN_HOME/guardrails.jsonl"
  git_quiet -C "$ARTISAN_HOME" add -A
  git_quiet -C "$ARTISAN_HOME" commit -m "home init"
  cd "$PROJECT"
  export ARTISAN_REPO=local/sample
}

ticket() { # number [label...]
  local n=$1 labels='[]' l=
  shift
  for l in "$@"; do labels=$(jq -c --arg l "$l" '. + [{name: $l}]' <<<"$labels"); done
  jq -n --argjson n "$n" --argjson l "$labels" '{number: $n, title: "Ticket \($n)", state: "open", labels: $l, body: "body"}' >"$FAKE_GH_DIR/issue-$n.json"
}

gate_issue() { # number title role
  jq -n --argjson n "$1" --arg t "$2" --arg r "$3" '{number: $n, title: $t, state: "open", labels: [{name: "review-gate"}],
    body: "# \($t)\n\n| Gate | Role needed | Slice | Tickets blocked |\n|---|---|---|---|\n| slice | \($r) | #1 | #2 |\n\nbody"}' >"$FAKE_GH_DIR/issue-$1.json"
}

sweep() { "$C" sweep --no-fetch "$@"; }

test_send_to_engineering_creates_a_plan_issue_with_those_sub_issues() {
  setup_chats
  ticket 345
  ticket 346
  local plan=
  plan=$("$C" send 345 346)
  assert_eq 347 "$plan"
  assert_contains "$(jq -r '.labels[].name' "$FAKE_GH_DIR/issue-347.json")" plan
  assert_contains "$(jq -r .title "$FAKE_GH_DIR/issue-347.json")" "#345, #346"
  assert_eq "[345,346]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-347.json")"
  # A repeat does not pile up a second plan.
  assert_eq 347 "$("$C" send 345 346)"
  # What resolve-scope reads back.
  assert_contains "$("$SCRIPTS/resolve-scope.sh" --repo local/sample 347)" '"number": 345'
}

test_a_send_whose_link_fails_warns_then_the_next_sweep_links_it() {
  setup_chats
  ticket 345
  ticket 346
  # 345 already has a parent, so the link fails like GitHub's.
  echo 99 >"$FAKE_GH_DIR/parent-345"
  local plan= err="$TEST_TMPDIR/send.err" st=0
  plan=$("$C" send 345 346 2>"$err") || st=$?
  assert_eq 0 "$st" "a failed link does not fail the send"
  assert_eq 347 "$plan"
  assert_contains "$(cat "$err")" "#345 could not be made a sub-issue of #347"
  assert_eq "[346]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-347.json")"
  # The parent goes away; the next sweep links the message issue's missing sub-issue.
  rm "$FAKE_GH_DIR/parent-345"
  sweep >/dev/null
  assert_eq "[346,345]" "$(jq -c . "$FAKE_GH_DIR/sub_issues-347.json")"
}

test_send_refuses_a_ticket_already_in_a_run() {
  setup_chats
  ticket 345 in-run
  local st=0
  "$C" send 345 >"$TEST_TMPDIR/out" 2>&1 || st=$?
  assert_eq 6 "$st"
  assert_contains "$(cat "$TEST_TMPDIR/out")" "already in run"
}

test_the_engineering_chat_picks_up_a_sent_plan_on_its_next_sweep() {
  setup_chats
  ticket 345
  "$C" send 345 >/dev/null
  local out=
  out=$(sweep)
  assert_contains "$out" "## Plans waiting for Engineering"
  assert_contains "$out" "#346 (Plan: send #345 to engineering)"
  assert_contains "$out" "ACTION start-plan 346 approve-envelope"
}

test_the_product_chat_refuses_to_triage_edit_or_relabel_an_in_run_ticket() {
  setup_chats
  ticket 1
  ticket 2 needs-triage
  "$C" guard 2
  "$C" label-run "$RUN_DIR"
  assert_contains "$(jq -r '.labels[].name' "$FAKE_GH_DIR/issue-1.json")" in-run
  # The run id is in a comment, once, even if the label step is repeated.
  "$C" label-run "$RUN_DIR"
  assert_eq 1 "$(grep -c "artisan-agent:run r1" "$FAKE_GH_DIR/comments-1.md")"
  local st=0 out=
  out=$("$C" guard 1 2>&1) || st=$?
  assert_eq 6 "$st"
  assert_contains "$out" "#1 is in run r1"
  assert_contains "$out" "doesn't triage, edit or relabel"
}

test_a_plan_approved_before_it_was_queued_starts_without_asking_again() {
  setup_chats
  ticket 345
  local plan= out=
  plan=$("$C" send 345)
  "$C" approve-envelope "$plan"
  "$C" approve-envelope "$plan"
  assert_eq 1 "$(grep -c "envelope-approved" "$FAKE_GH_DIR/comments-$plan.md")"
  out=$(sweep)
  assert_contains "$out" "ACTION start-plan $plan envelope-approved"
  case "$out" in *"approve-envelope"*) fail "asked for an approval already given" ;; esac
}

test_queued_plans_wait_for_the_lock_then_start_oldest_first() {
  setup_chats
  ticket 345
  ticket 346
  local a= b= out= holder=
  a=$("$C" send 345)
  b=$("$C" send 346)
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" >"$TEST_TMPDIR/.holder"
  ln -s "$holder" "$RUN_DIR/state.lock"
  out=$(sweep)
  assert_contains "$out" "queued behind the run lock"
  case "$out" in *"ACTION start-plan"*) fail "started a plan while the lock was held" ;; esac
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(sweep)
  assert_contains "$out" "ACTION start-plan $a approve-envelope"
  assert_contains "$out" "queued behind #$a"
  case "$out" in *"ACTION start-plan $b"*) fail "started the younger plan first" ;; esac
}

test_a_plan_blocked_by_an_open_plan_does_not_start() {
  setup_chats
  ticket 345
  ticket 346
  local a= b=
  a=$("$C" send 345)
  b=$("$C" send 346)
  echo "[$a]" >"$FAKE_GH_DIR/blocked_by-$b.json"
  # Only the earlier plan may start; the later one names its blocker.
  assert_contains "$(sweep)" "ACTION start-plan $a"
}

test_a_sweep_lists_open_gates_batched_by_job_and_role() {
  setup_chats
  gate_issue 20 "Slice gate: export (run r1)" "Engineering (QA)"
  gate_issue 21 "Slice gate: billing (run r2)" "Engineering (QA)"
  gate_issue 22 "Slice gate: design (run r2)" "Product"
  local out=
  out=$(sweep)
  assert_contains "$out" "| Role | Job | Gates | Waiting |"
  assert_contains "$out" "| Engineering (QA) | 13 Check a finished slice at a review gate | #20 (slice: export, run r1); #21 (slice: billing, run r2) | 2 |"
  assert_contains "$out" "| Product | 13 Check a finished slice at a review gate | #22 (slice: design, run r2) | 1 |"
  # A pair splitting the roles: each sees only their role's gates.
  out=$(sweep --role Product)
  assert_contains "$out" "#22 (slice: design, run r2)"
  case "$out" in *"#20 (slice"*) fail "the Product role saw an Engineering gate" ;; esac
  # Both chats see the same gates, from the tracker.
  assert_contains "$(sweep --chat product)" "#20 (slice: export, run r1)"
  # And `gate.sh list` reads the tracker too, with no run folder at all.
  assert_contains "$("$SCRIPTS/gate.sh" list)" "#22 (slice: design, run r2)"
}

test_a_sweep_announces_a_guardrail_change_and_a_new_plugin_version_once() {
  setup_chats
  mkdir -p "$ARTISAN_PLUGIN_VERSIONS_DIR/$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  local out=
  out=$(sweep)
  case "$out" in *"## Changes"*) fail "announced a change on the first sweep" ;; esac
  printf '{"id":"ind-1"}\n' >"$ARTISAN_HOME/guardrails.jsonl"
  git_quiet -C "$ARTISAN_HOME" add -A
  git_quiet -C "$ARTISAN_HOME" commit -m "tighten"
  mkdir -p "$ARTISAN_PLUGIN_VERSIONS_DIR/99.0.0"
  out=$(sweep)
  assert_contains "$out" "The individual guardrails changed"
  assert_contains "$out" "apply from the next wave"
  assert_contains "$out" "A new plugin version is installed: 99.0.0"
  out=$(sweep)
  case "$out" in *"## Changes"*) fail "announced the same change twice" ;; esac
}

test_a_gate_closed_on_github_is_announced_in_one_line_by_either_chat() {
  setup_chats
  jq -n '{number: 30, title: "Slice gate: export (run r1)", state: "closed", labels: [{name: "review-gate"}], body: "x"}' >"$FAKE_GH_DIR/issue-30.json"
  printf 'Gate #30 closed on GitHub: treated as approved; 3 undecided cards carried to the end gate\n\n<!-- artisan-agent:gate-closed-by-hand carried=3 -->' >"$FAKE_GH_DIR/comments-30.md"
  local out=
  out=$(sweep --chat product)
  assert_contains "$out" "Gate #30 closed on GitHub: treated as approved; 3 undecided cards carried to the end gate"
  out=$(sweep --chat product)
  case "$out" in *"Gate #30 closed"*) fail "announced twice" ;; esac
  # The Engineering chat keeps its own memory.
  assert_contains "$(sweep)" "Gate #30 closed on GitHub"
}

test_a_waiting_decision_notifies_only_when_the_terminal_is_idle_and_only_once() {
  setup_chats
  gate_issue 20 "Slice gate: export (run r1)" "Engineering (QA)"
  case "$(sweep)" in *"notify:"*) fail "notified while the Artisan was at the terminal" ;; esac
  assert_contains "$(sweep --idle)" "notify: Artisan Agent: 1 review gate(s) waiting"
  case "$(sweep --idle)" in *"notify:"*) fail "notified twice for the same gate" ;; esac
  gate_issue 21 "Slice gate: billing (run r1)" "Engineering (QA)"
  assert_contains "$(sweep --idle)" "notify: Artisan Agent: 2 review gate(s) waiting"
}

test_a_plan_waiting_for_its_envelope_notifies_when_idle() {
  setup_chats
  ticket 345
  "$C" send 345 >/dev/null
  assert_contains "$(sweep --idle)" "needs its run envelope approved"
}

test_the_product_chat_never_reads_a_run_state_file() {
  setup_chats
  "$SCRIPTS/state.sh" decision "$RUN_DIR" <(echo '{"id":1,"kind":"exception","question":"q","status":"waiting"}') >/dev/null
  assert_contains "$(sweep)" "Run r1 has 1 decision(s) waiting"
  case "$(sweep --chat product --idle)" in *"decision(s) waiting"*) fail "the Product chat read the run's state file" ;; esac
}

test_an_orchestrators_unclean_exit_notifies_at_once_naming_its_cause() {
  setup_chats
  echo '{"kind":"orchestrator-exit","cause":"error_max_turns","wave":2,"tickets":["217"],"question":"q"}' >"$TEST_TMPDIR/d.json"
  "$SCRIPTS/state.sh" decision "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  local out=""
  # At the terminal, not idle: still notified (#171).
  out=$(sweep)
  assert_contains "$out" "- Run r1: the orchestrator for wave 2 exited without finishing it (error_max_turns: #217)."
  assert_contains "$out" "notify: Artisan Agent: 1 decision(s) waiting in run r1; run r1: the orchestrator for wave 2 exited without finishing it (error_max_turns: #217)"
  case "$(sweep --idle)" in *"notify:"*) fail "notified twice for the same exit" ;; esac
}

test_due_follows_the_sweep_interval() {
  setup_chats
  ARTISAN_NOW=1000 "$C" due
  ARTISAN_NOW=1000 sweep >/dev/null
  assert_status 1 env ARTISAN_NOW=1200 "$C" due
  assert_status 0 env ARTISAN_NOW=1301 "$C" due
}

test_a_run_started_through_implement_plan_labels_every_ticket_once() {
  setup_chats
  ticket 1
  ticket 2
  "$C" label-run "$RUN_DIR"
  "$C" label-run "$RUN_DIR"
  for t in 1 2; do
    assert_contains "$(jq -r '.labels[].name' "$FAKE_GH_DIR/issue-$t.json")" in-run
    assert_eq 1 "$(grep -c "artisan-agent:run r1" "$FAKE_GH_DIR/comments-$t.md")"
  done
}

test_a_plan_started_at_once_records_no_envelope_approval() {
  # Nothing but approve-envelope writes the mark, and a started plan never calls it.
  setup_chats
  ticket 345
  local plan= out=
  plan=$("$C" send 345)
  assert_eq 0 "$(cat "$FAKE_GH_DIR"/comments-"$plan".md 2>/dev/null | grep -c "envelope-approved" || true)"
  out=$(sweep)
  assert_contains "$out" "ACTION start-plan $plan approve-envelope"
}

test_the_skills_name_each_call_inside_the_step_that_makes_it() {
  local ip= tp= step3= step6= step5=
  ip="$PLUGIN_ROOT/skills/implement-plan/SKILL.md"
  tp="$PLUGIN_ROOT/skills/to-plan/SKILL.md"
  step3=$(awk '/^### 3\./{f=1;next} /^### 4\./{f=0} f' "$ip")
  assert_contains "$step3" "chats.sh approve-envelope"
  assert_contains "$step3" "ACTION start-plan <issue> envelope-approved"
  assert_contains "$step3" "chats.sh label-run"
  assert_contains "$step3" "before the first wave launches"
  step5=$(awk '/^### 5\. Get approval/{f=1;next} /^### 6\./{f=0} f' "$tp")
  assert_contains "$step5" "chats.sh approve-envelope"
}
