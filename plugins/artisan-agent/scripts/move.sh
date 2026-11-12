#!/usr/bin/env bash
# Move a run between machines (laptop <-> always-on host), once it is idle.
# The rules and the reasons: ${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/host-and-move.md
#
# Usage:
#   move.sh drain <run-dir>
#       stop new waves: halt the run for a move (wave.sh launch is refused, 12,
#       until it is moved or `wave.sh launch --resume`). Safe to repeat.
#   move.sh idle <run-dir>
#       exit 0 if nothing is running (no ticket in flight, no live runner, no
#       other live holder of the run lock); else exit 4 and say what is
#   move.sh out <run-dir> [--remote NAME] [--wait SECONDS]
#       wait up to SECONDS (default 0) for idle, then push the integration
#       branch, the run's unmerged ticket branches and the run's state folder
#       to the runs/<run-id> branch (the folder is git-ignored, so the branch
#       carries it as a snapshot commit on top of the integration tip). The
#       run's `location` becomes "moved" here first (push pending), then the
#       run branch is pushed: a refused push puts this copy back to live, and
#       a death in between is finished or undone by running `out` again. At
#       no instant are two copies live; until `in` the run is live nowhere.
#   move.sh in <run-id> [--remote NAME]
#       from a clone of the same repo: fetch runs/<run-id>, put the state
#       folder, the integration branch (with its worktree) and the ticket
#       branches in place and claim the run by pushing one commit on top of
#       runs/<run-id>. The push is fast-forward only, so of two machines
#       resuming at once exactly one wins. Prints the run folder. Resume
#       with /artisan-agent:implement-plan as for any open run.
#   move.sh where <run-dir>
#       print "<live|draining|moved> <machine>" (live here with no move ever: "live <this machine>")
#
# `location` in the state file: {status: moved|live, machine, branch, commit?, at}.
# state-lib.sh refuses every lock (so every write) on a run whose location is
# "moved", or is live on another machine: the lock travels with the state.
# ARTISAN_MACHINE names this machine (default hostname -s).
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the run is not live here, 4 not idle,
# 5 the run is live on another machine, or not moved (nothing to resume),
# 6 a push was refused (someone else moved or claimed the run first).
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "move.sh: $*"; }

GIT_ID="-c user.name=Artisan-Agent -c user.email=artisan-agent@localhost"
main_of() { # any path inside a repo -> its main checkout
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository: $1"
  dirname "$common"
}

get() { jq -r "$1" "$(state_file "$RUN_DIR")"; }

# ---------------------------------------------------------------- idle

idle_report() { # run-dir: prints what is still running, one line each
  local rd="$1" f pid holder me
  jq -r '.tickets | to_entries[] | select(.value.status == "in_flight") | "ticket #\(.key) is in flight"' "$(state_file "$rd")"
  for f in "$rd"/workers/*/runner.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    state_pid_alive "$pid" && printf 'session %s is still running (pid %s)\n' "$(basename "$(dirname "$f")")" "$pid"
  done
  holder=$(state_lock_holder "$rd")
  me=$(state_writer_pid)
  if [ -n "$holder" ] && [ "$holder" != "$me" ] && [ "$holder" != "$PPID" ] && state_pid_alive "$holder"; then
    printf 'the run lock is held by pid %s\n' "$holder"
  fi
  return 0
}

cmd_idle() {
  local out
  state_require_run_dir "$1"
  out=$(idle_report "$1")
  [ -z "$out" ] || { printf '%s\n' "$out"; exit 4; }
}

cmd_drain() {
  local rd="$1"
  state_require_run_dir "$rd"
  state_with_lock "$rd" state_apply "$rd" "$STATE_JQ_DEFS"'
    if .halted != null then .
    else .halted = {wave: current_wave, tickets: [], reason: "draining to move to another machine", at: $now, move: true}
      | event({event: "halted", wave: current_wave, tickets: [], reason: "move"}; $now) end' --argjson now "$(state_now)"
}

# ---------------------------------------------------------------- snapshot

# snapshot_commit main run-id run-dir state-file parent... : a commit whose tree is the
# first parent's tree plus the run folder (state.json taken from state-file),
# parented on every parent given. The run folder is git-ignored, so it is built
# with a private index, never touching the checkout.
snapshot_commit() {
  local main="$1" id="$2" rd="$3" newstate="$4" idx f rel blob tree args
  shift 4
  idx="$TMP_DIR/index"
  rm -f "$idx"
  export GIT_INDEX_FILE="$idx"
  git -C "$main" read-tree "$1"
  while IFS= read -r f; do
    rel=${f#"$rd"/}
    case "$rel" in state.lock | .state.json.tmp* | .state.lock.tmp* | */runner.pid | state.json) continue ;; esac
    blob=$(git -C "$main" hash-object -w "$f")
    git -C "$main" update-index --add --cacheinfo "100644,$blob,.artisan-agent/runs/$id/$rel"
  done < <(find "$rd" -type f)
  blob=$(git -C "$main" hash-object -w "$newstate")
  git -C "$main" update-index --add --cacheinfo "100644,$blob,.artisan-agent/runs/$id/state.json"
  tree=$(git -C "$main" write-tree)
  unset GIT_INDEX_FILE
  args=""
  for p in "$@"; do args="$args -p $p"; done
  # shellcheck disable=SC2086
  git_in "$main" commit-tree "$tree" $args -m "Run $id: state snapshot"
}

