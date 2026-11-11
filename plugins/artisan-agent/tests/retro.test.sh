# Tests for /artisan-agent:retro's script, skills/retro/scripts/retro.sh, on a
# seeded sample run: a project repo with an origin, a run folder, a throwaway
# individual home, the fake tracker (with a `pr create` stand-in) and a stub
# claude for the headless preparer. Nothing here reaches GitHub or ~/.claude.

RETRO="$PLUGIN_ROOT/skills/retro/scripts/retro.sh"
PS="$PLUGIN_ROOT/skills/setup/scripts/project-setup.sh"

gq() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# sample_run: PROJECT (with origin), RUN_DIR (state.json of a finished run),
# ARTISAN_HOME (an individual home), FAKE_GH_DIR and GH_BIN.
sample_run() {
  PROJECT="$TEST_TMPDIR/project"
  gq init --bare "$TEST_TMPDIR/origin.git"
  gq init "$PROJECT"
  mkdir -p "$PROJECT/.artisan-agent"
  printf '.artisan-agent/runs/\n' >"$PROJECT/.gitignore"
  cp "$PLUGIN_ROOT/templates/config.yml" "$PROJECT/.artisan-agent/config.yml"
  printf '# Coding standards\n\n## Always ask\n\n- new dependencies\n' >"$PROJECT/CODING_STANDARDS.md"
  gq -C "$PROJECT" add -A
  gq -C "$PROJECT" commit -m init
  gq -C "$PROJECT" remote add origin "$TEST_TMPDIR/origin.git"
  gq -C "$PROJECT" push -u origin main
  gq -C "$PROJECT" remote set-head origin main

  RUN_DIR="$PROJECT/.artisan-agent/runs/r1"
  mkdir -p "$RUN_DIR"
  local t0=1800000000
  jq -n --argjson t0 "$t0" '{
    schema_version: 1, run_id: "r1", repo: "owner/repo",
    plan: {scope: ["10","11","12"], estimate_usd: 3, budget_usd: 3.75, config: {evidence_threshold: 3},
           tickets: {"10": {estimate_usd: 1}, "11": {estimate_usd: 1}, "12": {estimate_usd: 1}}},
    tickets: {
      "10": {status: "merged", attempts: 1, cost_usd: 1.2, dispatched_at: $t0},
      "11": {status: "merged", attempts: 1, cost_usd: 0.8, dispatched_at: $t0},
      "12": {status: "blocked", attempts: 2, cost_usd: 0.5, failures: [{attempt: 1, reason: "deadline"}, {attempt: 2, reason: "verifier fail"}]}},
    costs: {workers_usd: 2.5, orchestrator_usd: 0, total_usd: 2.5},
    findings: [{from: "10", seq: 1, title: "x"}],
    lessons: [],
    decisions: [
      {id: "d1", kind: "risk-gate", ticket: "10", status: "decided", choice: "clear", by: "Andrew"},
      {id: "d2", kind: "exception", ticket: "12", status: "decided", choice: "take it myself", by: "Andrew", redirect: "self"},
      {id: "d3", kind: "gate", job: 13, status: "decided", choice: "approve", by: "Artisan"},
      {id: "d4", kind: "design", status: "decided", choice: "use a queue", by: "orchestrator"}],
    events: [
      {seq: 1, at: $t0, event: "dispatch", ticket: "10"},
      {seq: 2, at: ($t0 + 3600), event: "merge", ticket: "10"},
      {seq: 3, at: ($t0 + 7200), event: "merge", ticket: "11"}]
  }' >"$RUN_DIR/state.json"

  mkdir -p "$PROJECT/.artisan-agent/triage"
  printf '*\n' >"$PROJECT/.artisan-agent/triage/.gitignore"
  printf '{"ts":"2026-11-10T10:00:00Z","ticket":52,"recommended":"do","ruled":"defer","criterion_that_should_have_caught_it":3,"reason":"pricing","run_id":null}\n' \
    >"$PROJECT/.artisan-agent/triage/misses.jsonl"

  export ARTISAN_HOME="$TEST_TMPDIR/home"
  gq init "$ARTISAN_HOME"
  printf '# Coding standards\n\n## Always ask\n' >"$ARTISAN_HOME/CODING_STANDARDS.md"
  printf '# Product standards\n\n## Always ask\n' >"$ARTISAN_HOME/PRODUCT_STANDARDS.md"
  : >"$ARTISAN_HOME/satisfaction.jsonl"
  gq -C "$ARTISAN_HOME" add -A
  gq -C "$ARTISAN_HOME" commit -m home

  export FAKE_GH_DIR="$TEST_TMPDIR/tracker"
  mkdir -p "$FAKE_GH_DIR" "$TEST_TMPDIR/bin"
  cat >"$TEST_TMPDIR/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr create" ]; then printf '%s\n' "\$*" >>"\$FAKE_GH_DIR/calls"; echo https://github.com/owner/repo/pull/7; exit 0; fi
