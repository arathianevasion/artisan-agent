# The upstream-updates check (#75): scripts/upstream-check.sh, on fake upstream trees,
# a fake marketplace, the fake tracker and a stub claude. No network, no real plugins.

UC="$PLUGIN_ROOT/scripts/upstream-check.sh"

# mk_tree DIR [flag-for-triage]: a tiny upstream with every dependency and replaced skill.
mk_tree() {
  local d=$1 n= flag=
  mkdir -p "$d/docs/agents"
  for n in $(sed -e 's/#.*//' "$PLUGIN_ROOT/guard/dependencies.list" | grep -v '^$') \
           $(bash "$PLUGIN_ROOT/guard/guard.sh" flag-watch | sed 's/^mattpocock-skills://'); do
    mkdir -p "$d/skills/engineering/$n"
    flag=
    case "$n" in implement|triage|retro|to-spec|grill-with-docs|implement-spec|wayfinder|to-tickets) flag="disable-model-invocation: true" ;; esac
    printf -- '---\nname: %s\n%s\ndescription: x\n---\nBody. See docs/agents/issue-tracker.md\n' "$n" "$flag" >"$d/skills/engineering/$n/SKILL.md"
  done
  for n in issue-tracker triage-labels domain; do printf '# %s\n' "$n" >"$d/docs/agents/$n.md"; done
  cat >"$d/docs/agents/triage-labels.md" <<'T'
| Label in mattpocock/skills | Label in our tracker | Meaning |
| -------------------------- | -------------------- | ------- |
| `needs-triage`             | `needs-triage`       | a       |
| `wontfix`                  | `wontfix`            | b       |
T
}

# env: a fake home with an installed upstream at sha OLD and a marketplace pinning NEW.
setup_env() {
  export HOME_DIR_T="$TEST_TMPDIR/ind"; mkdir -p "$HOME_DIR_T"
  export ARTISAN_HOME="$HOME_DIR_T" CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg"
  mk_tree "$TEST_TMPDIR/old"
  OLDSHA=aaaaaaa1111111111111111111111111111111111; NEWSHA=bbbbbbb2222222222222222222222222222222222
  [ "${1:-moved}" = same ] && NEWSHA=$OLDSHA
  export ARTISAN_PLUGINS_JSON="$TEST_TMPDIR/installed.json" ARTISAN_MARKETPLACE_JSON="$TEST_TMPDIR/market.json"
  cat >"$ARTISAN_PLUGINS_JSON" <<J
{"plugins":{"mattpocock-skills@claude-plugins-official":[{"scope":"user","installPath":"$TEST_TMPDIR/old","version":"1.0.0","gitCommitSha":"$OLDSHA"}]}}
J
  cat >"$ARTISAN_MARKETPLACE_JSON" <<J
{"plugins":[{"name":"mattpocock-skills","source":{"source":"url","url":"$TEST_TMPDIR/upstream.git","sha":"$NEWSHA"}}]}
J
}

# A real git repo for the new upstream, so fetch is exercised; mutate it with $1 before committing.
mk_upstream() { # mutation-command (run inside the tree, optional)
  local t="$TEST_TMPDIR/newsrc"
  mk_tree "$t"
  [ -z "${1:-}" ] || (cd "$t" && eval "$1")
  (cd "$t" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@x commit -qm new)
  git clone -q --bare "$t" "$TEST_TMPDIR/upstream.git"
  NEWSHA=$(git -C "$t" rev-parse HEAD)
  cat >"$ARTISAN_MARKETPLACE_JSON" <<J
{"plugins":[{"name":"mattpocock-skills","source":{"source":"url","url":"$TEST_TMPDIR/upstream.git","sha":"$NEWSHA"}}]}
J
}

mech() { bash "$UC" mechanical --old "$TEST_TMPDIR/old" --new "$1"; }

