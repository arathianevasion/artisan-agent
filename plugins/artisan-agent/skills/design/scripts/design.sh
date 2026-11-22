#!/usr/bin/env bash
# The design stage's script (#324): start a design, list the designs in
# progress, and read one back to resume it. /artisan-agent:design runs it.
#
# Usage:
#   design.sh start --name NAME --step STEP [--step STEP]... [--designer WHO] [--no-fetch]
#   design.sh status
#   design.sh resume [#]N
#   design.sh journey --design SLUG --name NAME --persona WHO --goal G --action A --next N [--goal G --action A --next N]...
#   design.sh prototype --design SLUG --change WHAT [--model MODEL]
#   design.sh approve --design SLUG --ticket [#]N [--tool-link URL] [--no-fetch]
#
# start: picks the base: with an origin remote, fetches it and uses
#   origin/<default branch> (with --no-fetch, origin/<default branch> as last
#   fetched); with none, the local <default branch>. The default branch is
#   origin/HEAD's name, else main. A failed fetch refuses, naming its cause and
#   --no-fetch. Captures a "before" screenshot of each named journey step from
#   a checkout of the base, with the recorded capture command
#   (scripts/capture.sh), into <main checkout>/.artisan-agent/designs/<slug>/before;
#   cuts the feature branch feature/<slug> and the prototype branch
#   prototype/<slug> from the base, tracking nothing; then opens the design
#   ticket, labelled design, recording both branches, the tool link (none yet),
#   the designer (WHO, or the gh login), the journey steps, the screenshots'
#   folder and the base it was cut from (its ref and commit). It never moves
#   the main checkout or any local branch but the two it cuts. <slug> is NAME
#   in lower case, with each run of other characters a "-". A capture that fails, or a branch that
#   already exists, stops it before anything is created; so does a gh failure,
#   which deletes the branches it cut and the screenshots' folder if it made it. Prints the ticket, the
#   branches and each screenshot's path.
# status: lists the open design tickets, "#<n> <title>", one per line.
# resume: prints design ticket N's branches, links, designer, steps and
#   screenshots' folder, one "<field>: <value>" per line.
#
# journey: writes one user journey file, journeys/<journey slug>.md, on the
#   feature branch feature/<SLUG> only, and commits it there. The file names
#   its persona and lists the ordered steps given, each with its goal, what
#   the user does and sees (action) and where they go next. A --goal starts a
#   step; the --action and --next after it belong to it. Give only the steps
#   the change touches: on a product with no journeys the folder starts with
#   those, and the file written again replaces the steps it had. It works in a
#   temporary checkout of the feature branch, so the main checkout, the local
#   default branch and every other branch stay as they were: the journeys on
#   main change only when the feature merges. Prints the file's path in the
#   repo and the commit. The file's shape:
#     # Journey: <name>
#     **Persona:** <persona>
#     ## Steps
#     ### 1. <goal>
#     - **Goal:** <goal>
#     - **Action:** <what the user does and sees>
#     - **Next:** <where they go next>
#
# prototype: dispatches a headless prototype worker (claude -p, detached, in
#   its own session, ARTISAN_ROLE=prototype) to build WHAT on the prototype
#   branch prototype/<SLUG>, in its own worktree, <main checkout>-wt/prototype-<SLUG>
#   (made if missing, reused if it is already on that branch). The worker never
#   runs on the feature branch or main, and the prototype branch is never
#   merged. Its brief, written to
#   <main checkout>/.artisan-agent/designs/<SLUG>/prototype-brief.md, names the
#   product's real components as its building blocks: the pointers under
#   "Where the design system lives" in each design standards file in force
#   (guardrails.sh design), product first. With none recorded it warns on
#   stderr and the brief says to use the components already in the code.
#   Refuses while the last worker it dispatched for SLUG is still running.
#   Prints the worktree, the branch, the brief, the worker's pid and its log.
#
# approve: records the design package on design ticket N, as a comment: the
#   journey diff (the journey files' change from the base the design was cut
#   from, on feature/<SLUG>), a screenshot per journey step the ticket lists
#   (read from journeys/screenshots/<step>.<ext> on the feature branch, beside
#   the journey files: nothing is copied or committed at approval), the
#   prototype (its branch, when it has commits of its own; else none) and the
#   tool link (--tool-link, else the ticket's own, else none). A design with no
#   prototype and no tool link approves on its screenshots alone. Refuses (1)
#   while a step has no screenshot on the feature branch, and while the
#   prototype branch is behind the default branch (origin/<it> after a fetch,
#   unless --no-fetch; the local one with no origin), naming the rebase. Prints
#   what it recorded.
#
# Runs in the product repo (any checkout of it). GH_BIN stands in for gh;
# ARTISAN_CLAUDE_BIN for claude.
# Exit status: 0 done; 1 failed (why on stderr); 2 bad usage; 16 no
# capture_command recorded (project setup records one).
# (journey: exit 1 when the feature branch is missing or checked out elsewhere.)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
tmp= # the capture worktree's parent; global for the EXIT trap
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
GH=${GH_BIN:-gh}
CLAUDE=${ARTISAN_CLAUDE_BIN:-claude}
PROTOTYPE_TOOLS="Read,Edit,Write,Glob,Grep,Bash"
# shellcheck source=../../../scripts/lib/detach-lib.sh
. "$PLUGIN_ROOT/scripts/lib/detach-lib.sh"
# shellcheck source=../../../scripts/lib/headless-lib.sh
. "$PLUGIN_ROOT/scripts/lib/headless-lib.sh"
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
  local name= designer= no_fetch= base= sha= cut= err= steps=() slug= main= feature= proto= root= before= made_before= st=0 s= body= url=
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
      --step) [ $# -ge 2 ] || usage; steps+=("$2"); shift 2 ;;
      --designer) [ $# -ge 2 ] || usage; designer=$2; shift 2 ;;
      --no-fetch) no_fetch=1; shift ;;
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
  if git remote get-url origin >/dev/null 2>&1; then
    # A design starts from prod: origin, fetched now, not a local main that may lag.
    base="origin/$main"
    if [ -z "$no_fetch" ]; then
      err=$(git fetch -q origin 2>&1) || die "fetching origin failed, so $base may be stale: $(printf '%s' "$err" | tr '\n' ' ')
