#!/usr/bin/env bash
# Every issue the plugin opens in a project is created here (#146), so the
# project's board convention is kept in one place.
# The rules: ${CLAUDE_PLUGIN_ROOT}/references/tracker-board.md
#
# Usage:
#   tracker.sh new-issue --kind KIND [--from TICKET] [--field NAME=VALUE]...
#                        [--run-dir DIR] [--project DIR] -- <gh issue create args>
#       runs `gh issue create` with the args after --, prints the new issue's
#       URL as gh does and exits with gh's status when it fails. Then, when the
#       project config sets tracker.board and KIND goes on the board, adds the
#       issue to that GitHub Project and sets each tracker.board.fields_at_filing
#       field: from --field when one names it, else the value TICKET (the
#       ticket the issue came from) has on the board, else left empty for
#       triage. Priority, Status and any field not listed are never set.
#       The body goes to gh as a file, never as an argument: give it as
#       --body-file FILE (FILE - is stdin; --body TEXT still works, for a
#       short one). A body over GitHub's 65,536-character limit is posted
#       whole: the issue body holds what fits and says the rest follows,
#       then each further part is a comment, in order, each under the limit
#       (a code fence cut by a part break is closed and opened again).
#       A board step that fails never fails the call: it warns on stderr,
#       queues the add for the next sweep and, with --run-dir, records a
#       board-add-failed event in that run's state file.
#   tracker.sh board-retry [--run-dir DIR] [--project DIR]
#       tries every queued board add again; one that fails again stays queued,
#       until ARTISAN_BOARD_TRIES retries (default 10) have failed: then it is
#       dropped with a warning to add it by hand.
#       The orchestrator's sweep (sweep.sh) and the chats' sweep (chats.sh
#       sweep) run it. With nothing queued it does nothing, offline.
#
# Kinds on the board (work that outlives the run): plan, finding,
# human-check, rework, split. Kinds off it (run plumbing that closes inside
# the run): gate (review, risk, exception, overrun and end gates), question.
#
# --run-dir defaults to ARTISAN_RUN_DIR (set for the sessions a run launches).
# The project is the main checkout of --run-dir's repo, else of --project
# (default: the current directory). Its config is .artisan-agent/config.yml;
# the queue is .artisan-agent/runs/.board/pending.jsonl (git-ignored), one
# JSON line per add: {repo, issue, url, kind, from, fields, at}.
# Callers that hold a run's state lock pass ARTISAN_WRITER_PID, so the event
# is written under their lock.
#
# Exit status: 0 ok (board failures included), 2 usage, else gh's status
# (a part comment that fails after the issue was created: its URL is printed
# first, and the missing parts are named on stderr).
# Portable to bash 3.2 (macOS) and Linux. Needs gh, jq and git.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
warn() { printf 'tracker.sh: %s\n' "$*" >&2; }

ON_BOARD=" plan finding human-check rework split "
# A queued add that has failed this many retries is given up, with a warning.
MAX_TRIES=${ARTISAN_BOARD_TRIES:-10}
OFF_BOARD=" gate question "

