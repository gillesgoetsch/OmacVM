#!/bin/bash
# The x86-apps feature's VM step (src/x86/guest/install.sh) without a VM:
# on builds and installs box64 once, then only checks it; off removes only
# OmacVM's own package and its binfmt rule; the build tools come and go; the
# status line the check and the control centre show. While it is on, x86_64
# programs go to box64 only: qemu-user's x86_64 rule (Omarchy 4.5) is held
# back by a file of OmacVM's in /etc/binfmt.d, and given back when off (#752).
# pacman, makepkg, systemctl and systemd-binfmt are stand-ins;
# /proc/sys/fs/binfmt_misc is a scratch folder. The tiny x86_64 test program
# is checked as an ELF (it runs only in a VM).
#   src/tests/x86-apps.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/state   # what the stand-ins share, per installed package: NAME.ver, NAME.packager,
             # NAME.provides (names it also answers to), NAME.rule (it has box64's binfmt rule)
V=$(bash -c 'source "$1"; echo "$pkgver-$pkgrel"' _ "$R/src/x86/guest/PKGBUILD")   # this version
OMACVM="OmacVM <omacvm@users.noreply.github.com>"
HOLD_LINE=$(sed -n "s/^HOLD_LINE='\(.*\)'$/\1/p" "$R/src/x86/guest/install.sh")
# binfmt.d rules as the packages ship them: box64's, qemu-user-static-binfmt's
# x86_64 and i386 (Omarchy 4.5), FEX's (not on Omarchy: a rule of someone else's).
export BOX64_RULE=':box64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/box64:'
QEMU_X86_64=':qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-x86_64-static:FP'
QEMU_I386=':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-i386-static:FP'
FEX_RULE=':FEX-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/FEXInterpreter:POCF'
mkdir -p "$T/bin"

cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
# NAME, or the installed package that provides it: -Q, -Qq and -Qi do that, -R does not.
find() {
  local f p
  [[ -s $S/$1.ver ]] && { echo "$1"; return 0; }
  for f in "$S"/*.provides; do
    [[ -f $f ]] || continue
    p=${f##*/}; p=${p%.provides}
    [[ -s $S/$p.ver && " $(cat "$f") " == *" $1 "* ]] && { echo "$p"; return 0; }
  done
  return 1
}
nf() { echo "error: package '$1' was not found" >&2; exit 1; }
case $1 in
  -T) for p in "${@:2}"; do [[ " $MISSING " == *" $p "* ]] && echo "$p"; done; exit 0 ;;
  -Q) n=$(find "$2") || nf "$2"; echo "$n $(cat "$S/$n.ver")" ;;
  -Qq) n=$(find "$2") || nf "$2"; echo "$n" ;;
  # Field names in the user's language, as pacman's (here Chinese), unless the locale is C.
  -Qi) n=$(find "$2") || nf "$2"
       if [[ ${LC_ALL:-${LANG:-C}} == C* ]]; then f=Name p=Packager; else f=名字 p=打包者; fi
       printf '%-16s: %s\n%-16s: %s\n' "$f" "$n" "$p" "$(cat "$S/$n.packager")" ;;
  # All or nothing, each target by its own name only.
  -Rns|-Rdd) [[ ${PACMAN_R:-ok} == ok ]] || exit 1
       t=(); for a in "${@:2}"; do [[ $a == -* ]] || t+=("$a"); done
       for a in "${t[@]}"; do [[ -s $S/$a.ver ]] || { echo "error: target not found: $a" >&2; exit 1; }; done
       for a in "${t[@]}"; do
         rm -f "$S/$a.ver" "$S/$a.provides"
         if [[ -f $S/$a.rule ]]; then rm -f "$S/$a.rule" "$ROOT/usr/lib/binfmt.d/box64.conf"; fi
       done ;;
  -U) for a in "$@"; do
        [[ $a == *.pkg.tar.* ]] || continue
        n=$(basename "$a"); n=${n%-"$V"-aarch64.pkg.tar.*}
        echo "pacman -U: qemu-user's x86_64 rule held back: $([[ -f $ROOT/etc/binfmt.d/qemu-x86_64-static.conf ]] && echo yes || echo no)" >> "$CALLS"
        # conflicts=(box64), also with a package that provides box64: --noconfirm says no
        if c=$(find box64) && [[ $c != "$n" ]]; then exit 1; fi
        echo "$V" > "$S/$n.ver"; echo "OmacVM <omacvm@users.noreply.github.com>" > "$S/$n.packager"
        echo box64 > "$S/$n.provides"; : > "$S/$n.rule"
        mkdir -p "$ROOT/usr/lib/binfmt.d"; echo "$BOX64_RULE" > "$ROOT/usr/lib/binfmt.d/box64.conf"
      done
      systemd-binfmt ;;   # systemd's pacman hook (Install, Upgrade of a binfmt.d file): a full run
