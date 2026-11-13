# guardrail-health.sh (health, moves, audits, backstop) and guardrails.sh
# loosen, on seeded run histories. Nothing outside $TEST_TMPDIR is touched.

. "$TESTS_DIR/helpers/run-state.sh"

H="$SCRIPTS/guardrail-health.sh"
G="$SCRIPTS/guardrails.sh"

# setup [guardrail-line...]: a project, an individual home holding the guardrails given.
setup() {
  make_project
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg" ARTISAN_HOME="$TEST_TMPDIR/home" ARTISAN_TEAM_CACHE="$TEST_TMPDIR/tc"
  mkdir -p "$ARTISAN_HOME"
  git_quiet -C "$ARTISAN_HOME" init
  git -C "$ARTISAN_HOME" symbolic-ref HEAD refs/heads/main
  : >"$ARTISAN_HOME/guardrails.jsonl"
  for l in "$@"; do printf '%s\n' "$l" >>"$ARTISAN_HOME/guardrails.jsonl"; done
  git_quiet -C "$ARTISAN_HOME" add -A
  git_quiet -C "$ARTISAN_HOME" commit -m seed
  cd "$PROJECT"
}

g() { # id key strict [extra-json]
  local x=${4:-}; [ -n "$x" ] || x='{}'
  jq -nc --arg id "$1" --arg k "$2" --argjson s "$3" --argjson x "$x" \
    '{id: $id, key: $k, value: "on", rule: "r", strict: $s, origin: {date: "2026-01-01T00:00:00Z", reason: "seed", who: "Andrew"}, moves: []} + $x'
}

# run name events-json [extra-json]: a run folder with a state.json
run() {
  local x=${3:-}; [ -n "$x" ] || x='{}'
  mkdir -p "$TEST_TMPDIR/runs/$1"
  jq -n --arg id "$1" --argjson ev "$2" --argjson x "$x" \
    '{schema_version: 1, run_id: $id, repo: "owner/repo", tickets: {}, events: $ev, review_gates: []} + $x' >"$TEST_TMPDIR/runs/$1/state.json"
}
R() { printf '%s/runs/%s' "$TEST_TMPDIR" "$1"; }

fired() { jq -nc --arg g "$1" '{event: "guardrail-fired", guardrail: $g}'; }
bypass() { jq -nc --arg g "$1" --arg r "$2" '{event: "guardrail-bypassed", guardrail: $g, reason: $r, by: "Andrew"}'; }
unchanged() { jq -nc --arg a "$1" '{event: "gate-decision", gate: "slice-1", card: 1, by: "Andrew", outcome: "keep", area: $a}'; }

proposal() { jq -r --arg id "$2" '[.proposals[] | select(.id == $id) | .move] | first // "none"' <<<"$1"; }

test_each_guardrail_shows_as_fired_bypassed_or_never_fired_with_origin() {
  setup "$(g a-fired k1 1)" "$(g b-bypassed k2 1)" "$(g c-never k3 1)"
  run r1 "[$(fired a-fired), $(bypass b-bypassed "needed it for a hotfix")]"
  run r2 "[$(fired a-fired)]"
  out=$("$H" health --runs "$(R r1)" "$(R r2)")
  assert_eq "fired bypassed never fired" "$(jq -r '[.guardrails[] | .status] | join(" ")' <<<"$out" | sed 's/ never/ never/')"
  assert_eq "needed it for a hotfix" "$(jq -r '.guardrails[] | select(.id == "b-bypassed") | .bypassed[0].reason' <<<"$out")"
  assert_eq "seed Andrew" "$(jq -r '.guardrails[0] | [.origin.reason, .origin.who] | join(" ")' <<<"$out")"
  assert_contains "$("$H" health --runs "$(R r1)" "$(R r2)" --table)" "bypassed (needed it for a hotfix)"
}

