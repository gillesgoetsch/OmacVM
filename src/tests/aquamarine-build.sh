#!/bin/bash
# OmacVM's aquamarine for the Mac pointer (cursor hotspots), offline.
# omacvm-aquamarine-build names a build only while it is for the installed
# package version and from this patch (--lib, --status); the pacman hook
# builds again only in a VM that had a build and drops the builds of other
# versions; a build is installed only with the installed library's soname,
# all of its symbols and the hotspot code; the build itself runs as its own
# user id, within the time cap, and takes Omarchy's recipe of the installed
# version with the patch after the recipe's own. omacvm-app-host hands the
# library to the compositor only in a start that asks, and omacvm_app.lua puts
# the pointer on the cursor plane only then. A made-up file system
# (OMACVM_AQUAMARINE_TEST_ROOT), a made-up recipe repository and stand-ins for
# pacman, chown, nproc, flock, setpriv, timeout, objdump, nm and makepkg: no
# root, no network, no compiler.
#   src/tests/aquamarine-build.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/app/guest
BUILD=$G/aquamarine/omacvm-aquamarine-build
PATCH=$G/aquamarine/aquamarine-cursor-plane-hotspot.patch
T=$(mktemp -d "${TMPDIR:-/tmp}/aquamarine-build.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
has() {   # WHAT NEEDLE HAYSTACK
  case $3 in *"$2"*) echo "ok   $1" ;; *) printf 'FAIL %s\n  no %s in: %s\n' "$1" "$2" "$3"; fail=1 ;; esac
}
lacks() {   # WHAT NEEDLE HAYSTACK
  case $3 in *"$2"*) printf 'FAIL %s\n  %s in it\n' "$1" "$2"; fail=1 ;; *) echo "ok   $1" ;; esac
}

V=0.15.1-1.3
AQ=usr/local/lib/omacvm/aquamarine
export CALLS=$T/calls FAKE_VERSION=$V
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY

# ---------- stand-ins: each call is logged ----------
mkdir "$T/bin"
cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
[[ -z $FAKE_VERSION ]] && exit 1
echo "aquamarine $FAKE_VERSION"
EOF
printf '#!/bin/bash\necho "chown $*" >> "$CALLS"\n' > "$T/bin/chown"
printf '#!/bin/bash\necho 4\n' > "$T/bin/nproc"
# The build's fetch and makepkg never run as root's child here: timeout gives
# what a build would (FAKE_BUILD: the library's text, "" = the network is down).
cat > "$T/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >> "$CALLS"
[[ -n ${FAKE_BUILD:-} ]] || { echo "fatal: unable to access 'https://github.com/omacom/omarchy-pkgs.git/': Could not resolve host: github.com" >&2; exit 128; }
printf '%s\n' "$FAKE_BUILD"
EOF
# A "library" is a text file: its first line the soname, then its symbols.
# As the real ones, they fail on an empty file (what a failed build leaves).
printf '#!/bin/bash\n[[ -s $2 ]] || { echo "objdump: $2: file format not recognized" >&2; exit 1; }\necho "  SONAME               $(head -n1 "$2")"\n' > "$T/bin/objdump"
printf '#!/bin/bash\n[[ -s $3 ]] || { echo "nm: $3: no symbols" >&2; exit 1; }\ntail -n +2 "$3" | sed "s/^/0000000000001000 T /"\n' > "$T/bin/nm"
# flock: one build at a time (macOS has none; the lock itself is the kernel's).
printf '#!/bin/bash\necho "flock $*" >> "$CALLS"\n' > "$T/bin/flock"
for tool in git makepkg fakeroot cmake hyprwayland-scanner g++ patch; do
  [[ -e $T/bin/$tool ]] || printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$tool" > "$T/bin/$tool"
done
rm "$T/bin/git" "$T/bin/patch"   # the real ones (the recipe test below)
command -v sha256sum >/dev/null || printf '#!/bin/bash\nexec shasum -a 256 "$@"\n' > "$T/bin/sha256sum"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH

SUM=$(sha256sum < "$PATCH" | cut -d' ' -f1)
STOCK=$'libaquamarine.so.14\n_ZN10Aquamarine8CBackend6createEv\n_ZN10Aquamarine17CDRMAtomicRequest13planePropsPosEv'
OURS=$STOCK$'\n_ZN10Aquamarine17CDRMAtomicRequest17planePropsHotspotEv'

