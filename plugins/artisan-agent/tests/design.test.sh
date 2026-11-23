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
  f=$(git show feature/faster-checkout:docs/journeys/buy-a-ticket.md)
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
  assert_eq "" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/' || true)" "journeys before"
  "$DESIGN" journey --design faster-checkout --name "Buy a ticket" --persona "First-time buyer" \
    --goal "Pay" --action "Enters card details" --next "Confirmation" >/dev/null
  assert_eq "docs/journeys/buy-a-ticket.md" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/')"
  assert_eq 1 "$(git show feature/faster-checkout:docs/journeys/buy-a-ticket.md | grep -c '^### ')"
}

test_the_journey_changes_stay_off_main_and_the_checkout() {
  seed
  start_checkout >/dev/null
  local main=
  main=$(git rev-parse main)
  journey >/dev/null
  assert_eq "$main" "$(git rev-parse main)" "main moved"
  assert_eq "" "$(git ls-tree -r --name-only main | grep '^docs/journeys/' || true)" "main has journeys"
  [ ! -e "$P/docs/journeys" ] || fail "the checkout got the journeys folder"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)"
  assert_eq "" "$(git status --porcelain -- docs/journeys)" "the checkout is dirty"
  assert_eq "" "$(git worktree list | grep -v "^$P " || true)" "a worktree was left behind"
}

test_a_second_journey_is_its_own_file_and_a_rewrite_replaces_steps() {
  seed
  start_checkout >/dev/null
  journey >/dev/null
  "$DESIGN" journey --design faster-checkout --name "Refund" --persona "Buyer" \
    --goal "Ask" --action "Opens help" --next "End" >/dev/null
  assert_contains "$(journey)" "unchanged"
  assert_eq "docs/journeys/buy-a-ticket.md
docs/journeys/refund.md" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/')"
  assert_eq 2 "$(git show feature/faster-checkout:docs/journeys/buy-a-ticket.md | grep -c '^### ')"
}

test_a_journey_step_without_goal_action_and_next_is_refused() {
  seed
  start_checkout >/dev/null
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --persona p --goal g --action a
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --persona p --action a --next n
  assert_status 2 "$DESIGN" journey --design faster-checkout --name J --goal g --action a --next n
  assert_eq "" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/' || true)"
}

test_a_journey_for_a_design_that_was_not_started_is_refused() {
  seed
  assert_status 1 "$DESIGN" journey --design nope --name J --persona p --goal g --action a --next n
}

test_no_plugin_file_names_a_root_journeys_folder() {
  local hits=
  hits=$(grep -rnE '(^|[^[:alnum:]_/.-])journeys/' --exclude-dir=tests --exclude=CHANGELOG.md "$PLUGIN_ROOT" 2>/dev/null || true)
  assert_eq "" "$hits" "a root journeys/ folder is named"
}

test_the_skill_names_the_journey_format_and_the_write_from_main_step() {
  local text=
  text=$(sed -n '/^## 3\. /,/^## 4\. /p' "$SKILL")
  assert_contains "$text" "design.sh journey"
  assert_contains "$text" "docs/journeys/"
  assert_contains "$text" "**Persona:**"
  assert_contains "$text" "- **Goal:**"
  assert_contains "$text" "- **Action:**"
  assert_contains "$text" "- **Next:**"
  assert_contains "$text" "written from main first"
  assert_contains "$text" "from main"
  assert_contains "$text" "feature branch"
}

# design.sh prototype (#326): a headless prototype worker, dispatched into its
# own worktree on the prototype branch, briefed with the real components.

# main's design standards point at the design system; the checkout stays on work.
seed_design_system() {
  git checkout -q main
  printf '# Design standards\n\n## Personas\n\n- First-time buyer\n\n## Where the design system lives\n\nPointers only, never copies: a path or a link per line.\n\n- src/components/\n- https://storybook.example/ui\n\n## UX conventions\n\n- No modals\n' >DESIGN_STANDARDS.md
  git add DESIGN_STANDARDS.md && git commit -q -m standards
  git checkout -q work
  export ARTISAN_HOME="$TEST_TMPDIR/home"
}

