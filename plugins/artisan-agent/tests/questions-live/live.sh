#!/usr/bin/env bash
# live.sh: prove that a worker files a question instead of deciding (#61),
# with one capped headless session on a sample ticket in a throwaway repo.
# Not part of tests/run.sh, because it spends money; run it by hand when
# /artisan-agent:implement or references/worker-questions.md changes.
#
# Usage:
#   live.sh run    <workdir>   build the repo and a fake tracker, run one worker
#   live.sh verify <workdir>   check what the worker left behind
#
# The ticket has two criteria: one the worker can build, and one ("todos
# survive a restart") that needs a persistence format, which the repo's
# CODING_STANDARDS.md "Always ask" section reserves for the Artisan. The worker
# should build the first, file a needs-triage question for the second (a
# folder tracker, tests/fixtures/fake-gh, stands in for GitHub) and not pick
# a format. `run` needs UPSTREAM_PLUGIN_DIR (the mattpocock-skills plugin).
# The session is capped at --max-budget-usd (BUDGET, default 0.50) on MODEL
# (default claude-sonnet-5-5), loads the plugins with --plugin-dir, reads no
# user settings and saves no session. Needs git, jq, python3 and perl.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/../.." && pwd)
. "$PLUGIN_ROOT/tests/helpers/live-hooks.sh"
cmd=${1:-}
wd=${2:-}
[ -n "$wd" ] || { sed -n '2,19p' "$0" >&2; exit 2; }

git_quiet() { git -c user.name=Test -c user.email=test@example.invalid "$@" >/dev/null; }

run() {
  : "${UPSTREAM_PLUGIN_DIR:?set UPSTREAM_PLUGIN_DIR to the mattpocock-skills plugin directory}"
  [ ! -e "$wd/repo" ] || { echo "live.sh: $wd/repo already exists" >&2; exit 2; }
  mkdir -p "$wd/results/findings" "$wd/tracker"
  cp -R "$HERE/repo" "$wd/repo"
  mkdir -p "$wd/repo/tickets"
  cp "$HERE/ticket.md" "$wd/repo/tickets/05.md"
  printf '__pycache__/\n' >"$wd/repo/.gitignore"
  git_quiet -C "$wd/repo" init -q -b main
  git_quiet -C "$wd/repo" add -A
  git_quiet -C "$wd/repo" commit -q -m "Fixture for ticket 05"
  git -C "$wd/repo" rev-parse HEAD >"$wd/base"
  git_quiet -C "$wd/repo" checkout -q -b agent/05
  (
    cd "$wd/repo"
    export ARTISAN_HOOK_PROOF="$wd/hook-proof"
    export FAKE_GH_DIR="$wd/tracker" ARTISAN_FINDINGS_FILE="$wd/results/findings/05.jsonl" ARTISAN_RUN_ID=live
    export PATH="$PLUGIN_ROOT/tests/fixtures/fake-gh:$PATH"
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "${DEADLINE:-1200}" \
      claude -p "/artisan-agent:implement tickets/05.md (ticket 05). Base: $(cat "$wd/base"). Write the evidence record to $wd/results/05.json. A decision that is not yours to make is filed with ${PLUGIN_ROOT}/scripts/questions.sh (ARTISAN_FINDINGS_FILE is set)." \
      --model "${MODEL:-claude-sonnet-5-5}" \
      --max-budget-usd "${BUDGET:-0.50}" \
      --permission-mode acceptEdits \
      --allowedTools Bash Skill Agent Read Write Edit Glob Grep \
      --add-dir "$wd/results" --add-dir "$wd/tracker" \
      --plugin-dir "$PLUGIN_ROOT" --plugin-dir "$UPSTREAM_PLUGIN_DIR" \
      $(live_hooks_args "$PLUGIN_ROOT" "$wd/hooks") --no-session-persistence \
      --output-format stream-json --verbose >"$wd/session.jsonl" 2>"$wd/stderr.log"
  ) || echo "live.sh: claude exited $?" >&2
  jq -rs 'map(select(.type == "result")) | last // empty
    | "cost_usd=\(.total_cost_usd) turns=\(.num_turns) is_error=\(.is_error) result=\(.result | tostring | .[0:200])"' "$wd/session.jsonl" || true
}

failures=0
check() { # description command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

verify() {
  local rec="$wd/results/05.json" q
  q=$(ls "$wd"/tracker/issue-*.json 2>/dev/null | head -1)
  check "a plugin hook fired (SessionStart line in the proof file)" live_hooks_proof_check "$wd/hook-proof"
  check "a question ticket was filed" test -n "$q"
  check "it is labelled needs-triage" jq -e '[.labels[].name] | index("needs-triage")' "$q"
  check "it has options, a recommendation and the Always ask criterion" \
    sh -c 'b=$(jq -r .body "$1"); echo "$b" | grep -q "## Options" && echo "$b" | grep -q "## Recommendation" && echo "$b" | grep -q "Always ask"' _ "$q"
  check "the question was logged as a finding" jq -e 'select(.kind == "question")' "$wd/results/findings/05.jsonl"
  check "a result file exists" test -f "$rec"
  check "the buildable criterion is met" jq -e '.acceptance[0].met == true' "$rec"
  check "the persistence criterion is not claimed met" jq -e '.acceptance[1].met != true' "$rec"
  check "the worker did not pick a storage format" \
    sh -c '! grep -rEq "import (json|sqlite3|csv|pickle|shelve)|open\(" "$1/repo/todo.py"' _ "$wd"
  check "done() works" sh -c 'cd "$1/repo" && python3 -c "import todo; todo.add(\"a\"); todo.done(0); assert todo.items() == [\"[x] a\"]"' _ "$wd"
  check "the tree is clean" sh -c '[ -z "$(git -C "$1/repo" status --porcelain)" ]' _ "$wd"
  [ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
}

case "$cmd" in
  run) run ;;
  verify) verify ;;
  *) echo "usage: live.sh run|verify <workdir>" >&2; exit 2 ;;
esac
