#!/bin/bash
# SPIRV-Tools' validator as Venus runs it (virgl-venus-spirv-validate.patch) and the scan's
# Function and Private element count and Workgroup bytes (virgl-venus-spirv-scan.patch) on the
# CPU alone, ADR 0065, #624: the four new and changed files come out of the patches into an
# empty folder, and test-venus-spirv-validate.c runs against them and the runtime build's
# SPIRV-Tools, once as built and once under AddressSanitizer (SPIRV-Tools built with it too)
# and UndefinedBehaviorSanitizer (vkr's code). No Vulkan driver, no GPU: invalid and crash
# modules never reach a real driver (STANDARDS 14b).
#  - spirv-corpus/pass: real modules (DXVK, Dawn, vkcube, dEQP-VK data, Zink, naga (Zed, wgpu), glslc test
#    shaders) pass for both drivers' targets, with their pipeline's checks
#    (spirv-corpus/README.md);
#  - spirv-corpus/refuse: modules that ended KosmicKrisp's or MoltenVK's process or hung
#    them on an M4, or took spirv-val past 512 MB, 2 s or the process, are refused by the
#    scan, spirv-val, the element cap or the pipeline checks;
#  - units: the targets, the cache (hits, bound, LRU order, no refusals kept, 8 threads),
#    the size cap, the Function and Private element cases, the Workgroup bytes, the
#    variables one entry point gets;
#  - venus-spirv-extensions.tsv: every SPIR-V extension a Vulkan extension vkr offers
#    enables is one this SPIRV-Tools knows (an unknown one would refuse real modules), and
#    with VIRGL_SOURCE every extension vkr_common.c's table offers has a row.
#   test-venus-spirv-validate.sh SPIRV_TOOLS_PREFIX SPIRV_TOOLS_ASAN_PREFIX [VIRGL_SOURCE]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
prefix=$1 asan_prefix=$2 virgl_source=${3:-}
patches="$here/../../patches"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-venus-spirv-validate.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"
# a new file's hunk: every line starts with "+"
take() { # PATCH FILE
  awk -v file="$2" '$0 == "+++ b/src/venus/" file { on = 1; next }
       on && /^(--- |diff )/ { exit }
       on && /^@@/ { next }
       on { print substr($0, 2) }' "$1" > "$work/src/$2"
  [[ -s $work/src/$2 ]] || { echo "FAIL: no src/venus/$2 in $1"; exit 1; }
}
take "$patches/virgl-venus-spirv-scan.patch" vkr_spirv.c
take "$patches/virgl-venus-spirv-scan.patch" vkr_spirv.h
take "$patches/virgl-venus-spirv-validate.patch" vkr_spirv_validate.c
take "$patches/virgl-venus-spirv-validate.patch" vkr_spirv_validate.h
srcs=("$here/test-venus-spirv-validate.c" "$work/src/vkr_spirv.c" "$work/src/vkr_spirv_validate.c")
warn=(-std=c11 -Wall -Wextra -Werror -I"$work/src")
cc -O2 "${warn[@]}" -I"$prefix/include" "${srcs[@]}" "$prefix/lib/libSPIRV-Tools.a" -lc++ \
  -o "$work/validate"
cc -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer "${warn[@]}" \
  -I"$asan_prefix/include" "${srcs[@]}" "$asan_prefix/lib/libSPIRV-Tools.a" -lc++ -o "$work/validate-asan"
c++ -std=c++17 -O1 -Wall -Wextra -Werror -I"$prefix/include" "$here/test-venus-spirv-extensions.cpp" \
  "$prefix/lib/libSPIRV-Tools.a" -o "$work/extensions"

corpus="$here/spirv-corpus"
pass=("$corpus"/pass/*.spv)
refuse=()
for f in "$corpus"/refuse/*.spv; do [[ $f == *.vs.spv ]] || refuse+=("$f"); done
(( ${#pass[@]} > 150 && ${#refuse[@]} > 100 )) || { echo "FAIL: the corpus is missing"; exit 1; }
for bin in validate validate-asan; do
  "$work/$bin" units "$corpus/pass/vkcube-vert.spv"
  # mvk11: MoltenVK's device under an app that asks for Vulkan 1.0 or 1.1 (it reports the
  # instance's version): SPIR-V past 1.4 is refused there, all else as on mvk
  for profile in kk mvk mvk11; do
    "$work/$bin" pass "$profile" "${pass[@]}"
    "$work/$bin" refuse "$profile" "${refuse[@]}"
  done
done
"$work/extensions" "$here/venus-spirv-extensions.tsv"

# every extension vkr's table offers has a row (a new one needs its SPIR-V extensions named)
if [[ -n $virgl_source ]]; then
  missing=$(awk '/vkr_extension_table = \{/ { on = 1; next } on && /^\};/ { exit }
                 on && /= true,/ { sub(/^[ \t]*\./, "VK_"); sub(/ = true,.*/, ""); print }' \
              "$virgl_source/src/venus/vkr_common.c" |
            while read -r ext; do grep -q "^$ext	" "$here/venus-spirv-extensions.tsv" || echo "$ext"; done)
  [[ -z $missing ]] || { echo "FAIL: venus-spirv-extensions.tsv has no row for: $missing"; exit 1; }
  echo "extensions: every extension vkr_common.c offers has a row"
fi

# the cost, for the record: microseconds per module (cache off), median of 5
"$work/validate" time kk 5 "${pass[@]}" |
  awk -F'\t' '{ n++; t += $3; b += $2; if ($3 > m) m = $3 } END {
    printf "time: spirv-val %d modules, %.0f us in all, %.0f us per KB, slowest %.0f us\n", n, t, t / (b / 1024), m }'
echo "venus spirv validate: all ok"
