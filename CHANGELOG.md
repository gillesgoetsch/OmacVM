# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 3.0.5 (unreleased)

- With OmacVM.app and the test app OmacVM Test.app on one Mac, each one's
  Gestures took the other app's VMs as its own too: both captured the
  trackpad and acted on Ctrl+Option+Esc. Each Gestures now takes only the
  VMs of its own app (told by the VM's code signature), as the Bridge
  does since 3.0.1.
- Touch ID is no longer marked experimental (control centre, `omacvm
  features`, README): it is a regular feature, still off until you turn it on.
- Omanotch: when something moved the hidden NOTCH output after it was in
  place (a Hyprland config reload with an older rule, another `hyprctl
  eval`), the strip beside the notch could stay wrong for up to 30 s.
  notchcast now puts it back on its next look (about 2 s). A rule Hyprland
  does not take is sent again with growing waits, at most every 30 s once
  it keeps failing, and never more than 4 times in 30 s.

- A Mac without Xcode's Command Line Tools: OmacVM.app no longer makes macOS
  ask to install them. Before, the setup screen's look for a prebuilt VM ran
  python3 and opened macOS's "install the command line developer tools?"
  window as the app opened, Build refused until they were installed, and
  the control centre's jobs and `omacvm vms` asked again (a Swift script
  for the notch). The app now carries a python3, Omanotch and those Swift
  programs ready made, so its whole route runs without them (and without
  Homebrew). UTM, VMware Fusion and Parallels still need them, and
  `omacvm build` asks for them only there.

- OmacVM.app on Macs with little memory (8 GB): an app in the VM that takes
  too much graphics memory (a browser with big WebGL pages) no longer turns
  the whole VM black. The last part of the graphics memory guard (512 MB on
  8 GB, 1 GB on 16 GB, 2 GB from 32 GB) is kept for the desktop (Hyprland,
  the bar and the lock screen): the app past its share, or the app that
  wants more while macOS is short of memory, loses its own GPU context, and
  the VM shows a note that says so. Before, whichever asked next lost it, often Hyprland,
  and the app then restarted the desktop, closing every app. When the
  desktop is still lost, the window and the note say why (the guard,
  macOS short of memory, or a graphics failure).

- OmacVM.app: when the drive with a running VM drops off (unplugged, a
  loose cable, ejected by force), the app stops the VM at once and its
  window says "The drive with your VMs (NAME) is gone. Reconnect it and
  start the VM again." The VM shows as unavailable until the drive is back,
  then as ready again. Before, QEMU kept running on files that were gone.
  A VMs folder whose drive was not plugged in at launch shows up by itself
  once it is.

- OmacVM.app's VM window is compact and fits a 13-inch MacBook without
  scrolling (it was up to about 900 points tall); on a smaller screen it stops at
  the screen and scrolls. Settings sit in two columns, on/off settings are
  switches, and the long explanations moved behind an (i). Disk is one row
  with **Change…**. USB devices now have their own switch, off by default
  (a VM that already had devices keeps them).

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
