#!/bin/bash
# Build and install linux-aarch64-thp: Arch Linux ARM's current linux-aarch64,
# with transparent huge pages "always" and MGLRU on (see thp-pkgbuild.py).
# Run as root inside the VM: ./build-thp-kernel.sh <desktop-user>
# Takes ~10 min on 16 vCPUs, over an hour on 4 (an M2 MacBook Air). The stock kernel stays installed as the fallback
# entry in GRUB's advanced menu; GRUB boots the THP kernel by default.
# Re-run it to follow a new ALARM kernel release; when the installed one is
# already ALARM's current release it does nothing (OMACVM_REBUILD_KERNEL=1
# builds anyway).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=${1:?usage: build-thp-kernel.sh <desktop-user>}
ALARM=https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64

G=/etc/default/grub
# GRUB boots the THP kernel by default (also after a disable that only
# pointed GRUB back at the stock kernel).
grub_default_thp() {
  grep -qx 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"' $G && return 0
  sed -i -e '/^GRUB_TOP_LEVEL="\/boot\/vmlinuz-linux-aarch64-thp"$/d' -e '/^GRUB_TOP_LEVEL="\/boot\/Image"$/d' \
    -e '/^GRUB_TOP_LEVEL="\/boot\/vmlinuz-linux"$/d' $G
  grep -q '^GRUB_TOP_LEVEL=' $G || echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"' >> $G
  grep -q '^GRUB_DISABLE_LINUX_UUID=' $G || echo 'GRUB_DISABLE_LINUX_UUID=false' >> $G
  grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -2
}

latest=$(curl -fsSL "$ALARM/PKGBUILD" | sed -n 's/^pkgver=//p; s/^pkgrel=//p' | paste -sd- -) || latest=""
have=$(pacman -Q linux-aarch64-thp 2>/dev/null | awk '{ print $2 }' || true)   # none yet: build
if [[ -z $latest && -n $have ]]; then
  echo "could not reach GitHub to check for a newer kernel: keeping linux-aarch64-thp $have"
  grub_default_thp
  exit 0
fi
[[ -n $latest ]] || { echo "could not reach GitHub for the kernel's PKGBUILD" >&2; exit 1; }
if [[ $have == "$latest" && -z ${OMACVM_REBUILD_KERNEL:-} ]]; then
  echo "linux-aarch64-thp $have is ALARM's current kernel: nothing to build"
  grub_default_thp
  exit 0
fi
"$here/../guest/pkg-add" xmlto docbook-xsl kmod inetutils bc git dtc python pahole cpio base-devel
# Built in fresh folders of root's (root never follows a link the user put
# there), under /home: root's snapshots (subvolume @) leave it out, so the
# GBs of build files never end up in one. makepkg runs as the user; the
# packages are copied to root's folder before pacman. makepkg's downloads
# (the kernel tarball, about 160 MB) stay in $SRC, so a new pkgrel or point
# release does not fetch it again.
B=/home/.omacvm-kernel
[[ -L $B ]] && rm -f "$B"
install -d -o root -g root -m 755 "$B"
SRC=$B/src
[[ -L $SRC ]] && rm -f "$SRC"
install -d -o "$U" -g "$U" "$SRC"
W=$(mktemp -d "$B/build.XXXXXX"); P=$(mktemp -d "$B/pkg.XXXXXX")
trap 'rm -rf "$W" "$P"' EXIT
cd "$W"
curl -fsSL "$ALARM/PKGBUILD" -o PKGBUILD
for f in linux.preset linux-aarch64.install $(sed -n "/^source=(/,/)/p" PKGBUILD | grep -o "'[^':]*'" | tr -d "'"); do
  curl -fsSL "$ALARM/$f" -o "$f"
done
python3 "$here/thp-pkgbuild.py" "$W"
chmod 755 "$W"; chown -R "$U:$U" "$W"
# makepkg builds with one job unless told otherwise: use every vCPU.
# Its thousands of compiler lines go to a log, not to the terminal.
LOG=$B/build.log
echo "building linux-aarch64-thp $latest (log: $LOG)"
if ! sudo -u "$U" env MAKEFLAGS="-j$(nproc)" SRCDEST="$SRC" makepkg --noconfirm --cleanbuild > "$LOG" 2>&1; then
  tail -30 "$LOG" >&2
  echo "build-thp-kernel: the build failed, full log in the VM: $LOG" >&2
  exit 1
fi
# Keep only the downloads this PKGBUILD uses.
keep=$(sudo -u "$U" makepkg --printsrcinfo | sed -n 's/^[[:space:]]*source = //p' | sed 's/::.*//; s#.*/##')
for f in "$SRC"/*; do
  [[ -e $f || -L $f ]] || continue
  grep -qxF "$(basename "$f")" <<<"$keep" || rm -f "$f"
done
cp -P "$W"/linux-aarch64-thp-[0-9]*.pkg.tar.* "$W"/linux-aarch64-thp-headers-*.pkg.tar.* "$P"/
for f in "$P"/*; do [[ -f $f && ! -L $f ]] || { echo "build-thp-kernel: $f is not a plain file" >&2; exit 1; }; done
pacman -U --noconfirm "$P"/linux-aarch64-thp-[0-9]*.pkg.tar.* "$P"/linux-aarch64-thp-headers-*.pkg.tar.*
# Builds before this one were kept in the user's cache (several GB, partly
# root's): gone, unless a link is on the way there.
C=$(getent passwd "$U" | cut -d: -f6)/.cache
if [[ ! -L $C && ! -L $C/omacvm && -d $C/omacvm/linux-aarch64-thp ]]; then rm -rf "$C/omacvm/linux-aarch64-thp" || true; fi

grub_default_thp
echo "linux-aarch64-thp installed; reboot to use it"
