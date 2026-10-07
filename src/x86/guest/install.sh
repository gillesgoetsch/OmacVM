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
# Tests: OMACVM_X86_ROOT puts /proc/sys/fs/binfmt_misc and the test program
# under a scratch folder.
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
ours() { local i; i=$(pacman -Qi "$1" 2>/dev/null) || return 1; grep -q "^Packager *: $PACKAGER" <<<"$i"; }
ver() { pacman -Q "$1" 2>/dev/null | awk '{ print $2 }' || true; }
have() { ver $PKG; }
old() { [[ -n $(ver box64) ]] && ours box64; }   # OmacVM's, under the old name
registered() { [[ -f $BINFMT/box64 ]] && grep -q '^enabled' "$BINFMT/box64"; }
x86_test() {
  local t rc
  t=$(mktemp "$ROOT/tmp/omacvm-x86-test.XXXXXX")
  base64 -d <<<"$HELLO" > "$t"; chmod 755 "$t"
  rc=0; [[ $(BOX64_NOBANNER=1 BOX64_LOG=0 timeout 20 "$t" 2>/dev/null) == x86_64 ]] || rc=1
  rm -f "$t"; return $rc
}

status() {
  local v; v=$(have)
  if [[ -z $v ]]; then
    v=$(ver box64)
    if [[ -z $v ]]; then echo "off box64 not installed"
    elif ours box64; then echo "needed box64 $v under its old package name: omacvm apply"
    else echo "ok box64 $v (not OmacVM's: installed by hand, left alone)"; fi
  elif ! ours $PKG; then echo "ok box64 $v (not OmacVM's: installed by hand, left alone)"
  elif (( $(vercmp "$v" "$VER") < 0 )); then echo "needed box64 $v is older than $VER: omacvm apply"
  elif ! registered; then echo "broken box64 $v installed, but x86_64 programs are not handed to it (binfmt): omacvm apply"
  else echo "ok box64 $v runs x86_64 programs and AppImages"; fi
}

binfmt_reload() {
  # systemd's pacman hook does this on install; on removal it may not.
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
  (( ${#rm[@]} )) || exit 0
  echo "x86 apps: removing box64"
  pacman -Rns --noconfirm "${rm[@]}" >>"$LOG" 2>&1 || { echo "x86 apps: pacman could not remove box64 (details in $LOG)" >&2; exit 1; }
  binfmt_reload off
  ! registered || { echo "x86 apps: box64 removed, but its binfmt rule is still there (reboot)" >&2; exit 1; }
  exit 0
fi

s=$(status)
if [[ ${s%% *} == ok ]]; then
  echo "x86 apps: ${s#* }"; exit 0
fi
if [[ ${s%% *} == broken ]]; then
  binfmt_reload on
  if registered; then echo "x86 apps: box64 $(have) (binfmt rule registered again)"; exit 0; fi
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
