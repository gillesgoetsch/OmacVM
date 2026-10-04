#!/bin/bash
# Build OmacVM.app into dist/: the launcher, QEMU (built from source on the
# first run and when its patches or build scripts change, about 70 seconds),
# UEFI firmware, the VM scripts and OmacVM's VM side (src/ of the repo this
# lives in, as committed). Signed ad hoc, or with OMACVM_SIGN_ID (below).
#   scripts/build-app.sh [--name NAME] [--release]
#     --name     the app's name and Dock title (default OmacVM)
#     --release  for a published zip: the whole repo must be committed
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
NAME=OmacVM; RELEASE=0
while (( $# )); do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --release) RELEASE=1; shift ;;
    *) echo "usage: build-app.sh [--name NAME] [--release]" >&2; exit 2 ;;
  esac
done
log() { printf '==> %s\n' "$*"; }

# OmacVM's VM side as committed (git archive of HEAD), so the app always says
# which commit it carries. Uncommitted changes in src/ would not be in it:
# stop. A release build takes nothing that is not committed.
COMMIT=$(git -C "$REPO" rev-parse HEAD)
if [[ -n $(git -C "$REPO" status --porcelain -- src) ]]; then
  echo "src/ has uncommitted changes: commit them first (the app takes OmacVM as committed)" >&2
  exit 1
fi
if (( RELEASE )) && [[ -n $(git -C "$REPO" status --porcelain) ]]; then
  echo "a release build needs a clean tree: commit or stash first" >&2
  git -C "$REPO" status --short >&2
  exit 1
fi
RT=$ROOT/runtime/.build
# What the runtime was built from: its build scripts, patches and the tests
# the build runs, and which UEFI firmware (OMACVM_FIRMWARE=qemu: QEMU's
# prebuilt one, TianoCore logo).
INPUTS=$(cd "$ROOT/runtime" && { shasum -a 256 ./*.sh runtime-files.txt patches/* Tests/firmware/*.py Tests/virgl/*.py Tests/virgl/*.c Tests/virgl/*.h
  echo "firmware=${OMACVM_FIRMWARE:-omacvm}"; } | shasum -a 256 | cut -d' ' -f1)
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
  MACOSX_DEPLOYMENT_TARGET=15.0 swift build --disable-sandbox -c release -debug-info-format none 2>&1 | { grep -v '^\[' || true; } ||
  { echo "launcher build failed" >&2; exit 1; }
LAUNCHER=$ROOT/app/.build/release/OmacVM
[[ -x $LAUNCHER ]] || { echo "launcher build failed" >&2; exit 1; }

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
install -m644 "$RT/firmware/edk2-aarch64-code.fd" "$RT/firmware/firmware-source" "$C/Resources/firmware/"
install -m755 "$ROOT/scripts/create-vm.sh" "$ROOT/scripts/apply-vm.sh" "$ROOT/scripts/vm-common.sh" "$C/Resources/scripts/"
git -C "$REPO" archive "$COMMIT" src | tar -x -C "$C/Resources/omacvm"
echo "$COMMIT" > "$C/Resources/omacvm/COMMIT"
install -m644 "$ROOT/LICENSE" "$C/Resources/licenses/LICENSE.omacvm-app"
install -m644 "$ROOT/THIRD_PARTY_NOTICES.md" "$C/Resources/licenses/"
install -m644 "$ROOT/runtime/LICENSE.try-omarchy" "$C/Resources/licenses/"
install -m644 "$RT/firmware/edk2-licenses.txt" "$C/Resources/licenses/"
install -m644 "$ROOT/runtime/boot-logo/LICENSE.omarchy" "$C/Resources/licenses/"
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

# The app carries the version of the OmacVM it is part of.
VERSION=$(cat "$REPO/src/VERSION")
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.omacvm.app</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>OmacVM</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>OmacVMCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>The VM can use your Mac's microphone.</string>
  <key>NSCameraUsageDescription</key><string>Linux apps in the VM can use your Mac's camera. It is on only while one of them uses it.</string>
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
  for f in "$C/Resources/runtime/lib"/*.dylib "$C/Resources/runtime/bin/zstd"; do
    codesign "${SIGN[@]}" "$f"
  done
  codesign "${SIGN[@]}" --identifier org.omacvm.app.qemu \
    --entitlements "$ROOT/runtime/qemu-hvf.entitlements" "$C/Resources/runtime/bin/OmacVM"
  codesign "${SIGN[@]}" --identifier org.omacvm.netd "$NETD"
  codesign "${SIGN[@]}" --identifier org.omacvm.app \
    --entitlements "$ROOT/app/OmacVM.entitlements" "$APP"
else
  log "signing (ad hoc)"
  for f in "$C/Resources/runtime/lib"/*.dylib "$C/Resources/runtime/bin/zstd"; do
    codesign --force --sign - "$f" 2>/dev/null
  done
  # The designated requirement names the identifier, not the binary's hash, so
  # macOS keeps Accessibility and other grants across rebuilds (as OmacVM's helpers).
  codesign --force --sign - --identifier org.omacvm.app.qemu -r='designated => identifier "org.omacvm.app.qemu"' \
    --entitlements "$ROOT/runtime/qemu-hvf.entitlements" "$C/Resources/runtime/bin/OmacVM"
  codesign --force --sign - --identifier org.omacvm.netd "$NETD"
  codesign --force --sign - --identifier org.omacvm.app -r='designated => identifier "org.omacvm.app"' "$APP"
fi
codesign --verify --deep --strict "$APP"
log "built $APP ($(du -sh "$APP" | cut -f1))"
