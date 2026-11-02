/*
 * mac-ime: which modifier change the full-grab tap lets go on to macOS
 * (#357, omacvm-cocoa-ime-shift-logic.patch). A table of single events and
 * Shift sequences through ui/omacvm-ime-shift.h; real CGEvents (made here, no
 * permission needed) read the way the tap reads them; copies that come back
 * with another time stamp or with no CGEvent are told by key code and
 * direction within 300 ms, once each; the orders in which the VM and the
 * input method get a passed Shift and the keys around it. The rules before
 * (nothing goes on) and #655's mask (every modifier change goes on) must
 * each fail the table.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <stdio.h>
#include <stdlib.h>
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

#define MS 1000000ull   /* ns */

/* As ui/cocoa.m reads it in the tap (before handleEvent), and remembers it after. */
static bool tap_pass(OmacVMImeShift *sh, CGEventRef e, bool on, int st, uint64_t now)
{
    OmacVMImeState s;
    bool waiting, on_state;
    int key = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);

    state(st, &s, &waiting, &on_state);
    if (CGEventGetType(e) != kCGEventFlagsChanged ||
        !omacvm_ime_shift_pass(sh, key, CGEventGetFlags(e), on && on_state, &s, waiting)) {
        return false;
    }
    omacvm_ime_shift_sent(sh, omacvm_ime_shift_slot(sh), key, CGEventGetFlags(e), now, true);
    return true;
}

/* As ui/cocoa.m reads a copy from the app's queue: [event keyCode], [event modifierFlags]. */
static int back(OmacVMImeShift *sh, CGEventRef e, uint64_t now)
{
    return omacvm_ime_shift_copy(sh, (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode),
                                 CGEventGetFlags(e), now);
}

/*
 * Who gets what, as ui/cocoa.m does it: the VM gets every tap event once
 * (a passed Shift in the tap, never its copy); the input context gets a
 * passed Shift from its copy, or before the next key, in order.
 */
typedef struct {
    char vm[64], im[64];    /* 'd'/'u' Shift press/release, 'a' another key */
    int nvm, nim;
    OmacVMImeShift sh;
} World;

static void w_flush(World *w, uint64_t now, uint64_t before, bool expired_only)
{
    int i;

    while ((i = omacvm_ime_shift_due(&w->sh, now, before, expired_only)) >= 0) {
        w->sh.sent[i].due = false;
        if (!omacvm_ime_shift_stale(&w->sh, i, now)) {
            w->im[w->nim++] = w->sh.sent[i].down ? 'd' : 'u';
        }
    }
}

/* An event in the tap: a Shift (down/up) that goes on, or another key. */
static void w_tap(World *w, char what, uint64_t now)
{
    OmacVMImeState s;
    bool waiting, on;

    state(ACTIVE, &s, &waiting, &on);
    if (what == 'a') {
        w_flush(w, now, UINT64_MAX, false);
        w->vm[w->nvm++] = 'a';
        w->im[w->nim++] = 'a';
        return;
    }
    uint64_t flags = what == 'd' ? SH | LS : 0;
    bool pass = omacvm_ime_shift_pass(&w->sh, 56, flags, true, &s, waiting);
    w_flush(w, now, UINT64_MAX, true);
    w->vm[w->nvm++] = what;
    if (pass) {
        omacvm_ime_shift_sent(&w->sh, omacvm_ime_shift_slot(&w->sh), 56, flags, now, true);
    } else {
        w->im[w->nim++] = what;
    }
}

/* A copy back from macOS in the app's queue. */
static void w_back(World *w, char what, uint64_t now)
{
    int i = omacvm_ime_shift_copy(&w->sh, 56, what == 'd' ? SH | LS : 0, now);

    if (i < 0) {                     /* not a copy: QEMU's path, VM and input context */
        w_flush(w, now, UINT64_MAX, false);
        w->vm[w->nvm++] = what;
        w->im[w->nim++] = what;
        return;
    }
    if (w->sh.sent[i].due) {
        w_flush(w, now, w->sh.sent[i].seq, false);
        w->sh.sent[i].due = false;
        w->im[w->nim++] = what;
    }
}

static void world(const char *name, const char *script, const char *want_vm, const char *want_im)
{
    World w;
    char buf[160];
    uint64_t t = 1000 * MS;

    memset(&w, 0, sizeof(w));
    /* script: T<ms> advance, then tap d/u/a, or b<d|u> a copy back */
    for (const char *p = script; *p; p++) {
        if (*p == 'T') {
            t += (uint64_t)strtoul(p + 1, (char **)&p, 10) * MS;
            p--;
        } else if (*p == 'b') {
            w_back(&w, *++p, t);
        } else if (*p != ' ') {
            w_tap(&w, *p, t);
        }
    }
    snprintf(buf, sizeof(buf), "%s: the VM gets %s, the input method %s", name, want_vm, want_im);
    check(!strcmp(w.vm, want_vm) && !strcmp(w.im, want_im), buf);
    if (strcmp(w.vm, want_vm) || strcmp(w.im, want_im)) {
        printf("     got: the VM %s, the input method %s\n", w.vm, w.im);
    }
}

