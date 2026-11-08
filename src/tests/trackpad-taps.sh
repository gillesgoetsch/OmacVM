#!/bin/bash
# omacvm check's "trackpad taps" line (src/guest/check.sh, taps_line and the line
# that calls it). The virtual trackpad never taps: Omarchy 4.5 leaves Hyprland's
# tap-to-click on, and the start of a pinch was a two-finger tap there, a right
# click (3.4.1). ok for OmacVM's false, warn for the user's own true, bad with no
# setting; a commented-out line is no setting. The function is taken from
# check.sh as it is; ~/.config/hypr is a stand-in.
#   src/tests/trackpad-taps.sh
#   OMACVM_SRC=DIR src/tests/trackpad-taps.sh   against another checkout's src/
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-trackpad-taps.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
D=$T/hypr; mkdir -p "$D"
OMACVM='hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = false })'
GLIDE='hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", accel_profile = "flat", natural_scroll = true, scroll_factor = 0.656 })'

awk '/^taps_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$SRC/guest/check.sh" > "$T/fn.sh"
if [[ ! -s $T/fn.sh ]]; then echo "FAIL no taps_line in check.sh"; exit 1; fi
# shellcheck disable=SC1091
source "$T/fn.sh"
expect() {   # WHAT WANT-STATUS [TEXT]: ~/.config/hypr as set up just before
  local got; got=$(taps_line "$D")
  if [[ ${got%%$'\t'*} == "$2" && $got == *"${3:-}"* ]]; then echo "ok   $1"
  else echo "FAIL $1: want '$2${3:+ ... $3}', got '$got'"; fail=1; fi
}
files() { rm -f "$D"/*; while (( $# )); do printf '%s\n' "$2" > "$D/$1"; shift 2; done; }

files input.lua "$OMACVM" omacvm_glide.lua "$GLIDE"
expect "OmacVM's line (Update VM): ok" ok "off on the virtual trackpad"
files input.lua "  $OMACVM"
expect "... indented: ok" ok
files input.lua 'hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = true })'
expect "the user's own true: warn" warn "your setting"
files input.lua "-- $OMACVM" omacvm_glide.lua "$GLIDE"
expect "OmacVM's line commented out: bad (taps are on)" bad "Update VM"
files input.lua "  --$OMACVM"
expect "... commented out, indented: bad" bad
files input.lua "$OMACVM" mine.lua '-- hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = true })'
expect "OmacVM's false, the user's true commented out: ok" ok
files omacvm_glide.lua "$GLIDE"
expect "only scroll momentum's settings for the device: bad" bad "Update VM"
files input.lua 'hl.device({ name = "some-other-touchpad", tap_to_click = false })'
expect "another device's false: bad" bad
rm -f "$D"/*
expect "no Lua files: bad" bad
# check.sh says the line in the gestures block, from ~/.config/hypr.
blk=$(awk '/^if \[\[ \$GESTURES == on \]\]; then$/ {b = ""; on = 1} on {b = b $0 "\n"} on && /^else skip "trackpad gestures"/ {printf "%s", b; on = 0}' "$SRC/guest/check.sh")
if grep -q 'taps_line "\$H/.config/hypr")' <<<"$blk" && grep -q '"trackpad taps"' <<<"$blk"; then
  echo "ok   check.sh's gestures block says the line"
else echo "FAIL check.sh's gestures block has no trackpad taps line"; fail=1; fi
(( fail == 0 )) && echo "trackpad-taps: all passed"
exit $fail
