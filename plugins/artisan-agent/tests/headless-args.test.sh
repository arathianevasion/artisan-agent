# Static check (#214): every script that launches `claude -p` passes the
# headless arguments (lib/headless-lib.sh's headless_args, #187) in that same
# command, so a permission request is never waited on. A new launch site
# that forgets them fails here.
# Bash 3.2-safe: awk and find only.

# Launches that deliberately carry no allowlist, with why:
#   project-setup.sh hook-probe: the hook blocks the prompt before any model
#   call, so no tool is ever requested (#214).
EXEMPT="skills/setup/scripts/project-setup.sh"

# Prints "file:line" for each `claude -p` launch whose command (the line and
# its backslash continuations) lacks HEADLESS_ARGS.
bare_launches() {
  find "$PLUGIN_ROOT" -type f -name '*.sh' ! -path '*/tests/*' ! -path '*/.git/*' | while IFS= read -r f; do
    awk -v f="$f" '
      function flush() { if (cmd != "" && cmd !~ /HEADLESS_ARGS/) print f ":" start; cmd = "" }
      cmd != "" { cmd = cmd " " $0; if ($0 !~ /\\$/) flush(); next }
      /^[[:space:]]*#/ { next }
      /(\$CLAUDE[A-Z_]*|\$\{CLAUDE[A-Z_]*\}|claude)"? +-p( |$)/ { start = NR; cmd = $0; if ($0 !~ /\\$/) flush() }
    ' "$f"
  done
}

test_every_claude_p_launch_passes_the_headless_arguments() {
  local hits= f=
  hits=$(bare_launches)
  for f in $EXEMPT; do hits=$(printf '%s\n' "$hits" | grep -v "$PLUGIN_ROOT/$f" || true); done
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  [ -z "$hits" ] || fail "claude -p without headless_args's \"\${HEADLESS_ARGS[@]}\":
$hits"
}

test_the_lint_flags_a_launch_without_the_headless_arguments() {
  local d="$TEST_TMPDIR/p"; mkdir -p "$d"
  printf '#!/bin/bash\n"$CLAUDE" -p "x" \\\n  --model m\n' >"$d/bad.sh"
  printf '#!/bin/bash\n"$CLAUDE" -p "x" "${HEADLESS_ARGS[@]}" \\\n  --model m\n' >"$d/good.sh"
  local run_hits=; run_hits=$(PLUGIN_ROOT="$d" bare_launches)
  assert_contains "$run_hits" "bad.sh:2"
  case "$run_hits" in *good.sh*) fail "flagged a launch that has the arguments" ;; esac
}
