# The suite on another machine over ssh (#386, #406): the merge gate's local
# fallback and a worker's full suite before hand-in both run it this way. The
# commit goes there as a git bundle into a fresh clone that is removed after,
# so nothing on the host has to be set up per project and two runs never
# share a checkout.
#
#   remote_host_up HOST
#       HOST answers ssh within 10 seconds. Fails for an empty HOST.
#   remote_suite HOST DIR SHA CMD LOG
#       runs CMD (sh -c) on HOST in a clone of SHA from the repo at DIR,
#       output to LOG. Returns CMD's exit status, REMOTE_NO_CHECKOUT when the
#       clone could not be made there, 255 when the ssh link failed, or
#       REMOTE_NO_BUNDLE when the bundle could not be made here (before ssh).
#
# Portable to bash 3.2 (macOS) and Linux.

REMOTE_NO_CHECKOUT=86
REMOTE_NO_BUNDLE=87

remote_host_up() {
  [ -n "$1" ] || return 1
  ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$1" true >/dev/null 2>&1
}

remote_suite() {
  local host="$1" dir="$2" sha="$3" cmd="$4" log="$5"
  local ref="refs/artisan-gate/$sha" bundle="" rc=0 q=""
  bundle=$(mktemp "${TMPDIR:-/tmp}/artisan-gate.XXXXXX")
  git -C "$dir" update-ref "$ref" "$sha"
  git -C "$dir" bundle create -q "$bundle" "$ref" >/dev/null 2>&1 || rc=$REMOTE_NO_BUNDLE
  git -C "$dir" update-ref -d "$ref"
  if [ "$rc" -ne 0 ]; then rm -f "$bundle"; return "$rc"; fi
  q=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "d=\$(mktemp -d) && cat >\"\$d/gate.bundle\" && git init -q \"\$d/w\" && cd \"\$d/w\" \
    && git fetch -q \"\$d/gate.bundle\" $ref && git checkout -q --detach $sha || { rm -rf \"\$d\"; exit $REMOTE_NO_CHECKOUT; }
    sh -c '$q'; rc=\$?; cd /; rm -rf \"\$d\"; exit \$rc" \
    <"$bundle" >"$log" 2>&1 || rc=$?
  rm -f "$bundle"
  return "$rc"
}
