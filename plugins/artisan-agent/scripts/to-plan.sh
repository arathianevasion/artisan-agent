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
#   to-plan.sh check   <plans.json> --graph FILE [--override-human-check <ticket> "<criterion>" --why TEXT]...
#                                  verify every ticket is in one plan, no blocker comes after its
#                                  dependent and a Human check is in its agent ticket's plan; then
#                                  refuse approval (exit 1, the flags printed under "Needs your
#                                  attention") while an agent criterion reads as needing a person.
#                                  Each override is recorded on the plan (human_check_overrides).
#   to-plan.sh render  <plans.json> --graph FILE      the approval view (Markdown): a table of plans,
#                                  then each plan's tickets with their acceptance criteria
#   to-plan.sh split-human-check --repo owner/name [--graph FILE [--plans FILE]] [--what TEXT] <ticket> "<criterion>"
#                                  move the criterion off the agent ticket into its Human check
#                                  ticket (references/human-checks.md): title "Human check: <what>
#                                  (#<ticket>)" (what defaults to the ticket's title), the marker,
#                                  ready-for-human, blocked by the ticket. Creates it, or adds to the
#                                  open one for that ticket; a repeat changes nothing. The graph and
#                                  --plans (the agent ticket's plan), when given, follow.
#   to-plan.sh publish <plans.json> --graph FILE --repo owner/name --approved [--replace-parent]
#                      [--override-human-check <ticket> "<criterion>" --why TEXT]...
#                                  create one `plan` issue per plan, each ticket a sub-issue of
#                                  its plan, and a later plan blocked by the earlier plans it
#                                  depends on. Needs --approved: the Artisan's approval. The
#                                  issue numbers are written back into plans.json, so a repeat
#                                  run carries on where a failed one stopped.
#
# A criterion "reads as needing a person" when it holds a phrase from
# references/human-checks.md or the project's human_check_phrases (config.sh;
# --config FILE to name the config file).
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
GRAPH= REPO= BUDGET= APPROVED= REPLACE_PARENT= POS= PLANS= WHAT= CONFIG= OVERRIDES='[]'
parse() {
  POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --override-human-check)
        [ $# -ge 3 ] || usage
        OVERRIDES=$(jq -c --arg t "$2" --arg c "$3" '. + [{ticket: ($t | ltrimstr("#")), criterion: $c, why: ""}]' <<<"$OVERRIDES")
        shift 3 ;;
      --why)
        [ $# -ge 2 ] || usage
        [ "$(jq length <<<"$OVERRIDES")" -gt 0 ] || die "--why follows the --override-human-check it gives the reason for"
        OVERRIDES=$(jq -c --arg w "$2" '.[-1].why = $w' <<<"$OVERRIDES")
        shift 2 ;;
      --plans) [ $# -ge 2 ] || usage; PLANS=$2; shift 2 ;;
      --what) [ $# -ge 2 ] || usage; WHAT=$2; shift 2 ;;
      --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
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
# The project's own phrases (config human_check_phrases) for to-plan.py.
# Outside a git repository with no --config, only the reference's list.
phrases() {
  local p=
  if [ -n "$CONFIG" ]; then
    p=$("$SCRIPT_DIR/config.sh" show --file "$CONFIG") || exit 1
  elif git rev-parse --git-common-dir >/dev/null 2>&1; then
    p=$("$SCRIPT_DIR/config.sh" show) || exit 1
  else
    p='{}'
  fi
  TO_PLAN_EXTRA_PHRASES=$(jq -c '.human_check_phrases // []' <<<"$p")
  export TO_PLAN_EXTRA_PHRASES
}
# Record any --override-human-check on the plans file, then check it.
check_plans() {
  phrases
  if [ "$(jq length <<<"$OVERRIDES")" -gt 0 ]; then py override "$1" "$GRAPH" "$OVERRIDES"; fi
  py check "$1" "$GRAPH"
}

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
    check_plans "${POS[0]}" ;;

  render)
    parse "$@"; need_graph
    [ "${#POS[@]}" -eq 1 ] || usage
    phrases
    py render "${POS[0]}" "$GRAPH" ;;

  split-human-check)
    parse "$@"; need gh; need_repo
    [ -z "$GRAPH" ] || need_graph
    [ -z "$PLANS" ] || [ -n "$GRAPH" ] || die "--plans needs --graph"
    [ "${#POS[@]}" -eq 2 ] || usage
    agent=${POS[0]#\#}
    printf '%s' "$agent" | grep -Eq '^[0-9]+$' || die "the agent ticket must be a number, got \"${POS[0]}\""
    [ -z "$PLANS" ] || [ -f "$PLANS" ] || die "no such plans file: $PLANS"
    issue=$(gh issue view "$agent" -R "$REPO" --json number,title,body) || die "cannot read #$agent"
    marker="<!-- artisan-agent:human-check-for #$agent -->"
    open=$(gh issue list -R "$REPO" --state open --limit 1000 --json number,title,body) \
      || die "cannot list the open issues to find #$agent's Human check"
    hc=$(jq -r --arg m "$marker" '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].number // empty' <<<"$open")
    hc_body=null
    [ -z "$hc" ] || hc_body=$(jq --argjson n "$hc" '.[] | select(.number == $n) | .body // ""' <<<"$open")
    req=$(jq -n --argjson i "$issue" --argjson hb "$hc_body" --arg c "${POS[1]}" --arg w "$WHAT" \
      '{agent: ($i.number | tostring), agent_title: $i.title, agent_body: ($i.body // ""),
        criterion: $c, hc_body: $hb, what: (if $w == "" then null else $w end)}')
    plan=$(py split-text <<<"$req") || exit 1
    crit=$(jq -r .criterion <<<"$plan")
    title=$(jq -r .title <<<"$plan")
    # The Human check first, then the edge, then the agent ticket: a run that
    # stops part way leaves the criterion in both places, and a repeat finishes it.
    if [ -z "$hc" ]; then
      url=$(gh issue create -R "$REPO" --title "$title" --body "$(jq -r .hc_body <<<"$plan")" --label ready-for-human) \
        || die "could not create the Human check for #$agent (does the ready-for-human label exist on $REPO?)"
      hc=${url##*/}
      printf '%s' "$hc" | grep -Eq '^[0-9]+$' || die "could not read the new issue number from: $url"
    elif [ "$(jq -r '.hc_body != null' <<<"$plan")" = true ]; then
      gh issue edit "$hc" -R "$REPO" --body "$(jq -r .hc_body <<<"$plan")" >/dev/null \
        || die "could not add the criterion to Human check #$hc"
    fi
    aid=$(gh api "repos/$REPO/issues/$agent" | jq -r '.id // empty') && [ -n "$aid" ] \
      || die "cannot look up the id of #$agent; run split-human-check again"
    if ! err=$(gh api --method POST "repos/$REPO/issues/$hc/dependencies/blocked_by" -F "issue_id=$aid" 2>&1 >/dev/null); then
      case "$err" in
        *[Aa]lready*) ;;
        *) die "could not block Human check #$hc by #$agent: $err (run split-human-check again)" ;;
      esac
    fi
    if [ "$(jq -r '.agent_body != null' <<<"$plan")" = true ]; then
      gh issue edit "$agent" -R "$REPO" --body "$(jq -r .agent_body <<<"$plan")" >/dev/null \
        || die "could not take the criterion off #$agent (Human check #$hc has it); run split-human-check again"
    fi
    [ -z "$GRAPH" ] || py split-files "$GRAPH" "$PLANS" "$agent" "$hc" "$crit" "$title"
    printf 'Human check #%s for #%s: %s\n' "$hc" "$agent" "$crit" ;;

  publish)
    parse "$@"; need gh; need_graph; need_repo
    [ "${#POS[@]}" -eq 1 ] || usage
    file=${POS[0]}
    [ -n "$APPROVED" ] || die "publish needs --approved: plans are created only once the Artisan has approved them"
    check_plans "$file"
    deps=$(py deps "$file" "$GRAPH")
    count=$(jq '.plans | length' "$file")
    save() { jq "$@" "$file" >"$file.tmp" && mv "$file.tmp" "$file"; }
    # The database id of issue $1. Runs in a command substitution, so callers
    # add `|| exit 1`: a failed lookup stops here, before any write is attempted.
    dbid() {
      local out= id=
      out=$(gh api "repos/$REPO/issues/$1") || die "cannot look up the id of #$1 (gh api failed); nothing was written for it, run publish again"
      id=$(printf '%s' "$out" | jq -r '.id // empty') && [ -n "$id" ] || die "the tracker returned no id for #$1; run publish again"
      printf '%s' "$id"
    }

    # 1. One issue per plan, earliest first, so a later plan can name them.
    i=0
    while [ "$i" -lt "$count" ]; do
      if [ "$(jq -r --argjson i "$i" '.plans[$i].issue // empty' "$file")" = "" ]; then
        title=$(jq -r --argjson i "$i" '"Plan \($i + 1): \(.plans[$i].slice)"' "$file")
        body=$(jq -r --argjson i "$i" --slurpfile g "$GRAPH" '
          .plans[$i] as $p
          | ($p.tickets | map(. as $t | "- [ ] #\($t) (\($g[0].tickets[$t].title))") | join("\n")) as $list
          | ([(.human_check_overrides // [])[] | select(.ticket as $t | $p.tickets | index($t))
              | "- #\(.ticket): \"\(.criterion)\" stays on the agent ticket. Why: \(.why)"] | join("\n")) as $ov
          | (if $ov == "" then "" else "\n\n## Human-check overrides\n\($ov)" end) as $ov
          | "A plan: tickets the Artisan approved to run together, ending at a slice reviewable end to end.\n\nEnds at: \($p.slice)\n\n## Tickets\n\($list)\($ov)\n\nCreated by `/artisan-agent:to-plan`. Run it with `/artisan-agent:implement-plan`."' "$file")
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
        tid=$(dbid "$t") || exit 1
        args=(-F "sub_issue_id=$tid")
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
        bid=$(dbid "$blocker") || exit 1
        if ! err=$(gh api --method POST "repos/$REPO/issues/$plan_no/dependencies/blocked_by" -F "issue_id=$bid" 2>&1 >/dev/null); then
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
