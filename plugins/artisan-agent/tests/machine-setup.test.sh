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
  local before after out
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
  local before after out
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
  local out
  out=$("$SCRIPT" remove "project-install:artisan-agent@artisan-agent:project:$GONE") || fail "remove failed: $out"
  assert_contains "$out" "uninstalled: artisan-agent@artisan-agent (project)"
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

# A directory holding only the named tools (as stubs), to stand in for PATH.
path_with() { # dir tool...
  local d=$1 t; shift; mkdir -p "$d"
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
