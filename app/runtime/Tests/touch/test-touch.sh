#!/bin/bash
# Touch on a touch display (omacvm-cocoa-touch*.patch, #843):
#   - the rules: the logic patch makes ui/omacvm-touch.h in an empty folder
#     and test-touch.c runs against it (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (one recognizer on the main view
#     and on every other display's view, direct touches only, begun at
#     touch-down so AppKit's mouse emulation never runs; the fingers' own
#     movement to the rules; the guest's pointer to the finger, never through
#     the mouse path or the corner guard; scrolling on the precise-scroll
#     path; the coast's timer in the common modes; a pinch's two fingers to
#     the guest's touch screen, never a trackpad's made-up ones; the switches
#     and the qemu.log lines at start);
#   - with a patched hw/input/virtio-input-hid.c too: the multitouch device
#     is a touch screen only (omacvm-virtio-multitouch-touch-only.patch);
#   - with --self-test [<ui/cocoa.m> [<virtio-input-hid.c>] without the
#     patches]: every wiring check fails on that code (CI: stubs; the runtime
#     build: the real files before the patches).
#   test-touch.sh [<patched ui/cocoa.m> [<patched virtio-input-hid.c>] |
#                  --self-test [<old ui/cocoa.m> [<old virtio-input-hid.c>]]]
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
lacks() { [[ -n $1 ]] && ! grep -qF -- "$2" <<<"$1"; }
# In TEXT, the first line with A comes before the first line with B (both there).
line() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }
before() { local a b; a=$(line "$1" "$2"); b=$(line "$1" "$3"); [[ -n $a && -n $b ]] && (( a < b )); }
checks() {
  local m=$1 hid=${2:-} main head install rinit began moved ended cancelled touch tscroll queue stop pinit rec
  local two contact screen share place fake handler minit
  main=$(body "$m" '- (id)initWithFrame:(NSRect)frameRect')
  head=$(body "$m" '- (id)initWithFrame:(NSRect)frame output:(int)index')
  install=$(body "$m" 'static void omacvm_touch_install(NSView *view, int output)')
  rec=$(awk '/^@implementation OmacVMTouchRecognizer/ {on=1} on {print} on && /^@end/ {exit}' "$m")
  rinit=$(body "$m" '- (instancetype)initWithOutput:(int)index')
  began=$(body "$m" '- (void)touchesBeganWithEvent:(NSEvent *)event')
  moved=$(body "$m" '- (void)touchesMovedWithEvent:(NSEvent *)event')
  ended=$(body "$m" '- (void)touchesEndedWithEvent:(NSEvent *)event')
  cancelled=$(body "$m" '- (void)touchesCancelledWithEvent:(NSEvent *)event')
  touch=$(body "$m" '- (void) omacvmTouch:(const OmacVMTouchActions *)acts view:(NSView *)view output:(int)output')
  tscroll=$(body "$m" '- (void) omacvmTouchScroll:(double)dx dy:(double)dy')
  queue=$(body "$m" '- (bool) omacvmQueuePointer:(NSEvent *)event view:(NSView *)view output:(int)output')
  stop=$(body "$m" 'static void omacvm_coast_stop(void)')
  pinit=$(body "$m" 'static void omacvm_pointer_init(void)')
  two=$(body "$m" '- (void)two:(NSDictionary *)now')
  contact=$(body "$m" '- (void) omacvmTouchContact:(int)slot type:(InputMultiTouchType)type u:(double)u v:(double)v')
  screen=$(body "$m" 'static bool omacvm_touch_screen(void)')
  share=$(body "$m" '- (bool) omacvmShare:(NSPoint)p view:(NSView *)view u:(double *)u v:(double *)v')
  place=$(body "$m" '- (bool) omacvmQueuePlace:(NSPoint)p view:(NSView *)view output:(int)output')
  fake=$(body "$m" 'static void cocoa_pinch_send_frame(void *opaque, const CocoaPinchFrame *frame)')
  chk "the rules are included" grep -q '#include "ui/omacvm-touch.h"' "$m"
  chk "the main view gets the recognizer" has "$main" 'omacvm_touch_install(self, 0);'
  chk "every other display's view gets it, with its output" has "$head" 'omacvm_touch_install(self, index);'
  chk "OMACVM_TOUCH not 1: no recognizer (AppKit's emulation as before)" \
    before "$install" 'if (omacvm_touch_off) {' 'addGestureRecognizer:'
  chk "the switches are read before the first view asks" has "$install" 'omacvm_touch_settings();'
  chk "the recognizer takes direct touches only (never a mouse or a trackpad)" \
    has "$rinit" '[self setAllowedTouchTypes:NSTouchTypeMaskDirect];'
  chk "the recognizer delays no mouse button" has "$rinit" '[self setDelaysPrimaryMouseButtonEvents:NO];'
  chk "a mouse click fails the recognizer (the view's own methods take it)" \
    has "$rec" '- (void)mouseDown:(NSEvent *)click { [self setState:NSGestureRecognizerStateFailed]; }'
  chk "the recognizer gives its own location (macOS 27 SDK)" has "$rec" '- (NSPoint)locationInView:(NSView *)view'
  chk "touch-down begins the recognizer (AppKit's emulation never runs), before the rules" \
    before "$began" '[self setState:NSGestureRecognizerStateBegan];' 'omacvm_touch_begin(&omacvm_touch, [event timestamp]'
  chk "a move gives the fingers' own movement (each finger against its last place)" \
    has "$moved" 'NSValue *was = fingers[k];'
  chk "a move goes to the rules with the event's time" has "$moved" 'omacvm_touch_move(&omacvm_touch, [event timestamp]'
  chk "a lift goes to the rules with the fingers still down" \
    has "$ended" 'omacvm_touch_lift(&omacvm_touch, [event timestamp], (int)[now count], &acts);'
  chk "the recognizer ends at the last lift" has "$ended" '[self setState:NSGestureRecognizerStateEnded];'
  chk "macOS taking the touches ends a drag" has "$cancelled" 'omacvm_touch_cancel(&omacvm_touch, &acts);'
  chk "the guest's pointer goes to the finger (omacvmQueuePlace)" \
    has "$touch" 'omacvmQueuePlace:NSMakePoint(a->x, a->y) view:view output:output'
  chk "a touch never takes the mouse path" lacks "$touch" 'handleMouseEvent'
  chk "a touch never goes through the corner guard" lacks "$touch" 'omacvm_guard_corners'
  chk "a touch's place is never the guard's" lacks "$touch" 'omacvmQueuePointer'
  chk "no tablet yet: nothing placed" has "$touch" 'if (!isAbsoluteEnabled) {'
  chk "a touch with another app in front brings OmacVM forward" has "$touch" '[NSApp activate];'
  chk "and takes the pointer, as a click does" has "$touch" '[self grabMouse];'
  chk "buttons with their own sync" has "$touch" 'qemu_input_queue_btn(dcl.con, b, down);'
  chk "the coast's timer runs in the common modes (AppKit tracks touches in another)" \
    has "$touch" 'addTimer:omacvm_coast_timer forMode:NSRunLoopCommonModes'
  chk "the coast's steps are the rules'" has "$touch" 'omacvm_touch_coast_step(&omacvm_coast_vx, &omacvm_coast_vy,'
  chk "a coast is stopped by invalidating its timer" has "$stop" '[omacvm_coast_timer invalidate];'
  chk "scrolling: the content follows the finger (the rules' deltas)" \
    has "$tscroll" 'omacvm_touch_scroll_deltas(dx, dy, omacvm_touch_gain, &sx, &sy);'
  chk "scrolling: on the precise-scroll path, its own remainder" \
    has "$tscroll" 'cocoa_scroll_update(&omacvm_touch_scroll, sx, sy);'
  chk "scrolling: Cocoa's X to Linux's (REL_HWHEEL is right)" \
    has "$tscroll" 'qemu_input_queue_rel(dcl.con, INPUT_AXIS_HWHEEL, -frame.x);'
  chk "the mouse's place: the guard first, then the same mapping as a touch's" \
    before "$queue" 'omacvm_guarded_target(&view, &output, &p)' 'return [self omacvmQueuePlace:p view:view output:output];'
  chk "qemu.log says at start whether touch is on" has "$pinit" '"AppKit'"'"'s mouse emulation (OMACVM_TOUCH is not 1)"'
  chk "qemu.log says the scrolling's gain" has "$pinit" 'wheel units per point (OMACVM_TOUCH_SCROLL)'
  chk "two fingers landing go to the rules, after the touch-down" \
    before "$began" 'omacvm_touch_begin(&omacvm_touch, [event timestamp]' '[self two:now];'
  chk "two fingers moving go to the rules, after the move" \
    before "$moved" 'omacvm_touch_move(&omacvm_touch, [event timestamp]' '[self two:now];'
  chk "only exactly two fingers" has "$two" 'if ([ids count] != 2) {'
  chk "the same finger first every time (each keeps its contact in the guest)" \
    before "$two" 'if (!first || !now[first]) {' 'omacvm_touch_two(&omacvm_touch, a.x, a.y, b.x, b.y, &acts);'
  chk "the guest's touch screen is the virtio-multitouch device" \
    has "$screen" 'object_resolve_path_type("", "virtio-multitouch-device", NULL) != NULL;'
  chk "a pinch without a touch screen in the guest sends nothing" has "$touch" 'if (!omacvm_touch_screen() ||'
  chk "a pinch's first finger is contact 0, at its share of the output" \
    has "$touch" '[self omacvmTouchContact:0 type:type u:u0 v:v0];'
  chk "a pinch's second finger is contact 1" has "$touch" '[self omacvmTouchContact:1 type:type u:u1 v:v1];'
  chk "a pinch's end lifts contact 0" has "$touch" 'qemu_input_queue_mtt(dcl.con, INPUT_MULTI_TOUCH_TYPE_END, 0, -1);'
  chk "a pinch's end lifts contact 1" has "$touch" 'qemu_input_queue_mtt(dcl.con, INPUT_MULTI_TOUCH_TYPE_END, 1, -1);'
  chk "a contact: its slot before its place (the device sends the place to the slot named last)" \
    before "$contact" 'qemu_input_queue_mtt(dcl.con, type, slot, slot);' 'qemu_input_queue_mtt_abs(dcl.con, INPUT_AXIS_X,'
  chk "a contact stays on its output" has "$contact" 'lround(MIN(1.0, MAX(0.0, v)) * INPUT_EVENT_ABS_MAX),'
  chk "no button event for a contact (the tablet takes the UI's buttons)" lacks "$touch$contact" 'INPUT_BUTTON_TOUCH'
  chk "a finger's share of its output: the main view's black rows are not the guest" \
    has "$share" 'size.height -= black;'
  chk "the pointer's place uses the same share" has "$place" '[self omacvmShare:p view:view u:&u v:&v]'
  chk "a trackpad's made-up pinch contacts never go to the guest's touch screen" \
    before "$fake" 'if (omacvm_touch_screen()) {' 'qemu_input_queue_mtt(dcl.con,'
  chk "qemu.log says where a pinch goes" has "$pinit" '"cocoa: touch: a two-finger pinch %s", omacvm_touch_screen() ?'
  [[ -n $hid ]] || return 0
  handler=$(awk '/^static const QemuInputHandler virtio_multitouch_handler = \{/ {on=1} on {print} on && /^};/ {exit}' "$hid")
  minit=$(body "$hid" 'static void virtio_multitouch_init(Object *obj)')
  chk "the multitouch device takes multitouch events only (no button of the tablet's)" \
    has "$handler" '.mask  = INPUT_EVENT_MASK_MTT,'
  chk "the multitouch device shows the guest BTN_TOUCH only" has "$minit" 'virtio_input_extend_config(vinput, keys,'
  chk "the multitouch device shows the guest no mouse's buttons" lacks "$minit" 'keymap_button'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-} oldhid=${3:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-touch.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    # The multitouch device before the patch: the buttons' events and a mouse's buttons.
    { printf 'static const QemuInputHandler virtio_multitouch_handler = {\n'
      printf '    .mask  = INPUT_EVENT_MASK_BTN | INPUT_EVENT_MASK_MTT,\n};\n'
      printf 'static void virtio_multitouch_init(Object *obj)\n{\n'
      printf '    virtio_input_extend_config(vinput, keymap_button,\n}\n'; } > "$T/old-hid.c"
    oldhid=$T/old-hid.c
    # The code before the patch: the views' inits and the mouse's place.
    { printf -- '- (id)initWithFrame:(NSRect)frameRect\n{\n    [self addTrackingArea:hoverArea];\n}\n'
      printf -- '- (id)initWithFrame:(NSRect)frame output:(int)index\n{\n    omacvm_drop_register(self);\n}\n'
      printf -- '- (bool) omacvmQueuePointer:(NSEvent *)event view:(NSView *)view output:(int)output\n{\n'
      printf '    if (omacvm_guarded_target(&view, &output, &p) < 0) {\n        return true;\n    }\n}\n'
      printf 'static void cocoa_pinch_send_frame(void *opaque, const CocoaPinchFrame *frame)\n{\n'
      printf '        qemu_input_queue_mtt(dcl.con,\n}\n'
      printf 'static void omacvm_pointer_init(void)\n{\n    omacvm_ptr.off = v && !strcmp(v, "0");\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" "$oldhid" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old${oldhid:+, $oldhid})"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old${oldhid:+, $oldhid}):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$(checks "$1" "${2:-}" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-touch: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-touch: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-touch.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-touch-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-touch.c" -o "$work/test-touch" -lm
"$work/test-touch"
