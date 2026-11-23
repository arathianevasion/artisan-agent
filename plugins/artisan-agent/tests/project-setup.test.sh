# Project-level setup, tested only against throwaway repos under $TEST_TMPDIR, a local
# bare "origin", a stub gh (GH_BIN) and claude (ARTISAN_CLAUDE_BIN), and a fake HOME.

PS="$PLUGIN_ROOT/skills/setup/scripts/project-setup.sh"

# A fake machine with an individual home, a stub gh, and a project repo that upstream's
# setup-matt-pocock-skills has already prepared (GitHub tracker by default).
seed() { # [tracker title]
  local title=${1:-GitHub}
  export HOME="$TEST_TMPDIR/home"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GH_BIN="$TEST_TMPDIR/gh" ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude"
  mkdir -p "$HOME"
  "$PLUGIN_ROOT/skills/setup/scripts/machine-setup.sh" init >/dev/null 2>&1 || true
  cat >"$GH_BIN" <<EOF
#!/bin/sh
echo "\$*" >>"$TEST_TMPDIR/gh-calls"
case "\$1 \$2" in
  "api user") echo artisan ;;
  "label list") cat "$TEST_TMPDIR/labels" 2>/dev/null || true ;;
  "label create") echo "\$3" >>"$TEST_TMPDIR/labels" ;;
  "pr list") cat "$TEST_TMPDIR/open-pr" 2>/dev/null || true ;;
  "pr create") echo https://github.test/o/p/pull/1 ;;
esac
EOF
  chmod +x "$GH_BIN"
  printf 'needs-triage\nbug\n' >"$TEST_TMPDIR/labels"
  git init -q --bare -b main "$TEST_TMPDIR/origin.git"
  git init -q -b main "$TEST_TMPDIR/proj"
  P="$TEST_TMPDIR/proj"
  mkdir -p "$P/docs/agents"
  printf '# Project\n\n## Agent skills\n\nSee docs/agents.\n' >"$P/CLAUDE.md"
  printf '# Issue tracker: %s\n\nIssues live here.\n\n## Conventions\n\n- **Create an issue**: ...\n\n## When a skill says "publish"\n\nCreate one.\n' "$title" >"$P/docs/agents/issue-tracker.md"
  printf '# Triage Labels\n\n| Label in mattpocock/skills | Label in our tracker | Meaning |\n| - | - | - |\n| `needs-triage` | `needs-triage` | x |\n| `needs-info` | `needs-info` | x |\n| `ready-for-agent` | `ready-for-agent` | x |\n| `ready-for-human` | `ready-for-human` | x |\n| `wontfix` | `wontfix` | x |\n' >"$P/docs/agents/triage-labels.md"
  git -C "$P" add -A && git -C "$P" commit -q -m init
  git -C "$P" remote add origin "$TEST_TMPDIR/origin.git"
  git -C "$P" push -q -u origin main
  git -C "$P" remote set-head origin main
  answers '{"pr_boundary":"slice","pr_level":"product","always_ask":{"product":["Pricing changes"],"coding":["New dependencies"]},"team_repo":"","checks":[]}'
}

answers() { printf '%s\n' "$1" >"$TEST_TMPDIR/answers.json"; }

# begin, apply, labels, finish: one whole setup run. Prints the scripts' output.
run_setup() {
  local wt=
  wt=$("$PS" begin "$P")
  "$PS" apply "$wt" "$TEST_TMPDIR/answers.json"
  "$PS" labels "$wt"
  "$PS" finish "$wt"
}

branch_file() { git -C "$TEST_TMPDIR/origin.git" show "artisan-agent/setup:$1"; }

merge_setup_pr() { # what merging the PR does: main gains the branch; the main checkout pulls
  git -C "$TEST_TMPDIR/origin.git" update-ref refs/heads/main refs/heads/artisan-agent/setup
  git -C "$TEST_TMPDIR/origin.git" update-ref -d refs/heads/artisan-agent/setup
  git -C "$P" pull -q --ff-only origin main
}

