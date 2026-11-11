#!/usr/bin/env bash
# The ADR and guardrail check at plan approval (#67): the mechanical half. An
# agent reads the ADRs and the tickets and writes a check file; this script
# validates it against the ADRs on disk and prints the approval view. The
# procedure, and the adjustment loop, are in references/adr-check.md.
#
# Usage:
#   adr-check.sh list   [--adr-dir D]                    ADRs as JSON: number, file, title
#   adr-check.sh refs   [--adr-dir D]                    read text on stdin; print the number of
#                                                        each existing ADR it cites (ADR 0001,
#                                                        ADR-1, docs/adr/0001-...), one per line
#   adr-check.sh render <check.json> [--adr-dir D] [--guardrails resolve.json]
#                                                        the approval view (Markdown tables): plan
#                                                        compliance, each ticket's ADRs with tension
#                                                        flagged, ADR gaps, then guardrail conflicts
#                                                        with the level that applies (the output of
#                                                        `guardrails.sh resolve`)
#   adr-check.sh affected <check.json> --adr N           tickets whose ADRs include N: the ones to
#                                                        re-check after N is edited
#
# check.json: {"plan_adrs": [{"adr","compliance","note"}],
#              "tickets":   [{"ticket","title","adrs":[{"adr","tension","note"}]}],
#              "gaps":      [{"decision","tickets":[],"suggestion"}]}
# `adr` is a number such as "0001"; one that no file in the ADR directory has is
# refused. --adr-dir defaults to docs/adr at the repo root.
# Exit status: 0 ok, 1 refused (unknown ADR, bad file), 2 usage.

set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
cmd=$1; shift
adr_dir="" file="" gfile="" adr_n=""
while [ $# -gt 0 ]; do
  case "$1" in
    --adr-dir) [ $# -ge 2 ] || usage; adr_dir=$2; shift 2 ;;
    --guardrails) [ $# -ge 2 ] || usage; gfile=$2; shift 2 ;;
    --adr) [ $# -ge 2 ] || usage; adr_n=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$file" ] || usage; file=$1; shift ;;
  esac
done
if [ -z "$adr_dir" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository; pass --adr-dir"
  adr_dir="$root/docs/adr"
fi

# adrs_json: [{number, file, title}]
adrs_json() {
  local f n t out=""
  for f in "$adr_dir"/[0-9][0-9][0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" | cut -c1-4)
    t=$(sed -n 's/^# *//p' "$f" | head -n 1)
    out="$out$(jq -nc --arg n "$n" --arg f "$(basename "$f")" --arg t "$t" '{number: $n, file: $f, title: $t}')"$'\n'
  done
  printf '%s' "$out" | jq -sc '.'
}

pad() { printf '%04d' "$((10#$1))"; }

need_check() {
  [ -f "$file" ] || die "no check file: ${file:-<none>}"
  jq -e '(.plan_adrs // []) | type == "array"' "$file" >/dev/null 2>&1 || die "$file is not a check file"
}

# refuse any ADR number in the check file that has no file
validate() {
  local known bad
  known=$(adrs_json)
  bad=$(jq -r --argjson known "$known" '
    [(.plan_adrs // [])[].adr, ((.tickets // [])[].adrs // [])[].adr] | unique
    | map(select(. as $a | ($known | map(.number) | index($a)) | not)) | join(", ")' "$file")
  [ -z "$bad" ] || die "ADR not found in $adr_dir: $bad"
}

case "$cmd" in
  list) adrs_json ;;
  refs)
    known=$(adrs_json | jq -r '.[].number')
    { grep -oiE 'ADR[ -]?[0-9]{1,4}|docs/adr/[0-9]{4}' || true; } | grep -oE '[0-9]+$' | while read -r n; do pad "$n"; echo; done | sort -u \
      | while read -r n; do printf '%s\n' "$known" | grep -qx "$n" && echo "$n"; done || true
    ;;
  affected)
    need_check; [ -n "$adr_n" ] || usage
    jq -r --arg a "$(pad "$adr_n")" '(.tickets // [])[] | select([.adrs[]?.adr] | index($a)) | .ticket' "$file"
    ;;
  render)
    need_check; validate
    known=$(adrs_json)
    echo "## ADR check"
    echo
    echo "### The plan against its ADRs"
    echo
    jq -r --argjson known "$known" '
      def t($n): ($known | map(select(.number == $n))[0].title // "");
      def cell: gsub("\\|"; "\\|") | gsub("\n"; " ");
      if ((.plan_adrs // []) | length) == 0 then "No ADR applies to this plan."
      else "| ADR | Title | Compliance | How |", "|---|---|---|---|",
        ((.plan_adrs // [])[] | "| \(.adr) | \(t(.adr) | cell) | \(.compliance // "complies" | cell) | \(.note // "" | cell) |") end' "$file"
    echo
    echo "### Each ticket against its ADRs"
    echo
    echo "| Ticket | ADR | Tension | Note |"
    echo "|---|---|---|---|"
    jq -r '
      def cell: gsub("\\|"; "\\|") | gsub("\n"; " ");
      (.tickets // [])[] | . as $t
      | (if (($t.adrs // []) | length) == 0 then [{adr: "none", tension: false, note: ""}] else $t.adrs end)[]
      | "| #\($t.ticket) (\($t.title // "" | cell)) | \(.adr) | \(if .tension then "TENSION" else "none" end) | \(.note // "" | cell) |"' "$file"
    echo
    echo "### Decisions no ADR covers yet"
    echo
    jq -r '
      def cell: gsub("\\|"; "\\|") | gsub("\n"; " ");
      if ((.gaps // []) | length) == 0 then "No gaps found."
      else "| Decision | Tickets | Suggested |", "|---|---|---|",
        ((.gaps // [])[] | "| \(.decision | cell) | \((.tickets // []) | map("#" + .) | join(", ")) | \(.suggestion // "" | cell) |") end' "$file"
    echo
    echo "### Guardrail conflicts"
    echo
    if [ -z "$gfile" ]; then
      echo "Guardrails not checked."
    else
      [ -f "$gfile" ] || die "no guardrails file: $gfile"
      jq -r '
        def cell: gsub("\\|"; "\\|") | gsub("\n"; " ");
        . as $r
        | if (($r.conflicts // []) | length) == 0 and (($r.own_reviews // []) | length) == 0 then "No conflicts between the three levels."
          else "| Guardrail | Applies | Overridden |", "|---|---|---|",
            (($r.conflicts // [])[] as $k
             | ($r.applied | map(select(.key == $k))[0]) as $w
             | "| \($k) | \($w.level // "?"): \($w.value // "?") | \([$r.overridden[] | select(.key == $k) | "\(.level): \(.value)"] | join("; ")) |"),
            (($r.own_reviews // [])[] | "| \(.key) | own-reviews: \(.level): \(.value) (the Artisan holding those gates) | |") end' "$gfile"
    fi
    ;;
  *) usage ;;
esac
