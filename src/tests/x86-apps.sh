#!/bin/bash
# The x86-apps feature's VM step (src/x86/guest/install.sh) without a VM:
# on builds and installs box64 once, then only checks it; off removes only
# OmacVM's own package and its binfmt rule; the build tools come and go; the
# status line the check and the control centre show. pacman, makepkg and
# systemctl are stand-ins; /proc/sys/fs/binfmt_misc is a scratch folder. The
# tiny x86_64 test program is checked as an ELF (it runs only in a VM).
#   src/tests/x86-apps.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/state   # what the stand-ins share: NAME.ver and NAME.packager per installed package
V=$(bash -c 'source "$1"; echo "$pkgver-$pkgrel"' _ "$R/src/x86/guest/PKGBUILD")   # this version
mkdir -p "$T/bin"

cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
case $1 in
  -T) for p in "${@:2}"; do [[ " $MISSING " == *" $p "* ]] && echo "$p"; done; exit 0 ;;
  -Q) [[ -s $S/$2.ver ]] || exit 1; echo "$2 $(cat "$S/$2.ver")" ;;
  -Qi) [[ -s $S/$2.ver ]] || exit 1; printf 'Name            : %s\nPackager        : %s\n' "$2" "$(cat "$S/$2.packager")" ;;
  -Rns|-Rdd) for a in "${@:2}"; do [[ $a == -* ]] || rm -f "$S/$a.ver"; done ;;
  -U) for a in "$@"; do
        [[ $a == *.pkg.tar.* ]] || continue
        n=$(basename "$a"); n=${n%-"$V"-aarch64.pkg.tar.*}
        [[ -s $S/box64.ver ]] && exit 1   # conflicts=(box64): --noconfirm says no
        echo "$V" > "$S/$n.ver"; echo "OmacVM <omacvm@users.noreply.github.com>" > "$S/$n.packager"
      done ;;
esac
exit 0
EOF
# pacman's vercmp: enough for x.y.z-n.
cat > "$T/bin/vercmp" <<'EOF'
#!/bin/bash
[[ $1 == "$2" ]] && { echo 0; exit; }
[[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]] && echo -1 || echo 1
EOF
# systemd-binfmt: registers what pacman installed (its hook does the same).
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
if [[ $* == "restart systemd-binfmt" ]]; then
  rm -f "$BINFMT/box64"
  [[ ( -s $S/omacvm-box64.ver || -s $S/box64.ver ) && $BINFMT_RESTART == works ]] && echo enabled > "$BINFMT/box64"
fi
exit 0
EOF
cat > "$T/bin/runuser" <<'EOF'
#!/bin/bash
echo "runuser $*" >> "$CALLS"
while [[ $1 != -- ]]; do shift; done; shift
exec "$@"
EOF
cat > "$T/bin/makepkg" <<'EOF'
#!/bin/bash
[[ $MAKEPKG == ok ]] || exit 1
: > "$PKGDEST/omacvm-box64-$V-aarch64.pkg.tar.zst"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/chown"
# guest/pkg-add: installs what is missing (its own test: src/tests/pkg-safe.sh).
cat > "$T/bin/pkg-add" <<'EOF'
#!/bin/bash
echo "pkg-add $*" >> "$CALLS"
[[ $PKGADD == ok ]]
EOF
# The test program, as the binfmt rule would run it: say x86_64 if it is ours.
cat > "$T/bin/timeout" <<'EOF'
#!/bin/bash
[[ $X86_RUNS == yes && $(head -c 4 "$2") == $'\x7fELF' ]] && echo x86_64
EOF
chmod +x "$T/bin/"*

# INSTALLED/PACKAGER: omacvm-box64; BOX64/BOX64_PACKAGER: a package named box64
# (by hand, or OmacVM's from before the rename)
run() {   # ARGS... ; env: INSTALLED PACKAGER BOX64 BOX64_PACKAGER REGISTERED MISSING MAKEPKG PKGADD BINFMT_RESTART X86_RUNS
  rm -rf "$T/root" "$S"; mkdir -p "$T/root/proc/sys/fs/binfmt_misc" "$T/root/var/log" "$T/root/tmp" "$S"
  [[ -n ${INSTALLED:-} ]] && echo "$INSTALLED" > "$S/omacvm-box64.ver"
  echo "${PACKAGER:-OmacVM <omacvm@users.noreply.github.com>}" > "$S/omacvm-box64.packager"
  [[ -n ${BOX64:-} ]] && echo "$BOX64" > "$S/box64.ver"
  echo "${BOX64_PACKAGER:-someone <a@b>}" > "$S/box64.packager"
  [[ ${REGISTERED:-no} == yes ]] && echo enabled > "$T/root/proc/sys/fs/binfmt_misc/box64"
  : > "$T/calls"
  OUT=$(V=$V CALLS=$T/calls S=$S BINFMT=$T/root/proc/sys/fs/binfmt_misc OMACVM_X86_ROOT=$T/root \
    MISSING=${MISSING:-} MAKEPKG=${MAKEPKG:-ok} PKGADD=${PKGADD:-ok} OMACVM_PKG_ADD=$T/bin/pkg-add BINFMT_RESTART=${BINFMT_RESTART:-works} X86_RUNS=${X86_RUNS:-yes} \
    PATH="$T/bin:$PATH" bash "$R/src/x86/guest/install.sh" "$@" 2>&1); CODE=$?
}
called() { grep -qF -- "$1" "$T/calls" && echo yes || echo no; }
registered() { [[ -f $T/root/proc/sys/fs/binfmt_misc/box64 ]] && echo yes || echo no; }

