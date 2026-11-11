#!/usr/bin/env bash
# Project-level setup for /artisan-agent:setup. Reads what is there, never overwrites,
# lands its changes as one PR from branch artisan-agent/setup, and a rerun changes nothing.
#
#   project-setup.sh scan [REPO]           facts, one "key<TAB>value..." per line
#   project-setup.sh begin [REPO]          make or reuse the setup worktree; prints its path
#   project-setup.sh apply WT ANSWERS      add every missing item in the setup worktree WT and
#                                          commit; ANSWERS is a JSON file (see PROJECT.md)
#   project-setup.sh labels WT             create the ten labels missing from the GitHub tracker
#   project-setup.sh pre-commit [REPO]     install guard/pre-commit.sh (main-checkout fallback)
#   project-setup.sh hook-probe [REPO]     prints "fires" or "silent": does the plugin's
#                                          replaced-skill hook fire here? (headless claude, $0 if it fires)
#   project-setup.sh prove-check [--ref REF] [--prepare CMD] --break CMD -- CHECK...
#                                          prove CHECK fails on a deliberate break in a throwaway worktree
#   project-setup.sh motivation get [REPO]          print the recorded motivation (exit 1: none)
#   project-setup.sh motivation set [REPO] < TEXT   record it in the individual home and commit there
#   project-setup.sh individual HEADING LINE        add LINE under HEADING in the individual
#                                          CODING_STANDARDS.md and commit there (individual guardrails)
#   project-setup.sh finish WT             push the branch and open (or reuse) the PR; with no new
#                                          commits, remove the worktree and branch: "unchanged"
#
# The individual home is ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/artisan-agent (machine-level setup);
# ARTISAN_INDIVIDUAL_HOME overrides it.
# GH_BIN and ARTISAN_CLAUDE_BIN override gh and claude (tests use stubs). Portable to bash 3.2.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
GUARD=$ROOT/guard
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_INDIVIDUAL_HOME:-$CFG/artisan-agent}
GH=${GH_BIN:-gh}
CLAUDE_BIN=${ARTISAN_CLAUDE_BIN:-claude}
BRANCH=artisan-agent/setup
POINTER='Start with `/artisan-agent:craft`.'
HOOK_FILE=.claude/hooks/artisan-agent-block-replaced.sh
MARKER="Blocked by the artisan-agent replaced-skill guard:"

die() { printf 'project-setup.sh: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' >&2; exit 2; }
edit() { python3 -I "$HERE/project_edit.py" "$@"; }

main_of() { # repo dir -> main checkout path
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not a git repository: $1"
  dirname "$common"
}

ident_args() { # a fixed identity only when git has none (CI, fresh machines)
  if git -C "$1" var GIT_COMMITTER_IDENT >/dev/null 2>&1 && git -C "$1" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' -c user.name=Artisan-Agent -c user.email=artisan-agent@localhost
}

git_commit() { # dir message [paths...]
  local dir=$1 msg=$2; shift 2
  local args; args=$(ident_args "$dir")
  # shellcheck disable=SC2086
  git -C "$dir" $args commit -q -m "$msg" "$@"
}

base_ref() { # the default branch to start from: origin's HEAD, else the main checkout's HEAD
  local m=$1 r
  if r=$(git -C "$m" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then printf '%s\n' "$r"; return; fi
  if git -C "$m" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then echo origin/main; return; fi
  git -C "$m" rev-parse -q --verify HEAD >/dev/null || die "$m has no commits yet; commit something first so setup has a base for its PR"
  git -C "$m" rev-parse --abbrev-ref HEAD
}

tracker_kind() { # from upstream's docs/agents/issue-tracker.md title
  local f=$1/docs/agents/issue-tracker.md title
  [ -f "$f" ] || { echo none; return; }
  title=$(head -n 1 "$f")
  case "$title" in
    *GitHub*) echo github ;;
    *GitLab*) echo gitlab ;;
    *Local*) echo local ;;
    *) echo other ;;
  esac
}

