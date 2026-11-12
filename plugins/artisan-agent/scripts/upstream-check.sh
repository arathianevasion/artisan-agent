#!/usr/bin/env bash
# The upstream-updates check (#75): an upstream change never lands mid-run
# unchecked. Run by the retro (skills/retro/SKILL.md, "Upstream check").
#
#   upstream-check.sh refresh
#       refreshes the claude-plugins-official marketplace (claude plugin marketplace update)
#   upstream-check.sh status
#       installed mattpocock-skills against the commit the marketplace now pins.
#       "no upstream change ..." (exit 0), or one line
#       "moved<TAB>old-sha<TAB>new-sha<TAB>old-tree<TAB>url" (exit 10)
#   upstream-check.sh fetch <url> <sha> <dest>
#       clones the new upstream commit into <dest> (a new, empty folder)
#   upstream-check.sh mechanical --old DIR --new DIR
#       the mechanical check. Prints "ok ..." and "FAIL <kind> <detail>" lines; exit 1 on any FAIL:
#         dependency  a skill in guard/dependencies.list no longer exists
#         flag        a dependency or replaced skill's disable-model-invocation flag changed
#         docs-agents a docs/agents file name the old tree had is gone
#         label       a triage label name the old tree had is gone
#   upstream-check.sh run <work-dir>
#       the whole check, for the retro: status; when upstream has not moved it says so and
#       runs nothing else. When it has: fetch, mechanical, the judgement agent (JUDGE.md),
#       then report. Writes <work-dir>/{new,mechanical.txt,judgement.json,report.md}.
#       Exit 0 reported (breaking or not), 10 not used, 1 failed
#   upstream-check.sh report <work-dir>
#       turns mechanical.txt and judgement.json into the Artisan's tables. A breaking
#       change (a mechanical FAIL or a breaking judgement entry) files one pipeline ticket
#       and withholds the update offer; otherwise it prints "Update upstream to <sha>?"
#   upstream-check.sh file-ports <work-dir>
#       after the Artisan says yes: one pipeline ticket per improvement worth porting
#       and per kept skill that starts breaking ARTISAN.md
#
# The lists it reads are the guard's: guard/guard.sh flag-watch (the replaced skills) and
# guard/dependencies.list. The individual home's upstream-notes.md (lessons the retro
# delivered) goes to the judgement agent. Environment: ARTISAN_HOME (or
# ARTISAN_INDIVIDUAL_HOME), default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent;
# ARTISAN_PLUGINS_JSON (installed_plugins.json) and ARTISAN_MARKETPLACE_JSON, overriding
# the plugin folder's; ARTISAN_PIPELINE_REPO; GH_BIN, ARTISAN_CLAUDE_BIN stand-ins.
# Exit status: 0 ok, 1 failed, 2 bad usage, 10 moved/not used. Portable to bash 3.2.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-${ARTISAN_INDIVIDUAL_HOME:-$CFG/artisan-agent}}
PLUGINS_JSON=${ARTISAN_PLUGINS_JSON:-$CFG/plugins/installed_plugins.json}
MARKET_NAME=claude-plugins-official
MARKET_JSON=${ARTISAN_MARKETPLACE_JSON:-$CFG/plugins/marketplaces/$MARKET_NAME/.claude-plugin/marketplace.json}
UPSTREAM=mattpocock-skills
PIPELINE_REPO=${ARTISAN_PIPELINE_REPO:-arathianevasion/artisan-agent}
GH=${GH_BIN:-gh}
CLAUDE=${ARTISAN_CLAUDE_BIN:-claude}
DEPS="$PLUGIN_ROOT/guard/dependencies.list"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'upstream-check.sh: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

dependency_names() {
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$DEPS" | grep -v '^$' || true
}
replaced_names() { bash "$PLUGIN_ROOT/guard/guard.sh" flag-watch | sed "s/^$UPSTREAM://"; }

