# EXIT trap, then dies on an unbound variable. Bash 3.2 exits with the trap's status.
cleanup() { :; }
test_trap_then_unbound_variable() {
  trap cleanup EXIT
  echo "$UNSET_VARIABLE_FOR_THE_FIXTURE"
}
