# run-lock.sh check sees a run open on another machine (#430): an unmerged
# run/<id> branch or a live runs/<id> snapshot on the remote, or an open
# in-run ticket on the tracker. Exit 4, naming what it found.

RL="$PLUGIN_ROOT/scripts/run-lock.sh"

gq() { git -c init.defaultBranch=main -c user.name=T -c user.email=t@example.invalid "$@" >/dev/null 2>&1; }

# make_repo: $REPO is a main checkout with an origin ($ORIGIN, bare), and a gh
# on PATH whose in-run tickets are the JSON in $TEST_TMPDIR/in-run.json.
make_repo() {
  ORIGIN="$TEST_TMPDIR/origin.git"
  REPO="$TEST_TMPDIR/repo"
  gq init --bare "$ORIGIN"
  mkdir -p "$REPO/.artisan-agent"
  gq -C "$REPO" init
  printf '.artisan-agent/runs/\n' >"$REPO/.gitignore"
  printf 'one\n' >"$REPO/doc.md"
  gq -C "$REPO" add -A
  gq -C "$REPO" commit -m init
  gq -C "$REPO" remote add origin "$ORIGIN"
  gq -C "$REPO" push origin main
  gq --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
  mkdir -p "$TEST_TMPDIR/bin"
  printf '[]\n' >"$TEST_TMPDIR/in-run.json"
  cat >"$TEST_TMPDIR/bin/gh" <<EOT
#!/bin/bash
printf '%s\n' "\$*" >>"$TEST_TMPDIR/gh.log"
case "\$1 \$2" in
  "issue list") cat "$TEST_TMPDIR/in-run.json"; exit 0 ;;
esac
exit 1
EOT
  chmod +x "$TEST_TMPDIR/bin/gh"
  PATH="$TEST_TMPDIR/bin:$PATH"
}

# push_branch name: a commit on top of main, pushed to origin as <name>.
push_branch() {
  gq -C "$REPO" checkout -b "tmp-$$"
  printf '%s\n' "$1" >>"$REPO/doc.md"
  gq -C "$REPO" commit -am "$1"
  gq -C "$REPO" push origin "HEAD:refs/heads/$1"
  gq -C "$REPO" checkout main
  gq -C "$REPO" branch -D "tmp-$$"
}

check() { # args... -> sets OUT, ERR, RC
  RC=0
  OUT=$("$RL" check "$@" 2>"$TEST_TMPDIR/err") || RC=$?
  ERR=$(cat "$TEST_TMPDIR/err")
}

test_an_unmerged_run_branch_on_the_remote_is_a_run_open_elsewhere() {
  make_repo
  push_branch run/p268-1115
  check "$REPO"
  assert_eq 4 "$RC" "$OUT $ERR"
  assert_contains "$OUT" "run/p268-1115"
}

test_a_run_branch_merged_into_main_is_not_open() {
  make_repo
  push_branch run/old
  gq -C "$REPO" fetch origin
  gq -C "$REPO" merge --ff-only origin/run/old
  gq -C "$REPO" push origin main
  check "$REPO"
  assert_eq 0 "$RC" "$OUT $ERR"
}

test_an_open_in_run_ticket_is_a_run_open_elsewhere() {
  make_repo
  printf '[{"number":412,"title":"Some ticket"}]\n' >"$TEST_TMPDIR/in-run.json"
  check "$REPO"
  assert_eq 4 "$RC" "$OUT $ERR"
  assert_contains "$OUT" "#412"
  assert_contains "$(cat "$TEST_TMPDIR/gh.log")" "in-run"
}

test_with_nothing_open_anywhere_check_exits_0() {
  make_repo
  check "$REPO"
  assert_eq 0 "$RC" "$OUT $ERR"
  assert_eq "" "$OUT"
}

# push_snapshot id state-json: a runs/<id> snapshot commit carrying the run's state.
push_snapshot() {
  local id=$1 state=$2
  gq -C "$REPO" checkout -b "snap-$$"
  mkdir -p "$REPO/.artisan-agent/runs/$id"
  printf '%s\n' "$state" >"$REPO/.artisan-agent/runs/$id/state.json"
  gq -C "$REPO" add -f ".artisan-agent/runs/$id/state.json"
  gq -C "$REPO" commit -m snapshot
  gq -C "$REPO" push origin "HEAD:refs/heads/runs/$id"
  gq -C "$REPO" checkout main
  gq -C "$REPO" branch -D "snap-$$"
  rm -rf "$REPO/.artisan-agent/runs/$id"
}