# ---------- status ----------
INSTALLED="" run --status
expect "status, none: off" "off box64 not installed" "$OUT"
INSTALLED=$V REGISTERED=yes run --status
expect "status, ours and registered: ok" "ok box64 $V runs x86_64 programs and AppImages" "$OUT"
INSTALLED=$V REGISTERED=no run --status
expect "status, not registered: broken" broken "${OUT%% *}"
INSTALLED=0.4.2-1 REGISTERED=yes run --status
expect "status, older: needed" "needed box64 0.4.2-1 is older than $V: omacvm apply" "$OUT"
BOX64=0.4.0-1 run --status
expect "status, box64 installed by hand: ok, left alone" "ok box64 0.4.0-1 (not OmacVM's: installed by hand, left alone)" "$OUT"
OLD="OmacVM <omacvm@users.noreply.github.com>"
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run --status
expect "status, OmacVM's under the old name box64: needed" "needed box64 $V under its old package name: omacvm apply" "$OUT"

# ---------- off ----------
INSTALLED="" run off
expect "off, none: silent, status 0" "0 " "$CODE $OUT"
expect "off, none: pacman removes nothing" no "$(called "pacman -Rns")"
INSTALLED=$V REGISTERED=yes run off
expect "off, ours: removed" "0 yes" "$CODE $(called "pacman -Rns --noconfirm omacvm-box64")"
expect "off, ours: binfmt rule gone" no "$(registered)"
BOX64=$V REGISTERED=yes run off
expect "off, box64 installed by hand: left alone" "0 no" "$CODE $(called "pacman -Rns")"
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run off
expect "off, OmacVM's under the old name: removed" "0 yes no" "$CODE $(called "pacman -Rns --noconfirm box64") $(registered)"

# ---------- on ----------
INSTALLED=$V REGISTERED=yes run on
expect "on, already there: no build" "0 no" "$CODE $(called "runuser")"
expect "on, already there: says so" "x86 apps: box64 $V runs x86_64 programs and AppImages" "$OUT"
INSTALLED=$V REGISTERED=no run on
expect "on, rule lost: registered again, no build" "0 yes no" "$CODE $(registered) $(called "runuser")"

MISSING="cmake python" run on
expect "on, fresh VM: built and installed" 0 "$CODE"; [[ $CODE == 0 ]] || echo "$OUT"
expect "on, fresh VM: built as nobody" yes "$(called "runuser -u nobody")"
expect "on, fresh VM: build tools as dependencies, through pkg-add" yes "$(called "pkg-add --asdeps cmake python")"
expect "on, fresh VM: fuse2 through pkg-add, before pacman -U" "pkg-add --asdeps glibc gcc-libs fuse2" \
  "$(grep -B1 '^pacman -U' "$T/calls" | head -1)"
expect "on, fresh VM: build tools removed after" yes "$(called "pacman -Rns --noconfirm cmake python")"
expect "on, fresh VM: binfmt rule registered" yes "$(registered)"
expect "on, fresh VM: last line" "x86 apps: box64 $V runs x86_64 programs and AppImages" "$(tail -1 <<<"$OUT")"
expect "on, fresh VM: build folder gone" "" "$(ls -d /var/tmp/omacvm-box64.* 2>/dev/null | while read -r d; do [[ $d -nt $T/calls ]] && echo "$d"; done)"

INSTALLED=0.4.2-1 REGISTERED=yes run on
expect "on, older: rebuilt" "0 yes" "$CODE $(called "pacman -U")"
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run on
expect "on, OmacVM's under the old name: swapped for omacvm-box64" "0 yes $V" \
  "$CODE $(called "pacman -Rdd --noconfirm box64") $(cat "$S/omacvm-box64.ver" 2>/dev/null)"
