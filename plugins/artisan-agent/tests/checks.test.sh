# checks.sh: the one reader of CODING_STANDARDS.md `## Checks`, tested on
# what setup really writes (project-setup.sh apply, through
# project-setup.test.sh's throwaway repo and stub gh), and its fallback when
# nothing is recorded.

. "$TESTS_DIR/project-setup.test.sh"
# Only this file's tests run here; project-setup.test.sh's run in their own file.
for _f in $(declare -F | awk '$3 ~ /^test_/ && $3 !~ /^test_c_/ {print $3}'); do unset -f "$_f"; done
unset _f

CHECKS="$PLUGIN_ROOT/scripts/checks.sh"

# A project whose setup proved two checks (./test.sh and ./lint.sh) and was
# merged, plus a Makefile target a discovery would find but nobody recorded.
# It writes ran-make-test when it runs.
setup_with_checks() {
  seed_checks
  printf '#!/bin/sh\necho "lint ok"\ngrep -qx ok value\n' >"$P/lint.sh"
  chmod +x "$P/lint.sh"
  printf 'test:\n\ttouch ran-make-test\n' >"$P/Makefile"
  git -C "$P" add -A && git -C "$P" commit -q -m "lint, make"
  git -C "$P" push -q origin main
  answers '{"checks":[{"command":"./test.sh","break_cmd":"echo broken >value","break":"wrote a wrong value"},
                      {"command":"./lint.sh","break_cmd":"echo broken >value","break":"wrote a wrong value, again"}]}'
  run_setup >/dev/null
  merge_setup_pr
}

test_c_reads_exactly_the_checks_setup_recorded() {
  setup_with_checks
  # setup's own scan finds more than it recorded: make test is a candidate.
  assert_contains "$("$PS" scan "$P")" "check	Makefile	make test"
  local json
  json=$(cd "$P" && "$CHECKS" json)
  assert_eq true "$(printf '%s' "$json" | jq -r .recorded)"
  assert_eq "./test.sh ./lint.sh" "$(printf '%s' "$json" | jq -r '[.checks[].command] | join(" ")')"
  assert_eq "wrote a wrong value" "$(printf '%s' "$json" | jq -r '.checks[0].break')"
  assert_eq "$(date +%Y-%m-%d)" "$(printf '%s' "$json" | jq -r '.checks[1].proven_on')"
  assert_eq "./test.sh
./lint.sh" "$(cd "$P" && "$CHECKS" list)"
}

test_c_the_suite_runs_every_recorded_check_and_fails_if_one_does() {
  setup_with_checks
  local suite
  suite=$(cd "$P" && "$CHECKS" suite)
  assert_eq "( ./test.sh ) && ( ./lint.sh )" "$suite"
  (cd "$P" && sh -c "$suite") >/dev/null || fail "the suite is red on a green project"
  echo broken >"$P/value"
  if (cd "$P" && sh -c "$suite") >/dev/null 2>&1; then fail "the suite stayed green with a check red"; fi
}

test_c_run_runs_only_the_recorded_checks_and_reports_each() {
  setup_with_checks
  local out rc=0
  out=$(cd "$P" && "$CHECKS" run --out "$TEST_TMPDIR/checks.json" -- "make test") || rc=$?
  assert_eq 0 "$rc"
  assert_eq "./test.sh:true ./lint.sh:true" "$(printf '%s' "$out" | jq -r '[.results[] | "\(.command):\(.passed)"] | join(" ")')"
  assert_eq "lint ok" "$(printf '%s' "$out" | jq -r '.results[1].result')"
  assert_eq '["make test"]' "$(printf '%s' "$out" | jq -c .not_run)"
  [ ! -e "$P/ran-make-test" ] || fail "a discovered command that isn't recorded was run"
  cmp -s <(printf '%s\n' "$out") "$TEST_TMPDIR/checks.json" || fail "--out differs from what was printed"
  assert_contains "$(cat "$TEST_TMPDIR/checks.logs/2.log")" "lint ok"
}

# A project that recorded one check, its whole suite (./test.sh).
setup_with_suite_check() {
  seed_checks
  git -C "$P" push -q origin main
  answers '{"checks":[{"command":"./test.sh","break_cmd":"echo broken >value","break":"wrote a wrong value"}]}'
  run_setup >/dev/null
  merge_setup_pr
}

test_c_a_worker_skips_a_recorded_check_that_is_the_suite_and_says_so() {
  setup_with_suite_check
  local out rc=0
  out=$(cd "$P" && "$CHECKS" run --worker) || rc=$?
  assert_eq 0 "$rc"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c .results)"
  assert_eq "./test.sh: left to the merge gate (it is the run's suite command)" "$(printf '%s' "$out" | jq -r '.not_run[0]')"
}

