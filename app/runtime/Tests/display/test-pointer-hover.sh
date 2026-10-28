#!/bin/bash
# A move over the VM while another app is in front gives the guest the
# pointer's place, and nothing else (omacvm-cocoa-pointer-hover*.patch):
#   - the rule: the logic patch makes ui/omacvm-pointer-hover.h in an empty
#     folder and test-pointer-hover.c runs against it (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (the other displays' windows give
#     the place before their early return; the main view has a second
#     tracking area, active always, with its own owner, through the same
#     rule; the hover sends only the place: no grab, no corner guard, no
#     cursor change, no key window, nothing activated; the switch and the
#     qemu.log line at start);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check
#     fails on that code (CI: a stub; the runtime build: the real cocoa.m
#     before the patch).
#   test-pointer-hover.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
# A function's or method's body: from its first line (HEAD starts it) to the
# first '}' at the line's start. A declaration is not it: a line ending in ';'
# before the '{' line (a method's declaration can take two lines).
body() {
  awk -v h="$2" '
    !on && index($0, h) == 1 && $0 !~ /;$/ { on = 1; open = 0; buf = "" }
    on && !open { buf = buf $0 "\n"; if ($0 ~ /;$/) { on = 0; next }
                  if ($0 ~ /^\{/) { open = 1; printf "%s", buf }; next }
    on { print } on && /^}$/ { exit }' "$1"
}
# One line per check: "ok WHAT" or "FAIL WHAT".
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
# In TEXT, the first line with A comes before the first line with B (both there).
line() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }
before() { local a b; a=$(line "$1" "$2"); b=$(line "$1" "$3"); [[ -n $a && -n $b ]] && (( a < b )); }
# TEXT is there and has none of the calls that take the pointer, the keyboard or the cursor.
only_place() {
  [[ -n $1 ]] || return 1
  local bad
  for bad in grabMouse omacvm_guard_corners omacvm_cursor_again omacvm_cursor_image NSCursor \
             makeKey makeKeyWindow activateIgnoringOtherApps activate CGAssociateMouseAndMouseCursorPosition \
             CGWarpMouseCursorPosition qemu_input_queue_btn 'isMouseGrabbed =' omacvmTakePointer; do
    has "$1" "$bad" && return 1
  done
  return 0
}
checks() {
  local m=$1 head wanted hover main init watch pinit
  head=$(body "$m" '- (void) omacvmHeadEvent:(NSEvent *)event view:(NSView *)view output:(int)output')
  wanted=$(body "$m" '- (bool) omacvmHoverWanted:(NSEvent *)event view:(NSView *)view output:(int)output')
  hover=$(body "$m" '- (void) omacvmHover:(NSEvent *)event view:(NSView *)view output:(int)output')
  main=$(body "$m" '- (void) omacvmHoverMain:(NSEvent *)event')
  init=$(body "$m" '- (id)initWithFrame:(NSRect)frameRect')
  watch=$(awk '/^@implementation OmacVMHoverWatch/ {on=1} on {print} on && /^@end/ {exit}' "$m")
  pinit=$(body "$m" 'static void omacvm_pointer_init(void)')
  chk "the rule is included" grep -q '#include "ui/omacvm-pointer-hover.h"' "$m"
  chk "another display's window: a move while another app is in front asks the rule" \
    has "$head" 'if ([self omacvmHoverWanted:event view:view output:output button:button]) {'
  chk "and gives the place before its early return" \
    before "$head" '[self omacvmHover:event view:view output:output];' 'return;'
  chk "never takes the pointer for it (the hover comes before the grab)" \
    before "$head" '[self omacvmHover:event view:view output:output];' '[self grabMouse];'
  chk "the rule: OMACVM_POINTER_HOVER" has "$wanted" '.off = omacvm_hover_off,'
  chk "the rule: an absolute pointer" has "$wanted" '.absolute = isAbsoluteEnabled,'
  chk "the rule: the VM does not have the pointer" has "$wanted" '.grabbed = isMouseGrabbed,'
  chk "the rule: OmacVM not in front" has "$wanted" '.active = [NSApp isActive],'
  chk "the rule: a move" has "$wanted" '.move = button < 0,'
  chk "the rule: no button held" has "$wanted" '.buttons = [NSEvent pressedMouseButtons] != 0,'
  chk "the rule: Touch ID's panel down" has "$wanted" '.touchid = omacvm_touchid_up,'
  chk "the rule: two or more displays" has "$wanted" '.displays = omacvm_active_outputs(),'
  chk "the rule: a window in full screen" has "$wanted" '.full = output > 0 || omacvm_main_full_screen(),'
  chk "the rule: the window on top under the pointer" has "$wanted" '[NSWindow windowNumberAtPoint:[NSEvent mouseLocation]'
  chk "the rule decides" has "$wanted" 'return omacvm_pointer_hover(&in);'
  chk "the hover sends only the place: no grab, no guard, no cursor, no key window, no activation" \
    only_place "$hover"
  chk "the hover drops a place the corner guard kept, before the place is queued" \
    before "$hover" 'omacvm_guard_place = false;' 'omacvmQueuePointer:event view:view output:output'
  chk "the hover sends the place with the BQL" has "$hover" 'with_bql(^{'
  chk "the hover syncs the tablet's event" has "$hover" 'qemu_input_event_sync();'
  chk "the hover's debug line, rate limited" has "$hover" 'omacvm_hover_log_due(CACurrentMediaTime(), &omacvm_hover_logged)'
  chk "the main view: a second tracking area, active always, with moves" \
    has "$init" 'options:NSTrackingActiveAlways |'
  chk "the main view's second area has its own owner (no second mouseMoved: to the view)" \
    has "$init" 'owner:omacvm_hover_watch'
  chk "the main view's second area is added" has "$init" '[self addTrackingArea:hoverArea];'
  chk "its moves go to the main view's hover" has "$watch" '[cocoaView omacvmHoverMain:e];'
  chk "the main view's hover goes only through the same rule" \
    before "$main" 'if ([self omacvmHoverWanted:event view:self output:0 button:-1]) {' '[self omacvmHover:event view:self output:0];'
  chk "the main view's hover sends only the place" only_place "$main"
  chk "OMACVM_POINTER_HOVER read at start" has "$pinit" 'omacvm_hover_off = omacvm_pointer_hover_off(getenv("OMACVM_POINTER_HOVER"));'
  chk "qemu.log says at start whether it is on" has "$pinit" 'is in front: %s", omacvm_hover_off ? "dropped (OMACVM_POINTER_HOVER=0)"'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-hover.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    # The code before the patch (837b4a88): such a move is dropped.
    { printf -- '- (void) omacvmHeadEvent:(NSEvent *)event view:(NSView *)view output:(int)output\n'
      printf '                  button:(int)button down:(bool)down\n{\n'
      printf '    if (!isMouseGrabbed) {\n        if (button < 0 && (!isAbsoluteEnabled || ![NSApp isActive])) {\n'
      printf '            return;\n        }\n        [self grabMouse];\n    }\n}\n'
      printf -- '- (id)initWithFrame:(NSRect)frameRect\n{\n'
      printf '    NSTrackingAreaOptions options = NSTrackingActiveInKeyWindow |\n'
      printf '                                    NSTrackingMouseMoved;\n'
      printf '    [self addTrackingArea:trackingArea];\n}\n'
      printf 'static void omacvm_pointer_init(void)\n{\n    omacvm_ptr.off = v && !strcmp(v, "0");\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$(checks "$1" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-pointer-hover: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-pointer-hover: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-hover.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-pointer-hover-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-pointer-hover.c" -o "$work/test-pointer-hover" -lm
"$work/test-pointer-hover"
