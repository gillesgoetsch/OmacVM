#!/bin/bash
# omacvm-netd's offline tests: it builds without warnings, and its time limits
# on vmnet hold (test-netd.c, with vmnet replaced). No root, no VM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FW=(-framework vmnet -framework Security -framework CoreFoundation -lbsm)
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -o "$T/omacvm-netd" "$HERE/omacvm-netd.c" "${FW[@]}"
echo "ok   omacvm-netd builds without warnings"
xcrun clang -O1 -g -Wall -Wno-unused-function -fsanitize=address,undefined -mmacosx-version-min=14.0 \
  -o "$T/test-netd" "$HERE/test-netd.c" "${FW[@]}"
"$T/test-netd" 2>"$T/log" || { cat "$T/log" >&2; exit 1; }
