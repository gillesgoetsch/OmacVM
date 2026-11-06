# 0070: The Mac's display stays on while a video plays in the VM

Status: accepted, built (`idle-inhibit`, for 3.3.1), OmacVM.app only, always
on (no switch). Needs the app update and Update VM; either alone changes
nothing.

## Context

The user, on battery with macOS's "turn display off" at 2 minutes: "it goes
display black every 2 minutes or so.. even when I'm in the vm watching a
video..". A Mac video player holds `PreventUserIdleDisplaySleep` while it
plays. Inside the VM the player asks the compositor not to idle
(`zwp_idle_inhibit_manager_v1`, which Omarchy's shell honours), but nothing
reached macOS: OmacVM.app's QEMU held only an App Nap activity that lets the
display sleep.

The user's rule: "behave similar to mac os, when watching a video or so not
go to sleep, but we don't want false positives as well, keeping the machine
awake when it shouldnt". So: the display only, never system sleep; nothing
held for a paused video, a background tab, music, a hidden or minimised VM
window, a locked screen, a closed lid, a paused VM or a stuck guest.

What Omarchy 4 has: no hypridle; idle is the shell's Quickshell
`IdleMonitor` with `respectInhibitors: true`. Hyprland 0.56.2's
`inhibitingIdle` in `j/clients` is true for a window whose app holds an
inhibitor AND for windows with an `idle_inhibit` window rule (Omarchy's
full-screen rules for some apps, its `noidle` tag). Chromium 156 and older
also inhibit for audio-only tabs, downloads and calls (fixed in 157 by
4dd9a00d80, a plain code change, no flag or switch). Omarchy's Chromium on
Arch Linux ARM is 156.0.8078.79 (2026-11-05); 157 reached Chrome's stable
channel on 2026-11-03.

What tells a video from music in Chromium 156: its wake lock's type.
`power_save_blocker_linux.cc` (the same at 153.0.8010.36, 156.0.8078.79 and,
but for the Wayland line, 157.0.8103.38) asks Wayland not to idle for every
type, but over D-Bus it tells `kPreventDisplaySleep` locks to
`org.freedesktop.ScreenSaver` and `kPreventAppSuspension` locks (music
"Playing audio", downloads, WebRTC) to `org.freedesktop.PowerManagement`,
each only if the name has an owner (after `org.gnome.SessionManager`, which
Omarchy has not). A display lock is Blink's "Video Wake Lock" (a playing
video on a visible page, at least 20 % of the view or with sound, or in
picture-in-picture; released on pause, end and a hidden tab) or a page's
screen wake lock: the same locks that Chrome turns into this assertion on a
Mac. Nothing in Omarchy owns `org.freedesktop.ScreenSaver` (checked in the
test VM: no ScreenSaver, PowerManagement or SessionManager on the session
bus). MPRIS (PlaybackStatus is Playing for music too, no video flag),
PipeWire (a browser's video is no PipeWire stream) and full screen (most
videos play in a window) do not tell them apart.

## Decision

1. **The guest** (`omacvm-displays`, the display agent already on
   `org.omacvm.display`) asks Hyprland every 10 s, with its layout compare,
   for `j/clients` (one request while nothing inhibits; Hyprland has no event
   for inhibitors). A window counts only when all hold:
   - `inhibitingIdle` is true and `j/getprop address:<a> idle_inhibit` is 0
     (no window rule: a full-screen terminal is no video);
   - its workspace is shown (the active or the shown special workspace) on a
     Mac output (`Virtual-N`) whose display is on, and no other window is
     full screen there; the window is mapped and not hidden;
   - the session is not locked (`omarchy-hyprland-session-locked`);
   - Chromium-based programs (`icudtl.dat` beside the program: Chromium,
     its web apps, Chrome, Brave, Electron apps) only while their process
     holds a display wake lock. The agent serves `org.freedesktop.ScreenSaver`
     on the session bus (`serve_display_locks`, Gio, in its own thread):
     a Chromium-based caller (by the pid the bus gives) gets a cookie, any
     other caller an error, so Firefox, SDL and the rest fall back as when
     nobody serves the name. A lock goes with `UnInhibit`, when its caller
     leaves the bus, or when its pid belongs to another process; at most 64.
     Also counted, by Wayland alone: the system's `/usr/lib/chromium/chromium`,
     not replaced on disk while it runs, with pacman's `chromium` 157 or
     newer (if another program owns the name).
   It sends `{"inhibit": ["Virtual-1", ...]}` at once on a change, again
   every 10 s while not empty, `[]` once (and on SIGTERM). No answer from
   Hyprland: nothing is sent. Omarchy's Stay Awake and OmacVM's no-idle-lock
   are never sent: they would keep the Mac's display on for good.
