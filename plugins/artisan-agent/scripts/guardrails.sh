#!/usr/bin/env bash
# Guardrail levels, read at the point of use. What each level is, where it
# lives and the precedence: ${CLAUDE_PLUGIN_ROOT}/references/guardrails.md.
#
# Usage:
#   guardrails.sh sources [--no-fetch]
#       fetch the three sources and print each one's commit as JSON:
#       {team, product, individual}, each {commit, ...} or null.
#   guardrails.sh wave-start <run-dir> <wave>
#       the start of a wave, from wave.sh launch: fetch all three sources;
#       if a product guardrail changed on main, bring main into the run's
#       integration branch (in its worktree); record the plugin version and
#       each source's commit in the state file (state.sh wave-start). Prints
#       one JSON line. Exit 6: main would not merge cleanly (a decision is
#       queued, the wave is not recorded). When the run's base (integration.base)
#       is not in main, main is not merged on its own: exit 9, an exception
#       decision (reason guardrail-base: base, ref, commits each side lacks, the
#       changed guardrail files) is queued, answered with `state.sh decide <id>
#       merge|keep-base|halt`. merge brings main in (guardrail-merge, with by);
#       keep-base records the base's guardrails as the product's for the wave
#       (guardrail-base-kept) and is not asked again until the guardrail files
#       change again on main; halt halts the run (exit 10).
#   guardrails.sh resolve [--run-dir D] [--role product|engineering] [--ticket T[,T...]] [--areas A[,A...]]
#       the guardrails in force, as JSON: {sources, applied, own_reviews,
#       overridden, conflicts}. With --run-dir it reads each source at the
#       commit the latest wave recorded, so an edit made mid-wave applies
#       from the next one; without it, each source as committed now.
#       --role keeps an individual guardrail only if it has no role or this one.
#       --ticket (with --run-dir) and --areas keep an area-scoped guardrail (one
#       with an `area`) only if that area is among the tickets' areas
#       (`plan.tickets.<t>.areas`, set by gate-plan.sh propose) or the named
#       ones; with neither, every guardrail is listed, area-scoped or not.
#   guardrails.sh table [--run-dir D] [--role R] [--ticket T[,T...]] [--areas A[,A...]]
#       the "Guardrails applied" section for a packet, a markdown table.
#   guardrails.sh tighten --level individual|product|team --who NAME --reason TEXT
#       [--id ID] [--key K --value V --rule TEXT] [--strict N] [--evidence TEXT]
#       [--scope own-reviews] [--role product|engineering] [--run RUN-ID] [--pr]
#       write a new guardrail, or tighten an existing one (--id, a higher
#       --strict), with its origin or its move. individual: committed straight
#       to the individual home. product, team: a branch and commit in a
#       throwaway worktree (with --pr, pushed and opened as a PR); it applies
#       from the next wave once merged. Refuses a loosening (5): only a retro,
#       with evidence, loosens. Refuses a --who that names an agent (2).
#
#   guardrails.sh loosen --level individual|product|team --who NAME --reason TEXT
#       --id ID --strict N --evidence TEXT [--value V] [--rule TEXT] [--run RUN-ID]
#       [--override-reason TEXT [--run-dir D]] [--pr]
#       the retro's loosening path: lower an existing guardrail's --strict, with
#       the evidence and who, recorded as a `loosen` move. Needs --evidence and a
#       --strict below the current one (5 otherwise); refuses the scope floor
#       (key scope-floor) and a defer-only gate (defer_only: true) with 7. Only a
#       person, from a retro that showed the evidence (guardrail-health.sh).
#       It also needs the latest health report (`guardrail-health.sh health
#       --record`) to propose loosening this guardrail, and records the report's
#       id and date on the move; with none, or one that doesn't, it exits 8.
#       --override-reason TEXT proceeds anyway: the reason and --who are recorded
#       on the move as an override, and with --run-dir D a `guardrail-bypassed`
#       event is logged in that run's state file.
#
# Environment:
#   ARTISAN_HOME            the individual home (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent)
#   ARTISAN_TEAM_CACHE      where the team guardrails repo is cloned (default
#                           ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent-team)
#   ARTISAN_TEAM_URL_BASE   prefix for the team repo's clone URL (default https://github.com/)
#   ARTISAN_HEALTH_DIR      where `guardrail-health.sh health --record` keeps the latest report
#                           (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent-health)
#   ARTISAN_MAIN_REF        the product's main branch (default origin/main, else main)
#
# Exit status: 0 ok, 1 error (a source could not be fetched), 2 usage,
# 5 a loosening (tighten) or not a loosening (loosen), 6 merge conflict,
# 9 wave-start: the run's base is not in main, a decision is waiting, 10 wave-start: halted by that decision,
# 7 loosen refused: the scope floor or a defer-only gate, 8 loosen refused:
# the latest health report doesn't propose it (or there is none).
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "guardrails.sh: $*"; }

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
TEAM_CACHE=${ARTISAN_TEAM_CACHE:-$CFG/artisan-agent-team}
TEAM_URL_BASE=${ARTISAN_TEAM_URL_BASE:-https://github.com/}
PRODUCT_FILE=.artisan-agent/guardrails.jsonl
SHARED_FILE=guardrails.jsonl   # at the root of the team repo and of the individual home

# A change to any of these on main is a product guardrail change: checks (CI),
# standards, glossary, ADRs, config and the guardrail ledger.
PRODUCT_PATHS='^(\.artisan-agent/(config\.yml|guardrails\.jsonl)|CODING_STANDARDS\.md|PRODUCT_STANDARDS\.md|GLOSSARY\.md|docs/adr/|\.github/workflows/)'

git_id() { # a commit identity only if the machine has none
  { git config user.name && git config user.email; } >/dev/null 2>&1 \
    || printf -- '-c user.name=Artisan-Agent -c user.email=artisan-agent@localhost'
}
commit_in() { # dir message paths...
  local dir=$1 msg=$2 ident=
  shift 2
  ident=$(cd "$dir" && git_id)
  # shellcheck disable=SC2086
  git -C "$dir" add -- "$@"
  # shellcheck disable=SC2086
  git -C "$dir" $ident commit -q -m "$msg" -- "$@"
}

main_checkout() { # from a run dir or the current directory
  local common=
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository"
  dirname "$common"
}

main_ref() { # main checkout -> a ref, or nothing
  local m=$1
  if [ -n "${ARTISAN_MAIN_REF:-}" ]; then printf '%s\n' "$ARTISAN_MAIN_REF"
  elif git -C "$m" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then echo origin/main
  elif git -C "$m" rev-parse -q --verify refs/heads/main >/dev/null; then echo main
  fi
}

team_repo() { # main checkout -> owner/name or nothing
  local f="$1/.artisan-agent/config.yml"
  [ -f "$f" ] || return 0
  "$SCRIPT_DIR/config.sh" get team_guardrails_repo --file "$f" 2>/dev/null | jq -r '. // empty' || true
}
team_dir() { printf '%s/%s\n' "$TEAM_CACHE" "$(printf %s "$1" | tr / _)"; }

# fetch_team repo -> the clone's directory, at origin/main
fetch_team() {
  local repo=$1 dir=
  dir=$(team_dir "$repo")
  mkdir -p "$TEAM_CACHE"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q origin 2>/dev/null || die "could not fetch the team guardrails repo $repo"
  else
    git clone -q "$TEAM_URL_BASE$repo" "$dir" 2>/dev/null || die "could not clone the team guardrails repo $repo from $TEAM_URL_BASE$repo"
  fi
  git -C "$dir" rev-parse -q --verify refs/remotes/origin/main >/dev/null \
    || die "team guardrails repo $repo has no main branch"
  printf '%s\n' "$dir"
}

# ----------------------------------------------------------------- sources

# sources_json main-checkout fetch(1|0)
sources_json() {
  local m=$1 fetch=$2 repo= tdir= tc="" pc="" ic="" ref= dirty=false
  repo=$(team_repo "$m")
  if [ -n "$repo" ]; then
    if [ "$fetch" = 1 ]; then tdir=$(fetch_team "$repo"); else tdir=$(team_dir "$repo"); fi
    tc=$(git -C "$tdir" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null || true)
  fi
  ref=$(main_ref "$m")
  if [ -n "$ref" ]; then
    if [ "$fetch" = 1 ] && git -C "$m" remote get-url origin >/dev/null 2>&1; then
      git -C "$m" fetch -q origin 2>/dev/null || die "could not fetch origin for the product guardrails"
    fi
    pc=$(git -C "$m" rev-parse -q --verify "$ref" 2>/dev/null || true)
  fi
  if [ -d "$HOME_DIR/.git" ]; then
    ic=$(git -C "$HOME_DIR" rev-parse -q --verify HEAD 2>/dev/null || true)
    [ -z "$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)" ] || dirty=true
  fi
  jq -n --arg repo "$repo" --arg tc "$tc" --arg pc "$pc" --arg ref "$ref" --arg ic "$ic" --argjson dirty "$dirty" '{
    team: (if $tc == "" then null else {repo: $repo, commit: $tc} end),
    product: (if $pc == "" then null else {ref: $ref, commit: $pc} end),
    individual: (if $ic == "" then null else {commit: $ic, uncommitted_edits_ignored: $dirty} end)}'
}

