#!/usr/bin/env bash
# The run lock: one run per repo. A run holds the lock while its state.lock
# (see ${CLAUDE_PLUGIN_ROOT}/references/state-file.md) names a live pid.
#
# Usage:
#   run-lock.sh check [dir] [--local] [--override WHO]
#       exit 0 if no run holds the lock; exit 3 and print "<run-id> <pid>" if
#       one does. dir: any path inside the repo (default: the current directory).
#       When no run here holds it, also look for a run open on another machine
#       (#430): on the remote (origin), a run/<id> branch not merged into its
#       default branch, or a runs/<id> snapshot (move.sh) whose run hasn't ended;
#       on the tracker (gh), an open ticket labelled in-run. Runs whose folder
#       is live here don't count. Any found: exit 4, printing one line each,
#       "branch run/<id>", "snapshot runs/<id>" or "ticket #<n> <title>".
#       A remote or tracker it can't reach is skipped, with "remote not
#       checked: …" or "tracker not checked: …" on stderr, as before #430.
#   --local     only the lock here, as before #430 (no network): the hooks and
#               the sweep, which only need to know whether a run holds the lock
#   --override WHO
#               what was found elsewhere doesn't stop the caller: exit 0, and
#               append {at, by: WHO, machine, found} to
#               .artisan-agent/runs/run-lock-overrides.jsonl. A lock held here
#               still exits 3.
#
# A lock whose pid is dead is stale and does not count. A one-off state write
# takes the lock for a moment too, so a check can be refused for that moment;
# retry. Exit status: 0 free, 1 error, 2 usage, 3 held here, 4 maybe open
# elsewhere.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"

