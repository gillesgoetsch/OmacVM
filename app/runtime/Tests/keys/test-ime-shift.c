/*
 * mac-ime: which modifier change the full-grab tap lets go on to macOS
 * (#357, omacvm-cocoa-ime-shift-logic.patch). A table of single events and
 * Shift sequences through ui/omacvm-ime-shift.h; real CGEvents (made here, no
 * permission needed) read the way the tap reads them; the copy that comes
 * back is dropped once. The rules before (nothing goes on) and #655's mask
 * (every modifier change goes on) must each fail the table.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <stdio.h>
#include <string.h>

#include "omacvm-ime-shift.h"

_Static_assert(OMACVM_IME_SHIFT_LEFT == kVK_Shift, "left Shift");
_Static_assert(OMACVM_IME_SHIFT_RIGHT == kVK_RightShift, "right Shift");
_Static_assert(OMACVM_IME_SHIFT_F_SHIFT == kCGEventFlagMaskShift, "Shift flag");
_Static_assert(OMACVM_IME_SHIFT_F_CONTROL == kCGEventFlagMaskControl, "Control flag");
_Static_assert(OMACVM_IME_SHIFT_F_OPTION == kCGEventFlagMaskAlternate, "Option flag");
_Static_assert(OMACVM_IME_SHIFT_F_COMMAND == kCGEventFlagMaskCommand, "Command flag");
_Static_assert(OMACVM_IME_SHIFT_F_FN == kCGEventFlagMaskSecondaryFn, "fn flag");
_Static_assert(OMACVM_IME_SHIFT_F_LEFT == NX_DEVICELSHIFTKEYMASK, "left Shift's device bit");
_Static_assert(OMACVM_IME_SHIFT_F_RIGHT == NX_DEVICERSHIFTKEYMASK, "right Shift's device bit");

#define SH  kCGEventFlagMaskShift
#define CT  kCGEventFlagMaskControl
#define OP  kCGEventFlagMaskAlternate
#define CM  kCGEventFlagMaskCommand
#define FN  kCGEventFlagMaskSecondaryFn
#define CAP kCGEventFlagMaskAlphaShift
#define NC  kCGEventFlagMaskNonCoalesced
#define LS  NX_DEVICELSHIFTKEYMASK
#define RS  NX_DEVICERSHIFTKEYMASK

/* mac-ime's state: which of its conditions holds. */
enum { ACTIVE, PLAIN, NO_FIELD, PASSWORD, NOT_KEY, NO_MODULE, WAITING, OFF, SWITCH_OFF };
static const char *state_names[] = { "active", "plain layout", "no text field", "password field",
                                     "window not key", "no module", "off delay", "mac-ime off",
                                     "OMACVM_IME_SHIFT=0" };

static void state(int st, OmacVMImeState *s, bool *waiting, bool *on)
{
    memset(s, 0, sizeof(*s));
    s->hello = s->focus = s->window_key = s->source_im = true;
    *waiting = false;
    *on = true;
    switch (st) {
    case PLAIN: s->source_im = false; break;
    case NO_FIELD: s->focus = false; break;
    case PASSWORD: s->password = true; break;
    case NOT_KEY: s->window_key = false; break;
    case NO_MODULE: s->hello = false; break;
    case WAITING: s->focus = false; *waiting = true; break;
    case OFF: case SWITCH_OFF: *on = false; break;
    }
}

typedef struct {
    int key;
    uint64_t flags;
    int st;
    bool pass;          /* goes on to macOS */
} Step;

typedef struct {
    const char *name;
    Step steps[6];
} Case;

#define END { -1, 0, 0, false }

