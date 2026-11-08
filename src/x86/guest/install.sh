#!/bin/bash
# x86 apps (as root, in the VM): x86_64 Linux programs and AppImages run on
# the VM's ARM CPU through box64. Arch Linux ARM has no box64 package, so this
# builds the one in PKGBUILD here (pinned commit, a few minutes) and installs
# it with pacman; its binfmt rule makes x86_64 programs start like native ones.
#   install.sh on        build and install box64 if it is missing or older
#   install.sh off       remove OmacVM's box64 package (silent when there is none)
#   install.sh --status  one line: STATE DETAIL, STATE one of
#                        ok | off | needed | broken
#   install.sh --test    run a tiny x86_64 program through the binfmt rule
# The package is omacvm-box64 (provides box64): a package named box64 would be
# swapped for the AUR's by Omarchy's update. One named box64 is someone else's,
# or OmacVM's from before the rename (replaced on the next apply).
# While it is on, x86_64 programs go to box64 only. Omarchy 4.5 has
# qemu-user-static-binfmt, whose x86_64 rule systemd-binfmt loads after
# box64's (file-name order) at every boot, so the kernel tries it first (#752).
# OmacVM holds that one rule back with a file of its own of the same name in
# /etc/binfmt.d (it hides the /usr/lib one) and removes it when off; qemu-user's
# other rules stay. A file of that name that is not OmacVM's is left alone.
# Tests: OMACVM_X86_ROOT puts /proc/sys/fs/binfmt_misc, /etc/binfmt.d and the
# test program under a scratch folder.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(bash -c 'source ./PKGBUILD; echo "$pkgver-$pkgrel"')
ROOT=${OMACVM_X86_ROOT:-}
BINFMT=$ROOT/proc/sys/fs/binfmt_misc
LOG=$ROOT/var/log/omacvm-x86-apps.log
PACKAGER="OmacVM <omacvm@users.noreply.github.com>"
# Packages only through guest/pkg-add: never an update of one the VM has.
PKG_ADD=${OMACVM_PKG_ADD:-$PWD/../../guest/pkg-add}

# A 160-byte static x86_64 program: write(1, "x86_64\n"), exit(0).
HELLO=f0VMRgIBAQAAAAAAAAAAAAIAPgABAAAAeABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAOAABAAAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAoAAAAAAAAACgAAAAAAAAAAAQAAAAAAAAuAEAAAC/AQAAAEiNNRAAAAC6BwAAAA8FuDwAAAAx/w8FeDg2XzY0Cg==

# (pacman's output read whole first: grep -q could end the pipe early, and pipefail
# would count pacman's SIGPIPE as "not ours")
PKG=omacvm-box64
# pacman's field names follow the locale ("Packager" is 打包者 in Chinese): read in C.
ours() { local i; i=$(LC_ALL=C pacman -Qi "$1" 2>/dev/null) || return 1; grep -q "^Packager *: $PACKAGER" <<<"$i"; }
ver() { pacman -Q "$1" 2>/dev/null | awk '{ print $2 }' || true; }
have() { ver $PKG; }
# OmacVM's, under the old name: a package named box64. Not one that provides it
# (pacman -Q box64 also answers with omacvm-box64; pacman -R box64 does not, #751).
old() { [[ $(pacman -Qq box64 2>/dev/null) == box64 ]] && ours box64; }
registered() { [[ -f $BINFMT/box64 ]] && grep -q '^enabled' "$BINFMT/box64"; }