exec "$PLUGIN_ROOT/tests/fixtures/fake-gh/gh" "\$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  export GH_BIN="$TEST_TMPDIR/bin/gh"
}

# The preparer's lessons for the sample run, one of each kind that matters.
seed_lessons() {
  mkdir -p "$RUN_DIR/retro"
  jq -n '{summary: "The run shipped CSV export for finance staff; one ticket was taken back.", lessons: [
    {id: "L1", kind: "engineering-taste", checkable: true, lesson: "Test files are named after the module they test",
     role: "engineering", scope: "this-project", why: "Two verifier fails were misnamed tests",
     change: {path: "tests/check-test-names.sh", text: "#!/bin/sh\n# fails on a test file named after no module", replace: true}},
    {id: "L2", kind: "product-taste", lesson: "Exports always carry a header row", role: "product", scope: "generalises",
     why: "Redirected at the gate on #10", change: {path: "PRODUCT_STANDARDS.md", section: "## Always ask", text: "- export formats"},
     recommendation: "Yes: it held in both products you export from"},
    {id: "L3", kind: "pipeline", lesson: "verify.sh should show the unmet criterion first", role: "engineering",
     scope: "generalises", ask: "batch", why: "Read twice at the exception", ticket: {title: "Show the unmet criterion first", body: "From run r1."}},
    {id: "L4", kind: "calibration", lesson: "Sonnet tickets cost 20% over estimate", role: "engineering", scope: "this-project",
     why: "Ticket 10 ran 1.2 against 1.0", evidence: ["#10"], change: {key: "estimate_multipliers.claude-sonnet-5-5", value: 1.2}},
    {id: "L5", kind: "upstream", lesson: "Upstream tdd now names CONTEXT.md again", role: "engineering", scope: "this-project",
     why: "A worker read the wrong file"},
    {id: "L6", kind: "domain", lesson: "Export means a downloaded file, not an API", role: "product", scope: "this-project",
     why: "Two tickets used it both ways", change: {path: "GLOSSARY.md", section: "## Language", text: "**Export**: a downloaded file."}}
  ]}' >"$RUN_DIR/retro/lessons.json"
}

test_facts_show_focus_shares_rubber_stamps_throughput_and_cost_per_merged_ticket() {
  sample_run
  mkdir -p "$RUN_DIR/retro"
  printf '{"what":"retyped the ticket numbers","focus":"chore"}\n' >"$RUN_DIR/retro/actions.jsonl"
  local f; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq 2 "$(jq .merged <<<"$f")" merged
  assert_eq 2 "$(jq .hours <<<"$f")" hours
  assert_eq 1 "$(jq .throughput_per_hour <<<"$f")" throughput
  assert_eq 1.25 "$(jq .cost_per_merged_usd <<<"$f")" "cost per merged"
  # risk gate, exception and gate are solution (jobs 13, 15, 13); the miss is problem (job 18);
  # the agent's design decision is not the Artisan's; the retyping is a chore.
  assert_eq 5 "$(jq .actions.total <<<"$f")" actions
  assert_eq '20 60 0 20' "$(jq -r '.actions.shares_percent | "\(.problem) \(.solution) \(.pipeline) \(.chore)"' <<<"$f")" shares
  assert_eq '2 2 100' "$(jq -r '.rubber_stamp | "\(.gates) \(.unchanged) \(.rate)"' <<<"$f")" "rubber stamp"
  assert_eq 1 "$(jq .triage_misses <<<"$f")" misses
  assert_eq 1.2 "$(jq '.per_ticket[] | select(.ticket == "10") | .ratio' <<<"$f")" "cost against estimate"
}

