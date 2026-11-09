# 0072: Firefox's wake locks and the guest idle hold

Status: accepted, built (`f-ff`, for 3.4.2, #750), OmacVM.app only, always on
(no switch). Amends [0070](0070-display-awake-for-video.md). Needs Update VM
only (the Mac side is 3.3.1's), then a restart of Firefox.

## Context

Since 3.3.1 the Mac's display stays on while a video plays in the VM (ADR
0070), but not for a video in Firefox, on Omarchy 4.0 and 4.5 alike (#750,
found by the 4.5 sweep). Firefox (`widget/gtk/WakeLockListener.cpp`, the same
in 158.0, 159.0 and 159.0.1) keeps one wake lock route for the whole browser.
It tries `org.freedesktop.ScreenSaver` first; on any error it moves every
wake lock to the next route for good (`SwitchToNextWakeLockType`):
FreeDesktop Power (nobody serves it), the portal (not in Omarchy's session),
then Wayland's idle inhibit. The display agent answered every caller that is
not Chromium with an error, and Firefox never got to Wayland: its window's
`inhibitingIdle` stayed false. With nobody serving the name (before 3.3.1) it
was the same, so this is not a regression; Firefox never had a working route
here.

What Firefox 158 sends to a ScreenSaver that accepts (a stand-in in a test
VM, work notes of `f-ff`): its main process (the pid Hyprland gives its
window) calls `Inhibit` with a reason from its `dom.properties`: "Playing
video" for a playing video with an audio track (also muted), "Playing audio"
for sound, "Screen lock" for a page's screen wake lock; "Autoscroll" and
"Download in progress" exist too. A video without an audio track takes no
lock. It sends `UnInhibit` at the pause, and 1.7 s after its window goes to a
workspace that is not shown; on quit or a crash its bus name goes away about
3 s later.

A second gap: Omarchy's own idle (the shell's Quickshell `IdleMonitor`,
`respectInhibitors: true`; screensaver at 150 s, lock at 300 s, on 4.0 and
4.5) waits only for Wayland's idle inhibitors. Chromium and mpv hold one;
Firefox, told only over D-Bus, does not. With a Firefox video playing and no
input, Omarchy's screensaver came at about 150 s and the session locked at
about 300 s (4.5 test VM). The screensaver is a full-screen window over the
video, so the video's output stops counting and the Mac's display sleeps
anyway. Accepting the D-Bus call alone would gain about 30 s.

## Decision

1. **The display agent** (`omacvm-displays`, `DisplayLocks`) gives every
   Gecko-based caller (`libxul.so` beside the program: Firefox, its forks,
   Thunderbird) a cookie, never an error, also when its 64 locks are full
   (then the cookie is not kept and never counts). Its reason decides:
   "Playing video" and "Screen lock" count (Firefox's own en-US names and the
   fallback in its code: the same two kinds as Chromium's display locks), and
   so do their translations in every language pack installed with that
   Firefox (`browser/extensions/langpack-*.xpi` beside the program, its
   `dom.properties` `WakeLockVideoPlaying` and `WakeLockScreenLock`, read
   again when that folder changes): a Firefox in German sends "Video
   abspielen". Every other reason never counts. A reason the agent does not
   know is logged once. Everyone else (mpv, SDL, Python, gdbus) still gets the error.
2. **Which window**: a window counts when it asks Wayland not to idle (as
   before) or its process holds a counting Firefox lock; every other rule of
   ADR 0070 applies unchanged (no `idle_inhibit` window rule, a shown
   workspace on a Mac output that is on, not under another full-screen
   window, mapped, not hidden, the session not locked). Release, also as for
   Chromium: `UnInhibit`, the caller leaving the bus, its pid getting another
   process; the agent's next check (at most 10 s) sends the new list; the
   Mac's 30 s lease and powerd's 45 s timeout are unchanged. Firefox never
   renews a lock, so there is no per-lock expiry: it would end a long video.
3. **The guest idle hold** (`GuestAwake`, `omacvm-awake.qml`): while a window
   counts through a Firefox lock, the agent runs `quickshell -p
   /usr/local/lib/omacvm/omacvm-awake.qml` as its own child (in the agent's
   cgroup, so it goes when the agent stops or dies) and writes the lease
   `$XDG_RUNTIME_DIR/omacvm/guest-awake` (`{"until": now + 25 s}`) at each
   check. The QML is a 1x1 transparent layer surface at the top left (Top
   layer, an empty input mask, no exclusive zone) with an `IdleInhibitor`.
   The child quits when the lease is missing or stale: a hung agent lets go
   within about 30 s. Hyprland 0.56 (`CInputManager::recheckIdleInhibitorStatus`)
   looks at the inhibitors only when one is made or goes and when a window
   maps or unmaps, and counts a layer surface's only while it is mapped: an
   inhibitor made before the surface maps never counts, and one switched off
   and on starts Omarchy's idle timers again. So the inhibitor is made once,
   2 s after the surface is shown (Quickshell's `backingWindowVisible`; a
   timer from the start could fire before a slow guest maps the surface),
   and never switched; the lease ends the process
   instead. (The first build switched it with the lease and made it at once:
   Omarchy's screensaver came at 150 s and the lock at 300 s in row R7; the
   plan step's spike had held only because Firefox's own window mapped after
   the spike's surface.) Hyprland counts a mapped layer surface's inhibitor
   whatever the layer, so nothing has to sit above a full-screen video. The child is stopped when no
   Firefox window counts, on SIGTERM, and a leftover lease is removed at the
   agent's start. Quickshell leaves a folder per instance in
   `$XDG_RUNTIME_DIR/quickshell` (by-id/<id> with its logs, lock and IPC
   socket, about 6 KB, linked from by-pid/<pid>) also when it quits by
   itself; the agent removes its child's once the child has gone, or every
   play would leave one in the session's RAM until logout. A start whose surface is not in Hyprland's `j/layers`
   within 15 s fails, and so does a child that ends; after 3 failures in a
   row the agent stops trying until it restarts and logs it once (the Mac
   side still works). A shown surface clears the count, so a child that held
   and then quit (a stale lease after the guest's clock jumped, Hyprland slow
   to answer, killed by hand) is started again however often that happens. Chromium and mpv
   never get it: they hold Omarchy's idle themselves.

## Consequences

- A video in Firefox keeps the Mac's display on while it can be seen, as in
  Chromium; a page's screen wake lock too. Music, autoscroll and downloads
  do not. A video without an audio track does not (Firefox takes no lock);
  a muted video with one does, as Chromium does for a large muted video.
- The VM's own screensaver and lock now wait while a Firefox video can be
  seen, as they do for Chromium and mpv. A hung Firefox with a visible window
  keeps the session unlocked and the Mac's display on, as a hung Chromium
  does (ADR 0070's reading of "stuck").
- A Firefox that was running during Update VM got the old agent's error and
  stays off this route until it restarts: restart Firefox once after Update
  VM (CHANGELOG, troubleshooting 56). A call that falls in an agent restart
  does the same.
- One lock per process: with two Firefox windows on two shown outputs, both
  count while one plays (Firefox lets go 1.7 s after the playing window is
  hidden). Chromium has the same kind of imprecision.
- Firefox sends its reasons in its interface language: Firefox 158 with
  `firefox-i18n-de` and a German interface (its about:support titled
  "Informationen zur Fehlerbehebung") sent "Video abspielen" and
  "Audiowiedergabe" (row R16; the plan step's spike had seen English only
  because its interface had stayed English). Language packs installed with
  Firefox are read; one a person installed into their profile is not: then a
  video does not count and the agent logs the reason once. Flatpak or Snap
  Firefox (its program inside its own mount namespace) is not detected and
  keeps getting the error.
- One more Quickshell process (about 128 MB resident in the test VMs) only
  while a Firefox video counts.
- Checked on Omarchy 4.5 (Quickshell 0.3.2, Hyprland 0.56.2, Firefox 158) and
  4.0 (Quickshell 0.3.2, Hyprland 0.57.1, Firefox 159.0.1): with a Firefox
  video and no input for 330 s, no screensaver and no lock; after the pause
  the screensaver came about 150 s later, as after a Chromium pause on the
  same VM. If a later Quickshell cannot load the QML, the agent gives up
  after 3 failed starts in a row and only the Mac side works.
- The 1x1 surface takes no input (empty mask, pinned by a test). Row CLICK2
  on 4.5 and 4.0: with the bar hidden, a window that logs clicks sat at
  layout 0,0; a click at 0,0 reached it without the helper and with it
  (its layer at 0,0 on Top), and did not reach it with the same surface
  without the empty mask beside it (the control).

## Rejected

- Accepting the D-Bus call only: Omarchy's screensaver covers the video at
  150 s, the output stops counting, the Mac's display sleeps soon after.
- A Hyprland window rule or the `noidle` tag on Firefox's window
  (`hl.dsp.window.set_prop`): Omarchy's screensaver still came at 150 s. It
  was measured on a window that was already mapped, where Hyprland may not
  look at idle again; but a static rule cannot follow play and pause anyway.
- `MOZ_WAKE_LOCK_TYPE=WaylandIdleInhibit` in the session: Firefox would then
  inhibit for music, downloads and autoscroll alike, and nothing could tell
  them apart.
- A per-lock expiry: Firefox takes one lock per play and never renews it.
- An OmacVM plugin in Omarchy's shell: a plugin install restarts the shell
  and is staged under a lock, it would run all the time, and 4.0's plugin
  support is not known. A systemd user unit: the agent's own child needs no
  unit file, no `systemctl` calls and no leftover cleanup, and it cannot
  outlive the agent.
- The Overlay layer for the surface: not needed (see Decision 3) and not
  tested.
