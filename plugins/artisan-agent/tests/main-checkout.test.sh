# Main-checkout protection and the one-run-per-repo lock: the plugin hook
# (guard/protect.sh), its generated wiring, and the two fallbacks that work
# with the plugin hook disabled (git pre-commit hook, run-lock.sh check).

PROTECT="$PLUGIN_ROOT/guard/protect.sh"
ST="$PLUGIN_ROOT/scripts/state.sh"
RL="$PLUGIN_ROOT/scripts/run-lock.sh"
GUARD="$PLUGIN_ROOT/guard/guard.sh"

gq() { git -c init.defaultBranch=main -c user.name=T -c user.email=t@example.invalid "$@" >/dev/null 2>&1; }

# make_repo: $REPO is a main checkout that has adopted the pipeline.
make_repo() {
  REPO="$TEST_TMPDIR/repo"
  mkdir -p "$REPO/.artisan-agent"
  gq -C "$REPO" init
  printf '.artisan-agent/runs/\n' >"$REPO/.gitignore"
  printf 'max_agents: 5\n' >"$REPO/.artisan-agent/config.yml"
  printf 'one\n' >"$REPO/doc.md"
  gq -C "$REPO" add -A
  gq -C "$REPO" commit -m init
}

# stub_gh: a gh on PATH that records its arguments and holds issues in a file.
stub_gh() {
  mkdir -p "$TEST_TMPDIR/bin"
  GH_LOG="$TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  cat >"$TEST_TMPDIR/bin/gh" <<EOT
#!/bin/bash
printf '%s\n' "\$*" >>"$GH_LOG"
case "\$1 \$2" in
  "issue list") cat "$TEST_TMPDIR/issues" 2>/dev/null; exit 0 ;;
  "issue create") t=""; while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t=\$2; shift; done
                  printf '%s\n' "\$t" >>"$TEST_TMPDIR/issues"; echo "https://example.invalid/issues/1"; exit 0 ;;
esac
exit 1
EOT
  chmod +x "$TEST_TMPDIR/bin/gh"
  PATH="$TEST_TMPDIR/bin:$PATH"
}

# hold_lock: a run r1 whose lock names a live process ($HOLDER_PID).
hold_lock() {
  mkdir -p "$REPO/.artisan-agent/runs/r1"
  sleep 60 >/dev/null 2>&1 &
  HOLDER_PID=$!
  ln -s "$HOLDER_PID" "$REPO/.artisan-agent/runs/r1/state.lock"
  trap 'kill $HOLDER_PID 2>/dev/null || true' EXIT
}

edit_event() { # file [cwd]
  jq -cn --arg f "$1" --arg c "${2:-$REPO}" '{hook_event_name:"PreToolUse",tool_name:"Edit",cwd:$c,tool_input:{file_path:$f}}'
}

test_edit_in_main_checkout_is_refused_with_where_to_work() {
  make_repo
  local out=
  out=$(edit_event "$REPO/doc.md" | "$PROTECT" main-edit)
  assert_contains "$out" '"permissionDecision":"deny"'
  assert_contains "$out" "main checkout"
  assert_contains "$out" "doc-change.sh start"
  assert_contains "$out" "worktree"
}

test_edit_of_a_new_file_in_a_new_directory_is_refused_too() {
  make_repo
  assert_contains "$(edit_event "$REPO/new/dir/x.md" | "$PROTECT" main-edit)" '"deny"'
}

test_edit_in_a_linked_worktree_is_allowed() {
  make_repo
  git -C "$REPO" worktree add -q -b agent/9 "$TEST_TMPDIR/wt" >/dev/null 2>&1
  assert_eq "" "$(edit_event "$TEST_TMPDIR/wt/doc.md" "$TEST_TMPDIR/wt" | "$PROTECT" main-edit)"
}

test_edit_outside_a_repo_or_of_ignored_runtime_files_or_in_unadopted_repo_is_allowed() {
  make_repo
  assert_eq "" "$(edit_event "$TEST_TMPDIR/elsewhere.txt" | "$PROTECT" main-edit)"
  assert_eq "" "$(edit_event "$REPO/.artisan-agent/runs/r1/state.json" | "$PROTECT" main-edit)"
  rm "$REPO/.artisan-agent/config.yml"
  assert_eq "" "$(edit_event "$REPO/doc.md" | "$PROTECT" main-edit)"
}

