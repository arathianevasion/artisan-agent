#!/usr/bin/env bash
# The retro's mechanics for /artisan-agent:retro. The skill (SKILL.md) holds
# the chat round; this script reads the run, checks the lessons, keeps the
# satisfaction record and delivers what the Artisan kept. Files live in the
# run folder's retro/ (see SKILL.md, "Files").
#
#   retro.sh prepare <run-dir> [--chat-log FILE] [--model M] [--max-budget-usd N]
#       gathers the run's inputs and runs a fresh headless session (PREPARE.md)
#       that writes retro/lessons.json and retro/actions.jsonl; then facts and check
#   retro.sh facts <run-dir>        the run's facts and signals -> retro/facts.json
#   retro.sh check <run-dir>        lessons.json plus the Artisan's own lessons ->
#                                   retro/checked.json (homes, questions); exit 1 lists problems
#   retro.sh render <run-dir>       the chat round as Markdown: lessons, questions,
#                                   signals, the motivation and the satisfaction questions
#   retro.sh add-lesson <run-dir> <lesson-json>
#                                   a lesson in the Artisan's own words (a "why?" answer);
#                                   kept without another question
#   retro.sh satisfaction <run-dir> <answers.json>
#                                   appends the record to the individual home's
#                                   satisfaction.jsonl and commits it; prints the triggers
#                                   ("why <question> <reason>", "chore <text>"); each
#                                   chore becomes a kept pipeline lesson. Exit 3: already recorded
#   retro.sh motivation <run-dir> update < TEXT
#                                   replaces the product's motivation in the individual home
#                                   (only on the Artisan's yes)
#   retro.sh deliver <run-dir> <decisions.json> [--pr]
#                                   delivers the kept lessons: one project branch
#                                   retro/<run-id> (--pr: pushed, one PR), individual-home
#                                   commits with origin, pipeline tickets, upstream notes.
#                                   Never files a retro issue. Rerunning delivers nothing twice
#
# decisions.json: {"<lesson id>": "yes" | "no" | "this-project"}. "this-project" keeps a
# lesson marked generalises without promoting it. Nothing is delivered without one.
#
# Environment: ARTISAN_HOME (or ARTISAN_INDIVIDUAL_HOME) the individual home, default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent; ARTISAN_PIPELINE_REPO, default
# arathianevasion/artisan-agent; GH_BIN, ARTISAN_CLAUDE_BIN stand-ins for gh and claude.
#
# Exit status: 0 ok, 1 failed, 2 bad usage, 3 already recorded. Portable to bash 3.2.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
py() { python3 -I "$SCRIPT_DIR/retro.py" "$@"; }
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-${ARTISAN_INDIVIDUAL_HOME:-$CFG/artisan-agent}}
PIPELINE_REPO=${ARTISAN_PIPELINE_REPO:-arathianevasion/artisan-agent}
GH=${GH_BIN:-gh}
CLAUDE=${ARTISAN_CLAUDE_BIN:-claude}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'retro.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

run_dir() { [ -f "$1/state.json" ] || die "no state file in $1"; (cd "$1" && pwd); }
main_of() { # the main checkout that holds a run folder
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "$1 is not in a git repo"
  dirname "$common"
}
run_id() { jq -r '.run_id' "$1/state.json"; }
today() { date +%Y-%m-%d; }

ident() { # a commit identity only when git has none (CI, fresh machines)
  if git -C "$1" var GIT_COMMITTER_IDENT >/dev/null 2>&1 && git -C "$1" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then return 0; fi
  printf '%s\n' -c user.name=Artisan-Agent -c user.email=artisan-agent@localhost
}
commit_in() { # dir message paths...
  local dir=$1 msg=$2 id
  shift 2
  id=$(ident "$dir")
  git -C "$dir" add -- "$@"
  if git -C "$dir" diff --cached --quiet -- "$@"; then return 0; fi
  # shellcheck disable=SC2086
  git -C "$dir" $id commit -q -m "$msg" -- "$@"
}
need_home() { [ -d "$HOME_DIR/.git" ] || die "no individual home at $HOME_DIR; run /artisan-agent:setup (machine-level) first"; }

# The retro reads every triage miss newer than the last retro (skills/triage/SKILL.md).
misses_since_last() { # main out
  local f="$1/.artisan-agent/triage/misses.jsonl" last=""
  [ -f "$1/.artisan-agent/retro/last" ] && last=$(cat "$1/.artisan-agent/retro/last")
  if [ -f "$f" ]; then jq -c --arg last "$last" 'select((.ts // "") > $last)' "$f" >"$2" 2>/dev/null || : >"$2"; else : >"$2"; fi
}

