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
  local f=; f=$("$RETRO" facts "$RUN_DIR")
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
  local out=; out=$("$RETRO" check "$RUN_DIR")
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
  local err=; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "check passed"
  assert_contains "$err" "lesson X: role"
  assert_contains "$err" "lesson X: scope"
  assert_contains "$err" "lesson X: needs change.path"
  assert_contains "$err" "lesson Y: kind"
}

test_a_check_must_be_the_check_itself_not_a_line_in_a_standards_file() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  echo '{"lessons":[{"id":"X","kind":"product-taste","checkable":true,"lesson":"Exports carry a header row","role":"product","scope":"this-project","why":"#12","change":{"path":"PRODUCT_STANDARDS.md","text":"- header rows"}}]}' \
    >"$RUN_DIR/retro/lessons.json"
  local err=; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "check passed"
  assert_contains "$err" "lesson X: a check's change must be the check itself"
}

test_render_is_one_chat_round_with_batch_questions_signals_and_satisfaction() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  local r=; r=$("$RETRO" render "$RUN_DIR")
  assert_contains "$r" "The run shipped CSV export for finance staff"
  assert_contains "$r" 'one "yes" keeps them all'
  assert_contains "$r" "| # | Lesson | Home | Role | Reach | Why |"
  assert_contains "$r" "| L1 | Test files are named after the module they test | a check (lint rule, test, hook, CI job) (taste a machine can check: was engineering taste) | engineering | this-project |"
  assert_contains "$r" "### Judgement calls"
  assert_contains "$r" "**L2** Keep this lesson (does it generalise beyond this project?)?"
  assert_contains "$r" "| Focus shares |"
  assert_contains "$r" "| Rubber-stamp rate | 2 of 2 decisions unchanged (100%): 2 of 2 gate decisions approved unchanged, 0 of 0 rulings took the recommendation |"
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
  local r=; r=$("$RETRO" render "$RUN_DIR")
  assert_contains "$r" "Nothing to learn from this run."
  assert_contains "$r" "3. Is the pipeline better at delivering after this run"
  case "$r" in *"Judgement calls"*|*"one \"yes\""*) fail "lessons shown on a smooth run" ;; esac
}

