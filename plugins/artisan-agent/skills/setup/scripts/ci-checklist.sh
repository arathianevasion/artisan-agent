#!/usr/bin/env bash
# The CI checklist (#196). Read-only: reads a repo's GitHub Actions workflows,
# test configs, .artisan-agent/config.yml and CODING_STANDARDS.md `## Checks`,
# and prints one markdown table, an item per row marked present, missing or n/a,
# with a one-line how-to and a link to references/ci.md. Changes nothing.
#
# Usage: ci-checklist.sh [repo-dir]     (default: the current directory)
# Exit:  0 always when the directory exists; 2 on bad usage.
# Bash 3.2-safe. The detection is a heuristic over text: it says what the files
# show, and the Artisan decides (references/ci.md).

set -u

ref='${CLAUDE_PLUGIN_ROOT}/references/ci.md'
repo=${1:-.}
[ $# -le 1 ] && [ -d "$repo" ] || { echo "usage: ci-checklist.sh [repo-dir]" >&2; exit 2; }

wf=""
for f in "$repo"/.github/workflows/*.yml "$repo"/.github/workflows/*.yaml; do
  [ -f "$f" ] && wf="$wf
$(grep -vE '^[[:space:]]*#' "$f")"
done
cfg=""
for f in "$repo"/playwright.config.* "$repo"/vitest.config.* "$repo"/vite.config.* "$repo"/jest.config.* \
  "$repo"/pytest.ini "$repo"/pyproject.toml "$repo"/package.json "$repo"/tox.ini; do
  [ -f "$f" ] && cfg="$cfg
$(grep -vE '^[[:space:]]*(#|//)' "$f")"
done
both="$wf
$cfg"
config="$repo/.artisan-agent/config.yml"

has() { printf '%s\n' "$1" | grep -Eq -- "$2"; }

have_wf=1
[ -n "$wf" ] || have_wf=0

# Each item sets st (present|missing|n/a), how, anchor.
rows=""
add() { # name status how anchor
  rows="$rows
| $1 | $2 | $3 | \`$ref#$4\` |"
}

# --- state of the items other items lean on ---
skiptree=missing
has "$wf" 'actions/artifacts[^[:space:]]*name=' && skiptree=present

quarantine=0
has "$both" 'quarantine' && quarantine=1
if [ -n "$(find "$repo" -maxdepth 3 \( -name node_modules -o -name .git \) -prune -o -iname '*quarantine*' -type f -print 2>/dev/null | head -n 1)" ]; then
  quarantine=1
fi

# --- the items ---
if [ "$have_wf" = 0 ]; then
  for pair in \
    "Shard the slow suite|shard" "Cache dependencies and browsers|cache" \
    "Cheap checks first, fail fast|fail-fast" "Cancel superseded runs|cancel-superseded" \
    "Skip a tree that already passed|skip-passed-trees" "Retry in the job, with a quarantine list|retries-and-quarantine" \
    "One gate command|one-gate-command" "No second run on main|no-second-run-on-main" \
    "Docs-only changes run nothing|docs-only" "Per-test timings kept|timings" \
    "The merge-gate time limit is recorded|merge-gate-limit"; do
    add "${pair%%|*}" "n/a" "no GitHub Actions workflow in .github/workflows" "${pair##*|}"
  done
else
  # sharding
  if has "$both" '(--shard|shard:|shardIndex|matrix\.shard|--splits|pytest-split)'; then
    add "Shard the slow suite" present "a shard matrix or --shard is in use" shard
  else
    add "Shard the slow suite" missing "split the slow suite across runners with a matrix and the runner's --shard flag" shard
  fi
  # caching
  if has "$wf" '(actions/cache|cache:|cache-dependency-path|ms-playwright)'; then
    add "Cache dependencies and browsers" present "a cache step or a setup action's cache: is set" cache
  else
    add "Cache dependencies and browsers" missing "turn on the setup action's cache: and cache the browser directory" cache
  fi
  # fail fast
  if has "$wf" '(^[[:space:]]+needs:|fail-fast: true|--bail|--max-failures|--maxfail|bail:)'; then
    add "Cheap checks first, fail fast" present "a job needs an earlier job, or the runner stops at the first failures" fail-fast
  else
    add "Cheap checks first, fail fast" missing "put lint and typecheck in a job the test jobs need" fail-fast
  fi
  # cancel superseded
  if has "$wf" 'cancel-in-progress:[[:space:]]*true'; then
    add "Cancel superseded runs" present "concurrency cancels in-progress runs" cancel-superseded
  else
    add "Cancel superseded runs" missing "add a concurrency group per ref with cancel-in-progress: true" cancel-superseded
  fi
  # skip passed trees
  if [ "$skiptree" = present ]; then
    add "Skip a tree that already passed" present "looks up an artifact by name through the API" skip-passed-trees
  elif has "$wf" 'actions/cache' && has "$wf" '(rev-parse[^[:space:]]*[[:space:]]+[^[:space:]]*\^\{tree\}|tree)'; then
    add "Skip a tree that already passed" missing "a cache is used as the record, and main can't restore it; publish an artifact named for the tree instead" skip-passed-trees
  else
    add "Skip a tree that already passed" missing "a passing run publishes an artifact named for its tree; a later run looks it up with actions/artifacts?name=" skip-passed-trees
  fi
  # retries and quarantine
  retries=0
  has "$both" '(retries:[[:space:]]*[1-9]|retryTimes|retry:[[:space:]]*[1-9]|--retries[ =][1-9]|--rerun-failed|--reruns|nick-fields/retry)' && retries=1
  if [ $retries = 1 ] && [ $quarantine = 1 ]; then
    add "Retry in the job, with a quarantine list" present "retries and a quarantine list are both set" retries-and-quarantine
  elif [ $retries = 1 ]; then
    add "Retry in the job, with a quarantine list" missing "retries are set but no quarantine list: add one, and report what passed on a retry" retries-and-quarantine
  elif [ $quarantine = 1 ]; then
    add "Retry in the job, with a quarantine list" missing "a quarantine list exists but nothing retries in the job" retries-and-quarantine
  else
    add "Retry in the job, with a quarantine list" missing "retry failed tests once in the job (retries: 0 today), and keep a quarantine list" retries-and-quarantine
  fi
  # one gate command
  gate=0
  scripts=$(printf '%s\n' "$wf" | grep -E '^[[:space:]-]*(run:|\./|bash |sh |make )' | grep -oE '[A-Za-z0-9_./-]+\.sh' | sed 's|^\./||')
  for s in $scripts; do
    [ -f "$repo/$s" ] && gate=1
  done
  checks=$(awk '/^## Checks/ {on=1; next} /^## / {on=0} on && /^- `/ {sub(/^- `/, ""); sub(/`.*/, ""); print}' "$repo/CODING_STANDARDS.md" 2>/dev/null)
  if [ -n "$checks" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] && printf '%s\n' "$wf" | grep -qF -- "$c" && gate=1
    done <<EOF2