test_each_lesson_gets_its_home_role_and_reach_and_only_judgement_calls_are_questions() {
  sample_run; seed_lessons
  local out; out=$("$RETRO" check "$RUN_DIR")
  local c="$RUN_DIR/retro/checked.json"
  # The seeded machine-checkable taste lesson is proposed as a check.
  assert_eq mechanical "$(jq -r '.lessons[] | select(.id == "L1") | .kind' "$c")" "checkable becomes a check"
  assert_contains "$(jq -r '.lessons[] | select(.id == "L1") | .home' "$c")" "a check"
  assert_eq engineering-taste "$(jq -r '.lessons[] | select(.id == "L1") | .rehomed_from' "$c")"
  assert_eq 'L2 L4' "$(jq -r '[.lessons[] | select(.ask == "question") | .id] | join(" ")' "$c")" questions
  assert_eq 'L1 L3 L5 L6' "$(jq -r '[.lessons[] | select(.ask == "batch") | .id] | join(" ")' "$c")" batch
  assert_eq 0 "$(jq '[.lessons[] | select((.home // "") == "" or (.role // "") == "" or (.scope // "") == "")] | length' "$c")" "home, role, reach"
  assert_contains "$(jq -r '.lessons[] | select(.id == "L3") | .home' "$c")" "arathianevasion/artisan-agent"
  assert_contains "$(jq -r '.lessons[] | select(.id == "L5") | .home' "$c")" "upstream check"
  assert_contains "$(jq -r '.lessons[] | select(.id == "L4") | .question' "$c")" "thin evidence"
  assert_contains "$out" "L1	batch	mechanical"
}

test_check_refuses_a_lesson_without_role_reach_or_change() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  echo '{"lessons":[{"id":"X","kind":"engineering-taste","lesson":"a","why":"b"},{"id":"Y","kind":"nonsense","lesson":"c"}]}' \
    >"$RUN_DIR/retro/lessons.json"
  local err; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "check passed"
  assert_contains "$err" "lesson X: role"
  assert_contains "$err" "lesson X: scope"
  assert_contains "$err" "lesson X: needs change.path"
  assert_contains "$err" "lesson Y: kind"
}

test_render_is_one_chat_round_with_batch_questions_signals_and_satisfaction() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  local r; r=$("$RETRO" render "$RUN_DIR")
  assert_contains "$r" "The run shipped CSV export for finance staff"
  assert_contains "$r" 'one "yes" keeps them all'
  assert_contains "$r" "| # | Lesson | Home | Role | Reach | Why |"
  assert_contains "$r" "| L1 | Test files are named after the module they test | a check (lint rule, test, hook, CI job) (taste a machine can check: was engineering taste) | engineering | this-project |"
  assert_contains "$r" "### Judgement calls"
  assert_contains "$r" "**L2** Keep this lesson (does it generalise beyond this project?)?"
  assert_contains "$r" "| Focus shares |"
  assert_contains "$r" "| Rubber-stamp rate at gates |"
  assert_contains "$r" "| Throughput | 2 merged in 2 h"
  assert_contains "$r" "| Cost per merged ticket | \$1.25 per merged ticket"
  assert_contains "$r" "1. Do you understand the problem this run solved"
  assert_contains "$r" "4. Did anything eat your time without serving a focus? (free text)"
  case "$r" in *"Why this product matters"*) fail "a motivation shown with none recorded" ;; esac
  case "$r" in *"Nothing to learn"*) fail "nothing to learn on a run with lessons" ;; esac
}

test_a_smooth_run_ends_with_nothing_to_learn_plus_the_satisfaction_questions() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  echo '{"lessons":[]}' >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null
  assert_eq true "$(jq .smooth "$RUN_DIR/retro/checked.json")"
  local r; r=$("$RETRO" render "$RUN_DIR")
  assert_contains "$r" "Nothing to learn from this run."
  assert_contains "$r" "3. Is the pipeline better at delivering after this run"
  case "$r" in *"Judgement calls"*|*"one \"yes\""*) fail "lessons shown on a smooth run" ;; esac
}

