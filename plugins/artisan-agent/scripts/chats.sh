#!/usr/bin/env bash
# Two chats through the tracker: what the Engineering chat and the Product chat
# do for each other, and only through issues. The rules and the ownership
# table: ${CLAUDE_PLUGIN_ROOT}/references/two-chats.md.
#
# Usage (repo: --repo OWNER/NAME, else $ARTISAN_REPO, else `gh repo view`):
#   chats.sh send --repo R <issue>...
#       Product chat: "send #N and #M to engineering". Creates a `plan` issue
#       with those tickets as sub-issues, for the Engineering chat's plan
#       step. Refuses (6) a ticket that is `in-run`, closed or missing; reuses
#       the open plan issue with the same title. Prints the plan's number.
#   chats.sh guard --repo R <issue>
#       Product chat, before it triages, edits or relabels a ticket: exit 0 if
#       the ticket is free to touch, 6 (and a line naming the run) if it is
#       `in-run`.
#   chats.sh label-run --repo R <run-dir>
#       Engineering chat, once a run starts: every ticket in scope gets the
#       `in-run` label and one comment naming the run id (once). Exit 1 if any
#       ticket could not be marked.
#   chats.sh approve-envelope --repo R <plan-issue>
#       Engineering chat: records on the plan issue that the Artisan approved
#       the run envelope before the plan was queued (so a queued plan skips
#       the approval when its turn comes).
#   chats.sh gates --repo R
#       the open `review-gate` issues, read from the tracker, batched by job
#       and role, as a Markdown table. Works across both chats and every run.
#   chats.sh sweep --repo R [--chat engineering|product] [--idle] [--no-fetch]
#                  [--project DIR]
#       The cheap check each chat makes on every wake and at least every
#       sweep_minutes: gates (above), gates closed by hand, guardrail changes,
#       a new plugin version, and (Engineering chat) the plan to start now
#       when the run lock is free. Prints Markdown, then `ACTION <verb> ...`
#       lines for the chat to act on, then `notify: <text>` when --idle (the
#       terminal is idle) and a decision is waiting that no earlier sweep
#       notified. A chat sends `notify:` as a push notification.
#   chats.sh due [--chat C] [--project DIR]
#       exit 0 if the chat's last sweep was at least sweep_minutes ago (or
#       never), else 1.
#
# The sweep's own memory (last sweep, versions seen, what it announced) is the
# chat's own: .artisan-agent/runs/.chat/<chat>.json (git-ignored). Nothing
# else passes between the chats.
#
# Exit status: 0 ok, 1 error, 2 usage, 6 refused.
# Portable to bash 3.2 (macOS) and Linux. Needs jq, python3 and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "chats.sh: $*"; }

REPO=${ARTISAN_REPO:-}
CHAT=engineering
IDLE=0
FETCH=1
PROJECT=.
ARGS=()
parse() {
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
      --chat) [ $# -ge 2 ] || usage; CHAT=$2; shift 2 ;;
      --project) [ $# -ge 2 ] || usage; PROJECT=$2; shift 2 ;;
      --idle) IDLE=1; shift ;;
      --no-fetch) FETCH=0; shift ;;
      --*) usage ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
  case "$CHAT" in engineering|product) ;; *) usage ;; esac
}