skill_file() { # tree name -> path of its SKILL.md, or nothing
  local f
  for f in "$1"/skills/*/"$2"/SKILL.md "$1/skills/$2/SKILL.md"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 0
}

flag_of() { # SKILL.md -> true | false (the front matter's disable-model-invocation)
  awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit}
       /^disable-model-invocation:[[:space:]]*true[[:space:]]*$/{f=1}
       END{print f?"true":"false"}' "$1"
}

docs_agents_names() { # tree -> file names under docs/agents the tree has or its skills point at
  {
    ls "$1"/docs/agents/*.md 2>/dev/null | sed 's#.*/##' || true
    grep -rhoE 'docs/agents/[A-Za-z0-9_.-]+\.md' "$1/skills" 2>/dev/null | sed 's#.*/##' || true
  } | sort -u
}

label_names() { # tree -> the canonical triage label names (first column of the label table)
  local f
  for f in "$1"/docs/agents/triage-labels.md "$1"/skills/*/*/triage-labels.md; do
    [ -f "$f" ] || continue
    awk -F'|' '/^\|/ { c=$2; gsub(/[ `]/, "", c); if (c != "" && c !~ /^-+$/ && c !~ /^Labelin/) print c }' "$f"
  done | sort -u
}

short() { printf '%s' "$1" | cut -c1-7; }

user_install() { # -> the JSON of the user-scope install of the upstream plugin, or nothing
  [ -f "$PLUGINS_JSON" ] || return 0
  jq -c --arg k "$UPSTREAM@$MARKET_NAME" \
    '[.plugins[$k][]? | select(.scope == "user")] | last // empty' "$PLUGINS_JSON"
}

cmd_refresh() {
  "$CLAUDE" plugin marketplace update "$MARKET_NAME" >/dev/null 2>&1 \
    || die "could not refresh the $MARKET_NAME marketplace"
  echo "refreshed $MARKET_NAME"
}

cmd_status() {
  local inst sha path ver new url
  inst=$(user_install)
  [ -n "$inst" ] || die "no user-scope install of $UPSTREAM@$MARKET_NAME in $PLUGINS_JSON"
  sha=$(jq -r '.gitCommitSha // ""' <<<"$inst"); path=$(jq -r '.installPath // ""' <<<"$inst")
  ver=$(jq -r '.version // ""' <<<"$inst")
  [ -f "$MARKET_JSON" ] || die "no marketplace listing at $MARKET_JSON"
  new=$(jq -r --arg n "$UPSTREAM" '[.plugins[] | select(.name == $n)][0].source.sha // ""' "$MARKET_JSON")
  url=$(jq -r --arg n "$UPSTREAM" '[.plugins[] | select(.name == $n)][0].source.url // ""' "$MARKET_JSON")
  [ -n "$new" ] || die "the marketplace pins no commit for $UPSTREAM"
  if [ "$sha" = "$new" ]; then
    printf 'no upstream change (%s %s)\n' "$ver" "$(short "$sha")"
    return 0
  fi
  printf 'moved\t%s\t%s\t%s\t%s\n' "$sha" "$new" "$path" "$url"
  return 10
}

