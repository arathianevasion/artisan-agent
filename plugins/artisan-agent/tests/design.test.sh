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

# Review fixes: start stops before creating anything, keeping capture's
# "no capture command" status, and undoes its branches when gh fails.
nothing_created() {
  [ ! -e "$FAKE_GH_DIR/issue-1.json" ] || fail "a ticket was opened"
  assert_status 1 git rev-parse --verify -q refs/heads/feature/faster-checkout
  assert_status 1 git rev-parse --verify -q refs/heads/prototype/faster-checkout
  [ ! -e "$P/.artisan-agent/designs/faster-checkout" ] || fail "a before folder was left"
}

test_no_recorded_capture_command_exits_16_and_creates_nothing() {
  seed
  printf 'max_agents: 2\n' >.artisan-agent/config.yml
  assert_status 16 start_checkout
  nothing_created
}

test_a_step_name_that_is_not_a_file_name_is_refused_before_capturing() {
  seed
  assert_status 2 "$DESIGN" start --name "Faster checkout" --step cart --step ../x --designer ana
  nothing_created
}

test_a_capture_failing_on_a_later_step_leaves_no_before_folder() {
  seed
  printf "capture_command: '[ \"\$ARTISAN_CAPTURE_STEP\" = pay ] && exit 3; cp build.txt \"\$ARTISAN_CAPTURE_DIR/\$ARTISAN_CAPTURE_STEP.png\"'\n" >.artisan-agent/config.yml
  assert_status 1 start_checkout
  nothing_created
}

test_a_failing_gh_issue_create_deletes_the_branches_it_cut() {
  seed
  export GH_BIN="$TEST_TMPDIR/gh"
  printf '#!/bin/sh\n[ "$1 $2" = "issue create" ] && exit 1\nexec gh "$@"\n' >"$GH_BIN" && chmod +x "$GH_BIN"
  assert_status 1 start_checkout
  nothing_created
}

test_resume_takes_a_bare_number() {
  seed
  start_checkout >/dev/null
  assert_contains "$("$DESIGN" resume 1)" "feature branch: feature/faster-checkout"
}

# Rework #369: with an origin, start fetches it and cuts and captures from
# origin/<default branch>, never local main (which may lag); with none, from
# local main. A failed fetch refuses, naming the cause and --no-fetch.
# seed_origin: an origin whose main is a commit ahead of the local main.
seed_origin() {
  seed
  O="$TEST_TMPDIR/origin"
  git clone -q "$P" "$O"
  git -C "$O" config user.name t && git -C "$O" config user.email t@t
  git -C "$O" checkout -q main
  git remote add origin "$O"
  git fetch -q origin
  printf 'prod build\n' >"$O/build.txt"
  git -C "$O" commit -q -am prod
}

test_with_an_origin_start_fetches_and_cuts_and_captures_from_origin_main() {
  seed_origin
  local local_main= prod=
  local_main=$(git rev-parse main)
  prod=$(git -C "$O" rev-parse main)
  start_checkout >/dev/null
  assert_eq "$prod" "$(git rev-parse feature/faster-checkout)"
  assert_eq "$prod" "$(git rev-parse prototype/faster-checkout)"
  assert_eq "prod build" "$(cat "$P/.artisan-agent/designs/faster-checkout/before/cart.png")"
  assert_eq "$local_main" "$(git rev-parse main)" "start moved local main"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)" "start moved the checkout"
  assert_eq "" "$(git config --get branch.feature/faster-checkout.merge || true)" "the feature branch should track nothing"
  assert_contains "$(issue 1 | jq -r .body)" "- **Cut from:** \`origin/main\` at $prod"
}

