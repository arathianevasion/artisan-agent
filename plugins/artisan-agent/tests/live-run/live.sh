#!/usr/bin/env bash
# Live proof of the two-tier run (#54): a real Engineering chat, orchestrator
# and worker, each a capped headless `claude -p` loading this plugin with
# --plugin-dir under the normal login, on a throwaway repo with the fake
# tracker (tests/fixtures/fake-gh). Nothing reaches GitHub; no settings are
# read or written (--setting-sources project,local, --no-session-persistence).
#
# Usage: live.sh <workdir>
#
# Needs UPSTREAM_PLUGIN_DIR (the mattpocock-skills plugin, for the worker's
# tdd and code-review). Every session is capped at BUDGET (default 0.50)
# dollars; the worker and orchestrator models default to claude-sonnet-5-5.
#
# Steps, each checked and printed as ok/FAIL:
#   1. chat: /artisan-agent:implement-plan on ticket #1, plan step with a
#      --set override, state file, integration worktree, orchestrator
#      launched; the chat's whole process group is killed the moment the
#      orchestrator is up (kill-the-launcher)
#   2. the orchestrator and worker carry on regardless; the orchestrator
#      exits after writing state
#   3. a second chat, with no messages or notices, learns of completion from
#      the exit record and the sweep (wave.sh status)
#   4. a fresh verifier passed the ticket; its commit is merged --no-ff into
#      the integration branch, the suite is green there, the ticket is closed
#      with the state file's evidence contract, the events are in order, and
#      the main checkout never changed
#
# Portable to bash 3.2 (macOS). Needs git, jq, python3, perl.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/../.." && pwd)
WD=${1:?usage: live.sh <workdir>}
: "${UPSTREAM_PLUGIN_DIR:?set UPSTREAM_PLUGIN_DIR to the mattpocock-skills plugin directory}"
BUDGET=${BUDGET:-0.50}
MODEL=${MODEL:-claude-sonnet-5-5}

[ ! -e "$WD/sample" ] || { echo "live.sh: $WD/sample already exists" >&2; exit 2; }
mkdir -p "$WD"
WD=$(cd "$WD" && pwd -P)
REPO=$WD/sample
RUN=$REPO/.artisan-agent/runs/live1
export FAKE_GH_DIR=$WD/tracker
export PATH="$PLUGIN_ROOT/tests/fixtures/fake-gh:$PATH"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export ARTISAN_CLAUDE_ARGS="--plugin-dir $PLUGIN_ROOT --plugin-dir $UPSTREAM_PLUGIN_DIR --setting-sources project,local --no-session-persistence"
export ARTISAN_MAX_BUDGET_USD=$BUDGET

failures=0
check() { # description command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

# ------------------------------------------------------------------ sample
mkdir -p "$REPO/tests" "$REPO/docs/agents" "$REPO/.artisan-agent" "$FAKE_GH_DIR"
cat >"$REPO/greet.py" <<'PY'
"""Greetings."""


def greet(name):
    return f"Hello, {name}."
PY
cat >"$REPO/tests/test_greet.py" <<'PY'
import unittest

from greet import greet


class GreetTest(unittest.TestCase):
    def test_greet(self):
        self.assertEqual(greet("Ada"), "Hello, Ada.")
PY
: >"$REPO/tests/__init__.py"
printf '# Sample\n\nRun the suite with `python3 -m unittest -q`.\n' >"$REPO/README.md"
printf '__pycache__/\n.artisan-agent/runs/\n' >"$REPO/.gitignore"
printf 'max_agents: 2\n' >"$REPO/.artisan-agent/config.yml"
cat >"$REPO/docs/agents/issue-tracker.md" <<'MD'
# Issue tracker

Issues live on GitHub as `local/sample`; use the `gh` CLI with `-R local/sample`
(for example `gh issue view 1 -R local/sample`).
MD
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Sample project"
MAIN_HEAD=$(git -C "$REPO" rev-parse HEAD)

jq -n '{number: 1, title: "Add shout()", state: "open", labels: [{name: "ready-for-agent"}],
  body: "## What to build\nA `shout(name)` function in `greet.py` that greets loudly.\n\n## Acceptance criteria\n- [ ] `shout(\"ada\")` returns `\"HELLO, ADA!\"`\n- [ ] A unit test covers it at the `greet.shout` seam\n\n## Seams\n`greet.shout(name)`"}' \
  >"$FAKE_GH_DIR/issue-1.json"