esac
exit 0
EOF
# pacman's vercmp: enough for x.y.z-n.
cat > "$T/bin/vercmp" <<'EOF'
#!/bin/bash
[[ $1 == "$2" ]] && { echo 0; exit; }
[[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]] && echo -1 || echo 1
EOF
# systemd-binfmt with no arguments (systemd-binfmt.service at boot and on a
# restart, systemd's pacman hook): every rule out, then the binfmt.d files in
# file-name order, a file in /etc hiding the /usr/lib one of the same name.
cat > "$T/bin/systemd-binfmt" <<'EOF'
#!/bin/bash
echo "systemd-binfmt $*" >> "$CALLS"
for e in "$BINFMT"/*; do
  case ${e##*/} in register|status|\*) ;; *) rm -f "$e" ;; esac
done
[[ $BINFMT_RESTART == works ]] || exit 0
hex() { printf '%b' "$1" | od -An -tx1 | tr -d ' \n'; }
for n in $( { ls "$ROOT/usr/lib/binfmt.d" "$ROOT/etc/binfmt.d" 2>/dev/null; } | grep '\.conf$' | sort -u); do
  f=$ROOT/etc/binfmt.d/$n; [[ -e $f || -L $f ]] || f=$ROOT/usr/lib/binfmt.d/$n
  while IFS= read -r l; do
    [[ $l == :* ]] || continue   # comments
    IFS=: read -r _ name _ off magic mask interp flags <<<"$l"
    [[ -e $BINFMT/$name ]] && continue   # the kernel takes a name once
    { echo enabled; echo "interpreter $interp"; echo "flags: $flags"; echo "offset ${off:-0}"
      echo "magic $(hex "$magic")"; [[ -z $mask ]] || echo "mask $(hex "$mask")"; } > "$BINFMT/$name"
  done < "$f"
