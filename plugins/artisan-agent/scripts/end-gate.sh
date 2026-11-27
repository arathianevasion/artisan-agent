#!/usr/bin/env bash
# The end gate and the PRs to main (#71): once every ticket in scope is done,
# a review-gate issue holds the end gate's packet (the deferred gates of both
# kinds, the open decisions raised at gates and not yet ruled on, the cards
# carried from gates closed on GitHub, and, when it doubles as
# the slice gate of a Small change or Bug, the decision cards and evidence, a
# Bug's leading with its failing test). After the Artisan approves, the PRs to
# main are cut along the pr-boundaries guardrail, each body written with
# upstream `pr`; then the in-run labels come off and the retro is offered.
# The rules: ${CLAUDE_PLUGIN_ROOT}/references/end-gate.md.
#
# Usage, from the Run chat once wave.sh status says `done`:
#   end-gate.sh status <run-dir>
#       one word: not-due (tickets remain; Human checks don't count),
#       due, open, removed (the Artisan
#       removed the end gate at the plan step), approved, ended.
#   end-gate.sh packet <run-dir>
#       the end gate's packet, as it would be opened now.
#   end-gate.sh open <run-dir>
#       opens the review-gate issue "End gate: run <id>" (or finds the one a
#       crashed call opened) and queues an "end-gate" decision. Prints the
#       issue. Refused (6) when not due or removed. First deletes any
#       ci/<run-id>-* branch a merge gate on CI left on origin (merge-gate.sh sweep).
#   end-gate.sh boundary <run-dir>
#       the PR boundary as JSON: {value, level, source: "guardrail"} from the
#       pr-boundaries guardrail (product, then team, then individual), the
#       approved one once recorded, or {value: null, proposed: "slice",
#       source: "none"}.
#   end-gate.sh approve <run-dir> [--boundary slice|plan|ticket|run] [--by NAME]
#                       [--why W] [--changed]
#       the Artisan approves the end gate: refused (6) while a deferred gate
#       is still open or an open decision raised at a gate (gate-action.sh
#       triage) is not ruled on (it reads the rulings with questions.sh sync
#       first), refused (22) while a Human check is open and not
#       deferred, or (6) with no boundary recorded and none given (job 17 is
#       approved until a guardrail covers it). Decides the end-gate decision
#       (job 13, changed), and a pr-boundary decision (job 17) when the
#       boundary was the Artisan's; closes the issue with the decisions.
#   end-gate.sh defer-check <run-dir> <ticket> --why W [--by NAME] [--return CONDITION]
#       a Human check deferred past the run (references/human-checks.md):
#       it stays open, labelled deferred with a return condition, and no
#       longer holds approval; event human-check-deferred. Refused (6)
#       before the end gate is due.
#   end-gate.sh prs <run-dir> [--json]
#       the PRs to cut, stacked in merge order: number, branch, base, tickets.
#       One PR per run is the integration branch into the default branch. A
#       group whose tickets are all on the default branch, and no cut PR
#       carries, is left out; the table names it with the reason (#363).
#   end-gate.sh cut <run-dir> <n> --body-file F [--title T]
#       builds branch pr/<run-id>/<n> (the integration branch's merge commit
#       where the group's tickets end, or the group cherry-picked onto the
#       previous PR when its merges are not consecutive), pushes it when the
#       repo has an origin, and opens the PR with the body upstream `pr`
#       wrote. Prints the PR's URL; again, the same URL. PR n-1 first (6).
#       A worktree_setup that fails in the PR's worktree (#182) records an
#       end-gate-setup-failed event and a waiting end-gate-setup decision
#       (command, exit status, stderr tail), cuts nothing and refuses (6);
#       cut refuses that PR (6) until the Artisan answers with
#       state.sh decide <run-dir> <id> retry|bypass (bypass: cut it without
#       the setup).
#   end-gate.sh finish <run-dir>
#       once every PR is cut, or once the integration branch's tip is already
#       on the default branch because the Artisan merged it as one PR (#364:
#       records that PR, found with gh pr list, as end_gate.merged_outside;
#       with the tip off main it refuses and names the merges main lacks): retires each design whose feature the run ships
#       and whose PR has merged into main, with every PR under it in the stack
#       (a design whose PR is cut but not merged is listed as waiting; run
#       finish again after the merge, even once the run has ended)
#       (design.sh retire: a ticket in scope whose body has a "Design: #<n>"
#       line names design ticket <n>; the design's ticket closes with the URL
#       of the last PR carrying one of its tickets; a design no ticket names is
#       left alone), removes the in-run label from every ticket in
#       scope, records the run's end and prints the merge gate costs
#       (retro.py gate-costs) and the retro offer.
#
# An urgent ticket (lever.sh urgent, references/run-levers.md) ships through
# its own end gate and PR, scoped to that one ticket and based on main, with
# this same packet, PR body and cut. From the Run chat, once the
# ticket has returned and been verified:
#   end-gate.sh urgent-packet <run-dir> <ticket>
#       the packet for that ticket alone, as it would be opened now.
#   end-gate.sh urgent-open <run-dir> <ticket>
#       opens "End gate: urgent #<t> (run <id>)" and queues its decision. 6
#       unless the ticket has returned with a passing verdict at its tip.
#   end-gate.sh urgent-approve <run-dir> <ticket> [--by NAME] [--why W]
#   end-gate.sh urgent-cut <run-dir> <ticket> --body-file F [--title T]
#       builds pr/<run-id>/urgent-<t> at the ticket's tip (never through the
#       integration branch), pushes it when there is an origin, opens the PR
#       to main with the body upstream `pr` wrote. Prints the URL; again, the same.
#   end-gate.sh urgent-finish <run-dir> <ticket>
#       once the Artisan has merged that PR: merges main into the integration
#       branch in its worktree, runs the plan's full suite there at background
#       priority (lib/priority-lib.sh, #248; red undoes the merge, queues a
#       decision, exit 7), marks the ticket merged and
#       takes the in-run label off. 6 while the PR is not merged.
#
# Environment: ARTISAN_HOME, ARTISAN_TEAM_CACHE (as guardrails.sh);
# ARTISAN_MAIN_BRANCH, the branch PRs go to (default the main checkout's).
#
# Exit status: 0 ok, 1 error, 2 usage, 3 the state lock is held, 6 refused,
# 22 a Human check is still open (approve).
#
# Portable to bash 3.2 (macOS) and Linux. Needs git, jq, python3 and gh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
# shellcheck source=lib/wave-lib.sh
. "$SCRIPT_DIR/lib/wave-lib.sh"
# shellcheck source=lib/priority-lib.sh
. "$SCRIPT_DIR/lib/priority-lib.sh"
state_require_jq

usage() { state_usage "$0"; }
die() { state_die 1 "end-gate.sh: $*"; }
refuse() { state_die 6 "end-gate.sh: $*"; }

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
TEAM_CACHE=${ARTISAN_TEAM_CACHE:-$CFG/artisan-agent-team}
URGENT=
PACKET() { python3 -I "$SCRIPT_DIR/lib/packet.py" "$@"; }

# ------------------------------------------------------------------ status

placed() { [ "$(get '[(.plan.gates // [])[] | select(.kind? == "end")] | length')" -gt 0 ]; }
end_def() { get -c '[(.plan.gates // [])[] | select(.kind? == "end")] | first // {}'; }

