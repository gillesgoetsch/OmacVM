# Prebuilt VMs

`omacvm build` can make the VM on your Mac (30 to 70 minutes, mostly
downloads and Omarchy's install) or download one that is already built
(faster). Both end the same way: your user, your password, your features,
OmacVM on the Mac and in the VM.

| | Parallels | UTM | VMware Fusion | OmacVM.app |
|---|---|---|---|---|
| Download | 3.7 GB | 3.5 GB | 6.0 GB | 3.6 GB (test image) |
| `omacvm build --prebuilt` (measured, M4 Max, fast connection) | 6 min | about 4 min | about 5 min | 3 min plus the download (test image, see below) |
| `omacvm build` (building it here) | 30-70 min | 30-70 min | 45-85 min | 10-30 min |

The Fusion image is larger: it carries Hyprland with OmacVM's vmwgfx fix and
VMware Tools, both built in the VM, and their build tools.

The OmacVM.app numbers are test numbers: an OmacVM 2.7.0 test image, copied
from a local folder (no download), and without the step that builds the Mac
helpers (Bridge, Gestures), which every app user gets. They will be replaced
with measured numbers when the first image for the app is released.

## Using one

In OmacVM.app, the setup asks "How": "Download a prebuilt VM" or "Build
it here" (the choice is there when the release has an image for the app).
From the terminal:

```bash
omacvm build                       # asks: "Build it yourself" or "Download a prebuilt VM"
omacvm build --vm-type utm --prebuilt
omacvm build --vm-type app --prebuilt
OMACVM_PASSWORD=… omacvm build --yes --vm-type fusion --prebuilt --user anna --feature scroll-momentum=on
```

What happens:

1. The questions are the same as for a build: app, resources, folder,
   features, user, password.
2. The image for this app is downloaded from a GitHub release whose tag
   starts with `prebuilt-` (see below which one), in parts of at most 1.9 GB, each checked against the
   manifest's SHA-256. Interrupted downloads resume. The parts go to
   `~/Library/Caches/omacvm/prebuilt/` (OmacVM.app with its VMs folder on
   another drive: `.downloads/prebuilt/` in that folder) and are deleted
   after unpacking (`OMACVM_PREBUILT_KEEP=1` keeps them).
3. The VM is unpacked into the usual place (`--vm-dir` and the folder question
   work as for a build), gets a new VM id, new MAC addresses and your name,
   CPUs, memory and disk size.
4. A small seed disk (ISO, label `OMACVM-SEED`) holds your answers: user name,
   full name, the password hash (`openssl passwd -6`), the Mac's SSH key for
   root (`~/.ssh/omacvm.pub`), hostname, keyboard, timezone, language, display
   mode, the Mac's network for SSH. It is attached before the first boot.
5. In the VM, `omacvm-firstboot.service` runs once before the login screen:
   it grows the disk, creates your user from the image's home template, sets
   the rest from the seed and disables itself. SSH host keys and the machine
   id are new.
6. On the Mac: `omacvm apply` with your features (Parallels: also Parallels
   Tools from your own Parallels Desktop). Then the VM shuts down once, the
   seed is detached and deleted, and the VM starts again.

OmacVM takes the newest image with its own major version and a version up to
its own (OmacVM 2.5.0 uses a 2.4.0 image when there is no newer one): the
first `omacvm apply` brings the VM side to the current version anyway. With no
such image (or no connection), `--prebuilt` builds the VM here instead and
says so (OmacVM.app too, and an OmacVM.app from before prebuilt images).

OmacVM.app's image is only the disk (`Omarchy/disk.img`, raw, sparse): the
app keeps its settings in `vm.env` itself. Its script
(`app/scripts/prebuilt-vm.sh`, the app runs it as it runs `create-vm.sh`)
downloads and checks the parts, unpacks the disk into the VM's folder, grows
it, makes fresh firmware variables and the seed, and runs the first boot
without a window, with the seed as a second disk. Then `omacvm apply` as
after a build, the VM shuts down and the seed is deleted (also when anything
fails). A run that fails before the VM is ready also deletes the disk and
firmware variables it made, so building again starts over.

Before the download it checks for free space (the parts plus the unpacked
disk plus 2 GB). Only `Omarchy/disk.img` is taken from the archive, and only
as a plain file (not a link). The manifest's values are checked before use,
and the first boot's log is cut to printable text before the app or the
terminal shows it. The password is hashed on the Mac (`src/prebuilt/sha512crypt.py`,
the same `$6$` hash as `openssl passwd -6`; macOS's own openssl has no
`-6` and the app needs no Homebrew). The app only ever starts the finished
VM.

Images from before 2.6.0 have no sound card on UTM and Fusion: the build
adds one while the VM is off, after the seed is gone.

## Downloading one by hand

Each release has, per app, `omacvm-prebuilt-VERSION-ROUTE.tar.zst.part-aa`,
`-ab`, …, a manifest (`.json`) with its signature (`.json.sig`), SHA-256 sums
(`.sha256`) and the package list. `omacvm build --prebuilt` and the app only
use an image whose manifest is signed with OmacVM's release key (from 3.0.0;
[release-keys.md](release-keys.md)) and take each part's SHA-256 from it. By
hand, check the signature with `python3 src/release/keys.py verify
prebuilt-manifest omacvm-prebuilt-VERSION-ROUTE.json`.

