# 0074: HDR only in full screen

Status: accepted, built (`hdr-fullscreen-only`, for 3.5.0), behind the app's
experimental switch `hdrFullScreenOnly` (off by default). Needs the app update
and Update VM; either alone changes nothing.

## Context

The user, 2026-11-14: "I still desire a much more efficent system, specially
on the m1 max, I see approx 2-3x less battery live than on mac os". Asked
which savings to build as experimental switches, the user picked "HDR only
when shown", stating the windowed-HDR limit and the Hyprland version limit.

With HDR on (ADR 0049) Virtual-1 is a 10-bit PQ output all the time. Chrome
then draws every page into an FP16 PQ layer, Hyprland converts in an FP16
pass, QEMU draws into 8-byte half-float surfaces, and the window's layer has
EDR. With HDR off all of that is gone. On the M1 Max (2026-10-25, brightness
0) HDR off took 2.8 W less on a YouTube clip and 6.5 W less on the work mix.
`pw-autohdr` (2026-11-12) showed the same for an SDR desktop with HDR in
reach: Chrome drew 8-bit (AB24) and no FP16 layer.

What Linux gives: no signal for "HDR content on screen" under an SDR
desktop. Chrome tone-maps HDR video into SDR itself and says nothing to the
compositor. Hyprland's own `render:cm_auto_hdr`:

- 0.56.2 (Omarchy 4.5) switches the output to PQ only for a full-screen
  surface that already set an HDR description; a surface is offered the
  output's sRGB description, so Chrome never does (pw-autohdr: HDR lost).
- 0.57 offers the full-screen surface PQ and switches, but it flips the HDR
  metadata in the commit of a frame rendered before the switch
  (`handleFullscreenSettings` runs after rendering): one frame would be shown
  in the wrong colours at every switch.

QEMU tags every 10-bit scanout PQ (`cocoa_gl_present_colorspace`), an 8-bit
one sRGB.

## Decision

**Full screen is the trigger, the scanout depth is the per-frame signal.**

- The guest's display agent (`omacvm-displays`) runs Virtual-1 at 8-bit sRGB
  (`bitdepth = 8, cm = "srgb"`, still `supports_hdr = 1` for KMS recorders,
  #579) while no window there is in Hyprland's full screen, and at today's
  10-bit PQ rule while one is: at once into full screen, 2 s after the last
  one is gone, never two switches within 1.5 s. Hyprland's auto HDR stays 0
  (omacvm_app.lua), on 0.56 and 0.57 alike.
- A cm change re-describes the output, and Hyprland tells every
  colour-managed client (`preferred_changed`); a bitdepth change makes the
  output's buffers again. Content, format and description change together in
  the next composed frame, so each frame carries its own colour in its depth:
  no kernel or protocol change.
- `omacvm-display-sync --hdr` sends only the HDR part of Virtual-1's last
  rule, under the same lock as a whole run, outside the loop guard (a
  full-screen flip is no layout change, so flips never count towards its
  60 s hold). The agent runs it in the background and keeps only the newest
  state; every Hyprland request has a time limit.
- QEMU never draws a frame into surfaces of the other colour
  (`omacvm-cocoa-present-depth-hold.patch`): such a frame is held until the
  hold-off ends, then the right surfaces are made and the newest frame drawn.
  This fixes a bug of its own: two depth changes within the hold-off showed
  PQ codes as sRGB for up to half a second. Unconditional in HDR runs.
- While the frames are 8-bit, QEMU tells the guest the headroom the display
  had while PQ showed (else its most, capped 16), not the ~1 the panel falls
  to without EDR; after the frames turn PQ, not less until macOS's ramp is
  done (3 s). Same rule as PR #709's.
- The switch is the app's key `hdrFullScreenOnly`, read live by QEMU (KVO),
  passed to the guest as `"hdr_follow": true` in Virtual-1's layout entry
  (only while on). Off: the layout, the headroom and the monitor rule are
  exactly as before.
- The agent declines (PQ as before, the reason in
  `display-sync/hdr-follow` for `omacvm check`) when Hyprland's
  `render:cm_auto_hdr`, `render:direct_scanout` or `quirks:prefer_hdr` is
  on, monitors.lua has the user's own rule for Virtual-1, or Hyprland refused
  the 8-bit rule.

## Alternatives

- **Forward the connector's HDR_OUTPUT_METADATA EOTF per frame** (a
  virtio-gpu command before RESOURCE_FLUSH, QEMU retags each frame) with a
  10-bit sRGB desktop and Hyprland's auto HDR: size L (guest kernel, QEMU
  validation), does not fix 0.57's one-frame-late switch, does nothing on
  0.56, and saves less (half-float surfaces stay). Kept as the fallback if the
  8 <-> 10-bit flip glitches on screen.
- **Count only full-screen windows that play video** (inhibitingIdle,
  contentType): a full-screen terminal would stay SDR, but a full-screen HDR
  still image would not switch. Left for measurement.

## Consequences

- HDR in a window shows as SDR (Chrome tone-maps it). Any full-screen window
  turns HDR on, also a terminal, and costs what HDR costs today. The desktop
  composites at 8 bits, as with HDR off.
- Only the main window's display; other displays stay 8-bit SDR as before.
- Full-screen video saves nothing; the saving is in windowed use. Watts go
  into the row's (i) only from this build's own M1 Max A/B/B/A rows.
- macOS keeps the panel's headroom up about 15 s after the last EDR frame
  whatever QEMU does.
