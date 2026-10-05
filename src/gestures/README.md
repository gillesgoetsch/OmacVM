# OmacVM Gestures

Mac trackpad gestures for the Omarchy VM in Parallels, UTM or VMware Fusion. The VM app gives
a Linux guest only a mouse (pointer, clicks, a wheel), so pinch and
3/4-finger swipes never arrive. This tool reads the trackpad's raw
finger contacts on the Mac (private MultitouchSupport framework) and replays
them on a virtual Apple touchpad in the guest, where libinput and Hyprland turn
them into real gestures. With **macOS-native scroll momentum** (experimental, per VM) it also carries
two-finger scrolling, with macOS's own acceleration and momentum.

**Capture mode** = Parallels, UTM or VMware Fusion is the frontmost app, its VM window fills a
display (full screen), and that VM's daemon is connected and wants the
trackpad. Then:

- macOS trackpad gesture events are dropped (event tap): no Spaces / Mission
  Control / Exposé / Launchpad / pinch on the Mac side;
- 3+-finger frames and 2-finger pinches go to the guest;
- pointer, clicks and two-finger scrolling stay on the VM app's own path;
  with scroll momentum, two-finger scrolling goes to the guest too (below);
- the Mac's pointer is hidden wherever the VM window is what a click would hit
  (the guest draws its own pointer), and shown over anything else (the
  Omanotch strip, the Dock, menus, another display);
- on UTM, VMware Fusion and OmacVM.app, Cmd shortcuts reach the guest as Super (a virtual
  keyboard). With the gestures feature off, the VM's daemon is off too (no link to the Mac's
  Gestures at all), and so is this.

**⌃⌥⌘ Esc** releases the trackpad to macOS (Omarchy shows a notification); it
re-arms when you come back to the full-screen VM, or press the combo again.
If the Mac helper stops, the tap goes with it and macOS has its gestures back.

## macOS-native scroll momentum

Turned on per VM (`omacvm enable scroll-momentum`; `OMACVM_FEATURE_scroll_momentum=on` in the VM's
`/etc/omacvm/env`). While two fingers touch the trackpad, every frame
goes to the guest, together with macOS's own scroll events for them (`A`, its
acceleration); macOS's scroll events no longer reach the VM app. After the
lift, macOS's momentum follows (`W`) and the guest continues the same virtual
touch with it, so apps see a finger glide and add no fling of their own. A
pinch is macOS's call (`P`). Details: `AGENTS.md` (Architecture) and the full
tuning log in `docs/experiments/trackpad-scrolling.md`.

| Part | Where |
|---|---|
| Mac helper | `mac/omacvm-gestures.c` (+ `mac/scroll_ns.m`): the built-in trackpad, else an external Magic Trackpad (MultitouchSupport also lists Magic Mice: told apart by a surface at least 100 mm wide); without either keys-only, checking every 10 s → `~/Applications/OmacVMGestures.app` (`org.omacvm.gestures`), LaunchAgent `org.omacvm.gestures`, log `~/Library/Logs/omacvm-gestures.log`. Listens on `10.211.55.2:47830`, `192.168.64.1:47830`, port 47830 of the `.1` of VMware Fusion's NAT network, `127.0.0.1:47830` and `192.168.77.1:47830` (OmacVM.app, its fast network: those clients count as the app's). Needs Accessibility + Input Monitoring. Options: `--keys-only` (no trackpad for any VM), `-v`, `--record` (`~/Library/Logs/omacvm-input.tsv`, Glide analysis) |
| Guest daemon | `guest/omacvm-gestures` → `/usr/local/bin/omacvm-gestures` (python-evdev, root), `guest/omacvm-gestures.service` (systemd, reads `/etc/omacvm/env`). Creates "Apple Inc. Magic Trackpad (OmacVM)" (Apple vendor id) and, on UTM, "OmacVM keyboard (Mac shortcuts)"; connects to the Mac. Glide settings: `OMACVM_GLIDE_*` (defaults = the tuned values) |
| Its Hyprland settings ("Glide" in the code) | `guest/glide.sh <user> on\|off` → `~/.config/hypr/omacvm_glide.lua` (required from `hyprland.lua`), `--disable-smooth-scrolling` for Chromium/Chrome |
| Hyprland | `~/.config/hypr/input.lua`: `hl.gesture({ fingers = 3/4, direction = "horizontal", action = "workspace" })` |
| Probe | `probe/probe.c`: raw frame + event-tap feasibility probe (`./probe 30` observe, `./probe 30 block` drop gestures) |

Install / remove on the Mac: `mac/install.sh`, `mac/uninstall.sh` (or
`omacvm apply` / `omacvm uninstall`). Guest: `guest/install.sh <user>` (root,
in the VM; `omacvm apply` runs it).

Protocol (TCP, one line each): see the header of `mac/omacvm-gestures.c`
(`F`, `S`, `O`, `A`, `W`, `P`, `K` to the guest; `R <gestures> <glide> <proof> <name>`
from it, with the VM's name in base64). First both sides prove they know the
Bridge's token (HMAC-SHA256 over two nonces and the Mac address the helper
accepted on, the Mac first), so the token never goes over the wire and the VM
ignores a listener that cannot prove it (on 127.0.0.1, for OmacVM.app, any Mac
program could listen; a proof it fetched from the helper on 10.211.55.2 names
that address and fails). Daemons from before
that send `H <gestures> <glide> <token> <name>` and are still let in; daemons
without a token (OmacVM 2.3 and older) are refused until `omacvm update`. With two VMs in one app, only the VM named in the title of the app's
front window gets the trackpad and the keys; without a match every VM of that
app does.

Verified on macOS 15.7.4, Parallels 27.0.2, MacBook Pro M4 Max: 4-finger and
3-finger swipes switch workspaces, pinch zooms in Chrome, macOS Spaces swipes
blocked while captured, ⌃⌥⌘ Esc releases and re-arms; the scroll momentum's glide distance
within 5-10 % of macOS's, with the same decay.
