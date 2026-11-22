#!/usr/bin/env bash
# The design stage's script (#324): start a design, list the designs in
# progress, and read one back to resume it. /artisan-agent:design runs it.
#
# Usage:
#   design.sh start --name NAME --step STEP [--step STEP]... [--designer WHO]
#   design.sh status
#   design.sh resume [#]N
#
# start: captures a "before" screenshot of each named journey step from a
#   checkout of main, with the recorded capture command (scripts/capture.sh),
#   into <main checkout>/.artisan-agent/designs/<slug>/before; cuts the feature
#   branch feature/<slug> and the prototype branch prototype/<slug> from main;
#   then opens the design ticket, labelled design, recording both branches,
#   the tool link (none yet), the designer (WHO, or the gh login), the journey
#   steps and the screenshots' folder. <slug> is NAME in lower case, with each
#   run of other characters a "-". A capture that fails, or a branch that
#   already exists, stops it before anything is created; so does a gh failure,
#   which deletes the branches it cut and the screenshots' folder if it made it. Prints the ticket, the
#   branches and each screenshot's path.
# status: lists the open design tickets, "#<n> <title>", one per line.
# resume: prints design ticket N's branches, links, designer, steps and
#   screenshots' folder, one "<field>: <value>" per line.
#
# Runs in the product repo (any checkout of it). GH_BIN stands in for gh.
# Exit status: 0 done; 1 failed (why on stderr); 2 bad usage; 16 no
# capture_command recorded (project setup records one).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
tmp= # the capture worktree's parent; global for the EXIT trap
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
GH=${GH_BIN:-gh}
LABEL=design

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'design.sh: %s\n' "$*" >&2; exit 1; }

main_branch() {
  local h=
  h=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && { printf '%s\n' "${h#origin/}"; return; }
  printf 'main\n'
}

# The main checkout's root, from any worktree of the repo.
main_root() {
  local common=
  common=$(git rev-parse --path-format=absolute --git-common-dir) || die "not in a git repo"
  dirname "$common"
}

has_branch() { git rev-parse --verify -q "refs/heads/$1" >/dev/null; }

cmd_start() {
  local name= designer= steps=() slug= main= feature= proto= root= before= made_before= st=0 s= body= url=
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
      --step) [ $# -ge 2 ] || usage; steps+=("$2"); shift 2 ;;
      --designer) [ $# -ge 2 ] || usage; designer=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$name" ] && [ "${#steps[@]}" -gt 0 ] || usage
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$slug" ] || die "the design's name needs a letter or digit: $name"
  for s in "${steps[@]}"; do # capture.sh's rule, checked before anything runs
    case "$s" in
      '' | .* | *[!A-Za-z0-9._-]*) printf 'design.sh: a step name must be a file name, got: %s\n' "$s" >&2; exit 2 ;;
    esac
  done
  feature="feature/$slug" proto="prototype/$slug"
  main=$(main_branch)
  has_branch "$main" || die "no $main branch to cut the design from"
  for s in "$feature" "$proto"; do
    has_branch "$s" && die "branch $s already exists: resume that design, or pick another name"
  done
  [ -n "$designer" ] || designer=$("$GH" api user --jq .login) || die "no --designer given, and gh api user failed"
  [ -n "$designer" ] || die "no --designer given, and gh named no login"

  root=$(main_root)
  before="$root/.artisan-agent/designs/$slug/before"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/artisan-design.XXXXXX")
  trap 'git worktree remove --force "$tmp/main" >/dev/null 2>&1 || true; rm -rf "$tmp"; git worktree prune >/dev/null 2>&1 || true' EXIT
  git worktree add -q --detach "$tmp/main" "$main" || die "could not check out $main to capture from"
  # Into a scratch folder first, so a failed step leaves no half-filled one.
  for s in "${steps[@]}"; do
    (cd "$tmp/main" && "$PLUGIN_ROOT/scripts/capture.sh" "$s" "$tmp/before" >/dev/null) || {
      st=$?
      printf 'design.sh: capturing step %s from %s failed (capture.sh exit %s)\n' "$s" "$main" "$st" >&2
      exit "$st"
    }
  done
  [ -e "$before" ] || made_before=1
  mkdir -p "$before"
  cp -R "$tmp/before/." "$before/"

  git branch "$feature" "$main"
  git branch "$proto" "$main"

  body=$(printf 'A design in progress, started with /artisan-agent:design.\n\n- **Feature branch:** `%s`\n- **Prototype branch:** `%s`\n- **Tool link:** none yet\n- **Designer:** %s\n- **Journey steps:** %s\n- **Before screenshots:** `%s`\n' \
    "$feature" "$proto" "$designer" "$(IFS=,; printf '%s' "${steps[*]}" | sed 's/,/, /g')" "$before")
  url=$(printf '%s' "$body" | "$GH" issue create --title "Design: $name" --body-file - --label "$LABEL") || {
    git branch -D -q "$feature" "$proto" || true
    if [ -n "$made_before" ]; then rm -rf "$before"; rmdir "$(dirname "$before")" 2>/dev/null || true; fi
    die "gh issue create failed; the branches and screenshots are removed, start again"
  }
  (cd "$before" && find . -type f | sed 's#^\./##' | sort) | while IFS= read -r f; do printf '%s/%s\n' "$before" "$f"; done
  printf 'design ticket: #%s\n' "${url##*/}"
  printf 'feature branch: %s\nprototype branch: %s\n' "$feature" "$proto"
}

cmd_status() {
  [ $# -eq 0 ] || usage
  local out=
  out=$("$GH" issue list --state open --label "$LABEL" --limit 200 --json number,title \
    --jq '.[] | "#\(.number) \(.title)"') || die "gh issue list failed"
  if [ -z "$out" ]; then echo "no designs in progress"; else printf '%s\n' "$out"; fi
}

cmd_resume() {
  [ $# -eq 1 ] || usage
  local n=${1#\#} json=
  case "$n" in '' | *[!0-9]*) usage ;; esac
  json=$("$GH" issue view "$n" --json number,title,body,labels) || die "gh issue view $n failed"
  jq -e --arg l "$LABEL" 'any(.labels[]; .name == $l)' <<<"$json" >/dev/null || die "#$n is not a design ticket (no $LABEL label)"
  jq -r '"design: #\(.number) \(.title)"' <<<"$json"
  # Each "- **Field:** value" line of the body, as "field: value" without backticks.
  jq -r .body <<<"$json" | sed -nE 's/^- \*\*([^*]+):\*\* (.*)$/\1: \2/p' | tr -d '`' \
    | awk -F': ' '{ printf "%s: ", tolower($1); sub(/^[^:]*: /, ""); print }'
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
  start) cmd_start "$@" ;;
  status) cmd_status "$@" ;;
  resume) cmd_resume "$@" ;;
  *) usage ;;
esac