test_a_failed_fetch_refuses_naming_the_cause_and_no_fetch() {
  seed_origin
  git remote set-url origin "$TEST_TMPDIR/gone"
  local err= st=0
  err=$(start_checkout 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "fetch"
  assert_contains "$err" "gone"
  assert_contains "$err" "--no-fetch"
  nothing_created
}

test_no_fetch_cuts_from_origin_main_as_last_fetched_and_records_it() {
  seed_origin
  local fetched=
  fetched=$(git rev-parse origin/main)
  git remote set-url origin "$TEST_TMPDIR/gone"
  "$DESIGN" start --name "Faster checkout" --step cart --designer ana --no-fetch >/dev/null
  assert_eq "$fetched" "$(git rev-parse feature/faster-checkout)"
  assert_eq "main build" "$(cat "$P/.artisan-agent/designs/faster-checkout/before/cart.png")"
  assert_contains "$(issue 1 | jq -r .body)" "- **Cut from:** \`origin/main\` at $fetched, as last fetched (--no-fetch)"
}

test_with_no_origin_the_ticket_records_local_main() {
  seed
  start_checkout >/dev/null
  assert_contains "$(issue 1 | jq -r .body)" "- **Cut from:** \`main\` at $(git rev-parse main)"
  assert_contains "$("$DESIGN" resume 1)" "cut from: main at $(git rev-parse main)"
}

# #325: user journeys, one file per journey, written on the feature branch only.
journey() {
  "$DESIGN" journey --design faster-checkout --name "Buy a ticket" --persona "First-time buyer" \
    --goal "Pick a seat" --action "Taps a seat on the map and sees its price" --next "Pay" \
    --goal "Pay" --action "Enters card details and sees a receipt" --next "Confirmation" "$@"
}

test_a_journey_file_names_its_persona_and_lists_ordered_steps() {
  seed
  start_checkout >/dev/null
  journey >/dev/null
  local f=
  f=$(git show feature/faster-checkout:journeys/buy-a-ticket.md)
  assert_contains "$f" "# Journey: Buy a ticket"
  assert_contains "$f" "**Persona:** First-time buyer"
  assert_eq "### 1. Pick a seat
### 2. Pay" "$(printf '%s\n' "$f" | grep '^### ')"
  assert_eq "- **Goal:** Pick a seat
- **Action:** Taps a seat on the map and sees its price
- **Next:** Pay
- **Goal:** Pay
- **Action:** Enters card details and sees a receipt
- **Next:** Confirmation" "$(printf '%s\n' "$f" | grep '^- ')"
}

test_with_no_journeys_only_the_touched_steps_are_written_on_the_feature_branch() {
  seed
  start_checkout >/dev/null
  assert_eq "" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^journeys/' || true)" "journeys before"
  "$DESIGN" journey --design faster-checkout --name "Buy a ticket" --persona "First-time buyer" \
    --goal "Pay" --action "Enters card details" --next "Confirmation" >/dev/null
  assert_eq "journeys/buy-a-ticket.md" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^journeys/')"
  assert_eq 1 "$(git show feature/faster-checkout:journeys/buy-a-ticket.md | grep -c '^### ')"
}

test_the_journey_changes_stay_off_main_and_the_checkout() {
  seed
  start_checkout >/dev/null
  local main=
  main=$(git rev-parse main)
  journey >/dev/null
  assert_eq "$main" "$(git rev-parse main)" "main moved"
  assert_eq "" "$(git ls-tree -r --name-only main | grep '^journeys/' || true)" "main has journeys"
  [ ! -e "$P/journeys" ] || fail "the checkout got the journeys folder"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)"
  assert_eq "" "$(git status --porcelain -- journeys)" "the checkout is dirty"
  assert_eq "" "$(git worktree list | grep -v "^$P " || true)" "a worktree was left behind"
}

test_a_second_journey_is_its_own_file_and_a_rewrite_replaces_steps() {
  seed
  start_checkout >/dev/null
  journey >/dev/null
  "$DESIGN" journey --design faster-checkout --name "Refund" --persona "Buyer" \
    --goal "Ask" --action "Opens help" --next "End" >/dev/null
  assert_contains "$(journey)" "unchanged"
  assert_eq "journeys/buy-a-ticket.md
journeys/refund.md" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^journeys/')"
  assert_eq 2 "$(git show feature/faster-checkout:journeys/buy-a-ticket.md | grep -c '^### ')"
}

test_a_journey_step_without_goal_action_and_next_is_refused() {
  seed
  start_checkout >/dev/null
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --persona p --goal g --action a
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --persona p --action a --next n
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --goal g --action a --next n
  assert_eq "" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^journeys/' || true)"
}

test_a_journey_for_a_design_that_was_not_started_is_refused() {
  seed
  assert_status 1 "$DESIGN" journey --design nope --name J --persona p --goal g --action a --next n
}

test_the_skill_names_the_journey_format_and_the_write_from_main_step() {
  local text=
  text=$(sed -n '/^## 3\. /,/^## 4\. /p' "$SKILL")
  assert_contains "$text" "design.sh journey"
  assert_contains "$text" "journeys/"
  assert_contains "$text" "**Persona:**"
  assert_contains "$text" "- **Goal:**"
  assert_contains "$text" "- **Action:**"
  assert_contains "$text" "- **Next:**"
  assert_contains "$text" "written from main first"
  assert_contains "$text" "from main"
  assert_contains "$text" "feature branch"
}
