#!/bin/bash
# Sign an assembled OmacVM.app: build-app.sh's last step, in its own script so
# the same signing runs on an app put together on another Mac (a build Mac
# without the keys: src/release/release.sh with OMACVM_RELEASE_APP_FROM).
#   scripts/sign-app.sh APP ID [--test-identity]
#     ID               the app's bundle id (build-app.sh's): given by the caller,
#                      never read from the app
#     --test-identity  the helpers are the test identity's (OmacVM Test Bridge,
#                      OmacVM Test Gestures; build-app.sh --test-identity)
# OMACVM_SIGN_ID: a Developer ID identity (name or SHA-1) signs for release,
# with the hardened runtime and a timestamp; without it the app is signed ad hoc.
# Under the hardened runtime the app (whose QEMU uses the microphone) needs
# audio-input, as try-omarchy's app has it. Entitlements come from this
# checkout (app/*.entitlements, runtime/qemu-hvf.entitlements).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
(( $# == 2 || $# == 3 )) || { echo "usage: sign-app.sh APP ID [--test-identity]" >&2; exit 2; }
APP=$1; ID=$2; TEST=0
case ${3:-} in "") ;; --test-identity) TEST=1 ;; *) echo "usage: sign-app.sh APP ID [--test-identity]" >&2; exit 2 ;; esac
[[ -d $APP/Contents ]] || { echo "not an app: $APP" >&2; exit 2; }
[[ $ID =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "not a bundle id: $ID" >&2; exit 2; }
BRIDGE_APP=OmacVMBridge.app; BRIDGE_ID=org.omacvm.bridge
GESTURES_APP=OmacVMGestures.app; GESTURES_ID=org.omacvm.gestures
if (( TEST )); then
  BRIDGE_APP="OmacVM Test Bridge.app"; BRIDGE_ID=org.omacvm.test.bridge
  GESTURES_APP="OmacVM Test Gestures.app"; GESTURES_ID=org.omacvm.test.gestures
fi
C=$APP/Contents
NETD=$C/Library/LaunchServices/org.omacvm.netd
log() { printf '==> %s\n' "$*"; }

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
  codesign "${SIGN[@]}" --identifier "$ID.docktile" "$C/PlugIns/OmacVMDockTile.docktileplugin"
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
  codesign --force --sign - --identifier "$ID.docktile" "$C/PlugIns/OmacVMDockTile.docktileplugin"
  # The helpers keep the signature their build gave them (src/lib/sign.sh: the same rule).
  codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$APP"
fi
codesign --verify --deep --strict "$APP"
