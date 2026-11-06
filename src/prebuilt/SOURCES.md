# Sources of the prebuilt OmacVM VMs

Each prebuilt VM (`omacvm-prebuilt-VERSION-app.tar.zst.part-*`) is an
OmacVM.app disk with Arch Linux ARM, Omarchy (omarchy-mac) and OmacVM's guest
side. It is what `omacvm build` makes on your Mac, with the user and
everything personal removed (see `docs/prebuilt.md` in the OmacVM
repository).

`omacvm-prebuilt-VERSION-app-packages.txt` next to it lists every package
in the image with its version and licence.

## Where the sources are

| What | Licence | Source |
|---|---|---|
| Arch Linux ARM packages (kernel `linux-aarch64`, base system, everything installed with pacman) | each package's own: GPL, LGPL, MIT, BSD and others (see the package list) | https://archlinuxarm.org (package sources: https://github.com/archlinuxarm/PKGBUILDs, upstream sources linked from each PKGBUILD; Arch Linux's own: https://gitlab.archlinux.org/archlinux/packaging/packages) |
| Omarchy for Macs (omarchy-mac) and the packages of its ARM repository (Hyprland stack) | MIT (Omarchy), BSD-3-Clause (Hyprland) and others | https://github.com/omacom/omarchy-mac, https://github.com/basecamp/omarchy, https://github.com/hyprwm |
| OmacVM's guest side (`/usr/local/share/omacvm`) | MIT | https://github.com/gillesgoetsch/omacvm |

For the exact source of a package version, use the version in the package
list: Arch Linux ARM keeps its build recipes in git, and the upstream source
archives are named in each recipe. Ask in the OmacVM repository's issues if
you need a source archive you cannot find; it will be provided for three
years after the image's release.

## What is not in the images

- **Nothing personal**: no user, no SSH keys or host keys, no machine id, no
  passwords, no logs, no package cache. The first boot creates your user from
  your answers.
