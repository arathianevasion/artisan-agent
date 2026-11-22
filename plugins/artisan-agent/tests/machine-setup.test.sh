# Machine-level setup, tested only against a fake HOME / CLAUDE_CONFIG_DIR under $TEST_TMPDIR.

SCRIPT="$PLUGIN_ROOT/skills/setup/scripts/machine-setup.sh"

seed_machine() { # builds a fake machine: stale installs, copies, overrides
  export HOME="$TEST_TMPDIR/home"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude-stub"
  export GIT_CONFIG_GLOBAL=/dev/null
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/tdd" "$CLAUDE_CONFIG_DIR/skills/implement-plan" \
    "$CLAUDE_CONFIG_DIR/skills/debate-me" "$CLAUDE_CONFIG_DIR/skills/mine" \
    "$CLAUDE_CONFIG_DIR/plugins" "$TEST_TMPDIR/proj"
  echo tdd >"$CLAUDE_CONFIG_DIR/skills/tdd/SKILL.md"
  echo ip >"$CLAUDE_CONFIG_DIR/skills/implement-plan/SKILL.md"
  echo dm >"$CLAUDE_CONFIG_DIR/skills/debate-me/SKILL.md"
  echo mine >"$CLAUDE_CONFIG_DIR/skills/mine/SKILL.md"
  cat >"$CLAUDE_CONFIG_DIR/settings.json" <<JSON
{"theme": "dark", "skillOverrides": {"tdd": "off", "mine": "off", "other": "name-only"}}
JSON
  cat >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" <<JSON
{"version": 2, "plugins": {
  "artisan-agent@artisan-agent": [
    {"scope": "user", "installPath": "/x", "version": "0.1.0"},
    {"scope": "project", "projectPath": "$TEST_TMPDIR/proj", "installPath": "/y", "version": "1.2.3"}]}}
JSON
  cat >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json" <<JSON
{"claude-plugins-official": {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}, "autoUpdate": true},
 "artisan-agent": {"source": {"source": "github", "repo": "arathianevasion/artisan-agent"}}}
JSON
  printf '#!/bin/sh\necho "$PWD $*" >>"%s/claude-calls"\n' "$TEST_TMPDIR" >"$ARTISAN_CLAUDE_BIN"
  chmod +x "$ARTISAN_CLAUDE_BIN"
}

snapshot() { (cd "$HOME" && find . -type f -not -path './.claude/artisan-agent/.git/*' | sort | xargs cksum); }

test_init_creates_individual_home_as_git_repo_and_is_a_noop_on_rerun() {
  seed_machine
  "$SCRIPT" init >/dev/null
  local h="$CLAUDE_CONFIG_DIR/artisan-agent"
  [ -d "$h/.git" ] || fail "no git repo"
  [ -f "$h/CODING_STANDARDS.md" ] && [ -f "$h/PRODUCT_STANDARDS.md" ] || fail "standards missing"
  [ -f "$h/satisfaction.jsonl" ] && [ ! -s "$h/satisfaction.jsonl" ] || fail "satisfaction record not empty"
  assert_contains "$(cat "$h/CODING_STANDARDS.md")" "## Always ask"
  assert_eq "" "$(git -C "$h" status --porcelain)" "home committed"
  local before= after= out=
  before=$(snapshot); out=$("$SCRIPT" init); after=$(snapshot)
  assert_eq "$before" "$after" "rerun changed files"
  assert_contains "$out" "unchanged: individual home"
}

test_init_never_overwrites_existing_standards() {
  seed_machine
  mkdir -p "$CLAUDE_CONFIG_DIR/artisan-agent"
  echo "my taste" >"$CLAUDE_CONFIG_DIR/artisan-agent/CODING_STANDARDS.md"
  "$SCRIPT" init >/dev/null
  assert_eq "my taste" "$(cat "$CLAUDE_CONFIG_DIR/artisan-agent/CODING_STANDARDS.md")"
}