# A guest with Omarchy's aquamarine $V installed; "built": our build of it too.
guest() {   # [built]
  rm -rf "$T/root" && mkdir -p "$T/root/$AQ" "$T/root/usr/lib" "$T/root/var/tmp"
  cp "$PATCH" "$T/root/$AQ/"
  printf '%s\n' "$STOCK" > "$T/root/usr/lib/libaquamarine.so.0.15.1"
  ln -s libaquamarine.so.0.15.1 "$T/root/usr/lib/libaquamarine.so"
  if [[ ${1:-} == built ]]; then
    mkdir "$T/root/$AQ/$V"
    printf '%s\n' "$OURS" > "$T/root/$AQ/$V/libaquamarine.so.14"
    echo "$SUM $V" > "$T/root/$AQ/$V/stamp"
  fi
  : > "$CALLS"
}
run() { OMACVM_AQUAMARINE_TEST_ROOT=$T/root "$BUILD" "$@" 2>> "$T/err"; }
calls() { tr '\n' ';' < "$CALLS"; }

# ---------- --lib and --status: only a build of the installed version, from this patch ----------
guest built
expect "a current build: --lib names its folder" "$T/root/$AQ/$V" "$(run --lib)"
expect "a current build: --status" "built for aquamarine $V" "$(run --status)"
expect "a current build: nothing is built again" "omacvm-aquamarine: $V: up to date" "$(run)"
expect "a current build: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
has "a build takes the lock first, and waits for another at most as long as a build may take" "flock -w 900 9" "$(calls)"
out=$(FAKE_VERSION=0.16.0-1.1 run --lib); expect "the package moved on: --lib names nothing" "1:" "$?:$out"
has "the package moved on: --status says so" "not built for aquamarine 0.16.0-1.1: not built yet" "$(FAKE_VERSION=0.16.0-1.1 run --status)"
echo "0000 $V" > "$T/root/$AQ/$V/stamp"
out=$(run --lib); expect "a build from another patch: --lib names nothing" "1:" "$?:$out"
has "a build from another patch: --status" "out of date (another patch)" "$(run --status)"
guest built; rm "$T/root/$AQ/$V/stamp"
out=$(run --lib); expect "a library without its stamp is never named" "1:" "$?:$out"
guest
out=$(run --lib); expect "no build: --lib names nothing" "1:" "$?:$out"
out=$(FAKE_VERSION="" run --lib); expect "no aquamarine package: --lib names nothing" "1:" "$?:$out"

# ---------- the hook: only a VM that had a build builds again ----------
guest
run --hook > /dev/null; expect "hook, no build before: exit 0" 0 $?
expect "hook, no build before: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
guest built
out=$(FAKE_VERSION=0.16.0-1.1 run --hook); expect "hook after an update, the network down: exit 0 (never fails the update)" 0 $?
has "hook after an update: the old version's build goes" "$V: removed (aquamarine is 0.16.0-1.1)" "$out"
expect "hook after an update: the old library is gone" "" "$(ls "$T/root/$AQ/$V" 2>/dev/null)"
has "hook after an update: builds for the new version, as its own user id" \
  "setpriv --reuid=64918 --regid=64918 --clear-groups --no-new-privs -- env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/bin/core_perl HOME=" "$(calls)"
has "hook after an update: the new version" "--unprivileged 0.16.0-1.1 " "$(calls)"
has "hook after an update: within the time cap" "timeout --kill-after=10 " "$(calls)"
has "a failed build says why" "not built for aquamarine 0.16.0-1.1: build failed: fatal: unable to access" "$(FAKE_VERSION=0.16.0-1.1 run --status)"
guest
out=$(run); expect "a first build that fails before it makes a library: exit 1" 1 $?
has "a first build that fails: said, and kept for --status and the next hook" "build failed: fatal: unable to access" "$out $(run --status)"
: > "$CALLS"; run --hook > /dev/null
has "the hook tries again after a failed first build" "--unprivileged $V " "$(calls)"
out=$(FAKE_VERSION=0.16.0-1.1 run --lib); expect "a failed build: --lib names nothing (Hyprland runs Omarchy's)" "1:" "$?:$out"
: > "$CALLS"
FAKE_VERSION=0.16.0-1.1 run --hook > /dev/null
has "the next hook tries again after a failed build" "--unprivileged 0.16.0-1.1 " "$(calls)"

