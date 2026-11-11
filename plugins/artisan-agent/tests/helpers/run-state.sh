# Fixtures for the run state file tests: a throwaway project repo, an approved
# plan, and a stub `gh` on PATH so the real GitHub API is never called.
# Sourced by state.test.sh, sweep.test.sh and reconcile.test.sh.

SCRIPTS="$PLUGIN_ROOT/scripts"

git_quiet() { git -c init.defaultBranch=main -c user.name=Test -c user.email=test@example.invalid "$@" >/dev/null 2>&1; }

# make_project: a git repo in $TEST_TMPDIR/project with the run folder ignored.
# Sets PROJECT and RUN_DIR.
make_project() {
  PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  git_quiet -C "$PROJECT" init
  printf '.artisan-agent/runs/\n' >"$PROJECT/.gitignore"
  mkdir -p "$PROJECT/.artisan-agent"
  printf 'max_agents: 5\n' >"$PROJECT/.artisan-agent/config.yml"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m init
  RUN_DIR="$PROJECT/.artisan-agent/runs/r1"
}

# write_plan path [scope-json] [tickets-json]
write_plan() {
  local scope='["10","11","12"]' tickets='{}'
  [ -n "${2:-}" ] && scope=$2
  [ -n "${3:-}" ] && tickets=$3
  jq -n --argjson scope "$scope" --argjson tickets "$tickets" '{
    run_id: "r1", repo: "owner/repo", integration_branch: "run/r1",
    scope: $scope,
    waves: [["10"], ["11"], ["12"]],
    tickets: $tickets,
    gates: [{kind: "slice", after: "12"}],
    max_agents: 5, budget_usd: 20, attempts_per_ticket: 2
  }' >"$1"
}

# init_run [scope-json] [tickets-json]: project + initialised state file.
init_run() {
  make_project
  write_plan "$TEST_TMPDIR/plan.json" "$@"
  "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
}

state_get() { jq -r "$1" "$RUN_DIR/state.json"; }

# install_gh_stub: puts a fake gh first on PATH. It answers
#   gh api repos/<repo>/issues/<n>                       from $GH_STUB/issue-<n>.json
#   gh api repos/<repo>/issues/<n>/dependencies/blocked_by  from $GH_STUB/blocked_by-<n>.json ([] if absent)
# logs every call to $GH_STUB/calls, and fails on anything else.
install_gh_stub() {
  GH_STUB="$TEST_TMPDIR/gh-stub"
  mkdir -p "$GH_STUB/bin"
  cat >"$GH_STUB/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB/calls"
[ "${1:-}" = api ] || { echo "gh stub: unsupported: $*" >&2; exit 1; }
case "$2" in
  repos/*/issues/*/dependencies/blocked_by)
    n=${2%/dependencies/blocked_by}; n=${n##*/}
    if [ -f "$GH_STUB/blocked_by-$n.json" ]; then cat "$GH_STUB/blocked_by-$n.json"; else echo '[]'; fi ;;
  repos/*/issues/*)
    n=${2##*/}
    [ -f "$GH_STUB/issue-$n.json" ] || { echo "gh stub: HTTP 404 for #$n" >&2; exit 1; }
    cat "$GH_STUB/issue-$n.json" ;;
  *) echo "gh stub: unsupported: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$GH_STUB/bin/gh"
  PATH="$GH_STUB/bin:$PATH"
  export GH_STUB PATH
}

# stub_issue n open|closed [label...]
stub_issue() {
  local n="$1" state="$2"
  shift 2
  jq -n --argjson n "$n" --arg s "$state" --args '{number: $n, state: $s,
    labels: [$ARGS.positional[] | {name: .}]}' "$@" >"$GH_STUB/issue-$n.json"
}

# stub_blocked_by n "blocker:state" ...
stub_blocked_by() {
  local n="$1" pair
  shift
  for pair in "$@"; do
    jq -n --argjson b "${pair%%:*}" --arg s "${pair#*:}" '{number: $b, state: $s}'
  done | jq -s . >"$GH_STUB/blocked_by-$n.json"
}

# Ticket branches: branch_with_commit ticket (off the current integration tip)
branch_with_commit() {
  git_quiet -C "$PROJECT" checkout -b "agent/$1" run/r1
  printf '%s\n' "$1" >"$PROJECT/t$1.txt"
  git_quiet -C "$PROJECT" add -A
  git_quiet -C "$PROJECT" commit -m "ticket $1"
  git_quiet -C "$PROJECT" checkout main
}

merge_ticket() { # ticket -> prints merge commit
  git_quiet -C "$PROJECT" checkout run/r1
  git_quiet -C "$PROJECT" merge --no-ff -m "Merge agent/$1" "agent/$1"
  git_quiet -C "$PROJECT" checkout main
  git -C "$PROJECT" rev-parse run/r1
}

# A worker stand-in: a long sleep in the background. Prints its pid. Call
# kill_workers (trap it on EXIT) so no test leaves a process behind.
start_worker() {
  sleep 347 >/dev/null 2>&1 &
  printf '%s\n' "$!" >>"$TEST_TMPDIR/.workers"
  printf '%s\n' "$!"
}

kill_workers() {
  local pid
  [ -f "$TEST_TMPDIR/.workers" ] || return 0
  for pid in $(cat "$TEST_TMPDIR/.workers"); do kill -KILL "$pid" 2>/dev/null || true; done
}

state_sum() { cksum <"$RUN_DIR/state.json"; }