test_auto_update_off_for_official_and_on_for_ours() {
  seed_machine
  "$SCRIPT" init >/dev/null
  local s="$CLAUDE_CONFIG_DIR/settings.json" k="$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
  assert_eq "False True dark" "$(python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]));e=d["extraKnownMarketplaces"]
print(e["claude-plugins-official"]["autoUpdate"],e["artisan-agent"]["autoUpdate"],d["theme"])' "$s")"
  assert_eq "False True" "$(python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]));print(d["claude-plugins-official"]["autoUpdate"],d["artisan-agent"]["autoUpdate"])' "$k")"
}

test_scan_offers_each_seeded_item_and_changes_nothing() {
  seed_machine
  local before= after= out=
  before=$(snapshot); out=$("$SCRIPT" scan); after=$(snapshot)
  assert_eq "$before" "$after" "scan modified files"
  assert_contains "$out" "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj"
  assert_contains "$out" "stale-skill:tdd"
  assert_contains "$out" "override:tdd"
  assert_contains "$out" "plugin-skill:implement-plan"
  assert_contains "$out" "plugin-skill:debate-me"
  case "$out" in *skill:mine*|*override:mine*|*override:other*|*:user:*) fail "offered something that is not stray: $out" ;; esac
}

test_nothing_is_removed_without_a_yes() {
  seed_machine
  "$SCRIPT" scan >/dev/null
  "$SCRIPT" remove >/dev/null 2>&1
  [ -d "$CLAUDE_CONFIG_DIR/skills/tdd" ] || fail "tdd removed with no ids"
  [ ! -e "$TEST_TMPDIR/claude-calls" ] || fail "uninstall ran with no ids"
}

test_remove_moves_skills_to_trash_drops_override_and_uninstalls() {
  seed_machine
  "$SCRIPT" remove stale-skill:tdd plugin-skill:implement-plan plugin-skill:debate-me \
    override:tdd "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj" >/dev/null
  local t="$CLAUDE_CONFIG_DIR/skills/.trash"
  [ ! -e "$CLAUDE_CONFIG_DIR/skills/tdd" ] || fail "tdd still in skills"
  [ -f "$(ls -d "$t"/tdd.*)/SKILL.md" ] || fail "tdd not in trash"
  [ -f "$(ls -d "$t"/implement-plan.*)/SKILL.md" ] || fail "implement-plan not in trash"
  [ -f "$(ls -d "$t"/debate-me.*)/SKILL.md" ] || fail "debate-me not in trash"
  [ -d "$CLAUDE_CONFIG_DIR/skills/mine" ] || fail "unrelated skill touched"
  assert_eq "other mine dark" "$(python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]));print(*sorted(d["skillOverrides"],reverse=True),d["theme"])' "$CLAUDE_CONFIG_DIR/settings.json")"
  assert_contains "$(cat "$TEST_TMPDIR/claude-calls")" "$TEST_TMPDIR/proj plugin uninstall artisan-agent@artisan-agent --scope project"
}

# A stub claude that records whether CLAUDE_CONFIG_DIR was in its environment, and its value.
stub_recording_config_dir() {
  printf '#!/bin/sh\nif [ "${CLAUDE_CONFIG_DIR+set}" = set ]; then echo "set:$CLAUDE_CONFIG_DIR"; else echo unset; fi >"%s/claude-env"\n' "$TEST_TMPDIR" >"$ARTISAN_CLAUDE_BIN"
}

test_remove_runs_the_cli_without_config_dir_when_the_caller_never_set_it() {
  seed_machine
  stub_recording_config_dir
  local cfg="$CLAUDE_CONFIG_DIR"
  unset CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  # The script reads plugin records from the default $HOME/.claude, which is where seed_machine put them.
  local out=""
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj") || fail "remove failed: $out"
  assert_contains "$out" "uninstalled:"
  assert_eq unset "$(cat "$TEST_TMPDIR/claude-env")" "the CLI must not see CLAUDE_CONFIG_DIR"
  [ "$cfg" = "$HOME/.claude" ] || fail "seed layout changed"
}

