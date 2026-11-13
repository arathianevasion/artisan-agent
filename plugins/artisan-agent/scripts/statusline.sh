#!/usr/bin/env bash
# The plugin's status-line capture: plan usage and the context window, written
# where the usage guard (budget.sh) and the cockpit read them.
# Rules: ${CLAUDE_PLUGIN_ROOT}/references/cost-and-usage.md.
#
# Usage:
#   statusline.sh
#       the status-line command itself. Claude Code runs it with the session's
#       JSON on stdin, on every event and every refreshInterval seconds. It
#       writes <home>/usage.json (plan usage, the latest session's model and
#       context window) and <home>/sessions/<session-id>.json (that session's
#       model, window and transcript), each in one step, then prints the
#       line: the chained status line's output when one is recorded
#       (statusline-next.json, kept by install), else a short line of its own.
#       Rate limits missing from the input (an API-key login, or before the
#       session's first response) leave the last reading as it was.
#   statusline.sh install [--refresh SECONDS]
#       copies this script to <home>/statusline.sh (a path that survives
#       plugin updates; run install again after an update) and points the
#       statusLine in <config>/settings.json at it, with refreshInterval
#       (default 60). A statusLine already there that is not this one is
#       kept in <home>/statusline-next.json and chained, so its line still
#       shows. Every other setting is kept. A rerun changes nothing.
#   statusline.sh window --transcript F
#       the context window size, in tokens, captured for the session whose
#       transcript is F; nothing (exit 1) when no capture names it.
#   statusline.sh path
#       the usage file's path.
#
# <config> is CLAUDE_CONFIG_DIR (default ~/.claude); <home>, the Artisan's
# individual home, is ARTISAN_HOME (default <config>/artisan-agent).
# ARTISAN_USAGE_FILE overrides the usage file's path.
#
# Exit status: 0 ok, 1 error, 2 usage. The capture itself never fails the
# status line: a write it can't make is skipped and the line still prints.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -uo pipefail

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
USAGE_FILE=${ARTISAN_USAGE_FILE:-$HOME_DIR/usage.json}
SESSIONS=$HOME_DIR/sessions
NEXT=$HOME_DIR/statusline-next.json
SELF="$0"

usage() { sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'statusline.sh: %s\n' "$*" >&2; exit 1; }

now() { date +%s; }

# write_atomic path: stdin to a temp file beside path, then a rename. Empty
# input (the jq feeding it failed) replaces nothing.
write_atomic() {
  local tmp="$1.tmp.$$"
  cat >"$tmp" && [ -s "$tmp" ] && mv -f "$tmp" "$1" && return 0
  rm -f "$tmp"
  return 1
}

