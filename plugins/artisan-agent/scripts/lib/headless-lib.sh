# The permission arguments every headless `claude -p` step starts with, chosen
# in one place (#187): wave.sh's orchestrator and workers, verify.sh's
# verifier and retro.sh's preparer. Sourced, never run.
#
# --permission-mode dontAsk denies a tool outside the allowlist at once and
# never asks. A headless session has no one to answer a prompt, and a `claude`
# wrapper on PATH (the cmux shim) can carry hooks that turn a permission
# request into a "needs input" wait the step never comes back from. In
# dontAsk no permission request is raised, so no hook can make one wait,
# whichever `claude` is on PATH. Settings' allow rules still apply.
#
# A denied tool shows in the session's final result event, as
# permission_denials (run-ticket.sh counts them into the exit record).
#
# Portable to bash 3.2 (macOS) and Linux.

HEADLESS_PERMISSION_MODE=dontAsk

# headless_args tools: sets HEADLESS_ARGS to the permission arguments for a
# headless session allowed exactly tools (a --allowedTools list).
headless_args() {
  HEADLESS_ARGS=(--permission-mode "$HEADLESS_PERMISSION_MODE" --allowedTools "$1")
}
