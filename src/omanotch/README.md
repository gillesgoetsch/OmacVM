<h1 align="center">Omanotch</h1>

<h3 align="center">Enabling the MacBook notch in Omarchy VMs</h3>

<p align="center">The real Omarchy bar, right where the VM app leaves a black hole.</p>

<p align="center">
  <b>Part of <a href="../../README.md">OmacVM</a></b>, which sets it up with the VM: the <code>omanotch</code> feature, on by default on a MacBook with a notch.
</p>

<p align="center">
  <img src="docs/hero.svg" alt="Animated diagram: the VM leaves the notch strip black; inside the VM Omarchy renders its bar on an invisible monitor; Omanotch streams the changed pixels into the strip, the windows grow to full height, and a click on the clock travels back and opens the calendar right below the notch." width="100%">
</p>

You run [Omarchy](https://omarchy.org) full screen in a VM (OmacVM.app, UTM,
VMware Fusion or Parallels) on a MacBook with a notch. The strip beside the
notch stays black, and Omarchy draws its own bar below it. **Omanotch** puts
Omarchy's **real** bar into that strip (the actual Quickshell bar, pixels and
all) and gives the space the bar used to take back to your windows.

<p align="center">
  <img src="docs/before-after.svg" alt="Before: a black strip above the VM plus Omarchy's bar inside it. After: the bar sits beside the notch and the windows use the whole screen below." width="100%">
</p>

## The black strip

In full screen the VM apps put their window *below* the camera housing. The
strip beside the notch (the menu bar's height, 43 points on a 16-inch MacBook
Pro at "More Space") stays black, and Omarchy's 26-point bar comes below it:
about 69 points of screen, gone. The VM cannot go up there:

- **Parallels** has no setting for it; its staff
  [said so on their forum](https://forum.parallels.com/threads/2021-16-macbook-fullscreen-over-notch.355917/).
- **UTM** 5.0.6 can draw into the notch area, but only on macOS 27.
- **macOS** lets only the app that owns a window place it next to the notch;
  moving the VM app's window there from outside is refused.

**But a tiny Mac app of our own can**, and it can show whatever the VM would
have shown.

## How the trick works

1. **An invisible monitor.** Inside the VM, Hyprland gets an extra, headless
   output called `NOTCH`: exactly as wide as your screen, exactly as tall as the
   bar. Nobody ever sees it. It sits *on top of* the real display's top edge,
   which sounds wrong but is the whole point — Parallels' mouse and UTM's USB
   tablet are mapped over the bounding box of all monitors, so an extra monitor
   anywhere else would shift every click.
2. **The bar, twice.** Omarchy's bar is cloned with Omarchy's own
   `omarchy plugin clone` and patched: one copy renders on `NOTCH` (the pixels
   you will see), the copy on the real display shrinks to 1 px and hides just
   off screen. It is not gone, though — your clicks are pressed on that hidden
   copy, so Omarchy opens its panels (clock, audio, network, …) on the visible
   display, right below the notch. The wallpaper is patched the same way: it is
   laid out once across the strip and the display, so with the bar hidden
   (Super+Shift+Space) the image runs straight through the notch strip.
3. **Streaming only what changes.** `notchcast`, a small C program in the VM,
   captures `NOTCH` with Wayland's `ext-image-copy-capture`. A capture only
   completes when Hyprland actually repaints, so an idle bar costs zero CPU. It
   sends just the rectangle that changed, LZ4-compressed — usually 0.5–3 KB —
   over the VM's private network. It finds the Mac by itself.
4. **A panel above everything.** *Omanotch.app* draws the frames in a
   borderless panel at window level 27 — above the menu bar (24) and above an
   invisible window Parallels and UTM keep over the strip (26). It never takes focus,
   so your keyboard stays with the VM. It lives on the VM's full-screen Space
   and slides with it when you swipe.
5. **Cursor juggling.** Over the strip, the Mac shows the *guest's* cursor
   images (sent over from the VM) while the VM hides its own; over the VM, the
   macOS cursor is hidden for real. One cursor at a time.
6. **Fail-safe.** The Mac app says "keep the bar parked" every second. If you
   leave full screen or the Mac app quits or crashes, the VM brings its bar
   back at once; if even the program in the VM dies, within 15 seconds.

## What it handles

<p align="center">
  <img src="docs/states.svg" alt="Animated loop: Omanotch bar beside the notch, a notification right under it, a theme switch, the bar hidden with the wallpaper running through the strip, full-screen video with a black strip, the lock screen with a black strip, 16/14/13-inch MacBooks with the notch gap staying aligned, and swiping Spaces with the strip travelling along" width="100%">
</p>

Notifications never cut into the strip, theme switches don't make it jump,
hiding the bar lets the wallpaper run through behind the notch, full-screen
video and the lock screen turn it black, and it follows you across Spaces and
MacBook sizes.

## Any notched MacBook

Nothing is tied to one model. The Mac app measures everything on the spot:
where the camera housing is, how tall the strip is, and how many guest pixels
land on one Mac point. 13- and 15-inch MacBook Air, 14- and 16-inch MacBook
Pro, any "Larger Text" to "More Space" setting — the invisible monitor, the
notch gap in the bar and every click follow along, also when you change the
resolution while the VM is running. If the VM's resolution does not match the
Mac point for point, the strip is scaled to fit instead of cut off.

## Requirements

- A MacBook with a notch, Omarchy full screen on the built-in display.
- UTM: **automatic mouse capture off** (UTM → Settings → Input → uncheck both
  *Capture input automatically…* options), or the pointer can never reach the
  strip. For a sharp strip turn on the display's *Retina Mode* and keep
  *Resize display to window size automatically* on.

## Install

[OmacVM](../../README.md) installs both sides (`omacvm enable omanotch` on an
existing VM). To work on Omanotch itself, from `src/omanotch` of an OmacVM
checkout: `./guest/install.sh` in the VM as your user, `./mac/install.sh` on
the Mac (builds `~/Applications/Omanotch.app`, starts it at login, logs to
`~/Library/Logs/omanotch.log`). `./guest/uninstall.sh` (with
`--remove-bar-clone` to drop the bar clone too) and `./mac/uninstall.sh`
remove them.

## Configuration

Mac app — `defaults write ch.gillesgoetsch.omanotch <key> <value>`, then
`launchctl kickstart -k gui/$(id -u)/ch.gillesgoetsch.omanotch`:

| Key | Default | |
|---|---|---|
| `vmOwners` | `Parallels Desktop`, `UTM`, `VMware Fusion`, OmacVM.app | apps whose full-screen window is the VM (`-array …`) |
| `vmInterfacePrefixes` | `bridge`, `vnic` | VM network interfaces the Mac listens on … |
| `vmSubnets` | `192.168.64.0/24`, `10.211.55.0/24`, `10.37.129.0/24` | … if their network is one of these (UTM, Parallels shared, Parallels host-only); guests are accepted only from that network |
| `listenHost` | *(automatic)* | listen on this one IPv4 address instead |
| `port` | `47811` | |
| `flush` | `false` | `true`: the bar is exactly as tall as the camera housing, as in OmacVM.app's notch-strip mode; the few points of the strip below it show the wallpaper. `false`: the bar fills the strip (macOS's menu bar height). Taken up within two seconds, no restart needed |

