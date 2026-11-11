#!/usr/bin/env bash
# List open `deferred` tickets whose return condition has been met.
# Return conditions are read from the deferral comment's line:
#   Return condition: date YYYY-MM-DD
#   Return condition: next review on YYYY-MM-DD
#   Return condition: blocked-by #12 #15      (due once every listed ticket is closed)
# Prints one "#N title: why" line per due ticket, or "none due". Read-only.
# ARTISAN_TODAY (YYYY-MM-DD) overrides today's date. Portable to bash 3.2.
set -euo pipefail

today=${ARTISAN_TODAY:-$(date +%F)}

rows=$(gh issue list --label deferred --state open --limit 200 --json number,title,comments \
  --jq '.[] | [.number, .title, ([.comments[].body | select(test("Return condition:"))] | last // "")] | @tsv')

found=0
while IFS=$'\t' read -r num title body; do
  [ -n "$num" ] || continue
  # @tsv escapes newlines as the two characters \n; take the condition line.
  cond=$(printf '%s' "$body" | sed 's/\\n/\
/g' | sed -n 's/.*Return condition:[[:space:]]*//p' | tail -n 1)
  [ -n "$cond" ] || continue
  why=
  case "$cond" in
    blocked-by*)
      open=0; refs=
      for n in $(printf '%s' "$cond" | grep -o '#[0-9][0-9]*' | tr -d '#'); do
        refs="$refs #$n"
        state=$(gh issue view "$n" --json state --jq .state)
        [ "$state" = CLOSED ] || open=1
      done
      [ -n "$refs" ] && [ $open -eq 0 ] && why="blocking event closed (${refs# })"
      ;;
    *)
      d=$(printf '%s' "$cond" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -n 1 || true)
      # ISO dates compare correctly as strings.
      if [ -n "$d" ] && [ ! "$d" \> "$today" ]; then why="date $d has passed"; fi
      ;;
  esac
  if [ -n "$why" ]; then printf '#%s %s: %s\n' "$num" "$title" "$why"; found=1; fi
done <<EOF2
$rows
EOF2

[ $found -eq 1 ] || echo "none due"
