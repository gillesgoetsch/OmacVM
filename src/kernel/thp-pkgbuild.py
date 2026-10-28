#!/usr/bin/env python3
"""Turn Arch Linux ARM's current linux-aarch64 package into linux-aarch64-thp.

Usage: thp-pkgbuild.py <dir>   (dir holds ALARM's PKGBUILD, linux.preset and
linux-aarch64.install; they are rewritten in place)

The result is the same kernel with the same config, except:
  * transparent huge pages "always" (instead of madvise) and MGLRU on: faster
    memory access and calmer reclaim in a VM that cannot hand memory back;
  * zswap defaults to zstd;
  * named linux-aarch64-thp, installed as /boot/vmlinuz-linux-aarch64-thp next
    to the stock kernel (which stays the fallback in the boot menu);
  * no device-tree blobs and no Chromebook image (a Parallels VM needs neither).
Fails loudly if ALARM's PKGBUILD no longer has the expected shape.
"""
import hashlib
import re
import sys
from pathlib import Path

THP_CONFIG = '''
  # OmacVM: memory-access speed (THP always) and reclaim (MGLRU)
  scripts/config --enable TRANSPARENT_HUGEPAGE --enable TRANSPARENT_HUGEPAGE_ALWAYS \\
    --disable TRANSPARENT_HUGEPAGE_MADVISE --enable LRU_GEN --enable LRU_GEN_ENABLED \\
    --enable ZSWAP_COMPRESSOR_DEFAULT_ZSTD --disable ZSWAP_COMPRESSOR_DEFAULT_LZO \\
    --set-str ZSWAP_COMPRESSOR_DEFAULT zstd
  make olddefconfig
  grep -E "^CONFIG_(TRANSPARENT_HUGEPAGE|LRU_GEN)" .config
'''
CHROMEBOOK_FILES = {"generate_chromebook_its.sh", "kernel.keyblock", "kernel_data_key.vbprivk"}


def sub(pattern, repl, text, count=1, flags=0):
    new, n = re.subn(pattern, repl, text, count=count, flags=flags)
    if n == 0:
        sys.exit(f"thp-pkgbuild: ALARM's PKGBUILD changed, pattern not found: {pattern}")
    return new


def array(name, text):
    m = re.search(rf"^{name}=\((.*?)\)", text, re.S | re.M)
    if not m:
        sys.exit(f"thp-pkgbuild: no {name}=() in PKGBUILD")
    # Lines ALARM commented out are no entries (7.3: a #"...patch-${pkgver}.xz" line in source=()).
    body = "\n".join(l for l in m.group(1).split("\n") if not l.lstrip().startswith("#"))
    return m, re.findall(r"""['"]([^'"]+)['"]""", body)


def main(d):
    d = Path(d)
    pkgbuild = (d / "PKGBUILD").read_text()

    preset = (d / "linux.preset").read_text()
    preset = sub(r"initramfs-linux\.img", "initramfs-linux-aarch64-thp.img", preset)
    preset = sub(r"initramfs-linux-fallback\.img", "initramfs-linux-aarch64-thp-fallback.img", preset)
    (d / "linux.preset").write_text(preset)
    install = (d / "linux-aarch64.install").read_text()
    install = install.replace("initramfs-linux.img", "initramfs-linux-aarch64-thp.img")
    install = install.replace("initramfs-linux-fallback.img", "initramfs-linux-aarch64-thp-fallback.img")
    (d / "linux-aarch64-thp.install").write_text(install)

    p = pkgbuild
    p = sub(r"^# / AArch64 multi-platform.*$",
            "# / AArch64 multi-platform, derived from ALARM linux-aarch64 by OmacVM:\n"
            "#   THP always, MGLRU on, no dtbs/Chromebook image. Installs next to the stock kernel.", p, flags=re.M)
    p = sub(r"^pkgbase=linux-aarch64$", "pkgbase=linux-aarch64-thp", p, flags=re.M)
    p = sub(r'^_desc="AArch64 multi-platform"$', '_desc="AArch64 multi-platform, THP always + MGLRU (OmacVM)"', p, flags=re.M)
    p = sub(r"'uboot-tools' 'vboot-utils' ", "", p)
    p = sub(r"(^makedepends=\([^)]*)\)", r"\1 'pahole' 'cpio')", p, flags=re.M)

    # source/md5sums: drop the Chromebook files, re-hash the rewritten preset
    src_m, sources = array("source", p)
    sum_m, sums = array("md5sums", p)
    if len(sources) != len(sums):
        sys.exit("thp-pkgbuild: source and md5sums differ in length")
    keep = [(s, h) for s, h in zip(sources, sums) if s not in CHROMEBOOK_FILES]
    keep = [(s, hashlib.md5(preset.encode()).hexdigest() if s == "linux.preset" else h) for s, h in keep]
    src_text = "source=(" + "\n        ".join(f'"{s}"' if "$" in s else f"'{s}'" for s, _ in keep) + ")"
    sum_text = "md5sums=(" + "\n         ".join(f"'{h}'" for _, h in keep) + ")"
    p = p[:sum_m.start()] + sum_text + p[sum_m.end():]
    p = p[:src_m.start()] + src_text + p[src_m.end():]

    p = sub(r'(  cat "\$\{srcdir\}/config" > \./\.config\n)', r"\1" + THP_CONFIG.replace("\\", "\\\\"), p)
    p = sub(r"make \$\{MAKEFLAGS\} Image Image\.gz modules\n.*\n.*dtbs\n", "make ${MAKEFLAGS} Image modules\n", p)
    p = sub(r'provides=\("linux=\$\{pkgver\}" ', 'provides=(', p)
    p = sub(r"^  conflicts=\('linux'\)\n", "", p, flags=re.M)
    p = sub(r'echo "Installing boot image and dtbs\.\.\."\n.*\n.*dtbs_install\n',
            'echo "Installing boot image..."\n'
            '  install -Dm644 arch/arm64/boot/Image "${pkgdir}/boot/vmlinuz-${pkgbase}"\n', p)
    p = sub(r'^  provides=\("linux-headers=\$\{pkgver\}"\)\n  conflicts=\(\'linux-headers\'\)\n', "", p, flags=re.M)
    p = sub(r"\n_package-chromebook\(\) \{.*?\n\}\n", "\n", p, flags=re.S)
    p = sub(r'^pkgname=\("\$\{pkgbase\}" "\$\{pkgbase\}-headers" "\$\{pkgbase\}-chromebook"\)',
            'pkgname=("${pkgbase}" "${pkgbase}-headers")', p, flags=re.M)
    (d / "PKGBUILD").write_text(p)
    print("linux-aarch64-thp PKGBUILD written")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
