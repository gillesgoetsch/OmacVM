#!/bin/bash
# The drop helper (omacvm-drop-at.c) builds against a real libwayland with
# -Werror, as install.sh builds it in the VM (CI: Ubuntu's libwayland-dev).
set -euo pipefail
here=$(cd "$(dirname "$0")/../guest" && pwd -P)
t=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-drop-at.XXXXXX")
trap 'rm -rf "$t"' EXIT
for p in wlr-layer-shell-unstable-v1 wlr-virtual-pointer-unstable-v1; do
  wayland-scanner client-header "$here/proto/$p.xml" "$t/$p-client-protocol.h"
  wayland-scanner private-code "$here/proto/$p.xml" "$t/$p-protocol.c"
done
# shellcheck disable=SC2046
cc -O2 -Wall -Wextra -Werror -I"$t" -o "$t/omacvm-drop-at" "$here/omacvm-drop-at.c" "$t"/*-protocol.c $(pkg-config --cflags --libs wayland-client)
rc=0; "$t/omacvm-drop-at" 2>/dev/null || rc=$?
[[ $rc == 2 ]] || { echo "FAIL omacvm-drop-at without arguments: exit $rc, wanted 2"; exit 1; }
echo "ok   omacvm-drop-at builds with -Werror and checks its arguments"
