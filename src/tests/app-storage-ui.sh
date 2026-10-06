#!/bin/bash
# Renders OmacVM.app's storage screens to PNGs from a fixture home (three VMs:
# two in ~/OmacVM, one in 2.9's hidden folder). Nothing opens on screen; the
# real home, the app's settings and VMs are not read or touched (a binary of
# its own name keeps its own settings, removed after).
#   src/tests/app-storage-ui.sh OUT_DIR
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?usage: app-storage-ui.sh OUT_DIR}
mkdir -p "$OUT"
T=$(mktemp -d)
BIN=omacvm-storage-render
trap 'rm -rf "$T"; defaults delete "$BIN" >/dev/null 2>&1 || true' EXIT
H=$T/home
vm() {   # FOLDER
  mkdir -p "$1/logs"; printf "NAME='%s'\nCPUS=4\nMEM_MB=8192\nDISK_GB=64\nSSH_PORT=52222\nVM_USER='me'\n" "$(basename "$1")" > "$1/vm.env"
  mkfile -n 64g "$1/disk.img"; dd if=/dev/urandom of="$1/disk.img" bs=1m count=40 conv=notrunc 2>/dev/null
  mkfile -n 64m "$1/efi-vars.fd"; : > "$1/ready"
}
vm "$H/OmacVM/Omarchy"
vm "$H/OmacVM/Work"
vm "$H/Library/Application Support/OmacVM/VMs/Old VM"
mkdir -p "$H/Library/Caches/omacvm/live"; mkfile 300m "$H/Library/Caches/omacvm/live/TryOmarchy.dmg"
defaults delete "$BIN" >/dev/null 2>&1 || true
srcs=()
# main.swift (the app delegate) and the update UI renderer, which needs it, stay out.
for f in "$R"/app/app/Sources/OmacVM/*.swift; do
  case $(basename "$f") in main.swift|RenderUpdateUI.swift) ;; *) srcs+=("$f") ;; esac
done
libs=()
for m in OmacVMUpdate OmacVMNet OmacVMUSB OmacVMFolder OmacVMFeatures OmacVMBuildProgress OmacVMWindow; do   # the app's library targets (Package.swift)
  swiftc -swift-version 5 -parse-as-library -static -emit-library -emit-module -module-name $m \
    -emit-module-path "$T/$m.swiftmodule" -o "$T/lib$m.a" "$R"/app/app/Sources/$m/*.swift
  libs+=(-l$m)
done
swiftc -swift-version 5 -I "$T" -L "$T" "${libs[@]}" -o "$T/$BIN" "${srcs[@]}" "$R/src/tests/app-storage-ui/main.swift"
HOME=$H CFFIXED_USER_HOME=$H OMACVM_RESOURCES=$R/app "$T/$BIN" "$OUT"
