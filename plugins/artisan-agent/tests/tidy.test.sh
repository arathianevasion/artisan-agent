# tidy.sh (#427): once a run's PRs have merged on the origin, the main checkout
# is fast-forwarded (only when clean and only behind) and the run's worktrees
# and merged branches are removed; dirty work and unmerged branches are kept
# and named. Fake `gh`; the origin is a local bare repo.

. "$TESTS_DIR/helpers/run-state.sh"

TIDY="$PLUGIN_ROOT/scripts/tidy.sh"

# A project cloned from a bare origin, a run r1 with an integration worktree
# (run/r1, one commit) and one PR worktree (pr/r1/1) on the same commit.
# Nothing is merged yet.
setup_tidy() {
  ORIGIN="$TEST_TMPDIR/origin.git"
  git_quiet init --bare -b main "$ORIGIN"
  PROJECT="$TEST_TMPDIR/project"
  git_quiet clone "$ORIGIN" "$PROJECT"
  printf '.artisan-agent/runs/\n' >"$PROJECT/.gitignore"
  mkdir -p "$PROJECT/.artisan-agent"
  printf 'max_agents: 5\n' >"$PROJECT/.artisan-agent/config.yml"
  echo base >"$PROJECT/f.txt"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m init
  git_quiet -C "$PROJECT" push -u origin main
  RUN_DIR="$PROJECT/.artisan-agent/runs/r1"
  IWT="$TEST_TMPDIR/project-wt/run-r1"
  PWT="$TEST_TMPDIR/project-wt/pr-r1-1"
  git_quiet -C "$PROJECT" worktree add -b run/r1 "$IWT" main
  echo work >"$IWT/w.txt"
  git_quiet -C "$IWT" add -A
  git_quiet -C "$IWT" commit -m work
  git_quiet -C "$PROJECT" worktree add -b pr/r1/1 "$PWT" run/r1
  write_plan "$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.integration.worktree = $wt
    | .end_gate.prs = [{number: 5, url: "https://github.com/owner/repo/pull/5", branch: "pr/r1/1"}]' --arg wt "$IWT"
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/prs"
  cat >"$TEST_TMPDIR/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") cat "$TEST_TMPDIR/prs/\${3##*/}" 2>/dev/null || echo "OPEN -" ;;
  "pr list") b=; while [ \$# -gt 0 ]; do [ "\$1" = --head ] && b=\$2; shift; done
             cat "$TEST_TMPDIR/prs/head-\$(echo "\$b" | tr / _)" 2>/dev/null || true ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
}

# merge_on_origin: the run's PR lands on origin/main (the local main stays behind).
merge_on_origin() {
  git_quiet -C "$PROJECT" push origin run/r1:main
  echo "MERGED $(git -C "$PROJECT" rev-parse pr/r1/1)" >"$TEST_TMPDIR/prs/5"
}

branch_exists() { git -C "$PROJECT" rev-parse -q --verify "refs/heads/$1" >/dev/null; }

test_merged_run_fast_forwards_main_and_removes_worktrees_and_branches() {
  setup_tidy
  merge_on_origin
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "$(git -C "$PROJECT" rev-parse origin/main)" "$(git -C "$PROJECT" rev-parse main)"
  assert_eq "no" "$([ -d "$IWT" ] && echo yes || echo no)"
  assert_eq "no" "$([ -d "$PWT" ] && echo yes || echo no)"
  assert_eq "no" "$(branch_exists run/r1 && echo yes || echo no)"
  assert_eq "no" "$(branch_exists pr/r1/1 && echo yes || echo no)"
  assert_contains "$out" "fast-forwarded"
}

test_run_whose_prs_are_not_merged_removes_and_moves_nothing() {
  setup_tidy
  local before=
  before=$(git -C "$PROJECT" rev-parse main)
  git_quiet -C "$PROJECT" push origin run/r1:other   # origin has the work, but not on main
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "$before" "$(git -C "$PROJECT" rev-parse main)"
  assert_eq "yes" "$([ -d "$IWT" ] && echo yes || echo no)"
  assert_eq "yes" "$([ -d "$PWT" ] && echo yes || echo no)"
  assert_contains "$out" "not merged"
}

test_main_with_local_commits_is_left_alone_with_one_line_saying_why() {
  setup_tidy
  merge_on_origin
  echo mine >"$PROJECT/mine.txt"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m local
  local before= out=
  before=$(git -C "$PROJECT" rev-parse main)
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "$before" "$(git -C "$PROJECT" rev-parse main)"
  assert_contains "$out" "left alone: main has local commits"
}

