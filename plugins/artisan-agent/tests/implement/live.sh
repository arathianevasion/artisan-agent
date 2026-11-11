#!/usr/bin/env bash
# live.sh: prove /artisan-agent:implement with capped headless sessions on
# sample tickets in throwaway git repos. Not part of tests/run.sh, because it
# spends money; run it by hand when the skill changes.
#
# Usage:
#   live.sh setup  <scenario> <workdir>   build the throwaway repo only
#   live.sh run    <scenario> <workdir>   build it, then run one headless worker
#   live.sh verify <scenario> <workdir>   check what the worker left behind
#
# Scenarios (fixtures in tests/fixtures/implement/<scenario>/):
#   named-seam    the ticket names its seam; built test-first there
#   unnamed-seam  no seam named; the worker's new seam becomes a decision card
#   review-seeds  a first attempt with a seeded bug, a seeded documented-standard
#                 violation and a seeded judgement-call smell; the bug and the
#                 violation get fixed, the smell becomes a decision card
#
# `run` needs UPSTREAM_PLUGIN_DIR: a directory holding the mattpocock-skills
# plugin (for tdd and code-review). It loads both plugins with --plugin-dir,
# reads no user settings (--setting-sources project,local), saves no session
# (--no-session-persistence), and caps the session with --max-budget-usd
# (BUDGET, default 0.50), --model (MODEL, default claude-sonnet-5-5) and a
# wall-clock deadline (DEADLINE seconds, default 1200).
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3 and perl.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/../.." && pwd)
FIXTURES="$PLUGIN_ROOT/tests/fixtures/implement"

ticket_id() {
  case "$1" in
    named-seam) echo 01 ;;
    unnamed-seam) echo 02 ;;
    review-seeds) echo 03 ;;
    *) echo "live.sh: unknown scenario: $1" >&2; exit 2 ;;
  esac
}

git_quiet() { git -c user.name=fixture -c user.email=fixture@example.invalid "$@" >/dev/null; }

# Builds <workdir>/repo: main holds the fixture and the ticket; the worker's
# branch agent/<id> starts from main, plus the seeded first attempt for
# review-seeds. Writes <workdir>/base (the commit the branch started from).
setup() {
  local scenario=$1 wd=$2 id fixture
  id=$(ticket_id "$scenario")
  fixture="$FIXTURES/$scenario"
  [ ! -e "$wd/repo" ] || { echo "live.sh: $wd/repo already exists" >&2; exit 2; }
  mkdir -p "$wd/results"
  cp -R "$fixture/repo" "$wd/repo"
  mkdir -p "$wd/repo/tickets"
  cp "$fixture/ticket.md" "$wd/repo/tickets/$id.md"
  printf '__pycache__/\n.artisan-agent/runs/\n' > "$wd/repo/.gitignore"
  git_quiet -C "$wd/repo" init -q -b main
  git_quiet -C "$wd/repo" add -A
  git_quiet -C "$wd/repo" commit -q -m "Fixture for ticket $id"
  git -C "$wd/repo" rev-parse HEAD > "$wd/base"
  git_quiet -C "$wd/repo" checkout -q -b "agent/$id"
  if [ -d "$fixture/attempt" ]; then
    cp -R "$fixture/attempt/." "$wd/repo/"
    git_quiet -C "$wd/repo" add -A
    git_quiet -C "$wd/repo" commit -q -m "First attempt at ticket $id (stopped before review)"
  fi
}

