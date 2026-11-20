# The default voice standards template (#273): static checks. They assert names
# and markers, not wording, so tuning a rule's prose doesn't break them.

TEMPLATE="$PLUGIN_ROOT/templates/VOICE_STANDARDS.md"

test_the_template_states_the_resolution_order_before_the_rules() {
  local text= order= block=
  text=$(cat "$TEMPLATE")
  order=$(grep -n -i 'only the Artisan reads.*individual.*first' "$TEMPLATE" | head -n 1 | cut -d: -f1)
  block=$(grep -n '^<!-- voice-default v[0-9]* start' "$TEMPLATE" | cut -d: -f1)
  [ -n "$order" ] || fail "chat only the Artisan reads doesn't follow the individual file first"
  assert_contains "$text" "product, then team, then individual"
  assert_contains "$text" "ADR 0003"
  [ "$order" -lt "$block" ] || fail "the resolution order comes after the default block"
}

test_the_default_rules_sit_in_one_marked_block_carrying_version_1() {
  assert_eq 1 "$(grep -c '^<!-- voice-default v1 start' "$TEMPLATE")" "one start marker, version 1"
  assert_eq 1 "$(grep -c '^<!-- voice-default end' "$TEMPLATE")" "one end marker"
  local block=
  block=$(sed -n '/^<!-- voice-default v1 start/,/^<!-- voice-default end/p' "$TEMPLATE")
  local r=
  for r in R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16 R17 R18 R19 P1 P2 P3 P4; do
    printf '%s\n' "$block" | grep -q "^- \*\*$r\*\* " || fail "$r is not in the default block"
  done
}

test_an_empty_section_for_the_artisans_own_rules_follows_the_block() {
  local end= own= rest=
  end=$(grep -n '^<!-- voice-default end' "$TEMPLATE" | cut -d: -f1)
  own=$(grep -n '^## Your own rules$' "$TEMPLATE" | cut -d: -f1)
  [ -n "$own" ] || fail "no '## Your own rules' section"
  [ "$own" -gt "$end" ] || fail "the own-rules section is inside or before the default block"
  rest=$(sed -n "$((own + 1)),\$p" "$TEMPLATE")
  printf '%s\n' "$rest" | grep -qE '^(- |[0-9]+\. |#)' && fail "the own-rules section is not empty: $rest"
  true
}

test_the_template_credits_unslop_under_mit() {
  local text=; text=$(cat "$TEMPLATE")
  assert_contains "$text" "theclaymethod/unslop"
  assert_contains "$text" "MIT"
}

test_the_template_fits_the_cap_of_about_1500_tokens() {
  local chars=; chars=$(wc -c <"$TEMPLATE" | tr -d ' ')
  [ $((chars / 4)) -le 1500 ] || fail "template is $((chars / 4)) tokens (characters / 4), over the 1,500 cap"
}

test_each_version_older_than_the_templates_is_kept_as_history_for_the_retros_move() {
  local v= cur= f=
  cur=$(sed -n 's/^<!-- voice-default v\([0-9]*\) start.*/\1/p' "$TEMPLATE")
  v=1
  while [ "$v" -lt "$cur" ]; do
    [ -f "$(dirname "$TEMPLATE")/voice-default-history/v$v.md" ] || fail "no history for default v$v"
    v=$((v + 1))
  done
  # While the template is at v1, its block is the v1 history.
  if [ "$cur" = 1 ]; then
    assert_eq "$(sed -n '/^<!-- voice-default v1 start/,/^<!-- voice-default end/p' "$TEMPLATE")" \
      "$(cat "$(dirname "$TEMPLATE")/voice-default-history/v1.md")" "history v1 differs from the v1 block"
  fi
}
