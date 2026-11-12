#!/usr/bin/env bash
# The engine behind /artisan-agent:to-plan: read the ticket graph, propose
# plans, let the Artisan edit them, show the approval view and, once approved,
# create the `plan` issues. Plans are files until `publish`; nothing touches
# the tracker before then except reading it.
#
# Usage:
#   to-plan.sh graph --repo owner/name <ticket>...     print the ticket graph (JSON): title,
#                                  acceptance criteria and blocked_by within the set for each
#                                  ticket, open blockers outside it as external_blockers. The
#                                  chat then adds each ticket's `slice` (a name for the
#                                  reviewable thing it contributes to) and its estimate
#                                  (`estimate_usd`, or `model` + `expected` tokens).
#   to-plan.sh propose --graph FILE --budget USD      print the proposed plans (JSON)
#   to-plan.sh split   <plans.json> --graph FILE <plan> <ticket,ticket,...>
#                                  move those tickets into a new plan after <plan>
#   to-plan.sh merge   <plans.json> --graph FILE <plan> <plan>
#   to-plan.sh reorder <plans.json> --graph FILE <order>   such as 2,1,3
#   to-plan.sh move    <plans.json> --graph FILE <ticket> <plan>
#                                  each edit rewrites the file, renumbering the plans, and is
#                                  refused (file untouched) if it would put a blocker in a
#                                  later plan than the ticket it blocks
#   to-plan.sh check   <plans.json> --graph FILE      verify every ticket is in one plan and no blocker
#                                  comes after its dependent
#   to-plan.sh render  <plans.json> --graph FILE      the approval view (Markdown): a table of plans,
#                                  then each plan's tickets with their acceptance criteria
#   to-plan.sh publish <plans.json> --graph FILE --repo owner/name --approved [--replace-parent]
#                                  create one `plan` issue per plan, each ticket a sub-issue of
#                                  its plan, and a later plan blocked by the earlier plans it
#                                  depends on. Needs --approved: the Artisan's approval. The
#                                  issue numbers are written back into plans.json, so a repeat
#                                  run carries on where a failed one stopped.
#
# The budget (USD) is the amount the Artisan would approve in one go; there is
# no default. Exit status: 0 ok, 1 refused (the reason is on stderr), 2 bad usage.
# Needs python3, jq and, for graph and publish, gh. Bash 3.2-safe.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PY=$SCRIPT_DIR/lib/to-plan.py

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'to-plan.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH"; }
need jq; need python3
py() { python3 -I "$PY" "$@"; }

