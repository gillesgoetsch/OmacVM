#!/bin/bash
# omacvm check's "media keys" line: the Bridge's normal log lines (tap
# installed, created again when a VM comes to the front) are not failures.
#   src/tests/media-keys-check.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
fails=0
expect() {   # LINE STATUS DETAIL
  local got; got=$(media_keys_state "$1")
  if [[ $got == "$2"$'\t'"$3" ]]; then echo "ok   ${1:-(none)}"
  else echo "FAIL ${1:-(none)}: want '$2 $3', got '${got//$'\t'/ }'"; fails=$((fails + 1)); fi
}
expect "media keys: event tap installed" ok "event tap installed"
expect "media keys: event tap created again (an OmacVM VM came to the front)" ok "event tap installed"
expect "media keys: event tap created again (macOS invalidated it)" ok "event tap installed"
expect "media keys: cannot create the event tap again (an OmacVM VM came to the front); keeping the old one" \
  warn "cannot create the event tap again (an OmacVM VM came to the front); keeping the old one"
expect "media keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)" \
  fail "waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)"
expect "media keys: cannot create the event tap although Accessibility is granted; retrying" \
  fail "cannot create the event tap although Accessibility is granted; retrying"
expect "" fail "no event tap yet"
# check.sh reads the same log lines and goes through media_keys_state.
grep -q "last_line \"\$BRIDGE_LOG\" 'media keys: (event tap|waiting|cannot)'" "$R/src/cmd/check.sh" &&
  grep -q 'media_keys_state "$m"' "$R/src/cmd/check.sh" ||
  { echo "FAIL src/cmd/check.sh no longer uses media_keys_state for the Bridge's media keys line"; fails=$((fails + 1)); }
# The Bridge still logs the lines this test knows.
for l in 'media keys: event tap created again' 'media keys: event tap installed' 'keeping the old one'; do
  grep -qF "$l" "$R/src/bridge/mac/keys.swift" || { echo "FAIL keys.swift no longer logs '$l'"; fails=$((fails + 1)); }
done
(( fails == 0 )) && echo "media keys check: all passed" || { echo "media keys check: $fails failed"; exit 1; }