static void real_events(void)
{
    OmacVMImeShift sh;
    CGEventRef down = flags_event(kVK_Shift, SH | LS | NC), up = flags_event(kVK_Shift, NC);
    CGEventRef cmd = flags_event(kVK_Command, CM | 0x08 | NC);
    uint64_t t = 5000 * MS;

    memset(&sh, 0, sizeof(sh));
    if (!down || !up || !cmd) {
        check(false, "real CGEvents: made");
        return;
    }
    CGEventSetTimestamp(up, CGEventGetTimestamp(down) + 80000000);   /* 80 ms later */
    check(tap_pass(&sh, down, true, ACTIVE, t), "real CGEvent: Shift press goes on");
    check(tap_pass(&sh, up, true, ACTIVE, t + 80 * MS), "real CGEvent: ... and its release");
    check(!tap_pass(&sh, cmd, true, ACTIVE, t + 90 * MS), "real CGEvent: Command does not");

    /* The copies come back with another time stamp (as on a real Mac): told by key and direction. */
    CGEventRef down2 = CGEventCreateCopy(down), up2 = CGEventCreateCopy(up);
    if (!down2 || !up2) {
        check(false, "real CGEvents: copied");
        return;
    }
    CGEventSetTimestamp(down2, CGEventGetTimestamp(down) + 7000000);
    CGEventSetTimestamp(up2, CGEventGetTimestamp(up) + 12000000);
    check(back(&sh, down2, t + 7 * MS) >= 0, "the press's copy with another time stamp is told and dropped");
    check(back(&sh, up2, t + 92 * MS) >= 0, "... the release's too");
    check(back(&sh, down2, t + 93 * MS) < 0, "... only once");
    check(back(&sh, cmd, t + 94 * MS) < 0, "an event that was kept is not taken for a copy");
    CFRelease(down2);
    CFRelease(up2);
    CFRelease(down);
    CFRelease(up);
    CFRelease(cmd);
}

