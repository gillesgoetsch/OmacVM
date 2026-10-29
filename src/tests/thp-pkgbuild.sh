#!/bin/bash
# The memory-optimized kernel's PKGBUILD rewriter (src/kernel/thp-pkgbuild.py) on ALARM's linux-aarch64 in its
# two shapes: a point release (7.2.12: kernel.org's patch is a source) and a new kernel (7.2, 7.3: that line is
# commented out inside source=()). On 7.3 the rewriter counted the commented-out line and stopped with "source
# and md5sums differ in length": every memory-optimized kernel build failed. The written PKGBUILD is read back
# by bash, as makepkg reads it. No network: ALARM's PKGBUILD cut down to the lines the rewriter changes.
#   src/tests/thp-pkgbuild.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$R/src/kernel/thp-pkgbuild.py" "$T" <<'PY'
import hashlib, importlib.util, os, subprocess, sys
RW, T = sys.argv[1], sys.argv[2]
fail = 0
def expect(what, want, got):
    global fail
    if want == got:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}\n  want: {want}\n  got:  {got}")
        fail = 1

# ALARM's linux-aarch64 7.3-1 (2026-10-24), cut down. @PATCH@: the kernel.org patch line, @PATCHSUM@ its md5.
PKGBUILD = '''# / AArch64 multi-platform
# Maintainer: Kevin Mihelich <kevin@archlinuxarm.org>

buildarch=8

pkgbase=linux-aarch64
_srcname=@SRCNAME@
_kernelname=${pkgbase#linux}
_desc="AArch64 multi-platform"
pkgver=@PKGVER@
pkgrel=1
arch=('aarch64')
license=('GPL-2.0-only')
makedepends=('xmlto' 'docbook-xsl' 'kmod' 'inetutils' 'bc' 'git' 'uboot-tools' 'vboot-utils' 'dtc' 'python')
options=('!strip')
source=("https://www.kernel.org/pub/linux/kernel/v7.x/${_srcname}.tar.xz"
        @PATCH@"https://www.kernel.org/pub/linux/kernel/v7.x/patch-${pkgver}.xz"
        '0001-arm64-dts-rockchip-disable-pwm0-on-rk3399-firefly.patch'
        '0002-pps-Compatibility-hack-should-be-X86-specific.patch'
        'config'
        'generate_chromebook_its.sh'
        'kernel.keyblock'
        'kernel_data_key.vbprivk'
        'linux.preset')
md5sums=('b38587333374ecce1141b9b5886c4fcf'
@PATCHSUM@         '328ab847d1a56a5cabbb4779d931a175'
         'c4aa031077a71d86837ed1624e8ca4de'
         '95261d0e026bb038cb202ea009a778fa'
         '7c97cf141750ad810235b1ad06eb9f75'
         '61c5ff73c136ed07a7aadbf58db3d96a'
         '584777ae88bce2c5659960151b64c7d8'
         'f82b1a5732c416762bbc88e00b1a4b15')

prepare() {
  cd $_srcname

  # add upstream patch
  if [[ -f ../patch-${pkgver} ]]; then
    git apply --whitespace=nowarn ../patch-${pkgver}
  fi

  cat "${srcdir}/config" > ./.config
}

build() {
  cd ${_srcname}
  unset LDFLAGS
  make ${MAKEFLAGS} Image Image.gz modules
  # Generate device tree blobs with symbols to support applying device tree overlays in U-Boot
  make ${MAKEFLAGS} DTC_FLAGS="-@" dtbs
}

_package() {
  pkgdesc="The Linux Kernel and modules - ${_desc}"
  provides=("linux=${pkgver}" "KSMBD-MODULE" "WIREGUARD-MODULE")
  conflicts=('linux')
  install=${pkgname}.install

  cd $_srcname
  echo "Installing boot image and dtbs..."
  install -Dm644 arch/arm64/boot/Image{,.gz} -t "${pkgdir}/boot"
  make INSTALL_DTBS_PATH="${pkgdir}/boot/dtbs" dtbs_install

  echo "Installing modules..."
}

_package-headers() {
  pkgdesc="Header files and scripts for building modules for linux kernel - ${_desc}"
  provides=("linux-headers=${pkgver}")
  conflicts=('linux-headers')

  cd $_srcname
}

_package-chromebook() {
  pkgdesc="The Linux Kernel - ${_desc} - Chromebooks"
  depends=('linux-aarch64')
  install=${pkgname}.install
  vbutil_kernel --keyblock ../kernel.keyblock --signprivate ../kernel_data_key.vbprivk
}

pkgname=("${pkgbase}" "${pkgbase}-headers" "${pkgbase}-chromebook")
for _p in ${pkgname[@]}; do
  eval "package_${_p}() {
    _package${_p#${pkgbase}}
  }"
done
'''
PRESET = '''ALL_kver="/boot/Image"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux.img"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_options="-S autodetect"
'''
INSTALL = '''post_upgrade() {
  echo "initramfs-linux.img initramfs-linux-fallback.img"
}
'''