# The runs live here: folders with a state file, live on this machine
# (state_location_guard) and not ended. One id per line.
local_runs() { # runs-dir
  local f= d=
  for f in "$1"/*/state.json; do
    [ -f "$f" ] || continue
    d=$(dirname "$f")
    state_location_guard "$d" 2>/dev/null || continue
    jq -e '(.end_gate.status // "") == "ended"' "$f" >/dev/null 2>&1 && continue
    basename "$d"
  done
}

# Their tickets, one number per line.
local_tickets() { # runs-dir ids...
  local runs=$1 id=
  shift
  for id in "$@"; do
    jq -r '(.tickets // {}) | keys[]' "$runs/$id/state.json" 2>/dev/null || true
  done
}

is_in() { # word list...
  local w=$1 x=
  shift
  for x in "$@"; do [ "$x" = "$w" ] && return 0; done
  return 1
}

# Lines for run/ and runs/ branches on the remote; "remote not checked" on
# stderr when it can't be read.
remote_runs() { # main remote here-ids...
  local main=$1 remote=$2 heads= head= sha= ref= id= state=
  shift 2
  export GIT_TERMINAL_PROMPT=0
  git -C "$main" remote get-url "$remote" >/dev/null 2>&1 \
    || { echo "run-lock.sh: remote not checked: no remote named $remote" >&2; return 0; }
  heads=$(git -C "$main" ls-remote --symref "$remote" HEAD 'refs/heads/run/*' 'refs/heads/runs/*' 2>/dev/null) \
    || { echo "run-lock.sh: remote not checked: $remote could not be reached" >&2; return 0; }
  head=$(awk '$1 == "ref:" && $3 == "HEAD" { sub("refs/heads/", "", $2); print $2 }' <<<"$heads")
  [ -n "$head" ] || head=main
  grep -q 'refs/heads/runs\?/' <<<"$heads" || return 0
  git -C "$main" fetch -q "$remote" "+refs/heads/$head:refs/remotes/$remote/$head" \
    "+refs/heads/run/*:refs/remotes/$remote/run/*" "+refs/heads/runs/*:refs/remotes/$remote/runs/*" 2>/dev/null \
    || { echo "run-lock.sh: remote not checked: could not fetch from $remote" >&2; return 0; }
  while read -r sha ref; do
    case "$ref" in
      refs/heads/run/*)
        id=${ref#refs/heads/run/}
        is_in "$id" "$@" && continue
        git -C "$main" merge-base --is-ancestor "$sha" "refs/remotes/$remote/$head" 2>/dev/null && continue
        echo "branch run/$id"
        ;;
      refs/heads/runs/*)
        id=${ref#refs/heads/runs/}
        is_in "$id" "$@" && continue
        state=$(git -C "$main" show "$sha:.artisan-agent/runs/$id/state.json" 2>/dev/null || true)
        jq -e '(.end_gate.status // "") == "ended"' <<<"$state" >/dev/null 2>&1 && continue
        echo "snapshot runs/$id"
        ;;
    esac
  done < <(awk '$1 != "ref:" && $2 ~ /^refs\/heads\/runs?\// { print $1, $2 }' <<<"$heads")
}

# Lines for open in-run tickets not in a run here; "tracker not checked" on
# stderr when gh can't answer.
tracker_runs() { # main here-tickets...
  local main=$1 rows= n= title=
  shift
  command -v gh >/dev/null 2>&1 || { echo "run-lock.sh: tracker not checked: gh is not installed" >&2; return 0; }
  rows=$(cd "$main" && gh issue list --state open --label in-run --limit 10000 --json number,title 2>/dev/null) \
    && jq -e 'type == "array"' <<<"$rows" >/dev/null 2>&1 \
    || { echo "run-lock.sh: tracker not checked: gh could not list in-run tickets" >&2; return 0; }
  while IFS=$'\t' read -r n title; do
    [ -n "$n" ] || continue
    is_in "$n" "$@" && continue
    echo "ticket #$n $title"
  done < <(jq -r '.[] | [(.number | tostring), (.title // "")] | @tsv' <<<"$rows")
}

case "${1:-}" in
  check)
    shift
    dir=. only_local=0 override=
    while [ $# -gt 0 ]; do
      case "$1" in
        --local) only_local=1; shift ;;
        --override) [ $# -ge 2 ] && [ -n "$2" ] || state_usage "$0"; override=$2; shift 2 ;;
        -*) state_usage "$0" ;;
        *) dir=${1:-.}; shift ;;
      esac
    done
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || state_die 1 "not inside a git repository: $dir"
    main=$(dirname "$common")
    runs="$main/.artisan-agent/runs"
    for lock in "$runs"/*/state.lock; do
      [ -L "$lock" ] || continue
      pid=$(readlink "$lock")
      if state_pid_alive "$pid"; then
        printf '%s %s\n' "$(basename "$(dirname "$lock")")" "$pid"
        exit 3
      fi
    done
    [ "$only_local" -eq 0 ] || exit 0
    state_require_jq
    here=()
    while IFS= read -r id; do here+=("$id"); done < <(local_runs "$runs")
    here_tickets=()
    if [ ${#here[@]} -gt 0 ]; then
      while IFS= read -r t; do here_tickets+=("$t"); done < <(local_tickets "$runs" "${here[@]}")
    fi
    found=$(remote_runs "$main" origin ${here[@]+"${here[@]}"}; tracker_runs "$main" ${here_tickets[@]+"${here_tickets[@]}"})
    [ -n "$found" ] || exit 0
    if [ -n "$override" ]; then
      mkdir -p "$runs"
      jq -cn --arg by "$override" --arg m "$(state_machine_id)" --argjson at "$(state_now)" --arg f "$found" \
        '{at: $at, by: $by, machine: $m, found: ($f | split("\n"))}' >>"$runs/run-lock-overrides.jsonl"
      printf '%s\n' "$found" >&2
      echo "run-lock.sh: a run may be open elsewhere (above); overridden by $override, recorded in $runs/run-lock-overrides.jsonl" >&2
      exit 0
    fi
    printf '%s\n' "$found"
    exit 4
    ;;
  *) state_usage "$0" ;;
esac
