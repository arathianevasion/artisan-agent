test_passes() {
  assert_eq a a
}

test_stops_at_first_failed_command() {
  false
  echo "should not be reached"
}

test_fails_an_assertion() {
  assert_eq expected actual "the fixture's assertion"
}