session() { # name prompt -> runs claude -p in the sample repo, output in $WD/<name>.json
  local name=$1 prompt=$2
  (
    cd "$REPO"
    exec claude -p "$prompt" --model "$MODEL" --max-budget-usd "$BUDGET" \
      --permission-mode acceptEdits --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Skill" \
      $ARTISAN_CLAUDE_ARGS --output-format json
  ) </dev/null >"$WD/$name.json" 2>"$WD/$name.stderr"
}

# ------------------------------------------------------ 1. chat and launch
set -m
session chat "/artisan-agent:implement-plan ticket #1 on local/sample. Use run id live1, the model $MODEL for the worker, an expected size of 50000 input tokens, 20000 output tokens and 10 minutes, and the suite command \`python3 -m unittest -q\`. I approve the plan as you render it, with one override for this run only: max_agents=1, applied with --set. Don't wait for me: once approved, start the run and launch the wave as the skill says, then end your turn." &
CHAT=$!
set +m
i=0
until [ -s "$RUN/workers/orchestrator-w1.1/runner.pid" ]; do
  i=$((i + 1))
  if ! kill -0 "$CHAT" 2>/dev/null && [ ! -s "$RUN/workers/orchestrator-w1.1/runner.pid" ]; then
    echo "FAIL the chat ended without launching an orchestrator (see $WD/chat.json)"
    jq -r '.result // empty' "$WD/chat.json" 2>/dev/null | tail -20
    exit 1
  fi
  [ "$i" -lt 3000 ] || { echo "FAIL no orchestrator after 10 minutes"; kill -KILL "-$CHAT" 2>/dev/null; exit 1; }
  sleep 0.2
done
if kill -0 "$CHAT" 2>/dev/null; then chat_alive=yes; else chat_alive=no; fi
kill -KILL "-$CHAT" 2>/dev/null || true
wait "$CHAT" 2>/dev/null || true
ORCH=$(cat "$RUN/workers/orchestrator-w1.1/runner.pid")
echo "info chat was alive when killed: $chat_alive; orchestrator runner pid $ORCH"
check "the chat ran the plan step with an override for this run" \
  jq -e '.plan.overrides.max_agents.value == 1 and .plan.max_agents == 1' "$RUN/state.json"
check "the plan names the tracker repo as owner/name" jq -e '.repo == "local/sample"' "$RUN/state.json"
check "the state file holds the approved scope" jq -e '.plan.scope == ["1"]' "$RUN/state.json"
check "the integration worktree exists beside the repo" test -d "$WD/sample-wt/run-live1"
sleep 2
check "the orchestrator survived the chat being killed" kill -0 "$ORCH"

# --------------------------------------------- 2. orchestrator and worker
i=0
until [ -f "$RUN/results/orchestrator-w1.1.exit.json" ]; do
  i=$((i + 1))
  [ "$i" -lt 1800 ] || { echo "FAIL the orchestrator did not finish in 30 minutes"; break; }
  sleep 1
done
check "the worker ran detached and completed" \
  sh -c "[ \"\$('$PLUGIN_ROOT/scripts/classify-worker.sh' '$RUN' 1 1)\" = 'completed -' ]"
check "the orchestrator completed and exited" \
  sh -c "[ \"\$('$PLUGIN_ROOT/scripts/classify-worker.sh' '$RUN' orchestrator-w1 1)\" = 'completed -' ]"
check "the orchestrator wrote the wave report" test -s "$RUN/results/orchestrator-w1.1.result.json"
check "the orchestrator is no longer running" sh -c "! kill -0 $ORCH"

