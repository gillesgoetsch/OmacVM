#!/bin/bash
# No quit by itself; a quit while the guest starts presses the power button
# again (omacvm-cocoa-quit-clean.patch), checked in the patched ui/cocoa.m:
#   - AppKit's last window going does not quit (a hidden full-screen run
#     quit when AppKit closed its full-screen mouse detection window); the
#     VM window's close button, or the VM window closing any other way, does;
#   - a quit presses the power button (a paused VM resumed first). While the
#     guest still starts (since its start or reset) it presses again every
#     few seconds (a press before logind listens is lost) and waits longer;
#     a guest that is up gets one press (Omarchy's power menu opens on the
#     key). The stop comes after the last press, with a line in qemu.log.
#   test-quit-clean.sh <patched ui/cocoa.m>   (the runtime build)
#   test-quit-clean.sh --self-test            (CI: the checks catch the old code)
set -uo pipefail

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
define() { sed -n "s/^#define $2 \\([0-9][0-9]*\\)\$/\\1/p" "$1" | head -1; }

problems() {
  local f=$1 last close willclose term press reset wait bwait boot every until
  last=$(body "$f" '- (BOOL)applicationShouldTerminateAfterLastWindowClosed:')
  # The app controller's (the VM window's), not the other displays' delegate.
  close=$(body "$f" "/* Called when the user clicks on a window's close button */")
  willclose=$(body "$f" '- (void)windowWillClose:(NSNotification *)notification')
  term=$(body "$f" '- (NSApplicationTerminateReply)applicationShouldTerminate:')
  press=$(body "$f" 'static void omacvm_quit_press(int after, int wait, bool booting)')
  reset=$(body "$f" 'static void omacvm_quit_guest_reset(void *opaque)')
  [[ -n $last && -n $close && -n $term ]] || { echo "the quit methods not found"; return; }
  { grep -q 'return NO;' <<<"$last" && ! grep -q 'return YES;' <<<"$last"; } ||
    echo "AppKit's last window going quits the VM"
  grep -q '\[NSApp terminate: *sender\]' <<<"$close" || echo "the close button no longer quits"
  { grep -q '\[notification object\] == \[cocoaView window\]' <<<"$willclose" &&
    grep -q '\[NSApp terminate:' <<<"$willclose"; } || echo "the VM window closing some other way does not quit"
  [[ -n $press ]] || { echo "no omacvm_quit_press"; return; }
  grep -q 'with_bql(' <<<"$press" || echo "the power button is pressed without the BQL"
  awk '/runstate_check\(RUN_STATE_PAUSED\)/{p=NR} /qmp_cont\(NULL\);/{c=NR} /runstate_is_running\(\)/{r=NR}
       /qemu_system_powerdown_request\(\);/{q=NR} END{exit !(p && c && r && q && p < c && c < r && r < q)}' <<<"$press" ||
    echo "the power button is pressed without resuming a paused guest and checking that it runs"
  grep -q 'fprintf(stderr, "omacvm: quit:' <<<"$press" || echo "the presses are not logged"
  grep -q 'omacvm_quit_boot_ms = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);' <<<"$reset" ||
    echo "the guest's start is not taken from its resets"
  grep -q 'qemu_register_reset(omacvm_quit_guest_reset, NULL);' "$f" || echo "the reset handler is not registered"
  grep -q 'qemu_clock_get_ms(QEMU_CLOCK_REALTIME) - omacvm_quit_boot_ms <' <<<"$term" &&
    grep -q 'OMACVM_QUIT_BOOT_S \* 1000' <<<"$term" || echo "a quit does not tell a starting guest apart"
  grep -q 'omacvm_quit_press(0, wait, booting);' <<<"$term" || echo "a quit does not press the power button"
  grep -q 'for (int t = OMACVM_QUIT_PRESS_EVERY_S; booting && t <= OMACVM_QUIT_PRESS_UNTIL_S;' <<<"$term" &&
    grep -q 'omacvm_quit_press(t, wait, booting);' <<<"$term" ||
    echo "a quit while the guest starts presses the power button only once (or a booted guest more than once)"
  grep -q 'int wait = booting ? OMACVM_QUIT_BOOT_WAIT_S : OMACVM_QUIT_WAIT_S;' <<<"$term" ||
    echo "the wait does not depend on the guest's start"
  grep -q 'replyToApplicationShouldTerminate:YES' <<<"$term" || echo "a hung guest is never stopped"
  grep -q 'stopping it' <<<"$term" || echo "the stop is not logged"
  wait=$(define "$f" OMACVM_QUIT_WAIT_S); bwait=$(define "$f" OMACVM_QUIT_BOOT_WAIT_S)
  boot=$(define "$f" OMACVM_QUIT_BOOT_S); every=$(define "$f" OMACVM_QUIT_PRESS_EVERY_S)
  until=$(define "$f" OMACVM_QUIT_PRESS_UNTIL_S)
  if [[ -z $wait || -z $bwait || -z $boot || -z $every || -z $until ]]; then
    echo "the quit times are not defined"
  elif ! (( every > 0 && every <= until && until + 20 <= bwait && wait <= bwait && boot > 0 )); then
    echo "the last press leaves the guest under 20 s before the stop ($every/$until/$bwait s)"
  fi
}