git_in() { # main git-args... (identity fixed when the repo has none)
  local main="$1"
  shift
  if { git -C "$main" config user.name && git -C "$main" config user.email; } >/dev/null 2>&1; then
    git -C "$main" "$@"
  else
    # shellcheck disable=SC2086
    git $GIT_ID -C "$main" "$@"
  fi
}

remote_state() { # main remote-ref id -> the state json on that ref, or nothing
  git -C "$1" show "$2:.artisan-agent/runs/$3/state.json" 2>/dev/null || true
}

# ---------------------------------------------------------------- out

cmd_out() {
  local rd="$1" remote=origin wait=0 id main ib tip rref prev rstate rstatus rmach me out snap
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) [ $# -ge 2 ] || usage; remote=$2; shift 2 ;;
      --wait) [ $# -ge 2 ] || usage; wait=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  RUN_DIR=$rd
  state_require_run_dir "$rd"
  # A copy left "moved, push pending" by an out that died is finished (or
  # undone) by running out again; any other moved copy is refused as before.
  local pending=0
  if [ "$(get '.location.status // ""')" = moved ] && [ "$(get '.location.pending // false')" = true ] \
    && [ "$(get '.location.machine // ""')" = "$(state_machine_id)" ]; then
    pending=1
    export ARTISAN_MOVING=1
  else
    state_location_guard "$rd" || exit 3
  fi
  id=$(get .run_id)
  main=$(main_of "$rd")
  me=$(state_machine_id)
  ib=$(get .integration.branch)

  # Idle: wait for it, then take the lock so nothing starts while we push.
  local waited=0
  while :; do
    out=$(idle_report "$rd")
    [ -z "$out" ] && break
    if [ "$waited" -ge "$wait" ]; then
      printf 'not idle, so the run is not moved:\n%s\n' "$out" >&2
      exit 4
    fi
    sleep 2
    waited=$((waited + 2))
  done
  git -C "$main" remote get-url "$remote" >/dev/null 2>&1 || die "no remote named $remote"
  git -C "$main" rev-parse -q --verify "refs/heads/$ib" >/dev/null || die "the integration branch $ib does not exist here"
  tip=$(git -C "$main" rev-parse "refs/heads/$ib")

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  state_lock "$rd" "$(state_writer_pid)" || exit 3
  trap 'rm -rf "$TMP_DIR"; state_unlock "'"$rd"'" "'"$(state_writer_pid)"'" || true' EXIT
  out=$(idle_report "$rd" | grep -v 'run lock' || true)
  [ -z "$out" ] || { printf 'not idle, so the run is not moved:\n%s\n' "$out" >&2; exit 4; }

  # The branch may already hold this run (an earlier move): it must not be live elsewhere.
  rref="refs/remotes/$remote/runs/$id"
  # Set before the fetch: it fails on a first move (no runs/<id> yet), and bash 4+
  # (Linux) leaves a bare `local` unset, so set -u would trip on the reads below.
  prev="" rstate="" rstatus="" rmach=""
  if git -C "$main" fetch -q "$remote" "+refs/heads/runs/$id:$rref" 2>/dev/null; then
    prev=$(git -C "$main" rev-parse "$rref")
    rstate=$(remote_state "$main" "$rref" "$id")
    rstatus=$(printf '%s' "$rstate" | jq -r '.location.status // empty' 2>/dev/null || true)
    rmach=$(printf '%s' "$rstate" | jq -r '.location.machine // empty' 2>/dev/null || true)
  fi
  snap=""
  if [ "$pending" = 1 ]; then
    snap=$(get '.location.commit // ""')
    # The push already landed (the copy died after it): only the marker is left to clear.
    if [ -n "$snap" ] && [ -n "$prev" ] && git -C "$main" merge-base --is-ancestor "$snap" "$prev" 2>/dev/null; then
      out_finish "$rd" "$id" "$ib" "$snap"
      return 0
    fi
    [ -n "$snap" ] || { out_undo "$rd" "$me"; die "a move was left half done with no snapshot; the run is live here again"; }
  fi
  if [ "$rstatus" = live ] && [ "$rmach" != "$me" ]; then
    [ "$pending" = 0 ] || out_undo "$rd" "$me"
    printf 'the run is live on %s according to %s/runs/%s; it is not moved from here\n' "$rmach" "$remote" "$id" >&2
    exit 5
  fi

  if [ "$pending" = 0 ]; then
    # The new state, then the snapshot commit carrying it.
    jq --arg m "$me" --arg b "runs/$id" --argjson now "$(state_now)" "$STATE_JQ_DEFS"'
        .halted = (if .halted.move == true then null else .halted end)
        | .location = {status: "moved", machine: $m, branch: $b, at: $now}
        | event({event: "moved-out", from: $m, branch: $b}; $now)' "$(state_file "$rd")" >"$TMP_DIR/state.json"
    local parents="$tip"
    [ -z "$prev" ] || parents="$tip $prev"
    # shellcheck disable=SC2086
    snap=$(snapshot_commit "$main" "$id" "$rd" "$TMP_DIR/state.json" $parents)
  fi

  # Push the integration branch and the unmerged ticket branches first: a refusal
  # here changes nothing, because this copy is still live.
  git -C "$main" push -q "$remote" "refs/heads/$ib:refs/heads/$ib" 2>&1 || { [ "$pending" = 0 ] || out_undo "$rd" "$me"; echo "move.sh: the push of $ib was refused" >&2; exit 6; }
  local t br
  for t in $(jq -r '.tickets | to_entries[] | select(.value.status != "merged" and .value.status != "closed") | .key' "$(state_file "$rd")"); do
    br=$(jq -r --arg t "$t" '.tickets[$t].branch' "$(state_file "$rd")")
    git -C "$main" rev-parse -q --verify "refs/heads/$br" >/dev/null || continue
    git -C "$main" push -q "$remote" "refs/heads/$br:refs/heads/$br" 2>&1 || { [ "$pending" = 0 ] || out_undo "$rd" "$me"; echo "move.sh: the push of $br was refused" >&2; exit 6; }
  done

  # Two-phase marker. Phase one: this copy stops being live (moved, push
  # pending) BEFORE the run branch is pushed, so at no instant are two copies
  # live. Phase two: the push. If it is refused, this copy goes back to live;
  # if this process dies in between, running out again finishes or undoes it.
  if [ "$pending" = 0 ]; then
    # The pushed snapshot has the drain halt cleared; this copy keeps it until the push lands.
    jq --arg c "$snap" --argjson h "$(get '.halted')" '.location.commit = $c | .location.pending = true | .halted = $h' "$TMP_DIR/state.json" >"$(state_tmp "$rd")"
    ARTISAN_MOVING=1 state_commit "$rd" "$(state_tmp "$rd")"
  fi
  [ "${ARTISAN_MOVE_DIE_AT:-}" != after-mark ] || kill -KILL $$ # test hook (tests/move.test.sh)
  git -C "$main" push -q "$remote" "$snap:refs/heads/runs/$id" 2>&1 \
    || { out_undo "$rd" "$me"; echo "move.sh: runs/$id was refused (the run was moved or claimed elsewhere first); this copy is live again, nothing changed on $remote" >&2; exit 6; }
  [ "${ARTISAN_MOVE_DIE_AT:-}" != after-push ] || kill -KILL $$ # test hook
  out_finish "$rd" "$id" "$ib" "$snap"
}

