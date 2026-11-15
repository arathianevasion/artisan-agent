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
#       not in the published answer (the agent may simply not have found it). Exit 0 same, 10 differs, 1 unreadable
#   model-prices.sh apply <published.json>
#       after the Artisan says yes: sets each published model's rates and the "as of"
#       date in the file's _source. A model absent from the answer is kept, never deleted
#
# Nothing changes until `apply`; the file is only ever rewritten with the Artisan's yes.
# Environment: ARTISAN_PRICES_FILE (default references/model-prices.json),
# ARTISAN_CLAUDE_BIN (stand-in), ARTISAN_PRICES_MODEL, ARTISAN_PRICES_BUDGET,
# ARTISAN_TODAY (the date to record, default today). Exit: 0 ok, 1 failed ("price check failed:"
# and the denied calls when the agent gave no usable answer), 2 bad usage,
# 10 prices differ. Portable to bash 3.2.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
FILE=${ARTISAN_PRICES_FILE:-$PLUGIN_ROOT/references/model-prices.json}
# Absolute, so the agent's grant names the file itself (#245).
case "$FILE" in /*) ;; *) [ ! -d "$(dirname "$FILE")" ] || FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")" ;; esac
CLAUDE=${ARTISAN_CLAUDE_BIN:-claude}
BRIEF="$PLUGIN_ROOT/skills/retro/PRICES.md"
# shellcheck source=lib/headless-lib.sh
. "$HERE/lib/headless-lib.sh"   # headless_args: never a permission prompt (#214)
# The hosts Anthropic's pricing page is served from (its redirects included):
# the only places the agent may fetch from (#245).
PRICES_HOSTS="docs.anthropic.com docs.claude.com platform.claude.com www.anthropic.com anthropic.com www.claude.com claude.com"

# prices_tools answer-file: the allowlist for what PRICES.md asks and nothing
# wider (#245): read the recorded file, fetch the pricing page, write the
# answer file. A "//" rule is an absolute path, so each grant is that one file
# wherever the session runs; a bare Read or Write would still be refused
# outside the session's folder, which is how the check was denied before.
prices_tools() {
  local tools="" host=""
  tools="Read(/$FILE),Write(/$1),Edit(/$1)"
  for host in $PRICES_HOSTS; do tools="$tools,WebFetch(domain:$host)"; done
  printf '%s' "$tools"
}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'model-prices.sh: %s\n' "$*" >&2; exit 1; }
# failed: the fetch got no usable answer. Said as a failed check (#245), so
# the retro never reads it as "no change".
failed() { die "price check failed: $*"; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

check_shape() { # file
  [ -f "$1" ] || die "no such file: $1"
  jq -e '(.models | type == "object") and (.models | length > 0)
         and ([.models[] | (.input_per_mtok | type == "number" and . > 0)
                          and (.output_per_mtok | type == "number" and . > 0)] | all)' "$1" >/dev/null 2>&1 \
    || die "$1 is not {\"models\": {<id>: {input_per_mtok, output_per_mtok}}} with positive numbers"
}

cmd_fetch() {
  local work=${1:-} prompt= denied=
  [ -n "$work" ] || usage
  mkdir -p "$work"; work=$(cd "$work" && pwd)
  rm -f "$work/published.json"
  prompt="$(cat "$BRIEF")

Recorded file: $FILE
Write your answer to: $work/published.json"
  headless_args "$(prices_tools "$work/published.json")"
  ( cd "$work" && ARTISAN_ROLE=prices-check "$CLAUDE" -p "$prompt" "${HEADLESS_ARGS[@]}" \
      --model "${ARTISAN_PRICES_MODEL:-claude-sonnet-5-5}" --max-budget-usd "${ARTISAN_PRICES_BUDGET:-0.50}" \
      --output-format json >"$work/prices-session.json" 2>"$work/prices-session.err" ) \
    || failed "the prices agent failed (see $work/prices-session.err)"
  denied=$(headless_denied_calls "$work/prices-session.json" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
  [ -s "$work/published.json" ] || failed "the prices agent wrote no $work/published.json${denied:+ (denied tools: $denied)}"
  ( check_shape "$work/published.json" ) 2>/dev/null || failed "the prices agent's answer $work/published.json is not {\"models\": {<id>: {input_per_mtok, output_per_mtok}}} with positive numbers"
}

cmd_compare() {
  local pub=${1:-} rows=
  [ -n "$pub" ] || usage
  check_shape "$FILE"; check_shape "$pub"
  rows=$(jq -r --slurpfile p "$pub" '
    . as $r | ($p[0].models) as $new
    | ( ($new | keys[]) as $m
        | ($r.models[$m]) as $old | $new[$m] as $n
        | if $old == null then [$m, "not recorded", "$\($n.input_per_mtok * 1) / $\($n.output_per_mtok * 1)"]
          elif $old.input_per_mtok != $n.input_per_mtok or $old.output_per_mtok != $n.output_per_mtok
            then [$m, "$\($old.input_per_mtok * 1) / $\($old.output_per_mtok * 1)", "$\($n.input_per_mtok * 1) / $\($n.output_per_mtok * 1)"]
          else empty end ),
      ( ($r.models | keys[]) as $m | select($new[$m] == null)
        | [$m, "$\($r.models[$m].input_per_mtok * 1) / $\($r.models[$m].output_per_mtok * 1)", "not in the published answer (kept)"] )
    | @tsv' "$FILE")
  if [ -z "$rows" ]; then echo "no price change"; return 0; fi
  printf '## Model prices differ from the published pricing\n\n'
  printf '| Model | Recorded (input / output per Mtok) | Published |\n|---|---|---|\n'
  printf '%s\n' "$rows" | awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
  printf '\nUpdate model prices?\n'
  return 10
}

cmd_apply() {
  local pub=${1:-} today= tmp=
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