test_a_recorded_motivation_is_shown_above_the_satisfaction_questions_and_updated_only_when_asked() {
  sample_run; seed_lessons
  echo "My grandmother ran a bakery." | ARTISAN_INDIVIDUAL_HOME=$ARTISAN_HOME bash "$PS" motivation set "$PROJECT" >/dev/null
  "$RETRO" check "$RUN_DIR" >/dev/null
  local r m q head
  r=$("$RETRO" render "$RUN_DIR")
  assert_contains "$r" "> My grandmother ran a bakery."
  m=$(printf '%s\n' "$r" | grep -n 'bakery' | cut -d: -f1)
  q=$(printf '%s\n' "$r" | grep -n '^1\. Do you understand' | cut -d: -f1)
  [ "$m" -lt "$q" ] || fail "motivation (line $m) not above the questions (line $q)"
  case "$r" in *"Repo:"*|*"Private:"*) fail "the record's header shown" ;; esac
  # Not updated unless the Artisan says yes: rendering changes nothing.
  head=$(git -C "$ARTISAN_HOME" rev-parse HEAD)
  "$RETRO" render "$RUN_DIR" >/dev/null
  assert_eq "$head" "$(git -C "$ARTISAN_HOME" rev-parse HEAD)" "render committed something"
  # On yes, the update is committed to the individual home.
  echo "It is how I keep her recipes alive." | "$RETRO" motivation "$RUN_DIR" update >/dev/null
  assert_contains "$(cat "$ARTISAN_HOME"/motivations/*.md)" "recipes alive"
  assert_eq "" "$(git -C "$ARTISAN_HOME" status --porcelain)" "update committed"
  assert_contains "$(git -C "$ARTISAN_HOME" log -1 --format=%s)" "at the retro of run r1"
  assert_contains "$("$RETRO" render "$RUN_DIR")" "> It is how I keep her recipes alive."
}

test_approved_lessons_land_as_one_pr_home_commits_with_origin_and_pipeline_tickets_never_a_retro_issue() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"L1":"yes","L2":"yes","L3":"yes","L4":"no","L5":"yes","L6":"yes"}' >"$TEST_TMPDIR/decisions.json"
  local out home0; home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  out=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" --pr)
  # One project branch with one commit per project lesson, pushed, one PR.
  local wt="$TEST_TMPDIR/project-wt/retro-r1"
  assert_eq 3 "$(git -C "$TEST_TMPDIR/origin.git" rev-list --count main..retro/r1)" "commits on the PR branch"
  assert_contains "$(git -C "$wt" log --format=%B main..HEAD)" "Origin: run r1 of owner/repo"
  [ -f "$wt/tests/check-test-names.sh" ] || fail "the check was not added"
  assert_contains "$(cat "$wt/PRODUCT_STANDARDS.md")" "- export formats"
  assert_contains "$(cat "$wt/GLOSSARY.md")" "**Export**: a downloaded file."
  assert_eq "{}" "$(jq -c .estimate_multipliers <<<"$(bash "$PLUGIN_ROOT/scripts/config.sh" show --file "$wt/.artisan-agent/config.yml")")" "a declined lesson changed config"
  assert_eq 1 "$(grep -c '^pr create' "$FAKE_GH_DIR/calls")" "one PR"
  # A pipeline ticket in arathianevasion/artisan-agent; no retro issue anywhere else.
  assert_eq 1 "$(grep -c '^issue create' "$FAKE_GH_DIR/calls")" "issues created"
  assert_contains "$(grep '^issue create' "$FAKE_GH_DIR/calls")" "-R arathianevasion/artisan-agent"
  assert_contains "$(grep '^issue create' "$FAKE_GH_DIR/calls")" "--label needs-triage"
  # Individual home: the upstream note and the promoted generalising lesson, each with origin.
  assert_eq $((home0 + 2)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "home commits"
  assert_contains "$(cat "$ARTISAN_HOME/upstream-notes.md")" "Origin: run r1"
  assert_contains "$(cat "$ARTISAN_HOME/PRODUCT_STANDARDS.md")" "- Exports always carry a header row (from run r1"
  assert_contains "$(git -C "$ARTISAN_HOME" log --format=%B)" "Origin: run r1 of owner/repo"
  assert_eq "" "$(git -C "$ARTISAN_HOME" status --porcelain)" "home left clean"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "main checkout untouched"
  assert_contains "$out" "project	retro/r1"
  assert_contains "$out" "pr	https://github.com/owner/repo/pull/7"
  # Delivering again changes nothing.
  local calls; calls=$(wc -l <"$FAKE_GH_DIR/calls")
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" --pr >/dev/null
  assert_eq "$calls" "$(wc -l <"$FAKE_GH_DIR/calls")" "second delivery called the tracker"
  assert_eq $((home0 + 2)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "second delivery committed"
  assert_eq 3 "$(git -C "$wt" rev-list --count main..HEAD)" "second delivery added commits"
}

test_nothing_changes_until_the_artisan_answers() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  assert_status 1 "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/none.json"
  echo '{}' >"$TEST_TMPDIR/decisions.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" >/dev/null
  [ ! -d "$TEST_TMPDIR/project-wt/retro-r1" ] || fail "a worktree with no kept lessons"
  git -C "$PROJECT" rev-parse -q --verify refs/heads/retro/r1 >/dev/null && fail "a branch with no kept lessons"
  [ ! -f "$FAKE_GH_DIR/calls" ] || fail "the tracker was called: $(cat "$FAKE_GH_DIR/calls")"
  assert_eq 1 "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "home changed"
}