$checks
EOF2
  fi
  if [ $gate = 1 ]; then
    add "One gate command" present "the workflow runs a script in the repo or a recorded check, the command a person runs" one-gate-command
  else
    add "One gate command" missing "put the gate in one script (like tests/run.sh) and have the workflow call it" one-gate-command
  fi
  # no second run on main
  if ! has "$wf" '^[[:space:]]*push:'; then
    add "No second run on main" n/a "no push trigger, so nothing runs again on main" no-second-run-on-main
  elif [ "$skiptree" = present ]; then
    add "No second run on main" present "the push run can skip a tree that passed (artifact lookup)" no-second-run-on-main
  else
    add "No second run on main" missing "a push runs the suite on a tree its pull request passed; look the tree up (see skip a passed tree)" no-second-run-on-main
  fi
  # docs only
  filter=0
  has "$wf" '(paths-ignore:|^[[:space:]]+paths:)' && filter=1
  skip=0
  if [ -f "$config" ]; then
    awk '/^merge_gate_skip_paths:/ {
           v=$0; sub(/^merge_gate_skip_paths:[[:space:]]*/, "", v)
           if (v ~ /^\[[^]]/) {found=1; exit}
           on=1; next }
         on && /^[[:space:]]*-[[:space:]]/ {found=1; exit}
         on && /^[^[:space:]-]/ {exit}
         END {exit found ? 0 : 1}' "$config" && skip=1
  fi
  if [ $filter = 1 ] && [ $skip = 1 ]; then
    add "Docs-only changes run nothing" present "a workflow path filter and merge_gate_skip_paths agree" docs-only
  elif [ $filter = 1 ]; then
    add "Docs-only changes run nothing" missing "the workflow filters paths, but merge_gate_skip_paths is empty: add the same paths" docs-only
  elif [ $skip = 1 ]; then
    add "Docs-only changes run nothing" missing "merge_gate_skip_paths is set, but the workflow has no paths filter" docs-only
  else
    add "Docs-only changes run nothing" missing "add paths-ignore for docs to the workflow and the same paths to merge_gate_skip_paths" docs-only
  fi
  # timings
  if has "$wf" 'upload-artifact' && has "$both" '(junit|durations|timing|--reporter|reporter:|--profile)'; then
    add "Per-test timings kept" present "a report with durations is uploaded as an artifact" timings
  else
    add "Per-test timings kept" missing "write a junit or json report and upload it with actions/upload-artifact" timings
  fi
  # merge-gate limit
  if [ -f "$config" ] && grep -Eq '^merge_gate_minutes_limit:[[:space:]]*[0-9]' "$config"; then
    add "The merge-gate time limit is recorded" present "merge_gate_minutes_limit is set in .artisan-agent/config.yml" merge-gate-limit
  else
    add "The merge-gate time limit is recorded" missing "set merge_gate_minutes_limit in .artisan-agent/config.yml (6 by default)" merge-gate-limit
  fi
fi

printf '| Item | Status | What the files show, or how | Reference |\n|---|---|---|---|%s\n' "$rows"