need_repo() {
  [ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "no repository: pass --repo OWNER/NAME"
}

# The repo's main checkout, where .artisan-agent/ lives.
main_checkout() {
  local common
  common=$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository: $PROJECT"
  dirname "$common"
}

RUN_MARK='artisan-agent:run '
ENVELOPE_MARK='artisan-agent:envelope-approved'
CLOSED_MARK='artisan-agent:gate-closed-by-hand'

issue_json() { # n: number,title,state,labels,body,comments
  gh issue view "$1" -R "$REPO" --json number,title,state,labels,body,comments 2>/dev/null
}

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# The run id an in-run ticket's comment names, or empty.
run_id_of() { # issue-json
  jq -r --arg m "$RUN_MARK" '[(.comments // [])[] | .body // "" | capture("<!-- " + $m + "(?<id>[^ ]+) -->")? | .id] | last // ""' <<<"$1"
}

is_in_run() { jq -e 'any((.labels // [])[]; .name == "in-run")' <<<"$1" >/dev/null; }

# ------------------------------------------------------------------- guard

cmd_guard() {
  [ ${#ARGS[@]} -eq 1 ] || usage
  need_repo
  local n=${ARGS[0]#\#} j run
  j=$(issue_json "$n") || die "could not read #$n"
  if is_in_run "$j"; then
    run=$(run_id_of "$j")
    echo "#$n is in run ${run:-(unknown)}: the Product chat doesn't triage, edit or relabel it. Comment on it, or file a new ticket."
    exit 6
  fi
  exit 0
}

# -------------------------------------------------------------------- send

cmd_send() {
  [ ${#ARGS[@]} -ge 1 ] || usage
  need_repo
  local n j state title list="" plan url num pid existing t id out
  local nums=()
  for n in "${ARGS[@]}"; do
    n=${n#\#}
    case "$n" in ''|*[!0-9]*) usage ;; esac
    j=$(issue_json "$n") || state_die 6 "chats.sh: #$n was not found on the tracker"
    is_in_run "$j" && state_die 6 "chats.sh: #$n is already in run $(run_id_of "$j"); it can't be sent again"
    state=$(lower "$(jq -r .state <<<"$j")")
    [ "$state" = open ] || state_die 6 "chats.sh: #$n is $state, not open"
    nums+=("$n")
    title=$(jq -r .title <<<"$j")
    list="$list- [ ] #$n $title
"
  done
  title="Plan: send $(printf '#%s, ' "${nums[@]}" | sed 's/, $//') to engineering"
  existing=$(gh issue list -R "$REPO" --state open --label plan --json number,title,labels \
    | jq -r --arg t "$title" '[.[] | select(.title == $t and any((.labels // [])[]; .name == "plan"))] | first | .number // empty')
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  url=$(gh issue create -R "$REPO" --title "$title" --label plan --body "Sent from the Product chat for the Engineering chat's plan step. It waits here until Engineering plans it.

$list
<!-- artisan-agent:sent-from-product -->") || die "could not create the plan issue"
  plan=${url##*/}
  for t in "${nums[@]}"; do
    out=$(gh api "repos/$REPO/issues/$t") || die "could not read #$t"
    id=$(jq -er .id <<<"$out") || die "no id for #$t"
    gh api --method POST "repos/$REPO/issues/$plan/sub_issues" -F "sub_issue_id=$id" >/dev/null 2>&1 \
      || echo "chats.sh: #$t could not be made a sub-issue of #$plan (it may already have a parent); the plan's body lists it" >&2
  done
  echo "$plan"
}

# --------------------------------------------------------------- label-run

cmd_label_run() {
  [ ${#ARGS[@]} -eq 1 ] || usage
  need_repo
  local run_dir=${ARGS[0]} file run t j bad=0
  file=$(state_file "$run_dir")
  state_valid_file "$file" || die "unreadable or wrong schema version: $file"
  run=$(jq -r .run_id "$file")
  for t in $(jq -r '.plan.scope[]' "$file"); do
    j=$(issue_json "$t") || { echo "chats.sh: could not read #$t" >&2; bad=1; continue; }
    is_in_run "$j" || gh issue edit "$t" -R "$REPO" --add-label in-run >/dev/null 2>&1 \
      || { echo "chats.sh: could not label #$t in-run" >&2; bad=1; continue; }
    if [ "$(run_id_of "$j")" != "$run" ]; then
      gh issue comment "$t" -R "$REPO" --body "In run \`$run\`. The Product chat won't triage, edit or relabel this ticket while it is in the run.

<!-- ${RUN_MARK}$run -->" >/dev/null 2>&1 || { echo "chats.sh: could not comment on #$t" >&2; bad=1; }
    fi
  done
  [ "$bad" -eq 0 ] || exit 1
}

cmd_approve_envelope() {
  [ ${#ARGS[@]} -eq 1 ] || usage
  need_repo
  local n=${ARGS[0]#\#} j
  j=$(issue_json "$n") || die "could not read #$n"
  if jq -e --arg m "$ENVELOPE_MARK" 'any((.comments // [])[]; (.body // "") | contains($m)) or ((.body // "") | contains($m))' <<<"$j" >/dev/null; then
    return 0
  fi
  gh issue comment "$n" -R "$REPO" --body "The Artisan approved this plan's run envelope (waves, models, estimates, budget) before it was queued; it starts without asking again.

<!-- $ENVELOPE_MARK -->" >/dev/null || die "could not comment on #$n"
}

# ------------------------------------------------------------------- gates

# One JSON line per open review-gate issue: number, kind, role, job, run, title.
gate_lines() {
  gh issue list -R "$REPO" --state open --label review-gate --json number,title,body,labels \
    | jq -c '.[] | select(any((.labels // [])[]; .name == "review-gate"))
      | (.body // "" | split("\n")) as $l
      | ($l | index("| Gate | Role needed | Slice | Tickets blocked |")) as $i
      | (if $i == null then [] else ($l[$i + 2] // "" | split("|")) end) as $row
      | ((.title | capture("^(?<k>[A-Za-z]+) gate")? | .k) // "Review") as $kind
      | {number, title,
         kind: $kind,
         role: (if ($row | length) > 2 then ($row[2] | gsub("^ +| +$"; "")) else "" end),
         run: ((.title | capture("\\(run (?<r>[^)]+)\\)")? | .r) // null)}
      | .role = (if .role == "" or .role == "-" then "unassigned" else .role end)
      | .job = (if (.kind | ascii_downcase) == "slice" then "13 Check a finished slice at a review gate" else "unassigned" end)
      | .what = (.title | sub("^[A-Za-z]+ gate: "; "") | sub(" \\(run [^)]+\\)$"; ""))' | jq -s 'sort_by(.number)'
}

render_gates() { # gate-lines-json
  local g=$1
  if [ "$(jq length <<<"$g")" -eq 0 ]; then
    echo "No review gate is open."
    return 0
  fi
  echo "| Role | Job | Gates | Waiting |"
  echo "|---|---|---|---|"
  jq -r 'group_by([.role, .job])[]
    | "| \(.[0].role) | \(.[0].job) | \(map("#\(.number) (\(.kind | ascii_downcase): \(.what)\(if .run then ", run " + .run else "" end))") | join("; ")) | \(length) |"' <<<"$g"
}

cmd_gates() {
  need_repo
  render_gates "$(gate_lines)"
}

# ------------------------------------------------------------- chat memory

chat_dir() { printf '%s/.artisan-agent/runs/.chat\n' "$(main_checkout)"; }
chat_file() { printf '%s/%s.json\n' "$(chat_dir)" "$CHAT"; }

mem_get() { # jq filter [args]
  local f
  f=$(chat_file)
  if [ -s "$f" ]; then jq -r "$@" "$f"; else echo ""; fi
}
mem_set() { # jq filter [args]: one-step rewrite
  local f d
  f=$(chat_file)
  d=$(dirname "$f")
  mkdir -p "$d"
  [ -s "$f" ] || echo '{}' >"$f"
  jq "$@" "$f" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

sweep_minutes() {
  local v
  v=$("$SCRIPT_DIR/config.sh" get sweep_minutes 2>/dev/null) || v=5
  case "$v" in ''|*[!0-9]*) v=5 ;; esac
  echo "$v"
}

cmd_due() {
  local last now mins
  last=$(mem_get '.last_sweep // ""')
  [ -n "$last" ] || exit 0
  now=$(state_now)
  mins=$(cd "$PROJECT" && sweep_minutes)
  [ $((now - last)) -ge $((mins * 60)) ] && exit 0
  exit 1
}

# --------------------------------------------------------------- the sweep

# The highest plugin version installed beside the running one (the cache keeps
# one folder per version), else the running one.
plugin_versions() {
  local own dir
  own=$(jq -r '.version // "0"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo 0)
  dir=${ARTISAN_PLUGIN_VERSIONS_DIR:-$(dirname "$PLUGIN_DIR")}
  python3 -I - "$own" "$dir" <<'PY'
import os, re, sys
own, d = sys.argv[1], sys.argv[2]
def key(v):
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.+-]", v))
vs = [own]
try:
    vs += [n for n in os.listdir(d) if re.match(r"^\d+\.\d+", n)]
except OSError:
    pass
print(own, max(vs, key=key))
PY
}

sweep_gates() {
  local g nums
  g=$(gate_lines)
  echo "## Review gates"
  echo
  render_gates "$g"
  nums=$(jq -r 'map("#\(.number)") | join(" ")' <<<"$g")
  [ -z "$nums" ] || echo "ACTION gates $nums" >>"$ACTIONS"
  WAITING_KEYS="$WAITING_KEYS$(jq -r '.[] | "gate-\(.number)"' <<<"$g" | tr '\n' ' ')"
  [ "$(jq length <<<"$g")" -eq 0 ] || WAITING_TEXT="$WAITING_TEXT$(jq length <<<"$g") review gate(s) waiting; "
}

# Gates closed by hand. The Engineering chat's runs record the approval
# (gate.sh sync, which comments on the issue); both chats read the line from
# the tracker.
sweep_closed_gates() {
  local main run_dir closed n j line carried seen out=""
  main=$(main_checkout)
  if [ "$CHAT" = engineering ]; then
    for run_dir in "$main"/.artisan-agent/runs/*/; do
      [ -f "$run_dir/state.json" ] || continue
      jq -e '(.review_gates // []) | any(.status == "open")' "$run_dir/state.json" >/dev/null 2>&1 || continue
      "$SCRIPT_DIR/gate.sh" sync "${run_dir%/}" >/dev/null 2>&1 || true
    done
  fi
  closed=$(gh issue list -R "$REPO" --state closed --label review-gate --json number,labels \
    | jq -r '.[] | select(any((.labels // [])[]; .name == "review-gate")) | .number')
  for n in $closed; do
    seen=$(mem_get --arg n "$n" '(.closed_announced // []) | index($n | tonumber) // empty')
    [ -z "$seen" ] || continue
    j=$(issue_json "$n") || continue
    line=$(jq -r --arg m "$CLOSED_MARK" '[(.comments // [])[] | .body // "" | select(contains($m))] | last // ""' <<<"$j" \
      | grep -v "^<!--" | sed '/^$/d' | head -n 1 || true)
    [ -n "$line" ] || continue
    out="$out$line
"
    mem_set --argjson n "$n" '.closed_announced = (((.closed_announced // []) + [$n]) | unique)'
  done
  if [ -n "$out" ]; then
    echo "## Gates closed on GitHub"
    echo
    printf '%s\n' "$out"
  fi
}

sweep_changes() {
  local src old new k out="" own latest have
  src=$("$SCRIPT_DIR/guardrails.sh" sources $([ "$FETCH" = 1 ] || echo --no-fetch) 2>/dev/null \
        | jq -c '{team: (.team.commit // null), product: (.product.commit // null), individual: (.individual.commit // null)}') \
    || src='{"team":null,"product":null,"individual":null}'
  [ -n "$src" ] || src='{"team":null,"product":null,"individual":null}'
  old=$(mem_get '.guardrails // empty')
  if [ -n "$old" ]; then
    for k in team product individual; do
      new=$(jq -r --arg k "$k" '.[$k] // ""' <<<"$src")
      have=$(jq -r --arg k "$k" '.[$k] // ""' <<<"$old")
      [ "$new" = "$have" ] || out="$out- The $k guardrails changed (${have:0:7} → ${new:0:7}); they apply from the next wave.
"
    done
  fi
  mem_set --argjson g "$src" '.guardrails = $g'
  read -r own latest <<<"$(plugin_versions)"
  have=$(mem_get '.plugin_version // ""')
  [ -n "$have" ] || have=$own
  [ "$latest" = "$have" ] || out="$out- A new plugin version is installed: $latest (was $have); it applies from the next wave.
"
  mem_set --arg v "$latest" '.plugin_version = $v'
  if [ -n "$out" ]; then
    echo "## Changes"
    echo
    printf '%s\n' "$out"
    echo "ACTION announce-changes" >>"$ACTIONS"
  fi
}

# Open plan issues, oldest first, that haven't started: not in-run, not
# blocked by an open plan, with at least one ticket not yet in a run.
plan_rows() {
  gh issue list -R "$REPO" --state open --label plan --json number,title,body,labels \
    | jq -c '.[] | select(any((.labels // [])[]; .name == "plan")) | select(any((.labels // [])[]; .name == "in-run") | not) | {number, title, body}' \
    | jq -s 'sort_by(.number)[]' | jq -c .
}

sweep_plans() {
  local rows p n t j total title blockers subs tickets open_tickets approved first="" locked held rows_out="" waiting=""
  rows=$(plan_rows)
  [ -n "$rows" ] || return 0
  locked=0
  held=$("$SCRIPT_DIR/run-lock.sh" check "$PROJECT" 2>/dev/null) || locked=1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$(jq -r .number <<<"$p")
    title=$(jq -r .title <<<"$p")
    blockers=$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null \
      | jq -r '[.[] | select((.state // "open" | ascii_downcase) == "open") | "#\(.number)"] | join(", ")') || blockers=""
    subs=$(gh api "repos/$REPO/issues/$n/sub_issues" 2>/dev/null | jq -c '[.[].number]') || subs="[]"
    [ -n "$subs" ] || subs="[]"
    if [ "$subs" = "[]" ]; then
      subs=$(jq -c '[.body // "" | scan("- \\[ \\] #([0-9]+)") | .[0] | tonumber]' <<<"$p")
    fi
    # Only open tickets count; any already in a run mean the plan has started.
    total=0 open_tickets=0 tickets=""
    for t in $(jq -r '.[]' <<<"$subs"); do
      j=$(issue_json "$t") || continue
      [ "$(lower "$(jq -r .state <<<"$j")")" = open ] || continue
      total=$((total + 1))
      tickets="$tickets${tickets:+, }#$t"
      is_in_run "$j" || open_tickets=$((open_tickets + 1))
    done
    [ -n "$tickets" ] || tickets="none (a request, not tickets)"
    if [ "$total" -gt 0 ] && [ "$open_tickets" -eq 0 ]; then continue; fi
    approved=no
    gh issue view "$n" -R "$REPO" --json body,comments 2>/dev/null \
      | jq -e --arg m "$ENVELOPE_MARK" 'any((.comments // [])[]; (.body // "") | contains($m)) or ((.body // "") | contains($m))' >/dev/null && approved=yes
    if [ -n "$blockers" ]; then
      rows_out="$rows_out| #$n ($title) | $tickets | waits for $blockers |
"
    elif [ -n "$first" ]; then
      rows_out="$rows_out| #$n ($title) | $tickets | queued behind #$first |
"
    elif [ "$locked" -eq 1 ]; then
      rows_out="$rows_out| #$n ($title) | $tickets | queued behind the run lock (held by ${held:-another run}) |
"
      first=$n
    else
      first=$n
      if [ "$approved" = yes ]; then
        rows_out="$rows_out| #$n ($title) | $tickets | **start the plan step now**; its envelope was approved before it was queued |
"
        echo "ACTION start-plan $n envelope-approved" >>"$ACTIONS"
      else
        rows_out="$rows_out| #$n ($title) | $tickets | **start the plan step now**; ask the Artisan to approve the run envelope (waves, models, estimates, budget) |
"
        echo "ACTION start-plan $n approve-envelope" >>"$ACTIONS"
        WAITING_KEYS="$WAITING_KEYS""plan-$n "
        WAITING_TEXT="$WAITING_TEXT""plan #$n needs its run envelope approved; "
      fi
    fi
  done <<EOF
$rows
EOF
  [ -n "$rows_out" ] || return 0
  echo "## Plans waiting for Engineering"
  echo
  echo "| Plan | Tickets | Status |"
  echo "|---|---|---|"
  printf '%s' "$rows_out"
  echo
}

sweep_decisions() { # Engineering chat only: decisions waiting in a live run's state file
  local main f run n
  main=$(main_checkout)
  SAW_DECISIONS=0
  for f in "$main"/.artisan-agent/runs/*/state.json; do
    [ -f "$f" ] || continue
    run=$(jq -r '.run_id // empty' "$f" 2>/dev/null) || continue
    n=$(jq -r '[(.decisions // [])[] | select(.status == "waiting")] | length' "$f" 2>/dev/null) || continue
    [ "${n:-0}" -gt 0 ] || continue
    echo "- Run $run has $n decision(s) waiting for the Artisan (\`wave.sh status\`)."
    SAW_DECISIONS=1
    WAITING_KEYS="$WAITING_KEYS""decisions-$run-$n "
    WAITING_TEXT="$WAITING_TEXT""$n decision(s) waiting in run $run; "
  done
}

cmd_sweep() {
  need_repo
  ACTIONS=$(mktemp "${TMPDIR:-/tmp}/chats-actions.XXXXXX")
  WAITING_KEYS="" WAITING_TEXT=""
  trap 'rm -f "$ACTIONS"' EXIT
  local before key fresh="" notified
  echo "# Sweep ($CHAT chat)"
  echo
  sweep_gates
  echo
  sweep_closed_gates
  sweep_changes
  if [ "$CHAT" = engineering ]; then
    sweep_plans
    sweep_decisions
  fi
  [ ! -s "$ACTIONS" ] || { cat "$ACTIONS"; }
  # A push notification, once per waiting decision, when the terminal is idle.
  notified=$(mem_get '(.notified // []) | join(" ")')
  for key in $WAITING_KEYS; do
    case " $notified " in *" $key "*) ;; *) fresh="$fresh $key" ;; esac
  done
  if [ "$IDLE" = 1 ] && [ -n "$fresh" ]; then
    echo "notify: Artisan Agent: ${WAITING_TEXT%; }"
    mem_set --arg add "$fresh" '.notified = (((.notified // []) + ($add | split(" ") | map(select(. != "")))) | unique)'
  fi
  mem_set --argjson now "$(state_now)" --arg keys "$WAITING_KEYS" '.last_sweep = $now | .notified = ((.notified // []) | map(select(. as $k | ($keys | split(" ") | index($k)))))
'
}

[ $# -ge 1 ] || usage
cmd=$1
shift
parse "$@"
case "$cmd" in
  send) cmd_send ;;
  guard) cmd_guard ;;
  label-run) cmd_label_run ;;
  approve-envelope) cmd_approve_envelope ;;
  gates) cmd_gates ;;
  sweep) cmd_sweep ;;
  due) cmd_due ;;
  *) usage ;;
esac