# ------------------------------------- 3. a fresh chat learns from files
session status-chat "You are the Engineering chat for run live1 of /artisan-agent:implement-plan (run folder $RUN). You were just woken; there are no messages for you. Do step 6 of the skill (${PLUGIN_ROOT}/skills/implement-plan/SKILL.md): check the run with wave.sh status and report it to me as the skill says. Do not launch anything." || true
check "the second chat reported the ticket merged from files alone" \
  sh -c "jq -r '.result' '$WD/status-chat.json' | grep -i -q 'merged as'"
"$PLUGIN_ROOT/scripts/wave.sh" status "$RUN" >"$WD/status.txt" 2>&1 || true
check "wave.sh status says the run is done" grep -q '^next: done' "$WD/status.txt"

# ----------------------------------------------------------- 4. outcomes
IB_TIP=$(git -C "$REPO" rev-parse run/live1)
check "the integration branch's tip is a --no-ff merge of agent/1" \
  sh -c "[ \"\$(git -C '$REPO' rev-parse '$IB_TIP^2')\" = \"\$(git -C '$REPO' rev-parse agent/1)\" ]"
check "the ticket's commit is the one the evidence record names" \
  sh -c "[ \"\$(git -C '$REPO' rev-parse \"\$(jq -r .commit '$RUN/results/1.1.result.json')\")\" = \"\$(git -C '$REPO' rev-parse agent/1)\" ]"
check "the suite is green on the integration branch" sh -c "cd '$WD/sample-wt/run-live1' && python3 -m unittest -q"
check "shout() exists on the integration branch" sh -c "cd '$WD/sample-wt/run-live1' && python3 -c 'from greet import shout; assert shout(\"ada\") == \"HELLO, ADA!\"'"
check "the ticket is closed on the tracker" jq -e '.state == "closed"' "$FAKE_GH_DIR/issue-1.json"
check "the evidence was posted on the ticket" grep -q '| Criterion | Met | Evidence |' "$FAKE_GH_DIR/comments-1.md"
check "events in order: dispatch, result, verify, verified, merge, closed" \
  jq -e '[.events[].event | select(. == "dispatch" or . == "result" or . == "verify" or . == "verified" or . == "merge" or . == "closed")] == ["dispatch","result","verify","verified","merge","closed"]' "$RUN/state.json"
check "a fresh verifier passed the ticket before the merge" \
  jq -e '.tickets["1"].evidence.verdict == "pass" and (.tickets["1"].verifications | length) >= 1' "$RUN/state.json"
contract_posted() { # the JSON folded into the comment is the state file's contract
  awk '/^```json$/ {on = 1; next} /^```$/ {on = 0} on' "$FAKE_GH_DIR/comments-1.md" | jq -cS . >"$WD/posted.json" \
    && jq -cS '.tickets["1"].evidence' "$RUN/state.json" | cmp -s - "$WD/posted.json"
}
check "the evidence comment carries the state file's contract" contract_posted
check "the main checkout never moved and is clean" \
  sh -c "[ \"\$(git -C '$REPO' rev-parse HEAD)\" = '$MAIN_HEAD' ] && [ -z \"\$(git -C '$REPO' status --porcelain)\" ]"
check "the worker's and orchestrator's costs are in the state file" \
  jq -e '.tickets["1"].cost_usd > 0 and .costs.orchestrator_usd > 0' "$RUN/state.json"
check "the tracker was only ever the fake one" test -s "$FAKE_GH_DIR/calls"

# Costs, from each session's own JSON output.
for f in "$WD/chat.json" "$RUN/workers/orchestrator-w1.1/output.json" "$RUN/workers/1.1/output.json" "$RUN"/workers/verify-1.*/output.json "$WD/status-chat.json"; do
  printf 'cost %s: %s\n' "$(basename "$(dirname "$f")")/$(basename "$f")" "$(jq -r '.total_cost_usd // "unknown (killed)"' "$f" 2>/dev/null || echo unknown)"
done

# Nothing left running.
for p in $(cat "$RUN"/workers/*/runner.pid 2>/dev/null); do kill -0 "$p" 2>/dev/null && { echo "FAIL runner $p still running; stopping it"; kill -TERM "$p"; failures=$((failures + 1)); }; done
echo "$failures failed"
[ "$failures" -eq 0 ]
