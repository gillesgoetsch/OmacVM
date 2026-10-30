#!/bin/bash
# The guard's rules: the desktop reserve (virgl-gpu-guard-desktop-reserve.patch)
# and the grace at critical memory pressure (virgl-gpu-guard-critical-grace.patch).
# The first patch's new src/virgl_gpu_guard.h goes into an empty folder, the
# second one's changes to it are applied there, and test-gpu-guard-policy.c runs
# against it. No GL, no renderer. CI runs it; the runtime build runs the renderer
# itself (test-resource-budget.c, modes reserve, critical and critical-steady).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patch_file="$here/../../patches/virgl-gpu-guard-desktop-reserve.patch"
grace_file="$here/../../patches/virgl-gpu-guard-critical-grace.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-gpu-guard.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"
# The header is a new file: every line of its hunk starts with "+".
awk '/^\+\+\+ b\/src\/virgl_gpu_guard\.h/ { on = 1; next }
     on && /^(--- |diff )/ { exit }
     on && /^@@/ { next }
     on { print substr($0, 2) }' "$patch_file" > "$work/src/virgl_gpu_guard.h"
[[ -s $work/src/virgl_gpu_guard.h ]] || { echo "FAIL: no src/virgl_gpu_guard.h in $patch_file"; exit 1; }
# The grace patch's hunks for the header only (the renderer's are for the runtime build).
awk '/^--- a\/src\/virgl_gpu_guard\.h/ { on = 1 }
     on && /^--- a\// && !/virgl_gpu_guard\.h/ { exit }
     on { print }' "$grace_file" > "$work/grace.diff"
[[ -s $work/grace.diff ]] || { echo "FAIL: no change to src/virgl_gpu_guard.h in $grace_file"; exit 1; }
patch -s -d "$work" -p1 < "$work/grace.diff"
cc -std=c11 -Wall -Wextra -Werror -I"$work/src" "$here/test-gpu-guard-policy.c" -o "$work/test-gpu-guard-policy"
"$work/test-gpu-guard-policy"
