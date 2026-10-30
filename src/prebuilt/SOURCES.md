# Sources of the prebuilt OmacVM VMs

Each prebuilt VM (`omacvm-prebuilt-VERSION-ROUTE.tar.zst.part-*`) is a disk
with Arch Linux ARM, Omarchy (omarchy-mac) and OmacVM's guest side, plus the
VM's configuration file. It is what `omacvm build` makes on your Mac, with the
user and everything personal removed (see `docs/prebuilt.md` in the OmacVM
repository).

`omacvm-prebuilt-VERSION-ROUTE-packages.txt` next to it lists every package
in the image with its version and licence.

## Where the sources are

| What | Licence | Source |
|---|---|---|
| Arch Linux ARM packages (kernel `linux-aarch64`, base system, everything installed with pacman) | each package's own: GPL, LGPL, MIT, BSD and others (see the package list) | https://archlinuxarm.org (package sources: https://github.com/archlinuxarm/PKGBUILDs, upstream sources linked from each PKGBUILD; Arch Linux's own: https://gitlab.archlinux.org/archlinux/packaging/packages) |
| Omarchy for Macs (omarchy-mac) and the packages of its ARM repository (Hyprland stack) | MIT (Omarchy), BSD-3-Clause (Hyprland) and others | https://github.com/omacom/omarchy-mac, https://github.com/basecamp/omarchy, https://github.com/hyprwm |
| OmacVM's guest side (`/usr/local/share/omacvm`) | MIT | https://github.com/gillesgoetsch/omacvm |
| VMware Fusion image only: Hyprland rebuilt with OmacVM's vmwgfx patch | BSD-3-Clause | Hyprland's source from the Omarchy repository + `src/fusion/guest/hyprland-vmwgfx/<release>.patch` in OmacVM |
| VMware Fusion image only: open-vm-tools, built from Arch Linux's recipe | LGPL-2.1 / GPL-2.0 | https://github.com/vmware/open-vm-tools, https://gitlab.archlinux.org/archlinux/packaging/packages/open-vm-tools |
| UTM image only: spice-vdagent, qemu-guest-agent (Arch Linux ARM packages) | GPL | see Arch Linux ARM above |

For the exact source of a package version, use the version in the package
list: Arch Linux ARM keeps its build recipes in git, and the upstream source
archives are named in each recipe. Ask in the OmacVM repository's issues if
you need a source archive you cannot find; it will be provided for three
years after the image's release.

## What is not in the images

- **No Parallels Tools.** They belong to Parallels. `omacvm build --prebuilt`
  (or `omacvm apply`) installs them from your own Parallels Desktop.
- **No VMware or Parallels program files.** The VM configuration files
  (`config.pvs`, `.vmx`, `config.plist`) are plain settings.
- **Nothing personal**: no user, no SSH keys or host keys, no machine id, no
  passwords, no logs, no package cache. The first boot creates your user from
  your answers.