test_fresh_repo_gets_one_pr_with_every_item_and_the_main_checkout_is_untouched() {
  seed
  local before= out=
  before=$(cd "$P" && git status --porcelain && cat CLAUDE.md docs/agents/*.md | cksum)
  out=$(run_setup)
  assert_contains "$out" "pr: https://github.test/o/p/pull/1"
  assert_eq "$before" "$(cd "$P" && git status --porcelain && cat CLAUDE.md docs/agents/*.md | cksum)" "main checkout changed"
  assert_eq 1 "$(grep -c '^pr create' "$TEST_TMPDIR/gh-calls")" "one PR"
  # every item is on the PR branch
  branch_file .artisan-agent/config.yml | cmp -s - "$PLUGIN_ROOT/templates/config.yml" || fail "config is not the template"
  assert_contains "$(branch_file .gitignore)" ".artisan-agent/runs/"
  local s=; s=$(branch_file .claude/settings.json)
  assert_eq true "$(printf '%s' "$s" | jq '.enabledPlugins["artisan-agent@artisan-agent"] and .enabledPlugins["mattpocock-skills@claude-plugins-official"]')"
  assert_eq arathianevasion/artisan-agent "$(printf '%s' "$s" | jq -r '.extraKnownMarketplaces["artisan-agent"].source.repo')"
  assert_eq null "$(printf '%s' "$s" | jq '.hooks')" "no hook unless plugin hooks don't fire"
  assert_contains "$(branch_file PRODUCT_STANDARDS.md)" "## Always ask"
  assert_contains "$(branch_file PRODUCT_STANDARDS.md)" "- Pricing changes"
  assert_contains "$(branch_file CODING_STANDARDS.md)" "- New dependencies"
  assert_contains "$(branch_file CODING_STANDARDS.md)" '- `pr-boundaries`: one PR per slice'
  assert_contains "$(branch_file CLAUDE.md)" 'Start with `/artisan-agent:craft`.'
  local t=; t=$(branch_file docs/agents/issue-tracker.md)
  assert_contains "$t" '**Who the Artisan is** (triage compares ticket authors to this): `gh api user --jq .login`, which was `artisan` at setup.'
  assert_contains "$t" '**Tickets filed by agents** carry the `needs-triage` label'
  # GLOSSARY, ADRs and .out-of-scope only when needed: not by setup
  git -C "$TEST_TMPDIR/origin.git" show artisan-agent/setup:GLOSSARY.md >/dev/null 2>&1 && fail "glossary created"
  # the worktree and local branch are gone; nothing left behind
  assert_eq 1 "$(git -C "$P" worktree list | wc -l | tr -d ' ')"
}

test_setup_writes_the_autocompact_override_and_a_rerun_changes_nothing() {
  seed
  run_setup >/dev/null
  assert_eq 40 "$(branch_file .claude/settings.json | jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')"
  assert_eq null "$(branch_file .claude/settings.json | jq '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "the window is never forced"
  merge_setup_pr
  assert_contains "$(run_setup)" "unchanged: the project is already set up"
}

test_a_project_value_for_the_override_is_kept() {
  seed
  mkdir -p "$P/.claude"
  printf '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"55","OTHER":"1"}}\n' >"$P/.claude/settings.json"
  git -C "$P" add -A && git -C "$P" commit -q -m own && git -C "$P" push -q origin main
  local out=; out=$(run_setup)
  assert_contains "$out" "kept: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is \"55\""
  assert_eq 55 "$(branch_file .claude/settings.json | jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')"
  assert_eq 1 "$(branch_file .claude/settings.json | jq -r '.env.OTHER')"
}

test_deny_rules_match_the_replaced_skill_list() {
  seed
  run_setup >/dev/null
  assert_eq "$("$PLUGIN_ROOT/guard/guard.sh" deny-rules)" "$(branch_file .claude/settings.json | jq -r '.permissions.deny[]')"
}

test_the_eleven_labels_exist_on_the_tracker_and_in_the_doc() {
  seed
  run_setup >/dev/null
  local l= doc=; doc=$(branch_file docs/agents/triage-labels.md)
  for l in needs-triage needs-info ready-for-agent ready-for-human wontfix review-gate plan in-run urgent deferred design; do
    grep -qx "$l" "$TEST_TMPDIR/labels" || fail "label $l not on the tracker"
    assert_contains "$doc" "\`$l\`"
  done
  assert_eq 0 "$(grep -c '^label create needs-triage' "$TEST_TMPDIR/gh-calls" || true)" "existing label recreated"
}

test_a_fresh_repo_ignores_the_designs_folder_once() {
  seed
  run_setup >/dev/null
  assert_contains "$(branch_file .gitignore)" ".artisan-agent/designs/"
  assert_eq 1 "$(branch_file .gitignore | grep -cx '.artisan-agent/designs/')" "designs line duplicated"
  assert_eq 1 "$(branch_file .gitignore | grep -cx '.artisan-agent/runs/')" "runs line lost or duplicated"
}

test_a_rerun_adds_the_designs_line_to_a_setup_that_predates_it() {
  seed
  printf '.artisan-agent/runs/\n' >"$P/.gitignore"
  git -C "$P" add -A && git -C "$P" commit -q -m ignore && git -C "$P" push -q origin main
  local out=
  out=$(run_setup)
  assert_contains "$out" "changed: .gitignore ignores .artisan-agent/designs/"
  assert_eq 1 "$(branch_file .gitignore | grep -cx '.artisan-agent/runs/')" "runs line duplicated"
  assert_eq 1 "$(branch_file .gitignore | grep -cx '.artisan-agent/designs/')" "designs line not added once"
}

test_a_present_designs_line_is_left_unchanged() {
  seed
  printf '.artisan-agent/runs/\n.artisan-agent/designs/\n' >"$P/.gitignore"
  git -C "$P" add -A && git -C "$P" commit -q -m ignore && git -C "$P" push -q origin main
  local out=
  out=$(run_setup)
  assert_not_contains "$out" "designs/"
  assert_eq "$(cat "$P/.gitignore")" "$(branch_file .gitignore)"
}

test_rerun_after_merging_changes_nothing() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  local before= out=
  before=$(cd "$P" && git rev-parse HEAD && git status --porcelain)
  : >"$TEST_TMPDIR/gh-calls"
  out=$(run_setup)
  assert_contains "$out" "unchanged: the project is already set up; no PR"
  assert_eq "$before" "$(cd "$P" && git rev-parse HEAD && git status --porcelain)"
  grep -qE '^(pr create|label create)' "$TEST_TMPDIR/gh-calls" && fail "rerun touched the tracker: $(cat "$TEST_TMPDIR/gh-calls")"
  git -C "$TEST_TMPDIR/origin.git" rev-parse -q --verify artisan-agent/setup >/dev/null && fail "rerun pushed a branch"
  assert_eq 1 "$(git -C "$P" worktree list | wc -l | tr -d ' ')"
}

test_rerun_with_the_pr_still_open_stops() {
  seed
  run_setup >/dev/null
  echo https://github.test/o/p/pull/1 >"$TEST_TMPDIR/open-pr"
  local out= rc=0
  out=$("$PS" begin "$P" 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "a setup PR is still open: https://github.test/o/p/pull/1"
}

test_existing_repo_keeps_its_own_files_and_only_gains_lines() {
  seed
  printf '# Our product\n\nWe value speed.\n' >"$P/PRODUCT_STANDARDS.md"
  printf '# Code\n\n## Always ask\n\n- Schema changes\n\n## Style\n\nTabs.\n' >"$P/CODING_STANDARDS.md"
  mkdir -p "$P/.claude" "$P/.artisan-agent"
  printf '{"theme":"x","enabledPlugins":{"artisan-agent@artisan-agent":false},"permissions":{"deny":["Bash(rm:*)"]}}\n' >"$P/.claude/settings.json"
  printf 'max_agents: 2\n' >"$P/.artisan-agent/config.yml"
  printf 'node_modules/\n' >"$P/.gitignore"
  git -C "$P" add -A && git -C "$P" commit -q -m own && git -C "$P" push -q origin main
  local out= f=
  out=$(run_setup)
  assert_contains "$out" "kept: artisan-agent@artisan-agent is set to false"
  for f in PRODUCT_STANDARDS.md CODING_STANDARDS.md .gitignore .artisan-agent/config.yml CLAUDE.md docs/agents/issue-tracker.md docs/agents/triage-labels.md; do
    # every original line is still there, in order: the diff only adds
    diff "$P/$f" <(branch_file "$f") | grep -q '^<' && fail "$f lost or changed a line"
  done
  assert_eq "max_agents: 2" "$(branch_file .artisan-agent/config.yml)"
  local s=; s=$(branch_file .claude/settings.json)
  assert_eq x "$(printf '%s' "$s" | jq -r .theme)"
  assert_eq false "$(printf '%s' "$s" | jq '.enabledPlugins["artisan-agent@artisan-agent"]')"
  assert_eq "Bash(rm:*)" "$(printf '%s' "$s" | jq -r '.permissions.deny[0]')"
  assert_contains "$(branch_file PRODUCT_STANDARDS.md)" "## Always ask"
  local c=; c=$(branch_file CODING_STANDARDS.md)
  assert_contains "$c" "$(printf -- '- Schema changes\n- New dependencies\n\n## Style')"
}

test_setup_refuses_until_upstream_setup_has_run() {
  seed
  git -C "$P" rm -q docs/agents/issue-tracker.md && git -C "$P" commit -q -m drop
  local out= rc=0
  out=$("$PS" begin "$P" 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "/mattpocock-skills:setup-matt-pocock-skills first"
  assert_contains "$("$PS" scan "$P")" "upstream	missing"
}

test_renamed_upstream_label_is_the_one_created() {
  seed
  sed 's/^| `needs-triage` | `needs-triage` |/| `needs-triage` | `triage` |/' "$P/docs/agents/triage-labels.md" >"$P/x"
  mv "$P/x" "$P/docs/agents/triage-labels.md"
  git -C "$P" commit -qam rename && git -C "$P" push -q origin main
  run_setup >/dev/null
  grep -q '^label create triage ' "$TEST_TMPDIR/gh-calls" || fail "renamed label not created: $(cat "$TEST_TMPDIR/gh-calls")"
  branch_file docs/agents/triage-labels.md | grep -q 'Upstream roles added' && fail "a mapped role was re-added"
  return 0
}

test_hook_fallback_writes_a_working_project_hook_only_when_asked() {
  seed
  answers '{"pr_boundary":"plan","pr_level":"product","hook_fallback":true}'
  run_setup >/dev/null
  local s= cmd=; s=$(branch_file .claude/settings.json)
  cmd=$(printf '%s' "$s" | jq -r '.hooks.UserPromptExpansion[0].hooks[0].command')
  assert_eq '"$CLAUDE_PROJECT_DIR"/.claude/hooks/artisan-agent-block-replaced.sh' "$cmd"
  assert_eq "$("$PLUGIN_ROOT/guard/guard.sh" matcher)" "$(printf '%s' "$s" | jq -r '.hooks.UserPromptExpansion[0].matcher')"
  branch_file .claude/hooks/artisan-agent-block-replaced.sh >"$TEST_TMPDIR/hook.sh"
  local out=
  out=$(printf '{"command_name":"mattpocock-skills:triage"}' | bash "$TEST_TMPDIR/hook.sh")
  assert_eq null "$(printf '%s' "$out" | jq -r '.decision // "null"')"
  assert_contains "$out" "artisan-agent:triage"
}

test_hook_probe_reports_whether_plugin_hooks_fire() {
  seed
  # Stub claude: the guard's current redirect as stream-json hook events, built from the real hook's output.
  local ctx=; ctx=$(printf '{"command_name":"mattpocock-skills:triage","command_args":"probe"}' | bash "$PLUGIN_ROOT/guard/block-replaced.sh")
  printf '%s\n' "$ctx" >"$TEST_TMPDIR/hook-out.json"
  cat >"$ARTISAN_CLAUDE_BIN" <<STUB
#!/bin/sh
echo "\$*" >>"$TEST_TMPDIR/claude-calls"
echo '{"type":"system","subtype":"hook_started","hook_event":"UserPromptExpansion"}'
jq -cn --rawfile o "$TEST_TMPDIR/hook-out.json" '{type:"system",subtype:"hook_response",hook_event:"UserPromptExpansion",output:\$o,stdout:\$o,exit_code:0,outcome:"success"}'
echo '{"type":"result","result":"ok"}'
STUB
  chmod +x "$ARTISAN_CLAUDE_BIN"
  assert_eq fires "$("$PS" hook-probe "$P")"
  assert_contains "$(cat "$TEST_TMPDIR/claude-calls")" "--max-budget-usd"
  assert_contains "$(cat "$TEST_TMPDIR/claude-calls")" "--include-hook-events"
  # No guard event (other hooks only, or none): silent.
  printf '#!/bin/sh\necho '"'"'{"type":"system","subtype":"hook_response","hook_event":"SessionStart","stdout":""}'"'"'\necho '"'"'{"type":"result","result":"ok"}'"'"'\n' >"$ARTISAN_CLAUDE_BIN"
  assert_eq silent "$("$PS" hook-probe "$P")"
  printf '#!/bin/sh\necho '"'"'{"type":"result","result":"ok"}'"'"'\n' >"$ARTISAN_CLAUDE_BIN"
  assert_eq silent "$("$PS" hook-probe "$P")"
}

test_motivation_goes_to_the_individual_home_never_the_pr_and_is_asked_once() {
  seed
  assert_contains "$("$PS" scan "$P")" "motivation	none"
  assert_status 1 "$PS" motivation get "$P"
  echo "My grandmother ran a bakery." | "$PS" motivation set "$P" >/dev/null
  local f=
  f=$(ls "$CLAUDE_CONFIG_DIR/artisan-agent/motivations/"*.md)
  assert_contains "$(cat "$f")" "My grandmother ran a bakery."
  assert_contains "$(cat "$f")" "Repo: $TEST_TMPDIR/origin"
  assert_eq "" "$(git -C "$CLAUDE_CONFIG_DIR/artisan-agent" status --porcelain)" "motivation committed"
  assert_contains "$("$PS" scan "$P")" "motivation	recorded"
  assert_status 1 sh -c "echo other | '$PS' motivation set '$P'"
  assert_contains "$(cat "$f")" "bakery"
  run_setup >/dev/null
  git -C "$TEST_TMPDIR/origin.git" grep -q bakery artisan-agent/setup && fail "motivation in the PR"
  return 0
}

test_skipping_the_motivation_does_not_block_setup() {
  seed
  assert_status 1 sh -c "printf '  \n' | '$PS' motivation set '$P'"
  assert_contains "$(run_setup)" "pr: "
  assert_contains "$("$PS" scan "$P")" "motivation	none"
}

test_motivation_set_needs_the_individual_home() {
  seed
  rm -rf "$CLAUDE_CONFIG_DIR/artisan-agent"
  local out= rc=0
  out=$(echo why | "$PS" motivation set "$P" 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "run machine-level setup first"
}

test_pr_boundary_at_individual_level_goes_to_the_individual_home() {
  seed
  answers '{"pr_boundary":"ticket","pr_level":"individual"}'
  run_setup >/dev/null
  branch_file CODING_STANDARDS.md | grep -q pr-boundaries && fail "individual guardrail in the PR"
  local h="$CLAUDE_CONFIG_DIR/artisan-agent" n=
  "$PS" individual Guardrails '- `pr-boundaries`: one PR per ticket (set at setup).' >/dev/null
  assert_contains "$(cat "$h/CODING_STANDARDS.md")" '## Guardrails'
  assert_eq "" "$(git -C "$h" status --porcelain)"
  n=$(git -C "$h" rev-list --count HEAD)
  "$PS" individual Guardrails '- `pr-boundaries`: one PR per ticket (set at setup).' >/dev/null
  assert_eq "$n" "$(git -C "$h" rev-list --count HEAD)" "rerun committed again"
}

# prove-check against a repo whose test passes until a file is broken.
seed_checks() {
  seed
  printf 'ok\n' >"$P/value"
  printf '#!/bin/sh\ngrep -qx ok value\n' >"$P/test.sh"
  chmod +x "$P/test.sh"
  git -C "$P" add -A && git -C "$P" commit -q -m checks
}

test_apply_records_only_checks_it_proves_itself_and_only_once() {
  seed_checks
  git -C "$P" push -q origin main
  answers '{"checks":[{"command":"./test.sh","break_cmd":"echo broken >value","break":"wrote a wrong value"},{"command":"true","break_cmd":"echo broken >value","break":"same"}]}'
  local out=; out=$(run_setup)
  assert_contains "$out" "proven	./test.sh"
  assert_contains "$out" "cannot-fail	true"
  local c=; c=$(branch_file CODING_STANDARDS.md)
  assert_contains "$c" '- `./test.sh`: proven to fail on'
  assert_contains "$c" 'breaking: wrote a wrong value'
  case "$c" in *'`true`'*) fail "an unproven check was recorded" ;; esac
  merge_setup_pr
  assert_contains "$(run_setup)" "unchanged: the project is already set up"
}

test_team_repo_must_be_owner_name() {
  seed
  answers '{"team_repo":"o/n|x"}'
  local wt= rc=0; wt=$("$PS" begin "$P")
  "$PS" apply "$wt" "$TEST_TMPDIR/answers.json" >/dev/null 2>&1 || rc=$?
  assert_eq 1 "$rc"
  answers '{"team_repo":"acme/guardrails"}'
  "$PS" apply "$wt" "$TEST_TMPDIR/answers.json" >/dev/null
  assert_contains "$(cat "$wt/.artisan-agent/config.yml")" "team_guardrails_repo: acme/guardrails"
}

test_prove_check_proves_a_real_check_in_a_throwaway_worktree() {
  seed_checks
  local out=
  out=$(cd "$P" && "$PS" prove-check --break 'echo broken >value' -- ./test.sh)
  assert_contains "$out" "proven	./test.sh"
  assert_eq ok "$(cat "$P/value")" "main checkout broken"
  assert_eq 1 "$(git -C "$P" worktree list | wc -l | tr -d ' ')" "throwaway worktree left"
  assert_eq "" "$(git -C "$P" status --porcelain)"
}

test_prove_check_reports_a_check_that_cannot_fail() {
  seed_checks
  local out= rc=0
  # like a typecheck over an empty program: passes whatever you break
  out=$(cd "$P" && "$PS" prove-check --break 'echo broken >value' -- true) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "cannot-fail	true	(still passes after the break: not trusted)"
  assert_eq 1 "$(git -C "$P" worktree list | wc -l | tr -d ' ')"
}

test_prove_check_refuses_an_already_failing_check_and_a_break_that_changes_nothing() {
  seed_checks
  local rc=0
  (cd "$P" && "$PS" prove-check --break 'echo broken >value' -- false) >/dev/null || rc=$?
  assert_eq 3 "$rc"
  rc=0
  (cd "$P" && "$PS" prove-check --break ':' -- ./test.sh) >/dev/null || rc=$?
  assert_eq 4 "$rc"
  assert_eq 1 "$(git -C "$P" worktree list | wc -l | tr -d ' ')"
}

test_pre_commit_installs_once_and_refuses_main_checkout_commits() {
  seed
  assert_contains "$("$PS" scan "$P")" "pre-commit	missing"
  "$PS" pre-commit "$P" >/dev/null
  local hook=; hook=$(git -C "$P" rev-parse --path-format=absolute --git-path hooks)/pre-commit
  local sum=; sum=$(cksum <"$hook")
  "$PS" pre-commit "$P" >/dev/null
  assert_eq "$sum" "$(cksum <"$hook")"
  assert_contains "$("$PS" scan "$P")" "pre-commit	installed"
  echo x >"$P/x" && git -C "$P" add x
  assert_status 1 git -C "$P" commit -q -m direct
  # setup's own worktree still commits
  run_setup >/dev/null
  branch_file .artisan-agent/config.yml >/dev/null
}

test_local_markdown_tracker_names_the_artisan_without_gh() {
  seed "Local Markdown"
  git -C "$P" config user.name "Ada Artisan"
  run_setup >/dev/null
  assert_contains "$(branch_file docs/agents/issue-tracker.md)" '`git config user.name`, which was `Ada Artisan` at setup. Make no `gh` call'
  grep -qE '^(label|api)' "$TEST_TMPDIR/gh-calls" && fail "gh called for a local tracker"
  return 0
}

test_scan_finds_candidate_checks() {
  seed
  printf '{"scripts":{"test":"jest","lint":"eslint .","build":"tsc","typecheck":"tsc --noEmit"}}\n' >"$P/package.json"
  printf 'test:\n\tgo test\nrelease:\n\ttrue\n' >"$P/Makefile"
  mkdir -p "$P/.github/workflows"
  printf 'jobs:\n  t:\n    steps:\n      - run: ./ci.sh\n' >"$P/.github/workflows/ci.yml"
  local out=; out=$("$PS" scan "$P")
  assert_contains "$out" "check	package.json	npm test"
  assert_contains "$out" "check	package.json	npm run lint"
  assert_contains "$out" "check	package.json	npm run typecheck"
  assert_contains "$out" "check	Makefile	make test"
  assert_contains "$out" "check	CI .github/workflows/ci.yml	./ci.sh"
  case "$out" in *"npm run build"*|*"make release"*) fail "non-check listed" ;; esac
}

test_setup_skill_asks_exactly_five_questions() {
  local f="$PLUGIN_ROOT/skills/setup/PROJECT.md"
  assert_eq 5 "$(sed -n '/^## The five questions/,/^## /p' "$f" | grep -c '^[0-9]\. \*\*')"
}

seed_workflow() { # name trigger-line
  mkdir -p "$P/.github/workflows"
  printf 'name: CI\non:\n  push:\n%s\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps: []\n' "$2" >"$P/.github/workflows/$1"
  git -C "$P" add -A && git -C "$P" commit -q -m "workflow $1"
  git -C "$P" push -q origin main
}

test_setup_records_the_gate_workflow_and_refuses_one_without_workflow_dispatch() {
  seed
  seed_workflow ci.yml '  workflow_dispatch:'
  seed_workflow push-only.yml '  pull_request:'
  local wt= rc=0 err=
  wt=$("$PS" begin "$P")
  answers '{"ci_gate_workflow":"push-only.yml"}'
  err=$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json" 2>&1 >/dev/null) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$err" "push-only.yml has no workflow_dispatch trigger"
  assert_contains "$err" "refused the gate workflow .github/workflows/push-only.yml"
  answers '{"ci_gate_workflow":"missing.yml"}'
  assert_status 1 "$PS" apply "$wt" "$TEST_TMPDIR/answers.json"
  answers '{"ci_gate_workflow":"ci.yml"}'
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "changed: the gate workflow is ci.yml"
  assert_eq "\"ci.yml\"" "$("$PLUGIN_ROOT/scripts/config.sh" get ci_gate.workflow --file "$wt/.artisan-agent/config.yml")"
  assert_eq 30 "$("$PLUGIN_ROOT/scripts/config.sh" get ci_gate.timeout_minutes --file "$wt/.artisan-agent/config.yml")"
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "unchanged: the gate workflow is ci.yml"
}

test_setup_adds_the_gate_workflow_to_a_config_that_predates_it() {
  seed
  seed_workflow ci.yml '  workflow_dispatch:'
  mkdir -p "$P/.artisan-agent"
  printf 'max_agents: 3\n' >"$P/.artisan-agent/config.yml"
  git -C "$P" add -A && git -C "$P" commit -q -m config && git -C "$P" push -q origin main
  local wt=
  wt=$("$PS" begin "$P")
  answers '{"ci_gate_workflow":"ci.yml"}'
  "$PS" apply "$wt" "$TEST_TMPDIR/answers.json" >/dev/null
  assert_eq "\"ci.yml\"" "$("$PLUGIN_ROOT/scripts/config.sh" get ci_gate.workflow --file "$wt/.artisan-agent/config.yml")"
  assert_eq 3 "$("$PLUGIN_ROOT/scripts/config.sh" get max_agents --file "$wt/.artisan-agent/config.yml")"
}

test_setup_offers_a_worktree_setup_default_for_a_node_project_and_records_it() {
  seed
  assert_not_contains "$("$PS" scan "$P")" "node-setup"
  printf '{}\n' >"$P/package-lock.json"
  git -C "$P" add -A && git -C "$P" commit -q -m lock && git -C "$P" push -q origin main
  assert_contains "$("$PS" scan "$P")" "node-setup	npm ci --prefer-offline"
  local wt=
  wt=$("$PS" begin "$P")
  assert_not_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "worktree_setup"
  answers '{"worktree_setup":"npm ci --prefer-offline"}'
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "changed: worktree_setup is npm ci --prefer-offline"
  assert_eq '"npm ci --prefer-offline"' "$("$PLUGIN_ROOT/scripts/config.sh" get worktree_setup --file "$wt/.artisan-agent/config.yml")"
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "unchanged: worktree_setup is npm ci --prefer-offline"
  answers '{"worktree_setup":"pnpm i"}'
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "kept: .artisan-agent/config.yml has worktree_setup: npm ci --prefer-offline"
}

test_setup_picks_the_node_default_by_lockfile() {
  seed
  printf '{}\n' >"$P/package-lock.json"; : >"$P/yarn.lock"
  assert_contains "$("$PS" scan "$P")" "node-setup	yarn install --frozen-lockfile"
  : >"$P/pnpm-lock.yaml"
  assert_contains "$("$PS" scan "$P")" "node-setup	pnpm install --frozen-lockfile --prefer-offline"
}

# #146: setup learns the board convention from the tracker doc and records it
# as tracker.board; a doc without one leaves the board empty.
board_doc() { # a tracker doc that describes a board, as claudia-kerman's does
  cat >>"$P/docs/agents/issue-tracker.md" <<'DOC'

## The Project: every issue gets an Area

All issues live on the GitHub Project **Board**: <https://github.com/users/someone/projects/3>, project number 3.

| Field | Values | Set by |
|---|---|---|
| **Area** | UI · Test & Tooling | whoever files the issue |
| **Priority** | P0 · P1 | triage |
| **Verified in** | Not yet · Stable | whoever merges |
DOC
  git -C "$P" commit -q -am "board doc"
  git -C "$P" push -q origin main
}

test_a_tracker_doc_that_describes_a_board_is_recorded_as_tracker_board() {
  seed
  board_doc
  assert_contains "$("$PS" scan "$P")" "$(printf 'board\tsomeone/3\tArea')"
  local out=
  out=$(run_setup)
  assert_contains "$out" "changed: tracker.board is someone/3, fields at filing: Area"
  branch_file .artisan-agent/config.yml >"$TEST_TMPDIR/config.yml"
  assert_eq '{"fields_at_filing":["Area"],"number":3,"owner":"someone"}' \
    "$("$PLUGIN_ROOT/scripts/config.sh" get tracker.board --file "$TEST_TMPDIR/config.yml" | jq -cS .)"
  assert_eq 1 "$(grep -c '^tracker:' "$TEST_TMPDIR/config.yml")" "one tracker block"
}

test_a_tracker_doc_without_a_board_records_none() {
  seed
  assert_not_contains "$("$PS" scan "$P")" "board"
  local out=
  out=$(run_setup)
  assert_not_contains "$out" "tracker.board"
  branch_file .artisan-agent/config.yml >"$TEST_TMPDIR/config.yml"
  assert_eq '{}' "$("$PLUGIN_ROOT/scripts/config.sh" get tracker.board --file "$TEST_TMPDIR/config.yml" | jq -c .)"
}

test_a_board_already_in_the_config_is_kept() {
  seed
  board_doc
  mkdir -p "$P/.artisan-agent"
  printf 'tracker:\n  board:\n    owner: other\n    number: 9\n    fields_at_filing: [Team]\n' >"$P/.artisan-agent/config.yml"
  git -C "$P" add -A && git -C "$P" commit -q -m config && git -C "$P" push -q origin main
  assert_contains "$(run_setup)" "kept: .artisan-agent/config.yml has tracker.board other/9"
}

test_the_answers_name_a_board_the_doc_does_not_link() {
  seed
  answers '{"pr_boundary":"slice","pr_level":"product","always_ask":{"product":[],"coding":[]},"team_repo":"","checks":[],"tracker_board":{"owner":"org","number":2,"fields_at_filing":["Area"]}}'
  run_setup >/dev/null
  branch_file .artisan-agent/config.yml >"$TEST_TMPDIR/config.yml"
  assert_eq 'org/2' "$("$PLUGIN_ROOT/scripts/config.sh" get tracker.board --file "$TEST_TMPDIR/config.yml" | jq -r '"\(.owner)/\(.number)"')"
}

test_an_inline_empty_tracker_map_is_replaced_by_the_board() {
  seed
  board_doc
  mkdir -p "$P/.artisan-agent"
  printf 'max_agents: 3\ntracker: {board: {}}\n' >"$P/.artisan-agent/config.yml"
  git -C "$P" add -A && git -C "$P" commit -q -m config && git -C "$P" push -q origin main
  assert_contains "$(run_setup)" "changed: tracker.board is someone/3"
  branch_file .artisan-agent/config.yml >"$TEST_TMPDIR/config.yml"
  assert_eq 'someone/3 3' "$("$PLUGIN_ROOT/scripts/config.sh" show --file "$TEST_TMPDIR/config.yml" | jq -r '"\(.tracker.board.owner)/\(.tracker.board.number) \(.max_agents)"')"
}

test_an_unreadable_board_in_the_config_is_kept_and_named() {
  seed
  board_doc
  mkdir -p "$P/.artisan-agent"
  printf 'tracker:\n  board:\n    owner: other\n    number: x\n' >"$P/.artisan-agent/config.yml"
  git -C "$P" add -A && git -C "$P" commit -q -m config && git -C "$P" push -q origin main
  assert_contains "$(run_setup 2>&1)" "kept: .artisan-agent/config.yml has a tracker.board config.sh cannot read"
}

# #266: a new list item goes after the section's list, not after a trailing paragraph.
upstream_conventions() { # upstream's issue-tracker-github.md shape: a list, then a paragraph
  printf '# Issue tracker: GitHub\n\n## Conventions\n\n- **Create an issue**: `gh issue create`\n  with a body.\n- **Close**: `gh issue close`\n\nInfer the repo from `git remote -v`.\n\n## When a skill says "publish"\n\nCreate one.\n' >"$P/docs/agents/issue-tracker.md"
  git -C "$P" commit -q -am "upstream shape" && git -C "$P" push -q origin main
}

test_a_new_bullet_goes_after_the_conventions_list_before_the_trailing_paragraph() {
  seed
  upstream_conventions
  run_setup >/dev/null
  local doc=; doc=$(branch_file docs/agents/issue-tracker.md)
  local want=; want=$(printf '%s\n' '- **Close**: `gh issue close`' \
    '- **Who the Artisan is** (triage compares ticket authors to this): `gh api user --jq .login`, which was `artisan` at setup.' \
    '- **Tickets filed by agents** carry the `needs-triage` label (the string `docs/agents/triage-labels.md` maps it to). Tickets the Artisan writes or approves skip triage.' \
    '' 'Infer the repo from `git remote -v`.')
  assert_contains "$doc" "$want"
  assert_contains "$doc" "$(printf 'with a body.\n- **Close**')"
}

test_a_rerun_after_the_list_insert_changes_nothing() {
  seed
  upstream_conventions
  run_setup >/dev/null
  merge_setup_pr
  local out=; out=$("$PLUGIN_ROOT/skills/setup/scripts/project_edit.py" section "$P/docs/agents/issue-tracker.md" Conventions \
    '- **Tickets filed by agents** carry the `needs-triage` label (the string `docs/agents/triage-labels.md` maps it to). Tickets the Artisan writes or approves skip triage.')
  assert_contains "$out" "unchanged:"
}

test_a_section_with_no_list_still_gets_the_line_at_its_end() {
  seed
  printf '# Issue tracker: GitHub\n\n## Conventions\n\nJust prose here.\n\n## Next\n\nText.\n' >"$P/docs/agents/issue-tracker.md"
  git -C "$P" commit -q -am "no list" && git -C "$P" push -q origin main
  run_setup >/dev/null
  local doc=; doc=$(branch_file docs/agents/issue-tracker.md)
  assert_contains "$doc" "$(printf 'Just prose here.\n- **Who the Artisan is**')"
  assert_contains "$doc" "$(printf 'skip triage.\n\n## Next')"
}

# #273: the product voice file is seeded at the repo root and imported beside the
# front-door pointer; a rerun adds only what's missing and overwrites nothing.
IMPORT='@VOICE_STANDARDS.md'

test_a_fresh_repo_gets_the_voice_file_and_its_import_beside_the_pointer() {
  seed
  local out=; out=$(run_setup)
  branch_file VOICE_STANDARDS.md | cmp -s - "$PLUGIN_ROOT/templates/VOICE_STANDARDS.md" || fail "the voice file is not the template"
  assert_contains "$(branch_file CLAUDE.md)" "$(printf 'Start with `/artisan-agent:craft`.\n%s' "$IMPORT")"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^tune: .*VOICE_STANDARDS.md')" "one summary line says where to tune the voice"
}

drop_voice_from_main() { # a project set up before #273: no voice file, no import
  git -C "$P" rm -q VOICE_STANDARDS.md
  grep -vxF "$IMPORT" "$P/CLAUDE.md" >"$TEST_TMPDIR/claude.md"; cp "$TEST_TMPDIR/claude.md" "$P/CLAUDE.md"
  git -C "$P" commit -q -am "set up before voice standards" && git -C "$P" push -q origin main
}

test_a_rerun_with_no_voice_file_adds_the_file_and_the_import_only() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  drop_voice_from_main
  run_setup >/dev/null
  assert_eq "$(printf 'M\tCLAUDE.md\nA\tVOICE_STANDARDS.md')" "$(git -C "$TEST_TMPDIR/origin.git" diff --name-status main artisan-agent/setup)"
  assert_eq "+$IMPORT" "$(git -C "$TEST_TMPDIR/origin.git" diff -U0 main artisan-agent/setup -- CLAUDE.md | grep '^+[^+]')"
  assert_contains "$(branch_file CLAUDE.md)" "$(printf 'Start with `/artisan-agent:craft`.\n%s' "$IMPORT")"
}

test_a_rerun_with_the_voice_file_and_import_present_changes_nothing() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  local out=; out=$(run_setup)
  assert_contains "$out" "unchanged: the project is already set up; no PR"
  assert_eq 1 "$(grep -cxF "$IMPORT" "$P/CLAUDE.md")" "the import appears once"
}

test_an_edited_voice_file_is_never_overwritten() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  printf -- '- Write in British English.\n' >>"$P/VOICE_STANDARDS.md"
  grep -vxF "$IMPORT" "$P/CLAUDE.md" >"$TEST_TMPDIR/claude.md"; cp "$TEST_TMPDIR/claude.md" "$P/CLAUDE.md"
  git -C "$P" commit -q -am "own voice rule, import dropped" && git -C "$P" push -q origin main
  run_setup >/dev/null
  assert_eq "$(cat "$P/VOICE_STANDARDS.md")" "$(branch_file VOICE_STANDARDS.md)" "the edited voice file changed"
  assert_eq "$(printf 'M\tCLAUDE.md')" "$(git -C "$TEST_TMPDIR/origin.git" diff --name-status main artisan-agent/setup)"
}

test_an_agents_md_only_repo_imports_the_voice_file_there() {
  seed
  git -C "$P" mv CLAUDE.md AGENTS.md && git -C "$P" commit -q -m agents && git -C "$P" push -q origin main
  run_setup >/dev/null
  assert_contains "$(branch_file AGENTS.md)" "$(printf 'Start with `/artisan-agent:craft`.\n%s' "$IMPORT")"
  git -C "$TEST_TMPDIR/origin.git" show artisan-agent/setup:CLAUDE.md >/dev/null 2>&1 && fail "CLAUDE.md created"
  true
}

# #322: the product design standards file is seeded at project setup, offers pointers to
# design docs it finds, adds the journey line to Always ask, and never overwrites.
JOURNEY='- A change to a user journey'

test_a_fresh_repo_gets_design_standards_with_five_sections_and_the_wcag_block() {
  seed
  run_setup >/dev/null
  local d=; d=$(branch_file DESIGN_STANDARDS.md)
  local s=
  for s in Personas "Where the design system lives" "UX conventions" "Accessibility floor" "Always ask"; do
    assert_contains "$d" "## $s"
  done
  assert_contains "$d" "WCAG 2.2 AA"
  assert_contains "$d" "<!-- design-default v1 start"
  assert_contains "$d" "<!-- design-default v1 end -->"
  branch_file DESIGN_STANDARDS.md | cmp -s - "$PLUGIN_ROOT/templates/DESIGN_STANDARDS.md" || fail "not the template"
}

seed_design_docs() {
  mkdir -p "$P/docs/design" "$P/src/components"
  printf '# Art bible\n' >"$P/docs/ART_BIBLE.md"
  printf '# Style guide\n' >"$P/docs/design/style-guide.md"
  printf 'x\n' >"$P/src/components/Button.tsx"
  printf '# Art bible 2\n' >"$P/docs/Style Guide.md"
  git -C "$P" add -A && git -C "$P" commit -q -m "design docs" && git -C "$P" push -q origin main
}

test_scan_offers_the_design_docs_it_finds_and_setup_writes_only_the_accepted_ones() {
  seed
  seed_design_docs
  local scan=; scan=$("$PS" scan "$P")
  assert_contains "$scan" "design-doc	docs/ART_BIBLE.md"
  assert_contains "$scan" "design-doc	docs/design/style-guide.md"
  assert_contains "$scan" "design-doc	src/components"
  assert_contains "$scan" "design-doc	docs/Style Guide.md"
  assert_eq 4 "$(printf '%s\n' "$scan" | grep -c '^design-doc')" "one line per doc, a path with spaces kept whole"
  answers '{"pr_boundary":"slice","pr_level":"product","design_pointers":["docs/ART_BIBLE.md"],"checks":[]}'
  run_setup >/dev/null
  local d=; d=$(branch_file DESIGN_STANDARDS.md)
  assert_contains "$d" '- `docs/ART_BIBLE.md`'
  case "$d" in *style-guide*|*components*) fail "a pointer the Artisan did not accept was written" ;; esac
}

test_no_pointers_are_written_unless_accepted() {
  seed
  seed_design_docs
  run_setup >/dev/null
  case "$(branch_file DESIGN_STANDARDS.md)" in *ART_BIBLE*) fail "pointer written without acceptance" ;; esac
  true
}

test_setup_adds_the_journey_line_to_product_always_ask() {
  seed
  run_setup >/dev/null
  assert_contains "$(branch_file PRODUCT_STANDARDS.md)" "$JOURNEY"
  assert_contains "$(branch_file PRODUCT_STANDARDS.md)" "- Pricing changes"
}

test_a_rerun_keeps_an_edited_design_file_and_journey_line() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  printf -- '- Own persona: Ada.\n' >>"$P/DESIGN_STANDARDS.md"
  sed 's/^- A change to a user journey.*/- Any change to how a person gets through the app (user journey)/' "$P/PRODUCT_STANDARDS.md" >"$TEST_TMPDIR/ps.md"
  cp "$TEST_TMPDIR/ps.md" "$P/PRODUCT_STANDARDS.md"
  git -C "$P" commit -q -am "own edits" && git -C "$P" push -q origin main
  local out=; out=$(run_setup)
  assert_contains "$out" "unchanged: the project is already set up"
  assert_eq "$(cat "$P/DESIGN_STANDARDS.md")" "$(git -C "$P" show HEAD:DESIGN_STANDARDS.md)"
  assert_eq 1 "$(grep -ci 'user journey' "$P/PRODUCT_STANDARDS.md")" "journey line duplicated"
}

test_a_rerun_adds_only_what_is_missing() {
  seed
  run_setup >/dev/null
  merge_setup_pr
  git -C "$P" rm -q DESIGN_STANDARDS.md
  grep -v 'user journey' "$P/PRODUCT_STANDARDS.md" >"$TEST_TMPDIR/ps.md"; cp "$TEST_TMPDIR/ps.md" "$P/PRODUCT_STANDARDS.md"
  git -C "$P" commit -q -am "before design standards" && git -C "$P" push -q origin main
  run_setup >/dev/null
  assert_eq "$(printf 'A\tDESIGN_STANDARDS.md\nM\tPRODUCT_STANDARDS.md')" "$(git -C "$TEST_TMPDIR/origin.git" diff --name-status main artisan-agent/setup)"
}

test_neither_claude_md_nor_agents_md_imports_the_design_standards() {
  seed
  run_setup >/dev/null
  case "$(branch_file CLAUDE.md)" in *DESIGN_STANDARDS*) fail "CLAUDE.md mentions the design standards" ;; esac
  true
}