test_remove_passes_config_dir_through_when_the_caller_set_it() {
  seed_machine
  stub_recording_config_dir
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  local out=""
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj") || fail "remove failed: $out"
  assert_contains "$out" "uninstalled:"
  assert_eq "set:$CLAUDE_CONFIG_DIR" "$(cat "$TEST_TMPDIR/claude-env")"
}

test_rescan_after_removal_offers_nothing() {
  seed_machine
  "$SCRIPT" remove stale-skill:tdd plugin-skill:implement-plan plugin-skill:debate-me override:tdd >/dev/null
  assert_eq "project-install" "$("$SCRIPT" scan | cut -f2 | tr '\n' ' ' | sed 's/ $//')" "only the install left"
}

# The stub models the real CLI (checked against claude 2.x in an isolated CLAUDE_CONFIG_DIR):
# a project-scope uninstall succeeds only when run from inside the recorded project path.
seed_gone_project() { # leaves an install whose project folder (two levels deep, one with a space) is gone
  seed_machine
  GONE="$TEST_TMPDIR/deleted parent/proj"
  printf '#!/bin/sh\n[ -d "%s" ] || { echo "not installed in project scope" >&2; exit 1; }\n[ "$PWD" = "%s" ] || { echo "not installed in project scope" >&2; exit 1; }\necho "$PWD $*" >>"%s/claude-calls"\n' "$GONE" "$GONE" "$TEST_TMPDIR" >"$ARTISAN_CLAUDE_BIN"
  python3 -I -c '
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["plugins"]["artisan-agent@artisan-agent"][1]["projectPath"]=sys.argv[2]
json.dump(d,open(p,"w"))' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" "$GONE"
}

test_remove_uninstalls_when_project_path_is_gone_and_leaves_no_folder_behind() {
  seed_gone_project
  local out=
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$GONE") || fail "remove failed: $out"
  assert_contains "$out" "uninstalled: artisan-agent@artisan-agent (project)"
  case $out in *"kept: enabledPlugins"*) fail "recreated-folder case must not report a restore" ;; esac
  assert_contains "$(cat "$TEST_TMPDIR/claude-calls")" "$GONE plugin uninstall artisan-agent@artisan-agent --scope project"
  [ ! -e "$GONE" ] || fail "recreated project folder left behind"
  [ ! -e "$TEST_TMPDIR/deleted parent" ] || fail "recreated parent folder left behind"
  [ -d "$TEST_TMPDIR" ] || fail "existing folders must stay"
}

test_remove_keeps_recreated_folder_that_the_uninstall_filled_and_reports_failure_honestly() {
  seed_gone_project
  printf '#!/bin/sh\nmkdir .claude && echo x >.claude/settings.json\n' >"$ARTISAN_CLAUDE_BIN"
  "$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$GONE" 2>"$TEST_TMPDIR/err" >/dev/null || fail "remove failed"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "kept: $GONE is not empty"
  [ -f "$GONE/.claude/settings.json" ] || fail "files the CLI wrote were removed"
  printf '#!/bin/sh\nexit 1\n' >"$ARTISAN_CLAUDE_BIN"
  rm -rf "$GONE"
  if "$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$GONE" >/dev/null 2>&1; then fail "a failing uninstall must fail"; fi
  [ ! -e "$GONE" ] || fail "folder left behind after a failed uninstall"
}

# The real CLI deletes the plugin's enabledPlugins key (and reformats the file) on a project-scope
# uninstall. This stub does the same, from inside the project.
stub_claude_deleting_enabled_key() {
  printf '#!/bin/sh\npython3 -I -c '"'"'import json,sys\nf=sys.argv[1]\nd=json.load(open(f))\nd["enabledPlugins"].pop(sys.argv[2],None)\njson.dump(d,open(f,"w"),indent=4,sort_keys=True)'"'"' "$PWD/.claude/%s" "$3"\n' "$1" >"$ARTISAN_CLAUDE_BIN"
}