```bash
shasum -a 256 -c omacvm-prebuilt-2.6.0-utm.sha256
cat omacvm-prebuilt-2.6.0-utm.tar.zst.part-* | zstd -dc --long=27 | tar -xSf -
```

That gives `Omarchy.pvm`, `Omarchy.utm` or `Omarchy.vmwarevm` (OmacVM.app's
image gives `Omarchy/disk.img`: use it through the app or
`omacvm build --vm-type app --prebuilt`). Open it with
its app (Parallels and Fusion ask whether you moved or copied it: say
copied). On its first boot the VM asks on its console for your user name,
password, keyboard layout and timezone, then shows the login screen.

Then, on the Mac, let OmacVM in and add its Mac side and features:

```bash
omacvm apply --vm Omarchy
```

The first time it stops (exit 3) with one command to run in the VM's
terminal: it adds OmacVM's SSH key for root, from the Mac's network only. Run
it, then `omacvm apply --vm Omarchy` again. On Parallels this also installs
Parallels Tools. A hand-made VM keeps the image's 64 GB disk; to grow it,
resize the disk in the app and reboot (the VM grows its file system on the
first boot only).

## How images are made

One script per app, on a Mac with that app:

```bash
src/prebuilt/make-image.sh parallels           # build, generalize, package
src/prebuilt/make-image.sh app                 # OmacVM.app's (headless, from this checkout)
src/prebuilt/make-image.sh parallels upload    # to the pre-release prebuilt-VERSION (OMACVM_PREBUILT_TAG=…)
src/prebuilt/make-image.sh parallels clean     # delete the image VM
```

- **build**: `omacvm build --image`, a normal build with the placeholder user
  `omacvmuser`, timezone UTC, keyboard `us`, `en_US.UTF-8`, a 64 GB disk, the
  default features without Omanotch and the battery (both depend on the Mac),
  and nothing of the Mac: no Bridge token,
  no Mac side, no Parallels Tools.
- **generalize** (`src/prebuilt/guest/generalize.sh`, in the VM):
  - the user goes; its home becomes the template
    `/var/lib/omacvm/prebuilt/home` without caches, shell histories,
    keyrings, SSH and GnuPG folders, the Bridge token, logs and Trash
  - root's `authorized_keys`, SSH host keys, `/etc/machine-id` (left empty),
    NetworkManager connections and its secret key, systemd's random seed and
    credential secret, snapper snapshots, the journal and logs, the pacman
    cache, temporary files, the build's sudo rule
  - the first-boot service is installed
  - a search for the build Mac's user name, full name, computer name, git
    name and e-mail, every SSH public key in `~/.ssh` and the Bridge token in
    `/etc /root /home /var /opt /srv /usr/local /boot`: any hit stops it
  - free space is overwritten with zeros (a no-copy-on-write file, so btrfs
    does not compress it away) and trimmed, then the VM powers off
- **OmacVM.app** (`make-image.sh app`): the build is the app's own
  `app/scripts/create-vm.sh` from the checkout (its QEMU runtime built with
  `app/scripts/build-app.sh`), with `OMACVM_CREATE_IMAGE=1`: the same
  answers, nothing of the Mac (no Bridge token, no Mac helpers). The VM
  lives in the output folder (`vm/`), not in the app's VMs folder, runs
  without a window and cannot reach the Mac's helpers
  (`OMACVM_HOST_PORTS=` empty). The package is `disk.img` alone, copied
  without its zeroed space; no firmware variables (GRUB is also on the
  disk's fallback path, `\EFI\BOOT\BOOTAA64.EFI`).
- **package**: the disk is compacted (`prl_disk_tool compact`,
  `vmware-vdiskmanager -k`; UTM's qcow2 stays sparse), the bundle is copied
  without logs, the Parallels `VM.app` stub, Mac paths, shared folders, ids or
  MAC addresses, checked for this Mac's home path and user name, then
  `tar | zstd -19 --long=27`, split into 1.9 GB parts, with a manifest
  (OmacVM and Omarchy versions, part sizes and SHA-256) and the package list.

`OMACVM_HEADLESS=1` starts the VMs without a window (Parallels Pro or
trial, UTM, Fusion). Run it from a copy of the checkout that nobody edits
while it runs: bash reads scripts as it goes.

Testing an image before it is uploaded:
`OMACVM_PREBUILT_SOURCE=~/Library/Caches/omacvm/prebuilt-out/utm omacvm build --vm-type utm --prebuilt`.
OmacVM.app's, without the app and the Mac's helpers (a VM folder with a
`vm.env` as the app writes it):
`printf '%s\n' PASSWORD | OMACVM_PREBUILT_SOURCE=…/prebuilt-out/app OMACVM_CREATE_NO_MAC=1 OMACVM_HOST_PORTS= app/scripts/prebuilt-vm.sh FOLDER`.

## Licences

The images contain Arch Linux ARM packages (GPL, LGPL, MIT, BSD and others),
Omarchy (MIT) and its packages, and OmacVM (MIT). The release has
`SOURCES.md` (where each part's source is) and the package list with each
package's licence. There are no Parallels Tools and no VMware or Parallels
program files in them; the Fusion image's open-vm-tools (LGPL) are built
from Arch's recipe, its Hyprland (BSD) with OmacVM's patch.
