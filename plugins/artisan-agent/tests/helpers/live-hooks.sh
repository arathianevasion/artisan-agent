# Shared by the live harnesses (tests/live-run, live-drain, implement,
# questions-live): run a headless `claude -p` with the plugin's hooks active
# and the Artisan's user settings out (#105).
#
# Why not `--setting-sources project,local` plus `--plugin-dir`: Claude Code
# 2.1.322 then loads the plugin's skills but never runs its hooks. So the hooks
# are registered by a throwaway settings file passed with --settings (a source
# that is always read), and the session reads only project and local settings.
# The hook scripts are the plugin's own; hooks.json is copied with
# ${CLAUDE_PLUGIN_ROOT} replaced by the plugin's path. Nothing is installed or
# written outside the directory given.
#
# Source this file, then:
#   live_hooks_args <plugin-root> <dir>   prints the flags to add to claude -p
#                                         (no spaces in either path)
#   live_hooks_proof_check <proof-file>   0 if a plugin hook fired, else 1
# and export ARTISAN_HOOK_PROOF=<proof-file> before the session starts: the
# plugin's SessionStart hook (scripts/compact-hook.sh) appends a line to it.
# Portable to bash 3.2 (macOS).

live_hooks_args() { # plugin-root dir
  local root=$1 dir=$2
  mkdir -p "$dir" || return 1
  sed "s#\${CLAUDE_PLUGIN_ROOT}#$root#g" "$root/hooks/hooks.json" >"$dir/plugin-hooks.settings.json" || return 1
  printf '%s' "--setting-sources project,local --settings $dir/plugin-hooks.settings.json"
}

live_hooks_proof_check() { # proof-file
  [ -s "$1" ] && grep -q '^session-start ' "$1"
}