test_remove_re_adds_the_enabled_plugins_key_the_uninstall_deleted() {
  seed_machine
  mkdir -p "$TEST_TMPDIR/proj/.claude"
  printf '{"enabledPlugins": {"artisan-agent@artisan-agent": true, "mattpocock-skills@claude-plugins-official": true}, "zeta": 1, "alpha": 2}\n' >"$TEST_TMPDIR/proj/.claude/settings.json"
  stub_claude_deleting_enabled_key settings.json
  local out=
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj") || fail "remove failed: $out"
  assert_contains "$out" "kept: enabledPlugins.artisan-agent@artisan-agent in $TEST_TMPDIR/proj/.claude/settings.json"
  assert_contains "$out" "uninstalled: artisan-agent@artisan-agent (project)"
  assert_eq "True True 1 2" "$(python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]));e=d["enabledPlugins"]
print(e["artisan-agent@artisan-agent"],e["mattpocock-skills@claude-plugins-official"],d["zeta"],d["alpha"])' "$TEST_TMPDIR/proj/.claude/settings.json")"
}

# The CLI leaves "enabledPlugins": {} in its own formatting; the restore adds one line and no more.
test_remove_restore_changes_nothing_but_the_added_key() {
  seed_machine
  mkdir -p "$TEST_TMPDIR/proj/.claude"
  printf '#!/bin/sh\nprintf '"'"'{\\n    "zeta": 1,\\n    "enabledPlugins": {},\\n    "alpha": 2\\n}\\n'"'"' >.claude/settings.json\n' >"$ARTISAN_CLAUDE_BIN"
  printf '{"enabledPlugins": {"artisan-agent@artisan-agent": true}}\n' >"$TEST_TMPDIR/proj/.claude/settings.json"
  "$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj" >/dev/null || fail "remove failed"
  assert_eq '{
    "zeta": 1,
    "enabledPlugins": {
        "artisan-agent@artisan-agent": true
    },
    "alpha": 2
}' "$(cat "$TEST_TMPDIR/proj/.claude/settings.json")"
}

test_remove_does_not_add_a_key_the_project_never_had() {
  seed_machine
  mkdir -p "$TEST_TMPDIR/proj/.claude"
  printf '{"enabledPlugins": {"other@x": true}}\n' >"$TEST_TMPDIR/proj/.claude/settings.json"
  stub_claude_deleting_enabled_key settings.json
  local out=
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$TEST_TMPDIR/proj") || fail "remove failed"
  case $out in *"kept: enabledPlugins"*) fail "reported a restore for a key that was never there" ;; esac
  assert_eq "other@x" "$(python3 -I -c 'import json,sys;print(*json.load(open(sys.argv[1]))["enabledPlugins"])' "$TEST_TMPDIR/proj/.claude/settings.json")"
}

test_remove_restores_the_key_in_settings_local_for_local_scope() {
  seed_machine
  mkdir -p "$TEST_TMPDIR/proj/.claude"
  printf '{"enabledPlugins": {"artisan-agent@artisan-agent": true}}\n' >"$TEST_TMPDIR/proj/.claude/settings.local.json"
  stub_claude_deleting_enabled_key settings.local.json
  local out=
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:local:$TEST_TMPDIR/proj") || fail "remove failed"
  assert_contains "$out" "kept: enabledPlugins.artisan-agent@artisan-agent in $TEST_TMPDIR/proj/.claude/settings.local.json"
}

# A directory holding only the named tools (as stubs), to stand in for PATH.
path_with() { # dir tool...
  local d=$1 t=; shift; mkdir -p "$d"
  for t in "$@"; do printf '#!/bin/sh\nexit 0\n' >"$d/$t"; chmod +x "$d/$t"; done
}

test_check_passes_when_jq_and_perl_are_present() {
  path_with "$TEST_TMPDIR/bin" jq perl
  out=$(PATH="$TEST_TMPDIR/bin" /bin/bash "$SCRIPT" check) || fail "check failed with both present"
  assert_contains "$out" "ok: jq and perl"
}