cmd_facts() {
  local rd; rd=$(run_dir "$1"); mkdir -p "$rd/retro"
  misses_since_last "$(main_of "$rd")" "$rd/retro/misses.jsonl"
  py facts "$rd/state.json" "$PLUGIN_ROOT/references/jobs.md" "$rd/retro/actions.jsonl" "$rd/retro/misses.jsonl" >"$rd/retro/facts.json.tmp"
  mv "$rd/retro/facts.json.tmp" "$rd/retro/facts.json"
  cat "$rd/retro/facts.json"
}

cmd_check() {
  local rd threshold combined; rd=$(run_dir "$1")
  [ -f "$rd/retro/lessons.json" ] || die "no retro/lessons.json in $rd: run prepare first"
  threshold=$(jq -r '.plan.config.evidence_threshold // 3' "$rd/state.json")
  combined="$rd/retro/.combined.json"
  if [ -s "$rd/retro/added.jsonl" ]; then
    jq --slurpfile added "$rd/retro/added.jsonl" '.lessons = ((.lessons // []) + $added)' "$rd/retro/lessons.json" >"$combined"
  else
    cp "$rd/retro/lessons.json" "$combined"
  fi
  if py check "$combined" "$threshold" >"$rd/retro/checked.json.tmp"; then
    mv "$rd/retro/checked.json.tmp" "$rd/retro/checked.json"; rm -f "$combined"
    jq -r '.lessons[] | "\(.id)\t\(.ask)\t\(.kind)\t\(.home)"' "$rd/retro/checked.json"
  else
    cat "$rd/retro/checked.json.tmp" >&2; rm -f "$rd/retro/checked.json.tmp" "$combined"; exit 1
  fi
}

motivation_file() { # repo -> a temp file holding the recorded motivation, or nothing
  local out=$2
  if ARTISAN_INDIVIDUAL_HOME=$HOME_DIR bash "$PLUGIN_ROOT/skills/setup/scripts/project-setup.sh" motivation get "$1" >"$out" 2>/dev/null; then
    return 0
  fi
  rm -f "$out"; return 1
}

cmd_render() {
  local rd main mot; rd=$(run_dir "$1"); main=$(main_of "$rd")
  [ -f "$rd/retro/checked.json" ] || die "no retro/checked.json: run check first"
  [ -f "$rd/retro/facts.json" ] || cmd_facts "$rd" >/dev/null
  py questions "$HOME_DIR/ARTISAN.md" "$PLUGIN_ROOT/ARTISAN.md" >"$rd/retro/questions.json"
  mot="$rd/retro/.motivation.md"
  if motivation_file "$main" "$mot"; then
    py render "$rd/retro/checked.json" "$rd/retro/facts.json" "$rd/retro/questions.json" "$mot"
  else
    py render "$rd/retro/checked.json" "$rd/retro/facts.json" "$rd/retro/questions.json"
  fi
  rm -f "$mot"
}

cmd_add_lesson() {
  local rd n; rd=$(run_dir "$1"); mkdir -p "$rd/retro"
  n=$(( $( [ -f "$rd/retro/added.jsonl" ] && wc -l <"$rd/retro/added.jsonl" || echo 0) + 1 ))
  jq -c --arg id "A$n" '{id: $id} + . + {source: "artisan"}' <<<"$2" >>"$rd/retro/added.jsonl" \
    || die "the lesson is not a JSON object"
  echo "A$n"
}

