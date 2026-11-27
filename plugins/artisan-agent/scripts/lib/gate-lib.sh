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
#   GATE_FOLD_JQ: the fold rule (#241), one jq def gate-plan.sh render and
#     gate.sh open (sync, drain.sh gate) both use. fold_into($g; $gates;
#     $waiting; $past) is where risk gate $g folds, or null when it opens on
#     its own: null for a gate kept as its own (`own`, gate-plan.sh keep) or
#     with a ticket still waiting on its ticket ($waiting: the unmerged
#     dependents in scope); else the first slice gate in $gates covering its
#     ticket that is not in $past (the gates already opened or answered),
#     else "end" when $gates has an end gate not in $past, else null.
#     $gates: [{id, kind, tickets}], as the plan numbers them.
#
#   GATE_CARRY_JQ: the small-run rule (#407), run over the state file.
#     run_small_clean is true when the plan's small_run_tickets is above 0,
#     the run has at most that many tickets in scope, and none has failed an
#     attempt, no gate was redirected and no exception gate was raised.
#     carry_to_end($g) is true when slice or risk gate $g is carried to the
#     end gate instead of waiting on the Artisan: the run is small and clean,
#     the plan places an end gate not yet opened, and the gate was not kept
#     as its own (`own`). A plan from before #407 has no small_run_tickets
#     in its config: its gates wait as they always did.
#
# The slice gate's body header (| Gate | Role needed | Slice | Tickets blocked |)
# is written by lib/packet.py, which owns it: `packet.py header` prints it.

GATE_CLOSED_MARK='artisan-agent:gate-closed-by-hand'

GATE_FOLD_JQ='
  def fold_into($g; $gates; $waiting; $past):
    if ($g.kind // "") != "risk" or ($g.own // false) or ($waiting | length) > 0 then null
    else ([$gates[] | select(.kind == "slice" and (.id as $id | $past | index($id)) == null)
           | select(.tickets // [] | map(tostring) | any(. as $t | $g.tickets | map(tostring) | index($t) != null)) | .id]
          | first)
         // (if any($gates[]; .kind == "end") and ($past | index("end")) == null then "end" else null end)
    end;
'

GATE_CARRY_JQ='
  def run_small_clean:
    (.plan.config.small_run_tickets? // 0) as $n
    | $n > 0 and ((.plan.scope // []) | length) <= $n
      and all((.tickets // {})[]; ((.failures // []) | length) == 0)
      and all((.review_gates // [])[]; .status != "redirected" and .redirect == null)
      and ((.exception_gates // []) | length) == 0;
  def carry_to_end($g):
    (($g.kind // "slice") as $k | $k == "slice" or $k == "risk")
    and (($g.own // false) | not)
    and any((.plan.gates // [])[]; .kind? == "end")
    and .end_gate.issue? == null and .end_gate.status? == null
    and run_small_clean;
'

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