test_check_reports_each_missing_tool_clearly() {
  path_with "$TEST_TMPDIR/nojq" perl
  rc=0; out=$(PATH="$TEST_TMPDIR/nojq" /bin/bash "$SCRIPT" check) || rc=$?
  assert_eq 1 "$rc" "exit status"
  assert_contains "$out" "missing: jq"
  case $out in *"missing: perl"*) fail "perl is present" ;; esac
  path_with "$TEST_TMPDIR/noperl" jq
  rc=0; out=$(PATH="$TEST_TMPDIR/noperl" /bin/bash "$SCRIPT" check) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "missing: perl"
  mkdir -p "$TEST_TMPDIR/empty"
  out=$(PATH="$TEST_TMPDIR/empty" /bin/bash "$SCRIPT" check) || true
  assert_contains "$out" "missing: jq"
  assert_contains "$out" "missing: perl"
}

test_init_still_sets_up_but_exits_non_zero_when_a_tool_is_missing() {
  seed_machine
  path_with "$TEST_TMPDIR/nojq" perl git python3
  for t in mkdir dirname cat tr sort grep date mv basename; do ln -s "$(command -v $t)" "$TEST_TMPDIR/nojq/$t"; done
  rc=0; out=$(PATH="$TEST_TMPDIR/nojq" /bin/bash "$SCRIPT" init 2>&1) || rc=$?
  assert_contains "$out" "missing: jq"
  [ "$rc" != 0 ] || fail "init must exit non-zero when jq is missing"
  [ -f "$CLAUDE_CONFIG_DIR/artisan-agent/CODING_STANDARDS.md" ] || fail "init must still create the individual home"
}

# ---- merge-batch (#180): host.json's merge_batch, as merge-gate writes merge_gate

test_merge_batch_on_and_off_write_host_json_and_a_second_call_changes_nothing() {
  seed_machine
  local f="$CLAUDE_CONFIG_DIR/artisan-agent/host.json" out=""
  unset ARTISAN_MERGE_BATCH
  out=$("$SCRIPT" merge-batch off)
  assert_contains "$out" "changed: merge_batch is off"
  assert_eq off "$(jq -r .merge_batch "$f")"
  cksum "$f" >"$TEST_TMPDIR/before"
  out=$("$SCRIPT" merge-batch off)
  assert_contains "$out" "unchanged: merge_batch is off"
  cksum "$f" >"$TEST_TMPDIR/after"
  assert_eq "$(cat "$TEST_TMPDIR/before")" "$(cat "$TEST_TMPDIR/after")"
  "$SCRIPT" merge-batch on >/dev/null
  assert_eq on "$(jq -r .merge_batch "$f")"
}

test_merge_batch_keeps_the_other_host_json_keys() {
  seed_machine
  local f="$CLAUDE_CONFIG_DIR/artisan-agent/host.json"
  mkdir -p "$(dirname "$f")"
  echo '{"merge_gate": "local", "x": 1}' >"$f"
  unset ARTISAN_MERGE_BATCH
  "$SCRIPT" merge-batch off >/dev/null
  assert_eq "local 1 off" "$(jq -r '"\(.merge_gate) \(.x) \(.merge_batch)"' "$f")"
}

test_merge_batch_with_an_invalid_value_exits_2_with_usage_and_writes_nothing() {
  seed_machine
  local rc=0 out=""
  out=$("$SCRIPT" merge-batch maybe 2>&1) || rc=$?
  assert_eq 2 "$rc"
  assert_contains "$out" "usage: machine-setup.sh merge-batch [on|off]"
  [ ! -e "$CLAUDE_CONFIG_DIR/artisan-agent/host.json" ] || fail "an invalid value must not write host.json"
  rc=0; "$SCRIPT" merge-batch on off >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc"
}

