#!/usr/bin/env bash
# Machine-level setup for /artisan-agent:setup. Run once per machine; a rerun changes nothing.
#
#   machine-setup.sh init           create the individual home, set marketplace auto-update
#   machine-setup.sh scan           list removal offers, one per line: ID<TAB>KIND<TAB>description
#   machine-setup.sh remove ID...   apply only the offers the Artisan said yes to
#   machine-setup.sh check          report any missing tool the pipeline's scripts need (jq, perl)
#   machine-setup.sh merge-gate [auto|local|ci]
#                                   this machine's merge gate (#139), in host.json in the individual
#                                   home: with no argument, print it as merge-gate.sh resolves it; with
#                                   one, record it (other keys kept). auto (the default) is local on
#                                   macOS and ci on Linux: where the full suite runs after each merge
#   machine-setup.sh merge-batch [on|off]
#                                   whether ready tickets merge as one batch (#167, #180), merge_batch
#                                   in host.json beside merge_gate: with no argument, print the
#                                   setting and its source (host.json, ARTISAN_MERGE_BATCH or default)
#                                   as JSON; with one, record it (other keys kept; a rerun changes nothing)
#
# Everything lives under CLAUDE_CONFIG_DIR (default $HOME/.claude). Nothing is deleted:
# skill copies move to $CFG/skills/.trash. ARTISAN_CLAUDE_BIN overrides the claude binary.
# Portable to bash 3.2.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PLUGINS=${CLAUDE_CODE_PLUGIN_CACHE_DIR:-$CFG/plugins}
HOME_DIR=$CFG/artisan-agent
TRASH=$CFG/skills/.trash
CLAUDE_BIN=${ARTISAN_CLAUDE_BIN:-claude}
PERSONAL_PLUGIN_SKILLS="implement-plan debate-me"

json() { python3 -I "$HERE/machine_json.py" "$@"; }

upstream_names() {
  {
    grep -v '^#' "$HERE/../upstream-skills.txt" 2>/dev/null || true
    local f=
    for f in "$PLUGINS"/cache/claude-plugins-official/mattpocock-skills/*/skills/*/SKILL.md \
             "$PLUGINS"/cache/claude-plugins-official/mattpocock-skills/*/skills/*/*/SKILL.md; do
      if [ -f "$f" ]; then basename "$(dirname "$f")"; fi
    done
  } | sort -u
}

# jq: classify-worker.sh reads worker output with it. perl: macOS has no setsid, so the worker
# runner detaches with perl. Prints one "missing:" line per absent tool; non-zero if any.
cmd_check() {
  local missing=0
  if ! command -v jq >/dev/null 2>&1; then
    echo "missing: jq - needed by scripts/classify-worker.sh to read worker output; install it (macOS: brew install jq; Debian/Ubuntu: apt install jq)"
    missing=1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    echo "missing: perl - needed on macOS to detach workers (macOS has no setsid); install it (Debian/Ubuntu: apt install perl; macOS ships it, so check PATH)"
    missing=1
  fi
  [ "$missing" = 1 ] || echo "ok: jq and perl are available"
  return "$missing"
}

standards_file() { # title
  printf '# %s\n\nIndividual level: these follow the Artisan into every project. Product and team standards win a contradiction.\n\n## Always ask\n\nThings that must always come back to the Artisan.\n' "$1"
}