# ---------- what a build must be before root installs it ----------
guest
out=$(FAKE_BUILD=$OURS run); expect "a build with the soname, the symbols and the hotspot code: exit 0" 0 $?
has "a good build is installed" "$V: built" "$out"
expect "a good build: --lib names it" "$T/root/$AQ/$V" "$(run --lib)"
expect "a good build: under its soname" "libaquamarine.so.14 stamp" "$(ls "$T/root/$AQ/$V" | tr '\n' ' ' | sed 's/ $//')"
guest
out=$(FAKE_BUILD=${OURS/so.14/so.15} run); expect "another soname: exit 1" 1 $?
has "another soname: not installed, and why" "the build is libaquamarine.so.15, Hyprland loads libaquamarine.so.14" "$out"
out=$(run --lib); expect "another soname: --lib names nothing" "1:" "$?:$out"
guest
out=$(FAKE_BUILD=$'libaquamarine.so.14\n_ZN10Aquamarine8CBackend6createEv\n_ZN10Aquamarine17CDRMAtomicRequest17planePropsHotspotEv' run)
has "a symbol of the installed library missing: not installed" "lacks symbols of the installed library" "$out"
guest
out=$(FAKE_BUILD=$STOCK run)
has "Omarchy's library again (the patch did nothing): not installed" "the build does not send cursor hotspots" "$out"
guest; rm "$T/bin/hyprwayland-scanner"
out=$(FAKE_BUILD=$OURS run); expect "a build tool missing: exit 1" 1 $?
has "a build tool missing: said, and omacvm apply adds it (never pacman -S by hand)" "build tools missing: hyprwayland-scanner (omacvm apply adds them)" "$out"
expect "a build tool missing: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
printf '#!/bin/bash\n' > "$T/bin/hyprwayland-scanner"; chmod +x "$T/bin/hyprwayland-scanner"
guest built
run --remove > /dev/null
expect "--remove: the builds go, the patch stays" "aquamarine-cursor-plane-hotspot.patch lock" "$(ls "$T/root/$AQ" | tr '\n' ' ' | sed 's/ $//')"

# ---------- the build itself: Omarchy's recipe of the installed version, the patch after its own ----------
# A recipe repository with two versions; makepkg here only runs prepare() on
# a made-up source tree and "packages" a library.
REPO=$T/recipes
mkdir -p "$REPO/pkgbuilds/aquamarine" && git -C "$REPO" init -q
recipe() {   # PKGREL
  cat > "$REPO/pkgbuilds/aquamarine/PKGBUILD" <<EOF
pkgname=aquamarine
pkgver=0.15.1
pkgrel=$1
source=(omarchy.patch)
sha256sums=(SKIP)
prepare() {
  cd "\$srcdir"/aquamarine-*/
  echo "omarchy $1" >> applied
}
EOF
  echo "omarchy's own patch $1" > "$REPO/pkgbuilds/aquamarine/omarchy.patch"
  git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "aquamarine 0.15.1-$1"
}
recipe 1.1; recipe 1.3; recipe 1.4
cat > "$T/bin/makepkg" <<'EOF'
#!/bin/bash
# What makepkg does with a PKGBUILD, as far as this test looks: prepare() in srcdir, then the package's library.
set -e
echo "makepkg $*" >> "$CALLS"
top=$PWD srcdir=$PWD/src; mkdir -p "$srcdir/aquamarine-0.15.1" pkg/aquamarine/usr/lib
source ./PKGBUILD
for f in "${source[@]}"; do cp "$f" "$srcdir/"; done
patch() { echo "patch $*" | sed "s|$srcdir/||" >> "$srcdir/aquamarine-0.15.1/applied"; }
prepare
{ echo "recipe pkgrel=$pkgrel"; cat "$srcdir/aquamarine-0.15.1/applied"; echo "sums ${sha256sums[*]}"; } > "$top/pkg/aquamarine/usr/lib/libaquamarine.so.0.15.1"
EOF
chmod +x "$T/bin/makepkg"
guest; mkdir "$T/w"
out=$(cd "$T" && OMACVM_AQUAMARINE_TEST_ROOT=$T/root OMACVM_AQUAMARINE_RECIPES=$REPO "$BUILD" --unprivileged "$V" "$T/w" 2> "$T/unpriv.err")
expect "the build: exit 0" 0 $?
has "the build takes the recipe of the installed version, not the newest" "recipe pkgrel=1.3" "$out"
has "the build: Omarchy's own patches first, then ours with no fuzz" "omarchy 1.3;patch -Np1 -F 0 -i omacvm-hotspot.patch" "$(tr '\n' ';' <<< "$out")"
has "the build: makepkg checks our patch by its sha256 too" "sums SKIP $SUM" "$out"
has "the build: no install, no archive, the VM's own packages as dependencies" "makepkg --nodeps --noarchive" "$(calls)"
rm -rf "$T/w"; mkdir "$T/w"
out=$(cd "$T" && OMACVM_AQUAMARINE_TEST_ROOT=$T/root OMACVM_AQUAMARINE_RECIPES=$REPO "$BUILD" --unprivileged 0.16.0-1.1 "$T/w" 2>&1)
expect "a version Omarchy's recipes do not have: exit 1" 1 $?
has "a version Omarchy's recipes do not have: said" "Omarchy's recipes have no aquamarine 0.16.0-1.1" "$out"