test_relative_path_resolves_against_cwd() {
  make_repo
  assert_contains "$(edit_event "doc.md" | "$PROTECT" main-edit)" '"deny"'
}

run_start_event() { # skill [event]
  if [ "${2:-}" = tool ]; then
    jq -cn --arg c "$REPO" --arg s "$1" '{hook_event_name:"PreToolUse",tool_name:"Skill",cwd:$c,tool_input:{skill:$s,args:"build the retry plan"}}'
  else
    jq -cn --arg c "$REPO" --arg s "$1" '{hook_event_name:"UserPromptExpansion",command_name:$s,command_args:"build the retry plan",cwd:$c}'
  fi
}

test_second_run_while_lock_held_is_refused_and_left_as_plan_issue() {
  make_repo; stub_gh; hold_lock
  local out=
  out=$(run_start_event artisan-agent:implement-plan | "$PROTECT" run-start)
  assert_contains "$out" '"decision":"block"'
  assert_contains "$out" "run r1"
  assert_contains "$out" "\`plan\` issue"
  assert_contains "$(cat "$GH_LOG")" "issue create"
  assert_contains "$(cat "$GH_LOG")" "--label plan"
  assert_contains "$(cat "$TEST_TMPDIR/issues")" "Plan: build the retry plan"
}

run_start_args() { # args [tool]: implement-plan with these arguments
  if [ "${2:-}" = tool ]; then
    jq -cn --arg c "$REPO" --arg a "$1" '{hook_event_name:"PreToolUse",tool_name:"Skill",cwd:$c,tool_input:{skill:"artisan-agent:implement-plan",args:$a}}'
  else
    jq -cn --arg c "$REPO" --arg a "$1" '{hook_event_name:"UserPromptExpansion",command_name:"artisan-agent:implement-plan",command_args:$a,cwd:$c}'
  fi
}

test_adding_tickets_or_an_urgent_ticket_to_the_running_run_is_let_through_not_refused_or_queued() {
  make_repo; stub_gh; hold_lock
  local a=
  for a in "add #45 #46" "Add 45" "urgent #47" "URGENT 47" "add-work #45" "--urgent #47" "add #45, #46"; do
    assert_eq "" "$(run_start_args "$a" | "$PROTECT" run-start)" "UserPromptExpansion: $a"
    assert_eq "" "$(run_start_args "$a" tool | "$PROTECT" run-start)" "Skill tool: $a"
  done
  assert_eq 0 "$(grep -c . "$GH_LOG")" "nothing was queued as a separate plan"
  # A different request is still refused and queued.
  assert_contains "$(run_start_args "build the urgent report" | "$PROTECT" run-start)" '"decision":"block"'
  assert_contains "$(run_start_args "add login page" | "$PROTECT" run-start)" '"decision":"block"'
  assert_contains "$(run_start_args "urgent" | "$PROTECT" run-start)" '"decision":"block"'
  assert_contains "$(run_start_args "address #45" | "$PROTECT" run-start)" '"decision":"block"'
}

test_a_retried_request_does_not_file_a_second_plan_issue() {
  make_repo; stub_gh; hold_lock
  run_start_event implement-plan | "$PROTECT" run-start >/dev/null
  run_start_event implement-plan | "$PROTECT" run-start >/dev/null
  assert_eq 1 "$(grep -c . "$TEST_TMPDIR/issues")"
}

test_claude_calling_the_skill_is_refused_too() {
  make_repo; stub_gh; hold_lock
  local out=
  out=$(run_start_event artisan-agent:implement-plan tool | "$PROTECT" run-start)
  assert_contains "$out" '"permissionDecision":"deny"'
  assert_contains "$out" "run r1"
}

