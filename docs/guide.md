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
   made: [prebuilt.md](prebuilt.md). OmacVM.app has no prebuilt VMs: it always
   builds its own.
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
   | Trackpad gestures in Omarchy, in full screen (macOS's own swipes are off then; ⌃⌥⌘ Esc gives them back) | on |
   | macOS-native scroll momentum *(experimental)* | off |
   | Omanotch, on a MacBook with a notch | on |
   | The Mac's battery: its charge and charging state in Omarchy's bar (Parallels shows it itself) | on with a battery, not on Parallels |
   | The Mac's clock: at the far right of the bar, in your Mac's menu bar format | on |
   | The Mac's camera as *Mac Camera*, on only while a Linux app uses it (UTM and Fusion: through OmacVM Bridge, also with the Bridge off) | on |
   | Omarchy's own screensaver and lock after idle (off: the Mac's lock protects the VM) | on |
   | Autologin | off |
   | Memory-optimized kernel: Arch Linux ARM's kernel rebuilt with transparent huge pages and MGLRU (its own has neither), for memory-heavy work; adds about 10 minutes to the build | off |

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
[full screen and ⌃⌥⌘ Esc](features.md#full-screen-and-the-escape-keys).

## Switch features, on any VM

```bash
omacvm features                 # see them, switch them (↑/↓, space, Return)
omacvm enable scroll-momentum   # or straight away
omacvm disable gestures --vm "Omarchy ARM"
```

Every feature can be switched on or off later, one at a time, and the VM keeps
your choices across updates. OmacVM installs what a feature needs on the Mac
too, and switching one takes well under a minute (the memory-optimized kernel
takes about 10 minutes the first time). A feature that needs another brings it
along: the scroll momentum needs the trackpad gestures, the wallpaper needs
the Bridge.

**Already have an Omarchy VM** you installed yourself from omarchy-mac?
`omacvm apply --vm NAME` adds OmacVM to it. If OmacVM cannot get in yet, it
prints the one command to run in the VM's terminal first (it lets OmacVM in
with its own SSH key, from the Mac only).

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

## Check

```bash
omacvm check            # --vm NAME for another VM
```

Goes through every feature on the Mac and in the running VM (permissions, the
Bridge, the bar widgets, gestures, scroll momentum, clipboard and pointer, the
battery, kernel, memory, Omanotch) and prints `ok` / `FAIL` with what to do
about each failure. It only reads; nothing is changed. `omacvm vms` lists your
VMs and their OmacVM version.