static const Case cases[] = {
    /* A lone Shift tap (flags as in #655's capture: 0x20102, then 0x100). */
    { "left Shift tap, input method active", { { 56, SH | LS | NC, ACTIVE, true }, { 56, NC, ACTIVE, true }, END } },
    { "right Shift tap, input method active", { { 60, SH | RS | NC, ACTIVE, true }, { 60, NC, ACTIVE, true }, END } },
    { "Shift tap during the off delay", { { 56, SH | LS, WAITING, true }, { 56, 0, WAITING, true }, END } },
    { "Shift tap with Caps Lock on", { { 56, SH | LS | CAP, ACTIVE, true }, { 56, CAP, ACTIVE, true }, END } },
    { "both Shifts", { { 56, SH | LS, ACTIVE, true }, { 60, SH | LS | RS, ACTIVE, true },
                       { 56, SH | RS, ACTIVE, true }, { 60, 0, ACTIVE, true }, END } },
    { "no device bits (posted by an app)", { { 56, SH, ACTIVE, true }, { 56, 0, ACTIVE, true }, END } },
    /* Not while mac-ime gives no keys to an input method. */
    { "plain layout", { { 56, SH | LS, PLAIN, false }, { 56, 0, PLAIN, false }, END } },
    { "no text field", { { 56, SH | LS, NO_FIELD, false }, { 56, 0, NO_FIELD, false }, END } },
    { "password field", { { 56, SH | LS, PASSWORD, false }, { 56, 0, PASSWORD, false }, END } },
    { "window without the keyboard", { { 56, SH | LS, NOT_KEY, false }, { 56, 0, NOT_KEY, false }, END } },
    { "no Fcitx5 module", { { 56, SH | LS, NO_MODULE, false }, { 56, 0, NO_MODULE, false }, END } },
    { "mac-ime off", { { 56, SH | LS, OFF, false }, { 56, 0, OFF, false }, END } },
    { "OMACVM_IME_SHIFT=0", { { 60, SH | RS, SWITCH_OFF, false }, { 60, 0, SWITCH_OFF, false }, END } },
    /* Never another modifier, never Shift with one of them down. */
    { "left Command", { { 55, CM | 0x08, ACTIVE, false }, { 55, 0, ACTIVE, false }, END } },
    { "right Command", { { 54, CM | 0x10, ACTIVE, false }, { 54, 0, ACTIVE, false }, END } },
    { "Control (twice)", { { 59, CT | 0x01, ACTIVE, false }, { 59, 0, ACTIVE, false },
                           { 59, CT | 0x01, ACTIVE, false }, { 59, 0, ACTIVE, false }, END } },
    { "right Control", { { 62, CT | 0x2000, ACTIVE, false }, { 62, 0, ACTIVE, false }, END } },
    { "Option", { { 58, OP | 0x20, ACTIVE, false }, { 58, 0, ACTIVE, false }, END } },
    { "right Option", { { 61, OP | 0x40, ACTIVE, false }, { 61, 0, ACTIVE, false }, END } },
    { "Caps Lock", { { 57, CAP, ACTIVE, false }, { 57, 0, ACTIVE, false }, END } },
    { "fn / globe", { { 63, FN, ACTIVE, false }, { 63, 0, ACTIVE, false }, END } },
    { "Shift with Command down (Super+Shift chords)",
      { { 55, CM | 0x08, ACTIVE, false }, { 56, CM | 0x08 | SH | LS, ACTIVE, false },
        { 56, CM | 0x08, ACTIVE, false }, { 55, 0, ACTIVE, false }, END } },
    { "Shift with Control down", { { 56, CT | SH | LS, ACTIVE, false }, { 56, CT, ACTIVE, false }, END } },
    { "Shift with Option down", { { 60, OP | SH | RS, ACTIVE, false }, { 60, OP, ACTIVE, false }, END } },
    { "Shift with fn down", { { 56, FN | SH | LS, ACTIVE, false }, { 56, FN, ACTIVE, false }, END } },
    /* A release goes on when its press did, whatever came between. */
    { "Command pressed after Shift: the release still goes on",
      { { 56, SH | LS, ACTIVE, true }, { 55, SH | LS | CM | 0x08, ACTIVE, false },
        { 56, CM | 0x08, ACTIVE, true }, { 55, 0, ACTIVE, false }, END } },
    { "focus gone while Shift is down: the release still goes on",
      { { 56, SH | LS, ACTIVE, true }, { 56, 0, NO_FIELD, true }, END } },
    { "focus there only for the release: it stays",
      { { 56, SH | LS, NO_FIELD, false }, { 56, 0, ACTIVE, false }, END } },
    { "a release with no press", { { 60, 0, ACTIVE, false }, END } },
    { "next tap after a kept one", { { 56, SH | LS, PLAIN, false }, { 56, 0, PLAIN, false },
                                     { 56, SH | LS, ACTIVE, true }, { 56, 0, ACTIVE, true }, END } },
};

enum { RULES_NEW, RULES_BEFORE, RULES_MASK };   /* this patch, main before it, #655's mask */

static bool step_pass(int rules, OmacVMImeShift *sh, const Step *st)
{
    OmacVMImeState s;
    bool waiting, on;

    state(st->st, &s, &waiting, &on);
    if (rules == RULES_BEFORE) {
        return false;
    }
    if (rules == RULES_MASK) {
        return true;
    }
    return omacvm_ime_shift_pass(sh, st->key, st->flags, on, &s, waiting);
}

/* Returns how many steps differ from the table. */
static int run(int rules, bool print)
{
    int bad = 0;

    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        OmacVMImeShift sh;
        int n = 0, case_bad = 0;

        memset(&sh, 0, sizeof(sh));
        for (const Step *st = cases[c].steps; st->key >= 0; st++, n++) {
            bool got = step_pass(rules, &sh, st);
            if (got != st->pass) {
                case_bad++;
                if (print) {
                    printf("FAIL %s: step %d (key %d flags 0x%llx, %s): %s, want %s\n", cases[c].name, n + 1,
                           st->key, (unsigned long long)st->flags, state_names[st->st],
                           got ? "goes on" : "kept", st->pass ? "goes on" : "kept");
                }
            }
        }
        bad += case_bad;
        if (print && !case_bad) {
            printf("ok   %s\n", cases[c].name);
        }
    }
    return bad;
}