# A stand-in claude that records where it ran and what it was told, commits a
# file there, then marks itself done.
fake_prototype_claude() {
  export FAKE_PROTO="$TEST_TMPDIR/proto-run"
  mkdir -p "$FAKE_PROTO"
  cat >"$TEST_TMPDIR/fake-claude" <<'SH'
#!/usr/bin/env bash
pwd -P >"$FAKE_PROTO/pwd"
git rev-parse --abbrev-ref HEAD >"$FAKE_PROTO/branch"
printf '%s\n' "$ARTISAN_ROLE" >"$FAKE_PROTO/role"
while [ $# -gt 0 ]; do [ "$1" = -p ] && printf '%s' "$2" >"$FAKE_PROTO/prompt"; shift; done
printf 'prototype\n' >>proto.txt && git add proto.txt && git commit -q -m prototype
touch "$FAKE_PROTO/done"
SH
  chmod +x "$TEST_TMPDIR/fake-claude"
  export ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/fake-claude"
}

wait_prototype() {
  local i=0
  while [ ! -e "$FAKE_PROTO/done" ]; do
    i=$((i + 1)); [ "$i" -le 100 ] || fail "the prototype worker never ran"
    sleep 0.1
  done
}

prototype() {
  "$DESIGN" prototype --design faster-checkout --change "Pay in one tap from the cart" "$@"
}

test_prototype_worker_runs_in_its_own_worktree_on_the_prototype_branch_only() {
  seed; seed_design_system; fake_prototype_claude
  start_checkout >/dev/null
  local main= feature= out=
  main=$(git rev-parse main) feature=$(git rev-parse feature/faster-checkout)
  out=$(prototype)
  wait_prototype
  assert_eq prototype/faster-checkout "$(cat "$FAKE_PROTO/branch")"
  assert_eq "$(cd "$P-wt/prototype-faster-checkout" && pwd -P)" "$(cat "$FAKE_PROTO/pwd")"
  assert_contains "$out" "worktree: $P-wt/prototype-faster-checkout"
  assert_eq prototype "$(git log -1 --format=%s prototype/faster-checkout)"
  assert_eq "$main" "$(git rev-parse main)" "main moved"
  assert_eq "$feature" "$(git rev-parse feature/faster-checkout)" "the feature branch moved"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)" "the checkout moved"
  assert_eq prototype "$(cat "$FAKE_PROTO/role")"
}

test_the_prototype_brief_names_the_real_components_from_the_design_system_pointer() {
  seed; seed_design_system; fake_prototype_claude
  start_checkout >/dev/null
  local out= brief=
  out=$(prototype)
  wait_prototype
  brief="$P/.artisan-agent/designs/faster-checkout/prototype-brief.md"
  assert_contains "$out" "brief: $brief"
  assert_contains "$(cat "$brief")" "real components"
  assert_contains "$(cat "$brief")" "- src/components/"
  assert_contains "$(cat "$brief")" "- https://storybook.example/ui"
  assert_not_contains "$(cat "$brief")" "No modals" "the brief copied another section"
  assert_contains "$(cat "$brief")" "Pay in one tap from the cart"
  assert_eq "$(cat "$brief")" "$(cat "$FAKE_PROTO/prompt")" "the worker was not given the brief"
}

test_with_no_design_system_pointer_the_prototype_warns_and_still_dispatches() {
  seed; fake_prototype_claude
  export ARTISAN_HOME="$TEST_TMPDIR/home"
  start_checkout >/dev/null
  local err=
  err=$(prototype 2>&1 >/dev/null)
  wait_prototype
  assert_contains "$err" "no design system pointer"
  assert_contains "$(cat "$FAKE_PROTO/prompt")" "use the components already in the code"
}

