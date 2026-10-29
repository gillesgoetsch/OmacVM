#!/usr/bin/env bash
# omacvm check's "full screen (app)" row for Full screen including notch
# (FullPanel): which of QEMU's lines it reads and what it says. Offline: the
# grep and the case block from src/cmd/check.sh on made-up qemu.log lines,
# among them the lines of a display change (omacvm-cocoa-fullpanel-retake.patch):
# "display change: ..." warns until a later "strip covered" (the VM sits below
# the notch meanwhile), "strip taken again" is not read, "strip not back" warns
# with the remedy (the menu bar setting when the menu bar is always shown),
# a later "strip covered" wins.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
c="$R/src/cmd/check.sh"
pat=$(grep -o "grep -E '^omacvm: full panel: ([^']*)'" "$c" | head -1 | sed "s/^grep -E '//; s/'\$//")
block=$(awk '/^    case \$nq in$/ {on = 1} on {print} on && /^    esac$/ {exit}' "$c")
hint=$(grep '^MENU_HINT="[^"]*"$' "$c")
[[ -n $pat && -n $block && -n $hint ]] || { echo "FAIL check.sh's FullPanel row is not where this test looks"; exit 1; }
eval "$hint"
ok() { printf 'ok|%s' "$2"; }
warn() { printf 'warn|%s' "$2"; }
skip() { printf 'skip|%s' "$2"; }
row() {  # the qemu.log lines on stdin -> what the row says
  local nq
  nq=$(grep -E "$pat" | tail -1)
  nq=${nq#omacvm: full panel: }
  eval "$block"
}
fail=0
t() {  # want-kind want-text name [qemu.log lines...]
  local got; got=$(if (( $# > 3 )); then printf '%s\n' "${@:4}"; fi | row)
  if [[ ${got%%|*} == "$1" && $got == *"$2"* ]]; then echo "ok   $3"
  else echo "FAIL $3: want $1 with '$2', got '$got'"; fail=1; fi
}

covered='omacvm: full panel: strip covered: full-screen Space 22, display 1728x1117, notch 32, menu bar hidden (Keep the Dock away)'
moved='omacvm: full panel: display change: frame (0 -323 2560x1440) on display (0 0 1728x1117), laid out for another display; the strip comes back once the displays settle'
released='omacvm: full panel: the full screen is on a display without a camera housing: normal full screen there'
trying='omacvm: full panel: below the notch after a display change (the displays settled): AppKit lays the window out again (try 1 of 3)'
taken='omacvm: full panel: strip taken again after a display change (try 1 of 3)'
covered2='omacvm: full panel: strip covered: full-screen Space 22, display 1728x1117, notch 32, menu bar hidden (Keep the Dock away)'
notback='omacvm: full panel: strip not back after a display change (AppKit kept the band, try 3 of 3): normal full screen until the next display change or full screen'
missing='omacvm: full panel: strip not back after a display change (selector missing: _NSFullScreenSpace -updateTileShapeAndReshapeContents is not there): normal full screen until the next display change or full screen'
menubar='omacvm: full panel: strip not back after a display change (menu bar always shown): normal full screen until the next display change or full screen'
tall='omacvm: full panel: strip not back after a display change (AppKit keeps a band taller than the camera housing: 44 pt, the housing 32 pt): normal full screen until the next display change or full screen'
lost='omacvm: full panel: strip lost: frame (0 0 864 1084) on display (0 0 1728x1117); normal full screen until the next one'
lostband='omacvm: full panel: strip lost: frame (0 0 1728x1084) on display (0 0 1728x1117); normal full screen until the next one'
went='omacvm: full panel: display change: the strip lost 0.4 s ago went with it; the strip comes back once the displays settle'

t ok "strip covered" "the strip covered" "$covered"
t warn "moved the window below the notch, the strip comes back" "a display change: warns until the strip is covered again" "$covered" "$moved"
t warn "normal full screen there" "on a display without a housing: warns" "$covered" "$moved" "$released"
t ok "strip covered" "taken again after a display change: covered (the same Space)" "$covered" "$moved" "$released" "$trying" "$taken" "$covered2"
t warn "normal full screen there" "'taken again' alone is not read" "$covered" "$moved" "$released" "$trying" "$taken"
t warn "moved the window below the notch, the strip comes back" "'taken again' after a display change alone: still warns" "$covered" "$moved" "$trying" "$taken"
t warn "leave full screen and enter it again" "strip not back: warns with the remedy" "$covered" "$moved" "$released" "$trying" "$notback"
t warn "selector missing" "strip not back (selector missing): says why" "$covered" "$moved" "$released" "$missing"
t warn "Automatically hide and show the menu bar: In Full Screen Only, or turn on Keep the Dock and hot corners away" \
  "strip not back (menu bar always shown): the menu bar setting is the remedy" "$covered" "$moved" "$released" "$menubar"
t warn "leave full screen and enter it again" "strip not back (a taller band): says both heights, warns with the remedy" \
  "$covered" "$moved" "$released" "$tall"
t warn "44 pt, the housing 32 pt" "... and the heights" "$covered" "$moved" "$released" "$tall"
t ok "strip covered" "a later strip covered wins over strip not back" "$covered" "$moved" "$released" "$notback" "$covered2"
t warn "macOS moved the window below the notch" "strip lost (Split View): as before" "$covered" "$lost"
t warn "moved the window below the notch, the strip comes back" "a strip lost that went with a display change: warns until covered" "$covered" "$lostband" "$went"
t ok "strip covered" "... then covered again" "$covered" "$lostband" "$went" "$covered2"
t skip "not in full screen" "no line yet"

echo "fullpanel-check: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