test_three_loosen_events_propose_a_loosen_and_fewer_do_not() {
  setup "$(g gr area-x 2 '{"area":"uploads"}')"
  run r1 "[$(bypass gr "slow"), $(bypass gr "slow again")]"
  assert_eq none "$(proposal "$("$H" health --runs "$(R r1)")" gr)"
  run r2 "[$(unchanged uploads)]"
  out=$("$H" health --runs "$(R r1)" "$(R r2)")
  assert_eq loosen "$(proposal "$out" gr)"
  assert_eq 3 "$(jq '.guardrails[0].loosen.count' <<<"$out")"
  assert_eq loosen "$(proposal "$("$H" health --runs "$(R r1)" "$(R r2)" --threshold 3 --table >/dev/null; "$H" health --runs "$(R r1)" "$(R r2)")" gr)"
}

test_a_guardrail_that_never_fires_over_three_runs_is_proposed_for_loosening() {
  setup "$(g quiet kq 1)"
  other=$(fired other)   # a run only counts once it recorded guardrail events
  run r1 "[$other]"; run r2 "[$other]"
  assert_eq none "$(proposal "$("$H" health --runs "$(R r1)" "$(R r2)")" quiet)"
  run r3 "[$other]"
  assert_eq loosen "$(proposal "$("$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)")" quiet)"
}

test_the_scope_floor_and_a_defer_only_gate_are_never_proposed_for_loosening() {
  setup "$(g floor scope-floor 9)" "$(g defer kd 9 '{"defer_only":true}')"
  o=$(fired other)
  run r1 "[$o]"; run r2 "[$o]"; run r3 "[$o]"; run r4 "[$o, $(bypass floor a), $(bypass floor b), $(bypass floor c)]"
  out=$("$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)" "$(R r4)")
  assert_eq none "$(proposal "$out" floor)"
  assert_eq none "$(proposal "$out" defer)"
  assert_eq "defer floor" "$(jq -r '.never_loosen | sort | join(" ")' <<<"$out")"
  assert_contains "$("$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)" "$(R r4)" --table)" "never loosens"
}

test_tighten_evidence_counts_redirects_differently_answers_misses_and_bugs() {
  setup "$(g gr kt 1 '{"area":"billing"}')"
  run r1 '[{"event":"gate-decision","gate":"s","card":1,"by":"Andrew","outcome":"change","area":"billing"},
           {"event":"shipped-bug","area":"billing","ticket":"7"}]'
  printf '{"ticket":"9","criterion":3,"area":"billing"}\n' >"$TEST_TMPDIR/misses.jsonl"
  out=$("$H" health --runs "$(R r1)" --misses "$TEST_TMPDIR/misses.jsonl")
  assert_eq tighten "$(proposal "$out" gr)"
  assert_eq 3 "$(jq '.guardrails[0].tighten.count' <<<"$out")"
}

