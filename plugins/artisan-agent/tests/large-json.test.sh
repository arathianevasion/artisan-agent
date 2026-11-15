# JSON that grows with the run or the tracker never reaches jq as one
# command-line argument (#208): Linux refuses one over 128 KiB. reconcile.sh
# and gate-action.sh parked read tickets whose bodies, and whose blockers'
# bodies, add up to over 1 MiB (a stub gh that serves them whole, as GitHub
# does), and leave nothing behind in TMPDIR or the run folder, whether they
# succeed or fail part-way. The review gate's side: gate-actions.test.sh.

. "$TESTS_DIR/helpers/run-state.sh"

# big_body n: an issue body of about 300 KiB, in $TEST_TMPDIR/body-<n>.md.
big_body() {
  head -c 300000 /dev/zero | tr '\0' x >"$TEST_TMPDIR/body-$1.md"
}

# big_issue n open|closed: the stub's issue file, with the big body.
big_issue() {
  big_body "$1"
  jq -n --argjson n "$1" --arg s "$2" --rawfile body "$TEST_TMPDIR/body-$1.md" \
    '{number: $n, state: $s, title: "Ticket \($n)", labels: [], body: $body}' >"$GH_STUB/issue-$1.json"
}

# big_blocked_by n blocker...: the blockers response, each blocker in full.
big_blocked_by() {
  local n="$1" b=""
  shift
  for b in "$@"; do cat "$GH_STUB/issue-$b.json"; done | jq -s . >"$GH_STUB/blocked_by-$n.json"
}

# Scope 10..12: 10 and 12 stand alone; 11 is blocked by both (open, in the
# run). Every body is ~300 KiB; 11's blockers response holds two of them.
setup_big_run() {
  install_gh_stub
  init_run '["10","11","12"]'
  big_issue 10 open
  big_issue 11 open
  big_issue 12 open
  big_blocked_by 11 10 12
  EMPTY_TMP="$TEST_TMPDIR/empty-tmp"
  mkdir -p "$EMPTY_TMP"
}

files_in() { # dir: every file under it, sorted
  (cd "$1" && find . -type f | sort)
}

# leaves_nothing before-list: TMPDIR is empty again and the checkout and run
# folder hold the same files as before.
leaves_nothing() {
  assert_eq "" "$(ls -A "$EMPTY_TMP")" "TMPDIR left with files"
  assert_eq "$1" "$(files_in "$PROJECT" | grep -v '^\./\.git/')" "new files in the checkout or run folder"
}

test_reconcile_reads_over_a_mebibyte_of_bodies_and_leaves_nothing_behind() {
  setup_big_run
  local before="" total=0
  total=$(cat "$GH_STUB"/issue-*.json "$GH_STUB"/blocked_by-*.json | wc -c)
  [ "$total" -gt 1048576 ] || fail "the tracker should hold over 1 MiB, holds $total bytes"
  before=$(files_in "$PROJECT" | grep -v '^\./\.git/')
  assert_eq "10 12" "$(TMPDIR="$EMPTY_TMP" "$SCRIPTS/reconcile.sh" "$RUN_DIR" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq '["10","12"]' "$(state_get '.frontier' | jq -c .)"
  leaves_nothing "$before"
}

test_reconcile_failing_part_way_leaves_nothing_behind() {
  setup_big_run
  local before=""
  before=$(files_in "$PROJECT" | grep -v '^\./\.git/')
  rm "$GH_STUB/issue-12.json"   # #12 can't be read: the call fails after #10 and #11
  assert_status 1 env TMPDIR="$EMPTY_TMP" "$SCRIPTS/reconcile.sh" "$RUN_DIR"
  leaves_nothing "$before"
}

# A slice gate (#50) is open on 10's slice; 11 and 12 are queued behind it,
# 11 also behind 10. Nothing else moves: the run is parked.
park_behind_gate() {
  "$SCRIPTS/state.sh" update "$RUN_DIR" '
    .tickets["10"] |= (.status = "merged" | .merge_commit = "abcdef1234567")
    | .frontier = []
    | .review_gates = [{id: "slice-1", kind: "slice", issue: 50, status: "open",
        title: "Slice gate: one (run r1)", tickets: ["10"], cards: [], decisions: []}]' >/dev/null
  big_issue 50 open
  big_blocked_by 11 10 50 12
  big_blocked_by 12 50
}

test_parked_reads_over_a_mebibyte_of_blockers_and_leaves_nothing_behind() {
  setup_big_run
  park_behind_gate
  local before="" out=""
  before=$(files_in "$PROJECT" | grep -v '^\./\.git/')
  out=$(TMPDIR="$EMPTY_TMP" "$SCRIPTS/gate-action.sh" parked "$RUN_DIR") || fail "parked failed: $out"
  assert_eq "parked: waiting on 1 review: Slice gate: one (run r1) #50; 2 tickets wait behind it: #11, #12" "$out"
  leaves_nothing "$before"
  # --record logs it, once.
  TMPDIR="$EMPTY_TMP" "$SCRIPTS/gate-action.sh" parked "$RUN_DIR" --record >/dev/null
  assert_eq 1 "$(state_get '[.events[] | select(.event == "parked")] | length')"
  assert_eq "" "$(ls -A "$EMPTY_TMP")"
}

test_parked_failing_part_way_leaves_nothing_behind() {
  setup_big_run
  park_behind_gate
  local before=""
  before=$(files_in "$PROJECT" | grep -v '^\./\.git/')
  # 12's blockers can't be read: parked can't say what holds it, and says nothing.
  rm "$GH_STUB/blocked_by-12.json"
  mkdir "$GH_STUB/blocked_by-12.json"   # the stub's cat fails on it
  assert_status 1 env TMPDIR="$EMPTY_TMP" "$SCRIPTS/gate-action.sh" parked "$RUN_DIR"
  leaves_nothing "$before"
}
