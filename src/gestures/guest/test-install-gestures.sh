#!/bin/bash
# Offline test of install.sh's Hyprland gesture lines (src/gestures/mac/test.sh):
# it adds a 3 and a 4-finger workspace swipe only for a count that has no
# sideways gesture yet (Hyprland refuses a second one, and a count the user
# gave to something else stays so); run twice, nothing more. Stand-ins for
# the root-only steps (packages, systemd, the daemon's file).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2" >&2; fail=1; fi; }
mkdir -p "$T/src/gestures/guest" "$T/src/guest" "$T/bin" "$T/home/u/.config/hypr"
cp "$HERE/install.sh" "$HERE/omacvm-gestures" "$T/src/gestures/guest/"
cp "$HERE/../../guest/home-files.sh" "$T/src/guest/"   # install.sh writes the home through it
# python-evdev stands in for itself: the daemon reads the gestures (--sideways).
mkdir -p "$T/py"
printf '%s\n' 'import itertools' 'n = itertools.count(1)' 'class Any(int):' \
  '    def __getattr__(self, name): return Any(next(n))' '    def __call__(self, *a, **k): return Any(next(n))' \
  'def __getattr__(name): return Any(next(n))' > "$T/py/evdev.py"
printf '#!/bin/sh\nexit 0\n' > "$T/src/guest/pkg-add"; chmod +x "$T/src/guest/pkg-add"
for c in install systemctl chown; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
printf '#!/bin/sh\necho "u:x:1000:1000::%s:/bin/bash"\n' "$T/home/u" > "$T/bin/getent"; chmod +x "$T/bin/getent"
I=$T/home/u/.config/hypr/input.lua
run() { PYTHONPATH=$T/py PATH="$T/bin:$PATH" bash "$T/src/gestures/guest/install.sh" u > /dev/null; }
lines() { grep -Ec "^hl\.gesture\(\{ fingers = $1, direction = \"horizontal\", action = \"workspace\" \}\)" "$I" || true; }

printf '%s\n' '-- Enable touchpad gestures for changing workspaces.' \
  '-- hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })' > "$I"
run
check '[[ $(lines 3) == 1 && $(lines 4) == 1 ]]' "a fresh input.lua (only Omarchy's commented example): 3 and 4-finger workspace swipes added"
run
check '[[ $(lines 3) == 1 && $(lines 4) == 1 ]]' "... run again: nothing more"
printf '%s\n' 'hl.gesture({ fingers = 3, direction = "left", action = function() hl.dispatch(hl.dsp.focus({ direction = "l" })) end })' \
  'hl.gesture({ fingers = 3, direction = "right", action = function() hl.dispatch(hl.dsp.focus({ direction = "r" })) end })' > "$I"
run
check '[[ $(lines 3) == 0 && $(lines 4) == 1 ]]' "3 fingers left/right move focus (the user's): only the 4-finger workspace swipe added"
printf '%s\n' 'hl.gesture({ fingers = 4, direction = "swipe", action = "move" })' > "$I"
printf '%s\n' 'hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })' > "$T/home/u/.config/hypr/gestures.lua"
run
check '[[ $(lines 3) == 0 && $(lines 4) == 0 ]]' "4 fingers to moving windows, 3 for workspaces in another file: nothing added"
rm -f "$T/home/u/.config/hypr/gestures.lua"
printf '%s\n' 'require("hypr.input")' 'require("hypr.windowsnap")' > "$T/home/u/.config/hypr/hyprland.lua"
: > "$I"
printf '%s\n' 'hl.gesture({' '  fingers = 3,' '  direction = "swipe",' '  action = { finish = function() snap() end },' '})' \
  > "$T/home/u/.config/hypr/windowsnap.lua"
run
check '[[ $(lines 3) == 0 && $(lines 4) == 1 ]]' "3 fingers snap windows (a table over several lines, another file): only the 4-finger workspace swipe added"
: > "$I"
PATH="$T/bin:$PATH" bash "$T/src/gestures/guest/install.sh" u > /dev/null   # no python-evdev: the one-line check
check '[[ $(lines 3) == 1 && $(lines 4) == 1 ]]' "... without the daemon's reader: the one-line check (misses that table)"

# No tap-to-click on the virtual trackpad (Omarchy 4.5 leaves Hyprland's default on:
# the start of a pinch was a two-finger tap, a right click). Once; the user's own kept.
rm -f "$T/home/u/.config/hypr/"*.lua
notap() { grep -cxF 'hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = false })' "$I" || true; }
: > "$I"
run
check '[[ $(notap) == 1 ]]' "tap-to-click off for the virtual trackpad"
run
check '[[ $(notap) == 1 ]]' "... run again: nothing more"
printf '%s\n' 'hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = true })' > "$T/home/u/.config/hypr/mine.lua"
: > "$I"
run
check '[[ $(notap) == 0 ]]' "the user's own tap setting for it (another file): nothing added"
rm -f "$T/home/u/.config/hypr/mine.lua"
: > "$I"
printf '%s\n' 'hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", accel_profile = "flat", natural_scroll = true,' \
  '            scroll_factor = 0.656 })' > "$T/home/u/.config/hypr/omacvm_glide.lua"
run
check '[[ $(notap) == 1 ]]' "scroll momentum's settings for the trackpad (no tap there): added"
: > "$I"
printf '%s\n' '-- hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = false })' > "$T/home/u/.config/hypr/mine.lua"
run
check '[[ $(notap) == 1 ]]' "a commented-out tap line (not a setting): added"
rm -f "$T/home/u/.config/hypr/mine.lua"
# The tap line first, a swipe added later: the gesture block still gets its header.
printf '%s\n' 'hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })' \
  'hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })' > "$I"
run
grep -v 'fingers = 3' "$I" > "$T/i" && cat "$T/i" > "$I"
run
check 'grep -q "^-- OmacVM trackpad: the Mac" "$I" && [[ $(lines 3) == 1 && $(notap) == 1 ]]' "a swipe added after the tap line: with its header"
# LUAC: a Lua 5.5 luac (CI's guest job builds one); else luac on PATH, if any.
LUAC=${LUAC:-$(command -v luac || true)}
if [[ -n $LUAC ]]; then
  check '"$LUAC" -p "$I"' "input.lua parses as Lua ($("$LUAC" -v 2>&1 | head -1))"
else echo "skip input.lua parses as Lua (no luac; LUAC=path)"
fi
exit $fail