agents_file() { # CLAUDE.md, else AGENTS.md if only that exists (upstream's rule: never create the other)
  if [ -f "$1/CLAUDE.md" ] || [ ! -f "$1/AGENTS.md" ]; then echo CLAUDE.md; else echo AGENTS.md; fi
}

upstream_done() { # upstream's setup-matt-pocock-skills leaves an "## Agent skills" block and docs/agents/
  local d=$1
  [ -f "$d/docs/agents/issue-tracker.md" ] || return 1
  grep -qs '^## Agent skills' "$d/CLAUDE.md" "$d/AGENTS.md"
}

repo_id() { # how the individual home names a product: host/owner/name from origin, else the path
  local m url
  m=$(main_of "$1")
  if url=$(git -C "$m" remote get-url origin 2>/dev/null) && [ -n "$url" ]; then
    url=${url%.git}; url=${url%/}
    case "$url" in
      *://*) url=${url#*://}; url=${url#*@} ;;
      *@*:*) url=${url#*@}; url=$(printf '%s' "$url" | sed 's/:/\//') ;;
    esac
    printf '%s\n' "$url"
  else
    printf 'local%s\n' "$m"
  fi
}

motivation_file() { printf '%s/motivations/%s.md\n' "$HOME_DIR" "$(repo_id "$1" | sed 's/[^A-Za-z0-9._-]/__/g')"; }

