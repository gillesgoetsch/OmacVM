#!/bin/bash
# The rules of virgl-venus-device-lost-backoff.patch: its new src/venus/vkr_restart_guard.h
# goes into an empty folder and test-venus-restart-guard.c runs against it. No GPU, no vkr:
# CI and the runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patch_file="$here/../../patches/virgl-venus-device-lost-backoff.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-restart-guard.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The header is a new file: every line of its hunk starts with "+".
awk '/^\+\+\+ b\/src\/venus\/vkr_restart_guard\.h/ { on = 1; next }
     on && /^(--- |diff )/ { exit }
     on && /^@@/ { next }
     on { print substr($0, 2) }' "$patch_file" > "$work/vkr_restart_guard.h"
[[ -s $work/vkr_restart_guard.h ]] || { echo "FAIL: no src/venus/vkr_restart_guard.h in $patch_file"; exit 1; }
cc -std=c11 -Wall -Wextra -Werror -I"$work" "$here/test-venus-restart-guard.c" -o "$work/test-venus-restart-guard"
"$work/test-venus-restart-guard"
