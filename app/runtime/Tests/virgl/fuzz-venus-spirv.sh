#!/bin/bash
# The SPIR-V scan of virgl-venus-spirv-scan.patch on the CPU alone (ADR 0065): its two new
# files (src/venus/vkr_spirv.c and .h) go into an empty folder and fuzz-venus-spirv.c runs
# against them under AddressSanitizer and UndefinedBehaviorSanitizer. No Vulkan driver, no
# GPU. CI runs it; the runtime build runs it before the patch. On macOS it stops itself past
# FUZZ_CAP_MB of memory (default 512, exit 3).
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
# the memory cap is inside the process (FUZZ_CAP_MB, default 512): an input past it is kept
# outside $work, which goes at the end
cap_out="${TMPDIR:-/tmp}/omacvm-venus-spirv-cap-$$.spv"
echo "fuzz-venus-spirv: memory cap ${FUZZ_CAP_MB:-512} MB; an input past it goes to $cap_out"
rc=0
FUZZ_CAP_OUT="$cap_out" "$work/fuzz-venus-spirv" "$@" || rc=$?
if (( rc == 3 )); then
  echo "FAIL: fuzz-venus-spirv went past its memory cap of ${FUZZ_CAP_MB:-512} MB; the input: $cap_out"
fi
exit "$rc"
