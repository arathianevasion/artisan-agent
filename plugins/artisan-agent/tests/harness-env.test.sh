# run.sh must not leak the caller's ARTISAN_* variables into tests (#121).

test_artisan_variables_are_cleared_by_prefix() {
  mkdir suite
  cat > suite/probe.test.sh <<'EOF'
test_probe() {
  # Fake worker: writes where a real run's variables point, if it sees them.
  [ -z "${ARTISAN_FINDINGS_FILE:-}" ] || echo '{"title":"fake"}' >> "$ARTISAN_FINDINGS_FILE"
  [ -z "${ARTISAN_RESULT_FILE:-}" ] || echo fake > "$ARTISAN_RESULT_FILE"
  [ -z "${ARTISAN_RUN_DIR:-}" ] || touch "$ARTISAN_RUN_DIR/leak"
  left=$(compgen -v ARTISAN_ || true)
  [ -z "$left" ] || { echo "leaked: $left" >&2; exit 1; }
}
EOF
  mkdir rundir
  echo before > findings; echo before > result
  ARTISAN_FINDINGS_FILE=$PWD/findings ARTISAN_RESULT_FILE=$PWD/result \
    ARTISAN_RUN_DIR=$PWD/rundir ARTISAN_ADDED_LATER_X=1 \
    bash "$TESTS_DIR/run.sh" suite >/dev/null 2>&1 || fail "probe suite failed (variable leaked)"
  assert_eq before "$(cat findings)" "findings file touched"
  assert_eq before "$(cat result)" "result file touched"
  [ ! -e rundir/leak ] || fail "run dir touched"
}