cmd_sources() {
  local fetch=1
  [ "${1:-}" != --no-fetch ] || fetch=0
  sources_json "$(main_checkout)" "$fetch"
}

# --------------------------------------------------------------- wave-start

queue_conflict() { # run-dir ref
  local d=
  d=$(mktemp "${TMPDIR:-/tmp}/guardrail-decision.XXXXXX")
  jq -n --arg r "$2" '{id: 0, kind: "exception",
    question: "Main changed a product guardrail but would not merge into the integration branch (\($r)). Resolve the conflict, then launch the wave again.",
    status: "waiting"}' >"$d"
  "$SCRIPT_DIR/state.sh" decision "$1" "$d" >/dev/null || true
  rm -f "$d"
}

# guardrail_fingerprint commit: a checksum of the product guardrail files as
# they are at the commit, so "the guardrail files changed again" is a compare.
guardrail_fingerprint() {
  local wt=$1 c=$2 tab=
  tab=$(printf '\t')
  git -C "$wt" ls-tree -r "$c" | grep -E "$tab${PRODUCT_PATHS#^}" | cksum | cut -d' ' -f1,2 || true
}

# queue_diverged run ref pc base fingerprint files worktree: the run's base is not in
# the product's ref, so main is not brought in; the Artisan chooses.
queue_diverged() {
  local run=$1 ref=$2 pc=$3 base=$4 fp=$5 files=$6 wt=$7 counts= only_ref= only_base= d=
  counts=$(git -C "$wt" rev-list --left-right --count "$base...$pc")
  only_base=${counts%%[[:space:]]*}
  only_ref=${counts##*[[:space:]]}
  d=$(mktemp "${TMPDIR:-/tmp}/guardrail-decision.XXXXXX")
  jq -n --arg r "$ref" --arg pc "$pc" --arg b "$base" --arg fp "$fp" --arg f "$files" \
    --argjson ob "$only_base" --argjson orf "$only_ref" '{id: 0, kind: "exception", reason: "guardrail-base",
    question: "Main (\($r), \($pc[0:7])) changed a product guardrail, but this run is based on \($b[0:7]), which \($r) does not contain: the run has \($ob) commit(s) \($r) lacks, and \($r) has \($orf) the run lacks. Changed guardrail files: \($f | split("\n") | map(select(. != "")) | join(", ")). Merge anyway, keep the guardrails as of the run base, or halt the run? Answer with state.sh decide <id> merge|keep-base|halt.",
    base: $b, ref: $r, product: $pc, fingerprint: $fp,
    base_only: $ob, ref_only: $orf, files: ($f | split("\n") | map(select(. != ""))),
    options: ["merge", "keep-base", "halt"], status: "waiting"}' >"$d"
  "$SCRIPT_DIR/state.sh" decision "$run" "$d" >/dev/null || { rm -f "$d"; die "could not queue the guardrail-base decision"; }
  rm -f "$d"
}