test_c_the_verifier_and_the_gate_still_run_the_suite_check() {
  setup_with_suite_check
  local out
  out=$(cd "$P" && "$CHECKS" run)
  assert_eq "./test.sh:true" "$(printf '%s' "$out" | jq -r '[.results[] | "\(.command):\(.passed)"] | join(" ")')"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c .not_run)"
  [ "$(cd "$P" && "$CHECKS" suite)" = "./test.sh" ] || fail "the gate's suite is not the check"
}

test_c_a_worker_skips_the_check_equal_to_the_plans_suite_command_and_runs_the_rest() {
  setup_with_checks
  local out
  out=$(cd "$P" && "$CHECKS" run --worker --suite ./test.sh)
  assert_eq "./lint.sh:true" "$(printf '%s' "$out" | jq -r '[.results[] | "\(.command):\(.passed)"] | join(" ")')"
  assert_contains "$(printf '%s' "$out" | jq -r '.not_run[0]')" "./test.sh: left to the merge gate"
}

test_c_a_worker_still_runs_every_check_when_none_is_the_suite() {
  setup_with_checks
  local out
  out=$(cd "$P" && "$CHECKS" run --worker)
  assert_eq "./test.sh:true ./lint.sh:true" "$(printf '%s' "$out" | jq -r '[.results[] | "\(.command):\(.passed)"] | join(" ")')"
}

test_c_a_red_recorded_check_is_reported_red_and_the_rest_still_run() {
  setup_with_checks
  echo broken >"$P/value"
  local out rc=0
  out=$(cd "$P" && "$CHECKS" run) || rc=$?
  assert_eq 7 "$rc"
  assert_eq "false false" "$(printf '%s' "$out" | jq -r '[.results[].passed] | join(" ")')"
  assert_eq 1 "$(printf '%s' "$out" | jq -r '.results[0].exit_code')"
}

test_c_with_none_recorded_each_command_says_so_and_names_what_was_found() {
  seed_checks
  local rc=0 out
  (cd "$P" && "$CHECKS" list) 2>"$TEST_TMPDIR/err" || rc=$?
  assert_eq 16 "$rc"
  assert_contains "$(cat "$TEST_TMPDIR/err")" "no recorded checks (no CODING_STANDARDS.md)"
  rc=0; (cd "$P" && "$CHECKS" suite) >/dev/null 2>&1 || rc=$?
  assert_eq 16 "$rc"
  out=$(cd "$P" && "$CHECKS" run -- ./test.sh)
  assert_eq false "$(printf '%s' "$out" | jq -r .recorded)"
  assert_eq 'no recorded checks (no CODING_STANDARDS.md): found `./test.sh`' "$(printf '%s' "$out" | jq -r .fallback)"
  assert_eq true "$(printf '%s' "$out" | jq -r '.results[0].passed')"
  rc=0; out=$(cd "$P" && "$CHECKS" run) || rc=$?
  assert_eq 16 "$rc"
  assert_contains "$(printf '%s' "$out" | jq -r .fallback)" "found nothing"
}

test_c_a_standards_file_without_checks_gives_its_reason() {
  mkdir p
  printf '# Coding standards\n\n## Always ask\n\n- New dependencies\n' >p/CODING_STANDARDS.md
  assert_eq "CODING_STANDARDS.md has no ## Checks section" "$("$CHECKS" json --dir p | jq -r .reason)"
  printf '\n## Checks\n\nNone chosen yet.\n\n## Guardrails\n\n- `pr-boundaries`: one PR per slice\n' >>p/CODING_STANDARDS.md
  assert_eq "## Checks in CODING_STANDARDS.md lists no checks" "$("$CHECKS" json --dir p | jq -r .reason)"
}

test_c_hand_written_lines_count_and_fences_comments_and_repeats_do_not() {
  mkdir p
  cat >p/CODING_STANDARDS.md <<'EOF'
# Coding standards

## Checks

- `npm test`: proven to fail on 2026-11-01, breaking: flipped an assertion
* `make lint`
<!--
- `make old`
-->
```
- `in a fence`
```
- `npm test`: again
- not a check

## Guardrails

- `pr-boundaries`: one PR per slice
EOF
  assert_eq "npm test|make lint" "$("$CHECKS" json --file p/CODING_STANDARDS.md | jq -r '[.checks[].command] | join("|")')"
  assert_eq "npm test" "$("$CHECKS" suite --dir p | sed 's/^( //; s/ ) &&.*//')"
}

test_c_an_out_path_with_quotes_still_writes_valid_json() {
  setup_with_checks
  local out
  out=$(cd "$P" && "$CHECKS" run --out "$TEST_TMPDIR/a \"q\" \\b/checks.json")
  assert_contains "$(printf '%s' "$out" | jq -r '.results[0].log')" 'a "q" \b/checks.logs/1.log'
}
