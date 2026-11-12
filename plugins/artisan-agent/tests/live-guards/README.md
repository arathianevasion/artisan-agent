# Live proof: the guard hooks with hooks active (#105)

Not part of `tests/run.sh` (real `claude -p` sessions, a few cents). `UPSTREAM_PLUGIN_DIR=<mattpocock-skills dir> live.sh <workdir>` runs five capped sessions in a throwaway repo with the fake tracker, using `tests/helpers/live-hooks.sh`'s flags (plugin hooks on, user settings out). Every session must also leave a SessionStart line in `ARTISAN_HOOK_PROOF`, or it FAILs.

Result, 2026-11-11, Claude Code 2.1.322, `claude-sonnet-5-5`, 0 failed:

| Proof (ticket) | Seen |
|---|---|
| Typed `/mattpocock-skills:implement` blocked, 0 turns, $0 (#50) | `Blocked by the artisan-agent replaced-skill guard: /mattpocock-skills:implement is replaced in this pipeline. Use /artisan-agent:implement instead.` |
| Bare `/retro` (an upstream-only name) blocked (#50) | same guard, naming `/mattpocock-skills:retro`. A bare `/implement` or `/triage` resolves to this plugin's own skill, so it is no block case |
| Edit of `doc.md` in the main checkout refused (#56) | the model reported the main-checkout guard's block; `doc.md` unchanged, tree clean |
| Second `implement-plan` while a run holds the lock refused and queued (#56) | `Blocked by the artisan-agent run lock: run live1 (pid …) holds the lock`; a `Plan: …` issue was created on the fake tracker |
| The holder's `implement-plan resume` passes run-start (#54) | not blocked; the session reached the model, which ran `run-digest.sh` |

Notes: a headless session with only `--allowedTools Bash` still stops at Bash permission prompts for compound commands, so the resume session ends with `claude exited 1` after its turn cap; what is proved is that the hook let it through.