test_evidence_both_ways_is_raised_not_proposed() {
  setup "$(g gr kt 1 '{"area":"a"}')"
  run r1 "[$(bypass gr x), $(bypass gr y), $(bypass gr z),
    {\"event\":\"shipped-bug\",\"area\":\"a\"},{\"event\":\"shipped-bug\",\"area\":\"a\"},{\"event\":\"shipped-bug\",\"area\":\"a\"}]"
  assert_eq conflict "$(proposal "$("$H" health --runs "$(R r1)")" gr)"
}

test_three_unshown_decisions_are_spot_checked() {
  setup "$(g gr kt 1 '{"area":"uploads"}')"
  cards='[{"question":"q1","choice":"c1","confidence":"provisional"},{"question":"q2","choice":"c2"},{"question":"q3","choice":"c3"},{"question":"q4","choice":"c4"}]'
  run r1 '[]' "{\"tickets\": {\"5\": {\"evidence\": {\"decisions\": $cards}}, \"6\": {\"evidence\": {\"decisions\": [{\"question\":\"shown\"}]}}},
    \"review_gates\": [{\"tickets\": [6]}]}"
  out=$("$H" spot-check --runs "$(R r1)")
  assert_eq 3 "$(jq '.asked | length' <<<"$out")"
  assert_eq "" "$(jq -r '.asked[] | select(.question == "shown") | .question' <<<"$out")"
  assert_eq q1 "$(jq -r '.asked[0].question' <<<"$out")"   # provisional first
}

test_a_differently_spot_check_counts_toward_a_tighten() {
  setup "$(g gr kt 1 '{"area":"uploads"}')"
  # the record goes through state.sh, so give it a real state file
  write_plan "$TEST_TMPDIR/plan.json"; "$SCRIPTS/state.sh" init "$RUN_DIR" "$TEST_TMPDIR/plan.json"
  for t in 1 2 3; do "$H" spot-check-record --run "$RUN_DIR" --ticket $t --card 0 --answer differently --area uploads; done
  "$H" spot-check-record --run "$RUN_DIR" --ticket 4 --card 0 --answer same --area uploads
  out=$("$H" health --runs "$RUN_DIR")
  assert_eq 3 "$(jq '.guardrails[0].tighten.count' <<<"$out")"
  assert_eq tighten "$(proposal "$out" gr)"
  assert_status 2 "$H" spot-check-record --run "$RUN_DIR" --ticket 4 --card 0 --answer maybe
}

test_triage_misses_and_repeated_discards_surface_with_a_suggestion() {
  setup
  printf '{"ticket":"9","criterion":3}\n{"ticket":"10"}\n' >"$TEST_TMPDIR/misses.jsonl"
  run r1 '[{"event":"pulled","ticket":"1","reason":"auth"},{"event":"deferred-question","ticket":"2","reason":"auth"}]' \
    '{"tickets": {"3": {"status": "closed", "area": "auth"}, "4": {"status": "closed", "area": "other"}}}'
  out=$("$H" audit --runs "$(R r1)" --misses "$TEST_TMPDIR/misses.jsonl")
  assert_contains "$(jq -r '.misses[0].suggestion' <<<"$out")" "criterion 3"
  assert_contains "$(jq -r '.misses[1].suggestion' <<<"$out")" "No criterion recorded"
  assert_eq "auth true other false" "$(jq -r '.discards | map("\(.key) \(.repeated)") | join(" ")' <<<"$out")"
  assert_contains "$(jq -r '.discards[0].suggestion' <<<"$out")" "Repeated 3 times for auth"
}

test_the_hands_on_question_follows_a_hands_on_run_and_the_nudge_follows_five_without() {
  setup
  run h '[{"event":"human-done","ticket":"1"}]'
  for n in 1 2 3 4 5; do run n$n '[]'; done
  out=$("$H" hands-on --runs "$(R h)")
  assert_eq true "$(jq .hands_on_latest <<<"$out")"
  assert_contains "$(jq -r .ask <<<"$out")" "Which ADR or guardrail would have let an agent build it your way?"
  four=$("$H" hands-on --runs "$(R h)" "$(R n1)" "$(R n2)" "$(R n3)" "$(R n4)")
  assert_eq false "$(jq .nudge <<<"$four")"; assert_eq null "$(jq .ask <<<"$four")"
  five=$("$H" hands-on --runs "$(R h)" "$(R n1)" "$(R n2)" "$(R n3)" "$(R n4)" "$(R n5)")
  assert_eq true "$(jq .nudge <<<"$five")"; assert_eq 5 "$(jq .runs_since_hands_on <<<"$five")"
}

test_the_backstop_flags_a_direct_commit_a_pr_with_no_run_and_a_ticket_closed_outside_a_run() {
  setup
  git_quiet -C "$PROJECT" checkout -b feature
  echo a >"$PROJECT/a"; git_quiet -C "$PROJECT" add -A; git_quiet -C "$PROJECT" commit -m "run work"
  git_quiet -C "$PROJECT" checkout main
  git_quiet -C "$PROJECT" merge --no-ff feature -m "Merge run"
  runmerge=$(git -C "$PROJECT" rev-parse HEAD)
  echo b >"$PROJECT/b"; git_quiet -C "$PROJECT" add -A; git_quiet -C "$PROJECT" commit -m "straight to main"
  direct=$(git -C "$PROJECT" rev-parse HEAD)
  run r1 '[{"event":"closed","ticket":"12"}]' "{\"integration\": {\"branch\": \"run/r1\", \"merges\": [{\"ticket\": \"12\", \"commit\": \"$runmerge\"}]}, \"tickets\": {\"12\": {\"status\": \"merged\", \"branch\": \"agent/12\"}}}"
  echo '[{"number":50,"headRefName":"agent/12"},{"number":51,"headRefName":"someone/hotfix"}]' >"$TEST_TMPDIR/prs.json"
  echo '[{"number":12,"closedAt":"2026-02-01"},{"number":77,"closedAt":"2026-02-02"}]' >"$TEST_TMPDIR/closed.json"
  out=$("$H" backstop --runs "$(R r1)" --repo-dir "$PROJECT" --main main --prs "$TEST_TMPDIR/prs.json" --closed "$TEST_TMPDIR/closed.json")
  assert_contains "$(jq -r '.direct_commits | join(" ")' <<<"$out")" "$direct"
  assert_eq 2 "$(jq '.direct_commits | length' <<<"$out")"   # and the project's own first commit
  assert_eq "51" "$(jq -r '.prs_without_run | map(.number) | join(" ")' <<<"$out")"
  assert_eq "77" "$(jq -r '.tickets_closed_outside_run | join(" ")' <<<"$out")"
  assert_contains "$("$H" backstop --runs "$(R r1)" --repo-dir "$PROJECT" --main main --prs "$TEST_TMPDIR/prs.json" --closed "$TEST_TMPDIR/closed.json" --table)" "| ticket closed outside a run | #77 |"
}

# health_report_proposing_loosen ID: three bypasses of ID in three runs, recorded as the latest health report
health_report_proposing_loosen() {
  run r1 "[$(bypass "$1" a)]"; run r2 "[$(bypass "$1" b)]"; run r3 "[$(bypass "$1" c)]"
  "$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)" --record >/dev/null
}

test_loosening_records_the_move_with_its_evidence_and_who() {
  setup "$(g gr kt 3)"
  health_report_proposing_loosen gr
  "$G" loosen --level individual --who Andrew --reason "retro r1" --id gr --strict 2 --run r1 \
    --evidence "3 bypasses: hotfix, hotfix, spike" >/dev/null
  line=$(jq -c 'select(.id == "gr")' "$ARTISAN_HOME/guardrails.jsonl")
  assert_eq "2 loosen Andrew r1 3" "$(jq -r '[.strict, .moves[0].kind, .moves[0].who, .moves[0].run, (.moves[0].evidence | split(" ")[0])] | join(" ")' <<<"$line")"
  assert_eq "3 2" "$(jq -r '[.moves[0].from.strict, .moves[0].to.strict] | join(" ")' <<<"$line")"
  assert_eq origin "$(jq -r 'if .origin.reason == "seed" then "origin" else "lost" end' <<<"$line")"
  assert_eq clean "$([ -z "$(git -C "$ARTISAN_HOME" status --porcelain)" ] && echo clean)"
}

test_loosening_refuses_no_evidence_a_raise_an_agent_and_the_protected() {
  setup "$(g gr kt 3)" "$(g floor scope-floor 9)" "$(g defer kd 9 '{"defer_only":true}')"
  before=$(git -C "$ARTISAN_HOME" rev-parse HEAD)
  assert_status 2 "$G" loosen --level individual --who Andrew --reason x --id gr --strict 1
  assert_status 5 "$G" loosen --level individual --who Andrew --reason x --id gr --strict 3 --evidence e
  assert_status 2 "$G" loosen --level individual --who "agent w" --reason x --id gr --strict 1 --evidence e
  assert_status 7 "$G" loosen --level individual --who Andrew --reason x --id floor --strict 1 --evidence e
  assert_status 7 "$G" loosen --level individual --who Andrew --reason x --id defer --strict 1 --evidence e
  assert_eq "$before" "$(git -C "$ARTISAN_HOME" rev-parse HEAD)"
}

test_runs_with_no_guardrail_events_never_make_a_loosen_proposal() {
  setup "$(g quiet kq 1)"
  run r1 '[]'; run r2 '[]'; run r3 '[]'
  assert_eq none "$(proposal "$("$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)")" quiet)"
}

test_a_missing_run_folder_or_flag_value_is_an_error_not_a_partial_answer() {
  setup
  run r1 '[]'
  assert_status 1 "$H" health --runs "$(R r1)" "$TEST_TMPDIR/nope"
  assert_status 2 "$H" health
  assert_status 2 "$H" backstop --runs "$(R r1)" --since
}

test_loosening_with_no_health_report_refuses_naming_what_is_missing() {
  setup "$(g gr kt 3)"
  before=$(git -C "$ARTISAN_HOME" rev-parse HEAD)
  assert_status 8 "$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e
  assert_contains "$("$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e 2>&1 || true)" "no guardrail-health report"
  assert_eq "$before" "$(git -C "$ARTISAN_HOME" rev-parse HEAD)"
}

