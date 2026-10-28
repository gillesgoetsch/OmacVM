#!/bin/bash
# The vCPU stall note's logic and text (qemu-hvf-vcpu-stall-note.patch) and
# the app menu's line (omacvm-cocoa-vm-stalls-menu.patch): the patches'
# headers go into an empty folder, and test-vcpu-stall.c runs against them
# (simulated vCPU threads). No QEMU, no VM.
# CI and the runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcpu-stall.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Only the headers' parts of the patches (the rest changes QEMU's files): the
# logic, and the app menu's line (omacvm-cocoa-vm-stalls-menu.patch).
awk '/^diff --git /{on = ($0 ~ /include\/qemu\/omacvm-stall\.h/)} on' \
  "$patches/qemu-hvf-vcpu-stall-note.patch" > "$work/header.patch"
awk '/^diff --git /{on = ($0 ~ /ui\/omacvm-vm-stalls\.h/)} on' \
  "$patches/omacvm-cocoa-vm-stalls-menu.patch" > "$work/menu.patch"
patch -s -d "$work" -p1 -f -i "$work/header.patch"
patch -s -d "$work" -p1 -f -i "$work/menu.patch"
san=()
# ASan and UBSan where the compiler has them (Apple's clang does)
if echo 'int main(void){return 0;}' | cc -x c - -fsanitize=address,undefined -o "$work/probe" 2>/dev/null; then
  san=(-fsanitize=address,undefined)
fi
cc -std=c11 -Wall -Wextra -Werror -O1 -g ${san[@]+"${san[@]}"} -I"$work/include" -I"$work" \
  "$here/test-vcpu-stall.c" -o "$work/test-vcpu-stall"
"$work/test-vcpu-stall"