KIND= FROM= RUN_DIR=${ARTISAN_RUN_DIR:-} PROJECT=. FIELDS='{}'
[ $# -ge 1 ] || usage
cmd=$1
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) [ $# -ge 2 ] || usage; KIND=$2; shift 2 ;;
    --from) [ $# -ge 2 ] || usage; FROM=${2#\#}; shift 2 ;;
    --field)
      [ $# -ge 2 ] || usage
      case "$2" in *=*) ;; *) usage ;; esac
      FIELDS=$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<<"$FIELDS")
      shift 2 ;;
    --run-dir) [ $# -ge 2 ] || usage; RUN_DIR=$2; shift 2 ;;
    --project) [ $# -ge 2 ] || usage; PROJECT=$2; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done

# The main checkout, or empty outside a git repository.
MAIN=
main_checkout() {
  local dir="$PROJECT" common=""
  [ -z "$RUN_DIR" ] || dir=$RUN_DIR
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  MAIN=$(dirname "$common")
}

# BOARD: tracker.board as JSON, or empty when the project sets none.
BOARD=
read_board() {
  local f="" out=""
  [ -n "$MAIN" ] || return 0
  f="$MAIN/.artisan-agent/config.yml"
  [ -f "$f" ] && grep -q '^tracker:' "$f" || return 0
  if ! out=$("$SCRIPT_DIR/config.sh" get tracker.board --file "$f" 2>&1); then
    warn "cannot read tracker.board from $f ($out); nothing goes on a board"
    return 0
  fi
  [ "$(jq -r 'type == "object" and (.owner // "") != "" and (.number // null) != null' <<<"$out")" = true ] || return 0
  BOARD=$(jq -c . <<<"$out")
}

queue_dir() { printf '%s/.artisan-agent/runs/.board\n' "$MAIN"; }

# board_add repo issue url from fields-json: the issue on the board with its
# fields set. On failure returns 1 with the reason in BOARD_ERR.
BOARD_ERR=
board_add() {
  local repo="$1" issue="$2" url="$3" from="$4" named="$5"
  local owner="" number="" out="" item="" values='{}' field="" val="" spec="" pid="" fields_json="" fid="" ftype="" opt=""
  local -a names=()
  owner=$(jq -r .owner <<<"$BOARD")
  number=$(jq -r .number <<<"$BOARD")
  BOARD_ERR=
  if ! out=$(gh project item-add "$number" --owner "$owner" --url "$url" --format json 2>&1); then
    BOARD_ERR="gh project item-add: $out"; return 1
  fi
  item=$(jq -r '.id // empty' <<<"$out" 2>/dev/null) || item=
  [ -n "$item" ] || { BOARD_ERR="gh project item-add gave no item id: $out"; return 1; }
  while IFS= read -r field; do
    [ -n "$field" ] && names+=("$field")
  done < <(jq -r '(.fields_at_filing // [])[] | tostring' <<<"$BOARD")
  [ "${#names[@]}" -gt 0 ] || return 0
  # The source ticket's values, read off the board (gh prints each under a
  # form of the field's name, so names compare without case or spaces).
  if [ -n "$from" ] && [ -n "$(jq -rn --argjson named "$named" '$ARGS.positional[] | select(. as $n | $named | has($n) | not)' --args "${names[@]}")" ]; then
    if ! out=$(gh project item-list "$number" --owner "$owner" --format json --limit 10000 2>&1); then
      BOARD_ERR="gh project item-list: $out"; return 1
    fi
    values=$(jq -c --arg repo "$repo" --argjson n "$from" '
      def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
      [.items[]? | select(.content.number == $n and ((.content.repository // "") | ascii_downcase) == ($repo | ascii_downcase))]
      | first // {} | with_entries(.key |= norm)' <<<"$out" 2>/dev/null) || values='{}'
  fi
  for field in "${names[@]}"; do
    val=$(jq -c --arg f "$field" --argjson named "$named" '
      def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
      if $named | has($f) then $named[$f] else (.[$f | norm] // null) end' <<<"$values")
    [ "$val" != null ] && [ "$val" != '""' ] || continue
    if [ -z "$fields_json" ]; then
      if ! fields_json=$(gh project field-list "$number" --owner "$owner" --format json 2>&1); then
        BOARD_ERR="gh project field-list: $fields_json"; return 1
      fi
      if ! out=$(gh project view "$number" --owner "$owner" --format json 2>&1); then
        BOARD_ERR="gh project view: $out"; return 1
      fi
      pid=$(jq -r '.id // empty' <<<"$out")
      [ -n "$pid" ] || { BOARD_ERR="gh project view gave no id"; return 1; }
    fi
    spec=$(jq -c --arg f "$field" '[.fields[]? | select(.name == $f)] | first // empty' <<<"$fields_json")
    if [ -z "$spec" ]; then warn "the board has no field \"$field\" (tracker.board.fields_at_filing); left empty on #$issue"; continue; fi
    fid=$(jq -r .id <<<"$spec")
    ftype=$(jq -r '.type // ""' <<<"$spec")
    case "$ftype:$(jq -r type <<<"$val")" in
      ProjectV2SingleSelectField:string)
        opt=$(jq -r --argjson v "$val" '[.options[]? | select(.name == $v) | .id] | first // empty' <<<"$spec")
        if [ -z "$opt" ]; then warn "\"$field\" has no option $val on the board; left empty on #$issue"; continue; fi
        out=$(gh project item-edit --id "$item" --project-id "$pid" --field-id "$fid" --single-select-option-id "$opt" 2>&1) \
          || { BOARD_ERR="gh project item-edit ($field): $out"; return 1; } ;;
      ProjectV2Field:number)
        out=$(gh project item-edit --id "$item" --project-id "$pid" --field-id "$fid" --number "$val" 2>&1) \
          || { BOARD_ERR="gh project item-edit ($field): $out"; return 1; } ;;
      ProjectV2Field:string)
        # field-list types text, number and date fields alike: a value that
        # reads as a date or a number is set as one, anything else as text.
        val=$(jq -r . <<<"$val")
        if printf '%s' "$val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then set -- --date "$val"
        elif printf '%s' "$val" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then set -- --number "$val"
        else set -- --text "$val"; fi
        out=$(gh project item-edit --id "$item" --project-id "$pid" --field-id "$fid" "$@" 2>&1) \
          || { BOARD_ERR="gh project item-edit ($field): $out"; return 1; } ;;
      *) warn "\"$field\" is a $ftype field the plugin does not set; left empty on #$issue" ;;
    esac
  done
  return 0
}

record_failure() { # entry-json why
  local entry="$1" why="$2"
  mkdir -p "$(queue_dir)"
  printf '%s\n' "$entry" >>"$(queue_dir)/pending.jsonl"
  [ -n "$RUN_DIR" ] && [ -f "$(state_file "$RUN_DIR")" ] || return 0
  ( state_with_lock "$RUN_DIR" state_apply "$RUN_DIR" "$STATE_JQ_DEFS"'
      event({event: "board-add-failed", issue: $e.issue, kind: $e.kind}
            + (if $e.from == "" then {} else {from: $e.from} end) + {why: $why}; $now)' \
      --argjson e "$entry" --arg why "$why" --argjson now "$(state_now)" ) \
    || warn "could not record the board-add-failed event in $RUN_DIR"
}

# GitHub refuses an issue or comment body over 65,536 characters. A part is
# measured in UTF-8 bytes (never fewer than its characters), and keeps 1,024
# of them for the part notice and a fence carried across the break.
BODY_LIMIT=65536
PART_ROOM=$((BODY_LIMIT - 1024))

# split_body FILE DIR: writes DIR/part-1.md ... DIR/part-N.md, each under
# BODY_LIMIT, which together hold FILE whole, and prints N. Parts break
# between lines; a line too long for one part is cut between characters.
# A part that ends inside a code fence closes it, and the next opens it again.
split_body() {
  local file="$1" dir="$2" n=0 i=0
  # --rawfile, not -Rs: jq 1.7 -R breaks a character cut by its 4 KiB reads.
  jq -n --rawfile body "$file" --argjson room "$PART_ROOM" '
    def cpbytes: if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end;
    # The longest head of the string, in characters, of at most $cap bytes.
    def head_fits($cap):
      . as $s | {n: ([length, $cap] | min)}
      | until(($s[0:.n] | utf8bytelength) <= $cap;
              .n = ([(.n * $cap / ($s[0:.n] | utf8bytelength) | floor), .n - 1] | min))
      | .n;
    # A line longer than $cap bytes, cut between characters into pieces.
    def pieces($cap):
      [{rest: .} | recurse(if .rest == "" then empty
                           else (.rest | head_fits($cap)) as $n | {piece: .rest[0:$n], rest: .rest[$n:]} end)
       | .piece // empty];
    # The fence a line opens or closes: "```" or "~~~" runs, up to 3 spaces in.
    def marker: (capture("^ {0,3}(?<m>`{3,}|~{3,})") | .m) // null;
    def step($line):
      ($line | marker) as $m
      | if .fence == null then (if $m != null then .fence = $line | .mark = $m else . end)
        elif $m != null and ($m[0:1] == .mark[0:1]) and ($m | length) >= (.mark | length)
             and ($line | test("^ {0,3}[`~]+\\s*$")) then .fence = null | .mark = null
        else . end;
    def close_part:
      .parts += [.cur + (if .fence != null then "\n" + .mark else "" end)]
      | .cur = (if .fence != null then .fence else "" end)
      | .b = (.cur | utf8bytelength) | .started = (.fence != null);
    def add($line):
      ($line | utf8bytelength) as $lb
      | (step($line)) as $next
      | (if $next.fence != null then ($next.mark | length) + 1 else 0 end) as $reserve
      | if (if .started then .b + 1 else .b end) + $lb + $reserve <= $room then
          .cur = (if .started then .cur + "\n" else .cur end) + $line
          | .b = (if .started then .b + 1 else .b end) + $lb | .started = true
          | .fence = $next.fence | .mark = $next.mark
        elif .started and .cur != (.fence // "") then close_part | add($line)
        else
          # Too long for any part: cut it between characters, a part each.
          (if .started then 1 else 0 end) as $sep
          | (($room - .b - $sep - 64) | if . < 1024 then 1024 else . end) as $cap
          | reduce ($line | pieces($cap) | to_entries[]) as $e (.;
              (if $e.key > 0 then close_part else . end)
              | .cur = (if .started then .cur + "\n" else .cur end) + $e.value
              | .b = (.cur | utf8bytelength) | .started = true)
          | .fence = $next.fence | .mark = $next.mark
        end;
    reduce ($body | split("\n"))[] as $line ({parts: [], cur: "", b: 0, started: false, fence: null, mark: null}; add($line))
    | .parts + (if .started then [.cur] else [] end)' >"$dir/parts.json"
  n=$(jq length "$dir/parts.json")
  while [ "$i" -lt "$n" ]; do
    jq -j --argjson i "$i" '.[$i]' "$dir/parts.json" >"$dir/part-$((i + 1)).md"
    i=$((i + 1))
  done
  printf '%s\n' "$n"
}

cmd_new_issue() {
  local url="" repo="" issue="" entry="" tmp="" parts=1 k=0 tries=0 has_body=0 missing=""
  local -a args=()
  case "$ON_BOARD$OFF_BOARD" in *" $KIND "*) ;; *) usage ;; esac
  if [ -n "$FROM" ] && ! state_is_uint "$FROM"; then
    warn "--from $FROM is not an issue number; no field is copied from it"
    FROM=
  fi
  [ $# -gt 0 ] || usage
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tracker.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  # The body, whichever way it came, goes to a file of its own.
  while [ $# -gt 0 ]; do
    case "$1" in
      --body|-b) [ $# -ge 2 ] || usage; printf '%s' "$2" >"$tmp/body.md"; has_body=1; shift 2 ;;
      --body-file|-F)
        [ $# -ge 2 ] || usage
        if [ "$2" = - ]; then cat >"$tmp/body.md"; else cat -- "$2" >"$tmp/body.md"; fi || exit 1
        has_body=1; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [ "$has_body" = 1 ]; then
    if [ "$(wc -c <"$tmp/body.md")" -lt "$BODY_LIMIT" ]; then
      cp "$tmp/body.md" "$tmp/part-1.md"
    else
      parts=$(split_body "$tmp/body.md" "$tmp")
      printf '\n\n---\n\n*This packet is too long for one issue body: it continues in the comments below (part 1 of %s).*\n' \
        "$parts" >>"$tmp/part-1.md"
    fi
    args+=(--body-file "$tmp/part-1.md")
  fi
  url=$(gh issue create ${args[@]+"${args[@]}"}) || exit $?
  printf '%s\n' "$url"
  issue=${url##*/}
  repo=$(printf '%s' "$url" | sed -n 's#^[a-z]*://[^/]*/\([^/]*/[^/]*\)/issues/[0-9][0-9]*$#\1#p')
  k=2
  while [ "$k" -le "$parts" ]; do
    { printf '*Continued from the issue body (part %s of %s).*\n\n' "$k" "$parts"; cat "$tmp/part-$k.md"; } >"$tmp/comment-$k.md"
    tries=0
    until [ -n "$repo" ] && gh issue comment "$issue" -R "$repo" --body-file "$tmp/comment-$k.md" >/dev/null; do
      tries=$((tries + 1))
      if [ -z "$repo" ] || [ "$tries" -ge 3 ]; then
        while [ "$k" -le "$parts" ]; do missing="$missing $k"; k=$((k + 1)); done
        warn "#$issue was created, but parts$missing of $parts of its body were not posted as comments; post them by hand"
        exit 1
      fi
    done
    k=$((k + 1))
  done
  case "$ON_BOARD" in *" $KIND "*) ;; *) return 0 ;; esac
  main_checkout
  read_board
  [ -n "$BOARD" ] || return 0
  if [ -z "$repo" ] || ! state_is_uint "$issue"; then
    warn "cannot read the new issue from \"$url\"; add it to the board by hand"
    return 0
  fi
  board_add "$repo" "$issue" "$url" "$FROM" "$FIELDS" && return 0
  entry=$(jq -cn --arg repo "$repo" --argjson issue "$issue" --arg url "$url" --arg kind "$KIND" --arg from "$FROM" \
    --argjson fields "$FIELDS" --argjson now "$(state_now)" \
    '{repo: $repo, issue: $issue, url: $url, kind: $kind, from: $from, fields: $fields, at: $now}')
  warn "#$issue was created, but not added to the board $(jq -r '"\(.owner)/\(.number)"' <<<"$BOARD"): $BOARD_ERR. The next sweep tries again."
  record_failure "$entry" "$BOARD_ERR"
}

cmd_board_retry() {
  local q="" f="" work="" line="" pid=""
  [ $# -eq 0 ] || usage
  main_checkout
  [ -n "$MAIN" ] || return 0
  q=$(queue_dir)
  [ -d "$q" ] || return 0
  # A retry works on its own copy, moved aside in one step, so an add queued
  # meanwhile is never lost; one left by a retry that died is taken over.
  work="$q/retry.$$.jsonl"
  for f in "$q"/retry.*.jsonl; do
    [ -f "$f" ] || continue
    pid=${f##*/retry.}; pid=${pid%.jsonl}
    ! state_pid_alive "$pid" || continue
    cat "$f" >>"$work" && rm -f "$f"
  done
  [ ! -f "$q/pending.jsonl" ] || mv "$q/pending.jsonl" "$work.new"
  [ ! -f "$work.new" ] || { cat "$work.new" >>"$work"; rm -f "$work.new"; }
  [ -s "$work" ] || { rm -f "$work"; return 0; }
  read_board
  if [ -z "$BOARD" ]; then
    warn "board adds are queued but tracker.board is no longer set; dropped: $(jq -rs 'map("#\(.issue)") | join(", ")' "$work")"
    rm -f "$work"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if board_add "$(jq -r .repo <<<"$line")" "$(jq -r .issue <<<"$line")" "$(jq -r .url <<<"$line")" \
         "$(jq -r '.from // ""' <<<"$line")" "$(jq -c '.fields // {}' <<<"$line")"; then
      echo "board: #$(jq -r .issue <<<"$line") added to $(jq -r '"\(.owner)/\(.number)"' <<<"$BOARD")"
    elif [ "$(jq -r '(.tries // 0) + 1' <<<"$line")" -ge "$MAX_TRIES" ]; then
      warn "#$(jq -r .issue <<<"$line") is still not on the board after $MAX_TRIES tries: $BOARD_ERR. Given up: add it by hand."
    else
      warn "#$(jq -r .issue <<<"$line") is still not on the board: $BOARD_ERR. The next sweep tries again."
      jq -c '.tries = ((.tries // 0) + 1)' <<<"$line" >>"$q/pending.jsonl"
    fi
  done <"$work"
  rm -f "$work"
}

case "$cmd" in
  new-issue) cmd_new_issue "$@" ;;
  board-retry) cmd_board_retry "$@" ;;
  *) usage ;;
esac
