#!/bin/bash
# The vCPU stall note's logic and text (qemu-hvf-vcpu-stall-note.patch): the
# patch's include/qemu/omacvm-stall.h goes into an empty folder, and
# test-vcpu-stall.c runs against it (simulated vCPU threads). No QEMU, no VM.
# CI and the runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcpu-stall.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Only the header's part of the patch (the rest changes QEMU's files).
awk '/^diff --git /{on = ($0 ~ /include\/qemu\/omacvm-stall\.h/)} on' \
  "$patches/qemu-hvf-vcpu-stall-note.patch" > "$work/header.patch"
patch -s -d "$work" -p1 -f -i "$work/header.patch"
san=()
# ASan and UBSan where the compiler has them (Apple's clang does)
if echo 'int main(void){return 0;}' | cc -x c - -fsanitize=address,undefined -o "$work/probe" 2>/dev/null; then
  san=(-fsanitize=address,undefined)
fi
cc -std=c11 -Wall -Wextra -Werror -O1 -g ${san[@]+"${san[@]}"} -I"$work/include" -I"$work" \
  "$here/test-vcpu-stall.c" -o "$work/test-vcpu-stall"
"$work/test-vcpu-stall"