VM — `systemctl --user edit notchcast`, `Environment=…`:

| Variable | Default | |
|---|---|---|
| `NOTCHBAR_HOST` | *(automatic)* | the Mac's address (list allowed); by default the default gateway (UTM) and `.2` of that network (Parallels) are tried — only on a VM shared network, so set this for bridged networking |
| `NOTCHBAR_VM_NETS` | `192.168.64.0/24 10.211.55.0/24 10.37.129.0/24` | networks where the Mac is looked for automatically |
| `NOTCHBAR_PORT` | `47811` | |
| `NOTCHBAR_OUTPUT` | `NOTCH` | name of the invisible monitor |
| `NOTCHBAR_SCREEN` | `Virtual-1` | the built-in display's output; by default OmacVM.app names it (with external displays it can be `Virtual-2` or later) |
| `NOTCHBAR_FOLLOW_MODE` | on under QEMU (UTM) | `1`/`0`: when UTM resizes the display to its window while running, apply and keep that size (Hyprland does not pick it up by itself) |

## Good to know

- The lock screen turns the strip black too: Omarchy draws its lock screen,
  password field included, on every output, and nothing is streamed while the
  session is locked.
- Full-screen video (or anything in real fullscreen, Super+F) turns the strip
  black, like macOS does. Maximized and tiled-fullscreen windows keep the bar.
