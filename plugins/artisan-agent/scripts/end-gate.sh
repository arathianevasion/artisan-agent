#!/usr/bin/env bash
# The end gate and the PRs to main (#71): once every ticket in scope is done,
# a review-gate issue holds the end gate's packet (the deferred gates of both
# kinds, the cards carried from gates closed on GitHub, and, when it doubles as
# the slice gate of a Small change or Bug, the decision cards and evidence, a
# Bug's leading with its failing test). After the Artisan approves, the PRs to
# main are cut along the pr-boundaries guardrail, each body written with
# upstream `pr`; then the in-run labels come off and the retro is offered.
# The rules: ${CLAUDE_PLUGIN_ROOT}/references/end-gate.md.
#
# Usage, from the Engineering chat once wave.sh status says `done`:
#   end-gate.sh status <run-dir>
#       one word: not-due (tickets remain), due, open, removed (the Artisan
#       removed the end gate at the plan step), approved, ended.
#   end-gate.sh packet <run-dir>
#       the end gate's packet, as it would be opened now.
#   end-gate.sh open <run-dir>
#       opens the review-gate issue "End gate: run <id>" (or finds the one a
#       crashed call opened) and queues an "end-gate" decision. Prints the
#       issue. Refused (6) when not due or removed.
#   end-gate.sh boundary <run-dir>
#       the PR boundary as JSON: {value, level, source: "guardrail"} from the
#       pr-boundaries guardrail (product, then team, then individual), the
#       approved one once recorded, or {value: null, proposed: "slice",
#       source: "none"}.
#   end-gate.sh approve <run-dir> [--boundary slice|plan|ticket] [--by NAME]
#                       [--why W] [--changed]
#       the Artisan approves the end gate: refused (6) while a deferred gate
#       is still open, or with no boundary recorded and none given (job 17 is
#       approved until a guardrail covers it). Decides the end-gate decision
#       (job 13, changed), and a pr-boundary decision (job 17) when the
#       boundary was the Artisan's; closes the issue with the decisions.
#   end-gate.sh prs <run-dir> [--json]
#       the PRs to cut, stacked in merge order: number, branch, base, tickets.
#   end-gate.sh cut <run-dir> <n> --body-file F [--title T]
#       builds branch pr/<run-id>/<n> (the integration branch's merge commit
#       where the group's tickets end, or the group cherry-picked onto the
#       previous PR when its merges are not consecutive), pushes it when the
#       repo has an origin, and opens the PR with the body upstream `pr`
#       wrote. Prints the PR's URL; again, the same URL. PR n-1 first (6).
#   end-gate.sh finish <run-dir>
#       once every PR is cut: removes the in-run label from every ticket in
#       scope, records the run's end and prints the retro offer.
#
# Environment: ARTISAN_HOME, ARTISAN_TEAM_CACHE (as guardrails.sh);
# ARTISAN_MAIN_BRANCH, the branch PRs go to (default the main checkout's).
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 6 refused.
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3 and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "end-gate.sh: $*"; }
refuse() { state_die 6 "end-gate.sh: $*"; }

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
TEAM_CACHE=${ARTISAN_TEAM_CACHE:-$CFG/artisan-agent-team}
PACKET() { python3 -I "$SCRIPT_DIR/lib/packet.py" "$@"; }

# ------------------------------------------------------------------ status

placed() { [ "$(get '[(.plan.gates // [])[] | select(.kind? == "end")] | length')" -gt 0 ]; }
end_def() { get -c '[(.plan.gates // [])[] | select(.kind? == "end")] | first // {}'; }

all_done() {
  [ "$(get "$STATE_JQ_DEFS"' . as $s | [.plan.scope[] | tostring
        | select(($s.tickets[.].status // "queued") as $st
                 | ($st == "merged" or $st == "closed" or (out_of_run | index($st))) | not)] | length')" -eq 0 ]
}

status_word() {
  local st
  st=$(get '.end_gate.status // ""')
  case "$st" in ended|approved|open) echo "$st"; return ;; esac
  if ! all_done; then echo not-due
  elif ! placed; then echo removed
  else echo due; fi
}

