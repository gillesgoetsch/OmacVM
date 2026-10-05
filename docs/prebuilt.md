# Prebuilt VMs

`omacvm build` can make the VM on your Mac (30 to 70 minutes, mostly
downloads and Omarchy's install) or download one that is already built
(faster). Both end the same way: your user, your password, your features,
OmacVM on the Mac and in the VM.

| | Parallels | UTM | VMware Fusion |
|---|---|---|---|
| Download | 3.7 GB | 3.5 GB | 6.0 GB |
| `omacvm build --prebuilt` (measured, M4 Max, fast connection) | 6 min | about 4 min | about 5 min |
| `omacvm build` (building it here) | 30-70 min | 30-70 min | 45-85 min |

The Fusion image is larger: it carries Hyprland with OmacVM's vmwgfx fix and
VMware Tools, both built in the VM, and their build tools.

## Using one

```bash
omacvm build                       # asks: "Build it yourself" or "Download a prebuilt VM"
omacvm build --vm-type utm --prebuilt
OMACVM_PASSWORD=… omacvm build --yes --vm-type fusion --prebuilt --user anna --feature scroll-momentum=on
```

What happens:

1. The questions are the same as for a build: app, resources, folder,
   features, user, password.
2. The image for this app is downloaded from a GitHub release whose tag
   starts with `prebuilt-` (see below which one), in parts of at most 1.9 GB, each checked against the
   manifest's SHA-256. Interrupted downloads resume. The parts go to
   `~/Library/Caches/omacvm/prebuilt/` and are deleted after unpacking
   (`OMACVM_PREBUILT_KEEP=1` keeps them).
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
says so. OmacVM.app (`--vm-type app`) has no prebuilt VMs and always builds
in the app.

Images from before 2.6.0 have no sound card on UTM and Fusion: the build
adds one while the VM is off, after the seed is gone.

## Downloading one by hand

Each release has, per app, `omacvm-prebuilt-VERSION-ROUTE.tar.zst.part-aa`,
`-ab`, …, a manifest (`.json`), SHA-256 sums (`.sha256`) and the package list.

```bash
shasum -a 256 -c omacvm-prebuilt-2.6.0-utm.sha256
cat omacvm-prebuilt-2.6.0-utm.tar.zst.part-* | zstd -dc --long=27 | tar -xSf -
```

That gives `Omarchy.pvm`, `Omarchy.utm` or `Omarchy.vmwarevm`. Open it with
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

## Licences

The images contain Arch Linux ARM packages (GPL, LGPL, MIT, BSD and others),
Omarchy (MIT) and its packages, and OmacVM (MIT). The release has
`SOURCES.md` (where each part's source is) and the package list with each
package's licence. There are no Parallels Tools and no VMware or Parallels
program files in them; the Fusion image's open-vm-tools (LGPL) are built
from Arch's recipe, its Hyprland (BSD) with OmacVM's patch.