def alarm(name, srcname, pkgver, patch_on):
    d = os.path.join(T, name)
    os.makedirs(d)
    p = (PKGBUILD.replace("@SRCNAME@", srcname).replace("@PKGVER@", pkgver)
         .replace("@PATCH@", "" if patch_on else "#")
         .replace("@PATCHSUM@", "         'eceba523139eef644a6353e85d3e7a01'\n" if patch_on else ""))
    for f, text in (("PKGBUILD", p), ("linux.preset", PRESET), ("linux-aarch64.install", INSTALL)):
        with open(os.path.join(d, f), "w") as fh:
            fh.write(text)
    return d

def bash_arrays(pkgbuild):   # source=() and md5sums=() as bash (and so makepkg) reads them
    out = subprocess.run(["bash", "-c", 'source "$1" >/dev/null 2>&1; printf "%s\\n" "${source[@]}"; echo --; '
                          'printf "%s\\n" "${md5sums[@]}"', "_", pkgbuild], capture_output=True, text=True).stdout
    src, sums = out.split("--\n")
    return src.split(), sums.split()

TARBALL = "https://www.kernel.org/pub/linux/kernel/v7.x/linux-{}.tar.xz"
PATCH = "https://www.kernel.org/pub/linux/kernel/v7.x/patch-{}.xz"
LOCAL = ["0001-arm64-dts-rockchip-disable-pwm0-on-rk3399-firefly.patch",
         "0002-pps-Compatibility-hack-should-be-X86-specific.patch", "config", "linux.preset"]

for label, srcname, pkgver, patch_on in (("ALARM 7.3 (patch line commented out)", "linux-7.3", "7.3", False),
                                         ("ALARM 7.2.12 (a point release)", "linux-7.2", "7.2.12", True)):
    d = alarm(pkgver, srcname, pkgver, patch_on)
    r = subprocess.run([sys.executable, "-I", RW, d], capture_output=True, text=True)
    expect(f"{label}: the rewriter writes the PKGBUILD", "linux-aarch64-thp PKGBUILD written",
           (r.stdout + r.stderr).strip())
    if r.returncode:
        continue
    pb = os.path.join(d, "PKGBUILD")
    text = open(pb).read()
    src, sums = bash_arrays(pb)
    want = [TARBALL.format(srcname[6:])] + ([PATCH.format(pkgver)] if patch_on else []) + LOCAL
    expect("  bash reads its sources: kernel.org's, ALARM's patches, config and preset, no Chromebook files",
           want, src)
    expect("  as many md5sums as sources", len(src), len(sums))
    preset = open(os.path.join(d, "linux.preset")).read()
    expect("  the rewritten preset's md5 next to it", hashlib.md5(preset.encode()).hexdigest(),
           sums[src.index("linux.preset")] if "linux.preset" in src else None)
    expect("  config keeps ALARM's md5", "95261d0e026bb038cb202ea009a778fa",
           sums[src.index("config")] if "config" in src else None)
    expect("  bash -n takes it", 0, subprocess.run(["bash", "-n", pb]).returncode)
    expect("  pkgbase linux-aarch64-thp, THP/MGLRU in prepare(), no Chromebook package", [True] * 4,
           ["\npkgbase=linux-aarch64-thp\n" in text, "--enable TRANSPARENT_HUGEPAGE_ALWAYS" in text,
            '\npkgname=("${pkgbase}" "${pkgbase}-headers")\n' in text, "_package-chromebook" not in text])

# Other ways bash leaves a line out or reads several entries from one.
spec = importlib.util.spec_from_file_location("thp_pkgbuild", RW)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
_, src = m.array("source", "source=('a'\n  # 'b' left out\n#'c'\n        'd')\n")
expect("comment lines with spaces before, or quotes in them: no entries", ["a", "d"], src)
_, src = m.array("source", "source=('a' 'b'\n        'c')\n")
expect("several entries on one line", ["a", "b", "c"], src)
sys.exit(fail)
PY