Retry when origin is reachable, or pass --no-fetch to start from $base as last fetched."
    fi
  else
    base=$main
  fi
  sha=$(git rev-parse --verify -q "$base^{commit}") || die "no $base to cut the design from"
  cut="\`$base\` at $sha"
  [ -z "$no_fetch" ] || [ "$base" = "$main" ] || cut="$cut, as last fetched (--no-fetch)"
  for s in "$feature" "$proto"; do
    has_branch "$s" && die "branch $s already exists: resume that design, or pick another name"
  done
  [ -n "$designer" ] || designer=$("$GH" api user --jq .login) || die "no --designer given, and gh api user failed"
  [ -n "$designer" ] || die "no --designer given, and gh named no login"

  root=$(main_root)
  before="$root/.artisan-agent/designs/$slug/before"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/artisan-design.XXXXXX")
  trap 'git worktree remove --force "$tmp/main" >/dev/null 2>&1 || true; rm -rf "$tmp"; git worktree prune >/dev/null 2>&1 || true' EXIT
  git worktree add -q --detach "$tmp/main" "$sha" || die "could not check out $base to capture from"
  # Into a scratch folder first, so a failed step leaves no half-filled one.
  for s in "${steps[@]}"; do
    (cd "$tmp/main" && "$PLUGIN_ROOT/scripts/capture.sh" "$s" "$tmp/before" >/dev/null) || {
      st=$?
      printf 'design.sh: capturing step %s from %s failed (capture.sh exit %s)\n' "$s" "$base" "$st" >&2
      exit "$st"
    }
  done
  [ -e "$before" ] || made_before=1
  mkdir -p "$before"
  cp -R "$tmp/before/." "$before/"

  git branch --no-track "$feature" "$sha"
  git branch --no-track "$proto" "$sha"

  body=$(printf 'A design in progress, started with /artisan-agent:design.\n\n- **Feature branch:** `%s`\n- **Prototype branch:** `%s`\n- **Tool link:** none yet\n- **Designer:** %s\n- **Journey steps:** %s\n- **Before screenshots:** `%s`\n- **Cut from:** %s\n' \
    "$feature" "$proto" "$designer" "$(IFS=,; printf '%s' "${steps[*]}" | sed 's/,/, /g')" "$before" "$cut")
  url=$(printf '%s' "$body" | "$GH" issue create --title "Design: $name" --body-file - --label "$LABEL") || {
    git branch -D -q "$feature" "$proto" || true
    if [ -n "$made_before" ]; then rm -rf "$before"; rmdir "$(dirname "$before")" 2>/dev/null || true; fi
    die "gh issue create failed; the branches and screenshots are removed, start again"
  }
  (cd "$before" && find . -type f | sed 's#^\./##' | sort) | while IFS= read -r f; do printf '%s/%s\n' "$before" "$f"; done
  printf 'design ticket: #%s\n' "${url##*/}"
  printf 'feature branch: %s\nprototype branch: %s\n' "$feature" "$proto"
}