done
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
if [[ $* == "restart systemd-binfmt" ]]; then exec systemd-binfmt; fi
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
[[ $PKGADD == ok ]] || exit 1
for p in "$@"; do [[ $p == -* ]] || { echo 1 > "$S/$p.ver"; echo "Arch Linux ARM" > "$S/$p.packager"; }; done
EOF
# The test program, as the binfmt rule would run it: say x86_64 if it is ours.
cat > "$T/bin/timeout" <<'EOF'
#!/bin/bash
[[ $X86_RUNS == yes && $(head -c 4 "$2") == $'\x7fELF' ]] && echo x86_64
EOF
# The build folder (mktemp -d /var/tmp/...) in the test's own folder: another
# copy of this test (another CI runner on the same Mac) builds in /var/tmp too.
cat > "$T/bin/mktemp" <<'EOF'
#!/bin/bash
a=("$@"); n=$((${#a[@]} - 1)); a[n]=${a[n]/#\/var\/tmp\//$VARTMP/}
d=$(/usr/bin/mktemp "${a[@]}") || exit 1
echo "mktemp $d" >> "$CALLS"; echo "$d"
EOF
chmod +x "$T/bin/"*

B=$T/root/proc/sys/fs/binfmt_misc
U=$T/root/usr/lib/binfmt.d
E=$T/root/etc/binfmt.d
# The VM before the step: INSTALLED/PACKAGER omacvm-box64; BOX64/BOX64_PACKAGER
# a package named box64 (by hand, or OmacVM's from before the rename);
# BOX64GIT someone else's package that provides box64 (the AUR's box64-git);
# QEMU=yes qemu-user-static-binfmt (Omarchy 4.5); FEX=yes FEX's x86_64 rule;
# HOLD ours|own|link: /etc/binfmt.d/qemu-x86_64-static.conf, OmacVM's or the
# person's (a rule, or a link to /dev/null). Rules loaded as at boot;
# REGISTERED=no: box64's is lost since.
setup() {
  rm -rf "$T/root" "$S"; mkdir -p "$B" "$U" "$T/root/var/log" "$T/root/tmp" "$S" "$T/vartmp"
  if [[ -n ${INSTALLED:-} ]]; then echo "$INSTALLED" > "$S/omacvm-box64.ver"; echo box64 > "$S/omacvm-box64.provides"; : > "$S/omacvm-box64.rule"; fi
  echo "${PACKAGER:-$OMACVM}" > "$S/omacvm-box64.packager"
  if [[ -n ${BOX64:-} ]]; then echo "$BOX64" > "$S/box64.ver"; : > "$S/box64.rule"; fi
  echo "${BOX64_PACKAGER:-someone <a@b>}" > "$S/box64.packager"
  if [[ -n ${BOX64GIT:-} ]]; then
    echo "$BOX64GIT" > "$S/box64-git.ver"; echo box64 > "$S/box64-git.provides"; : > "$S/box64-git.rule"
    echo "someone <a@b>" > "$S/box64-git.packager"
  fi
  if ls "$S"/*.rule >/dev/null 2>&1; then echo "$BOX64_RULE" > "$U/box64.conf"; fi
  if [[ ${QEMU:-no} == yes ]]; then echo "$QEMU_X86_64" > "$U/qemu-x86_64-static.conf"; echo "$QEMU_I386" > "$U/qemu-i386-static.conf"; fi
  if [[ ${FEX:-no} == yes ]]; then echo "$FEX_RULE" > "$U/FEX-x86_64.conf"; fi
  case ${HOLD:-} in
    ours) mkdir -p "$E"; printf '%s\n' "$HOLD_LINE" > "$E/qemu-x86_64-static.conf" ;;
    own) mkdir -p "$E"; printf '%s\n' "# mine" "$QEMU_X86_64" > "$E/qemu-x86_64-static.conf" ;;
    link) mkdir -p "$E"; ln -s /dev/null "$E/qemu-x86_64-static.conf" ;;
  esac
  boot
  [[ ${REGISTERED:-no} == yes ]] || rm -f "$B/box64"
  : > "$T/calls"
}
boot() { CALLS=/dev/null BINFMT=$B ROOT=$T/root BINFMT_RESTART=works "$T/bin/systemd-binfmt"; }
go() {   # ARGS... on the VM as it is now; env: MISSING MAKEPKG PKGADD BINFMT_RESTART X86_RUNS PACMAN_R
  # A VM in Chinese (#357): only what install.sh reads in C is in English.
  OUT=$(LANG=zh_CN.UTF-8 LC_ALL= V=$V CALLS=$T/calls VARTMP=$T/vartmp S=$S BINFMT=$B ROOT=$T/root OMACVM_X86_ROOT=$T/root \
    MISSING=${MISSING:-} MAKEPKG=${MAKEPKG:-ok} PKGADD=${PKGADD:-ok} OMACVM_PKG_ADD=$T/bin/pkg-add BINFMT_RESTART=${BINFMT_RESTART:-works} X86_RUNS=${X86_RUNS:-yes} \
    PACMAN_R=${PACMAN_R:-ok} PATH="$T/bin:$PATH" bash "$R/src/x86/guest/install.sh" "$@" 2>&1); CODE=$?
}
run() { setup; go "$@"; }
called() { grep -qF -- "$1" "$T/calls" && echo yes || echo no; }
count() { grep -cF -- "$1" "$T/calls"; }
registered() { [[ -f $B/box64 ]] && echo yes || echo no; }
entries() { local e l=""; for e in "$B"/*; do [[ -f $e ]] && l+=" ${e##*/}"; done; echo "${l# }"; }   # the binfmt rules live now
hold() {   # what /etc/binfmt.d/qemu-x86_64-static.conf is: none, ours, link or own
  local f=$E/qemu-x86_64-static.conf
  if [[ -L $f ]]; then echo link; elif [[ ! -e $f ]]; then echo none
  elif [[ $(head -n1 "$f") == "$HOLD_LINE" ]]; then echo ours; else echo own; fi
}

expect "install.sh: one HOLD_LINE, OmacVM's" yes "$([[ $HOLD_LINE == *OmacVM* ]] && echo yes)"

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
BOX64GIT=0.4.6.r9-1 run --status
expect "status, a package that provides box64 (box64-git) by hand: ok, left alone" \
  "ok box64 0.4.6.r9-1 (not OmacVM's: installed by hand, left alone)" "$OUT"
OLD=$OMACVM
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run --status
expect "status, OmacVM's under the old name box64: needed" "needed box64 $V under its old package name: omacvm apply" "$OUT"
# #752: qemu-user's x86_64 rule, loaded after box64's at boot, takes x86_64 programs first.
INSTALLED=$V REGISTERED=yes QEMU=yes run --status
expect "status, ours and qemu-user's x86_64 rule live (#752): broken, names it" \
  "broken box64 $V installed, but x86_64 programs go to qemu-x86_64 first (binfmt): omacvm apply" "$OUT"
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=ours run --status
expect "status, ours and qemu-user's x86_64 rule held back: ok (qemu-i386 stays)" \
  "ok box64 $V runs x86_64 programs and AppImages|box64 qemu-i386" "$OUT|$(entries)"
INSTALLED=$V REGISTERED=yes FEX=yes run --status
expect "status, ours and someone else's x86_64 rule: broken, names it" \
  "broken box64 $V installed, but x86_64 programs go to FEX-x86_64 first (a binfmt rule that is not OmacVM's: remove it to use box64)" "$OUT"
HOLD=ours QEMU=yes run --status
expect "status, off and OmacVM's hold left: needed" \
  "needed qemu-user's x86_64 rule is still held back by OmacVM (/etc/binfmt.d/qemu-x86_64-static.conf): omacvm apply" "$OUT"
BOX64GIT=0.4.6.r9-1 HOLD=ours QEMU=yes run --status
expect "status, box64-git by hand and OmacVM's hold left: needed (not hidden by 'not OmacVM's')" \
  "needed qemu-user's x86_64 rule is still held back by OmacVM (/etc/binfmt.d/qemu-x86_64-static.conf): omacvm apply" "$OUT"
HOLD=own QEMU=yes run --status
expect "status, off and a file of the person's own of that name: off" "off box64 not installed" "$OUT"

# ---------- off ----------
INSTALLED="" QEMU=yes run off
expect "off, none: silent, status 0" "0 " "$CODE $OUT"
expect "off, none: pacman removes nothing, no reload" "no no" "$(called "pacman -R") $(called "systemctl")"
# #751: pacman -Q box64 answers with omacvm-box64 (it provides box64); pacman -R box64 does not.
INSTALLED=$V REGISTERED=yes run off
expect "off, ours (#751): removed by its own name only" "0 yes no" \
  "$CODE $(called "pacman -Rns --noconfirm omacvm-box64") $(called "omacvm-box64 box64")"
expect "off, ours: binfmt rule gone" no "$(registered)"
BOX64=$V REGISTERED=yes run off
expect "off, box64 installed by hand: left alone" "0 no" "$CODE $(called "pacman -Rns")"
BOX64GIT=0.4.6.r9-1 REGISTERED=yes run off
expect "off, box64-git by hand: left alone, its rule too" "0 no yes" "$CODE $(called "pacman -R") $(registered)"
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run off
expect "off, OmacVM's under the old name: removed" "0 yes no" "$CODE $(called "pacman -Rns --noconfirm box64") $(registered)"
# A 4.5 VM where it was on: qemu-user's x86_64 rule comes back at once, and after a restart.
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=ours run off
expect "off, 4.5: package removed, OmacVM's hold gone, one reload" "0 yes none 1" \
  "$CODE $(called "pacman -Rns --noconfirm omacvm-box64") $(hold) $(count "systemctl restart systemd-binfmt")"
expect "off, 4.5: qemu-user's rules back, box64's gone" "qemu-i386 qemu-x86_64" "$(entries)"
expect "off, 4.5: nothing of OmacVM's left in /etc/binfmt.d" "" "$(ls -A "$E" 2>/dev/null)"
expect "off, 4.5: says what it removed" "x86 apps: removing box64|x86 apps: OmacVM's /etc/binfmt.d/qemu-x86_64-static.conf removed" "$(paste -sd'|' - <<<"$OUT")"
boot
expect "off, 4.5, after a restart: as before x86 apps" "qemu-i386 qemu-x86_64" "$(entries)"
HOLD=ours QEMU=yes run off
expect "off, only OmacVM's hold left: given back, one reload, qemu-x86_64 back" "0 none 1 no|qemu-i386 qemu-x86_64" \
  "$CODE $(hold) $(count "systemctl restart") $(called "pacman -R")|$(entries)"
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=own run off
expect "off, the person's own file of that name: left alone" "0 own" "$CODE $(hold)"
INSTALLED=$V REGISTERED=yes HOLD=link run off
expect "off, the person's own link to /dev/null: left alone" "0 link" "$CODE $(hold)"
PACMAN_R=fail INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=ours run off
expect "off, pacman -R fails: status 1, the hold stays, no reload" "1 ours no" "$CODE $(hold) $(called "systemctl")"

# ---------- on ----------
INSTALLED=$V REGISTERED=yes run on
expect "on, already there: no build" "0 no" "$CODE $(called "runuser")"
expect "on, already there: says so" "x86 apps: box64 $V runs x86_64 programs and AppImages" "$OUT"
expect "on, already there, no qemu-user (4.0): hold written, no reload" "ours no" "$(hold) $(called "systemctl")"
INSTALLED=$V REGISTERED=no run on
expect "on, rule lost: registered again, no build" "0 yes no" "$CODE $(registered) $(called "runuser")"
# #752 on a VM that has it on already: fixed by the next apply, no build, no restart.
INSTALLED=$V REGISTERED=yes QEMU=yes run on
expect "on, 4.5 with qemu-user's rule live: held back, rules loaded again, no build" "0 ours no 1" \
  "$CODE $(hold) $(called "runuser") $(count "systemctl restart systemd-binfmt")"
expect "on, 4.5: only box64 takes x86_64 (qemu-i386 stays)" "box64 qemu-i386" "$(entries)"
expect "on, 4.5: the hold file says what it is" "$HOLD_LINE" "$(head -n1 "$E/qemu-x86_64-static.conf")"
go --status
expect "on, 4.5: status ok after" "ok box64 $V runs x86_64 programs and AppImages" "$OUT"
boot
expect "on, 4.5, after a restart: only box64 takes x86_64" "box64 qemu-i386" "$(entries)"
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=ours run on
expect "on, 4.5, held already: nothing to do" "0 no" "$CODE $(called "systemctl")"

MISSING="cmake python" run on
expect "on, fresh VM: built and installed" 0 "$CODE"; [[ $CODE == 0 ]] || echo "$OUT"
expect "on, fresh VM: built as nobody" yes "$(called "runuser -u nobody")"
expect "on, fresh VM: build tools as dependencies, through pkg-add" yes "$(called "pkg-add --asdeps cmake python")"
expect "on, fresh VM: fuse2 through pkg-add, before pacman -U" "pkg-add --asdeps glibc gcc-libs fuse2" \
  "$(grep -B1 '^pacman -U' "$T/calls" | head -1)"
expect "on, fresh VM: build tools removed after" yes "$(called "pacman -Rns --noconfirm cmake python")"
expect "on, fresh VM: binfmt rule registered" yes "$(registered)"
expect "on, fresh VM: last line" "x86 apps: box64 $V runs x86_64 programs and AppImages" "$(tail -1 <<<"$OUT")"
expect "on, fresh VM: built in a folder of its own" yes "$(called "mktemp $T/vartmp/omacvm-box64.")"
expect "on, fresh VM: build folder gone" "" "$(ls -d "$T"/vartmp/omacvm-box64.* 2>/dev/null)"
QEMU=yes MISSING="cmake python" run on
expect "on, fresh 4.5 VM: built, qemu-user's rule held back before pacman -U (its hook loads the rules)" "0 yes" \
  "$CODE $(called "pacman -U: qemu-user's x86_64 rule held back: yes")"
expect "on, fresh 4.5 VM: only box64 takes x86_64" "box64 qemu-i386" "$(entries)"

INSTALLED=0.4.2-1 REGISTERED=yes run on
expect "on, older: rebuilt" "0 yes" "$CODE $(called "pacman -U")"
expect "on, older (pacman -Q box64 answers with omacvm-box64): no pacman -Rdd, the new one in" "no $V" \
  "$(called "pacman -Rdd") $(cat "$S/omacvm-box64.ver" 2>/dev/null)"
BOX64=$V BOX64_PACKAGER=$OLD REGISTERED=yes run on
expect "on, OmacVM's under the old name: swapped for omacvm-box64" "0 yes $V" \
  "$CODE $(called "pacman -Rdd --noconfirm box64") $(cat "$S/omacvm-box64.ver" 2>/dev/null)"
BOX64=0.4.0-1 run on
expect "on, box64 installed by hand: left alone, no build" "0 no" "$CODE $(called "runuser")"
BOX64GIT=0.4.6.r9-1 REGISTERED=yes QEMU=yes run on
expect "on, box64-git by hand: left alone, no build, qemu-user's rule too" "0 no none" "$CODE $(called "runuser") $(hold)"
BOX64GIT=0.4.6.r9-1 REGISTERED=yes QEMU=yes HOLD=ours run on
expect "on, box64-git by hand and OmacVM's hold left: hold given back, no build" "0 no none yes" \
  "$CODE $(called "runuser") $(hold) $([[ -f $B/qemu-x86_64 ]] && echo yes)"
# Someone else's x86_64 rule: named, never switched off by OmacVM.
INSTALLED=$V REGISTERED=yes FEX=yes run on
expect "on, someone else's x86_64 rule: fails, names it, no build" "1 yes no" \
  "$CODE $(grep -q "go to FEX-x86_64 first" <<<"$OUT" && echo yes) $(called "runuser")"
expect "on, someone else's x86_64 rule: its file and its rule stay" "$FEX_RULE yes" \
  "$(cat "$U/FEX-x86_64.conf") $([[ -f $B/FEX-x86_64 ]] && echo yes)"
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=own run on
expect "on, the person's own qemu-x86_64-static.conf: left alone, fails, names the rule" "1 own yes" \
  "$CODE $(hold) $(grep -q "go to qemu-x86_64 first" <<<"$OUT" && echo yes)"
INSTALLED=$V REGISTERED=yes QEMU=yes HOLD=link run on
expect "on, the person's own link to /dev/null: left alone, ok" "0 link" "$CODE $(hold)"

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

# ---------- omacvm check's line (the block from guest/check.sh) ----------
cat > "$T/x86" <<'EOF'
#!/bin/bash
case $1 in --status) echo "$X86_STATUS" ;; --test) exit "${X86_TEST:-0}" ;; esac
EOF
chmod +x "$T/x86"
blk=$(sed -n '/^FEATURE=x86-apps$/,/^FEATURE=""$/p' "$R/src/guest/check.sh" | sed "s#/usr/local/share/omacvm/x86/guest/install.sh#$T/x86#g")
cat > "$T/check" <<EOF
ok()   { echo "ok|\$1|\$2"; }
bad()  { echo "FAIL|\$1|\$2"; }
skip() { echo "skip|\$1|\$2"; }
$blk
EOF
chk() { X86_STATUS=$2 OMACVM_FEATURE_x86_apps=$1 bash "$T/check" 2>&1; }
expect "check, on and ok" "ok|x86 apps|box64 $V runs x86_64 programs and AppImages" \
  "$(chk on "ok box64 $V runs x86_64 programs and AppImages")"
expect "check, on and qemu-user first (#752): FAIL, names it" \
  "FAIL|x86 apps|box64 $V installed, but x86_64 programs go to qemu-x86_64 first (binfmt): omacvm apply" \
  "$(chk on "broken box64 $V installed, but x86_64 programs go to qemu-x86_64 first (binfmt): omacvm apply")"
expect "check, off" "skip|x86 apps|off (omacvm enable x86-apps: x86_64 programs through box64)" "$(chk off "off box64 not installed")"
expect "check, off and OmacVM's box64 still there" "FAIL|x86 apps|off, but OmacVM's box64 is still installed: omacvm apply" \
  "$(chk off "ok box64 $V runs x86_64 programs and AppImages")"
expect "check, off and only OmacVM's hold left: says so" \
  "FAIL|x86 apps|off, but qemu-user's x86_64 rule is still held back by OmacVM (/etc/binfmt.d/qemu-x86_64-static.conf): omacvm apply" \
  "$(chk off "needed qemu-user's x86_64 rule is still held back by OmacVM (/etc/binfmt.d/qemu-x86_64-static.conf): omacvm apply")"
expect "check, off and box64 by hand: skip" "skip|x86 apps|off (omacvm enable x86-apps: x86_64 programs through box64)" \
  "$(chk off "ok box64 0.4.0-1 (not OmacVM's: installed by hand, left alone)")"

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