found_checks() { # candidate check commands, "check<TAB>source<TAB>command"
  local d=$1 f t
  if [ -f "$d/package.json" ] && command -v jq >/dev/null 2>&1; then
    for t in $(jq -r '.scripts // {} | keys[]' "$d/package.json" 2>/dev/null); do
      case "$t" in
        test) printf 'check\tpackage.json\tnpm test\n' ;;
        lint|typecheck|type-check|check|tsc|format:check|test:*) printf 'check\tpackage.json\tnpm run %s\n' "$t" ;;
      esac
    done
  fi
  if [ -f "$d/Makefile" ]; then
    for t in $(grep -oE '^(test|tests|check|lint|typecheck):' "$d/Makefile" | tr -d : | sort -u); do
      printf 'check\tMakefile\tmake %s\n' "$t"
    done
  fi
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/pytest.ini" ] || [ -f "$d/setup.cfg" ]; then
    if grep -qs pytest "$d/pyproject.toml" "$d/pytest.ini" "$d/setup.cfg"; then printf 'check\tpython\tpython -m pytest\n'; fi
    if grep -qs '\[tool.mypy\]' "$d/pyproject.toml"; then printf 'check\tpython\tmypy .\n'; fi
    if grep -qs '\[tool.ruff' "$d/pyproject.toml"; then printf 'check\tpython\truff check .\n'; fi
  fi
  if [ -f "$d/Cargo.toml" ]; then printf 'check\tCargo.toml\tcargo test\ncheck\tCargo.toml\tcargo clippy -- -D warnings\n'; fi
  if [ -f "$d/go.mod" ]; then printf 'check\tgo.mod\tgo test ./...\ncheck\tgo.mod\tgo vet ./...\n'; fi
  for f in "$d"/.github/workflows/*.yml "$d"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*run:[[:space:]]*\([^|>].*\)$/\1/p' "$f" | while IFS= read -r t; do
      printf 'check\tCI %s\t%s\n' "${f#"$d"/}" "$t"
    done
  done
  for f in tests/run.sh test.sh scripts/test.sh bin/test; do
    if [ -x "$d/$f" ]; then printf 'check\t%s\t./%s\n' "$f" "$f"; fi
  done
  return 0
}

cmd_scan() {
  local d m p kind
  d=$(cd "${1:-.}" && pwd); m=$(main_of "$d")
  if upstream_done "$m"; then echo "upstream	ok"; else echo "upstream	missing"; fi
  kind=$(tracker_kind "$m"); printf 'tracker\t%s\n' "$kind"
  for p in .claude/settings.json .artisan-agent/config.yml PRODUCT_STANDARDS.md CODING_STANDARDS.md \
           docs/agents/triage-labels.md GLOSSARY.md docs/adr .out-of-scope; do
    if [ -e "$m/$p" ]; then printf 'item\t%s\tpresent\n' "$p"; else printf 'item\t%s\tmissing\n' "$p"; fi
  done
  if grep -qsF "$POINTER" "$m/$(agents_file "$m")"; then printf 'item\tpointer\tpresent\n'; else printf 'item\tpointer\tmissing\n'; fi
  if grep -qs 'Who the Artisan is' "$m/docs/agents/issue-tracker.md"; then printf 'item\tidentity\tpresent\n'; else printf 'item\tidentity\tmissing\n'; fi
  p=$(git -C "$m" rev-parse --path-format=absolute --git-path hooks)/pre-commit
  if [ ! -e "$p" ]; then echo "pre-commit	missing"; elif grep -q artisan-agent-pre-commit "$p"; then echo "pre-commit	installed"; else echo "pre-commit	foreign"; fi
  if [ ! -d "$HOME_DIR/.git" ]; then echo "individual-home	missing"
  elif [ -s "$(motivation_file "$m")" ]; then echo "motivation	recorded"; else echo "motivation	none"; fi
  if git -C "$m" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then printf 'setup-branch\t%s\n' "$BRANCH"; fi
  found_checks "$m"
}

open_pr() { # url of an open setup PR, if any
  (cd "$1" && "$GH" pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null) || true
}

cmd_begin() {
  local m wt base url
  m=$(main_of "${1:-.}")
  upstream_done "$m" || die "upstream's setup has not run here; type /mattpocock-skills:setup-matt-pocock-skills first"
  wt="$(dirname "$m")/$(basename "$m")-wt/artisan-agent-setup"
  if [ -d "$wt" ]; then printf '%s\n' "$wt"; return; fi
  if git -C "$m" remote get-url origin >/dev/null 2>&1; then
    git -C "$m" fetch -q origin >/dev/null 2>&1 || true
    url=$(open_pr "$m")
    [ -z "$url" ] || die "a setup PR is still open: $url; merge or close it, then rerun setup"
  fi
  base=$(base_ref "$m")
  if git -C "$m" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
    if git -C "$m" merge-base --is-ancestor "$BRANCH" "$base"; then
      git -C "$m" branch -q -D "$BRANCH"   # already merged: start fresh
    else
      git -C "$m" worktree add -q "$wt" "$BRANCH" >&2   # unmerged local setup branch (no remote): continue it
      printf '%s\n' "$wt"; return
    fi
  fi
  git -C "$m" worktree add -q -b "$BRANCH" "$wt" "$base" >&2
  printf '%s\n' "$wt"
}

standards_new() { # file title what
  [ -e "$1" ] && return 0
  printf '# %s\n\n%s\n\n## Always ask\n\nThings that must always come back to the Artisan. Only the Artisan changes this list (setup or a retro lesson).\n' "$2" "$3" >"$1"
  echo "changed: created ${1##*/}"
}

hook_script() { # a self-contained copy of block-replaced.sh with the reasons baked in
  printf '#!/bin/bash\n# artisan-agent-block-replaced: written by artisan-agent setup because plugin hooks did not fire here.\n'
  printf 'set -euo pipefail\n'
  printf '# Generated from the plugin'"'"'s guard/replaced-skills.list; rerun setup to refresh it.\n'
  printf 'reasons=$(cat <<'"'"'EOT'"'"'\n'
  "$GUARD/guard.sh" reasons
  printf 'EOT\n)\n'
  sed -e '1,/^input=/{/^input=/!d;}' -e 's|^reason=.*guard.sh" reasons|reason=$(printf "%s\\n" "$reasons"|' "$GUARD/block-replaced.sh"
}

