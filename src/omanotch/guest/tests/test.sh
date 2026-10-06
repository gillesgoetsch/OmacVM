#!/bin/bash
# Offline tests of Omanotch's VM side (no Wayland, no Hyprland needed).
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=c11 -Wall -Wextra -Werror -I../notchcast -o "$out/notch-place-test" notch-place-test.c
"$out/notch-place-test"
cc -std=c11 -Wall -Wextra -Werror -I../notchcast -o "$out/test_notchrule" test_notchrule.c -lm
"$out/test_notchrule"
python3 test_bar_patch.py
