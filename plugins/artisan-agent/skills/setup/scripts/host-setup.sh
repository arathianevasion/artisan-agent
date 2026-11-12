#!/usr/bin/env bash
# Host mode of /artisan-agent:setup: prepare the always-on machine (a Mac left on,
# else a small Linux VM) so runs carry on with the laptop closed (#69).
# Walkthrough and reasons: ${CLAUDE_PLUGIN_ROOT}/skills/setup/HOST.md
#
# Usage:
#   host-setup.sh check                         tools the host needs (claude, git, gh, jq, tmux, perl)
#   host-setup.sh apply [--workdir D] [--name N] [--load]
#       settings: remoteControlAtStartup and agentPushNotifEnabled on, in
#       <config>/settings.json (existing keys kept); the supervisor: a launcher
#       script that keeps `claude remote-control --spawn worktree` alive in a
#       tmux session, run at login/boot by a launchd agent (macOS) or a systemd
#       user unit + timer (Linux), written but loaded only with --load;
#       host.json in the individual home (only apply writes it). A file that differs from what it
#       would write is kept ("kept:"), never overwritten.
#   host-setup.sh trust DIR                     is DIR's workspace trust granted? (exit 0 trusted, 1 not)
#   host-setup.sh gh                            are gh credentials present? (exit 0, 1)
#   host-setup.sh mark [--repo D]               set host_configured: true in D's .artisan-agent/config.yml
#   host-setup.sh status [--workdir D]          one line per piece, "ok:" or "todo:"; exit 0 only if all are ok
#
# Workspace trust and the claude.ai login are granted interactively, once: this
# script reads them (`trust`, `status`, login-check.sh) and says how; it cannot
# grant them. Lines starting `changed:` are what it did, `unchanged:` a rerun.
#
# Environment: CLAUDE_CONFIG_DIR (default ~/.claude), ARTISAN_HOME, HOME (the
# service files go under it), ARTISAN_CLAUDE_BIN (the claude to supervise),
# ARTISAN_HOST_OS (macos|linux, for tests).
# Exit status: 0 ok, 1 something missing or failed, 2 usage.
#
# Portable to bash 3.2 (macOS) and Linux. Needs jq.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOME_DIR=${ARTISAN_HOME:-$CFG/artisan-agent}
HOST_DIR="$HOME_DIR/host"
SESSION=artisan-host
CLAUDE_BIN=${ARTISAN_CLAUDE_BIN:-claude}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || { echo "missing: jq - install it (macOS: brew install jq; Debian/Ubuntu: apt install jq)"; exit 1; }; }
host_os() {
  if [ -n "${ARTISAN_HOST_OS:-}" ]; then printf '%s\n' "$ARTISAN_HOST_OS"
  elif [ "$(uname -s)" = Darwin ]; then echo macos; else echo linux; fi
}

# write_file path mode: stdin to path unless it already has exactly that content.
# A file that differs is kept, never overwritten.
write_file() {
  local path="$1" mode="$2" tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [ -f "$path" ]; then
    if cmp -s "$tmp" "$path"; then echo "unchanged: $path"; else echo "kept: $path differs from what host mode writes; left alone (delete it to have it rewritten)"; fi
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  mv "$tmp" "$path"
  chmod "$mode" "$path"
  echo "changed: wrote $path"
}

cmd_check() {
  local missing=0 t hint
  for t in claude git gh jq tmux perl; do
    command -v "$t" >/dev/null 2>&1 && continue
    case "$t" in
      claude) hint="install Claude Code" ;;
      tmux) hint="macOS: brew install tmux; Debian/Ubuntu: apt install tmux" ;;
      gh) hint="https://cli.github.com" ;;
      *) hint="install $t" ;;
    esac
    echo "missing: $t - $hint"
    missing=1
  done
  [ "$missing" = 1 ] || echo "ok: claude, git, gh, jq, tmux and perl are available"
  return "$missing"
}

set_settings() { # <config>/settings.json: two booleans on, other keys kept
  local f="$CFG/settings.json" tmp
  mkdir -p "$CFG"
  [ -f "$f" ] || echo '{}' >"$f"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "failed: $f is not a JSON object; fix it and rerun"; return 1; }
  if jq -e '.remoteControlAtStartup == true and .agentPushNotifEnabled == true' "$f" >/dev/null; then
    echo "unchanged: remoteControlAtStartup and agentPushNotifEnabled are on in $f"
    return 0
  fi
  tmp="$f.tmp.$$"
  jq '.remoteControlAtStartup = true | .agentPushNotifEnabled = true' "$f" >"$tmp" && mv -f "$tmp" "$f"
  echo "changed: remoteControlAtStartup and agentPushNotifEnabled on in $f"
}