test_an_agents_md_only_repo_does_not_import_the_design_standards_either() {
  seed
  git -C "$P" mv CLAUDE.md AGENTS.md && git -C "$P" commit -q -m agents && git -C "$P" push -q origin main
  run_setup >/dev/null
  case "$(branch_file AGENTS.md)" in *DESIGN_STANDARDS*) fail "AGENTS.md mentions the design standards" ;; esac
  true
}

# The capture command (#323): proposed from the project type, proven by running
# it once, recorded only when it captured something, kept on a rerun.
test_setup_proposes_a_capture_command_from_the_project_type() {
  seed
  assert_not_contains "$("$PS" scan "$P")" "capture-command	proposed"
  printf 'export default {}\n' >"$P/playwright.config.ts"
  assert_contains "$("$PS" scan "$P")" 'capture-command	proposed	web	npx playwright test --grep "$ARTISAN_CAPTURE_STEP"'
  rm "$P/playwright.config.ts"
  printf '{"name":"mycli","bin":{"mycli":"bin/mycli.js"}}\n' >"$P/package.json"
  assert_contains "$("$PS" scan "$P")" 'capture-command	proposed	cli	node bin/mycli.js "$ARTISAN_CAPTURE_STEP" --help'
  rm "$P/package.json"
  printf '[package]\nname = "tool"\n' >"$P/Cargo.toml"
  assert_contains "$("$PS" scan "$P")" 'capture-command	proposed	cli	cargo run -q -- "$ARTISAN_CAPTURE_STEP" --help'
}

