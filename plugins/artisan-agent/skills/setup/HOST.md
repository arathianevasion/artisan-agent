# Host mode

Setup's host mode prepares the **always-on machine** (a Mac left on if one is available, otherwise a small Linux VM) so runs carry on with the laptop closed. Run `/artisan-agent:setup` there and say it is the host. Wherever you put something in front of the Artisan, follow `${CLAUDE_PLUGIN_ROOT}/ARTISAN.md`; the steps below are shown as a table.

The script is `${CLAUDE_PLUGIN_ROOT}/skills/setup/scripts/host-setup.sh` (run it with `bash`; usage at its top). Like the rest of setup it is rerunnable and never overwrites: a file that differs from what it would write is reported as `kept:`.

## What it does

| Step | Who | How |
|---|---|---|
| Tools | script | `host-setup.sh check`: `claude`, `git`, `gh`, `jq`, `tmux`, `perl` |
| `remoteControlAtStartup` on, push notifications on | script | `apply` sets both in `<config>/settings.json`, keeping every other key. Push is what carries gates, triage and questions to the phone |
| Remote Control in server mode under a supervisor | script | `apply` writes `start-remote-control.sh` (keeps `claude remote-control --spawn worktree` alive in the tmux session `artisan-host`) and a launchd agent (macOS) or systemd user unit and timer (Linux) that run it at login or boot and every five minutes. `apply --load` loads them; on Linux the Artisan runs `sudo loginctl enable-linger <user>` once so it runs with nobody logged in |
| Workspace trust | **the Artisan, once, interactively** | `cd <workdir> && claude`, accept the trust prompt. A headless server cannot ask. `host-setup.sh trust <workdir>` confirms it |
| gh credentials | **the Artisan, once** | `gh auth login`; `host-setup.sh gh` confirms it |
| claude.ai login and its expiry check | **the Artisan, once** | `claude auth login`, then `${CLAUDE_PLUGIN_ROOT}/scripts/login-check.sh stamp`. Nothing reports when a login began (about 30 days observed, undocumented), so the host records it in `login.json` |
| Config records the host | script | `host-setup.sh mark` sets `host_configured: true` in the project's `.artisan-agent/config.yml`; the change reaches the project by PR like any config change |
| Check the lot | script | `host-setup.sh status`: one `ok:` or `todo:` line per piece; exit 0 only when all are ok |

SSH is only for setting up and repairing the host. Workers are headless, so a permission prompt a worker hits has nobody to answer it and is denied; only the Engineering chat's prompts, gates and questions reach the phone.

## After setup

The Engineering chat, its orchestrators and workers run on the host once it is configured. The laptop keeps the Product chat and hands-on tickets, which arrive through git. The Artisan opens sessions on the host the same way from the Claude app on a phone or from claude.ai/code or the desktop app on a laptop; each spawns in its own worktree.

Before every wave launch on the host (not an orchestrator hand-off), `wave.sh launch` runs `login-check.sh check`: it refuses (exit 15, nothing launched) when the login would expire before the span of the tickets the run has left plus a margin, and tells the Artisan to log in again and `stamp`. A machine with no `host.json` written by host setup is not a host and is never checked, so without a host everything runs on the laptop unchanged.

## Two signals, one meaning each

| Signal | Where | Means | Written by |
|---|---|---|---|
| `host_configured` | project config (committed, shared) | this project's runs live on a host | `host-setup.sh mark` |
| `host.json` | individual home | this machine is the host | `host-setup.sh apply` only (a rerun changes nothing) |
| `login.json` | individual home | when the claude.ai login was made | `login-check.sh stamp` |

Before starting a run, `implement-plan` runs `${CLAUDE_PLUGIN_ROOT}/scripts/host-notice.sh`. With `host_configured` true on a machine that is not the host it exits 10 and prints one line; the Engineering chat says it and offers to start the run on the host, and starts it here only if the Artisan says so. On the host, or with `host_configured` false or absent, the run starts as usual. A laptop whose `host.json` came only from an old login stamp (it has no `configured: true`) is not a host; `host-notice.sh` prints a `legacy:` line offering `login-check.sh cleanup`, which moves the stamp to `login.json` and removes the file.

To bring a run home or send it to the host, see `${CLAUDE_PLUGIN_ROOT}/skills/implement-plan/references/host-and-move.md`.

## Tests

`tests/host.test.sh` runs against a fake `HOME` and `CLAUDE_CONFIG_DIR` (never the real ones), with a stub `tmux` and `gh`. The parts that need a real always-on machine (surviving a reboot, a gate reaching a phone) are hand checks, kept with #78.