cmd_fetch() {
  [ $# -eq 3 ] || usage
  [ ! -e "$3" ] || [ -z "$(ls -A "$3" 2>/dev/null)" ] || die "$3 is not empty"
  git clone --quiet "$1" "$3" >/dev/null 2>&1 || die "could not clone $1"
  git -C "$3" checkout --quiet "$2" >/dev/null 2>&1 || die "no commit $2 in $1"
}

cmd_mechanical() {
  local old= new= n f of nf fails=0 tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --old) old=$2; shift 2 ;;
      --new) new=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -d "$old" ] && [ -d "$new" ] || usage
  for n in $(dependency_names); do
    if [ -z "$(skill_file "$new" "$n")" ]; then
      echo "FAIL dependency $n no longer exists"; fails=$((fails + 1))
    else
      echo "ok dependency $n"
    fi
  done
  for n in $( { dependency_names; replaced_names; } | sort -u); do
    of=$(skill_file "$old" "$n"); nf=$(skill_file "$new" "$n")
    [ -n "$of" ] && [ -n "$nf" ] || continue
    if [ "$(flag_of "$of")" = "$(flag_of "$nf")" ]; then
      echo "ok flag $n"
    else
      echo "FAIL flag $n disable-model-invocation was $(flag_of "$of"), now $(flag_of "$nf")"
      fails=$((fails + 1))
    fi
  done
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/upstream-check.XXXXXX")
  docs_agents_names "$old" >"$tmp/old.docs"; docs_agents_names "$new" >"$tmp/new.docs"
  label_names "$old" >"$tmp/old.labels"; label_names "$new" >"$tmp/new.labels"
  for f in $(comm -23 "$tmp/old.docs" "$tmp/new.docs"); do
    echo "FAIL docs-agents $f is gone (renamed or removed)"; fails=$((fails + 1))
  done
  for f in $(comm -23 "$tmp/old.labels" "$tmp/new.labels"); do
    echo "FAIL label $f is gone (renamed or removed)"; fails=$((fails + 1))
  done
  [ "$fails" -gt 0 ] || { echo "ok docs-agents file names and triage labels unchanged"; }
  rm -rf "$tmp"
  [ "$fails" -eq 0 ]
}

block_file() { printf '%s/upstream-block.json' "$HOME_DIR"; }

cmd_run() {
  local work=${1:-} line old new oldtree url blocked state judge_prompt
  [ -n "$work" ] || usage
  mkdir -p "$work"
  rm -f "$work/mechanical.txt" "$work/judgement.json" "$work/report.md"
  line=$(cmd_status) && { echo "$line"; return 0; } || [ $? -eq 10 ] || exit 1
  IFS=$'\t' read -r _ old new oldtree url <<<"$line"
  # A breaking change withheld at an earlier retro stays withheld until its ticket closes.
  if [ -f "$(block_file)" ] && [ "$(jq -r .sha "$(block_file)")" = "$new" ]; then
    blocked=$(jq -r .ticket "$(block_file)")
    state=$("$GH" issue view "$blocked" -R "$PIPELINE_REPO" --json state -q .state 2>/dev/null || echo OPEN)
    if [ "$state" != "CLOSED" ] && [ "$state" != "closed" ]; then
      printf 'Upstream moved to %s but the update is withheld: blocked by #%s (open).\n' "$(short "$new")" "$blocked"
      return 0
    fi
  fi
  printf '%s\n' "$line" >"$work/moved.tsv"
  rm -rf "$work/new"
  cmd_fetch "$url" "$new" "$work/new"
  cmd_mechanical --old "$oldtree" --new "$work/new" >"$work/mechanical.txt" || true
  judge_prompt="$work/judge-prompt.md"
  {
    cat "$PLUGIN_ROOT/skills/retro/JUDGE.md"
    printf '\n## This check\n\n'
    printf -- '- Old upstream tree (installed): %s\n- New upstream tree: %s\n' "$oldtree" "$work/new"
    printf -- '- Replaced skills (guard/guard.sh flag-watch): %s\n' "$(replaced_names | tr '\n' ' ')"
    printf -- '- Dependency skills (guard/dependencies.list): %s\n' "$(dependency_names | tr '\n' ' ')"
    printf -- '- Write your answer to: %s\n' "$work/judgement.json"
    printf -- '- Mechanical check result: %s\n' "$work/mechanical.txt"
    if [ -s "$HOME_DIR/upstream-notes.md" ]; then
      printf '\n### Upstream notes the retro has kept (individual home upstream-notes.md)\n\n'
      cat "$HOME_DIR/upstream-notes.md"
    fi
    printf '\n### ARTISAN.md (the six rules kept skills must not break)\n\n'
    cat "$PLUGIN_ROOT/ARTISAN.md"
  } >"$judge_prompt"
  ( cd "$work" && ARTISAN_ROLE=upstream-judge "$CLAUDE" -p "$(cat "$judge_prompt")" \
      --model "${ARTISAN_UPSTREAM_MODEL:-claude-sonnet-5-5}" --max-budget-usd "${ARTISAN_UPSTREAM_BUDGET:-1.00}" \
      --output-format json >"$work/judge-session.json" 2>"$work/judge-session.err" ) \
    || die "the judgement agent failed (see $work/judge-session.err)"
  [ -s "$work/judgement.json" ] || die "the judgement agent wrote no $work/judgement.json"
  jq -e '.port and .behaviour and .artisan_md and .breaking' "$work/judgement.json" >/dev/null \
    || die "judgement.json lacks one of port, behaviour, artisan_md, breaking (arrays)"
  cmd_report "$work"
}