test_a_recorded_motivation_is_shown_above_the_satisfaction_questions_and_updated_only_when_asked() {
  sample_run; seed_lessons
  echo "My grandmother ran a bakery." | ARTISAN_INDIVIDUAL_HOME=$ARTISAN_HOME bash "$PS" motivation set "$PROJECT" >/dev/null
  "$RETRO" check "$RUN_DIR" >/dev/null
  local r= m= q= head=
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
  local out= home0=; home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
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
  local calls=; calls=$(wc -l <"$FAKE_GH_DIR/calls")
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
  local out= rec=
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
  local out=; out=$("$RETRO" satisfaction "$RUN_DIR" "$TEST_TMPDIR/answers.json")
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
  local out=
  out=$(ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR" --chat-log "$TEST_TMPDIR/chat.jsonl" --max-budget-usd 0.50)
  assert_contains "$out" "L1	batch	pipeline"
  local args=; args=$(cat "$RUN_DIR/retro/args")
  assert_contains "$args" "[-p]"
  assert_contains "$args" "[--max-budget-usd]
[0.50]"
  assert_contains "$args" "[--permission-mode]
[dontAsk]
[--allowedTools]"
  local tool=
  for tool in 'Bash(ls:*)' 'Bash(head:*)' 'Bash(python3 -I:*)' 'Bash(jq:*)' Write; do
    assert_contains "$args" "$tool"
  done
  assert_contains "$(cat "$RUN_DIR/retro/prompt.md")" "- Chat log: \`$RUN_DIR/retro/chat.md\`"
  assert_contains "$(cat "$RUN_DIR/retro/chat.md")" "chat line"
  assert_contains "$(cat "$RUN_DIR/retro/prompt.md")" "Prepare the retro"
  assert_contains "$(cat "$RUN_DIR/retro/env")" "ROLE=retro"
  assert_eq 5 "$(jq .actions.total "$RUN_DIR/retro/facts.json")" "the chat's action counted with the decisions and the miss"
  assert_eq 1 "$(jq .actions.counts.chore "$RUN_DIR/retro/facts.json")" "the chat's chore"
}

# A Claude Code transcript: three turns the Artisan typed (a string, text
# blocks, a slash command), and what is not theirs: a tool result, a meta
# line, a command's output and the assistant.
chat_transcript() {
  cat >"$1" <<'JSONL'
{"type":"user","timestamp":"2026-11-14T10:00:00Z","message":{"role":"user","content":"Approve the plan, but run #12 before #11"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Will do."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","timestamp":"2026-11-14T10:01:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"TOOL OUTPUT"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"META CAVEAT"}}
{"type":"user","timestamp":"2026-11-14T10:05:00Z","message":{"role":"user","content":[{"type":"text","text":"Merge gate is red again:\nwhy?"}]}}
{"type":"user","message":{"role":"user","content":"<local-command-stdout>COMMAND OUTPUT</local-command-stdout>"}}
{"type":"user","timestamp":"2026-11-14T11:00:00Z","message":{"role":"user","content":"<command-name>/artisan-agent:retro</command-name>"}}
JSONL
}

# #245: the preparer reads the Artisan's turns from a file in its own run
# folder, so no shell read of the transcript is needed and none is denied.
test_with_a_chat_log_the_preparer_counts_the_artisans_chat_actions_from_its_turns() {
  sample_run
  chat_transcript "$TEST_TMPDIR/transcript.jsonl"
  cat >"$TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" >"$ARTISAN_RUN_DIR/retro/args"
chat=$(printf '%s' "$*" | sed -n 's/^- Chat log: `\([^`]*\)`.*/\1/p' | head -1)
case "$chat" in "$ARTISAN_RUN_DIR"/*) ;; *) echo "{\"type\":\"result\",\"permission_denials\":[{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$chat\"}}]}"; exit 0 ;; esac
grep '^### ' "$chat" | while IFS= read -r _; do echo '{"what":"steered the run in chat","job":13,"focus":"pipeline"}'; done >"$ARTISAN_RUN_DIR/retro/actions.jsonl"
echo '{"lessons":[]}' >"$ARTISAN_RUN_DIR/retro/lessons.json"
echo '{"type":"result","permission_denials":[]}'
STUB
  chmod +x "$TEST_TMPDIR/bin/claude"
  ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR" --chat-log "$TEST_TMPDIR/transcript.jsonl" >/dev/null 2>"$TEST_TMPDIR/err"
  local turns=; turns=$(cat "$RUN_DIR/retro/chat.md")
  assert_contains "$turns" "Approve the plan, but run #12 before #11"
  assert_contains "$turns" "Merge gate is red again:
why?"
  assert_contains "$turns" "/artisan-agent:retro"
  local not=
  for not in "TOOL OUTPUT" "META CAVEAT" "COMMAND OUTPUT" "Will do."; do
    case "$turns" in *"$not"*) fail "the Artisan's turns hold what they didn't type: $not" ;; esac
  done
  assert_eq 3 "$(jq .actions.counts.pipeline "$RUN_DIR/retro/facts.json")" "one pipeline action per turn"
  case "$(cat "$TEST_TMPDIR/err")" in *denied*) fail "the preparer was denied: $(cat "$TEST_TMPDIR/err")" ;; esac
  assert_contains "$(cat "$RUN_DIR/retro/args")" "[--add-dir]
[$RUN_DIR]"
  assert_eq false "$(jq .actions.incomplete "$RUN_DIR/retro/facts.json")" "shares measured"
}

test_prepare_says_what_the_preparer_was_denied() {
  sample_run
  cat >"$TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"lessons":[]}' >"$ARTISAN_RUN_DIR/retro/lessons.json"
echo '{"type":"result","permission_denials":[{"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"for f in a; do ls $f; done"}}]}'
STUB
  chmod +x "$TEST_TMPDIR/bin/claude"
  ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR" >/dev/null 2>"$TEST_TMPDIR/err" || true
  assert_contains "$(cat "$TEST_TMPDIR/err")" "the preparer was denied these tool calls:
  Bash: for f in a; do ls \$f; done"
}

# #245: shares from a preparer that was denied a tool are not measured ones.
test_a_preparer_run_with_a_denied_tool_marks_the_focus_shares_incomplete() {
  sample_run
  chat_transcript "$TEST_TMPDIR/transcript.jsonl"
  cat >"$TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"lessons":[{"kind":"pipeline","lesson":"x","role":"engineering","scope":"this-project","why":"y","ticket":{"title":"t","body":"b"}}]}' >"$ARTISAN_RUN_DIR/retro/lessons.json"
: >"$ARTISAN_RUN_DIR/retro/actions.jsonl"
echo '{"type":"result","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"jq -r . /home/x/transcript.jsonl"}},{"tool_name":"Read","tool_input":{"file_path":"/home/x/transcript.jsonl"}}]}'
STUB
  chmod +x "$TEST_TMPDIR/bin/claude"
  ARTISAN_CLAUDE_BIN="$TEST_TMPDIR/bin/claude" "$RETRO" prepare "$RUN_DIR" --chat-log "$TEST_TMPDIR/transcript.jsonl" >/dev/null 2>&1
  assert_eq true "$(jq .actions.incomplete "$RUN_DIR/retro/facts.json")" "facts"
  assert_eq '["Bash","Read"]' "$(jq -c .actions.denied "$RUN_DIR/retro/facts.json")" "the denied tools"
  local row=
  row=$("$RETRO" render "$RUN_DIR" | grep '^| Focus shares |')
  assert_contains "$row" "incomplete"
  assert_contains "$row" "the preparer was denied Bash, Read"
  # A later facts (render, satisfaction) keeps the mark: it comes from the preparer's session.
  "$RETRO" facts "$RUN_DIR" >/dev/null
  assert_eq true "$(jq .actions.incomplete "$RUN_DIR/retro/facts.json")" "facts recomputed"
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

test_a_gate_decided_against_is_not_a_rubber_stamp() {
  sample_run
  jq '.decisions += [{id: "d5", kind: "gate", status: "decided", choice: "reject: wrong table", by: "Andrew"}]' \
    "$RUN_DIR/state.json" >"$TEST_TMPDIR/s" && mv "$TEST_TMPDIR/s" "$RUN_DIR/state.json"
  assert_eq '3 2 67' "$(jq -r '.rubber_stamp | "\(.gates) \(.unchanged) \(.rate)"' <<<"$("$RETRO" facts "$RUN_DIR")")"
}

test_a_generalising_check_is_promoted_as_a_check_and_domain_stays_with_the_project() {
  sample_run; mkdir -p "$RUN_DIR/retro"
  jq -n '{lessons: [
    {id: "C", kind: "mechanical", lesson: "CSV exports start with a header row", role: "engineering", scope: "generalises", why: "#12",
     change: {path: "tests/test_header.sh", text: "#!/bin/sh\nhead -1 out.csv | grep -q ,", replace: true}},
    {id: "D", kind: "domain", lesson: "Export means a file", role: "product", scope: "generalises", why: "#10",
     change: {path: "GLOSSARY.md", text: "**Export**: a file."}}]}' >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null
  assert_eq 'question batch' "$(jq -r '[.lessons[].ask] | join(" ")' "$RUN_DIR/retro/checked.json")"
  echo '{"C":"yes","D":"yes"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_contains "$(cat "$ARTISAN_HOME/CODING_STANDARDS.md")" "## Checks

- CSV exports start with a header row [check: tests/test_header.sh] (from run r1"
  case "$(cat "$ARTISAN_HOME/CODING_STANDARDS.md")" in *"Export means"*) fail "a domain lesson promoted" ;; esac
}

test_a_failed_delivery_leaves_the_misses_for_the_next_retro() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"L3":"yes"}' >"$TEST_TMPDIR/d.json"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_TMPDIR/bin/gh"
  assert_status 1 "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json"
  [ ! -f "$PROJECT/.artisan-agent/retro/last" ] || fail "marked done after a failure"
}

# gate_events: the sample run's merge gates (#199): #10 red then green
# (green on a rerun: flaky), #11 no verdict, a red base, then a skipped gate,
# #12 red on a local gate, and two gates the Artisan decided.
gate_events() {
  local t0=1800000000
  jq --argjson t0 "$t0" '
    .tickets["10"].suite = {passed: true, mode: "ci", run_id: 501, base_check: {verdict: "flaky"}}
    | .events = [
      {seq: 1, at: $t0, event: "dispatch", ticket: "10"},
      {seq: 2, at: ($t0 + 100), event: "merge-gate", ticket: "10", mode: "ci", gate: 1},
      {seq: 3, at: ($t0 + 820), event: "ci-wait", ticket: "10", gate: 1, minutes: 12, outcome: "red"},
      {seq: 4, at: ($t0 + 820), event: "failed", ticket: "10", kind: "ci"},
      {seq: 5, at: ($t0 + 1000), event: "merge-gate", ticket: "10", mode: "ci", gate: 2},
      {seq: 6, at: ($t0 + 2200), event: "ci-wait", ticket: "10", gate: 2, minutes: 20, outcome: "success"},
      {seq: 7, at: ($t0 + 3600), event: "merge", ticket: "10"},
      {seq: 8, at: ($t0 + 3700), event: "merge-gate", ticket: "11", mode: "ci", gate: 3},
      {seq: 9, at: ($t0 + 4000), event: "ci-wait", ticket: "11", gate: 3, minutes: 5, outcome: "no-verdict"},
      {seq: 10, at: ($t0 + 4000), event: "parked", reason: "ci", ticket: "11"},
      {seq: 11, at: ($t0 + 4500), event: "merge-gate", ticket: "11", mode: "ci", gate: 4},
      {seq: 12, at: ($t0 + 4980), event: "ci-wait", ticket: "11", gate: 4, minutes: 8, outcome: "red"},
      {seq: 13, at: ($t0 + 4980), event: "parked", reason: "base", ticket: "11"},
      {seq: 14, at: ($t0 + 6000), event: "merge-gate", ticket: "11", mode: "ci", gate: 5},
      {seq: 15, at: ($t0 + 6000), event: "merge-gate-skipped", ticket: "11"},
      {seq: 16, at: ($t0 + 6000), event: "ci-wait", ticket: "11", gate: 5, minutes: 0, outcome: "success"},
      {seq: 17, at: ($t0 + 7200), event: "merge", ticket: "11"},
      {seq: 18, at: ($t0 + 7300), event: "merge-gate", ticket: "12", mode: "local", gate: 6},
      {seq: 19, at: ($t0 + 7900), event: "blocked", ticket: "12"},
      {seq: 20, at: ($t0 + 8000), event: "gate-opened", gate: "e1", kind: "exception"},
      {seq: 21, at: ($t0 + 8000 + 31 * 60), event: "gate-decided", gate: "e1", kind: "exception"},
      {seq: 22, at: ($t0 + 10000), event: "gate-opened", gate: "end", kind: "end"},
      {seq: 23, at: ($t0 + 10000 + 76 * 60), event: "end-gate-approved"}]' \
    "$RUN_DIR/state.json" >"$RUN_DIR/state.json.new" && mv "$RUN_DIR/state.json.new" "$RUN_DIR/state.json"
}

test_facts_show_what_the_merge_gates_cost() {
  sample_run; gate_events
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq '5 2.5' "$(jq -r '.merge_gates | "\(.run) \(.run_per_merged)"' <<<"$f")" "gates run, per merged ticket"
  # CI: 12 + 20 + 5 + 8 + 0; the local gate 10 minutes, start to block.
  assert_eq '55 27.5' "$(jq -r '.merge_gates | "\(.minutes) \(.minutes_per_merged)"' <<<"$f")" "minutes waiting"
  assert_eq '5 2 1 1 1' "$(jq -r '.merge_gates.red | "\(.total) \(.own) \(.base) \(.flaky) \(.no_verdict)"' <<<"$f")" "red by cause"
  assert_eq '1 0' "$(jq -r '.merge_gates.not_run | "\(.skipped) \(.reused)"' <<<"$f")" "gates not run"
  assert_eq '2 107 76' "$(jq -r '.artisan_wait | "\(.decisions) \(.minutes) \(.longest_minutes)"' <<<"$f")" "waiting on the Artisan"
}

test_a_state_file_from_before_the_gate_events_gives_null_figures() {
  sample_run
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq 'null null null null' "$(jq -r '.merge_gates | "\(.run) \(.minutes) \(.red.total) \(.not_run.skipped)"' <<<"$f")" "no gate figures"
  assert_eq 'null null' "$(jq -r '.artisan_wait | "\(.minutes) \(.longest_minutes)"' <<<"$f")" "no gate waits"
  jq 'del(.events)' "$RUN_DIR/state.json" >"$RUN_DIR/s.json" && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
  f=$("$RETRO" facts "$RUN_DIR")
  assert_eq null "$(jq .merge_gates.run <<<"$f")" "no events at all"
}

test_the_retro_round_shows_the_merge_gate_costs_as_a_table() {
  sample_run; gate_events; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "| Merge gates run | 5 (2.5 per merged ticket) |"
  assert_contains "$out" "| Waiting on merge gates | 55 min (27.5 per merged ticket) |"
  assert_contains "$out" "| Red gates by cause | 5: own failure 2 · red base 1 · flaky 1 · no verdict 1 |"
  assert_contains "$out" "| Gates not run | skipped 1 · reused 0 |"
  assert_contains "$out" "| Waiting on the Artisan | 107 min over 2 decisions (longest 76 min) |"
}

test_an_old_run_shows_a_dash_for_each_merge_gate_figure() {
  sample_run; seed_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "| Merge gates run | - |"
  assert_contains "$out" "| Waiting on the Artisan | - |"
}

test_ci_gates_from_before_their_wait_was_recorded_give_null_minutes_and_causes() {
  sample_run; gate_events
  # A run from before #195: its CI gates logged merge-gate but no ci-wait.
  jq '.events |= map(select(.event != "ci-wait")) | del(.tickets["10"].suite)' "$RUN_DIR/state.json" >"$RUN_DIR/s.json" \
    && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq '5 1' "$(jq -r '.merge_gates | "\(.run) \(.not_run.skipped)"' <<<"$f")" "gates run and skipped are still known"
  assert_eq 'null null null null null' \
    "$(jq -r '.merge_gates | "\(.minutes) \(.minutes_per_merged) \(.red.total) \(.red.own) \(.red.no_verdict)"' <<<"$f")" "unknown, not zero"
}

test_the_table_dashes_only_the_figures_an_old_ci_run_cannot_have() {
  sample_run; gate_events
  jq '.events |= map(select(.event != "ci-wait"))' "$RUN_DIR/state.json" >"$RUN_DIR/s.json" && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
  local out=; out=$(python3 -I "$PLUGIN_ROOT/skills/retro/scripts/retro.py" gate-costs "$RUN_DIR/state.json")
  assert_contains "$out" "| Merge gates run | 5 (2.5 per merged ticket) |"
  assert_contains "$out" "| Waiting on merge gates | - |"
  assert_contains "$out" "| Red gates by cause | - |"
}

# ---- the merge gate's time limit (#200)

# The sample run's gates that ran: CI 12, 20, 5 and 8 minutes and the local
# gate's 10; the skipped gate (its ci-wait shares the skipped event's sha)
# ran nothing, so the median is 10.
mark_skipped_sha() {
  jq '.events |= map(if (.event == "merge-gate-skipped") or (.event == "ci-wait" and .gate == 5) then . + {sha: "s5"} else . end)' \
    "$RUN_DIR/state.json" >"$RUN_DIR/s.json" && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
}
set_limit() {
  jq --argjson l "$1" '.plan.config.merge_gate_minutes_limit = $l' "$RUN_DIR/state.json" >"$RUN_DIR/s.json" \
    && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
}

test_facts_hold_the_median_gate_minutes_and_whether_it_is_over_the_limit() {
  sample_run; gate_events; mark_skipped_sha
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  # A plan from before #200 has no limit: no verdict, so no line.
  assert_eq '10 null null' "$(jq -r '.merge_gates | "\(.median_minutes) \(.limit_minutes) \(.over_limit)"' <<<"$f")" "no limit in the plan"
  set_limit 6
  f=$("$RETRO" facts "$RUN_DIR")
  assert_eq '10 6 true' "$(jq -r '.merge_gates | "\(.median_minutes) \(.limit_minutes) \(.over_limit)"' <<<"$f")" "over the default"
  set_limit 10
  f=$("$RETRO" facts "$RUN_DIR")
  assert_eq '10 10 false' "$(jq -r '.merge_gates | "\(.median_minutes) \(.limit_minutes) \(.over_limit)"' <<<"$f")" "at the limit is not over"
}

test_a_run_with_no_gate_minutes_has_no_median_and_no_verdict_on_the_limit() {
  sample_run; set_limit 6
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq 'null 6 null' "$(jq -r '.merge_gates | "\(.median_minutes) \(.limit_minutes) \(.over_limit)"' <<<"$f")" "no gates"
}

test_the_packet_says_when_the_merge_gate_is_over_its_limit_and_proposes_a_ticket() {
  sample_run; gate_events; mark_skipped_sha; seed_lessons; set_limit 6
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "**The merge gate is over its time limit:** a median of 10 minutes per gate this run, against a limit of 6 (\`merge_gate_minutes_limit\`)."
  assert_contains "$out" "Proposed: a ticket in this project to bring the merge gate back under 6 minutes."
  set_limit 10
  rm -f "$RUN_DIR/retro/facts.json"
  out=$("$RETRO" render "$RUN_DIR")
  assert_not_contains "$out" "over its time limit"
  assert_not_contains "$out" "back under"
}

# ---- the balance: open-decision rulings and the leverage line (#234)

# with_rulings: three open decisions on the sample run, filed and ruled by
# the Decision chat: #40 took the raiser's recommendation (20 minutes after
# it was filed), #41 changed it (40 minutes), #42 recorded no verdict (10
# minutes). #41 was deferred first and answered later: one wait, two rulings.
with_rulings() {
  local t0=1800000000
  jq --argjson t0 "$t0" '
    .events += [
      {seq: 50, at: ($t0 + 600), event: "guardrail-fired", guardrail: "open-decision", ticket: "10", raised_by: "worker", case: "incomplete", question: "40"},
      {seq: 51, at: ($t0 + 600), event: "asked", ticket: "10", question: "40"},
      {seq: 52, at: ($t0 + 600 + 20 * 60), event: "ruled", ticket: "10", question: "40", ruling: "answer", took_recommendation: true, needed_decision_chat: true},
      {seq: 53, at: ($t0 + 900), event: "asked", ticket: "11", question: "41"},
      {seq: 54, at: ($t0 + 900 + 40 * 60), event: "ruled", ticket: "11", question: "41", ruling: "defer", took_recommendation: false, needed_decision_chat: true},
      {seq: 55, at: ($t0 + 900 + 90 * 60), event: "ruled", ticket: "11", question: "41", ruling: "answer", took_recommendation: false, needed_decision_chat: true},
      {seq: 56, at: ($t0 + 1200), event: "asked", ticket: "12", question: "42"},
      {seq: 57, at: ($t0 + 1200 + 10 * 60), event: "ruled", ticket: "12", question: "42", ruling: "reject", took_recommendation: null, needed_decision_chat: null}]' \
    "$RUN_DIR/state.json" >"$RUN_DIR/s.json" && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
}

test_each_ruling_is_one_of_the_artisans_actions_and_one_that_took_the_recommendation_is_a_rubber_stamp() {
  sample_run; with_rulings
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  # The sample's three decisions and one miss, plus four rulings (job 3).
  assert_eq 8 "$(jq .actions.total <<<"$f")" "rulings are actions"
  assert_eq 5 "$(jq .actions.counts.problem <<<"$f")" "the miss and each ruling (job 3) serve the problem"
  # Two gates approved unchanged, one ruling that took the recommendation, of
  # two gates and three rulings with a verdict (#42 has none).
  assert_eq '2 3 3 5 60' "$(jq -r '.rubber_stamp | "\(.gates) \(.rulings) \(.unchanged) \(.decisions) \(.rate)"' <<<"$f")" "rubber stamp"
  assert_eq '5 2 40 0 2 1' "$(jq -r '.leverage | "\(.decisions) \(.changed) \(.rate) \(.gates_changed) \(.rulings_changed) \(.rulings_unknown)"' <<<"$f")" "leverage"
}

test_the_signals_show_the_leverage_line_beside_throughput_and_the_waits_on_the_artisan() {
  sample_run; gate_events; with_rulings; seed_lessons
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  # Each question from its filing to its first ruling: 20 + 40 + 10.
  assert_eq '3 70 40' "$(jq -r '.open_decision_wait | "\(.rulings) \(.minutes) \(.longest_minutes)"' <<<"$f")" "open decisions waited"
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "| Rubber-stamp rate | 3 of 5 decisions unchanged (60%): 2 of 2 gate decisions approved unchanged, 1 of 3 rulings took the recommendation |"
  assert_contains "$out" "| Leverage | 40% of 5 decisions changed the outcome (gates 0 · rulings 2; 1 ruling with no verdict not counted) |"
  assert_contains "$out" "| Throughput | 2 merged in"
  assert_contains "$out" "| Waited on the Artisan | gates 107 min over 2 · open decisions 70 min over 3 (longest 40 min) |"
  # In that order: the balance reads as one block.
  local lev=; lev=$(printf '%s\n' "$out" | grep -n '^| Leverage |' | cut -d: -f1)
  local tp=; tp=$(printf '%s\n' "$out" | grep -n '^| Throughput |' | cut -d: -f1)
  local w=; w=$(printf '%s\n' "$out" | grep -n '^| Waited on the Artisan |' | cut -d: -f1)
  [ "$lev" -lt "$tp" ] && [ "$tp" -lt "$w" ] || fail "leverage, throughput and waits not side by side: $lev $tp $w"
}

test_a_run_with_no_decisions_shows_no_leverage_and_no_waits() {
  sample_run; seed_lessons
  jq '.decisions = []' "$RUN_DIR/state.json" >"$RUN_DIR/s.json" && mv "$RUN_DIR/s.json" "$RUN_DIR/state.json"
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "| Rubber-stamp rate | no gate decisions or rulings this run |"
  assert_contains "$out" "| Leverage | no gate decisions or rulings this run |"
  assert_contains "$out" "| Waited on the Artisan | - |"
}

test_the_leverage_trend_reads_earlier_runs_facts_from_the_satisfaction_record() {
  sample_run; with_rulings; seed_lessons
  # Earlier runs of this project, oldest first: r0a from before #234 (its
  # facts have gates only: 2 decisions, none changed), r0b with a leverage
  # line (2 of 4 changed); another project's run and a lesson line are not read.
  {
    echo '{"type":"answers","project":"owner/repo","run":"r0a","facts":{"rubber_stamp":{"gates":2,"unchanged":2,"rate":100}}}'
    echo '{"type":"answers","project":"other/repo","run":"x9","facts":{"leverage":{"decisions":10,"changed":10,"rate":100}}}'
    echo '{"type":"lesson","project":"owner/repo","run":"r0b","lesson":"x"}'
    echo '{"type":"answers","project":"owner/repo","run":"r0b","facts":{"leverage":{"decisions":4,"changed":2,"rate":50}}}'
  } >"$ARTISAN_HOME/satisfaction.jsonl"
  local f=; f=$("$RETRO" facts "$RUN_DIR")
  assert_eq 'r0a:0 r0b:50 r1:40' "$(jq -r '[.leverage.trend.runs[] | "\(.run):\(.rate)"] | join(" ")' <<<"$f")" "the runs, oldest first"
  # Over the three runs: (0 + 2 + 2) of (2 + 4 + 5) decisions changed the outcome.
  assert_eq 36 "$(jq .leverage.trend.rate <<<"$f")" "the trend"
  "$RETRO" check "$RUN_DIR" >/dev/null
  assert_contains "$("$RETRO" render "$RUN_DIR")" "· trend 36% over 3 runs (0% → 50% → 40%) |"
}

test_the_trend_keeps_only_the_most_recent_runs() {
  sample_run; with_rulings
  local i=0
  : >"$ARTISAN_HOME/satisfaction.jsonl"
  while [ "$i" -lt 7 ]; do
    printf '{"type":"answers","project":"owner/repo","run":"o%s","facts":{"leverage":{"decisions":1,"changed":1,"rate":100}}}\n' "$i" >>"$ARTISAN_HOME/satisfaction.jsonl"
    i=$((i + 1))
  done
  assert_eq 'o3 o4 o5 o6 r1' "$(jq -r '[.leverage.trend.runs[].run] | join(" ")' <<<"$("$RETRO" facts "$RUN_DIR")")"
}

test_the_retro_skill_shows_guardrail_healths_open_decision_proposals_with_the_balance() {
  local skill="$PLUGIN_ROOT/skills/retro/SKILL.md" signals=
  signals=$(grep '^   - \*\*Signals\*\*' "$skill") || fail "no Signals step in the retro skill"
  assert_contains "$signals" "leverage"
  assert_contains "$signals" "rulings"
  assert_contains "$signals" "open decisions waited on the Artisan"
  assert_contains "$signals" "\`open-decision\`"
  assert_contains "$signals" "guardrail health"
  assert_contains "$signals" "criterion 8"
}

# --- voice lessons (#276) ----------------------------------------------------

# voice_file PATH [OWN_RULES...]: a voice standards file shaped like the
# template: the default rules in their marked block, then the Artisan's own
# section holding OWN_RULES.
voice_file() {
  local path=$1 r=; shift
  {
    printf '# Voice standards\n\n## Which level wins\n\nBy reader (ADR 0003).\n\n'
    printf '<!-- voice-default v1 start: the plugin'"'"'s default rules. -->\n## Default rules\n\n'
    printf -- '- **R1** Start with the answer or finding.\n- **R10** At most one em-dash per paragraph.\n'
    printf '<!-- voice-default end -->\n\n## Your own rules\n\n<!-- Add your rules below. A new default version never touches this section. -->\n'
    for r in "$@"; do printf '%s\n' "$r"; done
  } >"$path"
}

# The default block of a voice file, markers included.
default_block() { awk '/<!-- voice-default v/ { f = 1 } f { print } /<!-- voice-default end/ { f = 0 }' "$1"; }

# voice_run: the sample run with a voice file at the individual and product
# levels, both committed.
voice_run() {
  sample_run
  voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"
  gq -C "$ARTISAN_HOME" add -A; gq -C "$ARTISAN_HOME" commit -m voice
  voice_file "$PROJECT/VOICE_STANDARDS.md"
  gq -C "$PROJECT" add -A; gq -C "$PROJECT" commit -m voice; gq -C "$PROJECT" push origin main
  mkdir -p "$RUN_DIR/retro"
}

test_a_voice_lesson_gets_a_voice_file_home_at_the_level_its_reader_sets() {
  voice_run
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers", role: "both", scope: "this-project",
     why: "Corrected twice in the run chat"},
    {id: "V2", kind: "voice", reader: "shared", lesson: "PR bodies lead with what changed for the user", role: "product",
     scope: "this-project", why: "The PR for #10 opened with a recap"},
    {id: "V3", kind: "voice", lesson: "Name the ticket in a finding title", role: "engineering", scope: "this-project",
     why: "Two findings had no ticket"},
    {id: "V4", kind: "voice", reader: "chat", level: "team", lesson: "No emoji", role: "both", scope: "this-project",
     why: "Asked for at the gate"}]}' >"$RUN_DIR/retro/lessons.json"
  local out=; out=$("$RETRO" check "$RUN_DIR")
  local c="$RUN_DIR/retro/checked.json"
  assert_eq individual "$(jq -r '.lessons[] | select(.id == "V1") | .level' "$c")" "chat defaults to individual"
  assert_eq product "$(jq -r '.lessons[] | select(.id == "V2") | .level' "$c")" "shared text defaults to product"
  assert_eq product "$(jq -r '.lessons[] | select(.id == "V3") | .level' "$c")" "an unclear reader takes the shared order"
  assert_eq team "$(jq -r '.lessons[] | select(.id == "V4") | .level' "$c")" "a level the Artisan picked is kept"
  assert_contains "$(jq -r '.lessons[] | select(.id == "V1") | .home' "$c")" "VOICE_STANDARDS.md"
  assert_contains "$(jq -r '.lessons[] | select(.id == "V1") | .home' "$c")" "individual"
  assert_eq 'individual project team' "$(jq -r '[.lessons[] | select(.id == "V1" or .id == "V2" or .id == "V4") | .delivery] | join(" ")' "$c")" deliveries
  assert_contains "$out" "V1	batch	voice"
}

test_check_refuses_a_voice_lesson_with_an_unknown_reader_or_level() {
  voice_run
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "everyone", lesson: "a", role: "both", scope: "this-project", why: "b"},
    {id: "V2", kind: "voice", level: "company", lesson: "c", role: "both", scope: "this-project", why: "d"}]}' >"$RUN_DIR/retro/lessons.json"
  local err=; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "check passed"
  assert_contains "$err" "lesson V1: reader"
  assert_contains "$err" "lesson V2: level"
}

# voice_lessons: one voice lesson at each level, in the shapes the preparer writes.
voice_lessons() {
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers", role: "both", scope: "this-project",
     why: "Corrected twice in the run chat"},
    {id: "V2", kind: "voice", reader: "shared", lesson: "PR bodies lead with what changed for the user", role: "product",
     scope: "this-project", why: "The PR for #10 opened with a recap", change: {text: "- PR bodies open with what changed for the user."}},
    {id: "V3", kind: "voice", reader: "chat", level: "team", lesson: "No emoji in status lines", role: "both",
     scope: "this-project", why: "Asked for at the gate"}]}' >"$RUN_DIR/retro/lessons.json"
}

test_a_kept_individual_voice_lesson_is_a_home_commit_with_origin_in_the_artisans_own_section() {
  voice_run; voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"V1":"yes"}' >"$TEST_TMPDIR/d.json"
  local f="$ARTISAN_HOME/VOICE_STANDARDS.md" before= home0= out=
  before=$(default_block "$f"); home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  out=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json")
  assert_eq $((home0 + 1)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "one home commit"
  assert_contains "$(git -C "$ARTISAN_HOME" log -1 --format=%B)" "Origin: run r1 of owner/repo"
  assert_eq "" "$(git -C "$ARTISAN_HOME" status --porcelain)" "home left clean"
  # In the Artisan's own section, after the default block, which is unchanged.
  assert_eq '- No "Great question" openers' "$(tail -1 "$f")" "the rule ends the own section"
  assert_eq "$before" "$(default_block "$f")" "the default block changed"
  assert_contains "$out" "voice	V1	$f"
  [ ! -d "$TEST_TMPDIR/project-wt/retro-r1" ] || fail "an individual lesson made a project branch"
  # Delivering again changes nothing.
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_eq $((home0 + 1)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "second delivery committed"
}

test_a_kept_product_voice_lesson_goes_in_the_retro_prs_voice_file_and_a_team_one_is_only_drafted() {
  voice_run; voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"V2":"yes","V3":"yes"}' >"$TEST_TMPDIR/d.json"
  local home0= out= wt="$TEST_TMPDIR/project-wt/retro-r1"
  home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  out=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" --pr)
  assert_eq 1 "$(git -C "$TEST_TMPDIR/origin.git" rev-list --count main..retro/r1)" "one commit on the PR branch"
  assert_eq "VOICE_STANDARDS.md" "$(git -C "$wt" diff --name-only main..HEAD)" "the PR changes only the voice file"
  assert_eq '- PR bodies open with what changed for the user.' "$(tail -1 "$wt/VOICE_STANDARDS.md")" "the rule ends the own section"
  assert_eq "$(default_block "$PROJECT/VOICE_STANDARDS.md")" "$(default_block "$wt/VOICE_STANDARDS.md")" "the default block changed"
  assert_contains "$(git -C "$wt" log -1 --format=%B)" "Origin: run r1 of owner/repo"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "| V2 | PR bodies lead with what changed for the user |"
  # The team lesson: a drafted line only. No other repo, no home commit, no ticket.
  assert_contains "$out" "team	V3	- No emoji in status lines"
  assert_contains "$(cat "$RUN_DIR/retro/team-voice.md")" "- No emoji in status lines"
  assert_eq "$home0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "the home changed"
  assert_eq 0 "$(grep -c '^issue create' "$FAKE_GH_DIR/calls" || true)" "a ticket was filed"
  assert_not_contains "$(git -C "$wt" show HEAD)" "No emoji" "the team line went into the project"
}

test_the_artisan_can_keep_a_voice_lesson_at_another_level() {
  voice_run; voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"V1":"product"}' >"$TEST_TMPDIR/d.json"
  local home0=; home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_eq '- No "Great question" openers' "$(tail -1 "$TEST_TMPDIR/project-wt/retro-r1/VOICE_STANDARDS.md")" "landed at product"
  assert_eq "$home0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "also landed at individual"
}

# full_voice_file PATH: a voice file whose own rules bring it just under the
# cap of about 1,500 tokens (6,000 characters), the last rule being "- Rule 0".
full_voice_file() {
  local rules=() i=
  for i in $(seq 1 60); do rules+=("- Filler rule $i: $(printf 'x%.0s' $(seq 1 70))"); done
  voice_file "$1" "${rules[@]}"
  while [ "$(wc -c <"$1")" -lt 5960 ]; do printf -- '- pad\n' >>"$1"; done
  printf -- '- Rule 0\n' >>"$1"
}

test_a_voice_lesson_past_the_cap_is_refused_unless_it_merges_or_replaces_a_rule() {
  voice_run
  full_voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"; gq -C "$ARTISAN_HOME" commit -am full
  local lesson='{id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers, and no closing offers to help further", role: "both",
     scope: "this-project", why: "Corrected twice"}'
  jq -n "{lessons: [$lesson]}" >"$RUN_DIR/retro/lessons.json"
  local err=; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "an append past the cap passed the check"
  assert_contains "$err" "lesson V1: "
  assert_contains "$err" "cap"
  # The same content, marked as a merge with an existing rule, is accepted and takes that rule's place.
  jq -n "{lessons: [$lesson + {change: {mode: \"merge\", rule: \"- Rule 0\"}}]}" >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "a merge was refused"
  local f="$ARTISAN_HOME/VOICE_STANDARDS.md" before=; before=$(default_block "$f")
  echo '{"V1":"yes"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_eq '- No "Great question" openers, and no closing offers to help further' "$(tail -1 "$f")" "the merged rule"
  assert_eq 0 "$(grep -c '^- Rule 0$' "$f" || true)" "the merged rule's old line is still there"
  assert_eq "$before" "$(default_block "$f")" "the default block changed"
}

test_a_replace_must_name_a_rule_in_the_artisans_own_section() {
  voice_run
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "a", role: "both", scope: "this-project", why: "b",
     change: {mode: "replace", rule: "- **R1** Start with the answer or finding."}},
    {id: "V2", kind: "voice", reader: "chat", lesson: "c", role: "both", scope: "this-project", why: "d",
     change: {mode: "replace"}},
    {id: "V3", kind: "voice", reader: "chat", lesson: "e", role: "both", scope: "this-project", why: "f",
     change: {mode: "rewrite"}}]}' >"$RUN_DIR/retro/lessons.json"
  local err=; err=$("$RETRO" check "$RUN_DIR" 2>&1 >/dev/null) && fail "check passed"
  assert_contains "$err" "lesson V1: "
  assert_contains "$err" "own section"
  assert_contains "$err" "lesson V2: "
  assert_contains "$err" "lesson V3: "
}

test_deliver_refuses_a_voice_lesson_kept_at_a_level_whose_file_it_would_push_past_the_cap() {
  voice_run
  full_voice_file "$PROJECT/VOICE_STANDARDS.md"
  gq -C "$PROJECT" commit -am full; gq -C "$PROJECT" push origin main
  jq -n '{lessons: [{id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers, and no closing offers to help further",
    role: "both", scope: "this-project", why: "Corrected twice"}]}' >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"V1":"product"}' >"$TEST_TMPDIR/d.json"
  local err=; err=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" 2>&1 >/dev/null) && fail "delivered past the cap"
  assert_contains "$err" "cap"
}

# --- the cap counts only kept voice lessons (#300) ----------------------------

# roomy_voice_file PATH: a voice file of 5,940 characters (about 1,485 tokens),
# with room under the cap for one of two_voice_lessons but not both.
roomy_voice_file() {
  local rules=() i=
  for i in $(seq 1 60); do rules+=("- Filler rule $i: $(printf 'x%.0s' $(seq 1 70))"); done
  voice_file "$1" "${rules[@]}"
  while [ "$(wc -c <"$1")" -lt 5934 ]; do printf -- '- pad\n' >>"$1"; done
  printf '%*s\n' $((5939 - $(wc -c <"$1"))) '' | tr ' ' '-' >>"$1"
}

# two_voice_lessons: two chat voice lessons, each a 34-character rule line.
two_voice_lessons() {
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers, ever", role: "both",
     scope: "this-project", why: "Corrected in the run chat"},
    {id: "V2", kind: "voice", reader: "chat", lesson: "No closing offers to help further", role: "both",
     scope: "this-project", why: "Corrected at the gate"}]}' >"$RUN_DIR/retro/lessons.json"
}

test_check_measures_each_voice_lesson_against_the_file_as_it_stands() {
  voice_run
  roomy_voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"; gq -C "$ARTISAN_HOME" commit -am roomy
  assert_eq 5940 "$(wc -c <"$ARTISAN_HOME/VOICE_STANDARDS.md" | tr -d ' ')" "the roomy file's size"
  two_voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "a lesson that fits alone was refused for one before it"
  assert_eq "V1 V2" "$(jq -r '[.lessons[].id] | join(" ")' "$RUN_DIR/retro/checked.json")" "both lessons checked"
}

test_a_dropped_voice_lesson_never_makes_a_kept_one_look_over_the_cap() {
  voice_run
  roomy_voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"; gq -C "$ARTISAN_HOME" commit -am roomy
  two_voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"no","V2":"yes"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null || fail "the kept lesson was refused"
  assert_eq '- No closing offers to help further' "$(tail -1 "$ARTISAN_HOME/VOICE_STANDARDS.md")" "the kept rule"
  assert_eq 0 "$(grep -c 'Great question' "$ARTISAN_HOME/VOICE_STANDARDS.md" || true)" "the dropped rule landed"
}

test_deliver_counts_every_kept_voice_lesson_toward_the_cap() {
  voice_run
  roomy_voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"; gq -C "$ARTISAN_HOME" commit -am roomy
  two_voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"yes","V2":"yes"}' >"$TEST_TMPDIR/d.json"
  local err=; err=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" 2>&1 >/dev/null) && fail "two kept lessons went past the cap"
  assert_contains "$err" "cap"
  assert_contains "$err" "V1"
  assert_contains "$err" "V2"
}

# --- the kept voice lessons are checked together before any write (#302) ------

test_deliver_refuses_two_kept_lessons_past_the_cap_before_any_commit() {
  voice_run
  roomy_voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md"; gq -C "$ARTISAN_HOME" commit -am roomy
  two_voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"yes","V2":"yes"}' >"$TEST_TMPDIR/d.json"
  local c0=; c0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  local err=; err=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" 2>&1 >/dev/null) && fail "delivered past the cap"
  assert_contains "$err" "V1"
  assert_contains "$err" "V2"
  assert_eq "$c0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "a commit was made before the refusal"
  assert_eq 0 "$(grep -c 'Great question' "$ARTISAN_HOME/VOICE_STANDARDS.md" || true)" "the first lesson was written"
  # Dropping one lets the other deliver.
  echo '{"V1":"yes","V2":"no"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null || fail "the fitting set was refused"
  assert_contains "$(cat "$ARTISAN_HOME/VOICE_STANDARDS.md")" "Great question"
}

test_deliver_refuses_two_kept_replaces_of_one_rule_before_any_commit() {
  voice_run
  voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md" "- Rule 0"; gq -C "$ARTISAN_HOME" commit -am own
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "First take", role: "both", scope: "this-project", why: "a",
     change: {mode: "replace", rule: "- Rule 0"}},
    {id: "V2", kind: "voice", reader: "chat", lesson: "Second take", role: "both", scope: "this-project", why: "b",
     change: {mode: "replace", rule: "- Rule 0"}}]}' >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"yes","V2":"yes"}' >"$TEST_TMPDIR/d.json"
  local c0=; c0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  local err=; err=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" 2>&1 >/dev/null) && fail "a rule was replaced twice"
  assert_contains "$err" "V1"
  assert_contains "$err" "V2"
  assert_eq "$c0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "a commit was made before the refusal"
  assert_contains "$(cat "$ARTISAN_HOME/VOICE_STANDARDS.md")" "- Rule 0"
}

test_deliver_refuses_a_lesson_moved_to_a_fuller_level_before_any_commit() {
  voice_run
  full_voice_file "$PROJECT/VOICE_STANDARDS.md"
  gq -C "$PROJECT" commit -am full; gq -C "$PROJECT" push origin main
  jq -n '{lessons: [
    {id: "V1", kind: "voice", reader: "chat", lesson: "No \"Great question\" openers", role: "both", scope: "this-project", why: "a"},
    {id: "V2", kind: "voice", reader: "chat", lesson: "No closing offers to help further, none at all", role: "both", scope: "this-project", why: "b"}]}' >"$RUN_DIR/retro/lessons.json"
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"yes","V2":"product"}' >"$TEST_TMPDIR/d.json"
  local c0=; c0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  local err=; err=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" 2>&1 >/dev/null) && fail "delivered past the product cap"
  assert_contains "$err" "V2"
  assert_contains "$err" "cap"
  assert_eq "$c0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "the individual lesson was committed before the refusal"
}

test_deliver_delivers_a_kept_voice_set_that_fits_as_before() {
  voice_run
  two_voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null || fail "check refused"
  echo '{"V1":"yes","V2":"yes"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null || fail "a fitting set was refused"
  assert_contains "$(cat "$ARTISAN_HOME/VOICE_STANDARDS.md")" "Great question"
  assert_eq '- No closing offers to help further' "$(tail -1 "$ARTISAN_HOME/VOICE_STANDARDS.md")" "the second rule"
}

test_the_round_says_a_voice_lesson_can_be_kept_at_another_level() {
  voice_run; voice_lessons
  "$RETRO" check "$RUN_DIR" >/dev/null
  local out=; out=$("$RETRO" render "$RUN_DIR")
  assert_contains "$out" "voice standards, individual level"
  assert_contains "$out" '"individual", "product" or "team"'
}

# --- a newer default voice version arrives as a move (#279) -----------------

# fake_v2_template: a template at version 2 (R1 loosened, R10 dropped, R20
# added) with version 1's block kept as the history that tells an edited
# default rule from a changed one. Exports ARTISAN_VOICE_TEMPLATE.
fake_v2_template() {
  local d="$TEST_TMPDIR/tpl"
  mkdir -p "$d/voice-default-history"
  default_block "$PROJECT/VOICE_STANDARDS.md" >"$d/voice-default-history/v1.md"
  {
    printf '# Voice standards\n\n## Which level wins\n\nBy reader (ADR 0003).\n\n'
    printf '<!-- voice-default v2 start: the plugin'"'"'s default rules. -->\n## Default rules\n\n'
    printf -- '- **R1** Lead with the answer.\n- **R20** Name the file you mean.\n'
    printf '<!-- voice-default end -->\n\n## Your own rules\n\n<!-- Add your rules below. A new default version never touches this section. -->\n'
  } >"$d/VOICE_STANDARDS.md"
  export ARTISAN_VOICE_TEMPLATE="$d/VOICE_STANDARDS.md"
}

# own_section FILE: everything from the Artisan's own section on.
own_section() { sed -n '/^## Your own rules$/,$p' "$1"; }

test_the_round_renders_one_move_per_voice_file_older_than_the_template_with_the_blocks_diff() {
  voice_run; fake_v2_template
  local out=; out=$("$RETRO" voice-moves "$RUN_DIR")
  assert_eq 2 "$(grep -c '^### Voice default v1 to v2' <<<"$out")" "one move per file"
  assert_contains "$out" "individual level"
  assert_contains "$out" "product level"
  assert_contains "$out" '+- **R20** Name the file you mean.'
  assert_contains "$out" '-- **R10** At most one em-dash per paragraph.'
  assert_contains "$out" "voice-default:individual"
  # The same moves close the chat round.
  seed_lessons; "$RETRO" check "$RUN_DIR" >/dev/null
  assert_contains "$("$RETRO" render "$RUN_DIR")" "### Voice default v1 to v2, individual level"
}

test_approving_a_move_replaces_the_default_block_and_version_and_leaves_the_own_section_byte_for_byte() {
  voice_run; fake_v2_template
  voice_file "$ARTISAN_HOME/VOICE_STANDARDS.md" '- Say "run" for a worker session.' '' '  keep   this spacing,	tabs too'
  gq -C "$ARTISAN_HOME" add -A; gq -C "$ARTISAN_HOME" commit -m own
  local f="$ARTISAN_HOME/VOICE_STANDARDS.md" own0= home0=
  own0=$(own_section "$f"); home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  seed_lessons; "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"voice-default:individual":"yes"}' >"$TEST_TMPDIR/d.json"
  local out=; out=$("$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json")
  assert_eq "$(default_block "$ARTISAN_VOICE_TEMPLATE")" "$(default_block "$f")" "the default block is the template's"
  assert_eq "$own0" "$(own_section "$f")" "the own section changed"
  assert_eq 1 "$(grep -c 'voice-default v2 start' "$f")" "the version"
  assert_eq $((home0 + 1)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "one home commit"
  assert_eq "" "$(git -C "$ARTISAN_HOME" status --porcelain)" "home left clean"
  assert_contains "$out" "voice-default	individual"
  # Approved once: the file has no move now, and delivering again changes nothing.
  assert_not_contains "$("$RETRO" voice-moves "$RUN_DIR")" "individual level" "a move still offered"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_eq $((home0 + 1)) "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "second delivery committed"
}

test_a_default_rule_edited_in_the_file_is_kept_and_flagged_in_the_move() {
  voice_run; fake_v2_template
  local f="$ARTISAN_HOME/VOICE_STANDARDS.md"
  voice_file "$f" '- My own.'
  sed -i.bak 's/^- \*\*R1\*\* .*/- **R1** Start with the answer, then the caveat./' "$f"; rm -f "$f.bak"
  gq -C "$ARTISAN_HOME" add -A; gq -C "$ARTISAN_HOME" commit -m edit
  local out=; out=$("$RETRO" voice-moves "$RUN_DIR")
  assert_contains "$out" "R1"
  assert_contains "$out" "you edited"
  assert_contains "$out" "- **R1** Start with the answer, then the caveat."
  seed_lessons; "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"voice-default:individual":"yes"}' >"$TEST_TMPDIR/d.json"
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" >/dev/null
  assert_contains "$(cat "$f")" "- **R1** Start with the answer, then the caveat."
  assert_not_contains "$(cat "$f")" "Lead with the answer." "the edited rule was overwritten"
  assert_contains "$(cat "$f")" "- **R20** Name the file you mean."
  assert_eq 1 "$(grep -c 'voice-default v2 start' "$f")" "the version"
}

test_a_file_already_at_the_current_version_gets_no_move() {
  voice_run; fake_v2_template
  cp "$ARTISAN_VOICE_TEMPLATE" "$ARTISAN_HOME/VOICE_STANDARDS.md"
  local out=; out=$("$RETRO" voice-moves "$RUN_DIR")
  assert_not_contains "$out" "individual level"
  assert_contains "$out" "product level"
  cp "$ARTISAN_VOICE_TEMPLATE" "$PROJECT/VOICE_STANDARDS.md"
  gq -C "$PROJECT" add -A; gq -C "$PROJECT" commit -m v2; gq -C "$PROJECT" push origin main
  assert_eq "" "$("$RETRO" voice-moves "$RUN_DIR")" "a current file got a move"
}

test_an_approved_product_move_lands_in_the_retro_prs_voice_file_only() {
  voice_run; fake_v2_template
  local own0=; own0=$(own_section "$PROJECT/VOICE_STANDARDS.md")
  seed_lessons; "$RETRO" check "$RUN_DIR" >/dev/null
  echo '{"voice-default:product":"yes"}' >"$TEST_TMPDIR/d.json"
  local wt="$TEST_TMPDIR/project-wt/retro-r1" home0=
  home0=$(git -C "$ARTISAN_HOME" rev-list --count HEAD)
  "$RETRO" deliver "$RUN_DIR" "$TEST_TMPDIR/d.json" --pr >/dev/null
  assert_eq 1 "$(git -C "$TEST_TMPDIR/origin.git" rev-list --count main..retro/r1)" "one commit on the PR branch"
  assert_eq "VOICE_STANDARDS.md" "$(git -C "$wt" diff --name-only main..HEAD)" "the PR changes only the voice file"
  assert_eq "$(default_block "$ARTISAN_VOICE_TEMPLATE")" "$(default_block "$wt/VOICE_STANDARDS.md")" "the default block"
  assert_eq "$own0" "$(own_section "$wt/VOICE_STANDARDS.md")" "the own section"
  assert_eq "$home0" "$(git -C "$ARTISAN_HOME" rev-list --count HEAD)" "the home changed"
  assert_contains "$(cat "$FAKE_GH_DIR/calls")" "pr create"
}

test_a_move_keeps_a_voice_file_with_crlf_line_endings_byte_for_byte_outside_the_block() {
  voice_run; fake_v2_template
  local f="$ARTISAN_HOME/VOICE_STANDARDS.md"
  voice_file "$f" '- Own rule.'
  awk '{ printf "%s\r\n", $0 }' "$f" >"$f.crlf"; mv "$f.crlf" "$f"
  gq -C "$ARTISAN_HOME" add -A; gq -C "$ARTISAN_HOME" commit -m crlf
  python3 -I "$PLUGIN_ROOT/skills/retro/scripts/retro.py" voice-upgrade "$ARTISAN_VOICE_TEMPLATE" "$f" >/dev/null 2>&1 || true
  assert_eq "- Own rule.$(printf '\r')" "$(tail -1 "$f")" "the own section lost its line endings"
}
