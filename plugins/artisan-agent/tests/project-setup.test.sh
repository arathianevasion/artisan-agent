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

test_the_ten_labels_exist_on_the_tracker_and_in_the_doc() {
  seed
  run_setup >/dev/null
  local l= doc=; doc=$(branch_file docs/agents/triage-labels.md)
  for l in needs-triage needs-info ready-for-agent ready-for-human wontfix review-gate plan in-run urgent deferred; do
    grep -qx "$l" "$TEST_TMPDIR/labels" || fail "label $l not on the tracker"
    assert_contains "$doc" "\`$l\`"
  done
  assert_eq 0 "$(grep -c '^label create needs-triage' "$TEST_TMPDIR/gh-calls" || true)" "existing label recreated"
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
  assert_eq block "$(printf '%s' "$out" | jq -r .decision)"
  assert_contains "$out" "Use /artisan-agent:triage instead."
}

test_hook_probe_reports_whether_plugin_hooks_fire() {
  seed
  printf '#!/bin/sh\necho "$*" >>"%s/claude-calls"\necho "{\\"result\\":\\"UserPromptExpansion operation blocked by hook: Blocked by the artisan-agent replaced-skill guard: x\\"}"\n' "$TEST_TMPDIR" >"$ARTISAN_CLAUDE_BIN"
  chmod +x "$ARTISAN_CLAUDE_BIN"
  assert_eq fires "$("$PS" hook-probe "$P")"
  assert_contains "$(cat "$TEST_TMPDIR/claude-calls")" "--max-budget-usd"
  printf '#!/bin/sh\necho "{\\"result\\":\\"ok\\"}"\n' >"$ARTISAN_CLAUDE_BIN"
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