# Every ticket done; a Human check is not work the run waits on (the end
# gate settles it: approve refuses while one is open).
all_done() {
  [ "$(get "$STATE_JQ_DEFS"' . as $s | [.plan.scope[] | tostring
        | select(. as $t | $s | is_human_check($t) | not)
        | select(($s.tickets[.].status // "queued") as $st
                 | ($st == "merged" or $st == "closed" or (out_of_run | index($st))) | not)] | length')" -eq 0 ]
}

status_word() {
  local st=
  st=$(get '.end_gate.status // ""')
  case "$st" in ended|approved|open) echo "$st"; return ;; esac
  if ! all_done; then echo not-due
  elif ! placed; then echo removed
  else echo due; fi
}

cmd_status() { [ $# -eq 1 ] || usage; open_run "$1"; status_word; }

# ---------------------------------------------------------------- boundary

# A pr-boundaries line as setup records it: - `pr-boundaries`: one PR per <x>
boundary_in() { grep -E '^- `pr-boundaries`: one PR per (slice|plan|ticket|run)' | head -1 | sed -E 's/.*one PR per (slice|plan|ticket|run).*/\1/' || true; }

team_repo() {
  local f="$MAIN/.artisan-agent/config.yml"
  [ -f "$f" ] || return 0
  "$SCRIPT_DIR/config.sh" get team_guardrails_repo --file "$f" 2>/dev/null | jq -r '. // empty' 2>/dev/null || true
}

guardrail_boundary() { # -> {value, level, source} or nothing
  local v= repo= tf=
  v=$(git -C "$MAIN" show HEAD:CODING_STANDARDS.md 2>/dev/null | boundary_in)
  if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "product", source: "guardrail"}'; return; fi
  repo=$(team_repo)
  tf="$TEAM_CACHE/$(printf %s "$repo" | tr / _)/CODING_STANDARDS.md"
  if [ -n "$repo" ] && [ -f "$tf" ]; then
    v=$(boundary_in <"$tf")
    if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "team", source: "guardrail"}'; return; fi
  fi
  if [ -f "$HOME_DIR/CODING_STANDARDS.md" ]; then
    v=$(boundary_in <"$HOME_DIR/CODING_STANDARDS.md")
    if [ -n "$v" ]; then jq -nc --arg v "$v" '{value: $v, level: "individual", source: "guardrail"}'; return; fi
  fi
}