cmd_apply() {
  local wt=$1 answers=$2 kind f login line team boundary level item tmp check break_cmd break_desc prepare outcome proven who
  [ -d "$wt" ] || die "no worktree at $wt (run begin first)"
  [ -f "$answers" ] || die "no answers file at $answers"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  wt=$(cd "$wt" && pwd)
  upstream_done "$wt" || die "upstream's setup has not run here; type /mattpocock-skills:setup-matt-pocock-skills first"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/artisan-setup.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # Config: a copy of the template, which holds every default.
  f=$wt/.artisan-agent/config.yml
  team=$(jq -r '.team_repo // ""' "$answers")
  case "$team" in ''|[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) ;; *) die "team_repo must be owner/name, got: $team" ;; esac
  case "$team" in */*/*|*[!A-Za-z0-9_./-]*) die "team_repo must be owner/name, got: $team" ;; esac
  if [ ! -e "$f" ]; then
    mkdir -p "$(dirname "$f")"
    if [ -n "$team" ]; then
      sed "s|^team_guardrails_repo:\$|team_guardrails_repo: $team|" "$ROOT/templates/config.yml" >"$f"
    else
      cp "$ROOT/templates/config.yml" "$f"
    fi
    echo "changed: created .artisan-agent/config.yml"
  else
    echo "unchanged: .artisan-agent/config.yml"
    if [ -n "$team" ] && ! grep -qxF "team_guardrails_repo: $team" "$f"; then
      echo "kept: .artisan-agent/config.yml exists; set team_guardrails_repo: $team in it by hand if you want it"
    fi
  fi
  if ! grep -qsx '.artisan-agent/runs/' "$wt/.gitignore"; then
    printf '.artisan-agent/runs/\n' >>"$wt/.gitignore"
    echo "changed: .gitignore ignores .artisan-agent/runs/"
  fi

  # Settings: plugins enabled (never installed here), our marketplace, the deny rules;
  # the hook only as the fallback for plugin hooks that don't fire.
  "$GUARD/guard.sh" deny-json >"$tmp/deny.json"
  # The Engineering chat compacts at the config's chat_context.compact_percent (default 40).
  compact=$("$ROOT/scripts/config.sh" get chat_context.compact_percent --file "$wt/.artisan-agent/config.yml") || die "cannot read chat_context.compact_percent"
  if [ "$(jq -r '.hook_fallback // false' "$answers")" = true ]; then
    mkdir -p "$wt/.claude/hooks"
    hook_script >"$tmp/hook.sh"
    if [ -e "$wt/$HOOK_FILE" ] && ! grep -q artisan-agent-block-replaced "$wt/$HOOK_FILE"; then
      echo "kept: $HOOK_FILE exists and is not ours; left alone"
    elif ! cmp -s "$tmp/hook.sh" "$wt/$HOOK_FILE"; then
      cp "$tmp/hook.sh" "$wt/$HOOK_FILE"; chmod +x "$wt/$HOOK_FILE"
      echo "changed: wrote $HOOK_FILE"
    fi
    # guard.sh prints --hook-command into JSON unescaped, so set the quoted path with jq.
    "$GUARD/guard.sh" settings-json --hook-command HOOK \
      | jq --arg c "\"\$CLAUDE_PROJECT_DIR\"/$HOOK_FILE" '.hooks.UserPromptExpansion[].hooks[].command = $c' >"$tmp/hook.json"
    edit settings "$wt/.claude/settings.json" "$tmp/deny.json" "$tmp/hook.json" --compact-percent "$compact"
  else
    edit settings "$wt/.claude/settings.json" "$tmp/deny.json" --compact-percent "$compact"
  fi

  # Standards, each with "Always ask"; seeded from question 2.
  standards_new "$wt/PRODUCT_STANDARDS.md" "Product standards" "Product level: the product's taste, in this repo and changed by PR. Read by triage, workers and verifiers at the point of use."
  standards_new "$wt/CODING_STANDARDS.md" "Coding standards" "Product level: how code is written in this repo, changed by PR. Read by workers and verifiers at the point of use."
  set -- ; while IFS= read -r item; do [ -n "$item" ] && set -- "$@" "- $item"; done <<EOT
$(jq -r '.always_ask.product // [] | .[]' "$answers")
EOT
  edit section "$wt/PRODUCT_STANDARDS.md" "Always ask" "$@"
  set -- ; while IFS= read -r item; do [ -n "$item" ] && set -- "$@" "- $item"; done <<EOT
$(jq -r '.always_ask.coding // [] | .[]' "$answers")
EOT
  edit section "$wt/CODING_STANDARDS.md" "Always ask" "$@"

  # Question 1: PR boundaries, a guardrail at the level the Artisan chose. Product level lives here.
  boundary=$(jq -r '.pr_boundary // ""' "$answers"); level=$(jq -r '.pr_level // "product"' "$answers")
  if [ -n "$boundary" ] && [ "$level" = product ]; then
    edit section "$wt/CODING_STANDARDS.md" "Guardrails" "- \`pr-boundaries\`: one PR per $boundary (set at setup)."
  fi

  # Question 4: the checks. apply proves each one itself, so only a check shown failing on its
  # break is recorded; any other outcome is reported and the check is not trusted.
  set -- ; while IFS=$'\037' read -r check break_cmd break_desc prepare; do
    [ -n "$check" ] || continue
    if [ -z "$break_cmd" ]; then printf 'no-break\t%s\t(no break_cmd given: not proven, not recorded)\n' "$check"; continue; fi
    if [ -n "$prepare" ]; then
      outcome=$(cd "$wt" && cmd_prove_check --prepare "$prepare" --break "$break_cmd" -- "$check" 2>/dev/null) && proven=1 || proven=0
    else
      outcome=$(cd "$wt" && cmd_prove_check --break "$break_cmd" -- "$check" 2>/dev/null) && proven=1 || proven=0
    fi
    if [ "$proven" = 1 ]; then
      set -- "$@" "- \`$check\`: proven to fail on $(date +%Y-%m-%d), breaking: $break_desc"
    fi
    printf '%s\n' "${outcome%%$'\n'*}"
  done <<EOT
$(jq -r '.checks // [] | .[] | [.command, (.break_cmd // ""), (.break // .break_cmd // ""), (.prepare // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' "$answers")
EOT
  if [ $# -gt 0 ]; then edit section "$wt/CODING_STANDARDS.md" "Checks" "$@"; fi

  # The ten labels, recorded in the triage-labels doc.
  edit labels-doc "$wt/docs/agents/triage-labels.md" | sed '/^labels:$/,$d'

  # Who the Artisan is, and agent-filed tickets carry needs-triage (read by triage).
  kind=$(tracker_kind "$wt"); f=$wt/docs/agents/issue-tracker.md
  who="- **Who the Artisan is** (triage compares ticket authors to this):"
  if ! grep -qsF "${who#- }" "$f"; then
    case "$kind" in
      github) login=$("$GH" api user --jq .login 2>/dev/null || true)
              line="$who \`gh api user --jq .login\`${login:+, which was \`$login\` at setup}." ;;
      gitlab) login=$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)
              line="$who \`glab api user\` (its \`username\`)${login:+, which was \`$login\` at setup}." ;;
      *) login=$(git -C "$wt" config user.name 2>/dev/null || true)
         line="$who \`git config user.name\`${login:+, which was \`$login\` at setup}. Make no \`gh\` call to find it." ;;
    esac
    edit section "$f" "Conventions" "$line"
  else
    echo "unchanged: $f names the Artisan"
  fi
  if ! grep -qs 'Tickets filed by agents' "$f"; then
    edit section "$f" "Conventions" "- **Tickets filed by agents** carry the \`needs-triage\` label (the string \`docs/agents/triage-labels.md\` maps it to). Tickets the Artisan writes or approves skip triage."
  fi

  # The front-door pointer.
  f=$wt/$(agents_file "$wt")
  if ! grep -qsF "$POINTER" "$f"; then
    { [ -s "$f" ] && printf '\n'; printf '%s\n' "$POINTER"; } >>"$f"
    echo "changed: ${f##*/} points at /artisan-agent:craft"
  fi

  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet; then
    echo "unchanged: nothing to commit"
  else
    git_commit "$wt" "Set up Artisan Agent for this project"
    echo "committed: $(git -C "$wt" rev-parse --short HEAD)"
  fi
}

