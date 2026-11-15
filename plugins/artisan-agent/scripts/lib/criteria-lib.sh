# A ticket's acceptance criteria where they live (#215): the body, else the
# newest triage comment with an Agent Brief heading (lib/criteria.py where,
# the rule the verifier reads a ticket by). Every script that edits a
# ticket's criteria (to-plan.sh split-human-check, wave.sh close) reads and
# writes them through these two, so a criterion is changed or ticked
# wherever it is. Sourced, never run; the sourcing script sets SCRIPT_DIR to
# the scripts folder.
#
# Portable to bash 3.2 (macOS) and Linux. Needs gh, jq and python3.

# criteria_read repo ticket text-file: prints where the ticket's criteria are,
# as JSON {criteria, source, comment_id}, and writes the text holding them
# (the body or that comment's body) to text-file. Returns 1 when the issue
# can't be read.
criteria_read() {
  local repo="$1" n="$2" text="$3" issue="" where=""
  issue=$(gh issue view "$n" -R "$repo" --json body,comments) || return 1
  where=$(printf '%s\n' "$issue" | python3 -I "$SCRIPT_DIR/lib/criteria.py" where) || return 1
  jq -j '.text' <<<"$where" >"$text" || return 1
  jq -c 'del(.text)' <<<"$where"
}

# criteria_write repo ticket where-json text-file: puts text-file back where
# criteria_read found it: the issue body, or that triage comment, edited in
# place (GitHub's updateIssueComment, by the comment's node id). Returns 1
# when the tracker refuses, or a comment has no id to edit it by.
criteria_write() {
  local repo="$1" n="$2" where="$3" text="$4" id=""
  case "$(jq -r '.source // "body"' <<<"$where")" in
    body) gh issue edit "$n" -R "$repo" --body-file "$text" >/dev/null; return ;;
  esac
  id=$(jq -r '.comment_id // empty' <<<"$where")
  [ -n "$id" ] || return 1
  jq -n --arg id "$id" --rawfile b "$text" \
    --arg q 'mutation($id: ID!, $body: String!) { updateIssueComment(input: {id: $id, body: $body}) { issueComment { id } } }' \
    '{query: $q, variables: {id: $id, body: $b}}' | gh api graphql --input - >/dev/null
}
