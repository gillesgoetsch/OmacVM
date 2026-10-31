#!/bin/bash
# Offline checks for display surfaces in memory (no VM, no QEMU build): the
# patch is pinned, applied, checked and tested by the runtime build, it has
# its guard, switch and log lines, and the build stops on a QEMU configured
# with a D-Bus display. The patch's own test (stand-ins for the file calls,
# a 2.2 s close()) is app/runtime/Tests/display/test-surface-memory.sh, run
# by the runtime build on the patched QEMU source.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-darwin-surface-memory.patch
B=$R/app/runtime/build-qemu-gpu-runtime.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
pinned() { (cd "$R/app/runtime/patches" && grep " qemu-darwin-surface-memory.patch$" SHA256SUMS | shasum -a 256 -c -); }

check "patch is pinned in SHA256SUMS" grep -q " qemu-darwin-surface-memory.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "patch matches its pinned checksum" pinned
check "runtime build applies the patch" grep -q 'patches/qemu-darwin-surface-memory.patch"' "$B"
check "runtime build stops when the mmap is missing" \
  grep -qF "grep -q 'MAP_PRIVATE | MAP_ANON' \"\$source_dir/ui/qemu-pixman.c\"" "$B"
check "runtime build runs its test on the patched source" \
  grep -q 'Tests/display/test-surface-memory.sh" "$source_dir"' "$B"
check "runtime build stops without CONFIG_DARWIN or with CONFIG_DBUS_DISPLAY" \
  grep -q 'CONFIG_DBUS_DISPLAY.*"\$config_host"' "$B"
check "the test's files are in the runtime inputs" grep -q 'Tests/display/\*' "$R/app/scripts/build-app.sh"
check "the test files are there" test -x "$R/app/runtime/Tests/display/test-surface-memory.sh" -a \
  -f "$R/app/runtime/Tests/display/test-surface-memory.c"
check "patch only on macOS without a D-Bus display" \
  grep -qF '+#elif defined(CONFIG_DARWIN) && !defined(CONFIG_DBUS_DISPLAY)' "$P"
check "patch maps anonymous memory" \
  grep -qF '+    p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);' "$P"
check "patch sets no share handle" grep -qF '+    *handle = SHAREABLE_NONE;' "$P"
check "patch reads OMACVM_SURFACE_MEMORY" grep -qF 'getenv("OMACVM_SURFACE_MEMORY")' "$P"
check "OMACVM_SURFACE_MEMORY=file keeps the temp files" \
  grep -qF '+        return qemu_memfd_alloc(name, size, 0, handle, errp);' "$P"
for line in '"OmacVM: display surfaces: %s\n"' '"temp files (OMACVM_SURFACE_MEMORY=file)"' '"in memory (no temp files)"'; do
  check "patch logs $line" grep -qF "$line" "$P"
done
# The free path is QEMU's own: the patch touches only the alloc function.
check "patch changes one file, one hunk" test "$(grep -c '^@@ ' "$P")-$(grep -c '^+++ ' "$P")" = "1-1"
echo "surface-memory: $((N - FAIL)) of $N ok"
(( FAIL == 0 ))
