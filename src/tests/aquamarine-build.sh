#!/bin/bash
# OmacVM's aquamarine for the Mac pointer (cursor hotspots), offline.
# omacvm-aquamarine-build names a build only while it is for the installed
# package version and from this patch and pinned recipe (--lib, --env,
# --status); a build drops the builds of other versions; a build is installed
# only with the installed library's soname, all of its symbols and the hotspot
# code; the build itself runs as its own user id, within the time cap, and
# takes only the pinned recipe of the installed version (each file checked by
# its sha256) with the patch after the recipe's own; once Omarchy's library
# sends the hotspots nothing is built and --env names Omarchy's.
# omacvm-app-host hands the library to the compositor only in a start that
# asks, and omacvm_app.lua puts the pointer on the cursor plane only then. A
# made-up file system (OMACVM_AQUAMARINE_TEST_ROOT), a made-up recipe server
# (file://) and stand-ins for pacman, chown, nproc, flock, setpriv, timeout,
# objdump, nm and makepkg: no root, no network, no compiler.
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
for tool in makepkg fakeroot cmake hyprwayland-scanner g++; do
  [[ -e $T/bin/$tool ]] || printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$tool" > "$T/bin/$tool"
done   # curl and patch: the real ones (the recipe test below)
command -v sha256sum >/dev/null || printf '#!/bin/bash\nexec shasum -a 256 "$@"\n' > "$T/bin/sha256sum"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH

SUM=$(sha256sum < "$PATCH" | cut -d' ' -f1)
sum() { sha256sum < "$1" | cut -d' ' -f1; }
# The pinned recipes the guest has (the recipe test below serves them).
C1=1111111111111111111111111111111111111111 C3=3333333333333333333333333333333333333333
SRV=$T/srv; mkdir -p "$SRV"
serve() {   # COMMIT PKGREL: Omarchy's recipe of 0.15.1-PKGREL at COMMIT
  local d=$SRV/$1/pkgbuilds/aquamarine
  mkdir -p "$d"
  cat > "$d/PKGBUILD" <<EOF2
pkgname=aquamarine
pkgver=0.15.1
pkgrel=$2
source=(omarchy.patch)
sha256sums=(SKIP)
prepare() {
  cd "\$srcdir"/aquamarine-*/
  echo "omarchy $2" >> applied
}
EOF2
  echo "omarchy's own patch $2" > "$d/omarchy.patch"
}
serve $C1 1.1; serve $C3 1.3
pin() { echo "$1 $2 PKGBUILD=$(sum "$SRV/$2/pkgbuilds/aquamarine/PKGBUILD") omarchy.patch=$(sum "$SRV/$2/pkgbuilds/aquamarine/omarchy.patch")"; }
RECIPES=$(printf '# pinned\n%s\n%s\n' "$(pin 0.15.1-1.1 $C1)" "$(pin $V $C3)")
LINE=$(pin $V $C3); LINE=${LINE#"$V "}
STAMP="$SUM $(printf '%s\n' "$LINE" | sha256sum | cut -c1-16) $V"
STOCK=$'libaquamarine.so.14\n_ZN10Aquamarine8CBackend6createEv\n_ZN10Aquamarine17CDRMAtomicRequest13planePropsPosEv'
OURS=$STOCK$'\n_ZN10Aquamarine17CDRMAtomicRequest17planePropsHotspotEv'

# A guest with Omarchy's aquamarine $V installed; "built": our build of it too.
guest() {   # [built]
  rm -rf "$T/root" && mkdir -p "$T/root/$AQ" "$T/root/usr/lib" "$T/root/var/tmp"
  cp "$PATCH" "$T/root/$AQ/"
  printf '%s\n' "$RECIPES" > "$T/root/$AQ/recipes"
  printf '%s\n' "$STOCK" > "$T/root/usr/lib/libaquamarine.so.0.15.1"
  ln -s libaquamarine.so.0.15.1 "$T/root/usr/lib/libaquamarine.so"
  if [[ ${1:-} == built ]]; then
    mkdir "$T/root/$AQ/$V"
    printf '%s\n' "$OURS" > "$T/root/$AQ/$V/libaquamarine.so.14"
    echo "$STAMP" > "$T/root/$AQ/$V/stamp"
  fi
  : > "$CALLS"
}
run() { OMACVM_AQUAMARINE_TEST_ROOT=$T/root "$BUILD" "$@" 2>> "$T/err"; }
calls() { tr '\n' ';' < "$CALLS"; }

# ---------- --lib and --status: only a build of the installed version, from this patch ----------
guest built
expect "a current build: --lib names its folder" "$T/root/$AQ/$V" "$(run --lib)"
expect "a current build: --env hands it to the compositor" "LD_LIBRARY_PATH=$T/root/$AQ/$V" "$(run --env)"
expect "a current build: --status" "built for aquamarine $V" "$(run --status)"
expect "a current build: nothing is built again" "omacvm-aquamarine: $V: up to date" "$(run)"
expect "a current build: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
has "a build takes the lock first, and waits for another at most as long as a build may take" "flock -w 900 9" "$(calls)"
out=$(FAKE_VERSION=0.16.0-1.1 run --lib); expect "the package moved on: --lib names nothing" "1:" "$?:$out"
has "the package moved on: --status says so" "not built for aquamarine 0.16.0-1.1: no pinned recipe for this version yet" "$(FAKE_VERSION=0.16.0-1.1 run --status)"
echo "0000 ${STAMP#* }" > "$T/root/$AQ/$V/stamp"
out=$(run --lib); expect "a build from another patch: --lib names nothing" "1:" "$?:$out"
out=$(run --env); expect "a build from another patch: --env names nothing" "1:" "$?:$out"
has "a build from another patch: --status" "out of date (another patch or recipe)" "$(run --status)"
guest built; sed -i.bak "s/omarchy.patch=[0-9a-f]*/omarchy.patch=$(printf '0%.0s' {1..64})/" "$T/root/$AQ/recipes"
out=$(run --lib); expect "a build from another pinned recipe: --lib names nothing" "1:" "$?:$out"
guest built; rm "$T/root/$AQ/$V/stamp"
out=$(run --lib); expect "a library without its stamp is never named" "1:" "$?:$out"
guest
out=$(run --lib); expect "no build: --lib names nothing" "1:" "$?:$out"
out=$(FAKE_VERSION="" run --lib); expect "no aquamarine package: --lib names nothing" "1:" "$?:$out"

# ---------- an update: the old build goes, the next apply builds the new version ----------
guest built
out=$(FAKE_VERSION=0.15.1-1.1 run); expect "an apply after an update, the network down: exit 1" 1 $?
has "an apply after an update: the old version's build goes" "$V: removed (aquamarine is 0.15.1-1.1)" "$out"
expect "an apply after an update: the old library is gone" "" "$(ls "$T/root/$AQ/$V" 2>/dev/null)"
has "an apply after an update: builds for the new version, as its own user id" \
  "setpriv --reuid=64918 --regid=64918 --clear-groups --no-new-privs -- env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/bin/core_perl HOME=" "$(calls)"
has "an apply after an update: the new version" "--unprivileged 0.15.1-1.1 " "$(calls)"
has "an apply after an update: within the time cap" "timeout --kill-after=10 " "$(calls)"
has "a failed build says why" "not built for aquamarine 0.15.1-1.1: build failed: fatal: unable to access" "$(FAKE_VERSION=0.15.1-1.1 run --status)"
out=$(FAKE_VERSION=0.15.1-1.1 run --env); expect "a failed build: --env names nothing (Hyprland runs Omarchy's)" "1:" "$?:$out"
guest built
out=$(FAKE_VERSION=0.16.0-1.1 FAKE_BUILD=$OURS run); expect "a version with no pinned recipe: exit 1" 1 $?
has "a version with no pinned recipe: said, nothing fetched" "no pinned recipe for this version" "$out"
expect "a version with no pinned recipe: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
has "a version with no pinned recipe: --status says so" "not built for aquamarine 0.16.0-1.1: build failed: no pinned recipe" "$(FAKE_VERSION=0.16.0-1.1 run --status)"
expect "no pacman hook: nothing runs inside an update" "" "$(ls "$G/aquamarine" | grep -F .hook)"
lacks "no pacman hook is installed" "pacman.d/hooks/95-omacvm-aquamarine" "$(cat "$G/install.sh")"

# ---------- Omarchy's library sends the hotspots: nothing built, the Mac pointer on Omarchy's ----------
guest built
printf '%s\n' "$OURS" > "$T/root/usr/lib/libaquamarine.so.0.15.1"
expect "Omarchy's library with the hotspots: --env names Omarchy's, not ours" "OMACVM_MAC_POINTER=omarchy" "$(run --env)"
has "Omarchy's library with the hotspots: --status" "Omarchy's aquamarine $V sends cursor hotspots" "$(run --status)"
out=$(run); expect "Omarchy's library with the hotspots: a build is a no-op: exit 0" 0 $?
has "Omarchy's library with the hotspots: ours goes" "nothing to build" "$out"
expect "Omarchy's library with the hotspots: our folder is gone" "" "$(ls "$T/root/$AQ/$V" 2>/dev/null)"
expect "Omarchy's library with the hotspots: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"

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
guest
out=$(FAKE_VERSION=1:0.16.0-1 FAKE_BUILD=$OURS run); expect "a version with an epoch (its colon would split LD_LIBRARY_PATH): exit 1" 1 $?
has "a version with an epoch: no build, said" "not a package version: 1:0.16.0-1" "$out"
out=$(FAKE_VERSION=1:0.16.0-1 run --lib); expect "a version with an epoch: --lib names nothing" "1:" "$?:$out"
guest; rm "$T/bin/hyprwayland-scanner"
out=$(FAKE_BUILD=$OURS run); expect "a build tool missing: exit 1" 1 $?
has "a build tool missing: said, and omacvm apply adds it (never pacman -S by hand)" "build tools missing: hyprwayland-scanner (omacvm apply adds them)" "$out"
expect "a build tool missing: nothing fetched" "" "$(grep -E '^(timeout|chown)' "$CALLS")"
printf '#!/bin/bash\n' > "$T/bin/hyprwayland-scanner"; chmod +x "$T/bin/hyprwayland-scanner"
guest built
run --remove > /dev/null
expect "--remove: the builds go, the patch and the pins stay" "aquamarine-cursor-plane-hotspot.patch lock recipes" "$(ls "$T/root/$AQ" | tr '\n' ' ' | sed 's/ $//')"

# ---------- the build itself: the pinned recipe of the installed version, the patch after its own ----------
# makepkg here only runs prepare() on a made-up source tree and "packages" a library.
cat > "$T/bin/makepkg" <<'EOF2'
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
EOF2
chmod +x "$T/bin/makepkg"
unpriv() {   # VERSION
  rm -rf "$T/w"; mkdir "$T/w"
  (cd "$T" && OMACVM_AQUAMARINE_TEST_ROOT=$T/root OMACVM_AQUAMARINE_RECIPES=file://$SRV "$BUILD" --unprivileged "$1" "$T/w" 2>&1)
}
guest
out=$(unpriv "$V"); expect "the build: exit 0" 0 $?
has "the build takes the pinned recipe of the installed version, not another" "recipe pkgrel=1.3" "$out"
has "the build: Omarchy's own patches first, then ours with no fuzz" "omarchy 1.3;patch -Np1 -F 0 -i omacvm-hotspot.patch" "$(tr '\n' ';' <<< "$out")"
has "the build: makepkg checks our patch by its sha256 too" "sums SKIP $SUM" "$out"
has "the build: no install, no archive, the VM's own packages as dependencies" "makepkg --nodeps --noarchive" "$(calls)"
echo "changed upstream" >> "$SRV/$C3/pkgbuilds/aquamarine/omarchy.patch"
out=$(unpriv "$V"); expect "a recipe file that does not match its pin: exit 1" 1 $?
has "a recipe file that does not match its pin: said" "omarchy.patch of Omarchy's recipe $C3 does not match its pinned sha256" "$out"
lacks "a recipe file that does not match its pin: makepkg never runs" "recipe pkgrel" "$out"
serve $C3 1.3
out=$(unpriv 0.16.0-1.1); expect "a version with no pinned recipe: exit 1" 1 $?
has "a version with no pinned recipe: said" "no pinned recipe for aquamarine 0.16.0-1.1" "$out"
guest; printf '0.15.1-1.3 %s ../PKGBUILD=%s\n' "$C3" "$(printf '0%.0s' {1..64})" > "$T/root/$AQ/recipes"
out=$(unpriv "$V"); expect "a pinned file name with a path: exit 1" 1 $?
has "a pinned file name with a path: refused" "not a pinned file: ../PKGBUILD=" "$out"
guest; printf '0.15.1-1.3 main PKGBUILD=%s\n' "$(sum "$SRV/$C3/pkgbuilds/aquamarine/PKGBUILD")" > "$T/root/$AQ/recipes"
out=$(unpriv "$V"); expect "a pin that is no commit (a branch moves): exit 1" 1 $?
has "a pin that is no commit: refused" "not a commit: main" "$out"
has "the real builder fetches over https only" "proto='=https'" "$(cat "$BUILD")"
while read -r v c rest; do
  [[ $v == \#* || -z $v ]] && continue
  [[ $c =~ ^[0-9a-f]{40}$ ]]; expect "recipes: $v is pinned to a full commit" 0 $?
  has "recipes: $v pins its PKGBUILD" "PKGBUILD=" "$rest"
done < "$G/aquamarine/recipes"

# ---------- the patch, the start, Hyprland ----------
for f in include/aquamarine/backend/drm/Atomic.hpp src/backend/drm/DRM.cpp src/backend/drm/impl/Atomic.cpp; do
  has "the patch changes $f" "+++ b/$f" "$(cat "$PATCH")"
done
lacks "the patch changes no public struct (Hyprland is built against Omarchy's headers)" "+++ b/include/aquamarine/backend/DRM.hpp" "$(cat "$PATCH")"
has "the patch asks for the plane after atomic" "drmSetClientCap(gpu->fd, DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT, 1)" "$(cat "$PATCH")"
HOST=$(cat "$G/omacvm-app-host")
has "omacvm-app-host: the library only in a start that asks and only a current build" \
  "if grep -qx 'OMACVM_HWCURSOR=1' \"\$out\" &&
   env=\$(/$AQ/omacvm-aquamarine-build --env 2>/dev/null); then" "$HOST"
has "omacvm-app-host: an earlier start's file goes first" 'rm -f "$ptr"' "$HOST"
has "the compositor's unit reads the file, and starts without it" "EnvironmentFile=-/run/omacvm/mac-pointer.env" "$(cat "$G/aquamarine/90-omacvm-mac-pointer.conf")"
has "omacvm_app.lua: the pointer on the cursor plane only with the file" 'io.open("/run/omacvm/mac-pointer.env")' "$(cat "$G/omacvm_app.lua")"
lacks "omacvm_app.lua: not for the app's wish alone" 'OMACVM_HWCURSOR=1' "$(cat "$G/omacvm_app.lua")"
INSTALL=$(cat "$G/install.sh")
has "install.sh puts the builder where the hook and omacvm-app-host run it" "AQ=/$AQ" "$INSTALL"
has "install.sh builds only for a start that asks" \
  "if grep -qx 'OMACVM_HWCURSOR=1' /run/omacvm/host.env 2>/dev/null; then" "$INSTALL"
has "install.sh installs the pinned recipes beside the builder" "install -Dm644 aquamarine/recipes \$AQ/recipes" "$INSTALL"
has "install.sh adds the build's tools through pkg-add, before the build" "../../guest/pkg-add base-devel cmake hyprwayland-scanner || true
  \$AQ/omacvm-aquamarine-build >" "$INSTALL"
has "install.sh: the drop-in for every compositor uwsm starts" "/etc/systemd/user/wayland-wm@.service.d/90-omacvm-mac-pointer.conf" "$INSTALL"
exit $fail
