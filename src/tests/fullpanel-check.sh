#!/usr/bin/env bash
# omacvm check's "full screen (app)" row for Full screen including notch
# (FullPanel): which of QEMU's lines it reads and what it says. Offline: the
# grep and the case block from src/cmd/check.sh on made-up qemu.log lines,
# among them the lines of a display change (omacvm-cocoa-fullpanel-retake.patch):
# "display change: ..." and "strip taken again" are not read, "strip not back"
# warns with the remedy, a later "strip covered" wins.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
c="$R/src/cmd/check.sh"
pat=$(grep -o "grep -E '^omacvm: full panel: ([^']*)'" "$c" | head -1 | sed "s/^grep -E '//; s/'\$//")
block=$(awk '/^    case \$nq in$/ {on = 1} on {print} on && /^    esac$/ {exit}' "$c")
[[ -n $pat && -n $block ]] || { echo "FAIL check.sh's FullPanel row is not where this test looks"; exit 1; }
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
covered2='omacvm: full panel: strip covered: full-screen Space 89, display 1728x1117, notch 32, menu bar hidden (Keep the Dock away)'
notback='omacvm: full panel: strip not back after a display change (AppKit kept the band, try 3 of 3): normal full screen until the next one'
missing='omacvm: full panel: strip not back after a display change (selector missing: _NSFullScreenSpace -updateTileShapeAndReshapeContents is not there): normal full screen until the next one'
lost='omacvm: full panel: strip lost: frame (0 0 864 1084) on display (0 0 1728x1117); normal full screen until the next one'

t ok "strip covered" "the strip covered" "$covered"
t ok "Space 22" "a display change line is not read" "$covered" "$moved"
t warn "normal full screen there" "on a display without a housing: warns" "$covered" "$moved" "$released"
t ok "Space 89" "taken again after a display change: covered" "$covered" "$moved" "$released" "$trying" "$taken" "$covered2"
t warn "normal full screen there" "'taken again' alone is not read" "$covered" "$moved" "$released" "$trying" "$taken"
t warn "leave full screen and enter it again" "strip not back: warns with the remedy" "$covered" "$moved" "$released" "$trying" "$notback"
t warn "selector missing" "strip not back (selector missing): says why" "$covered" "$moved" "$released" "$missing"
t ok "Space 89" "a later strip covered wins over strip not back" "$covered" "$moved" "$released" "$notback" "$covered2"
t warn "macOS moved the window below the notch" "strip lost (Split View): as before" "$covered" "$lost"
t skip "not in full screen" "no line yet"

echo "fullpanel-check: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
