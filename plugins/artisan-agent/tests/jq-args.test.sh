# Static check (#203, #208): no script hands jq JSON that grows with the run
# or the tracker as the value of --arg or --argjson. Linux refuses one
# argument over 128 KiB and macOS all of them together over 1 MiB, and jq
# then never starts. The forms it flags:
#   - a whole file: $(cat …) or $(< …), or a filter that reads one
#     ($(awk … file), $(sed …), $(head …), $(tail …), $(grep …));
#   - a tracker response: $(gh …), $(blockers_of …), $(human_checks_view …),
#     or a variable the same file assigns from `gh api`, `gh issue view`,
#     blockers_of or human_checks_view (unless that line narrows it with
#     --jq, | jq, or a --json list without body or comments);
#   - the recorded gate: $GATE, $(recorded …), or a variable assigned from
#     recorded;
#   - a map built over the scope: $tracker.
# Read a file with --slurpfile or --rawfile, or pass the JSON on stdin
# (--slurpfile x /dev/stdin <<<"$json", or `. as $x`), instead.
# Bash 3.2-safe: find and a POSIX awk only.

SCAN_AWK='
FNR == NR {
  if (match($0, /[A-Za-z_][A-Za-z_0-9]*=\$\([[:space:]]*(gh[[:space:]]+(api|issue[[:space:]]+view)|blockers_of|human_checks_view|recorded)[[:space:]]/) \
      && $0 !~ /--jq|\|[[:space:]]*jq[[:space:]]/ \
      && ($0 !~ /--json/ || $0 ~ /--json[[:space:]]+[^[:space:]]*(body|comments)/)) {
    name = substr($0, RSTART, RLENGTH); sub(/=.*/, "", name); big[name] = 1
  }
  next
}
{
  rest = $0; hit = 0
  while (!hit && match(rest, /--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+"?\$[({]?[^"[:space:]]*/)) {
    v = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^--arg(json)?[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+"?/, "", v)
    if (v ~ /^\$\([[:space:]]*(cat|<)/) hit = 1
    else if (v ~ /^\$\([[:space:]]*(awk|sed|head|tail|grep)([[:space:]]|$)/) hit = 1
    else if (v ~ /^\$\((gh|blockers_of|human_checks_view|recorded)$/) hit = 1
    else if (v ~ /^\$\{?(GATE|tracker)([^A-Za-z_0-9]|$)/) hit = 1
    else if (v !~ /^\$\(/) {
      n = v; sub(/^\$\{?/, "", n); sub(/[^A-Za-z_0-9].*$/, "", n)
      if (n in big) hit = 1
    }
  }
  if (hit) print FILENAME ":" FNR ":" $0
}'

scan() { # dir...: file:line of every hit in the plugin's shell files
  local f=""
  find "$@" -type f \( -name '*.sh' -o -name '*.bash' \) ! -path '*/tests/*' 2>/dev/null | sort \
    | while IFS= read -r f; do awk "$SCAN_AWK" "$f" "$f"; done
}

test_no_script_passes_growing_json_as_a_jq_argument() {
  local hits=""
  hits=$(scan "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills")
  [ -z "$hits" ] || fail "jq gets JSON that grows with the run as an argument (pass it with --slurpfile/--rawfile or on stdin):
$hits"
}

test_the_check_flags_arg_and_argjson_fed_by_cat() {
  local d="$TEST_TMPDIR/scripts" out=""
  mkdir -p "$d"
  cat >"$d/bad.sh" <<'SH'
jq -n --argjson v "$(cat "$view")" '$v'
jq -n --arg body "$(cat body.md)" '$body'
jq -n --argjson v $(cat f.json) '$v'
jq -n --argjson v "$(< f.json)" '$v'
jq -n --argjson lines "$(awk -v from="$seen" 'NR > from' "$f" | jq -Rn '[inputs]')" '$lines'
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
$d/bad.sh:4:jq -n --argjson v \"\$(< f.json)\" '\$v'
$d/bad.sh:5:jq -n --argjson lines \"\$(awk -v from=\"\$seen\" 'NR > from' \"\$f\" | jq -Rn '[inputs]')\" '\$lines'" "$out"
}

test_the_check_flags_tracker_responses_scope_maps_and_the_recorded_gate() {
  local d="$TEST_TMPDIR/scripts" out=""
  mkdir -p "$d"
  cat >"$d/bad.sh" <<'SH'
issue=$(gh api "repos/$repo/issues/$t") || die
jq -n --argjson i "$issue" '$i'
view=$(gh issue view "$n" -R "$REPO" --json body,comments)
jq -n --argjson v "$view" --arg t "$t" '$v'
jq -n --argjson b "$(blockers_of "$t" || echo null)" '$b'
jq -n --argjson b "$(gh api "repos/$(repo)/issues/$t/dependencies/blocked_by")" '$b'
jq -n --argjson hc "$(human_checks_view "$list")" '$hc'
jq -n --argjson tr "$tracker" '$tr'
jq -n --argjson gate "$GATE" '$gate'
jq -n --argjson g "${GATE}" '$g'
rec=$(recorded "$id")
jq -n --argjson g "$rec" '$g'
SH
  cat >"$d/good.sh" <<'SH'
state=$(gh api "repos/$repo/issues/$i" | jq -r .state)
jq -n --arg s "$state" '$s'
id=$(gh api "repos/$repo/issues/$i" --jq .id)
jq -n --argjson id "$id" '$id'
jq -c --arg t "$t" '.number' <<<"$issue"
m=$(gh issue view "$t" -R "$REPO" --json number,title,state) || die
jq -c --argjson m "$m" '. + [$m]' <<<"$members"
printf '%s' "$tracker" | jq --slurpfile tr /dev/stdin '$tr[0]' state.json
jq -r --arg gate "$(jq -r .id <<<"$GATE")" '$gate'
jq -n --arg trackers "$trackers" --argjson g "$def" '$g'
SH
  out=$(scan "$d" | cut -d: -f1-2)
  assert_eq "$d/bad.sh:2
$d/bad.sh:4
$d/bad.sh:5
$d/bad.sh:6
$d/bad.sh:7
$d/bad.sh:8
$d/bad.sh:9
$d/bad.sh:10
$d/bad.sh:12" "$out"
}
