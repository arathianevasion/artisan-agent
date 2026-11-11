#!/usr/bin/env bash
# Live proof of the orchestrator's hand-off (#59, pilot prerequisite 1): a
# real headless orchestrator, loading this plugin with --plugin-dir under the
# normal login, gets the hand-off marker mid-wave, with its worker in flight;
# it sees it at its next drain.sh check, finishes its step and hands off; a
# fresh real orchestrator finishes the same wave from the state file.
#
# The marker is written by running the plugin's own PreCompact hook
# (compact-hook.sh pre-compact) with the orchestrator's environment, exactly
# as Claude Code runs it, once the worker is dispatched. A headless session
# can't be made to compact on cue: claude -p (2.1.322) didn't autocompact
# even with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE and CLAUDE_CODE_AUTO_COMPACT_WINDOW
# set, and /compact needs the session to have ended (claude -p --resume).
# That the hook blocks a real headless orchestrator's compaction and writes
# the marker was proved separately with --resume and /compact (README.md). Workers and verifiers are the fake `claude` (scripted), so
# only the orchestrators cost anything. Nothing reaches GitHub (the fake
# tracker); no settings are written.
#
# Usage: live.sh <workdir>
#
# REAL_CLAUDE (default: the first `claude` on PATH that isn't a shim) is the
# real binary. Every session is capped at
# BUDGET (default 1.00) dollars; the orchestrators' model is MODEL (default
# claude-sonnet-5-5). The fake worker sleeps WORKER_SLEEP (default 90)
# seconds, so it is still in flight when the first orchestrator hands off.
#
# Prints ok/FAIL per check and exits non-zero on any FAIL.
#
# Portable to bash 3.2 (macOS). Needs git, jq, perl.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/../.." && pwd)
S=$PLUGIN_ROOT/scripts
WD=${1:?usage: live.sh <workdir>}
BUDGET=${BUDGET:-1.00}
MODEL=${MODEL:-claude-sonnet-5-5}
export WORKER_SLEEP=${WORKER_SLEEP:-90}

if [ -z "${REAL_CLAUDE:-}" ]; then
  for c in $(which -a claude); do
    case "$c" in *shim*) continue ;; esac
    REAL_CLAUDE=$c
    break
  done
fi
[ -x "${REAL_CLAUDE:-}" ] || { echo "live.sh: set REAL_CLAUDE to the claude binary" >&2; exit 2; }

[ ! -e "$WD/sample" ] || { echo "live.sh: $WD/sample already exists" >&2; exit 2; }
mkdir -p "$WD"
WD=$(cd "$WD" && pwd -P)
REPO=$WD/sample
RUN=$REPO/.artisan-agent/runs/live1
export FAKE_GH_DIR=$WD/tracker
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
# The hooks are what this proves, and plain `--setting-sources project,local`
# stops them running (2.1.322), so tests/helpers/live-hooks.sh registers them
# through --settings and keeps the Artisan's user settings out.
. "$PLUGIN_ROOT/tests/helpers/live-hooks.sh"
export ARTISAN_HOOK_PROOF=$WD/hook-proof
export ARTISAN_CLAUDE_ARGS="--plugin-dir $PLUGIN_ROOT $(live_hooks_args "$PLUGIN_ROOT" "$WD/hooks")"
export ARTISAN_MAX_BUDGET_USD=$BUDGET

failures=0
check() { # description command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

# --------------------------------------------- claude: real orchestrators only
mkdir -p "$WD/bin"
cat >"$WD/bin/claude" <<EOF
#!/usr/bin/env bash
# Orchestrators are real; workers and verifiers are the scripted fake.
if [ "\${ARTISAN_ROLE:-}" = orchestrator ]; then
  exec "$REAL_CLAUDE" "\$@"
fi
exec "$PLUGIN_ROOT/tests/fixtures/fake-claude/claude" "\$@"
EOF
chmod +x "$WD/bin/claude"
export PATH="$WD/bin:$PLUGIN_ROOT/tests/fixtures/fake-gh:$PATH"
export FAKE_CLAUDE_MODE=script FAKE_CLAUDE_LOG=$WD/fake-claude.log

export FAKE_CLAUDE_SCRIPT_WORKER=$WD/worker.sh
cat >"$FAKE_CLAUDE_SCRIPT_WORKER" <<'EOF'
set -e
sleep "$WORKER_SLEEP"
echo hi >hello.txt
git add -A && git commit -q -m "Add hello.txt"
jq -n --arg c "$(git rev-parse HEAD)" '{ticket: "1", status: "complete", commit: $c,
  acceptance: [{criterion: "hello.txt exists", met: true, evidence: {tests: ["sh check.sh"]}}],
  tests: {suite_passed: true, command: "sh check.sh", summary: "suite ok"},
  unsure: [], decisions: [], review: {ran: true, remarks: []}, findings: []}' >"$ARTISAN_RESULT_FILE"
EOF
export FAKE_CLAUDE_SCRIPT_VERIFIER=$WD/verifier.sh
cat >"$FAKE_CLAUDE_SCRIPT_VERIFIER" <<'EOF'
set -e
key=$(basename "$ARTISAN_RESULT_FILE" .result.json)
jq '{verdict: "pass", acceptance: [.[] | {criterion: ., met: true,
    evidence: {checks: [{command: "sh check.sh", result: "suite ok"}]}}], unsure: [], notes: "checked"}' \
  "$ARTISAN_RUN_DIR/prompts/$key.criteria.json" >"$ARTISAN_RESULT_FILE"
EOF

