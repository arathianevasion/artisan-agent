#!/usr/bin/env bash
# The evidence contract, shown: on the ticket as a comment, and in the
# Engineering chat as the wave digest. Both are printed from the state file
# alone (the contract verify.sh judge wrote), so the tracker and the state
# file can't disagree. The contract's shape:
# ${CLAUDE_PLUGIN_ROOT}/references/evidence-contract.md.
#
# Usage:
#   evidence.sh comment <run-dir> <ticket>
#       the ticket's evidence comment, Markdown: verdict, each criterion with
#       its evidence, the suite, diff stats, cost against the estimate, what
#       the worker was unsure of, the decisions it made alone, and the
#       contract itself as JSON. wave.sh close posts it.
#   evidence.sh digest <run-dir> [--wave N | --all]
#       the wave digest, Markdown: one table row per ticket dispatched in the
#       wave (default: the last orchestrator's wave), naming it by number and
#       short description, then one line of cost. --all covers every ticket
#       in scope.
#
# Exit status: 0 ok, 1 error (no contract for the ticket, an unreadable state
# file), 2 usage (including a --wave that is not a number).
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/state-lib.sh
. "$SCRIPT_DIR/lib/state-lib.sh"
state_require_jq

usage() { state_usage "$0"; }

[ $# -ge 2 ] || usage
cmd=$1 run_dir=$2
shift 2
state_require_run_dir "$run_dir"
FILE=$(state_file "$run_dir")
state_valid_file "$FILE" || state_die 1 "evidence.sh: $(state_version_message "$FILE")"

# Shared: a table cell, a dollar figure, a ticket's name.
DEFS='
  def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
  def usd: if . == null then "-"
    else (. * 100 | round) as $c | "$\($c / 100 | floor).\($c % 100 | tostring | if length == 1 then "0" + . else . end)" end;
  def name($s; $t): "#\($t) (\($s.plan.tickets[$t].title // "untitled"))";
  def arr: if type == "array" then . elif . == null then [] else [.] end;
  def ev: if type == "object" then
      ([(.tests | arr)[] | tostring] + [(.checks | arr)[] | if type == "object" then "\(.command): \(.result)" else tostring end]
       + (if .diff then [.diff | tostring] else [] end) + (if .why then [.why | tostring] else [] end)) | join("; ")
    else tostring end;
'

cmd_comment() {
  local t="${1:-}"
  [ -n "$t" ] || usage
  jq -e --arg t "$t" '.tickets[$t].evidence | type == "object"' "$FILE" >/dev/null \
    || state_die 1 "evidence.sh: #$t has no evidence contract yet; verify.sh judge writes it"
  jq -r --arg t "$t" "$DEFS"'
    . as $s | .tickets[$t] as $k
    | $k.evidence | .unsure |= arr | .decisions |= arr | .verifier.unsure |= arr | . as $e
    | "**Evidence for \(name($s; $t))**: the verifier says **\($e.verdict)**, \($e.criteria_met) of \($e.criteria_total) criteria met (attempt \($e.attempt), commit \($e.commit[0:7]), run \($s.run_id)).",
      (if $k.status == "merged" and $k.merge_commit then
         "Merged into `\($s.integration.branch)` as \($k.merge_commit[0:7]); the full suite passed after the merge." else empty end),
      "",
      "| Criterion | Met | Evidence |", "|---|---|---|",
      ($e.acceptance[] | "| \(.criterion | cell) | \(if .met then "yes" else "no" end) | \(.evidence | ev | cell) |"),
      "",
      "- **Suite:** \(if $e.tests then "`\($e.tests.command // "-")` → \($e.tests.summary // "-" | cell)" else "not reported" end)",
      "- **Diff:** \(if ($e.diff.summary // "") == "" then "no changes" else $e.diff.summary end)",
      "- **Cost:** \($e.cost.total_usd | usd) (worker \($e.cost.worker_usd | usd), verifier \($e.cost.verifier_usd | usd)) against an estimate of \($e.cost.estimate_usd | usd)",
      "",
      "**What the worker was unsure of**",
      (if ($e.unsure | length) == 0 then "Nothing." else ($e.unsure[] | "- \(. | cell)") end),
      (if ($e.verifier.unsure | length) > 0 then ("", "**What the verifier was unsure of**", ($e.verifier.unsure[] | "- \(. | cell)")) else empty end),
      "",
      "**Decisions made alone**",
      (if ($e.decisions | length) == 0 then "None."
       else ("| Question | Choice | Alternative | Kind | Confidence |", "|---|---|---|---|---|",
             ($e.decisions[] | "| \(.question // "-" | cell) | \(.choice // "-" | cell) | \(.alternative // "-" | cell) | \(.kind // "-" | cell) | \(.confidence // "-" | cell) |"))
       end),
      (if $e.verifier.notes then ("", "**Verifier notes:** \($e.verifier.notes | cell)") else empty end),
      "",
      "<details><summary>The evidence contract, as in the run state file</summary>",
      "",
      "```json",
      $k.evidence,
      "```",
      "</details>"' "$FILE"
}

cmd_digest() {
  local scope=wave wave=
  while [ $# -gt 0 ]; do
    case "$1" in
      --wave) [ $# -ge 2 ] || usage; case "$2" in '' | *[!0-9]*) usage ;; esac; wave=$2; shift 2 ;;
      --all) scope=all; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$wave" ] || wave=$(jq -r '(.orchestrators // []) | last | .wave // 1' "$FILE")
  jq -r --arg scope "$scope" --argjson w "$wave" "$DEFS"'
    . as $s
    # Each ticket'"'"'s wave is the wave that last dispatched it (wave.sh dispatch).
    | [ $s.plan.scope[] | select($scope == "all" or $s.tickets[.].wave == $w) ] as $ts
    | (if $scope == "all" then "Run \($s.run_id): every ticket" else "Wave \($w) of run \($s.run_id)" end)
      + ": \($ts | length) ticket\(if ($ts | length) == 1 then "" else "s" end).",
      "",
      "| Ticket | Outcome | Criteria | Unsure / decisions | Cost |",
      "|---|---|---|---|---|",
      ( $ts[] as $t | $s.tickets[$t] as $k | $k.evidence as $e
        | "| \(name($s; $t) | cell) | "
          + ( if $k.status == "merged" then "merged" + (if $k.merge_commit then " as \($k.merge_commit[0:7])" else "" end) + (if $k.tracker_closed then ", closed" else ", not closed yet" end)
              elif $k.status == "blocked" then "blocked: \($k.blocked_reason // ($k.failures // [] | last | .reason) // "see decisions" | cell)"
              elif $k.status == "in_flight" then "in flight (attempt \($k.attempts))"
              else $k.status end )
          # A contract from an earlier attempt says nothing about the current one.
          + " | " + (if $e == null then "not verified"
                     elif $e.attempt != $k.attempts and $k.status != "blocked" then "not verified yet (attempt \($k.attempts))"
                     else "\($e.criteria_met)/\($e.criteria_total) verified" end)
          + " | " + (if $e then "\($e.unsure | arr | length) unsure, \($e.decisions | arr | length) decision\(if ($e.decisions | arr | length) == 1 then "" else "s" end)" else "-" end)
          + " | \($k.cost_usd // 0 | usd) of \($s.plan.tickets[$t].estimate_usd // null | usd) |" ),
      "",
      "Cost: \([$ts[] as $t | $s.tickets[$t].cost_usd // 0] | add // 0 | usd) for these tickets; the run so far \($s.costs.total_usd // 0 | usd)\(if $s.plan.budget_usd then " of a \($s.plan.budget_usd | usd) budget" else "" end).",
      ( [ $ts[] | select($s.tickets[.].status == "blocked") ] as $b
        | if ($b | length) > 0 then "Blocked: \($b | map("#" + .) | join(", ")), each with a decision waiting (wave.sh status lists them)." else empty end )' "$FILE"
}

case "$cmd" in
  comment) cmd_comment "$@" ;;
  digest) cmd_digest "$@" ;;
  *) usage ;;
esac
