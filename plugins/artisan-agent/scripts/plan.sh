#!/usr/bin/env bash
# The plan step's arithmetic: turn a draft plan into the run envelope the
# Artisan approves in one go, and render it for that approval.
#
# Usage:
#   plan.sh build --draft FILE [--config FILE] [--history DIR] [--prices FILE]
#                 [--set key=value]...
#                                 print the plan (JSON) for state.sh init
#   plan.sh render <plan.json>    print the approval: waves, models, estimates,
#                                 Max Agents and every config number
#
# The draft is the orchestrator's proposal: run_id, repo, integration_branch,
# scope, waves, gates, and per ticket a title, model, expected_output and
# expected size {input_tokens, output_tokens, minutes}. build adds:
#   config         the project config (config.sh) with this run's overrides
#   overrides      {key: {value, project}} for every --set; never written to config.yml
#   max_agents, attempts_per_ticket   from the config
#   tickets.<t>.estimate_usd, .estimate_basis, .caps
#   estimate_usd   the total; budget_usd = total + overrun allowance
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
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  printf '%s/.artisan-agent/runs\n' "$(dirname "$common")"
}

# history_json dir run-id: [{model, cost}] for every merged ticket with a
# logged cost in another run's state file.
history_json() {
  local dir="$1" run_id="$2" f
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
  local draft= config= history= prices="$PLUGIN_DIR/references/model-prices.json"
  local sets=() cfg hist out
  history=$(runs_dir)
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) [ $# -ge 2 ] || usage; draft=$2; shift 2 ;;
      --config) [ $# -ge 2 ] || usage; config=$2; shift 2 ;;
      --history) [ $# -ge 2 ] || usage; history=$2; shift 2 ;;
      --prices) [ $# -ge 2 ] || usage; prices=$2; shift 2 ;;
      --set)
        [ $# -ge 2 ] || usage
        case "$2" in *=*) ;; *) die "--set needs key=value, got $2" ;; esac
        sets+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$draft" ] || usage
  [ -f "$draft" ] || die "no draft: $draft"
  jq -e . "$draft" >/dev/null 2>&1 || die "draft is not JSON: $draft"
  [ -f "$prices" ] || die "no price table: $prices"

  if [ -n "$config" ]; then
    cfg=$("$SCRIPT_DIR/config.sh" show --file "$config") || exit 1
  else
    cfg=$("$SCRIPT_DIR/config.sh" show) || exit 1
  fi
  hist=$(history_json "$history" "$(jq -r '.run_id // ""' "$draft")")

  if ! out=$(jq -n --slurpfile d "$draft" --slurpfile prices "$prices" \
      --argjson cfg "$cfg" --argjson hist "$hist" --args "$CONFIG_JQ_DEFS"'
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
  ' ${sets[@]+"${sets[@]}"} 2>&1); then
    die "$(printf '%s' "$out" | sed 's/^jq: error[^:]*: //; s/ (at <unknown>)$//')"
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
      "Total estimate: \($p.estimate_usd | money). Budget (estimate + \($p.config.overrun_allowance_percent)% overrun allowance): \($p.budget_usd | money).",
      "Max Agents: \($p.max_agents). Gates: \(if ($p.gates // []) == [] then "none" else ($p.gates | map(tojson) | join(", ")) end).",
      "",
      "### Every number this run uses",
      "| Setting | Value |",
      "|---|---|",
      ( $p.config | settings_list[] | .key as $k
        | "| \(.key) | \(if .value == null then "none" else .value end)\(if $ov | has($k) then " (this run only; project: \($ov[$k].project | if . == null then "none" else tostring end))" else "" end) |" ),
      "",
      "Approve as shown, or name any number to change for this run only."
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