cmd_wave_start() {
  [ $# -eq 2 ] || usage
  local run=$1 wave=$2 m= src= wt= ib= ref= pc= tip= version= merged=false changed= base= by= kept=false
  local fp="" files="" dec="" choice="" did="" inforce=""
  state_require_run_dir "$run"
  run=$(cd "$run" && pwd)
  m=$(main_checkout "$run")
  src=$(sources_json "$m" 1)
  pc=$(jq -r '.product.commit // ""' <<<"$src")
  ref=$(jq -r '.product.ref // ""' <<<"$src")
  wt=$(jq -r '.integration.worktree // ""' "$(state_file "$run")")
  ib=$(jq -r '.integration.branch // ""' "$(state_file "$run")")
  base=$(jq -r '.integration.base // ""' "$(state_file "$run")")
  by=""
  if [ -n "$pc" ] && [ -n "$wt" ] && [ -d "$wt" ] && ! git -C "$wt" merge-base --is-ancestor "$pc" HEAD; then
    tip=$(git -C "$wt" rev-parse HEAD)
    files=$(git -C "$wt" diff --name-only "$tip...$pc" | grep -E "$PRODUCT_PATHS" || true)
    changed=0
    [ -z "$files" ] || changed=$(printf '%s\n' "$files" | grep -c .)
    if [ "$changed" -gt 0 ]; then
      choice=merge
      # A run based on a commit main does not contain is not main's to
      # merge into: ask, then do what the Artisan answered.
      if [ -n "$base" ] && ! git -C "$wt" merge-base --is-ancestor "$base" "$pc"; then
        fp=$(guardrail_fingerprint "$wt" "$pc")
        dec=$(jq -c --arg fp "$fp" '[.decisions[] | select(.reason? == "guardrail-base" and .fingerprint == $fp
              and (.choice? != "halt" or .applied? != true))] | last // {}' "$(state_file "$run")")
        did=$(jq -r '.id // ""' <<<"$dec")
        choice=$(jq -r 'if .status == "decided" then .choice else "" end' <<<"$dec")
        by=$(jq -r '.by // ""' <<<"$dec")
        case "$choice" in
          merge | keep-base | halt) ;;
          *)
            if [ -z "$did" ]; then
              queue_diverged "$run" "$ref" "$pc" "$base" "$fp" "$files" "$wt"
              did=$(jq -r '.decisions | last | .id' "$(state_file "$run")")
            fi
            state_die 9 "guardrails.sh: $ref changed a product guardrail but the run's base $base is not in it; decision $did is waiting (state.sh decide $run $did merge|keep-base|halt); the wave is not recorded"
            ;;
        esac
      fi
      case "$choice" in
        halt)
          "$SCRIPT_DIR/state.sh" update "$run" "$STATE_JQ_DEFS"'
            .decisions |= map(if .id == $id then .applied = true else . end)
            | .halted = {wave: ($w | tonumber), tickets: [], at: $now, reason: "halted at the guardrail-base decision (\($id)): the run is based on a commit \($ref) does not contain"}
            | event({event: "halted", wave: ($w | tonumber), tickets: [], reason: "guardrail-base", decision: $id}; $now)' \
            --argjson id "$did" --arg w "$wave" --arg ref "$ref" --argjson now "$(date +%s)" >/dev/null
          state_die 10 "guardrails.sh: the run is halted at decision $did: it is based on a commit $ref does not contain (wave.sh launch --resume carries on and asks again)"
          ;;
        keep-base)
          kept=true
          "$SCRIPT_DIR/state.sh" event "$run" "$(jq -nc --arg c "$pc" --arg t "$tip" --arg w "$wave" --argjson d "$did" \
            '{event: "guardrail-base-kept", wave: ($w | tonumber), ref_commit: $c, in_force: $t, decision: $d}')" >/dev/null
          ;;
        *)
          if ! git -C "$wt" $(cd "$wt" && git_id) merge -q --no-ff -m "Bring $ref into $ib: a product guardrail changed" "$pc" >/dev/null 2>&1; then
            git -C "$wt" merge --abort >/dev/null 2>&1 || true
            queue_conflict "$run" "$ref"
            state_die 6 "guardrails.sh: $ref would not merge into $ib; a decision is queued"
          fi
          merged=true
          "$SCRIPT_DIR/state.sh" event "$run" "$(jq -nc --arg c "$pc" --arg w "$wave" --arg by "$by" \
            '{event: "guardrail-merge", wave: ($w | tonumber), from: $c} + (if $by == "" then {} else {by: $by} end)')" >/dev/null
          ;;
      esac
    fi
  fi
  # Keeping the base's guardrails: the product commit in force is the
  # integration tip's, which holds them.
  inforce=$pc
  [ "$kept" != true ] || inforce=$tip
  version=$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)
  "$SCRIPT_DIR/state.sh" wave-start "$run" "$wave" "$version" \
    "$(jq -r '.team.commit // "-"' <<<"$src")" "${inforce:--}" "$(jq -r '.individual.commit // "-"' <<<"$src")" >/dev/null
  jq -c --arg v "$version" --argjson merged "$merged" --argjson kept "$kept" --arg inforce "$inforce" \
    '{plugin_version: $v, team: .team.commit, product: (if $inforce == "" then .product.commit else $inforce end), individual: .individual.commit, main_merged: $merged, product_kept_base: $kept}' <<<"$src"
}

