#!/bin/bash
# OmacVM.app's full screen is always macOS's own, in a Space of its own, on
# every display (the notch's borderless kind shared the user's Space, and the
# escape combo then opened Mission Control). Checks, without a VM or a window:
#   - the app no longer asks QEMU for the notch's full screen (OMACVM_NOTCH)
#     nor tells the guest it covers the strip (omacvm.notch), and has no switch;
#   - the runtime build applies both patches after the boot splash and checks
#     the patched ui/cocoa.m (test-fullscreen-space.sh, its self-test here);
#   - `omacvm check` no longer reads the old switch;
#   - the shutdown, full-screen start and quit patches come after them, pinned
#     and checked (their tests' self-tests here);
#   - a borderless window has no shadow, so no macOS 26 rim.
#   src/tests/app-fullscreen-space.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() { grep -rqE "$1" "${@:2}" && echo yes || echo no; }

S="$R/app/app/Sources/OmacVM"
expect "the app sets no OMACVM_NOTCH" no "$(has 'OMACVM_NOTCH' "$S")"
# (omacvm.notchpointer, the pointer park in NOTCH, is another key)
expect "the app sends no omacvm.notch" no "$(has 'omacvm\.notch([^a-z]|$)' "$S")"
expect "no notch switch in the app" no "$(has 'useNotch|Use the notch for the menu bar' "$S")"
expect "omacvm check does not read the old switch" no "$(has 'useNotch' "$R/src/cmd/check.sh")"

B="$R/app/runtime/build-qemu-gpu-runtime.sh"
line() { grep -n -m1 -F "$1" "$B" | cut -d: -f1; }
splash=$(line 'patches/omacvm-cocoa-boot-splash.patch"')
own=$(line 'patches/omacvm-cocoa-fullscreen-own-space.patch"')
key=$(line 'patches/omacvm-cocoa-head-key-same-space.patch"')
test=$(line 'Tests/display/test-fullscreen-space.sh" "$source_dir/ui/cocoa.m"')
expect "the build applies both patches after the boot splash, then tests" yes \
  "$([[ -n $splash && -n $own && -n $key && -n $test ]] && (( splash < own && own < key && key < test )) && echo yes || echo no)"
for p in omacvm-cocoa-fullscreen-own-space.patch omacvm-cocoa-head-key-same-space.patch; do
  expect "$p pinned" yes \
    "$(cd "$R/app/runtime/patches" && grep -q " $p\$" SHA256SUMS && shasum -a 256 -c --status <(grep " $p\$" SHA256SUMS) && echo yes || echo no)"
done

out=$("$R/app/runtime/Tests/display/test-fullscreen-space.sh" --self-test 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect "test-fullscreen-space.sh catches the old code" 0 "$rc"

# The shutdown crash guard and the hidden full-screen start, after them.
for p in omacvm-cocoa-shutdown-events.patch omacvm-cocoa-fullscreen-start.patch; do
  expect "$p pinned" yes \
    "$(cd "$R/app/runtime/patches" && grep -q " $p\$" SHA256SUMS && shasum -a 256 -c --status <(grep " $p\$" SHA256SUMS) && echo yes || echo no)"
done
down=$(line 'patches/omacvm-cocoa-shutdown-events.patch"')
start=$(line 'patches/omacvm-cocoa-fullscreen-start.patch"')
expect "the build applies them after the full-screen patches" yes \
  "$([[ -n $down && -n $start ]] && (( key < down && down < start )) && echo yes || echo no)"
for t in test-shutdown-events.sh test-fullscreen-start.sh; do
  out=$("$R/app/runtime/Tests/display/$t" --self-test 2>&1); rc=$?
  echo "$out" | sed 's/^/     /'
  expect "$t catches the old code" 0 "$rc"
done

# No quit by itself (a hidden full-screen run quit after a minute); a quit
# presses the power button again: last, after the full-screen start.
p=omacvm-cocoa-quit-clean.patch
expect "$p pinned" yes \
  "$(cd "$R/app/runtime/patches" && grep -q " $p\$" SHA256SUMS && shasum -a 256 -c --status <(grep " $p\$" SHA256SUMS) && echo yes || echo no)"
quit=$(line 'patches/omacvm-cocoa-quit-clean.patch"')
qtest=$(line 'Tests/display/test-quit-clean.sh" "$source_dir/ui/cocoa.m"')
expect "the build applies it after the full-screen start, then tests" yes \
  "$([[ -n $quit && -n $qtest ]] && (( start < quit && quit < qtest )) && echo yes || echo no)"
out=$("$R/app/runtime/Tests/display/test-quit-clean.sh" --self-test 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect "test-quit-clean.sh catches the old code" 0 "$rc"

# A borderless window has no shadow (macOS 26's light rim around the
# display): after the Touch ID panel and the tap permission, then tested.
p=omacvm-cocoa-borderless-no-rim.patch
expect "$p pinned" yes \
  "$(cd "$R/app/runtime/patches" && grep -q " $p\$" SHA256SUMS && shasum -a 256 -c --status <(grep " $p\$" SHA256SUMS) && echo yes || echo no)"
panel=$(line 'patches/omacvm-cocoa-touchid-panel.patch"')
tap=$(line 'patches/omacvm-cocoa-tap-permission.patch"')
rim=$(line 'patches/omacvm-cocoa-borderless-no-rim.patch"')
rtest=$(line 'Tests/display/test-borderless-rim.sh" "$source_dir/ui/cocoa.m"')
expect "the build applies it after the Touch ID panel and the tap permission (its header), then tests" yes \
  "$([[ -n $panel && -n $tap && -n $rim && -n $rtest ]] && (( quit < panel && panel < tap && tap < rim && rim < rtest )) && echo yes || echo no)"
out=$("$R/app/runtime/Tests/display/test-borderless-rim.sh" --self-test 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect "test-borderless-rim.sh catches the old code" 0 "$rc"
out=$("$R/app/runtime/Tests/display/test-borderless-rim-live.sh" --build-only 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect "the live rim probe builds with the patch's helper" 0 "$rc"
exit $fail