test_run_start_passes_when_no_live_run_or_lock_is_stale_or_other_skill() {
  make_repo; stub_gh
  assert_eq "" "$(run_start_event implement-plan | "$PROTECT" run-start)"
  mkdir -p "$REPO/.artisan-agent/runs/r0"
  ln -s 999999 "$REPO/.artisan-agent/runs/r0/state.lock"      # dead pid: stale
  assert_eq "" "$(run_start_event implement-plan | "$PROTECT" run-start)"
  hold_lock
  assert_eq "" "$(run_start_event artisan-agent:implement | "$PROTECT" run-start)"
  assert_eq 0 "$(grep -c . "$GH_LOG")"
}

test_a_failing_gh_still_refuses_and_says_so() {
  make_repo; hold_lock
  mkdir -p "$TEST_TMPDIR/bin"; printf '#!/bin/bash\nexit 1\n' >"$TEST_TMPDIR/bin/gh"; chmod +x "$TEST_TMPDIR/bin/gh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  local out=
  out=$(run_start_event implement-plan | "$PROTECT" run-start)
  assert_contains "$out" '"decision":"block"'
  assert_contains "$out" "failed"
}

test_hooks_json_wires_both_hooks_from_the_generator() {
  local j="$PLUGIN_ROOT/hooks/hooks.json"
  assert_contains "$(jq -r '.hooks.PreToolUse[].matcher' "$j")" "Edit|Write|MultiEdit|NotebookEdit"
  assert_contains "$(jq -r '.hooks.PreToolUse[].matcher' "$j")" "Skill"
  assert_contains "$(jq -r '.hooks.UserPromptExpansion[].matcher' "$j")" "implement-plan"
  assert_contains "$(jq -r '.. | .command? // empty' "$j")" '"${CLAUDE_PLUGIN_ROOT}/guard/protect.sh" main-edit'
  [ -x "$PLUGIN_ROOT/guard/protect.sh" ] || fail "protect.sh is not executable"
}

# ---- fallback 1: the git pre-commit hook, no plugin hook in play ----

test_pre_commit_refuses_in_main_checkout_and_allows_in_a_worktree() {
  make_repo
  "$PLUGIN_ROOT/guard/install-pre-commit.sh" "$REPO" >/dev/null
  printf 'two\n' >>"$REPO/doc.md"
  git -C "$REPO" add doc.md
  local err=
  err=$(git -c user.name=T -c user.email=t@example.invalid -C "$REPO" commit -m x 2>&1) && fail "commit in the main checkout was allowed"
  assert_contains "$err" "main checkout"
  assert_contains "$err" "worktree"
  git -C "$REPO" reset -q --hard
  git -C "$REPO" worktree add -q -b agent/9 "$TEST_TMPDIR/wt" >/dev/null 2>&1
  printf 'three\n' >>"$TEST_TMPDIR/wt/doc.md"
  git -C "$TEST_TMPDIR/wt" add doc.md
  git -c user.name=T -c user.email=t@example.invalid -C "$TEST_TMPDIR/wt" commit -qm ok
}

test_pre_commit_install_is_idempotent_and_never_overwrites_a_foreign_hook() {
  make_repo
  local h="$REPO/.git/hooks/pre-commit"
  "$PLUGIN_ROOT/guard/install-pre-commit.sh" "$REPO" >/dev/null
  cksum "$h" >"$TEST_TMPDIR/a"
  "$PLUGIN_ROOT/guard/install-pre-commit.sh" "$REPO" >/dev/null
  cksum "$h" >"$TEST_TMPDIR/b"
  assert_eq "$(cat "$TEST_TMPDIR/a")" "$(cat "$TEST_TMPDIR/b")"
  [ -x "$h" ] || fail "hook not executable"
  printf '#!/bin/sh\necho mine\n' >"$h"
  assert_status 1 "$PLUGIN_ROOT/guard/install-pre-commit.sh" "$REPO"
  assert_contains "$(cat "$h")" "echo mine"
}

test_pre_commit_install_outside_a_repo_fails() {
  assert_status 1 "$PLUGIN_ROOT/guard/install-pre-commit.sh" "$TEST_TMPDIR"
}

