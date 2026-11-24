# 0075: The Mac pointer: aquamarine sends cursor hotspots, in a build of our own beside Omarchy's

Status: proposed (`mac-pointer-hotspot`), behind the app's hidden
`macPointer` setting (off). Every start without the setting runs as before.

## Context

The app's "Mac pointer for the VM" makes the image the guest puts on
virtio-gpu's cursor plane the Mac's own cursor (`omacvm-cocoa-hw-cursor.patch`,
3.2). macOS then moves the pointer itself: no guest frame, no pointer layer
of QEMU's, no wait. It never ran: since Linux 6.8 a virtual GPU
(`DRIVER_CURSOR_HOTSPOT`) hides its cursor plane from an atomic client that
does not set `DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT`, and Hyprland's aquamarine
sets neither the cap nor the plane's `HOTSPOT_X` and `HOTSPOT_Y` (0.15.1,
0.16.0, main on 2026-11-16). The Mac needs that hotspot: it places the image
by it. The pointer layer of [0054](0054-pointer-on-its-own-layer.md) gets
around the rule with a kernel option and no hotspot, which is enough for a
picture drawn at the plane's top left and not for a Mac cursor.

What else was looked at:

- aquamarine's legacy path (`AQ_NO_ATOMIC=1`): the kernel shows the plane to
  a non-atomic client and takes the hotspot from `drmModeSetCursor2`, with
  no build at all. But it has no damage clips ("Draw only what changed") and
  no HDR metadata, which an OmacVM.app VM uses.
- Upstream: hyprwm/aquamarine#372 is the same change (2026-08-31). A bot
  closed it unread: hyprwm takes pull requests from vouched contributors
  only. Omarchy carries its own aquamarine for aarch64 with patches
  (omacom/omarchy-pkgs), so the patch could also live there one day.
- A package of ours that replaces `aquamarine` (as `omacvm-vulkan-virtio`
  replaces `vulkan-virtio`): Hyprland is rebuilt against each aquamarine
  Omarchy ships, so a held package would break the desktop at the next
  update of Hyprland.

## Decision

1. **The patch** (`src/app/guest/aquamarine/aquamarine-cursor-plane-hotspot.patch`):
   the cap after `DRM_CLIENT_CAP_ATOMIC`, and `HOTSPOT_X`/`HOTSPOT_Y` next to
   `CRTC_X`/`CRTC_Y` for a new cursor image and for a move. The plane's
   position stays the pointer's place minus the hotspot, so the kernel's sum
   is the pointer's place. A driver without the feature refuses the cap and
   has no such properties: nothing changes on a real GPU or with
   `cursor_plane=1`. No public struct changes, as Hyprland is built against
   Omarchy's headers.
2. **A build beside Omarchy's package, never over it.**
   `omacvm-aquamarine-build` takes Omarchy's own recipe of the installed
   version, pinned in OmacVM (`src/app/guest/aquamarine/recipes`: per package
   version the omacom/omarchy-pkgs commit and the sha256 of each recipe file;
   the recipe's own sha256 sums pin its sources), adds the patch after
   the recipe's `prepare` with no fuzz, and runs makepkg as a user id of its
   own, without an archive or an install. Root takes only the library, and
   only when it has the installed library's soname, every symbol the
   installed one has, and the hotspot code. It goes to
   `/usr/local/lib/omacvm/aquamarine/<package version>/`, where ld.so does not
   look, with a stamp (the patch's sha256, the pin and the version) written
   last. Nothing unpinned is fetched: a version without a pin is not built.
3. **Loaded only in a start that asks.** At boot `omacvm-app-host` writes
   `/run/omacvm/mac-pointer.env` (`LD_LIBRARY_PATH=` that folder) only with
   `omacvm.hwcursor=1` and a build whose stamp fits the installed package
   (or `OMACVM_MAC_POINTER=omarchy` once Omarchy's own library sends the
   hotspots, omacom/omarchy-pkgs#2973: then no build is made or loaded). A
   drop-in of uwsm's compositor unit reads the file; `omacvm_app.lua` turns
   Hyprland's hardware cursor on only when the file is there. Any other
   start, a missing or failed build, or an aquamarine update without a new
   build runs Omarchy's library, and Hyprland draws the pointer itself.
4. **Built on request.** A VM that never asks needs no build: `omacvm apply`
   builds in a start that asks, or `sudo omacvm-aquamarine-build` by hand.
   No pacman hook: nothing of this runs inside a system update, and the next
   start after an aquamarine update runs Omarchy's library.
5. **Not with the pointer layer.** With `macPointer` the loader leaves
   `cursor_plane=1` out, as before: that plane has no hotspot, and QEMU would
   make a Mac cursor of an image whose hotspot it does not know.

## Consequences

- The pointer over the VM is the Mac's cursor: its lag is the Mac's own,
  whatever the VM does. What still goes through the guest is the shape (a
  new image when the pointer crosses onto text) and hiding.
- While a window is dragged, text is selected or a slider moved, the pointer
  is ahead of what it drags by the time the guest's frames take, more than
  with the pointer layer (which was one step ahead) and far more than with
  Hyprland's own pointer (drawn into the same frame).
- An aquamarine update needs the build again (3 to 10 minutes at the next
  Update VM, with the network), and a new version needs its pin in an OmacVM
  release first. Until then the VM has Hyprland's own pointer, not the
  pointer layer. `omacvm check`'s "Mac pointer" line says so.
- A version without a pin (a package from another repository, or one newer
  than this OmacVM) gets no build.
- What was checked, and what was not: docs/routes/app.md, "Mac pointer for
  the VM".
