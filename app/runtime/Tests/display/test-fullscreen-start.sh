#!/bin/bash
# A full-screen start shows nothing until it is there
# (omacvm-cocoa-fullscreen-start.patch), checked in the patched ui/cocoa.m:
#   - the main window is made transparent before it is first ordered in;
#   - it is shown again on windowDidEnterFullScreen: and on
#     windowDidFailToEnterFullScreen: (and by a timer as a safety net);
#   - the flag is set before the controller (and so the window) exists;
#   - the other displays' windows are transparent until macOS has each in
#     full screen (shown when it does, or when it gives up).
#   test-fullscreen-start.sh <patched ui/cocoa.m>   (the runtime build)
#   test-fullscreen-start.sh --self-test            (CI: the checks catch the old code)
set -uo pipefail

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }

problems() {
  local f=$1 hide enter fail headon headenter fullnext
  hide=$(body "$f" 'static void omacvm_start_hide(NSWindow *w)')
  enter=$(body "$f" '- (void)windowDidEnterFullScreen:')
  fail=$(body "$f" '- (void)windowDidFailToEnterFullScreen:')
  headon=$(body "$f" 'static void omacvm_head_on(')
  headenter=$(awk '/^@implementation OmacVMHeadDelegate/{on=1} on&&/^- \(void\)windowDidEnterFullScreen:/{w=1} w{print} w&&/^}$/{exit}' "$f")
  fullnext=$(awk '$0 == "static void omacvm_full_next(void)" {on=1} on {print} on && /^}$/ {exit}' "$f")
  [[ -n $hide ]] || { echo "no omacvm_start_hide"; return; }
  grep -q 'setAlphaValue:0.0' <<<"$headon" || echo "an extra display's window shows its windowed frame first"
  grep -q 'setAlphaValue:1.0' <<<"$headenter" || echo "an extra display's window stays invisible in full screen"
  grep -q 'setAlphaValue:1.0' <<<"$fullnext" || echo "an extra display's window stays invisible when macOS gives up"
  grep -q 'setAlphaValue:0.0' <<<"$hide" || echo "the start does not hide the window"
  grep -q 'dispatch_after' <<<"$hide" || echo "no safety net: a window that never gets to full screen stays invisible"
  awk '/omacvm_start_hide\(window\);/{h=NR} /makeKeyAndOrderFront:self\]/{o=NR} END{exit !(h && o && h < o)}' "$f" ||
    echo "the window is ordered in before it is hidden (the windowed frame flashes)"
  awk '/omacvm_start_full = opts->has_full_screen/{s=NR} /\[\[QemuCocoaAppController alloc\]/{c=NR} END{exit !(s && c && s < c)}' "$f" ||
    echo "the full-screen start is known only after the window exists"
  grep -q 'omacvm_start_reveal(' <<<"$enter" || echo "windowDidEnterFullScreen: does not show the window"
  grep -q 'omacvm_start_reveal(' <<<"$fail" || echo "windowDidFailToEnterFullScreen: leaves the window invisible"
}

if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fs-start.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  good() { cat <<'EOF'
static void omacvm_start_hide(NSWindow *w)
{
    [w setAlphaValue:0.0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ omacvm_start_reveal("timer"); });
}
        omacvm_start_hide(window);   /* before it is on screen */
            [window makeKeyAndOrderFront:self];
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
    omacvm_start_reveal("full screen refused");
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    omacvm_start_reveal("in full screen");
}
    omacvm_start_full = opts->has_full_screen && opts->full_screen &&
    controller = [[QemuCocoaAppController alloc] initWithCGL:1];
static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)
{
        [hd->window setAlphaValue:0.0];
        [hd->window orderFront:nil];
}
static void omacvm_full_next(void)
{
            [hd->window setAlphaValue:1.0];
}
@implementation OmacVMHeadDelegate
- (void)windowDidEnterFullScreen:(NSNotification *)note
{
        [[note object] setAlphaValue:1.0];
}
@end
EOF
  }
  case_() {
    local p; p=$(problems "$3")
    if [[ $2 == ok && -z $p ]] || [[ $2 == fail && -n $p ]]; then echo "ok   $1${p:+ ($p)}"
    else echo "FAIL $1: want $2, got: ${p:-no problem}"; fail=1; fi
  }
  good > "$T/good.m"; case_ "the fixed code" ok "$T/good.m"
  good | sed '/omacvm_start_hide(window);/d' > "$T/a.m"; case_ "never hidden (3.0.0 candidate)" fail "$T/a.m"
  good | sed '/omacvm_start_reveal("in full screen");/d' > "$T/b.m"; case_ "never shown again" fail "$T/b.m"
  good | sed '/omacvm_start_reveal("full screen refused");/d' > "$T/c.m"; case_ "invisible after a refused full screen" fail "$T/c.m"
  good | sed '/dispatch_after/,/omacvm_start_reveal("timer")/d' > "$T/d.m"; case_ "no safety net" fail "$T/d.m"
  good | sed '/        \[hd->window setAlphaValue:0.0\];/d' > "$T/e.m"; case_ "extra display shown windowed first" fail "$T/e.m"
  good | sed '/        \[\[note object\] setAlphaValue:1.0\];/d' > "$T/f.m"; case_ "extra display never shown" fail "$T/f.m"
  exit $fail
fi

[[ -f ${1:-} ]] || { echo "usage: $0 <patched ui/cocoa.m> | --self-test" >&2; exit 2; }
p=$(problems "$1")
if [[ -n $p ]]; then printf 'FAIL %s\n' "$p"; exit 1; fi
echo "ok   a full-screen start shows nothing until it is there"
