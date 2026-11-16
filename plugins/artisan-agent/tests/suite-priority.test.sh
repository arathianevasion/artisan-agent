# Background priority for local suites and checks (#248, lib/priority-lib.sh):
# every suite and recorded check the pipeline starts on this machine (checks.sh
# run, the local merge gate, end-gate.sh urgent-finish) runs under taskpolicy -b
# on macOS and nice -n 10 (plus ionice -c 3) on Linux, unless host.json says
# local_suite_priority: normal. Fake uname, taskpolicy, nice and ionice on PATH
# record each call and run what follows; no real process's priority changes.

CHECKS="$PLUGIN_ROOT/scripts/checks.sh"
MG="$PLUGIN_ROOT/scripts/merge-gate.sh"
HOST_JSON="$CLAUDE_CONFIG_DIR/artisan-agent/host.json"

# fake_os macos|linux: fake uname plus every priority tool, logging to $CALLS.
fake_os() {
  local bin="$TEST_TMPDIR/fakebin" kernel=Linux
  [ "$1" = macos ] && kernel=Darwin
  mkdir -p "$bin"
  printf '#!/bin/sh\necho %s\n' "$kernel" >"$bin/uname"
  # Each fake records its arguments, drops its own options and runs the rest.
  printf '#!/bin/sh\necho "taskpolicy $*" >>"$CALLS"\nshift\nexec "$@"\n' >"$bin/taskpolicy"
  printf '#!/bin/sh\necho "nice $*" >>"$CALLS"\nshift 2\nexec "$@"\n' >"$bin/nice"
  printf '#!/bin/sh\necho "ionice $*" >>"$CALLS"\nshift 2\nexec "$@"\n' >"$bin/ionice"
  chmod +x "$bin"/*
  export CALLS="$TEST_TMPDIR/calls" PATH="$bin:$PATH"
  : >"$CALLS"
}

# without_tools name...: PATH as links to every command on it but the names.
without_tools() {
  local dir="$TEST_TMPDIR/pathless" d="" f="" n="" skip=""
  mkdir -p "$dir"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n=${f##*/}
      [ -x "$f" ] && [ ! -e "$dir/$n" ] || continue
      skip=0
      for x in "$@"; do [ "$n" != "$x" ] || skip=1; done
      [ "$skip" = 1 ] || ln -s "$f" "$dir/$n"
    done
  done
  export PATH="$dir"
}

set_priority() { # value
  jq --arg p "$1" '.local_suite_priority = $p' "$HOST_JSON" >"$HOST_JSON.tmp" && mv "$HOST_JSON.tmp" "$HOST_JSON"
}

# A project with one recorded check that leaves a mark when it runs.
recorded_check() {
  P="$TEST_TMPDIR/proj"
  mkdir -p "$P"
  printf '#!/bin/sh\ntouch "%s/ran"\necho check ok\n' "$P" >"$P/check.sh"
  chmod +x "$P/check.sh"
  printf '# Standards\n\n## Checks\n\n- `./check.sh`: proven to fail on 2026-11-16, breaking: removed it\n' >"$P/CODING_STANDARDS.md"
}

run_checks() { "$CHECKS" run --file "$P/CODING_STANDARDS.md" --in "$P" "$@"; }

run_local_gate() {
  "$MG" local --dir "$P" --command "./check.sh" --log "$TEST_TMPDIR/suite.log"
}

test_sp_checks_run_under_nice_and_ionice_on_linux_by_default() {
  fake_os linux
  recorded_check
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run: $(cat "$TEST_TMPDIR/err")"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_contains "$(cat "$CALLS")" "ionice -c 3 nice -n 10 sh -c ./check.sh"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh"
}

test_sp_checks_run_under_taskpolicy_on_macos_by_default() {
  fake_os macos
  recorded_check
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run: $(cat "$TEST_TMPDIR/err")"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_contains "$(cat "$CALLS")" "taskpolicy -b sh -c ./check.sh"
  assert_not_contains "$(cat "$CALLS")" "nice"
}

test_sp_the_worker_and_verifier_checks_are_lowered_too() {
  fake_os linux
  recorded_check
  printf '\n- `./check.sh && true`: proven to fail on 2026-11-16, breaking: removed it\n' >>"$P/CODING_STANDARDS.md"
  run_checks --worker --suite './check.sh' >/dev/null 2>&1 || fail "checks.sh run --worker failed"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh && true"
}

test_sp_the_local_merge_gate_suite_runs_in_the_background_on_both() {
  fake_os linux
  recorded_check
  run_local_gate >/dev/null 2>&1 || fail "the gate failed"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh"
  fake_os macos
  run_local_gate >/dev/null 2>&1 || fail "the gate failed"
  assert_contains "$(cat "$CALLS")" "taskpolicy -b sh -c ./check.sh"
}

test_sp_normal_starts_the_commands_directly() {
  fake_os linux
  set_priority normal
  recorded_check
  run_checks >/dev/null 2>&1 || fail "checks.sh run failed"
  run_local_gate >/dev/null 2>&1 || fail "the gate failed"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_eq "" "$(cat "$CALLS")" "no priority tool is called"
  fake_os macos
  run_local_gate >/dev/null 2>&1 || fail "the gate failed"
  assert_eq "" "$(cat "$CALLS")" "no priority tool is called"
}

test_sp_background_written_out_is_the_default() {
  fake_os linux
  set_priority background
  recorded_check
  run_checks >/dev/null 2>&1 || fail "checks.sh run failed"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh"
}