test_unchanged_upstream_reports_no_change_and_runs_no_checks() {
  setup_env same
  local out=
  # A stub claude that would leave a mark if the judgement agent ran.
  printf '#!/bin/bash\ntouch "%s/claude-ran"\n' "$TEST_TMPDIR" >"$TEST_TMPDIR/claude"; chmod +x "$TEST_TMPDIR/claude"
  out=$(ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude" bash "$UC" run "$TEST_TMPDIR/w")
  assert_contains "$out" "no upstream change"
  [ ! -e "$TEST_TMPDIR/claude-ran" ] || fail "the judgement agent ran"
  [ ! -e "$TEST_TMPDIR/w/mechanical.txt" ] || fail "the mechanical check ran"
}

test_identical_trees_pass_the_mechanical_check() {
  setup_env
  mk_tree "$TEST_TMPDIR/n"
  assert_contains "$(mech "$TEST_TMPDIR/n")" "ok docs-agents"
}

test_a_removed_dependency_skill_fails() {
  setup_env; mk_tree "$TEST_TMPDIR/n"; rm -rf "$TEST_TMPDIR/n/skills/engineering/tdd"
  local out=; out=$(mech "$TEST_TMPDIR/n" || true)
  assert_contains "$out" "FAIL dependency tdd"
  assert_status 1 mech "$TEST_TMPDIR/n"
}

test_a_flipped_flag_on_a_replaced_skill_fails() {
  setup_env; mk_tree "$TEST_TMPDIR/n"
  sed -i.bak '/^disable-model-invocation/d' "$TEST_TMPDIR/n/skills/engineering/triage/SKILL.md"
  local out=; out=$(mech "$TEST_TMPDIR/n" || true)
  assert_contains "$out" "FAIL flag triage disable-model-invocation was true, now false"
  assert_status 1 mech "$TEST_TMPDIR/n"
}

test_a_flipped_flag_on_a_dependency_skill_fails() {
  setup_env; mk_tree "$TEST_TMPDIR/n"
  sed -i.bak 's/^description: x/disable-model-invocation: true\ndescription: x/' "$TEST_TMPDIR/n/skills/engineering/tdd/SKILL.md"
  assert_contains "$(mech "$TEST_TMPDIR/n" || true)" "FAIL flag tdd"
}

test_a_renamed_docs_agents_file_fails() {
  setup_env; mk_tree "$TEST_TMPDIR/n"
  mv "$TEST_TMPDIR/n/docs/agents/domain.md" "$TEST_TMPDIR/n/docs/agents/context.md"
  local out=; out=$(mech "$TEST_TMPDIR/n" || true)
  assert_contains "$out" "FAIL docs-agents domain.md"
  assert_status 1 mech "$TEST_TMPDIR/n"
}

test_a_renamed_label_fails() {
  setup_env; mk_tree "$TEST_TMPDIR/n"
  sed -i.bak 's/| `wontfix`   /| `rejected`  /' "$TEST_TMPDIR/n/docs/agents/triage-labels.md"
  local out=; out=$(mech "$TEST_TMPDIR/n" || true)
  assert_contains "$out" "FAIL label wontfix"
  assert_status 1 mech "$TEST_TMPDIR/n"
}

test_it_reads_the_guards_lists_not_its_own() {
  # Adding a name to the guard's flag-watch list is enough to watch its flag.
  setup_env; mk_tree "$TEST_TMPDIR/n"
  for s in implement; do :; done
  local out=; out=$(mech "$TEST_TMPDIR/n")
  local n=
  for n in $(bash "$PLUGIN_ROOT/guard/guard.sh" flag-watch | sed 's/^mattpocock-skills://') \
           $(sed -e 's/#.*//' "$PLUGIN_ROOT/guard/dependencies.list" | grep -v '^$'); do
    assert_contains "$out" " $n"
  done
}

# A stub claude: writes the judgement named in the prompt from $JUDGE_JSON.
stub_claude() {
  cat >"$TEST_TMPDIR/claude" <<'S'
#!/bin/bash
out=$(printf '%s' "$*" | sed -n 's/.*Write your answer to: \([^ ]*judgement.json\).*/\1/p' | head -1)
printf '%s' "$JUDGE_JSON" >"$out"
printf '%s' "$*" >"$(dirname "$out")/prompt-seen"
echo '{"result":"done"}'
S
  chmod +x "$TEST_TMPDIR/claude"
  export ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude"
}

fake_tracker() {
  export FAKE_GH_DIR="$TEST_TMPDIR/gh"; mkdir -p "$FAKE_GH_DIR"
  echo '{"number":1,"title":"x","body":"","state":"open","labels":[]}' >"$FAKE_GH_DIR/issue-1.json"
  export GH_BIN="$TESTS_DIR/fixtures/fake-gh/gh"
}

test_moved_upstream_lists_ports_and_behaviour_changes_and_offers_the_update() {
  setup_env; mk_upstream ""; stub_claude; fake_tracker
  printf '# notes\n- watch triage\n' >"$ARTISAN_HOME/upstream-notes.md"
  export JUDGE_JSON='{"port":[{"skill":"triage","title":"batch labels","why":"fewer calls"}],"behaviour":[{"skill":"tdd","change":"asks for seams first"}],"artisan_md":[],"breaking":[]}'
  local out=; out=$(bash "$UC" run "$TEST_TMPDIR/w")
  assert_contains "$out" "Improvements worth porting"
  assert_contains "$out" "| triage | batch labels | fewer calls |"
  assert_contains "$out" "| tdd | asks for seams first |"
  assert_contains "$out" "Update upstream to"
  # The agent was given the notes from the individual home and the guard's lists.
  assert_contains "$(cat "$TEST_TMPDIR/w/prompt-seen")" "watch triage"
  assert_contains "$(cat "$TEST_TMPDIR/w/prompt-seen")" "grill-with-docs"
  # No ticket is filed for an offer.
  [ ! -e "$FAKE_GH_DIR/issue-2.json" ] || fail "a ticket was filed"
}

test_a_breaking_change_files_a_ticket_and_withholds_the_offer() {
  setup_env; mk_upstream 'rm -rf skills/engineering/tdd'; stub_claude; fake_tracker
  export JUDGE_JSON='{"port":[],"behaviour":[],"artisan_md":[],"breaking":[]}'
  local out=; out=$(bash "$UC" run "$TEST_TMPDIR/w")
  assert_contains "$out" "no longer exists"
  assert_contains "$out" "Filed pipeline ticket #2"
  case "$out" in *"Update upstream to"*) fail "the update was offered" ;; esac
  assert_contains "$(cat "$FAKE_GH_DIR/issue-2.json")" "needs-triage"
  # The next retro, with the ticket still open, still withholds and runs no checks.
  out=$(bash "$UC" run "$TEST_TMPDIR/w2")
  assert_contains "$out" "withheld: blocked by #2"
  [ ! -e "$TEST_TMPDIR/w2/mechanical.txt" ] || fail "checks ran while blocked"
}

