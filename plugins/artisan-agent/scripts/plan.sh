#!/usr/bin/env bash
# The plan step's arithmetic: turn a draft plan into the run envelope the
# Artisan approves in one go, and render it for that approval.
#
# Usage:
#   plan.sh build --draft FILE [--config FILE] [--history DIR] [--prices FILE]
#                 [--standards FILE] [--set key=value]...
#                 [--override-human-check <ticket> "<criterion>" --why TEXT]...
#                                 print the plan (JSON) for state.sh init
#   plan.sh render <plan.json>    print the approval: waves, models, estimates,
#                                 Max Agents and every config number
#
# The draft is the orchestrator's proposal: run_id, repo, integration_branch,
# scope, waves, gates, and per ticket a title, model, expected_output,
# blocked_by (required: the ticket numbers of its open blockers, [] for none) and
# expected size {input_tokens, output_tokens, minutes}. build adds:
#   config         the project config (config.sh) with this run's overrides
#   overrides      {key: {value, project}} for every --set; never written to config.yml
#   max_agents, attempts_per_ticket   from the config
#   tickets.<t>.estimate_usd, .estimate_basis, .caps
#   hands_on       when the draft has a "hands_on" object {ticket, focus, minutes?}
#                  (at most one per plan; blocked_by per ticket gives the critical
#                  path): the ticket, its focus, whether it is on the critical path
#                  and the delay it costs the run (human.sh annotate)
#   estimate_usd   the total; budget_usd = total + overrun allowance
#   human_check_flags  each criterion that reads as needing a person, from a
#                  ticket's optional `acceptance` list in the draft (which
#                  wins; its issue is then not read) or, with none, from the
#                  ticket's issue body (gh issue view, scripts/lib/criteria.py
#                  extract; the criteria then show in tickets.<t>.acceptance).
#                  An issue that can't be read (no gh, offline) leaves the
#                  build succeeding, with those tickets named on stderr
#                  as unchecked (references/human-checks.md,
#                  plus config human_check_phrases): [{ticket, criterion, phrase}].
#                  While one stands the plan is not approvable: render says so
#                  and state.sh init refuses it. Split it into a Human check
#                  (to-plan.sh split-human-check) or override it:
#   criteria_missing  the tickets with no acceptance criteria anywhere: not in
#                  the draft, the issue body or a triage "Agent Brief" comment
#                  (criteria.py ticket; body wins, then the newest comment).
#                  tickets.<t>.acceptance_source says where a read list came
#                  from ("body" or the comment's url). While one stands the
#                  plan is not approvable: render says so, state.sh init refuses.
#   human_check_overrides  [{ticket, criterion, why}], one per
#                  --override-human-check, the Artisan's reason recorded
#   recorded_checks the recorded checks (checks.sh json over --standards,
#                  default CODING_STANDARDS.md at the checkout's top):
#                  {recorded, file, commands, suite} or {recorded: false, reason}
#   suite_command, suite_source
#                  with checks recorded, a draft without suite_command gets
#                  the recorded checks' suite (checks.sh suite): "recorded";
#                  a draft naming another command keeps it as "changed", shown
#                  as a change for the Artisan to approve. With none recorded,
#                  the draft's command (and its optional suite_found, where it
#                  was found) is "discovered", shown as a fallback; no command
#                  at all is "none".
#   merge_gate     only on a machine whose merge gate runs on CI (merge-gate.sh
#                  mode): {mode: "ci", workflow, timeout_minutes,
#                  minutes_per_merge, from_runs, note?}, the expected CI
#                  minutes per merge from the gate workflow's recent runs
#                  (merge-gate.sh minutes). Absent on a local machine.
#
# Estimates, in estimated dollars:
#   history   when past merged tickets on the same model have logged costs
#             (state.json files under --history, default the project's
#             .artisan-agent/runs): their mean cost x estimate_multipliers
#             (the model's own, else "all", else 1)
#   price     otherwise: the model's price (--prices, default
#             references/model-prices.json) x the ticket's expected tokens
# Floor: an estimate below minimum_estimates (the model's own, else "all", else
# none; config, overridable with --set minimum_estimates.<model>=N) is raised to
# it before caps and totals are derived. estimate_basis then has mode "minimum",
# the minimum, the estimate it replaced and that estimate's own basis.
# Caps follow run-ticket.sh: budget twice the estimate, 40 turns per
# estimated dollar (at least 20), deadline twice the expected minutes.
#
# Exit status: 0 ok, 1 invalid draft, config or prices, 2 bad usage.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/config-lib.sh
. "$SCRIPT_DIR/lib/config-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'plan.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

