# The person's path, end to end (release gate)

`cc-switches.sh` runs what a person does with OmacVM.app and its control
centre, on a real VM, and checks every answer. `src/release/release.sh` runs
it as a gate (step `e2e`): no release is published unless it passed for the
release commit, or an override with a reason is written down.

Why: on 2026-10-07 3.0.3 shipped with the fast network switch stranding a
running VM, the control centre's switches failing after an app update and
Touch ID refused on its first request after a Bridge restart. Every unit test
was green; nobody had pressed the switches in a real VM.

## What it does

| Step | What a person does | What is checked |
|---|---|---|
| prepare | Update VM in the app's window | the VM gets this app's OmacVM (`omacvm-version`, `logs/update.log`) |
| baseline | opens the control centre | it comes up "Mac linked", no row failing; `omacvm vms --json` reachable |
| switches | Space on every row, off and on (yes to questions) | the row's answer, `/etc/omacvm/env` and the VM folder's `features`, the Bridge's `job ... ended 0`, no refusal (409, unknown-vm) in its log, reachable |
| fastnet | Fast network on and off with the VM running, then each after a restart | the cc's answer, reachable, internet in the VM, `logs/network` (vmnet / user) |
| touchid | Touch ID on, restart, `sudo` (stand-in yes, then no), Bridge restarted then `sudo` at once, off | in without a password / the password prompt; the Bridge's log |
| graphics | Graphics: OpenGL, Vulkan (restart), Automatic | `omacvm graphics --json` agrees; this start is Vulkan |
| updates | U, c (check again) | no error; the Bridge's `update check: X (N parts)` |
| window | Check Now, the Fast network switch (Turn On…/Turn Off… before 3.0.5) in the app's window (VM stopped) | no error in the window; the VM's `fast-network` file |
| keys | (none: key events with exact flags go into the VM's QEMU only, `modifier-keys.sh`) | Shift+2 as the Mac's keyboard sends it; Shift's flagsChanged twice, or an event without flags right after it (Universal Control, #412); left and right Shift, Option, Control; Command without the keyboard; Caps Lock; a held key: the guest's virtio keyboard shows exactly those keys |
| unplug | a 6K virtual display plugged in and taken away while the VM's window is on it (`display-unplug.sh`): full screen with one window per display (3 times), Full screen including notch (a made-up notch, twice), a window (VM stopped first; not with `--hidden`) | the same QEMU runs on 8 s after each unplug, the VM answers over SSH, no new crash report (#402) |
| update | the release before installed, its Update VM, the features a new VM has, its control centre (`previous-*`); the app updates itself to this build (local feed, throwaway key); Update VM; every switch again | the app's version and signature, `update.log`, the switches as above |

The control centre is the real one: `omacvm` in tmux, started in the desktop
user's service manager (`systemd-run --user`) as a terminal on the desktop
is, so Touch ID's PAM client sees a local session. Keys go in with
`tmux send-keys`; answers are read from the terminal's screen
(`guest-cc.py`). The app's window is driven through Accessibility on the
launcher's own pid (`ax.swift`).

The Bridge takes at most 20 jobs an hour per VM (`jobsPerHour`); one pass
sends about 50. The count lives in the Bridge's memory, so the test starts
its test Bridge again before a step would go over it, and waits until the
control centre has asked the new one. Before the update, the test Bridge and
Gestures (they run from inside a test app; a person's live outside it) are
stopped, else the updater waits ("A VM runs from OmacVM Test").

Touch ID needs a finger and a Mac with Touch ID. The test identity's Bridge
(`org.omacvm.test.bridge`, never a release Bridge) reads a stand-in file,
`~/Library/Application Support/omacvm-test-bridge/touchid-test`: `yes` or
`no` answers instead of macOS's dialog (the log says "test stand-in"). The
rest of the path is the real one: the VM's PAM client, the app's relay, the
Bridge's checks and the signed answer.

## Results

`~/omacvm-e2e/<time>/`: `summary.tsv` (one line per step: ok, FAIL, BLOCKED,
skip), `result.json` (what the gate reads: the app's commit, `pass`), the
screens (`cc-N-*.json`), `run.log`. FAIL: the product is wrong. BLOCKED: this
Mac cannot run the step until a person does something once (below). Both
fail the gate; a skip says why the step does not apply here (Omanotch on a
Mac without a notch, or on a Mac with a notch but no test Omanotch on port
47911: the person's own is never used).

## Someone at the Mac, CI jobs

A row is only worth something on a Mac nobody uses: a person's key or click,
or a Screen Sharing viewer that loads the Mac, can move what a row measures
(the 3.2.4 gate: a Shift key 20 ms early while a Screen Sharing session
connected in the middle of the run). So `cc-switches.sh`, `modifier-keys.sh`,
`display-unplug.sh` and `onscreen.sh` ask before each step and each case,
not only at their start (`person.sh`):

- Someone is there while a remote session is open (Screen Sharing: its
  "Remote user is connected", screensharingd, an established connection on
  port 5900; Jump Desktop: its rtcproxy or desktopproxy), also one nobody
  touches, or when input that was not ours came in the last 5 minutes. Our
  own events (keys posted to QEMU, the on-screen test's moves and clicks)
  reset macOS's HID idle time too: the harness stamps them
  (`~/Library/Caches/omacvm-e2e-last-input`).
- Then the run waits (at most 30 minutes each time, `PERSON_WAIT`) and goes
  on when the Mac is quiet again; someone who stays: the rest is BLOCKED.
  `onscreen.sh` waits only between two rows, with the app's and the VM's
  windows hidden meanwhile (as Command-H); inside a row it only looks, and
  someone there ends that row BLOCKED (out of full screen first).
- A watcher looks every 2 seconds and writes each foreign input and each
  remote session that opens or ends with its time (`person.log` in the
  results). Rows that ran while someone came and went get a `person` row:
  skip when they passed, BLOCKED when one failed (run it again on a quiet
  Mac).

`--pause-ci` (or `OMACVM_E2E_PAUSE_CI=1`) on `cc-switches.sh` and
`onscreen.sh` stops this Mac's self-hosted GitHub Actions runners for the
run (`ci-runners.sh pause`: `launchctl bootout` of each runner's LaunchAgent
once its job is over; queued jobs wait on GitHub) and starts them again at
the end, also when the run fails (`ci-runners.sh resume`, from the EXIT
trap, which no further Ctrl-C, hangup or lost ssh can stop half way). A
runner still on a job after 50 minutes would start its VMs during the rows:
`cc-switches.sh` stops then, `onscreen.sh` runs no row on screen (BLOCKED;
update-vm and leftovers headless). A run
that dies without its cleanup (`kill -9`) is covered as well: the pause starts
a guard in its own session that resumes once the run's process is gone (within
10 s; its log `~/.omacvm-ci-paused.log`). A kit that runs several harnesses
pauses once around all of them with its own holder pid. By hand:
`src/tests/e2e/ci-runners.sh status` (what was stopped is written down in
`~/.omacvm-ci-paused`).

Exit codes of `modifier-keys.sh` and `display-unplug.sh`: 0 every case
passed, 1 a case failed, 2 a wrong call, 3 it could not run (no VM, another
VM, a tool), 5 someone stayed at the Mac (BLOCKED rows). `onscreen.sh`: 0
passed, 1 a row failed, 2 a wrong call, 5 BLOCKED rows and no FAIL (someone
at the Mac, CI runners on jobs, `--headless`). `cc-switches.sh`
takes their rows; a code that its rows do not explain (3, a crash, its time
limit) is a FAIL row of its own, the time limit while it waited for someone
a BLOCKED one.

## The test Mac, once

- Apple Silicon, nobody working on it (it refuses with a battery unless
  `OMACVM_E2E_LAPTOP=1`, and waits while someone is at it: above).
- The test identity, granted once (Accessibility, Input Monitoring for its
  Bridge and Gestures; Accessibility for the shell that runs the test, for
  the window steps).
- A test VM in the test app's VMs folder with autologin on, kept for this
  (`--clone-from KEPT --vm NAME` makes an APFS clone per run and deletes it
  after).
- The fast network's service for the test app: `src/net/mac/install.sh
  --app ~/Applications/"OmacVM Test.app"` once (an administrator's password);
  without it the fast network steps are BLOCKED.
- `OMACVM_SIGN_ID` (the Developer ID) for the update path. A test Mac whose
  SSH session cannot reach the Developer ID in its keychain (the Mac mini)
  gets the test app built and signed on the release Mac: `OMACVM_E2E_APP`
  for `remote.sh`, or `--app` with a copied build.
- Runs from a copy of the checkout, never one being edited (bash reads a
  script as it goes). `OMACVM_E2E_LOCKS`: the lock folders to hold, a colon
  list (default: the mini's VM lock and the test identity's).

## Run it

```bash
# a test identity build of the commit to test
OMACVM_SIGN_ID=<Developer ID> app/scripts/build-app.sh --test-identity
src/tests/e2e/cc-switches.sh --app app/dist/"OmacVM Test.app" \
  --clone-from "Bench OmacVM" --vm "OmacVM M-e2e" --previous latest
```

From the release Mac (release.sh step `e2e` does this when
`OMACVM_E2E_SSH` is set): `src/tests/e2e/remote.sh COMMIT OUT_DIR` with
`OMACVM_E2E_SSH="ssh -i KEY user@test-mac"` and
`OMACVM_E2E_ARGS='--clone-from "Bench OmacVM" --vm "OmacVM M-e2e" --previous latest'`.

`--only prepare,baseline,switches` (any list) runs part of it while working
on a fix; such a run never counts for the gate.

## Override

`OMACVM_RELEASE_E2E_OVERRIDE="<why, in a sentence>" src/release/release.sh X.Y.Z e2e`
lets the release go out without the gate. The reason, the time, M and who go
into the release output folder's `e2e-override.log`; publish and after say
it again.

## On screen, before every publish (`onscreen.sh`)

`onscreen.sh` clicks through OmacVM.app as a person does, with real pointer
moves and clicks (HID events) and Accessibility on the app's own processes,
and checks what the screen shows. Why: 3.1.24 shipped with the Mac's arrow
over the VM next to Omarchy's pointer, the window was 20 pt smaller after
full screen (#452), the app's window opened as tall as the display (#458),
and a switch could not be used with the VM stopped (#445). No headless test
saw any of them.

| Row | What a person does | What is checked |
|---|---|---|
| window | opens the app on the VM (Run Without Installing when it asks); the green button, twice | 800 pt wide, at most 800 tall, centred on its display; still 800 wide after each zoom (a title-bar double-click posted as events does nothing on macOS 15, so the button stands in for it) |
| update-vm | Update VM in the window (the VM's OmacVM made older first) | `UPDATED`, the VM's OmacVM is the app's; a kernel question gets Later |
| switch-stopped | WebGPU and GPU compute with the VM stopped, then Start in the window | the switch can be used; record and pending file; qemu.log "switched while the VM was stopped: set up in the VM"; the second start switches it back |
| vm-size | the VM's window to full screen and back, twice | the same size after each |
| pointer | moves into the VM; a background program shows the cursor (as OmacVM Gestures did up to 3.1.24); Finder and back; the same in full screen; Graphics without QEMU's lock on, then off (switched in the window) | the Mac shows no cursor over the VM: `CGCursorIsVisible` false or an empty image; a picture of the spot when it does |
| leftovers | shuts the VM down from inside, closes its window, quits the app | no QEMU of the VM, nothing from the app (but its helpers) or on the VM's folder |

Real events where they work: the pointer, the switches and the sidebar get
HID events; the window's header buttons (Start, Update VM) get
Accessibility's press, as a posted click under the window's toolbar does
nothing (macOS 15), and so does a posted title-bar double-click (the zoom
button stands in). A copy outside the Applications folders asks to be
installed: the test runs it without installing. Helpers of the copy that the
run started (its Bridge) are stopped at the end.

On screen only while nobody uses the Mac: no input for 300 s but the test's
own (its last event, also a run's before, in `~/Library/Caches/omacvm-e2e-last-input`), no Jump Desktop or Screen Sharing session (also one left alone), the screen unlocked. Someone
between two rows: the app's windows hidden, a wait (above); someone inside a
row: that row BLOCKED. Someone who stays, CI runners still on jobs (with
`--pause-ci`) or `--headless`: the rows on screen are BLOCKED and
update-vm (update-vm.sh, as the window runs it) and leftovers (a start
without a window) run headless. `src/tests/e2e-onscreen.sh` tests the checks
offline (CI), `src/tests/e2e-person.sh` the waits and the exit codes.

```bash
# the release zip as the test identity (only org.omacvm.app.test: macOS's permissions are kept for
# that id and the Developer ID team, every copy and build has them; a lane's own id has none and
# its QEMU asked "would like to control this Mac" at every VM start). Hold ~/.omacvm-test-identity.lock;
# save the test app's settings first and put them back after (test-vms.sh: e2e_settings_save/restore)
OMACVM_SIGN_ID=<Developer ID> src/tests/e2e/relabel.sh OmacVM-X.Y.Z.zip ~/e2e/app
A=~/e2e/app/"OmacVM Test.app"
defaults write org.omacvm.app.test vmsRoot ~/e2e/vms
# a stopped test VM from the prebuilt image (a few minutes), in that VMs folder
OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=org.omacvm.app.test OMACVM_PASSWORD=<any> "$A/Contents/Resources/omacvm/omacvm" \
  build --yes --prebuilt --no-mac --vm-type app --vm-name "OmacVM M-e2e" --cpus 4 --memory-gb 4 --disk-gb 64 \
  --user omtest --full-name "OmacVM Test" --hostname omacvm-e2e --feature autologin=on --feature no-idle-lock=on
# the caller holds the Mac's VM lock; run it from a copy of the checkout (bash reads a script as it runs)
src/tests/e2e/onscreen.sh --app "$A" --vm "OmacVM M-e2e" [--only pointer,vm-size] [--headless]
```

About 10 minutes (two starts, Update VM). Results: `summary.tsv` (ok, FAIL,
BLOCKED, skip), `result.json` (`kind` omacvm-e2e-onscreen, `pass`, the app's
version and commit, macOS), `shots/` (pictures when the shell may record the screen, else only the
window's words), `run.log`. A release runs it on a test
identity build of M (or the release zip relabeled, `relabel.sh`) on each
macOS it has a Mac for (docs/releasing.md).

## The real present on a locked Mac (`present-locked.sh`)

`present-locked.sh` runs the present path a person's full-screen VM uses,
at a 5K or 6K guest size, with "Draw only what changed" in check mode
(`OMACVM_GL_PRESENT_TILES=check`: every 30th frame drawn in tiles is drawn
whole too and compared), while a guest pointer moves at the top right. It
runs on a locked test Mac, with nobody there. Why: 3.2.14 squeezed the tiles
right of x 4096 on pictures wider than 4352 pixels (#637), and no release
row saw it. 3.2.15's gate row for it said ok with 0 checks: it was a hidden
start.

A hidden start (`OMACVM_COCOA_HIDDEN`) is never ordered in, so its view's
display link never ticks: QEMU presents its first frames and then none
(no frame in tiles, no check). It still tests the guest (QEMU's own frame
timer keeps the guest drawing), the shaders building and the switch read,
never the tiles, the pacing or the window's picture. Here the test app's
window is ordered in on a virtual display made for the run
(`app/scripts/dev/virtual-display.m --while-locked`): under the lock macOS
shows none of it, and the window gets its display's frame clock (60/s) like
one a person looks at.

| Step | What | Refused or VOID when |
|---|---|---|
| may it run | the session locked (`person_locked`), no other VM (the person's would get a window on the new display), no `~/.omacvm-bench.lock`, memory level 40 or more and pressure normal, the VM at most 4 GB, `~/.omacvm-test-identity.lock` free | exit 3, nothing made |
| displays | every real display's mode (pixels, refresh) read; one virtual display at the size asked (HiDPI, 60 Hz), a new random serial and its own name; the modes read again | a mode changed: stop, exit 5, `needs-user.txt` (STANDARDS 32: never set back); macOS gave another size: VOID |
| settings | `presentTiles`, `startFullScreen` on; `pauseWhileHidden`, `hdr`, `extraBrightness`, `mediaControls`, `vsyncLock`, `pointerPlane`, `gpuSafeMode` off (GPU safe mode turns tiles off, the pointer layer takes the pointer out of the frame); `skipInstallPaths`; saved first and put back (`e2e_settings_save`/`_restore`) | |
| start | the test app in test mode: `OMACVM_TEST_SKIP_DISPLAYS` = the real displays, `OMACVM_TEST_MAIN_DISPLAY` = ours, `OMACVM_PRESENT_HIDDEN=1`, `OMACVM_GUEST_PAUSE=0`, the clipboard apart (`OMACVM_TEST_PASTEBOARD`) | a window of QEMU outside the virtual display, or none on it: the app killed, VOID (the launcher's windows are noted) |
| in the VM | the Mac links off and checked (STANDARDS 18a), Virtual-1's mode, whether the compositor's damage reaches QEMU (OmacVM's driver: `omacvm check`'s "Changed parts"), a uinput pointer at the top right for `--seconds` (120), then on in 10 s steps until QEMU's next minute line (it writes none at its stop) | links still on: FAIL |
| verdict | `present_verdict` (onscreen-lib.sh) on this run's qemu.log lines | below |
| end | the VM stopped, the display gone, the settings and the links put back; the modes again; tccd "Notifying for access", UserNotificationCenter's windows, WindowServer "setting mode", nehelper's Local Network line | a mode changed: exit 5 |

The verdict: FAIL when any check differed (a `tiles check N:` line with
pixels that differ, or N > 0 in any `N of M checks differed`). ok needs the
check on, the session locked to the row's end, a frame in tiles, at least
20 checks, the guest at the size asked (#637 shows only past 4352 pixels)
and the virtual display awake at the end. Anything else is VOID with its
reason: the row proves nothing and the release owes it. No frame in tiles
from a VM whose damage does not reach QEMU (an older guest without
OmacVM's damage driver: every frame whole) says so.
`result.json` (`kind` omacvm-e2e-present-locked) does not pass on VOID.

The display goes by itself when the session unlocks: macOS's unlock notice,
or the lock read every 0.5 s (CoreGraphics' session and the IORegistry's
console user), when the script ends, or after 45 minutes. Before it goes,
every process run from inside the test app is killed: a window left on a
display that goes moves to the person's display. The script watches the
lock every second too (the same order) and stops the VM at critical memory.
`--drill-unlock S` sends the display tool a private notice S seconds into
the pointer (never macOS's own notice: the person's app and QEMU's lock
watch listen to it): the app's processes must be gone before the display,
none of its windows on another display meanwhile; that row is VOID.

What it does not cover: WindowServer's composite (under the lock macOS puts
none of the window's frames on a screen: 0 of 900 drawables presented on
the locked M1 Max), the panel's own refresh and 120 Hz pacing (the virtual
display is 60 Hz), the hold for a window nobody sees (present-unseen:
`OMACVM_PRESENT_HIDDEN=1` skips it), and surface use counts as WindowServer
holds them. The look on a real panel stays a person's check.

```bash
# the caller holds the Mac's VM lock; the session is locked; a stopped test VM of at most 4 GB;
# new builds copied over the one test app folder (a new folder brings macOS's Local Network question)
src/tests/e2e/present-locked.sh --vm "OmacVM M-e2e" --size 5120x2880 --out ~/e2e/present-5k
src/tests/e2e/present-locked.sh --vm "OmacVM M-e2e" --size 6016x3384 --out ~/e2e/present-6k
```

About 3.5 minutes a run (203 s on the M1 Max: the start, the 120 s pointer,
30 s more for QEMU's minute line, the stop). One size per run (a second run makes a new display
with a new serial; never a mode switch in a loop). Results: `summary.tsv`
(ok, FAIL, VOID, needs-user, info, warn), `result.json`, `qemu.log` (the
run's lines), the display lists, `run.log`. Exit 0 ok, 1 FAIL, 2 usage, 3
not run, 4 VOID, 5 a real display's mode changed.
`src/tests/e2e-onscreen.sh` tests the verdict on saved qemu.log lines
(`present-logs/`: 3.2.15 and 3.2.14 on the locked M1 Max, 3.2.15's hidden
gate row), the guard and the display tool's `--while-locked` without a
display (`--dry-run`), offline in CI.

## Stale frames after focus changes (`stale-frames/`)

`stale-frames/stale-frames.sh --vm NAME` checks #167 (window borders left
half drawn after a focus change) on a running test VM. Each round changes
the focus between two windows (Hyprland's dispatcher, a uinput tablet
crossing into the other window, or quick changes back and forth), waits for
the border animation, and takes the guest's scanout buffer (`scanout-read.c`:
TRANSFER_FROM_HOST of the plane's framebuffer, no frame asked for) and the VM
window on the Mac (ScreenCaptureKit, also on another Space). Then `grim
/dev/null` makes Hyprland draw the whole output again and both are taken
again. Any pixel below the bar that changed is a stale frame: in the guest's
buffer, or on the Mac. A grim screenshot cannot show this itself: Hyprland's
screencopy damages the whole output first. `src/tests/stale-frames-diff.sh`
tests the comparison offline (CI).