test_installed_hook_works_with_the_plugin_gone() {
  make_repo
  cp -R "$PLUGIN_ROOT/guard" "$TEST_TMPDIR/guardcopy"
  "$TEST_TMPDIR/guardcopy/install-pre-commit.sh" "$REPO" >/dev/null
  rm -rf "$TEST_TMPDIR/guardcopy"
  printf 'x\n' >>"$REPO/doc.md"; git -C "$REPO" add doc.md
  git -c user.name=T -c user.email=t@example.invalid -C "$REPO" commit -qm x 2>/dev/null && fail "allowed"
  return 0
}

# ---- fallback 2: implement-plan's own run-lock check ----

test_run_lock_check_reports_holder_and_ignores_stale_locks() {
  make_repo
  assert_status 0 "$RL" check "$REPO"
  mkdir -p "$REPO/.artisan-agent/runs/r0"
  ln -s 999999 "$REPO/.artisan-agent/runs/r0/state.lock"
  assert_status 0 "$RL" check "$REPO"
  hold_lock
  local out= rc=0
  out=$("$RL" check "$REPO") || rc=$?
  assert_eq 3 "$rc"
  assert_eq "r1 $HOLDER_PID" "$out"
}

test_run_lock_check_sees_a_lock_taken_through_state_sh_and_works_from_a_worktree() {
  make_repo
  local plan="$TEST_TMPDIR/plan.json"
  jq -n '{run_id:"r2",repo:"o/r",integration_branch:"run/r2",scope:["1"]}' >"$plan"
  "$ST" init "$REPO/.artisan-agent/runs/r2" "$plan"
  sleep 60 >/dev/null 2>&1 & local p=$!
  "$ST" lock "$REPO/.artisan-agent/runs/r2" "$p"
  git -C "$REPO" worktree add -q -b agent/9 "$TEST_TMPDIR/wt" >/dev/null 2>&1
  local rc=0
  "$RL" check "$TEST_TMPDIR/wt" >/dev/null || rc=$?
  kill "$p" 2>/dev/null || true
  assert_eq 3 "$rc"
}

test_implement_plan_checks_the_lock_before_anything_else_and_queues_a_plan_issue() {
  local s="$PLUGIN_ROOT/skills/implement-plan/SKILL.md"
  assert_contains "$(cat "$s")" 'scripts/run-lock.sh check'
  assert_contains "$(cat "$s")" 'guard/queue-plan.sh'
  assert_contains "$(cat "$s")" 'references/main-checkout.md'
  [ -x "$PLUGIN_ROOT/guard/queue-plan.sh" ] || fail "queue-plan.sh is not executable"
}

test_queue_plan_files_a_plan_issue_via_gh() {
  make_repo; stub_gh
  (cd "$REPO" && "$PLUGIN_ROOT/guard/queue-plan.sh" "run the retry tickets") >/dev/null
  assert_contains "$(cat "$GH_LOG")" "--label plan"
  assert_contains "$(cat "$TEST_TMPDIR/issues")" "Plan: run the retry tickets"
}

# ---- a chat's doc change ----