test_merge_batch_with_no_value_prints_the_setting_and_its_source() {
  seed_machine
  local f="$CLAUDE_CONFIG_DIR/artisan-agent/host.json" out=""
  unset ARTISAN_MERGE_BATCH
  out=$("$SCRIPT" merge-batch)
  assert_eq "on default" "$(jq -r '"\(.batch) \(.source)"' <<<"$out")"
  "$SCRIPT" merge-batch off >/dev/null
  out=$("$SCRIPT" merge-batch)
  assert_eq "off $f" "$(jq -r '"\(.batch) \(.source)"' <<<"$out")"
  out=$(ARTISAN_MERGE_BATCH=on "$SCRIPT" merge-batch)
  assert_eq "on ARTISAN_MERGE_BATCH" "$(jq -r '"\(.batch) \(.source)"' <<<"$out")"
}

# ---- local_suite_priority (#248): machine setup leaves it unset (default background)

test_machine_setup_leaves_local_suite_priority_unset() {
  seed_machine
  local f="$CLAUDE_CONFIG_DIR/artisan-agent/host.json"
  unset ARTISAN_MERGE_BATCH ARTISAN_LOCAL_SUITE_PRIORITY
  "$SCRIPT" init >/dev/null 2>&1 || true
  "$SCRIPT" merge-gate local >/dev/null
  "$SCRIPT" merge-batch off >/dev/null
  assert_eq null "$(jq '.local_suite_priority' "$f")"
  assert_eq "background default" "$(ARTISAN_MERGE_GATE=local "$PLUGIN_ROOT/scripts/merge-gate.sh" show | jq -r '"\(.priority) \(.priority_source)"')"
}

# ---- individual voice file and its import (#275)

VOICE_IMPORT_LINE() { echo "@$CLAUDE_CONFIG_DIR/artisan-agent/VOICE_STANDARDS.md"; }
voice_state() { "$SCRIPT" voice-import state | jq -r '"\(.due) \(.state)"'; }

test_init_seeds_the_individual_voice_file_with_the_marked_block_and_commits_it() {
  seed_machine
  local h="$CLAUDE_CONFIG_DIR/artisan-agent"
  "$SCRIPT" init >/dev/null
  [ -f "$h/VOICE_STANDARDS.md" ] || fail "no individual voice file"
  assert_contains "$(cat "$h/VOICE_STANDARDS.md")" "voice-default v1 start"
  assert_eq "" "$(git -C "$h" status --porcelain)" "voice file committed"
  git -C "$h" ls-files --error-unmatch VOICE_STANDARDS.md >/dev/null || fail "voice file not tracked"
}

test_init_leaves_an_existing_voice_file_untouched() {
  seed_machine
  local h="$CLAUDE_CONFIG_DIR/artisan-agent"
  mkdir -p "$h"
  echo "my voice" >"$h/VOICE_STANDARDS.md"
  "$SCRIPT" init >/dev/null
  assert_eq "my voice" "$(cat "$h/VOICE_STANDARDS.md")"
}

test_voice_import_state_is_due_only_with_no_import_line_and_no_decline() {
  seed_machine
  "$SCRIPT" init >/dev/null
  assert_eq "true due" "$(voice_state)"
  printf '@/some/other/VOICE_STANDARDS.md\n' >"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  assert_eq "true due" "$(voice_state)" "another file's import is not ours"
  VOICE_IMPORT_LINE >>"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  assert_eq "false imported" "$(voice_state)"
}

test_voice_import_yes_adds_the_line_once_and_keeps_the_other_content() {
  seed_machine
  "$SCRIPT" init >/dev/null
  printf '# Mine\n\nbe nice\n' >"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  "$SCRIPT" voice-import yes >/dev/null
  "$SCRIPT" voice-import yes >/dev/null
  local f="$CLAUDE_CONFIG_DIR/CLAUDE.md"
  assert_eq 1 "$(grep -cxF "$(VOICE_IMPORT_LINE)" "$f")" "import line count"
  assert_contains "$(cat "$f")" "be nice"
  assert_eq "# Mine" "$(head -1 "$f")"
  assert_eq "false imported" "$(voice_state)"
}

test_voice_import_yes_creates_the_user_claude_md_when_missing() {
  seed_machine
  "$SCRIPT" init >/dev/null
  "$SCRIPT" voice-import yes >/dev/null
  assert_eq "$(VOICE_IMPORT_LINE)" "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")"
}