out_finish() { # run-dir id integration-branch snapshot: the push landed; clear the pending marker
  local rd="$1"
  jq 'del(.location.pending) | .halted = (if .halted.move == true then null else .halted end)' "$(state_file "$rd")" >"$(state_tmp "$rd")"
  ARTISAN_MOVING=1 state_commit "$rd" "$(state_tmp "$rd")"
  printf 'moved %s: pushed %s and runs/%s (%s); resume it with: move.sh in %s\n' "$2" "$3" "$2" "$4" "$2"
}

out_undo() { # run-dir machine: the push did not land; this copy is live again
  local rd="$1" me="$2"
  jq --arg m "$me" --argjson now "$(state_now)" "$STATE_JQ_DEFS"'
      .location = {status: "live", machine: $m, at: $now}
      | event({event: "move-out-undone", machine: $m}; $now)' "$(state_file "$rd")" >"$(state_tmp "$rd")"
  ARTISAN_MOVING=1 state_commit "$rd" "$(state_tmp "$rd")"
}

# ---------------------------------------------------------------- in

rollback_claim() { # main id remote claim original-state-json: push the original (moved) state back over the claim
  local main="$1" id="$2" remote="$3" claim="$4" orig="$5" blob tree c idx="$TMP_DIR/index.rb"
  printf '%s' "$orig" >"$TMP_DIR/orig.json"
  export GIT_INDEX_FILE="$idx"
  git -C "$main" read-tree "$claim"
  blob=$(git -C "$main" hash-object -w "$TMP_DIR/orig.json")
  git -C "$main" update-index --add --cacheinfo "100644,$blob,.artisan-agent/runs/$id/state.json"
  tree=$(git -C "$main" write-tree)
  unset GIT_INDEX_FILE
  c=$(git_in "$main" commit-tree "$tree" -p "$claim" -m "Run $id: resume failed, handed back")
  git -C "$main" push -q "$remote" "$c:refs/heads/runs/$id" >/dev/null 2>&1
  echo "move.sh: resuming failed; runs/$id is handed back (moved), so it can be resumed again" >&2
}

