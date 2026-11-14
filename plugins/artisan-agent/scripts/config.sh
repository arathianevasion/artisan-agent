#!/usr/bin/env bash
# Read the project config, .artisan-agent/config.yml, with every missing key
# filled from its default. The settings and defaults: ${CLAUDE_PLUGIN_ROOT}/templates/config.yml.
#
# Usage:
#   config.sh show [--file FILE]          the effective config as JSON
#   config.sh get <key> [--file FILE]     one setting (dotted key, such as context.drain_percent)
#   config.sh defaults                    the defaults as JSON
#   config.sh path                        where the project config is read from
#
# The project config is <main checkout>/.artisan-agent/config.yml, or FILE.
# A missing file means every default. A key left out or left empty falls back
# to its default; a value of the wrong type is refused. This script never
# writes the file: a run's overrides live in its state file (state.sh override).
#
# Exit status: 0 ok, 1 unreadable or invalid config, 2 bad usage.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/config-lib.sh
. "$SCRIPT_DIR/lib/config-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'config.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

# resolve_project_path: sets PROJECT_PATH. Never call it inside $(...): die
# would only exit that subshell and the caller would carry on with an empty path.
PROJECT_PATH=
resolve_project_path() {
  local common=""
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository; pass --file"
  PROJECT_PATH="$(dirname "$common")/.artisan-agent/config.yml"
}

defaults_json() {
  config_yaml_json "$CONFIG_TEMPLATE" || die "unreadable defaults: $CONFIG_TEMPLATE"
}

# effective_json file
effective_json() {
  local file="$1" defaults= project= out=
  defaults=$(defaults_json)
  if [ -f "$file" ]; then
    project=$(config_yaml_json "$file") || exit 1
  else
    project='{}'
  fi
  if out=$(jq -n --argjson d "$defaults" --argjson p "$project" \
    "$CONFIG_JQ_DEFS"'$p | effective($d)' 2>&1); then
    printf '%s\n' "$out"
  else
    die "$file: $(printf '%s' "$out" | sed 's/^jq: error[^:]*: //; s/ (at <unknown>)$//')"
  fi
}

[ $# -ge 1 ] || usage
cmd=$1
shift
file= key=
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || usage; file=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$key" ] || usage; key=$1; shift ;;
  esac
done

case "$cmd" in
  show)
    [ -z "$key" ] || usage
    [ -n "$file" ] || { resolve_project_path; file=$PROJECT_PATH; }
    effective_json "$file"
    ;;
  get)
    [ -n "$key" ] || usage
    [ -n "$file" ] || { resolve_project_path; file=$PROJECT_PATH; }
    effective_json "$file" \
      | jq -e --arg k "$key" '($k | split(".")) as $p | if [paths] | index([$p]) then getpath($p) else error("no setting \($k)") end' 2>/dev/null \
      || die "no setting $key"
    ;;
  defaults)
    [ -z "$key" ] && [ -z "$file" ] || usage
    defaults_json | jq -S .
    ;;
  path)
    [ -z "$key" ] && [ -z "$file" ] || usage
    resolve_project_path
    printf '%s\n' "$PROJECT_PATH"
    ;;
  *) usage ;;
esac