# One journey file on the feature branch, written in a throwaway checkout of it.
cmd_journey() {
  local slug= name= persona= goals=() actions=() nexts=() i= jslug= file= body= wt= sha=
  while [ $# -gt 0 ]; do
    case "$1" in
      --design) [ $# -ge 2 ] || usage; slug=$2; shift 2 ;;
      --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
      --persona) [ $# -ge 2 ] || usage; persona=$2; shift 2 ;;
      --goal) [ $# -ge 2 ] || usage; goals+=("$2"); actions+=(""); nexts+=(""); shift 2 ;;
      --action) [ $# -ge 2 ] && [ "${#goals[@]}" -gt 0 ] || usage; actions[${#goals[@]}-1]=$2; shift 2 ;;
      --next) [ $# -ge 2 ] && [ "${#goals[@]}" -gt 0 ] || usage; nexts[${#goals[@]}-1]=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$name" ] && [ -n "$persona" ] && [ "${#goals[@]}" -gt 0 ] || usage
  for i in "${!goals[@]}"; do
    [ -n "${goals[$i]}" ] && [ -n "${actions[$i]}" ] && [ -n "${nexts[$i]}" ] || {
      printf 'design.sh: step %s needs a goal, an action and a next step\n' "$((i + 1))" >&2; exit 2
    }
  done
  jslug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$jslug" ] || die "the journey's name needs a letter or digit: $name"
  has_branch "feature/$slug" || die "no feature branch feature/$slug: start the design first"
  file="journeys/$jslug.md"
  body=$(printf '# Journey: %s\n\n**Persona:** %s\n\n## Steps\n' "$name" "$persona")
  for i in "${!goals[@]}"; do
    body+=$(printf '\n\n### %s. %s\n- **Goal:** %s\n- **Action:** %s\n- **Next:** %s' \
      "$((i + 1))" "${goals[$i]}" "${goals[$i]}" "${actions[$i]}" "${nexts[$i]}")
  done
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/artisan-design.XXXXXX")
  trap 'git worktree remove --force "$tmp/feature" >/dev/null 2>&1 || true; rm -rf "$tmp"; git worktree prune >/dev/null 2>&1 || true' EXIT
  wt="$tmp/feature"
  git worktree add -q "$wt" "feature/$slug" || die "could not check out feature/$slug (is it checked out elsewhere?)"
  mkdir -p "$wt/journeys"
  printf '%s\n' "$body" >"$wt/$file"
  git -C "$wt" add -- "$file"
  if git -C "$wt" diff --cached --quiet; then
    printf 'journey file: %s\nfeature branch: feature/%s\nunchanged\n' "$file" "$slug"
    return
  fi
  git -C "$wt" commit -q -m "Journey: $name (design $slug)" || die "committing $file on feature/$slug failed"
  sha=$(git -C "$wt" rev-parse --short HEAD)
  printf 'journey file: %s\nfeature branch: feature/%s\ncommit: %s\n' "$file" "$slug" "$sha"
}

# The design system pointers in force: the list lines under "Where the design
# system lives" in each level's design standards, product first.
design_pointers() {
  local json= f=
  json=$("$PLUGIN_ROOT/scripts/guardrails.sh" design) || return 0
  jq -r '.files[] | "\(.dir)\t\(.commit)\t\(.path)"' <<<"$json" | while IFS=$'\t' read -r d c f; do
    git -C "$d" show "$c:$f" 2>/dev/null \
      | awk '/^## /{on = ($0 ~ /^## Where the design system lives/); next} on && /^[-*] /'
  done
}

# A headless worker builds the prototype on the prototype branch, in its own worktree.
cmd_prototype() {
  local slug= change= model= branch= root= wt= at= pointers= dir= brief= pid= log= runner=
  while [ $# -gt 0 ]; do
    case "$1" in
      --design) [ $# -ge 2 ] || usage; slug=$2; shift 2 ;;
      --change) [ $# -ge 2 ] || usage; change=$2; shift 2 ;;
      --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$change" ] || usage
  branch="prototype/$slug"
  has_branch "$branch" || die "no prototype branch $branch: start the design first"
  root=$(main_root)
  wt="$(dirname "$root")/$(basename "$root")-wt/prototype-$slug"
  if [ -e "$wt" ]; then
    at=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null) || at=
    [ "$at" = "$branch" ] || die "$wt exists but is not a checkout of $branch: move it, then dispatch again"
  else
    mkdir -p "$(dirname "$wt")"
    git worktree add -q "$wt" "$branch" || die "could not check out $branch into $wt (is it checked out elsewhere?)"
  fi
  [ "$(git -C "$wt" symbolic-ref -q --short HEAD)" = "$branch" ] || die "$wt is not on $branch; refusing to dispatch"

  pointers=$(design_pointers)
  [ -n "$pointers" ] || printf 'design.sh: no design system pointer is recorded under "Where the design system lives" in DESIGN_STANDARDS.md; the worker will use the components it finds in the code\n' >&2
  dir="$root/.artisan-agent/designs/$slug"
  mkdir -p "$dir"
  brief="$dir/prototype-brief.md" log="$dir/prototype.log"
  {
    printf '# Prototype worker: design %s\n\n' "$slug"
    printf 'Build a functional prototype of this change: %s\n\n' "$change"
    printf '## Where you work\n\n'
    printf -- '- Only in this worktree, `%s`, on the prototype branch `%s`. Commit there.\n' "$wt" "$branch"
    printf -- '- Never switch branch, and never touch the feature branch `feature/%s` or the default branch. Never merge or push: the prototype branch is never merged.\n\n' "$slug"
    printf '## Build it from the real components\n\n'
    printf 'Make the prototype as close to prod as you can: build it from the product'"'"'s real components, the design system the design standards point to, not mock-ups or new look-alikes.\n\n'
    if [ -n "$pointers" ]; then
      printf 'The design system (from DESIGN_STANDARDS.md, "Where the design system lives"):\n\n%s\n\n' "$pointers"
    else
      printf 'No design system pointer is recorded in DESIGN_STANDARDS.md: use the components already in the code.\n\n'
    fi
    printf 'For a CLI, the prototype is the commands working on this branch.\n\n'
    printf 'When it works, end with what you built, how to try it, and what you faked.\n'
  } >"$brief"

  headless_args "$PROTOTYPE_TOOLS"
  runner=(env ARTISAN_ROLE=prototype "$CLAUDE" -p "$(cat "$brief")" "${HEADLESS_ARGS[@]}")
  [ -z "$model" ] || runner+=(--model "$model")
  if [ -s "$dir/prototype.pid" ] && kill -0 "$(cat "$dir/prototype.pid")" 2>/dev/null; then
    die "the prototype worker for $slug is still running (pid $(cat "$dir/prototype.pid")): let it finish or stop it, then dispatch again"
  fi
  rm -f "$dir/prototype.pid"
  pid=$(detach_start "$dir/prototype.pid" "$log" bash -c 'echo $$ >"$1.tmp" && mv "$1.tmp" "$1"; cd "$2" || exit 1; shift 2; exec "$@"' \
    _ "$dir/prototype.pid" "$wt" "${runner[@]}") || die "the prototype worker did not start; see $log"
  printf 'worktree: %s\nprototype branch: %s\nbrief: %s\nworker pid: %s\nlog: %s\n' "$wt" "$branch" "$brief" "$pid" "$log"
}

# The design package, recorded on the design ticket.
cmd_approve() {
  local slug= n= tool= no_fetch= json= base= main= feature= proto= cut= err= steps= s= shots= f= diff= prototype= body= tl= missing=
  while [ $# -gt 0 ]; do
    case "$1" in
      --design) [ $# -ge 2 ] || usage; slug=$2; shift 2 ;;
      --ticket) [ $# -ge 2 ] || usage; n=${2#\#}; shift 2 ;;
      --tool-link) [ $# -ge 2 ] || usage; tool=$2; shift 2 ;;
      --no-fetch) no_fetch=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$n" ] || usage
  case "$n" in *[!0-9]*) usage ;; esac
  feature="feature/$slug" proto="prototype/$slug"
  has_branch "$feature" || die "no feature branch $feature: start the design first"
  json=$("$GH" issue view "$n" --json number,title,body,labels) || die "gh issue view $n failed"
  jq -e --arg l "$LABEL" 'any(.labels[]; .name == $l)' <<<"$json" >/dev/null || die "#$n is not a design ticket (no $LABEL label)"
  body=$(jq -r .body <<<"$json")
  steps=$(printf '%s\n' "$body" | sed -nE 's/^- \*\*Journey steps:\*\* (.*)$/\1/p' | head -1 | tr ',' '\n' | sed 's/^ *//; s/ *$//')
  [ -n "$steps" ] || die "#$n records no journey steps"
  cut=$(printf '%s\n' "$body" | sed -nE 's/^- \*\*Cut from:\*\* `[^`]*` at ([0-9a-f]+).*$/\1/p' | head -1)
  [ -n "$cut" ] || die "#$n records no base it was cut from"

  # The prototype must reflect current prod.
  main=$(main_branch)
  if git remote get-url origin >/dev/null 2>&1; then
    base="origin/$main"
    if [ -z "$no_fetch" ]; then
      err=$(git fetch -q origin 2>&1) || die "fetching origin failed, so $base may be stale: $(printf '%s' "$err" | tr '\n' ' ')
Retry when origin is reachable, or pass --no-fetch to check against $base as last fetched."
    fi
  else
    base=$main
  fi
  git rev-parse --verify -q "$base^{commit}" >/dev/null || die "no $base to compare the prototype with"
  if has_branch "$proto" && [ "$(git rev-list --count "$base..$proto")" -gt 0 ]; then
    git merge-base --is-ancestor "$base" "$proto" \
      || die "the prototype branch $proto is behind $base: rebase it on $base (git rebase $base $proto in its worktree), then approve again"
    prototype="\`$proto\`"
  else
    prototype=none
  fi

  # A screenshot per changed step, on the feature branch beside the journeys.
  while IFS= read -r s; do
    f=$(git ls-tree -r --name-only "$feature" -- journeys/screenshots | grep -E "^journeys/screenshots/$s\.[A-Za-z0-9]+$" | head -1 || true)
    [ -n "$f" ] || missing="$missing $s"
    shots+="  - \`$s\`: \`$f\` on \`$feature\`"$'\n'
  done <<<"$steps"
  [ -z "$missing" ] || die "no screenshot on $feature for step(s):$missing; commit them to journeys/screenshots/<step>.<ext> beside the journey files, then approve again"

  diff=$(git diff --stat "$cut" "$feature" -- journeys ':!journeys/screenshots')
  [ -n "$diff" ] || diff="no journey file differs from the base"
  tl=${tool:-$(printf '%s\n' "$body" | sed -nE 's/^- \*\*Tool link:\*\* (.*)$/\1/p' | head -1)}
  case "$tl" in '' | 'none yet') tl=none ;; esac

  body=$(printf '**Design package: approved**\n\n- **Journey diff:** `%s` from `%s`\n\n```\n%s\n```\n\n- **Screenshots:**\n%s\n- **Prototype:** %s\n- **Tool link:** %s\n' \
    "$feature" "$cut" "$diff" "$shots" "$prototype" "$tl")
  printf '%s' "$body" | "$GH" issue comment "$n" --body-file - >/dev/null || die "gh issue comment $n failed"
  printf 'design package recorded on #%s\n%s\n' "$n" "$body"
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
  journey) cmd_journey "$@" ;;
  prototype) cmd_prototype "$@" ;;
  approve) cmd_approve "$@" ;;
  resume) cmd_resume "$@" ;;
  *) usage ;;
esac
