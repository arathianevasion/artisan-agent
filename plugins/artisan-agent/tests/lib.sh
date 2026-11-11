# Assertions for script tests. Sourced by run.sh into each test's process.
# Portable to bash 3.2 (macOS) and GNU userland (Linux).

fail() {
  printf '  %s\n' "$*" >&2
  exit 1
}

assert_eq() { # expected actual [message]
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$1], got [$2]"
}

assert_contains() { # haystack needle [message]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-assert_contains}: [$2] not found in [$1]" ;;
  esac
}

assert_status() { # expected-status command...
  local want="$1" got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  [ "$want" = "$got" ] || fail "assert_status: expected exit $want from [$*], got $got"
}