# Common options, parsed from anywhere after the subcommand.
GRAPH= REPO= BUDGET= APPROVED= REPLACE_PARENT= POS=
parse() {
  POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --graph) [ $# -ge 2 ] || usage; GRAPH=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
      --budget) [ $# -ge 2 ] || usage; BUDGET=$2; shift 2 ;;
      --approved) APPROVED=1; shift ;;
      --replace-parent) REPLACE_PARENT=1; shift ;;
      -*) usage ;;
      *) POS+=("$1"); shift ;;
    esac
  done
}
need_repo() {
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "--repo must be owner/name, got \"$REPO\""
}
need_graph() { [ -n "$GRAPH" ] && [ -f "$GRAPH" ] || die "--graph FILE is required (and must exist)"; }

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  graph)
    parse "$@"; need gh; need_repo
    [ "${#POS[@]}" -gt 0 ] || usage
    numbers=$(printf '%s\n' "${POS[@]}" | sed 's/^#//')
    out='{"tickets":{}}'
    for n in $numbers; do
      issue=$(gh issue view "$n" -R "$REPO" --json number,title,body,state) || die "cannot read #$n"
      deps=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by") || die "cannot read the blockers of #$n (a missing edge could put a blocker after its dependent)"
      crit=$(printf '%s' "$issue" | jq -r '.body // ""' | awk '
        /^##[[:space:]]/ { in_ac = ($0 ~ /^##[[:space:]]+[Aa]cceptance [Cc]riteria/); next }
        in_ac && /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+/ { sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+/, ""); print }')
      out=$(jq --arg n "$n" --argjson issue "$issue" --argjson deps "$deps" --arg crit "$crit" \
            --arg set "$numbers" '
        ($set | split("\n") | map(select(. != ""))) as $in
        | .tickets[$n] = {
            title: $issue.title,
            acceptance: ($crit | split("\n") | map(select(. != ""))),
            blocked_by: [$deps[] | .number | tostring | select(. as $b | $in | index($b))],
            external_blockers: [$deps[] | select(.state == "open") | .number | tostring | select(. as $b | ($in | index($b)) | not)]
          }
        | if .tickets[$n].external_blockers == [] then del(.tickets[$n].external_blockers) else . end' <<<"$out")
    done
    printf '%s\n' "$out" ;;

  propose)
    parse "$@"; need_graph
    [ -n "$BUDGET" ] || die "--budget USD is required: the amount you would approve in one go"
    python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$BUDGET" 2>/dev/null \
      || die "--budget must be a positive number of dollars, got \"$BUDGET\""
    py propose "$GRAPH" "$BUDGET" ;;

  split|merge|reorder|move)
    parse "$@"; need_graph
    [ "${#POS[@]}" -ge 2 ] || usage
    file=${POS[0]}
    [ -f "$file" ] || die "no such plans file: $file"
    py edit "$file" "$GRAPH" "$cmd" "${POS[@]:1}" ;;

  check)
    parse "$@"; need_graph
    [ "${#POS[@]}" -eq 1 ] || usage
    py check "${POS[0]}" "$GRAPH" ;;

  render)
    parse "$@"; need_graph
    [ "${#POS[@]}" -eq 1 ] || usage
    py render "${POS[0]}" "$GRAPH" ;;

  publish)
    parse "$@"; need gh; need_graph; need_repo
    [ "${#POS[@]}" -eq 1 ] || usage
    file=${POS[0]}
    [ -n "$APPROVED" ] || die "publish needs --approved: plans are created only once the Artisan has approved them"
    py check "$file" "$GRAPH"
    deps=$(py deps "$file" "$GRAPH")
    count=$(jq '.plans | length' "$file")
    save() { jq "$@" "$file" >"$file.tmp" && mv "$file.tmp" "$file"; }
    dbid() { gh api "repos/$REPO/issues/$1" | jq -r '.id'; }

    # 1. One issue per plan, earliest first, so a later plan can name them.
    i=0
    while [ "$i" -lt "$count" ]; do
      if [ "$(jq -r --argjson i "$i" '.plans[$i].issue // empty' "$file")" = "" ]; then
        title=$(jq -r --argjson i "$i" '"Plan \($i + 1): \(.plans[$i].slice)"' "$file")
        body=$(jq -r --argjson i "$i" --slurpfile g "$GRAPH" '
          .plans[$i] as $p
          | ($p.tickets | map(. as $t | "- [ ] #\($t) (\($g[0].tickets[$t].title))") | join("\n")) as $list
          | "A plan: tickets the Artisan approved to run together, ending at a slice reviewable end to end.\n\nEnds at: \($p.slice)\n\n## Tickets\n\($list)\n\nCreated by `/artisan-agent:to-plan`. Run it with `/artisan-agent:implement-plan`."' "$file")
        url=$(gh issue create -R "$REPO" --title "$title" --body "$body" --label plan) \
          || die "could not create the plan issue (does the \`plan\` label exist on $REPO?)"
        num=${url##*/}
        printf '%s' "$num" | grep -Eq '^[0-9]+$' || die "could not read the new issue number from: $url"
        save --argjson i "$i" --argjson n "$num" '.plans[$i].issue = $n'
      fi
      i=$((i + 1))
    done

    # 2. Tickets become sub-issues of their plan; a ticket that already has a
    # parent (its spec) keeps it unless --replace-parent, and stays listed in
    # the plan's body either way.
    kept=0
    i=0
    while [ "$i" -lt "$count" ]; do
      plan_no=$(jq -r --argjson i "$i" '.plans[$i].issue' "$file")
      for t in $(jq -r --argjson i "$i" '.plans[$i].tickets[]' "$file"); do
        args=(-F "sub_issue_id=$(dbid "$t")")
        [ -z "$REPLACE_PARENT" ] || args+=(-F replace_parent=true)
        if ! err=$(gh api --method POST "repos/$REPO/issues/$plan_no/sub_issues" "${args[@]}" 2>&1 >/dev/null); then
          case "$err" in
            *[Pp]arent*) printf 'to-plan.sh: #%s stays under its existing parent (listed in the body of #%s only)\n' "$t" "$plan_no" >&2
                         kept=$((kept + 1)) ;;
            *) die "could not make #$t a sub-issue of #$plan_no: $err (carry on by running publish again)" ;;
          esac
        fi
      done
      i=$((i + 1))
    done

    # 3. Native blocking between dependent plans.
    i=0
    while [ "$i" -lt "$count" ]; do
      plan_no=$(jq -r --argjson i "$i" '.plans[$i].issue' "$file")
      for d in $(printf '%s' "$deps" | jq -r --argjson i "$i" '.[$i][]'); do
        blocker=$(jq -r --argjson d "$d" '.plans[$d].issue' "$file")
        if ! err=$(gh api --method POST "repos/$REPO/issues/$plan_no/dependencies/blocked_by" -F "issue_id=$(dbid "$blocker")" 2>&1 >/dev/null); then
          case "$err" in
            *[Aa]lready*) ;;
            *) die "could not block #$plan_no by #$blocker: $err (carry on by running publish again)" ;;
          esac
        fi
      done
      i=$((i + 1))
    done

    printf '| Plan | Issue | Tickets |\n|---|---|---|\n'
    jq -r '.plans | to_entries[] | "| Plan \(.key + 1) | #\(.value.issue) | \(.value.tickets | map("#" + .) | join(", ")) |"' "$file"
    [ "$kept" -eq 0 ] || printf '%s ticket(s) kept their existing parent; see the notes above\n' "$kept" >&2 ;;

  *) usage ;;
esac