cmd_satisfaction() {
  local rd run project out rec trig; rd=$(run_dir "$1"); need_home
  [ -f "$2" ] || die "no answers file: $2"
  run=$(run_id "$rd"); project=$(jq -r '.repo // "unknown"' "$rd/state.json")
  [ -f "$rd/retro/facts.json" ] || cmd_facts "$rd" >/dev/null
  local hist="$HOME_DIR/satisfaction.jsonl"; [ -f "$hist" ] || : >"$hist"
  if jq -e --arg p "$project" --arg r "$run" 'select((.type // "answers") == "answers" and .project == $p and .run == $r)' "$hist" >/dev/null 2>&1; then
    echo "retro.sh: the satisfaction answers for run $run are already recorded" >&2; exit 3
  fi
  out=$(py record "$2" "$rd/retro/facts.json" "$hist" "$project" "$run" "$(today)") || exit 1
  rec=$(printf '%s\n' "$out" | sed -n 1p); trig=$(printf '%s\n' "$out" | sed -n 2p)
  printf '%s\n' "$rec" >>"$hist"
  commit_in "$HOME_DIR" "Satisfaction: run $run ($project)" satisfaction.jsonl
  printf '%s\n' "$trig" >"$rd/retro/triggers.json"
  jq -r '.why[] | "why\t\(.question)\t\(.reason)"' <<<"$trig"
  jq -r '.chores[]' <<<"$trig" | while IFS= read -r chore; do
    cmd_add_lesson "$rd" "$(jq -n --arg c "$chore" '{kind: "pipeline", lesson: ("Remove a chore: " + $c), role: "both",
      scope: "generalises", why: "Named by the Artisan at the retro as taking time without serving a focus",
      ticket: {title: ("Chore: " + $c)}}')" >/dev/null
    printf 'chore\t%s\n' "$chore"
  done
  if [ -f "$rd/retro/lessons.json" ]; then cmd_check "$rd" >/dev/null; fi
}

cmd_motivation() {
  local rd; rd=$(run_dir "$1"); [ "${2:-}" = update ] || usage; need_home
  ARTISAN_RUN_ID=$(run_id "$rd") ARTISAN_INDIVIDUAL_HOME=$HOME_DIR \
    bash "$PLUGIN_ROOT/skills/setup/scripts/project-setup.sh" motivation update "$(main_of "$rd")"
}

cmd_prepare() {
  local rd main chat="" model=claude-sonnet-5-5 budget=1.00 prompt
  rd=$(run_dir "$1"); shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --chat-log) chat=$2; shift 2 ;;
      --model) model=$2; shift 2 ;;
      --max-budget-usd) budget=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  main=$(main_of "$rd"); mkdir -p "$rd/retro"
  rm -f "$rd/retro/lessons.json" "$rd/retro/actions.jsonl"
  cmd_facts "$rd" >/dev/null
  prompt="$rd/retro/prompt.md"
  {
    cat "$PLUGIN_ROOT/skills/retro/PREPARE.md"
    printf '\n## This run\n\n'
    printf -- '- Run folder: `%s` (state file `state.json`; `results/`, `workers/`, `verify/`, `merges/`, `prompts/`)\n' "$rd"
    printf -- '- Facts and signals already computed: `%s`\n' "$rd/retro/facts.json"
    printf -- '- Triage misses since the last retro: `%s`\n' "$rd/retro/misses.jsonl"
    if [ -n "$chat" ]; then printf -- '- Chat log: `%s`\n' "$chat"; else printf -- '- Chat log: none given\n'; fi
    printf -- '- Project checkout (read only): `%s`; the plugin: `%s`\n' "$main" "$PLUGIN_ROOT"
    printf -- '- Evidence threshold: %s\n' "$(jq -r '.plan.config.evidence_threshold // 3' "$rd/state.json")"
    printf -- '- Write the lessons to `%s` and the Artisan'"'"'s actions to `%s`.\n' "$rd/retro/lessons.json" "$rd/retro/actions.jsonl"
  } >"$prompt"
  ( cd "$main" && ARTISAN_ROLE=retro ARTISAN_RUN_DIR=$rd "$CLAUDE" -p "$(cat "$prompt")" \
      --model "$model" --max-budget-usd "$budget" --output-format json \
      --permission-mode acceptEdits \
      --allowedTools "Read,Grep,Glob,Write,Edit,Bash(git log:*),Bash(git show:*),Bash(jq:*),Bash(gh issue view:*),Bash(gh pr list:*)" \
      >"$rd/retro/session.json" 2>"$rd/retro/session.err" ) || true
  [ -f "$rd/retro/lessons.json" ] || die "the preparer wrote no lessons; its output is in $rd/retro/session.json"
  cmd_facts "$rd" >/dev/null
  cmd_check "$rd"
}

# --- delivery -------------------------------------------------------------

delivered() { [ -f "$RD/retro/delivered.jsonl" ] && jq -e --arg id "$1" --arg to "$2" 'select(.id == $id and .to == $to)' "$RD/retro/delivered.jsonl" >/dev/null 2>&1; }
mark() { jq -nc --arg id "$1" --arg to "$2" --arg where "$3" '{id: $id, to: $to, where: $where}' >>"$RD/retro/delivered.jsonl"; }
origin_line() { jq -r --arg run "$RUN" --arg repo "$PROJECT" --arg d "$(today)" \
  '"Origin: run \($run) of \($repo), \($d); role \(.role); \(.why)"' "$1"; }

