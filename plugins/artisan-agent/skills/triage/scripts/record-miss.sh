#!/usr/bin/env bash
# Record a triage miss: the Artisan reversed an "uncontroversial" recommendation.
# Usage: record-miss.sh <ticket> <criterion 1-7|new> <recommended> <ruled> <reason>
# Appends one JSON line to $ARTISAN_AGENT_DIR/triage/misses.jsonl
# (default ./.artisan-agent/triage/misses.jsonl). The folder keeps itself out of git.
# Portable to bash 3.2.
set -euo pipefail

[ $# -eq 5 ] || { echo "usage: record-miss.sh <ticket> <criterion 1-7|new> <recommended> <ruled> <reason>" >&2; exit 2; }
ticket=${1#\#}; criterion=$2; recommended=$3; ruled=$4; reason=$5

case "$ticket" in ''|*[!0-9]*) echo "ticket must be a number: $1" >&2; exit 2 ;; esac
# Normalise: local-markdown tickets are numbered 01, 02...; JSON numbers can't have leading zeros.
ticket=$(printf '%s' "$ticket" | sed 's/^0*//'); [ -n "$ticket" ] || ticket=0
case "$criterion" in [1-7]|new) ;; *) echo "criterion must be 1-7 or new: $criterion" >&2; exit 2 ;; esac

esc() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

dir=${ARTISAN_AGENT_DIR:-.artisan-agent}/triage
mkdir -p "$dir"
[ -e "$dir/.gitignore" ] || printf '*\n' > "$dir/.gitignore"

if [ "$criterion" = new ]; then crit_json='null'; else crit_json=$criterion; fi
run=${ARTISAN_RUN_ID:-}
if [ -n "$run" ]; then run_json="\"$(esc "$run")\""; else run_json=null; fi

printf '{"ts":"%s","ticket":%s,"recommended":"%s","ruled":"%s","criterion_that_should_have_caught_it":%s,"reason":"%s","run_id":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ticket" "$(esc "$recommended")" "$(esc "$ruled")" \
  "$crit_json" "$(esc "$reason")" "$run_json" >> "$dir/misses.jsonl"
