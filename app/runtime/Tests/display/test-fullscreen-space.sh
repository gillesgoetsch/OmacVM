#!/bin/bash
# Full screen always in its own Space (omacvm-cocoa-fullscreen-own-space.patch)
# and a display that left the VM's Space stays left
# (omacvm-cocoa-head-key-same-space.patch), checked in the patched ui/cocoa.m:
#   - the full-screen toggle reaches the borderless kind (no Space) only in
#     test mode, else macOS's own toggleFullScreen:;
#   - nothing reads OMACVM_NOTCH any more, and the guest is sized from the
#     safe area (below the notch, where macOS puts a full-screen window);
#   - an extra display's window hands the key back to the main window at a
#     click in it (mouseDown:), only while the main window's Space shows, and
#     never when it merely becomes key (that depended on the order in which
#     macOS changes the key window and the Space).
#   test-fullscreen-space.sh <patched ui/cocoa.m>   (the runtime build)
#   test-fullscreen-space.sh --self-test            (CI: the checks catch the old code)
set -uo pipefail

# Prints what is wrong with FILE, nothing if it is right.
problems() {
  local f=$1 toggle safe head deleg down
  toggle=$(awk '/^- \(void\) ?doToggleFullScreen:\(id\)sender$/{on=1} on{print} on&&/^}$/{exit}' "$f")
  safe=$(awk '/^- \(NSSize\) ?screenSafeAreaSize$/{on=1} on{print} on&&/^}$/{exit}' "$f")
  head=$(awk '/^- \(void\)handKeyBack$/{on=1} on{print} on&&/^}$/{exit}' "$f")
  deleg=$(awk '/^@implementation OmacVMHeadDelegate/{on=1} on{print} on&&/^@end/{exit}' "$f")
  down=$(awk '/^- \(void\)mouseDown:\(NSEvent \*\)e$/{on=1} on{print} on&&/^}$/{exit}' "$f")
  [[ -n $toggle ]] || echo "no doToggleFullScreen:"
  [[ -z $toggle ]] || {
    grep -q '\[w toggleFullScreen:sender\];' <<<"$toggle" || echo "the toggle does not use macOS's own full screen"
    [[ $(grep -c 'omacvm_toggle_notch_full_screen()' <<<"$toggle") -le 1 ]] || echo "the borderless kind is reached more than one way"
    if grep -q 'omacvm_toggle_notch_full_screen()' <<<"$toggle"; then
      grep -q '^    if (notchFull || omacvm_test_mode()) {$' <<<"$toggle" ||
        echo "the borderless kind (no Space of its own) is reachable outside test mode"
    fi
  }
  [[ $(grep -c 'omacvm_toggle_notch_full_screen()' "$f") -le 2 ]] ||
    echo "the borderless kind is called from somewhere else than the toggle"
  ! grep -q 'OMACVM_NOTCH' "$f" || echo "OMACVM_NOTCH is still read"
  [[ -n $safe ]] || echo "no screenSafeAreaSize"
  [[ -z $safe ]] || ! grep -q 'return size;' <<<"$(sed '$d' <<<"$safe" | sed '$d')" ||
    echo "screenSafeAreaSize returns before taking off the safe area"
  [[ -n $head ]] || echo "no handKeyBack in OmacVMHeadView"
  [[ -z $head ]] || grep -q '\[main isOnActiveSpace\]' <<<"$head" ||
    echo "an extra display's window gives the key to a main window on a Space not shown (the escape combo bounces back)"
  grep -q '\[self handKeyBack\];' <<<"$down" || echo "a click in an extra display's window does not hand the key back"
  ! grep -q 'windowDidBecomeKey:' <<<"$deleg" ||
    echo "an extra display's window hands the key back when it becomes key (timing-dependent: the escape combo can bounce back)"
}