cmd_init() {
  local f= path= paths="" ident="" did=0 tools_rc=0
  cmd_check || tools_rc=1   # report now, still set up; the exit status stays non-zero at the end
  mkdir -p "$HOME_DIR"
  for f in CODING_STANDARDS.md PRODUCT_STANDARDS.md satisfaction.jsonl; do
    path=$HOME_DIR/$f
    [ -e "$path" ] && continue
    case $f in
      satisfaction.jsonl) : >"$path" ;;
      *) standards_file "Individual $(printf %s "${f%.md}" | tr "A-Z_" "a-z ")" >"$path" ;;
    esac
    paths="$paths $f"
  done
  if [ ! -d "$HOME_DIR/.git" ]; then
    git -C "$HOME_DIR" init -q
    git -C "$HOME_DIR" symbolic-ref HEAD refs/heads/main
    echo "changed: git repo created at $HOME_DIR"
    did=1
  fi
  if [ -n "$paths" ]; then
    # Commit only the files setup created, never the Artisan's own uncommitted edits.
    { git -C "$HOME_DIR" config user.name && git -C "$HOME_DIR" config user.email; } >/dev/null 2>&1 || ident="-c user.name=Artisan-Agent -c user.email=artisan-agent@localhost"
    # shellcheck disable=SC2086
    git -C "$HOME_DIR" add -- $paths
    # shellcheck disable=SC2086
    git -C "$HOME_DIR" $ident commit -q -m "Artisan Agent: individual home" -- $paths
    echo "changed: created$paths in $HOME_DIR"
    did=1
  fi
  [ "$did" = 1 ] || echo "unchanged: individual home $HOME_DIR"
  json autoupdate "$CFG"
  [ "$tools_rc" = 0 ] || echo "setup finished, but jq or perl is missing (see above); install it before running workers" >&2
  return "$tools_rc"
}

# The merge gate is the machine's choice, so it lives in host.json beside the
# host record, never in the individual home's git history.
cmd_merge_gate() {
  local want="${1:-}" f="$HOME_DIR/host.json" tmp=
  if [ -z "$want" ]; then "$HERE/../../../scripts/merge-gate.sh" show; return; fi
  case "$want" in auto | local | ci) ;; *) echo "merge_gate must be auto, local or ci, not \"$want\"" >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "missing: jq"; return 1; }
  mkdir -p "$HOME_DIR"
  if [ -f "$f" ] && [ "$(jq -r '.merge_gate // ""' "$f")" = "$want" ]; then
    echo "unchanged: merge_gate is $want in $f"
    return 0
  fi
  tmp="$f.tmp.$$"
  { if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; } | jq --arg m "$want" '.merge_gate = $m' >"$tmp" && mv -f "$tmp" "$f"
  echo "changed: merge_gate is $want in $f"
}

cmd_merge_batch() {
  local want="${1:-}" f="$HOME_DIR/host.json" tmp=
  if [ -z "$want" ]; then
    "$HERE/../../../scripts/merge-gate.sh" show | jq -c '{batch, source: .batch_source}'
    return
  fi
  command -v jq >/dev/null 2>&1 || { echo "missing: jq"; return 1; }
  mkdir -p "$HOME_DIR"
  if [ -f "$f" ] && [ "$(jq -r '.merge_batch // ""' "$f")" = "$want" ]; then
    echo "unchanged: merge_batch is $want in $f"
    return 0
  fi
  tmp="$f.tmp.$$"
  { if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; } | jq --arg m "$want" '.merge_batch = $m' >"$tmp" && mv -f "$tmp" "$f"
  echo "changed: merge_batch is $want in $f"
}

cmd_scan() {
  local up= name= pid= scope= ppath= ver= value=
  up=$(upstream_names)
  json installs "$CFG" | while IFS=$'\037' read -r pid scope ppath ver; do
    printf 'project-install:%s:%s:%s\tproject-install\t%s %s-scope install (version %s) at %s; projects should only enable it\n' \
      "$pid" "$scope" "$ppath" "$pid" "$scope" "$ver" "$ppath"
  done
  if [ -d "$CFG/skills" ]; then
    for name in $PERSONAL_PLUGIN_SKILLS; do
      if [ -e "$CFG/skills/$name" ]; then printf 'plugin-skill:%s\tpersonal-plugin-skill\tpersonal %s; now ships in the artisan-agent plugin\n' "$name" "$name"; fi
    done
    for name in $up; do
      if [ -e "$CFG/skills/$name" ]; then printf 'stale-skill:%s\tstale-upstream-skill\tpersonal copy of upstream skill %s\n' "$name" "$name"; fi
    done
  fi
  # shellcheck disable=SC2086
  json overrides "$CFG" $up $PERSONAL_PLUGIN_SKILLS | while IFS=$'\t' read -r name value; do
    printf 'override:%s\thiding-override\tskillOverrides "%s": "%s" only hides a skill being replaced\n' "$name" "$name" "$value"
  done
  return 0
}