test_a_breaking_judgement_entry_also_blocks() {
  setup_env; mk_upstream ""; stub_claude; fake_tracker
  export JUDGE_JSON='{"port":[],"behaviour":[{"skill":"tdd","change":"x"}],"artisan_md":[],"breaking":[{"skill":"tdd","title":"output renamed","why":"implement parses it"}]}'
  local out=; out=$(bash "$UC" run "$TEST_TMPDIR/w")
  assert_contains "$out" "Filed pipeline ticket #2"
  assert_contains "$(cat "$FAKE_GH_DIR/issue-2.json")" "output renamed"
}

test_file_ports_files_one_ticket_per_candidate() {
  setup_env; mk_upstream ""; stub_claude; fake_tracker
  export JUDGE_JSON='{"port":[{"skill":"triage","title":"batch labels","why":"w"}],"behaviour":[],"artisan_md":[{"skill":"grilling","rule":"2","why":"asks without a recommendation"}],"breaking":[]}'
  bash "$UC" run "$TEST_TMPDIR/w" >/dev/null
  assert_contains "$(bash "$UC" file-ports "$TEST_TMPDIR/w")" "port #2"
  assert_contains "$(cat "$FAKE_GH_DIR/issue-3.json")" "ARTISAN.md"
}

test_judge_brief_names_rule_7_and_asks_for_voice_overlap_flags() {
  local judge; judge=$(cat "$PLUGIN_ROOT/skills/retro/JUDGE.md")
  assert_contains "$judge" "rule 7"
  assert_contains "$judge" "voice_overlap"
  assert_contains "$judge" "rule id"
  assert_contains "$judge" "upstream skill"
}

test_report_renders_voice_overlap_flags_in_a_table() {
  setup_env; mk_upstream ""; stub_claude; fake_tracker
  export JUDGE_JSON='{"port":[],"behaviour":[],"artisan_md":[],"breaking":[],"voice_overlap":[{"skill":"writing-for-agents","rule":"no-filler-openers","why":"upstream now bans filler openers"}]}'
  local out; out=$(bash "$UC" run "$TEST_TMPDIR/w")
  assert_contains "$out" "Voice rules upstream now covers"
  assert_contains "$out" "| Rule | Upstream skill | Why |"
  assert_contains "$out" "| no-filler-openers | writing-for-agents | upstream now bans filler openers |"
}

test_report_on_a_fixture_judgement_renders_voice_overlap_rows() {
  local w="$TEST_TMPDIR/rw"; mkdir -p "$w"
  printf 'x\taaaaaaa\tbbbbbbb\n' >"$w/moved.tsv"; : >"$w/mechanical.txt"
  echo '{"port":[],"behaviour":[],"artisan_md":[],"breaking":[],"voice_overlap":[{"skill":"writing-for-agents","rule":"no-openers","why":"covered"},{"skill":"grilling","rule":"no-recaps","why":"covered too"}]}' >"$w/judgement.json"
  setup_env; mk_upstream ""
  local out; out=$(bash "$UC" report "$w" 2>&1) || true
  assert_contains "$out" "| no-openers | writing-for-agents | covered |"
  assert_contains "$out" "| no-recaps | grilling | covered too |"
}