static int fails;

static void check(bool ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

/* A flagsChanged event as macOS gives it to the tap. */
static CGEventRef flags_event(CGKeyCode key, CGEventFlags flags)
{
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, key, true);
    if (!e) {
        return NULL;
    }
    CGEventSetType(e, kCGEventFlagsChanged);
    CGEventSetFlags(e, flags);
    return e;
}

/* As ui/cocoa.m's omacvm_ime_shift_to_macos reads it. */
static bool tap_pass(OmacVMImeShift *sh, CGEventRef e, bool on, int st)
{
    OmacVMImeState s;
    bool waiting, on_state;
    int key = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);

    state(st, &s, &waiting, &on_state);
    if (CGEventGetType(e) != kCGEventFlagsChanged ||
        !omacvm_ime_shift_pass(sh, key, CGEventGetFlags(e), on && on_state, &s, waiting)) {
        return false;
    }
    omacvm_ime_shift_sent(sh, CGEventGetTimestamp(e), key);
    return true;
}

static void real_events(void)
{
    OmacVMImeShift sh;
    CGEventRef down = flags_event(kVK_Shift, SH | LS | NC), up = flags_event(kVK_Shift, NC);
    CGEventRef cmd = flags_event(kVK_Command, CM | 0x08 | NC);

    memset(&sh, 0, sizeof(sh));
    if (!down || !up || !cmd) {
        check(false, "real CGEvents: made");
        return;
    }
    CGEventSetTimestamp(up, CGEventGetTimestamp(down) + 80000000);   /* 80 ms later */
    check(tap_pass(&sh, down, true, ACTIVE), "real CGEvent: Shift press goes on");
    check(tap_pass(&sh, up, true, ACTIVE), "real CGEvent: ... and its release");
    check(!tap_pass(&sh, cmd, true, ACTIVE), "real CGEvent: Command does not");

    /* The copies come back through the app's queue: each dropped once. */
    CGEventRef down2 = CGEventCreateCopy(down), up2 = CGEventCreateCopy(up);
    check(down2 && omacvm_ime_shift_again(&sh, CGEventGetTimestamp(down2), kVK_Shift),
          "the press's copy is told (time stamp and key code) and dropped");
    check(up2 && omacvm_ime_shift_again(&sh, CGEventGetTimestamp(up2), kVK_Shift), "... the release's too");
    check(!omacvm_ime_shift_again(&sh, CGEventGetTimestamp(down), kVK_Shift), "... only once");
    check(!omacvm_ime_shift_again(&sh, CGEventGetTimestamp(cmd), kVK_Command),
          "an event that was kept is not dropped when it comes");
    if (down2) {
        CFRelease(down2);
    }
    if (up2) {
        CFRelease(up2);
    }
    CFRelease(down);
    CFRelease(up);
    CFRelease(cmd);
}

static void copies(void)
{
    OmacVMImeShift sh;
    bool all = true;

    memset(&sh, 0, sizeof(sh));
    omacvm_ime_shift_sent(&sh, 1000, 56);
    check(!omacvm_ime_shift_again(&sh, 1000, 60), "another key with the same time stamp: not dropped");
    check(!omacvm_ime_shift_again(&sh, 1001, 56), "the same key at another time: not dropped");
    check(omacvm_ime_shift_again(&sh, 1000, 56), "the copy: dropped");
    /* Up to OMACVM_IME_SHIFT_SENT copies may be on their way at once, in any order. */
    for (uint64_t t = 1; t <= OMACVM_IME_SHIFT_SENT; t++) {
        omacvm_ime_shift_sent(&sh, 2000 + t, 56 + (int)(t & 1) * 4);
    }
    for (uint64_t t = OMACVM_IME_SHIFT_SENT; t >= 1; t--) {
        all = all && omacvm_ime_shift_again(&sh, 2000 + t, 56 + (int)(t & 1) * 4);
    }
    check(all, "8 copies on their way: each dropped, in any order");
    /* A copy that never came is forgotten after 8 more. */
    omacvm_ime_shift_sent(&sh, 3000, 56);
    for (uint64_t t = 1; t <= OMACVM_IME_SHIFT_SENT; t++) {
        omacvm_ime_shift_sent(&sh, 4000 + t, 60);
    }
    check(!omacvm_ime_shift_again(&sh, 3000, 56), "a copy that never came is forgotten after 8 more");
}

int main(void)
{
    fails += run(RULES_NEW, true) != 0;
    int before = run(RULES_BEFORE, false), mask = run(RULES_MASK, false);
    check(before > 0, "the rules before (nothing goes on) fail the table");
    check(mask > 0, "#655's mask (every modifier change goes on) fails the table");
    printf("     (before: %d steps differ; mask: %d)\n", before, mask);
    real_events();
    copies();
    if (fails) {
        printf("test-ime-shift: %d FAIL\n", fails);
        return 1;
    }
    printf("test-ime-shift: all ok\n");
    return 0;
}