cmd_labels() {
  local wt=$1 have name color desc
  [ "$(tracker_kind "$wt")" = github ] || { echo "skipped: the tracker is not GitHub; the labels are recorded in docs/agents/triage-labels.md only"; return 0; }
  have=$(cd "$wt" && "$GH" label list --limit 500 --json name --jq '.[].name') || die "gh label list failed"
  edit labels-doc "$wt/docs/agents/triage-labels.md" | sed '1,/^labels:$/d' | while IFS=$'\t' read -r name desc; do
    if grep -qxF "$name" <<EOH
$have
EOH
    then continue; fi
    case "$name" in
      review-gate) color=5319e7 ;; plan) color=0e8a16 ;; in-run) color=fbca04 ;;
      urgent) color=b60205 ;; deferred) color=c5def5 ;; *) color=ededed ;;
    esac
    (cd "$wt" && "$GH" label create "$name" --color "$color" --description "$desc" >/dev/null) || die "gh label create $name failed"
    echo "changed: created label $name"
  done
  echo "labels: the ten labels exist on the tracker"
}

cmd_pre_commit() {
  local m out
  m=$(main_of "${1:-.}")
  if out=$("$GUARD/install-pre-commit.sh" "$m" 2>&1); then echo "pre-commit: $out"; else echo "kept: $out"; return 1; fi
}