test_prove_capture_runs_the_command_once_and_shows_the_captured_file() {
  seed
  local out= path=
  out=$(cd "$P" && "$PS" prove-capture 'printf PNG >"$ARTISAN_CAPTURE_DIR/$ARTISAN_CAPTURE_STEP.png"')
  assert_contains "$out" "proven	"
  path=${out#proven	}
  assert_eq PNG "$(cat "$path")"
  assert_eq "" "$(git -C "$P" status --porcelain)" "the proof writes nothing into the repo"
  local st=0
  out=$(cd "$P" && "$PS" prove-capture 'echo "no browser" >&2; exit 4') || st=$?
  assert_eq 1 "$st"
  assert_contains "$out" "failed	"
  assert_contains "$out" "no browser"
}

test_setup_records_a_proven_capture_command_and_a_rerun_keeps_it() {
  seed
  local wt= stub='printf PNG >"$ARTISAN_CAPTURE_DIR/$ARTISAN_CAPTURE_STEP.png"'
  wt=$("$PS" begin "$P")
  answers "$(jq -n --arg c "$stub" '{capture_command: $c}')"
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "changed: capture_command is $stub (proven: captured "
  assert_eq "$stub" "$("$PLUGIN_ROOT/scripts/config.sh" show --file "$wt/.artisan-agent/config.yml" | jq -r .capture_command)"
  answers '{}'
  assert_not_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "capture_command"
  answers '{"capture_command":"echo other"}'
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "kept: .artisan-agent/config.yml has capture_command: $stub"
  assert_eq "$stub" "$("$PLUGIN_ROOT/scripts/config.sh" show --file "$wt/.artisan-agent/config.yml" | jq -r .capture_command)"
  "$PS" finish "$wt" >/dev/null
  merge_setup_pr
  assert_contains "$("$PS" scan "$P")" "capture-command	recorded	$stub"
}

test_a_capture_command_that_fails_at_setup_is_not_recorded_and_setup_says_why() {
  seed
  local wt= out=
  wt=$("$PS" begin "$P")
  answers '{"capture_command":"echo \"chromium missing\" >&2; exit 2"}'
  out=$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")
  assert_contains "$out" "not recorded: capture_command failed:"
  assert_contains "$out" "chromium missing"
  assert_eq null "$("$PLUGIN_ROOT/scripts/config.sh" show --file "$wt/.artisan-agent/config.yml" | jq .capture_command)"
  answers '{"capture_command":"true"}'
  assert_contains "$("$PS" apply "$wt" "$TEST_TMPDIR/answers.json")" "captured nothing"
}
