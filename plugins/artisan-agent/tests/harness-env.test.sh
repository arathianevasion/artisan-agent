# run.sh must not leak the caller's ARTISAN_* variables into tests (#121).

test_artisan_variables_are_cleared_by_prefix() {
  mkdir suite
  cat > suite/probe.test.sh <<'EOF'
test_probe() {
  # Fake worker: writes where a real run's variables point, if it sees them.
  [ -z "${ARTISAN_FINDINGS_FILE:-}" ] || echo '{"title":"fake"}' >> "$ARTISAN_FINDINGS_FILE"
  [ -z "${ARTISAN_RESULT_FILE:-}" ] || echo fake > "$ARTISAN_RESULT_FILE"
  [ -z "${ARTISAN_RUN_DIR:-}" ] || touch "$ARTISAN_RUN_DIR/leak"
  # lib.sh sets its own ARTISAN_USAGE_FILE inside the test folder (#72); not a caller leak.
  left=$(compgen -v ARTISAN_ | grep -vx ARTISAN_USAGE_FILE || true)
  [ -z "$left" ] || { echo "leaked: $left" >&2; exit 1; }
}
EOF
  mkdir rundir
  echo before > findings; echo before > result
  ARTISAN_FINDINGS_FILE=$PWD/findings ARTISAN_RESULT_FILE=$PWD/result \
    ARTISAN_RUN_DIR=$PWD/rundir ARTISAN_ADDED_LATER_X=1 \
    bash "$TESTS_DIR/run.sh" suite > out 2>&1 || fail "probe suite failed (variable leaked): $(cat out)"
  assert_contains "$(cat out)" "1 passed, 0 failed" "probe did not run"
  assert_eq before "$(cat findings)" "findings file touched"
  assert_eq before "$(cat result)" "result file touched"
  [ ! -e rundir/leak ] || fail "run dir touched"
}
