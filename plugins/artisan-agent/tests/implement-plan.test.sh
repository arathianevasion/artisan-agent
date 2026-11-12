# implement-plan's text: glossary vocabulary, the two tiers, and tables
# wherever tickets are shown to the Artisan. Static checks over the skill.

SKILL_DIR="$PLUGIN_ROOT/skills/implement-plan"
skill_files() { printf '%s\n' "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/references/*.md; }

test_a_worker_is_never_called_an_agent() {
  # Allowed: the plugin's name, Max Agents, agent teams, docs/agents, agent/<branch>.
  local hits
  hits=$(skill_files | xargs grep -n -i -w 'agents\{0,1\}' \
    | grep -v -i 'artisan-agent\|max agents\|agent teams\|docs/agents\|agent/' || true)
  assert_eq "" "$hits" "\"agent\" where a worker or orchestrator is meant"
}

test_findings_are_filed_for_triage_not_discovered_work() {
  local hits
  hits=$(skill_files | xargs grep -n -i 'discovered work\|discovered, awaiting\|discovery' || true)
  assert_eq "" "$hits"
  assert_contains "$(cat "$SKILL_DIR/SKILL.md")" "Findings filed for triage"
}

test_the_chat_is_the_engineering_chat_and_not_the_orchestrator() {
  local skill
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" "You are the **Engineering chat**"
  assert_contains "$(cat "$SKILL_DIR/references/orchestrator.md")" "You are an **orchestrator**"
  ! grep -n -i 'you are the orchestrator\|the orchestrator stays here\|orchestrator never writes product code' "$SKILL_DIR/SKILL.md" \
    || fail "the chat is described as the orchestrator"
}

test_tickets_shown_to_the_artisan_are_tables() {
  # The plan, the wave digest and the run summary each show a table with the
  # ticket (number and description), wave, model and output or status.
  local skill
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" "**The wave digest** is the status table"
  assert_contains "$skill" "| Ticket | Wave | Model | Status |"
  assert_contains "$skill" "| Ticket | Wave | Model | Outcome |"
  assert_contains "$skill" "| #12 (retry failed uploads) | 1 |"
  # No numbered or bulleted lists of tickets ("1. #12 ..." or "- #12 ...").
  ! grep -n -E '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]+#[0-9]' "$SKILL_DIR/SKILL.md" \
    || fail "a ticket list that is not a table"
  ! grep -n -E '^(Completed|Blocked|Discovered|Branches left unmerged):' "$SKILL_DIR/SKILL.md" \
    || fail "the old list-shaped run summary"
}

test_the_old_result_paths_and_contract_are_gone() {
  local hits
  hits=$(skill_files | xargs grep -n '\.scratch/\|results/\${TICKET}\.json\|review\.remarks' || true)
  assert_eq "" "$hits"
  assert_contains "$(cat "$SKILL_DIR/references/dispatch.md")" 'references/evidence-record.md'
}

test_the_orchestrator_is_launched_detached_never_as_a_background_command() {
  local skill
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" "never as a tool background command"
  assert_contains "$skill" "wave.sh launch"
  assert_contains "$skill" "**end your turn**"
}