table() { # header1|header2|... then rows on stdin as tab-separated lines
  local heads=$1 n i sep=""
  n=$(printf '%s' "$heads" | awk -F'|' '{print NF}')
  printf '| %s |\n' "$(printf '%s' "$heads" | sed 's/|/ | /g')"
  for i in $(seq 1 "$n"); do sep="$sep---|"; done
  printf '|%s\n' "$sep"
  awk -F'\t' '{ printf "|"; for (i = 1; i <= NF; i++) { gsub(/\|/, "/", $i); printf " %s |", $i } printf "\n" }'
}

cmd_report() {
  local work=${1:-} mech j new old ticket body fails n
  [ -d "$work" ] || usage
  mech="$work/mechanical.txt"; j="$work/judgement.json"
  [ -f "$mech" ] && [ -f "$j" ] || die "report needs $mech and $j"
  IFS=$'\t' read -r _ old new _ _ <"$work/moved.tsv"
  fails=$(grep -c '^FAIL ' "$mech" || true)
  {
    printf '## Upstream moved: %s to %s\n\n' "$(short "$old")" "$(short "$new")"
    printf '**Mechanical check:** '
    if [ "$fails" -eq 0 ]; then printf 'passed.\n\n'; else
      printf '%s failure(s).\n\n' "$fails"
      grep '^FAIL ' "$mech" | sed 's/^FAIL //' | awk '{k=$1; $1=""; sub(/^ /,""); print k "\t" $0}' | table 'Kind|What changed'
      printf '\n'
    fi
    n=$(jq '.port | length' "$j")
    if [ "$n" -gt 0 ]; then
      printf '**Improvements worth porting**\n\n'
      jq -r '.port[] | [.skill, .title, .why] | @tsv' "$j" | table 'Skill|Improvement|Why'
      printf '\n'
    fi
    n=$(jq '.behaviour | length' "$j")
    if [ "$n" -gt 0 ]; then
      printf '**Behaviour changes in skills we use**\n\n'
      jq -r '.behaviour[] | [.skill, .change] | @tsv' "$j" | table 'Skill|Change' 
      printf '\n'
    fi
    n=$(jq '.artisan_md | length' "$j")
    if [ "$n" -gt 0 ]; then
      printf '**Kept skills that start breaking ARTISAN.md**\n\n'
      jq -r '.artisan_md[] | [.skill, .rule, .why] | @tsv' "$j" | table 'Skill|Rule|Why'
      printf '\n'
    fi
  } >"$work/report.md"
  n=$(jq '[.breaking[]] | length' "$j")
  if [ "$fails" -gt 0 ] || [ "$n" -gt 0 ]; then
    body=$(
      printf 'Upstream `%s` moved to `%s` and the update check found a breaking change. The update is withheld until this is fixed.\n\n' "$UPSTREAM" "$new"
      if [ "$fails" -gt 0 ]; then printf '## Mechanical check\n\n'; grep '^FAIL ' "$mech" | sed 's/^FAIL /- /'; printf '\n'; fi
      if [ "$n" -gt 0 ]; then printf '## Judgement check\n\n'; jq -r '.breaking[] | "- **\(.skill)**: \(.title). \(.why)"' "$j"; fi
    )
    ticket=$("$GH" issue create -R "$PIPELINE_REPO" --label needs-triage \
      --title "Upstream $(short "$new") breaks the pipeline: fix before updating" --body "$body" | sed 's#.*/##')
    mkdir -p "$HOME_DIR"
    jq -n --arg sha "$new" --arg ticket "$ticket" '{sha: $sha, ticket: $ticket}' >"$(block_file)"
    printf '**Breaking change.** Filed pipeline ticket #%s. The update offer is withheld until it is fixed.\n' "$ticket" >>"$work/report.md"
  else
    rm -f "$(block_file)"
    printf '**Update upstream to %s?** Nothing breaks; update `%s@%s` with `claude plugin update`.\n' \
      "$(short "$new")" "$UPSTREAM" "$MARKET_NAME" >>"$work/report.md"
  fi
  others "$work" >>"$work/report.md"
  cat "$work/report.md"
}

