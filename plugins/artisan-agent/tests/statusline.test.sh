# statusline.sh (#72): the plugin's status-line capture writes plan usage and
# the context window size for the session's own model to the individual home;
# install points an isolated settings.json at it every 60 seconds, chaining a
# status line already there; drain.sh reads the captured window for the chat.
# Never the machine's own config: CLAUDE_CONFIG_DIR and ARTISAN_HOME are the
# test's.

S="$PLUGIN_ROOT/scripts/statusline.sh"

setup_home() {
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/cfg/artisan-agent"
  unset ARTISAN_USAGE_FILE
  USAGE="$ARTISAN_HOME/usage.json"
}

# session_json model-id window [five-hour-%] [seven-day-%]: what Claude Code
# sends the status line (a window of 0 leaves context_window out).
session_json() {
  jq -nc --arg m "$1" --argjson w "$2" --arg f "${3:-}" --arg s "${4:-}" --arg tp "$TEST_TMPDIR/t-$1.jsonl" '
    {session_id: ("s-" + ($m | gsub("[^a-z0-9]"; ""))), transcript_path: $tp,
     model: {id: $m, display_name: $m}}
    + (if $w > 0 then {context_window: {context_window_size: $w, used_percentage: 12}} else {} end)
    + (if $f != "" then {rate_limits: {five_hour: {used_percentage: ($f | tonumber), resets_at: 1900000000},
                                       seven_day: {used_percentage: ($s | tonumber), resets_at: 1900500000}}} else {} end)'
}

test_capture_writes_usage_and_the_context_window_for_the_sessions_model() {
  setup_home
  local before line
  before=$(date +%s)
  line=$(session_json "claude-opus-5-5[1m]" 1000000 23.5 41.2 | "$S")
  assert_contains "$line" "ctx 12% of 1000k · 5h 23% · 7d 41%"
  assert_eq 1000000 "$(jq -r .context_window.size "$USAGE")"
  assert_eq "claude-opus-5-5[1m]" "$(jq -r .model.id "$USAGE")"
  assert_eq "23.5 1900000000 41.2" "$(jq -r '.rate_limits | "\(.five_hour.used_percentage) \(.five_hour.resets_at) \(.seven_day.used_percentage)"' "$USAGE")"
  [ "$(jq -r .rate_limits.at "$USAGE")" -ge "$before" ] || fail "the reading's time is when it was captured"
  # Another session on a 200k model: its own window, in its own session file.
  session_json claude-sonnet-5-5 200000 24 41 | "$S" >/dev/null
  assert_eq 200000 "$(jq -r .context_window.size "$USAGE")"
  assert_eq 1000000 "$(jq -r .context_window.size "$ARTISAN_HOME/sessions/s-claudeopus551m.json")"
  assert_eq 200000 "$(jq -r .context_window.size "$ARTISAN_HOME/sessions/s-claudesonnet55.json")"
}

test_window_falls_back_to_the_model_when_claude_code_gives_none() {
  setup_home
  session_json "claude-opus-5-5[1m]" 0 | "$S" >/dev/null
  assert_eq 1000000 "$(jq -r .context_window.size "$USAGE")"
  session_json claude-haiku-5-5 0 | "$S" >/dev/null
  assert_eq 200000 "$(jq -r .context_window.size "$USAGE")"
}

test_input_without_rate_limits_keeps_the_last_reading_and_its_age() {
  setup_home
  session_json claude-sonnet-5-5 200000 30 50 | "$S" >/dev/null
  jq '.rate_limits.at = 1000' "$USAGE" >"$USAGE.x" && mv "$USAGE.x" "$USAGE"
  session_json claude-sonnet-5-5 200000 | "$S" >/dev/null
  assert_eq "1000 30" "$(jq -r '.rate_limits | "\(.at) \(.five_hour.used_percentage)"' "$USAGE")" \
    "a refresh without rate limits must not make an old reading look fresh"
}

test_capture_never_fails_the_status_line() {
  setup_home
  local out
  out=$(printf 'not json' | "$S")
  assert_contains "$out" "artisan-agent"
  [ ! -e "$USAGE" ] || fail "nothing is written from bad input"
}

test_install_points_settings_at_the_capture_every_minute_and_chains_the_old_line() {
  setup_home
  mkdir -p "$CLAUDE_CONFIG_DIR"
  jq -n '{theme: "dark", statusLine: {type: "command", command: "echo gauge-line", padding: 1}}' >"$CLAUDE_CONFIG_DIR/settings.json"
  local out
  out=$("$S" install)
  assert_contains "$out" "changed: statusLine runs"
  assert_eq dark "$(jq -r .theme "$CLAUDE_CONFIG_DIR/settings.json")" "other settings kept"
  assert_eq "command $ARTISAN_HOME/statusline.sh 60 1" \
    "$(jq -r '.statusLine | "\(.type) \(.command) \(.refreshInterval) \(.padding)"' "$CLAUDE_CONFIG_DIR/settings.json")"
  [ -x "$ARTISAN_HOME/statusline.sh" ] || fail "the capture is copied into the individual home"
  assert_eq "echo gauge-line" "$(jq -r .command "$ARTISAN_HOME/statusline-next.json")"
  # The installed copy captures, and the old line still shows.
  out=$(session_json claude-sonnet-5-5 200000 10 20 | "$ARTISAN_HOME/statusline.sh")
  assert_eq gauge-line "$out"
  assert_eq 10 "$(jq -r .rate_limits.five_hour.used_percentage "$USAGE")"
  # A rerun changes nothing, and never chains the capture to itself.
  out=$("$S" install)
  assert_contains "$out" "unchanged"
  assert_eq "echo gauge-line" "$(jq -r .command "$ARTISAN_HOME/statusline-next.json")"
}

test_install_into_an_empty_config() {
  setup_home
  "$S" install --refresh 45 >/dev/null
  assert_eq 45 "$(jq -r .statusLine.refreshInterval "$CLAUDE_CONFIG_DIR/settings.json")"
  [ ! -e "$ARTISAN_HOME/statusline-next.json" ] || fail "nothing to chain"
}

test_drain_reads_the_chats_window_from_the_capture() {
  setup_home
  local tp="$TEST_TMPDIR/t-claude-sonnet-5-5.jsonl"
  session_json claude-sonnet-5-5 200000 | "$S" >/dev/null
  assert_eq 200000 "$("$S" window --transcript "$tp")"
  assert_status 1 "$S" window --transcript "$TEST_TMPDIR/other.jsonl"
  # 100,000 tokens used: 50% of the captured 200k window, not 10% of the 1M default.
  . "$TESTS_DIR/helpers/run-state.sh"
  init_run >/dev/null
  jq -nc '{type: "assistant", message: {model: "claude-sonnet-5-5", usage: {input_tokens: 100000, output_tokens: 0}}}' >"$tp"
  unset ARTISAN_CONTEXT_WINDOW
  local out
  out=$("$PLUGIN_ROOT/scripts/drain.sh" chat "$RUN_DIR" --transcript "$tp")
  assert_contains "$out" "50%"
}