2. **QEMU** (`omacvm-cocoa-video-awake.patch`, rules in
   `ui/omacvm-video-awake.h`) holds `kIOPMAssertionTypePreventUserIdleDisplaySleep`
   "OmacVM: the VM is playing video" while the list is under 30 s old, one of
   its outputs' windows can be seen (the sight guest-pause uses: visible,
   not covered, not on another Space, the screen neither locked nor asleep,
   nobody else on the console) and the VM runs. Released at once on `[]`,
   at the lease's end, out of sight, the channel closing, the VM stopping
   (`qemu_add_vm_change_state_handler`), and on `NSWorkspaceWillSleep`. A
   line with more than 16 names or anything but `Virtual-N` is ignored.
3. **Backstop**: the assertion carries powerd's own timeout (45 s, action
   Release), armed again every 10 s with `IOPMAssertionSetProperty`
   (checked on the mini, macOS 27: re-armed at 3 and 6 s, a 5 s timeout held
   to 10 s; without, gone at 5 s). A stuck main thread cannot hold it; it
   dies with QEMU.

No switch and no settings row: a Mac player does the same by itself.
`OMACVM_VIDEO_AWAKE=0` leaves it out; `OMACVM_TEST_VIDEO_SEEN=1` (tests)
counts a hidden test window as seen and lets `org.omacvm.test.lock`
(`OMACVM_TEST_LOCK_HOOK=1`) stand for the test Mac's own lock, sleep and
console: a test Mac nobody sits at is locked. The real lock was shown on the
mini with the switch off: guest saying `inhibit`, nothing held.

## Consequences

- Only OmacVM.app: UTM, Fusion and Parallels cannot see the VM's window.
- A video in Chromium (156 now) and its web apps counts as on a Mac.
  Chromium has one Wayland inhibit per process, put on the window that has
  the focus when its first lock starts: with music in one Chromium window and
  a video in another, the first one's display counts (not tested;
  troubleshooting 56).
- Firefox was not tested.
- The agent now owns `org.freedesktop.ScreenSaver` in the session. Only
  Chromium-based callers get an answer other than an error; an app that
  only ever tries that name (and not Wayland) keeps its behaviour, as it
  got an error before too. A program installed later that wants the name
  (hypridle, a power manager) cannot take it while the agent serves it.
- A player that hangs while it holds its inhibit, in a window that can be
  seen, keeps the Mac's display on until the window is hidden or minimised,
  the Mac locks or the VM stops, as a hung Mac player does. "Stuck" in the
  user's rule is read as the agent or the VM being stuck (the lease and
  powerd's timeout cover those), not the app. Holding only while that
  output draws frames would cover it too (not built).
- Battery: while nothing plays one Hyprland request every 10 s in the agent
  (its loop already wakes then) and nothing on the Mac.
- Old guest with the new app: nothing sent, nothing held. New guest with an
  older app: the key is ignored.

## Rejected

- hypridle or logind's IdleHint: Omarchy 4 has no hypridle, browsers do not
  use logind's inhibitor on Hyprland.
- The Bridge (HTTP): it cannot see the VM's window and is an optional helper.
- `inhibitingIdle` alone: it counts Hyprland's own window rules.
- Counting Chromium only from 157 (the first build of this ADR): Omarchy's
  Chromium is 156, so a browser video, the user's case, went dark.
- A Chromium flag or switch for 156: 4dd9a00d80 has none.
- Watching D-Bus without owning the name: with no owner Chromium sends no
  `Inhibit`, and its release is never seen.
- A system-sleep assertion, or NSProcessInfo's `NSActivityIdleDisplaySleepDisabled`
  in the no-app-nap activity: either would keep the display on whenever the
  VM runs.
