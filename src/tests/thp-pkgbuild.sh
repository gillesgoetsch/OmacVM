#!/bin/bash
# The memory-optimized kernel's PKGBUILD rewriter (src/kernel/thp-pkgbuild.py) reads ALARM's source=() and
# md5sums=() as bash does: a line commented out inside them is no entry. ALARM's linux-aarch64 7.3 has one
# (#"https://www.kernel.org/.../patch-${pkgver}.xz"), and the build stopped with "source and md5sums differ in
# length". No network: the arrays in ALARM's 7.3 shape.
#   src/tests/thp-pkgbuild.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$R/src/kernel/thp-pkgbuild.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("thp_pkgbuild", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
fail = 0
def expect(what, want, got):
    global fail
    if want == got:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}\n  want: {want}\n  got:  {got}")
        fail = 1

alarm73 = '''pkgbase=linux-aarch64
source=("https://www.kernel.org/pub/linux/kernel/v7.x/${_srcname}.tar.xz"
        #"https://www.kernel.org/pub/linux/kernel/v7.x/patch-${pkgver}.xz"
        '0001-arm64-dts-rockchip-disable-pwm0-on-rk3399-firefly.patch'
        'config'
        'generate_chromebook_its.sh'
        'kernel.keyblock'
        'kernel_data_key.vbprivk'
        'linux.preset')
md5sums=('b38587333374ecce1141b9b5886c4fcf'
         '328ab847d1a56a5cabbb4779d931a175'
         '95261d0e026bb038cb202ea009a778fa'
         '7c97cf141750ad810235b1ad06eb9f75'
         '61c5ff73c136ed07a7aadbf58db3d96a'
         '584777ae88bce2c5659960151b64c7d8'
         'f82b1a5732c416762bbc88e00b1a4b15')
'''
_, src = m.array("source", alarm73)
_, sums = m.array("md5sums", alarm73)
expect("ALARM 7.3: a commented-out source line is no entry", 7, len(src))
expect("  as many sources as md5sums", len(sums), len(src))
expect("  the kernel tarball first, the preset last",
       ["https://www.kernel.org/pub/linux/kernel/v7.x/${_srcname}.tar.xz", "linux.preset"], [src[0], src[-1]])
expect("  the commented-out patch is not among them", False, any("patch-${pkgver}" in s for s in src))
_, src = m.array("source", "source=('a'\n  # 'b' left out\n#'c'\n        'd')\n")
expect("comment lines with spaces before, or quotes in them: no entries", ["a", "d"], src)
_, src = m.array("source", "source=('a' 'b'\n        'c')\n")
expect("several entries on one line (7.2's shape still reads)", ["a", "b", "c"], src)
sys.exit(fail)
PY
