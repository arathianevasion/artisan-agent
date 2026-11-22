# capture.sh (#323): the one entry point that captures a named journey step
# into a folder, whatever kind of capture the product records in
# capture_command. Stub commands only: a "screenshot" one writes a file, a CLI
# one only prints.

CAPTURE="$PLUGIN_ROOT/scripts/capture.sh"

config_with() { # capture_command -> a config file holding it
  local q=
  q=$(printf '%s' "$1" | sed "s/'/''/g")
  printf "capture_command: '%s'\n" "$q" >"$TEST_TMPDIR/config.yml"
}

test_a_screenshot_command_captures_the_named_step_into_the_folder() {
  config_with 'printf PNG >"$ARTISAN_CAPTURE_DIR/$ARTISAN_CAPTURE_STEP.png"; echo noisy runner output'
  local out=
  out=$("$CAPTURE" checkout "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml")
  assert_eq "$TEST_TMPDIR/shots/checkout.png" "$out"
  assert_eq PNG "$(cat "$TEST_TMPDIR/shots/checkout.png")"
  [ ! -e "$TEST_TMPDIR/shots/checkout.txt" ] || fail "a command that wrote a file also left a transcript"
}

test_a_cli_command_is_captured_as_a_transcript_of_the_command_and_its_output() {
  config_with 'echo "hello from $ARTISAN_CAPTURE_STEP"; echo "warning: stale cache" >&2'
  local out=
  out=$("$CAPTURE" login "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml")
  assert_eq "$TEST_TMPDIR/shots/login.txt" "$out"
  assert_eq "\$ echo \"hello from \$ARTISAN_CAPTURE_STEP\"; echo \"warning: stale cache\" >&2
hello from login
warning: stale cache" "$(cat "$TEST_TMPDIR/shots/login.txt")"
}

test_recapturing_a_step_counts_the_overwritten_file() {
  config_with 'date +%s%N >"$ARTISAN_CAPTURE_DIR/$ARTISAN_CAPTURE_STEP.png"; echo again >>"$ARTISAN_CAPTURE_DIR/$ARTISAN_CAPTURE_STEP.png"'
  "$CAPTURE" home "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml" >/dev/null
  assert_eq "$TEST_TMPDIR/shots/home.png" "$("$CAPTURE" home "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml")"
}

test_a_failing_capture_command_fails_with_its_output() {
  config_with 'echo "browser not installed" >&2; exit 3'
  local err= st=0
  err=$("$CAPTURE" home "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml" 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "exited 3"
  assert_contains "$err" "browser not installed"
}

test_a_command_that_captures_nothing_fails() {
  config_with 'true'
  local err= st=0
  err=$("$CAPTURE" home "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml" 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "captured nothing"
}

test_no_recorded_capture_command_exits_16() {
  printf 'max_agents: 2\n' >"$TEST_TMPDIR/config.yml"
  local err= st=0
  err=$("$CAPTURE" home "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml" 2>&1) || st=$?
  assert_eq 16 "$st"
  assert_contains "$err" "no capture_command"
}

test_command_flag_overrides_the_config() {
  printf 'max_agents: 2\n' >"$TEST_TMPDIR/config.yml"
  assert_eq "$TEST_TMPDIR/shots/x.txt" "$("$CAPTURE" x "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml" --command 'echo hi')"
}

test_a_step_name_that_is_not_a_file_name_is_refused() {
  config_with 'echo hi'
  assert_status 2 "$CAPTURE" ../escape "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml"
  assert_status 2 "$CAPTURE" "" "$TEST_TMPDIR/shots" --file "$TEST_TMPDIR/config.yml"
}

test_capture_command_defaults_to_empty() {
  assert_eq null "$("$PLUGIN_ROOT/scripts/config.sh" show --file "$TEST_TMPDIR/none.yml" | jq .capture_command)"
}
