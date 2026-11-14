/*
 * HDR only in full screen (ADR 0074): the rules of ui/omacvm-hdr-follow.h,
 * no AppKit (test-hdr-follow.sh builds it against the logic patch).
 */
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-hdr-follow.h"

static int fails;

#define S 1000000000LL
#define MS 1000000LL

static void check(bool ok, const char *what)
{
    if (!ok) {
        printf("FAIL %s\n", what);
        fails++;
    }
}

static void near(double got, double want, const char *what)
{
    if (fabs(got - want) > 1e-9) {
        printf("FAIL %s: %.3f, not %.3f\n", what, got, want);
        fails++;
    }
}

/*
 * A model of cocoa_gl_present_alloc's hold-off (omacvm-cocoa-hdr-headroom.patch
 * with omacvm-cocoa-present-depth-hold.patch): returns what the present does
 * with a frame and moves the model's surfaces.
 */
enum { DRAWN, REMADE, SCALED, HELD };
typedef struct {
    bool have, deep, linear;
    int64_t alloc_ns, depth_ns, due;
} Surfaces;

static int present(Surfaces *s, bool deep, bool linear, bool pq, int64_t now)
{
    const int64_t realloc_ns = 500 * MS;

    s->due = 0;
    if (s->have) {
        if (deep == s->deep && linear == s->linear) {
            return DRAWN;
        }
        bool depth_now = now - s->depth_ns >= S;
        if (now - s->alloc_ns < realloc_ns && !depth_now) {
            s->due = omacvm_hf_hold_due(s->alloc_ns, realloc_ns, now);
            return omacvm_hf_wrong_colour(s->deep, s->linear, deep, pq) ? HELD : SCALED;
        }
        if (depth_now) {
            s->depth_ns = now;
        }
    }
    s->have = true;
    s->deep = deep;
    s->linear = linear;
    s->alloc_ns = now;
    return REMADE;
}

