# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 3.2.16 (unreleased)

- **Videos in Omarchy's Chromium loop, end and change size again (OmacVM.app).** When Chromium
  decoded a video on the Mac's media engine (the Chromium video feature), it stopped on the last
  picture: a looped video never started again, the page never got its `ended` event, and a Media
  Source stream stood still where its picture size changed (3.2.15 and older). At those points
  Chromium holds all of the decoder's picture buffers while the decoder still owes it the last
  pictures; the decoder answered Chromium's wait with an error, and Chromium 153 then never waited
  again. Now that wait sleeps until the pictures come. In a test VM on a Mac mini, 3 runs per row,
  before and after: a looped 6 s 2160p60 clip and a looped 30 s 1080p60 clip stopped at their end in
  6 of 6 runs before and looped in 6 of 6 after (the 4K clip 12 times in a 70 s run); the 4K clip
  without loop fired `ended` in 0 of 3 before and 3 of 3 after; a test page's Media Source stream
  that switches from 1080p to 720p at 6 s stopped at the switch before and played both sizes to its
  end after (one run each). Needs Update VM, then a restart of Chromium (if a video was open during
  the update, the new decoder loads at the VM's next start); nothing on the Mac, any app version.

## 3.2.15

In an OmacVM.app VM, apps keep their graphics at critical memory pressure when they only replace
buffers, and Chrome draws again by itself after it lost them; a Vulkan program can no longer stop
the VM with a command its device was not made for; "Draw only what changed" no longer squeezes wide
pictures; the Chromium (WebGPU) launcher plays videos; and a VM memory above the Mac's Best tier
says what it costs. With Hyprland 0.57, Omarchy's notifications, panels and menu are transparent
again, and HDR screenshots in OmacVM.app stay right. Needs the app update for the Vulkan checks, the
memory grace, the tiles and the memory texts (from the VM's next start), and Update VM or
`omacvm update` for the rest; on Hyprland 0.57 then log out and in, and quit Chromium before
starting Chromium (WebGPU) again. UTM and Parallels get the transparent panels with Hyprland 0.57,
fewer plugin reloads during an update, Omanotch's wait for a busy shell and the gestures daemon's
workspace names. VMware Fusion gets its Hyprland build for 0.57 (`omacvm update` before Omarchy
stable moves to 0.57), the same plugin and Omanotch fixes and the workspace names.

- **"Draw only what changed" no longer squeezes the right part of wide pictures (#637; reported by
  the user).** In an OmacVM.app VM with the experimental switch "Draw only what changed" on, a
  picture wider than 4352 pixels flickered at its right part while the pointer moved there: full
  screen on a 5K or 6K display, a 4K display set to look like more than 2176 points wide, a 24-inch
  iMac, or a window that wide. The changed parts right of pixel 4352 came out squeezed until the
  next whole frame (on a 5K display the last 768 pixels, so a line in the picture showed twice about
  128 points from the right edge). Apple's OpenGL squeezes a drawing that starts more than 4096
  pixels outside its target, and each changed part was drawn that way. Each part is now drawn inside
  its own surface. Found on a Mac mini with an LG UltraFine 5K. Needs the app update (from the VM's
  next start). Until then, switching "Draw only what changed" off avoids it (from the VM's next
  start).

- **A VM memory above the Mac's Best tier now says what it costs, and `omacvm check` says what
  Activity Monitor's number is made of (#633; reported by the user).** A 12 GB VM on a 16 GB Mac
  mini showed 23 GB in Activity Monitor: its graphics come on top of its memory (4.5 GB with Chrome
  at 5K there), and while macOS compresses the VM it counts part of it twice. In OmacVM.app the VM's
  General › Resources has an (i) that says so, and above the Best tier (8 GB on a 16 GB Mac) its
  orange note names the graphics on top with the last run's peak. `omacvm resources` gives the same
  warning (`"warning"` in `--json`), also when it only reads such a VM, and `omacvm check` has an
  "Activity Monitor" row while the VM runs: the number, the VM's memory, its graphics now and the
  rest (QEMU itself, graphics overhead, pages counted twice). Nothing lowers the setting by itself;
  the graphics stay outside it, with their runaway guard as before. Needs the app update (the window
  and its `omacvm`), or `omacvm update` for a command line install.

- **A program in the VM can no longer stop the VM with a Vulkan command its device was not
  made for, or with a buffer bound outside its memory (#629).** In an OmacVM.app VM with Graphics on
  Vulkan, a program that talked to the VM's Vulkan renderer directly could stop the whole VM: a
  command of a newer Vulkan version or of an extension its Vulkan device was not made with, one
  object named twice in one call, and a few other unusual requests made QEMU stop. A buffer bound
  partly outside its memory went through, which could let the Mac's GPU read and write outside
  that memory. Normal Vulkan apps go through Mesa in the VM, which does not send these. Now only
  that program's Vulkan connection ends, with the reason in the VM's log, and the VM goes on.
  See #624. Needs the app update (from the VM's next start).

- **While the Mac is short of memory, apps in the VM keep their graphics when they only replace
  buffers (#634; reported by the user).** While macOS's memory pressure was critical, OmacVM.app
  gave an app no new big graphics buffer (16 MB or more), and the app that made one lost its
  graphics: Chrome at its next window buffer (about 56 MB at 5K), and a Chrome started again at its
  first, for as long as macOS stayed critical (minutes on a Mac mini with 16 GB and a 12 GB VM). Now
  an app may replace its buffers there, and the VM's graphics may grow by a 32nd of the Mac's memory
  (256 MB to 1 GB; 512 MB on 16 GB) past what they used when critical began, in buffers that fit in
  what macOS has left; only growth past that stops an app, as before. The next item completes it: a
  Chrome lost past the grace gets a new GPU process from the VM. Needs the app update (from the VM's
  next start).

- **Chrome draws again by itself after it lost its graphics (#632; reported by the user).** When
  macOS ran short of memory (or the apps' share of graphics memory was full), an app's GPU context
  on the Mac was cut off so the desktop could keep drawing. The VM's graphics driver cannot tell the
  app, so Chrome kept drawing into the lost context: its windows went blank or flickered until it
  was quit, and the VM looked broken enough to restart (a Mac mini with 16 GB, Chrome at 5K). Now
  the VM ends the lost app's GPU process, and Chrome and Chromium start a new one within seconds;
  open tabs stay, pages with WebGL may need a reload (other Chromium-based apps such as Electron's
  have the same GPU process; not measured). At most once per app in 6 minutes and 3 times in an
  hour, as Chrome counts each as a crash and turns its GPU off after 3 in a short time; the note in
  the VM says what happened. Other apps get the note, as before. The item above completes it:
  without the app update, a Chrome started again while macOS stays critical loses its graphics again
  at once. Needs Update VM.

- **Videos play in the Chromium (WebGPU) launcher (#631).** In an OmacVM.app VM with Graphics on
  Vulkan, the "Chromium (WebGPU)" menu entry showed a video's first frames and then stopped: the
  first picture from the Mac's media engine restarted its GPU process, and every page's WebGPU with
  it. It now decodes video on the CPU (a 1080p30 clip at 29.8 fps, 30 decoded, none dropped). The
  normal Chromium entry keeps decoding on the Mac's media engine. Needs Update VM or
  `omacvm update`, then quit Chromium and start Chromium (WebGPU) again.

- **OmacVM.app: Omarchy's Chromium plays H.264 coded interlaced video on the CPU instead of
  showing no picture (#627).** From 3.2.13 the VM's VA-API refuses such pictures (the Mac's hardware
  decoder does not take them), and Chromium's V4L2 decoder then waited for a first picture that
  never came. OmacVM's decoder for Chromium now gives up on such a video after 3 refused
  pictures, before the first one, and Chromium decodes it on the CPU. Videos that play now are
  not affected. Checked in a test VM on an M1 Max: an interlaced 1080 clip showed no video with
  3.2.14 and plays now; a progressive one stays on the Mac's media engine. Needs Update VM or
  `omacvm update`.

- **Notifications, bar panels and the Omarchy menu are transparent again with Hyprland 0.57 (#638;
  reported in #630).** Hyprland 0.57.0 (released 2026-10-28; in Omarchy's edge repository, the dev
  channel, since 2026-10-29; Omarchy stable once it ships it) turns its option
  `quirks:skip_non_kms_dmabuf_formats` on by default. Hyprland then offers apps only the buffer
  formats a display plane takes, and the virtio-gpu display of OmacVM.app, UTM and Parallels takes
  none with alpha: every transparent layer Qt Quick draws on the GPU came out black, so each Omarchy
  notification, bar panel and the Omarchy menu blacked out the whole screen while it showed. OmacVM
  now turns the option off on every route (`~/.config/hypr/omacvm_vm.lua`), only when this Hyprland
  has it on and your own Hyprland files do not name it; on Hyprland 0.56 nothing changes, and VMware
  Fusion was not affected. Not caused by OmacVM 3.2.13, which came out after Hyprland 0.57. Needs
  Update VM or `omacvm update`, then log out and in (an OmacVM.app VM updated while it was shut down
  needs nothing more); before that, `hyprctl getoption` saying false is no proof. `omacvm check` has
  a "transparent panels" line. The workaround for older versions is in docs/troubleshooting.md, 50.
  Reported by @epicoun.

- **Screenshots and screen sharing of HDR apps stay right with Hyprland 0.57 (OmacVM.app, #639).**
  Hyprland 0.57.0 (released 2026-10-28; in Omarchy's edge repository, the dev channel, since
  2026-10-29; Omarchy stable once it ships it) still writes the SDR copy every capture reads with PQ
  windows' white at 80 nits (#579). OmacVM's fixed shader file was made for 0.56.2 only, so on 0.57
  screenshots, colour picks and screen shares of Chrome came out too bright again, and
  `omacvm check` said "no OmacVM fix for this Hyprland (0.56.2: not built from commit efb50993)"
  (see #630). OmacVM now carries the same fix for 0.57.0 and puts in the installed release's file
  after each Hyprland update. When no file fits, the "HDR captures" line names the installed
  Hyprland and the releases OmacVM has fixes for, e.g. "no OmacVM fix for Hyprland 0.58.0-1 yet
  (OmacVM has fixes for 0.56.2 and 0.57.0)". Needs Update VM or `omacvm update`; a running desktop
  takes it at once.

- **VMware Fusion builds Hyprland 0.57 with its graphics fix (#639).** OmacVM's Hyprland patch for
  Fusion's graphics driver (vmwgfx) did not apply to Hyprland 0.57.0 (the code around it moved), so
  the rebuild after a Hyprland update stopped, `omacvm apply` failed, and the VM was left with stock
  Hyprland: a black screen at the next login. OmacVM now carries the patch for each Hyprland release
  (0.56.2, 0.57.0) and builds with the one that applies. For a newer Hyprland it has no patch for
  yet, the update and `omacvm apply` go on and say "no vmwgfx fix for Hyprland <version> yet", and
  `omacvm check` names the version; `omacvm update` brings the patch once there is one. Needs
  `omacvm update` before Omarchy stable moves to 0.57.

- **A Hyprland that drops an option OmacVM.app sets shows no config error (#639).** `omacvm_app.lua`
  sets `cursor:no_hardware_cursors`, `cursor:use_cpu_buffer`, `render:keep_unmodified_copy` and
  `render:cm_auto_hdr` now only when this Hyprland has them (`hl.get_config`), as `omacvm_vm.lua`
  (#638) does: an option Hyprland does not know puts a red config error on the screen, which `pcall`
  did not stop. All four are still there in 0.57.0, so nothing changes today.

- **Swipe out to macOS sees Omarchy's scratchpad on Hyprland 0.57 (#639).** Hyprland 0.57 gives
  special (scratchpad) and named workspaces no id any more. With the scratchpad open, a four-finger
  swipe past the first or last workspace could switch the Mac's Space instead of staying in the VM,
  and OmacVM.app's check for a wallpaper that did not draw took a display showing the scratchpad for
  the bare desktop. Both now tell those workspaces by their name, on Hyprland 0.56 and 0.57; the
  gestures daemon now also listens for Hyprland's `changeworkspaceid` event (a workspace got a new
  id; 0.56.2 sends it too).

- **Updating a VM no longer asks Omarchy's shell to reload its plugins over and over (#625).**
  OmacVM enabled its bar widgets with Omarchy's `omarchy plugin enable` without a locale, and
  Omarchy took Qt's locale warning for a failure ("omarchy-plugin-enable: WARN" in the update's log)
  though the widget was enabled. A widget without its own place in the bar (the Wi-Fi QR card) then
  stayed queued until the end of the update, and each later widget enabled it again and asked the
  open shell to reload its plugins (8 times in one update after a 3.2.12 one). Now it is enabled
  once. Needs Update VM or `omacvm update`.

- **Omanotch counts an Omarchy shell that is starting or reloading as locked, as OmacVM's own
  widgets do (#625).** Its display panel (UTM, VMware Fusion, Parallels) and its copies of Omarchy's
  bar and background took a shell that runs but does not answer yet as unlocked and could write
  into Omarchy's plugins folder then; under a lock that reloads the lock screen without its
  password field. They now wait up to 20 s for the shell and otherwise do it later (the next
  start of Omanotch, or after the unlock). Omanotch installs again at this update (its files
  changed).

- **OmacVM.app: after an Omarchy update, the VM's displays follow the Mac's at once (#625).** At the
  first start after an Omarchy update that changed its display panel, the VM's display agent rebuilt
  OmacVM's display widget first, which waits for a busy shell; the display sync now starts at once
  and the widget is rebuilt beside it. A shell that takes no calls for 15 s now counts as busy, not
  as open, so the widget is not written into it.

- **Update VM no longer installs Omanotch again when it did not change (OmacVM.app, #626).** The
  check for a changed Omanotch counted Python's compiled files that the same update leaves
  beside Omanotch's display panel code, and those change with every update: each update of an
  OmacVM.app VM with Omanotch on built and installed it again. Omanotch installs once more at
  this update.

## 3.2.14

In an OmacVM.app VM, a program can no longer stop the whole VM through the Mac's Vulkan driver
(Graphics on Vulkan), and Ghostty opens and draws. Needs the app update for the Vulkan checks
(from the VM's next start), then Update VM or `omacvm update` and a new Ghostty (log out and in)
for Ghostty. UTM, VMware Fusion and Parallels: nothing changes.

- **A program in the VM can no longer stop the whole VM through the Mac's Vulkan driver (#623).**
  In an OmacVM.app VM with Graphics on Vulkan (Automatic gives it on macOS 26 and newer), a program
  that used Zink (OpenGL on Vulkan) could stop the whole VM: `glxinfo -B` with Zink and kopper off
  (`LIBGL_KOPPER_DISABLE=1`), or Ghostty with Zink and OpenGL 4.3 forced. Zink asked for a kind of
  linear image the Mac's driver cannot make, was told it could, and Metal then ended QEMU's
  process. Other unusual Vulkan requests did the same (too many levels or layers, a view past its
  image, a format the driver does not know, an unknown sampler filter). OmacVM.app now checks them
  on the Mac before its Vulkan driver gets them: the program gets a Vulkan error, or ends on its
  own, and the VM goes on; Zink is told that image is not supported. Found while testing #598,
  reported by @benoitdepaire. Needs the app update (from the VM's next start).

- **Ghostty opens and draws in OmacVM.app VMs (#622; reported in #598).** Ghostty 1.2 and newer need
  OpenGL 4.3, and an OmacVM.app VM's OpenGL is 4.1 (virgl on the Mac's OpenGL), so Ghostty opened no
  window ("Ghostty requires OpenGL 4.3"). OmacVM's EGL library in the VM now starts Ghostty, and
  only Ghostty, on Mesa's CPU renderer (llvmpipe, OpenGL 4.6); the programs started inside it keep
  the Mac's GPU, and a driver variable set by hand still wins. That costs the VM's CPU: 10 s of fast
  output took Ghostty about 20 CPU-seconds in a 1272x640-pixel window at scale 2, about 2 of a 4-CPU
  VM's cores (foot 0.8, Alacritty 0.6), and 35 in a 2512x1500-pixel one, nearly the whole VM (foot
  2, Alacritty 0.8; measured on a Mac mini M4). Alacritty and Kitty draw on the Mac's GPU; Omarchy's
  default foot draws on the CPU by design and costs little. With Ghostty as the default terminal,
  Omarchy's screensaver draws on the CPU too while it shows, and that costs a lot: on two displays
  at scale 2 it kept 3.7 of the VM's 4 cores busy, and the Mac mini drew about 36 W against 14-18 W
  without it (20 W in foot); `omarchy-toggle-screensaver` or `omacvm enable no-idle-lock` turns it
  off. `omacvm check` has a "Ghostty" line that says so. Zink is no way around it for now: on the
  Mac's Vulkan driver it gives OpenGL 2.1, and with OmacVM.app 3.2.13 and older a forced 4.3 stopped
  the whole VM; now the VM goes on, see the bullet above (docs/troubleshooting.md, 47; ADR 0064).
  Reported by @benoitdepaire. Needs Update VM, then log out and in (or `systemctl --user stop
  app-com.mitchellh.ghostty.service`).

## 3.2.13

In an OmacVM.app VM, mpv's and FFmpeg's VA-API deinterlacer no longer shows a green picture
(still open in 3.2.12), and H.264 coded interlaced decodes on the CPU instead of showing green
or wrong pictures. On every route, updating a running VM while its screen is locked, or
switching the control centre or Omanotch off then, no longer leaves Omarchy's lock screen
without its password field. Needs the app update (the deinterlacer, from the VM's next start),
then Update VM or `omacvm update` (the lock screen, interlaced H.264), then quit and start the
video players again. UTM, VMware Fusion and Parallels get only the lock screen fixes (#617,
#618). Still open: in Omarchy's Chromium (its own V4L2 decoder), H.264 coded interlaced may
show no picture instead of a green one (from the code; not checked in Chromium), and Omarchy
does not lock the VM again after an unlock until its shell restarts (omacom/omarchy-mac#738).

- **Updating a running VM whose screen is locked no longer leaves Omarchy's lock screen without
  its password field (#617).** `omacvm update` and `omacvm apply` wrote OmacVM's bar widgets again and
  asked Omarchy's shell to rescan them. The shell of omarchy-mac 4.0.3 then reloads all its
  plugins, its own lock screen too, and under the lock the new lock screen had no password field
  until the VM was shut down and started again (3.2.11 and 3.2.12). Now nothing is written there
  and nothing is rescanned while the session is locked: changed widgets wait beside it, and right
  after the unlock they go in place and the shell restarts once. A widget that did not change is
  no longer written again at every update, and two updates under one lock end with the newest
  widgets and one restart. Upstream Omarchy fixed the reload itself (omacom/omarchy#9485);
  omarchy-mac does not have it yet. Needs only the update to 3.2.13 (`omacvm update`, or the
  app's update and Update VM): that update already waits for the unlock.

- **Switching the control centre or Omanotch off while the VM is locked no longer leaves the lock
  screen without its password field either (#618).** The control centre leaves the bar at once
  and its folder goes at the next update; Omanotch stops at once and removes its copies of
  Omarchy's plugins right after the unlock (with 3.2.12 the lock screen stayed without its
  password field until the VM was shut down and started again). Omanotch's display panel (UTM,
  VMware Fusion, Parallels) is no longer rebuilt under the lock after an Omarchy update; the next
  start of Omanotch does it. The update to 3.2.13 installs Omanotch's VM side again (its files
  changed), also on a locked VM, and the lock screen keeps working there. Needs the update to
  3.2.13.

- **mpv's VA-API deinterlacer shows the right picture (#615).** In an OmacVM.app VM, mpv's
  default VA-API deinterlacer (`--vf=vavpp`, or `--deinterlace=yes` with `--hwdec=vaapi`) and
  FFmpeg's `deinterlace_vaapi` (its default and `motion_adaptive`) showed an all-green picture
  (3.2.11 and 3.2.12, where the notes list it as still open). Mesa's deinterlacer reads the
  decoded pictures with 2D-array lookups on samplers it declares without a view, and OmacVM's
  runtime turned such lookups into 2D ones only for samplers with a view, so the Mac's OpenGL
  read zeros. Now it does that for these too. Measured in a test VM (Mac mini M4, Mesa 26.2.5,
  FFmpeg 9.0.2, mpv 0.41) on an interlaced 1080p test clip coded as frames: FFmpeg 0 of 47
  frames green (3.2.12: 47), 28.1 dB against FFmpeg's CPU deinterlacer (3.2.12: 5.1 dB); mpv
  shows a field without combing, close to its CPU deinterlacer (33.0 and 34.2 dB against the
  test pattern's own picture of the field each shows; 3.2.12: 9.9 dB, all green). Needs only
  the app update, from the VM's next start; no Update VM.

- **H.264 coded interlaced decodes on the CPU instead of showing green or wrong pictures
  (#619).** In an OmacVM.app VM, H.264 video coded as fields or MBAFF frames (interlaced TV
  recordings, x264's interlaced mode) came out green or wrong with hardware decoding. Measured
  on 3.2.12: in mpv 99 % green at 1080i, wrong at 576i (24.3 dB against its CPU decoding), 100 %
  green with deinterlacing; FFmpeg's frames were not right either (0 and 2 of 50 bit for bit;
  not measured for green). The Mac's hardware decoder does not take such streams, and
  VideoToolbox's software decoder, which it used instead, dropped every picture after the first
  few and got the colours wrong at 1080 lines. OmacVM's VA-API driver in the VM now refuses these
  pictures, so the app gets an error instead: mpv (`--hwdec=vaapi`) switches to the CPU by itself
  and shows the same picture as its CPU decoding; FFmpeg with `-hwaccel vaapi` prints an error
  for each picture and exits with 69, so leave that option out for these videos. Video coded as
  progressive frames decodes in hardware as before. Measured on a Mac mini M4 with macOS 27.0
  (docs/video-decode.md). Needs Update VM, then quit and start the player again.

- **Correction to 3.2.12: memory the VM gives back (#603).** Its notes said none of the 1.5 GB
  the VM gave back stayed held. The VM gave back 2.4 GB, the Mac still held 1.5 GB of it, and
  none of that stayed held.

## 3.2.12

In an OmacVM.app VM, memory the VM gives back now leaves the Mac, and the VM gives back its
file cache while macOS compresses it; qemu.log, the app menu and `omacvm check` say when the
VM stood still and why; a video that starts no longer holds up the whole display; H.264
1080p and other such videos show at their own size, in Chromium odd-size videos too; and in
Full screen including notch the bar beside the notch comes back after a display change.
Update VM no longer restarts the lock screen of a locked VM, the memory-optimized kernel builds
again, and `omacvm check` warns about Google Chrome 154 or older on an M4 or newer Mac (update
Chrome there). Needs the app update, then shut the VM down and start it again (memory, stalls,
video starts, full screen), and Update VM (video sizes, the lock screen, the stall note in the
VM, the kernel: then Build Now), then quit and start Chrome, Chromium and mpv again. Still
open: mpv's default VA-API deinterlacer (`--vf=vavpp`) shows a green picture
(docs/video-decode.md).

- **The memory-optimized kernel builds again (#608).** Arch Linux ARM's kernel 7.3 has a
  commented-out line in its list of sources, and OmacVM counted it, so the kernel build stopped
  at once with "thp-pkgbuild: source and md5sums differ in length" on every route: turning the
  memory-optimized kernel on failed (the VM went back to what it had), and Build Now in Update
  VM kept the old kernel. It now skips such lines, as Arch's own tools do. After the update:
  Update VM and Build Now (`omacvm update --vm NAME --kernel`), or turn the kernel on again
  where that failed.

- **`omacvm check` warns when Google Chrome 154 or older runs on an M4 or newer Mac (#611).** Those
  versions crash on every video they decode on the CPU there; Chrome 155 fixes it (update Chrome).
  Needs only the app update (or `omacvm update`); no Update VM.

- **H.264 1080p and other videos whose decoder works at a larger size show at their own size
  (#610).** In an OmacVM.app VM, Google Chrome on Wayland and mpv (`hwdec=vaapi`) still showed
  H.264 videos at sizes that are not a multiple of 16 (1080p, 360p, 854x480) and HEVC at sizes
  that are not a multiple of 8 slightly squeezed, with the stream's padding rows in a strip below
  or beside them (8 rows of a 1080p video). The decoder works at the larger size, and only the
  player's import of the picture says where it ends. A small EGL library in the VM now passes that
  size to the VA-API driver, which tells the Mac. Measured in a test VM (Chrome 154, mpv 0.41, Mac
  mini M4): H.264 at 1920x1080, 1280x720, 854x480, 640x360, 426x240 (mpv) and 1918x1078, HEVC at
  854x480 and 1000x562 (10-bit too at 1000x562) are exact in Chrome, mpv and mpv's gpu-next (3.2.11: the
  strip in 23 of these); VP9, 10-bit VP9 and AV1 stay exact, and so do Firefox and Chromium; a
  video that really has 1088 rows keeps them all; FFmpeg's read-back stays bit for bit the
  software decode. Hyprland, Xwayland and Omarchy's shell (with its lock screen) do not load the
  library. Needs Update VM (the 3.2.11 app is enough), then quit and start Chrome and mpv again,
  or restart the VM.

- **A video that starts no longer holds up the VM's whole display (#596).** Starting a hardware
  video decoder asks the Mac's video service, and QEMU did that on its graphics thread, which
  every app in the VM, the desktop and their frames wait for. On a Mac mini in a video call
  (its tiles start a new decoder every few seconds) most starts took under 20 ms and some up to
  110 ms; when the Mac was short of memory one took 1.6 s. Each decoder now starts, changes and
  ends its session on its own queue, beside the graphics thread. A decoded picture that is not
  in within 250 ms (`OMACVM_VIDEO_GIVEUP_MS`) is given up: that video keeps its last picture
  until its decoder is there, and a picture given up is never written later into a surface the
  app may already use again. Other apps' frames still wait for a late picture, up to those 250
  ms (the VM's frames finish in one order). In a test where a decoder took 1.6 s to start, the
  app's frame commands returned in 0.02-0.5 ms (three runs) and another app's frame was done
  after 250 ms; before, the whole graphics thread waited the 1.6 s. When the
  Mac's video service does not answer at QEMU's start, the first question for what it can
  decode waits once, 10 s at most (before: 10 s for each codec asked, 60 s in all). Needs only
  the new app, from the VM's next start.

- **Memory the VM gives back now leaves the Mac (#603).** When Linux in an OmacVM.app VM
  frees memory, it tells QEMU, which puts fresh memory in its place. macOS kept the old
  pages anyway, in memory or compressed, until the VM stopped: it frees such pages only
  with the whole block of memory they belong to, and the rest of that block was still the
  VM's. Activity Monitor did not show them, and the Mac could not use them either. Now
  QEMU moves them aside and a thread of its own tells macOS they may go: macOS drops their
  compressed copies at once, and the others are marked for macOS to take first, without
  compressing them. Marked pages count as given back below; on a Mac with room they stay
  in memory until macOS needs it or the VM stops. On the Mac mini, a 3 GB VM after a
  browser session while macOS compressed it: the old way left on the Mac all 1.3 GB it
  still held of the 2.1 GB the VM gave back (92 % of it compressed); now none of 1.5 GB.
  After a cache drop: all 1.7 GB before, none of 1.6 GB now. On a MacBook Pro M1 Max, a
  4 GB VM after a browser session (3 runs each way): none of the 1.7-2.2 GB the Mac still
  held stayed held (3.3-3.5 GB with the memory-optimized kernel); that Mac had room, so
  1.2-1.6 GB of it stayed in memory, marked, until the VM stopped (1.7-1.8 GB with that
  kernel). The old way held 1.2 GB more until the VM stopped (1.8 GB with that kernel). A
  drop of 4.1 GB of file cache that macOS had compressed: none stayed held. QEMU's main lock
  per report of freed memory: about 1 ms on the mini (the old way 0.4-0.7 ms, and 16.5 ms in
  one run with 99 % of the pages compressed); on the M1 Max up to 8 ms either way, and 2.2 ms
  at most in that drop (the old way up to 26 ms while macOS compressed). A timer in
  every VM CPU saw no stall in either drop. Activity Monitor's figure for the VM does not
  change with this: those pages were never in it. `logs/qemu.log` says how much the VM
  reported and how much of it is still on the Mac. Needs only the new app, from the VM's
  next start; no Update VM. UTM, Parallels and Fusion: nothing changes.

- **The VM's file cache goes back to the Mac while macOS compresses the VM (#590, #603).**
  3.2.11 brought this give-back but left it off, as its QEMU kept the pages. With the fix
  above it runs: when macOS compresses the VM, the VM gives back the file cache it has not
  used lately, all but the newest 1 GB (an eighth of a smaller VM). At most once per 10
  minutes; macOS's memory warning still drops the whole cache. On a MacBook Pro M1 Max (a
  4 GB VM with 2.6 GB of files read, then a program taking the Mac's memory): the
  give-back came within 30 s, while macOS still called its memory pressure normal; the VM
  gave back 1.2 GB of file cache (2.8 GB before), and of the 3.2 GB the Mac still held of
  what the VM gave back in that run, none stayed held. With the memory-optimized kernel:
  1.1 of 2.5 GB, and none of 4.1 GB stayed held. The same row without the fix waited for
  macOS's warning, 1.5 minutes in, to drop the cache, and so did 3.2.11's own app (no give-back in
  5 minutes). When the Mac ran short faster, macOS's warning came first and dropped the
  whole cache, as before. If macOS keeps the pages anyway on a Mac (it refuses QEMU's
  advice, or half or more of what it held stays held), QEMU goes back to the old way for
  that run and the app turns this give-back off until the VM's next start: `logs/qemu.log`
  and `omacvm check`'s "VM memory" line say so. Needs only the app update, from the VM's
  next start.

- **qemu.log says when the VM stood still, and why (#595).** When macOS runs out of free
  memory, the processors of an OmacVM.app VM can wait in macOS for seconds while macOS makes
  memory free for them; the others run on, and in the VM it looks like a freeze (the kernel
  logs an RCU stall, the video daemon misses its watchdog, "no word from the Mac for 15 s"). On
  a Mac mini short of memory three of ten processors stood still for 1.2, 2.1 and 2.4 s. QEMU
  now writes one line per stall of 1 s or more: which processors, about how long, and why:
  "blocked in macOS's kernel waiting for memory" only when the Mac was paging then (compressing
  or swapping 16 MB/s or more, or memory pressure warn or critical), else just "blocked in
  macOS's kernel", or "waited for a Mac core" when the Mac's processors were busy. QEMU's main
  loop holding the VM 2 s or more is counted too (the mini once held it 2.2 s while freeing a
  display surface's memory). For example (the format, not a measurement): "OmacVM: stall: vCPUs
  1, 2, 3, 8 stood still for about 58 s, blocked in macOS's kernel waiting for memory (Mac:
  compressor and swap 900 MB/s, 0.3 GB free, pressure normal; the VM holds 51 GB, 20 GB of it
  compressed by macOS)". The counts go to `logs/vm-stalls`, and the app menu (beside the Apple
  menu) then says, for example, "The VM stood still 2 times (longest 58 s): the Mac ran out of
  memory" under Graphics memory. QEMU looks when its stall watchdog wakes anyway (every 2 s,
  every 250 ms while a processor stands): no new timer, so short stalls can be missed: one in
  macOS's kernel under about 2.25 s (3.25 s for a processor that was nearly idle before), one
  without a Mac core under about 4 s. The watchdog's "main loop stalled" line now says "in a
  GPU run without the BQL" when QEMU's graphics thread waited in a call to the Mac while the
  processors ran on (it said "with the BQL held (the VM waits)" there), and a line says when
  the watchdog itself woke more than 1 s late. That a stall came from the Mac's memory has been
  shown only in tests (simulated stalls). On a Mac mini with its processors busy, two runs gave
  7 and 11 "waited for a Mac core" lines (longest 5.8 s), each matching a pause the VM saw
  itself. Idle, sleep, YouTube 4K60, a 10-minute call and a 30-minute run gave no line. Needs
  only the new app, from the VM's next start.

- **When the VM stood still, the VM and `omacvm check` say so (#597).** From the counts QEMU's
  stall note keeps in `logs/vm-stalls`: after a stall of 10 s or more that QEMU put down to
  memory (the Mac was paging then), the VM shows a note with what helps (a smaller VM memory:
  `omacvm resources`), at most once per 30 minutes; for example (the format, not a measurement)
  "The VM stood still for 58 s: macOS ran out of free memory (the VM uses 51 GB of this Mac's
  64 GB), so the VM's processors had to wait ...". `omacvm check` has a "VM stalls" line: a
  warning with how often, how long and why (the Mac's memory, blocked in macOS's kernel, no
  free Mac processor, QEMU itself), never a failure, and "no stall seen this run" otherwise
  (short stalls can be missed). The note comes only for that memory cause, which has so far
  been shown only in tests (#595). The note needs Update VM; the rest only the new app.

- **Full screen including notch: the bar beside the notch comes back after a display change
  (#602).** With an OmacVM.app VM in "Full screen including notch" on a MacBook with an external
  display, the bar beside the notch could stay away after unplugging and plugging in displays or
  sleep (the MacBook's own display gone for a moment, or waking after the external one): the VM
  sat below the notch until full screen was left and entered again. macOS had laid the window
  out for the external display while it still named the MacBook's, and OmacVM took that for
  Split View and gave up the strip for the rest of that full screen. Now that counts as a
  display change: once the displays settle and the Mac is unlocked, the VM covers the strip
  again, without leaving full screen (macOS is asked to lay its full screen out again, at most 3
  times per display change; every later display change gets its own tries). Until then `omacvm
  check` warns that a display change moved the window below the notch; if macOS still keeps it
  there, check says so and what to do: leave full screen and enter it again (when macOS shows
  its menu bar in full screen: its menu bar setting or Keep the Dock and hot corners away
  first). On a MacBook Pro M1 Max with its display switched off for 10 s, 3.2.10 lost the strip
  3 times of 3 and this version covered it 3 of 3; in those rows macOS laid the window out again
  by itself, so OmacVM's own request for that has run only in tests. Needs only the app update,
  from the VM's next start (a VM that runs across the update keeps the old behaviour until it is
  shut down); no Update VM.

- **Update VM no longer restarts Omarchy's lock screen while the VM is locked, and Omanotch
  follows Omarchy's updates again after an unlock (#612).** Before it restarts the Omarchy shell
  for new bar widgets, OmacVM asks Omarchy whether the session is locked. In Update VM the
  answer came with a warning in front, so a locked session read as unlocked: the shell, which
  draws the lock screen, was restarted under the lock (the new shell locked again within about 2
  seconds), and Update VM waited 30 seconds longer. And Omarchy (omarchy-mac 4.0.x with
  Quickshell 0.3.2) keeps answering "locked" after the first unlock (omacom/omarchy-mac#738):
  Omanotch's copies of Omarchy's bar and background then stopped following Omarchy's updates
  until the next login, and an Update VM that installs Omanotch again could wait hours for them.
  OmacVM reads Omarchy's lock status now; while the VM is locked, the shell restarts right after
  the unlock. Not OmacVM's: after every unlock Omarchy does not lock the VM again (lock key,
  idle lock) until its shell restarts (an open fix: omacom/omarchy-mac#752). `omacvm check`
  warns while it is stuck; `omarchy-restart-shell` after an unlock brings the lock back for the
  next lock only. Needs Update VM (`omacvm check`'s warning only the app update).

- **Odd-size videos in Omarchy's Chromium are no longer one column narrower (#613).** In an
  OmacVM.app VM, Arch Linux ARM's Chromium (Omarchy's default browser) decodes on the Mac
  through OmacVM's V4L2 decoder, whose buffers are the picture rounded up to even. A video of an
  odd width or height (a VP9 video of 853x480 or 1001x563) came out squeezed by that extra
  column and row. The decoder now tells the Mac the picture's size for such buffers. Measured in
  a test VM (Chromium 153, Mac mini M4): 853x480 and 1001x563 at their own size (ratio within
  0.0005: 1.0002; 1.00005/1.00007), as with CPU decoding (3.2.11: one column, and one column and
  one row, too many in their place); 854x480, 720p, 1080p and 1000x562 were and stay exact.
  Needs Update VM (the 3.2.11 app is enough).
## 3.2.11

In an OmacVM.app VM, Google Chrome's GPU process no longer crashes in video calls, most
videos lose the repeated last row at their bottom, AV1 videos with film grain show the right
picture, the VM's pointer works on an external display while the MacBook's display shows
macOS (a paused display stays off meanwhile), and the Touch ID panel shows on the display you
work on. `omacvm check` shows the VM's memory. Needs the app update and Update VM, then shut
the VM down and start it again; the Touch ID panel needs only the app update, from the VM's
next start.

- **No repeated last row at the bottom of VP9, AV1 and most HEVC videos (#594).** In an
  OmacVM.app VM, Google Chrome on Wayland (as Omarchy starts it) draws hardware-decoded video
  straight from the decoder's frames, and so does mpv with `hwdec=vaapi`: the picture came out
  slightly squeezed, with its last row stretched over a strip below it (8 rows of a 1080p
  video, about 11 pixels when it fills 1440 screen rows; the green bar of 3.1.31 and older was
  the same strip, unwritten), and 854-wide and portrait 360x640 videos, as in video calls, had
  the strip on the right. The Mac now samples each video surface at the picture's own size, as
  the VM's VA-API driver tells it, with no copy: VP9 and AV1 videos no longer show the strip,
  nor HEVC at sizes that are a multiple of 8. Not yet for H.264 at sizes that are not a
  multiple of 16, 1080p among them, or HEVC at other sizes: there the decoder itself asks for
  a larger surface, VA-API does not say where the picture ends, and the stream's own padding
  rows still show. Omarchy's Chromium and Firefox were already exact. Needs the app update and
  Update VM, then shut the VM down and start it again.

- **Google Chrome's GPU process no longer crashes on video it receives in calls (#591,
  #592).** In an OmacVM.app VM, Chrome's GPU process could crash in video calls while it
  decoded the incoming video; after repeated crashes Chrome can stop using the GPU until it is
  restarted. Mesa's VA-API driver crashes when it is asked to decode into a video frame the
  app made itself and handed in, and Chrome on Wayland does that at times (both crash dumps
  read so far show it; why Chrome hands the frame in is not proven yet). The VM's VA-API
  driver shim now refuses those frames, and encoding from one too: Chrome gets an error for
  that one video instead of a crash. Needs Update VM, then quit Chrome fully once.

- **AV1 videos with film grain show the right picture in Google Chrome on Macs with an AV1
  decoder (M3 and newer) (#593).** Chrome decodes such a picture into one buffer and shows
  another (the picture with its grain); the Mac wrote only the first, so Chrome showed a
  buffer that held an older picture, or nothing (green). The picture now goes into both. Needs
  only the new app, from the VM's next start.

- **The VM's pointer works on the external display while the MacBook's display shows macOS
  (#601).** With the VM in full screen on the MacBook's display and an external one, switching
  the MacBook's display to macOS left the VM without pointer events on the external display:
  the VM's pointer stood still there, nothing reacted to hovering, scrolling went to where the
  pointer had been, and only a click brought it back. A move over the VM on the other display
  now moves the VM's pointer. The Mac app in front keeps the keyboard, and the Mac's arrow
  shows over the VM's pointer until you click, which takes the pointer and the keyboard as
  before. Needs the app update and a restart of the VM (shut it down and start it again); with
  Pause drawing while hidden on, Update VM too (next item).

- **Pause drawing while hidden: the hidden display stays off while you work in the VM on
  another one (#600).** With the VM in full screen on two displays and the main one switched
  to macOS, every pointer move or key in the VM on the other display turned the paused display
  on again (Omarchy has Hyprland wake every display at any input), and the Mac turned it off
  again a few seconds later, over and over. While a display is paused the VM's display agent
  now holds that wake-up off and puts it back as it was afterwards. Needs Update VM.

- **The Touch ID panel shows on the display you work on (#599).** With an OmacVM.app VM in
  full screen on two displays ("Use external displays", on by default), the Touch ID panel
  showed on the display the VM started on, often the MacBook's built-in screen, while you
  worked on the external one. It now shows on the display under the Mac's pointer, over the VM
  there; a VM in a window keeps it over its window, as before. macOS's own Touch ID dialog
  (for a command too long for the panel, the Mac-password fallback if you turned it on, or
  with the panel turned off) still shows on the display the VM started on. Needs only the app
  update, from the VM's next start.

- **`omacvm check` has a "VM memory" line; the file cache give-back waits for a QEMU fix
  (#590, #605).** In an OmacVM.app VM the line shows the VM's memory, whether the give-back
  below is on, and when the VM last freed its file cache in this run. When macOS warns that
  memory is short, the VM drops its file cache, as before. New but off in this release: while
  macOS compresses the VM, the app would ask the VM for its file cache not used lately (all but
  the newest 1 GB). That only helps when QEMU hands the pages the VM frees back to macOS, and
  this release's QEMU does not: on a Mac mini (a 3 GB VM), of the given-back memory the Mac
  still held, 1345 of 1346 MB stayed held in one test and 1721 of 1721 MB in another. A file
  the VM reads again then takes new pages, so the give-back would make the VM's number in
  Activity Monitor smaller while the Mac holds as much or more. It turns on by itself with the
  QEMU fix in a later release; `logs/qemu.log` says at each start whether it is on. Needs only
  the app update, from the VM's next start. UTM, Parallels and Fusion: nothing changes.

- **Correction to 3.2.10: arrays passed between shader stages do draw (#589).** 3.2.10 said
  arrays passed between stages still draw nothing: true only on Apple's software renderer. On
  the GPUs of a Mac mini M4 and a MacBook Air M2, the tested shape (vec4[2], vertex to
  fragment shader) links and draws. Values passed per patch between tessellation shaders still
  draw nothing.

- **Correction to 3.1.32: the smaller blocks made QEMU's footprint smaller, not what the Mac
  holds (#606).** 3.1.32 said a 4 GB VM held 1.1-1.4 GB less of the Mac's memory after a
  build and a dropped file cache, and `omacvm check` called its row "memory back to the Mac".
  What was measured was QEMU's footprint, the number Activity Monitor shows: memory Linux
  frees leaves it, but this release's QEMU keeps holding those pages on the Mac until the VM
  stops (the "VM memory" item above). The row is now called "free page reporting". Needs
  Update VM.

## 3.2.10

Apps in an OmacVM.app VM that draw with OpenGL program pipelines now draw. Needs only the app
update.

- **Apps that use OpenGL program pipelines now draw (#567).** Apps in an OmacVM.app VM that
  build their shaders as separate programs (`glCreateShaderProgramv`, program pipelines) drew
  nothing where they used them: the Mac's OpenGL refused every such shader, because it wants
  each one to declare the `gl_PerVertex` block it uses, and the VM's graphics stack never
  declared it for such shaders. Now each of them does, geometry and tessellation shaders too.
  Two kinds still draw nothing, as before: values passed per patch between tessellation
  shaders, and arrays passed between stages. If the Mac's OpenGL finds such a pipeline
  invalid at its first draw (for example a shader that reads a 2D and a cube texture, or an
  incomplete framebuffer), qemu.log says so and the app draws on. Needs only the new app,
  from the VM's next start (a VM that runs across the update keeps the old one until it is
  shut down); no Update VM.

## 3.2.9

AirPods, Control Center and the play keys play and pause what plays in the VM. In an HDR VM,
screenshots, screen shares and screen recordings look right. Both need Update VM once.

- **Screenshots and screen sharing of HDR apps look right in an HDR VM (#579).** With HDR and
  10-bit colour on, screenshots (also Omarchy's region screenshot and its frozen screen), colour
  picks and screen or window sharing of apps that draw in HDR, such as Chrome and Chromium, came
  out about 2.5 times too bright, light greys white. Hyprland 0.56.2 made its copy for captures
  with their white at 80 instead of 203 nits; the VM now gets a fixed copy of that one shader
  file, only for this Hyprland. Parts brighter than white are cut off in captures, which are SDR.
  Update VM puts it in; no restart needed.

- **Screen recordings of an HDR VM are no longer grey (#579).** Omarchy's recorder reads the
  screen itself and took the HDR picture for SDR: every app grey and flat, white at 148 of 255.
  The VM's graphics driver now tells it the screen is HDR, and it makes SDR of it with its own
  curve: much lighter, white at about 224 of 255 at a high headroom. Update VM, then shut the
  VM down and start it again. Update VM rebuilds the VM's graphics driver once on every
  OmacVM.app VM, whatever its switches (needs internet). If that build fails (offline, or over
  5 minutes), the VM starts with Linux's own driver: HDR, Pointer on its own layer and Draw only
  what changed stay off until an Update VM gets through, and `omacvm check` says so.

- **The HDR switch says when it counts.** HDR and 10-bit colour is read when the VM starts; a
  restart inside the VM (Omarchy's menu) keeps the setting it started with. While the VM runs with
  the other setting, the switch now says so: shut the VM down and start it again (#579).

- **AirPods and Control Center play and pause the VM (#577).** AirPods, other Bluetooth
  headphones, Control Center and the play keys now play, pause and skip what plays in an OmacVM.app
  VM (a video in the browser, music, mpv), and Control Center shows it. While the VM plays, the app
  is the Mac's Now Playing app, like Music. A Mac app that starts playing takes the controls, as
  between Mac apps; playing again in the VM takes them back. Volume stays the Mac's. On by default
  (Settings, Output, AirPods and media controls); the VM needs Update VM once. `omacvm check` has a
  "media controls" line.

- Tests: the on-screen release test (`onscreen.sh`) waits for someone at the test Mac only between
  two rows, with its app's and VM's windows hidden meanwhile; inside a row someone there ends that
  row BLOCKED, out of full screen first. With `--pause-ci`, a CI runner still on a job after the wait
  means no rows on screen (BLOCKED), not rows beside the job's VMs. Its exit code for BLOCKED rows is
  5, as in the other harnesses (3 meant "could not run" there).

## 3.2.8

An OpenGL query the Mac does not answer now finishes with 0 in the VM: no memory bytes from the Mac,
and no app waiting for it for ever.

- **An OpenGL query the Mac does not answer reads as 0 in the VM, not as the Mac's memory.** When
  the Mac's OpenGL did not answer a query's result (a query never started or still running, or a GL
  that refuses calls, as in #547), the VM got whatever bytes were on QEMU's stack, or the query never
  finished and the app waited for ever. Now it finishes with 0, and qemu.log says so once (#573).
  A query still waiting when the app's GL context is lost on the Mac never finished either; now
  it finishes with 0.

## 3.2.7

A click on another display's VM window keeps the pointer and keys, `omacvm check` names the
window's surfaces, and the experimental Frames in step with the Mac is gone (Update VM rebuilds the
VM's graphics driver once). Also: no memory bytes in qemu.log after a refused OpenGL call, and an
output that refuses every sound buffer size is left alone until it changes.

- **Frames in step with the Mac is gone.** The experimental switch from 3.2.3 showed typing and
  the pointer 1.5-7 ms sooner at 60 Hz (up to 2.5 ms at 120 Hz), and only while the screen moved.
  It saved no power, skipped a few more frames at 120 Hz, and needed OmacVM's own change to the
  VM's graphics driver: no gain worth that cost. If you had it on, there is nothing to do: the app
  forgets the setting and your VM draws as with it off. The other experimental switches stay as
  they are. For everyone with HDR and 10-bit colour, Pointer on its own layer or Draw only what
  changed on, Update VM rebuilds the VM's driver once (needs internet).

- **A refused OpenGL call no longer writes memory bytes into qemu.log.** Follow-up to #547: when the
  Mac's OpenGL does not compile or link a shader and gives no log, the log line is now empty instead of
  whatever was in memory. A pipeline check the Mac did not answer also no longer counts as a failed
  one; that path only runs once separable pipelines link on the Mac (#567).

- **`omacvm check` says which surfaces the VM window used.** A new "window surfaces" line for
  OmacVM.app VMs: lossless-compressed or plain, for normal colour and for HDR and Extra brightness,
  why lossless is off when it is, and a warning when making them failed this run (#562).

- **A click on an external display no longer lets go of the pointer for a moment (#563).** In
  full screen with the VM on more than one display, each click on another display's VM window gave
  the pointer and keyboard back to macOS and took them again: the Mac's cursor was shown and hidden,
  and a key held during the click (Shift for a Shift-click) was let go in the VM. The VM now keeps
  both through such a click. Command-Tab, the escape combo and swipes let go as before.

- **An output that refuses every sound buffer size is left alone until the Mac's output changes.**
  Follow-up to #548: when the Mac's output refused the VM's sound at every buffer size, QEMU tried it
  again every 30 s while the VM played. Each failed start may leave macOS's sound service silent, so
  now it waits until you pick another output, connect this one again or restart the sound service
  (`sudo killall coreaudiod`). Thanks to @maxschoenberger for the report (#548).

- **The "find devices on local networks" question says why it comes.** macOS asks it at the first
  VM start because Omarchy's network runs through OmacVM: its name lookups go to the Mac's DNS server
  (often the router, or Tailscale) and its connections to devices on your network go out from the app.
  The question said OmacVM reaches the VM on the Mac's own VM network, which only holds for the fast
  network. Tested on a Mac mini: an update through the app keeps the answer (3.2.3 to 3.2.4 through
  its updater, no new question); only another version of the app in another folder is asked again.
  Troubleshooting 42 says how to turn it on later; the Fast network's (i) says it needs it too.

- Tests: the release gate's harnesses (`cc-switches.sh`, `modifier-keys.sh`, `display-unplug.sh`,
  `onscreen.sh`) look for someone at the test Mac before every step, not only at their start: a
  remote session (Screen Sharing, also one left alone, or Jump Desktop) or input that was not
  theirs pauses the run until the Mac is quiet again, and rows that ran while someone came by get
  a `person` row with the times (3.2.4's gate had two Screen Sharing connects inside a run). With
  `--pause-ci` the test Mac's own CI runners stop for the run (each after its job) and start again
  at its end, also when the run is killed or its ssh connection drops (`src/tests/e2e/ci-runners.sh`).

## 3.2.6

Two changes: the pointer no longer jumps after a click near a corner of an external display, and
with HDR or Extra brightness the window's frames take fewer bytes on macOS 27 (same pixels).

- QEMU window (macOS 27): with HDR or Extra brightness on, the window's frames go into the Mac's
  lossless-compressed half-float format, like the SDR ones since 3.2.1: fewer bytes for every frame,
  the same pixels, brightness and frame rates. On a MacBook Pro M1 Max at 120 Hz with HDR on: a video
  -0.6 W (-3 %), scrolling -0.5 W (-4.5 %), about the same with Extra brightness. To turn it off
  (SDR's too): `launchctl setenv OMACVM_GL_LOSSLESS 0`, then quit and reopen the app
  (`launchctl unsetenv OMACVM_GL_LOSSLESS` turns it on again).

- **The pointer no longer jumps after a click near a corner of an external display (reported by
  the user).** In full screen on an external display, near its corners (Omarchy's bar with the
  workspace buttons), the pointer jumped after each click as soon as the mouse moved again: by
  about the way from the click before. Near corners OmacVM holds the Mac's cursor still (so no hot
  corner or Dock comes up) and moves the VM's pointer by the mouse's motion. A click on another
  display's window lets go of the cursor for a moment and puts it where the pointer is; the motion
  macOS reports next includes that move, and OmacVM added it to the pointer. Now it takes it out.

## 3.2.5

Five fixes: no "would like to control this Mac" dialog at every VM start, the pointer on every
display with Pointer on its own layer, notifications under the bar with Full screen including notch,
sound with AirPods, and a VM that ended at desktop start.

- **A failed OpenGL query at desktop start no longer ends the VM.** Seen once in about 30 test starts
  on a Mac mini (#547). While the Mac's OpenGL was failing calls of Omarchy's bar, virglrenderer read the
  size of its own uniform block without checking that the query worked, then checked it with an
  assertion and aborted QEMU. Now a program whose block size is too small or unknown is refused like any
  other shader the Mac does not take: the draws that need it are skipped and the VM keeps running.

- **No "would like to control this Mac" dialog at every VM start (reported by the user).** When OmacVM
  was not allowed to control the computer (Accessibility), each VM start made macOS show that dialog,
  also with nobody at the Mac, because the VM's keyboard tap was tried anyway (and refused). Now the tap
  is made only when macOS already allows it; otherwise the VM's window shows its note with Allow…, and
  only that button asks macOS. A grant you gave stays through updates: macOS keeps it for OmacVM's bundle
  id and its Developer ID team, not for one build.

- **Pointer on its own layer: the pointer on every display (#554, reported by the user).** With
  the switch on and the VM in full screen on the built-in display and an external one ("Use
  external displays"), the external display showed no pointer at all. Only the main window's
  display had the pointer's layer, and the VM drew no pointer of its own on the others. Now every
  display the VM uses has its own pointer layer, shown over that display's window. The VM needs
  Update VM for it; until then it draws the pointer itself, as with the switch off.

- **Notifications sit under the bar with Full screen including notch (reported by the user).** There the
  bar is as tall as the strip beside the notch (34 points on a 16-inch MacBook Pro), but Omarchy's
  notifications kept only the normal bar's room (26 points and the gap), so their top ran 3 points into
  the bar. They now keep the strip's height and Omarchy's normal gap. Window, Full screen with Omanotch's
  strip and displays without a notch stay as they were. Update VM brings it.

- **Sound with AirPods.** With AirPods (or another Bluetooth or AirPlay output) as the Mac's output,
  the VM had no sound since 3.1.17: macOS refused to start the queue of the sound's own thread (48 kHz,
  256-frame buffers; AudioQueueStart -66681). A VM started with a wireless output now gives macOS the
  queue of QEMU's main loop path (44.1 kHz, 512-frame buffers), which played for the reporter. A switch
  to one while the VM runs reopens it with 512-frame buffers; that helps if the buffer size was the
  cause, else restart the VM with the output connected. Any output that refuses a start gets the next
  size at once. `omacvm check` says which size plays ("sound buffers"). Not yet confirmed with real
  AirPods. Thanks to @maxschoenberger for the report, the workaround and the cause analysis (#548).

## 3.2.4

A new experimental switch in the VM window's Display settings: the Mac redraws only the parts of the
VM's picture that changed. Update VM now builds the VM's graphics driver only from patches that fit
exactly.

- **Draw only what changed (experimental, off by default).** A new switch in the VM window's Display
  section for the tiled present built into 3.2.3. OmacVM.app shows every frame of the VM as a new
  whole picture, so macOS redraws the whole window for each one, also when only the pointer moved.
  With the switch, only the 256x256 squares the VM changed get a new picture. For that the VM needs
  to say what changed in each frame: with the switch on, it loads OmacVM's own build of its graphics
  driver (the standard one with Linux 7.4's fix that passes this on; Update VM builds it, internet
  once). With the switch off, or in GPU safe mode, the Mac draws whole frames as before, and the VM
  loads the driver it loaded in 3.2.3: the standard one, or OmacVM's own when HDR and 10-bit colour,
  Pointer on its own layer or Frames in step with the Mac is on. OmacVM's own now always has the
  fix, so those starts tell the Mac what changed even with this switch off; the Mac does not use
  it then. MacBook Air M2, the VM full screen at 60 Hz, the pointer moving: 3.13-3.17 W instead of
  3.55-3.75 W for the whole Mac (-11 to -17 %, two sets); scrolling and typing the same. MacBook
  Pro M1 Max, HDR at 120 Hz full screen: macOS's WindowServer used less GPU time with the pointer
  moving or a spinner; the whole Mac's power there is measured again before we give a number. The
  same pixels and frame rate at 60 Hz (8-bit and HDR) and 120 Hz (HDR). `omacvm check` has a "Changed parts" line.
- **Guest driver patches must fit exactly.** Update VM applied the VM driver's patches with up to
  two lines of fuzz, so a part could land in the wrong place of a newer Linux kernel and still
  build. Now each part must fit exactly; if one does not, the driver is built without that patch
  (as when it does not apply at all), down to the standard driver.

## 3.2.3

Two new experimental switches in the VM window's Display settings: the VM stops drawing while its
window cannot be seen, and its frames can follow the refresh of the Mac's display. A tiled present
is built in, off for now.

- **Pause drawing while hidden (experimental, off by default).** A new switch in the VM window's
  Display settings. While none of the VM's window can be seen for 2 seconds (minimised, covered
  by other windows, on another Space, the screen locked or asleep), the VM turns its display off
  and stops drawing, as macOS apps do for a window nobody sees. Sound, downloads and everything
  else in the VM keep running. As soon as any part of the window shows again, the VM draws again;
  its first new picture comes a few frames later (20-45 ms), and until then you see the last one.
  A visible window is never touched: every frame, at the display's full rate.
  Measured for the whole Mac: on a MacBook Air M2 with the VM's window minimised, a 1080p video in
  the VM 3.5 -> 2.9 W (one clean row without the switch) and a terminal scrolling its output
  3.6 -> 2.5 W (two rows each; macOS idle: 2.3 W);
  on a MacBook Pro M4 Max with the VM hidden and the display asleep, the video 5.4-5.6 -> 4.6 W and
  the terminal 6.4-8.2 -> 2.9-3.0 W (the VM's idle level). It works at once in a running VM;
  Update VM brings the VM's side, and `omacvm check` says "pause while hidden: ready". Only the
  main window: in full screen on several displays the other windows keep drawing.

- **Frames in step with the Mac (experimental, off).** A new switch in the VM window's Display
  section. The VM's display clock had its own beat: a frame it drew right after one refresh of
  the Mac's display waited for the next one, anywhere up to a whole refresh, while the screen was
  moving. With the switch, the VM's clock follows the Mac display's refresh, so its frames are
  ready just before the Mac shows them. Mac mini, while the screen moves (medians of 60 per mode,
  two rounds of tests, 6-7 runs a side): at 60 Hz keys 1.5 to 7 ms sooner, the pointer about 6 ms,
  keys while the terminal itself scrolls 3.5 to 4 ms, with fewer repeated and skipped frames (143
  instead of 170); at 120 Hz up to 2.6 ms sooner (keys while the pointer moves 0 to 2.6 ms, the
  terminal 1.7 to 1.8 ms). When the VM's frames need more than a refresh, late frames wait as
  before. When a frame is too late for its refresh, the newer one is shown and the late one
  skipped: at 120 Hz that was a few more skipped frames (8 instead of 2 in about 3 minutes of
  moving frames). On a still screen there is no gain. The same pixels (checked on a MacBook Air)
  at the same rate (60 or 120 Hz); MacBook Air M2 power within 1 % (pointer moving, scrolling).
  The VM's driver follows only when its display rate is the Mac's, and if its patch does not fit
  a newer Linux kernel, Update VM builds the driver without it (HDR and the pointer layer keep
  working; `omacvm check` says so). Needs Update VM (it builds the VM's graphics driver, internet
  once); counts from the next start of the VM.

- **Tiled present, built, off for now.** OmacVM.app shows every frame of the VM as a new whole
  picture, so macOS redraws the whole window for each one, also when only the pointer moved. With
  tiles, only the 256x256 squares the VM changed get a new picture. MacBook Air M2, the VM full
  screen at 60 Hz with a driver that says what changed, the pointer moving: 3.13-3.17 W instead of
  3.55-3.75 W for the whole Mac (-11 to -17 %, two sets), the same pixels and frame rate; scrolling
  and typing the same.
  It needs a VM that says what changed in its frames (Linux 7.4, or OmacVM's own driver with that
  fix, #520), so there is no switch yet. `OMACVM_GL_PRESENT_TILES=1` in the app's environment
  turns it on for tests.

## 3.2.2

A running VM is no longer taken as stopped when another program has odd characters in its command
line, control centre switches in a row are not turned away, HDR costs the Mac's graphics less, and a
new experimental switch puts the pointer on its own layer.

- **A running OmacVM.app VM is no longer taken as stopped when another program on the Mac has
  odd characters in its command line.** omacvm reads the Mac's process list to find the VM's
  QEMU. One line that is not UTF-8 (a file name in an old encoding, binary arguments) made
  macOS's awk stop there, so omacvm missed the VM after it: a control centre switch then tried to
  start the running VM and ended with "did not get an address" (#545; found in the 3.2.1 test on
  a MacBook Air). The same line made `pgrep -f` fail, so `omacvm check` could miss a running
  Bridge, Gestures or Omanotch, and a build could miss another build that still reads a
  download. These reads now go byte by byte. Needs `omacvm update` (or the app's update) on the
  Mac.

- **Control centre switches right after another one are not turned away.** When a switch's job
  ended, the Bridge looks at its VMs again; if that look caught the VM busy for a moment, the next
  switch was refused with "unknown VM" at once and the control centre asked again, so that switch
  took about 12 s instead of 7-9 s (#528; reproduced in a test VM 3 of 3 times). The Bridge now looks again
  at once and waits for it (about 1 s), then backs off as before when the VM stays out of reach.
  Its log also says why it did not take a VM (not running, not set up, the SSH error) and which
  VM the app named. Needs `omacvm update` on the Mac (OmacVM.app: the app's update, then Update VM,
  which installs the new Bridge).

- **HDR costs the Mac's graphics less.** With HDR and 10-bit colour on, Omarchy's compositor drew every
  window twice per frame: once for the screen and once into an SDR copy it keeps for screen sharing. The
  copy is now made only while a screenshot or a screen share runs. The screen shows the same pixels and
  screenshots look the same; the Mac's GPU does 10-19 % less work per frame with HDR on (scrolling, video,
  a terminal). A `keep_unmodified_copy` you set in your own Hyprland config still wins. Needs Update VM.

- **Pointer on its own layer (experimental, off).** A new switch in the VM window's Display section.
  With it, moving the pointer no longer redraws the VM's screen: the VM puts its pointer on the
  graphics card's cursor layer, and the app shows that layer over the window, the same pointer in
  the same place (with Extra brightness as bright as the picture). Only the drawing of the VM's
  picture for each move goes; the VM still sends a frame per move. MacBook Air M2 (60 Hz), pointer
  moving, whole Mac: 3.32-3.52 W with the switch against 3.58-3.80 W without it (-0.26 W, -7 %);
  scrolling and video the same. On the Air the window shows the same pixels as without the switch
  (3 pixels one level off, as between two pictures without it). The pointer moves on its own, like the Mac's: while you drag something it can be a frame
  ahead of it. Only in the VM's main window: on other displays the VM draws the pointer as before.
  Not together with the hidden `macPointer` setting. Needs Update VM (it builds the VM's graphics
  driver, internet once); counts from the next start of the VM. With HDR on, Update VM builds that
  driver again too; until it has, an HDR start uses the stock driver and `omacvm check` says so.

- **Mac input methods** (experimental): the Mac's input method stays on while the VM moves the
  keyboard focus for a moment. Each time a text field in the VM lost the focus, the Mac switched
  its input method off at once, and on again with the next key; in the debug capture from
  @Vocllum (#357) the terminal lost and took its focus right after Enter, and WeChat Input typed
  English from then on without a Shift tap. When only the VM's field goes (the VM keeps the
  keyboard), the input method now goes off 0.2 s later, and not at all when a field takes the
  focus again within that time. Keys still go to the VM as keys while no field has the focus, and
  what was marked is still dropped when the field goes. A Shift tap within those 0.2 s still reaches the
  input method and can switch its mode. Not tried with WeChat Input itself (no
  test Mac has it). Needs the app update.

- **USB devices** (experimental): a device that QEMU took longer than 3 s to add was reported as
  not connected, but the VM often got it anyway: QEMU finished the add after the app had stopped
  waiting (#526; 6 of 6 times against a real QEMU). The app now waits up to 15 s for QEMU's
  answer, and without one asks QEMU which devices the VM has: one QEMU added late counts as
  connected, one it does not have is removed again. Needs the app update.

## 3.2.1

Google Chrome plays 1440p and 4K video on the Mac's media engine, call tiles show the whole picture,
the VM's window takes less power on macOS 27, the VM's disk is safer at a power cut, and volume 0 is
silent.

- **Google Chrome plays 1440p and 4K video on the Mac's media engine.** The Mac's graphics
  thread for the VM, which runs every app's drawing in it, waited for the media engine on each
  picture (about 5 ms for a 4K one on a MacBook Air M2, 3 ms on an M4 Max). Above 1080p Chrome's
  own drawing and the desktop's waited behind it, so the media engine dropped many more frames
  than Chrome's CPU decoders (YouTube 4K: 38 % against 7 % on the Air, 13-20 % against 8 % on a
  MacBook Pro M4 Max), and 3.2.0 kept 1440p and 4K on the CPU. Pictures now finish beside that
  thread, and Chrome's decoder waits for each one instead of the thread. A 60 fps video in
  Chrome now drops about as many frames on the media engine as on the CPU at 4K, 1440p and
  1080p (Air: 0.1-1.2 % against 0.1-1.9 %, M4 Max: 2.3-2.7 % against 1.5-4.1 %), with the VM at
  0.4 cores instead of 1.0-1.3 on the Air (0.6-0.8 on the M4 Max). 1080p, already on the media
  engine in 3.2.0, drops fewer frames than before: 0.2-1.2 % against 7-18 % on the Air, 2.3-2.7 %
  against 5.0-5.6 % on the M4 Max. Needs the app update and Update VM; restart Chrome after it.
  `OMACVM_VA_MAX=1920` in Chrome's environment keeps 1440p and 4K on the CPU;
  `OMACVM_VIDEO_DECODE_SYNC=1` in the app's environment brings back 3.2.0's way (the thread
  waits for each picture, Chrome up to 1080p).
- **Video call tiles in Google Chrome show the whole picture.** With hardware decoding (3.2.0)
  a 320x180 tile showed its picture squeezed into the top 168 rows and 12 rows of nothing below
  it (8 rows at 360p and on 1080p video, a strip on the right of 854-wide video): the VM's
  video driver rounds Chrome's frames up to a multiple of 16 rows and columns, and Chrome showed
  the rounded frame as its own size. The VM's VA-API driver now has those frames filled to their
  rounded size and reads only the picture's part of the decoded planes, so Chrome puts every
  row where its own CPU decoders do (checked at 320x180, 480x270, 640x360, 854x480 and 1080p in
  VP9, AV1 and H.264). Only in Chromium-based apps and with Mesa up to 26.2 (a newer Mesa
  turns it off until it is checked); needs Update VM, then restart Chrome. `OMACVM_VA_FILL=0`
  in Chrome's environment turns it off.
- **Less power to show the VM's window (macOS 27).** OmacVM.app now keeps the VM's picture in the
  Mac's lossless-compressed format, so the Mac's graphics move fewer bytes for every frame: on a MacBook
  Air M2 scrolling in the VM takes 0.20 W less at 60 Hz (4.45 W instead of 4.65 W, 4 %) and 0.37 W
  less at 120 Hz (6.18 W instead of 6.55 W, 6 %, on a 120 Hz virtual display); the picture is the same
  pixel for pixel. A video changes little (its frames compress less). To turn it off:
  `launchctl setenv OMACVM_GL_LOSSLESS 0`, then quit and reopen the app (`launchctl unsetenv
  OMACVM_GL_LOSSLESS` turns it on again).
- **The VM's disk is safer at a power cut.** When Omarchy saves a file for good, the Mac's drive now
  gets a write barrier: nothing written after it reaches the flash before what came before it.
  Until now a power cut (a Mac mini or Studio losing power, a held power button) could leave
  the VM's btrfs half written and unmountable, because macOS's fsync stops at the drive's cache.
  With the barrier only the last moments before the cut should be lost (a real power cut was not
  tested). Each synced write costs a little more: 0.25 ms per guest fsync on a MacBook Pro M4 Max,
  where 200 git commits took 0.97 s instead of 0.70 s; the barrier itself costs 0.2-0.75 ms on the
  Macs we measured, the most on an M1 Max. Installing 222 packages, git checkouts and big copies
  took the same time. `omacvm check` shows it as "disk flush". Needs the app update.
- **Volume 0 is silent.** With a VM in front, the volume-down key to 0 % (or Omarchy's volume
  slider at 0) set the Mac's volume to 0 but did not mute it, and 0 is not silence on a Mac's
  speakers: MacBook Pro and Mac mini speakers still play at -63.5 dB there, only 4 dB under the
  first step. A mute pressed before was cleared by the next volume-down, and 0 stayed unmuted. The
  Bridge now mutes the Mac's output at 0, as macOS does, and volume up from 0 unmutes it again.
  Needs `omacvm update` on the Mac (OmacVM.app: the app's update, then Update VM, which installs
  the new Bridge); nothing changes in the VM.
- **USB devices** (experimental): the list now says that a USB network adapter, or another Mac on a
  USB-C cable, is a network adapter that macOS keeps. It said serial port.
- **Partial present, built, off for now.** OmacVM.app's QEMU draws the whole frame into the window's
  picture for every frame, also when only the pointer moved. It can now draw only the part the VM says
  changed. In a bench on a MacBook Air M2 (no VM) the full draw cost 0.19 W at 60 frames a second and
  0.47 W at 120, a small box a few hundredths. It stays off until a VM run shows it draws right, and it
  needs a VM that says what changed in its desktop's frames (Linux 7.4, or OmacVM's own driver with
  that fix). `OMACVM_GL_PRESENT_DAMAGE=1` in the app's environment turns it on for tests.

## 3.2.0

Chrome decodes video on the Mac's media engine again, ⌃⌥ Esc takes the right display out of the VM, the
VM's time zone follows the Mac, macOS's Three Finger Drag stays macOS's, and the camera comes back.

- **Google Chrome decodes video on the Mac's media engine again, up to 1080p.** Chrome 155 and
  newer had gone back to decoding YouTube and video calls on the VM's CPU (Chrome's log: "Plane 0
  is out of bounds: ... > 4096"; Brave and other Chromium-based apps share that code). Chrome
  converts each decoded frame to RGB and checks that frame's buffer size first; the VM's buffers
  looked one page small. Past that check the converted frames would have been black: the Mac
  refused the converting shader, its colour matrix read as zeros and it could not read the
  video's planes (FFmpeg's `scale_vaapi` too). The VM's video driver now asks for buffers of the
  real size in Chromium-based apps, and the Mac draws the frames. Tested in Chrome 156 only.
  Up to 1080p (calls too): above that Chrome's hardware path dropped many more frames than its
  own decoders in our tests, so 1440p and 4K stay on the CPU. At 1080p it drops more frames
  too: YouTube 1080p60 AV1 on a MacBook Pro M4 Max lost 5.9-6.4 % of its frames against 2.1 % on
  the CPU (about 4 a second instead of 1). The VM's CPU went from 0.77 to 0.47 cores there, but
  QEMU's on the Mac only from 1.11 to 1.01: the conversion costs the Mac's graphics thread
  most of what the VM saves. `OMACVM_VA_EXPORT=0` in Chrome's environment in the VM keeps it on
  the CPU. Needs the app update and Update VM; restart Chrome after it.
- **Three Finger Drag.** With macOS's Three Finger Drag on (System Settings > Accessibility >
  Pointer Control > Trackpad Options > Dragging style), dragging with three fingers in the
  full-screen VM also switched Omarchy's workspaces. Three fingers now stay macOS's drag and only
  four-finger swipes go to the VM, as macOS itself does then. The setting is read live; with it
  off (the default) three and four fingers both switch workspaces as before.
- **The camera comes back.** After the MacBook's lid closed (or a USB or display camera was
  unplugged) while a Linux app used the camera, the VM's picture stayed black until the app or
  the VM was started again: the camera's session kept the camera that was gone. Each start now
  picks the camera again (the built-in one while the lid is open, else macOS's default, else
  the first there is), and a camera that is gone, suspended or gives no picture for 5 s (20 s for
  its first) is started again with whichever camera there is then; a camera plugged in meanwhile
  is taken at once.
- **The VM's time zone follows the Mac's.** The VM took the Mac's time zone only when it was set
  up, so after a trip its clock was off by the time difference. The Bridge now sends the Mac's
  zone, and the VM follows it at every start and within seconds of a change on the Mac. A zone
  you set in the VM yourself (Omarchy's menu, `timedatectl`) from now on is kept; set it back to
  the Mac's and it follows again. `omacvm check` shows which (line "time zone"). One set before
  this update is taken over by the Mac's once: set it again after the update to keep it.
- **⌃⌥ Esc on an external display.** With the VM full screen on the MacBook and an external
  display, ⌃⌥ Esc moved the display under the Mac's pointer. Omarchy does not move the pointer when
  you go to the other display with the keyboard, so often the other display went to macOS and the
  one you worked on stayed on the VM, and you had to swipe it out by hand. ⌃⌥ Esc now moves the
  display that has the VM's focus ("Focused monitor"), and the keyboard goes there. Back in from
  macOS also works on the external now: before, after you left it with a swipe, ⌃⌥ Esc there
  brought the MacBook's display back into the VM instead. Needs the VM's update (Update VM);
  until then the display under the pointer, as before.
- **⌃⌥ Esc with "All monitors".** With the VM full screen on two displays, ⌃⌥ Esc moved only the
  display under the pointer with macOS's shortcut; the other one needed a Dock swipe to go out and
  stayed on macOS on the way back in. Both displays now move, out and back in.
- **⌃⌥ Esc pressed again quickly.** A second ⌃⌥ Esc right after the first (while Control and
  Option were still down) set the trackpad back to the VM but still moved to macOS. Now it keeps
  you in the VM.

## 3.1.32

- **Vulkan windows show each new frame at once.** With "Vulkan windows without a copy" on (the
  default since 3.1.26, macOS 26 and newer), a Vulkan app's window showed its previous frame for
  one screen refresh after each new one: in Zed the caret jumped back a character for a moment on
  every move, a window that draws all the time was one swapchain cycle late (about 50 ms at
  60 Hz), and one that draws as fast as it can could tear. The Mac's OpenGL does not send one context's work when another one takes
  over, so the copy of the window's frame for the desktop went out one frame late; it is now sent
  first. Thanks to @epicoun for the report and its details (#499). If you added
  `MESA_VK_WSI_DEBUG=sw,nowlts` to `~/.config/environment.d/50-vulkan-present.conf` to get around
  it, take that line out after the update and log in again: Vulkan windows then go through the
  GPU again. The VM needs no update.
- **No green bar under videos.** Some videos played with the Mac's video decoder had a thin
  green strip at the bottom (VP9 and AV1 at 1080p, 540p and 360p: YouTube, and video in calls)
  or on the right (480p and 240p). The VM's video surfaces are a few rows and columns bigger
  than the picture, and those were never written; they now repeat the picture's last row and
  column. In small call tiles that strip can still show as a stretched edge instead of green.
  The VM needs no update.
- **Faster canvas and SVG drawing in Chrome and Chromium.** In OmacVM.app VMs, Chrome no longer
  draws every canvas stroke and clip path on the CPU: it now sees "OmacVM-GPU" as its GL renderer
  instead of "virgl", the name for which Chrome's Skia turns instanced drawing off. MotionMark's
  Paths and Suits ran at 29-48 fps and now hold the display's rate (75 fps in the test VM). Only
  Chrome and Chromium get the new name (other programs, Brave and Electron apps among them, keep
  "virgl"), and web pages that read the WebGL renderer now see "OmacVM-GPU" instead of the Mac's
  GPU model. A VM gets it at its next Update VM; restart Chrome after that.
- **Local AI models load with Vulkan on smaller Macs.** The VM's Vulkan memory window is now at
  least 4 GB. It was 1 GB for a 4 GB VM on an 8 GB Mac and 2 GB for a 24 GB VM on a 32 GB Mac,
  too small for a 3B language model's weights. The window limits how much Vulkan memory the VM
  can map; what Vulkan allocates counts against the VM's GPU memory guard (three quarters of the
  Mac's memory), not against macOS's memory pressure. So on an 8 GB Mac a large model can now
  make macOS swap where it did not load before. The VM needs no update.
- **More memory back to the Mac.** OmacVM.app's VM now gives memory Linux frees back to the Mac in
  256 KiB blocks, not only in whole 2 MiB ones. After a build and a dropped file cache, a 4 GB VM
  held 1.1-1.4 GB less of the Mac's memory, for about 0.5 % more CPU during the build; bigger VMs can get
  more back. Takes effect with Update VM (no restart needed); `omacvm check` shows it as
  "memory back to the Mac".

## 3.1.31

- **Trackpad gestures after sleep.** After the Mac woke from a longer sleep (Power Nap's short
  wakes too), three- and four-finger swipes and scroll momentum's two-finger scrolling no longer
  reached the VM until OmacVM Gestures was started again: macOS makes the trackpad's device anew at
  such a wake, and Gestures kept the old one. It now takes the new one about a second after the
  wake (a Magic Mouse's too).
- **Brightness and Extra brightness in the VM's Display panel.** Omarchy's brightness slider now
  also sets the MacBook's own display (through the Bridge, as the brightness keys), and on a Mac
  with an XDR display an Omarchy-style **Extra brightness** switch sits right under it, with the
  same use-with-care (i), in step with the app's row (OmacVM.app; switches only while that VM's
  window is in front). In the VM's terminal: `omacvm extra-brightness [on|off]`.
- **Extra brightness works with HDR.** With "HDR and 10-bit colour" on, Extra brightness now wins
  while it is on: the VM's picture gets up to 2x brighter, HDR highlights do not; turned off, HDR
  is back at once, in a running VM. Before, it stayed off over HDR ("not with HDR yet").
- **Extra brightness keeps your setting.** On or off, it stays as you last set it in the app or
  the VM's Display panel: through a restart of the VM or the Mac, Update VM and app updates, HDR
  or GPU safe mode switched, and a start on a display without it. Its (i) says so now.
- **Chromium (WebGPU) at the display's scale.** The "Chromium (WebGPU)" menu entry runs Chromium
  on X11, which does not see Omarchy's display scale: on a Retina display its pages and menus came
  out at half size. It now opens at the scale of the display it starts on (a scale you set
  yourself, on its command line or in `chromium-flags.conf`, still wins).

There is no 3.1.30: it was built but not released, and its changes are the ones above.

## 3.1.29

- **Extra brightness (experimental, off by default).** On a MacBook Pro's XDR display (or another
  display with more than 2x headroom), the VM window's Display settings have a switch that makes
  the VM's window up to about twice as bright as the Mac's normal white, for bright light. It acts
  at once in a running VM and ends by itself when the VM stops, its window is hidden or you turn
  it off. Use it with care: it uses much more battery and makes the Mac warmer; its (i) says so.
  Not with HDR yet. A MacBook Air does not show it. `omacvm check` has a line for it.

## 3.1.28

- **A VM from another Mac says what it needs.** When OmacVM Gestures or the Bridge aren't set up
  on this Mac (a VM folder copied to a new Mac), OmacVM says so before the start and in the
  window, and offers Update VM, which sets them up and lets them ask macOS for their
  permissions; the VM then starts. Before, nothing said so and gestures just didn't work. A
  helper that is not allowed yet, or switched off in Login Items, gets the right System Settings
  button. Nothing is installed without you, and Later starts the VM as it is. `omacvm check` has
  the same answer in its new "Mac setup" line.

## 3.1.27

- **Vendor HID devices is gone.** The experimental switch under USB devices (3.1.14, by
  @fbalazsy, #424) is removed at its author's request (#476). USB devices work as before; a
  vendor HID board stays with the Mac again, also one remembered as Connect. The USB Devices
  list then shows it as plugged in and kept by macOS, and the VM's log says why it did not
  connect. A VM folder's old `usb-vendor-hid` file is no longer read.
- **Full screen including notch: FullPanel rewritten with one small hook instead of many**
  (@brianmerchant, #480). macOS lays the VM's window out over the whole display itself now
  (FullPanel answers its full-screen menu bar question), and the menu bar's reveal is seen through
  AppKit's titlebar window instead of hooks on a private AppKit class. Nothing changes in how it
  looks or how it is set. With external displays on, `omacvm check` no longer warns about their
  windows' normal full screen. Earlier versions (3.0.16-3.1.26) adapted UTM's code (Apache-2.0);
  UTM is now credited in the notices ([ADR 0044](docs/adr/0044-fullpanel.md#replacement)).

## 3.1.26

- **Chrome no longer looks gray with HDR on.** With the experimental HDR switch on, Chrome and
  Chromium draw their whole window as HDR, and the VM dimmed all of it to fit, so pages and white
  looked gray. Their normal content now looks exactly like any other app's, and HDR video still
  goes brighter than white as far as the display can show.
- **OmacVM writes your home in the VM as you, everywhere.** After `~/.ssh`, the rest of the VM
  side did the same: `omacvm apply` wrote Hyprland's config, the Bridge's token, the bar's plugin
  folders and its own markers in the desktop user's home as root, following links there, so a
  program running as that user could point one at a system file and get root at the next apply.
  All of that is now written as the user, and root reads the user's files only as the user's
  own. The Mac folder is mounted at `~/Mac` only when that is a real folder, never through a
  link. `omacvm apply` sends the VM folder's SSH key on stdin again, not inside a command.
- **Update VM's SSH messages name the right key.** They say "this VM folder's key" (it said
  "this Mac's key"), and a VM that had the key already but still turns OmacVM away says so. The
  command for the VM's terminal also goes into the update's log, so Show Log still has it after
  Back. A VM folder whose `ssh-key.pub` went missing gets it back from its `ssh-key` instead of a
  new key the VM does not know. Without a guest agent, a feature switched while the VM was
  stopped gives up after about 10 minutes again (up to 20 with the SSH repair before it).
- **Graphics without QEMU's lock and Vulkan windows without a copy are on by default.** Both
  switches in the VM window's General section were off and marked experimental (since 3.1.18 and
  3.1.24). With them on, graphics work that only touches the GPU runs without QEMU's lock, so the
  VM's CPUs wait less for it (Mac mini, new Chromium windows: longest stop 107 ms -> 1 ms), and
  on macOS 26 and newer Vulkan apps' frames reach the screen without a copy. With MoltenVK
  (macOS 15) they are copied as before: the switch says so there, and `omacvm check` no longer
  warns about it. 10- and 25-minute runs with both on, on a Mac mini M4 and a MacBook Air M2
  with macOS 27: no GPU restart, no crash, no memory growth. Not tested on macOS 15. A switch
  you set in the VM window stays as you set it; if you went back in 3.1.18 with
  `defaults delete`, switch it off in the window. GPU safe mode still turns both off.

## 3.1.25

- **App VMs that know only another Mac's SSH key get this VM folder's key.** A VM set up on another Mac
  (or before 3.0.12) let only that Mac in over SSH: Update VM waited 5 minutes and then said the
  VM "did not come up", and feature switches failed. The app now adds the VM folder's own key
  through the VM's guest agent, without SSH: quietly at each start, and in Update VM within
  seconds of the first refusal, after which the update goes on. Only when the guest agent does
  not answer, Update VM stops with a **Copy Command** button (and an (i) that says what the command
  does) for a terminal in the VM. A VM that turns the key down now shuts down cleanly, and
  `omacvm apply` points to the same fix.
- **`omacvm apply` writes your `~/.ssh` in the VM as you.** It added the VM folder's SSH key to
  the desktop user's `~/.ssh/authorized_keys` as root and followed links there: a program
  running as that user could point `~/.ssh` at a system file and take it over at the next apply
  (and with it, root). That part now runs as the user; root's own key file is written as before.
- **A VM from a prebuilt image gets Vulkan, WebGPU and GPU compute again.** The image's package
  list is as old as the image, and Arch Linux ARM's mirrors keep only the newest version of each
  package. On a VM made today from the 3.0.8 image (11 days old), setup could not install the
  Vulkan driver's build tools or OpenCL ("package list older than the mirrors"): on macOS 26 and
  later the VM ended up with OpenGL only, and switching WebGPU and GPU compute on failed the same
  way. Setup now brings the VM's system up to date first, once, with Omarchy's own update (never
  one package alone), and restarts the VM when that brought a new kernel. On the Air the update
  took about 2.5 minutes (200 packages), and the whole setup 8.5 minutes, with everything working.
- **The update in the VM is no longer cut off half way.** OmacVM's system update (Graphics ->
  Vulkan, and now a prebuilt VM's setup) took systemd being briefly away during the update for the
  update's end, and stopped it in the middle of pacman's run.
- **A feature that did not switch on says why in the app.** After a failed switch the window and
  the log showed only "rolled back ... (what failed is above)"; that line now names it, e.g. "WebGPU
  and GPU compute was not set up: Omarchy's package list is older than the mirrors (omarchy update
  first)". `omacvm check` shows a FAIL row for WebGPU and GPU compute when it is on but its
  packages are missing, instead of "off: Graphics gives this VM OpenGL only".
- **Deleted files give their space back sooner.** In an OmacVM.app VM, what you delete goes
  back to the Mac by itself within about two minutes (disk.img gets smaller, and still grows up
  to the size you set). Files deleted outside your home folder stayed as long as one of
  omarchy-mac's update snapshots held them, and it keeps 5, one per `omarchy update`. VMs now
  keep the last 2: the older ones go once the next Update VM has updated the VM (a failed one
  leaves them), and the disk is trimmed then. A number you set yourself stays. On a test VM
  with 5 update snapshots, this step followed at once by a shutdown, as Update VM does it, gave
  back 1.9 GiB on the Mac before the VM was off (part of it the VM's first trim, which comes
  once). Each update after it gives back what its oldest snapshot held (before: nothing).
  `omacvm check` shows a "freeing disk space" line.
- **No second pointer over the VM.** The Mac's arrow could show up next to Omarchy's pointer and
  stay until you switched out of the VM and back. The app hid the Mac's cursor once when the VM
  took the pointer, but other programs and macOS can show it again (OmacVM Gestures also hid and
  showed it over full-screen VMs). While the VM has the pointer, the Mac's cursor is now an empty
  picture as well, so nothing shows when someone else shows it, and OmacVM Gestures leaves the
  app's VMs alone (Parallels, UTM and VMware Fusion as before). This also holds while the pointer
  rests, for example while you type: the app looks twice a second while it hides the cursor.
  Ctrl+Option+G, leaving the VM and switching apps bring the arrow back as before; on
  Omanotch's strip beside the notch the strip's own pointer stays.
- **HDR and 10-bit colour (experimental, off by default).** A new switch in the app's Display
  settings, shown on Macs with an HDR display (a MacBook Pro's XDR panel, an HDR monitor). With it
  the VM's main window runs at 10 bits: smoother gradients (about twice the levels on screen), and
  HDR highlights from Linux apps that send HDR. White stays the Mac's white; brighter parts go as
  far as the display can show at its current brightness (the VM tone-maps, macOS does not do it a
  second time, which made the desktop look dim). The VM loads its 10-bit graphics driver only for
  a start with the switch on; Update VM builds it. Few Linux apps send HDR yet (GStreamer does;
  mpv and Chromium show HDR video as SDR). Other displays' windows stay as they were.
- **The app's window opens at most 800 pt tall,** centred. On a large display it used to open as
  tall as the screen; you can still drag it taller.
- **mpv keeps playing in UTM VMs too.** UTM's VM draws OpenGL with virgl as well, with the same
  Mesa and mpv, so mpv's default output (gpu-next) keeps one open file per frame there too and
  stops drawing after about 17 s of 60 fps video. UTM VMs now get the same `vo=gpu` line in the
  system-wide mpv.conf as app VMs at their next `omacvm apply`; a `vo` line in your own
  `~/.config/mpv/mpv.conf` still wins. `omacvm check` shows the mpv line in UTM VMs.
- **WebGPU and GPU compute in the VM are faster on macOS 26 and newer.** KosmicKrisp, the Vulkan
  driver the app uses there, kept a compute shader's shared memory in a byte array, and Metal's
  compiler made every access to it slow. It is now 16-byte aligned: a WebGPU matrix multiply in a
  VM on a MacBook Air M2 went from about 256 to about 757 GFLOPS (MoltenVK: about 895).
- **Screenshots no longer crash the desktop (OmacVM.app).** Each screenshot left about 180 MB
  (on a 5K display) in a small memory folder of the VM, `/run/user/1000`. After a handful it was
  full, and Hyprland and apps such as Electron apps crashed (SIGBUS) and Hyprland came back in
  safe mode. OmacVM's own build of hyprpicker, which freezes the screen for screenshots, did not
  delete its files when it stopped. It does now, and Update VM removes what was left. `omacvm
  check` warns when that folder is over 80 % full.

## 3.1.24

- **The VM window keeps its size after full screen.** Leaving full screen gave the window back
  smaller, again with every full screen (1280 x 720 became 1140 x 700, then 1120 x 700): macOS
  put the old size back while the window still had the full-screen display's shape, and the
  window's 20-point steps rounded that down. The window now drops that shape before macOS puts
  its size back.
- **The app's window stays 800 points wide.** A double-click on its title bar (macOS's Fill) or
  window tiling made it as wide as the screen while its content stayed 800 points. It now goes
  back to 800 points at once, around the same middle; only its height changes, as intended.
- **mpv keeps playing after 17 seconds.** In app VMs mpv's default video output (gpu-next)
  kept one open file per frame: after about 17 s of 60 fps video it hit its limit of 1024 and
  every frame after that failed ("expect bad rendering" in its log). The leak is mpv's: it never
  hands its frames back to libplacebo's OpenGL swapchain, which frees each frame's fence only
  there, and on the VM's OpenGL (virgl) every fence is a file. The VM's system-wide mpv.conf now
  has `vo=gpu`, which frees them (5 minutes of 1080p60: 28 open files throughout). A `vo` line
  in your own `~/.config/mpv/mpv.conf` still wins. A VM gets it at its next Update VM;
  `omacvm check`'s mpv line now shows in every app VM.
- **Vulkan windows run at the display's rate.** A Vulkan app that waits for the display
  (vkcube, most games) ran at 45-50 frames a second on a 60 Hz display, OpenGL apps at 60.
  Mesa gave each frame a target time from the last frame's presentation and Hyprland held it
  until then; the VM's frame clock runs a few ms late, so frames often waited a refresh more.
  VMs with Vulkan now leave that timing out (`MESA_VK_WSI_DEBUG=nowlts`; a value you set
  yourself wins): vkcube 50 -> 60 fps on the Mac mini. Counts from the next login.
- **Vulkan windows without a copy (experimental, off).** A new switch in the VM window's General
  section, next to "Graphics without QEMU's lock". QEMU copied every frame of a Vulkan window
  on its main loop: 2.5 ms a frame for a 1816 x 870 window on a Mac mini, while the VM's CPUs
  waited. With it on (macOS 26 and newer), the Vulkan driver writes each frame into memory the
  Mac's OpenGL can read and the GPU puts it in place: 0.3 ms. Frame rates and pictures stay the
  same. `omacvm check` says which way the VM's Vulkan windows go (ADR 0047).

## 3.1.23

- **Keyboard sharing apps has a switch.** The setting for Synergy, Deskflow, Barrier and Input
  Leap (3.0.18, #350) was only a Terminal command. It is now a switch in the VM window's
  settings, under Input, with an (i) that says what it does. It counts from the VM's next start.
- **Mac input: modifier keys in the debug log.** With `OMACVM_IME_DEBUG=1`, each Shift, Control,
  Option or Command press and release now shows in the log with what the Mac's input method did
  with it, to find why a Shift tap does not always switch Chinese and English (#357, thanks
  @Vocllum).
- **OpenCL is right from the first login after a switch to Vulkan.** The check whether the Mac's
  Vulkan driver gives OpenCL a GPU (it does not on macOS 15) ran 90 s after the desktop came up,
  so the first session after switching Graphics to Vulkan could offer OpenCL without a device
  until the next login (apps then fell back to the CPU). It now also runs before the desktop
  session starts.

## 3.1.22

- **New VMs build again, and omarchy update works again.** Since 18 October, Omarchy's package
  server has no ARM builds of two Hyprland parts (hyprtoolkit and hyprland-guiutils), but
  omarchy-mac still asks that server for them by name. So building a new VM here stopped while
  Omarchy installed, and `omarchy update` in a VM stopped with "target not found"
  (omacom/omarchy-mac#741). OmacVM now leaves those two out while Omarchy's server does not have
  them, and the VM takes Arch Linux ARM's builds of them, which fit Omarchy's Hyprland. When the
  server has them again, nothing changes from how Omarchy does it. A VM gets this at its next
  Update VM; new VMs have it from the start. The ready-made VM download was not affected.
- The control centre's Omarchy update (and Graphics -> Vulkan on an older ready-made VM) now runs
  the same Omarchy as `omarchy update` in the terminal, not the copy the installer left behind.

## 3.1.21

- **mpv shows video with Vulkan.** With Graphics on Vulkan (Automatic on macOS 26 and newer), mpv
  picked Vulkan by itself and showed no picture at all. Now the VM's system-wide mpv.conf has
  mpv draw with OpenGL, which plays it (a 4K60 clip on the Mac mini). A `gpu-api` line in your
  own `~/.config/mpv/mpv.conf` still wins; Graphics OpenGL takes the line out again. A VM gets it
  at its next Update VM; `omacvm check` has an mpv line.
- **Swipe out to macOS goes the right way on macOS 26 and older.** On a MacBook Pro on macOS
  15.7 the Space first moved the wrong way (or bounced), then the swipe out took one step after
  all, and after two such swipes it stopped following the fingers. macOS before 27 reads the
  swipe's direction from fields it does not document; the direction the escape combo learned on
  that Mac now counts for the swipe out too, and a swipe that lands on the other side, or bounces,
  teaches it once. macOS 27 is unchanged.

## 3.1.20

- **WebGPU and GPU compute have a switch.** On macOS 26 and newer, where Graphics Automatic gives
  the VM Vulkan, OpenCL and WebGPU have run on the Mac's GPU since 3.0.13. Now they can be
  switched off and on again: General › WebGPU and GPU compute in the VM window (with the VM
  stopped, it counts from its next start), the control centre, or `omacvm disable gpu-compute`. Off removes OpenCL's switch, the
  "Chromium (WebGPU)" menu entry and Firefox's WebGPU; Vulkan stays as Graphics says. On by
  default, as before; a VM gets the switch at its next Update VM, with nothing to rebuild.
- **OpenCL only where it works.** With Graphics on Vulkan on a Mac whose driver Zink cannot use
  (MoltenVK, macOS 15), OpenCL listed a platform without a device. Now the VM checks Zink's device
  at Update VM and after each start, leaves OpenCL off there (apps use the CPU), and
  `omacvm check` says why.
- **Quieter OpenCL.** Zink's "Some incorrect rendering might occur" line is gone from every OpenCL
  start (Mesa's `ZINK_DEBUG=quiet`); rusticl's note about libclc stays (Mesa has no switch for it).
  With OmacVM's own Mesa (the vulkan feature, for macOS 15), Arch's OpenCL no longer adds a second
  platform with "Zink requires the nullDescriptor feature" at every start.
- Firefox gets WebGPU with Vulkan too (before only with the vulkan feature). The vulkan feature is
  now called "OmacVM's own Mesa (macOS 15)", and switching it off says that Vulkan follows Graphics
  instead of "Vulkan: off". qemu.log's graphics line names the Vulkan driver QEMU loads, also when
  `OMACVM_VULKAN_DRIVER` picks one.

## 3.1.19

- **Update VM no longer builds a new kernel by itself.** With the memory-optimized kernel on
  (off by default), every update after Arch Linux ARM released a new kernel (about once a week)
  built it in the VM: 10 minutes with 16 CPUs, over an hour with 4, and on a MacBook Air close
  to Update VM's 40-minute limit. Now Update VM asks first (Build Now or Later, with the time for
  the VM's CPUs); Later keeps the VM's kernel, and the next Update VM asks again. `omacvm update`
  asks in Terminal; `omacvm update --kernel` builds it without asking. A build gets its own time
  in Update VM instead of the 40 minutes.
- **The graphics switch from 3.1.18 is in the VM window.** General › Graphics without QEMU's lock
  (experimental, off by default), with an (i) saying what it does and what was measured. Same
  key as the `defaults write` in 3.1.18; counts from the next start of the VM.

## 3.1.18

- **The VM's graphics without QEMU's big lock (experimental, off by default).** While an app
  opened or a page drew new things, the VM's graphics held QEMU's lock for up to 100-350 ms,
  and the VM's CPUs stopped with it: the VM froze for that long, and its sound and typing
  waited. With `defaults write org.omacvm.app gpuOffMainLoop -bool true` the graphics work runs
  without that lock (counts from the next start of the VM). Measured on the Mac mini while new
  Chromium windows opened: the longest stop of the VM 107 ms -> 1 ms; while a Vulkan app
  started 779 ms -> 14 ms. Keys reach the screen as fast as before (60 Hz with a page scrolling
  beside: half within 34.8 ms, 95 % within 45.5 ms; before 37.3 and 69.2; 120 Hz the same), and
  Vulkan, WebGPU and OpenGL scores are unchanged. `defaults delete org.omacvm.app
  gpuOffMainLoop` goes back. GPU safe mode always takes the old way.

## 3.1.17

- **The sound on its own thread is on for everyone.** 3.1.16 brought it as an experiment; with it
  the VM's sound crackles much less while apps open, pages scroll or the Mac is busy, and reaches
  the Mac about 60 ms sooner. It has a switch in a new Output section of the VM window (after
  Input), with an (i) saying what it does. Off there (or `defaults write org.omacvm.app
  audioThread -bool false`) goes back to the sound as in 3.1.16 and before. Counts from the next
  start of the VM.
- **External display brightness never sends DDC/CI on the Mac's HDMI port.** There the Bridge's
  first DDC/CI read made a BenQ PD2500Q behind an HDMI to DisplayPort adapter go black and drop
  off until it was plugged in again, even with no VM running (#433, thanks @yusiwen for the
  thorough report). `omacvm check` now says "on the Mac's HDMI port" for such a display; use
  USB-C/DisplayPort for its brightness. A display that goes away right after DDC/CI on any other
  port gets none again, and a display that does not answer is asked at most three times instead
  of every minute.
- **Less battery at idle.** A VM sitting on its desktop wakes the Mac less often:
  - With its window minimised, hidden, covered or on another Space, QEMU kept its screen tick at
    the display's rate after any frame, 60 or 120 times a second for nothing. It now stays slow
    until the window shows again, and the newest picture is there at once.
  - In the VM, the display's vblank timer stops 100 ms after the last frame. It ran for 5 s after
    every frame, 300 to 600 wakeups each time, and all the time next to a blinking cursor.
  - OmacVM Gestures no longer looks at a resting pointer 20 times a second while a VM is full
    screen: the pointer's first move wakes it. `defaults write org.omacvm.gestures PointerRestTap
    -bool false` goes back to the old way.
  - The app, QEMU and the VM's own helpers wake less: the Mac clipboard is looked at twice a second
    while the VM is in front (four times before), the Bridge's event readers in the VM wait without
    a timer, video decoding's watchdog pings less, and the VM's Gestures client stops writing a log
    line every 2 s while OmacVM Gestures is not running.

  The watts get checked on a MacBook next; on the Mac mini this was measured in wakeups and CPU.

## 3.1.16

- **The sound on its own real-time thread (experimental, off by default).** OmacVM.app moved the
  VM's sound in QEMU's main loop, next to the VM's graphics: when an app opened or a page
  scrolled, the graphics held that loop for 100-350 ms and QEMU's sound buffer ran dry. With
  `defaults write org.omacvm.app audioThread -bool true` the sound card and the mixer run on a
  thread of their own at real-time priority, and the sound reaches the Mac about 60 ms sooner
  (round trip in the VM 272 -> 209 ms; videos stay in step). Measured on the Mac mini, 4 minutes
  each: browsing in Chromium while music plays 0, 0, 0, 0 and 2 breaks (before: 5, 14, 0, 0);
  the Mac busy 0 in 4 runs (before: 12, 0, 0). Not better yet with the VM's GPU busy (a game, WebGL)
  or everything busy at once: the VM itself stops while its graphics work, and the shorter
  buffer covers less of that. `defaults delete org.omacvm.app audioThread` goes back. `omacvm
  check` says which way the sound goes ("sound timing").

## 3.1.15

- **No more full-screen Spaces in a loop when a display goes while the Mac is locked.** With the
  VM in full screen on two displays, unplugging one while the Mac was locked (or a display waking
  up inactive for a few seconds) made OmacVM put the second display's window into full screen
  again and again: dozens of black full-screen Spaces and a clicking Mac until the VM quit. Now
  the VM's windows follow the displays only once they settle and the Mac is unlocked, a display
  that shows up inactive or at 1 x 1 counts as gone, full screen is tried at most four times per
  display, and a window that goes takes its Space with it. Reported by @ylorn (#428).
- Vendor HID devices: disconnecting one no longer freezes the VM for a moment while a request is
  still running (thanks @fbalazsy, from #427).

## 3.1.14

- **Vendor HID devices (experimental, off by default).** Boards that talk to their tools in HID
  reports of their own (ECU interfaces, bootloaders, programmers) are held by macOS's HID driver, so
  USB devices kept them on the Mac. A second switch under USB devices in the VM's window, **Vendor
  HID devices**, lets the VM have them: they are asked about, listed and remembered like other
  devices, and the VM gets their reports through macOS, without root. Only a device with one HID
  interface and its maker's own reports; keyboards, mice, game controllers and security keys stay
  with the Mac. With the switch off none of it runs. By @fbalazsy (#424).

## 3.1.13

- **Omanotch's bar from before 3.1.12 is made new once.** A bar copy without a saved original
  (set up with OmacVM 3.1.11 or older) could not follow Omarchy's updates and needed a step by
  hand. Update VM now makes it new from the installed Omarchy with OmacVM's patch, and from then
  on Omarchy's updates merge into it. If the old copy differed (your own edits, an older Omarchy),
  it is kept whole in `~/.config/omarchy/plugins/.<you>.bar.before-3.1.13`, and `omacvm check`
  and the control centre say where for two weeks or until you delete it. The same for the
  background copy.

## 3.1.12

- **Omanotch's bar follows Omarchy's updates and keeps your edits.** Omanotch runs its own copy of
  Omarchy's bar and background, and that copy stayed at the Omarchy it was made from. Now it follows
  each Omarchy update the way Omarchy updates its own plugins: your own changes in the copy stay
  when they don't touch what Omarchy changed. When they do, or OmacVM's patch doesn't fit the new
  bar yet, the copy stays as it is and `omacvm check` and the control centre say so. If the new
  bar doesn't load, it goes back to the one before.
- **A new VM's Omanotch bar could stay unpatched.** Right after setting up a VM with Omanotch, the
  shell could keep its compiled copy of the bar from before the patch, also after restarts: no bar
  beside the notch. Update VM fixes such a VM, and OmacVM now clears that compiled copy whenever it
  changes the bar.
- **The control centre shows warnings:** a feature that works, but not quite as it should, says
  why on its row (they were left out before).
- **A note by the keyboard light while macOS keeps it off** (MacBooks). With "Adjust keyboard
  brightness in low light" on, macOS turns the keyboard light off in bright light, and Shift with
  the brightness keys cannot light it then. The control centre says so next to the keyboard light,
  only while that setting is on.

## 3.1.11

- **Swipe out to macOS with four fingers.** With four fingers the swipe out mostly did nothing:
  the fourth finger coming down a moment after the others looked like a pinch. Now it follows the
  fingers like with three.
- **Swipe out follows the fingers your VM switches workspaces with.** If you give 3 fingers to
  something else (moving focus, snapping windows) and swipe workspaces with 4, only 4 fingers swipe
  out to macOS and 3 fingers stay with the VM. OmacVM reads your Hyprland gestures, also after you
  change them. Setting up gestures no longer adds a 3-finger workspace swipe when you use 3 fingers
  for something else.
- **A second display keeps the scale you pick** (OmacVM.app with a second Mac display, #416, thanks
  @fbalazsy). Picking 1.25x for Virtual-2 in the display panel lasted only until the next display
  sync, which put the display's own scale back. The pick is now saved per display and stays after a
  Hyprland reload and unplugging the display. The main display keeps Omarchy's own scaling.

## 3.1.10

- **Shift and the other modifier keys work when you type on another Mac's keyboard through
  Universal Control** (OmacVM.app). Shift was released the moment it was pressed, so Shift+2 typed
  2. The VM now sets each modifier from the flags macOS sends with every key, instead of flipping it
  on each change (#412, thanks @ylorn).

## 3.1.9

- **Skip the notch: the hidden indicators open left of the notch** when they don't fit right of it
  (Dictate, Screen Recording and the others). The tray stays where Omarchy has it, and the notch
  looks untouched until you point at the bar. Fixed: the weather and the tray jumping back and
  forth while the indicators showed, the room kept for them (a gap once a module was turned off),
  and the tray's "<" not opening after pointing at the notch. The setting's (i) shows it. Update VM
  brings the new bar.

## 3.1.8

- **Unplugging a display no longer shuts the VM off** (OmacVM.app, Full screen including notch,
  with a second display). When the display the VM's window was on was unplugged, macOS took the
  windows out of full screen and QEMU crashed while letting go of the other display's window: the
  VM was gone and Omarchy started from scratch. Now the VM keeps running and its window goes to a
  display that is left (#402, thanks @epicoun).

## 3.1.7

- **Shift and the brightness keys set the keyboard light reliably** (MacBooks, VM in front). Shift
  was often missed, so Shift + brightness changed the display instead (from a dim screen down to
  black) and the keyboard light could not be turned down again. The Bridge now reads Shift and
  Option from the keyboard itself. On macOS 27 every brightness press also stepped twice; now it
  steps once. A held key keeps going where it started when Shift is let go.
- Chromium no longer says "Failed to load extension" at every start after an `omacvm apply` of only some features: the no-AV1 extension now lives outside the folder apply replaces (#406, thanks @fbalazsy).

## 3.1.6

Swipe out to macOS follows your fingers, like a macOS Space switch.

- **Swipe out to macOS follows your fingers.** Past your first or last workspace the macOS Space
  beside the VM now moves with the swipe, like a macOS Space switch: pull back to stay in the VM,
  let go (or flick) to finish (#342). It used to wait for the lift and then jump in one step.
  Inside the VM, Hyprland's workspace swipe is as before. The VM needs Update VM (or `omacvm
  update`) for it; until then the swipe out works as before.
- The escape combo's fallback swipe (when macOS's Space shortcut does not move the Space) now
  works on macOS 27 too.

## 3.1.5

Skip the notch: when the bar is full, its items continue on the other side of the notch (an opt-in setting).

- **Skip the notch** (OmacVM.app, off by default, on a MacBook with a notch): bar items that no
  longer fit on their side of the notch continue on its other side, in the same order, instead of
  going behind the notch. They only hide when both sides are full; the menu and the clock at the
  far right never move. Omarchy's small indicators (Stay Awake and the others that show on hover)
  keep their room, so showing them moves nothing. In either full screen, only the bar beside the
  notch: external displays keep their bar. Display > Skip the notch in the VM's window (its (i)
  shows a picture), `omacvm notch --vm NAME --skip on`, or the control centre; a running VM
  follows within seconds.
- **Control centre: the Full screen row now shows for OmacVM.app VMs** (before, it never did: the
  Mac refused the command behind it).

## 3.1.4

The app icon's look stays in the Dock, and the Updates row shows how far a download is.

- **OmacVM.app: the icon's look stays in the Dock.** The look you pick for the app icon (click the
  icon in the window's header) now shows in the Dock all the time: with the window open, while the
  VM runs, after it shuts down, and when OmacVM is not running but kept in the Dock, also after a
  restart and after an update. Before, it showed only while the VM ran. Finder and Launchpad keep
  OmacVM's own icon: the app on disk is not changed, so its signature stays intact.
- **OmacVM.app updates: the Updates row shows the download's progress** ("Downloading OmacVM
  3.1.5… 12.3 of 34.8 MB"), and `update.log` says how long each step took. The checks of a new
  version (checksum, unpacking, signatures) take under a second; when an update takes minutes, it
  is the download (on a MacBook Air's Wi-Fi on 2026-10-13 the 35 MB came in at 0.3 MB/s). The
  downloads now stop at once when a server sends more than the signed feed names, and the switch
  to the new version no longer waits when macOS's app list (LaunchServices) hangs.

## 3.1.3

Omanotch is ready for Omarchy's next shell.

- **Omanotch is ready for Omarchy's next shell.** Upstream Omarchy changed its bar and wallpaper in
  October 2026 (omarchy-mac has not shipped that yet), and Omanotch's patches no longer applied to
  them: a VM set up on that shell would have had no Omanotch. Both patches now fit the old and the
  new shell, and notifications under the strip keep only the normal gap on both.
- On that shell too: the Bridge keeps Omarchy's own indicators when it takes out the night light
  one (it put omarchy-mac's list there), and OmacVM.app's display panel draws its "Use external
  displays" row's highlight on Qt 6.12.

## 3.1.2

The Mac's wallpaper follows the VM's theme again on every Space, the Updates row says when an update downloads, and a source checkout uses the app's Mac helpers when its Swift fails.

- **The Mac's wallpaper on every Space**: when the VM's theme or background changes, every Space
  and display shows the new picture again. The picture settings the Bridge copies to every Space in
  macOS's wallpaper store could still name the old, deleted picture, and on macOS 27 the store
  entry it wrote was refused, so every Space showed macOS's default picture. Thanks @fbalazsy
  (#388).
- **Updates: the settings row says "Downloading OmacVM 3.1.3…"** while a found update downloads
  (from the next update on), instead of "Checking…" (it looked stuck on a slow connection), and
  offers **Update Now** next to the switch once the update is ready, the same as the banner.
- A source checkout of OmacVM (`~/.omacvm` or a clone) asks the installed OmacVM.app's built
  helpers (notch, display, clock format, free space) when its own Swift run fails, for example on
  an SDK the compiler does not support. Before, the answer was lost. Thanks @fbalazsy (#387).

## 3.1.1

Omarchy's shell draws again on Qt 6.12, and the settings sidebar marks the section at the top again.

- **Omarchy's bar, menus, OSD and notifications draw again on Qt 6.12** (Arch Linux ARM's update
  of 2026-10-12). They were empty, and a VM built from scratch since then had a blank shell from
  the first boot. Qt 6.12 brought a `Color` of its own into QtQuick, which hid Omarchy's shell
  colours. OmacVM imports QtQuick 6.11 in the Omarchy files that need it (nothing changes on Qt
  6.11) and does it again after every Omarchy or Qt update. A VM that is already blank: Update VM
  (or `omacvm apply`). Reported by @raulVetclaims (#376).
- `omacvm check`: a **shell colours** row counts the colour errors in the running shell's log and
  says what to do.
- OmacVM.app, the VM's settings: while you scroll, the sidebar marks the section at the top again.
  Only over the last screen of the page does it move on, so the last sections are marked in turn
  and the last one at the very bottom. (3.1.0 marked the section near the middle of the window.)

## 3.1.0

A new settings window, Swipe out to macOS, Closing the window, every scale in Full screen including notch.

- OmacVM.app: **the VM's settings in one window**. A header with the VM, its state and Start; a
  sidebar (General, Display, Input, Sharing & Devices, Storage & Updates) that scrolls to each
  section. Resources and the disk's size change in the window itself (− and +). Every setting
  keeps its key or file, so the choices you made stay.
- OmacVM.app: **Closing the window**: *Shut down* (the default), *Keep running* (the VM goes on;
  click OmacVM in the Dock to come back; Quit still shuts it down) or *Ask*. Asked for by
  @Vocllum (#358).
- **Swipe out to macOS** (off by default): swipe past your first or last workspace to the macOS
  Space beside the VM, the same way ⌃⌥ Esc goes. On the right, the first swipe from your last
  workspace still opens a new one. A Magic Mouse swipe counts too. Every route: OmacVM.app's
  window, the control centre or `defaults write org.omacvm.gestures SwipeOut -bool true`. Asked
  for by @epicoun (#342).
- OmacVM.app, **Full screen including notch**: every Omarchy scale (1, 1.25, 1.6, 2, 3, 4) works,
  without a black band, and the next start begins at that scale. Before, 1.25 and 1.6 became
  1.33 and 2. Thanks @brianmerchant, whose PR and tests were the reference (#355).
- OmacVM.app, **Full screen including notch**: with macOS's "Always show the menu bar in full
  screen" on, the strip is covered anyway while **Keep the Dock and hot corners away** is on (the
  default). With that off it still falls back to normal full screen, and `omacvm check` warns
  (#356, @brianmerchant).
- OmacVM.app, **Full screen including notch**: macOS's own menu bar reveal on the way into full
  screen no longer shows over the strip.
- OmacVM.app: **Update VM** no longer turns off Chrome's and Brave's WebRTC video encoding. Each
  start puts the flags back when they are missing, so a VM updated with 3.0.18 is fixed by its
  next start.
- OmacVM.app: a VM window you cannot see (minimised, hidden, covered, on another Space) draws no
  frames until it shows again.
- OmacVM.app: **updates** show as a banner under the header, with What's New, Later and Update
  Now (Update After Shutdown while the VM runs). No macOS notification.
- OmacVM.app: **Delete VM…** asks for the VM's name, typed exactly.
- OmacVM.app: **the app icon** has eight looks (OmacVM's own and seven Omarchy themes): click it in
  the window's header. The Dock and the VM's window show it too.
- OmacVM.app: the new VM's setup, the USB devices list and All VMs have the same look, light and
  dark.
- ⌃⌥ Esc no longer shows a notice in Omarchy.
- **Control centre**, every route: the Mac's **Escape combo** (focused monitor or all) and **Swipe
  out to macOS**, next to Magic Mouse swipe. On the Mac: `omacvm gestures` (`escape pointer|all`,
  `swipe-out on|off`, `mouse-swipe 3|4`).

## 3.0.18

Fixes for Full screen including notch, the start animation, Omanotch's patches and Mac input
methods, and a switch for keyboard sharing apps.

- OmacVM.app, **Full screen including notch**: macOS's menu bar no longer slides in at the top
  edge while **Keep the Dock and hot corners away** is on (the default), as in normal full screen.
  With that setting off it still comes down at the top edge (3.0.16) (#362).
- OmacVM.app, **Full screen including notch**: with Omarchy's bar hidden (Super+Shift+Space) the
  strip beside the notch was black. The wallpaper now fills the whole screen up to the top edge;
  windows still start below the strip. A full-screen video still turns the strip black (#364).
- OmacVM.app: the **start animation** (OMACVM turning into Omarchy's logo) now plays on every
  start, also with macOS's Reduce motion on. Before, Reduce motion gave a still logo (#359).
- OmacVM.app: **keyboard sharing apps** (Synergy, Deskflow, Barrier, Input Leap) could lose the
  keyboard to a VM started after them. A hidden switch puts OmacVM's keyboard taps at the end of
  macOS's chain, so the sharing app sees the keys first: `defaults write org.omacvm.app
  shareKeyboard -bool true`, then restart the VM. Trackpad gestures still go to Omarchy.
  Reported by @javierburongarcia (#350).
- **Omanotch**: the bar and wallpaper patches no longer trust their version line alone. A bar
  that has the line but not the whole patch (for example from another FullPanel build) is
  restored from its unpatched copy and patched again; without a clean copy the install stops and
  says to clone the bar again. Reported by @brianmerchant (#354).
- **Mac input methods** (mac-ime, experimental): in a VM whose language is not English, the control
  centre and `omacvm check` said the Fcitx5 module was not built, although it was; pacman's
  package info is now read in English. The same fix keeps `omacvm disable x86-apps` from leaving
  OmacVM's box64 behind in such a VM. The check's Mac links row (under Omanotch) no longer fails
  for a VM started with Mac input methods on. Fcitx5 no longer shows a tip at login to unset
  `GTK_IM_MODULE`: Fcitx5 runs without it, GTK apps keep it. Reported by @Vocllum (#357).

## 3.0.17

- OmacVM.app: the **start animation** (OMACVM turning into Omarchy's logo) plays again in full
  screen. A full-screen start keeps the window invisible until macOS has it in full screen, and the
  animation ran meanwhile: with **Full screen including notch** it was over before the window
  showed, and a normal full-screen start lost part of OMACVM's hold. Now it starts when the window
  shows (#352).

## 3.0.16

Full screen including the notch, without Omanotch: a new, experimental way to start a VM in OmacVM.app.

- OmacVM.app: **Full screen including notch, no Omanotch needed**, experimental and off by
  default. The VM uses the whole built-in display, top to bottom, including the strip beside the
  camera notch, and Omarchy's bar sits there, split around the notch, as tall as this MacBook's
  menu bar. macOS's menu bar comes down from the top edge as in other full-screen apps, also with
  Keep the Dock away. Omanotch is not needed for this and stays idle for that start. The VM
  window's **Start in** picker has it, with **Window** and **Full screen, notch via Omanotch**
  (only one can be active, so it is one setting now; on a Mac without a notch the choices are
  Window and Full screen). Also `omacvm fullscreen --vm NAME notch|standard` (or `omacvm notch
  --vm NAME fullpanel|native`) and the control centre's Full screen row. From the VM's next
  start; external displays stay as they are; `omacvm check` says whether the strip is covered.
  Notch via Omanotch stays the default and the way on UTM, VMware Fusion and Parallels. Proposed
  and first built by @brianmerchant (#339).
- Known trade-off: at the full panel height Hyprland offers the scales 1, 1.33, 2 and 4 (1 and 2
  on a 16-inch MacBook Pro), so a saved 1.67 becomes 2 in this mode. With the notch via Omanotch
  the scales stay as they were.

## 3.0.15

- OmacVM.app: the control centre showed **OmacVM Bridge and Touch ID as failing** ("OmacVM Bridge
  is not running") while both worked. 3.0.14's check finds the Bridge by its process, and macOS's
  `pgrep` leaves out its own parent processes; the control centre's check runs as a child of the
  Bridge, so the Bridge never found itself. Fixed with `pgrep -a`, with a test.

## 3.0.14

Gestures start working as soon as you allow them, and `omacvm check` tells the truth about the Mac helpers.

- OmacVM Gestures now notices when you allow Accessibility and Input Monitoring while it waits,
  and starts listening right away. Before, it could wait for good after a fresh install, so
  trackpad gestures and scroll momentum never connected until it was restarted (#330, reported
  by @brianmerchant). If macOS only tells a new process about the permission, the helper starts
  again by itself, once.
- `omacvm check` finds the Bridge and Gestures however they were started (after "Quit & Reopen"
  in System Settings macOS starts them itself), and reads their permissions from the running
  helper, not from an older log. It says when Gestures runs but waits for a permission. Both
  helpers now write their log also when macOS started them (#331, reported by @brianmerchant).
- `omacvm check` in the VM says "not checked: vulkaninfo missing" instead of "no Venus device"
  when vulkan-tools is not installed. Update VM now installs vulkan-tools with the Vulkan driver
  (#332, reported by @brianmerchant).

## 3.0.13

Vulkan by default on newer Macs.

- OmacVM.app: **Automatic graphics is now Vulkan on macOS 26 and newer** (KosmicKrisp), OpenGL
  before. Measured on a Mac mini M4 and a MacBook Air M2: the OpenGL desktop, WebGL and glmark2
  stay within 1 % with Vulkan on, and Vulkan apps and WebGPU work out of the box. A VM on Automatic
  builds its Vulkan driver at the next update and runs on OpenGL until then. OpenGL and Vulkan as a
  choice are unchanged.

## 3.0.12

VMs that move between Macs: copied, on an external drive, or opened on a smaller Mac.

- OmacVM.app: **Open Existing VM…** in the setup and in the settings (below VMs folder) shows a
  VM that is somewhere else, copied from another Mac or on an external drive, at once. Pick the
  VM's folder (the one with vm.env) or the folder it is in. Before, the setup only offered a new
  VM, and a VMs folder set there needed a restart of the app. A VM that runs in another app or on
  another Mac is not started: the window says so instead of "QEMU exit 1".
- OmacVM.app: a VM copied to another Mac can be reached there (Update VM, the Bridge, the control
  centre, `omacvm`). Each VM folder now has its own SSH key (`ssh-key`), which `omacvm apply` and
  Update VM put into the VM beside the Mac's own key; both keep working. Before, the VM knew only
  the key of the Mac that set it up, and Update VM on the other Mac waited for SSH. A VM set up
  before this gets the key at its next update on the Mac it came from.
- OmacVM.app: a VM copied from a bigger Mac starts with what this Mac allows. A VM with more CPUs
  or memory than this Mac has (16 CPUs and 48 GB on an 8 GB MacBook Air, say) starts, and runs
  Update VM, at this Mac's Best tier, and the window says so under Resources. Its vm.env keeps
  the full size, so it has it again on the Mac it came from.
- OmacVM.app: a VM that was not shut down cleanly, or whose folder was copied while it ran, asks
  before it starts (and before Update VM): "its disk may be damaged". While the app runs a VM,
  the file `running` in its folder names the Mac and QEMU; a clean shutdown removes it.
- OmacVM.app: Update VM no longer waits forever on a VM whose disk fails. When the VM's console
  or the update shows btrfs or ext4 errors or a read-only file system, the update stops at once
  and says what to do (a VM copied while it ran: copy it again after shutting it down there). An
  update that hangs is stopped after 40 minutes.
- Omanotch: a test can no longer leave your Omanotch on OmacVM's test port. The test port and the
  test Bridge's folder (`port`, `bridgeDir`) now come only from a test Omanotch's launch arguments;
  saved values are ignored and removed at start. On a MacBook Air a test had saved both, Omanotch
  listened on 47911 with the test Bridge's token, and the VM's notch stayed empty.

## 3.0.11

- Omanotch: the bar sits in the middle of the notch strip at every display scale, on the 14- and
  16-inch MacBook Pro and the MacBook Air. At scale 1.6 it was about 3 px too low, at scale 2 about
  1 px too high. At fractional scales the hidden NOTCH output is rounded up to whole pixels, and
  the strip meant to cut those extra rows at the top, but cut them at the bottom (AppKit flips a
  flipped view's layer too). The bar also centred itself in the whole output rather than in the
  part the strip shows, in whole logical px (5 above and 6 below at scale 2). Now the strip cuts
  at the top and the bar centres in the shown part to the pixel.
- Omanotch: switching the Omarchy theme shows Omarchy's reveal again, instead of a black flash
  and the desktop sliding in. A theme switch reloads Hyprland's config, which dropped the rule
  omacvm-display-sync gives the screen; the screen fell back to an "auto" place, which is to the
  right of the hidden NOTCH output, until display-sync put it back 0.3 s later. Hyprland slid the
  picture along and the wallpaper hid while its output moved. omacvm_app.lua now sets the rule
  the screen shows again during the reload (display-sync keeps it in the runtime folder), so
  nothing moves. And the reveal ran on the strip only when its new image was ready first; the
  built-in display then switched at the end without the animation. A late output now joins the
  running reveal (background patch v7).
- Vulkan (Venus): apps that check for Vulkan at start and then let it go no longer crash a
  moment later (Moonlight crashed at every start). A thread that had used the Venus driver
  ended after the driver was unloaded and ran Mesa's cleanup from unloaded code. OmacVM's
  Venus build now has Mesa's fix (commit 935c4ec3, not in a Mesa release yet); the VM
  builds it again on the next `omacvm apply` (a few minutes, while Vulkan is on). If you started
  Moonlight with `VK_ICD_FILENAMES=/nonexistent.json` (or a similar Vulkan override) to
  get around it, remove that now.
- OmacVM.app: the "Mac input (Chinese, Japanese, Korean)" switch in the VM's window can now be
  used (#316). It was greyed out while the VM was stopped, and while the VM runs the window is
  hidden. Now you switch it while the VM is stopped ("From the next start."): at the next start
  the VM gets the input method port, and the app sets up the VM's part as soon as the VM is up,
  so it works from that start. Switching it off works the same way. While the VM runs, the
  control centre (or `omacvm enable|disable mac-ime`) switches it as before.

## 3.0.10

- OmacVM.app: a new VM's disk no longer stays at almost its full size on the Mac (reported by
  @brianmerchant, #305: a fresh 3.0.9 setup on macOS 15.8.1 took 61 of 64 GB; `sparsify.py`
  brought it to 7.9). After the image is unpacked, and again once the setup has shut the VM
  down, a disk.img that takes more than half its size is made sparse (every zeroed MiB becomes a
  hole, the bytes stay the same), and create.log says what the disk takes on the Mac and which
  image it came from. The image itself unpacks sparse (prebuilt-3.0.8: 6.9 GB on macOS 15.7).
- Gestures: a permission macOS kept for another build no longer leaves it waiting for good
  (reported by @brianmerchant, #306). macOS ties each permission entry to the signature of the
  build that asked; one from another build (e.g. a helper built on the Mac before OmacVM.app's
  signed copy) shows as on in System Settings but is refused, and switching it off and on does
  not replace it. When Accessibility or Input Monitoring is missing at start, Gestures now clears
  its own entry for that permission once per build (tccutil, only the missing one), then asks
  again, as the app does for its keyboard entry since 3.0.6 (#255). `omacvm check` names the
  tccutil commands on that row and no longer suggests `omacvm apply` for scroll momentum while
  Gestures waits for its Mac permissions.
- Omanotch: the pointer on the strip shows Omarchy's auto-hidden indicators as on the bar itself
  (reported by @brianmerchant, #308). The guest's pointer is not on the bar while the Mac's is
  on the strip, so the bar's hover never fired there and the indicators (Dictation, Screen
  Recording, Do Not Disturb, ...) could not be reached with `alwaysShow` off. Omanotch now tells
  the VM when the pointer moves between a widget and the bar's free space, and the bar (patch v18)
  does what its hover does: the indicators show from the free space and stay until the pointer
  leaves the strip. Needs Omanotch and the VM's OmacVM from this version (Update VM).
- The Mac input methods feature is named for what it is for: "Mac input (Chinese, Japanese,
  Korean)" in the app, "Mac input: Chinese, Japanese…" in the control centre; its info text says
  normal keyboard layouts (accents included) do not need it.

## 3.0.9

- Bridge: its media-key tap can no longer hold the Mac's keyboard and clicks (reported by
  @brianmerchant, #290). The tap now exists only while a VM is in front (not while the Mac sleeps
  or another user's session is in front); one macOS disabled is removed and never enabled again
  (it was enabled again every 2 s, so a tap that did not answer held keys and clicks until the
  Bridge was stopped); a watchdog disables it when the Bridge's main thread has not answered for
  a second; after three such stops in 10 minutes the media keys stay macOS's until the
  Accessibility list changes. Like Gestures, no tap without "control the computer" once a tap had it.
  While it has a tap, the Bridge asks macOS's permission service off its main thread and does not nap.
- Gestures: its event tap follows the Bridge's new rule (#290). A tap macOS disabled
  is removed and never enabled again (before: enabled again at once, so a tap that
  did not answer could hold the Mac's keys and clicks again); a new one comes after
  2 s, then 30 s, and after three in 10 minutes Gestures lets go of the keyboard and
  trackpads until the Accessibility list changes. A watchdog disables the tap when
  Gestures' main thread has not answered for a second.
- The command line from `install.sh` (`~/.omacvm`) follows OmacVM's releases, as
  OmacVM.app does: `omacvm update` and `install.sh` take it to the newest release,
  or to OmacVM.app's version when the app is newer. Before, it followed `main`,
  which could be behind the app's release, and `omacvm update` said "already up
  to date". A checkout with local changes, another clone or an `OMACVM_REF` is
  not moved; then the warning names the app's own `omacvm`. Takes effect from the
  first release that has it. Reported by @brianmerchant (#291).
- `omacvm features` (and option 2 of the menu): moving up and down the checklist no longer
  doubles or overwrites rows. Every row now fits on one line (long ones are cut), the list
  scrolls in a short window and is drawn again when the window changes size. Reported by
  @brianmerchant (#292).

- Tests and other HOMEs: the Mac helpers' LaunchAgents get `org.omacvm.test.*` labels with
  the test identity or a HOME that is not the user's own, so a test run can no longer
  replace the user's own Bridge, Gestures, clipboard helper or Omanotch (`src/lib/labels.sh`,
  `src/tests/test-labels.sh`).

## 3.0.8

- Capture mode no longer makes the VM lag or the sound crackle
  ([troubleshooting 32](docs/troubleshooting.md#32-app-the-vm-lags-and-the-sound-crackles-while-recording-the-screen-or-taking-a-screenshot)).
  Screen recording: the Mac's video encoder works beside QEMU's main loop
  instead of stopping it for every frame. On a MacBook Air M2 at 2940x1840
  the main loop went from 93 % to 14 % busy, the VM's sound from a third to
  all of it, the display from 12 to 29 frames a second while recording, and
  gpu-screen-recorder from 87 % to 8 % of a vCPU. Constant QP now uses a
  normal encoder session with the QP held in place
  ([video encoding](docs/video-encode.md#while-recording)). Screenshots: in
  OmacVM.app VMs `omacvm apply` builds a hyprpicker that draws the frozen
  screen once instead of on every frame (Hyprland 41 % to 11 % of a vCPU while
  picking), and big texture uploads from the VM take half the main loop's
  time.
- Experimental, off by default, OmacVM.app only: the Mac's input methods
  type in Omarchy: the Mac's candidate window opens at the text cursor in
  the VM, the chosen text goes into the VM's field (tested with Pinyin,
  Japanese Romaji kana and 2-Set Korean in a GTK app, foot and Chromium;
  Kotoeri's candidate list not confirmed yet); keys, Cmd shortcuts and
  Hyprland's binds stay as they are, password fields get plain keys. On
  with `omacvm enable mac-ime`, the control centre, or "Mac input methods
  (experimental)" in the app's VM window while the VM runs, then one
  restart of the VM. A VM with it off starts exactly as before. Requested
  and scoped by @Vocllum (#273). Details: docs/features.md, design: docs/adr/0043-mac-ime.md.
- OmacVM.app's prebuilt VM is new (release `prebuilt-3.0.8`, 3.7 GB):
  Omarchy 4.0.3rc4 with 60 packages newer than in `prebuilt-3.0.0` (kernel
  7.2.9, Mesa 26.2.4, Chromium 153), and the login keyring is made on the
  VM's first boot, so Chromium never asks for a keyring password. Setup from
  it took 90-94 s plus the download (MacBook Pro M4 Max, MacBook Air M2).
  Apps before 3.0.8 keep using `prebuilt-3.0.0`.
- Graphics: browser pages that change shader values before every draw (WebGL
  Aquarium) are faster on the Mac's OpenGL. The values of a whole batch go to
  the GPU in one upload; before, each draw set them with its own OpenGL call,
  and Apple's OpenGL then redid its draw setup. Aquarium with 30,000 fish on a
  MacBook Pro M4 Max: 32.9 to 41.8 frames a second
  (`OMACVM_VIRGL_CONST_UBO=0` turns it off).
- Control centre: a feature that cannot be set up because the VM's package
  list is older than the mirrors now says so. On a Mac mini, "WebGPU and GPU
  compute on" failed with only "was not set up", and "space tries again"
  could not work until the VM was updated. The control centre now names the
  reason, offers omarchy update in its own window (only on yes), and says to
  switch the feature on again after it. OmacVM still never updates a single
  package on its own (that can leave a black screen). `omacvm enable` and
  `omacvm apply` give the reason in their "what failed" line too.
- Control centre: a switch shows its check mark within a second of "done".
  Before, the row waited 5-10 s for the VM's checks and the Mac's status;
  they now come in after it.
- Control centre: the Graphics row fits on its line, also in an 80-column
  window ("Vulkan: OpenGL until r builds it"); enter shows the whole text, in
  the VM's own words.
- App: the window keeps 20 pt on both sides. A long VMs folder is cut in
  the middle (free space and Change… stay), Change…, Update VM and Start end
  on one line, and the window is 8 pt shorter. The new VM form's Bridge line
  wraps instead of running past the fields; a long VM name no longer wraps in
  All VMs.
- The keyboard row in the app's window turns "Allowed" as soon as OmacVM is allowed in
  System Settings, without quitting the app first (macOS kept the old answer for the running
  app; the app now asks in a fresh process).
- The OMACVM logo stays 1.9 s longer before it turns into Omarchy's (2.5 s instead of 0.6 s;
  the animation ends at 5.5 s, before the desktop is ready).
- `omacvm build --vm-type utm`: when macOS put UTM's shared network on
  another range than 192.168.64.0/24 (another VM network on the Mac was
  there first), the build said so only at the end, after the whole install
  (about 10 minutes). It now stops as soon as the live installer has its
  address, and the message says why this can happen.
- `omacvm build`: two builds at once (for example a UTM and a Parallels VM)
  no longer break each other. The second one stopped in step 1 with "mv: …
  TryOmarchy-v0.4.1.dmg: No such file or directory", as both used the same
  download and work files. Now it says it waits for the other build and
  starts its installer when that one is done.
- Tests: app-cli-identity.sh no longer fails on a CI runner Mac where
  OmacVM.app is open.

## 3.0.7

- Omanotch: after Update VM to 3.0.6 the bar could be missing from the notch
  strip. The update builds notchcast again at the next login; until then the
  old service kept trying to start the missing program and ran into systemd's
  start limit, so the installer's own start was refused
  ("start of the service was attempted too often"). The service now waits
  for notchcast to be built, the installer starts it once with the limit
  cleared, and Update VM starts a notchcast stuck like this again without a
  reboot.

## 3.0.6

- OmacVM.app: a VM named with `--vm` (by `omacvm`, a start request or a
  script) that is not there is an error ("No VM named … Nothing was
  started."), never the VM shown or the first VM. A new VM's suggested name
  is never the name of a folder that is there already, and Build is off for
  such a name: a build into it would take over that VM's disk.
- `omacvm features` without `--vm` started the VM named Omarchy when it was
  off, to read its features, and did it through an old copy of the app
  ("OmacVM Bench 2.9.1.app" sorted before OmacVM.app). Listing and reading
  (`features`, `features --json`, `check`, `vms`) now never start a VM: one
  that is off is shown from its folder on the Mac ("VM is off", `"running":
  false` in the JSON). `enable`, `disable` and `apply` start a stopped VM
  only when it is named with `--vm`; without it they say so (exit 3).
  omacvm takes OmacVM.app by its name before any other copy (a renamed
  install next, test, bench, RC and lane copies last), and never starts a
  VM with an app older than the OmacVM the VM has, nor while another copy
  of the app is open (that copy would take the start).
- OmacVM.app: a VM no longer crawls while its window is out of sight (the
  Mac's screen locked, the VM's full screen on another Space, the window
  minimized or covered). macOS's App Nap slowed every QEMU thread to
  background priority, and a job in the VM ran at 2-20 % of its speed.
  QEMU now tells macOS the VM is working; the idle Mac still sleeps.
- The control centre in the VM brings its own Textual (8.2.8 with Rich,
  Pygments and the rest, pure Python, in `src/control/vendor`). It came from
  pacman's python-textual before, which a VM not updated for a few days
  cannot get (the mirrors no longer have the files its package list names),
  so after an update `omacvm` in the VM showed only plain text. Now nothing
  is installed with pacman for it, on every VM, whatever OmacVM it had.
  `omacvm check` checks that copy.
- When Textual still does not load, the control centre's "repair it from the
  Mac" waits through the Bridge restarting, as the full control centre does,
  instead of saying "OmacVM Bridge does not answer" while the Bridge row said
  works. It says "Textual is installed" only once Textual really loads, and
  why not otherwise. A repair of the control centre no longer builds and
  restarts the Mac's Bridge when it is up to date.
- Fast network switched on in OmacVM.app: the control centre showed "OmacVM's
  record said off: fixed", though only the VM's own copy was behind the
  record. The copy now follows without a note; a record that was really
  wrong is still named.
- Vulkan chosen while the VM's driver is not built: the app, `omacvm
  graphics` and the control centre now say how it gets built ("OmacVM in the
  VM: r on Graphics") instead of "until the next apply". A repair of another
  feature no longer says the Vulkan driver "did not build": it never tried.
- The camera and Chromium video on a VM whose package list is older than
  the mirrors (a VM updated from 2.9.1 without dkms, say): their rows said
  "omacvm apply", which only meets the same missing files again. They now
  name the packages that are missing and the way out: update the system
  (omarchy update), then r on the row.
- Graphics memory in the control centre: macOS's memory pressure "warn" alone
  is fine now, with a short note (a Mac that gives the VM half its memory sits
  there). "Needs you" only when macOS is out of memory or graphics memory was
  refused or lost.
- OmacVM.app: a VM started while its window was not visible (screen
  locked, the window on another Space, the app hidden) could
  crash in its first seconds, in the start animation. Since 3.0.0 the
  animation replaces a display link that gives no frames, and dropping
  one freed it while macOS still used it. The animation now holds its
  link until it is done with it.
- Notch: moving the pointer between the VM and Omanotch's strip beside the
  camera in full screen no longer flickers. For up to half a second at each
  crossing there were two arrows (the VM's stayed on its top rows) or none
  (on the way back). The VM's arrow now moves out of sight in the same
  moment the Mac's shows on the strip, and comes back with the next move.
  Full screen keeps its own Space.
- OmacVM.app's keyboard note stayed red with OmacVM on under Accessibility.
  macOS keeps "control the computer" (what the VM's key tap needs) as an
  entry of its own, tied to the build that made it. One left by an older
  build no longer matches, and macOS refuses the tap whatever the
  Accessibility switch shows; Allow… could not replace it. The app now
  clears its own old entry (once, when the note would be red) and Allow…
  clears both of its entries before it asks again, so with OmacVM on under
  Accessibility the note goes away by itself. The (i) and `omacvm check`
  name the Terminal way too: `tccutil reset PostEvent org.omacvm.app`.
- Graphics memory guard: when an app in the VM is stopped for taking too
  much graphics memory, Hyprland can still show the app's last buffer (an
  empty window now) and keeps drawing. Before, Hyprland lost its GPU context
  there too and the VM went black, as in 3.0.3. The log now says "apps'
  share reached" when an app stops at its share, not "budget reached".
- OmacVM.app: browser pages that draw many objects one by one (WebGL
  Aquarium) are faster: on the Mac's OpenGL a draw no longer sets its
  vertex buffers and selects its shaders again when nothing changed.
- Graphics: browser pages that draw many objects with the same indices (WebGL
  Aquarium, one draw per fish) no longer read those indices back from the
  GPU on every draw; the safety check reads them once per change
  (`OMACVM_VIRGL_INDEX_RANGE_CACHE=0` turns it off).
- The Mac's battery in the VM (UTM, VMware Fusion, OmacVM.app): Omarchy's
  battery panel now shows the real watts and the time left. The Mac never
  sent the battery's current, so UPower guessed watts from charge steps:
  0, then numbers from 1 to over 200 W (85 W at 85 % looked like the
  percentage), and no time left while the guess was 0. The Mac now sends
  current and power, and the VM's battery module (1.1.0, rebuilt by
  `omacvm update`) shows them as `current_now` and `power_now`. Needs both
  sides updated; `omacvm check` says which one is missing. No charge limit
  in macOS: the module says 100 % instead of nothing.
- A VM made from a prebuilt image had no default keyring, so the first start
  of Chromium or Chrome stopped at "Choose password for new keyring". The
  first boot now makes Omarchy's default keyring (no password) for the new
  user, as a full build does; `omacvm apply` makes it in VMs from older
  images, and `omacvm check` has a "keyring" line. The first boot makes it
  without a login session, so it no longer waits 2 minutes for one.
- `omacvm build` checked for 30 GB free on the Mac's own disk even when the
  VM goes to another drive (an SD card or external drive, with `--vm-dir` or
  OmacVM.app's VMs folder there). It now checks the drive the VM goes to, and
  the Mac's disk only for the download when that stays there, and says which
  drive is short.
- UTM VMs can go on an external drive: `omacvm build --vm-type utm
  --vm-dir PATH` (or another folder in the build's "Where should the VM
  go?"). The drive needs about 30 GB free, the Mac's own disk only a little
  ([UTM route](docs/routes/utm.md#utm-on-an-external-drive)).
- A UTM build no longer stops at "Could not write domain" when macOS keeps
  the terminal out of UTM's data: it says so and builds the VM without
  UTM's speed settings.
- VMware Fusion: a new VM on a MacBook Air (or another Retina display under
  3000 pixels wide) came up at scale 1, with tiny text, also in full screen.
  The scale came from the display's width; it is now the Mac display's own
  (2 on Retina, 1 on a plain display), as on the other routes. A scale you
  pick later in Omarchy (Super + /, or the top bar's Display panel) still
  stays over updates. A Fusion VM that is at 1 now: pick 2 there once.
- Troubleshooting 29 (no sound at all after a start, fixed in 3.0.4) names
  the real cause: WirePlumber meeting Chromium's video decoder before its
  daemon is ready. A kernel update alone never did it: the module is built
  during the update and loads early at the next start. The VM test for it
  (`src/tests/vdec-wireplumber.sh --vm NAME`) also checks WirePlumber
  starting with the decoder there.
- The test build ("OmacVM Test") never uses the installed app's VMs
  folders: without a VMs folder of its own (or with one of the installed
  app's), its VMs go into ~/OmacVM Test VMs; `omacvm` with the test identity
  agrees. Test hooks that change a VM (the disk size, forcing a VM off for
  an update) act only on a VM in the folder the test build was given, and
  no test build (any bundle id but the release one) starts, updates (Update
  VM) or resizes a VM of the installed app. A test build hands a start only
  to its own copy when one runs already, and `omacvm` with the test identity
  starts a VM only through a test app from 3.0.6 on (`OmacVMTestVMs` in its
  Info.plist), never through the installed app. On 2026-10-07 a
  test run with a lost setting started a person's VM and made its disk
  smaller.
- The test app OmacVM Test.app: its own `omacvm`, run by hand from a shell,
  now works as the test app (its own Bridge and Gestures), as when the app
  runs it. Before, it set up the normal helpers from the test app. The
  Bridge also counts a re-signed copy of the test app as the test app, as
  the app and Gestures do, and such a copy's omacvm starts VMs in that copy.
  The test app's omacvm never opens OmacVM.app.
- Fast network: installed for the test app OmacVM Test.app (Developer ID),
  the service now trusts the test app's QEMU by its team, as for OmacVM.app,
  not only that exact build. A test Mac gives the admin password once, not
  after every new test build. Same rules as before: only OmacVM's QEMU
  identifiers of a team that OmacVM's release key vouches for; ad hoc builds
  and other teams still get their exact build only. Installs for OmacVM.app
  are unchanged and stay valid.
- CI now builds OmacVM.app with app/scripts/build-app.sh on every pull
  request and push to main (on the Mac mini, QEMU runtime from its cache), so
  a break in the app build shows on the pull request, not at release time.
- Tests: the e2e harnesses save and restore the test app's settings with
  quoted paths (a missing save no longer deletes a setting) and start only a
  test VM in the test app's own folder (`src/tests/e2e/test-vms.sh`,
  `src/tests/e2e/drive-drop.sh`).

## 3.0.5

- OmacVM.app's VM window is compact and fits a 13-inch MacBook without
  scrolling (it was up to about 900 points tall); on a smaller screen it
  stops at the screen and scrolls. Settings sit in two columns, on/off
  settings are switches, and the long explanations moved behind an (i).
  Disk is one row with **Change…**. USB devices now have their own switch,
  off by default (a VM that already had devices keeps them).
- OmacVM.app: Disk › Change… is one slider for the disk's size, with a
  number field. It goes down to what Omarchy needs (what btrfs holds,
  plus 10 % or 5 GB spare, never under 64 GB) and up to what the Mac has
  free. Smaller is new: the VM starts, Omarchy moves its files below the
  new size, the VM restarts once while disk.img is cut, and the file
  system is checked. A copy of the disk (an APFS clone) is kept until
  that check passes; if a step fails, Go Back brings it back. Compact is
  gone: the space Omarchy frees already goes back to the Mac by itself.
- USB devices (OmacVM.app, experimental) no longer go to the VM by
  themselves. With **USB devices** on, plugging a device in while the VM
  runs asks "Connect “ST-Link V2” to Omarchy or keep it on the Mac?". The
  answer is for that plug-in only, unless you check **Always do this for
  this device**. **Devices…** lists the remembered devices (Ask Each Time,
  Connect to Omarchy, Keep on Mac, Forget). Two identical devices are told
  apart by where they are plugged in and their serial numbers. Devices
  switched on under 3.0.1 to 3.0.4 keep connecting by themselves and now
  show in the list.
- OmacVM.app: when the drive with a running VM drops off (unplugged, a
  loose cable, ejected by force), the app stops the VM at once and its
  window says "The drive with your VMs (NAME) is gone. Reconnect it and
  start the VM again." The VM shows as unavailable until the drive is back,
  then as ready again. Before, QEMU kept running on files that were gone.
  A VMs folder whose drive was not plugged in at launch shows up by itself
  once it is.
- OmacVM.app on Macs with little memory (8 GB): an app in the VM that takes
  too much graphics memory (a browser with big WebGL pages) no longer turns
  the whole VM black. The last part of the graphics memory guard (512 MB on
  8 GB, 1 GB on 16 GB, 2 GB from 32 GB) is kept for the desktop (Hyprland,
  the bar and the lock screen): the app past its share, or the app that
  wants more while macOS is short of memory, loses its own GPU context, and
  the VM shows a note that says so. Before, whichever asked next lost it,
  often Hyprland, and the app then restarted the desktop, closing every
  app. When the desktop is still lost, the window and the note say why (the
  guard, macOS short of memory, or a graphics failure).
- A Mac without Xcode's Command Line Tools: OmacVM.app no longer makes macOS
  ask to install them. Before, the setup screen's look for a prebuilt VM ran
  python3 and opened macOS's "install the command line developer tools?"
  window as the app opened, Build refused until they were installed, and
  the control centre's jobs and `omacvm vms` asked again (a Swift script
  for the notch). The app now carries a python3, Omanotch and those Swift
  programs ready made, so its whole route runs without them (and without
  Homebrew). UTM, VMware Fusion and Parallels still need them, and
  `omacvm build` asks for them only there.
- A VM built behind a proxy on the Mac's 127.0.0.1 (Clash, V2Ray, Surge)
  no longer keeps `10.0.2.2:<port>` as its proxy on the fast network, where
  that address leads nowhere and apps failed (Helium could not install
  1Password: Error 6, #232). The build's proxy is now worked out at each
  login for the network the VM is on: `10.0.2.2` on QEMU's network while the
  Mac still uses that proxy, `192.168.77.1` on the fast network only if the
  proxy accepts LAN connections, else none (the VM then goes out through
  the Mac and its VPN or TUN mode directly). A proxy on another host stays
  as it was. `omacvm apply` moves a VM's existing proxy over (from its
  next login); `omacvm-proxy-env` in the VM and `omacvm check` say what a
  login gets.
- An older `omacvm` no longer puts its OmacVM over a VM that has a newer
  one. An old command line checkout (`~/.omacvm` from `install.sh`) first on
  the PATH beside a newer OmacVM.app turned a feature switch into a downgrade:
  `omacvm disable fast-network` replaced a 3.0.3 VM's OmacVM with 2.9.1, and
  its control centre stopped opening (#233). `apply`, `enable`, `disable`,
  a repair and `update` now compare the VM's OmacVM with their own and stop
  before anything changes on the Mac or in the VM, naming both versions and
  OmacVM.app's own `omacvm` (or `omacvm update` first); `--allow-downgrade`
  goes back on purpose. `omacvm features --json` and `omacvm check` leave
  such a VM's feature record alone. `omacvm` says when OmacVM.app on the Mac
  is newer than itself, `install.sh` too, and the app's "omacvm in Terminal"
  row says when the one Terminal runs is older. The control centre's jobs
  run OmacVM.app's `omacvm` instead of a checkout with an older OmacVM.
- With OmacVM.app and the test app OmacVM Test.app on one Mac, each one's
  Gestures took the other app's VMs as its own too: both captured the
  trackpad and acted on Ctrl+Option+Esc. Each Gestures now takes only the
  VMs of its own app (told by the VM's code signature), as the Bridge
  does since 3.0.1.
- Omanotch: when something moved the hidden NOTCH output after it was in
  place (a Hyprland config reload with an older rule, another `hyprctl
  eval`), the strip beside the notch could stay wrong for up to 30 s.
  notchcast now puts it back on its next look (about 2 s). A rule Hyprland
  does not take is sent again with growing waits, at most every 30 s once
  it keeps failing, and never more than 4 times in 30 s.
- Touch ID is no longer marked experimental (control centre, `omacvm
  features`, README): it is a regular feature, still off until you turn it on.

## 3.0.4

- Fast network after an app update: the service from an earlier app keeps
  working when its protocol is the same (3.0.1 to 3.0.3 count as one), so
  most updates need no new install and no password. When it does need an
  update (3.0.0's and 2.9's services do), the app asks before the VM starts
  ("The fast network needs an update: Update…", one password), and its
  window, `omacvm check` and `omacvm enable fast-network` offer the same.
  Saying no starts the VM on the normal network, and it says so. Other
  switches (Touch ID too) and Update VM no longer stop on an outdated
  service. Nothing the VM asks for (the control centre) puts up macOS's
  password dialog or uses sudo: the app asks on the Mac at the next start.
  A service that stopped after macOS's VM network failed too often is left
  alone until the Mac restarts (no question at each start).
- Turning the fast network on or off while the VM runs is for its next
  start, and the app, the control centre and `omacvm` say so; the VM keeps
  its network (and its address) until then, and the service stays while a
  VM runs on it.
- The control centre and Touch ID no longer say "needs the Mac" for an
  OmacVM.app VM whose fast network was turned off while it ran (it keeps
  vmnet until its next start): the Mac finds the VM's address from its
  running QEMU. After the Bridge starts, or a VM does, the first request
  waits a few seconds for a fresh look at the VMs instead of minutes, and
  a VM the Mac cannot reach is told so instead of "not running".
- The control centre's "needs the Mac" says the real reason: "the Mac
  cannot reach this VM: ..." with why (no address, the fast network down,
  SSH refused), or that OmacVM did not set the VM up. Touch ID for an
  OmacVM.app VM no longer needs the Mac to reach the VM over SSH.
- Touch ID (off until you turn it on) works as soon as you turn it on.
  OmacVM.app gives every VM its Touch ID port from the start (it stays
  closed while Touch ID is off), so turning it on in the control centre or
  with `omacvm enable touch-id` needs no restart of the VM. A VM that
  OmacVM.app 3.0.3 or older started needs one restart for it; the control
  centre then says "on from the VM's next start: shut it down, then start
  it again" instead of a red x. Turning it on no longer restarts OmacVM
  Bridge (any switch did when it came once from the control centre and
  once from a terminal), and the first Touch ID request after the Bridge
  or the VM started no longer falls to the password: the Bridge takes an
  OmacVM.app VM's request by name, and waits for its VM list for
  Parallels, UTM and Fusion. A polkit prompt (pkexec, 1Password) right
  after `sudo` uses Touch ID too instead of saying "too many tries".
  Turning it on ends with "Touch ID is ready: try sudo -v" (and
  1Password's own switch, if it is off). When it still uses the password,
  the prompt says why ("the Mac is still starting", "OmacVM Bridge on the
  Mac does not answer", ...), the VM's journal keeps each request
  (`journalctl -t omacvm-touchid`), and `omacvm check` says what is
  missing on the Mac and how the last request went.
- Touch ID: with 1Password in the VM, OmacVM says once (a notice, and a
  line in the control centre's Touch ID details and `omacvm check`) that
  1Password needs its own switch: Settings › Security › Unlock using
  system authentication. Never while it is on; then the line says
  "1Password: uses Touch ID". OmacVM does not change 1Password's settings.
  The details also list Bitwarden's and KeePassXC's switches.
- Touch ID in OmacVM.app: the panel now looks like Omarchy's own password
  prompt in your theme, light themes too: its colours, a border in
  Hyprland's border colours and its rounding. It follows a theme switch
  within a second, and comes in your VM's last theme at once after Touch ID
  was turned off and on (before, that sent it back to the dark default).
- Touch ID is faster: after a yes the VM goes on the moment your finger
  matches, and the panel is gone at once (a 90 ms check, none with Reduce
  Motion), with your keyboard back in the VM in the same moment. Before,
  the panel played 1.6 s of animation and held your keys meanwhile.
- Taking OmacVM Gestures' Accessibility or Input Monitoring away in System
  Settings while it ran could freeze the Mac's keyboard and clicks (the
  pointer still moved) until the helper was killed. Gestures now removes
  its event tap and lets go of the trackpads at once, and takes them back
  when the permission returns. The Bridge's media-key tap and OmacVM.app's
  own full-grab tap do the same, and `omacvm uninstall` waits for the
  helpers to quit before it resets their permissions. Fixes #192.
- OmacVM.app's keyboard note asked for the wrong permission. The VM's
  key tap (⌘ Tab, ⌘ Space, ⌘ ⇧ 4 to Omarchy) needs Accessibility; Input
  Monitoring is not enough, but Allow… opened Input Monitoring, and with
  it on the note stayed red even after Accessibility was turned on. Now
  the note names only Accessibility, Allow… opens that pane, the (i)
  has the steps, and once it is allowed the note says "allowed, takes
  effect at the next VM start" at once.
- No sound after a kernel update: in OmacVM.app VMs with Chromium video on,
  the first start after a new kernel could leave every app silent until
  WirePlumber was restarted. WirePlumber hung on Chromium's video decoder
  when it came late; it now leaves the decoder alone. `omacvm apply`
  restarts WirePlumber once for this, never during a call.
- Chromium video after a kernel update: when the decoder came late, its
  service stayed down until the next start and videos played on the CPU.
  The decoder now starts its service when it comes.
- VMware Fusion: setting up a new VM stopped at "failed during: VMware
  Fusion" (3.0.0 to 3.0.3). The first Hyprland build ran from a copy that
  could not install its build tools, and the VMware Tools build then
  stopped at "here: unbound variable".
- A new OmacVM.app VM on a Mac that never had OmacVM's Bridge, with Gestures
  turned off at setup: the build stopped at "Adding OmacVM to the VM" (no
  Bridge token yet). The token is now made for the VM's first setup too.
- Ctrl-C in `omacvm build` always stops the step that runs (waiting for
  SSH or for the VM's address, the prebuilt image's unpack, asking whether
  this terminal may control UTM) and everything it started, and its
  spinner. Before, only the unpack stopped: the other steps went on in the
  background after the build had ended, a spinner could go on drawing over
  the prompt, and a Ctrl-C that came just as the spinner drew could be
  lost. A prebuilt image could now and then fail to unpack with "could not
  unpack the image (free disk space?)" although nothing was wrong. Closing
  the control centre while a job ran could end with a Python error; it
  closes cleanly now.
- OmacVM.app on macOS 26: no light 1 pt line around the screen when the VM's
  window is borderless over a whole display (2.9.1's notch full screen
  had it; in 3.0 that window is left only for tests). macOS 26 draws that
  line with a window's shadow; borderless windows now have none. macOS's
  own full screen, which 3.0 uses, never had the line.

## 3.0.3

- Touch ID: the Mac's panel in OmacVM.app shows a sudo command or polkit
  action whole. One that does not fit goes to macOS's own dialog, which
  shows all of it; before, the panel cut it in the middle, which could hide
  what runs. Prebuilt images never carry Touch ID keys.

## 3.0.2

- Touch ID in the VM (experimental, off by default; turn it on in the
  control centre or with `omacvm enable touch-id`): sudo, polkit prompts
  and 1Password's "Unlock using system authentication" in Omarchy ask the
  Mac's Touch ID first; the password
  keeps working, and comes at once when the Mac is locked, another app is
  in front or the Mac has no Touch ID. The Mac asks every time, shows the
  command and its terminal, and gives the VM only yes or no. Only for the
  person at the VM's screen: never over SSH or for a program without a
  terminal. Parallels, UTM, VMware Fusion and OmacVM.app (there through
  its own port: shut the VM down and start it again once after turning it
  on) (ADR 0041). In OmacVM.app the Mac asks in its own panel in your
  Omarchy theme, centred on the VM's window, with a fingerprint that
  traces, turns green and draws a check (or shakes red); no click needed.
  Parallels, UTM and Fusion keep macOS's own dialog.
- The Mac's camera in ffmpeg (and other apps that go by the frame times):
  a recording was all black, and `ffmpeg -t 10` ended at once. A new reader
  gets the last frame first, and that frame carried the time of the
  camera's last use, maybe an hour back; ffmpeg filled the hour with copies
  of it. The frames now carry a clock that stops while no app reads, so the
  next frame follows right after. Browsers and `v4l2-ctl` worked before and
  still do. If the camera service restarted while an app read the camera
  (an update, say), it could get stuck restarting every 2 seconds on the
  rest of a half-read frame; it now skips that and goes on.
- Mission Control from the escape combo (pressed twice): Esc often did not
  close it, because the VM took the key, and ⌃⌥ Esc in it did nothing or
  gave the keyboard to Finder. It took up to three presses to get back into
  the VM. Now Esc closes Mission Control and the VM gets no Esc, and one
  ⌃⌥ Esc closes it and goes back into the VM.
- OmacVM.app: when the VM's desktop stops drawing because its graphics
  reached the most one VM may use (three quarters of the Mac's memory), the
  window now says so. It said "macOS ran short of memory", also when macOS
  still had memory (seen on an 8 GB MacBook Air with a browser full of WebGL).
- Updates in one step. `u` in the control centre checks, then updates what
  is older: with OmacVM.app on the Mac, the app first (it shuts the VM down
  cleanly, updates, restarts and starts the VM again; one confirm, "save your
  work"), then the VM's part right after the restart. The top line says
  what: "Update available: 3.0.2 (Mac app and this VM) · u updates". No
  more U, then c, then i. The app's window gets **Check Now** and "Update to
  X…". From 3.0.0 or 3.0.1, update the app once by hand (shut the VM down, then
  OmacVM › Check for Updates…): the one-step update works from 3.0.2 on.
- The control centre shows an update while it runs: step n of N with a bar
  and the latest log line (also on the Updates screen); through OmacVM.app
  the four steps (the Mac gets the app, the VM shuts down, the app installs
  and starts the VM again, the VM updates). At the end "Updated to X" or the
  error with the next step, the list at once, and R restarts the VM for the
  kernel, memory and keyboard changes.
- Error texts say the next step: "update OmacVM.app first: u in the control
  centre does it, or Check Now in OmacVM on the Mac" instead of
  "OmacVM.app is older than this release".
- Switching a feature (control centre, `omacvm enable` or `disable`) no
  longer makes the screens flicker. A switch ran the whole VM side again:
  Hyprland's config files were rewritten and reloaded, and the displays
  moved several times (seen with a 6K display when WebGPU was switched on).
  Now a switch installs only that feature's part, plus parts this OmacVM
  changed. The whole VM side still runs when the VM has another OmacVM
  version or its Graphics setting changed. Any apply now rewrites
  Hyprland's files only when they change, and the Mesa build for WebGPU
  runs at the lowest priority.
- OmacVM.app: after *Later* on "The VM's desktop stopped drawing", the app
  menu has *Restart the Desktop…* until the desktop restarts. Before, there
  was no way back: the screen stayed black until the VM was shut down.
- OmacVM.app: Omarchy's scale panel offers 1.25 and 1.6 on notched Macs
  too (full screen leaves a few black rows at the bottom). On every Mac the
  VM window now resizes in 20 point steps.
- OmacVM.app: Quit in the VM's window right after the VM starts (while it
  still boots) shuts it down cleanly. The Mac pressed the VM's power button
  once, the VM was not listening yet, and it was stopped after a minute.
  In the first 2 minutes after a start or restart the button is now pressed
  again every 10 seconds, up to 40 seconds; qemu.log says each step. A
  hidden VM in full screen (test runs) no longer quits by itself.
- OmacVM.app: the sound is in step with the picture in videos (YouTube in
  Chromium, Firefox, mpv). The VM never knew how late the Mac plays its
  sound (QEMU's buffers, 110-150 ms, plus the Mac's output: about 13 ms
  wired, 170 ms with AirPods), so the sound came that much after the
  picture. The app now tells the VM, at the start and whenever the Mac's
  output changes, and PipeWire passes it on to the players. Measured on
  the Mac mini (wired, Chromium): the sound 125-164 ms late before, 0 to
  42 ms after. Not a 3.0.0 change: `audioClassic` (the old sound timing)
  was as late. Fine-tuning:
  `defaults write org.omacvm.app audioDelayExtraMs -int N`
  (troubleshooting 28).
- Control centre: a Magic Mouse swipe row (3 or 4 fingers) while the Mac
  has a Magic Mouse, on every route.
- OmacVM.app with its VMs folder on another drive: downloads go there too
  (`.downloads` in that folder), not to the Mac's own disk.
- Omanotch: with the bar hidden (Super+Shift+Space) the notch strip shows
  the wallpaper's rows right above the VM's picture again, as one picture
  over the whole MacBook screen. Since 3.0.0 NOTCH sits right above the
  built-in display in OmacVM.app (#130); the wallpaper patch no longer
  found its display there, and every output drew its own copy: the strip
  a zoomed piece of the image's middle. Background patch v6 finds the
  display in both places. In a window (no strip on screen) the VM's
  wallpaper is now laid out the same way, so it sits a little lower and
  larger than in 3.0.0.
- Omanotch: no more box of the old bar (the clock's last digits) at the
  strip's end after hiding the bar while the pointer was at the top edge.
  notchcast froze the pixels around a cursor that was not on NOTCH at all.
- Omanotch: at fractional scales (such as 1.6) the strip trims the extra
  rounding rows at its top only, so its bottom row meets the display's top
  row and the wallpaper runs through without a step.
- Omanotch: the first session of a new VM on a MacBook with a notch no
  longer blinks. The top of the screen went black for a frame every 2
  seconds until the VM restarted (the 3.0.1 known issue, also in 3.0.0).

## 3.0.1

- OmacVM.app: the globe (fn) key pressed on its own goes to the VM, no
  longer to macOS's Emoji & Symbols over it, while the VM's window has the
  keyboard. In Omarchy it opens the emoji picker (it is XF86Launch3 there,
  for your own bindings). fn+F1..F12 and the brightness and media keys work
  as before, also with "Use F1, F2, etc. keys as standard function keys" on.
  VMs set up before 3.0.1 get the emoji picker binding with `omacvm update`
  (or `omacvm apply`). `defaults write org.omacvm.app globeKeyToVM -bool
  false` leaves it with macOS.
- Graphics Vulkan on macOS 26 and newer (KosmicKrisp): Vulkan apps in a
  window or full screen now use Mesa's normal present path like on
  MoltenVK, not the VM's software copy. The Mac still copies each frame
  into Hyprland's OpenGL texture, straight from shared memory (vkmark full
  screen at 5K on a Mac mini M4: about 260; 203 with the software copy in
  3.0.0, other scenes). Automatic stays OpenGL.
- OmacVM.app VMs on an external drive: the control centre in the VM said
  "no such OmacVM.app VM" and could not switch features, update, change
  Graphics or show the Mac's checks. OmacVM Bridge ran omacvm as a program
  of its own, and macOS refused it the drive without asking: the VMs folder
  looked empty. The Bridge now runs omacvm for the app's VMs through the app
  (`OmacVM --control-run`), which already has the access, so nothing new is
  asked. The app also sends the VM's graphics memory numbers with the
  request. Listing the app's VMs no longer misses one on an external drive
  now and then (a glob in bash could see the folder as empty, #151).
- `omacvm enable vulkan` when OmacVM's Mesa does not build in the VM: the
  VM goes back to what it had and the command fails (exit 4), as in the
  control centre. Before, it ended with 0 and the record said Vulkan was on,
  so a second `omacvm enable vulkan` said "Nothing to change". `omacvm
  enable` and `disable` now always work this way. An apply that finds no
  OmacVM Mesa also keeps the record at off.
- The memory-optimized kernel says how long it really takes: a kernel build
  in the VM, about 10 minutes with 16 CPUs, over an hour with 4 (it said
  about 10 minutes). The control centre and `omacvm features` say it only
  while it is off. A control centre job may now run 4 hours (it was 1 hour,
  which could stop a kernel build on a 4-CPU VM).
- OmacVM.app: macOS's "find devices on local networks" question now says
  why OmacVM asks: it reaches the VM on the Mac's own VM network.
- OmacVM.app: a VM build, and each apply in a VM without a window, is about
  a minute shorter. The QEMU guest agent no longer waits for its port there.
- The control centre opens from the Mac: *Features…* in OmacVM.app's menu
  (while the VM runs) or `omacvm features --vm NAME --in-vm` (also in
  `omacvm`'s menu) open it on the VM's desktop, one window, in front. It
  says what is missing when it cannot: nobody logged in, the control centre
  off, an older OmacVM in the VM.
- Control centre: `r` on a feature that works asks first (it installs that
  feature again) instead of starting at once without a word. "Report a
  problem" keeps sudo's working folder (`PWD=/`), which it used to take out
  as a secret, and counts only what it really took out.
- OmacVM.app: a VM made by an older app (2.9.x and earlier, or 3.0.0) gets
  this app's OmacVM with Update VM in the app's window. Before, replacing
  the app left the VM's side as it was, and a VM from before 3.0.0 has no
  control centre to ask for it.
- Omanotch: Omarchy's display panel no longer lists the hidden NOTCH output
  as a display (it could be scaled or switched off there).
- OmacVM.app in full screen on a MacBook with a notch (Omanotch on), or
  with external displays: after a Hyprland config reload (a theme change, a
  saved hypr file, a feature switched in the control centre) the pointer
  could reach only the left or the right half of the screen for up to 30
  seconds. The VM told the Mac where its outputs were from a moment when
  they were still moving. It now hears every move and tells the Mac within
  half a second. In the VM, a reinstall of the guest files no longer stops
  the display agent.
- OmacVM.app's VM window: Resources › Custom… sets CPUs and memory one by
  one (from 4 GB; macOS always keeps an eighth of the memory, at least
  2 GB, and a warning shows when it keeps too little). Disk shows what it takes on the Mac and its max: Grow… makes the
  max larger with the VM off, and Omarchy grows into it at the next start;
  Compact… gives the Mac back the space the VM no longer uses (the max
  stays; making it smaller is not offered, it could lose the VM).
  "omacvm in Terminal" Install links the app's own `omacvm` into
  ~/.local/bin or /usr/local/bin (never over another omacvm); offered once
  in the first setup. The keyboard note goes grey ("allowed, takes effect at
  the next VM start") once OmacVM is allowed, checked again when the app
  comes to the front.
- One OmacVM in the Dock. A running VM showed as a second app next to
  OmacVM, and "Keep in Dock" on it kept a bare program from inside the app
  (blank icon, starts nothing once the VM is off). The VM now shows in
  OmacVM's own Dock icon: a click on it brings the VM to the front, and
  "Keep in Dock" keeps OmacVM. If you pinned the old blank icon, remove it
  from the Dock and pin OmacVM again.
- OmacVM.app VMs start about 5 seconds faster (Mac mini M4: 14.2 s to the
  desktop before, 8.7 s now): the firmware no longer waits 5 seconds for a
  key before it boots (the wait was hidden under the boot logo).
  `defaults write org.omacvm.app firmwareWait -int 5` brings it back.
- OmacVM.app: **Mac folder** (off by default). One folder of the Mac at
  `~/Mac` in the VM (virtio-9p; big files fast, many small files slow). A
  folder that is not there or that OmacVM may not open is left out for that
  start and the VM starts as usual; the home folder and the folders above it
  are refused. VMs from before 3.0.1: `omacvm apply` once.
- OmacVM.app's build window says more while it builds: what runs right now
  ("Installing gum (27 of 190 packages)"), downloads with a bar, MB done,
  speed and time left, how long the step usually takes on a Mac like yours
  (or took last time), and "Working. Last output 4 s ago." so a quiet part
  never looks frozen. *Show details* shows the last 20 lines of the log.
- USB devices (experimental, OmacVM.app, off by default): give a VM a USB
  device macOS does not use itself (debug probes, SDR sticks, boards in DFU
  mode), per VM in the app's window ([docs/usb.md](docs/usb.md)).
- Building a VM behind a proxy (Vocllum, #122). The build takes the Mac's
  proxy (http_proxy/https_proxy/all_proxy in the terminal, else the fixed
  proxies in macOS's network settings) into the VM: pacman, git and the
  Omarchy installer use it, through sudo and the installer's systemd unit
  too. A proxy on the Mac's 127.0.0.1 (Clash and the like) is reached as
  10.0.2.2 in OmacVM.app: its port gets through at the build and at every
  VM start. pacman and git clone try a failed download again (3 tries)
  while Omarchy installs. PAC files are not read. Details: docs/guide.md,
  "Behind a proxy".
- Fast network: a VPN whose interface is up before it gets its address (an
  IKEv2 connection's `ipsec0`, a tunnel brought up first) now gets the VPN
  NAT within a second. For such an address the service saw only a new
  route, and waited for the next other change. It also missed IPv4 address
  messages (shorter than it expected). Tested with a real WireGuard client
  (docs/routes/app.md).
- Fast network: `omacvm enable fast-network` (and the control centre's
  switch) failed with "no OmacVM.app installed" when OmacVM.app was not in
  /Applications or ~/Applications (another drive, or not moved yet). It
  now uses the app whose omacvm runs (#162).
- In the VM (every route): PipeWire's sound threads stay real-time. RTKit,
  which gives them real-time priority, took a VM that had been stopped for
  a runaway thread and put them back to normal priority for the rest of the
  session; after that the sound could break while the VM and the Mac were
  busy (on a Mac mini, 5 minutes of a test tone: up to 81 breaks, against
  0-6 with real-time PipeWire). `omacvm apply` now runs RTKit without that
  watchdog, and `omacvm check` shows "sound priority".
- Graphics Vulkan: WebGPU in Chromium on the Mac's GPU, without the
  experimental vulkan feature. The VM's Venus driver (OmacVM's build of
  Mesa 26.2.4) now shares the semaphores Chrome asks for before it offers
  pages a WebGPU adapter (before: "no adapter"), and a "Chromium (WebGPU)"
  menu entry starts Chromium with its compositor on Vulkan. VMs set to
  Vulkan rebuild the driver once (a few minutes, in the background after
  the next start, or with `omacvm apply`). `omacvm check` has a "WebGPU in
  Chromium" row.
- OmacVM.app: when the VM's desktop loses its graphics on the Mac (for
  example when macOS runs short of memory), the desktop now starts again by
  itself instead of staying black until you click *Restart the Desktop*.
  Apps open in the VM close and what was not saved in them is lost; the new
  session shows a notification naming them, and locks itself again if it
  was locked. At most once in 10 minutes, then the app asks again. Only
  the bar lost: only the bar restarts. Turn
  it off with `defaults write org.omacvm.app desktopAutoRestart -bool false`.
  VMs get it with `omacvm apply` (before that, the app restarts the login
  manager directly, without the notification).
- Graphics -> Vulkan on a VM from an older prebuilt image: OmacVM updates
  the whole system first (`omarchy update`, asks first in a terminal), so
  the driver build works.
- **x86 Linux apps** (experimental, off by default): `omacvm enable
  x86-apps` builds box64 in the VM; x86_64 programs and AppImages then
  start like ARM ones, slower (on an M4: about 85 % of native speed for
  plain code, under half for vector-heavy code, plus a start-up cost;
  tested with 7-Zip and ripgrep; Obsidian's AppImage opens on an ARM64
  Linux server, not yet tried in a VM; Node.js is not reliable). `omacvm disable x86-apps` removes it. Every route.
  ([details](docs/features.md#x86-linux-apps))
- OmacVM.app's own window (start, options, setup) opens centred on the
  MacBook's built-in display, not somewhere on an external monitor. With
  the lid closed or on a Mac without a built-in display, it opens centred
  on the main display. The VM's window still opens where you are.
- The feature "Screensaver and lock" is now "Screensaver and lock
  disabled" (`no-idle-lock`), ticked when OmacVM keeps Omarchy's own
  screensaver and lock off. Before, switching them off showed an empty
  row, as if something was missing. Nothing changes on a VM: its old
  choice is read the other way round, and `omacvm enable/disable
  idle-lock` still works as before. New VMs keep Omarchy's own screensaver
  and lock, as before.
- Graphics Vulkan on an M1 or M2 Mac no longer leaves a VM that never
  boots (a black window). macOS gives VMs less address space there, and
  Vulkan's host memory window did not fit, so the firmware found no
  devices. OmacVM's QEMU now puts a small PCI window right above the VM's
  memory, and the host memory window is 1 GB or more there (256 MB for a
  VM near 64 GB). If a Vulkan start still shows nothing, OmacVM.app stops
  it and starts the VM on OpenGL, and the app, `omacvm graphics`,
  `omacvm check` and the control centre say "Vulkan did not start on this
  Mac: using OpenGL" with the reason. When the firmware found no devices,
  OpenGL stays until Vulkan is chosen again ("Try Vulkan again" in the
  app); otherwise the next start tries Vulkan again.
- Omanotch: the right bar from the first frame after login. The bar no
  longer shows up on the display right under the notch strip for a few
  seconds at boot (a second copy came back for 3 s about 8 s after login),
  and the strip no longer shows a stretched or empty frame first. When the
  strip showed at the end of the last session, or Omanotch sees the VM full
  screen when it connects (also the first full-screen start after a windowed
  one), the bar starts in the strip with the notch layout of then. A Mac
  restart or an Omanotch quit with the VM running keeps that. If the VM is
  windowed now, Omanotch gives the bar back as soon as it connects (an older
  Omanotch, or none running: after 8 s).
- Chromium video: the decoder service comes back by itself after a broken
  Mesa is fixed or FFmpeg is updated, and `omacvm check` says why it is down.

## 3.0.0

In short: OmacVM.app updates itself, the control centre in Omarchy (a
floating window, also on a Mac with only the app), a prebuilt VM for the
app, Vulkan (a Graphics setting; KosmicKrisp on macOS 26 and newer),
Chromium video on the Mac's media engine, VMs on any drive (Storage shows
their sizes), a boot splash, any Omarchy scale on 5K and larger displays,
sound that holds on a busy Mac, the fast network with a VPN. Full screen
with a Space of its own on every display, no crash when the VM shuts down,
Magic Mouse swipes (3 or 4 fingers), ⌃⌥ Esc twice for Mission Control,
Omanotch on by default on a Mac with a notch, finer brightness steps, ⌘ +
F10/F11/F12 for Omarchy's screenshots, features that show their real
state, no black desktop after a partial Mesa update. And less power
when idle. From 2.9.x: `omacvm update` once; after that the app updates
itself. Details below.

- The display brightness keys step twice as fine while a VM is in front:
  32 steps instead of macOS's 16 (Option: 64), on the MacBook's display,
  Apple displays and DDC/CI monitors alike. Bigger jumps on a DDC/CI
  monitor ramp over a few writes instead of jumping. `"brightness_steps"`
  in the Bridge's `config.json` changes it.
- ⌘ + F10/F11/F12 (⌘ with mute, volume down, volume up) take Omarchy's
  screenshots again on a Mac whose speakers have a volume (a MacBook): the
  Bridge set the Mac's volume and Omarchy never got the key. On a Mac mini
  with an audio interface it already worked.
- The control centre updates the VM's own system too: `o` on the Updates
  screen (or `omacvm update-system`) runs Omarchy's full update in its own
  window, then checks that the graphics still start and says whether a
  restart is safe. It shows how many package updates wait. Never a
  `pacman -Sy` on its own: that partial update gave the black screen.
- OmacVM.app tells you when macOS does not let it read the keyboard (the
  VM's ⌘ Tab, ⌘ Space and screenshot keys then went to macOS without a word):
  a note with an Allow… button in the VM's window, a line in the VM's log,
  and a warning in `omacvm check`.
- A Magic Mouse works in the full-screen VM like the trackpad: two
  fingers sideways swipe Omarchy's workspaces (macOS no longer gets that
  swipe while the VM has the input), a one-finger flick sideways goes back
  or forward. Scrolling stays as it was. The swipe counts as four fingers
  on a trackpad; with a Magic Mouse connected, the app's **Magic Mouse
  swipe** setting (setup and VM window) picks 3 or 4.
- OmacVM.app's full screen always gets a Space of its own, on every
  display, the MacBook's too. Before, on a Mac with a notch, full screen
  was a window over the Space you were on: other windows could share it,
  and the escape combo opened Mission Control instead of moving to macOS.
  macOS keeps a full-screen window below the camera, and Omanotch fills
  the strip beside the notch (as with Parallels and UTM): it is on by
  default for new app VMs on a Mac with a notch. A VM made by an earlier
  app has it off, and the strip stays black until `omacvm enable
  omanotch`. The switch "Use the notch for the menu bar" is gone. With two
  displays the escape combo no longer jumps back into the VM a moment
  after leaving it.
- The escape combo moves one Space, to the one beside the VM, also when
  macOS's slide lands late (it could end two Spaces over, on Desktop 1).
  Pressed twice quickly it opens Mission Control; once, never.
- Omanotch under OmacVM.app: the hidden NOTCH output sits above the
  built-in display, where the strip is, so Hyprland no longer warns
  "Monitor NOTCH overlaps" at start; the pointer's hand-over between the
  VM and the strip beside the notch is quicker.
- OmacVM.app no longer quits with "OmacVM quit unexpectedly" when the VM
  shuts down: a key or mouse event that came in while QEMU was closing
  read its freed keyboard state. A VM that starts in full screen now shows
  nothing until it is there (no windowed frame, no macOS menu bar over the
  splash). Hyprland no longer warns "Monitor Virtual-2 overlaps with other
  monitor(s)" when an external display comes back into the VM's full
  screen.
- A feature switched outside OmacVM shows as it is: the fast network
  turned on with OmacVM.app's button, and autologin set up by an Omarchy
  install or a migration (any SDDM autologin file). `omacvm features`,
  `omacvm check`, `omacvm apply` and the control centre read the real state
  and fix OmacVM's record ("fixed the record"); before, they showed it off.
  Autologin off now also sets such a file aside (`NAME.omacvm-off`). An
  OmacVM.app VM's `features` file is the one record; `vm.env`'s `FEATURES`
  goes after the first apply. The control centre says what "slow" meant
  (about 10 minutes to switch on) and what WebGPU and GPU compute needs on
  this Mac (KosmicKrisp on macOS 26, MoltenVK on 15).
- Fixed: a black screen after an OmacVM job. With a refreshed package list,
  OmacVM's installs could update Mesa on its own (Mesa 26.2.4 next to LLVM
  22), and the desktop could not open its graphics (GBM). OmacVM now only
  installs packages the VM lacks, never updates one alone, never runs
  `pacman -Sy`, and checks after every install that the graphics still
  open (and puts packages back if not). The Vulkan driver check runs only
  with Graphics Vulkan. Recovery: docs/troubleshooting.md, 27.
- The escape combo is now **⌃⌥ Esc** (Control + Option + Escape), easy
  with one hand (brianmerchant, #42). Only exactly these keys count: with
  Shift (or another key) added they go on as ordinary keys. Neither Omarchy
  nor macOS uses Ctrl+Option+Esc. The old ⌃⌥⌘ Esc
  still works through 3.0.x; the first time it is used in a VM, Omarchy shows
  "New shortcut: ⌃⌥ Esc". It is removed in a later version. OmacVM.app's QEMU
  now lets the combo through to OmacVM Gestures, whichever of the two
  started first. OmacVM.app's *Escape combo* setting is now *This monitor*
  or *All monitors*. Parallels, UTM and Fusion: `omacvm update` brings the
  new Gestures (until then the old combo keeps working).
- `omacvm vms` (and the control centre's Bridge, which runs it) no longer
  hangs or brings up a macOS prompt on a Mac with UTM installed. macOS 14
  and later ask before an app reads another app's data, and the read waits
  until someone answers. OmacVM now leaves UTM alone unless you use UTM
  with OmacVM, reads UTM's own files only when you run omacvm in a terminal
  (or act on a UTM VM), and gives up after 2 seconds: the UTM VM then shows
  as "unknown (UTM data not readable)". OmacVM.app VMs never touch UTM.
- Control centre: the graphics memory check is on the Graphics memory row
  only (it showed on the Graphics row too).
- `base-install.sh` keeps pacstrap's whole output in its log, so a failed
  package install shows its real cause.
- OmacVM.app: the pointer moves in Omarchy right after the VM starts, and
  after a reboot in the VM, without a click into the window first, in a
  window and in full screen, on any display. Coming back to the VM's window
  (Command-Tab, the escape combo) gives it the pointer at once too. The Mac's
  pointer over the VM hides only once Omarchy draws its own, so there is
  always one to see while the VM boots.
- Release keys: OmacVM.app's update feed, the control centre's manifest and
  the prebuilt images' manifests are signed with OmacVM's release key (a
  main and a spare key ship in every copy; either one signs). The Developer
  ID team the app must be signed by comes from that signed feed, not from
  the code, so a new Developer ID can be announced; the app and
  `omacvm build`/`omacvm update` refuse an app of a team it does not name.
  Prebuilt images are only used with a signed manifest. A signed feed can
  revoke a spare key that leaked. The fast network's service trusts a
  Developer ID team only when the release's signed feed lists it (or the
  app installs it for itself); otherwise it trusts only that exact build,
  and builds the service from source instead of running the app's own copy
  as root.
  Maintainers: [docs/release-keys.md](docs/release-keys.md).
- Video decoding: HEVC made by the Mac's own encoder (FFmpeg's `hevc_vaapi`
  in the VM, `hevc_videotoolbox` on the Mac) decodes in hardware. After its
  first pictures it came out garbled.
- OmacVM.app: an in-between scale (1.6, say) on a 5K display no longer turns
  the VM black and flickering. The VM's GPU memory on the Mac had a budget of
  a quarter of the Mac's memory (4 GB on a 16 GB Mac mini), and a 5K desktop
  with apps open, whose buffers are all made again on a scale change, reached
  it: Hyprland's next buffer was refused and its GPU context lost. Graphics
  memory now has no fixed limit: it grows while macOS has memory to give,
  and new big buffers are refused only when macOS runs short (its memory
  pressure). 6K and 8K displays fit too. A runaway VM still stops at three
  quarters of the Mac's memory.
- OmacVM.app: the app shows the VM's graphics memory beside its VM memory
  (graphics memory comes from the Mac on top): before a start in the app,
  while the VM runs in its app menu ("Graphics memory: 1.6 GB (peak
  2.6 GB)"), in `omacvm check` (now and peak) and in the control centre in
  the VM (a "Graphics memory" row, every 2 s while it is open, ! while macOS
  is short of memory or after refusals). When macOS warns that memory is short, the VM drops its
  file cache so the Mac gets that memory back.
- OmacVM.app: if the VM's desktop loses its GPU context anyway, the app says
  so and offers to restart the desktop session, instead of a black VM.
- OmacVM.app: the VM's display sync sends a mode only when Hyprland shows
  another (each resend was a modeset: a flash, every buffer made again), one
  call at a time, and stops following an output that keeps changing (a loop)
  for a minute, with a line in `omacvm check`.
- OmacVM.app: on a 4K or larger display, Omarchy's display panel says 2x is
  the sharp scale there. What in-between scales cost:
  [docs/routes/app.md](docs/routes/app.md#display-scale-on-4k-5k-and-larger-displays).
- OmacVM.app: an app whose texture or buffer goes past the VM's GPU memory
  budget loses its GPU context at once, and QEMU's log says why. With the
  VM's reset-aware Mesa (`src/app/guest/mesa`, not installed by default) a
  robust app reads `GL_GUILTY_CONTEXT_RESET` and can start over. Vulkan
  (Venus) memory now counts against the same budget, for as long as anything
  in the VM still holds it (a kept dma-buf or mapping too).
- The Mac's keyboard light goes dimmer: a new lowest step (0.001) below the
  three added in 2.6.0, about half as bright as the old lowest and as dim as
  the keys go while still lit. A step a Mac's keyboard can't light is
  skipped, and Omarchy's popup shows a lit keyboard as 1 %, not 0 %.
- A feature switched off is off on every route. Omanotch off left an
  Omanotch that was still to be built at the next login, which then built
  itself and kept connecting to the Mac; the Bridge, the wallpaper and
  queued bar widgets or clock could come back the same way when nobody was
  logged in. Now nothing of an off feature runs in the VM or connects to
  the Mac, OmacVM.app gives a VM nothing of the Mac for its features that
  are off (no Omanotch, Gestures or Bridge port, no battery or camera) from
  its next start, and `omacvm check` says "off" for them, or fails when
  something of them still runs.
  On OmacVM.app a feature turned on while the VM runs gets its link to the
  Mac at the VM's next start: `omacvm apply` names it and `omacvm check`
  says to shut the VM down and start it again.
- OmacVM.app can make its VM from a prebuilt image, like the other apps:
  "Download a prebuilt VM" in the app's setup, or
  `omacvm build --vm-type app --prebuilt`. The parts are checked against
  the image's signed manifest; the first boot (without a window) sets up your
  user, password, keyboard and timezone from a seed that is deleted after.
  The first image comes with 3.0.0 (release `prebuilt-3.0.0`). See
  [docs/prebuilt.md](docs/prebuilt.md).
- OmacVM.app: the setup shows the VMs folder and its free space. Storage in
  the app's window changes it (an external drive too) and moves the VMs: a
  rename on the same drive, else copied, read back, compared and only then
  deleted, with progress and Cancel; or New VMs Only, and the VMs stay
  where they are and keep working. A VM that runs is never moved, nor one
  whose files change during the move, nor a VM folder that is a link. A
  half copy left by quitting during a move is deleted at the next launch.
  Storage shows the VM in the window with its size and Show in Finder; All
  VMs… lists every VM with size, Show in Finder and Delete. Downloaded
  images (the Omarchy images the app downloaded to set up VMs, in
  `~/Library/Caches/omacvm`) with Remove…: it asks first, names the size and
  never touches the Mac's Downloads folder.
- A drive that is not connected is named as such ("SD4TB is not
  connected"), and nothing is built into a stale /Volumes folder. A VM whose
  files are missing says which and does not start.
- VMs in the old hidden folder are found wherever the VMs folder is, and the
  app offers once to move them to `~/OmacVM`; new VMs go to `~/OmacVM`.
- An app in /Applications offers once to move itself to ~/Applications.
- VM folders are left out of Time Machine.
- Going back to 2.9.0: once 3.0 has made `~/OmacVM`, 2.9.0 shows only the
  VMs in `~/OmacVM` (or in the folder picked in the app). VMs still in the
  old hidden folder or another folder are hidden from it, not deleted; 3.0
  finds them again.
- Omarchy's Chromium decodes H.264 and VP9 on the Mac's media engine in
  OmacVM.app VMs, YouTube included, with no flags to set: feature
  `chromium-video`, on by default for app VMs (`omacvm disable
  chromium-video` takes it out). YouTube 4K60 uses 0.41-0.62 of a core in
  the VM instead of 1.00-1.11. HEVC, AV1 and 10-bit stay on the CPU.
  `omacvm check` has a "video decoding in Chromium" line.
- Video: reading a decoded picture out in the other YUV layout works. FFmpeg's
  `-hwaccel_output_format vaapi -vf hwdownload,format=yuv420p` gave the same
  empty picture for every frame since 2.7.0; NV12 to I420/YV12 and back are
  now bit for bit the decoded picture (in the desktop session; done by the
  VM's VA-API driver shim).
- The OmacVM control centre: `omacvm` in Omarchy (the Omarchy menu's
  OmacVM row, the bar's OmacVM item or a terminal) shows every feature with
  its live status and what to do on the Mac when it needs you. Switch a
  feature, repair it, see its checks and log. "Report a problem" (also
  `omacvm report` on the Mac) collects the check, versions and logs without
  names, addresses, keys or Wi-Fi names, shows you the text, and opens a
  GitHub issue with it. Requests go to the Mac through OmacVM Bridge, signed
  with a key each VM gets from `omacvm apply`. It shows when a release has
  updates for your features (from the release's signed manifest) and
  installs them when you ask (as `omacvm update` does). Feature `control-centre`, on by
  default; an older VM is asked once at its next apply.
- The control centre opens as a floating window in the middle of the
  screen (65 % of the display), from the menu, the bar, or `omacvm` typed
  in a terminal on the desktop (`omacvm --here` stays in the terminal).
  Escape closes it.
- The control centre works on a Mac with only OmacVM.app (no `omacvm`
  command installed). The app carries the whole `omacvm` and points OmacVM
  Bridge at it at every start; before, every Mac row said "not checked".
  Changes run from a copy, so nothing is written inside the signed app.
  Without Textual in the VM, the control centre installs it from the Mac
  instead of asking you to run `sudo pacman`.
- `omacvm check` no longer calls the Bridge failing when it sets up its
  media keys again as a VM comes to the front.
- OmacVM.app can update itself (weekly check, waits until the VM is shut
  down, goes back to the old version if the new one does not start; "Go
  Back" in the app menu). The feed is signed with OmacVM's release key;
  3.0.0 is the first release with one. From 2.9.x, update once with
  `omacvm update` (or the zip); 2.9.x apps do not check by themselves.
- Prebuilt VMs for Parallels, UTM and VMware Fusion: only the VM bundle comes
  out of the image, and its settings and disks are checked before use (no
  paths outside the bundle, no shared folders, no extra QEMU arguments,
  disks without a parent). Free space is checked before the download, and
  the seed with the password hash is deleted however the build ends.
- The escape combo (now ⌃⌥ Esc) in the full-screen VM no longer takes the VM
  out of full screen.
  It moves the monitor under the pointer to the Space you came from with
  macOS's own "Move left/right a space" shortcut (as set in System Settings
  › Keyboard › Keyboard Shortcuts, ⌃← and ⌃→ by default), with macOS's own
  animation; pressed again in macOS, it moves back into the VM. On macOS 27
  the swipe OmacVM made before did nothing on a Mac mini. If the shortcut
  is off or does not move, Omarchy says so and nothing else happens (never
  Mission Control). The VM is never hidden.
- OmacVM.app: when a VM's window opens, OMACVM turns into Omarchy's logo
  (about 3.5 s; just the logo with Reduce motion). The logo then stays until
  Omarchy's desktop (or its login or lock screen) is there, over the
  firmware, GRUB and Linux's text, and fades into it once the wallpaper is
  drawn (not into Hyprland's grey before it); also after a restart.
  It gives way at once if the VM stops on an error, and after 40 seconds
  without a desktop, so a prompt or an error in the VM shows. If Omarchy has
  shown nothing at all after 90 seconds, a line under the logo says so and
  where the logs are.
- OmacVM.app: an output with nothing on it shows Omarchy's logo instead of
  QEMU's "Display output is not active.", and plain black once the desktop
  was there (also when it came after the 40 seconds): an idle Omarchy that
  turns its display off now shows black.
- Boot logo: the firmware's logo is as big as the app's start animation
  (810 x 190 at 1920 x 1080) and smaller on a small screen (a small window
  after a restart) instead of none.
- OmacVM.app wakes the Mac less while Omarchy sits idle. QEMU's screen tick
  slows to 500 ms when nothing changes (`OMACVM_IDLE_REFRESH=0` keeps the
  old rate), the app holds the guest agent's connection, and the Mac
  clipboard is polled fast only while the VM is in front: on an idle
  desktop QEMU wakes about 65-120 times a second instead of 130-190, the
  app 1.2 instead of 5. In the VM the clipboard, display and camera agents
  wait for events instead of looking every second; on the Mac, Gestures
  checks the pointer at 20 Hz once it rests (was 120) and Omanotch only
  polls while a VM is connected.
- OmacVM.app: a Graphics setting per VM, **OpenGL**, **Vulkan** or
  **Automatic** (the default), in the app's setup and VM window, with
  `omacvm graphics --vm NAME opengl|vulkan|auto`, and on the control
  centre's Graphics row. Vulkan gives the VM Vulkan on the Mac's GPU (Venus)
  next to OpenGL; OpenGL and the browsers stay on virgl either way, so
  Vulkan only adds Vulkan apps (on macOS 26 and newer on KosmicKrisp, which
  ran vkmark off-screen 29 % faster than MoltenVK on a Mac mini M4).
  Automatic is OpenGL on every Mac in 3.0.0; turning it to Vulkan on
  macOS 26 and newer later is one line. It applies at the VM's next start,
  and `omacvm check` says what a start got. The hidden `venus` switch of 2.9
  is gone: if it was on, the app's first 3.0.0 launch sets Graphics to
  Vulkan for each VM that had no choice of its own (OpenGL stays OpenGL)
  and says so in its log.
  With Vulkan the VM also gets OpenCL on the Mac's GPU (Arch's rusticl on
  Zink on Venus, no build) where the Mac's driver is KosmicKrisp (macOS 26
  and newer): Geekbench 7 OpenCL 20,121 on a Mac mini M4 (the Mac itself:
  35,240). On macOS 15 (MoltenVK) Zink cannot run, so OpenCL there needs
  `omacvm enable vulkan` (below).
- KosmicKrisp is in the app (about 13 MB, its licences in the app's
  licences folder): on macOS 26 and newer Vulkan runs on it, on older macOS
  on MoltenVK. A Mac where KosmicKrisp cannot run falls back to MoltenVK
  and QEMU's log says why; `OMACVM_VULKAN_DRIVER=moltenvk|kosmickrisp`
  picks one by hand. Release builds have it; building it needs Xcode 26 and
  Homebrew's llvm, spirv-llvm-translator, spirv-tools and bison
  (`app/runtime/build-kosmickrisp.sh --check` lists what is missing); other
  builds keep MoltenVK only unless `OMACVM_RUNTIME_KOSMICKRISP=1`.
- Vulkan's host memory window comes from the VM's memory plan (what the Mac
  has beyond the VM and macOS's reserve, 1 to 32 GB) instead of a fixed
  4 GB; what Vulkan allocates still counts against the GPU memory budget.
- Vulkan works on a stock Omarchy: while Arch Linux ARM has Mesa 26.2.3,
  whose Venus driver does not size GPU memory to the Mac's 16 KiB pages
  (every Vulkan app failed with `ERROR_OUT_OF_HOST_MEMORY`), `omacvm apply`
  builds Mesa 26.2.4's Venus driver as Arch's `vulkan-virtio` package when
  the setting gives the VM Vulkan. Until it is built, a VM set to Vulkan
  starts with OpenGL only, and the app, `omacvm graphics` and the control
  centre say "Vulkan (driver not built yet: runs on OpenGL until the next
  apply)". In the VM a timer looks again 90 s after boot, after the desktop
  is up, so a build never holds up the boot or the desktop. `omacvm check`
  has a "Vulkan (Venus)" row.
- Vulkan windows no longer take Omarchy's desktop down: a Vulkan app on
  Wayland (vkcube, vkmark) made Hyprland lose its GPU context for good (a
  black desktop) when it took the app's frame as a dma-buf. macOS OpenGL
  cannot import that memory (a Metal heap), and the failed import ended
  the whole context. Now the Mac copies the Vulkan image into an OpenGL
  texture each time Hyprland draws it, and an import that cannot work
  leaves that window blank instead of ending the context.
  On macOS 15 (MoltenVK) Vulkan apps now use Mesa's normal present path
  (vkmark on an M4 Max, median of 3: 865 in a window and 678 full screen,
  against 336 and 65 with the CPU copy).
  On macOS 26 and newer (KosmicKrisp) Vulkan windows still go through the
  CPU copy (`MESA_VK_WSI_DEBUG=sw`), which is slower, mostly full screen
  (vkmark full screen 203 on a Mac mini M4 at 5K). The faster path is not
  tested on KosmicKrisp yet. A VM started by an older app also keeps the
  CPU copy.
- OmacVM.app: WebGPU and GPU compute, experimental and off by default:
  `omacvm enable vulkan --vm NAME`, then restart the VM. The VM gets OpenCL
  (darktable, ffmpeg's OpenCL filters, Geekbench GPU), WebGPU in Firefox,
  and a "Chromium (WebGPU)" menu entry with WebGPU on the Mac's GPU (the
  normal Chromium keeps its software WebGPU), and Vulkan whatever its
  Graphics setting. The first time, the VM builds a Mesa for it: about 3
  minutes on an M4 Max and a 140 MB download (Mesa's source and Rust;
  Omarchy has LLVM and Clang already). The build tools it adds are removed
  after the build, and the feature is only turned on when the build worked.
  WebGPU matrix multiply in that Chromium: about 5,000-6,300 GFLOPS, 84 % of
  Chrome on the Mac in a locked batch; Geekbench 7 GPU OpenCL 45 % of the
  Mac's own OpenCL. A 15-minute soak (OpenCL, WebGPU in both browsers,
  ffmpeg OpenCL) passed in the app with no failure, and the host's GPU
  memory went back down when the browsers closed. `omacvm disable vulkan`
  removes it.
- Fast network (OmacVM.app, experimental): a button in the app turns it on
  and off (Fast network › Turn On…, one password dialog), and Omanotch's
  link works over it (the strip itself not checked on a notch Mac yet).
  Two VMs at once work (each from an app copy with its own bundle id: the
  app runs one VM at a time).
- Fast network: moving a running VM between the fast network and QEMU's
  user network no longer leaves it without internet for seconds. Back to
  the fast network had a gap of 7-8 s, now none (the user network stays
  until the fast one has worked for 12 s); to the user network 6.6 s
  instead of 14.5 s (app VMs skip a card's routes the moment its link goes
  down). Measured on a Mac mini with two VMs.
- Fast network field tests on the Mac mini: a real sleep and wake (SSH and
  Omanotch back within 2-5 s, no reconnect), Wi-Fi/Ethernet changes (no
  gap), two VMs at once.
- Fast network: a VPN connected while the VM runs works for the VM. macOS
  translates the VM's addresses only on the networks that were up when its
  sharing service started, so a VPN's server got the VM's own addresses
  and dropped them (a full tunnel: no internet in the VM). The fast
  network's service now does that translation itself for such networks,
  only while a VM is on the fast network and only in its own pf rules
  (nothing else in the Mac's firewall changes), and takes it away when the
  VPN goes. `omacvm check` shows it (docs/routes/app.md).
- OmacVM.app: the sound holds while the VM and the Mac are busy. QEMU's
  main loop, which moves the sound and runs the VM's GPU, now runs at
  user-interactive QoS instead of competing with the VM's CPUs, and the
  sound card no longer takes the time it missed (a new shader stops that
  thread for 50-80 ms) from the VM all at once. In 10-minute tests on a
  MacBook Pro with the VM's GPU busy and 8 busy threads on the Mac, breaks
  in a test tone went from 12 to 2; with every core busy as well, from a
  median of 365 to 50. The sound's delay is the same. `omacvm check` shows
  it ("sound timing"); `defaults write org.omacvm.app audioClassic -bool
  true` goes back.
- OmacVM.app: a Mac audio device that does not answer no longer hangs the
  VM. Up to 2.9.1 QEMU waited for it without a limit at the start (no
  window, the VM never ran) and whenever the VM started a sound. Now it opens
  the device on a thread of its own; after 3 s the VM runs without sound,
  `omacvm check` says so ("sound") with the fix, and the sound comes back
  once the device answers again.

## 2.9.1

A hotfix for 2.9.0: brightness keys that work with the VM in front, a
way out of the VM that always works, no VM freeze under network load, and
WebGL Aquarium back to 2.8.0's speed.

### Fixed

- OmacVM.app: the VM no longer freezes when the Mac cannot send one of its
  UDP packets at once (seen on a Mac mini during a big file copy; network
  filters and VPN apps can hold sends back). QEMU's user network waited in
  that send with the whole VM stopped; now the packet is dropped, as a busy
  network would, and `qemu.log` says so at most once a minute with where it
  was going. `info usernet` counts the drops.
- If QEMU's main loop stops for more than 2 seconds for any reason,
  `qemu.log` now says where it is and when it is back
  (`OMACVM_STALL_WATCHDOG=0` turns this off).
- Brightness keys with an OmacVM.app VM in front (full screen or in a
  window): on macOS 27 they reach no app, so OmacVM Bridge now reads them
  from the keyboard (Input Monitoring; macOS still gets every key) and sets
  the display the VM is on. This works with a Bluetooth Magic Keyboard too.
  Quick presses step every time and a held key repeats at macOS's key repeat
  speed. With no VM in front, macOS handles them as always. The volume keys
  are taken at the keyboard level as well.
- ⌃⌥⌘ Esc always gets you out of the full-screen VM. After the swipe,
  OmacVM Gestures checks that the VM is no longer in front; if it still is
  (on a Mac mini the swipe did nothing and Finder had no window), the VM's
  window leaves full screen and is hidden, and ⌃⌥⌘ Esc in macOS brings it
  back. On a Mac with only the desktop and the VM's Space, a swipe that
  bounces is tried the other way once. "Swipe all monitors" swipes each
  display.
- ⌃⌥⌘ Esc in an OmacVM.app window gives the keyboard back to the app you
  were in before (else Finder); pressed again in macOS, the window comes
  back with the keyboard.
- The helpers' key taps take the front place again in more cases after
  OmacVM.app restarts: also for a VM in a window, and for the Bridge's media
  keys when macOS names no program for QEMU (builds on brianmerchant's fix,
  #39).
- WebGL Aquarium is back to 2.8.0's speed with 2.9.0's GPU gains kept: the
  thread that waits for GPU fences no longer tests them back to back while
  QEMU's render thread runs guest commands (it took Apple's OpenGL lock from
  it). Bench lock, this part alone: Aquarium 20.15-20.6 fps against 2.9.0's
  19.0 and 2.8.0's 20.2 (ADR 0026). `OMACVM_VIRGL_FENCE_BUSY=0` goes back.
- Mouse wheels scroll one to one again, with nothing after the wheel stops
  (a smooth-scrolling mouse such as a Logitech MX could jump on). Scroll
  momentum now only ever takes a trackpad's scrolling (built-in, or a Magic
  Trackpad, also one connected later), so it is on by default for new VMs.
- Omarchy's bar shows Wi-Fi as connected while the Mac is, also before
  Location Services is allowed for OmacVM Bridge (or when it is not): the
  link decides then and the network's name stays hidden. No more flipping
  on and off.

### Also

- OmacVM.app's `apply-vm.sh` takes `--reset-host-key` for a reinstalled VM.
- OmacVM Bridge logs a brightness key an external display did not take
  once, and asks for QEMU's control socket again on the next key.
- Experimental, off by default: every macOS shortcut to the VM while it has
  the keyboard (`defaults write org.omacvm.app macShortcuts -bool false` and
  a VM restart). On a Mac mini macOS's shortcuts were not always handed
  back, so macOS keeps them unless you turn this on.
- Docs: OmacVM.app needs macOS 15 or newer.

## 2.9.0

A faster GPU path for OmacVM.app with frames on the display's refresh (120
Hz on a MacBook Pro), fewer black WebGL canvases, video encoding on the
Mac's media engine, ⌃⌥⌘ Esc straight back to macOS, media and brightness
keys for the VM and external displays, signed Mac helpers, and an opt-in
fast network. Numbers against 2.8.0 are from the release candidate, with
the benchmark lock held.

### GPU and display (OmacVM.app)

- A faster GPU path. GPU fences come back in about 0.2 ms instead of 1.5
  ms, so light 3D work runs two to three and a half times as fast:
  glmark2's short set 2,856 against 2.8.0's 1,124. A new frame goes to the
  window as soon as Omarchy finishes it, drawn off the main thread as an
  IOSurface, not on QEMU's 30 ms timer.
- WebGL-heavy pages stay about where they were; there Apple's OpenGL is the
  limit. Against 2.8.0 with one other VM running: Aquarium 19.0 against 19.9
  fps (4.5% slower: the new threads that wait for the GPU and show frames
  take Apple's OpenGL lock from the render thread; a fix is in testing),
  Basemark Web 3.0 2,669 against 2,482.
- The thread that waits for the GPU no longer keeps a core busy, also during
  a long GPU job (about 2,100 wakeups a second instead of 19,900). If it
  cannot start, the VM falls back to the old 1 ms polling and says so in
  `qemu.log` and `omacvm check`, instead of hanging the guest's GPU.
- Frames on the display's refresh: one new frame per refresh (testufo 117-120
  new frames a second on a 120 Hz display; 2.8.0 about 90). On a ProMotion
  MacBook the refresh rate follows what the guest draws (a 24 fps video asks
  for 24 Hz), as native apps do; displays with one rate keep it.
  `OMACVM_GL_REFRESH=fixed` keeps the full rate. The windows on other
  displays still draw the old way.
- Colours: frames are tagged sRGB, so the guest's colours are no longer
  stretched to the MacBook's P3 range (red was too saturated).
- WebGL and OpenGL apps: shaders and limits that Apple's OpenGL refuses no
  longer stop the app's whole GL context (the canvas or window went black for
  good). dEQP GLES3 (every 50th case) 812 to 855 of 869; the whole GLES3
  list in one process 22,445 to 43,125 cases; the WebGL conformance pages in
  one Chrome 430 to 776 (WebGL 1) and 97 to 959 (WebGL 2), because one
  refused shader no longer breaks every page after it. 107 transform
  feedback cases that failed in 2.7.1 pass.
- The guest can no longer make QEMU allocate up to 3 GiB of window surfaces,
  or new ones on every frame: they are at most the size of the largest Mac
  display and made again at most twice a second.
- If the picture or the GPU misbehaves on a Mac:
  `defaults write org.omacvm.app gpuSafeMode -bool true` and a VM restart go
  back to the fence and frame path of 2.8.0 (video decoding and the other
  fixes stay). `omacvm check` shows which path a VM took.
- Vulkan in the VM, hidden and experimental (Venus on MoltenVK):
  `defaults write org.omacvm.app venus -bool true`. Needs Mesa 26.2.4 or newer
  in the VM (`app/scripts/dev/guest-mesa-venus.sh` builds it while Arch Linux
  ARM has 26.2.3). vkmark about 4,500 to 5,200; the same build with the old
  polled fences gives about 730 (no release had Venus). Venus memory is mapped
  into the VM only in whole 16 KiB pages that belong to it. `omacvm check`
  names the Vulkan driver a VM uses.
- KosmicKrisp, opt-in at build time: a runtime built with
  `OMACVM_RUNTIME_KOSMICKRISP=1` (needs Xcode 26 and Homebrew's llvm,
  spirv-llvm-translator and spirv-tools) also carries Mesa's Vulkan
  driver on Metal. On macOS 26 and newer Venus then runs on it (Vulkan 1.4,
  more features than MoltenVK); when it cannot start, Venus falls back to
  MoltenVK, says why in `qemu.log`, and `omacvm check` shows a warning. The
  released app is built without it.
- HDR, hidden and experimental: `defaults write org.omacvm.app hdr -bool
  true`, then in the VM `sudo omacvm-virtio-gpu-build` (a 10-bit virtio-gpu
  module, rebuilt for new kernels) and a restart. Only on displays that can
  show HDR; the main window's output only. mpv and Chrome do not send HDR yet.
- In full screen the pointer no longer races near the screen corners and the
  Dock's edge (since 2.8.0 it got faster there with every move, up to about
  20 times). It now moves as macOS moves it everywhere, and reaches
  Omarchy's own corners. The Mac's cursor still stays off the corners and
  the Dock's edge. New setting "Keep the Dock and hot corners away in full
  screen" (on by default); off gives macOS's own full screen.
- "Use the notch for the menu bar" is on by default (Omarchy's bar beside the
  notch in full screen). It shows only on a Mac whose built-in display has a
  notch, checked again when displays change; if you switched it off before,
  it stays off.

### Video (OmacVM.app)

- Video encoding on the Mac's media engine: apps in the VM that encode H.264
  or HEVC through VA-API use it instead of the VM's CPU (FFmpeg's
  `h264_vaapi`/`hevc_vaapi`, OBS Studio's VAAPI encoders). Google Chrome's
  and Brave's WebRTC encoder (camera and screen sharing) is on by default.
  FFmpeg 1080p uses 6 to 8 times less Mac CPU than x264/x265. 8 encoders at
  once per VM, 12 at most. `OMACVM_VIDEO_NO_ENCODE=1` in QEMU's environment
  turns it off.
- Video decoding: up to 32 hardware decoders per VM (Chrome's 16 plus one
  Firefox's 16). Past that, a video decodes on the CPU instead of playing
  black (the VM's VA-API driver knows the Mac's limit). The copy of each
  decoded picture can no longer be dropped by the app's own graphics state.
  Existing VMs get the new driver with `omacvm update`.

### Keys, brightness and the Mac's helpers

- ⌃⌥⌘ Esc in the full-screen VM now takes you straight back to macOS: the
  monitor under the pointer swipes to the Space beside the VM's, with
  macOS's own animation, and the keyboard follows the pointer's monitor (no
  trackpad needed, a mouse is enough). Pressed there again it swipes back
  into the VM, full screen, with the trackpad and keys. OmacVM.app's
  "Escape combo" setting swipes all monitors instead (other routes:
  `defaults write org.omacvm.gestures EscapeSwipe all`). If the swipe cannot
  be made or does not land, the app you were in before comes to the front
  instead, and if macOS refuses that too, the VM's app is hidden: the
  keyboard is never stuck in the VM. Before, it only handed the trackpad
  back. OmacVM.app, Parallels, UTM and VMware Fusion.
- Media keys with an OmacVM.app VM in front, full screen or in a window:
  volume and mute set the Mac's output; when it has no software volume (an
  audio interface such as a Focusrite Scarlett), they set the VM's own
  volume with Omarchy's popup instead of macOS's greyed-out panel.
  Play/pause, next and previous go to the VM's players, not macOS's Now
  Playing. The keys reach the VM through QEMU's control socket; if that is
  busy, the key goes to macOS. The Bridge takes them at the HID level: on
  macOS 27 the volume keys never reach a session tap.
- OmacVM.app carries OmacVM Bridge and OmacVM Gestures built and signed with
  OmacVM's Developer ID: `omacvm apply`, `omacvm update` and the app install
  these copies (nothing is compiled on the Mac), and macOS keeps their
  Accessibility and Input Monitoring permissions across updates. macOS asks
  once more after the first signed install. A source checkout without the
  app, or of another version, builds them as before. Both helpers log which
  permission is missing, and `omacvm check` shows it.
- After OmacVM.app was restarted, ⌃⌥⌘ Esc and the media keys could stop
  working until the Mac's helpers were restarted: the new VM's own key tap
  sat ahead of theirs. They now take the front place again whenever an
  OmacVM VM comes to the front (Gestures fix by brianmerchant, #39).
- External display brightness (feature `external-brightness`, on): with the
  VM in front on an external display, the Mac's brightness keys set that
  display, in macOS's 16 steps (Option: 64), with Omarchy's popup. A display
  macOS dims itself (Studio Display, Pro Display XDR, LG UltraFine) goes
  through macOS's own control, also on a Mac mini where it is the only
  display; other monitors over DDC/CI. Omarchy's
  brightness keys, `omarchy brightness display` and its monitor panel in the
  VM do the same through OmacVM Bridge. OmacVM.app also in a window;
  Parallels, UTM and VMware Fusion in full screen. The built-in display works
  as before, and so does a display without DDC/CI (`omacvm check` names it
  and why). A key the Bridge cannot use goes to macOS, and the Bridge's log
  says once why.
- OmacVM Bridge: Wi-Fi no longer flips between connected and disconnected
  in Omarchy's bar on a Mac on Ethernet with Wi-Fi also on (Mac mini).
- Trackpad gestures off now means the VM's Gestures service is off on every
  route. On UTM, VMware Fusion and OmacVM.app it used to keep running for
  the Cmd shortcuts and connected to the Mac's Gestures anyway; Cmd as Super
  there now comes with the gestures feature. `omacvm apply` stops the service
  in VMs that have gestures off.

### OmacVM.app and its VMs

- OmacVM.app keeps its VMs in `~/OmacVM`, one folder per VM, and installs
  itself in `~/Applications`. VMs in the old place
  (`~/Library/Application Support/OmacVM/VMs`) stay there and keep working
  while `~/OmacVM` does not exist; a folder picked in the app still wins.
  `omacvm` finds the app in `~/Applications` or `/Applications` and the VMs
  the same way as the app. Spotlight still lists the file names in
  `~/OmacVM` (it never reads inside a VM disk); to hide them, add the folder
  under System Settings › Spotlight › Search Privacy.
- The install dialog starts on the name and folder of the copy you installed
  before, so a new download replaces it instead of adding a second app, and
  says when Install replaces a copy. Run Without Installing now counts for
  that copy only. Install refuses to replace a copy that is running.
- OmacVM.app opens the VM's window on the display you are using (under the
  pointer, else the one with the active menu bar) and gives it the keyboard.
- Fast network, experimental and off by default:
  `omacvm enable fast-network --vm NAME` puts the VM on macOS's own VM
  network (vmnet, as Parallels and UTM) through a small system service,
  `omacvm-netd`, that asks for your password once. On a Mac mini, VM to Mac
  7.2 instead of 3.0 Gbit/s with less CPU; Mac to VM is lower than the user
  network (9.5 against 12.2 Gbit/s). Without the service the VM keeps QEMU's
  user network. Not tested yet: a MacBook, VPNs, sleep and wake, Wi-Fi
  changes, several VMs at once, Omanotch over it.
- The app carries the licence texts of MoltenVK and the Vulkan loader
  (Apache-2.0, with cereal and cJSON), and of KosmicKrisp in builds that
  have it.

### Prebuilt VMs

- The image's manifest is checked before use. A bad value in a manifest (for
  example a disk size with a command in it) could run that command on the
  Mac; now such a manifest is refused and the VM is built here instead.

## 2.8.0

- OmacVM.app uses every Mac display in full screen: a window (in its own
  Space) and an Omarchy output per display, at its resolution, scale and
  refresh rate, placed as in macOS's arrangement, with plugging in and out
  live. "Use external displays" in Omarchy's display panel keeps full screen
  on one display. Tested on a real external monitor next to a MacBook with a
  notch, and on virtual displays.
- OmacVM.app in full screen on a Mac with a notch: Omarchy gets the window's
  real size (1728x1080 points on a 14-inch MacBook Pro, was 1728x1085). The
  picture is no longer squeezed and the pointer lands where it is on the Mac
  (it was up to 5 points off at the bottom).
- OmacVM.app in full screen: the Dock no longer comes up at the edge of an
  external display. Near a screen corner the Mac's cursor is held 3 points
  short of it; whether that keeps macOS hot corners from firing is not
  confirmed yet (in tests with simulated mouse motion they still fired).
- Cmd-drag moves an Omarchy window from one Mac display to another; a held
  modifier key is no longer let go when the pointer crosses to another
  display's window.
- Omanotch with external displays: the strip and its bar stay on the
  MacBook whichever display holds the main window (OmacVM.app tells the VM
  which output is the built-in display). Before, with the main window on an
  external display, the MacBook showed two bars.
- OmacVM.app: displays no longer come up black (dark grey, no wallpaper, no
  bar) after a start or reboot, about one boot in six with two displays.
  QEMU refused the memory of a large texture (Omarchy's wallpaper, 81 MB)
  when the VM's memory was fragmented, and the shell lost its GPU context.
  It also happened with one display, less often, in earlier versions.
  The VM now also checks what each display really shows and restarts the
  shell once if one stays grey; omacvm check says "desktop" and, on the Mac,
  "GPU contexts".
- Omanotch's wallpaper is decoded at the display's size (about a third of
  the memory per display on a MacBook, so UTM's QEMU, which keeps the old
  limit, no longer refuses it up to about a 4K display; a 6K display's
  upload is still too big for it), and its bar and wallpaper follow their
  output when it moves in the layout.
- Omanotch: after a shell restart the bar is parked under the strip again
  within seconds; before, the MacBook could show two bars.
- Per-display workspaces handle more than two displays (Virtual-3 gets
  21..30, and so on), and several workspaces of an unplugged display all
  come back when it returns. Tested on OmacVM.app; Parallels and Fusion use
  the same file.
- Change the CPUs and memory of an existing VM: `omacvm resources --vm NAME`
  with `--resources low|balanced|high|best`, `--cpus N` or `--memory-gb N`
  (also in the `omacvm` menu). The same tiers and limits as the build, on
  every route: Parallels (`prlctl set`, or its settings file on Standard),
  UTM, VMware Fusion (graphics memory goes down with the memory when it would
  no longer fit) and OmacVM.app. The VM must be stopped, except on
  OmacVM.app, which takes the change at its next start. A name used in two
  apps needs `--vm-type`.
- OmacVM.app: a Resources picker in the VM's window, with the create
  screen's tiers; it applies on the next start.

## 2.7.1

Security and crash fixes for OmacVM.app's GPU (a VM could restart the Mac),
plus fixes from testing 2.7.0 on a Mac mini.

- OmacVM.app: a Linux app could make the Mac's GPU read outside a buffer (a
  draw past the end of its buffers, an unbound uniform block); the GPU
  faulted and macOS restarted. The app now checks every buffer range a draw
  reaches before the GPU sees it, and skips draws that would leave one.
- OmacVM.app: a WebGL 2 or OpenGL ES app using transform feedback could stop
  the VM (QEMU crashed in Apple's OpenGL when it ended the recording). Fixed in
  the app's virglrenderer, with a build-time test.
- OmacVM.app: a shader the Mac refuses skips its draws instead of stopping the
  whole app's GPU context.
- OmacVM.app: a Linux app switching the screen between large modes in a loop
  grew the VM's GPU memory on the Mac by up to 1.1 GB per switch and never gave
  it back, until the Mac ran out of memory (2.6.0 and 2.7.0 too). Two GL
  contexts were never flushed; both are now, and the memory stays flat.
- OmacVM.app: the textures and buffers a VM's apps make have a memory budget
  on the Mac, a quarter of its memory (`OMACVM_GPU_MEMORY_MB` changes it, 0
  turns it off). Past it, the app's GPU context stops; the VM and the Mac go on.
  Screens and cursors may go 256 MB past it, so the desktop keeps working.
- OmacVM.app: a texture copy whose size the app's check cannot work out is
  refused (2.7.0 let such copies through unchecked).
- OmacVM.app: a VM starts with Omarchy's logo instead of TianoCore's. The app
  builds its UEFI firmware itself: the same edk2 as QEMU's, with QEMU's build
  flags, only the logo is new. If that build fails, the app keeps QEMU's
  firmware and says so.
- Omanotch no longer asks for Accessibility. It picks the VM for the strip by
  the full-screen window's app; with two VMs of one app it keeps the one it
  serves (or takes the one that connected last) instead of reading window
  titles.
- `omacvm uninstall --purge` deleted every OmacVM.app VM: on macOS's usual
  disk, OmacVM's settings folder and the app's VMs folder are the same. It
  now removes only OmacVM's own files, and says what stays.
- A VM name used in two apps (a Parallels VM and an OmacVM.app VM both called
  "OmacVM Test") is no longer guessed: `omacvm apply`, `check`, `features` and
  `update --vm NAME` stop and ask for `--vm-type`. Before, they took the
  Parallels VM.
- UTM: listing VMs (the menu, `omacvm vms`, `update`, `build --dry-run`) no
  longer hangs for up to 10 minutes while macOS asks whether the terminal may
  control UTM; a VM's address is found without waiting on UTM; a UTM VM in an
  unknown state is never started. The build asks about that permission before
  the download, and a timeout says it may be macOS's unanswered prompt. Build
  UTM VMs in Terminal on the Mac, not over SSH.
- `omacvm build` lists OmacVM.app first in the app question, as the README
  recommends.
- `omacvm check` on a Mac without a notch says "no notch" for the app's notch
  strip line.
- `omacvm update` says "macOS asks for permissions now" only on a first
  install.
- **VMs last set up or updated with OmacVM 2.3 or older need one
  `omacvm update`** (with the VM running). Until then OmacVM Gestures doesn't
  let them in, because their trackpad daemon has no Bridge token.
  `omacvm check` says so.
- Old names are gone: `--mac-wallpaper` (now `--wallpaper`), the feature name
  `glide` on the command line (now `scroll-momentum`; a VM that still has the
  old setting keeps it), and the clean-up of the "Omarchy Notch Bar" app from
  before Omanotch had its name.
- The 1.x commands `./build.sh`, `./apply.sh` and `./check.sh` in the
  repository's root are gone. Use `omacvm build`, `omacvm apply` and
  `omacvm check`.

## 2.7.0

- OmacVM.app: videos are decoded by the Mac's media engine instead of the
  VM's CPU. Google Chrome, Brave and Firefox (H.264 and VP9; AV1 in Chrome,
  not yet in Firefox), mpv, FFmpeg and GStreamer apps use it: YouTube in 4K
  at 60 fps plays with the VM's CPU nearly idle. HEVC and 10-bit video work
  too (mpv, FFmpeg, GStreamer; in Chrome HEVC stops after a seek for now). Omarchy's own Chromium
  (Arch Linux ARM) is built without VA-API and still decodes on the CPU; a
  route for it (V4L2) is planned. OmacVM installs no browser for this; Google
  Chrome for Linux ARM comes from `src/bench/install-chrome.sh`. See
  [docs/video-decode.md](docs/video-decode.md).
- OmacVM.app: a Linux app could stop the VM by reading back a texture in the
  YUYV plane format (mpv's VA-API check did): QEMU's heap overflowed. Fixed in
  the app's virglrenderer, with a build-time test for every texture format.
- Mac mini, iMac and Studio: a Studio Display or LG UltraFine's brightness
  follows the brightness keys; no keyboard light, notch or trackpad is a skip
  in `omacvm check`, not a failure; a Parallels VM on a Mac without a battery
  says so; Gestures finds VMware Fusion VMs when Fusion started after it; the
  Bridge picks the main display first.
- The menu says a suspended VM is suspended, not stopped.
- UTM and VMware Fusion: right after the first boot, the battery agent waits
  for the Bridge instead of failing (`omacvm check` reported it, and the
  Wi-Fi QR card, until a minute later).
- VMs from the 2.5 and 2.6 prebuilt images: the desktop background was black
  (links into the image's placeholder home). First boot now fixes the links;
  `omacvm apply` or `omacvm update` repairs older VMs.
- OmacVM.app: building a VM under the name of a deleted one no longer stops
  at step 5 (the old SSH host key), and a build works again after macOS
  cleared the live system's cache.
- Gestures: with two OmacVM.app VMs running, each keeps its connection (they
  all come from 127.0.0.1 and pushed each other out every second).

## 2.6.0

- OmacVM.app: Omarchy in its own Mac app, without Parallels, UTM or VMware
  Fusion. It brings QEMU (try-omarchy's patched build) and runs it with
  Apple's Hypervisor framework. Download `OmacVM-2.6.0.zip` from the release,
  signed with a Developer ID. See [docs/routes/app.md](docs/routes/app.md).
- `omacvm build --vm-type app`: builds the VM through OmacVM.app with the same
  questions as the other routes. It downloads the app when it is missing
  (after asking), checks the zip against its `.sha256` and that the app is
  signed with OmacVM's Developer ID. `omacvm update` replaces an older app.
- Omanotch is built in: it lives in `src/omanotch` and OmacVM installs it
  from there, on the Mac and in the VM, with no clone of its own repo.
- Proofs between the VM and the Mac, so another program on the Mac can't pose
  as Gestures, the Bridge or Omanotch: Gestures and Omanotch never get the
  Bridge's token; the VM and the helper each prove they know it (HMAC-SHA256
  over fresh nonces and the Mac address). The Bridge gets the token only
  after its own proof checks out.
- The Mac's battery in Omarchy's bar on a MacBook: charge, charging and
  Omarchy's battery panel, as on a laptop (feature `battery`, on for UTM,
  VMware Fusion and OmacVM.app; Parallels shows it itself). The VM never
  suspends for a low battery. Time left and the low-battery warning are not
  tested yet with the Mac on battery. See
  [src/battery/README.md](src/battery/README.md).
- The Mac's camera as *Mac Camera* for Linux apps and video calls in the
  browser (feature `camera`). It is on only while an app uses it. UTM and
  Fusion get it through OmacVM Bridge (installed for it also with the
  Bridge off), OmacVM.app over its own port, Parallels shares it itself.
  Programs on the Mac can't use the Bridge's camera.
- Sound and the Mac's microphone on UTM and Fusion: new VMs get a sound card,
  an existing one gets it the next time `omacvm apply` starts it from shut
  down. macOS must allow the VM's app the microphone; `omacvm check` says
  when it doesn't. OmacVM.app asks for it when it starts a VM; its QEMU
  starts the recording on a thread of its own, so a slow start never stops
  the VM (the VM records silence until the microphone runs).
- WebGL pages no longer hang in OmacVM.app. Basemark Web 3.0 stopped at its
  fifth test because the app's virglrenderer turned shaders that read integer
  textures into GLSL the Mac refuses (finding 23 in
  [docs/troubleshooting.md](docs/troubleshooting.md)).
- Omanotch can make its bar exactly as tall as the notch:
  `defaults write ch.gillesgoetsch.omanotch flush -bool true`. Off by default.
- The Mac's keyboard light goes three steps dimmer than macOS's lowest with
  Shift and the brightness keys (`"keyboard_low_steps": false` in the
  Bridge's `config.json` turns them off).
- One event stream from the Mac per VM, shared by the bar widgets and the
  on-screen display, instead of up to nine.
- Benchmarks: the GPU as a share of the Mac in the README (Basemark Web 3.0
  and WebGL Aquarium in Chrome). `bench.sh` runs Basemark too, and Geekbench's
  GPU test with Metal and OpenCL on the Mac. No VM can run Geekbench's GPU
  test: its Linux ARM preview has none, and no VM offers Vulkan or OpenCL.

## 2.5.0

- Prebuilt VMs for Parallels, UTM and VMware Fusion: `omacvm build` asks
  whether to build the VM here or download one (`--prebuilt`). The VM is
  ready in about 4 to 6 minutes instead of 30 to 70. See
  [docs/prebuilt.md](docs/prebuilt.md).
- The build picks the fastest Arch Linux ARM mirrors first, so a slow
  default mirror no longer stops it (#24).

## 2.4.1

- With Omanotch, notifications sit right under the notch strip.
- VMs on Arch Linux ARM's own kernel have their snapshots in GRUB again, and
  `omacvm check` says when they go missing.
- Two VMs in one app: Cmd shortcuts and swipes go only to the VM in front.
- The memory-optimized kernel: turning it off really goes back to the stock
  kernel; its build output goes to a log.

## 2.4.0

- Shift and the brightness keys set the Mac's keyboard light, with Omarchy's
  own popup; Option takes small steps.
- Longer battery life: the Gestures daemon, the Gestures helper, the
  clipboard, the Parallels display sync and the Bridge no longer wake up for
  nothing. `omacvm update` is much faster.
- Safer: OmacVM remembers each VM's SSH host key (after a rebuild:
  `omacvm apply --vm NAME --reset-host-key`); `omacvm update` sends the
  Bridge's key only to VMs it set up; Gestures talks only to VMs that know
  the Bridge's token; the clipboard from the VM follows no links; names are
  checked or quoted everywhere.
- Fixes: `omacvm update` goes on past a VM it can't reach; `--vm-dir` works
  with spaces and relative paths; your own lines in `input.lua` survive an
  update; UTM applies a new display mode at the next restart.

## 2.3.1

- New VMs get the Mac's clock (#11); builds no longer hang at "Waiting for
  SSH" with several keys in ssh-agent (#10); Canadian English keyboards get
  the English layout (#13).
- The README compares all four ways: speed, browser graphics, YouTube 4K,
  power and battery hours.

## 2.3.0

- The Mac's clock in Omarchy's bar, at the far right, in the Mac's format
  (`omacvm disable mac-clock` puts it back).
- Chromium, Chrome, Brave and Firefox draw on the GPU on every route.
- Older Parallels VMs use every display in full screen.
- Scroll momentum works in Brave; tools to measure power, battery life and
  video decoding.

## 2.2.2

- UTM: WebGL reads back right; every buffer is drawn without multisampling
  (no WebGL antialiasing on UTM).

## 2.2.1

- UTM: Chrome and the other Chromium browsers use the GPU. OmacVM sets UTM's
  default renderer, and `omacvm check` tells you if it isn't set.

## 2.2.0

- VMware Fusion is the third way, next to Parallels and UTM: every display
  in the macOS arrangement, the GPU, and all of OmacVM's features. OmacVM
  builds Hyprland with a fix for Fusion's black screen and builds VMware
  Tools. See [docs/routes/vmware-fusion.md](docs/routes/vmware-fusion.md).
- Choose where the VM goes (`--vm-dir`, also on an external drive).
- New Parallels VMs use every display in full screen; the slide between
  workspaces is back after a three-finger swipe; Omanotch repairs itself if
  its first build failed.

## 2.1.1

- The Mac's wallpaper keeps following Omarchy's theme after many theme
  switches (systemd no longer stops the watcher).

## 2.1.0

- The Mac's Bluetooth in Omarchy's Bluetooth panel: paired devices with
  battery levels, connect and disconnect, Bluetooth on and off, forget a
  device. Pairing opens the Mac's Bluetooth settings.

## 2.0.2

- Builds with scroll momentum no longer stop in the last step.
- macOS's permission prompts are explained when they appear; the Swift
  compiler is checked before the build starts.
- VM names are unique across Parallels and UTM.
- `omacvm check` points out a menu bar that is always shown; the setup draws
  right without a UTF-8 locale.

## 2.0.1

- Fresh Macs: Xcode's command line tools come through macOS's software
  update; free space is measured like Finder does (30 GB to build); home
  folders with spaces work; long build steps show a live status line.

## 2.0.0

- `omacvm`: one command to build, switch features, update and check, put on
  your PATH by the one-line installer.
- A setup that installs what is missing (Xcode's tools, Homebrew, Parallels
  or UTM 5) and asks its questions as screens.
- macOS-native scroll momentum (experimental).
- Every feature can be switched on an existing VM; each VM tells Gestures
  what it wants.
- Night Shift and True Tone in the bar; `--json` and exit codes for coding
  agents; Mac mini, iMac and Studio with a Magic Trackpad.

## 1.1.0

- `./build.sh` asks first: Parallels or UTM, resources, features, user, then
  a summary. The VM remembers the choices; `./apply.sh` keeps them.
- The memory-optimized kernel is opt-in.
- OmacVM's own icon; everything but the entry points moved to `src/`.

## 1.0.0

- First release: one command builds an Omarchy VM in Parallels Desktop or
  UTM, with the Mac's Wi-Fi, audio, media keys, Night Shift and True Tone,
  trackpad gestures, Retina displays at 120 Hz, the clipboard both ways and
  the keyboard layout from the Mac. `./check.sh` checks every feature.