test_a_prototype_for_a_design_that_was_not_started_is_refused() {
  seed; fake_prototype_claude
  local st=0
  prototype >/dev/null 2>&1 || st=$?
  assert_eq 1 "$st"
  assert_eq "" "$(ls "$FAKE_PROTO")" "a worker ran"
}

test_a_prototype_worktree_on_another_branch_is_refused() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  git worktree add -q "$P-wt/prototype-faster-checkout" feature/faster-checkout
  local st=0
  prototype >/dev/null 2>&1 || st=$?
  assert_eq 1 "$st"
  assert_eq "" "$(ls "$FAKE_PROTO")" "a worker ran on the wrong branch"
}

test_a_second_dispatch_reuses_the_prototype_worktree() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  prototype >/dev/null 2>&1; wait_prototype; rm -f "$FAKE_PROTO/done"
  prototype >/dev/null 2>&1; wait_prototype
  assert_eq prototype/faster-checkout "$(cat "$FAKE_PROTO/branch")"
  assert_eq 2 "$(git rev-list --count main..prototype/faster-checkout)"
}

# worktree_setup in the prototype worktree (#371).
set_setup() {
  printf '%s\n' "worktree_setup: '$1'" >>"$P/.artisan-agent/config.yml"
  git -C "$P" commit -q -am "setup config"
}

test_a_new_prototype_worktree_runs_worktree_setup_before_the_worker() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  set_setup 'pwd -P >"$ARTISAN_MAIN/setup-ran"; ls "$FAKE_PROTO/pwd" 2>/dev/null >"$ARTISAN_MAIN/setup-saw-worker" || true'
  prototype >/dev/null
  wait_prototype
  assert_eq "$(cd "$P-wt/prototype-faster-checkout" && pwd -P)" "$(cat "$P/setup-ran")"
  assert_eq "" "$(cat "$P/setup-saw-worker")" "the worker had already run"
}

test_a_failing_setup_launches_no_worker_and_exits_non_zero_with_its_stderr_tail() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  set_setup 'echo npm exploded >&2; exit 3'
  local st=0 err=
  err=$(prototype 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "exited 3"
  assert_contains "$err" "npm exploded"
  assert_eq "" "$(ls "$FAKE_PROTO")" "a worker ran"
  assert_eq "" "$(git worktree list | grep prototype-faster-checkout || true)" "the worktree was left"
}

test_a_reused_prototype_worktree_does_not_run_setup_again() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  set_setup 'echo x >>"$ARTISAN_MAIN/setup-count"'
  prototype >/dev/null 2>&1; wait_prototype; rm -f "$FAKE_PROTO/done"
  prototype >/dev/null 2>&1; wait_prototype
  assert_eq 1 "$(wc -l <"$P/setup-count" | tr -d ' ')"
}

test_the_scripts_readme_lists_the_prototype_worktree_under_worktree_setup() {
  assert_contains "$(grep '^| worktree setup command' "$PLUGIN_ROOT/scripts/README.md")" "design.sh prototype"
}

test_the_skill_dispatches_the_prototype_worker_with_design_sh() {
  local text=
  text=$(sed -n '/^## 4\. /,/^## 5\. /p' "$SKILL")
  assert_contains "$text" "design.sh prototype --design"
  assert_contains "$text" "real components"
  assert_contains "$text" "Where the design system lives"
}

test_the_skill_recommends_a_functional_prototype_on_behaviour_change_and_records_a_skip() {
  local text=
  text=$(sed -n '/^## 4\. /,/^## 5\. /p' "$SKILL")
  assert_contains "$text" "recommend a functional prototype"
  assert_contains "$text" "look-only"
  assert_contains "$text" "**Prototype:** skipped"
}

