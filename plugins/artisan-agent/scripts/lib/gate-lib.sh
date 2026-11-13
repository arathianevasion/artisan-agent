# Text and rules the gate scripts share, so each lives in one place: gate.sh,
# gate-action.sh and chats.sh source this. Bash 3.2-safe.
#
#   GATE_CLOSED_MARK: the marker gate.sh sync puts on the tracker comment that
#     announces a gate closed by hand; chats.sh sweep finds the comment by it.
#   exception_choices_table body|chat: the exception gate's six choices as a
#     Markdown table. "body" is the table in the gate's issue body (its
#     reslice and drop rows carry {{leaves}}, for the caller to fill in);
#     "chat" is the shorter one gate-action.sh chat prints.
#
# The slice gate's body header (| Gate | Role needed | Slice | Tickets blocked |)
# is written by lib/packet.py, which owns it: `packet.py header` prints it.

GATE_CLOSED_MARK='artisan-agent:gate-closed-by-hand'

exception_choices_table() { # body|chat
  local style="$1" choice="" in_body="" in_chat="" head="Choice"
  [ "$style" != body ] || head="Say"
  printf '| %s | Does |\n|---|---|\n' "$head"
  # choice @ text in the gate body @ text in the chat
  while IFS='@' read -r choice in_body in_chat; do
    if [ "$style" = body ]; then
      printf '| %s | %s |\n' "$choice" "$in_body"
    else
      printf '| %s | %s |\n' "$choice" "$in_chat"
    fi
  done <<'ROWS'
retry with notes@a fresh worker on the same branch, given your notes and one more attempt@a fresh worker given your notes, one more attempt
reslice@leaves the run labelled `needs-triage`, to be sliced again{{leaves}}@out of the run, labelled needs-triage; everything that depends on it goes back to triage with it
take it myself@labelled `ready-for-human`; you build it in your own worktree@ready-for-human, built by you
drop@leaves the run; the ticket stays open{{leaves}}@out of the run; everything that depends on it goes back to needs-triage with it
bypass@leaves the run; its dependents go ahead without it; recorded with who@out of the run; its dependents go ahead
defer@its dependents go ahead now; this gate stays open until the end gate@its dependents go ahead; the gate waits for the end gate
ROWS
}