# ------------------------------------------------------------------ sample
mkdir -p "$REPO/.artisan-agent" "$FAKE_GH_DIR"
printf '#!/bin/sh\necho "suite ok"\n' >"$REPO/check.sh"
printf '.artisan-agent/runs/\n' >"$REPO/.gitignore"
printf 'max_agents: 2\n' >"$REPO/.artisan-agent/config.yml"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Sample project"
MAIN_HEAD=$(git -C "$REPO" rev-parse HEAD)
jq -n '{number: 1, title: "Add hello", state: "open", labels: [{name: "ready-for-agent"}],
  body: "## Acceptance criteria\n- [ ] hello.txt exists"}' >"$FAKE_GH_DIR/issue-1.json"
jq -n --arg m "$MODEL" '{run_id: "live1", repo: "local/sample", integration_branch: "run/live1", scope: ["1"],
  waves: [["1"]], max_agents: 2, attempts_per_ticket: 2, suite_command: "sh check.sh", budget_usd: 5,
  orchestrator: {model: $m, estimate_usd: 0.5},
  tickets: {"1": {title: "Add hello", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 10},
                  expected_files: ["hello.txt"],
                  caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 600}}}}' >"$WD/plan.json"
"$S/state.sh" init "$RUN" "$WD/plan.json"

# The chat: a long-lived stand-in that holds the lock between waves.
sleep 3600 &
CHAT=$!
trap 'kill $CHAT 2>/dev/null || true' EXIT
export ARTISAN_WRITER_PID=$CHAT
(cd "$REPO" && "$S/wave.sh" start "$RUN" >/dev/null && "$S/wave.sh" launch "$RUN" >"$WD/launch.out")
echo "info launched $(cat "$WD/launch.out")"

# Once the worker is dispatched: the PreCompact hook, as Claude Code runs it.
i=0
until jq -e '[.events[].event] | index("dispatch")' "$RUN/state.json" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 600 ] || { echo "FAIL no dispatch in 10 minutes"; break; }
  sleep 1
done
hook_rc=0
jq -nc --arg cwd "$WD/sample-wt/run-live1" --arg tp "$(cat "$RUN/workers/orchestrator-w1.1/transcript.path" 2>/dev/null)" \
  '{session_id: "live", transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: "auto"}' \
  | ARTISAN_ROLE=orchestrator ARTISAN_RUN_DIR=$RUN ARTISAN_RESULT_FILE=$RUN/results/orchestrator-w1.1.result.json \
    "$S/compact-hook.sh" pre-compact 2>/dev/null || hook_rc=$?
echo "info PreCompact hook run at $(date +%T) with the worker in flight: exit $hook_rc"

# ------------------------------------------------------ wait for the wave
i=0
until [ -f "$RUN/results/orchestrator-w1.1.exit.json" ] && {
        [ ! -f "$RUN/workers/orchestrator-w1.1/handoff.json" ] || [ -f "$RUN/results/orchestrator-w1.2.exit.json" ]; }; do
  i=$((i + 1))
  [ "$i" -lt 1800 ] || { echo "FAIL the wave did not finish in 30 minutes"; break; }
  sleep 1
done

check "the first orchestrator's PreCompact hook left the hand-off marker" test -f "$RUN/workers/orchestrator-w1.1/handoff.json"
check "the hook blocked the compaction (exit 2)" test "$hook_rc" = 2
check "a plugin hook fired (SessionStart line in the proof file)" live_hooks_proof_check "$ARTISAN_HOOK_PROOF"
check "the first orchestrator's SessionStart hook recorded its transcript" test -s "$RUN/workers/orchestrator-w1.1/transcript.path"
check "the first orchestrator recorded its hand-off" jq -e '.orchestrators[0].handoff.reason | test("compaction")' "$RUN/state.json"
check "it wrote the hand-off report as its result" jq -e '.handoff.to == "orchestrator-w1"' "$RUN/results/orchestrator-w1.1.result.json"
check "the next orchestrator took the same wave" jq -e '[.orchestrators[].wave] == [1, 1]' "$RUN/state.json"
check "the second orchestrator completed" \
  sh -c "[ \"\$('$S/classify-worker.sh' '$RUN' orchestrator-w1 2)\" = 'completed -' ]"
check "the ticket merged and closed" jq -e '.tickets["1"].status == "merged" and .tickets["1"].tracker_closed' "$RUN/state.json"
check "the worker in flight was never dispatched again" jq -e '.tickets["1"].attempts == 1' "$RUN/state.json"
check "the events show the hand-off before the merge" \
  jq -e '[.events[].event] | index("handoff") as $h | $h != null and $h < index("merge")' "$RUN/state.json"
check "the main checkout never changed" sh -c "[ \"\$(git -C '$REPO' rev-parse HEAD)\" = '$MAIN_HEAD' ]"

echo "info events: $(jq -r '[.events[].event] | join(" ")' "$RUN/state.json")"
echo "info handoff: $(jq -c '.orchestrators[0].handoff' "$RUN/state.json")"
for n in 1 2; do
  echo "info orchestrator $n: $("$S/classify-worker.sh" "$RUN" orchestrator-w1 "$n" 2>/dev/null || true), \$$(jq -r '.total_cost_usd // "?"' "$RUN/workers/orchestrator-w1.$n/output.json" 2>/dev/null || echo '?')"
done
[ ! -f "$RUN/workers/orchestrator-w1.1/transcript.path" ] \
  || echo "info first orchestrator's context at the end: $("$S/drain.sh" percent --transcript "$(cat "$RUN/workers/orchestrator-w1.1/transcript.path")")"

# Leave nothing running.
for pid in $(cat "$RUN"/workers/*/runner.pid 2>/dev/null); do kill -TERM "$pid" 2>/dev/null || true; done
[ "$failures" -eq 0 ]