cmd_hook_probe() {
  local m name out
  m=$(main_of "${1:-.}")
  # Capture first, then take line one: an early-closing reader would SIGPIPE guard.sh under pipefail.
  name=$("$GUARD/guard.sh" flag-watch)
  name=${name%%$'\n'*}
  out=$(cd "$m" && "$CLAUDE_BIN" -p --output-format json --max-turns 1 --max-budget-usd 0.05 "/$name probe" 2>&1 || true)
  case "$out" in *"$MARKER"*) echo fires ;; *) echo silent ;; esac
}

cmd_prove_check() {
  local ref=HEAD prepare="" brk="" check wt rc=0 out
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) ref=$2; shift 2 ;;
      --prepare) prepare=$2; shift 2 ;;
      --break) brk=$2; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  [ -n "$brk" ] && [ $# -gt 0 ] || usage
  check="$*"
  git rev-parse --git-dir >/dev/null 2>&1 || die "run prove-check inside the repo"
  wt=$(mktemp -d "${TMPDIR:-/tmp}/artisan-prove.XXXXXX")/wt
  git worktree add -q --detach "$wt" "$ref" >&2 || die "cannot make a throwaway worktree at $ref"
  # Our own throwaway: --force is needed because we break it on purpose.
  # shellcheck disable=SC2064
  trap "git worktree remove --force '$wt' >/dev/null 2>&1 || true; rm -rf '$(dirname "$wt")'" EXIT
  if [ -n "$prepare" ]; then (cd "$wt" && bash -c "$prepare") >/dev/null 2>&1 || { printf 'prepare-failed\t%s\n' "$check"; return 5; }; fi
  out=$(cd "$wt" && bash -c "$check" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'already-failing\t%s\t(exit %s before any break; fix it first)\n' "$check" "$rc"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    return 3
  fi
  (cd "$wt" && bash -c "$brk") >/dev/null 2>&1 || true
  if [ -z "$(git -C "$wt" status --porcelain)" ]; then printf 'no-break\t%s\t(the break changed no file)\n' "$check"; return 4; fi
  rc=0; out=$(cd "$wt" && bash -c "$check" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'cannot-fail\t%s\t(still passes after the break: not trusted)\n' "$check"
    return 1
  fi
  printf 'proven\t%s\t(exit %s after the break)\n' "$check" "$rc"
}

need_home() { [ -d "$HOME_DIR/.git" ] || die "no individual home at $HOME_DIR; run machine-level setup first (machine-setup.sh init)"; }

cmd_motivation() {
  local sub=${1:-} f text id
  [ $# -gt 0 ] && shift
  f=$(motivation_file "${1:-.}"); id=$(repo_id "${1:-.}")
  case "$sub" in
    get) [ -s "$f" ] || exit 1; cat "$f" ;;
    set)
      need_home
      [ ! -s "$f" ] || die "a motivation is already recorded for $id ($f); setup never overwrites it"
      text=$(cat)
      [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || die "empty motivation; nothing recorded (skipping is fine)"
      mkdir -p "$(dirname "$f")"
      printf '# Motivation: %s\n\nRepo: %s\nRecorded: %s\nPrivate: yes\n\n%s\n' "$id" "$id" "$(date +%Y-%m-%d)" "$text" >"$f"
      git -C "$HOME_DIR" add -- "$f"
      git_commit "$HOME_DIR" "Motivation for $id" -- "$f"
      echo "changed: motivation for $id recorded in the individual home"
      ;;
    *) usage ;;
  esac
}

cmd_individual() {
  local heading=$1 line=$2 f=$HOME_DIR/CODING_STANDARDS.md
  need_home
  edit section "$f" "$heading" "$line"
  if [ -n "$(git -C "$HOME_DIR" status --porcelain -- CODING_STANDARDS.md)" ]; then
    git_commit "$HOME_DIR" "Individual guardrail: $line" -- CODING_STANDARDS.md
  fi
}

cmd_finish() {
  local wt=$1 m base n url
  [ -d "$wt" ] || die "no worktree at $wt"
  wt=$(cd "$wt" && pwd); m=$(main_of "$wt")
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "uncommitted changes in $wt; run apply again"
  base=$(base_ref "$m")
  n=$(git -C "$wt" rev-list --count "$base..HEAD")
  if [ "$n" = 0 ]; then
    git -C "$m" worktree remove "$wt"
    git -C "$m" branch -q -D "$BRANCH"
    echo "unchanged: the project is already set up; no PR"
    return 0
  fi
  if ! git -C "$m" remote get-url origin >/dev/null 2>&1; then
    git -C "$m" worktree remove "$wt"
    echo "no remote: branch $BRANCH holds the setup commit; merge it yourself"
    return 0
  fi
  git -C "$wt" push -q -u origin "$BRANCH" >&2 || die "push failed; the worktree is kept at $wt"
  url=$(open_pr "$wt")
  if [ -z "$url" ]; then
    url=$(cd "$wt" && "$GH" pr create --head "$BRANCH" --base "${base#origin/}" --title "Set up Artisan Agent" \
      --body "Project setup by /artisan-agent:setup: settings (plugins enabled, marketplace, replaced-skill deny rules), config with every default, standards with \"Always ask\", the ten labels in the triage-labels doc, who the Artisan is, and the front-door pointer. Nothing existing was overwritten.") \
      || die "gh pr create failed; the branch is pushed and the worktree kept at $wt"
    echo "pr: $url"
  else
    echo "pr: $url (updated)"
  fi
  git -C "$m" worktree remove "$wt"
  git -C "$m" branch -q -D "$BRANCH"   # pushed; the PR holds it, and a rerun starts fresh
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  scan) cmd_scan "$@" ;;
  begin) cmd_begin "$@" ;;
  apply) [ $# -eq 2 ] || usage; cmd_apply "$@" ;;
  labels) [ $# -eq 1 ] || usage; cmd_labels "$@" ;;
  pre-commit) cmd_pre_commit "$@" ;;
  hook-probe) cmd_hook_probe "$@" ;;
  prove-check) cmd_prove_check "$@" ;;
  motivation) cmd_motivation "$@" ;;
  individual) [ $# -eq 2 ] || usage; cmd_individual "$@" ;;
  finish) [ $# -eq 1 ] || usage; cmd_finish "$@" ;;
  *) usage ;;
esac