static void copies(void)
{
    OmacVMImeShift sh;
    uint64_t t = 1000 * MS;
    bool all = true;

    memset(&sh, 0, sizeof(sh));
    /* A copy with no CGEvent: only the key code and the NSEvent's flags. */
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t, true);
    check(omacvm_ime_shift_copy(&sh, 56, SH | LS | 0x100, t + 3 * MS) >= 0,
          "a copy with no CGEvent (key code and flags only) is told");
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t, true);
    check(omacvm_ime_shift_copy(&sh, 56, 0x100, t + 3 * MS) < 0, "the other direction is not its copy");
    check(omacvm_ime_shift_copy(&sh, 60, SH | RS, t + 3 * MS) < 0, "the other Shift is not its copy");
    check(omacvm_ime_shift_copy(&sh, 55, SH | LS, t + 3 * MS) < 0, "another key is not its copy");
    check(omacvm_ime_shift_copy(&sh, 56, SH | LS, t + 301 * MS) < 0, "after 300 ms: not its copy any more");
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t, true);
    check(omacvm_ime_shift_copy(&sh, 56, SH | LS, t + 300 * MS) >= 0, "at 300 ms: still its copy");
    /* Right Shift released while the left is held: flags still have Shift and the left bit. */
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 60, SH | LS, t, true);
    check(omacvm_ime_shift_copy(&sh, 60, SH | LS, t + 2 * MS) >= 0,
          "right Shift's release with the left still down is told as a release");
    /* One drop per event sent. */
    memset(&sh, 0, sizeof(sh));
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t, true);
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t + 1 * MS, true);
    int a = omacvm_ime_shift_copy(&sh, 56, SH | LS, t + 4 * MS), b = omacvm_ime_shift_copy(&sh, 56, SH | LS, t + 5 * MS);
    check(a >= 0 && b >= 0 && a != b && sh.sent[a].seq < sh.sent[b].seq &&
          omacvm_ime_shift_copy(&sh, 56, SH | LS, t + 6 * MS) < 0,
          "two sent, two dropped (oldest first), a third is not");
    /* Up to OMACVM_IME_SHIFT_SENT copies may be on their way at once, in any order. */
    memset(&sh, 0, sizeof(sh));
    for (int k = 0; k < OMACVM_IME_SHIFT_SENT; k++) {
        omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), k & 1 ? 60 : 56, k & 2 ? 0 : SH | (k & 1 ? RS : LS),
                              t + (uint64_t)k * MS, true);
    }
    for (int k = OMACVM_IME_SHIFT_SENT - 1; k >= 0; k--) {
        all = all && omacvm_ime_shift_copy(&sh, k & 1 ? 60 : 56, k & 2 ? 0 : SH | (k & 1 ? RS : LS), t + 20 * MS) >= 0;
    }
    check(all, "8 copies on their way: each dropped");
    /* A full ring: the next slot is the oldest. */
    memset(&sh, 0, sizeof(sh));
    for (int k = 0; k < OMACVM_IME_SHIFT_SENT; k++) {
        omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t + (uint64_t)k * MS, true);
    }
    int s = omacvm_ime_shift_slot(&sh);
    check(sh.sent[s].seq == 1, "8 waiting: the next takes the oldest's slot (cocoa.m gives it to the input method first)");
    /* Due: oldest first; expired_only waits for the copy's 300 ms. */
    memset(&sh, 0, sizeof(sh));
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, SH | LS, t, true);
    omacvm_ime_shift_sent(&sh, omacvm_ime_shift_slot(&sh), 56, 0, t + 50 * MS, true);
    int d = omacvm_ime_shift_due(&sh, t + 60 * MS, UINT64_MAX, false);
    check(d >= 0 && sh.sent[d].down, "due: the oldest first (the press)");
    check(omacvm_ime_shift_due(&sh, t + 60 * MS, UINT64_MAX, true) < 0, "... none expired yet at 60 ms");
    check(omacvm_ime_shift_due(&sh, t + 301 * MS, UINT64_MAX, true) == d, "... the press expired at 301 ms");
    check(omacvm_ime_shift_due(&sh, t + 60 * MS, sh.sent[d].seq, false) < 0, "... nothing due before the oldest");
    check(!omacvm_ime_shift_stale(&sh, d, t + 999 * MS) && omacvm_ime_shift_stale(&sh, d, t + 1001 * MS),
          "a press is too old for the input method after 1 s");
    int r = -1;
    for (int k = 0; k < OMACVM_IME_SHIFT_SENT; k++) {
        if (sh.sent[k].due && !sh.sent[k].down) {
            r = k;
        }
    }
    check(r >= 0 && !omacvm_ime_shift_stale(&sh, r, t + 5000 * MS), "... a release never is");
    check(omacvm_ime_shift_mode(NULL) == OMACVM_IME_SHIFT_ON && omacvm_ime_shift_mode("1") == OMACVM_IME_SHIFT_ON &&
          omacvm_ime_shift_mode("0") == OMACVM_IME_SHIFT_OFF && omacvm_ime_shift_mode("skip") == OMACVM_IME_SHIFT_SKIP &&
          omacvm_ime_shift_mode("skipx") == OMACVM_IME_SHIFT_ON && omacvm_ime_shift_mode("") == OMACVM_IME_SHIFT_ON,
          "OMACVM_IME_SHIFT: unset/1 on, 0 off, skip a test");
}

/* Orders, as ui/cocoa.m wires the rules: what the VM and the input method get. */
static void orders(void)
{
    world("lone tap, copies back 5 ms after each", "d T5 bd T80 u T5 bu", "du", "du");
    world("lone tap, copies late but in time (main thread busy 250 ms)", "d T80 u T170 bd bu", "du", "du");
    world("chord typed before the copy: Shift first, then the key", "d T1 a T4 bd T80 u T5 bu", "dau", "dau");
    world("chord with the release before its copy too", "d T1 a T1 u T1 a T5 bd bu", "daua", "daua");
    world("letters after a tap: each in order", "d T5 bd T80 u T5 bu T50 a T50 a", "duaa", "duaa");
    world("copy never back: given before the next key", "d T5 bd T80 u T400 a", "dua", "dua");
    world("copy never back: given on the next Shift after 300 ms", "d T5 bd T80 u T400 d T5 bd", "dud", "dud");
    world("release's copy never back, next key 2 s later: still given", "d T5 bd T80 u T2000 a", "dua", "dua");
    world("press's copy never back, next key 2 s later: too old, not given", "d T2000 a", "da", "a");
    world("a copy after 300 ms is not a copy (QEMU's path)", "d T400 bd", "dd", "dd");
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
    orders();
    if (fails) {
        printf("test-ime-shift: %d FAIL\n", fails);
        return 1;
    }
    printf("test-ime-shift: all ok\n");
    return 0;
}
