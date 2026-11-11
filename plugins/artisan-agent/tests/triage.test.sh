# Tests for the triage skill's scripts: record-miss.sh and deferred-due.sh.

SCRIPTS="$PLUGIN_ROOT/skills/triage/scripts"

test_record_miss_appends_readable_json_line() {
  ARTISAN_AGENT_DIR="$TEST_TMPDIR/state" "$SCRIPTS/record-miss.sh" '#12' 3 "do" "defer" 'adds a "dependency"'
  local f="$TEST_TMPDIR/state/triage/misses.jsonl" line
  line=$(cat "$f")
  assert_contains "$line" '"ticket":12'
  assert_contains "$line" '"recommended":"do"'
  assert_contains "$line" '"ruled":"defer"'
  assert_contains "$line" '"criterion_that_should_have_caught_it":3'
  assert_contains "$line" '"reason":"adds a \"dependency\""'
  assert_contains "$line" '"run_id":null'
}

test_record_miss_appends_and_ignores_itself_in_git() {
  export ARTISAN_AGENT_DIR="$TEST_TMPDIR/state"
  "$SCRIPTS/record-miss.sh" 1 new do discard "nothing covered it"
  ARTISAN_RUN_ID=run-7 "$SCRIPTS/record-miss.sh" 2 4 do needs-triage "taste"
  assert_eq 2 "$(wc -l < "$TEST_TMPDIR/state/triage/misses.jsonl" | tr -d ' ')" "line count"
  assert_contains "$(sed -n 1p "$TEST_TMPDIR/state/triage/misses.jsonl")" '"criterion_that_should_have_caught_it":null'
  assert_contains "$(sed -n 2p "$TEST_TMPDIR/state/triage/misses.jsonl")" '"run_id":"run-7"'
  assert_eq '*' "$(cat "$TEST_TMPDIR/state/triage/.gitignore")" "self-ignoring folder"
}

test_record_miss_rejects_bad_input() {
  export ARTISAN_AGENT_DIR="$TEST_TMPDIR/state"
  assert_status 2 "$SCRIPTS/record-miss.sh" abc 3 do defer why
  assert_status 2 "$SCRIPTS/record-miss.sh" 5 9 do defer why
  assert_status 2 "$SCRIPTS/record-miss.sh" 5 3 do defer
}

# A stub gh that serves a seeded tracker: #10 date passed, #11 date in future,
# #12 blocked by closed #20, #13 blocked by open #21, #14 no return condition.
make_stub_gh() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "issue list"*)
    printf '10\tOld date\tReason: x\\nReturn condition: date 2026-10-01\n'
    printf '11\tFuture date\tReturn condition: next review on 2026-12-31\n'
    printf '12\tEvent closed\tReturn condition: blocked-by #20\n'
    printf '13\tEvent open\tReturn condition: blocked-by #21\n'
    printf '14\tNo condition\t\n'
    ;;
  "issue view 20"*) echo CLOSED ;;
  "issue view 21"*) echo OPEN ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
}

test_deferred_due_surfaces_passed_date_and_closed_blocker() {
  make_stub_gh
  local out
  out=$(PATH="$TEST_TMPDIR/bin:$PATH" ARTISAN_TODAY=2026-11-10 "$SCRIPTS/deferred-due.sh")
  assert_contains "$out" '#10 Old date: date 2026-10-01 has passed'
  assert_contains "$out" '#12 Event closed: blocking event closed (#20)'
  assert_contains "$out" '#14 No condition: gap'
  case "$out" in *'#11'*|*'#13'*) fail "not-due ticket listed: $out" ;; esac
}

test_deferred_due_does_not_list_a_date_that_has_not_come() {
  make_stub_gh
  local out
  out=$(PATH="$TEST_TMPDIR/bin:$PATH" ARTISAN_TODAY=2026-09-01 "$SCRIPTS/deferred-due.sh")
  case "$out" in *'#10'*) fail "#10 not yet due on 2026-09-01" ;; esac
  assert_contains "$out" '#12'
}

test_record_miss_zero_padded_numbers_are_valid_json() {
  export ARTISAN_AGENT_DIR="$TEST_TMPDIR/state"
  "$SCRIPTS/record-miss.sh" 02 7 Do Defer x
  "$SCRIPTS/record-miss.sh" '#02' 7 Do Defer x
  "$SCRIPTS/record-miss.sh" 000 new Do Defer x
  local f="$TEST_TMPDIR/state/triage/misses.jsonl" line n=0
  while IFS= read -r line; do
    printf '%s' "$line" | python3 -I -m json.tool >/dev/null || fail "invalid JSON: $line"
    n=$((n+1))
  done < "$f"
  assert_eq 3 "$n" "lines"
  assert_contains "$(sed -n 1p "$f")" '"ticket":2,'
  assert_contains "$(sed -n 2p "$f")" '"ticket":2,'
  assert_contains "$(sed -n 3p "$f")" '"ticket":0,'
}

test_backlog_review_prompt_resolves_plugin_without_plugin_root() {
  local md="$PLUGIN_ROOT/skills/triage/backlog-review.md" line
  # Inside the pasted prompt, plugin paths use $ROOT, never the unset variable.
  local prompt; prompt=$(sed -n '/^````text/,/^````$/p' "$md")
  assert_contains "$prompt" 'claude plugin list --json'
  if printf '%s\n' "$prompt" | grep -v 'ROOT=' | grep -q 'CLAUDE_PLUGIN_ROOT'; then fail "prompt uses \${CLAUDE_PLUGIN_ROOT} outside the resolver"; fi
  if printf '%s\n' "$prompt" | grep -q 'find /'; then fail "prompt mentions find /"; fi
  # Run the resolver with the variable unset and a stub claude.
  line=$(printf '%s\n' "$prompt" | grep '^ *ROOT=' | sed 's/^ *//')
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/installed"
  cat > "$TEST_TMPDIR/bin/claude" <<STUB
#!/usr/bin/env bash
[ "\$*" = "plugin list --json" ] || exit 1
cat <<JSON
[{"id":"mattpocock-skills@claude-plugins-official","enabled":true,"installPath":"/nope"},
 {"id":"artisan-agent@artisan-agent","enabled":false,"installPath":"/disabled"},
 {"id":"artisan-agent@artisan-agent","enabled":true,"installPath":"$TEST_TMPDIR/installed"}]
JSON
STUB
  chmod +x "$TEST_TMPDIR/bin/claude"
  local out; out=$(env -u CLAUDE_PLUGIN_ROOT PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$line")
  assert_eq "$TEST_TMPDIR/installed" "$out" "resolved root"
  out=$(CLAUDE_PLUGIN_ROOT=/set PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$line")
  assert_eq /set "$out" "variable wins when set"
}

test_triage_identity_follows_the_tracker_doc() {
  local skill="$PLUGIN_ROOT/skills/triage/SKILL.md"
  if grep -q 'gh api user' "$skill"; then fail "triage SKILL.md hardcodes gh api user"; fi
  assert_contains "$(cat "$skill")" 'docs/agents/issue-tracker.md'
  assert_contains "$(cat "$skill")" 'on a local-markdown tracker make no `gh` call'
}
