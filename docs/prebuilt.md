# Prebuilt VMs

`omacvm build` can make the VM on your Mac (10 to 30 minutes, mostly
downloads and Omarchy's install) or download one that is already built
(faster: a 3.7 GB download, then about 1.5 minutes). Both end the same way:
your user, your password, your features, OmacVM on the Mac and in the VM.

The 1.5 minutes are for `prebuilt-3.0.8`, copied from a local folder: 90 s
on a MacBook Pro M4 Max, 94 s on a MacBook Air M2 with the Mac helpers
(Bridge, Gestures). The download comes on top.

## Using one

In OmacVM.app, the setup asks "How": "Download a prebuilt VM" or "Build
it here" (the choice is there when the release has an image). From the
terminal:

```bash
omacvm build                       # asks: "Build it yourself" or "Download a prebuilt VM"
omacvm build --prebuilt
OMACVM_PASSWORD=… omacvm build --yes --prebuilt --user anna --feature scroll-momentum=on
```

What happens:

1. The questions are the same as for a build: resources, features, user,
   password.
2. The image is downloaded from a GitHub release whose tag starts with
   `prebuilt-` (see below which one), in parts of at most 1.9 GB, each
   checked against the manifest's SHA-256. Interrupted downloads resume. The
   parts go to `~/Library/Caches/omacvm/prebuilt/` (with the VMs folder on
   another drive: `.downloads/prebuilt/` in that folder) and are deleted
   after unpacking (`OMACVM_PREBUILT_KEEP=1` keeps them).
3. The disk is unpacked into the VM's folder and grown to your disk size;
   the VM gets fresh firmware variables, your name, CPUs and memory.
4. A small seed disk (ISO, label `OMACVM-SEED`) holds your answers: user name,
   full name, the password hash, the Mac's SSH key for root
   (`~/.ssh/omacvm.pub`), hostname, keyboard, timezone, language, display
   mode, the Mac's network for SSH. It is attached as a second disk for the
   first boot, which runs without a window.
5. In the VM, `omacvm-firstboot.service` runs once before the login screen:
   it grows the disk, creates your user from the image's home template with
   Omarchy's default keyring (no password, as a full build has; the template
   has no keyrings), sets the rest from the seed and disables itself. SSH host keys and the machine
   id are new.
6. On the Mac: `omacvm apply` with your features. Before the features, once, it
   brings the VM's system up to date with Omarchy's own update
   (`src/prebuilt/guest/first-update`: `omarchy update`, then the graphics
   test), and restarts the VM when that brought a new kernel. The image's
   package list is as old as the image, and Arch Linux ARM's mirrors keep
   only the newest version of each package: without the update, a feature
   that installs a package would not find it. Then the VM shuts down and the
   seed is deleted (also when anything fails). A run that fails before the
   VM is ready also deletes the disk and firmware variables it made, so
   building again starts over.

OmacVM takes the newest image with its own major version and a version up to
its own (OmacVM 2.5.0 uses a 2.4.0 image when there is no newer one): the
first `omacvm apply` brings the VM side to the current version anyway. With no
such image (or no connection), `--prebuilt` builds the VM here instead and
says so (an OmacVM.app from before prebuilt images too).

The image is only the disk (`Omarchy/disk.img`, raw, sparse): the app keeps
its settings in `vm.env` itself. Its script (`app/scripts/prebuilt-vm.sh`,
the app runs it as it runs `create-vm.sh`) does the steps above.

Before the download it checks for free space (the parts plus the unpacked
disk plus 2 GB). Only `Omarchy/disk.img` is taken from the archive, and only
as a plain file (not a link). The manifest's values are checked before use,
and the first boot's log is cut to printable text before the app or the
terminal shows it. The password is hashed on the Mac (`src/prebuilt/sha512crypt.py`,
the same `$6$` hash as `openssl passwd -6`; macOS's own openssl has no
`-6`). The app only ever starts the finished VM.

## Downloading one by hand

Each release has `omacvm-prebuilt-VERSION-app.tar.zst.part-aa`, `-ab`, …, a
manifest (`.json`) with its signature (`.json.sig`), SHA-256 sums
(`.sha256`) and the package list. `omacvm build --prebuilt` and the app only
use an image whose manifest is signed with OmacVM's release key (from 3.0.0;
[release-keys.md](release-keys.md)) and take each part's SHA-256 from it. By
hand, check the signature with `python3 src/release/keys.py verify
prebuilt-manifest omacvm-prebuilt-VERSION-app.json`.

```bash
shasum -a 256 -c omacvm-prebuilt-3.0.8-app.sha256
cat omacvm-prebuilt-3.0.8-app.tar.zst.part-* | zstd -dc --long=27 | tar -xSf -
```

That gives `Omarchy/disk.img`: use it through the app or
`omacvm build --prebuilt`.

## How images are made

```bash
src/prebuilt/make-image.sh app                 # build, generalize, package (headless, from this checkout)
src/prebuilt/make-image.sh app upload          # to the pre-release prebuilt-VERSION (OMACVM_PREBUILT_TAG=…)
src/prebuilt/make-image.sh app clean           # delete the image VM
```

- **build**: the app's own `app/scripts/create-vm.sh` from the checkout (its
  QEMU runtime built with `app/scripts/build-app.sh`), with
  `OMACVM_CREATE_IMAGE=1`: the placeholder user `omacvmuser`, timezone UTC,
  keyboard `us`, `en_US.UTF-8`, a 64 GB disk, the default features without
  Omanotch and the battery (both depend on the Mac), and nothing of the Mac
  (no Bridge token, no Mac helpers). The VM lives in the output folder
  (`vm/`), not in the app's VMs folder, runs without a window and cannot
  reach the Mac's helpers (`OMACVM_HOST_PORTS=` empty).
  `OMACVM_PREBUILT_APP=/path/OmacVM.app` (absolute, the checkout's
  version): the build and the start use that app's own scripts and runtime
  (its `Contents/Resources`), as the app makes a person's VM. `release.sh`
  sets it for an app built on another Mac, which leaves no runtime build in
  the checkout.
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
- **package**: `disk.img` alone, copied without its zeroed space; no
  firmware variables (GRUB is also on the disk's fallback path,
  `\EFI\BOOT\BOOTAA64.EFI`). Checked for this Mac's home path and user
  name, then `tar | zstd -19 --long=27`, split into 1.9 GB parts, with a
  manifest (OmacVM and Omarchy versions, part sizes and SHA-256) and the
  package list.

Run it from a copy of the checkout that nobody edits while it runs: bash
reads scripts as it goes.

Testing an image before it is uploaded, without the app and the Mac's
helpers (a VM folder with a `vm.env` as the app writes it):
`printf '%s\n' PASSWORD | OMACVM_PREBUILT_SOURCE=…/prebuilt-out/app OMACVM_CREATE_NO_MAC=1 OMACVM_HOST_PORTS= app/scripts/prebuilt-vm.sh FOLDER`.

## Licences

The images contain Arch Linux ARM packages (GPL, LGPL, MIT, BSD and others),
Omarchy (MIT) and its packages, and OmacVM (MIT). The release has
`SOURCES.md` (where each part's source is) and the package list with each
package's licence.
