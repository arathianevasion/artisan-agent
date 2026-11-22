# design.sh (#324): the design stage's start, status and resume, against a
# throwaway repo and the fake gh (fixtures/fake-gh), so nothing touches GitHub.

DESIGN="$PLUGIN_ROOT/skills/design/scripts/design.sh"

# A product repo whose main records a capture command that "screenshots" a step
# by copying the build's marker file, checked out on another branch so a
# capture from the checkout instead of main shows.
seed() {
  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR"
  PATH="$TESTS_DIR/fixtures/fake-gh:$PATH"
  export PATH GIT_CONFIG_GLOBAL=/dev/null
  P="$TEST_TMPDIR/proj"
  git init -q -b main "$P"
  git -C "$P" config user.name t && git -C "$P" config user.email t@t
  mkdir -p "$P/.artisan-agent"
  printf 'main build\n' >"$P/build.txt"
  printf "capture_command: 'cp build.txt \"\$ARTISAN_CAPTURE_DIR/\$ARTISAN_CAPTURE_STEP.png\"'\n" >"$P/.artisan-agent/config.yml"
  git -C "$P" add -A && git -C "$P" commit -q -m init
  git -C "$P" checkout -q -b work
  printf 'work in progress\n' >"$P/build.txt"
  git -C "$P" commit -q -am wip
  cd "$P"
}

start_checkout() {
  "$DESIGN" start --name "Faster checkout" --step cart --step pay --designer ana
}

issue() { cat "$FAKE_GH_DIR/issue-$1.json"; }

test_start_opens_a_design_ticket_labelled_design() {
  seed
  local out=
  out=$(start_checkout)
  assert_contains "$out" "design ticket: #1"
  assert_eq design "$(issue 1 | jq -r '.labels[].name')"
  assert_contains "$(issue 1 | jq -r .title)" "Faster checkout"
}

test_start_cuts_the_feature_and_prototype_branches_from_main() {
  seed
  start_checkout >/dev/null
  local main=
  main=$(git rev-parse main)
  assert_eq "$main" "$(git rev-parse feature/faster-checkout)"
  assert_eq "$main" "$(git rev-parse prototype/faster-checkout)"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)" "start moved the checkout"
}

test_start_captures_before_screenshots_of_each_step_from_main() {
  seed
  local out= d=
  out=$(start_checkout)
  d="$P/.artisan-agent/designs/faster-checkout/before"
  assert_eq "main build" "$(cat "$d/cart.png")"
  assert_eq "main build" "$(cat "$d/pay.png")"
  assert_contains "$out" "$d/cart.png"
  assert_eq "" "$(git worktree list | grep -v "^$P " || true)" "a capture worktree was left behind"
}

test_a_failing_capture_opens_no_ticket_and_cuts_no_branch() {
  seed
  printf "capture_command: 'exit 3'\n" >.artisan-agent/config.yml
  git commit -q -am broken
  git checkout -q main && git merge -q --ff-only work && git checkout -q work
  local st=0
  start_checkout >/dev/null 2>&1 || st=$?
  assert_eq 1 "$st"
  [ ! -e "$FAKE_GH_DIR/issue-1.json" ] || fail "a ticket was opened"
  assert_status 1 git rev-parse --verify -q refs/heads/feature/faster-checkout
}

test_start_refuses_a_design_whose_branches_exist() {
  seed
  git branch feature/faster-checkout main
  assert_status 1 start_checkout
  [ ! -e "$FAKE_GH_DIR/issue-1.json" ] || fail "a ticket was opened"
}

test_the_design_ticket_records_branches_tool_link_and_designer() {
  seed
  start_checkout >/dev/null
  local body=
  body=$(issue 1 | jq -r .body)
  assert_contains "$body" "- **Feature branch:** \`feature/faster-checkout\`"
  assert_contains "$body" "- **Prototype branch:** \`prototype/faster-checkout\`"
  assert_contains "$body" "- **Tool link:** none yet"
  assert_contains "$body" "- **Designer:** ana"
  assert_contains "$body" "- **Journey steps:** cart, pay"
}

test_status_lists_open_design_tickets_only() {
  seed
  start_checkout >/dev/null
  "$DESIGN" start --name Onboarding --step welcome --designer bo >/dev/null
  printf '{"number":3,"title":"A bug","body":"","state":"open","labels":[{"name":"bug"}]}\n' >"$FAKE_GH_DIR/issue-3.json"
  jq '.state="closed"' "$FAKE_GH_DIR/issue-2.json" >"$TEST_TMPDIR/x" && mv "$TEST_TMPDIR/x" "$FAKE_GH_DIR/issue-2.json"
  local out=
  out=$("$DESIGN" status)
  assert_eq "#1 Design: Faster checkout" "$out"
}

test_status_with_no_designs_says_so() {
  seed
  assert_eq "no designs in progress" "$("$DESIGN" status)"
}

test_resume_prints_the_designs_branches_and_links() {
  seed
  start_checkout >/dev/null
  local out=
  out=$("$DESIGN" resume '#1')
  assert_contains "$out" "design: #1 Design: Faster checkout"
  assert_contains "$out" "feature branch: feature/faster-checkout"
  assert_contains "$out" "prototype branch: prototype/faster-checkout"
  assert_contains "$out" "tool link: none yet"
  assert_contains "$out" "designer: ana"
  assert_contains "$out" "journey steps: cart, pay"
  assert_contains "$out" "before screenshots: $P/.artisan-agent/designs/faster-checkout/before"
}

test_resume_refuses_a_ticket_that_is_not_a_design() {
  seed
  printf '{"number":3,"title":"A bug","body":"","state":"open","labels":[{"name":"bug"}]}\n' >"$FAKE_GH_DIR/issue-3.json"
  assert_status 1 "$DESIGN" resume 3
}

test_bad_usage_exits_2() {
  seed
  assert_status 2 "$DESIGN"
  assert_status 2 "$DESIGN" start --name x
  assert_status 2 "$DESIGN" start --step a
  assert_status 2 "$DESIGN" resume
}

# The skill (static, names not wording): its steps in order, the design
# standards read in the first, before the design starts.
SKILL="$PLUGIN_ROOT/skills/design/SKILL.md"

test_the_skill_names_its_steps_in_order() {
  local want="1. Read the design standards
2. Start or resume
3. Write the journey diff
4. Prototype
5. High-fidelity design
6. Approve
7. Retire at ship"
  assert_eq "$want" "$(sed -nE 's/^## ([0-9]+\. [^(]*[^ (]).*$/\1/p' "$SKILL")"
}

test_the_skill_reads_the_design_standards_before_starting() {
  local first=
  first=$(sed -n '/^## 1\. /,/^## 2\. /p' "$SKILL")
  assert_contains "$first" "DESIGN_STANDARDS.md"
  assert_contains "$first" "guardrails.sh design"
}

test_the_skill_runs_design_sh_to_start_status_and_resume() {
  local text=
  text=$(sed -n '/^## 2\. /,/^## 3\. /p' "$SKILL")
  assert_contains "$text" "design.sh start"
  assert_contains "$text" "design.sh status"
  assert_contains "$text" "design.sh resume"
}
