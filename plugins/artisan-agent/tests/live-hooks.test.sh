# Tests for how the live harnesses run claude (#105): plugin hooks active,
# user settings out, a hook-fired proof in every harness.

HELPER="$TESTS_DIR/helpers/live-hooks.sh"
HARNESSES=$(cd "$TESTS_DIR" && ls */live.sh)

# The real claude, if there is one (CI has none: the live checks then skip).
real_claude() { command -v claude 2>/dev/null; }

# A session that goes as far as its SessionStart hooks, then stops at the login
# check ("Not logged in") in an isolated, empty config directory. Costs nothing.
unlogged_session() { # config-dir extra-args...
  local cfg=$1
  shift
  # shellcheck disable=SC2068
  CLAUDE_CONFIG_DIR=$cfg perl -e 'alarm shift; exec @ARGV or die' 60 \
    claude -p "$@" --max-budget-usd 0.05 --no-session-persistence "hi" </dev/null >/dev/null 2>&1 || true
}

test_no_live_harness_passes_setting_sources_project_local() {
  local h=
  for h in $HARNESSES; do
    if grep -q -e '--setting-sources[ =]*project,local' "$TESTS_DIR/$h"; then
      fail "$h passes --setting-sources project,local: plugin hooks never run under it"
    fi
  done
}

test_every_live_harness_uses_the_helper_and_checks_the_hook_proof() {
  local h=
  for h in $HARNESSES; do
    grep -q 'helpers/live-hooks.sh' "$TESTS_DIR/$h" || fail "$h does not source helpers/live-hooks.sh"
    grep -q 'live_hooks_args' "$TESTS_DIR/$h" || fail "$h does not use live_hooks_args"
    grep -q 'live_hooks_proof_check' "$TESTS_DIR/$h" || fail "$h does not check that a plugin hook fired"
    grep -q 'ARTISAN_HOOK_PROOF' "$TESTS_DIR/$h" || fail "$h does not set ARTISAN_HOOK_PROOF"
  done
}

test_the_helper_registers_the_plugins_hooks_with_absolute_paths() {
  local args= f=
  . "$HELPER"
  args=$(live_hooks_args "$PLUGIN_ROOT" "$TEST_TMPDIR/h")
  f=$TEST_TMPDIR/h/plugin-hooks.settings.json
  assert_contains "$args" "--settings $f"
  jq -e . "$f" >/dev/null || fail "settings file is not JSON"
  case "$(cat "$f")" in *CLAUDE_PLUGIN_ROOT*) fail "a placeholder was left in the settings file" ;; esac
  assert_contains "$(cat "$f")" "\\\"$PLUGIN_ROOT/scripts/compact-hook.sh\\\" session-start"
  assert_contains "$(cat "$f")" "\\\"$PLUGIN_ROOT/guard/protect.sh\\\" main-edit"
  assert_eq "$(jq -S .hooks "$PLUGIN_ROOT/hooks/hooks.json" | grep -c command)" "$(jq -S .hooks "$f" | grep -c command)" "same hooks as hooks.json"
}

test_the_proof_check_fails_when_no_hook_fired() {
  . "$HELPER"
  ! live_hooks_proof_check "$TEST_TMPDIR/none" || fail "a missing proof file counted as a hook firing"
  : >"$TEST_TMPDIR/empty"
  ! live_hooks_proof_check "$TEST_TMPDIR/empty" || fail "an empty proof file counted as a hook firing"
}

test_the_session_start_hook_leaves_a_proof_line_and_only_when_asked() {
  . "$HELPER"
  echo '{"session_id":"s1","cwd":"'"$TEST_TMPDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | "$PLUGIN_ROOT/scripts/compact-hook.sh" session-start
  assert_eq "" "$(ls -A "$TEST_TMPDIR")" "no proof without ARTISAN_HOOK_PROOF"
  echo '{"session_id":"s1","cwd":"'"$TEST_TMPDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | ARTISAN_HOOK_PROOF="$TEST_TMPDIR/proof" "$PLUGIN_ROOT/scripts/compact-hook.sh" session-start
  assert_contains "$(cat "$TEST_TMPDIR/proof")" "session-start "
  assert_contains "$(cat "$TEST_TMPDIR/proof")" "session=s1"
  live_hooks_proof_check "$TEST_TMPDIR/proof" || fail "the proof check missed the line"
}

test_a_live_session_with_the_helpers_flags_runs_a_plugin_hook() {
  real_claude >/dev/null || return 0
  . "$HELPER"
  mkdir -p "$TEST_TMPDIR/cfg" "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work"
  # shellcheck disable=SC2046
  ARTISAN_HOOK_PROOF="$TEST_TMPDIR/proof" unlogged_session "$TEST_TMPDIR/cfg" --plugin-dir "$PLUGIN_ROOT" \
    $(live_hooks_args "$PLUGIN_ROOT" "$TEST_TMPDIR/hooks")
  live_hooks_proof_check "$TEST_TMPDIR/proof" || fail "no plugin hook fired in a session started with the helper's flags"
}

test_a_seeded_user_hook_runs_without_the_flags_and_not_with_them() {
  real_claude >/dev/null || return 0
  . "$HELPER"
  mkdir -p "$TEST_TMPDIR/cfg" "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user >> %s/marker"}]}]}}\n' "$TEST_TMPDIR" \
    >"$TEST_TMPDIR/cfg/settings.json"
  unlogged_session "$TEST_TMPDIR/cfg"
  [ -s "$TEST_TMPDIR/marker" ] || fail "control: the seeded user hook did not run, so the check below proves nothing"
  rm -f "$TEST_TMPDIR/marker"
  # shellcheck disable=SC2046
  unlogged_session "$TEST_TMPDIR/cfg" --plugin-dir "$PLUGIN_ROOT" $(live_hooks_args "$PLUGIN_ROOT" "$TEST_TMPDIR/hooks")
  [ ! -e "$TEST_TMPDIR/marker" ] || fail "a user-scope hook ran in a session started with the helper's flags"
}
