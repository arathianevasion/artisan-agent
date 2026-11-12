#!/usr/bin/env bash
# The reconciler: bring the state file into line with git and the tracker,
# then recompute the frontier from them, never from the plan's waves.
# Field meanings: ${CLAUDE_PLUGIN_ROOT}/references/state-file.md
#
# Usage: reconcile.sh <run-dir>
#
# A new orchestrator runs this before anything else. It:
#   1. marks merged every ticket in scope whose branch was merged into the
#      integration branch (with --no-ff, so the merge commit is on its
#      first-parent line), recording that merge commit; git is the fact, the
#      state file only a claim;
#   2. runs the sweep (sweep.sh) over in-flight tickets and findings;
#   3. reads each ticket in scope from the tracker (gh api): open or closed,
#      labels, and its native blocked-by list;
#   4. marks closed any queued ticket the tracker has closed without a merge;
#   5. writes the frontier: queued tickets, open on the tracker, not labelled
#      ready-for-human and not held for the Artisan (human.sh), whose blockers are all merged into the integration
#      branch (blockers in the run) or closed (blockers outside it).
# Prints the frontier, one ticket per line. Running it again on the same git
# and tracker state changes nothing. The run folder must sit at
# <checkout>/.artisan-agent/runs/<run-id>.
#
# Exit status: 0 ok, 1 error (including a failed tracker read: git's merges
# and the sweep are kept, the frontier is not recomputed and must not be
# used), 2 usage, 3 the lock is held by another live process.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

[ $# -eq 1 ] || state_usage "$0"
RUN_DIR=$(cd "$1" && pwd)
state_require_run_dir "$RUN_DIR"
REPO_DIR=$(cd "$RUN_DIR/../../.." && pwd)

# merge_commit_for integration branch: the first commit on the integration
# branch's first-parent line that contains the ticket branch's tip.
merge_commit_for() {
  local integration="$1" tip="$2" c=
  local commits=
  commits=$(git -C "$REPO_DIR" rev-list --first-parent --reverse "$integration")
  for c in $commits; do
    if git -C "$REPO_DIR" merge-base --is-ancestor "$tip" "$c"; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

reconcile() {
  local file= tmp= repo= integration= first_parent= t= branch= tip= sha= issue= blockers= tracker=
  file=$(state_file "$RUN_DIR")
  tmp=$(state_tmp "$RUN_DIR")
  cp "$file" "$tmp"

  step() { state_step "$tmp" "$@"; }

  repo=$(jq -r '.repo' "$tmp")
  integration=$(jq -r '.integration.branch' "$tmp")

  # Tickets added to the scope after approval get an entry.
  step "$STATE_JQ_DEFS"'reduce .plan.scope[] as $t (.;
          if .tickets[$t] == null then .tickets[$t] = new_ticket($t) else . end)'

  # Git: what is merged into the integration branch.
  if git -C "$REPO_DIR" rev-parse -q --verify "refs/heads/$integration" >/dev/null; then
    first_parent=$(git -C "$REPO_DIR" rev-list --first-parent "$integration")
    for t in $(jq -r '.plan.scope[]' "$tmp"); do
      [ "$(jq -r --arg t "$t" '.tickets[$t].status' "$tmp")" = "merged" ] && continue
      branch=$(jq -r --arg t "$t" '.tickets[$t].branch' "$tmp")
      tip=$(git -C "$REPO_DIR" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null) || continue
      # A branch still sitting on the integration line (dispatched, nothing
      # merged yet) is not merged work; a merged ticket comes in through a
      # --no-ff merge commit, so its tip is off the first-parent line.
      case "$first_parent" in *"$tip"*) continue ;; esac
      sha=$(merge_commit_for "$integration" "$tip") || continue
      step "$STATE_JQ_DEFS"'merged($t; $sha)
        | event({event: "merge", ticket: $t, commit: $sha, source: "reconcile"}; $now)' \
        --arg t "$t" --arg sha "$sha" --argjson now "$(state_now)"
    done
  fi

  state_commit "$RUN_DIR" "$tmp"

  # The sweep, under this call's lock, after git: a worker whose branch is
  # already merged is not a failed attempt.
  ARTISAN_WRITER_PID=$(state_writer_pid) "$SCRIPT_DIR/sweep.sh" "$RUN_DIR" || return $?
  cp "$file" "$tmp"

  # Tracker: state, labels and blockers for every ticket in scope.
  tracker='{}'
  for t in $(jq -r '.plan.scope[]' "$tmp"); do
    issue=$(gh api "repos/$repo/issues/$t") || { rm -f "$tmp"; state_die 1 "reconcile: could not read #$t from the tracker"; }
    blockers=$(gh api "repos/$repo/issues/$t/dependencies/blocked_by") \
      || { rm -f "$tmp"; state_die 1 "reconcile: could not read blockers of #$t from the tracker"; }
    tracker=$(jq -n --argjson acc "$tracker" --arg t "$t" --argjson i "$issue" --argjson b "$blockers" '
      $acc + {($t): {
        state: ($i.state | ascii_downcase),
        labels: [$i.labels[]? | (.name? // .)],
        blocked_by: [$b[]? | {number: (.number | tostring), state: (.state | ascii_downcase)}]
      }}')
  done

  step "$STATE_JQ_DEFS"'
    .tickets |= with_entries(
      if .value.status == "queued" and $tr[.key].state == "closed"
      then .value.status = "closed" else . end)
    | . as $s
    | .frontier = [
        $s.plan.scope[] as $t
        | select($s.tickets[$t].status == "queued")
        | select($tr[$t].state == "open")
        | select(($tr[$t].labels | index("ready-for-human")) == null)
        | select($s.tickets[$t].human == null)
        | select((($s.plan.hands_on.ticket // "") | tostring) != $t)
        | select(all($tr[$t].blocked_by[];
            if $s.tickets[.number] != null
            then $s.tickets[.number].status == "merged"
                 and ($s.tickets[.number].risk_gate.status? // "") != "waiting"
                 and ((.number | tostring) as $b | $s | gate_holds($b) | not)
            else .state == "closed" end))
        | $t
      ] | .frontier |= sort_by(tonumber? // .)' --argjson tr "$tracker"

  state_commit "$RUN_DIR" "$tmp"
}

state_with_lock "$RUN_DIR" reconcile
jq -r '.frontier[]' "$(state_file "$RUN_DIR")"
