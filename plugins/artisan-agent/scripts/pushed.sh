#!/usr/bin/env bash
# The ticket branches the plugin pushes to a project's remote, and their
# deletion once nothing needs them (#211). worker-ci.sh run pushes a worker's
# branch for its CI run, and move.sh out pushes a moving run's unmerged
# ticket branches; both are recorded in the state file's `pushed`
# (${CLAUDE_PLUGIN_ROOT}/references/state-file.md). Once a ticket is closed
# (merged and closed on the tracker) or has left the run, `prune` deletes its
# branch on the remote: wave.sh close and every sweep run it.
#
# Usage:
#   pushed.sh note <run-dir> <branch> <sha> [--remote R] [--by WHO]
#       note a branch pushed by a process that does not hold the run's lock
#       (worker-ci.sh run, in a worker): one file under <run-dir>/pushed/,
#       no lock taken. The next prune folds it into `pushed`. R defaults to
#       origin, WHO to worker-ci.
#   pushed.sh prune <run-dir>
#       fold the notes into `pushed`, then, for each recorded branch whose
#       ticket is closed (merged with tracker_closed, or status closed) or
#       has left the run (dropped, resliced, bypassed, sent_back, or no
#       longer among the tickets), read its tip on its remote and:
#         - gone already: forget it;
#         - the commit recorded, or one already merged into the integration
#           branch: delete it (a lease on that tip, so a push in between
#           wins), print "deleted <branch>", event branch-deleted;
#         - anything else: someone else pushed to it. Leave it, warn on
#           stderr naming it, forget it (event branch-left);
#         - the remote can't be read or the delete fails: warn, keep it
#           with failed: {tries, why, at}; the next prune tries again.
#       A branch with no ticket in the run, or a ticket still in the run
#       (deferred included), is kept.
#
# Exit status: 0 ok (a failed delete included: it warns and the next prune
# retries it), 1 error, 2 usage, 3 the lock is held or the run is not live
# here.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git and jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
warn() { printf 'pushed.sh: %s\n' "$*" >&2; }

cmd_note() {
  local rd="${1:-}" branch="${2:-}" sha="${3:-}" remote=origin by=worker-ci dir="" f=""
  [ -n "$rd" ] && [ -n "$branch" ] && [ -n "$sha" ] || usage
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) [ $# -ge 2 ] || usage; remote=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  state_require_run_dir "$rd"
  dir="$rd/pushed"
  mkdir -p "$dir"
  # Written aside, then renamed: the fold reads only whole *.json notes.
  f="$dir/$(state_now).$$.json"
  jq -nc --arg b "$branch" --arg s "$sha" --arg r "$remote" --arg by "$by" --argjson at "$(state_now)" \
    '{branch: $b, sha: $s, remote: $r, by: $by, at: $at}' >"$dir/.note.$$.tmp"
  mv -f "$dir/.note.$$.tmp" "$f"
}