runs_dir() {
  local common=
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  printf '%s/.artisan-agent/runs\n' "$(dirname "$common")"
}

# history_json dir run-id: [{model, cost}] for every merged ticket with a
# logged cost in another run's state file.
history_json() {
  local dir="$1" run_id="$2" f=
  {
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      for f in "$dir"/*/state.json; do
        [ -f "$f" ] || continue
        jq -c --arg run "$run_id" '
          select(.schema_version == 1 and .run_id != $run)
          | .plan.tickets as $pt
          | .tickets | to_entries[]
          | select(.value.status == "merged" and ((.value.cost_usd // 0) > 0)
                   and ($pt[.key].model // null) != null)
          | {model: $pt[.key].model, cost: .value.cost_usd}' "$f" 2>/dev/null || true
      done
    fi
  } | jq -s .
}

cmd_build() {
  local draft= config= history= prices="$PLUGIN_DIR/references/model-prices.json" standards=
  local sets=() cfg= hist= out= checks= suite= overrides='[]' ov= flags=
  history=$(runs_dir)
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) [ $# -ge 2 ] || usage; draft=$2; shift 2 ;;
      --config) [ $# -ge 2 ] || usage; config=$2; shift 2 ;;
      --history) [ $# -ge 2 ] || usage; history=$2; shift 2 ;;
      --prices) [ $# -ge 2 ] || usage; prices=$2; shift 2 ;;
      --standards) [ $# -ge 2 ] || usage; standards=$2; shift 2 ;;
      --set)
        [ $# -ge 2 ] || usage
        case "$2" in *=*) ;; *) die "--set needs key=value, got $2" ;; esac
        sets+=("$2"); shift 2 ;;
      --override-human-check)
        [ $# -ge 3 ] || usage
        overrides=$(jq -c --arg t "$2" --arg c "$3" '. + [{ticket: ($t | ltrimstr("#")), criterion: $c, why: ""}]' <<<"$overrides")
        shift 3 ;;
      --why)
        [ $# -ge 2 ] || usage
        [ "$(jq length <<<"$overrides")" -gt 0 ] || die "--why follows the --override-human-check it gives the reason for"
        overrides=$(jq -c --arg w "$2" '.[-1].why = $w' <<<"$overrides")
        shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$draft" ] || usage
  [ -f "$draft" ] || die "no draft: $draft"
  jq -e . "$draft" >/dev/null 2>&1 || die "draft is not JSON: $draft"
  [ -f "$prices" ] || die "no price table: $prices"

  if [ -n "$config" ]; then
    cfg=$("$SCRIPT_DIR/config.sh" show --file "$config") || exit 1
  elif git rev-parse --git-common-dir >/dev/null 2>&1; then
    cfg=$("$SCRIPT_DIR/config.sh" show) || exit 1
  else
    cfg=$("$SCRIPT_DIR/config.sh" defaults) || exit 1 # outside a repository: no project config
  fi
  hist=$(history_json "$history" "$(jq -r '.run_id // ""' "$draft")")
  # The recorded checks, read only through checks.sh.
  local where=()
  [ -z "$standards" ] || where=(--file "$standards")
  checks=$("$SCRIPT_DIR/checks.sh" json ${where[@]+"${where[@]}"}) || exit 1
  suite=$("$SCRIPT_DIR/checks.sh" suite ${where[@]+"${where[@]}"} 2>/dev/null) || suite=

  if ! out=$(jq -n --slurpfile d "$draft" --slurpfile prices "$prices" \
      --argjson cfg "$cfg" --argjson hist "$hist" --argjson checks "$checks" --arg suite "$suite" --args "$CONFIG_JQ_DEFS"'
    def round2: (. * 100 | round) / 100;
    def need($cond; $msg): if $cond then . else error($msg) end;
    $d[0] as $d | $prices[0].models as $price
    | $d
    | need(type == "object" and (.run_id | type == "string") and (.repo | type == "string")
           and (.integration_branch | type == "string") and (.scope | type == "array")
           and (.scope | length) > 0;
           "the draft needs run_id, repo, integration_branch and a non-empty scope")
    | .scope |= map(tostring)
    | .waves = ((.waves // []) | map(map(tostring)))
    | . as $plan
    | need(([.waves[][] | select(. as $t | $plan.scope | index($t) | not)] | length) == 0;
           "waves name tickets outside the scope: \([.waves[][] | select(. as $t | $plan.scope | index($t) | not)] | join(", "))")
    # The run config: the project config with each --set applied in turn.
    | .config = $cfg | .overrides = {}
    | .max_agents = .config.max_agents | .attempts_per_ticket = .config.attempts_per_ticket
    | reduce ($ARGS.positional[] | capture("^(?<k>[^=]+)=(?<v>.*)$")) as $s
        (.; run_override($s.k; $s.v | parse_value))
    | .tickets = (.tickets // {})
    | reduce .scope[] as $t (.;
        (.tickets[$t] // error("ticket \($t) is in scope but has no entry in tickets")) as $tk
        | ($tk.model // error("ticket \($t) has no model")) as $m
        | need(($tk.blocked_by | type) == "array";
               "ticket \($t) has no blocked_by (the open blockers resolve-scope.sh returned; [] for none)")
        | ($tk.expected // {}) as $x
        | need(($x.minutes | type) == "number" and $x.minutes > 0;
               "ticket \($t) needs expected.minutes")
        | [$hist[] | select(.model == $m) | .cost] as $past
        | (if ($past | length) > 0 then
             ((.config.estimate_multipliers[$m] // .config.estimate_multipliers.all // 1)) as $mult
             | ($past | add / length) as $mean
             | {usd: ($mean * $mult),
                basis: {mode: "history", tickets: ($past | length), mean_usd: ($mean | round2), multiplier: $mult}}
           else
             ($price[$m] // error("no price for model \($m); add it to the price table")) as $p
             | need(($x.input_tokens | type) == "number" and ($x.output_tokens | type) == "number";
                    "ticket \($t) needs expected.input_tokens and expected.output_tokens (no history for \($m))")
             | {usd: ($x.input_tokens / 1000000 * $p.input_per_mtok + $x.output_tokens / 1000000 * $p.output_per_mtok),
                basis: {mode: "price", input_per_mtok: $p.input_per_mtok, output_per_mtok: $p.output_per_mtok,
                        input_tokens: $x.input_tokens, output_tokens: $x.output_tokens}}
           end) as $e
        | ((.config.minimum_estimates[$m] // .config.minimum_estimates.all // 0) | round2) as $min
        | (if ($e.usd | round2) < $min
           then {usd: $min, basis: {mode: "minimum", model: $m, minimum_usd: $min,
                                    estimated_usd: ($e.usd | round2), was: $e.basis}}
           else $e end) as $e
        | ([$e.usd | round2, 0.01] | max) as $usd
        | .tickets[$t] = ($tk + {
            estimate_usd: $usd,
            estimate_basis: $e.basis,
            caps: {
              max_budget_usd: ($usd * 2 | round2),
              max_turns: ([$usd * 40 | ceil, 20] | max),
              deadline_seconds: ($x.minutes * 120 | ceil)
            }
          }))
    | .estimate_usd = ([.scope[] as $t | .tickets[$t].estimate_usd] | add | round2)
    | .budget_usd = (.estimate_usd * (1 + .config.overrun_allowance_percent / 100) | round2)
    # The suite: the recorded checks unless the draft changes it, visibly.
    | .recorded_checks = ({recorded: $checks.recorded, file: $checks.file, commands: [$checks.checks[].command]}
                 + (if $checks.recorded then {suite: $suite} else {reason: $checks.reason} end))
    | (.suite_command // "") as $s
    | if $checks.recorded then
        if $s == "" or $s == $suite then .suite_command = $suite | .suite_source = "recorded"
        else .suite_source = "changed" end
      elif $s == "" then .suite_command = null | .suite_source = "none"
      else .suite_source = "discovered" end
  ' ${sets[@]+"${sets[@]}"} 2>&1); then
    die "$(printf '%s' "$out" | sed 's/^jq: error[^:]*: //; s/ (at <unknown>)$//')"
  fi
  # On a CI machine, what each merge's gate costs in CI time (#139).
  local gate= wf= mins=
  gate=$("$SCRIPT_DIR/merge-gate.sh" mode) || exit 1
  if [ "$gate" = ci ]; then
    wf=$(printf '%s' "$out" | jq -r '.config.ci_gate.workflow // empty')
    mins='{"runs": 0, "minutes": null}'
    if [ -n "$wf" ]; then
      mins=$("$SCRIPT_DIR/merge-gate.sh" minutes --repo "$(jq -r '.repo' "$draft")" --workflow "$wf" 2>/dev/null) \
        || mins='{"runs": 0, "minutes": null, "note": "the gate workflow'"'"'s runs could not be read"}'
    fi
    out=$(printf '%s' "$out" | jq --argjson m "$mins" --arg wf "$wf" '.merge_gate = ({mode: "ci",
      workflow: (if $wf == "" then null else $wf end), timeout_minutes: .config.ci_gate.timeout_minutes,
      minutes_per_merge: $m.minutes, from_runs: $m.runs} + (if $m.note then {note: $m.note} else {} end))')
  fi
  # A ticket the draft gives no `acceptance` list gets its criteria from its
  # issue body (criteria.py extract); a draft's own list wins and its issue is
  # not read. Tickets whose issue can't be read are named on stderr.
  local repo="" t="" issue="" tc="" unchecked=""
  repo=$(jq -r '.repo // ""' "$draft")
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    issue=""
    if [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
      issue=$(gh issue view "$t" -R "$repo" --json body,comments 2>/dev/null) || issue=""
    fi
    if [ -z "$issue" ] || ! tc=$(printf '%s\n' "$issue" | python3 -I "$SCRIPT_DIR/lib/criteria.py" ticket 2>/dev/null); then
      unchecked="${unchecked:+$unchecked, }#$t"
      continue
    fi
    out=$(printf '%s' "$out" | jq --arg t "$t" --argjson c "$tc" '.tickets[$t].acceptance = $c.criteria
      | .tickets[$t].acceptance_source = $c.source')
  done < <(printf '%s' "$out" | jq -r '.tickets | to_entries[] | select(.value.acceptance == null and (.value.human_check_for // null) == null) | .key')
  if [ -n "$unchecked" ]; then
    printf 'plan.sh: could not read the issue for %s: those tickets'"'"' criteria were not checked for Human check flags\n' "$unchecked" >&2
  fi
  # A ticket that still has no criteria (neither the draft, the body nor an
  # Agent Brief comment gave any) can't be verified: the plan isn't approvable.
  out=$(printf '%s' "$out" | jq '.criteria_missing = [.tickets | to_entries[]
    | select((.value.human_check_for // null) == null and .value.acceptance != null and (.value.acceptance | length) == 0) | .key]')
  # Agent criteria that need a person (references/human-checks.md), less the
  # Artisan's overrides.
  ov='[]'
  if [ "$(jq length <<<"$overrides")" -gt 0 ]; then
    ov=$(printf '%s' "$out" | python3 -I "$SCRIPT_DIR/lib/to-plan.py" overrides "$overrides" 2>&1) \
      || die "$(printf '%s' "$ov" | sed 's/^to-plan: //')"
  fi
  out=$(printf '%s' "$out" | jq --argjson ov "$ov" '.human_check_overrides = $ov')
  flags=$(printf '%s' "$out" | TO_PLAN_EXTRA_PHRASES=$(printf '%s' "$out" | jq -c '.config.human_check_phrases // []') \
    python3 -I "$SCRIPT_DIR/lib/to-plan.py" flags 2>&1) || die "$(printf '%s' "$flags" | sed 's/^to-plan: //')"
  out=$(printf '%s' "$out" | jq --argjson f "$flags" '.human_check_flags = $f')
  # The draft's one hands-on ticket, if it names one (human.sh annotate).
  if [ "$(jq -r '.hands_on != null' "$draft")" = true ]; then
    out=$(printf '%s' "$out" | "$SCRIPT_DIR/human.sh" annotate --draft "$draft") || exit 1
  fi
  printf '%s\n' "$out"
}

cmd_render() {
  local plan="$1"
  [ -f "$plan" ] || die "no plan: $plan"
  jq -r "$CONFIG_JQ_DEFS"'
    def money: "$" + (. * 100 | round | tostring | if length < 3 then ("00" + .)[-3:] else . end
                      | .[:-2] + "." + .[-2:]);
    def ticket($t): "#\($t)";
    . as $p
    | ($p.overrides // {}) as $ov
    | ([$p.waves[][]] ) as $waved
    | ($p.waves + (if ([$p.scope[] | select(. as $t | $waved | index($t) | not)] | length) > 0
                   then [[$p.scope[] | select(. as $t | $waved | index($t) | not)]] else [] end)) as $waves
    | "## Run \($p.run_id): approve scope, plan and numbers together",
      "",
      "Scope: \($p.scope | map(ticket(.) + " (" + ($p.tickets[.].title // "untitled") + ")") | join(", ")). Anything else waits.",
      "",
      ( $waves | to_entries[]
        | (.key + 1) as $w
        | "### Wave \($w)",
          "| Ticket | Model | Estimate | From | Expected output | Expected files |",
          "|---|---|---|---|---|---|",
          ( .value[] as $t | $p.tickets[$t] as $tk
            | "| \(ticket($t)) (\($tk.title // "untitled")) | \($tk.model) | \($tk.estimate_usd | money) | "
              + (if $tk.estimate_basis.mode == "minimum"
                 then "minimum for \($tk.estimate_basis.model) (estimated \($tk.estimate_basis.estimated_usd | money))"
                 elif $tk.estimate_basis.mode == "history"
                 then "history: \($tk.estimate_basis.tickets) merged ticket(s), mean \($tk.estimate_basis.mean_usd | money) x \($tk.estimate_basis.multiplier)"
                 else "price: \($tk.estimate_basis.input_tokens) in / \($tk.estimate_basis.output_tokens) out tokens" end)
              + " | \($tk.expected_output // "") | "
              + (if ($tk.expected_files // []) == [] then "none declared"
                 else ($tk.expected_files | map("`" + . + "`") | join(", ")) end) + " |" ),
          ( [.value[] | select(($p.tickets[.].expected_files // []) == [])] as $bare
            | if ($bare | length) > 0 then "" else empty end ),
          ( .value[] as $t | select(($p.tickets[$t].expected_files // []) == [])
            | "\(ticket($t)) runs alone: no expected files, so it'"'"'s treated as touching everything. Name its files to let it share a wave." ),
          "" ),
      ( $p.hands_on // null | if . == null then empty else
        "### Hands-on ticket",
        "| Ticket | Focus | Critical path | Delay to the run |",
        "|---|---|---|---|",
        "| \(ticket(.ticket)) (\($p.tickets[.ticket].title // "untitled")) | \(.focus) | \(if .on_critical_path then "yes" else "no (slack \(.slack_minutes) min)" end) | \(if .delay_minutes > 0 then "about \(.delay_minutes) min later" else "none" end) |",
        "",
        (if .delay_minutes > 0 then "Building this by hand delays the run\(if .on_critical_path then " (it is on the critical path)" else " (its hands-on time exceeds its slack)" end): the run finishes about \(.delay_minutes) minutes later, and \(.dependents | map(ticket(.)) | join(", ") | if . == "" then "nothing" else . end) waits for it. Confirm the delay, or choose a ticket off the critical path." else "\(if .on_critical_path then "On the critical path, but no delay is expected" else "Off the critical path" end): the run is not delayed. It is held without dispatch, built in its own worktree, and goes through the same verifier, suite and merge as a worker'"'"'s ticket." end),
        "" end),
      ( ($p.human_check_flags // []) | if length == 0 then empty else
        "### Needs your attention",
        "| Ticket | Criterion | Reads as needing a person |",
        "|---|---|---|",
        ( .[] | "| \(ticket(.ticket)) (\($p.tickets[.ticket].title // "untitled")) | \(.criterion) | \"\(.phrase)\" |" ),
        "",
        "An agent can'"'"'t show these, so the verifier could never pass them. Split each into a Human check (`to-plan.sh split-human-check`), or override it with a reason (`--override-human-check <ticket> \"<criterion>\" --why ...` on the build). Not approvable while one stands.",
        "" end ),
      ( ($p.criteria_missing // []) | if length == 0 then empty else
        "### Tickets with no acceptance criteria",
        "| Ticket |",
        "|---|",
        ( .[] | "| \(ticket(.)) (\($p.tickets[.].title // "untitled")) |" ),
        "",
        "Neither the ticket body nor a triage Agent Brief comment has a checkbox list of acceptance criteria, so the verifier would have nothing to check. Add a `## Acceptance criteria` checklist to each ticket, then rebuild. Not approvable while one stands.",
        "" end ),
      ( ($p.human_check_overrides // []) | if length == 0 then empty else
        "### Human-check overrides",
        "| Ticket | Criterion kept on the agent ticket | Why |",
        "|---|---|---|",
        ( .[] | "| \(ticket(.ticket)) | \(.criterion) | \(.why) |" ),
        "" end ),
      "Total estimate: \($p.estimate_usd | money). Budget (estimate + \($p.config.overrun_allowance_percent)% overrun allowance): \($p.budget_usd | money).",
      "Max Agents: \($p.max_agents). Gates: \(if ($p.gates // []) == [] then "none" else ($p.gates | map(tojson) | join(", ")) end).",
      "",
      "### Suite command",
      ( (($p.recorded_checks.commands // []) | map("`" + . + "`") | join(", ")) as $rec
      | if $p.suite_source == "recorded" then
           "`\($p.suite_command)`: the recorded checks (\($rec), from `CODING_STANDARDS.md` `## Checks`), run after every merge."
         elif $p.suite_source == "changed" then
           "**Changed from the recorded checks:** this run'"'"'s suite is `\($p.suite_command)`; the recorded checks (\($rec)) run `\($p.recorded_checks.suite)`. Approve the change, or drop it to run the recorded checks."
         elif $p.suite_source == "discovered" then
           "`\($p.suite_command)`. No recorded checks (\($p.recorded_checks.reason)): found `\($p.suite_command)`\(if $p.suite_found then " in \($p.suite_found)" else "" end). Nothing has proven it can fail; setup'"'"'s checks question records proven ones."
         elif $p.suite_source == "none" then
           "**None.** No recorded checks (\($p.recorded_checks.reason)) and the draft names no suite; every merge needs one, so name it before approving."
         else "`\($p.suite_command // "none")`" end ),
      "",
      ( $p.merge_gate // null | if . == null or .mode != "ci" then empty else
        "### Merge gate: on CI",
        (if .workflow == null then
           "**No gate workflow recorded.** This machine runs no suite after a merge, so with no gate workflow (`ci_gate.workflow` in `.artisan-agent/config.yml`) nothing can merge. Record one through project setup, or set this machine'"'"'s `merge_gate` to `local`."
         else
           "Each merge runs no suite here: it waits for `\(.workflow)` on a throwaway `ci/*` branch, and parks the run after \(.timeout_minutes) minutes without a conclusion. "
           + (if .minutes_per_merge == null
              then "Expected CI time per merge: unknown (\(.note // "no completed runs of `\(.workflow)` to measure"))."
              else "Expected CI time: about \(.minutes_per_merge) minutes per merge (mean of its last \(.from_runs) completed runs), about \(.minutes_per_merge * ($p.scope | length) | ceil) minutes for this run'"'"'s \($p.scope | length) merges." end)
         end),
        "" end ),
      "### Every number this run uses",
      "| Setting | Value |",
      "|---|---|",
      ( $p.config | settings_list[] | .key as $k
        | "| \(.key) | \(if .value == null then "none" else .value end)\(if $ov | has($k) then " (this run only; project: \($ov[$k].project | if . == null then "none" else tostring end))" else "" end) |" ),
      "",
      (if ($p.criteria_missing // []) != [] then "Not approvable yet: \($p.criteria_missing | length) ticket(s) with no acceptance criteria (above)."
       elif ($p.human_check_flags // []) == [] then "Approve as shown, or name any number to change for this run only."
       else "Not approvable yet: \($p.human_check_flags | length) criteria need a person (above)." end)
  ' "$plan"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  build) cmd_build "$@" ;;
  render) [ $# -eq 1 ] || usage; cmd_render "$1" ;;
  *) usage ;;
esac
