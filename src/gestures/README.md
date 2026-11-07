# OmacVM Gestures

Mac trackpad gestures for the Omarchy VM in OmacVM.app. The VM app gives
a Linux guest only a mouse (pointer, clicks, a wheel), so pinch and
3/4-finger swipes never arrive. This tool reads the trackpad's raw
finger contacts on the Mac (private MultitouchSupport framework) and replays
them on a virtual Apple touchpad in the guest, where libinput and Hyprland turn
them into real gestures. With **macOS-native scroll momentum** (experimental, per VM) it also carries
two-finger scrolling, with macOS's own acceleration and momentum.

**Capture mode** = an OmacVM.app VM is the frontmost app, its window fills a
display (full screen), and that VM's daemon is connected and wants the
trackpad. Then:

- macOS trackpad gesture events are dropped (event tap): no Spaces / Mission
  Control / Exposé / Launchpad / pinch on the Mac side;
- 3+-finger frames and 2-finger pinches go to the guest;
- pointer, clicks and two-finger scrolling stay on the VM app's own path;
  with scroll momentum, two-finger scrolling goes to the guest too (below);
- where OmacVM.app has no Accessibility for its keyboard grab, Cmd shortcuts reach the guest as Super (a virtual
  keyboard). With the gestures feature off, the VM's daemon is off too (no link to the Mac's
  Gestures at all), and so is this.