test_sp_an_unknown_value_is_refused_naming_the_allowed_ones() {
  fake_os linux
  set_priority low
  recorded_check
  local st=0
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || st=$?
  assert_eq 1 "$st" "checks.sh run refuses"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "local_suite_priority must be background or normal, not \"low\""
  [ ! -e "$P/ran" ] || fail "the check ran despite the refusal"
  st=0
  run_local_gate >/dev/null 2>"$TEST_TMPDIR/err" || st=$?
  assert_eq 1 "$st" "the local gate refuses"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "must be background or normal"
  [ ! -e "$P/ran" ] || fail "the suite ran despite the refusal"
}

test_sp_a_bad_value_stops_a_local_gate_before_it_starts() {
  fake_os linux
  set_priority low
  recorded_check
  local st=0
  "$MG" start --result "$TEST_TMPDIR/res/r.json" --pid-file "$TEST_TMPDIR/g.pid" --log "$TEST_TMPDIR/g.log" \
    -- local --dir "$P" --command ./check.sh --log "$TEST_TMPDIR/suite.log" >/dev/null 2>"$TEST_TMPDIR/err" || st=$?
  assert_eq 1 "$st" "start refuses, so wave.sh undoes the merge without blocking the ticket"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "must be background or normal"
  [ ! -e "$TEST_TMPDIR/g.pid" ] || fail "a gate runner started"
}

test_sp_show_names_the_priority_and_its_source() {
  fake_os linux
  assert_eq "background default" "$("$MG" show | jq -r '"\(.priority) \(.priority_source)"')"
  set_priority normal
  assert_eq "normal $HOST_JSON" "$("$MG" show | jq -r '"\(.priority) \(.priority_source)"')"
}

test_sp_a_missing_tool_runs_at_normal_priority_with_a_note() {
  fake_os linux
  recorded_check
  without_tools nice ionice
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run failed: $(cat "$TEST_TMPDIR/err")"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "nice not found: ran at normal priority"
  assert_eq 1 "$(grep -c 'normal priority' "$TEST_TMPDIR/err")" "one line"
  rm -f "$P/ran"
  run_local_gate >/dev/null 2>"$TEST_TMPDIR/err" || fail "the gate failed"
  [ -e "$P/ran" ] || fail "the suite did not run"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "ran at normal priority"
}

test_sp_a_missing_taskpolicy_on_macos_runs_at_normal_priority_with_a_note() {
  fake_os macos
  recorded_check
  without_tools taskpolicy
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run failed"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "taskpolicy not found: ran at normal priority"
}

test_sp_without_ionice_linux_still_lowers_the_cpu_priority() {
  fake_os linux
  recorded_check
  without_tools ionice
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run failed"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh"
  assert_not_contains "$(cat "$CALLS")" "ionice"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "ionice not found: disk at normal priority"
}

test_sp_a_failing_check_still_fails_under_the_wrapper() {
  fake_os linux
  recorded_check
  printf '#!/bin/sh\nexit 3\n' >"$P/check.sh"
  local st=0 out=""
  out=$(run_checks 2>/dev/null) || st=$?
  assert_eq 7 "$st"
  assert_eq 3 "$(printf '%s' "$out" | jq -r '.results[0].exit_code')"
  st=0
  run_local_gate >/dev/null 2>&1 || st=$?
  assert_eq 7 "$st" "the gate is red"
}

# Every place a script starts a suite or check with sh -c goes through the one
# wrapper, so a new one can't run at full priority by accident.
test_sp_every_suite_start_goes_through_the_wrapper() {
  local hits=""
  hits=$(grep -n 'sh -c "\$' "$PLUGIN_ROOT/scripts/checks.sh" "$PLUGIN_ROOT/scripts/merge-gate.sh" \
    "$PLUGIN_ROOT/scripts/end-gate.sh" "$PLUGIN_ROOT/scripts/wave.sh" "$PLUGIN_ROOT/scripts/verify.sh" \
    | grep -v 'priority_run sh -c' || true)
  [ -z "$hits" ] || fail "a suite or check starts outside priority_run:
$hits"
  assert_contains "$(cat "$PLUGIN_ROOT/scripts/end-gate.sh")" 'priority_run sh -c "$suite"'
}

test_sp_the_worker_hears_why_a_bad_value_is_refused() {
  fake_os linux
  set_priority low
  recorded_check
  local st=0
  run_checks --worker >/dev/null 2>"$TEST_TMPDIR/err" || st=$?
  assert_eq 1 "$st"
  assert_eq 'local_suite_priority must be background or normal, not "low" ('"$HOST_JSON"')' "$(cat "$TEST_TMPDIR/err")"
}

test_sp_a_tool_that_refuses_is_named_as_refusing_not_missing() {
  fake_os linux
  recorded_check
  printf '#!/bin/sh\necho "ionice: ioprio_set failed" >&2\nexit 1\n' >"$TEST_TMPDIR/fakebin/ionice"
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run failed"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_contains "$(cat "$CALLS")" "nice -n 10 sh -c ./check.sh"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "ionice could not run here: disk at normal priority"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_TMPDIR/fakebin/nice"
  rm -f "$P/ran"
  run_checks >/dev/null 2>"$TEST_TMPDIR/err" || fail "checks.sh run failed"
  [ -e "$P/ran" ] || fail "the check did not run"
  assert_eq "nice could not run here: ran at normal priority" "$(cat "$TEST_TMPDIR/err")"
}