# The other binfmt rules that take x86_64 programs (an x86_64 ELF, executable or
# PIE, matches the rule's magic under its mask), as the kernel matches them.
X86_ELF=(7f454c4602010100000000000000000002003e00 7f454c4602010100000000000000000003003e00)
takes_x86() {
  local f=$1 m k o h i x y z hit
  grep -qx enabled "$f" 2>/dev/null || return 1
  m=$(sed -n 's/^magic //p' "$f"); k=$(sed -n 's/^mask //p' "$f"); o=$(sed -n 's/^offset //p' "$f")
  # hex only (it goes into arithmetic), at the start of the file, within the header
  [[ $m =~ ^([0-9a-f][0-9a-f])+$ && ( -z $k || $k =~ ^[0-9a-f]+$ ) && ${o:-0} == 0 && ${#m} -le 40 ]] || return 1
  for h in "${X86_ELF[@]}"; do
    hit=1
    for (( i = 0; i < ${#m}; i += 2 )); do
      x=${h:i:2} y=${m:i:2} z=${k:i:2}
      (( ((0x$x ^ 0x$y) & 0x${z:-ff}) == 0 )) || { hit=0; break; }
    done
    (( hit )) && return 0
  done
  return 1
}
x86_others() {   # their names, space separated
  local e n l=""
  for e in "$BINFMT"/*; do
    n=${e##*/}
    [[ -f $e && $n != register && $n != status && $n != box64 ]] || continue
    if takes_x86 "$e"; then l+=" $n"; fi
  done
  echo "${l# }"
}

# qemu-user's x86_64 rule, held back while x86 apps is on.
QEMU_HOLD=$ROOT/etc/binfmt.d/qemu-x86_64-static.conf
HOLD_LINE='# OmacVM x86 apps: x86_64 programs go to box64, not to qemu-user (#752).'
held() { [[ -f $QEMU_HOLD && ! -L $QEMU_HOLD ]] && [[ $(head -n1 "$QEMU_HOLD") == "$HOLD_LINE" ]]; }
hold() {   # only where there is no file of that name yet
  [[ -e $QEMU_HOLD || -L $QEMU_HOLD ]] && return 0
  install -d -m755 "${QEMU_HOLD%/*}"
  printf '%s\n' "$HOLD_LINE" "# Removed when x86 apps is switched off (omacvm disable x86-apps). Empty: no rules." > "$QEMU_HOLD"
  chmod 644 "$QEMU_HOLD"
}
give_back() { held || return 1; rm -f "$QEMU_HOLD"; }   # true when it removed OmacVM's file
# Someone else's box64 (installed by hand): left alone, and so is qemu-user's rule.
foreign() {
  if [[ -n $(have) ]]; then
    if ours $PKG; then return 1; fi
    return 0
  fi
  [[ -n $(ver box64) ]] && ! old
}
x86_test() {
  local t rc
  t=$(mktemp "$ROOT/tmp/omacvm-x86-test.XXXXXX")
  base64 -d <<<"$HELLO" > "$t"; chmod 755 "$t"
  rc=0; [[ $(BOX64_NOBANNER=1 BOX64_LOG=0 timeout 20 "$t" 2>/dev/null) == x86_64 ]] || rc=1
  rm -f "$t"; return $rc
}

status() {
  local v o; v=$(have)
  if [[ -n $v ]] && ours $PKG; then
    if (( $(vercmp "$v" "$VER") < 0 )); then echo "needed box64 $v is older than $VER: omacvm apply"
    elif ! registered; then echo "broken box64 $v installed, but x86_64 programs are not handed to it (binfmt): omacvm apply"
    elif o=$(x86_others); [[ -n $o ]]; then
      # qemu-user's x86_64 rule: OmacVM holds it back; any other rule is left alone
      if [[ $o == qemu-x86_64 ]] && { held || [[ ! -e $QEMU_HOLD && ! -L $QEMU_HOLD ]]; }; then
        echo "broken box64 $v installed, but x86_64 programs go to $o first (binfmt): omacvm apply"
      else echo "broken box64 $v installed, but x86_64 programs go to $o first (a binfmt rule that is not OmacVM's: remove it to use box64)"; fi
    else echo "ok box64 $v runs x86_64 programs and AppImages"; fi
  elif old; then echo "needed box64 $(ver box64) under its old package name: omacvm apply"
  elif held; then echo "needed qemu-user's x86_64 rule is still held back by OmacVM (${QEMU_HOLD#"$ROOT"}): omacvm apply"
  elif v=${v:-$(ver box64)}; [[ -n $v ]]; then echo "ok box64 $v (not OmacVM's: installed by hand, left alone)"
  else echo "off box64 not installed"; fi
}

binfmt_reload() {
  # systemd's pacman hook does this on install; on removal it may not. Every
  # rule out, then the binfmt.d files: qemu-user's x86_64 rule goes or comes back.
  systemctl restart systemd-binfmt >>"$LOG" 2>&1 || true
  if [[ $1 == off && -f $BINFMT/box64 ]]; then echo -1 > "$BINFMT/box64" 2>/dev/null || true; fi
}

case ${1:-} in
  --status) status; exit 0 ;;
  --test) x86_test; exit ;;
  on|off) ;;
  *) echo "usage: install.sh on|off|--status|--test" >&2; exit 2 ;;
esac
(( EUID == 0 )) || [[ -n $ROOT ]] || { echo "x86 apps: run as root" >&2; exit 1; }

if [[ $1 == off ]]; then
  rm=()
  [[ -n $(have) ]] && ours $PKG && rm+=("$PKG")
  old && rm+=(box64)
  if (( ${#rm[@]} )); then
    echo "x86 apps: removing box64"
    pacman -Rns --noconfirm "${rm[@]}" >>"$LOG" 2>&1 || { echo "x86 apps: pacman could not remove box64 (details in $LOG)" >&2; exit 1; }
  fi
  # After pacman: a removal that failed keeps qemu-user's rule held back.
  gave=no
  if give_back; then gave=yes; echo "x86 apps: qemu-user's x86_64 rule back"; fi
  if (( ${#rm[@]} )); then
    binfmt_reload off
    ! registered || { echo "x86 apps: box64 removed, but its binfmt rule is still there (reboot)" >&2; exit 1; }
  elif [[ $gave == yes ]]; then
    binfmt_reload on
  fi
  exit 0
fi

if foreign; then
  if give_back; then binfmt_reload on; fi
  s=$(status); echo "x86 apps: ${s#* }"; exit 0
fi
# Before any pacman -U: its hook loads the binfmt rules too.
hold
s=$(status)
if [[ ${s%% *} == ok ]]; then
  echo "x86 apps: ${s#* }"; exit 0
fi
if [[ ${s%% *} == broken ]]; then
  binfmt_reload on
  s=$(status)
  if [[ ${s%% *} == ok ]]; then echo "x86 apps: box64 $(have) (binfmt rules loaded again)"; exit 0; fi
  if registered; then echo "x86 apps: ${s#* }" >&2; exit 1; fi
fi

echo "x86 apps: building box64 $VER (a few minutes, log $LOG)"
deps=(base-devel)
while IFS= read -r d; do deps+=("$d"); done < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${makedepends[@]}"')
missing=$(pacman -T "${deps[@]}" || true)
B=$(mktemp -d /var/tmp/omacvm-box64.XXXXXX)
cleanup() {
  rm -rf "$B"
  if [[ -n $missing ]]; then
    # shellcheck disable=SC2086 # one package per word
    pacman -Rns --noconfirm $missing >>"$LOG" 2>&1 || echo "x86 apps: build tools left installed (pacman -Rns did not take them all)"
  fi
}
trap cleanup EXIT
fail() { echo "x86 apps: $1 (details in $LOG)" >&2; exit 1; }
: > "$LOG"
if [[ -n $missing ]]; then
  # shellcheck disable=SC2086 # one package per word
  "$PKG_ADD" --asdeps $missing || fail "the build tools are not installed"
fi
install -m644 PKGBUILD "$B/"
chown -R nobody: "$B"
# makepkg refuses root: build as nobody (it downloads and checks the sha256 itself).
( cd "$B" && runuser -u nobody -- env HOME="$B" PKGDEST="$B" BUILDDIR="$B/build" SRCDEST="$B" LOGDEST="$B" PACKAGER="$PACKAGER" \
    makepkg --nodeps --noconfirm --noprogressbar ) >>"$LOG" 2>&1 || fail "the build failed"
pkg=""
for f in "$B/$PKG-$VER"-aarch64.pkg.tar.*; do [[ -f $f ]] && pkg=$f; done
[[ -n $pkg ]] || fail "the build made no package"
# OmacVM's box64 under the old name first (the two conflict); fuse2 stays.
if old; then pacman -Rdd --noconfirm box64 >>"$LOG" 2>&1 || fail "pacman could not remove the old box64 package"; fi
# Its libraries (fuse2) through pkg-add too, so pacman -U installs nothing else.
# shellcheck disable=SC2046 # one package per word
"$PKG_ADD" --asdeps $(bash -c 'source ./PKGBUILD; echo "${depends[@]}"') || fail "box64's libraries are not installed"
pacman -U --noconfirm --needed "$pkg" >>"$LOG" 2>&1 || fail "pacman could not install $(basename "$pkg")"
registered || binfmt_reload on
s=$(status)
[[ ${s%% *} == ok ]] || fail "installed, but: ${s#* }"
x86_test || fail "installed, but a test x86_64 program did not run"
echo "x86 apps: ${s#* }"