others() { # other plugins installed from this marketplace whose pinned commit moved
  local rows
  [ -f "$PLUGINS_JSON" ] && [ -f "$MARKET_JSON" ] || return 0
  rows=$(jq -r --slurpfile m "$MARKET_JSON" --arg up "$UPSTREAM@$MARKET_NAME" --arg mk "@$MARKET_NAME" '
    .plugins | to_entries[] | select(.key | endswith($mk)) | select(.key != $up) |
    .key as $k | ($k | sub($mk; "")) as $name |
    (.value | map(select(.scope == "user")) | last) as $i | select($i != null) |
    ([$m[0].plugins[] | select(.name == $name)][0].source.sha? // "") as $pin |
    select($pin != "" and $pin != ($i.gitCommitSha // "")) |
    [$name, ($i.version // ""), ($pin[0:7])] | @tsv' "$PLUGINS_JSON" 2>/dev/null || true)
  [ -n "$rows" ] || return 0
  printf '\n**Other plugins from %s have moved. Update them?**\n\n' "$MARKET_NAME"
  printf '%s\n' "$rows" | table 'Plugin|Installed|Pinned now'
}

cmd_file_ports() {
  local work=${1:-} j new
  [ -f "$work/judgement.json" ] || usage
  j="$work/judgement.json"; IFS=$'\t' read -r _ _ new _ _ <"$work/moved.tsv"
  jq -r '.port[] | [.skill, .title, .why] | @tsv' "$j" | while IFS=$'\t' read -r skill title why; do
    "$GH" issue create -R "$PIPELINE_REPO" --label needs-triage \
      --title "Port from upstream $(short "$new"): $title" \
      --body "Upstream \`$skill\` improved: $why"$'\n\n'"Found by the upstream-updates check; see the retro." | sed 's#.*/##' | sed "s/^/port #/"
  done
  jq -r '.artisan_md[] | [.skill, .rule, .why] | @tsv' "$j" | while IFS=$'\t' read -r skill rule why; do
    "$GH" issue create -R "$PIPELINE_REPO" --label needs-triage \
      --title "Upstream $(short "$new"): kept skill $skill starts breaking ARTISAN.md ($rule)" \
      --body "$why" | sed 's#.*/##' | sed "s/^/artisan-md #/"
  done
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  refresh) cmd_refresh ;;
  status) cmd_status ;;
  fetch) cmd_fetch "$@" ;;
  mechanical) cmd_mechanical "$@" ;;
  run) cmd_run "$@" ;;
  report) cmd_report "$@" ;;
  file-ports) cmd_file_ports "$@" ;;
  -h|--help|help|"") usage ;;
  *) echo "upstream-check.sh: unknown command $cmd" >&2; usage ;;
esac