run() {
  local scenario=$1 wd=$2 id base
  : "${UPSTREAM_PLUGIN_DIR:?set UPSTREAM_PLUGIN_DIR to the mattpocock-skills plugin directory}"
  setup "$scenario" "$wd"
  id=$(ticket_id "$scenario")
  base=$(cat "$wd/base")
  (
    cd "$wd/repo"
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "${DEADLINE:-1200}" \
      claude -p "/artisan-agent:implement tickets/$id.md (ticket $id). Base: $base. Write the evidence record to $wd/results/$id.json." \
      --model "${MODEL:-claude-sonnet-5-5}" \
      --max-budget-usd "${BUDGET:-0.50}" \
      --permission-mode acceptEdits \
      --allowedTools Bash Skill Agent Read Write Edit Glob Grep \
      --add-dir "$wd/results" \
      --plugin-dir "$PLUGIN_ROOT" \
      --plugin-dir "$UPSTREAM_PLUGIN_DIR" \
      --setting-sources project,local \
      --no-session-persistence \
      --output-format stream-json --verbose \
      > "$wd/session.jsonl" 2> "$wd/stderr.log"
  ) || echo "live.sh: claude exited $?" >&2
  jq -r 'select(.type == "result") | "cost_usd=\(.total_cost_usd) turns=\(.num_turns) is_error=\(.is_error) result=\(.result | tostring | .[0:200])"' \
    "$wd/session.jsonl" || true
}

failures=0
check() { # description command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    failures=$((failures + 1))
  fi
}

record_says() { jq -e "$2" "$1"; }

py() { (cd "$1" && python3 -c "$2"); }

# Paths the session wrote or edited, in order.
edited_paths() {
  jq -r 'select(.type == "assistant") | .message.content[]?
    | select(.type == "tool_use" and (.name == "Write" or .name == "Edit" or .name == "MultiEdit"))
    | .input.file_path' "$1/session.jsonl" 2>/dev/null
}

# True unless a Write/Edit to a path matching $3 comes before the first to $2.
# (Edits made through Bash leave no path here; red_before_commit covers them.)
not_edited_before() {
  edited_paths "$1" | awk -v a="$2" -v b="$3" '
    $0 ~ a && !ia { ia = NR } $0 ~ b && !ib { ib = NR }
    END { exit !(!ib || (ia && ia < ib)) }'
}

# True when a test run failed (red) before the session's first git commit
# finished. A Bash call that both runs the tests and commits counts its own
# red output first, since its commands run in order.
red_before_commit() {
  jq -rs '
    [.[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "Bash" and (.input.command | test("git( -C [^ ]+)? commit")))
      | .id] as $commits
    | .[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
    | .tool_use_id as $id
    | (if (.content | tostring | test("FAILED \\(|AssertionError|ImportError")) then "red" else empty end),
      (if ($commits | index($id)) != null then "commit" else empty end)' "$1/session.jsonl" 2>/dev/null | awk '
    $0 == "red" && !r { r = NR } $0 == "commit" && !c { c = NR }
    END { exit !(r && (!c || r < c)) }'
}

skill_loaded() { # session skill
  jq -e --arg s "$2" 'select(.type == "assistant") | .message.content[]?
    | select(.type == "tool_use" and .name == "Skill" and .input.skill == $s)' "$1/session.jsonl" >/dev/null 2>&1
}

suite_passes() { (cd "$1" && python3 -m unittest -q); }
tree_clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
no_stash() { [ -z "$(git -C "$1" stash list)" ]; }
branch_moved() { [ "$(git -C "$1" rev-parse HEAD)" != "$2" ] && [ "$(git -C "$1" rev-list --count "$2..HEAD")" -gt "${3:-0}" ]; }
record_commit_is_tip() { [ "$(jq -r .commit "$2")" = "$(git -C "$1" rev-parse HEAD)" ] || [ "$(git -C "$1" rev-parse "$(jq -r .commit "$2")")" = "$(git -C "$1" rev-parse HEAD)" ]; }

verify() {
  local scenario=$1 wd=$2 id repo record base seeded=0
  id=$(ticket_id "$scenario")
  repo="$wd/repo"
  record="$wd/results/$id.json"
  base=$(cat "$wd/base")
  [ "$scenario" != review-seeds ] || seeded=1

  check "a result file exists" test -f "$record"
  check "it is an evidence record ($HERE/check-evidence-record.sh)" "$HERE/check-evidence-record.sh" "$record"
  check "status is complete" record_says "$record" '.status == "complete"'
  check "the worker committed on agent/$id" branch_moved "$repo" "$base" "$seeded"
  check "the record names the branch tip" record_commit_is_tip "$repo" "$record"
  check "the working tree is clean" tree_clean "$repo"
  check "nothing was stashed" no_stash "$repo"
  check "the suite passes" suite_passes "$repo"
  check "the record says the suite passed" record_says "$record" '.tests.suite_passed == true'
  check "every acceptance criterion is met" record_says "$record" '(.acceptance | length) > 0 and all(.acceptance[]; .met == true)'
  check "code-review ran" record_says "$record" '.review.ran == true'
  check "the worker loaded mattpocock-skills:tdd" skill_loaded "$wd" mattpocock-skills:tdd
  check "the worker loaded mattpocock-skills:code-review" skill_loaded "$wd" mattpocock-skills:code-review

  case "$scenario" in
    named-seam)
      check "slugify meets the ticket's examples" py "$repo" '
from text import slugify
assert slugify("Hello, World!") == "hello-world"
assert slugify("  --Weekly   Plan 2--  ") == "weekly-plan-2"'
      check "slugify is tested at the named seam" grep -q slugify "$repo/tests/test_text.py"
      check "test-first: no Write/Edit to text.py before the test" not_edited_before "$wd" 'tests/test_text\.py$' '/text\.py$'
      check "test-first: a test run failed before the first commit" red_before_commit "$wd"
      ;;
    unnamed-seam)
      check "cli.py export prints the CSV" py "$repo" '
