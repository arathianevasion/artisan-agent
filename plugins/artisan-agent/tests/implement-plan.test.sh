# implement-plan's text: glossary vocabulary, the two tiers, and tables
# wherever tickets are shown to the Artisan. Static checks over the skill.

SKILL_DIR="$PLUGIN_ROOT/skills/implement-plan"
skill_files() { printf '%s\n' "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/references/*.md; }

test_a_worker_is_never_called_an_agent() {
  # Allowed: the plugin's name, Max Agents, agent teams, docs/agents, agent/<branch>.
  local hits=
  hits=$(skill_files | xargs grep -n -i -w 'agents\{0,1\}' \
    | grep -v -i 'artisan-agent\|max agents\|agent teams\|docs/agents\|agent/' || true)
  assert_eq "" "$hits" "\"agent\" where a worker or orchestrator is meant"
}

test_findings_are_filed_for_triage_not_discovered_work() {
  local hits=
  hits=$(skill_files | xargs grep -n -i 'discovered work\|discovered, awaiting\|discovery' || true)
  assert_eq "" "$hits"
  assert_contains "$(cat "$SKILL_DIR/SKILL.md")" "Findings filed for triage"
}

test_the_chat_is_the_run_chat_and_not_the_orchestrator() {
  local skill=
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" "You are the **Run chat**"
  assert_contains "$(cat "$SKILL_DIR/references/orchestrator.md")" "You are an **orchestrator**"
  ! grep -n -i 'you are the orchestrator\|the orchestrator stays here\|orchestrator never writes product code' "$SKILL_DIR/SKILL.md" \
    || fail "the chat is described as the orchestrator"
}

test_tickets_shown_to_the_artisan_are_tables() {
  # The plan, the wave digest and the run summary each show a table with the
  # ticket (number and description), wave, model and output or status.
  local skill=
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
  local hits=
  hits=$(skill_files | xargs grep -n '\.scratch/\|results/\${TICKET}\.json\|review\.remarks' || true)
  assert_eq "" "$hits"
  assert_contains "$(cat "$SKILL_DIR/references/dispatch.md")" 'references/evidence-record.md'
}

test_the_orchestrator_is_launched_detached_never_as_a_background_command() {
  local skill=
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" "never as a tool background command"
  assert_contains "$skill" "wave.sh launch"
  assert_contains "$skill" "**end your turn**"
}

test_the_orchestrators_exit_wakes_the_chat_which_notifies_at_once() {
  local skill=
  skill=$(cat "$SKILL_DIR/SKILL.md")
  assert_contains "$skill" 'scripts/wave.sh wait <run folder>` as a **background** Bash task'
  assert_contains "$skill" "so the orchestrator's exit wakes you"
  assert_contains "$skill" "the \`wave.sh wait\` task ends"
  assert_contains "$skill" "**The orchestrator never fails silently.**"
  assert_contains "$skill" "send its \`notify:\` line as a push notification"
  assert_contains "$skill" "an orchestrator's exit is notified idle or not"
}

# #336: a design tweak during a run reuses existing paths, told apart by the journey test.
tweak_section() {
  awk '/^### Design tweaks during a run/{f=1;next} /^### /{f=0} f' "$SKILL_DIR/SKILL.md"
}

test_a_look_only_tweak_becomes_a_small_change_ticket_in_the_open_run() {
  local s=
  s=$(tweak_section)
  [ -n "$s" ] || fail "no 'Design tweaks during a run' section in the Run chat's instructions"
  assert_contains "$s" "look-only tweak"
  assert_contains "$s" "Small change ticket"
  assert_contains "$s" "lever.sh add"
}

test_a_journey_changing_tweak_is_filed_as_an_open_decision() {
  local s=
  s=$(tweak_section)
  assert_contains "$s" "journey-changing tweak"
  assert_contains "$s" "open decision"
  assert_contains "$s" "--criterion 8"
  assert_contains "$s" "Decision chat"
}

test_the_two_tweaks_are_told_apart_by_whether_a_journey_step_changes() {
  local s=
  s=$(tweak_section)
  assert_contains "$s" "whether a journey step changes"
}