# ---------- the patch, the start, Hyprland ----------
for f in include/aquamarine/backend/drm/Atomic.hpp src/backend/drm/DRM.cpp src/backend/drm/impl/Atomic.cpp; do
  has "the patch changes $f" "+++ b/$f" "$(cat "$PATCH")"
done
lacks "the patch changes no public struct (Hyprland is built against Omarchy's headers)" "+++ b/include/aquamarine/backend/DRM.hpp" "$(cat "$PATCH")"
has "the patch asks for the plane after atomic" "drmSetClientCap(gpu->fd, DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT, 1)" "$(cat "$PATCH")"
HOST=$(cat "$G/omacvm-app-host")
has "omacvm-app-host: the library only in a start that asks and only a current build" \
  "if grep -qx 'OMACVM_HWCURSOR=1' \"\$out\" &&
   lib=\$(/$AQ/omacvm-aquamarine-build --lib 2>/dev/null); then" "$HOST"
has "omacvm-app-host: an earlier start's file goes first" 'rm -f "$ptr"' "$HOST"
has "the compositor's unit reads the file, and starts without it" "EnvironmentFile=-/run/omacvm/mac-pointer.env" "$(cat "$G/aquamarine/90-omacvm-mac-pointer.conf")"
has "omacvm_app.lua: the pointer on the cursor plane only with the file" 'io.open("/run/omacvm/mac-pointer.env")' "$(cat "$G/omacvm_app.lua")"
lacks "omacvm_app.lua: not for the app's wish alone" 'OMACVM_HWCURSOR=1' "$(cat "$G/omacvm_app.lua")"
INSTALL=$(cat "$G/install.sh")
has "install.sh puts the builder where the hook and omacvm-app-host run it" "AQ=/$AQ" "$INSTALL"
has "install.sh builds only for a start that asks or a VM that has a build" \
  "if grep -qx 'OMACVM_HWCURSOR=1' /run/omacvm/host.env 2>/dev/null || compgen -G \"\$AQ/*/\" > /dev/null; then" "$INSTALL"
has "install.sh adds the build's tools through pkg-add, before the build" "../../guest/pkg-add base-devel git cmake hyprwayland-scanner || true
  \$AQ/omacvm-aquamarine-build >" "$INSTALL"
has "install.sh: the drop-in for every compositor uwsm starts" "/etc/systemd/user/wayland-wm@.service.d/90-omacvm-mac-pointer.conf" "$INSTALL"
HOOK=$(cat "$G/aquamarine/95-omacvm-aquamarine.hook")
has "pacman hook: runs the installed builder" "Exec = /$AQ/omacvm-aquamarine-build --hook" "$HOOK"
has "pacman hook: after aquamarine" "Target = aquamarine" "$HOOK"

exit $fail