test_a_calibration_lesson_kept_sets_the_config_number_in_the_pr() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"L4":"yes"}' >"$TEST_TMPDIR/decisions.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" >/dev/null
  local wt="$TEST_TMPDIR/project-wt/retro-r1"
  assert_eq 1.2 "$(bash "$PLUGIN_ROOT/scripts/config.sh" get estimate_multipliers.claude-sonnet-5-5 --file "$wt/.artisan-agent/config.yml")"
  assert_contains "$(cat "$wt/.artisan-agent/config.yml")" "# Multipliers on history-based estimates" "comments kept"
}

test_satisfaction_answers_are_recorded_privately_and_a_score_of_two_and_a_chore_become_lessons() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  cat >"$TEST_TMPDIR/answers.json" <<'EOF'
{"problem": {"score": 4, "comment": "Learned who reads the exports"},
 "solution": {"score": 2, "comment": "The header row was not my call"},
 "pipeline": {"score": "skip"},
 "chores": "retyping ticket numbers; confirming merges"}
EOF
  local out rec
  out=$("$RETRO" satisfaction "$RUN_DIR" "$TEST_TMPDIR/answers.json")
  assert_contains "$out" "why	solution	scored 2"
  assert_contains "$out" "chore	retyping ticket numbers"
  assert_contains "$out" "chore	confirming merges"
  rec=$(tail -1 "$ARTISAN_HOME/satisfaction.jsonl")
  assert_eq '4 2 skip' "$(jq -r '.scores | "\(.problem) \(.solution) \(.pipeline)"' <<<"$rec")" scores
  assert_eq 'answers r1 owner/repo' "$(jq -r '"\(.type) \(.run) \(.project)"' <<<"$rec")"
  assert_contains "$(jq -r .comments.solution <<<"$rec")" "not my call"
  assert_eq 2 "$(jq .facts.merged <<<"$rec")" "the run's facts kept"
  [ -n "$(jq -r .date <<<"$rec")" ] || fail "no date"
  assert_eq "" "$(git -C "$ARTISAN_HOME" status --porcelain)" "record committed"
  [ ! -f "$PROJECT/satisfaction.jsonl" ] || fail "answers in the project"
  # The "why?" answer becomes a lesson, kept without another question.
  "$RETRO" add-lesson "$RUN_DIR" '{"kind":"experience","lesson":"I want the header-row call at the gate","role":"product","scope":"this-project","why":"Scored solution 2"}' >/dev/null
  "$RETRO" check "$RUN_DIR" >/dev/null
  assert_eq 'A1 A2 A3' "$(jq -r '[.lessons[] | select(.source == "artisan") | .id] | join(" ")' "$RUN_DIR/retro/checked.json")"
  assert_eq 0 "$(jq '[.lessons[] | select(.source == "artisan" and .ask == "question")] | length' "$RUN_DIR/retro/checked.json")"
  # Named chores become pipeline tickets on delivery.
  echo '{}' >"$TEST_TMPDIR/decisions.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" >/dev/null
  assert_eq 2 "$(grep -c '^issue create -R arathianevasion/artisan-agent' "$FAKE_GH_DIR/calls")" "chore tickets"
  assert_contains "$(cat "$FAKE_GH_DIR"/issue-*.json)" "Chore: retyping ticket numbers"
  assert_eq 'lesson' "$(tail -1 "$ARTISAN_HOME/satisfaction.jsonl" | jq -r .type)" "experience lesson kept with the record"
  # Recorded once per run.
  assert_status 3 "$RETRO" satisfaction "$RUN_DIR" "$TEST_TMPDIR/answers.json"
}