BOX64=0.4.0-1 run on
expect "on, box64 installed by hand: left alone, no build" "0 no" "$CODE $(called "runuser")"

MISSING="cmake" MAKEPKG=fail run on
expect "on, build fails: status 1" 1 "$CODE"
expect "on, build fails: tools removed all the same" yes "$(called "pacman -Rns --noconfirm cmake")"
expect "on, build fails: nothing installed" no "$(called "pacman -U")"
expect "on, build fails: says where the log is" yes "$(grep -q "the build failed (details in $T/root/var/log/omacvm-x86-apps.log)" <<<"$OUT" && echo yes || echo no)"

MISSING="cmake" PKGADD=fail run on
expect "on, pkg-add cannot install the build tools: fails, no build" "1 no" "$CODE $(called "runuser")"

BINFMT_RESTART=broken run on
expect "on, binfmt never registers: fails" 1 "$CODE"
X86_RUNS=no run on
expect "on, the test program does not run: fails" "1 yes" "$CODE $(grep -q "test x86_64 program did not run" <<<"$OUT" && echo yes)"

run bogus
expect "bad argument: usage, status 2" 2 "$CODE"

# ---------- the test program and the package ----------
hello=$(sed -n 's/^HELLO=//p' "$R/src/x86/guest/install.sh")
python3 - "$hello" <<'EOF' && echo "ok   test program: static x86_64 ELF that writes x86_64 and exits 0" || { echo "FAIL test program"; exit 1; }
import base64, struct, sys
b = base64.b64decode(sys.argv[1])
assert b[:4] == b"\x7fELF" and b[4] == 2 and b[5] == 1, "ELF64 little endian"
e_type, e_machine = struct.unpack_from("<HH", b, 16)
assert e_type == 2 and e_machine == 0x3e, "x86_64 executable"
entry, phoff = struct.unpack_from("<QQ", b, 24)
p_type, p_flags, p_off, p_vaddr, _, p_filesz = struct.unpack_from("<IIQQQQ", b, phoff)
assert p_type == 1 and p_off == 0 and p_filesz == len(b), "one load segment, the whole file"
code = b[entry - p_vaddr:]
assert code.count(b"\x0f\x05") == 2 and b.endswith(b"x86_64\n"), "write + exit syscalls, the message"
# lea rsi, [rip + d] points at the message
i = code.index(b"\x48\x8d\x35"); d = struct.unpack_from("<i", code, i + 3)[0]
assert code[i + 7 + d:] == b"x86_64\n", "lea points at the message"
# the binfmt rule (box64's, from the PKGBUILD's source) matches it
magic = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"
mask = b"\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff"
assert all((b[k] & mask[k]) == magic[k] for k in range(20)), "box64's binfmt rule matches"
EOF
[[ $? == 0 ]] || fail=1
pk=$R/src/x86/guest/PKGBUILD
expect "PKGBUILD: a pinned commit, not a branch" yes "$(grep -qE '^_commit=[0-9a-f]{40} ' "$pk" && echo yes)"
expect "PKGBUILD: no settings app without its PyQt (menu entry)" yes "$(grep -q 'rm -f "$pkgdir/usr/bin/box64-configurator" "$pkgdir/usr/share/applications/box64-configurator.desktop"' "$pk" && echo yes)"
expect "PKGBUILD: the malloc hack for every program (Electron apps)" yes "$(grep -qF "'[*]' 'BOX64_MALLOC_HACK=2'" "$pk" && echo yes)"
expect "PKGBUILD: not named box64 (the AUR's name), provides and conflicts with it" "omacvm-box64 box64=${V%-*} box64" \
  "$(bash -c 'source "$1"; echo "$pkgname ${provides[*]} ${conflicts[*]}"' _ "$pk")"
expect "PKGBUILD: two sources, two sha256s" "2 2" \
  "$(bash -c 'source "$1"; echo "${#source[@]} ${#sha256sums[@]}"' _ "$pk")"
expect "PKGBUILD: no SKIP checksum" 0 "$(grep -c SKIP "$pk")"
expect "PKGBUILD: generic ARM64 build (not the 16K-page M1 profile)" yes "$(grep -q -- '-D ARM64=ON -D ARM_DYNAREC=ON' "$pk" && ! grep -q -- '-D M1' "$pk" && echo yes)"
expect "parts.tsv: x86/ is the feature's" yes "$(grep -q $'^x86-apps\tx86/\\*\\*$' "$R/src/release/parts.tsv" && echo yes)"
exit $fail
