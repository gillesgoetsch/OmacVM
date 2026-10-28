# 0015: One window per Mac display

Status: accepted. Built on `app-displays` (`omacvm-cocoa-displays.patch`,
`qemu-virtio-gpu-display-event-race.patch`, guest `omacvm-displays`), tested
on virtual displays only, not merged.

## Context

In full screen with an external monitor, users want Omarchy on every Mac
display at that display's resolution and scale, arranged as on the Mac,
following plug and unplug. QEMU's Cocoa display shows one console in one
window.

## Options

1. One big window spanning all displays, one guest output. macOS gives each
   display its own Space in full screen; a spanning window does not work
   there, and scale differs per display.
2. One window per display, one virtio-gpu output (console) per window.
3. One window, several guest outputs drawn side by side in it. Same Spaces
   problem as 1.

## Decision

Option 2: the main window is `Virtual-1`; each other Mac display gets a head
window with its own `DisplayChangeListener` and layer, sharing the main GL
context. Heads exist only in full screen, only after the guest agent said
hello, and only with "Use external displays" on. Positions and the toggle
travel over the virtio-serial port `org.omacvm.display` (Linux virtio-gpu has
no suggested position). One virtio-tablet; QEMU maps the pointer into the
bounding box of all monitors the guest reported.

## Consequences

- Native resolution and scale per display; arrangement and plug/unplug
  follow live.
- More windows means more focus and pointer-grab cases (only grab while the
  app is active; key window handover). Real full screen with Spaces on a real
  monitor still needs a person at the screen.
- The guest sends JSON that QEMU parses: numbers are type-checked and
  bounded, updates are rate-limited to one a second.
- Up to 5 outputs (`max_outputs=5`).
- Heads use `CAOpenGLLayer` today; with [0010](0010-iosurface-present.md)
  merged they should use the IOSurface present too.

## Addendum (2026-10-28): the pointer's place while another app is in front

In full screen on two displays the person can switch one display to macOS
(its Space) while the other still shows the VM. A Mac app is then in front
and QEMU lets go of the pointer. "Only grab while the app is active" above
made a move over the other display's window do nothing at all: the VM's
pointer stood still there until a click (no hover, scrolls at the old
place).

Options: take the pointer at the first move (takes the keyboard from the
Mac app every time the pointer crosses the VM: what the rule was for); hide
the Mac's cursor from the background (a missed exit leaves the Mac app
without a cursor); give the guest the pointer's place only.

Decision: the place only (`omacvm-cocoa-pointer-hover*.patch`,
`ui/omacvm-pointer-hover.h`). With OmacVM not in front, the VM on two or more
displays, an absolute pointer, no button held, Touch ID's panel down and the
window in full screen with nothing above it under the pointer, a move goes
to the guest's tablet and nothing else happens: no grab, no corner guard,
no key window, no activation. The keyboard stays with the Mac app. Both
pointers show on that display (the Mac's arrow over the guest's), as at
boot. A click takes the pointer as before. The main window's view gets a
second tracking area, active always, so the same holds when the main window
is the one still shown. `OMACVM_POINTER_HOVER=0` keeps the old way.

With "Pause drawing while hidden" each such move reaches the guest while the
other display is paused, and Omarchy's `misc:mouse_move_enables_dpms` woke
it at every move. The display agent holds that option (and key presses')
off while it holds a display off; both ship in the same release.