test_loosening_a_guardrail_the_latest_report_does_not_propose_refuses() {
  setup "$(g gr kt 3)" "$(g other ko 3)"
  health_report_proposing_loosen other
  run r1 "[$(bypass other a), $(fired gr)]"; run r2 "[$(bypass other b), $(fired gr)]"; run r3 "[$(bypass other c), $(fired gr)]"
  "$H" health --runs "$(R r1)" "$(R r2)" "$(R r3)" --record >/dev/null
  assert_status 8 "$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e
  assert_contains "$("$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e 2>&1 || true)" "does not propose loosening gr"
}

test_loosening_after_a_report_proposing_it_records_the_report() {
  setup "$(g gr kt 3)"
  health_report_proposing_loosen gr
  id=$(jq -r '.id' "$CLAUDE_CONFIG_DIR/artisan-agent-health/latest.json")
  "$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e >/dev/null
  line=$(jq -c 'select(.id == "gr")' "$ARTISAN_HOME/guardrails.jsonl")
  assert_eq "$id" "$(jq -r '.moves[0].report.id' <<<"$line")"
  assert_eq "null" "$(jq -r '.moves[0].override' <<<"$line")"
}

test_loosening_with_an_override_reason_records_reason_and_who_as_a_bypass() {
  setup "$(g gr kt 3)"
  run r1 '[]'
  "$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e \
    --override-reason "the audit is a week away" --run-dir "$(R r1)" >/dev/null
  line=$(jq -c 'select(.id == "gr")' "$ARTISAN_HOME/guardrails.jsonl")
  assert_eq "the audit is a week away|Andrew" "$(jq -r '.moves[0].override | [.reason, .by] | join("|")' <<<"$line")"
  assert_eq "guardrail-bypassed gr Andrew" "$(jq -r '.events[-1] | [.event, .guardrail, .by] | join(" ")' "$(R r1)/state.json")"
  assert_contains "$(jq -r '.events[-1].reason' "$(R r1)/state.json")" "the audit is a week away"
}

test_an_override_with_a_bad_run_dir_is_refused_before_anything_is_committed() {
  setup "$(g gr kt 3)"
  before=$(git -C "$ARTISAN_HOME" rev-parse HEAD)
  assert_status 1 "$G" loosen --level individual --who Andrew --reason x --id gr --strict 2 --evidence e \
    --override-reason why --run-dir "$TEST_TMPDIR/nope"
  assert_eq "$before" "$(git -C "$ARTISAN_HOME" rev-parse HEAD)"
}
