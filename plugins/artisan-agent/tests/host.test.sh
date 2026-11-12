# Host mode (#69): the setup script against a fake home, and the login-expiry check.

. "$TESTS_DIR/helpers/run-state.sh"

HOST_SETUP="$PLUGIN_ROOT/skills/setup/scripts/host-setup.sh"

fake_host() { # a fake HOME and config dir; nothing outside the scratch dir is touched
  export HOME="$TEST_TMPDIR/home" CLAUDE_CONFIG_DIR="$TEST_TMPDIR/home/.claude" ARTISAN_HOST_OS=${1:-macos}
  unset ARTISAN_HOME
  mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$TEST_TMPDIR/work"
}

make_host() { "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null; }

test_apply_turns_on_remote_control_and_push_and_writes_the_supervisor() {
  fake_host macos
  printf '{"theme":"dark","remoteControlAtStartup":false}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
  out=$("$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name artisan-test)
  assert_contains "$out" "changed:"
  assert_eq true "$(jq .remoteControlAtStartup "$CLAUDE_CONFIG_DIR/settings.json")"
  assert_eq true "$(jq .agentPushNotifEnabled "$CLAUDE_CONFIG_DIR/settings.json")"
  assert_eq dark "$(jq -r .theme "$CLAUDE_CONFIG_DIR/settings.json")" "other settings are kept"
  l="$CLAUDE_CONFIG_DIR/artisan-agent/host/start-remote-control.sh"
  [ -x "$l" ] || fail "launcher missing"
  assert_contains "$(cat "$l")" "remote-control --spawn worktree --name 'artisan-test'"
  bash -n "$l"
  [ -f "$HOME/Library/LaunchAgents/com.artisan-agent.host.plist" ] || fail "no launchd agent"
  assert_contains "$(cat "$HOME/Library/LaunchAgents/com.artisan-agent.host.plist")" "RunAtLoad"
  assert_eq true "$(jq .configured "$CLAUDE_CONFIG_DIR/artisan-agent/host.json")"
}

test_apply_on_linux_writes_a_systemd_unit_and_timer() {
  fake_host linux
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null
  [ -f "$HOME/.config/systemd/user/artisan-agent-host.service" ] || fail "no service"
  assert_contains "$(cat "$HOME/.config/systemd/user/artisan-agent-host.timer")" "OnBootSec"
  [ ! -e "$HOME/Library/LaunchAgents" ] || fail "launchd file written on linux"
}

test_apply_is_rerunnable_and_never_overwrites_a_changed_file() {
  fake_host macos
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name n >/dev/null
  out=$("$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name n)
  assert_contains "$out" "unchanged: $CLAUDE_CONFIG_DIR/artisan-agent/host/start-remote-control.sh"
  echo '# mine' >>"$CLAUDE_CONFIG_DIR/artisan-agent/host/start-remote-control.sh"
  out=$("$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name n)
  assert_contains "$out" "kept:"
  assert_contains "$(cat "$CLAUDE_CONFIG_DIR/artisan-agent/host/start-remote-control.sh")" "# mine"
}

test_apply_refuses_a_settings_file_that_is_not_an_object() {
  fake_host macos
  echo '[1]' >"$CLAUDE_CONFIG_DIR/settings.json"
  assert_status 1 "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work"
  assert_eq '[1]' "$(jq -c . "$CLAUDE_CONFIG_DIR/settings.json")"
}

test_the_launcher_starts_remote_control_in_tmux_only_when_it_is_gone() {
  fake_host macos
  mkdir -p "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TMUX_LOG"
[ "$1" = has-session ] && [ -f "$TMUX_LOG.up" ] && exit 0
[ "$1" = has-session ] && exit 1
touch "$TMUX_LOG.up"
STUB
  chmod +x "$TEST_TMPDIR/bin/tmux"
  export TMUX_LOG="$TEST_TMPDIR/tmux.log"
  ARTISAN_CLAUDE_BIN=/fake/claude "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null
  l="$CLAUDE_CONFIG_DIR/artisan-agent/host/start-remote-control.sh"
  PATH="$TEST_TMPDIR/bin:$PATH" bash "$l"
  assert_contains "$(cat "$TMUX_LOG")" "new-session -d -s artisan-host /fake/claude remote-control --spawn worktree"
  PATH="$TEST_TMPDIR/bin:$PATH" bash "$l"
  assert_eq 1 "$(grep -c '^new-session' "$TMUX_LOG")" "a second run starts nothing"
}

test_trust_reads_the_claude_json_the_interactive_prompt_wrote() {
  fake_host macos
  d=$(cd "$TEST_TMPDIR/work" && pwd -P)
  assert_status 1 "$HOST_SETUP" trust "$d"
  jq -n --arg d "$d" '{projects: {($d): {hasTrustDialogAccepted: true}}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
  assert_status 0 "$HOST_SETUP" trust "$d"
}

test_mark_sets_host_configured_in_the_project_config() {
  fake_host macos
  make_project
  printf 'max_agents: 5\nhost_configured: false\n' >"$PROJECT/.artisan-agent/config.yml"
  "$HOST_SETUP" mark --repo "$PROJECT" >/dev/null
  assert_eq true "$("$PLUGIN_ROOT/scripts/config.sh" get host_configured --file "$PROJECT/.artisan-agent/config.yml")"
  assert_contains "$("$HOST_SETUP" mark --repo "$PROJECT")" "unchanged:"
  rm "$PROJECT/.artisan-agent/config.yml"
  "$HOST_SETUP" mark --repo "$PROJECT" >/dev/null
  assert_eq true "$("$PLUGIN_ROOT/scripts/config.sh" get host_configured --file "$PROJECT/.artisan-agent/config.yml")"
}

test_status_is_green_only_when_every_piece_is_in_place() {
  fake_host macos
  d=$(cd "$TEST_TMPDIR/work" && pwd -P)
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_TMPDIR/bin/tmux"; cp "$TEST_TMPDIR/bin/tmux" "$TEST_TMPDIR/bin/gh"
  chmod +x "$TEST_TMPDIR/bin/tmux" "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  assert_status 1 "$HOST_SETUP" status
  "$HOST_SETUP" apply --workdir "$d" >/dev/null
  assert_status 1 "$HOST_SETUP" status
  jq -n --arg d "$d" '{projects: {($d): {hasTrustDialogAccepted: true}}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
  assert_status 1 "$HOST_SETUP" status
  "$PLUGIN_ROOT/scripts/login-check.sh" stamp >/dev/null
  assert_status 0 "$HOST_SETUP" status
}

# ---- one meaning each: host.json is the host, login.json the stamp (#108)

HN="$PLUGIN_ROOT/scripts/host-notice.sh"
AH() { printf '%s' "$CLAUDE_CONFIG_DIR/artisan-agent"; }

test_a_stamp_on_a_non_host_makes_no_host_json() {
  fake_host macos
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$L" stamp --at 1000000 >/dev/null
  [ ! -e "$(AH)/host.json" ] || fail "stamp created host.json"
  assert_eq 1000000 "$(jq .login_at "$(AH)/login.json")"
  assert_contains "$("$L" check --span-minutes 100000)" "no host here"
}

test_the_expiry_check_reads_the_stamp_file_on_a_host() {
  fake_host macos
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null
  assert_status 15 "$L" check --span-minutes 1
  "$L" stamp --at 1000000 >/dev/null
  assert_eq null "$(jq .login_at "$(AH)/host.json")" "the stamp is not in host.json"
  assert_status 0 "$L" check --span-minutes 60 --now 3500000
  assert_status 15 "$L" check --span-minutes 60 --now 3600000
}

test_host_setup_alone_writes_host_json_and_a_rerun_changes_nothing() {
  fake_host macos
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name n >/dev/null
  before=$(cat "$(AH)/host.json")
  out=$("$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" --name n)
  assert_contains "$out" "unchanged: host record"
  assert_eq "$before" "$(cat "$(AH)/host.json")"
}

test_a_legacy_host_json_is_not_a_host_and_cleanup_moves_the_stamp() {
  fake_host macos
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  mkdir -p "$(AH)"
  echo '{"login_at":1000000,"login_lifetime_days":30}' >"$(AH)/host.json"
  assert_contains "$("$L" legacy)" "legacy:"
  assert_contains "$("$L" check --span-minutes 100000 2>&1)" "no host here"
  out=$("$L" cleanup)
  assert_contains "$out" "changed:"
  [ ! -e "$(AH)/host.json" ] || fail "host.json left"
  assert_eq 1000000 "$(jq .login_at "$(AH)/login.json")"
  assert_status 1 "$L" legacy
  assert_contains "$("$L" cleanup)" "unchanged:"
}

test_cleanup_keeps_a_real_hosts_record() {
  fake_host macos
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null
  jq '.login_at = 5' "$(AH)/host.json" >"$(AH)/h.tmp" && mv "$(AH)/h.tmp" "$(AH)/host.json"
  assert_status 1 "$L" legacy
  "$L" cleanup >/dev/null
  assert_eq true "$(jq .configured "$(AH)/host.json")"
  assert_eq 5 "$(jq .login_at "$(AH)/login.json")"
}

test_a_start_on_a_non_host_with_host_configured_gets_the_notice_and_exit_10() {
  fake_host macos
  make_project
  printf 'host_configured: true\n' >"$PROJECT/.artisan-agent/config.yml"
  out=$("$HN" --repo "$PROJECT" || echo "exit $?")
  assert_contains "$out" "runs live on the always-on host"
  assert_contains "$out" "exit 10"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'always-on host')" "one line of notice"
}

test_a_stamp_only_laptop_with_host_configured_still_gets_the_notice() {
  fake_host macos
  make_project
  printf 'host_configured: true\n' >"$PROJECT/.artisan-agent/config.yml"
  "$PLUGIN_ROOT/scripts/login-check.sh" stamp >/dev/null
  assert_status 10 "$HN" --repo "$PROJECT"
}

test_a_start_on_the_host_is_normal() {
  fake_host macos
  make_project
  printf 'host_configured: true\n' >"$PROJECT/.artisan-agent/config.yml"
  "$HOST_SETUP" apply --workdir "$TEST_TMPDIR/work" >/dev/null
  assert_status 0 "$HN" --repo "$PROJECT"
}

test_host_configured_false_or_absent_starts_locally() {
  fake_host macos
  make_project
  assert_eq "" "$("$HN" --repo "$PROJECT")"
  assert_status 0 "$HN" --repo "$PROJECT"
  printf 'host_configured: false\n' >"$PROJECT/.artisan-agent/config.yml"
  assert_status 0 "$HN" --repo "$PROJECT"
}

test_the_notice_run_on_a_legacy_laptop_offers_cleanup() {
  fake_host macos
  make_project
  mkdir -p "$(AH)"; echo '{"login_at":1}' >"$(AH)/host.json"
  assert_contains "$("$HN" --repo "$PROJECT")" "cleanup"
}

# ---- the login-expiry check

test_a_machine_with_no_host_record_is_not_checked() {
  fake_host macos
  out=$("$PLUGIN_ROOT/scripts/login-check.sh" check --span-minutes 100000)
  assert_contains "$out" "no host here"
}

test_a_host_refuses_a_run_the_login_would_not_outlast() {
  fake_host macos; make_host
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$L" stamp --at 1000000 >/dev/null
  # 30 days = 2592000 s; the login lasts until 3592000
  assert_status 0 "$L" check --span-minutes 60 --now 3500000
  assert_status 0 "$L" check --span-minutes 60 --margin-minutes 0 --now 3588000
  assert_status 15 "$L" check --span-minutes 60 --now 3588000
  assert_status 15 "$L" check --span-minutes 60 --now 3600000
  msg=$("$L" check --span-minutes 60 --now 3588000 2>&1 || true)
  assert_contains "$msg" "expires"
  assert_contains "$msg" "stamp"
}

test_a_host_with_no_login_stamp_refuses() {
  fake_host macos
  mkdir -p "$CLAUDE_CONFIG_DIR/artisan-agent"
  echo '{"configured":true}' >"$CLAUDE_CONFIG_DIR/artisan-agent/host.json"
  assert_status 15 "$PLUGIN_ROOT/scripts/login-check.sh" check --span-minutes 1
}

test_the_span_comes_from_the_runs_forecast_waves() {
  fake_host macos; make_host
  init_run '["10","11","12"]' '{"10":{"expected":{"minutes":30},"caps":{"deadline_seconds":3600}},"11":{"expected":{"minutes":10},"caps":{"deadline_seconds":1200}},"12":{"caps":{"deadline_seconds":3000}}}'
  # waves [[10],[11],[12]]: 30 + 10 + 25 (half the deadline) = 65 minutes
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$L" stamp --at 1000000 >/dev/null
  assert_status 0 "$L" check --run-dir "$RUN_DIR" --margin-minutes 0 --now $((1000000 + 2592000 - 65 * 60))
  assert_status 15 "$L" check --run-dir "$RUN_DIR" --margin-minutes 0 --now $((1000000 + 2592000 - 65 * 60 + 1))
}

test_the_first_wave_launch_is_refused_on_a_host_whose_login_would_expire() {
  fake_host macos; make_host
  init_run
  "$PLUGIN_ROOT/scripts/login-check.sh" stamp --at 1 >/dev/null
  "$SCRIPTS/wave.sh" start "$RUN_DIR" >/dev/null
  assert_status 15 "$SCRIPTS/wave.sh" launch "$RUN_DIR"
  [ ! -d "$RUN_DIR/workers" ] || [ -z "$(ls "$RUN_DIR/workers" 2>/dev/null)" ] || fail "an orchestrator was started"
  assert_eq false "$(state_get '(.orchestrators // []) | length > 0')"
}

test_a_resumed_run_is_checked_against_the_tickets_it_has_left() {
  fake_host macos; make_host
  init_run '["10","11","12"]' '{"10":{"expected":{"minutes":30},"caps":{"deadline_seconds":3600}},"11":{"expected":{"minutes":10},"caps":{"deadline_seconds":1200}},"12":{"caps":{"deadline_seconds":3000}}}'
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.tickets["10"].status = "merged"'
  L="$PLUGIN_ROOT/scripts/login-check.sh"
  "$L" stamp --at 1000000 >/dev/null
  # 10 is merged: 10 + 25 = 35 minutes left
  assert_status 0 "$L" check --run-dir "$RUN_DIR" --margin-minutes 0 --now $((1000000 + 2592000 - 35 * 60))
  assert_status 15 "$L" check --run-dir "$RUN_DIR" --margin-minutes 0 --now $((1000000 + 2592000 - 35 * 60 + 1))
}