# The notes, folded into `pushed` (each the newest push of its branch), then removed.
fold() {
  local f="" note="" notes="[]"
  local -a files=()
  [ -d "$RUN_DIR/pushed" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
    if note=$(jq -ce 'select(type == "object" and (.branch | type) == "string" and (.sha | type) == "string")' "$f" 2>/dev/null); then
      notes=$(jq -c --argjson n "$note" '. + [$n]' <<<"$notes")
    else
      warn "skipped a note that is not a pushed branch: $f"
    fi
  done < <(find "$RUN_DIR/pushed" -type f -name '*.json' | sort)
  [ "${#files[@]}" -gt 0 ] || return 0
  state_apply "$RUN_DIR" '
    . as $root
    | reduce ($n | sort_by(.at))[] as $x (.;
        .pushed = ((.pushed // {}) + {($x.branch): {
          ticket: ([$root.tickets | to_entries[] | select(.value.branch == $x.branch) | .key][0] // null),
          remote: ($x.remote // "origin"), sha: $x.sha, by: ($x.by // "worker-ci"), at: $x.at}}))' --argjson n "$notes"
  rm -f "${files[@]}"
}

# Branches to prune: one "branch<TAB>sha<TAB>remote<TAB>ticket" line each.
done_branches() {
  jq -r '
    . as $root
    | (.pushed // {}) | to_entries[]
    | select(.value.ticket != null)
    | ($root.tickets[.value.ticket]) as $k
    | select($k == null
        or ($k.status | IN("closed", "dropped", "resliced", "bypassed", "sent_back"))
        or ($k.status == "merged" and ($k.tracker_closed // false)))
    | [.key, .value.sha, (.value.remote // "origin"), .value.ticket] | @tsv' "$(state_file "$RUN_DIR")"
}

forget() { # branch event-json
  state_apply "$RUN_DIR" "$STATE_JQ_DEFS"'
    .pushed |= del(.[$b]) | if $e == null then . else event($e; $now) end' \
    --arg b "$1" --argjson e "$2" --argjson now "$(state_now)"
}

failed() { # branch why
  warn "$2; the next sweep tries again"
  state_apply "$RUN_DIR" '
    .pushed[$b].failed = {tries: ((.pushed[$b].failed.tries // 0) + 1), why: $why, at: $now}' \
    --arg b "$1" --arg why "$2" --argjson now "$(state_now)"
}

prune() {
  fold
  [ "$(jq '(.pushed // {}) | length' "$(state_file "$RUN_DIR")")" -gt 0 ] || return 0
  local common="" main="" ib="" br="" sha="" remote="" t="" tip="" ev=""
  common=$(git -C "$RUN_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { warn "$RUN_DIR is not inside a git repository, so no pushed branch is pruned"; return 0; }
  main=$(dirname "$common")
  ib=$(jq -r '.integration.branch // ""' "$(state_file "$RUN_DIR")")
  while IFS=$'\t' read -r br sha remote t; do
    [ -n "$br" ] || continue
    ev=$(jq -nc --arg b "$br" --arg t "$t" --arg r "$remote" --arg s "$sha" '{branch: $b, ticket: $t, remote: $r, sha: $s}')
    if ! tip=$(git -C "$main" ls-remote --heads "$remote" "refs/heads/$br" 2>/dev/null); then
      failed "$br" "could not delete $br on $remote: $remote could not be read"
      continue
    fi
    tip=${tip%%[[:space:]]*}
    if [ -z "$tip" ]; then
      forget "$br" "$(jq -c '. + {event: "branch-deleted", already: true}' <<<"$ev")"
      continue
    fi
    if [ "$tip" != "$sha" ] && ! { [ -n "$ib" ] && git -C "$main" cat-file -e "$tip^{commit}" 2>/dev/null \
      && git -C "$main" merge-base --is-ancestor "$tip" "refs/heads/$ib" 2>/dev/null; }; then
      warn "left $br on $remote: its tip moved to $tip after the run pushed $sha (someone else pushed to it)"
      forget "$br" "$(jq -c --arg tip "$tip" '. + {event: "branch-left", tip: $tip}' <<<"$ev")"
      continue
    fi
    if git -C "$main" push -q --force-with-lease="refs/heads/$br:$tip" "$remote" --delete "$br" >/dev/null 2>&1; then
      forget "$br" "$(jq -c '. + {event: "branch-deleted"}' <<<"$ev")"
      printf 'deleted %s\n' "$br"
    else
      failed "$br" "could not delete $br on $remote"
    fi
  done < <(done_branches)
}

cmd_prune() {
  [ $# -eq 1 ] || usage
  RUN_DIR=$1
  state_require_run_dir "$RUN_DIR"
  state_with_lock "$RUN_DIR" prune
}

case "${1:-}" in
  note) shift; cmd_note "$@" ;;
  prune) shift; cmd_prune "$@" ;;
  *) usage ;;
esac
