#!/bin/bash
# Offline test of src/app/guest/venus (no VM): when an OmacVM.app VM gets the
# Venus driver built from Mesa 26.2.4 (with the WebGPU semaphore patch), and
# that the package, the installer and the check agree. The real build and Vulkan run are tested in a VM (see
# docs/routes/app.md, "Vulkan").
set -u
cd "$(dirname "$0")/../.." || exit 1
D=src/app/guest/venus
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Stand-ins for pacman and vercmp (pacman's own version order for these cases).
cat > "$T/pacman" <<'EOF'
#!/bin/bash
[[ $1 == -Q && -n ${HAVE:-} ]] && { echo "vulkan-virtio $HAVE"; exit 0; }
exit 1
EOF
cat > "$T/vercmp" <<'EOF'
#!/usr/bin/env python3
import re, sys
def key(v):
    e, _, v = v.rpartition(":")
    v, _, r = v.partition("-")
    num = lambda s: [int(x) for x in re.findall(r"\d+", s)]
    return (int(e or 0), num(v), num(r))
a, b = key(sys.argv[1]), key(sys.argv[2])
print((a > b) - (a < b))
EOF
# ldd: what the driver links ($LDD_MISSING: a library that went away).
cat > "$T/ldd" <<'EOF'
#!/bin/bash
echo "	libdrm.so.2 => /usr/lib/libdrm.so.2"
[[ -z ${LDD_MISSING:-} ]] || echo "	$LDD_MISSING => not found"
EOF
# GNU install -D (macOS's has no -D): the last argument is the target.
cat > "$T/install" <<'EOF'
#!/bin/bash
src=/dev/stdin
while (( $# > 1 )); do case $1 in -D*|-m*) ;; *) src=$1 ;; esac; shift; done
mkdir -p "$(dirname "$1")" && cat "$src" > "$1"
EOF
chmod +x "$T/pacman" "$T/vercmp" "$T/ldd" "$T/install"
: > "$T/libvulkan_virtio.so"
export OMACVM_VENUS_LIB=$T/libvulkan_virtio.so

st() {   # PROBE HAVE -> the state word
  PATH="$T:$PATH" OMACVM_VENUS_PROBE=$1 HAVE=$2 "$D/vulkan-virtio.sh" --status | cut -d' ' -f1
}
expect() {   # NAME PROBE HAVE WANT
  local got; got=$(st "$2" "$3")
  [[ $got == "$4" ]] && pass "$1: $4" || fail "$1: got '$got', want '$4'"
}
V="venus=1 blob_alignment=16384"
expect "Vulkan off in the app"           "venus=0 blob_alignment=0" "1:26.2.3-1"   no-venus
expect "4 KiB pages (no alignment)"      "venus=1 blob_alignment=4096" "1:26.2.3-1" no-pages
expect "old kernel (alignment unknown)"  "venus=1 blob_alignment=0" "1:26.2.3-1"    no-pages
expect "Arch Linux ARM's 26.2.3"         "$V" "1:26.2.3-1"   needed
expect "no Venus driver at all"          "$V" ""             needed
O=1:26.2.4.omacvm1-1
expect "ours (26.2.4 + WebGPU patch)"    "$V" "$O"           ok
expect "ours from 3.0.0 (26.2.4-0.1)"    "$V" "1:26.2.4-0.1" update
expect "the distro's 26.2.4"             "$V" "1:26.2.4-1"   update
expect "a distro rebuild of 26.2.4"      "$V" "1:26.2.4-3"   update
expect "a newer Mesa"                    "$V" "1:26.3.1-2"   ok
[[ $(PATH="$T:$PATH" OMACVM_VENUS_PROBE=$V HAVE=1:26.3.1-2 "$D/vulkan-virtio.sh" --status) == *"no shared semaphores for WebGPU"* ]] &&
  pass "a newer Mesa: says WebGPU waits for our build" || fail "a newer Mesa: no word on WebGPU"
[[ $(PATH="$T:$PATH" OMACVM_VENUS_PROBE=$V HAVE=$O "$D/vulkan-virtio.sh" --status) != *WebGPU* ]] &&
  pass "ours: nothing about WebGPU missing" || fail "ours: says WebGPU is missing"
got=$(PATH="$T:$PATH" LDD_MISSING=libdisplay-info.so.2 OMACVM_VENUS_PROBE=$V HAVE=$O "$D/vulkan-virtio.sh" --status | cut -d' ' -f1)
[[ $got == needed ]] && pass "ours with a library gone: needed (rebuilt)" || fail "ours with a library gone: got '$got'"
got=$(PATH="$T:$PATH" LDD_MISSING=libdisplay-info.so.2 OMACVM_VENUS_PROBE=$V HAVE=1:26.3.1-2 "$D/vulkan-virtio.sh" --status | cut -d' ' -f1)
[[ $got == ok ]] && pass "the distro's newer one with a library gone: left to pacman" || fail "distro's newer one, library gone: got '$got'"

# Nothing to do -> silent, exit 0, also as a normal user (apply runs it on every app VM).
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "Vulkan off: silent" || fail "Vulkan off: rc $rc, said '$out'"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=$O "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && $out == "Vulkan (Venus): vulkan-virtio $O sizes GPU memory to 16384-byte pages" ]] &&
  pass "already fixed: one line" || fail "already fixed: rc $rc, said '$out'"
# The 3.0.0 build or the distro's 26.2.4: rebuilt with the patch (root only), not with OmacVM's Mesa.
: > "$T/icd.json"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=1:26.2.4-1 OMACVM_MESA_ICD=$T/icd.json "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "update with OmacVM's Mesa: silent" || fail "update with OmacVM's Mesa: rc $rc, said '$out'"
rm -f "$T/icd.json"
if (( EUID != 0 )); then
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=1:26.2.4-0.1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "update: builds (root only)" || fail "update did not go to the build: rc $rc, said '$out'"
fi

# --ready (the Mac's Automatic waits for it) and --want (omacvm apply, when the
# VM's Graphics gives it Vulkan: built also before the VM has the Venus device).
rd() { PATH="$T:$PATH" HAVE=$1 OMACVM_MESA_ICD=$T/${2:-none}.json "$D/vulkan-virtio.sh" --ready; echo $?; }
[[ $(rd 1:26.2.3-1) == 1 ]] && pass "--ready: 26.2.3 is not" || fail "--ready said yes to 26.2.3"
[[ $(rd "") == 1 ]] && pass "--ready: no driver is not" || fail "--ready said yes without a driver"
[[ $(rd 1:26.2.4-0.1) == 0 ]] && pass "--ready: ours" || fail "--ready said no to 26.2.4-0.1"
[[ $(rd 1:26.3.0-1) == 0 ]] && pass "--ready: a newer distro Mesa" || fail "--ready said no to 26.3.0"
: > "$T/icd.json"
[[ $(rd 1:26.2.3-1 icd) == 0 ]] && pass "--ready: OmacVM's Mesa (vulkan feature)" || fail "--ready said no with OmacVM's Mesa"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=$O OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "--want, driver there, no Venus yet: silent" || fail "--want with the driver: rc $rc, said '$out'"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.3.1-2 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "--want, a newer distro Mesa: silent" || fail "--want over a newer Mesa: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.4-0.1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "--want, 3.0.0's build: rebuilt with the patch (root only)" ||
    fail "--want did not rebuild 26.2.4-0.1: rc $rc, said '$out'"
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "--want, 26.2.3, no Venus yet: builds (root only)" ||
    fail "--want did not go to the build: rc $rc, said '$out'"
fi
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" --nonsense 2>&1); rc=$?
[[ $rc == 2 ]] && pass "unknown option: usage" || fail "unknown option: rc $rc"

# Never a partial upgrade: when installing the build tools would update an
# installed package (package lists newer than the system), the build stops
# before pacman installs anything. Root-only part run as a user on a copy.
P=$T/partial; mkdir -p "$P/venus"; cp -R "$D/." "$P/venus/"
sed -e 's/^(( EUID == 0 )) ||.*$/:/' -e "s#^LOG=.*#LOG=$P/build.log#" "$D/vulkan-virtio.sh" > "$P/venus/vulkan-virtio.sh"
cat > "$P/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
case "$1 $2" in
  "-Q vulkan-virtio") echo "vulkan-virtio 1:26.2.4-0.1"; exit 0 ;;
  "-Q spirv-tools") exit 0 ;;            # installed: the update would be partial
  "-Q "*) exit 1 ;;
  "-T "*) echo glslang; exit 0 ;;
  "-S --print") printf 'glslang\n%s\n' $PULLS; exit 0 ;;