import subprocess, sys
out = subprocess.run([sys.executable, "cli.py", "export"], capture_output=True, text=True, check=True).stdout
assert out.splitlines() == ["number,customer,amount_pence", "INV-001,Ada,1250", "INV-002,Grace,99000"], out'
      check "cli.py list is unchanged" py "$repo" '
import subprocess, sys
out = subprocess.run([sys.executable, "cli.py", "list"], capture_output=True, text=True, check=True).stdout
assert out == "INV-001 Ada\nINV-002 Grace\n", out'
      check "the new seam is a decision card" record_says "$record" \
        'any(.decisions[]; ((.question + " " + .choice) | test("seam|test|function|interface|module|boundary"; "i")))'
      ;;
    review-seeds)
      check "the seeded bug is fixed: 5000 pence ships free" py "$repo" '
from shop import shipping
assert shipping(5000) == 0 and shipping(4999) == 499 and shipping(6000) == 0'
      check "the seeded standard violation is fixed: shop.py never prints" sh -c "! grep -n 'print(' '$repo/shop.py'"
      check "the judgement-call smell is unchanged: check_address keeps its signature" \
        grep -qx 'def check_address(street, city, postcode):' "$repo/shop.py"
      check "the judgement-call smell is unchanged: delivery_label keeps its signature" \
        grep -qx 'def delivery_label(street, city, postcode):' "$repo/shop.py"
      check "review findings were fixed" record_says "$record" 'any(.review.findings[]; .disposition == "fixed")'
      check "a review finding was left as a decision" record_says "$record" 'any(.review.findings[]; .disposition == "decision")'
      check "the smell is a decision card" record_says "$record" \
        'any(.decisions[]; ((.question + " " + .choice + " " + .alternative) | test("address|street|postcode|clump"; "i")))'
      ;;
  esac

  echo
  echo "decision cards:"
  jq -r '.decisions[]? | "  - [\(.kind), \(.confidence // "no confidence")] \(.question) -> \(.choice) (not: \(.alternative))"' "$record" 2>/dev/null || true
  [ "$failures" -eq 0 ]
}

[ $# -eq 3 ] || { sed -n '2,24p' "$0" >&2; exit 2; }
case "$1" in
  setup) setup "$2" "$3" ;;
  run) run "$2" "$3" ;;
  verify) verify "$2" "$3" ;;
  *) sed -n '2,24p' "$0" >&2; exit 2 ;;
esac