- Omarchy's notification popups keep their usual distance below where the
  bar *would* be (a bar's height lower than panels). The notification service
  takes that distance from the bar's size and runs cloned copies sandboxed, so
  Omanotch cannot change it without editing Omarchy's own files. The popups
  never reach into the strip, though.
- Hover effects (tooltips, hover highlights) are not mirrored; clicks, right
  and middle clicks and scrolling are. Tray icons show up but can't be clicked
  in the strip.
- The bar and background clones are forks of Omarchy's plugins. After an
  Omarchy update that changes them, re-clone and run `./guest/install.sh`
  again — the patches are versioned and refuse to apply blindly.
- Hyprland warns about overlapping monitors after layout changes. The overlap
  is deliberate; `notchbar.lua` dismisses that one warning and nothing else.
- Several VMs at once: the strip shows the bar of the VM whose window is full
  screen on the built-in display, and only that VM's bar is parked; the
  others keep their own bar. Omanotch needs no macOS permission for this: it
  knows the window's app (Parallels, UTM, VMware Fusion or OmacVM.app), not
  which of its VMs the window shows. With two VMs of one app connected, the
  strip keeps the one it serves, else takes the one that connected last;
  switching between them does not switch the strip.
- OmacVM.app's VMs reach the Mac at 127.0.0.1, where any Mac program could
  connect, or listen in Omanotch's place. There `notchcast` and the Mac first
  prove to each other that they know OmacVM's Bridge token (HMAC-SHA256 over
  two nonces and 127.0.0.1, the Mac first), so the token itself is never
  sent; a connection that has not proved it yet does not get in the way of a
  connected VM. The same on the app's fast network (vmnet, the Mac at
  192.168.77.1; the proof then names that address): `notchcast` takes it when
  it is the VM's gateway, and connects again when the app moves the VM between
  the two networks. VMs on Parallels, UTM and VMware Fusion skip this: their VM
  network is the check. The protocol is in `mac/Sources/GuestAuth.swift`.
- Keep UTM's library window and Parallels' Control Center out of full screen on
  the built-in display while a VM is connected: from the outside they look just
  like a full-screen VM.
- On an older Omarchy (up to about September 2026) the bar patch also makes the
  cloned bar loadable at all; newer versions don't need that.
- Cursor handling uses the window-server property `SetsCursorInBackground`,
  which is not public API (but widely used and stable for years).
- At the exact moment the pointer crosses into the strip you may catch a
  ghost of the VM cursor for a frame or two: the VM draws its own cursor and
  the display pipeline has a little latency.

## Tip: a macOS-style clock

With the bar in the menu-bar spot, a macOS-like clock at the far right feels
natural. In `~/.config/omarchy/shell.json`, move the `omarchy.clock` entry to
the end of `bar.layout.right`, give it `"format": "ddd MMM d HH:mm"`
(→ `Wed Sep 30 19:20`) and set `"centerAnchor": ""`. The shell picks the change
up by itself.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Strip stays black | `~/Library/Logs/omanotch.log` ("listening on …", "guest connected"?) · in the VM: `systemctl --user status notchcast` |
| UTM: the pointer never reaches the strip | UTM's automatic input capture is on (see Requirements), or press ⌃⌥ to release the mouse |
| UTM: with capture off the VM's cursor does not move | a SPICE agent (`spice-vdagentd`) takes UTM's absolute mouse positions: it must run with a real uinput device (not `-f`) and a session agent that reports the screen size — or not at all, then QEMU's USB tablet is used |
| Bar in the VM *and* in the strip | `omarchy-shell notchbar state` → `parked` should be `true` and `screen` the built-in display · `~/.local/state/omanotch/park` is what notchcast asked for (`1 <output>`); the bar follows it within 3 s, also after a shell restart |
| No bar for a few seconds after login (windowed VM) | the strip showed at the end of the last session, so the bar started in the strip (`~/.local/state/omanotch/expect` says `1 <output>`); Omanotch gives it back at once, an older Omanotch after 8 s, and the next login starts normally |
| OmacVM.app: the strip stays black | `~/Library/Logs/omanotch.log` ("refused a connection on 127.0.0.1: …", or on 192.168.77.1 on the fast network) · in the VM: `journalctl --user -u notchcast` ("answered no proof": the Mac's Omanotch is older than the VM's, update it) |
| Strip shows another VM's bar | two VMs of one app are connected: Omanotch tells apps apart, not VMs of one app (`~/Library/Logs/omanotch.log`: "strip serves guest …"); stop the other VM or restart its `notchcast` |
| Mouse lands in the wrong place | `hyprctl monitors` → `NOTCH` must have the built-in display's x and width, and sit at its position (OmacVM.app: right above it, touching its top edge) |
| Panels open on the wrong screen | `NOTCHBAR_SCREEN` must name the built-in display (OmacVM.app: `$XDG_RUNTIME_DIR/omacvm/builtin` does, `omacvm check` → "notch display") |

## Credits

- [Omarchy](https://omarchy.org) by DHH and contributors — the bar, the
  shell, the whole beautiful thing
- [Hyprland](https://hyprland.org) and [Quickshell](https://quickshell.org)
- Not affiliated with Omarchy, Parallels, UTM or Apple. Omarchy's bar and
  background code is not included here: it is cloned from your own Omarchy
  installation and patched at install time.

## License

MIT — see [LICENSE](LICENSE).
