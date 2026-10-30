#!/bin/bash
# The SPIR-V scan of virgl-venus-spirv-scan.patch on the CPU alone (ADR 0065): its two new
# files (src/venus/vkr_spirv.c and .h) go into an empty folder and fuzz-venus-spirv.c runs
# against them under AddressSanitizer and UndefinedBehaviorSanitizer. No Vulkan driver, no
# GPU. CI runs it; the runtime build runs it before the patch.
#   fuzz-venus-spirv.sh [ITERATIONS [SEED]]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patch_file="$here/../../patches/virgl-venus-spirv-scan.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-venus-spirv.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"
# A new file's hunk: every line starts with "+".
for f in vkr_spirv.c vkr_spirv.h; do
  awk -v file="$f" '$0 == "+++ b/src/venus/" file { on = 1; next }
       on && /^(--- |diff )/ { exit }
       on && /^@@/ { next }
       on { print substr($0, 2) }' "$patch_file" > "$work/src/$f"
  [[ -s $work/src/$f ]] || { echo "FAIL: no src/venus/$f in $patch_file"; exit 1; }
done
cc -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
  -Wall -Wextra -Werror -I"$work/src" "$here/fuzz-venus-spirv.c" "$work/src/vkr_spirv.c" \
  -o "$work/fuzz-venus-spirv"
"$work/fuzz-venus-spirv" "$@"