trash_skill() {
  local name=$1 dest=
  [ -e "$CFG/skills/$name" ] || { echo "skipped: $name is already gone"; return 0; }
  mkdir -p "$TRASH"
  dest=$TRASH/$name.$(date +%Y%m%d%H%M%S)
  [ -e "$dest" ] && dest=$dest.$$
  mv "$CFG/skills/$name" "$dest"
  echo "moved to trash: $name -> $dest"
}

# The claude CLI finds a project-scope install by the current directory, so the uninstall must
# run inside the project's path. When that folder is gone, recreate it (only the missing
# levels), run the CLI's own uninstall, then remove the levels we created if still empty.
uninstall_in_project() { # plugin scope path
  local pid=$1 scope=$2 ppath=$3 d= created="" recreated=0 rc=0
  if [ ! -d "$ppath" ]; then
    d=$ppath
    while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
      created="$created$d"$'\n'   # deepest first, one per line
      d=$(dirname "$d")
    done
    mkdir -p "$ppath" || { echo "failed: cannot recreate $ppath to uninstall $pid ($scope)" >&2; return 1; }
    recreated=1
  fi
  (cd "$ppath" && CLAUDE_CONFIG_DIR=$CFG "$CLAUDE_BIN" plugin uninstall "$pid" --scope "$scope" >/dev/null) || rc=$?
  if [ "$recreated" = 1 ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      rmdir "$d" 2>/dev/null || echo "kept: $d is not empty after the uninstall" >&2
    done <<EOF_CREATED
$created
EOF_CREATED
  fi
  if [ "$rc" = 0 ]; then
    if [ "$recreated" = 1 ]; then echo "uninstalled: $pid ($scope) at $ppath (project folder was gone; recreated it for the uninstall and removed it again)"
    else echo "uninstalled: $pid ($scope) at $ppath"; fi
  else
    echo "failed: claude plugin uninstall $pid --scope $scope in $ppath" >&2
  fi
  return "$rc"
}

cmd_remove() {
  local id= kind= rest= pid= scope= ppath= status=0
  [ $# -gt 0 ] || { echo "remove: no ids given; nothing removed" >&2; return 0; }
  for id in "$@"; do
    kind=${id%%:*}
    rest=${id#*:}
    case $kind in
      stale-skill|plugin-skill) trash_skill "$rest" ;;
      override) json drop-override "$CFG" "$rest" ;;
      project-install)
        pid=${rest%%:*}; rest=${rest#*:}; scope=${rest%%:*}; ppath=${rest#*:}
        if [ -z "$ppath" ]; then
          echo "failed: $pid ($scope) has no project path in the registry; nothing to run the uninstall in" >&2
          status=1
        elif ! uninstall_in_project "$pid" "$scope" "$ppath"; then
          status=1
        fi ;;
      *) echo "unknown id: $id" >&2; status=1 ;;
    esac
  done
  return $status
}

case ${1:-} in
  init) cmd_init ;;
  check) cmd_check ;;
  scan) cmd_scan ;;
  remove) shift; cmd_remove "$@" ;;
  merge-gate) shift; [ $# -le 1 ] || { echo "usage: machine-setup.sh merge-gate [auto|local|ci]" >&2; exit 2; }; cmd_merge_gate "$@" ;;
  merge-batch)
    shift
    if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != on ] && [ "$1" != off ]; }; then
      echo "usage: machine-setup.sh merge-batch [on|off]" >&2; exit 2
    fi
    cmd_merge_batch "$@" ;;
  *) echo "usage: machine-setup.sh init|check|scan|remove ID...|merge-gate [auto|local|ci]|merge-batch [on|off]" >&2; exit 2 ;;
esac