**⌃⌥ Esc** releases the trackpad to macOS (no notice in Omarchy) and
moves the display under the pointer one Space toward the one it showed
before the VM, with macOS's own "Move left/right a space" shortcut as the
user set it (`com.apple.symbolichotkeys` 79 and 81; ⌃← and ⌃→ by default),
posted at the HID level once the combo's keys are up and marked so our tap
and OmacVM.app's QEMU let it through; macOS animates it as its own swipe
(`EscapeSwipe` = `all` in the `org.omacvm.gestures` settings: every display
that shows the VM, the pointer visiting each). The keyboard follows the
pointer's display. Pressed there again in macOS, it moves back. The VM is
never taken out of full screen and never hidden. Every move is checked: the
shortcut off or the Space unchanged -> a Dock swipe (macOS 15 ignores the
shortcut from the notched built-in display's full-screen Space); still
unchanged, or no Spaces information -> one log line, nothing else (no notice;
helpers up to 3.0.18 sent `N <why>`). A change that lands late is looked for
twice more before the next step, so one press never moves two Spaces. Mission
Control only on a double press (twice within 0.4 s; the second press drops
what the first has not posted yet). Back in, a shortcut that does not land brings the VM's window to the
front instead. In an OmacVM.app window the combo gives the keyboard to the
app from before (else Finder) and brings the window back. It re-arms when you
come back to the full-screen VM, or press the combo again.
If the Mac helper stops, the tap goes with it and macOS has its gestures back.

**Swipe out to macOS** (#342, opt-in: `SwipeOut` in `org.omacvm.gestures`, off by
default; OmacVM.app's "Swipe out to macOS", the control centre): a swipe of three or
more fingers past the first or the last workspace goes on to the macOS Space on that
side. The guest decides at the lift, with Hyprland's workspaces as they were when the
swipe began (`guest/omacvm-gestures`, `SwipeOut`): the way the swipe goes is the
workspaces' way (`gestures:workspace_swipe_invert`); past the lowest workspace of the
focused display = left; on the right the first swipe from the last workspace makes a
new empty one (as Hyprland does), a swipe past that empty one = right
(`workspace_swipe_create_new` off: the last one at once). Sideways travel at least
`OMACVM_SWIPE_OUT_MIN` (0.12, where Hyprland changes the workspace) of the trackpad's width, 1.5 times more sideways than up
or down; a Magic Mouse's swipe counts (its virtual fingers). It says `X left|right` over
its connection (only after the Mac's `X on`); the Mac takes it only from the VM in
front while captured, at most once a second, and moves the way ⌃⌥ Esc does
(`EscapeSwipe`), only to that side: no Space there = nothing at all. Hyprland's own
swipe may have made a new empty workspace meanwhile: the guest goes back to the one
the swipe began on. Tests: `mac/test-escape.c`, `guest/test-swipe-out.py` (a made-up
Hyprland), `mac/test.sh` 2b (the line over a real connection).

## macOS-native scroll momentum

On per VM by default (`omacvm disable scroll-momentum` turns it off; `OMACVM_FEATURE_scroll_momentum` in the VM's
`/etc/omacvm/env`). It takes only a trackpad's scrolling (built-in or Magic Trackpad, every one connected, also
later; `mac/scroll-model.h`, per scroll event: phases from a scroll that a trackpad's fingers make, and its
momentum). Wheel mice, smooth-scrolling mice and a Magic Mouse pass to the VM app one to one
(`mac/test-scroll.c`). While two fingers touch the trackpad, every frame
goes to the guest, together with macOS's own scroll events for them (`A`, its
acceleration); macOS's scroll events no longer reach the VM app. After the
lift, macOS's momentum follows (`W`) and the guest continues the same virtual
touch with it, so apps see a finger glide and add no fling of their own. A
pinch is macOS's call (`P`). Details: `AGENTS.md` (Architecture) and the full
tuning log in `docs/experiments/trackpad-scrolling.md`.

| Part | Where |
|---|---|
| Mac helper | `mac/omacvm-gestures.c` (+ `mac/scroll_ns.m`, `mac/scroll-model.h`): the built-in trackpad and every Magic Trackpad (MultitouchSupport also lists Magic Mice: told apart by a surface at least 100 mm wide), the one touching now sends its frames; looked for again every 10 s and 1 s after macOS adds a multi-touch device (one connected later or again, and the new device macOS makes for the built-in trackpad at a wake from deep sleep: the old one is let go); without any keys-only → `~/Applications/OmacVMGestures.app` (`org.omacvm.gestures`), LaunchAgent `org.omacvm.gestures`, log `~/Library/Logs/omacvm-gestures.log`. Listens on `127.0.0.1:47830` and `192.168.77.1:47830` (OmacVM.app, its fast network: those clients count as the app's). Needs Accessibility + Input Monitoring. Options: `--keys-only` (no trackpad for any VM), `-v`, `--record` (`~/Library/Logs/omacvm-input.tsv`, Glide analysis) |
| Guest daemon | `guest/omacvm-gestures` → `/usr/local/bin/omacvm-gestures` (python-evdev, root), `guest/omacvm-gestures.service` (systemd, reads `/etc/omacvm/env`). Creates "Apple Inc. Magic Trackpad (OmacVM)" (Apple vendor id) and "OmacVM keyboard (Mac shortcuts)" (Cmd as Super); connects to the Mac. Glide settings: `OMACVM_GLIDE_*` (defaults = the tuned values) |
| Its Hyprland settings ("Glide" in the code) | `guest/glide.sh <user> on\|off` → `~/.config/hypr/omacvm_glide.lua` (required from `hyprland.lua`), `--disable-smooth-scrolling` for Chromium/Chrome |
| Hyprland | `~/.config/hypr/input.lua`: `hl.gesture({ fingers = 3/4, direction = "horizontal", action = "workspace" })` |
| Probe | `probe/probe.c`: raw frame + event-tap feasibility probe (`./probe 30` observe, `./probe 30 block` drop gestures) |

Install / remove on the Mac: `mac/install.sh`, `mac/uninstall.sh` (or
`omacvm apply` / `omacvm uninstall`). Guest: `guest/install.sh <user>` (root,
in the VM; `omacvm apply` runs it).

Protocol (TCP, one line each): see the header of `mac/omacvm-gestures.c`
(`F`, `S`, `O`, `A`, `W`, `P`, `K`, `X on|off` to the guest; `R <gestures> <glide> <proof> <name>`
from it, with the VM's name in base64, then `X left|right`). First both sides prove they know the
Bridge's token (HMAC-SHA256 over two nonces and the Mac address the helper
accepted on, the Mac first), so the token never goes over the wire and the VM
ignores a listener that cannot prove it (on 127.0.0.1, for OmacVM.app, any Mac
program could listen; a proof it fetched from the helper on 192.168.77.1 names
that address and fails). Daemons from before
that send `H <gestures> <glide> <token> <name>` and are still let in; daemons
without a token (OmacVM 2.3 and older) are refused until `omacvm update`. With two VMs in OmacVM.app, only the VM named in the title of the app's
front window gets the trackpad and the keys; without a match every VM of that
app does.

Verified on macOS 15.7.4, MacBook Pro M4 Max (first in one of the retired VM apps, since 3.0 in OmacVM.app): 4-finger and
3-finger swipes switch workspaces, pinch zooms in Chrome, macOS Spaces swipes
blocked while captured, the escape combo (then ⌃⌥⌘ Esc) releases and re-arms; the scroll momentum's glide distance
within 5-10 % of macOS's, with the same decay.