current_boundary() {
  local b=
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

# main_ref: the ref the default branch is read from: origin's, fetched now,
# when the repo has an origin and the fetch works, else the local branch.
main_ref() {
  local b=
  b=$(main_branch)
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1 \
    && git -C "$MAIN" fetch -q origin "$b" >/dev/null 2>&1; then
    b="origin/$b"
  fi
  printf '%s\n' "$b"
}

# on_main: the merged tickets whose merge commit is already on the default
# branch, as a JSON array of strings. Once a PR is cut the tickets left out
# then are recorded (end_gate.left_out) and read instead, so the PRs keep
# their numbers whatever reaches main afterwards.
on_main() {
  local ref= t= c= out=
  if [ "$(get '.end_gate.left_out != null')" = true ]; then get -c '.end_gate.left_out'; return; fi
  ref=$(main_ref)
  while read -r t c; do
    [ -n "$c" ] || continue
    git -C "$MAIN" merge-base --is-ancestor "$c" "$ref" 2>/dev/null && out="$out${out:+,}\"$t\""
  done <<EOF2
$(get -r '. as $s | [((.integration.merges // [])[] | [(.ticket | tostring), .commit]),
    (.plan.scope[] | tostring | select($s.tickets[.].merge_commit? != null) | [., $s.tickets[.].merge_commit])]
  | .[] | join(" ")')
EOF2
  printf '[%s]\n' "$out"
}

# The PRs for a boundary, stacked in merge order: each group of merged tickets
# (by ticket, slice, plan or the whole run; a rework ticket goes with what it
# reworks) ends at its last merge; groups are ordered by that merge. A group
# whose every ticket is already on the default branch, and no cut PR carries,
# is left out (#363): {prs, left_out}. One PR per run is the integration
# branch itself, into the default branch.
pr_groups() { # boundary-value
  get -c --arg b "$1" --arg run "$RUN_ID" --arg main "$(main_branch)" --arg ib "$(integration_branch)" \
    --argjson onmain "$(on_main)" '
    . as $s
    | ((.integration.merges // []) | map(.ticket | tostring)) as $m0
    | (if $m0 == [] then [.plan.scope[] | tostring | select($s.tickets[.].merge_commit? != null and ($s.tickets[.].urgent // false | not))] else $m0 end) as $m1
    | [$m1 | to_entries[] | .value as $v | select(.key as $k | $m1[$k + 1:] | index($v) | not) | $v
       | select($s.tickets[.].status? == "merged")] as $order
    | ([(.end_gate.prs // [])[].tickets[]] | map(tostring)) as $cut
    | def key($t): ($s.plan.tickets[$t] // {}) as $p | ($s.plan.tickets[$p.rework_of // ""] // {}) as $o
        | if $b == "ticket" then $t
          elif $b == "run" then "run"
          elif $b == "slice" then ($p.slice // $o.slice // "#\($t)") | tostring
          else ($p.plan // $o.plan // "run") | tostring end;
    def commit($t): ([($s.integration.merges // [])[] | select((.ticket | tostring) == $t) | .commit] | last)
        // $s.tickets[$t].merge_commit;
    [$order[] | key(.)] as $keys
    | [$keys | unique[] as $k | {key: $k, tickets: [$order[] | select(key(.) == $k)],
        last: ([$keys | to_entries[] | select(.value == $k) | .key] | max)}]
    | sort_by(.last)
    | ([.[].tickets[]] == $order) as $consecutive
    | map(. + {left_out: (all(.tickets[]; . as $t | ($onmain | index($t)) != null and ($cut | index($t)) == null))}) as $all
    | {left_out: [$all[] | select(.left_out) | {key, tickets, why: "already on \($main)"}],
       prs: ([$all[] | select(.left_out | not)] | to_entries | map(.key as $i | .value
        | {n: ($i + 1), key, tickets, consecutive: $consecutive,
           branch: (if $b == "run" then $ib else "pr/\($run)/\($i + 1)" end),
           base: (if $i == 0 then $main else "pr/\($run)/\($i)" end),
           commits: [.tickets[] | commit(.)]}))}'
}

pr_plan() { pr_groups "$1" | jq -c .prs; } # boundary-value

need_prs_allowed() {
  need_ruled "No PR to main is cut"
  case "$(status_word)" in
    approved) ;;
    ended) ;;
    *) refuse "the PRs to main wait for the end gate's approval (end-gate.sh approve)" ;;
  esac
}

# stack_steps: how to merge stacked PRs (#271). Printed with two or more PRs in
# the plan, nothing for one. A PR deleted with its branch closes the PR stacked
# on it instead of retargeting it, so no merge command carries --delete-branch:
# retarget the next PR to main after each merge, delete branches at the end.
stack_steps() { # plan-json
  local plan="$1"
  [ "$(jq length <<<"$plan")" -gt 1 ] || return 0
  echo
  echo "Merge the stack in this order. Never use \`--delete-branch\`: deleting a PR's branch closes the PR stacked on it instead of retargeting it."
  echo
  jq -r --slurpfile s "$FILE" '. as $plan | length as $len | to_entries[] | .key as $i | .value as $p
    | (($s[0].end_gate.prs // []) | map(select(.n == $p.n)) | first | .url // "<PR \($p.n)>") as $url
    | "\($i + 1). `gh pr merge \($url) --merge`"
      + (if $i + 1 < $len
         then "\n   then `gh pr edit \(($s[0].end_gate.prs // []) | map(select(.n == $plan[$i + 1].n)) | first | .url // "<PR \($plan[$i + 1].n)>") --base main`"
         else "" end)' <<<"$plan"
  echo
  echo "Delete the merged branches (\`$(jq -r 'map(.branch) | join("`, `")' <<<"$plan")\`) only after the whole stack has merged."
}

cmd_prs() {
  [ $# -ge 1 ] || usage
  open_run "$1"
  need_prs_allowed
  local plan= groups=
  groups=$(pr_groups "$(get -r '.end_gate.boundary.value')")
  plan=$(jq -c .prs <<<"$groups")
  if [ "${2:-}" = --json ]; then printf '%s\n' "$plan"; return; fi
  echo "| PR | Branch | Into | Tickets | Cut |"
  echo "|---|---|---|---|---|"
  jq -r --slurpfile s "$FILE" '.[] | . as $p
    | "| \(.n) | `\(.branch)` | `\(.base)` | \(.tickets | map("#" + . + (($s[0].plan.tickets[.].title // null) | if . then " (\(.))" else "" end)) | join(", ")) | \(($s[0].end_gate.prs // []) | map(select(.n == $p.n)) | first | .url // "not yet") |"' <<<"$plan"
  jq -r '.left_out[] | "\nLeft out: \(.tickets | map("#" + .) | join(", ")) (\(.key)): \(.why); no PR is cut for it."' <<<"$groups"
  stack_steps "$plan"
}

git_id() { { git -C "$MAIN" config user.name && git -C "$MAIN" config user.email; } >/dev/null 2>&1 \
  || printf -- '-c user.name=Artisan-Agent -c user.email=artisan-agent@localhost'; }

# setup_failed n branch: the project's worktree_setup failed in PR n's
# worktree (#182). Records an end-gate-setup-failed event and a waiting
# end-gate-setup decision (retry or bypass) naming the command, its exit
# status and its stderr tail, then refuses (6) with one line. No PR is cut.
setup_failed() {
  local n="$1" branch="$2" id="" line="" rc="null"
  state_is_uint "${SETUP_RC:-}" && rc=$SETUP_RC
  # The id is the decision count inside the locked write, as everywhere else.
  apply '((.decisions | length) + 1) as $id
    | .decisions += [{id: $id, kind: "end-gate-setup", gate: "end", pr: $n, branch: $b,
          question: "PR \($n)'"'"'s worktree_setup failed at the end gate: retry once the command is fixed, or bypass the setup for this PR?",
          command: $cmd, exit: $rc, stderr: $tail, detail: $err, options: ["retry", "bypass"],
          status: "waiting", at: $now}]
    | event({event: "end-gate-setup-failed", n: $n, branch: $b, command: $cmd, exit: $rc, stderr: $tail, decision: $id}; $now)' \
    --argjson n "$n" --arg b "$branch" --arg cmd "$SETUP_CMD" --argjson rc "$rc" \
    --arg tail "$SETUP_TAIL" --arg err "$SETUP_ERR"
  id=$(setup_decision "$n" waiting)
  line=$(printf '%s' "$SETUP_ERR" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')
  refuse "PR $n: $line; no PR is cut and decision $id waits: state.sh decide $RUN_DIR $id retry|bypass, then end-gate.sh cut again"
}

# setup_decision n status [choice]: the last end-gate-setup decision for PR n
# with that status (and choice) not yet applied, or nothing.
setup_decision() {
  get --argjson n "$1" --arg st "$2" --arg c "${3:-}" '[.decisions[] | select(.kind == "end-gate-setup" and .pr == $n
    and .status == $st and .applied != true and ($c == "" or .choice == $c))] | last | .id // empty'
}

build_branch() { # pr-json [bypass-setup]: points pr/<run>/<n> at the group's work
  local pr="$1" bypass="${2:-}" branch="" base="" tmp="" c="" ident=""
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
  # The project's worktree_setup (#173), unless the Artisan bypassed it for
  # this PR after it failed (#182).
  if [ -z "$bypass" ] && ! worktree_setup "$tmp"; then
    git -C "$MAIN" worktree remove --force "$tmp" >/dev/null 2>&1 || true
    setup_failed "$(jq -r .n <<<"$pr")" "$branch"
  fi
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
  local n="$2" body= title= plan= groups= pr= url= branch= base= repo= d=""
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
  groups=$(pr_groups "$(get -r '.end_gate.boundary.value')")
  plan=$(jq -c .prs <<<"$groups")
  pr=$(jq -c --argjson n "$n" '.[] | select(.n == $n)' <<<"$plan")
  [ -n "$pr" ] || refuse "there is no PR $n (end-gate.sh prs)"
  if [ "$n" -gt 1 ]; then
    [ -n "$(get -r --argjson p "$((n - 1))" '(.end_gate.prs // [])[] | select(.n == $p) | .url')" ] \
      || refuse "PR $n is stacked on PR $((n - 1)): cut that first"
  fi
  # A failed worktree_setup waits for the Artisan: retry or bypass (#182).
  d=$(setup_decision "$n" waiting)
  [ -z "$d" ] || refuse "PR $n's worktree_setup failed and decision $d waits: state.sh decide $RUN_DIR $d retry|bypass, then end-gate.sh cut again"
  branch=$(jq -r .branch <<<"$pr"); base=$(jq -r .base <<<"$pr"); repo=$(get -r .repo)
  # One PR per run is the integration branch itself: nothing to build.
  [ "$(get -r '.end_gate.boundary.value')" = run ] || build_branch "$pr" "$(setup_decision "$n" decided bypass)"
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    git -C "$MAIN" push -q origin "$branch:refs/heads/$branch" >&2 || die "could not push $branch"
  fi
  [ -n "$title" ] || title="Run $RUN_ID, PR $n of $(jq length <<<"$plan"): $(jq -r '.tickets | map("#" + .) | join(", ")' <<<"$pr")"
  url=$(gh pr create -R "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body") \
    || die "could not open the PR for $branch (the branch is kept)"
  url=$(printf '%s\n' "$url" | tail -1)
  apply '.end_gate.prs = ((.end_gate.prs // []) + [$pr + {url: $url, at: $now}])
    | .end_gate.left_out //= $lo
    | .decisions |= map(if .kind == "end-gate-setup" and .pr == $pr.n and .status == "decided" then .applied = true else . end)
    | event({event: "pr-cut", n: $pr.n, branch: $pr.branch, base: $pr.base, tickets: $pr.tickets, url: $url}; $now)' \
    --argjson pr "$(jq -c '{n, branch, base, tickets}' <<<"$pr")" --arg url "$url" \
    --argjson lo "$(jq -c '[.left_out[].tickets[]]' <<<"$groups")"
  echo "$url"
}

# ------------------------------------------------------------------ packet

packet() {
  local def= b= gview= title=
  def=$(end_def)
  title="End gate: run $RUN_ID"
  [ -z "$URGENT" ] || title="End gate: urgent #$URGENT (run $RUN_ID)"
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
    # The view and its cards grow with the run: both reach jq on stdin (#203).
    gview=$({ printf '%s\n' "$gview"; PACKET cards <<<"$gview"; } | jq -s '.[0].gate.cards = .[1] | .[0]')
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
  if [ -n "$URGENT" ]; then
    # The escalation tests it meets: it gets no risk gate (no dependents wait
    # on it), so its own end gate covers what a risk gate would have.
    jq -n --slurpfile s "$FILE" --arg t "$URGENT" '{gate: {tickets: [$t]}, state: $s[0]}' | PACKET risk
    echo "## PR to main"
    echo
    echo "One PR for #$URGENT alone, based on \`$(main_branch)\`; the run's other tickets are not in it. Its body is written with upstream \`pr\`. Once it is merged, \`end-gate.sh urgent-finish\` merges \`$(main_branch)\` into the integration branch and runs the full suite."
    echo
    echo "## Overall action"
    echo
    echo "- **approve**: the PR to \`$(main_branch)\` is cut."
    echo "- **not yet**: say what is wrong. The gate stays open and nothing is cut."
    echo "- **a bug in #$URGENT**: say so with either answer; it is recorded as a bug found at this gate (\`gate.sh bug <run-dir> $URGENT --gate urgent-$URGENT\`), tighten evidence for the ticket's areas at the retro."
    return 0
  fi
  [ -z "$(unruled)" ] || sync_unruled >/dev/null
  # The risk gates folded into the end gate (#241): their slice gate had
  # opened when they were raised; and the gates a small clean run carried
  # here (#407). Nothing when there are none.
  jq -n --slurpfile s "$FILE" '{gate: {id: "end", kind: "end", tickets: []}, state: $s[0]}' | PACKET folded
  echo "## Deferred gates"
  echo
  echo "Still waiting here. Answer each before approving: a review gate with \`gate.sh approve\` or \`gate.sh change\`, an exception gate with \`gate-action.sh\` (references/gate-actions.md)."
  echo
  "$SCRIPT_DIR/gate-action.sh" deferred "$RUN_DIR"
  echo
  open_decisions_section
  echo
  human_checks_section
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
    *) echo "No PR boundary is recorded: proposed **one PR per slice** (each PR reviewable end to end). Approve it, or name per plan, per ticket or one per run; until a \`pr-boundaries\` guardrail covers it, the boundary is yours to approve (job 17)." ;;
  esac
  echo
  echo "## Overall action"
  echo
  echo "- **approve**: the PRs to \`$(main_branch)\` are cut, the \`in-run\` labels come off and the retro is offered."
  echo "- **not yet**: say what is wrong. The end gate stays open and nothing is cut; a fix joins the run through its own plan step."
  echo "- **a bug in #<ticket>**: say so with either answer; it is recorded as a bug found at this gate (\`gate.sh bug <run-dir> <ticket> --gate end\`), tighten evidence for the ticket's areas at the retro."
}

cmd_packet() { [ $# -eq 1 ] || usage; open_run "$1"; packet; }

# The open decisions raised at a gate (gate-action.sh triage, #232) that the
# Decision chat hasn't ruled on: no ruling read by questions.sh sync yet. Any
# ruling counts, Defer and Discard too: the Decision chat has decided what
# happens to it. Each is {in: the ticket it is in} + its question record.
UNRULED_JQ='[.tickets | to_entries[] | .key as $t | (.value.questions // [])[]
  | select(.raised_at == "gate" and .ruling == null) | {in: $t} + .]'
unruled() { get -r "$UNRULED_JQ"' | map("#\(.ticket)") | join(", ")'; }

# Read the rulings first, so one given on the tracker counts at once. A
# tracker that can't be read leaves the state as it was: the hold stands.
sync_unruled() {
  [ -n "$(unruled)" ] || return 0
  "$SCRIPT_DIR/questions.sh" sync "$RUN_DIR" >/dev/null \
    || echo "end-gate.sh: could not read the open decisions' rulings (questions.sh sync); going by the state file" >&2
}

# No PR to main while one is open: approve and cut both refuse (6).
need_ruled() { # what is refused
  sync_unruled
  [ -z "$(unruled)" ] \
    || refuse "open decisions raised at a gate wait for the Decision chat's ruling: $(unruled). $1 until each is ruled on"
}

open_decisions_section() {
  echo "## Open decisions raised at gates"
  echo
  if [ -z "$(unruled)" ]; then
    echo "None waiting: every open decision raised at a gate is ruled on."
    return 0
  fi
  echo "Sent to the Decision chat from a gate and not ruled on yet. No PR to \`$(main_branch)\` is cut until each is ruled on (\`questions.sh sync\` reads the rulings)."
  echo
  echo "| Open decision | Ticket | Raised at | Item |"
  echo "|---|---|---|---|"
  get -r "$UNRULED_JQ"'[] | "| #\(.ticket) | #\(.in) | gate #\(.gate_issue // "-") (\(.gate // "-")) | \(.item | to_entries | map("\(.key) \(.value)") | join(", ")) |"'
}

# ------------------------------------------------------------ Human checks

# The Human checks the end gate lists (references/human-checks.md): every one
# still open, and every one deferred past the run.
end_checks_json() {
  get -c "$STATE_JQ_DEFS"' . as $s
    | [.plan.scope[] | tostring | select(. as $t | $s | is_human_check($t))
       | select($s.tickets[.].status == "queued" or $s.tickets[.].human_check.state? == "deferred")
       | . as $c
       | {ticket: ., for: ($s | human_check_for($c)), state: ($s.tickets[.].human_check.state // "open")}
         + (($s.tickets[.].human_check.deferral // null) | if . then {deferral: .} else {} end)
         + (($s.tickets[.].human_check.gate // null) | if . then {carried_from: .} else {} end)
         + (($s | check_rework($c)) | if . then {waiting_on: split(" ")[1]} else {} end)]'
}

human_checks_section() {
  human_checks_view "$(end_checks_json)" | PACKET checks
}

open_checks() { get -r "$STATE_JQ_DEFS"' open_human_checks | map("#" + .) | join(", ")'; }

# defer-check: a Human check deferred past the run, on the Artisan's word,
# with who and why. It stays open on the tracker, labelled deferred with a
# return condition, and no longer holds the end gate's approval.
cmd_defer_check() {
  [ $# -ge 2 ] || usage
  open_run "$1"
  local t="$2" by=Artisan why="" ret="" agent="" repo="" open=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --why) [ $# -ge 2 ] && [ -n "$2" ] || usage; why=$2; shift 2 ;;
      --by) [ $# -ge 2 ] && [ -n "$2" ] || usage; by=$2; shift 2 ;;
      --return) [ $# -ge 2 ] && [ -n "$2" ] || usage; ret=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$why" ] || usage
  [ "$(get --arg t "$t" "$STATE_JQ_DEFS"' is_human_check($t)')" = true ] || refuse "#$t is not a Human check of this run"
  case "$(status_word)" in
    due|open|removed) ;;
    *) refuse "a Human check is deferred past the run at the end gate; it is not due yet (answer #$t at its slice gate with gate.sh check)" ;;
  esac
  [ "$(get --arg t "$t" '.tickets[$t].status')" = queued ] \
    || refuse "Human check #$t is $(get --arg t "$t" '.tickets[$t].human_check.state // .tickets[$t].status'), not open"
  # The same refusal as gate.sh check: a failed check waits on its rework (#178).
  open=$(get -r --arg t "$t" "$STATE_JQ_DEFS"' check_rework($t) // ""')
  [ -z "$open" ] || refuse "Human check #$t already failed at ${open% *}; rework #${open#* } is open"
  agent=$(get --arg t "$t" "$STATE_JQ_DEFS"' human_check_for($t)')
  [ -n "$ret" ] || ret="check #$agent's work on $(main_branch) once run $RUN_ID's PRs are merged"
  repo=$(get -r .repo)
  gh issue edit "$t" -R "$repo" --add-label deferred --remove-label in-run >/dev/null \
    || die "could not label #$t deferred on the tracker"
  gh issue comment "$t" -R "$repo" --body "> *This was generated by AI during a run.*

Deferred past run $RUN_ID at its end gate by $by: $why. This Human check stays open; nothing in the run waits on it.

Return condition: $ret" >/dev/null || die "could not comment on #$t"
  apply '.tickets[$t].status = "deferred" | .tickets[$t].pid = null
    | .tickets[$t].human_check = ((.tickets[$t].human_check // {for: $a}) + {state: "deferred",
        deferral: {by: $by, why: $why, return: $ret, at: $now}})
    | event({event: "human-check-deferred", ticket: $t, agent_ticket: $a, gate: "end", by: $by, why: $why}; $now)' \
    --arg t "$t" --arg a "$agent" --arg by "$by" --arg why "$why" --arg ret "$ret"
  echo "Human check #$t deferred past the run by $by; it stays open, labelled deferred (return condition: $ret)"
}

cmd_open() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local num= repo= title= url= dir=
  num=$(get -r '.end_gate.issue // empty')
  if [ -n "$num" ]; then echo "$num"; return 0; fi
  case "$(status_word)" in
    due) ;;
    removed) refuse "the Artisan removed the end gate at the plan step: approve the PR boundary with end-gate.sh approve" ;;
    *) refuse "the end gate is not due: tickets in scope are still to merge" ;;
  esac
  # Any ci/<run-id>-* branch a merge gate on CI left behind (a crash mid-gate).
  "$SCRIPT_DIR/merge-gate.sh" sweep --prefix "ci/$RUN_ID-" --dir "$MAIN" >/dev/null 2>&1 || true
  repo=$(get -r .repo); title="End gate: run $RUN_ID"
  dir="$RUN_DIR/gates"; mkdir -p "$dir"
  packet >"$dir/end.md"
  num=$(gh issue list -R "$repo" --state open --limit 10000 --label review-gate --json number,title \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  if [ -z "$num" ]; then
    url=$("$SCRIPT_DIR/tracker.sh" new-issue --kind gate -- -R "$repo" --title "$title" --label review-gate --body-file "$dir/end.md") \
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
  get -r "$(state_deferred_gates_jq)"'| map("\(.title) #\(.issue)") | join("; ")'
}

cmd_approve() {
  [ $# -ge 1 ] || usage
  open_run "$1"
  shift
  local by=Artisan why= set= changed=false st= b= issue= src=
  while [ $# -gt 0 ]; do
    case "$1" in
      --boundary) [ $# -ge 2 ] || usage; set=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; why=$2; shift 2 ;;
      --changed) changed=true; shift ;;
      *) usage ;;
    esac
  done
  case "$set" in ""|slice|plan|ticket|run) ;; *) usage ;; esac
  st=$(status_word)
  [ "$st" = not-due ] || [ -z "$(open_deferred)" ] \
    || refuse "deferred gates are still waiting here; answer each first: $(open_deferred)"
  # Nothing an open decision touches reaches main before it is ruled on.
  [ "$st" = not-due ] || need_ruled "The end gate can't be approved"
  # No PR is cut while a Human check is open, unless it is deferred past the run.
  [ "$st" = not-due ] || [ -z "$(open_checks)" ] \
    || state_die 22 "end-gate.sh: Human checks are still open: $(open_checks). Answer each (gate.sh check $RUN_DIR <n> pass|fail --why W) or defer it past the run (end-gate.sh defer-check $RUN_DIR <n> --why W)"
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
    refuse "no pr-boundaries guardrail is recorded: the boundary is the Artisan's to approve. Proposed: one PR per slice (--boundary slice|plan|ticket|run)"
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
    | event({event: "end-gate-approved", by: $by, boundary: $b.value, source: $src, changed: $changed}; $now)
    | answer_folded("end"; "approved"; $by; $changed; $now)' \
    --arg by "$by" --arg why "$why" --argjson changed "$changed" --argjson b "$b" --arg src "$src"
  if [ -n "$issue" ]; then
    gh issue close "$issue" -R "$(get -r .repo)" --comment "Approved by $by. PRs to main: one per $(jq -r .value <<<"$b") ($src$([ "$src" = guardrail ] && printf ', %s level' "$(jq -r .level <<<"$b")")).$([ -n "$why" ] && printf ' Why: %s' "$why")" >/dev/null \
      || die "approved in the state file, but could not close #$issue"
  fi
  echo "approved: PRs one per $(jq -r .value <<<"$b"); next: end-gate.sh prs, then write each body with upstream pr and end-gate.sh cut"
}

# pr_unmerged_through <n>: the URLs of the cut PRs 1..n that are not merged yet,
# space-separated (empty when all are). A stacked PR merges into its base, so a
# PR counts as shipped to the default branch only once every PR under it has
# merged too. Fails when a PR's state can't be read.
pr_unmerged_through() {
  local n="$1" i= u= st= out= repo=
  repo=$(get -r .repo)
  for ((i = 1; i <= n; i++)); do
    u=$(get -r --argjson n "$i" '[(.end_gate.prs // [])[] | select(.n == $n) | .url] | first // empty')
    [ -n "$u" ] || return 1
    st=$(gh pr view "${u##*/}" -R "$repo" --json state -q .state 2>/dev/null) || return 1
    [ "$st" = MERGED ] || out="$out${out:+ }$u"
  done
  printf '%s\n' "$out"
}

# retire_designs: design.sh retire for each open design a ticket in scope names
# ("Design: #<n>" at the start of a line in its body), and no other (#335). Its
# merge is the last PR that carries one of the design's tickets, and a design
# is retired only once that PR has merged (#396); one whose PR hasn't is left
# alone and named in $waiting. Safe to run again: a design already retired has
# a closed ticket and is skipped.
retire_designs() {
  local repo= t= body= d= dj= slug= plan= pr= url= pairs= seen=" " rc=0 unmerged= last= groups= mine= out=
  waiting=
  repo=$(get -r .repo)
  groups=$(pr_groups "$(get -r '.end_gate.boundary.value')")
  plan=$(jq -c .prs <<<"$groups")
  for t in $(get -r '.plan.scope[]'); do
    body=$(gh issue view "$t" -R "$repo" --json body --jq .body 2>/dev/null) || { echo "end-gate.sh: could not read #$t to look for its design" >&2; rc=1; continue; }
    for d in $(printf '%s\n' "$body" | sed -nE 's/^[Dd]esign: #([0-9]+).*$/\1/p'); do
      pairs="$pairs$d:$t "
    done
  done
  for d in $(printf '%s\n' $pairs | cut -d: -f1 | sort -un); do
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "
    dj=$(gh issue view "$d" -R "$repo" --json labels,state,body 2>/dev/null) || { echo "end-gate.sh: could not read design #$d" >&2; rc=1; continue; }
    jq -e 'any(.labels[]; .name == "design") and (.state | ascii_downcase) == "open"' <<<"$dj" >/dev/null || continue
    slug=$(jq -r .body <<<"$dj" | sed -nE 's/^- \*\*Feature branch:\*\* `feature\/([^`]+)`.*$/\1/p' | head -1)
    [ -n "$slug" ] || { echo "end-gate.sh: design #$d records no feature branch" >&2; rc=1; continue; }
    url=; last=
    for t in $(printf '%s\n' $pairs | sed -n "s/^$d://p"); do
      pr=$(jq -r --arg t "$t" '[.[] | select(.tickets | index($t))] | last | .n // empty' <<<"$plan")
      [ -z "$pr" ] || [ -n "$last" -a "$pr" -le "${last:-0}" ] || last=$pr
    done
    [ -z "$last" ] || { pr=$last; url=$(get -r --argjson n "$pr" '[(.end_gate.prs // [])[] | select(.n == $n) | .url] | first // empty'); }
    if [ -z "$url" ] && { [ "${outside:-0}" -eq 1 ] || [ "$(get '.end_gate.merged_outside != null')" = true ]; }; then
      # The whole branch merged as one PR outside end-gate.sh cut (#364): that PR carries every ticket.
      # finish found it before recording it; a rerun reads the record.
      url=$(get -r '.end_gate.merged_outside.url // empty')
      [ -n "$url" ] || url=${OUT_URL:-}
      [ -n "$url" ] || { echo "end-gate.sh: design #$d is not retired: the PR that merged the run was not found; retire it with design.sh retire" >&2; continue; }
      (cd "$MAIN" && "$SCRIPT_DIR/../skills/design/scripts/design.sh" retire --design "$slug" --ticket "$d" --merge "$url") >&2 \
        || { echo "end-gate.sh: could not retire design #$d" >&2; rc=1; }
      continue
    fi
    if [ -z "$url" ] && [ -z "$last" ]; then
      # Every ticket of the design was left out as already on main (#363): no
      # PR of this run carries it, and the one that merged it isn't known.
      mine=$(printf '%s\n' $pairs | sed -n "s/^$d://p" | jq -Rsc 'split("\n") | map(select(. != ""))')
      out=$(jq -r --argjson m "$mine" '[.left_out[].tickets[]] as $lo
        | if all($m[]; . as $t | $lo | index($t) != null) then $m | map("#" + .) | join(", ") else "" end' <<<"$groups")
      if [ -n "$out" ]; then
        echo "end-gate.sh: design #$d is not retired: its tickets ($out) reached main outside this run's PRs; retire it with design.sh retire --merge <the PR that merged them>" >&2
        continue
      fi
    fi
    [ -n "$url" ] || { echo "end-gate.sh: no cut PR carries a ticket of design #$d" >&2; rc=1; continue; }
    # Cutting a PR isn't shipping it: retire once the PR, and every PR under it
    # in the stack, has merged (#396). Until then the design is waiting.
    unmerged=$(pr_unmerged_through "$pr") || { echo "end-gate.sh: could not read the PRs carrying design #$d" >&2; rc=1; continue; }
    if [ -n "$unmerged" ]; then
      echo "end-gate.sh: design #$d is waiting on the merge of $unmerged; run end-gate.sh finish again once it has merged" >&2
      waiting="$waiting #$d"
      continue
    fi
    (cd "$MAIN" && "$SCRIPT_DIR/../skills/design/scripts/design.sh" retire --design "$slug" --ticket "$d" --merge "$url") >&2 \
      || { echo "end-gate.sh: could not retire design #$d" >&2; rc=1; }
  done
  return "$rc"
}

# outside_merge: the integration branch's tip is already on the default branch
# (the Artisan merged the whole branch as one PR, #364). Sets $OUT_TIP and
# $OUT_REF; on success $OUT_URL (the merging PR's URL, empty when none is
# found); on failure $OUT_MISSING, the merges the default branch lacks.
outside_merge() {
  local ib= base= ref= t= c= merges=
  OUT_URL= OUT_MISSING=
  ib=$(integration_branch); base=$(main_branch); ref=$base
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    git -C "$MAIN" fetch -q origin "$base" >&2 || die "could not fetch origin $base"
    ref="origin/$base"
  fi
  OUT_REF=$ref
  OUT_TIP=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$ib^{commit}" 2>/dev/null) || OUT_TIP=
  if [ -n "$OUT_TIP" ] && git -C "$MAIN" merge-base --is-ancestor "$OUT_TIP" "$ref" 2>/dev/null; then
    OUT_URL=$(gh pr list -R "$(get -r .repo)" --state merged --search "$OUT_TIP" --json number,url -q '.[0].url // ""' 2>/dev/null || true)
    return 0
  fi
  merges=$(get -r '(.integration.merges // [])[] | "\(.ticket) \(.commit)"')
  while read -r t c; do
    [ -n "$t" ] || continue
    git -C "$MAIN" merge-base --is-ancestor "$c" "$ref" 2>/dev/null || OUT_MISSING="$OUT_MISSING${OUT_MISSING:+, }#$t (${c:0:7})"
  done <<EOF2
$merges
EOF2
  [ -n "$OUT_MISSING" ] || OUT_MISSING="the integration branch's tip ${OUT_TIP:0:7}"
  return 1
}

cmd_finish() {
  [ $# -eq 1 ] || usage
  open_run "$1"
  local want= have= repo= t= bad=0 done_list= outside=0 via=
  # A rerun after the run ended retires the designs whose PRs have merged since (#396).
  if [ "$(status_word)" = ended ]; then
    waiting=
    retire_designs || die "some designs are not retired; fix that and run end-gate.sh finish again"
    if [ -n "$waiting" ]; then echo "Run $RUN_ID has ended; designs still waiting on their PR's merge:$waiting."
    else echo "Run $RUN_ID has ended; every design it ships is retired."; fi
    return 0
  fi
  [ "$(status_word)" = approved ] || refuse "the run ends after the end gate's approval and its PRs"
  want=$(pr_plan "$(get -r '.end_gate.boundary.value')" | jq length)
  have=$(get '(.end_gate.prs // []) | length')
  # No PR cut at all: the branch may have reached main as one PR (#364), even
  # when that leaves no PR to cut (#363).
  if [ "$have" -lt "$want" ] || [ "$have" -eq 0 ]; then
    if outside_merge; then outside=1
    elif [ "$have" -lt "$want" ]; then refuse "$have of $want PRs cut; cut the rest first (end-gate.sh prs). The integration branch is not on $OUT_REF either; merges missing from it: $OUT_MISSING"
    fi
  fi
  repo=$(get -r .repo)
  waiting=
  retire_designs || die "some designs are not retired; fix that and run end-gate.sh finish again"
  for t in $(get -r '.plan.scope[]'); do
    if gh issue edit "$t" -R "$repo" --remove-label in-run >/dev/null 2>&1; then done_list="$done_list #$t"
    else echo "end-gate.sh: could not remove in-run from #$t" >&2; bad=1; fi
  done
  [ "$bad" -eq 0 ] || die "some in-run labels are still on; run end-gate.sh finish again"
  if [ "$outside" -eq 1 ]; then
    apply '.end_gate.status = "ended" | .end_gate.ended_at = $now
      | .end_gate.merged_outside = {url: (if $url == "" then null else $url end), tip: $tip, into: $ref}
      | event({event: "run-ended", prs: (((.end_gate.prs // []) | map(.url)) + (if $url == "" then [] else [$url] end))}; $now)' \
      --arg url "$OUT_URL" --arg tip "$OUT_TIP" --arg ref "$OUT_REF"
    via=${OUT_URL:-a PR that could not be found}
    echo "Run $RUN_ID ended: its integration branch was already on $(main_branch), through $via; in-run removed from$done_list."
  else
    apply '.end_gate.status = "ended" | .end_gate.ended_at = $now
      | event({event: "run-ended", prs: ((.end_gate.prs // []) | map(.url))}; $now)'
    echo "Run $RUN_ID ended: $have PR(s) to $(main_branch); in-run removed from$done_list."
  fi
  [ -z "$waiting" ] || echo "Designs waiting on their PR's merge (run end-gate.sh finish $RUN_DIR again after it merges):$waiting."
  [ "$outside" -eq 1 ] || stack_steps "$(get -c '.end_gate.prs // []')"
  # For the run summary: what the merge gates cost (#199).
  echo
  python3 -I "$SCRIPT_DIR/../skills/retro/scripts/retro.py" gate-costs "$FILE" \
    || echo "end-gate.sh: could not total the merge gates' costs" >&2
  echo
  echo "Next: offer the retro, /artisan-agent:retro."
}

# ------------------------------------------------------------ urgent ticket

# An urgent ticket (lever.sh urgent) ships through its own end gate and PR,
# scoped to that one ticket and based on main, with the same packet, PR body
# (upstream `pr`) and cut as the run's. Its gate lives in urgent_gates.<t>.

urgent_args() { # run-dir ticket: opens the run, sets U
  [ $# -ge 2 ] || usage
  open_run "$1"
  U=$2
  [ "$(get --arg t "$U" '.tickets[$t].urgent // false')" = true ] || refuse "#$U is not an urgent ticket (lever.sh urgent)"
}
U=
ugate() { get -r --arg t "$U" "$1" ; }
ustatus() { ugate '.urgent_gates[$t].status // ""'; }

cmd_urgent_packet() {
  urgent_args "$@"
  local tmp= real=
  tmp=$(mktemp "${TMPDIR:-/tmp}/urgent-packet.XXXXXX")
  jq --arg t "$U" '.plan.scope = [$t] | .plan.gates = [] | .plan.route = "" | .end_gate = {}' "$FILE" >"$tmp"
  real=$FILE; FILE=$tmp; URGENT=$U
  packet || { FILE=$real; URGENT=; rm -f "$tmp"; return 1; }
  FILE=$real; URGENT=; rm -f "$tmp"
}

cmd_urgent_open() {
  urgent_args "$@"
  local num= repo= title= url= dir= st= tip=
  num=$(ugate '.urgent_gates[$t].issue // empty')
  if [ -n "$num" ]; then echo "$num"; return 0; fi
  st=$(get --arg t "$U" '.tickets[$t].status')
  [ "$st" = returned ] || refuse "#$U is $st: its end gate opens once its work has returned and been verified"
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$(get --arg t "$U" '.tickets[$t].branch')") || die "no branch for #$U"
  [ "$(get --arg t "$U" --arg tip "$tip" '.tickets[$t].evidence | if . != null and .verdict == "pass" and .commit == $tip then "pass" else "" end')" = pass ] \
    || refuse "#$U has no passing verdict at $tip: run verify.sh start, then verify.sh judge"
  repo=$(get -r .repo); title="End gate: urgent #$U (run $RUN_ID)"
  dir="$RUN_DIR/gates"; mkdir -p "$dir"
  cmd_urgent_packet "$RUN_DIR" "$U" >"$dir/urgent-$U.md"
  num=$(gh issue list -R "$repo" --state open --limit 10000 --label review-gate --json number,title \
          | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  if [ -z "$num" ]; then
    url=$("$SCRIPT_DIR/tracker.sh" new-issue --kind gate -- -R "$repo" --title "$title" --label review-gate --body-file "$dir/urgent-$U.md") \
      || die "could not open the urgent end gate's issue"
    num=${url##*/}
  fi
  apply '
    .urgent_gates = ((.urgent_gates // {}) | .[$t] = {status: "open", issue: $num, title: $title, opened_at: $now})
    | .decisions += [{id: ((.decisions | length) + 1), kind: "end-gate", gate: "urgent-\($t)", issue: $num,
        question: "\($title) is #\($num): approve to cut its PR to main.", status: "waiting", at: $now}]
    | event({event: "gate-opened", gate: "urgent-\($t)", kind: "end", issue: $num}; $now)' \
    --arg t "$U" --argjson num "$num" --arg title "$title"
  echo "$num"
}

cmd_urgent_approve() {
  urgent_args "$@"
  shift 2
  local by=Artisan why= issue=
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] || usage; by=$2; shift 2 ;;
      --why) [ $# -ge 2 ] || usage; why=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$(ustatus)" in
    open) ;;
    "") refuse "open #$U's end gate first (end-gate.sh urgent-open)" ;;
    *) refuse "#$U's end gate is already $(ustatus)" ;;
  esac
  issue=$(ugate '.urgent_gates[$t].issue // empty')
  apply '
    .urgent_gates[$t] += {status: "approved", approved_at: $now, by: $by}
    | decide((.decisions | map(select(.kind == "end-gate" and .gate == "urgent-\($t)" and .status == "waiting")) | first | .id // -1);
        {choice: "approve", by: $by, job: 13, changed: false} + (if $why == "" then {} else {why: $why} end); $now)
    | event({event: "end-gate-approved", gate: "urgent-\($t)", by: $by}; $now)' \
    --arg t "$U" --arg by "$by" --arg why "$why"
  if [ -n "$issue" ]; then
    gh issue close "$issue" -R "$(get -r .repo)" --comment "Approved by $by. PR to $(main_branch): #$U alone.$([ -n "$why" ] && printf ' Why: %s' "$why")" >/dev/null \
      || die "approved in the state file, but could not close #$issue"
  fi
  echo "approved: #$U ships on its own PR to $(main_branch); next: write its body with upstream pr, then end-gate.sh urgent-cut"
}

cmd_urgent_cut() {
  urgent_args "$@"
  shift 2
  local body= title= url= branch= base= repo= tip=
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) [ $# -ge 2 ] || usage; body=$2; shift 2 ;;
      --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$body" ] || usage
  case "$(ustatus)" in
    approved | ended) ;;
    *) refuse "the PR waits for #$U's end gate approval (end-gate.sh urgent-approve)" ;;
  esac
  url=$(ugate '.urgent_gates[$t].pr.url // empty')
  if [ -n "$url" ]; then echo "$url"; return 0; fi
  [ -f "$body" ] || die "no body file at $body"
  tip=$(git -C "$MAIN" rev-parse -q --verify "refs/heads/$(get --arg t "$U" '.tickets[$t].branch')") || die "no branch for #$U"
  branch="pr/$RUN_ID/urgent-$U"; base=$(main_branch); repo=$(get -r .repo)
  git -C "$MAIN" branch -f "$branch" "$tip" >/dev/null || die "could not create $branch"
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    git -C "$MAIN" push -q origin "$branch:refs/heads/$branch" >&2 || die "could not push $branch"
  fi
  [ -n "$title" ] || title="Urgent #$U: $(get -r --arg t "$U" '.plan.tickets[$t].title // "untitled"')"
  url=$(gh pr create -R "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body") \
    || die "could not open the PR for $branch (the branch is kept)"
  url=$(printf '%s\n' "$url" | tail -1)
  apply '.urgent_gates[$t].pr = {url: $url, branch: $branch, base: $base, at: $now}
    | event({event: "pr-cut", gate: "urgent-\($t)", branch: $branch, base: $base, tickets: [$t], url: $url}; $now)' \
    --arg t "$U" --arg url "$url" --arg branch "$branch" --arg base "$base"
  echo "$url"
}

# Once the urgent PR is merged: main comes into the integration branch, the
# full suite runs there, and the ticket is merged for the run (it is on main).
cmd_urgent_finish() {
  urgent_args "$@"
  local url= num= state= oid= wt= ib= pre= suite= log= ref= base= sha= paths= repo=
  case "$(ustatus)" in
    ended) echo "#$U already shipped and synced"; return 0 ;;
    approved) ;;
    *) refuse "#$U's end gate is not approved" ;;
  esac
  url=$(ugate '.urgent_gates[$t].pr.url // empty')
  [ -n "$url" ] || refuse "cut #$U's PR first (end-gate.sh urgent-cut)"
  num=${url##*/}; repo=$(get -r .repo)
  state=$(gh pr view "$num" -R "$repo" --json state -q .state) || die "could not read $url"
  [ "$state" = MERGED ] || refuse "$url is $state: merge it first; main joins the integration branch after"
  oid=$(gh pr view "$num" -R "$repo" --json mergeCommit -q '.mergeCommit.oid // ""' 2>/dev/null || true)
  # A resolved main merge is gating (wave.sh resolved): finish it there.
  [ "$(get -r --arg t "$U" '.merge_gate.ticket // ""')" != "$U" ] \
    || state_die 20 "end-gate.sh: main's merge into the integration branch is in its merge gate; run wave.sh merge $RUN_DIR $U to wait on it"
  wt=$(integration_worktree); ib=$(integration_branch); base=$(main_branch)
  suite=$(get -r '.plan.suite_command // ""')
  [ -n "$suite" ] || die "the plan has no suite_command; the full suite must run after main joins the integration branch"
  priority_init || exit 1
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "the integration worktree $wt has uncommitted changes"
  ref=$base
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    git -C "$MAIN" fetch -q origin "$base" >&2 || die "could not fetch origin $base"
    ref="origin/$base"
  fi
  pre=$(git -C "$wt" rev-parse HEAD)
  if ! git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-Artisan-Agent}" -c user.email="${GIT_AUTHOR_EMAIL:-artisan-agent@localhost}" \
       merge --no-edit -m "Merge $base into $ib (urgent #$U shipped)" "$ref" >/dev/null 2>&1; then
    local pjson= head=
    pjson=$(git -C "$wt" diff -z --name-only --diff-filter=U | jq -Rs 'split("\u0000")[:-1]')
    paths=$(jq -r 'join(" ")' <<<"$pjson")
    if [ "$(get --arg t "$U" '.tickets[$t].resolve != null')" = true ] || [ -z "$paths" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || git -C "$wt" reset -q --hard "$pre"
      queue_sync_decision "$U" "merging $ref into $ib conflicts in ${paths:-unknown paths}; $([ -n "$paths" ] && echo "its one /artisan-agent:resolve-conflicts try is used" || echo "it failed with no conflicted paths to resolve")"
      refuse "merging $ref into $ib failed (${paths:-no conflicted paths}); nothing changed and a decision is queued"
    fi
    # Left in progress for the one try at resolving it (as wave.sh merge does).
    head=$(git -C "$wt" rev-parse "$ref")
    apply '.tickets[$t].resolve = {attempt: (.tickets[$t].attempts // 1), paths: $p, pre: $pre, outcome: "pending",
          sync: {ref: $ref, head: $head, url: $url, oid: $oid}, at: $now}
      | event({event: "conflict", ticket: $t, paths: $p, next: "resolve-conflicts", sync: true}; $now)' \
      --arg t "$U" --argjson p "$pjson" --arg pre "$pre" --arg ref "$ref" --arg head "$head" --arg url "$url" --arg oid "$oid"
    state_die 11 "end-gate.sh: merging $ref into $ib conflicts in $paths; run /artisan-agent:resolve-conflicts once in $wt, then wave.sh resolved $RUN_DIR $U"
  fi
  mkdir -p "$RUN_DIR/merges"
  log="$RUN_DIR/merges/urgent-$U.suite.log"
  if ! (cd "$wt" && priority_run sh -c "$suite") >"$log" 2>&1; then
    git -C "$wt" reset -q --hard "$pre"
    apply '.decisions += [{id: ((.decisions | length) + 1), kind: "exception", ticket: $t,
        question: "Merging main into the integration branch after urgent #\($t) shipped made the suite fail (merges/urgent-\($t).suite.log); the merge was undone. Fix the integration branch, or take it yourself?",
        status: "waiting", at: $now}]
      | event({event: "main-sync-red", ticket: $t, log: $l}; $now)' --arg t "$U" --arg l "merges/urgent-$U.suite.log"
    state_die 7 "end-gate.sh: merging $ref into $ib made the suite fail; the merge was undone (see $log)"
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  apply '
    .tickets[$t] |= (.status = "merged" | .pid = null | .merge_commit = (if $oid == "" then $sha else $oid end)
      | .suite = {command: $suite, passed: true, log: $l}
      | .shipped = {pr: $url, main_merged_into: $ib, sync_commit: $sha, at: $now})
    | .urgent_gates[$t] += {status: "ended", ended_at: $now, sync_commit: $sha}
    | event({event: "urgent-shipped", ticket: $t, pr: $url, sync_commit: $sha}; $now)' \
    --arg t "$U" --arg oid "$oid" --arg sha "$sha" --arg suite "$suite" --arg l "merges/urgent-$U.suite.log" \
    --arg url "$url" --arg ib "$ib"
  gh issue edit "$U" -R "$repo" --remove-label in-run >/dev/null 2>&1 || echo "end-gate.sh: could not remove in-run from #$U" >&2
  echo "#$U shipped: $url merged; $base is in $ib ($sha) with the full suite green. Close it with wave.sh close."
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  urgent-packet) cmd_urgent_packet "$@" ;;
  urgent-open) cmd_urgent_open "$@" ;;
  urgent-approve) cmd_urgent_approve "$@" ;;
  urgent-cut) cmd_urgent_cut "$@" ;;
  urgent-finish) cmd_urgent_finish "$@" ;;
  status) cmd_status "$@" ;;
  packet) cmd_packet "$@" ;;
  open) cmd_open "$@" ;;
  boundary) cmd_boundary "$@" ;;
  approve) cmd_approve "$@" ;;
  prs) cmd_prs "$@" ;;
  cut) cmd_cut "$@" ;;
  finish) cmd_finish "$@" ;;
  defer-check) cmd_defer_check "$@" ;;
  *) usage ;;
esac
