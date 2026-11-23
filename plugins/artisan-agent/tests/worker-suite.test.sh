# worker-suite.sh (#406): a worker's full suite before hand-in, on the home PC
# when it answers ssh, against the worker's own commit; else nothing runs and
# the worker runs the guard and covering tests where it is.

WS="$PLUGIN_ROOT/scripts/worker-suite.sh"

# A project whose recorded suite writes the commit it ran on (git HEAD) to
# $TEST_TMPDIR/ran, prints a run.sh-style summary line, and fails when
# FAIL_SUITE is in its tree. A main checkout on main, and a worker's
# worktree on agent/1 one commit ahead of it.
setup_project() {
  P="$TEST_TMPDIR/proj" W="$TEST_TMPDIR/wt"
  mkdir -p "$P"
  git -C "$P" init -q -b main
  cat >"$P/suite.sh" <<SH
#!/bin/sh
git rev-parse HEAD >'$TEST_TMPDIR/ran'
pwd >'$TEST_TMPDIR/ran-in'
if [ -e FAIL_SUITE ]; then echo "FAIL other: test_elsewhere"; echo "9 passed, 1 failed"; exit 1; fi
echo "10 passed, 0 failed"
SH
  chmod +x "$P/suite.sh"
  printf '# Standards\n\n## Checks\n\n- `./suite.sh`: proven to fail on 2026-11-22, breaking: a FAIL_SUITE file\n' >"$P/CODING_STANDARDS.md"
  git -C "$P" add -A && git -C "$P" commit -q -m base
  git -C "$P" worktree add -q -b agent/1 "$W"
  echo change >"$W/feature.txt"
  git -C "$W" add -A && git -C "$W" commit -q -m "the worker's change"
}

# A fake ssh in front of PATH: it answers the probe when $FAKE_SSH_UP is set
# (and logs each call); a remote command runs here, in a shell, as the remote
# would run it.
fake_ssh() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
[ -n "${FAKE_SSH_UP:-}" ] || { echo "ssh: connect to host home-wsl port 22: Operation timed out" >&2; exit 255; }
for last; do :; done
exec sh -c "$last"
SH
  chmod +x "$TEST_TMPDIR/bin/ssh"
  export PATH="$TEST_TMPDIR/bin:$PATH" FAKE_SSH_LOG="$TEST_TMPDIR/ssh.log"
}

OUT= RC=
ws_run() { RC=0; OUT=$(cd "$W" && "$WS" run --host home-wsl --log "$TEST_TMPDIR/suite.log" "$@" 2>"$TEST_TMPDIR/ws.err") || RC=$?; }

test_ws_reachable_runs_the_full_suite_there_on_the_workers_commit() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  ws_run
  assert_eq 0 "$RC" "$OUT $(cat "$TEST_TMPDIR/ws.err")"
  assert_eq "$(git -C "$W" rev-parse HEAD)" "$(cat "$TEST_TMPDIR/ran")" "the suite ran on the worker's commit"
  [ "$(git -C "$P" rev-parse HEAD)" != "$(cat "$TEST_TMPDIR/ran")" ] || fail "ran on the main checkout's branch"
  case $(cat "$TEST_TMPDIR/ran-in") in "$W"|"$P") fail "ran in a local checkout, not a clone on the host" ;; esac
  assert_contains "$(head -1 "$FAKE_SSH_LOG")" "home-wsl true"
  assert_eq "home-wsl true true 10 0 ./suite.sh" \
    "$(jq -r '"\(.where) \(.ran) \(.passed) \(.counts.passed) \(.counts.failed) \(.command)"' <<<"$OUT")"
  assert_eq "$(git -C "$W" rev-parse HEAD)" "$(jq -r .commit <<<"$OUT")"
  assert_eq "10 passed, 0 failed" "$(jq -r .summary <<<"$OUT")"
  assert_eq "" "$(git -C "$W" for-each-ref refs/artisan-gate)" "no ref left behind"
}

test_ws_a_failing_full_suite_is_red_with_its_counts() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  touch "$W/FAIL_SUITE"; git -C "$W" add -A; git -C "$W" commit -q -m "breaks a test elsewhere"
  ws_run
  assert_eq 7 "$RC" "$OUT"
  assert_eq "false 9 1" "$(jq -r '"\(.passed) \(.counts.passed) \(.counts.failed)"' <<<"$OUT")"
  assert_contains "$(cat "$TEST_TMPDIR/suite.log")" "FAIL other: test_elsewhere"
}

test_ws_unreachable_runs_nothing_and_says_to_run_guard_and_covering_tests_here() {
  setup_project; fake_ssh; unset FAKE_SSH_UP
  ws_run
  assert_eq 17 "$RC" "$OUT"
  [ ! -e "$TEST_TMPDIR/ran" ] || fail "the full suite ran though the PC is unreachable"
  assert_eq "local false" "$(jq -r '"\(.where) \(.ran)"' <<<"$OUT")"
  assert_contains "$(jq -r .why <<<"$OUT")" "home-wsl did not answer ssh"
  assert_contains "$(jq -r .instead <<<"$OUT")" "guard tests and the covering tests"
}

test_ws_a_link_that_drops_after_the_probe_falls_back_too() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  # The probe answers; the run's connection fails as ssh does (255).
  cat >"$TEST_TMPDIR/bin/ssh" <<'SH'
#!/bin/sh
case "$*" in *' true') exit 0 ;; esac
exit 255
SH
  ws_run
  assert_eq 17 "$RC" "$OUT"
  assert_eq "local false" "$(jq -r '"\(.where) \(.ran)"' <<<"$OUT")"
  [ ! -e "$TEST_TMPDIR/ran" ] || fail "ran here"
}

test_ws_no_host_configured_falls_back() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  RC=0; OUT=$(cd "$W" && "$WS" run --host "" --log "$TEST_TMPDIR/suite.log" 2>/dev/null) || RC=$?
  assert_eq 17 "$RC" "$OUT"
  assert_contains "$(jq -r .why <<<"$OUT")" "no host"
  [ ! -s "$FAKE_SSH_LOG" ] || fail "ssh was called with no host"
}

test_ws_refuses_uncommitted_work() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  echo more >>"$W/feature.txt"
  ws_run
  assert_eq 1 "$RC"
  assert_contains "$(cat "$TEST_TMPDIR/ws.err")" "commit"
  [ ! -e "$TEST_TMPDIR/ran" ] || fail "ran on a dirty tree"
}

test_ws_no_recorded_checks_is_16() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  git -C "$W" rm -q CODING_STANDARDS.md; git -C "$W" commit -q -m "no checks"
  ws_run
  assert_eq 16 "$RC" "$OUT"
  assert_eq false "$(jq -r .ran <<<"$OUT")"
}

test_ws_the_host_defaults_to_the_merge_gates_fallback_host() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  RC=0; OUT=$(cd "$W" && "$WS" run --log "$TEST_TMPDIR/suite.log" 2>/dev/null) || RC=$?
  assert_eq 0 "$RC" "$OUT"
  assert_eq home-wsl "$(jq -r .where <<<"$OUT")"
}

test_ws_a_silent_suite_that_exits_1_is_red_not_a_fallback() {
  setup_project; fake_ssh; export FAKE_SSH_UP=1
  ws_run --command "exit 1"
  assert_eq 7 "$RC" "$OUT"
  assert_eq "home-wsl true false" "$(jq -r '"\(.where) \(.ran) \(.passed)"' <<<"$OUT")"
}