esac
exit 0
EOF
chmod +x "$P/pacman"; cp "$T/vercmp" "$T/ldd" "$P/"
CALLS=$P/calls PULLS=spirv-tools PATH="$P:$PATH" OMACVM_VENUS_PROBE="$V" OMACVM_MESA_ICD=$T/none.json \
  bash "$P/venus/vulkan-virtio.sh" > "$P/out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'would update spirv-tools' "$P/out" && ! grep -q 'pacman -S --needed --noconfirm' "$P/calls" &&
  ! grep -q 'pacman -Rns' "$P/calls" && pass "build tools that would update installed packages: stops, installs nothing" ||
  fail "partial upgrade not refused: rc $rc, said '$(cat "$P/out")'"

# The package: Mesa 26.2.4 (blob alignment) + the semaphore patch; it stays over
# the distro's builds of the same Mesa, a newer Mesa replaces it.
eval "$(bash -c "source $D/PKGBUILD"' && declare -p pkgname epoch pkgver pkgrel _mesaver source sha256sums')"
fixed=$(sed -n 's/^FIXED=\([^ ]*\).*/\1/p' "$D/vulkan-virtio.sh")
[[ $pkgname == vulkan-virtio && "$epoch:$_mesaver" == "$fixed" && $pkgver == "$_mesaver".omacvm* ]] &&
  pass "PKGBUILD is $epoch:$pkgver (Mesa ${fixed#*:})" || fail "PKGBUILD $pkgname $epoch:$pkgver vs FIXED $fixed"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:$_mesaver-9") == 1 ]] && pass "ours stays over the distro's $_mesaver-x" ||
  fail "the distro's $_mesaver-9 would replace ours"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:26.3.0-1") == -1 ]] && pass "a newer Mesa replaces ours" ||
  fail "ours would hold back a newer Mesa"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