test_doc_change_goes_through_a_branch_worktree_and_fast_forwards_main() {
  make_repo
  local wt= before=
  before=$(git -C "$REPO" rev-parse HEAD)
  wt=$(cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" start fix)
  [ -d "$wt" ] || fail "no worktree"
  assert_eq "doc/fix" "$(git -C "$wt" branch --show-current)"
  assert_eq "$before" "$(git -C "$REPO" rev-parse HEAD)"      # main untouched while working
  printf 'changed\n' >"$wt/doc.md"
  git -C "$wt" add doc.md; git -c user.name=T -c user.email=t@example.invalid -C "$wt" commit -qm "doc fix"
  assert_eq "one" "$(cat "$REPO/doc.md")"
  (cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" finish fix) >/dev/null
  assert_eq "changed" "$(cat "$REPO/doc.md")"
  assert_eq "$before" "$(git -C "$REPO" rev-parse HEAD~1)"    # a fast-forward: history is linear
  [ ! -d "$wt" ] || fail "worktree not removed"
  git -C "$REPO" rev-parse -q --verify doc/fix >/dev/null && fail "branch not removed"
  return 0
}

test_doc_change_finish_rebases_when_main_moved_and_refuses_a_dirty_main() {
  make_repo
  local wt=
  wt=$(cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" start two)
  printf 'x\n' >"$wt/new.md"; git -C "$wt" add new.md
  git -c user.name=T -c user.email=t@example.invalid -C "$wt" commit -qm new
  printf 'y\n' >"$REPO/other.md"; gq -C "$REPO" add other.md; gq -C "$REPO" commit -m other
  printf 'dirty\n' >>"$REPO/doc.md"
  assert_status 1 bash -c "cd '$REPO' && '$PLUGIN_ROOT/scripts/doc-change.sh' finish two"
  git -C "$REPO" checkout -q doc.md
  (cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" finish two) >/dev/null
  [ -f "$REPO/new.md" ] && [ -f "$REPO/other.md" ] || fail "both changes should be on main"
}

test_doc_change_refuses_bad_names_and_empty_branch() {
  make_repo
  assert_status 1 bash -c "cd '$REPO' && '$PLUGIN_ROOT/scripts/doc-change.sh' start 'a b'"
  (cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" start e) >/dev/null
  assert_status 1 bash -c "cd '$REPO' && '$PLUGIN_ROOT/scripts/doc-change.sh' finish e"
}

test_doc_change_finish_says_so_when_git_has_no_identity() {
  make_repo
  local wt= err=
  wt=$(cd "$REPO" && "$PLUGIN_ROOT/scripts/doc-change.sh" start noid)
  printf 'x\n' >"$wt/n.md"; git -C "$wt" add n.md
  git -c user.name=T -c user.email=t@example.invalid -C "$wt" commit -qm new
  printf 'y\n' >"$REPO/o.md"; gq -C "$REPO" add o.md; gq -C "$REPO" commit -m other
  err=$(cd "$REPO" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
    "$PLUGIN_ROOT/scripts/doc-change.sh" finish noid 2>&1) && fail "finish should refuse"
  assert_contains "$err" "no committer identity"
  [ -d "$wt" ] || fail "worktree must stay"
}

# #59: resuming the open run is not a second run. A bare call, "resume" or
# the run's id passes, typed or called by Claude, and files nothing; anything
# else is still refused.
test_resuming_the_open_run_passes_the_run_lock() {
  make_repo; stub_gh; hold_lock
  local args=
  for args in "" "  " resume r1 "resume r1"; do
    assert_eq "" "$(jq -cn --arg c "$REPO" --arg a "$args" \
      '{hook_event_name:"UserPromptExpansion",command_name:"artisan-agent:implement-plan",command_args:$a,cwd:$c}' \
      | "$PROTECT" run-start)" "typed [$args]"
    assert_eq "" "$(jq -cn --arg c "$REPO" --arg a "$args" \
      '{hook_event_name:"PreToolUse",tool_name:"Skill",cwd:$c,tool_input:{skill:"artisan-agent:implement-plan",args:$a}}' \
      | "$PROTECT" run-start)" "called [$args]"
  done
  # Typed bare, the hook sees no arguments, only the prompt.
  local p=
  for p in "/artisan-agent:implement-plan" "/implement-plan resume" "/artisan-agent:implement-plan r1"; do
    assert_eq "" "$(jq -cn --arg c "$REPO" --arg p "$p" \
      '{hook_event_name:"UserPromptExpansion",command_name:"artisan-agent:implement-plan",prompt:$p,cwd:$c}' \
      | "$PROTECT" run-start)" "prompt [$p]"
  done
  assert_eq 0 "$(grep -c . "$GH_LOG")"
  assert_contains "$(jq -cn --arg c "$REPO" \
    '{hook_event_name:"UserPromptExpansion",command_name:"implement-plan",command_args:"resume r2",cwd:$c}' \
    | "$PROTECT" run-start)" '"decision":"block"'
}

# #153: the session that holds the run is never refused. Its Claude process
# holds the lock (implement-plan, "Hold the run") and runs the hook, so the
# lock's pid is an ancestor of the hook's process. hold_lock_as_ancestor
# writes a script that takes the lock with its own pid and runs the hook from
# inside it: directly (the holder is the hook's parent) or through `sh -c`
# (its grandparent, as a host that runs hooks through a shell would).
hold_lock_as_ancestor() { # shape: direct|shell
  mkdir -p "$REPO/.artisan-agent/runs/r1"
  local s="$TEST_TMPDIR/holder.sh"
  if [ "$1" = shell ]; then
    printf '#!/bin/bash\nln -s "$$" "%s"\nsh -c '"'"'"$1" run-start'"'"' sh "%s"\nrc=$?\nrm -f "%s"\nexit $rc\n' \
      "$REPO/.artisan-agent/runs/r1/state.lock" "$PROTECT" "$REPO/.artisan-agent/runs/r1/state.lock" >"$s"
  else
    printf '#!/bin/bash\nln -s "$$" "%s"\n"%s" run-start\nrc=$?\nrm -f "%s"\nexit $rc\n' \
      "$REPO/.artisan-agent/runs/r1/state.lock" "$PROTECT" "$REPO/.artisan-agent/runs/r1/state.lock" >"$s"
  fi
  chmod +x "$s"
  HOLDER_SCRIPT=$s
}

test_the_holding_session_passes_whatever_it_asks_in_both_process_tree_shapes() {
  make_repo; stub_gh
  local shape="" a=""
  for shape in direct shell; do
    hold_lock_as_ancestor "$shape"
    for a in "Carry on run r1 after the #151 repair" "plan the login page" "build the retry plan"; do
      assert_eq "" "$(run_start_args "$a" | "$HOLDER_SCRIPT")" "$shape, typed: $a"
      assert_eq "" "$(run_start_args "$a" tool | "$HOLDER_SCRIPT")" "$shape, called: $a"
    done
  done
  assert_eq 0 "$(grep -c . "$GH_LOG")" "nothing was queued as a plan"
}

# While a wave runs, the orchestrator's detached runner holds the lock, taken
# over from the chat (`run-ticket.sh --lock-from <chat pid>`): the chat that
# launched it still counts as the holding session; another session does not.
fake_runner() { # lock-from pid: start a process whose command line is a runner's; sets RUNNER_PID
  mkdir -p "$TEST_TMPDIR/runner"
  printf '#!/bin/bash\ntrap "kill \\$c 2>/dev/null; exit 0" TERM\nsleep 60 & c=$!\nwait $c\n' >"$TEST_TMPDIR/runner/run-ticket.sh"
  chmod +x "$TEST_TMPDIR/runner/run-ticket.sh"
  "$TEST_TMPDIR/runner/run-ticket.sh" --role orchestrator --lock-from "$1" --run-dir x --ticket orchestrator-w1 >/dev/null 2>&1 &
  RUNNER_PID=$!
}

test_the_holding_session_passes_while_its_wave_runner_holds_the_lock() {
  make_repo; stub_gh
  mkdir -p "$REPO/.artisan-agent/runs/r1"
  local lock="$REPO/.artisan-agent/runs/r1/state.lock" out=""
  # The chat (this test's shell, an ancestor of the hook) handed the lock on.
  fake_runner "$$"
  trap 'kill $RUNNER_PID 2>/dev/null || true' EXIT
  ln -s "$RUNNER_PID" "$lock"
  assert_eq "" "$(run_start_args "plan the login page" | "$PROTECT" run-start)" "the launching chat"
  # A runner launched by another session.
  kill "$RUNNER_PID"; wait "$RUNNER_PID" 2>/dev/null || true; rm -f "$lock"
  sleep 60 >/dev/null 2>&1 &
  OTHER_PID=$!
  fake_runner "$OTHER_PID"
  trap 'kill $RUNNER_PID $OTHER_PID 2>/dev/null || true' EXIT
  ln -s "$RUNNER_PID" "$lock"
  out=$(run_start_args "plan the login page" | "$PROTECT" run-start)
  assert_contains "$out" '"decision":"block"'
  assert_contains "$(cat "$TEST_TMPDIR/issues")" "Plan: plan the login page"
}