test_voice_import_no_records_the_decline_keeps_host_json_and_leaves_claude_md_alone() {
  seed_machine
  "$SCRIPT" init >/dev/null
  local f="$CLAUDE_CONFIG_DIR/artisan-agent/host.json"
  echo '{"merge_gate": "local", "x": 1}' >"$f"
  printf 'keep me\n' >"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  "$SCRIPT" voice-import no >/dev/null
  assert_eq "local 1 true" "$(jq -r '"\(.merge_gate) \(.x) \(.voice_import_declined)"' "$f")"
  assert_eq "keep me" "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")"
  assert_eq "false declined" "$(voice_state)"
}

test_voice_import_rejects_an_unknown_argument() {
  seed_machine
  local rc=0
  "$SCRIPT" voice-import maybe >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc"
}

test_setup_skill_makes_the_voice_offer_with_its_reach_and_recommends_yes() {
  local s=
  s=$(cat "$PLUGIN_ROOT/skills/setup/SKILL.md")
  assert_contains "$s" "voice-import state"
  assert_contains "$s" "every repo on the machine"
  assert_contains "$s" "repos without Artisan Agent"
  assert_contains "$s" "Recommend yes"
  assert_contains "$s" "voice-import no"
}

test_voice_import_no_fails_and_leaves_no_temp_file_when_host_json_is_invalid() {
  seed_machine
  "$SCRIPT" init >/dev/null
  local d="$CLAUDE_CONFIG_DIR/artisan-agent" rc=0 out=
  echo 'not json' >"$d/host.json"
  out=$("$SCRIPT" voice-import no 2>/dev/null) || rc=$?
  [ "$rc" != 0 ] || fail "reported success on invalid host.json"
  assert_not_contains "$out" "changed:"
  assert_eq "not json" "$(cat "$d/host.json")"
  assert_eq 1 "$(ls "$d" | grep -c '^host.json')" "temp file left behind"
}

# ---- design standards at the individual and team levels (#330)

test_init_seeds_an_empty_individual_design_file_and_commits_it() {
  seed_machine
  local h="$CLAUDE_CONFIG_DIR/artisan-agent" t=
  "$SCRIPT" init >/dev/null
  [ -f "$h/DESIGN_STANDARDS.md" ] || fail "no individual design file"
  t=$(cat "$h/DESIGN_STANDARDS.md")
  assert_contains "$t" "Individual level"
  assert_contains "$t" "## Always ask"
  assert_not_contains "$t" "## Personas"   # personas live at product level only
  assert_eq "" "$(git -C "$h" status --porcelain)" "design file committed"
  git -C "$h" ls-files --error-unmatch DESIGN_STANDARDS.md >/dev/null || fail "design file not tracked"
}

test_init_never_overwrites_an_individual_design_file() {
  seed_machine
  local h="$CLAUDE_CONFIG_DIR/artisan-agent"
  mkdir -p "$h"
  echo "my design" >"$h/DESIGN_STANDARDS.md"
  "$SCRIPT" init >/dev/null
  "$SCRIPT" init >/dev/null
  assert_eq "my design" "$(cat "$h/DESIGN_STANDARDS.md")"
}

test_init_drafts_a_team_design_file_and_says_where_to_land_it_by_pr() {
  seed_machine
  local out= d="$CLAUDE_CONFIG_DIR/artisan-agent-drafts/DESIGN_STANDARDS.md"
  out=$("$SCRIPT" init)
  [ -f "$d" ] || fail "no team draft at $d"
  assert_contains "$(cat "$d")" "Team level"
  assert_not_contains "$(cat "$d")" "## Personas"
  assert_contains "$out" "$d"
  assert_contains "$out" "team guardrails repo"
  assert_contains "$out" "by PR"
  # a rerun neither overwrites the draft nor repeats the offer
  echo "edited draft" >"$d"
  out=$("$SCRIPT" init)
  assert_eq "edited draft" "$(cat "$d")"
  assert_not_contains "$out" "land it"
}