[[ ${#source[@]} == 2 && ${source[1]} == mesa-venus-opaque-fd-semaphores.patch &&
   ${sha256sums[0]} =~ ^[0-9a-f]{64}$ && ${sha256sums[1]} == "$(sum "$D/patches/${source[1]}")" ]] &&
  pass "sources pinned by sha256 (the patch matches patches/)" || fail "sources not pinned, or the patch changed without its sha256"
grep -q 'install -m644 PKGBUILD patches/mesa-venus-opaque-fd-semaphores.patch "$B/"' "$D/vulkan-virtio.sh" &&
  pass "the build gets the patch" || fail "vulkan-virtio.sh does not hand the patch to makepkg"

# Wired in: apply's app step runs it, check reads it.
grep -q '^venus/vulkan-virtio.sh $want ||' src/app/guest/install.sh && pass "app install runs it" || fail "app install does not run it"
grep -q 'OMACVM_GRAPHICS=//p' src/app/guest/install.sh && pass "app install builds ahead for Graphics Vulkan" || fail "app install ignores OMACVM_GRAPHICS"
grep -q 'ExecStart=/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh$' "$D/omacvm-venus-driver.service" &&
  grep -q 'omacvm-venus-driver.service' src/app/guest/install.sh && pass "boot unit runs it" || fail "no boot unit"
# Never in the boot's critical chain: a timer after the desktop, no
# network-online.target and no [Install] on the service (a build at boot made
# multi-user.target, and with it the desktop, wait for it).
svc=$D/omacvm-venus-driver.service tmr=$D/omacvm-venus-driver.timer
if ! grep -v '^#' "$svc" | grep -q 'network-online' && ! grep -q '^\[Install\]' "$svc" && grep -q '^OnBootSec=' "$tmr" &&
   grep -q '^WantedBy=timers.target' "$tmr" && grep -q 'systemctl enable omacvm-venus-driver.timer' src/app/guest/install.sh &&
   grep -q 'rm -f /etc/systemd/system/multi-user.target.wants/omacvm-venus-driver.service' src/app/guest/install.sh; then
  pass "driver unit runs from a timer after boot, without network-online"
else
  fail "driver unit can delay the boot (network-online, [Install] on the service, or no timer)"
fi
grep -q 'app/guest/venus/vulkan-virtio.sh --status' src/guest/check.sh && pass "check has the Vulkan (Venus) row" || fail "no check row"

# OpenCL on that Vulkan (venus/opencl.sh): apply sets it up for Graphics Vulkan, off for OpenGL,
# leaves it to the vulkan feature's Mesa when that is there; omacvm graphics does it too.
grep -q '^if \[\[ $graphics == vulkan \]\]; then venus/opencl.sh ||' src/app/guest/install.sh &&
  grep -q 'venus/opencl.sh --off' src/app/guest/install.sh && pass "app install sets up OpenCL with Vulkan" ||
  fail "app install does not run venus/opencl.sh"
grep -q 'app/guest/venus/opencl.sh' src/cmd/graphics.sh && pass "omacvm graphics sets up OpenCL" || fail "omacvm graphics skips OpenCL"
grep -q '90-omacvm-opencl.conf' src/guest/check.sh && pass "check has the OpenCL row" || fail "no OpenCL check row"
O=$T/opencl.conf
OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" --nonsense >/dev/null 2>&1
[[ $? == 2 ]] && pass "opencl.sh: unknown option: usage" || fail "opencl.sh: unknown option accepted"
echo RUSTICL_ENABLE=zink > "$O"
OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" --off && [[ ! -e $O ]] &&
  pass "opencl.sh --off removes the switch" || fail "opencl.sh --off kept the switch"
echo RUSTICL_ENABLE=zink > "$O"; : > "$T/ours.icd"
out=$(OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/ours.icd "$D/opencl.sh" 2>&1); rc=$?
[[ $rc == 0 && ! -e $O && $out == *"feature vulkan"* ]] && pass "opencl.sh: OmacVM's Mesa has its own rusticl" ||
  fail "opencl.sh with OmacVM's Mesa: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* && ! -e $O ]] && pass "opencl.sh installs as root only" ||
    fail "opencl.sh as a user: rc $rc, said '$out'"
fi

# WebGPU in Chromium on that Vulkan (venus/webgpu.sh): the launcher with Graphics
# Vulkan; --off keeps it while Graphics Vulkan or the vulkan feature's Mesa gives WebGPU.
grep -q '^if \[\[ $graphics == vulkan \]\]; then venus/webgpu.sh ||' src/app/guest/install.sh &&
  grep -q 'venus/webgpu.sh --off' src/app/guest/install.sh && pass "app install sets up WebGPU with Vulkan" ||
  fail "app install does not run venus/webgpu.sh"
grep -q 'app/guest/venus/webgpu.sh' src/cmd/graphics.sh && pass "omacvm graphics sets up WebGPU" || fail "omacvm graphics skips WebGPU"
grep -q '"WebGPU in Chromium"' src/guest/check.sh && grep -qF 'pacman -Q vulkan-virtio 2>/dev/null) == *omacvm*' src/guest/check.sh &&
  pass "check has the WebGPU row for Graphics Vulkan" || fail "no WebGPU check row for Graphics Vulkan"
grep -q './webgpu.sh --off' "$D/install.sh" && pass "vulkan feature off leaves the launcher to webgpu.sh" ||
  fail "venus/install.sh --remove deletes the launcher itself"
W=$T/root; mkdir -p "$W/etc/omacvm"
wg() { PATH="$T:$PATH" OMACVM_WEBGPU_ROOT=$W OMACVM_CHROMIUM=${CHR:-/nonexistent} "$D/webgpu.sh" "$@" >/dev/null 2>&1; }
has() { [[ -f $W/usr/local/bin/omacvm-chromium-webgpu && -L $W/usr/local/bin/omacvm-chrome-webgpu ]]; }
CHR=$T/ldd wg && has && [[ -f $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh: launcher, Chrome link and menu entry" || fail "webgpu.sh did not install the launcher"
echo OMACVM_GRAPHICS=vulkan > "$W/etc/omacvm/env"
wg --off; has && pass "webgpu.sh --off keeps it with Graphics Vulkan" || fail "webgpu.sh --off removed it with Graphics Vulkan"
echo OMACVM_GRAPHICS=opengl > "$W/etc/omacvm/env"; mkdir -p "$W/etc/vulkan/icd.d"; : > "$W/etc/vulkan/icd.d/omacvm_venus_icd.json"
wg --off; has && pass "webgpu.sh --off keeps it with the vulkan feature's Mesa" || fail "webgpu.sh --off removed the vulkan feature's launcher"
rm "$W/etc/vulkan/icd.d/omacvm_venus_icd.json"
wg --off; ! has && [[ ! -e $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh --off removes it with OpenGL" || fail "webgpu.sh --off left the launcher with OpenGL"
wg --nonsense; [[ $? == 2 ]] && pass "webgpu.sh: unknown option: usage" || fail "webgpu.sh: unknown option accepted"
wg; has && [[ ! -e $W/usr/share/applications/omacvm-chromium-webgpu.desktop ]] &&
  pass "webgpu.sh without Chromium: launcher, no menu entry" || fail "webgpu.sh without Chromium"

# Vulkan windows: Mesa's normal WSI when the app says it shows them (omacvm.vkwindows=1),
# else the software WSI (an older app ended Hyprland's GPU context on the import).
G=src/app/guest/omacvm-vulkan-present
d=$(mktemp -d)
sed "s#/run/omacvm/host.env#$d/host.env#" "$G" > "$d/gen"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "no host.env: software WSI" || fail "no host.env: not software WSI"
echo OMACVM_VKWINDOWS=1 > "$d/host.env"
[[ -z $(sh "$d/gen") ]] && pass "app shows Vulkan windows: normal WSI" || fail "app shows Vulkan windows: still software WSI"
printf 'OMACVM_SCREEN=2056x1329\nOMACVM_VKWINDOWS=0\n' > "$d/host.env"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "flag 0: software WSI" || fail "flag 0: not software WSI"
rm -rf "$d"
grep -q 'user-environment-generators/90-omacvm-vulkan-present' src/app/guest/install.sh &&
  grep -q 'rm -f /etc/environment.d/90-omacvm-vulkan.conf' src/app/guest/install.sh && pass "installed as a session generator" ||
  fail "generator not installed (or the old fixed file kept)"
grep -q 'value=omacvm.vkwindows=1' app/app/Sources/OmacVM/Runner.swift && pass "the app sends omacvm.vkwindows" ||
  fail "the app does not send omacvm.vkwindows"
grep -q '^Before=systemd-user-sessions.service' src/app/guest/omacvm-app-host.service && pass "host.env is written before sessions" ||
  fail "host.env may come after the session starts"
grep -q 'virgl-set-type-without-egl.patch' app/runtime/build-qemu-gpu-runtime.sh && pass "the runtime has the import patch" ||
  fail "the runtime lacks virgl-set-type-without-egl.patch"

(( fails == 0 )) && echo "venus-driver: all ok" || { echo "venus-driver: $fails failed"; exit 1; }
