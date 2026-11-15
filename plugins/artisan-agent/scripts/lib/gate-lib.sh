# Text and rules the gate scripts share, so each lives in one place: gate.sh,
# gate-action.sh and chats.sh source this. Bash 3.2-safe.
#
#   GATE_CLOSED_MARK: the marker gate.sh sync puts on the tracker comment that
#     announces a gate closed by hand; chats.sh sweep finds the comment by it.
#   exception_choices_table body|chat: the exception gate's six choices (and
#     the "a bug" flag retry and take take) as a
#     Markdown table. "body" is the table in the gate's issue body (its
#     reslice and drop rows carry {{leaves}}, for the caller to fill in);
#     "chat" is the shorter one gate-action.sh chat prints.
#   unmeetable_choices_table body|chat: the choices of an exception gate
#     whose ticket has a criterion no worker can meet (reason "unmeetable",
#     #186), in the same two styles: split it into a Human check or a new
#     ticket, rewrite it, drop it with a reason, or retry anyway; and bypass
#     or defer, as on any exception gate.
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
retry or take, a bug@with retry with notes or take it myself, also records a bug found in the ticket at this gate, tighten evidence for its areas at the retro (`--bug`)@with retry or take: also records a bug found in the ticket
ROWS
}

unmeetable_choices_table() { # body|chat
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
split into a Human check@the criterion moves to the ticket's Human check (`ready-for-human`, next slice gate); a fresh verifier judges the same commit on the rest (`split --human`)@to its Human check; the same commit verified again
split into a new ticket@the criterion becomes a new `needs-triage` ticket, outside this run; a fresh verifier judges the same commit on the rest (`split --ticket`)@to a new needs-triage ticket; the same commit verified again
rewrite@you give the criterion's new wording; a fresh verifier judges the same commit against it (`rewrite --as`)@your wording; the same commit verified again
drop it@the criterion is dropped with your reason; a fresh verifier judges the same commit on the rest (`drop-criterion --why`)@dropped with your reason; the same commit verified again
retry anyway@a fresh worker on the same branch, one more attempt, told you judge the criterion meetable and given your notes@a fresh worker, one more attempt
bypass@leaves the run; its dependents go ahead without it; recorded with who@out of the run; its dependents go ahead
defer@its dependents go ahead now; this gate stays open until the end gate@its dependents go ahead; the gate waits for the end gate
ROWS
}
