# Reading a session's `claude -p --output-format stream-json` stream
# (workers/<t>.<n>/stream.jsonl). Sourced, never run. Needs jq.
#
# An event is chosen by its parsed "type", never by how its line starts:
# claude writes other keys before "type" (a current result line begins
# {"duration_api_ms":…,"stop_reason":…,"session_id":…, and "type" comes
# later), and the order is not promised. A line that is not a JSON object
# (a half-written last line, noise) is skipped, never fatal.
#
# Portable to bash 3.2 (macOS) and Linux.

# stream_events type stream-file: every event of that type, in order, one
# compact JSON object per line. Nothing when the file is missing. A cheap
# fixed-string grep for the quoted type keeps the per-second poll light; jq
# then keeps only the lines whose own top-level type it is.
stream_events() {
  local type="$1" file="$2"
  [ -f "$file" ] || return 0
  { grep -F "\"$type\"" "$file" 2>/dev/null || true; } \
    | jq -cR --arg t "$type" 'fromjson? | select(type == "object" and .type == $t)' 2>/dev/null || true
}

# stream_result stream-file: the stream's final result event (the object
# `--output-format json` prints), or nothing when it has none.
stream_result() {
  stream_events result "$1" | tail -n 1
}