test_a_snapshot_of_a_run_not_ended_is_open_and_an_ended_one_is_not() {
  make_repo
  push_snapshot moving '{"run_id":"moving","location":{"status":"moved","machine":"vm"}}'
  push_snapshot done '{"run_id":"done","end_gate":{"status":"ended"}}'
  check "$REPO"
  assert_eq 4 "$RC" "$OUT $ERR"
  assert_contains "$OUT" "runs/moving"
  assert_not_contains "$OUT" "runs/done"
}

test_a_run_whose_folder_is_live_here_is_not_elsewhere() {
  make_repo
  push_branch run/here
  mkdir -p "$REPO/.artisan-agent/runs/here"
  printf '{"run_id":"here"}\n' >"$REPO/.artisan-agent/runs/here/state.json"
  check "$REPO"
  assert_eq 0 "$RC" "$OUT $ERR"
}

test_with_the_remote_unreachable_check_behaves_as_today_and_says_so() {
  make_repo
  push_branch run/p268-1115
  gq -C "$REPO" remote set-url origin "$TEST_TMPDIR/gone.git"
  check "$REPO"
  assert_eq 0 "$RC" "$OUT $ERR"
  assert_contains "$ERR" "remote not checked"
}

test_with_the_tracker_unreachable_check_says_it_was_not_checked() {
  make_repo
  printf '#!/bin/sh\necho "gh: not logged in" >&2\nexit 4\n' >"$TEST_TMPDIR/bin/gh"
  check "$REPO"
  assert_eq 0 "$RC" "$OUT $ERR"
  assert_contains "$ERR" "tracker not checked"
}

test_a_lock_held_here_still_exits_3_without_looking_at_the_remote() {
  make_repo
  push_branch run/p268-1115
  mkdir -p "$REPO/.artisan-agent/runs/r1"
  sleep 60 >/dev/null 2>&1 & local pid=$!
  ln -s "$pid" "$REPO/.artisan-agent/runs/r1/state.lock"
  check "$REPO"
  kill "$pid" 2>/dev/null || true
  assert_eq 3 "$RC"
  assert_eq "r1 $pid" "$OUT"
}

test_local_skips_the_remote_and_the_tracker() {
  make_repo
  push_branch run/p268-1115
  printf '[{"number":412,"title":"Some ticket"}]\n' >"$TEST_TMPDIR/in-run.json"
  check "$REPO" --local
  assert_eq 0 "$RC" "$OUT $ERR"
}

test_an_override_passes_and_is_recorded_with_who_and_what() {
  make_repo
  push_branch run/p268-1115
  check "$REPO" --override "Andrew: the VM run was abandoned"
  assert_eq 0 "$RC" "$OUT $ERR"
  local log="$REPO/.artisan-agent/runs/run-lock-overrides.jsonl"
  [ -f "$log" ] || fail "no override record"
  assert_eq "Andrew: the VM run was abandoned" "$(jq -r .by "$log")"
  assert_contains "$(jq -c .found "$log")" "run/p268-1115"
  assert_contains "$ERR" "overridden"
}

test_an_override_with_nothing_found_records_nothing() {
  make_repo
  check "$REPO" --override "Andrew"
  assert_eq 0 "$RC"
  [ ! -e "$REPO/.artisan-agent/runs/run-lock-overrides.jsonl" ] || fail "recorded an override that overrode nothing"
}

test_implement_plan_refuses_a_run_open_elsewhere_unless_overridden() {
  local s="$PLUGIN_ROOT/skills/implement-plan/SKILL.md"
  assert_contains "$(cat "$s")" 'Exit 4 means'
  assert_contains "$(cat "$s")" 'run-lock.sh check --override'
}

test_the_hook_and_the_sweep_check_only_the_lock_here() {
  assert_contains "$(cat "$PLUGIN_ROOT/guard/protect.sh")" 'run-lock.sh" check "$cwd" --local'
  assert_contains "$(cat "$PLUGIN_ROOT/scripts/chats.sh")" 'run-lock.sh" check "$PROJECT" --local'
}
