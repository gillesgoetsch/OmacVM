#!/usr/bin/env bash
# The guest check's "notch display" row: where may Omanotch's hidden NOTCH
# output sit? On the built-in display's top edge (the
# app's fallback) or, under OmacVM.app, right above it (notch-place.h). Any
# other place is still flagged. Offline: notch_spot from check.sh on fixtures.
# Also its "NOTCH workspaces" line (#760, Omarchy 4.5): notch_ws_unloaded on
# made-up `notchbar state` answers and bar copy widgets; and the "notch
# display" and FullPanel rows with Qt's locale warning before the state (#769).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
fn=$(awk '/^notch_spot\(\) \{$/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
[[ -n $fn ]] || { echo "FAIL check.sh has no notch_spot"; exit 1; }
eval "$fn"
fn=$(awk '/^notch_ws_unloaded\(\) \{$/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
[[ -n $fn ]] || { echo "FAIL check.sh has no notch_ws_unloaded"; exit 1; }
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
t over  other "$(mons 492 1735)"           "another VM type: NOTCH on Virtual-1's top edge"
t ""    other "$(mons 492 1692)"           "another VM type: NOTCH above Virtual-1 is a misplacement"
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

# The "NOTCH workspaces" line: only a state that says "omarchy" while the
# copy's widget has the patch (it is there but does not load). Gone or
# unpatched is copies.py's line; "copy" is fine; "none" is no NOTCH bar (or no
# Omarchy workspaces on it); 4.0's state has no key.
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
printf '// omarchy-notch-bar: the display the strip stands in for\nItem {}\n' > "$D/patched.qml"
printf 'Item {}\n' > "$D/stock.qml"
LOCALE='  WARN: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.
Qt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.'
state() {  # workspaces value ("" = no key, Omarchy 4.0)
  local w=""; [[ -n $1 ]] && w=",\"workspaces\":\"$1\""
  echo "{\"parked\":true,\"screen\":\"Virtual-1\",\"fullpanel\":\"off\",\"skip\":false$w,\"bars\":[[\"Virtual-1\",\"parked\",true,26,26,null]]}"
}
w() {  # want(warn|-) state widget name
  local got=-; notch_ws_unloaded "$2" "$3" && got=warn
  if [[ $got == "$1" ]]; then echo "ok   $4"; else echo "FAIL $4: want $1, got $got"; fail=1; fi
}
for loc in "" "$LOCALE"; do
  pre=${loc:+"$loc"$'\n'}; tag=${loc:+" (after Qt's locale warning)"}
  w warn "$pre$(state omarchy)" "$D/patched.qml" "omarchy + patched copy widget: does not load$tag"
  w -    "$pre$(state omarchy)" "$D/stock.qml"   "omarchy + unpatched copy widget: copies.py's line$tag"
  w -    "$pre$(state omarchy)" "$D/gone.qml"    "omarchy + no copy widget: copies.py's line$tag"
  w -    "$pre$(state copy)"    "$D/patched.qml" "copy: loads$tag"
  w -    "$pre$(state none)"    "$D/patched.qml" "none: no NOTCH bar$tag"
  w -    "$pre$(state "")"      "$D/patched.qml" "no workspaces key (Omarchy 4.0)$tag"
done
w - "" "$D/patched.qml" "the bar does not answer"
w - "not json" "$D/patched.qml" "the state is not JSON"
# check.sh's line uses it on the bar copy's widget, names no login and does
# not promise a reason the log does not hold.
grep -qF 'notch_ws_unloaded "$st" "$H/.config/omarchy/plugins/$U.bar/widgets/Workspaces.qml"' "$R/src/guest/check.sh" &&
  echo "ok   check.sh's NOTCH workspaces line uses notch_ws_unloaded" ||
  { echo "FAIL check.sh's NOTCH workspaces line does not use notch_ws_unloaded on the copy's widget"; fail=1; }
line=$(grep -F 'warn "NOTCH workspaces"' "$R/src/guest/check.sh")
[[ $line == *'plugins/\$USER.bar'* && $line != *'says why'* && $line == *"'omanotch: NOTCH workspaces'"* ]] &&
  echo "ok   the line names \$USER.bar and the log line it can point to" ||
  { echo "FAIL the NOTCH workspaces line: $line"; fail=1; }
grep -qF 'console.warn("omanotch: NOTCH workspaces: ' "$R/src/omanotch/guest/bar/apply-patch.py" &&
  echo "ok   the bar writes that log line" || { echo "FAIL the bar patch no longer writes 'omanotch: NOTCH workspaces'"; fail=1; }

# check.sh's reads of `notchbar state` (#769): Qt's locale warning before the
# JSON (check over ssh, no UTF-8 locale) must not turn a parked bar into "two
# bars" nor the FullPanel row into "does not answer". The rows are cut out of
# check.sh and run with stand-ins for the session's answers.
fn=$(awk '/^shell_json\(\) \{/ {print; exit}' "$R/src/guest/check.sh")
[[ -n $fn ]] || { echo "FAIL check.sh has no shell_json"; exit 1; }
eval "$fn"
n_reads=$(grep -c 'omarchy-shell notchbar state' "$R/src/guest/check.sh")
n_clean=$(grep -c 'omarchy-shell notchbar state 2>/dev/null | shell_json)' "$R/src/guest/check.sh")
(( n_reads > 0 && n_reads == n_clean )) && echo "ok   every notchbar state read in check.sh goes through shell_json ($n_reads)" ||
  { echo "FAIL $n_clean of $n_reads notchbar state reads in check.sh go through shell_json"; fail=1; }
j() {  # want got name
  if [[ $2 == "$1" ]]; then echo "ok   $3"; else echo "FAIL $3: want '$1', got '$2'"; fail=1; fi
}
j '{"parked":true}' "$(printf '%s\n{"parked":true}\n' "$LOCALE" | shell_json)" "shell_json: the object after Qt's locale warning"
j '{"parked":true}' "$(printf '{"parked": true}\n' | shell_json)" "shell_json: the object alone"
j "" "$(printf '%s\n' "$LOCALE" | shell_json)" "shell_json: the warning alone (an Omarchy without the call)"
j "" "$(printf '' | shell_json)" "shell_json: no answer"
j "" "$(printf 'Function not found.\n1\n' | shell_json)" "shell_json: text and a bare number are no state"

rowcut() {  # FIRST LAST: check.sh's lines from the first that starts with FIRST to the next that starts with LAST
  FIRST=$1 LAST=$2 awk 'index($0, ENVIRON["FIRST"]) == 1 { on = 1 } on { print } on && index($0, ENVIRON["LAST"]) == 1 { exit }' "$R/src/guest/check.sh"
}
nd=$(rowcut '  b=$(cat "$RUN/omacvm/builtin"' '  else ok "notch display"')
fp=$(rowcut '  st=$(as_user omarchy-shell notchbar state' '  esac')
[[ $nd == *'bad "notch display"'* && $fp == *'ok "full screen"'* ]] ||
  { echo "FAIL check.sh's notch display / full screen rows are not where this test looks"; exit 1; }
NOW=1800000000000
MONS='[{"name": "Virtual-1", "x": 0, "y": 0, "width": 3456, "height": 2234, "scale": 2.0},
 {"name": "NOTCH", "x": 0, "y": -32, "width": 3456, "height": 64, "scale": 2.0}]'
mkdir -p "$D/home/.local/state/omanotch" "$D/run"
run_row() {  # BLOCK STATE PARK: what the row says (kind|name|detail)
  ( H=$D/home RUN=$D/run TYPE=app STATE=$2
    printf '%s\n' "$3" > "$H/.local/state/omanotch/park"; echo $(( NOW - 1000 )) > "$H/.local/state/omanotch/beat"
    as_user() {
      case "$*" in
        "hyprctl monitors all -j") printf '%s\n' "$MONS" ;;
        "omarchy-shell notchbar state") [[ -n $STATE ]] && printf '%s\n' "$STATE" ;;
        "hyprctl layers -j") echo '{}' ;;
      esac
    }
    date() { echo "$NOW"; }
    ok() { echo "ok|$1|$2"; }; bad() { echo "fail|$1|$2"; }; skip() { echo "skip|$1|$2"; }
    eval "$1" )
}
r() {  # want-kind want-text name BLOCK STATE PARK
  local got; got=$(run_row "$4" "$5" "$6")
  if [[ ${got%%|*} == "$1" && $got == *"$2"* ]]; then echo "ok   $3"; else echo "FAIL $3: want $1 with '$2', got '$got'"; fail=1; fi
}
parked=$(state copy)
loose='{"parked":false,"screen":"","fullpanel":"off","skip":false,"workspaces":"copy","bars":[["Virtual-1","bar",true,26,26,null]]}'
other='{"parked":true,"screen":"Virtual-2","fullpanel":"off","skip":false,"bars":[]}'
strip='{"parked":false,"screen":"","fullpanel":"strip","skip":false,"bars":[["Virtual-1","fullpanel",true,64,64,null]]}'
for loc in "" "$LOCALE"; do
  pre=${loc:+"$loc"$'\n'}; tag=${loc:+" (after Qt's locale warning)"}
  r ok "its bar in the strip" "notch display: parked on Virtual-1, park 1$tag" "$nd" "$pre$parked" "1 Virtual-1"
  r fail "own bar is not parked" "notch display: park 1 but the bar not parked is still caught$tag" "$nd" "$pre$loose" "1 Virtual-1"
  r fail "the bar on Virtual-2 is parked" "notch display: parked on another output is still caught$tag" "$nd" "$pre$other" "1 Virtual-1"
  r ok "Virtual-1 (64 px)" "full screen including notch: the bar in the strip$tag" "$fp" "$pre$strip" ""
done
r skip "the bar does not answer" "full screen including notch: no answer" "$fp" "" ""
r skip "the bar does not answer" "full screen including notch: the warning alone" "$fp" "$LOCALE" ""

echo "notch-check: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
