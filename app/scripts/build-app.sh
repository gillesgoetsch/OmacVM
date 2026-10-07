#!/bin/bash
# Build OmacVM.app into dist/: the launcher, QEMU (built from source on the
# first run and when its patches or build scripts change, about 70 seconds),
# UEFI firmware, the VM scripts and OmacVM's VM side (src/ of the repo this
# lives in, as committed), its Mac helpers and a python3 (scripts/fetch-python.sh),
# so a Mac without Xcode's Command Line Tools needs nothing else. Signed ad
# hoc, or with OMACVM_SIGN_ID (below).
#   scripts/build-app.sh [--name NAME] [--id BUNDLE_ID] [--release]
#   scripts/build-app.sh --test-identity [--install]
#     --name     the app's name and Dock title (default OmacVM)
#     --id       another bundle id (default org.omacvm.app): test builds that
#                must not share settings, VMs or the running app with an
#                installed OmacVM
#     --release  for a published zip: the whole repo must be committed, and the
#                runtime has KosmicKrisp (OMACVM_RUNTIME_KOSMICKRISP=1 unless set:
#                Vulkan on macOS 26+; its tools: runtime/build-kosmickrisp.sh --check;
#                or OMACVM_KOSMICKRISP_FROM=DIR, built on another Mac:
#                runtime/import-kosmickrisp.sh)
#     --test-identity  (or OMACVM_TEST_IDENTITY=1) the one test identity for the
#                developers' Macs: "OmacVM Test" (org.omacvm.app.test), its helpers
#                "OmacVM Test Bridge" (org.omacvm.test.bridge, port 47931) and
#                "OmacVM Test Gestures" (org.omacvm.test.gestures, port 47930, own
#                settings domain), never the installed ones' ids, ports or folders.
#                Always Developer ID signed (OMACVM_SIGN_ID), so macOS keeps the
#                grants given to it once (Accessibility, Input Monitoring, Bluetooth,
#                Screen Recording) across rebuilds: tests use only this identity.
#     --install  with --test-identity: copy it over ~/Applications/OmacVM Test.app
#                (always that path; refused while it runs)
#   scripts/build-app.sh --runtime-inputs [--release]
#                prints the hash of what the QEMU runtime is built from (the
#                runtime/.build/inputs.sha256 this build wants) and builds nothing:
#                CI keeps runtimes under it (.github/app-runtime-cache.sh)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
NAME=OmacVM; ID=org.omacvm.app; RELEASE=0; TEST=${OMACVM_TEST_IDENTITY:-0}; INSTALL=0; INPUTS_ONLY=0
while (( $# )); do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --id) ID=$2; shift 2 ;;
    --release) RELEASE=1; shift ;;
    --test-identity) TEST=1; shift ;;
    --install) INSTALL=1; shift ;;
    --runtime-inputs) INPUTS_ONLY=1; shift ;;
    *) echo "usage: build-app.sh [--name NAME] [--id BUNDLE_ID] [--release] | --test-identity [--install] | --runtime-inputs [--release]" >&2; exit 2 ;;
  esac
done
[[ $TEST == [01] ]] || { echo "OMACVM_TEST_IDENTITY is 0 or 1" >&2; exit 2; }
BRIDGE_APP=OmacVMBridge.app; BRIDGE_ID=org.omacvm.bridge
GESTURES_APP=OmacVMGestures.app; GESTURES_ID=org.omacvm.gestures
if (( TEST )); then
  (( ! RELEASE )) || { echo "--test-identity is not a release" >&2; exit 2; }
  [[ -n ${OMACVM_SIGN_ID:-} ]] || { echo "the test identity is always Developer ID signed: set OMACVM_SIGN_ID" >&2; exit 2; }
  NAME="OmacVM Test"; ID=org.omacvm.app.test
  BRIDGE_APP="OmacVM Test Bridge.app"; BRIDGE_ID=org.omacvm.test.bridge
  GESTURES_APP="OmacVM Test Gestures.app"; GESTURES_ID=org.omacvm.test.gestures
