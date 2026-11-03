/*
 * mac-ime: the copy of a Shift that an active HID tap lets go on, as macOS
 * really gives it back to the app (#357, ui/omacvm-ime-shift.h). Local only,
 * not in CI (no Accessibility there): ime-shift-copy.sh builds and runs it.
 *
 * An active kCGHIDEventTap with the full-grab tap's mask returns each Shift
 * flagsChanged this test posts at the HID level (marked in
 * kCGEventSourceUserData) and records it as ui/cocoa.m does
 * (omacvm_ime_shift_sent, its own clock). The app, in front with a small
 * window, reads what comes back in its own queue (a local monitor): CGEvent
 * nil or not, time stamp, flags, and runs omacvm_ime_shift_copy on it.
 * Exit 0: every copy came back and was told, once each; 1: not; 2: skipped
 * (no tap, screen locked, not in front), with the reason.
 *
 * Posted events are not a real keyboard: on a Mac mini M4, macOS 27.0
 * (2026-11-02) all 12 copies came back 0.3-4.1 ms later with a CGEvent and
 * the tap's own time stamp, where @Vocllum's real keypresses in #655 came
 * back with another time stamp or none (0 of 22 told by it). So this checks
 * the matcher on what macOS gives back; the difference itself needs a person
 * at a real keyboard (OMACVM_IME_DEBUG=1's "back from macOS, dropped" lines).
 */
#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <stdio.h>
#include <time.h>

#include "omacvm-ime-shift.h"

#define MARK 0x6f6d6163ll           /* "omac" in kCGEventSourceUserData */
#define TAPS 6                      /* lone Shift taps (left, right alternating) */

static OmacVMImeShift sh;
static int seen_tap, back_total, back_told, back_nil, back_same_ts, back_twice;
static uint64_t tap_ts[2 * TAPS];
static int tap_n;
static double lat_max_ms;

static uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static CGEventRef tap_cb(CGEventTapProxy proxy __attribute__((unused)), CGEventType type, CGEventRef e, void *info)
{
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(*(CFMachPortRef *)info, true);
        return e;
    }
    if (type != kCGEventFlagsChanged || CGEventGetIntegerValueField(e, kCGEventSourceUserData) != MARK) {
        return e;                   /* not ours: as it came */
    }
    int key = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    seen_tap++;
    if (tap_n < 2 * TAPS) {
        tap_ts[tap_n++] = CGEventGetTimestamp(e);
    }
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), key, CGEventGetFlags(e), now_ns(), true);
    return e;                       /* goes on to macOS, as a passed Shift */
}

static void post(CGEventSourceRef src, CGKeyCode key, CGEventFlags flags)
{
    CGEventRef e = CGEventCreateKeyboardEvent(src, key, true);
    CGEventSetType(e, kCGEventFlagsChanged);
    CGEventSetFlags(e, flags);
    CGEventSetIntegerValueField(e, kCGEventSourceUserData, MARK);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(void)
{
    @autoreleasepool {
        CFDictionaryRef d = CGSessionCopyCurrentDictionary();
        bool locked = d && CFDictionaryGetValue(d, CFSTR("CGSSessionScreenIsLocked")) == kCFBooleanTrue;
        if (d) {
            CFRelease(d);
        }
        if (locked) {
            printf("SKIP the screen is locked: the copy is not delivered to a locked session\n");
            return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        static CFMachPortRef port;
        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                           CGEventMaskBit(kCGEventFlagsChanged);
        port = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask,
                                tap_cb, &port);
        if (!port) {
            printf("SKIP no active HID tap (Accessibility for this shell's app)\n");
            return 2;
        }
        CFRunLoopSourceRef rls = CFMachPortCreateRunLoopSource(NULL, port, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, kCFRunLoopCommonModes);

        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *ev) {
            int key = (int)[ev keyCode];
            if (key != kVK_Shift && key != kVK_RightShift) {
                return ev;
            }
            CGEventRef cg = [ev CGEvent];
            uint64_t t = now_ns();
            back_total++;
            if (!cg) {
                back_nil++;
            } else {
                for (int i = 0; i < tap_n; i++) {
                    back_same_ts += CGEventGetTimestamp(cg) == tap_ts[i];
                }
            }
            int i = omacvm_ime_shift_copy(&sh, key, (uint64_t)[ev modifierFlags], t);
            if (i >= 0) {
                double ms = (t - sh.sent[i].at) / 1e6;
                back_told++;
                lat_max_ms = ms > lat_max_ms ? ms : lat_max_ms;
                printf("back: key %d flags 0x%llx CGEvent %s time stamp %llu: told (%.1f ms)\n", key,
                       (unsigned long long)[ev modifierFlags], cg ? "yes" : "nil",
                       cg ? (unsigned long long)CGEventGetTimestamp(cg) : 0ull, ms);
            } else {
                back_twice++;
                printf("back: key %d flags 0x%llx: NOT told\n", key, (unsigned long long)[ev modifierFlags]);
            }
            return nil;             /* used up here, as handleEvent does */
        }];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, 240, 60)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:NO];
        [w setTitle:@"ime-shift-copy (a test, 4 s)"];
        [w makeKeyAndOrderFront:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [NSApp activateIgnoringOtherApps:YES];   /* macOS 26+ refuses the new activate() without a click */
#pragma clang diagnostic pop
        });
        __block CGEventSourceRef src = NULL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (![NSApp isActive]) {
                printf("SKIP this app did not come to the front (the copy goes to the active app)\n");
                exit(2);
            }
            src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        });
        for (int k = 0; k < TAPS; k++) {
            bool right = k & 1;
            CGKeyCode key = right ? kVK_RightShift : kVK_Shift;
            uint64_t bit = right ? NX_DEVICERSHIFTKEYMASK : NX_DEVICELSHIFTKEYMASK;
            int64_t at = 1600 + k * 370;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, at * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                post(src, key, kCGEventFlagMaskShift | bit | NX_NONCOALSESCEDMASK);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (at + 120) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                post(src, key, NX_NONCOALSESCEDMASK);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (1600 + TAPS * 370 + 500) * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            CGEventTapEnable(port, false);
            [w orderOut:nil];
            printf("posted %d, in the tap %d, back in the app's queue %d: told %d, not told %d; "
                   "CGEvent nil %d; time stamp equal to the tap's %d; latest %.1f ms\n",
                   2 * TAPS, seen_tap, back_total, back_told, back_twice, back_nil, back_same_ts, lat_max_ms);
            bool ok = seen_tap == 2 * TAPS && back_total == 2 * TAPS && back_told == 2 * TAPS && back_twice == 0;
            printf("%s\n", ok ? "ime-shift-copy: all ok" : "ime-shift-copy: FAIL");
            fflush(stdout);
            exit(ok ? 0 : 1);
        });
        [NSApp run];
        return 1;
    }
}