test_upstream_notes_are_read_where_the_retro_delivers_them() {
  # retro.sh delivers to $ARTISAN_HOME/upstream-notes.md; this reads the same file.
  assert_contains "$(grep -n 'upstream-notes.md' "$PLUGIN_ROOT/skills/retro/scripts/retro.sh")" 'HOME_DIR/upstream-notes.md'
  assert_contains "$(grep -n 'upstream-notes.md' "$PLUGIN_ROOT/scripts/upstream-check.sh")" 'HOME_DIR/upstream-notes.md'
}

test_file_ports_twice_files_nothing_twice_and_keeps_empty_fields() {
  setup_env; mk_upstream ""; stub_claude; fake_tracker
  export JUDGE_JSON='{"port":[{"skill":"triage","title":"batch labels","why":""}],"behaviour":[],"artisan_md":[],"breaking":[]}'
  bash "$UC" run "$TEST_TMPDIR/w" >/dev/null
  bash "$UC" file-ports "$TEST_TMPDIR/w" >/dev/null
  assert_contains "$(cat "$FAKE_GH_DIR/issue-2.json")" "batch labels"
  assert_contains "$(bash "$UC" file-ports "$TEST_TMPDIR/w")" "already filed"
  [ ! -e "$FAKE_GH_DIR/issue-3.json" ] || fail "a duplicate ticket was filed"
}

# --- the judge never waits on a permission prompt (#214) ---

# A stub that, like dontAsk, writes the answer only when --allowedTools lists
# Write (and Bash(diff:*), which the brief asks for), and otherwise reports
# the denial in its result event.
allowlist_claude() {
  cat >"$TEST_TMPDIR/claude" <<'S'
#!/bin/bash
printf '[%s]\n' "$@" >"$TEST_TMPDIR/claude.args"
mode= tools= prompt=
while [ $# -gt 0 ]; do
  case "$1" in --permission-mode) mode=$2 ;; --allowedTools) tools=$2 ;; -p) prompt=$2 ;; esac; shift
done
out=$(printf '%s' "$prompt" | sed -n 's/.*Write your answer to: \([^ ]*judgement.json\).*/\1/p' | head -1)
case ",$tools," in
  *,Write,*) [ "$mode" = dontAsk ] && printf '%s' "$JUDGE_JSON" >"$out"; echo '{"result":"done"}' ;;
  *) echo '{"result":"stopped","permission_denials":[{"tool_name":"Write","tool_input":{}}]}' ;;
esac
S
  chmod +x "$TEST_TMPDIR/claude"
  export ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/claude"
}

test_the_judge_starts_in_dontask_with_an_allowlist_for_its_brief() {
  setup_env; mk_upstream ""; allowlist_claude; fake_tracker
  export TEST_TMPDIR JUDGE_JSON='{"port":[],"behaviour":[],"artisan_md":[],"breaking":[]}'
  bash "$UC" run "$TEST_TMPDIR/w" >/dev/null
  local args=; args=$(cat "$TEST_TMPDIR/claude.args")
  assert_contains "$args" "[--permission-mode]
[dontAsk]"
  assert_contains "$args" "[--allowedTools]
[Read,Glob,Grep,Write,Bash(diff:*)]"
  [ -s "$TEST_TMPDIR/w/judgement.json" ] || fail "the judge could not write judgement.json with only the listed tools"
}

test_a_denied_tool_under_the_shim_ends_the_judge_promptly_with_the_denial_reported() {
  setup_env; mk_upstream ""; fake_tracker
  unset ARTISAN_CLAUDE_BIN
  export FAKE_CLAUDE_MODE=deny FAKE_SHIM_LOG="$TEST_TMPDIR/shim.log"
  local out= i=0 pid=
  PATH="$TESTS_DIR/fixtures/fake-cmux-shim:$TESTS_DIR/fixtures/fake-claude:$PATH" \
    bash "$UC" run "$TEST_TMPDIR/w" >"$TEST_TMPDIR/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fail "the upstream check waited on the shim's prompt"; fi
  wait "$pid" && fail "the upstream check passed with no judgement" || true
  out=$(cat "$TEST_TMPDIR/out")
  assert_contains "$out" "wrote no"
  assert_contains "$out" "denied tools: Bash"
  assert_eq shim "$(cat "$FAKE_SHIM_LOG")" "the shim started the session"
}