# ----------------------------------------------------------------- resolve

# read_level level dir-or-checkout commit path -> JSON records, one per line
read_level() {
  local level=$1 dir=$2 commit=$3 path=$4
  [ -n "$commit" ] && [ "$commit" != null ] || return 0
  git -C "$dir" show "$commit:$path" 2>/dev/null | jq -c --arg l "$level" --arg v "${commit:0:7}" \
    'select(type == "object") | . + {level: $l, version: $v}' || true
}

# resolve_json run-dir role tickets areas
resolve_json() {
  local run=$1 role=$2 tickets=${3:-} areas=${4:-} m= src= tdir= repo= recs= scoped=null
  if [ -n "$tickets" ] && [ -z "$run" ]; then state_die 2 "guardrails.sh: --ticket needs --run-dir"; fi
  if [ -n "$tickets" ] || [ -n "$areas" ]; then
    scoped=$(jq -nc --arg a "$areas" '$a | split(",") | map(select(. != ""))')
    if [ -n "$tickets" ]; then
      state_require_run_dir "$run"
      scoped=$(jq -c --arg t "$tickets" --argjson a "$scoped" \
        '. as $s | $a + [($t | split(",") | map(select(. != ""))[]) as $k | ($s.plan.tickets[$k].areas // [])[]] | unique' "$(state_file "$run")")
    fi
  fi
  if [ -n "$run" ]; then
    state_require_run_dir "$run"
    m=$(main_checkout "$run")
    src=$(jq -c '(.waves // []) | last // {} | .guardrails // {}
      | {team: (if .team then {commit: .team} else null end),
         product: (if .product then {commit: .product} else null end),
         individual: (if .individual then {commit: .individual} else null end)}' "$(state_file "$run")")
  else
    m=$(main_checkout)
    src=$(sources_json "$m" 0)
  fi
  repo=$(team_repo "$m")
  recs=$({
    [ -z "$repo" ] || read_level team "$(team_dir "$repo")" "$(jq -r '.team.commit // ""' <<<"$src")" "$SHARED_FILE"
    read_level product "$m" "$(jq -r '.product.commit // ""' <<<"$src")" "$PRODUCT_FILE"
    read_level individual "$HOME_DIR" "$(jq -r '.individual.commit // ""' <<<"$src")" "$SHARED_FILE"
  })
  jq -n --argjson src "$src" --arg role "$role" --argjson scoped "$scoped" --argjson recs "$(printf '%s\n' "$recs" | jq -sc '.')" '
    def rank: {product: 3, team: 2, individual: 1}[.level];
    def strict: (.strict // 0);
    def slim: {key, level, id, value, strict: strict, version, rule: (.rule // null), scope: (.scope // null), role: (.role // null), area: (.area // null), origin: (.origin // null), moves: (.moves // []), defer_only: (.defer_only == true), protected: ((.key == "scope-floor") or (.defer_only == true))};
    def classify:
      . as $g
      | ($g | map(select(.level != "individual")) | sort_by([(-(rank)), (-(strict))])) as $shared
      | ($g | map(select(.level == "individual")) | sort_by(-(strict))) as $own
      | ($shared[0] // $own[0]) as $win
      | ($g | map(select(. != $win and .value != $win.value))) as $diff
      | ($diff | map(select(.level == "individual" and .scope == "own-reviews"
                            and ($shared | length) > 0 and strict > ($win | strict)))) as $stricter
      | {win: $win, own: $stricter, lost: ($diff - $stricter)};
    ($recs | map(select(.level != "individual" or $role == "" or (.role // "") == "" or .role == $role))
           | map(select($scoped == null or (.area // "") == "" or (.area as $a | $scoped | index($a) != null)))) as $all
    | [$all | group_by(.key)[] | classify] as $res
    | {sources: $src,
       applied: [$res[].win | slim],
       own_reviews: [$res[].own[] | slim],
       overridden: [$res[] | .win as $w | .lost[] | slim + {overridden_by: {level: $w.level, id: $w.id}}],
       conflicts: [$res[] | select((.lost | length) > 0 or (.own | length) > 0) | .win.key] | unique}'
}

cmd_resolve() {
  local run="" role="" tickets="" areas=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
      --role) [ $# -ge 2 ] || usage; role=$2; shift 2 ;;
      --ticket) [ $# -ge 2 ] || usage; tickets=$2; shift 2 ;;
      --areas) [ $# -ge 2 ] || usage; areas=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  resolve_json "$run" "$role" "$tickets" "$areas"
}

cmd_table() {
  local run="" role="" json="" tickets="" areas=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) [ $# -ge 2 ] || usage; run=$2; shift 2 ;;
      --role) [ $# -ge 2 ] || usage; role=$2; shift 2 ;;
      --ticket) [ $# -ge 2 ] || usage; tickets=$2; shift 2 ;;
      --areas) [ $# -ge 2 ] || usage; areas=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  json=$(resolve_json "$run" "$role" "$tickets" "$areas")
  jq -r "$(state_jq_row_def)"'
    "| Guardrail | Level | Version | Says |",
    "|---|---|---|---|",
    (.applied[] | [.id, .level, .version, "\(.key) = \(.value)"] | row),
    (.own_reviews[] | [.id, "individual (own reviews)", .version, "\(.key) = \(.value)"] | row),
    ( if (.overridden | length) > 0 then
        "", "Overridden by a higher level:", "",
        "| Guardrail | Level | Version | Overridden by |", "|---|---|---|---|",
        (.overridden[] | [.id, .level, .version, "\(.overridden_by.id) (\(.overridden_by.level))"] | row)
      else empty end )' <<<"$json"
}

# ----------------------------------------------------------------- tighten

cmd_tighten() { move_guardrail tighten "$@"; }
cmd_loosen() { move_guardrail loosen "$@"; }

# health_report_for ID: prints {id, date} of the latest health report if it
# proposes loosening ID; otherwise prints what is missing and fails.
health_report_for() {
  local f=${ARTISAN_HEALTH_DIR:-$CFG/artisan-agent-health}/latest.json
  [ -f "$f" ] || { echo "no guardrail-health report has been recorded for $1"; return 1; }
  if [ "$(jq -r --arg id "$1" '[.proposals[] | select(.id == $id and .move == "loosen")] | length' "$f")" = 0 ]; then
    echo "the latest guardrail-health report ($(jq -r '.id' "$f")) does not propose loosening $1"
    return 1
  fi
  jq -c '{id, date}' "$f"
}

# move_guardrail tighten|loosen ...: write a new guardrail or move one, with
# its origin or its move. A loosening needs evidence and an existing, lower-
# strictness target, and is never made for the scope floor or a defer-only gate.
move_guardrail() {
  local mode=$1 mode_tag=""
  shift
  [ "$mode" != loosen ] || mode_tag=" (loosen)"
  local level="" who="" reason="" id="" key="" value="" rule="" strict="" evidence="" scope="" role="" run="" pr=0 override="" run_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --level) level=${2:-}; shift 2 ;;   --who) who=${2:-}; shift 2 ;;
      --reason) reason=${2:-}; shift 2 ;; --id) id=${2:-}; shift 2 ;;
      --key) key=${2:-}; shift 2 ;;       --value) value=${2:-}; shift 2 ;;
      --rule) rule=${2:-}; shift 2 ;;     --strict) strict=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;; --scope) scope=${2:-}; shift 2 ;;
      --role) role=${2:-}; shift 2 ;;     --run) run=${2:-}; shift 2 ;;
      --override-reason) override=${2:-}; shift 2 ;; --run-dir) run_dir=${2:-}; shift 2 ;;
      --pr) pr=1; shift ;;
      *) usage ;;
    esac
  done
  case "$level" in individual | product | team) ;; *) usage ;; esac
  [ -n "$who" ] && [ -n "$reason" ] || usage
  case "$(printf %s "$who" | tr 'A-Z' 'a-z')" in
    agent* | worker* | orchestrator* | verifier* | claude*) state_die 2 "guardrails.sh: only a person moves a guardrail; --who $who names an agent" ;;
  esac
  [ -z "$strict" ] || state_is_uint "$strict" || usage
  [ -n "$id" ] || id=$(printf %s "$key" | tr -c 'A-Za-z0-9\n' '-' | sed 's/^-*//;s/-*$//')
  [ -n "$id" ] || usage
  if [ "$mode" = loosen ]; then
    [ -n "$evidence" ] || state_die 2 "guardrails.sh: a loosening records the evidence for it: pass --evidence"
    [ -n "$strict" ] || usage
    [ -z "$run_dir" ] || [ -f "$run_dir/state.json" ] || die "no state.json in --run-dir $run_dir"
  fi

  local m= dir= branch="" file= path= now= date= current= new=
  m=$(main_checkout)
  now=$(state_now)
  date=$(jq -rn --argjson n "$now" '$n | todate')
  case "$level" in
    individual)
      [ -d "$HOME_DIR/.git" ] || die "no individual home at $HOME_DIR; run /artisan-agent:setup first"
      dir=$HOME_DIR; path=$SHARED_FILE ;;
    product | team)
      branch="guardrail/$id-$now"
      if [ "$level" = product ]; then
        local ref=
        ref=$(main_ref "$m")
        [ -n "$ref" ] || die "the product has no main branch"
        dir="$(dirname "$m")/$(basename "$m")-wt/guardrail-$id"
        mkdir -p "$(dirname "$dir")"
        git -C "$m" worktree add -q -b "$branch" "$dir" "$ref" >/dev/null 2>&1 || die "could not add a worktree for $branch"
        path=$PRODUCT_FILE
      else
        local repo= tdir=
        repo=$(team_repo "$m")
        [ -n "$repo" ] || die "no team_guardrails_repo in .artisan-agent/config.yml"
        tdir=$(fetch_team "$repo")
        dir="$TEAM_CACHE/wt-$(printf %s "$repo" | tr / _)-$id"
        git -C "$tdir" worktree add -q -b "$branch" "$dir" origin/main >/dev/null 2>&1 || die "could not add a worktree for $branch"
        path=$SHARED_FILE
      fi ;;
  esac
  file="$dir/$path"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : >"$file"

  current=$(jq -sc --arg id "$id" 'map(select(.id == $id)) | first // null' "$file")
  drop_worktree() { [ -z "$branch" ] || git -C "$m" worktree remove --force "$dir" >/dev/null 2>&1 || true; }
  if [ "$mode" = loosen ]; then
    [ "$current" != null ] || { drop_worktree; die "no guardrail $id at the $level level to loosen"; }
    if [ "$(jq -r '(.key == "scope-floor") or (.defer_only == true)' <<<"$current")" = true ]; then
      drop_worktree
      state_die 7 "guardrails.sh: $id is the scope floor or a defer-only gate; it never loosens"
    fi
    local cur_l=
    cur_l=$(jq -r '.strict // 0' <<<"$current")
    if [ "$strict" -ge "$cur_l" ]; then
      drop_worktree
      state_die 5 "guardrails.sh: $id is at strictness $cur_l; a loosening needs a lower --strict"
    fi
    # a loosening follows the latest health report, or is a stated, recorded override
    local report=null
    if [ -z "$override" ]; then
      report=$(health_report_for "$id") || { drop_worktree; state_die 8 "guardrails.sh: $report; a loosening follows a health report (guardrail-health.sh health --record), or pass --override-reason"; }
    fi
    new=$(jq -c --arg value "$value" --arg rule "$rule" --argjson strict "$strict" --arg date "$date" \
      --arg evidence "$evidence" --arg who "$who" --arg run "$run" --arg override "$override" --argjson report "$report" '
      . as $o | (if $value == "" then . else .value = $value end)
      | (if $rule == "" then . else .rule = $rule end) | .strict = $strict
      | .moves += [{date: $date, kind: "loosen", evidence: $evidence, who: $who,
                    from: {value: $o.value, strict: ($o.strict // 0)}, to: {value: .value, strict: $strict}}
                   + (if $run == "" then {} else {run: $run} end)
                   + (if $override == "" then {report: $report} else {override: {reason: $override, by: $who}} end)]' <<<"$current")
  elif [ "$current" = null ]; then
    [ -n "$key" ] && [ -n "$value" ] && [ -n "$rule" ] || die "a new guardrail needs --key, --value and --rule"
    new=$(jq -nc --arg id "$id" --arg key "$key" --arg value "$value" --arg rule "$rule" --arg strict "${strict:-1}" \
      --arg scope "$scope" --arg role "$role" --arg run "$run" --arg date "$date" --arg reason "$reason" --arg who "$who" '
      {id: $id, key: $key, value: $value, rule: $rule, strict: ($strict | tonumber)}
      + (if $scope == "" then {} else {scope: $scope} end) + (if $role == "" then {} else {role: $role} end)
      + {origin: ({date: $date, reason: $reason, who: $who} + (if $run == "" then {} else {run: $run} end)), moves: []}')
  else
    local cur=
    cur=$(jq -r '.strict // 0' <<<"$current")
    [ -n "$strict" ] && [ "$strict" -gt "$cur" ] \
      || { drop_worktree
           state_die 5 "guardrails.sh: $id is at strictness $cur; --strict must be higher. Only a retro, with evidence, loosens a guardrail"; }
    new=$(jq -c --arg value "$value" --arg rule "$rule" --argjson strict "$strict" --arg date "$date" \
      --arg evidence "${evidence:-$reason}" --arg who "$who" '
      . as $o | (if $value == "" then . else .value = $value end)
      | (if $rule == "" then . else .rule = $rule end) | .strict = $strict
      | .moves += [{date: $date, kind: "tighten", evidence: $evidence, who: $who,
                    from: {value: $o.value, strict: ($o.strict // 0)}, to: {value: .value, strict: $strict}}]' <<<"$current")
  fi
  { jq -c --arg id "$id" 'select(.id != $id)' "$file"; printf '%s\n' "$new"; } >"$file.tmp"
  mv "$file.tmp" "$file"
  if [ "$level" = individual ]; then
    commit_in "$dir" "Guardrail $id${mode_tag}: $reason" "$path"
    printf 'individual: committed %s in %s\n' "$id" "$dir"
  else
    commit_in "$dir" "Guardrail $id${mode_tag} ($level): $reason" "$path"
    printf '%s: committed %s on branch %s in %s; it applies from the next wave once merged\n' "$level" "$id" "$branch" "$dir"
    if [ "$pr" = 1 ]; then
      git -C "$dir" push -q -u origin "$branch" && gh pr create --head "$branch" --title "Guardrail $id ($level)" \
        --body "$reason" -R "$( [ "$level" = product ] && git -C "$m" remote get-url origin | sed -E 's#.*github.com[:/]##;s#\.git$##' || team_repo "$m")" >/dev/null \
        || die "could not push and open the PR; the branch is in $dir"
    fi
  fi
  if [ "$mode" = loosen ] && [ -n "$override" ] && [ -n "$run_dir" ]; then
    "$SCRIPT_DIR/state.sh" event "$run_dir" "$(jq -nc --arg g "$id" --arg r "loosened without a health report: $override" --arg by "$who" \
      '{event: "guardrail-bypassed", guardrail: $g, reason: $r, by: $by}')" >/dev/null
  fi
}

# -------------------------------------------------------------------- main

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  sources) cmd_sources "$@" ;;
  wave-start) cmd_wave_start "$@" ;;
  resolve) cmd_resolve "$@" ;;
  table) cmd_table "$@" ;;
  tighten) cmd_tighten "$@" ;;
  loosen) cmd_loosen "$@" ;;
  *) usage ;;
esac
