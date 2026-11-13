cleanup() { :; }
test_trap_then_passes() {
  trap cleanup EXIT
  assert_eq 1 1 "fixture"
}