cmd_status() { [ $# -eq 1 ] || usage; open_run "$1"; status_word; }

# ---------------------------------------------------------------- boundary

# A pr-boundaries line as setup records it: - `pr-boundaries`: one PR per <x>
boundary_in() { grep -E '^- `pr-boundaries`: one PR per (slice|plan|ticket)' | head -1 | sed -E 's/.*one PR per (slice|plan|ticket).*/\1/' || true; }

team_repo() {
  local f="$MAIN/.artisan-agent/config.yml"
  [ -f "$f" ] || return 0
  "$SCRIPT_DIR/config.sh" get team_guardrails_repo --file "$f" 2>/dev/null | jq -r '. // empty' 2>/dev/null || true
}

guardrail_boundary() { # -> {value, level, source} or nothing
  local v repo
  v=$(git -C "$MAIN" show HEAD:CODING_STANDARDS.md 2>/dev/null | boundary_in)
  if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "product", source: "guardrail"}'; return; fi
  repo=$(team_repo)
  if [ -n "$repo" ] && [ -f "$TEAM_CACHE/$(printf %s "$repo" | tr / _)/CODING_STANDARDS.md" ]; then
    v=$(boundary_in <"$TEAM_CACHE/$(printf %s "$repo" | tr / _)/CODING_STANDARDS.md")
    if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "team", source: "guardrail"}'; return; fi
  fi
  if [ -f "$HOME_DIR/CODING_STANDARDS.md" ]; then
    v=$(boundary_in <"$HOME_DIR/CODING_STANDARDS.md")
    if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "individual", source: "guardrail"}'; return; fi
  fi
}

current_boundary() {
  local b
  b=$(get -c '.end_gate.boundary // empty')
  [ -n "$b" ] || b=$(guardrail_boundary)
  [ -n "$b" ] || b='{"value":null,"proposed":"slice","source":"none"}'
  printf '%s\n' "$b"
}