if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-quit.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  fail=0
  good() { cat <<'EOF'
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    return NO;
}
#define OMACVM_QUIT_WAIT_S 60
#define OMACVM_QUIT_BOOT_S 120
#define OMACVM_QUIT_BOOT_WAIT_S 70
#define OMACVM_QUIT_PRESS_EVERY_S 10
#define OMACVM_QUIT_PRESS_UNTIL_S 40
static bool powerdownPending;
static int64_t omacvm_quit_boot_ms;

static void omacvm_quit_guest_reset(void *opaque)
{
    omacvm_quit_boot_ms = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
}

static void omacvm_quit_press(int after, int wait, bool booting)
{
    with_bql(^{   /* skipped once the display is cleaned up (QEMU exits) */
        if (runstate_check(RUN_STATE_PAUSED)) {
            qmp_cont(NULL);
        }
        if (!runstate_is_running()) {
            return;
        }
        qemu_system_powerdown_request();
        fprintf(stderr, "omacvm: quit: power button pressed\n");
    });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
                                                         (NSApplication *)sender
{
    if (!powerdownPending) {
        powerdownPending = true;
        __block bool booting = false;
        with_bql(^{
            booting = qemu_clock_get_ms(QEMU_CLOCK_REALTIME) - omacvm_quit_boot_ms <
                      OMACVM_QUIT_BOOT_S * 1000;
        });
        int wait = booting ? OMACVM_QUIT_BOOT_WAIT_S : OMACVM_QUIT_WAIT_S;
        omacvm_quit_press(0, wait, booting);
        for (int t = OMACVM_QUIT_PRESS_EVERY_S; booting && t <= OMACVM_QUIT_PRESS_UNTIL_S;
             t += OMACVM_QUIT_PRESS_EVERY_S) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, t * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                omacvm_quit_press(t, wait, booting);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "omacvm: quit: guest still on after %d s, stopping it\n", wait);
            [NSApp replyToApplicationShouldTerminate:YES];
        });
    }
    return NSTerminateLater;
}

- (void)windowWillClose:(NSNotification *)notification
{
    if ([notification object] == [cocoaView window] && !powerdownPending) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:self];
        });
    }
}

/* Called when the user clicks on a window's close button */
- (BOOL)windowShouldClose:(id)sender
{
    [NSApp terminate: sender];
    return NO;
}

    omacvm_quit_boot_ms = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
    qemu_register_reset(omacvm_quit_guest_reset, NULL);

- (BOOL)windowShouldClose:(id)sender
{
    return NO;
}
EOF
  }
  # 3.0.1's code: one press, quit when AppKit's last window goes.
  old() { cat <<'EOF'
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    return YES;
}
static bool powerdownPending;

