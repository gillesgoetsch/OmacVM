# Build and use a VM, step by step

The short version is in the [README](../README.md#build-a-vm). This page has
every step of the build, what to do after it, and the everyday commands in
full.

## What `omacvm build` asks

```bash
omacvm            # or: omacvm build
```

It first shows what it found on your Mac (Xcode's command line tools,
Homebrew, OmacVM.app, UTM, VMware Fusion, Parallels) and installs what is
missing, after asking. Then a few screens (↑/↓ to choose, space to switch,
Return to confirm):

1. **The app: OmacVM.app, UTM, VMware Fusion or Parallels**, with a short
   comparison. If the app isn't installed yet (or UTM is older than 5), it
   offers to install it (OmacVM.app: it downloads it; UTM: with Homebrew), or
   tells you how (Fusion: a free download from Broadcom, after signing in). A
   fresh Parallels without a licence yet asks which edition you plan on (the
   trial is Pro).
2. **Build it yourself or download a prebuilt VM.** Building takes 30 to 70
   minutes and fetches everything from Arch Linux ARM and omarchy-mac. The
   prebuilt VM is the same build, made by OmacVM without any user in it and
   brought to your OmacVM version on the way: a download of 3.5 to 6 GB, then
   a few minutes (6 minutes in all for Parallels on a fast connection). Either
   way you get your own user, password, features, keyboard and timezone. You
   can also download a prebuilt VM by hand from the
   [releases](https://github.com/gillesgoetsch/omacvm/releases) and open it in
   its app: it asks for your user and password on its first boot. `--prebuilt`
   or `--build` for scripts; details, what is in the images and how they are
   made: [prebuilt.md](prebuilt.md). OmacVM.app offers the same choice in its
   own setup once a release has an image for it.
3. **How much of the Mac the VM gets**: Low, Balanced, High or Best, shown as
   CPUs and memory, or Custom. Best leaves macOS and the GPU a buffer of a
   quarter of the memory, at least 8 GB. On Parallels Standard OmacVM stays
   within its limits ([Parallels](routes/parallels.md)).

   Then **where the VM goes**: the app's own folder, or any folder you pick,
   an external drive for example (APFS or Mac OS Extended; Parallels and
   Fusion; UTM keeps its VMs in its own library, OmacVM.app in the folder set
   in the app). With `--vm-dir PATH` for scripts.
4. **Features**, one checklist with the recommended ones on:

   | | Default |
   |---|---|
   | OmacVM Bridge: the Mac's Wi-Fi, Bluetooth, audio, Night Shift and media keys in Omarchy | on |
   | Omarchy's wallpaper on the Mac too | on |
   | Trackpad gestures in Omarchy, in full screen (macOS's own swipes are off then; ⌃⌥ Esc takes you back to macOS) | on |
   | macOS-native scroll momentum *(experimental)*: a trackpad's scrolling only, mice scroll one to one | on |
   | Omanotch, on a MacBook with a notch | on |
   | The Mac's battery: its charge and charging state in Omarchy's bar (Parallels shows it itself) | on with a battery, not on Parallels |
   | The Mac's clock: at the far right of the bar, in your Mac's menu bar format | on |
   | The Mac's camera as *Mac Camera*, on only while a Linux app uses it (UTM and Fusion: through OmacVM Bridge, also with the Bridge off) | on |
   | External display brightness: the brightness keys (and Omarchy's own) set the external display the VM is on, over DDC/CI (needs the Bridge) | on |
   | Screensaver and lock disabled: Omarchy's own screensaver and lock after idle stay off, the Mac's lock protects the VM | off |
   | Autologin | off |
   | Memory-optimized kernel: Arch Linux ARM's kernel rebuilt with transparent huge pages and MGLRU (its own has neither), for memory-heavy work; a kernel build in the VM: about 10 minutes with 16 CPUs, over an hour with 4 | off |
   | The OmacVM control centre: `omacvm` in Omarchy, also in the Omarchy menu and the bar | on |

5. **Your user name, full name and password.** Omarchy's own first-boot setup
   is not used.

Then it shows a summary and starts: 30 to 70 minutes in numbered steps
(OmacVM.app 10 to 30 minutes; VMware Fusion about 15 minutes more: it builds
Hyprland with a fix), mostly downloads and Omarchy's install, with the whole log in
`~/Library/Logs/omacvm-build-*.log`. A VM window opens on the way: that is the
temporary installer, leave it alone. Parallels Desktop may also show its own
windows on the way (sign in, continue the trial): click through them, the
build waits.

`omacvm build --dry-run` asks everything and stops at the summary;
`omacvm build --help` lists the options for unattended builds. Your keyboard
layout, timezone and language come from the Mac.

## Behind a proxy

When the Mac goes through a proxy, the build passes it on to the VM; nothing
changes without one.

- **Where it comes from**: `http_proxy`, `https_proxy`, `all_proxy` and
  `no_proxy` (either case) in the terminal you build from, else the fixed
  proxies in System Settings > Network > Details > Proxies (Web, Secure web,
  SOCKS, and the bypass list). `scutil --proxy` shows what macOS has.
  `OMACVM_PROXY=off omacvm build ...` builds without it.
- **In the VM**: while Omarchy installs, the same variables in
  `/etc/environment.d/90-omacvm-proxy.conf` (the desktop) and
  `/etc/profile.d/omacvm-proxy.sh` (shells); `/etc/sudoers.d/05-omacvm-proxy`
  makes sudo keep them. The build's pacman, git and the Omarchy installer use
  them. After the install `/etc/omacvm/proxy.env` keeps them and the VM uses
  them only where the network it is on reaches the proxy, worked out at each
  login (`omacvm-proxy-env` prints what a login gets, and why a proxy is left
  out; `omacvm check` says it too). Delete `/etc/omacvm/proxy.env` to stop.
- **A proxy on the Mac's 127.0.0.1** (Clash, V2Ray, Surge and the like):
  OmacVM.app's VMs reach it as `10.0.2.2:<port>` on QEMU's network; the app
  lets that port through at the build and at every start while the Mac
  still uses that proxy (`qemu.log`: "Mac proxy"). The fast network cannot
  reach the Mac's 127.0.0.1: there the VM uses `192.168.77.1:<port>` if the
  proxy accepts LAN connections (Clash: "Allow LAN"), else no proxy, and
  goes out through the Mac (and its VPN or TUN mode, if one is on) directly.
  Parallels, UTM and Fusion cannot reach the Mac's 127.0.0.1 either: let the
  proxy accept LAN connections and set `http_proxy`/`https_proxy` to the
  Mac's address before building.
- **Not read**: proxy auto-config (PAC) files and automatic discovery (WPAD).
  The build says so; set `http_proxy` and `https_proxy` in the terminal.
- **Flaky connections**: while Omarchy installs, pacman and `git clone` try
  a failed download again (3 tries, "Operation too slow" included).
- **Proxy changed later**: edit `/etc/omacvm/proxy.env` in the VM (the
  Mac's 127.0.0.1 is `10.0.2.2` in it), then log in again. The app follows a
  new port on the Mac by itself from the next start.

## After the build

Once, on the Mac:

1. **Allow the prompts**: Location Services for *OmacVM Bridge* (Wi-Fi
   names), Bluetooth for *OmacVM Bridge*, Accessibility for *OmacVM Bridge*
   and *OmacVM Gestures*, Input Monitoring for *OmacVM Gestures* (Omanotch
   needs none). The camera
   is asked for the first time a Linux app uses it: for *OmacVM Bridge* (UTM,
   Fusion), *OmacVM* (the app) or *Parallels Desktop*. The microphone belongs
   to the VM's app: UTM asks the first time, OmacVM.app when it starts the VM;
   for Parallels Desktop and VMware Fusion check System Settings › Privacy &
   Security › Microphone, or the VM records silence or nothing. With the
   Bridge off but the camera on (UTM, Fusion), *OmacVM Bridge* is still
   installed for the camera and asks for Location Services, Accessibility and
   Bluetooth too: say no, the camera does not need them.
2. **Parallels: let Cmd reach Omarchy.** One Parallels setting:
   [Parallels](routes/parallels.md#after-the-build-let-cmd-reach-omarchy).
3. **UTM: keep UTM in the foreground app list** (started from the Dock or
   Spotlight): [UTM](routes/utm.md#keep-utm-in-the-foreground).

Then put the VM in full screen: see
[full screen and ⌃⌥ Esc](features.md#full-screen-and-the-escape-keys).

## Switch features, on any VM

```bash
omacvm features                 # see them, switch them (↑/↓, space, Return)
omacvm disable scroll-momentum  # or straight away
omacvm disable gestures --vm "Omarchy ARM"
```

Or in Omarchy itself: `omacvm` (or OmacVM in the Omarchy menu, or the OmacVM
item in the bar) opens the control centre. From the Mac, *Features…* in
OmacVM.app's menu (beside the Apple menu, while the VM runs) or
`omacvm features --vm NAME --in-vm` opens it on the VM's desktop (one
window, brought to the front if it is open already; someone must be logged
in there). Space switches the feature under
the cursor; the Mac does the same as `omacvm enable/disable` there, and macOS
still asks for its permissions on the Mac. `r` repairs the feature under the
cursor (only that one). If a change fails, the VM goes back to what it had
and the control centre says what to try next. A VM from before the control
centre gets it with its next `omacvm apply` or `omacvm update` (one question,
default yes; `--yes` takes the default without asking).

Every feature can be switched on or off later, one at a time, and the VM keeps
your choices across updates. OmacVM installs what a feature needs on the Mac
too, and switching one takes well under a minute (the memory-optimized kernel
is a kernel build: about 10 minutes with 16 CPUs, over an hour with 4). A
feature that needs another brings it along: the scroll momentum needs the trackpad gestures, the wallpaper needs
the Bridge.

Off means off: nothing of the feature keeps running in the VM, the VM no
longer talks to the Mac for it, OmacVM.app gives that VM nothing of the Mac
for it from its next start, and `omacvm check` says "off".
On OmacVM.app the same goes for turning one on: the VM gets its link to
the Mac from its next start (shut it down and start it again).

**Already have an Omarchy VM** you installed yourself from omarchy-mac?
`omacvm apply --vm NAME` adds OmacVM to it. If OmacVM cannot get in yet, it
prints the one command to run in the VM's terminal first (it lets OmacVM in
with its own SSH key, from the Mac only).

## Graphics: OpenGL, Vulkan or Automatic (OmacVM.app)

```bash
omacvm graphics --vm Omarchy            # the setting, and what it gives on this Mac
omacvm graphics --vm Omarchy vulkan     # opengl, vulkan or auto
```

Also in the app (setup and the VM's window) and on the control centre's
Graphics row. It applies at the VM's next start. Automatic picks the faster
path on this Mac; Vulkan adds Vulkan for Vulkan apps next to OpenGL
([details](routes/app.md)).

## Change CPUs and memory

```bash
omacvm resources --vm Omarchy                    # what it has, and what each tier gives
omacvm resources --vm Omarchy --resources high   # low, balanced, high or best
omacvm resources --vm Omarchy --cpus 8 --memory-gb 24
```

The same tiers and limits as the build: up to this Mac's CPUs and memory, and
within the Parallels licence. Parallels, UTM and VMware Fusion change a
stopped VM only (shut it down first; a suspended one too); a change applies on
the VM's next start. OmacVM.app has the same picker in its window, below the
VM's name. A name used in two apps needs `--vm-type parallels|utm|fusion|app`.

## Update

```bash
omacvm update
```

Pulls the newest OmacVM (when your copy has no local changes), updates the Mac
side and every running VM that has OmacVM, keeping each VM's choices. Stopped
VMs are listed; `omacvm update --vm NAME` starts one and updates it.

In the control centre, `U` shows what an update changes, feature by feature,
and installs it (the Mac and that VM). The Mac checks once a week; `s` there
turns the checks and the update notice off entirely: no marks and no prompts,
and an update is installed only right after `c` checked again. (Releases do
not carry their signed update list yet: until then the control centre says
"no release key yet" and `omacvm update` on the Mac is the way.)

The VM's own system (Omarchy and its Arch packages) is a separate update:
`o` on the same screen, or `omacvm update-system` in the VM. It runs
`omarchy update` in its own window and then checks that the graphics still
start, before you restart. Do not run `pacman -Sy` alone: a partial update
can leave the VM at a black screen.

## Check

```bash
omacvm check            # --vm NAME for another VM
```

Goes through every feature on the Mac and in the running VM (permissions, the
Bridge, the bar widgets, gestures, scroll momentum, clipboard and pointer, the
battery, kernel, memory, Omanotch) and prints `ok` / `FAIL` with what to do
about each failure. It only reads; nothing is changed. `omacvm vms` lists your
VMs and their OmacVM version.
