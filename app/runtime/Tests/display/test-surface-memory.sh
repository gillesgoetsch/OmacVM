#!/bin/bash
# Test for qemu-darwin-surface-memory.patch (no VM): the surface functions of
# the patched QEMU source with stand-ins for the file calls and a slow
# close() (CLOSE_MS, default 2200), in both modes, and QEMU's log line.
#   test-surface-memory.sh QEMU_SOURCE_DIR [WORK_DIR]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${1:?usage: test-surface-memory.sh QEMU_SOURCE_DIR [WORK_DIR]}
work=${2:-$(mktemp -d "${TMPDIR:-/tmp}/omacvm-test-surface.XXXXXX")}
mkdir -p "$work"
awk '/^#ifdef WIN32$/ { buf = $0 "\n"; on = 1; next } on { buf = buf $0 "\n" } on && /^#endif$/ { if (buf ~ /typedef int qemu_pixman_shareable;/) printf "%s", buf; on = 0 }' \
  "$src/include/ui/qemu-pixman.h" > "$work/qemu-pixman-shareable.inc"
awk '/^void \*qemu_memfd_alloc\(/,/^}$/ { print } /^void qemu_memfd_free\(/,/^}$/ { print }' "$src/util/memfd.c" \
  > "$work/memfd-alloc-free.inc"
awk 'prev ~ /^static void \*$/ && /^qemu_pixman_shareable_alloc\(/ { on = 1; print prev }
     on { print } on && /^qemu_pixman_image_new_shareable\(/ { last = 1 } on && last && /^}$/ { exit } { prev = $0 }' \
  "$src/ui/qemu-pixman.c" > "$work/pixman-shareable.inc"
for f in qemu-pixman-shareable memfd-alloc-free pixman-shareable; do
  [[ -s $work/$f.inc ]] || { echo "FAIL: nothing taken for $f.inc from $src"; exit 1; }
done
cc -Wall -Werror -Wno-unused-function -I"$work" -I"$src/include/ui" "$here/test-surface-memory.c" \
  -o "$work/test-surface-memory"
fail=0
run() {   # run MODE ENV_VALUE CLOSE_MS WANT_LOG
  local log
  OMACVM_SURFACE_MEMORY=$2 "$work/test-surface-memory" "$3" "$1" 2>"$work/$1.err" | sed 's/^/  /' || fail=1
  log=$(cat "$work/$1.err")
  [[ $log == "$4" ]] || { echo "FAIL $1: QEMU's log said: '$log'"; echo "  want: '$4'"; fail=1; }
}
run memory "" "${CLOSE_MS:-2200}" "OmacVM: display surfaces: in memory (no temp files)"
run file file 0 "OmacVM: display surfaces: temp files (OMACVM_SURFACE_MEMORY=file)"
(( fail == 0 )) && echo "test-surface-memory: all ok" || { echo "test-surface-memory: FAILED"; exit 1; }