- (NSApplicationTerminateReply)applicationShouldTerminate:
                                                         (NSApplication *)sender
{
    if (!powerdownPending) {
        powerdownPending = true;
        with_bql(^{
            qemu_system_powerdown_request();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [NSApp replyToApplicationShouldTerminate:YES];
        });
    }
    return NSTerminateLater;
}

/* Called when the user clicks on a window's close button */
- (BOOL)windowShouldClose:(id)sender
{
    [NSApp terminate: sender];
    return NO;
}
EOF
  }
  case_() {
    local p; p=$(problems "$3")
    if [[ $2 == ok && -z $p ]] || [[ $2 == fail && -n $p ]]; then echo "ok   $1${p:+ ($(tr '\n' ';' <<<"$p"))}"
    else echo "FAIL $1: want $2, got: ${p:-no problem}"; fail=1; fi
  }
  good > "$T/good.m"; case_ "the fixed code" ok "$T/good.m"
  old > "$T/old.m"; case_ "3.0.1's code" fail "$T/old.m"
  good | sed '/applicationShouldTerminateAfterLastWindowClosed/,/^}$/s/return NO;/return YES;/' > "$T/a.m"
  case_ "quits when the last window goes" fail "$T/a.m"
  good | sed '/close button \*\//,/^}$/s/\[NSApp terminate: sender\];//' > "$T/b.m"; case_ "close button does not quit" fail "$T/b.m"
  good | sed '/windowWillClose/,/^}$/s/\[NSApp terminate:self\];//' > "$T/b2.m"; case_ "VM window closed: no quit" fail "$T/b2.m"
  good | sed '/omacvm_quit_press(t, wait, booting);/d' > "$T/c.m"; case_ "one press only" fail "$T/c.m"
  good | sed 's/; booting && t <=/; t <=/' > "$T/c2.m"; case_ "a booted guest pressed again (power menu)" fail "$T/c2.m"
  good | sed '/if (!runstate_is_running()) {/,/^        }$/d' > "$T/d.m"; case_ "presses a stopped guest" fail "$T/d.m"
  good | sed '/if (runstate_check(RUN_STATE_PAUSED)) {/,/^        }$/d' > "$T/d2.m"; case_ "a paused guest is not resumed" fail "$T/d2.m"
  good | sed 's/replyToApplicationShouldTerminate:YES/replyToApplicationShouldTerminate:NO/' > "$T/e.m"
  case_ "never stops a hung guest" fail "$T/e.m"
  good | sed 's/OMACVM_QUIT_PRESS_UNTIL_S 40/OMACVM_QUIT_PRESS_UNTIL_S 60/' > "$T/f.m"; case_ "last press too close to the stop" fail "$T/f.m"
  good | sed 's/int wait = booting ? OMACVM_QUIT_BOOT_WAIT_S : OMACVM_QUIT_WAIT_S;/int wait = OMACVM_QUIT_WAIT_S;/' > "$T/f2.m"
  case_ "no longer wait while the guest starts" fail "$T/f2.m"
  good | sed '/fprintf(stderr, "omacvm: quit: power button/d' > "$T/g.m"; case_ "presses not logged" fail "$T/g.m"
  good | sed 's/    with_bql(^{   \/\* skipped.*/    ({/' > "$T/h.m"; case_ "press without the BQL" fail "$T/h.m"
  good | sed '/    qemu_register_reset(omacvm_quit_guest_reset, NULL);/d' > "$T/i.m"; case_ "a guest reboot is not a start" fail "$T/i.m"
  exit $fail
fi

[[ -f ${1:-} ]] || { echo "usage: $0 <patched ui/cocoa.m> | --self-test" >&2; exit 2; }
p=$(problems "$1")
if [[ -n $p ]]; then printf 'FAIL %s\n' "$p"; exit 1; fi
echo "ok   no quit by itself; a quit while the guest starts presses the power button until it is off"