if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fs-space.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  good() { cat <<'EOF'
- (NSSize) screenSafeAreaSize
{
    NSSize size = [[[self window] screen] frame].size;
    NSEdgeInsets insets = [[[self window] screen] safeAreaInsets];
    size.width -= insets.left + insets.right;
    size.height -= insets.top + insets.bottom;
    return size;
}
static void omacvm_toggle_notch_full_screen(void)
{
}
- (void) doToggleFullScreen:(id)sender
{
    NSWindow *w = [cocoaView window];
    if (notchFull || omacvm_test_mode()) {
        omacvm_toggle_notch_full_screen();
        return;
    }
    [w toggleFullScreen:sender];
}
@implementation OmacVMHeadView
- (void)handKeyBack
{
    NSWindow *main = [cocoaView window];
    if ([main isVisible] && [main isOnActiveSpace] && [NSApp isActive] && ![main isKeyWindow]) {
        [main makeKeyWindow];
    }
}
- (void)mouseDown:(NSEvent *)e
{
    [self handKeyBack];
    [self send:e button:INPUT_BUTTON_LEFT down:true];
}
@end
@implementation OmacVMHeadDelegate
- (BOOL)windowShouldClose:(id)sender
{
    return NO;
}
@end
EOF
  }
  case_() {   # WHAT WANT(ok|fail) FILE
    local p; p=$(problems "$3")
    if [[ $2 == ok && -z $p ]] || [[ $2 == fail && -n $p ]]; then echo "ok   $1${p:+ ($p)}"
    else echo "FAIL $1: want $2, got: ${p:-no problem}"; fail=1; fi
  }
  good > "$T/good.m"
  case_ "the fixed code" ok "$T/good.m"
  # 3.0.0 candidate: notch mode's borderless window on a shared Space.
  good | python3 -c '
import sys; s = sys.stdin.read()
s = s.replace("    if (notchFull || omacvm_test_mode()) {",
  "    if (notchFull || omacvm_test_mode() ||\n        (omacvm_notch_mode() && !([w styleMask] & NSWindowStyleMaskFullScreen) &&\n         [[w screen] safeAreaInsets].top > 0)) {")
s = "static bool omacvm_notch_mode(void) { return getenv(\"OMACVM_NOTCH\"); }\n" + s
print(s, end="")' > "$T/notch.m"
  case_ "notch mode's borderless full screen" fail "$T/notch.m"
  good | sed 's/    NSEdgeInsets insets/    if (omacvm_notch_mode()) {\n        return size;\n    }\n    NSEdgeInsets insets/' > "$T/size.m"
  case_ "guest sized over the strip" fail "$T/size.m"
  good | sed 's/ \[main isOnActiveSpace\] \&\&//' > "$T/bounce.m"
  case_ "key handed to a main window on another Space" fail "$T/bounce.m"
  good | sed 's/^    \[self handKeyBack\];$//' > "$T/noclick.m"
  case_ "a click keeps the key in the extra window" fail "$T/noclick.m"
  good | python3 -c '
import sys; s = sys.stdin.read()
s = s.replace("@implementation OmacVMHeadDelegate\n", "@implementation OmacVMHeadDelegate\n- (void)windowDidBecomeKey:(NSNotification *)note\n{\n    [[cocoaView window] makeKeyWindow];\n}\n")
print(s, end="")' > "$T/becomekey.m"
  case_ "key handed back when the extra window becomes key (3.0.0 candidate)" fail "$T/becomekey.m"
  good | sed 's/\[w toggleFullScreen:sender\];/omacvm_toggle_notch_full_screen();/' > "$T/never.m"
  case_ "no macOS full screen at all" fail "$T/never.m"
  exit $fail
fi

[[ -f ${1:-} ]] || { echo "usage: $0 <patched ui/cocoa.m> | --self-test" >&2; exit 2; }
p=$(problems "$1")
if [[ -n $p ]]; then printf 'FAIL %s\n' "$p"; exit 1; fi
echo "ok   full screen in its own Space; a display that left the VM stays left"
