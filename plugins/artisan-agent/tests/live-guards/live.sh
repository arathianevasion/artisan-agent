#!/usr/bin/env bash
# Live proof that the plugin's guard hooks work in real headless sessions with
# hooks active (#105; reruns the hook-dependent proofs of #50, #54 and #56):
#
#   1. a typed /mattpocock-skills:implement, and a bare /retro (upstream-only name),
#      are blocked by the replaced-skill guard (#50). A bare /implement or /triage
#      resolves to this plugin's own skill, so it is not a block case
#   2. an Edit in the main checkout of an adopted repo is denied (#56)
#   3. while a run holds the lock, a second /artisan-agent:implement-plan is
#      refused and queued as a plan issue (the fake tracker) (#56)
#   4. the lock holder's own "resume" gets through the run-start hook (#54)
#
# Each session loads the plugin and mattpocock-skills with --plugin-dir under the
# normal login, with tests/helpers/live-hooks.sh's flags (hooks on, user
# settings out), no saved session, and a --max-budget-usd cap (BUDGET, default
# 0.30). Every session also has to leave a SessionStart line in the hook proof
# file, or the run FAILs. Nothing reaches GitHub (fake tracker).
#
# Usage: live.sh <workdir>     needs UPSTREAM_PLUGIN_DIR (mattpocock-skills)
# Portable to bash 3.2 (macOS). Needs git, jq, perl.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/../.." && pwd)
S=$PLUGIN_ROOT/scripts
WD=${1:?usage: live.sh <workdir>}
: "${UPSTREAM_PLUGIN_DIR:?set UPSTREAM_PLUGIN_DIR to the mattpocock-skills plugin directory}"
BUDGET=${BUDGET:-0.30}
MODEL=${MODEL:-claude-sonnet-5-5}
. "$PLUGIN_ROOT/tests/helpers/live-hooks.sh"

[ ! -e "$WD/repo" ] || { echo "live.sh: $WD/repo already exists" >&2; exit 2; }
mkdir -p "$WD"
WD=$(cd "$WD" && pwd -P)
REPO=$WD/repo
RUN=$REPO/.artisan-agent/runs/live1
export FAKE_GH_DIR=$WD/tracker
export PATH="$PLUGIN_ROOT/tests/fixtures/fake-gh:$PATH"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
FLAGS=$(live_hooks_args "$PLUGIN_ROOT" "$WD/hooks")

failures=0
check() { # description command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

mkdir -p "$REPO/.artisan-agent" "$FAKE_GH_DIR"
printf '.artisan-agent/runs/\n' >"$REPO/.gitignore"
printf 'max_agents: 2\n' >"$REPO/.artisan-agent/config.yml"
printf 'original\n' >"$REPO/doc.md"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Sample project"
jq -n '{run_id: "live1", repo: "local/sample", integration_branch: "run/live1", scope: ["1"], waves: [["1"]],
  max_agents: 2, attempts_per_ticket: 2, suite_command: "true", budget_usd: 5,
  orchestrator: {model: "claude-sonnet-5-5", estimate_usd: 0.5},
  tickets: {"1": {title: "Add hello", model: "claude-sonnet-5-5", estimate_usd: 0.25, expected: {minutes: 10},
                  expected_files: ["hello.txt"], caps: {max_budget_usd: 0.5, max_turns: 20, deadline_seconds: 600}}}}' >"$WD/plan.json"
sleep 3600 &
HOLDER=$!
trap 'kill $HOLDER 2>/dev/null || true' EXIT
ARTISAN_WRITER_PID=$HOLDER "$S/state.sh" init "$RUN" "$WD/plan.json" >/dev/null
[ -L "$RUN/state.lock" ] || ln -s "$HOLDER" "$RUN/state.lock"
"$S/run-lock.sh" check "$REPO" >/dev/null && { echo "live.sh: the run lock is not held" >&2; exit 2; } || true

session() { # name prompt... : runs one capped session in the repo, output to $WD/<name>.json
  local name=$1 prompt=$2
  shift 2
  rm -f "$WD/proof-$name"
  (cd "$REPO" && ARTISAN_HOOK_PROOF="$WD/proof-$name" perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 240 \
    claude -p "$prompt" --model "$MODEL" --max-budget-usd "$BUDGET" --max-turns 3 --permission-mode acceptEdits --allowedTools Bash Read \
    --plugin-dir "$PLUGIN_ROOT" --plugin-dir "$UPSTREAM_PLUGIN_DIR" $FLAGS --no-session-persistence \
    --output-format stream-json --verbose "$@" >"$WD/$name.jsonl" 2>"$WD/$name.err" </dev/null) || echo "info $name: claude exited $?"
  jq -s 'map(select(.type == "result")) | last // {}' "$WD/$name.jsonl" >"$WD/$name.json" 2>/dev/null || echo '{}' >"$WD/$name.json"
  echo "info $name: $(jq -r '"cost $\(.total_cost_usd) turns \(.num_turns) result: \(.result | tostring | .[0:160])"' "$WD/$name.json" 2>/dev/null)"
  check "$name: a plugin hook fired (SessionStart line)" live_hooks_proof_check "$WD/proof-$name"
}
result_has() { jq -e --arg s "$2" '.result | tostring | contains($s)' "$WD/$1.json"; }

session guard-namespaced "/mattpocock-skills:implement TEST"
check "namespaced: blocked by the replaced-skill guard" result_has guard-namespaced "replaced-skill guard"
check "namespaced: no turns, no model run" jq -e '.num_turns == 0' "$WD/guard-namespaced.json"

session guard-bare "/retro TEST"
check "bare: blocked by the replaced-skill guard" result_has guard-bare "replaced-skill guard"

session main-edit "Use the Edit tool to replace the word original with changed in doc.md. Do nothing else."
check "main-checkout edit refused: doc.md unchanged" sh -c "[ \"\$(cat '$REPO/doc.md')\" = original ]"
check "main-checkout edit refused: the git tree is clean" sh -c "[ -z \"\$(git -C '$REPO' status --porcelain)\" ]"

session second-run "/artisan-agent:implement-plan add a goodbye command"
check "second run refused by the run lock" result_has second-run "run lock"
check "second run queued as a plan issue" sh -c "grep -q 'plan' '$FAKE_GH_DIR/calls' && ls '$FAKE_GH_DIR'/issue-*.json >/dev/null"

session holder-resume "/artisan-agent:implement-plan resume"
check "the holder's resume is not refused by run-start" sh -c "! jq -e '.result | tostring | contains(\"run lock\")' '$WD/holder-resume.json'"
check "the holder's resume reached the model and ran the run digest" \
  sh -c "grep -q 'run-digest' '$WD/holder-resume.jsonl'"

echo "$failures failed"
kill "$HOLDER" 2>/dev/null || true
[ "$failures" -eq 0 ]