launcher_path() { printf '%s/start-remote-control.sh\n' "$HOST_DIR"; }

write_launcher() { # workdir name
  local workdir="$1" name="$2"
  write_file "$(launcher_path)" 755 <<EOF
#!/usr/bin/env bash
# Keeps Remote Control in server mode alive in tmux (written by host-setup.sh).
# Safe to run any number of times: it starts the session only when it is gone.
# Sessions spawn in worktrees; headless workers have nobody to ask, so a
# permission prompt they hit is denied.
export PATH="\$PATH:/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin"
export CLAUDE_CONFIG_DIR="$CFG"
tmux has-session -t $SESSION 2>/dev/null && exit 0
cd "$workdir" || exit 1
exec tmux new-session -d -s $SESSION "$CLAUDE_BIN remote-control --spawn worktree --name '$name'"
EOF
}

write_service() { # supervisor files for this OS
  local l os
  l=$(launcher_path)
  os=$(host_os)
  if [ "$os" = macos ]; then
    write_file "$HOME/Library/LaunchAgents/com.artisan-agent.host.plist" 644 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.artisan-agent.host</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$l</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
EOF
  else
    write_file "$HOME/.config/systemd/user/artisan-agent-host.service" 644 <<EOF
[Unit]
Description=Artisan Agent host: Remote Control server in tmux

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/bin/bash $l

[Install]
WantedBy=default.target
EOF
    write_file "$HOME/.config/systemd/user/artisan-agent-host.timer" 644 <<EOF
[Unit]
Description=Keep the Artisan Agent host session alive

[Timer]
OnBootSec=30
OnUnitActiveSec=5min
Unit=artisan-agent-host.service

[Install]
WantedBy=timers.target
EOF
  fi
}

load_service() {
  if [ "$(host_os)" = macos ]; then
    launchctl bootout "gui/$(id -u)/com.artisan-agent.host" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.artisan-agent.host.plist" && echo "changed: loaded the launchd agent"
  else
    systemctl --user daemon-reload && systemctl --user enable --now artisan-agent-host.timer && echo "changed: enabled the systemd timer"
    echo "todo: for the timer to run with nobody logged in, run once: sudo loginctl enable-linger $(id -un)"
  fi
}

cmd_apply() {
  local workdir="$PWD" name="" load=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir) [ $# -ge 2 ] || usage; workdir=$2; shift 2 ;;
      --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
      --load) load=1; shift ;;
      *) usage ;;
    esac
  done
  need_jq
  [ -d "$workdir" ] || { echo "failed: no such directory: $workdir"; exit 1; }
  workdir=$(cd "$workdir" && pwd)
  [ -n "$name" ] || name="artisan-host-$(hostname -s 2>/dev/null || echo host)"
  set_settings
  write_launcher "$workdir" "$name"
  write_service
  mkdir -p "$HOME_DIR"
  # host.json is "this machine is the host": only this writes it (#108).
  local cur=$HOME_DIR/host.json new="$HOME_DIR/host.json.tmp.$$"
  { if [ -f "$cur" ]; then cat "$cur"; else echo '{}'; fi; } | jq --arg w "$workdir" --arg n "$name" --arg s "$SESSION" '.workdir = $w | .name = $n | .tmux_session = $s | .configured = true' >"$new"
  if [ -f "$cur" ] && cmp -s "$new" "$cur"; then rm -f "$new"; echo "unchanged: host record $cur"
  else mv -f "$new" "$cur"; echo "changed: host record $cur (workdir $workdir)"; fi
  [ "$load" = 0 ] || load_service
  [ "$load" = 1 ] || echo "todo: load the supervisor once: host-setup.sh apply --load (it survives a reboot from then on)"
  echo "todo: grant workspace trust once, interactively: cd $workdir && claude (accept the trust prompt), then host-setup.sh trust $workdir"
  echo "todo: log in once (claude auth login), then record it: $PLUGIN_ROOT/scripts/login-check.sh stamp"
}