cmd_boundary() { [ $# -eq 1 ] || usage; open_run "$1"; current_boundary; }

# --------------------------------------------------------------------- PRs

main_branch() {
  [ -z "${ARTISAN_MAIN_BRANCH:-}" ] || { printf '%s\n' "$ARTISAN_MAIN_BRANCH"; return; }
  git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo main
}

# The PRs for a boundary, stacked in merge order: each group of merged tickets
# (by ticket, slice or plan; a rework ticket goes with what it reworks) ends
# at its last merge; groups are ordered by that merge.
pr_plan() { # boundary-value
  get -c --arg b "$1" --arg run "$RUN_ID" --arg main "$(main_branch)" '
    . as $s
    | ((.integration.merges // []) | map(.ticket | tostring)) as $m0
    | (if $m0 == [] then [.plan.scope[] | tostring | select($s.tickets[.].merge_commit? != null)] else $m0 end) as $m1
    | [$m1 | to_entries[] | .value as $v | select(.key as $k | $m1[$k + 1:] | index($v) | not) | $v
       | select($s.tickets[.].status? == "merged")] as $order
    | def key($t): ($s.plan.tickets[$t] // {}) as $p | ($s.plan.tickets[$p.rework_of // ""] // {}) as $o
        | if $b == "ticket" then $t
          elif $b == "slice" then ($p.slice // $o.slice // "#\($t)") | tostring
          else ($p.plan // $o.plan // "run") | tostring end;
    def commit($t): ([($s.integration.merges // [])[] | select((.ticket | tostring) == $t) | .commit] | last)
        // $s.tickets[$t].merge_commit;
    [$order[] | key(.)] as $keys
    | [$keys | unique[] as $k | {key: $k, tickets: [$order[] | select(key(.) == $k)],
        last: ([$keys | to_entries[] | select(.value == $k) | .key] | max)}]
    | sort_by(.last)
    | ([.[].tickets[]] == $order) as $consecutive
    | to_entries | map(.key as $i | .value
        | {n: ($i + 1), key, tickets, consecutive: $consecutive,
           branch: "pr/\($run)/\($i + 1)", base: (if $i == 0 then $main else "pr/\($run)/\($i)" end),
           commits: [.tickets[] | commit(.)]})'
}

need_prs_allowed() {
  case "$(status_word)" in
    approved) ;;
    ended) ;;
    *) refuse "the PRs to main wait for the end gate's approval (end-gate.sh approve)" ;;
  esac
}

cmd_prs() {
  [ $# -ge 1 ] || usage
  open_run "$1"
  need_prs_allowed
  local plan
  plan=$(pr_plan "$(get -r '.end_gate.boundary.value')")
  if [ "${2:-}" = --json ]; then printf '%s\n' "$plan"; return; fi
  echo "| PR | Branch | Into | Tickets | Cut |"
  echo "|---|---|---|---|---|"
  jq -r --slurpfile s "$FILE" '.[] | . as $p
    | "| \(.n) | `\(.branch)` | `\(.base)` | \(.tickets | map("#" + . + (($s[0].plan.tickets[.].title // null) | if . then " (\(.))" else "" end)) | join(", ")) | \(($s[0].end_gate.prs // []) | map(select(.n == $p.n)) | first | .url // "not yet") |"' <<<"$plan"
}

git_id() { { git -C "$MAIN" config user.name && git -C "$MAIN" config user.email; } >/dev/null 2>&1 \
  || printf -- '-c user.name=Artisan-Agent -c user.email=artisan-agent@localhost'; }

build_branch() { # pr-json: points pr/<run>/<n> at the group's work
  local pr="$1" branch base tmp c ident
  branch=$(jq -r .branch <<<"$pr")
  if [ "$(jq -r .consecutive <<<"$pr")" = true ]; then
    git -C "$MAIN" branch -f "$branch" "$(jq -r '.commits | last' <<<"$pr")" >/dev/null || die "could not create $branch"
    return
  fi
  if [ "$(jq -r .n <<<"$pr")" = 1 ]; then base=$(get -r '.integration.base // empty'); else base=$(jq -r .base <<<"$pr"); fi
  [ -n "$base" ] || die "no integration base recorded for run $RUN_ID"
  tmp="$WT_ROOT/$RUN_ID-pr-$(jq -r .n <<<"$pr")"
  rm -rf "$tmp"; git -C "$MAIN" worktree prune
  git -C "$MAIN" worktree add -q --detach "$tmp" "$base" || die "could not make a worktree for $branch"
  ident=$(git_id)
  for c in $(jq -r '.commits[]' <<<"$pr"); do
    # shellcheck disable=SC2086
    if ! git -C "$tmp" $ident cherry-pick -m 1 "$c" >/dev/null 2>&1; then
      git -C "$tmp" cherry-pick --abort >/dev/null 2>&1 || true
      git -C "$MAIN" worktree remove --force "$tmp"
      refuse "$branch: merge $c does not apply on its own; its merges are not consecutive on the integration branch. Choose another boundary, or cut this PR by hand"
    fi
  done
  git -C "$MAIN" branch -f "$branch" "$(git -C "$tmp" rev-parse HEAD)" >/dev/null
  git -C "$MAIN" worktree remove --force "$tmp"
}

cmd_cut() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local n="$2" body= title= plan pr url branch base repo
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) [ $# -ge 2 ] || usage; body=$2; shift 2 ;;
      --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$body" ] || usage
  need_prs_allowed
  url=$(get -r --argjson n "$n" '(.end_gate.prs // [])[] | select(.n == $n) | .url')
  if [ -n "$url" ]; then echo "$url"; return 0; fi
  [ -f "$body" ] || die "no body file at $body"
  plan=$(pr_plan "$(get -r '.end_gate.boundary.value')")
  pr=$(jq -c --argjson n "$n" '.[] | select(.n == $n)' <<<"$plan")
  [ -n "$pr" ] || refuse "there is no PR $n (end-gate.sh prs)"
  if [ "$n" -gt 1 ]; then
    [ -n "$(get -r --argjson p "$((n - 1))" '(.end_gate.prs // [])[] | select(.n == $p) | .url')" ] \
      || refuse "PR $n is stacked on PR $((n - 1)): cut that first"
  fi
  branch=$(jq -r .branch <<<"$pr"); base=$(jq -r .base <<<"$pr"); repo=$(get -r .repo)
  build_branch "$pr"
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    git -C "$MAIN" push -q -f origin "$branch:refs/heads/$branch" >&2 || die "could not push $branch"
  fi
  [ -n "$title" ] || title="Run $RUN_ID, PR $n of $(jq length <<<"$plan"): $(jq -r '.tickets | map("#" + .) | join(", ")' <<<"$pr")"
  url=$(gh pr create -R "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body") \
    || die "could not open the PR for $branch (the branch is kept)"
  url=$(printf '%s\n' "$url" | tail -1)
  apply '.end_gate.prs = ((.end_gate.prs // []) + [$pr + {url: $url, at: $now}])
    | event({event: "pr-cut", n: $pr.n, branch: $pr.branch, base: $pr.base, tickets: $pr.tickets, url: $url}; $now)' \
    --argjson pr "$(jq -c '{n, branch, base, tickets}' <<<"$pr")" --arg url "$url"
  echo "$url"
}

# ------------------------------------------------------------------ packet

tref() { get -r --arg t "$1" '"#\($t)" + ((.plan.tickets[$t].title // null) | if . then " (\(.))" else "" end)'; }

packet() {
  local def b gview title
  def=$(end_def)
  title="End gate: run $RUN_ID"
  echo "# $title"
  echo
  if [ "$(jq -r '.bug // false' <<<"$def")" = true ] || [ "$(get -r '.plan.route // ""')" = bug ]; then
    echo "## The failing test"
    echo
    echo "The core of a bug's verification: the test that failed before the fix and passes after it."
    echo
    echo "| Ticket | Failing test | Verdict | Evidence |"
    echo "|---|---|---|---|"
    get -r '. as $s | .plan.scope[] | tostring as $t | ($s.plan.tickets[$t].failing_test // null) as $ft
      | ($s.tickets[$t].evidence.acceptance // []) as $acc
      | ([$acc[] | select(.met == true and ((.evidence.tests // []) | length) > 0
            and ($ft == null or any(.evidence.tests[]; contains($ft))))] | length > 0) as $proven
      | "| #\($t)" + (($s.plan.tickets[$t].title // null) | if . then " (\(.))" else "" end)
        + " | " + (if $ft then "`\($ft)`" else "**none named**" end)
        + " | " + (if $proven then "proven" else "**needs you**" end)
        + " | " + ([$acc[] | .evidence.tests // [] | .[]] | unique | join("; ") | if . == "" then "-" else gsub("\\|"; "/") end) + " |"'
    echo
  fi
  if [ "$(jq -r '.doubles_as_slice // false' <<<"$def")" = true ]; then
    # It doubles as the slice gate: the slice packet over every merged ticket,
    # without its title and its overall action (the end gate's follows).
    gview=$(jq -n --slurpfile s "$FILE" --arg title "$title" '
      {gate: {kind: "end", slice: "the run", title: $title, role: "Engineering (QA)",
              tickets: [$s[0].plan.scope[] | tostring | select($s[0].tickets[.].status? == "merged")],
              dependents: []},
       state: $s[0], guardrails: "", provisional: ""}')
    gview=$(jq --argjson c "$(PACKET cards <<<"$gview")" '.gate.cards = $c' <<<"$gview")
    PACKET body <<<"$gview" | sed '1,2d' | sed '/^## Overall action/,$d'
  else
    echo "| Gate | Role needed | Tickets | PRs to |"
    echo "|---|---|---|---|"
    echo "| end | Engineering (QA) | $(get -r '. as $s | [.plan.scope[] | tostring | "#\(.)" + (($s.plan.tickets[.].title // null) | if . then " (\(.))" else "" end)] | join(", ")') | \`$(main_branch)\` |"
    echo
    echo "| Ticket | Outcome | Merge |"
    echo "|---|---|---|"
    get -r '. as $s | .plan.scope[] | tostring as $t
      | "| #\($t)" + (($s.plan.tickets[$t].title // null) | if . then " (\(.))" else "" end)
        + " | \($s.tickets[$t].status // "queued") | " + (($s.tickets[$t].merge_commit // null) | if . then "`\(.[0:7])`" else "-" end) + " |"'
    echo
  fi
  echo "## Deferred gates"
  echo
  echo "Still waiting here. Answer each before approving: a review gate with \`gate.sh approve\` or \`gate.sh change\`, an exception gate with \`gate-action.sh\` (references/gate-actions.md)."
  echo
  "$SCRIPT_DIR/gate-action.sh" deferred "$RUN_DIR"
  echo
  echo "## Cards carried from gates closed on GitHub"
  echo
  "$SCRIPT_DIR/gate.sh" carried "$RUN_DIR"
  echo
  echo "## PRs to main"
  echo
  b=$(current_boundary)
  case "$(jq -r .source <<<"$b")" in
    guardrail) echo "One PR per **$(jq -r .value <<<"$b")**, from the $(jq -r .level <<<"$b") \`pr-boundaries\` guardrail. Each PR's body is written with upstream \`pr\`." ;;
    approved) echo "One PR per **$(jq -r .value <<<"$b")**, approved by $(jq -r .by <<<"$b")." ;;
    *) echo "No PR boundary is recorded: proposed **one PR per slice** (each PR reviewable end to end). Approve it, or name per plan or per ticket; until a \`pr-boundaries\` guardrail covers it, the boundary is yours to approve (job 17)." ;;
  esac
  echo
  echo "## Overall action"
  echo
  echo "- **approve**: the PRs to \`$(main_branch)\` are cut, the \`in-run\` labels come off and the retro is offered."
  echo "- **not yet**: say what is wrong. The end gate stays open and nothing is cut; a fix joins the run through its own plan step."
}

cmd_packet() { [ $# -eq 1 ] || usage; open_run "$1"; packet; }

cmd_open() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local num repo title url dir
  num=$(get -r '.end_gate.issue // empty')
  if [ -n "$num" ]; then echo "$num"; return 0; fi
  case "$(status_word)" in
    due) ;;
    removed) refuse "the Artisan removed the end gate at the plan step: approve the PR boundary with end-gate.sh approve" ;;
    *) refuse "the end gate is not due: tickets in scope are still to merge" ;;
  esac
  repo=$(get -r .repo); title="End gate: run $RUN_ID"
  dir="$RUN_DIR/gates"; mkdir -p "$dir"
  packet >"$dir/end.md"
  num=$(gh issue list -R "$repo" --state open --label review-gate --json number,title \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  if [ -z "$num" ]; then
    url=$(gh issue create -R "$repo" --title "$title" --label review-gate --body "$(cat "$dir/end.md")") \
      || die "could not open the end gate's issue"
    num=${url##*/}
  fi
  apply '
    if .end_gate.issue? != null then .
    else .end_gate = ((.end_gate // {}) + {status: "open", issue: $num, title: $title, opened_at: $now})
      | .decisions += [{id: ((.decisions | length) + 1), kind: "end-gate", gate: "end", issue: $num,
          question: "\($title) is #\($num): approve to cut the PRs to main, end the run and offer the retro.",
          status: "waiting", at: $now}]
      | event({event: "gate-opened", gate: "end", kind: "end", issue: $num}; $now) end' \
    --argjson num "$num" --arg title "$title"
  echo "$num"
}

open_deferred() {
  get -r '[(.review_gates // [])[], (.exception_gates // [])[] | select(.status == "deferred") | "\(.title) #\(.issue)"] | join("; ")'
}

cmd_approve() {
  [ $# -ge 1 ] || usage
  open_run "$1"
  shift
  local by=Artisan why= set= changed=false st b issue src
  while [ $# -gt 0 ]; do
    case "$1" in
      --boundary) [ $# -ge 2 ] || usage; set=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; why=$2; shift 2 ;;
      --changed) changed=true; shift ;;
      *) usage ;;
    esac
  done
  case "$set" in ""|slice|plan|ticket) ;; *) usage ;; esac
  st=$(status_word)
  [ "$st" = not-due ] || [ -z "$(open_deferred)" ] \
    || refuse "deferred gates are still waiting here; answer each first: $(open_deferred)"
  case "$st" in
    open|removed) ;;
    due) refuse "open the end gate first (end-gate.sh open)" ;;
    approved|ended) refuse "the end gate is already $st" ;;
    *) refuse "the end gate is not due: tickets in scope are still to merge" ;;
  esac
  b=$(guardrail_boundary)
  if [ -n "$set" ]; then
    src=approved
    b=$(jq -nc --arg v "$set" --arg by "$by" --argjson g "${b:-null}" \
      '{value: $v, source: "approved", by: $by, proposed: ($g.value // "slice")}')
  elif [ -n "$b" ]; then
    src=guardrail
  else
    refuse "no pr-boundaries guardrail is recorded: the boundary is the Artisan's to approve. Proposed: one PR per slice (--boundary slice|plan|ticket)"
  fi
  issue=$(get -r '.end_gate.issue // empty')
  apply '
    .end_gate = ((.end_gate // {}) + {status: "approved", approved_at: $now, by: $by, boundary: ($b | del(.proposed))})
    | decide((.decisions | map(select(.kind == "end-gate" and .status == "waiting")) | first | .id // -1);
        {choice: "approve", by: $by, job: 13, changed: $changed} + (if $why == "" then {} else {why: $why} end); $now)
    | (if $src == "approved" then
         .decisions += [{id: ((.decisions | length) + 1), kind: "pr-boundary", gate: "end",
           question: "How are the PRs to main cut?", status: "decided", at: $now, decided_at: $now,
           choice: $b.value, by: $by, job: 17, changed: ($b.value != $b.proposed)}
           + (if $why == "" then {} else {why: $why} end)]
       else . end)
    | event({event: "end-gate-approved", by: $by, boundary: $b.value, source: $src, changed: $changed}; $now)' \
    --arg by "$by" --arg why "$why" --argjson changed "$changed" --argjson b "$b" --arg src "$src"
  if [ -n "$issue" ]; then
    gh issue close "$issue" -R "$(get -r .repo)" --comment "Approved by $by. PRs to main: one per $(jq -r .value <<<"$b") ($src$([ "$src" = guardrail ] && printf ', %s level' "$(jq -r .level <<<"$b")")).$([ -n "$why" ] && printf ' Why: %s' "$why")" >/dev/null \
      || die "approved in the state file, but could not close #$issue"
  fi
  echo "approved: PRs one per $(jq -r .value <<<"$b"); next: end-gate.sh prs, then write each body with upstream pr and end-gate.sh cut"
}

cmd_finish() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local want have repo t bad=0 done_list=
  [ "$(status_word)" = approved ] || refuse "the run ends after the end gate's approval and its PRs"
  want=$(pr_plan "$(get -r '.end_gate.boundary.value')" | jq length)
  have=$(get '(.end_gate.prs // []) | length')
  [ "$have" -ge "$want" ] || refuse "$have of $want PRs cut; cut the rest first (end-gate.sh prs)"
  repo=$(get -r .repo)
  for t in $(get -r '.plan.scope[]'); do
    if gh issue edit "$t" -R "$repo" --remove-label in-run >/dev/null 2>&1; then done_list="$done_list #$t"
    else echo "end-gate.sh: could not remove in-run from #$t" >&2; bad=1; fi
  done
  [ "$bad" -eq 0 ] || die "some in-run labels are still on; run end-gate.sh finish again"
  apply '.end_gate.status = "ended" | .end_gate.ended_at = $now
    | event({event: "run-ended", prs: ((.end_gate.prs // []) | map(.url))}; $now)'
  echo "Run $RUN_ID ended: $have PR(s) to $(main_branch); in-run removed from$done_list."
  echo "Next: offer the retro, /artisan-agent:retro."
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  status) cmd_status "$@" ;;
  packet) cmd_packet "$@" ;;
  open) cmd_open "$@" ;;
  boundary) cmd_boundary "$@" ;;
  approve) cmd_approve "$@" ;;
  prs) cmd_prs "$@" ;;
  cut) cmd_cut "$@" ;;
  finish) cmd_finish "$@" ;;
  *) usage ;;
esac