base_ref() {
  local r
  if r=$(git -C "$MAIN" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then echo "$r"; return; fi
  if git -C "$MAIN" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then echo origin/main; return; fi
  git -C "$MAIN" rev-parse --abbrev-ref HEAD
}

project_lessons() { # worktree-making, one commit per lesson, one PR
  local ids=$1 pr=$2 wt branch base id lf path n=0
  [ -n "$ids" ] || return 0
  branch="retro/$RUN"; wt="$(dirname "$MAIN")/$(basename "$MAIN")-wt/retro-$RUN"
  if [ ! -d "$wt" ]; then
    base=$(base_ref)
    mkdir -p "$(dirname "$wt")"
    if git -C "$MAIN" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      git -C "$MAIN" worktree add -q "$wt" "$branch" >/dev/null 2>&1 || die "could not add the worktree for $branch"
    else
      git -C "$MAIN" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1 || die "could not add a worktree for $branch"
    fi
  fi
  for id in $ids; do
    delivered "$id" project && continue
    lf="$RD/retro/.lesson-$id.json"
    jq --arg id "$id" '.lessons[] | select(.id == $id)' "$CHECKED" >"$lf"
    path=$(py apply "$wt" "$lf") || die "could not apply lesson $id"
    commit_in "$wt" "$(printf 'Retro lesson %s (run %s): %s\n\n%s\nHome: %s' "$id" "$RUN" \
      "$(jq -r .lesson "$lf")" "$(origin_line "$lf")" "$(jq -r .home "$lf")")" "$path"
    mark "$id" project "$branch"; rm -f "$lf"; n=$((n + 1))
  done
  if [ "$(git -C "$wt" rev-list --count "$(base_ref)..HEAD" 2>/dev/null || echo 0)" = 0 ]; then
    git -C "$MAIN" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$MAIN" branch -D "$branch" >/dev/null 2>&1 || true
    return 0
  fi
  printf 'project\t%s\t%s\n' "$branch" "$wt"
  if [ "$pr" = 1 ] && ! delivered pr pr; then
    local body url
    body=$(jq -r --arg run "$RUN" '"Lessons kept at the retro of run \($run). Merging this PR is the approval; there is no retro issue.\n\n| # | Lesson | Home | Role | Reach |\n|---|---|---|---|---|\n" +
      ([.lessons[] | select(.delivery == "project")] | map("| \(.id) | \(.lesson) | \(.home) | \(.role) | \(.scope) |") | join("\n"))' "$CHECKED")
    git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1 || die "could not push $branch"
    url=$(cd "$wt" && "$GH" pr create --head "$branch" --title "Retro lessons from run $RUN" --body "$body") \
      || die "could not open the PR for $branch"
    mark pr pr "$url"; printf 'pr\t%s\n' "$url"
  elif [ "$pr" = 1 ]; then
    git -C "$wt" push -q origin "$branch" >/dev/null 2>&1 || die "could not push $branch"
  fi
}

home_file_for() { # kind -> the individual standards file and section a generalising lesson is promoted to
  case "$1" in
    product-taste) echo "PRODUCT_STANDARDS.md|## Lessons" ;;
    mechanical) echo "CODING_STANDARDS.md|## Checks" ;;
    *) echo "CODING_STANDARDS.md|## Lessons" ;;
  esac
}