test_a_fall_of_one_over_three_runs_prompts_why() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  printf '%s\n' \
    '{"type":"answers","project":"owner/repo","run":"r-a","scores":{"problem":4,"solution":4,"pipeline":5}}' \
    '{"type":"answers","project":"other/repo","run":"r-x","scores":{"problem":1,"solution":1,"pipeline":1}}' \
    '{"type":"answers","project":"owner/repo","run":"r-b","scores":{"problem":4,"solution":4,"pipeline":4}}' \
    >"$ARTISAN_HOME/satisfaction.jsonl"
  gq -C "$ARTISAN_HOME" commit -am history
  echo '{"problem":{"score":4},"solution":{"score":"skip"},"pipeline":{"score":4},"chores":"none"}' >"$TEST_TMPDIR/answers.json"
  local out; out=$("$RETRO" satisfaction "$RUN_DIR" "$TEST_TMPDIR/answers.json")
  assert_eq "why	pipeline	fell from 5 to 4 over three runs" "$out"
}

test_satisfaction_refuses_a_score_out_of_range() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  echo '{"problem":{"score":7},"solution":{"score":3},"pipeline":{"score":3}}' >"$TEST_TMPDIR/answers.json"
  assert_status 1 "$RETRO" satisfaction "$RUN_DIR" "$TEST_TMPDIR/answers.json"
  assert_eq 0 "$(wc -l <"$ARTISAN_HOME/satisfaction.jsonl" | tr -d ' ')" "nothing recorded"
}

test_prepare_runs_a_fresh_capped_headless_session_and_checks_its_lessons() {
  sample_run
  cat >"$TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >"$ARTISAN_RUN_DIR/retro/args"
echo "ROLE=$ARTISAN_ROLE PWD=$PWD" >"$ARTISAN_RUN_DIR/retro/env"
echo '{"lessons":[{"kind":"pipeline","lesson":"Name the chat log in the digest","role":"engineering","scope":"generalises","why":"looked for it"}]}' \
  >"$ARTISAN_RUN_DIR/retro/lessons.json"
echo '{"what":"asked for the run status twice","focus":"chore"}' >"$ARTISAN_RUN_DIR/retro/actions.jsonl"
echo '{"type":"result","total_cost_usd":0.01}'
STUB
  chmod +x "$TEST_TMPDIR/bin/claude"
  printf 'chat line\n' >"$TEST_TMPDIR/chat.jsonl"
  local out
  out=$(ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR" --chat-log "$TEST_TMPDIR/chat.jsonl" --max-budget-usd 0.50)
  assert_contains "$out" "L1	batch	pipeline"
  local args; args=$(cat "$RUN_DIR/retro/args")
  assert_contains "$args" "[-p]"
  assert_contains "$args" "[--max-budget-usd]
[0.50]"
  assert_contains "$(cat "$RUN_DIR/retro/prompt.md")" "$TEST_TMPDIR/chat.jsonl"
  assert_contains "$(cat "$RUN_DIR/retro/prompt.md")" "Prepare the retro"
  assert_contains "$(cat "$RUN_DIR/retro/env")" "ROLE=retro"
  assert_eq 5 "$(jq .actions.total "$RUN_DIR/retro/facts.json")" "the chat's action counted with the decisions and the miss"
  assert_eq 1 "$(jq .actions.counts.chore "$RUN_DIR/retro/facts.json")" "the chat's chore"
}

test_prepare_fails_when_the_preparer_writes_no_lessons() {
  sample_run
  printf '#!/bin/sh\necho "{}"\n' >"$TEST_TMPDIR/bin/claude"; chmod +x "$TEST_TMPDIR/bin/claude"
  assert_status 1 env ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR"
}

test_the_retro_reads_only_misses_newer_than_the_last_retro() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{}' >"$TEST_TMPDIR/decisions.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/decisions.json" >/dev/null
  [ -f "$PROJECT/.artisan-agent/retro/last" ] || fail "no last-retro mark"
  assert_eq "" "$(git -C "$PROJECT" status --porcelain)" "the mark is not ignored"
  assert_eq 0 "$(jq .triage_misses <<<"$("$RETRO" facts "$RUN_DIR")")" "an old miss read again"
}
