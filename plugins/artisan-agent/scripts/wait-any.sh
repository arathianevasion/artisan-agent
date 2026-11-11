#!/usr/bin/env bash
# Block in the foreground until a run's files change, or until a timeout.
#
# Usage: wait-any.sh <run-dir> [--timeout SECONDS] [--interval SECONDS] [--seen FILE]
#
# Watches every file under <run-dir>/results/ (result files, exit records and
# results/findings/*.jsonl), skipping dotfiles, which are writes in progress.
# Returns when a file appears that this caller has not seen, or a seen file
# changes size (a findings file growing). It prints one line per change,
# "new <path>" or "grew <path>" (or "changed <path>" if it shrank), with paths
# relative to <run-dir>, and records what it saw so the next call only wakes
# on later changes.
#
# What it has seen is kept in --seen (default <run-dir>/.wait-any.seen). The
# first call with no seen file reports every file already present: files are
# the truth, so a caller that just started reconciles against all of them.
#
# --timeout defaults to 110 seconds, under the Bash tool's 2-minute default
# timeout. A caller passing a longer --timeout must pass the Bash tool a
# longer timeout too.
#
# Exit status: 0 on a change, 124 on timeout, 2 on bad usage.
#
# Portable to bash 3.2 (macOS) and Linux.

set -euo pipefail

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage
run_dir=$1
shift
timeout=110
interval=1
seen=

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout=${2:?}; shift 2 ;;
    --interval) interval=${2:?}; shift 2 ;;
    --seen) seen=${2:?}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "wait-any.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$run_dir" ]; then
  echo "wait-any.sh: no such run folder: $run_dir" >&2
  exit 2
fi
seen=${seen:-$run_dir/.wait-any.seen}
[ -f "$seen" ] || : >"$seen"

# One "size<TAB>path" line per watched file, sorted by path.
snapshot() {
  [ -d "$run_dir/results" ] || return 0
  (
    cd "$run_dir"
    find results -type f ! -name '.*' | LC_ALL=C sort | while IFS= read -r f; do
      size=$(wc -c <"$f" 2>/dev/null | tr -d ' ') || continue
      printf '%s\t%s\n' "$size" "$f"
    done
  )
}

# Lines describing what changed between the seen snapshot and the current one.
changes() { # current-snapshot-file
  awk -F'\t' '
    FILENAME == ARGV[1] { old[$2] = $1; next }
    !($2 in old)   { print "new " $2; next }
    $1 + 0 > old[$2] + 0 { print "grew " $2; next }
    $1 + 0 < old[$2] + 0 { print "changed " $2 }
  ' "$seen" "$1"
}

current=$(mktemp "${TMPDIR:-/tmp}/wait-any.XXXXXX")
trap 'rm -f "$current"' EXIT

end=$((SECONDS + timeout))
while :; do
  snapshot >"$current"
  found=$(changes "$current")
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    cp "$current" "$seen.tmp" && mv "$seen.tmp" "$seen"
    exit 0
  fi
  [ "$SECONDS" -lt "$end" ] || exit 124
  sleep "$interval"
done
