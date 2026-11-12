#!/usr/bin/env bash
# Keep the plan step's price table current (#91). Estimates made without history use
# references/model-prices.json; nothing else checks that it stays current. The retro's
# upstream check (skills/retro/SKILL.md, "Upstream check") runs this each retro.
#
#   model-prices.sh run <work-dir>
#       the whole check: fetch, then compare. Prints "no price change" (exit 0) when the
#       published prices match the file, or the table of differences ending
#       "Update model prices?" (exit 10). Writes <work-dir>/published.json.
#   model-prices.sh fetch <work-dir>
#       a fresh capped headless session (brief: skills/retro/PRICES.md) reads Anthropic's
#       published pricing and writes <work-dir>/published.json, in the file's own shape
#   model-prices.sh compare <published.json>
#       recorded against published: one table row per model that differs, is new or is
#       no longer published. Exit 0 same, 10 differs, 1 unreadable
#   model-prices.sh apply <published.json>
#       after the Artisan says yes: sets each published model's rates and the "as of"
#       date in the file's _source. A model no longer published is kept, never deleted
#
# Nothing changes until `apply`; the file is only ever rewritten with the Artisan's yes.
# Environment: ARTISAN_PRICES_FILE (default references/model-prices.json),
# ARTISAN_CLAUDE_BIN (stand-in), ARTISAN_PRICES_MODEL, ARTISAN_PRICES_BUDGET,
# ARTISAN_TODAY (the date to record, default today). Exit: 0 ok, 1 failed, 2 bad usage,
# 10 prices differ. Portable to bash 3.2.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
FILE=${ARTISAN_PRICES_FILE:-$PLUGIN_ROOT/references/model-prices.json}
CLAUDE=${ARTISAN_CLAUDE_BIN:-claude}
BRIEF="$PLUGIN_ROOT/skills/retro/PRICES.md"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'model-prices.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

check_shape() { # file
  [ -f "$1" ] || die "no such file: $1"
  jq -e '(.models | type == "object") and (.models | length > 0)
         and ([.models[] | (.input_per_mtok | type == "number" and . > 0)
                          and (.output_per_mtok | type == "number" and . > 0)] | all)' "$1" >/dev/null 2>&1 \
    || die "$1 is not {\"models\": {<id>: {input_per_mtok, output_per_mtok}}} with positive numbers"
}

cmd_fetch() {
  local work=${1:-} prompt
  [ -n "$work" ] || usage
  mkdir -p "$work"; work=$(cd "$work" && pwd)
  rm -f "$work/published.json"
  prompt="$(cat "$BRIEF")

Recorded file: $FILE
Write your answer to: $work/published.json"
  ( cd "$work" && ARTISAN_ROLE=prices-check "$CLAUDE" -p "$prompt" \
      --model "${ARTISAN_PRICES_MODEL:-claude-sonnet-5-5}" --max-budget-usd "${ARTISAN_PRICES_BUDGET:-0.50}" \
      --output-format json >"$work/prices-session.json" 2>"$work/prices-session.err" ) \
    || die "the prices agent failed (see $work/prices-session.err)"
  [ -s "$work/published.json" ] || die "the prices agent wrote no $work/published.json"
  check_shape "$work/published.json"
}

cmd_compare() {
  local pub=${1:-} rows
  [ -n "$pub" ] || usage
  check_shape "$FILE"; check_shape "$pub"
  rows=$(jq -r --slurpfile p "$pub" '
    . as $r | ($p[0].models) as $new
    | ( ($new | keys[]) as $m
        | ($r.models[$m]) as $old | $new[$m] as $n
        | if $old == null then [$m, "not recorded", "$\($n.input_per_mtok) / $\($n.output_per_mtok)"]
          elif $old.input_per_mtok != $n.input_per_mtok or $old.output_per_mtok != $n.output_per_mtok
            then [$m, "$\($old.input_per_mtok) / $\($old.output_per_mtok)", "$\($n.input_per_mtok) / $\($n.output_per_mtok)"]
          else empty end ),
      ( ($r.models | keys[]) as $m | select($new[$m] == null)
        | [$m, "$\($r.models[$m].input_per_mtok) / $\($r.models[$m].output_per_mtok)", "no longer published"] )
    | @tsv' "$FILE")
  if [ -z "$rows" ]; then echo "no price change"; return 0; fi
  printf '## Model prices differ from the published pricing\n\n'
  printf '| Model | Recorded (input / output per Mtok) | Published |\n|---|---|---|\n'
  printf '%s\n' "$rows" | awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
  printf '\nUpdate model prices?\n'
  return 10
}

cmd_apply() {
  local pub=${1:-} today tmp
  [ -n "$pub" ] || usage
  check_shape "$FILE"; check_shape "$pub"
  today=${ARTISAN_TODAY:-$(date +%F)}
  tmp="$FILE.tmp.$$"
  jq --slurpfile p "$pub" --arg d "$today" '
    .models += $p[0].models
    | ._source |= (if type == "string" then sub("as of [0-9]{4}-[0-9]{2}-[0-9]{2}"; "as of \($d)") else . end)' \
    "$FILE" >"$tmp" || { rm -f "$tmp"; die "could not rewrite $FILE"; }
  mv "$tmp" "$FILE"
  printf 'updated %s (as of %s)\n' "$FILE" "$today"
}

cmd_run() {
  local work=${1:-}
  [ -n "$work" ] || usage
  cmd_fetch "$work"
  cmd_compare "$work/published.json"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  fetch) shift; cmd_fetch "$@" ;;
  compare) shift; cmd_compare "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  *) usage ;;
esac
