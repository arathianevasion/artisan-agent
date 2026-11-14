# Static check (#203): no script hands jq a whole file as the value of
# --arg or --argjson: $(cat …) or $(< …). Run files grow with the run (the
# state, a gate view); Linux refuses one argument over 128 KiB and macOS all
# of them together over 1 MiB, and jq then never starts. Read a file with
# --slurpfile or --rawfile, or on stdin, instead. Bash 3.2-safe: grep and find only.

PATTERN='--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+"?\$\([[:space:]]*(cat[[:space:]]|<)'

scan() { # dir...: file:line of every hit in the plugin's shell files
  find "$@" -type f \( -name '*.sh' -o -name '*.bash' \) ! -path '*/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -nE -- "$PATTERN" 2>/dev/null || true
}

test_no_script_passes_a_cat_of_a_file_as_a_jq_argument() {
  local hits=
  hits=$(scan "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills")
  [ -z "$hits" ] || fail "jq gets a whole file as an argument (pass it with --slurpfile/--rawfile or on stdin):
$hits"
}

test_the_check_flags_arg_and_argjson_fed_by_cat() {
  local d="$TEST_TMPDIR/scripts" out=
  mkdir -p "$d"
  cat >"$d/bad.sh" <<'SH'
jq -n --argjson v "$(cat "$view")" '$v'
jq -n --arg body "$(cat body.md)" '$body'
jq -n --argjson v $(cat f.json) '$v'
jq -n --argjson v "$(< f.json)" '$v'
SH
  cat >"$d/good.sh" <<'SH'
jq -n --slurpfile v "$view" '$v[0]'
jq -n --rawfile body body.md '$body'
jq -n --arg t "$(jq -r .id f.json)" '$t'
SH
  out=$(scan "$d")
  assert_eq "$d/bad.sh:1:jq -n --argjson v \"\$(cat \"\$view\")\" '\$v'
$d/bad.sh:2:jq -n --arg body \"\$(cat body.md)\" '\$body'
$d/bad.sh:3:jq -n --argjson v \$(cat f.json) '\$v'
$d/bad.sh:4:jq -n --argjson v \"\$(< f.json)\" '\$v'" "$out"
}