# The window: what Claude Code reports, else the model's (1M for a [1m]
# model id, 200,000 otherwise), the same rule drain.sh applies.
WINDOW_JQ='
  def window: (.context_window.context_window_size // null) as $w
    | if ($w | type) == "number" and $w > 0 then $w
      elif ((.model.id // "") | test("\\[1m\\]")) then 1000000
      else 200000 end;'

capture() {
  local input= t= prev= sid= line=
  input=$(cat)
  t=$(now)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input" || { echo "artisan-agent: no session data"; return 0; }
  mkdir -p "$HOME_DIR" "$SESSIONS" 2>/dev/null || true
  prev='{}'
  [ -s "$USAGE_FILE" ] && prev=$(jq -c 'if type == "object" then . else {} end' "$USAGE_FILE" 2>/dev/null || echo '{}')
  jq -c --argjson t "$t" --argjson prev "$prev" "$WINDOW_JQ"'
    {schema_version: 1, written_at: $t,
     session_id: (.session_id // null),
     model: {id: (.model.id // null), display_name: (.model.display_name // null)},
     context_window: {size: window, used_percentage: (.context_window.used_percentage // null)},
     rate_limits: (if (.rate_limits | type) == "object"
                     and (.rate_limits.five_hour != null or .rate_limits.seven_day != null)
                   then {at: $t,
                         five_hour: (.rate_limits.five_hour // null | if . then {used_percentage, resets_at} else null end),
                         seven_day: (.rate_limits.seven_day // null | if . then {used_percentage, resets_at} else null end)}
                   else ($prev.rate_limits // null) end)}' <<<"$input" 2>/dev/null \
    | write_atomic "$USAGE_FILE" 2>/dev/null || true
  sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
  case "$sid" in '' | */* | .*) ;; *)
    jq -c --argjson t "$t" "$WINDOW_JQ"'
      {session_id, at: $t, transcript_path: (.transcript_path // null), model: (.model.id // null),
       context_window: {size: window, used_percentage: (.context_window.used_percentage // null)}}' \
      <<<"$input" 2>/dev/null | write_atomic "$SESSIONS/$sid.json" 2>/dev/null || true
    # Old sessions' files go, about once an hour.
    if [ ! -e "$SESSIONS/.pruned" ] || [ -n "$(find "$SESSIONS/.pruned" -mmin +60 2>/dev/null)" ]; then
      find "$SESSIONS" -name '*.json' -mtime +7 -exec rm -f {} + 2>/dev/null || true
      : >"$SESSIONS/.pruned" 2>/dev/null || true
    fi
    ;;
  esac
  # The line: a chained status line's, else our own.
  if [ -s "$NEXT" ] && line=$(jq -r '.command // empty' "$NEXT" 2>/dev/null) && [ -n "$line" ]; then
    printf '%s' "$input" | sh -c "$line" 2>/dev/null
    return 0
  fi
  jq -r "$WINDOW_JQ"'
    def pct: if . == null then "?" else (. | floor | tostring) + "%" end;
    "\(.model.display_name // .model.id // "?") · ctx \(.context_window.used_percentage | pct) of \(window / 1000 | floor)k"
    + (if .rate_limits.five_hour then " · 5h \(.rate_limits.five_hour.used_percentage | pct)" else "" end)
    + (if .rate_limits.seven_day then " · 7d \(.rate_limits.seven_day.used_percentage | pct)" else "" end)' \
    <<<"$input" 2>/dev/null || echo "artisan-agent"
}

cmd_install() {
  local refresh=60 settings= target= cur=
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) [ $# -ge 2 ] || usage; refresh=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  # install runs from the plugin's scripts directory; the installed copy
  # (capture) stays standalone and never needs the library.
  # shellcheck source=lib/state-lib.sh
  . "$(dirname "$SELF")/lib/state-lib.sh" 2>/dev/null \
    || die "install needs the plugin's scripts/lib/state-lib.sh beside it; run install from the plugin, not the installed copy"
  state_is_uint "$refresh" && [ "$refresh" -gt 0 ] || usage
  command -v jq >/dev/null 2>&1 || die "jq is required"
  mkdir -p "$HOME_DIR" "$CFG" || die "could not create $HOME_DIR"
  target="$HOME_DIR/statusline.sh"
  if ! cmp -s "$SELF" "$target" 2>/dev/null; then
    cp "$SELF" "$target.tmp.$$" && chmod +x "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target" \
      || die "could not copy the capture to $target"
    echo "changed: status-line capture copied to $target"
  fi
  settings="$CFG/settings.json"
  [ -s "$settings" ] || echo '{}' >"$settings"
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 || die "$settings is not a JSON object; not touching it"
  cur=$(jq -c '.statusLine // null' "$settings")
  if [ "$cur" != null ] && [ "$(jq -r '.command // ""' <<<"$cur")" != "$target" ]; then
    jq -c '{command, padding}' <<<"$cur" | write_atomic "$NEXT" || die "could not record the existing status line"
    echo "changed: the existing status line is kept and chained ($NEXT)"
  fi
  if [ "$(jq -c --arg c "$target" --argjson r "$refresh" '.statusLine == ((.statusLine // {}) + {type: "command", command: $c, refreshInterval: $r})' "$settings")" = true ]; then
    echo "unchanged: statusLine already runs the capture every ${refresh}s"
    return 0
  fi
  jq --arg c "$target" --argjson r "$refresh" \
    '.statusLine = ((.statusLine // {}) + {type: "command", command: $c, refreshInterval: $r})' "$settings" \
    | write_atomic "$settings" || die "could not write $settings"
  echo "changed: statusLine runs $target every ${refresh}s ($settings)"
}

cmd_window() {
  local transcript= f=
  while [ $# -gt 0 ]; do
    case "$1" in
      --transcript) [ $# -ge 2 ] || usage; transcript=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$transcript" ] || usage
  [ -d "$SESSIONS" ] || return 1
  f=$(grep -l -F "\"transcript_path\":$(jq -n --arg p "$transcript" '$p')" "$SESSIONS"/*.json 2>/dev/null | head -n 1)
  [ -n "$f" ] || return 1
  jq -e '.context_window.size | select(type == "number" and . > 0)' "$f" 2>/dev/null
}

case "${1:-}" in
  '') capture ;;
  install) shift; cmd_install "$@" ;;
  window) shift; cmd_window "$@" ;;
  path) echo "$USAGE_FILE" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
