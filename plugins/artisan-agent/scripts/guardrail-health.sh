#!/usr/bin/env bash
# The retro's guardrail health, moves and audits (#74). Reads the run history
# (state files' event logs); proposes, never changes. Loosening is made only by
# `guardrails.sh loosen`, after the Artisan has seen the evidence here.
# Rules and event shapes: ${CLAUDE_PLUGIN_ROOT}/references/guardrail-health.md.
#
# Usage (--runs takes run folders, oldest first; --table prints markdown):
#   guardrail-health.sh health --runs DIR... [--threshold N] [--misses FILE] [--table] [--record]
#       each guardrail in force (guardrails.sh resolve) as fired, bypassed (with
#       reasons) or never fired, with its origin, and the moves its evidence
#       supports: loosen or tighten once it reaches the threshold (default 3).
#       The scope floor and a defer-only gate never get a loosen proposal.
#       Guardrail conflicts and evidence both ways are raised, not resolved.
#       --record keeps the report ({id, date, proposals}) as the latest one in
#       ARTISAN_HEALTH_DIR (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent-health/latest.json):
#       `guardrails.sh loosen` acts only on a guardrail that report proposes.
#   guardrail-health.sh spot-check --runs DIR... [--count N]
#       about N (default 3) decisions a worker made alone that no gate showed
#   guardrail-health.sh spot-check-record --run DIR --ticket T --card I --answer same|differently [--area A] [--guardrail ID]
#       record the answer: "differently" is tighten evidence in the area
#   guardrail-health.sh audit --runs DIR... [--misses FILE] [--threshold N] [--table]
#       triage misses with the criterion that should have caught them, and
#       patterns in the runs' discards and deferrals
#   guardrail-health.sh hands-on --runs DIR... [--nudge-after N]
#       whether the newest run had a hands-on ticket (ask what the Artisan
#       decided that an agent would have needed) and whether to nudge (N runs, default 5, with none)
#   guardrail-health.sh backstop --runs DIR... [--repo-dir D] [--main REF] [--since DATE]
#       [--prs FILE] [--closed FILE] [--table]
#       (pass --since: without it every ticket ever closed is checked)
#       commits straight to main, PRs and merges with no run record, tickets
#       closed outside a run. --prs and --closed are JSON files standing in for
#       `gh pr list` and `gh issue list`.
#
# Exit status: 0 ok, 1 error, 2 usage.
# Portable to bash 3.2 and Linux. Needs git, jq (gh for backstop without --prs/--closed).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }

RUNS=()
TABLE=0
RECORD=0
THRESHOLD=3
MISSES=""
VALUE_OPTS=""   # a command's own options that take a value; each lands in OPT_<name>, dashes as underscores
parse_common() { # sets RUNS, TABLE, THRESHOLD, MISSES, OPT_*, REST (array of unparsed words)
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs) shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do RUNS+=("$1"); shift; done ;;
      --table) TABLE=1; shift ;;
      --record) RECORD=1; shift ;;
      --threshold) [ $# -ge 2 ] || usage; THRESHOLD=$2; shift 2 ;;
      --misses) [ $# -ge 2 ] || usage; MISSES=$2; shift 2 ;;
      *) if [[ " $VALUE_OPTS " == *" $1 "* ]]; then
           [ $# -ge 2 ] || usage
           printf -v "OPT_$(printf %s "${1#--}" | tr - _)" %s "$2"; shift 2
         else REST+=("$1"); shift; fi ;;
    esac
  done
  state_is_uint "$THRESHOLD" || usage
}

state_files() { # prints each run's state.json; refuses none or a folder without one
  local d
  [ ${#RUNS[@]} -gt 0 ] || usage
  for d in "${RUNS[@]}"; do
    [ -f "$d/state.json" ] || state_die 1 "guardrail-health.sh: no state.json in $d"
  done
  for d in "${RUNS[@]}"; do printf '%s\n' "$d/state.json"; done
}

misses_json() { # the triage misses as a JSON array
  if [ -n "$MISSES" ] && [ -f "$MISSES" ]; then jq -sc 'map(select(type == "object"))' "$MISSES"; else echo '[]'; fi
}

states_json() { # every state as one array
  local files
  state_files >/dev/null || exit $?
  files=()
  for d in "${RUNS[@]}"; do files+=("$d/state.json"); done
  jq -sc '.' "${files[@]}"
}

# ------------------------------------------------------------------ health

HEALTH_JQ='
def evs: [.states[] | . as $s | (.events // [])[] | . + {run: $s.run_id}];
def match($g): (.guardrail == $g.id) or ((.area // null) != null and $g.area != null and .area == $g.area);
def hits($name; $g): [evs[] | select(.event == $name and match($g))];
def decided($g): [evs[] | select(.event == "gate-decision" and match($g))];
def row($g):
  (hits("guardrail-fired"; $g)) as $fired
  | (hits("guardrail-bypassed"; $g)) as $byp
  | ($byp | map(select((.reason // "") != ""))) as $reasoned
  | (decided($g) | map(select((.outcome // "keep") == "keep" and ((.redirect // false) | not)))) as $unchanged
  | (decided($g) | map(select(.outcome == "change" or (.redirect // false)))) as $redirects
  | ([evs[] | select(.event == "spot-check" and .answer == "differently" and match($g))]) as $differently
  | ([.misses[] | select(match($g))]) as $misses
  | ([evs[] | select(.event == "shipped-bug" and match($g))]) as $bugs
  | (if ($fired | length) == 0 and ($byp | length) == 0 then ([.states[] | select([(.events // [])[] | select(.event == "guardrail-fired" or .event == "guardrail-bypassed")] | length > 0)] | length) else 0 end) as $never
  | ([ ($reasoned | map({kind: "bypass", reason: .reason, run: .run})[]),
       ($unchanged | map({kind: "gate approved unchanged", gate: .gate, run: .run})[]),
       (if $never > 0 then {kind: "never fired", runs: $never} else empty end) ]) as $loosen
  | ([ ($redirects | map({kind: "redirect at gate", gate: .gate, run: .run})[]),
       ($differently | map({kind: "spot-check: decided differently", ticket: .ticket, run: .run})[]),
       ($misses | map({kind: "triage miss", ticket: .ticket, criterion: (.criterion // null)})[]),
       ($bugs | map({kind: "shipped bug", ticket: .ticket, run: .run})[]) ]) as $tighten
  | { id: $g.id, level: $g.level, key: $g.key, value: $g.value, area: $g.area,
      origin: $g.origin, protected: $g.protected,
      status: (if ($byp | length) > 0 then "bypassed" elif ($fired | length) > 0 then "fired" else "never fired" end),
      fired: ($fired | length),
      bypassed: ($byp | map({reason: (.reason // null), by: (.by // null), run: .run})),
      loosen: {count: (if $never > 0 then $never else ($reasoned | length) + ($unchanged | length) end), evidence: $loosen},
      tighten: {count: ($tighten | length), evidence: $tighten} };
. as $in
| [.resolved.applied[] | . as $g | $in | row($g)] as $rows
| ($rows | map(
    if (.loosen.count >= $th and .tighten.count >= $th) then
      {id, move: "conflict", why: "evidence both ways: \(.loosen.count) to loosen, \(.tighten.count) to tighten; raised, neither proposed"}
    elif .tighten.count >= $th then
      {id, move: "tighten", evidence: .tighten.evidence}
    elif .loosen.count >= $th and (.protected | not) then
      {id, move: "loosen", evidence: .loosen.evidence}
    else empty end)) as $props
| { runs: (.states | length), threshold: $th, guardrails: $rows, proposals: $props,
    never_loosen: [$rows[] | select(.protected and .loosen.count >= $th) | .id],
    conflicts: .resolved.conflicts, overridden: .resolved.overridden }'

health_table() {
  jq -r "$(state_jq_row_def)"'
    def origin: if .origin then "\(.origin.date // "?") \(.origin.who // "?"): \(.origin.reason // "")" else "no origin recorded" end;
    def st: if .status == "bypassed" then "bypassed (" + ([.bypassed[] | .reason // "no reason"] | join("; ")) + ")" else .status end;
    "Guardrail health over \(.runs) run(s); a move is proposed at \(.threshold) events.", "",
    "| Guardrail | Level | Status | Origin | Loosen evidence | Tighten evidence | Move |",
    "|---|---|---|---|---|---|---|",
    (. as $r | .guardrails[] | . as $g
      | [.id, .level, st, origin, "\(.loosen.count)", "\(.tighten.count)",
         (([$r.proposals[] | select(.id == $g.id) | .move] | first) // (if ($r.never_loosen | index($g.id)) then "never loosens" else "none" end))] | row),
    (if (.conflicts | length) > 0 then "", "Guardrail conflicts raised: " + (.conflicts | join(", ")) else empty end)' <<<"$1"
}

cmd_health() {
  parse_common "$@"
  [ ${#REST[@]} -eq 0 ] || usage
  local states misses resolved out
  states=$(states_json)
  misses=$(misses_json)
  resolved=$("$SCRIPT_DIR/guardrails.sh" resolve)
  out=$(jq -n --argjson states "$states" --argjson misses "$misses" --argjson resolved "$resolved" --argjson th "$THRESHOLD" \
    '{states: $states, misses: $misses, resolved: $resolved} | '"$HEALTH_JQ")
  if [ "$RECORD" = 1 ]; then
    local dir=${ARTISAN_HEALTH_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent-health} now
    now=$(state_now)
    mkdir -p "$dir"
    jq -n --argjson now "$now" --argjson out "$out" \
      '{id: "health-\($now)", date: ($now | todate), runs: $out.runs, threshold: $out.threshold, proposals: $out.proposals}' >"$dir/latest.json.tmp.$$"
    mv "$dir/latest.json.tmp.$$" "$dir/latest.json"
  fi
  if [ "$TABLE" = 1 ]; then health_table "$out"; else printf '%s\n' "$out"; fi
}

# -------------------------------------------------------------- spot-check

cmd_spot_check() {
  VALUE_OPTS="--count"
  parse_common "$@"
  [ ${#REST[@]} -eq 0 ] || usage
  local count=${OPT_count:-3}
  state_is_uint "$count" || usage
  states_json | jq -c --argjson n "$count" '
    [.[] | . as $s
      | ([($s.review_gates // [])[] | (.tickets // [])[] | tostring] + [($s.provisional_shown // [])[] | tostring]) as $shown
      | ($s.tickets // {}) | to_entries[]
      | select(.key as $t | ($shown | index($t)) | not)
      | .key as $t | (.value.evidence.decisions // []) | to_entries[]
      | {run: $s.run_id, ticket: $t, card: .key, question: .value.question, choice: .value.choice,
         alternative: (.value.alternative // .value.alternative_considered // null),
         area: (.value.area // null), provisional: ((.value.confidence // "provisional") == "provisional")}]
    | (map(select(.provisional)) + map(select(.provisional | not))) | .[:$n]
    | {asked: ., question: "Would you have decided any of these differently?"}'
}

cmd_spot_check_record() {
  local run="" ticket="" card="" answer="" area="" guardrail=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run | --ticket | --card | --answer | --area | --guardrail) [ $# -ge 2 ] || usage
        case "$1" in --run) run=$2 ;; --ticket) ticket=$2 ;; --card) card=$2 ;; --answer) answer=$2 ;; --area) area=$2 ;; --guardrail) guardrail=$2 ;; esac
        shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$run" ] && [ -n "$ticket" ] && [ -n "$card" ] || usage
  case "$answer" in same | differently) ;; *) usage ;; esac
  "$SCRIPT_DIR/state.sh" event "$run" "$(jq -nc --arg t "$ticket" --arg c "$card" --arg a "$answer" --arg area "$area" --arg g "$guardrail" \
    '{event: "spot-check", ticket: $t, card: ($c | tonumber), answer: $a} + (if $area == "" then {} else {area: $area} end) + (if $g == "" then {} else {guardrail: $g} end)')" >/dev/null
}

# ------------------------------------------------------------------- audit

AUDIT_JQ='
def key: (.area // .reason // "unspecified");
{ misses: [.misses[] | {ticket, criterion: (.criterion // null),
    suggestion: (if .criterion then "Check controversy criterion \(.criterion) catches this kind of recommendation" else "No criterion recorded: name the criterion that should have caught it" end)}],
  discards: (
    [.states[] | . as $s
      | ( [(.events // [])[] | select(.event == "pulled" or .event == "deferred-question")
           | {run: $s.run_id, ticket, what: (if .event == "pulled" then "pulled" else "deferred question" end), key: key}]
        + [($s.tickets // {}) | to_entries[] | select(.value.status == "closed")
           | {run: $s.run_id, ticket: .key, what: "closed unmerged", key: (.value.area // "unspecified")}] )[]]
    | group_by(.key)
    | map({key: .[0].key, count: length, items: ., repeated: (length >= $th),
           suggestion: (if length >= $th then "Repeated \(length) times for \(.[0].key): raise a guardrail or criterion covering it" else null end)})) }'

cmd_audit() {
  parse_common "$@"
  [ ${#REST[@]} -eq 0 ] || usage
  local out
  out=$(jq -n --argjson states "$(states_json)" --argjson misses "$(misses_json)" --argjson th "$THRESHOLD" \
    '{states: $states, misses: $misses} | '"$AUDIT_JQ")
  if [ "$TABLE" = 1 ]; then
    jq -r "$(state_jq_row_def)"'
      "| Triage miss | Criterion | Suggestion |", "|---|---|---|",
      (.misses[] | ["#\(.ticket)", (.criterion // "none" | tostring), .suggestion] | row),
      "", "| Discards and deferrals | Count | Suggestion |", "|---|---|---|",
      (.discards[] | [.key, "\(.count)", (.suggestion // "below the threshold")] | row)' <<<"$out"
  else printf '%s\n' "$out"; fi
}

# ----------------------------------------------------------------- hands-on

cmd_hands_on() {
  VALUE_OPTS="--nudge-after"
  parse_common "$@"
  [ ${#REST[@]} -eq 0 ] || usage
  local after=${OPT_nudge_after:-5}
  state_is_uint "$after" || usage
  states_json | jq -c --argjson after "$after" '
    map([(.events // [])[] | select(.event == "human-done")] | length > 0) as $flags
    | ($flags | length) as $n
    | ([range(0; $n) | select($flags[.])] | last) as $last
    | (if $last == null then $n else $n - 1 - $last end) as $since
    | {hands_on_latest: ($n > 0 and $flags[$n - 1]), runs_since_hands_on: $since,
       ask: (if $n > 0 and $flags[$n - 1] then "What did you decide that an agent would have needed? Which ADR or guardrail would have let an agent build it your way?" else null end),
       nudge: ($since >= $after),
       nudge_text: (if $since >= $after then "\($since) runs with no hands-on work: take a ticket yourself soon, so the guardrails keep learning how you decide." else null end)}'
}

# ----------------------------------------------------------------- backstop

cmd_backstop() {
  VALUE_OPTS="--repo-dir --main --since --prs --closed"
  parse_common "$@"
  [ ${#REST[@]} -eq 0 ] || usage
  local repo_dir=${OPT_repo_dir:-.} main=${OPT_main:-main} since=${OPT_since:-} prs=${OPT_prs:-} closed=${OPT_closed:-}
  local states repo prs_json closed_json commits=""
  states=$(states_json)
  repo=$(jq -r '.[0].repo // ""' <<<"$states")
  if [ -n "$prs" ]; then prs_json=$(cat "$prs")
  else prs_json=$(gh pr list -R "$repo" --state merged --limit 200 --json number,headRefName,mergeCommit,mergedAt) \
    || state_die 1 "guardrail-health.sh: could not list merged PRs; pass --prs FILE"; fi
  if [ -n "$closed" ]; then closed_json=$(cat "$closed")
  else closed_json=$(gh issue list -R "$repo" --state closed --limit 200 --json number,closedAt) \
    || state_die 1 "guardrail-health.sh: could not list closed tickets; pass --closed FILE"; fi
  # first-parent commits on main: "<sha> <parent count>"
  commits=$(git -C "$repo_dir" log --first-parent ${since:+--since="$since"} --format='%H %P' "$main" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ") | {sha: .[0], parents: (length - 1)})')
  local out
  out=$(jq -n --argjson states "$states" --argjson prs "$prs_json" --argjson closed "$closed_json" \
    --argjson commits "$commits" --arg since "$since" '
    ([$states[] | (.integration.merges // [])[] | .commit]) as $runcommits
    | ([$states[] | .integration.branch // empty] + [$states[] | (.tickets // {}) | to_entries[] | (.value.branch // "agent/\(.key)")]) as $branches
    | ([$prs[] | .mergeCommit.oid // .mergeCommit // empty]) as $prcommits
    | ([$states[] | (.tickets // {}) | to_entries[] | select(.value.status == "merged" or .value.status == "closed") | .key]
       + [$states[] | (.events // [])[] | select(.event == "closed") | .ticket | tostring]) as $inrun
    | { direct_commits: [$commits[] | select(.parents == 1 and ((.sha | IN($prcommits[])) | not) and ((.sha | IN($runcommits[])) | not)) | .sha],
        unrecorded_merges: [$commits[] | select(.parents > 1 and ((.sha | IN($prcommits[])) | not) and ((.sha | IN($runcommits[])) | not)) | .sha],
        prs_without_run: [$prs[] | select((.headRefName | IN($branches[])) | not) | {number, headRefName}],
        tickets_closed_outside_run: [$closed[] | select(($since == "" or (.closedAt // "") >= $since) and ((.number | tostring) | IN($inrun[]) | not)) | .number] }')
  if [ "$TABLE" = 1 ]; then
    jq -r "$(state_jq_row_def)"'
      "| Backstop | What | Flagged |", "|---|---|---|",
      (.direct_commits[] | ["direct commit to main", .[0:10], "no PR, no run record"] | row),
      (.unrecorded_merges[] | ["merge to main", .[0:10], "no PR, no run record"] | row),
      (.prs_without_run[] | ["PR with no run record", "#\(.number) (\(.headRefName))", "no run opened its branch"] | row),
      (.tickets_closed_outside_run[] | ["ticket closed outside a run", "#\(.)", "no run merged or closed it"] | row)' <<<"$out"
  else printf '%s\n' "$out"; fi
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  health) cmd_health "$@" ;;
  spot-check) cmd_spot_check "$@" ;;
  spot-check-record) cmd_spot_check_record "$@" ;;
  audit) cmd_audit "$@" ;;
  hands-on) cmd_hands_on "$@" ;;
  backstop) cmd_backstop "$@" ;;
  *) usage ;;
esac
