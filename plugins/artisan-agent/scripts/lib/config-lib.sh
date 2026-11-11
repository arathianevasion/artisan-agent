# Shared definitions for the project config (config.sh, plan.sh, state.sh).
# Sourced, never run. The settings and their defaults are written once, in
# ${CLAUDE_PLUGIN_ROOT}/templates/config.yml.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq and python3.

CONFIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_TEMPLATE="$CONFIG_LIB_DIR/../../templates/config.yml"

# config_yaml_json file: the file as JSON on stdout (the plain YAML subset in
# lib/yaml-subset.py). Fails with the offending line on stderr.
config_yaml_json() {
  python3 -I "$CONFIG_LIB_DIR/yaml-subset.py" "$1"
}

# jq definitions shared by every reader and writer of config numbers.
#   effective($defaults): the project config (.) merged over the defaults.
#     A missing or empty key falls back to its default; a value of the wrong
#     type is an error naming the key.
#   override($key; $value): the effective config (.) with one setting changed
#     for this run. The key must be a setting (a dotted path to a number,
#     true/false or text), or a model under estimate_multipliers; the value
#     must have the setting's type. Errors name what is wrong.
#   run_override($key; $value): a plan, or the plan in a state file (.), with one
#     setting overridden for this run: .config changed, .overrides[$key] =
#     {value, project} (project: the value before this run touched it), and
#     max_agents and attempts_per_ticket kept in step with the config.
#   parse_value: a command-line string as a number, true/false, null or text.
#   settings_list: every setting as [{key, value}], keys dotted, in file order.
CONFIG_JQ_DEFS='
  def strip_nulls: if type == "object" then with_entries(select(.value != null) | .value |= strip_nulls) else . end;
  def leaves: paths(type != "object" and type != "array");
  def kind: if type == "null" or type == "string" then "text" elif type == "boolean" then "true/false" else type end;
  def check_against($d; $path):
    . as $v
    | if ($d | type) == "object" and ($path | length) > 0 and ($path[-1] == "areas") then
        (if ($v | type) == "object" then . else error("areas must be a map of named path sets") end)
      elif ($path == ["estimate_multipliers"]) then
        (if ($v | type) != "object" then error("estimate_multipliers must be a map of model to number")
         elif ([$v[] | select(type != "number" or . <= 0)] | length) > 0 then error("estimate_multipliers values must be positive numbers")
         else . end)
      elif ($d | type) == "object" then
        (if ($v | type) != "object" then error("\($path | join(".")) must be a map")
         else reduce ($v | keys_unsorted[]) as $k ($v;
           if $d | has($k) then .[$k] |= check_against($d[$k]; $path + [$k]) else . end) end)
      elif ($d | kind) != ($v | kind) then
        error("\($path | join(".")) must be \($d | kind), not \($v | kind)")
      elif ($v | type) == "number" and $v < 0 then
        error("\($path | join(".")) must not be negative")
      else . end;
  def effective($defaults): ($defaults * (. // {} | strip_nulls)) | check_against($defaults; []);
  def parse_value:
    if test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber
    elif . == "true" then true elif . == "false" then false
    elif . == "null" or . == "" then null else . end;
  def override($key; $value):
    ($key | split(".")) as $p
    | if ($p | length) == 2 and $p[0] == "estimate_multipliers" then
        (if ($value | type) == "number" and $value > 0 then setpath($p; $value)
         else error("estimate_multipliers.\($p[1]) must be a positive number") end)
      elif ([leaves] | index([$p])) == null then
        error("\($key) is not a setting; settings are: \([leaves | join(".")] | join(", "))")
      elif (getpath($p) | kind) != ($value | kind) then
        error("\($key) must be \(getpath($p) | kind), not \($value | kind)")
      elif ($value | type) == "number" and $value < 0 then error("\($key) must not be negative")
      else setpath($p; $value) end;
  def run_override($key; $value):
    (.config | getpath($key | split("."))) as $was
    | .config |= override($key; $value)
    | .overrides = ((.overrides // {}) | .[$key] = {value: $value,
        project: (if has($key) then .[$key].project else $was end)})
    | .max_agents = .config.max_agents
    | .attempts_per_ticket = .config.attempts_per_ticket;
  def settings_list:
    . as $c
    | [leaves | select(.[0] != "areas" and .[0] != "estimate_multipliers")
       | {key: join("."), value: (. as $p | $c | getpath($p))}]
    + (if ($c.areas | length) == 0 then [{key: "areas", value: "none"}]
       else [$c.areas | to_entries[] | {key: "areas.\(.key)", value: (.value | tojson)}] end)
    + (if ($c.estimate_multipliers | length) == 0 then [{key: "estimate_multipliers", value: "none"}]
       else [$c.estimate_multipliers | to_entries[] | {key: "estimate_multipliers.\(.key)", value: .value}] end);
'
