# A project board for the fake gh (#146): tracker.board in a project's config
# and the board itself, with an Area field. Sourced by tests that check which
# issues go on the board. Needs FAKE_GH_DIR.

# add_board project-dir repo [ticket=Area]...: tracker.board (owner someone,
# number 1, fields_at_filing [Area]) appended to the project's config, and a
# board holding each ticket with its Area (an empty Area: on the board without one).
add_board() {
  local project=$1 repo=$2 pair="" items='[]'
  shift 2
  cat >>"$project/.artisan-agent/config.yml" <<'EOF'
tracker:
  board:
    owner: someone
    number: 1
    fields_at_filing: [Area]
EOF
  for pair in "$@"; do
    items=$(jq -c --arg r "$repo" --argjson n "${pair%%=*}" --arg a "${pair#*=}" \
      '. + [{id: "PVTI_s\($n)", content: {type: "Issue", number: $n, repository: $r, url: "https://github.com/\($r)/issues/\($n)"},
             values: (if $a == "" then {} else {Area: $a} end)}]' <<<"$items")
  done
  jq -n --argjson items "$items" '{id: "PVT_1", fields: [
      {id: "F_area", name: "Area", type: "ProjectV2SingleSelectField",
       options: [{id: "O_ui", name: "UI"}, {id: "O_pipe", name: "Pipeline"}, {id: "O_test", name: "Test & Tooling"}]},
      {id: "F_prio", name: "Priority", type: "ProjectV2SingleSelectField", options: [{id: "O_p0", name: "P0"}]}],
    items: $items}' >"$FAKE_GH_DIR/project-someone-1.json"
}

# on_board issue repo: the issue's board values as JSON, or "absent".
on_board() {
  jq -r --argjson n "$1" --arg r "$2" \
    '[.items[] | select(.content.number == $n and .content.repository == $r) | .values | tojson] | first // "absent"' \
    "$FAKE_GH_DIR/project-someone-1.json"
}