# #337: the Figma adapter, used only when Figma's MCP server is connected.
test_the_skill_checks_for_figmas_mcp_server_and_falls_back_to_screenshots_and_links() {
  local text=
  text=$(sed -n '/^## 5\. /,/^## 6\. /p' "$SKILL")
  assert_contains "$text" "Check for Figma's MCP server"
  assert_contains "$text" "Without it, work from screenshots and links alone"
  assert_contains "$text" "ADR 0004"
  # The link is recorded with or without the server; only the adapter's tools need it.
  assert_contains "$text" "With or without the server, the Figma file's link is the tool link"
  assert_eq "" "$(printf '%s\n' "$text" | grep -n 'nothing below applies' || true)"
}

test_with_figmas_server_the_skill_reads_captures_main_writes_and_records_the_tool_link() {
  local text=
  text=$(sed -n '/^## 5\. /,/^## 6\. /p' "$SKILL")
  assert_contains "$text" "**Read a design**"
  assert_contains "$text" "get_design_context"
  assert_contains "$text" "**Capture main into Figma**"
  assert_contains "$text" "generate_figma_design"
  assert_contains "$text" "**Write a design**"
  assert_contains "$text" "use_figma"
  assert_contains "$text" "--tool-link <figma link>"
  assert_contains "$(sed -n '/^## 6\. /,/^## 7\. /p' "$SKILL")" "a tool link never replaces a step's screenshot"
}

test_no_step_of_the_design_skill_commits_from_the_decision_chat() {
  assert_contains "$(cat "$SKILL")" "No step commits from the Decision chat"
  # the chat runs no git command that writes: every commit is design.sh's, in its own checkout, or the worker's
  assert_eq "" "$(grep -nE 'git (commit|add|merge|push|checkout|switch|cherry-pick|rebase|reset)' "$SKILL" || true)"
}

test_a_dispatch_while_the_prototype_worker_still_runs_is_refused() {
  seed; fake_prototype_claude
  start_checkout >/dev/null
  # a worker that is still going: it waits for the test to let it finish
  printf 'while [ ! -e "$FAKE_PROTO/go" ]; do sleep 0.1; done\n' >>"$TEST_TMPDIR/fake-claude"
  local st=0 err= pid=
  prototype >/dev/null 2>&1
  pid=$(cat "$P/.artisan-agent/designs/faster-checkout/prototype.pid")
  err=$(prototype 2>&1 >/dev/null) || st=$?
  touch "$FAKE_PROTO/go"
  assert_eq 1 "$st"
  assert_contains "$err" "still running (pid $pid)"
  wait_prototype
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  assert_eq 1 "$(git rev-list --count main..prototype/faster-checkout)" "a second worker ran"
}

# design.sh approve (#327): the design package is recorded on the design
# ticket; screenshots are read from the feature branch, beside the journeys.
# add_screenshots: commits a screenshot per step on the feature branch, in a throwaway checkout.
add_screenshots() {
  local wt="$TEST_TMPDIR/shots" s=
  git worktree add -q "$wt" feature/faster-checkout
  mkdir -p "$wt/docs/journeys/screenshots"
  for s in "$@"; do printf 'after %s\n' "$s" >"$wt/docs/journeys/screenshots/$s.png"; done
  git -C "$wt" add -A && git -C "$wt" commit -q -m screenshots
  git worktree remove --force "$wt"
}
approve() { "$DESIGN" approve --design faster-checkout --ticket 1 "$@"; }
comments() { cat "$FAKE_GH_DIR/comments-1.md"; }