int main(void)
{
    /* Which frames would show wrong colours. */
    check(!omacvm_hf_wrong_colour(false, false, false, true), "8-bit in 8-bit is right");
    check(!omacvm_hf_wrong_colour(true, false, true, true), "PQ in PQ is right");
    check(omacvm_hf_wrong_colour(false, false, true, true), "PQ in 8-bit sRGB surfaces is wrong");
    check(omacvm_hf_wrong_colour(true, false, false, true), "sRGB in PQ surfaces is wrong");
    check(!omacvm_hf_wrong_colour(false, true, true, true), "linear surfaces decode PQ (extra brightness)");
    check(!omacvm_hf_wrong_colour(false, true, false, true), "linear surfaces take sRGB");
    check(!omacvm_hf_wrong_colour(false, false, true, false), "without HDR both depths are sRGB");
    check(!omacvm_hf_wrong_colour(true, false, false, false), "without HDR both depths are sRGB (2)");

    /* The hold's timer is never at or before now. */
    check(omacvm_hf_hold_due(10 * S, 500 * MS, 10 * S + 100 * MS) == 10 * S + 500 * MS, "due at the hold-off's end");
    check(omacvm_hf_hold_due(10 * S, 500 * MS, 10 * S + 500 * MS) > 10 * S + 500 * MS, "due at now moves after now");
    check(omacvm_hf_hold_due(10 * S, 500 * MS, 11 * S) > 11 * S, "due in the past moves after now");

    /*
     * The guest flips 8 -> 10 -> 8 bit: each flip's first frame gets surfaces
     * of its own at once (more than 1 s apart), so nothing is held.
     */
    Surfaces s = { 0 };
    int64_t t = 10 * S;
    check(present(&s, false, false, true, t) == REMADE, "first frame: surfaces");
    check(present(&s, false, false, true, t + 8 * MS) == DRAWN, "next frame drawn");
    check(present(&s, true, false, true, t + 2 * S) == REMADE, "PQ: new surfaces at once");
    check(present(&s, false, false, true, t + 4 * S) == REMADE, "sRGB again: new surfaces at once");

    /*
     * Two flips within 1 s, the second inside the hold-off: 3.4.5 drew the
     * PQ frame into 8-bit sRGB surfaces (wrong colours for up to 0.5 s);
     * now it is held until the hold-off's end, then drawn in its own.
     */
    s = (Surfaces){ 0 };
    check(present(&s, false, false, true, t) == REMADE, "2: first frame");
    check(present(&s, false, false, true, t + 300 * MS) == DRAWN, "2: drawn");
    s.depth_ns = t + 200 * MS;    /* a depth remake just before (another flip) */
    s.alloc_ns = t + 200 * MS;
    check(present(&s, true, false, true, t + 400 * MS) == HELD, "a PQ frame is held, not shown in sRGB surfaces");
    check(s.due == t + 700 * MS, "held until the hold-off ends");
    check(present(&s, true, false, true, s.due) == REMADE, "then PQ surfaces and the frame");

    /* Linear surfaces wanted (extra brightness on) in the hold-off of PQ ones. */
    s = (Surfaces){ 0 };
    present(&s, true, false, true, t);
    s.depth_ns = t;
    check(present(&s, true, true, true, t + 100 * MS) == SCALED, "a PQ frame stays right in PQ surfaces until linear ones come");
    check(present(&s, false, true, true, t + 100 * MS) == HELD, "an sRGB frame is held, not shown in PQ surfaces");
    /* Without HDR (a 10-bit sRGB desktop) the hold-off draws as before. */
    s = (Surfaces){ 0 };
    present(&s, false, false, false, t);
    s.depth_ns = t;
    check(present(&s, true, false, false, t + 100 * MS) == SCALED, "without HDR a 10-bit frame goes into 8-bit surfaces as before");

    /* The headroom the guest is told. */
    OmacvmHfEdr h = { .held = -1 };
    near(omacvm_hf_edr(&h, 1, 1.2, 16, false, true, 0, 0), 16, "SDR first: the display's most");
    near(omacvm_hf_edr(&h, 1, 1.2, 40, false, true, 0, 0), 16, "capped at 16");
    h = (OmacvmHfEdr){ .held = -1 };
    near(omacvm_hf_edr(&h, 1, 1.2, 4, false, true, 0, 0), 4, "SDR: the display's most (4)");
    /* full screen at 5 s: macOS ramps 1.2 -> 4 over 2 s */
    near(omacvm_hf_edr(&h, 1, 1.2, 4, false, false, 5 * S, 5 * S + 100 * MS), 4, "PQ while ramping: not less than before");
    near(omacvm_hf_edr(&h, 1, 2.5, 4, false, false, 5 * S, 6 * S), 4, "PQ while ramping (2)");
    near(omacvm_hf_edr(&h, 1, 3.6, 4, false, false, 5 * S, 8 * S + 1), 3.6, "after 3 s: the current headroom");
    near(omacvm_hf_edr(&h, 1, 3.6, 4, false, true, 5 * S, 20 * S), 3.6, "SDR again: what it had with PQ");
    near(omacvm_hf_edr(&h, 1, 1.0, 4, false, false, 30 * S, 30 * S + 1), 3.6, "next full screen starts from it");
    near(omacvm_hf_edr(&h, 1, 3.7, 4, false, false, 30 * S, 30 * S + 2), 3.7, "ramp done when current reaches it");
    near(omacvm_hf_edr(&h, 2, 1.1, 2, false, true, 30 * S, 31 * S), 2, "another display forgets it");
    /* a PQ stretch that only ever saw SDR headroom does not lower it */
    h = (OmacvmHfEdr){ .held = -1 };
    omacvm_hf_edr(&h, 1, 1.0, 8, false, false, 1 * S, 5 * S);
    near(omacvm_hf_edr(&h, 1, 1.0, 8, false, true, 1 * S, 6 * S), 8, "SDR headroom is never remembered");

    if (fails) {
        printf("test-hdr-follow: %d failed\n", fails);
        return 1;
    }
    printf("test-hdr-follow: all passed\n");
    return 0;
}