fi
(( ! INSTALL || TEST )) || { echo "--install is only for --test-identity" >&2; exit 2; }
[[ $ID =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "not a bundle id: $ID" >&2; exit 2; }
(( ! RELEASE )) || [[ $ID == org.omacvm.app ]] || { echo "a release keeps the bundle id org.omacvm.app" >&2; exit 2; }
log() { printf '==> %s\n' "$*"; }
# A release ships KosmicKrisp: Graphics' Automatic gives Vulkan with it on
# macOS 26 and newer (MoltenVK stays for older macOS and as the fallback).
if (( RELEASE )); then
  : "${OMACVM_RUNTIME_KOSMICKRISP:=1}"
  export OMACVM_RUNTIME_KOSMICKRISP
fi

# OmacVM's VM side as committed (git archive of HEAD), so the app always says
# which commit it carries. Uncommitted changes in src/ would not be in it:
# stop. A release build takes nothing that is not committed.
(( INPUTS_ONLY )) || COMMIT=$(git -C "$REPO" rev-parse HEAD)
if (( ! INPUTS_ONLY )) && [[ -n $(git -C "$REPO" status --porcelain -- src) ]]; then
  echo "src/ has uncommitted changes: commit them first (the app takes OmacVM as committed)" >&2
  exit 1
fi
if (( RELEASE && ! INPUTS_ONLY )) && [[ -n $(git -C "$REPO" status --porcelain) ]]; then
  echo "a release build needs a clean tree: commit or stash first" >&2
  git -C "$REPO" status --short >&2
  exit 1
fi
RT=$ROOT/runtime/.build
# What the runtime was built from: its build scripts, patches and the tests
# the build runs, which UEFI firmware (OMACVM_FIRMWARE=qemu: QEMU's prebuilt
# one, TianoCore logo), and with KosmicKrisp its build tools (a new Homebrew
# LLVM rebuilds it).
KK_STAMP=
if [[ ${OMACVM_RUNTIME_KOSMICKRISP:-0} == 1 ]]; then
  # OMACVM_KOSMICKRISP_FROM: built on another Mac (runtime/import-kosmickrisp.sh).
  if [[ -n ${OMACVM_KOSMICKRISP_FROM:-} ]]; then
    KK_STAMP=$("$ROOT/runtime/import-kosmickrisp.sh" "$OMACVM_KOSMICKRISP_FROM" --stamp)
  else
    KK_STAMP=$("$ROOT/runtime/build-kosmickrisp.sh" --stamp)
  fi
fi
INPUTS=$(cd "$ROOT/runtime" && { shasum -a 256 ./*.sh runtime-files.txt patches/* Tests/firmware/*.py Tests/virgl/*.py Tests/virgl/*.c Tests/virgl/*.h Tests/display/* Tests/keys/* Tests/net/* boot-logo/*.py
  echo "firmware=${OMACVM_FIRMWARE:-omacvm}"
  echo "kosmickrisp=${OMACVM_RUNTIME_KOSMICKRISP:-0}${KK_STAMP:+ $KK_STAMP}"; } | shasum -a 256 | cut -d' ' -f1)
if (( INPUTS_ONLY )); then echo "$INPUTS"; exit 0; fi
# A runtime built with OMACVM_RUNTIME_TEST_HOOKS=1 (test hooks) is never shipped.
if [[ ! -x $RT/qemu-gpu-runtime/bin/qemu-system-aarch64 || ! -f $RT/firmware/edk2-aarch64-code.fd
      || -e $RT/qemu-gpu-runtime.test-hooks
      || $(cat "$RT/inputs.sha256" 2>/dev/null) != "$INPUTS" ]]; then
  log "QEMU (from source)"
  "$ROOT/runtime/build-qemu-gpu-runtime.sh"
  # A fallback to QEMU's firmware (the edk2 build or its test failed, maybe
  # just a download) is not kept: the next build tries again.
  if [[ $(cat "$RT/firmware/firmware-source" 2>/dev/null) == omacvm* || ${OMACVM_FIRMWARE:-} == qemu ]]; then
    echo "$INPUTS" > "$RT/inputs.sha256"
  else
    rm -f "$RT/inputs.sha256"
  fi
fi
FIRMWARE=$(cat "$RT/firmware/firmware-source" 2>/dev/null || echo "unknown")
log "firmware: $FIRMWARE"
# A release carries Omarchy's boot logo, unless QEMU's firmware was asked for.
if (( RELEASE )) && [[ $FIRMWARE != omacvm* && ${OMACVM_FIRMWARE:-} != qemu ]]; then
  echo "the edk2 build failed (QEMU's firmware instead): fix it, or OMACVM_FIRMWARE=qemu for a release without the Omarchy boot logo" >&2
  exit 1
fi

log "launcher"
cd "$ROOT/app"
mkdir -p .build/mc/swift .build/mc/clang
SWIFT_MODULECACHE_PATH=$PWD/.build/mc/swift CLANG_MODULE_CACHE_PATH=$PWD/.build/mc/clang \
  MACOSX_DEPLOYMENT_TARGET=15.0 swift build --disable-sandbox -c release -debug-info-format none --product OmacVM 2>&1 | { grep -v '^\[' || true; } ||
  { echo "launcher build failed" >&2; exit 1; }
LAUNCHER=$ROOT/app/.build/release/OmacVM
[[ -x $LAUNCHER ]] || { echo "launcher build failed" >&2; exit 1; }
# Touch ID's panel, which QEMU loads (omacvm-cocoa-touchid-panel.patch, ADR 0041).
SWIFT_MODULECACHE_PATH=$PWD/.build/mc/swift CLANG_MODULE_CACHE_PATH=$PWD/.build/mc/clang \
  MACOSX_DEPLOYMENT_TARGET=15.0 swift build --disable-sandbox -c release -debug-info-format none --product OmacVMTouchIDPanel 2>&1 | { grep -v '^\[' || true; } ||
  { echo "Touch ID panel build failed" >&2; exit 1; }
TOUCHID_PANEL=$ROOT/app/.build/release/libOmacVMTouchIDPanel.dylib
[[ -f $TOUCHID_PANEL ]] || { echo "Touch ID panel build failed" >&2; exit 1; }

ICON=$ROOT/.build/OmacVM.icns
if [[ ! -f $ICON ]]; then
  log "icon"
  mkdir -p "$ROOT/.build"
  "$REPO/src/icon/make-icns.sh" "$ICON"
fi

APP=$ROOT/dist/$NAME.app
C=$APP/Contents
log "assembling $APP"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources/scripts" "$C/Resources/firmware" "$C/Resources/omacvm" "$C/Resources/licenses"
install -m755 "$LAUNCHER" "$C/MacOS/OmacVM"
install -m644 "$ICON" "$C/Resources/OmacVM.icns"
ditto "$RT/qemu-gpu-runtime" "$C/Resources/runtime"
mv "$C/Resources/runtime/bin/qemu-system-aarch64" "$C/Resources/runtime/bin/OmacVM"
install -m644 "$TOUCHID_PANEL" "$C/Resources/runtime/lib/OmacVMTouchIDPanel.dylib"
install_name_tool -id @rpath/OmacVMTouchIDPanel.dylib "$C/Resources/runtime/lib/OmacVMTouchIDPanel.dylib"
mkdir -p "$C/Resources/fonts"
install -m644 "$ROOT/fonts/JetBrainsMono-Regular.ttf" "$ROOT/fonts/JetBrainsMono-Bold.ttf" "$ROOT/fonts/OFL.txt" "$C/Resources/fonts/"
# The app starts QEMU through this link, so macOS counts it as this app: one
# icon in the Dock (DockIdentity.swift). The kernel still names it OmacVM.
ln -s ../Resources/runtime/bin/OmacVM "$C/MacOS/OmacVM-VM"
install -m644 "$RT/firmware/edk2-aarch64-code.fd" "$RT/firmware/firmware-source" "$C/Resources/firmware/"
install -m755 "$ROOT/scripts/create-vm.sh" "$ROOT/scripts/prebuilt-vm.sh" "$ROOT/scripts/apply-vm.sh" "$ROOT/scripts/vm-common.sh" \
  "$ROOT/scripts/update-vm.sh" \
  "$ROOT/scripts/update-swap.sh" "$C/Resources/scripts/"
# The complete omacvm (entry script + src, as a release checkout): apply-vm.sh
# runs its src/, and the Bridge runs it for the control centre when there is no
# checkout (src/lib/mac.sh cli_file_app). The Bridge runs it only when nobody
# else can write it (control.swift controlCLI): no group/other write bits.
git -C "$REPO" archive "$COMMIT" omacvm src | tar -x -C "$C/Resources/omacvm"
echo "$COMMIT" > "$C/Resources/omacvm/COMMIT"
chmod -R go-w "$C/Resources/omacvm"
install -m644 "$ROOT/LICENSE" "$C/Resources/licenses/LICENSE.omacvm-app"
install -m644 "$ROOT/THIRD_PARTY_NOTICES.md" "$C/Resources/licenses/"
install -m644 "$ROOT/runtime/LICENSE.try-omarchy" "$C/Resources/licenses/"
install -m644 "$RT/firmware/edk2-licenses.txt" "$C/Resources/licenses/"
install -m644 "$ROOT/runtime/boot-logo/LICENSE.omarchy" "$C/Resources/licenses/"
# MoltenVK and the Vulkan loader (Apache-2.0) need their licence texts.
if [[ -e $RT/qemu-gpu-runtime/lib/libMoltenVK.dylib || -e $RT/qemu-gpu-runtime/lib/libvulkan.1.dylib ]]; then
  install -m644 "$ROOT/runtime/LICENSE.vulkan.txt" "$C/Resources/licenses/"
fi
# A runtime with KosmicKrisp must carry its licence notice.
if [[ -e $RT/qemu-gpu-runtime/lib/libvulkan_kosmickrisp.dylib ]]; then
  KK_NOTICE=$RT/qemu-gpu-runtime/share/licenses/LICENSE.mesa-kosmickrisp.txt
  [[ -s $KK_NOTICE ]] || { echo "the runtime has KosmicKrisp but no $KK_NOTICE" >&2; exit 1; }
  install -m644 "$KK_NOTICE" "$C/Resources/licenses/"
fi
# The fast network's root daemon (src/net/mac), built here and signed with the
# app, so omacvm enable fast-network needs no Xcode on the user's Mac. Its
# version is its source's hash, as src/net/mac/install.sh builds it.
log "omacvm-netd"
NETD_SRC=$C/Resources/omacvm/src/net/mac/omacvm-netd.c
NETD=$C/Library/LaunchServices/org.omacvm.netd
mkdir -p "$C/Library/LaunchServices"
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -DNETD_VERSION="\"$(shasum -a 256 "$NETD_SRC" | cut -c1-16)\"" -o "$NETD" "$NETD_SRC" \
  -framework vmnet -framework Security -framework CoreFoundation -lbsm

# OmacVM's Mac helpers (Bridge, Gestures), built here from the src/ inside the
# app and signed with it: omacvm apply/update and the app's own apply install
# these copies (src/lib/helpers.sh), so the user's Mac compiles nothing and,
# with the Developer ID, macOS keeps their Accessibility and Input Monitoring
# grants across updates. Built in a copy: nothing lands in the app's src/.
# Omanotch (src/omanotch, on with a notch) the same way: without Xcode's
# Command Line Tools on the user's Mac, nothing can build it there.
log "Mac helpers (Bridge, Gestures, Omanotch)"
HB=$(mktemp -d)
cp -R "$C/Resources/omacvm/src" "$HB/src"
OMACVM_HELPER_TEST=$TEST "$HB/src/bridge/mac/build.sh" >/dev/null 2>&1 || { echo "the Bridge did not build" >&2; rm -rf "$HB"; exit 1; }
OMACVM_HELPER_TEST=$TEST "$HB/src/gestures/mac/build.sh" >/dev/null 2>&1 || { echo "Gestures did not build" >&2; rm -rf "$HB"; exit 1; }
"$HB/src/omanotch/mac/build.sh" >/dev/null 2>&1 || { echo "Omanotch did not build" >&2; rm -rf "$HB"; exit 1; }
mkdir -p "$C/Helpers"
ditto "$HB/src/bridge/mac/build/OmacVMBridge.app" "$C/Helpers/$BRIDGE_APP"
ditto "$HB/src/gestures/mac/build/OmacVMGestures.app" "$C/Helpers/$GESTURES_APP"
ditto "$HB/src/omanotch/mac/build/Omanotch.app" "$C/Helpers/Omanotch.app"
rm -rf "$HB"

# What else the Mac side would ask Xcode's Command Line Tools for (src/lib/tools.sh):
# the Swift answers it runs (is there a notch, the built-in display, the clock
# format, free space), built here, and a python3 for the scripts (prebuilt
# images, the password hash, apply, report). On a Mac without them
# /usr/bin/python3 and swift only ask to install the tools.
log "Mac tools and python3"
mkdir -p "$C/Resources/tools"
for t in display/mac-notch display/mac-display clock/mac-clock lib/mac-free-gb; do
  xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$C/Resources/tools/${t#*/}" \
    "$C/Resources/omacvm/src/$t.swift" || { echo "${t#*/}.swift did not build" >&2; exit 1; }
done
PYDIR=$("$ROOT/scripts/fetch-python.sh")
ditto "$PYDIR" "$C/Resources/python"
install -m644 "$PYDIR/../LICENSE.python.txt" "$C/Resources/licenses/"

# Every program in the app must start on the macOS the app says it needs
# (LSMinimumSystemVersion 15.0 below): a helper built without a minimum takes
# the build Mac's macOS (Gestures built on macOS 27 did not start on 26).
MIN_MACOS=15.0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^Mach-O' || continue
  # KosmicKrisp is loaded only on macOS 26 and newer (Graphics.swift).
  [[ $f == */libvulkan_kosmickrisp.dylib ]] && continue
  m=$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/ {b = 1} b && $1 == "minos" {print $2; exit}')
  [[ -z $m ]] && m=$(otool -l "$f" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/ {b = 1} b && $1 == "version" {print $2; exit}')
  if [[ -n $m ]] && [[ $(printf '%s\n%s\n' "$m" "$MIN_MACOS" | sort -V | tail -1) != "$MIN_MACOS" ]]; then
    echo "${f#"$C/"} needs macOS $m, newer than the app's $MIN_MACOS: build it with a -target / deployment target" >&2
    exit 1
  fi
done < <(find "$C" -type f -perm -u+x -print0)

# The app carries the version of the OmacVM it is part of.
# OmacVMControlRun: OmacVM Bridge may run the control centre's omacvm through
# this app (OmacVM --control-run, ControlRun.swift); an older app has no key.
# Bluetooth: macOS charges Bluetooth, the camera and the microphone of a
# helper run from inside this bundle (Contents/Helpers) to the app, and kills
# the helper if the app's Info.plist has no reason for it (OS_REASON_TCC).
# The installed Bridge runs from ~/Applications and has its own; this keeps
# a Bridge started in place alive (src/tests/prebuilt-helpers.sh checks).
# NSPrefersDisplaySafeAreaCompatibilityMode false: macOS never shrinks the
# whole display below the camera for the launcher's windows (no "Scale to fit
# below built-in camera" box in Get Info). Since 3.0.1 it holds for the VM's
# windows too: QEMU, started as Contents/MacOS/OmacVM-VM, counts as this app
# (DockIdentity.swift), so AppKit reads this file for it as well; its full
# screen is macOS's own and sits below the camera.
VERSION=$(cat "$REPO/src/VERSION")
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>OmacVM</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>OmacVMCommit</key><string>$COMMIT</string>
  <key>OmacVMControlRun</key><true/>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrefersDisplaySafeAreaCompatibilityMode</key><false/>
  <key>NSLocalNetworkUsageDescription</key><string>OmacVM reaches your VM on the Mac's own VM network: to set it up, for the control centre and for the fast network.</string>
  <key>NSMicrophoneUsageDescription</key><string>The VM can use your Mac's microphone.</string>
  <key>NSCameraUsageDescription</key><string>Linux apps in the VM can use your Mac's camera. It is on only while one of them uses it.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Your Mac folder setting shares this folder with the VM at ~/Mac.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Your Mac folder setting shares this folder with the VM at ~/Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Your Mac folder setting shares this folder with the VM at ~/Mac.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Your Mac folder setting shares a folder on this drive with the VM at ~/Mac.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Your Mac folder setting shares a folder on this network drive with the VM at ~/Mac.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>OmacVM Bridge shows this Mac's Bluetooth devices in your Linux VM's status bar, and connects, disconnects or forgets them when you ask there.</string>$( (( TEST )) && printf '\n  <key>OmacVMGesturesDomain</key><string>%s</string>' "$GESTURES_ID")
</dict>
</plist>
EOF

# OMACVM_SIGN_ID: a Developer ID identity (name or SHA-1) signs for release,
# with the hardened runtime and a timestamp; without it the build is signed ad hoc.
# Under the hardened runtime the app (whose QEMU uses the microphone) needs
# audio-input, as try-omarchy's app has it.
if [[ -n ${OMACVM_SIGN_ID:-} ]]; then
  log "signing ($OMACVM_SIGN_ID)"
  SIGN=(--force --sign "$OMACVM_SIGN_ID" --options runtime --timestamp)
  for f in "$C/Resources/runtime/lib"/*.dylib "$C/Resources/runtime/bin/zstd" "$C/Resources/tools"/*; do
    codesign "${SIGN[@]}" "$f"
  done
  codesign "${SIGN[@]}" --identifier "$ID.python" "$C/Resources/python/bin/python3.13"
  codesign "${SIGN[@]}" --identifier ch.gillesgoetsch.omanotch "$C/Helpers/Omanotch.app"
  codesign "${SIGN[@]}" --identifier "$ID.qemu" \
    --entitlements "$ROOT/runtime/qemu-hvf.entitlements" "$C/Resources/runtime/bin/OmacVM"
  codesign "${SIGN[@]}" --identifier org.omacvm.netd "$NETD"
  codesign "${SIGN[@]}" --identifier "$BRIDGE_ID" --entitlements "$ROOT/app/OmacVMBridge.entitlements" "$C/Helpers/$BRIDGE_APP"
  codesign "${SIGN[@]}" --identifier "$GESTURES_ID" "$C/Helpers/$GESTURES_APP"
  codesign "${SIGN[@]}" --identifier "$ID" \
    --entitlements "$ROOT/app/OmacVM.entitlements" "$APP"
else
  log "signing (ad hoc)"
  for f in "$C/Resources/runtime/lib"/*.dylib "$C/Resources/runtime/bin/zstd" "$C/Resources/tools"/* \
           "$C/Resources/python/bin/python3.13"; do
    codesign --force --sign - "$f" 2>/dev/null
  done
  # The designated requirement names the identifier, not the binary's hash, so
  # macOS keeps Accessibility and other grants across rebuilds (as OmacVM's helpers).
  codesign --force --sign - --identifier "$ID.qemu" -r="designated => identifier \"$ID.qemu\"" \
    --entitlements "$ROOT/runtime/qemu-hvf.entitlements" "$C/Resources/runtime/bin/OmacVM"
  codesign --force --sign - --identifier org.omacvm.netd "$NETD"
  # The helpers keep the signature their build gave them (src/lib/sign.sh: the same rule).
  codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$APP"
fi
codesign --verify --deep --strict "$APP"
log "built $APP ($(du -sh "$APP" | cut -f1))"

# The test identity lives at one path; a running copy is never replaced.
if (( INSTALL )); then
  DEST=$HOME/Applications/"OmacVM Test.app"
  if pgrep -f "$DEST/Contents/" >/dev/null; then
    echo "$DEST is running: quit it (and its helpers) first" >&2; exit 1
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  codesign --verify --deep --strict "$DEST"
  log "installed $DEST"
fi