cmd_trust() { # DIR
  local dir="${1:-}" f
  [ -n "$dir" ] || usage
  [ -d "$dir" ] || { echo "todo: no such directory: $dir"; return 1; }
  dir=$(cd "$dir" && pwd -P)
  f="$CFG/.claude.json"
  [ -f "$f" ] || f="$HOME/.claude.json"
  if [ -f "$f" ] && jq -e --arg d "$dir" '.projects[$d].hasTrustDialogAccepted == true' "$f" >/dev/null 2>&1; then
    echo "ok: $dir is trusted"
    return 0
  fi
  echo "todo: $dir is not trusted yet: run claude there once and accept the trust prompt"
  return 1
}

cmd_gh() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then echo "ok: gh credentials present"; return 0; fi
  echo "todo: gh has no credentials: run gh auth login (or set GH_TOKEN for the supervisor's environment)"
  return 1
}

cmd_mark() {
  local repo="$PWD" common cfgfile
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "failed: not inside a git repository: $repo"; exit 1; }
  cfgfile="$(dirname "$common")/.artisan-agent/config.yml"
  mkdir -p "$(dirname "$cfgfile")"
  if [ -f "$cfgfile" ] && grep -Eq '^host_configured:[[:space:]]*true[[:space:]]*$' "$cfgfile"; then
    echo "unchanged: host_configured is already true in $cfgfile"
  elif [ -f "$cfgfile" ] && grep -Eq '^host_configured:' "$cfgfile"; then
    sed 's/^host_configured:.*/host_configured: true/' "$cfgfile" >"$cfgfile.tmp.$$" && mv -f "$cfgfile.tmp.$$" "$cfgfile"
    echo "changed: host_configured: true in $cfgfile (commit it by PR; the config is the project's)"
  else
    { [ ! -s "$cfgfile" ] || [ -z "$(tail -c1 "$cfgfile")" ] || echo; printf 'host_configured: true\n'; } >>"$cfgfile"
    echo "changed: host_configured: true added to $cfgfile (commit it by PR; the config is the project's)"
  fi
}

cmd_status() {
  local workdir="" bad=0 f="$CFG/settings.json" login
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir) [ $# -ge 2 ] || usage; workdir=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  need_jq
  if [ -z "$workdir" ] && [ -f "$HOME_DIR/host.json" ]; then workdir=$(jq -r '.workdir // empty' "$HOME_DIR/host.json"); fi
  if [ -f "$f" ] && jq -e '.remoteControlAtStartup == true' "$f" >/dev/null 2>&1; then echo "ok: remoteControlAtStartup on"; else echo "todo: remoteControlAtStartup is not on ($f)"; bad=1; fi
  if [ -f "$f" ] && jq -e '.agentPushNotifEnabled == true' "$f" >/dev/null 2>&1; then echo "ok: push notifications on"; else echo "todo: push notifications are not on ($f)"; bad=1; fi
  if [ -x "$(launcher_path)" ]; then echo "ok: supervisor launcher present"; else echo "todo: no supervisor launcher: host-setup.sh apply"; bad=1; fi
  if [ "$(host_os)" = macos ]; then
    if [ -f "$HOME/Library/LaunchAgents/com.artisan-agent.host.plist" ]; then echo "ok: launchd agent written"; else echo "todo: no launchd agent: host-setup.sh apply"; bad=1; fi
  else
    if [ -f "$HOME/.config/systemd/user/artisan-agent-host.timer" ]; then echo "ok: systemd timer written"; else echo "todo: no systemd timer: host-setup.sh apply"; bad=1; fi
  fi
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then echo "ok: tmux session $SESSION is running"; else echo "todo: tmux session $SESSION is not running (the supervisor starts it)"; bad=1; fi
  if [ -n "$workdir" ]; then cmd_trust "$workdir" || bad=1; else echo "todo: no workdir recorded: host-setup.sh apply --workdir D"; bad=1; fi
  cmd_gh || bad=1
  login=$(jq -r '.login_at // empty' "$HOME_DIR/login.json" 2>/dev/null || true)
  [ -n "$login" ] || login=$(jq -r '.login_at // empty' "$HOME_DIR/host.json" 2>/dev/null || true)
  if [ -n "$login" ]; then echo "ok: login recorded (login-check.sh checks it before each run)"; else echo "todo: no login recorded: log in, then login-check.sh stamp"; bad=1; fi
  return "$bad"
}

case "${1:-}" in
  check) cmd_check ;;
  apply) shift; cmd_apply "$@" ;;
  trust) shift; cmd_trust "${1:-}" ;;
  gh) cmd_gh ;;
  mark) shift; cmd_mark "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) usage ;;
esac
