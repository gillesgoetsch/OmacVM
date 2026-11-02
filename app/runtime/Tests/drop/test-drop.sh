#!/bin/bash
# Drag and drop of files into the VM (drag-drop): the rules
# (omacvm-cocoa-drop-logic.patch makes ui/omacvm-drop.h in an empty folder,
# test-drop.c runs against it) and the hooks omacvm-cocoa-drop.patch puts into
# ui/cocoa.m: with the feature off (no OMACVM_DROP_SOCKET) no view takes drops.
# No QEMU, no display.
#   test-drop.sh                         (CI: the hooks from the patch)
#   test-drop.sh <patched ui/cocoa.m>    (the runtime build)
#   test-drop.sh --self-test <ui/cocoa.m before the patch>: every wiring check fails there
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-drop.XXXXXX")
trap 'rm -rf "$work"' EXIT
self=0
if [[ ${1:-} == --self-test ]]; then self=1; shift; fi
if (( ! self )); then
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-drop-logic.patch"
  san=(-fsanitize=address,undefined)
  cc -std=c11 -Wall -Wextra -Werror "${san[@]}" -x c /dev/null -c -o "$work/probe.o" 2>/dev/null || san=()
  cc -std=c11 -Wall -Wextra -Werror ${san[@]+"${san[@]}"} -I"$work/ui" "$here/test-drop.c" -o "$work/test-drop"
  "$work/test-drop"
fi
if [[ $# -ge 1 ]]; then
  src=$1
else
  # The patch's new side: context and added lines, without the removed ones.
  src=$work/new.m
  awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' "$patches/omacvm-cocoa-drop.patch" > "$src"
fi
fail=0 passed=0
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
has() {
  if grep -qF -- "$3" <<<"$2"; then echo "ok   $1"; passed=$((passed + 1)); else echo "FAIL $1"; fail=1; fi
}
init=$(body "$src" 'static void omacvm_drop_init(void)')
has "on only with OMACVM_DROP_SOCKET" "$init" 'if (!path || !*path) {'
on_line=$(grep -nF 'omacvm_drop_on = true;' <<<"$init" | cut -d: -f1 || true)
ret_line=$(grep -nF 'if (!path || !*path) {' <<<"$init" | cut -d: -f1 || true)
if [[ -n $on_line && -n $ret_line && $on_line -gt $ret_line ]]; then echo "ok   ... set after that check"; passed=$((passed + 1))
else echo "FAIL omacvm_drop_on set before checking OMACVM_DROP_SOCKET"; fail=1; fi
n=$(grep -c 'omacvm_drop_on = ' "$src" || true)
if [[ $n -eq 1 ]]; then echo "ok   ... and nowhere else"; passed=$((passed + 1)); else echo "FAIL omacvm_drop_on is set in $n places"; fail=1; fi
has "views registered only when on" "$(grep -A3 -xF 'static void omacvm_drop_register(NSView *view)' "$src" || true)" 'if (omacvm_drop_on) {'
has "... the main view at init" "$init" 'omacvm_drop_register(cocoaView);'
has "... every display head's view" "$(cat "$src")" '        omacvm_drop_register(self);'
n=$(grep -c 'registerForDraggedTypes' "$src" || true)
if [[ $n -eq 1 ]]; then echo "ok   no other drop registration"; passed=$((passed + 1)); else echo "FAIL registerForDraggedTypes in $n places"; fail=1; fi
if [[ $(grep -A1 -xF '    omacvm_ime_init();' "$src" | tail -1) == '    omacvm_drop_init();' ]]; then
  echo "ok   started with the display (after mac-ime)"; passed=$((passed + 1))
else echo "FAIL omacvm_drop_init() is not called after omacvm_ime_init()"; fail=1; fi
take=$(body "$src" 'static bool omacvm_drop_take(NSArray<NSURL *> *urls)')
has "a drop: the rules first" "$take" 'if (v != OMACVM_DROP_TAKE) {'
has "... then opened off the main thread" "$take" 'dispatch_async(omacvm_drop_queue, ^{'
n=$(grep -c 'open(path, O_RDONLY' "$src" || true)
send=$(body "$src" 'static void omacvm_drop_send(NSArray<NSString *> *paths)')
has "files opened only in omacvm_drop_send (the queue)" "$send" 'fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);'
if [[ $n -eq 1 ]]; then echo "ok   ... nowhere else"; passed=$((passed + 1)); else echo "FAIL a dropped path is opened in $n places"; fail=1; fi
has "... regular files only" "$send" '!S_ISREG(st.st_mode)'
has "... a time limit for a drop" "$send" 'OMACVM_DROP_OPEN_LIMIT'
has "... sent as open files, never paths" "$(body "$src" 'static bool omacvm_drop_send_frame(')" 'c.h.cmsg_type = SCM_RIGHTS;'
v=$(body "$src" 'static int omacvm_drop_verdict_for(NSArray<NSURL *> *urls)')
has "taken only after the app's ready" "$v" '.ready = omacvm_drop_ready && omacvm_drop_fd >= 0,'
has "... folders from the URL alone (no disk access on the main thread)" "$v" '[u hasDirectoryPath]'
over=$(body "$src" 'static NSDragOperation omacvm_drag_over(')
has "while dragging: no drop unless the rules take it" "$over" 'return NSDragOperationNone;'
has "... the guest's pointer follows the drag" "$over" 'omacvmQueuePointer:e view:view output:output'
lcb=$(body "$src" 'static void omacvm_drop_line_cb(const char *line, void *ctx)')
has "test-drop lines only with OMACVM_DROP_TEST=1" "$lcb" 'if (omacvm_drop_test) {'
has "... through the window's own path" "$lcb" 'omacvm_drop_take(urls);'
for c in QemuCocoaView OmacVMHeadView; do
  impl=$(awk -v h="@implementation $c (OmacVMDrop)" 'index($0, h) == 1 {on=1} on {print} on && /^@end/ {exit}' "$src")
  has "$c: performDragOperation takes the drop" "$impl" '- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { return omacvm_drop_take(omacvm_drop_urls(info)); }'
done
if (( self )); then
  if (( passed == 0 )); then echo "ok   self-test: every wiring check fails before the patch"; exit 0; fi
  echo "FAIL self-test: $passed wiring checks pass before the patch"; exit 1
fi
exit $fail
