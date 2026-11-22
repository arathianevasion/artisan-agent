#!/usr/bin/env bash
# Capture one named step of a user journey into a folder (#323): the one entry
# point every other script calls, so none of them knows which kind of capture
# the product uses.
#
# Usage:
#   capture.sh STEP FOLDER [--file CONFIG] [--command CMD]
#
# Runs the project's capture_command (.artisan-agent/config.yml, or CONFIG;
# CMD instead, as setup does to prove one) with bash in the repo root, with
# ARTISAN_CAPTURE_STEP=STEP and ARTISAN_CAPTURE_DIR=FOLDER (made if missing).
# A command that writes a file into FOLDER, new or changed, has captured it
# (a screenshot). One that writes none but prints output (a CLI) is captured
# as a transcript, FOLDER/STEP.txt: "$ " and the command, then its output,
# stdout and stderr together as a terminal shows them.
# Prints each captured file's path, one per line.
#
# STEP is a file name: letters, digits, ".", "_" and "-", not starting with ".".
#
# Exit status: 0 captured; 1 the command failed or captured nothing (why on
# stderr, with the tail of its output); 2 bad usage; 16 no capture_command
# recorded.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'capture.sh: %s\n' "$*" >&2; exit 1; }

step= dir= file= cmd= have_cmd= conf= npos=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || usage; file=$2; shift 2 ;;
    --command) [ $# -ge 2 ] || usage; cmd=$2; have_cmd=1; shift 2 ;;
    -*) usage ;;
    *)
      npos=$((npos + 1))
      case $npos in 1) step=$1 ;; 2) dir=$1 ;; *) usage ;; esac
      shift ;;
  esac
done
[ "$npos" = 2 ] && [ -n "$dir" ] || usage
case "$step" in
  '' | .* | *[!A-Za-z0-9._-]*) printf 'capture.sh: the step name must be a file name, got: %s\n' "$step" >&2; exit 2 ;;
esac

if [ -z "$have_cmd" ]; then
  if [ -n "$file" ]; then
    conf=$("$SCRIPT_DIR/config.sh" show --file "$file") || exit 1
  else
    conf=$("$SCRIPT_DIR/config.sh" show) || exit 1
  fi
  cmd=$(jq -r '.capture_command // empty' <<<"$conf")
fi
if [ -z "$cmd" ]; then
  echo "capture.sh: no capture_command recorded; project setup records one" >&2
  exit 16
fi

mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)

# What the folder holds now, by checksum, so a recapture that overwrites the
# same file still counts.
snapshot() { (cd "$dir" && find . -type f -print0 | xargs -0 cksum 2>/dev/null | sort) || true; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/artisan-capture.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
snapshot >"$tmp/before"
st=0
(cd "$root" && ARTISAN_CAPTURE_STEP=$step ARTISAN_CAPTURE_DIR=$dir bash -c "$cmd") >"$tmp/out" 2>&1 </dev/null || st=$?
if [ "$st" != 0 ]; then
  die "the capture command exited $st: $cmd
$(tail -n 20 "$tmp/out")"
fi
snapshot >"$tmp/after"

# Lines of "after" not in "before" are the files written: "<sum> <size> ./<path>".
captured=$(comm -13 "$tmp/before" "$tmp/after" | sed -E 's#^[0-9]+ [0-9]+ \./##')
if [ -n "$captured" ]; then
  printf '%s\n' "$captured" | sed "s#^#$dir/#"
  exit 0
fi
if [ -s "$tmp/out" ]; then
  { printf '$ %s\n' "$cmd"; cat "$tmp/out"; } >"$dir/$step.txt"
  printf '%s\n' "$dir/$step.txt"
  exit 0
fi
die "the capture command captured nothing: it wrote no file into $dir and printed no output: $cmd"