cmd_in() {
  local id="$1" remote=origin main rd rref rstate rstatus rmach me ib wt t br claim tree
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) [ $# -ge 2 ] || usage; remote=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  main=$(main_of .)
  rd="$main/.artisan-agent/runs/$id"
  me=$(state_machine_id)
  RUN_DIR=$rd
  git -C "$main" fetch -q "$remote" "+refs/heads/runs/$id:refs/remotes/$remote/runs/$id" 2>/dev/null \
    || { echo "move.sh: no runs/$id on $remote: the run was not moved there" >&2; exit 5; }
  rref="refs/remotes/$remote/runs/$id"
  rstate=$(remote_state "$main" "$rref" "$id")
  [ -n "$rstate" ] || die "runs/$id holds no state file"
  rstatus=$(printf '%s' "$rstate" | jq -r '.location.status // empty')
  rmach=$(printf '%s' "$rstate" | jq -r '.location.machine // empty')
  if [ "$rstatus" != moved ]; then
    printf 'the run is live on %s (runs/%s says %s): it is not resumed here\n' "${rmach:-another machine}" "$id" "${rstatus:-live}" >&2
    exit 5
  fi
  # A copy already live here has nothing to resume.
  if [ -f "$(state_file "$rd")" ] && [ "$(get '.location.status // "live"')" = live ] && [ "$(get '.location.machine // ""')" = "$me" ]; then
    echo "move.sh: the run is already live on this machine" >&2
    exit 5
  fi

  ib=$(printf '%s' "$rstate" | jq -r '.integration.branch')
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # The claim comes first: one commit on top of runs/<id>, pushed fast-forward
  # only. Whoever's push lands is the run's one live machine.
  printf '%s' "$rstate" | jq --arg m "$me" --arg b "runs/$id" --argjson now "$(state_now)" "$STATE_JQ_DEFS"'
      .location = {status: "live", machine: $m, branch: $b, at: $now}
      | .halted = (if .halted.move == true then null else .halted end)
      | .tickets |= map_values(if has("worktree") then .worktree = null else . end)
      | .integration |= del(.worktree)
      | event({event: "moved-in", to: $m, branch: $b}; $now)' >"$TMP_DIR/state.json"
  local idx="$TMP_DIR/index" blob
  export GIT_INDEX_FILE="$idx"
  git -C "$main" read-tree "$rref"
  blob=$(git -C "$main" hash-object -w "$TMP_DIR/state.json")
  git -C "$main" update-index --add --cacheinfo "100644,$blob,.artisan-agent/runs/$id/state.json"
  tree=$(git -C "$main" write-tree)
  unset GIT_INDEX_FILE
  claim=$(git_in "$main" commit-tree "$tree" -p "$rref" -m "Run $id: resumed on $me")
  git -C "$main" push -q "$remote" "$claim:refs/heads/runs/$id" 2>&1 \
    || { echo "move.sh: another machine claimed runs/$id first; nothing changed here" >&2; exit 6; }
  git -C "$main" update-ref "$rref" "$claim"
  # Anything that fails from here on hands the run back (moved, in transit),
  # so a half-resumed run is never stranded as live on a machine that has no state.
  CLAIM_TREE_STATE="$rstate"
  trap 'rc=$?; if [ "$rc" -ne 0 ]; then rollback_claim "$main" "$id" "$remote" "$claim" "$CLAIM_TREE_STATE" || true; fi; rm -rf "$TMP_DIR"' EXIT

  # Branches: the integration branch and the unmerged ticket branches, as pushed.
  wt="$(dirname "$main")/$(basename "$main")-wt/run-$id"
  git -C "$main" fetch -q "$remote" "+refs/heads/$ib:refs/remotes/$remote/$ib" || die "could not fetch $ib"
  if [ -d "$wt" ]; then
    git -C "$wt" merge -q --ff-only "refs/remotes/$remote/$ib" >/dev/null 2>&1 || die "the integration worktree $wt cannot fast-forward to $remote/$ib (it has work the run does not)"
  else
    git -C "$main" branch -f "$ib" "refs/remotes/$remote/$ib" >/dev/null 2>&1 || die "could not set $ib from $remote"
  fi
  for t in $(printf '%s' "$rstate" | jq -r '.tickets | to_entries[] | select(.value.status != "merged" and .value.status != "closed") | .key'); do
    br=$(printf '%s' "$rstate" | jq -r --arg t "$t" '.tickets[$t].branch')
    if git -C "$main" fetch -q "$remote" "+refs/heads/$br:refs/remotes/$remote/$br" 2>/dev/null; then
      git -C "$main" branch -f "$br" "refs/remotes/$remote/$br" >/dev/null 2>&1 || true
    fi
  done

  # The state folder, from the claim; then this machine's own worktree.
  mkdir -p "$rd"
  git -C "$main" archive "$claim" ".artisan-agent/runs/$id" | tar -x -C "$main"
  rm -f "$rd"/workers/*/runner.pid "$rd/state.lock"
  ARTISAN_MOVING=1 "$SCRIPT_DIR/wave.sh" start "$rd" >/dev/null
  printf '%s\n' "$rd"
}

cmd_where() {
  local m
  state_require_run_dir "$1"
  RUN_DIR=$1
  m=$(get '.location.machine // ""')
  printf '%s %s\n' "$(get '.location.status // "live"')" "${m:-$(state_machine_id)}"
}

case "${1:-}" in
  drain) [ $# -eq 2 ] || usage; cmd_drain "$2" ;;
  idle) [ $# -eq 2 ] || usage; cmd_idle "$2" ;;
  out) [ $# -ge 2 ] || usage; rd=$2; shift 2; cmd_out "$rd" "$@" ;;
  in) [ $# -ge 2 ] || usage; id=$2; shift 2; cmd_in "$id" "$@" ;;
  where) [ $# -eq 2 ] || usage; cmd_where "$2" ;;
  *) usage ;;
esac