test_approve_records_journey_diff_screenshots_prototype_and_tool_link() {
  seed; start_checkout >/dev/null
  journey >/dev/null
  add_screenshots cart pay
  git worktree add -q "$TEST_TMPDIR/pt" prototype/faster-checkout
  printf 'proto\n' >"$TEST_TMPDIR/pt/proto.txt"
  git -C "$TEST_TMPDIR/pt" add -A && git -C "$TEST_TMPDIR/pt" commit -q -m proto
  git worktree remove --force "$TEST_TMPDIR/pt"
  approve --tool-link https://figma.example/f/1 >/dev/null
  local c=
  c=$(comments)
  assert_contains "$c" "Design package: approved"
  assert_contains "$c" "docs/journeys/buy-a-ticket.md"
  assert_contains "$c" "+- **Goal:** Pick a seat"
  assert_contains "$c" "\`cart\`: \`docs/journeys/screenshots/cart.png\` on \`feature/faster-checkout\`"
  assert_contains "$c" "\`pay\`: \`docs/journeys/screenshots/pay.png\`"
  assert_contains "$c" "- **Prototype:** \`prototype/faster-checkout\`"
  assert_contains "$c" "- **Tool link:** https://figma.example/f/1"
}

test_approve_refuses_while_the_prototype_branch_is_behind_main_naming_the_rebase() {
  seed; start_checkout >/dev/null
  add_screenshots cart pay
  git worktree add -q "$TEST_TMPDIR/pt" prototype/faster-checkout
  printf 'proto\n' >"$TEST_TMPDIR/pt/proto.txt"
  git -C "$TEST_TMPDIR/pt" add -A && git -C "$TEST_TMPDIR/pt" commit -q -m proto
  git worktree remove --force "$TEST_TMPDIR/pt"
  git checkout -q main && printf 'newer\n' >news.txt && git add news.txt && git commit -q -m news && git checkout -q work
  local st=0 err=
  err=$(approve 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "prototype/faster-checkout is behind main"
  assert_contains "$err" "rebase"
  [ ! -e "$FAKE_GH_DIR/comments-1.md" ] || fail "a package was recorded"
}

test_the_packages_screenshots_are_read_from_the_feature_branch_and_a_missing_one_refuses() {
  seed; start_checkout >/dev/null
  add_screenshots cart
  local st=0 err=
  err=$(approve 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "no screenshot on feature/faster-checkout for step(s): pay"
  assert_eq "" "$(git status --porcelain --untracked-files=no)" "approve touched the checkout"
  assert_eq docs/journeys/screenshots/cart.png "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/')"
}

# #384: capturing main is remote-server only and needs a supporting client; without it, the "before" screenshots stand.
test_capture_main_into_figma_needs_the_remote_server_and_falls_back_to_the_before_screenshots() {
  local line=
  line=$(sed -n '/^## 5\. /,/^## 6\. /p' "$SKILL" | grep -F '**Capture main into Figma**')
  assert_contains "$line" "remote Figma MCP server"
  assert_contains "$line" "a client that supports it"
  assert_contains "$line" "the \"before\" screenshots"
}

# #337: a Figma design is not a substitute for the screenshots; the package
# from a tool link still carries one per changed step.
test_approve_with_a_figma_tool_link_still_refuses_a_step_with_no_screenshot() {
  seed; start_checkout >/dev/null
  add_screenshots cart
  local st=0 err=
  err=$(approve --tool-link https://www.figma.com/design/abc/Checkout 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "no screenshot on feature/faster-checkout for step(s): pay"
  [ ! -e "$FAKE_GH_DIR/comments-1.md" ] || fail "a package was recorded"
}

test_approve_with_a_figma_tool_link_carries_a_screenshot_per_changed_step() {
  seed; start_checkout >/dev/null
  add_screenshots cart pay
  approve --tool-link https://www.figma.com/design/abc/Checkout >/dev/null
  local c=
  c=$(comments)
  assert_contains "$c" "- **Tool link:** https://www.figma.com/design/abc/Checkout"
  assert_contains "$c" "\`cart\`: \`docs/journeys/screenshots/cart.png\` on \`feature/faster-checkout\`"
  assert_contains "$c" "\`pay\`: \`docs/journeys/screenshots/pay.png\` on \`feature/faster-checkout\`"
}

test_a_design_with_no_prototype_and_no_tool_link_approves_on_screenshots_alone() {
  seed; start_checkout >/dev/null
  add_screenshots cart pay
  git checkout -q main && printf 'newer\n' >news.txt && git add news.txt && git commit -q -m news && git checkout -q work
  approve >/dev/null
  assert_contains "$(comments)" "- **Prototype:** none"
  assert_contains "$(comments)" "- **Tool link:** none"
  assert_contains "$(comments)" "pay"
}

# design.sh retire (#335): at ship the prototype and the package's screenshots
# go, the journey diff stays, and the design ticket closes with its merge.
retire() { "$DESIGN" retire --design faster-checkout --ticket 1 --merge https://example/pr/9 "$@"; }

shipped_design() {
  seed; start_checkout >/dev/null
  journey >/dev/null
  add_screenshots cart pay
  git worktree add -q "$TEST_TMPDIR/pt" prototype/faster-checkout
  printf 'proto\n' >"$TEST_TMPDIR/pt/proto.txt"
  git -C "$TEST_TMPDIR/pt" add -A && git -C "$TEST_TMPDIR/pt" commit -q -m proto
}

test_retire_deletes_the_prototype_branch_and_its_worktree() {
  shipped_design
  retire >/dev/null
  git rev-parse --verify -q refs/heads/prototype/faster-checkout >/dev/null && fail "the prototype branch is still there"
  assert_eq "" "$(git worktree list | grep prototype || true)"
}

test_retire_deletes_the_package_screenshots_and_leaves_the_journey_diff() {
  shipped_design
  git worktree remove --force "$TEST_TMPDIR/pt"
  retire >/dev/null
  assert_eq "docs/journeys/buy-a-ticket.md" "$(git ls-tree -r --name-only feature/faster-checkout | grep '^docs/journeys/')"
  assert_contains "$(git diff main feature/faster-checkout --stat)" "docs/journeys/buy-a-ticket.md"
  assert_eq "" "$(git diff main feature/faster-checkout --name-only | grep screenshots || true)"
  [ ! -e "$P/.artisan-agent/designs/faster-checkout" ] || fail "the before screenshots are still there"
  assert_eq work "$(git rev-parse --abbrev-ref HEAD)" "retire moved the checkout"
  assert_eq "" "$(git status --porcelain --untracked-files=no)"
}

test_retire_closes_the_design_ticket_with_the_merge_it_shipped_in() {
  shipped_design
  retire >/dev/null
  assert_eq closed "$(issue 1 | jq -r .state)"
  assert_contains "$(comments)" "Shipped in https://example/pr/9"
}

test_retiring_twice_is_harmless() {
  shipped_design
  retire >/dev/null
  retire >/dev/null
  assert_eq closed "$(issue 1 | jq -r .state)"
  assert_eq 1 "$(grep -c 'Retired at ship' "$FAKE_GH_DIR/comments-1.md")" "the ticket was closed twice"
}

test_retire_refuses_a_ticket_that_is_not_a_design() {
  seed; start_checkout >/dev/null
  jq '.labels = []' "$FAKE_GH_DIR/issue-1.json" >"$FAKE_GH_DIR/x" && mv "$FAKE_GH_DIR/x" "$FAKE_GH_DIR/issue-1.json"
  local st=0 err=
  err=$(retire 2>&1 >/dev/null) || st=$?
  assert_eq 1 "$st"
  assert_contains "$err" "is not a design ticket"
  git rev-parse --verify -q refs/heads/prototype/faster-checkout >/dev/null || fail "the prototype was deleted"
}

test_retire_needs_the_merge_it_shipped_in() {
  seed; start_checkout >/dev/null
  assert_status 2 "$DESIGN" retire --design faster-checkout --ticket 1
}

test_the_skill_says_the_end_gate_retires_designs() {
  local s=
  s=$(cat "$PLUGIN_ROOT/skills/design/SKILL.md")
  assert_contains "$s" "design.sh retire"
  assert_not_contains "$s" "Not built yet"
}