test_main_with_uncommitted_tracked_changes_is_left_alone_with_one_line_saying_why() {
  setup_tidy
  merge_on_origin
  echo edited >"$PROJECT/f.txt"
  local before= out=
  before=$(git -C "$PROJECT" rev-parse main)
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "$before" "$(git -C "$PROJECT" rev-parse main)"
  assert_eq "edited" "$(cat "$PROJECT/f.txt")"
  assert_contains "$out" "left alone: main has uncommitted changes"
}

test_a_worktree_with_uncommitted_work_is_kept_and_named_while_the_rest_goes() {
  setup_tidy
  merge_on_origin
  echo wip >"$PWT/wip.txt"
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "yes" "$([ -d "$PWT" ] && echo yes || echo no)"
  assert_eq "yes" "$(branch_exists pr/r1/1 && echo yes || echo no)"
  assert_eq "no" "$([ -d "$IWT" ] && echo yes || echo no)"
  assert_contains "$out" "kept $PWT: uncommitted work"
}

test_a_branch_not_on_the_origins_default_branch_is_kept_and_named() {
  setup_tidy
  merge_on_origin
  echo more >"$PWT/more.txt"
  git_quiet -C "$PWT" add -A
  git_quiet -C "$PWT" commit -m "after the merge"
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "yes" "$([ -d "$PWT" ] && echo yes || echo no)"
  assert_eq "yes" "$(branch_exists pr/r1/1 && echo yes || echo no)"
  assert_contains "$out" "kept $PWT: pr/r1/1 is not on origin/main"
}

test_the_retro_worktree_goes_once_its_pr_merged_and_stays_while_it_is_open() {
  setup_tidy
  merge_on_origin
  RWT="$TEST_TMPDIR/project-wt/retro-r1"
  git_quiet -C "$PROJECT" worktree add -b retro/r1 "$RWT" main
  echo lesson >"$RWT/l.txt"
  git_quiet -C "$RWT" add -A
  git_quiet -C "$RWT" commit -m lesson
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "yes" "$([ -d "$RWT" ] && echo yes || echo no)"
  assert_contains "$out" "kept $RWT"
  # The retro PR squash-merges: its commit is not an ancestor of main, but gh says merged at that tip.
  echo "MERGED $(git -C "$PROJECT" rev-parse retro/r1)" >"$TEST_TMPDIR/prs/head-retro_r1"
  "$TIDY" "$RUN_DIR" >/dev/null 2>&1
  assert_eq "no" "$([ -d "$RWT" ] && echo yes || echo no)"
  assert_eq "no" "$(branch_exists retro/r1 && echo yes || echo no)"
}

test_a_run_merged_as_one_pr_outside_the_gate_is_tidied_too() {
  setup_tidy
  "$SCRIPTS/state.sh" update "$RUN_DIR" '.end_gate.prs = [] | .end_gate.merged_outside = {url: null, tip: "x", into: "origin/main"}'
  git_quiet -C "$PROJECT" push origin run/r1:main
  "$TIDY" "$RUN_DIR" >/dev/null 2>&1
  assert_eq "no" "$([ -d "$IWT" ] && echo yes || echo no)"
}

test_a_squash_merged_run_still_loses_its_integration_worktree_and_branch() {
  setup_tidy
  # The PR squash-merges: main gets a new commit, so no run branch is an ancestor of it.
  local wt="$TEST_TMPDIR/squash"
  git_quiet clone "$ORIGIN" "$wt"
  echo work >"$wt/w.txt"
  git_quiet -C "$wt" add -A
  git_quiet -C "$wt" commit -m "squash of the run"
  git_quiet -C "$wt" push origin main
  echo "MERGED $(git -C "$PROJECT" rev-parse pr/r1/1)" >"$TEST_TMPDIR/prs/5"
  local out=
  out=$("$TIDY" "$RUN_DIR" 2>&1)
  assert_eq "no" "$([ -d "$IWT" ] && echo yes || echo no)"
  assert_eq "no" "$([ -d "$PWT" ] && echo yes || echo no)"
  assert_eq "no" "$(branch_exists run/r1 && echo yes || echo no)"
  assert_eq "$(git -C "$PROJECT" rev-parse origin/main)" "$(git -C "$PROJECT" rev-parse main)"
}
