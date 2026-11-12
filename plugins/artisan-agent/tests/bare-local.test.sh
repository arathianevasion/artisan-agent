# Static check: no shell file in the plugin declares a `local` without a value.
# On bash 4+ a bare `local x` leaves x unset, not empty, so reading it under
# `set -u` on a path that never assigns it dies on Linux and passes on the Mac
# (#127: move.sh broke CI that way). Declare `local x=` instead.
# Bash 3.2-safe: awk and find only.

LINT="$TESTS_DIR/helpers/bare-local.awk"

# Every shell file under dir: *.sh, plus extensionless files with a shell shebang.
shell_files() {
  local f=
  find "$1" -type f ! -path '*/.git/*' | while IFS= read -r f; do
    case "$f" in
      *.sh) printf '%s\n' "$f" ;;
      *.*) ;;
      *) head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh|env sh)' && printf '%s\n' "$f" ;;
    esac
  done
}

test_every_local_in_the_plugin_has_a_value() {
  local files= hits=
  files=$(shell_files "$PLUGIN_ROOT")
  [ -n "$files" ] || fail "found no shell files under $PLUGIN_ROOT"
  # shellcheck disable=SC2086
  hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk -f "$LINT")
  [ -z "$hits" ] || fail "bare local (declare it with a value, e.g. local x=):
$hits"
}

test_the_lint_flags_bare_locals_with_file_line_and_name() {
  local f="$TEST_TMPDIR/bad.sh" out=
  printf 'f() {\n  local x\n  local a= b c=1 d\n  if t; then local g; fi\n  local -a arr=() e\n  local h; local i=1\n}\n' > "$f"
  out=$(awk -f "$LINT" "$f")
  assert_eq "$f:2: x
$f:3: b
$f:3: d
$f:4: g
$f:5: e
$f:6: h" "$out"
}

test_the_lint_passes_declarations_with_values() {
  local f="$TEST_TMPDIR/good.sh" out=
  cat > "$f" <<'SH'
f() {
  local x=
  local x=""
  local x="$1" y=$(echo a b) z='a b'
  local -a arr=()
  local -a arr=(a b)
  local a= b=
  local -r r=1   # local bare in a comment
  echo "local not_a_declaration"
}
SH
  out=$(awk -f "$LINT" "$f")
  [ -z "$out" ] || fail "flagged valid declarations:
$out"
}
