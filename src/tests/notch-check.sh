#!/usr/bin/env bash
# The guest check's "notch display" row: where may Omanotch's hidden NOTCH
# output sit? On the built-in display's top edge (Parallels, UTM, Fusion, the
# app's fallback) or, under OmacVM.app, right above it (notch-place.h). Any
# other place is still flagged. Offline: notch_spot from check.sh on fixtures.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
fn=$(awk '/^notch_spot\(\) \{$/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
[[ -n $fn ]] || { echo "FAIL check.sh has no notch_spot"; exit 1; }
eval "$fn"
fail=0

# The user's layout (2026-10-06): 6K above the MacBook, Virtual-1 at 492,1735,
# 2056 logical px wide at scale 2; NOTCH 43 logical px high.
mons() {  # NOTCH x y [width px] [height px] [scale]
  cat <<J
[{"name": "Virtual-2", "x": 0, "y": 0, "width": 6016, "height": 3384, "scale": 2.0},
 {"name": "Virtual-1", "x": 492, "y": 1735, "width": 4112, "height": 2572, "scale": 2.0},
 {"name": "NOTCH", "x": $1, "y": $2, "width": ${3:-4112}, "height": ${4:-86}, "scale": ${5:-2.0}}]
J
}
t() {  # want type json name
  local got; got=$(notch_spot "$3" Virtual-1 "$2")
  if [[ $got == "$1" ]]; then echo "ok   $4"; else echo "FAIL $4: want '${1}', got '${got}'"; fail=1; fi
}

t above app  "$(mons 492 1692)"           "OmacVM.app: NOTCH right above Virtual-1 (492,1692)"
t over  app  "$(mons 492 1735)"           "OmacVM.app fallback: NOTCH on Virtual-1's top edge"
t over  utm  "$(mons 492 1735)"           "UTM/Parallels: NOTCH on Virtual-1's top edge"
t ""    utm  "$(mons 492 1692)"           "UTM/Parallels: NOTCH above Virtual-1 is a misplacement"
t ""    app  "$(mons 0 0)"                "NOTCH on the 6K is a misplacement"
t ""    app  "$(mons 492 1600)"           "NOTCH far above Virtual-1 (gap) is a misplacement"
t ""    app  "$(mons 492 1720)"           "NOTCH half over Virtual-1's top edge is a misplacement"
t ""    app  "$(mons 500 1692)"           "NOTCH above but shifted sideways is a misplacement"
t ""    app  "$(mons 492 1692 3456)"      "NOTCH above but narrower than Virtual-1 is a misplacement"
t above app  "$(mons 492 1703 4112 64 2.0)" "a 32 px strip right above (1703 + 64/2 = 1735)"
t above app  "$(mons 492 1708 4112 43 1.6)" "fractional scale: 43 px / 1.6 = 26.9 logical, within a px"
t ""    app  '[{"name": "Virtual-1", "x": 0, "y": 0, "width": 3456, "height": 2234, "scale": 2.0}]' "no NOTCH output: nothing"
t above app  '[{"name": "Virtual-1", "x": 0, "y": 0, "width": 3456, "height": 2234, "scale": 2.0},
               {"name": "NOTCH", "x": 0, "y": -32, "width": 3456, "height": 64, "scale": 2.0}]' "one display: NOTCH at 0,-32 above it"

# check.sh uses it for the row (and no longer demands NOTCH at the same spot).
grep -qF 'notch_spot "$mons" "$b" "$TYPE"' "$R/src/guest/check.sh" && echo "ok   check.sh's row uses notch_spot" ||
  { echo "FAIL check.sh's notch display row does not use notch_spot"; fail=1; }
grep -qF '$(at NOTCH) != "$(at "$b")"' "$R/src/guest/check.sh" &&
  { echo "FAIL check.sh still wants NOTCH exactly on the display"; fail=1; }

echo "notch-check: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