cmd_deliver() {
  local pr=0 decisions ids_project="" id kind dec lf f
  RD=$(run_dir "$1"); decisions=$2; shift 2
  [ "${1:-}" = --pr ] && pr=1
  [ -f "$decisions" ] || die "no decisions file: nothing changes until the Artisan answers"
  CHECKED="$RD/retro/checked.json"; [ -f "$CHECKED" ] || die "no retro/checked.json: run check first"
  MAIN=$(main_of "$RD"); RUN=$(run_id "$RD"); PROJECT=$(jq -r '.repo // "unknown"' "$RD/state.json")
  local failed=0
  for id in $(jq -r '.lessons[].id' "$CHECKED"); do
    dec=$(jq -r --arg id "$id" '.[$id] // ""' "$decisions")
    if [ -z "$dec" ] && [ "$(jq -r --arg id "$id" '.lessons[] | select(.id == $id) | .source // ""' "$CHECKED")" = artisan ]; then dec=yes; fi
    case "$dec" in yes|this-project) ;; *) continue ;; esac
    kind=$(jq -r --arg id "$id" '.lessons[] | select(.id == $id) | .kind' "$CHECKED")
    lf="$RD/retro/.lesson-$id.json"
    jq --arg id "$id" '.lessons[] | select(.id == $id)' "$CHECKED" >"$lf"
    case "$kind" in
      pipeline)
        if ! delivered "$id" pipeline; then
          local url
          if url=$("$GH" issue create -R "$PIPELINE_REPO" --title "$(jq -r .ticket.title "$lf")" --label needs-triage \
              --body "$(printf '> *This was generated by AI during the retro.*\n\n%s\n\n%s\n\n%s' \
                "$(jq -r .lesson "$lf")" "$(jq -r .ticket.body "$lf")" "$(origin_line "$lf")")"); then
            mark "$id" pipeline "$url"; printf 'pipeline\t%s\t%s\n' "$id" "$url"
          else failed=1; echo "retro.sh: could not file the pipeline ticket for $id" >&2; fi
        fi ;;
      upstream)
        need_home
        if ! delivered "$id" upstream; then
          f="$HOME_DIR/upstream-notes.md"
          [ -f "$f" ] || printf '# Notes for the upstream check\n\nKept by the retro; the upstream check reads them.\n' >"$f"
          printf -- '\n- %s %s\n  %s\n' "$(today)" "$(jq -r .lesson "$lf")" "$(origin_line "$lf")" >>"$f"
          commit_in "$HOME_DIR" "Upstream note $id (run $RUN): $(jq -r .lesson "$lf")" upstream-notes.md
          mark "$id" upstream "$f"; printf 'upstream\t%s\t%s\n' "$id" "$f"
        fi ;;
      experience)
        need_home
        if ! delivered "$id" experience; then
          jq -c --arg run "$RUN" --arg p "$PROJECT" --arg d "$(today)" \
            '{type: "lesson", date: $d, project: $p, run: $run, lesson: .lesson, role: .role, why: .why}' "$lf" >>"$HOME_DIR/satisfaction.jsonl"
          commit_in "$HOME_DIR" "Experience lesson $id (run $RUN): $(jq -r .lesson "$lf")" satisfaction.jsonl
          mark "$id" experience "$HOME_DIR/satisfaction.jsonl"; printf 'experience\t%s\tsatisfaction record\n' "$id"
        fi ;;
      *) ids_project="$ids_project $id" ;;
    esac
    # A generalising lesson the Artisan confirmed is promoted to the individual level.
    if [ "$dec" = yes ] && [ "$(jq -r '.promotable // false' "$lf")" = true ] && ! delivered "$id" promoted; then
      need_home
      f=$(home_file_for "$kind"); local section=${f#*|}; f=${f%%|*}
      local what; what=$(jq -r 'if .kind == "mechanical" then "\(.lesson) [check: \(.change.path)]" else .lesson end' "$lf")
      py promote "$HOME_DIR/$f" "$section" "- $what ($(origin_line "$lf" | sed 's/^Origin: /from /'))"
      commit_in "$HOME_DIR" "$(printf 'Promote retro lesson %s (run %s): %s\n\n%s' "$id" "$RUN" "$(jq -r .lesson "$lf")" "$(origin_line "$lf")")" "$f"
      mark "$id" promoted "$HOME_DIR/$f"; printf 'promoted\t%s\t%s\n' "$id" "$HOME_DIR/$f"
    fi
    rm -f "$lf"
  done
  project_lessons "$(echo $ids_project)" "$pr"
  [ "$failed" = 0 ] || return 1   # the next retro reads this one's misses again
  mkdir -p "$MAIN/.artisan-agent/retro"
  [ -e "$MAIN/.artisan-agent/retro/.gitignore" ] || printf '*\n' >"$MAIN/.artisan-agent/retro/.gitignore"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$MAIN/.artisan-agent/retro/last"
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
  prepare) [ $# -ge 1 ] || usage; cmd_prepare "$@" ;;
  facts) [ $# -eq 1 ] || usage; cmd_facts "$1" ;;
  check) [ $# -eq 1 ] || usage; cmd_check "$1" ;;
  render) [ $# -eq 1 ] || usage; cmd_render "$1" ;;
  add-lesson) [ $# -eq 2 ] || usage; cmd_add_lesson "$1" "$2" ;;
  satisfaction) [ $# -eq 2 ] || usage; cmd_satisfaction "$1" "$2" ;;
  motivation) [ $# -eq 2 ] || usage; cmd_motivation "$1" "$2" ;;
  deliver) [ $# -ge 2 ] || usage; cmd_deliver "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
