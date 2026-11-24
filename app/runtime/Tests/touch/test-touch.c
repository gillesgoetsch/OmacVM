/*
 * The touch rules (ui/omacvm-touch.h, omacvm-cocoa-touch-logic.patch): what
 * the guest gets for a tap, a scroll, a hold-drag, a long press, two fingers,
 * a pinch and a coast. Made-up touches with the timing measured on the touch display
 * (#843): taps last 50-75 ms and do not move, a hold-drag starts moving
 * 470-850 ms in, a double tap's second tap lands 5-26 pt from the first, one
 * finger of two lifts a moment before the other. No QEMU, no AppKit.
 */
#include <stdio.h>
#include "omacvm-touch.h"

static int fail;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        fail = 1;
    }
}

/* The actions' kinds as a string ("M D U" ...), for compact checks. */
static const char *kinds(const OmacVMTouchActions *o)
{
    static char buf[64];
    static const char *k[] = { "M", "D", "U", "RD", "RU", "S", "C", "X", "PB", "PM", "PE" };
    buf[0] = 0;
    for (int i = 0; i < o->n; i++) {
        if (i) {
            strcat(buf, " ");
        }
        strcat(buf, k[o->a[i].kind]);
    }
    return buf;
}
static int is(const OmacVMTouchActions *o, const char *want)
{
    return !strcmp(kinds(o), want);
}
static int near(double a, double b)
{
    return fabs(a - b) < 1e-6;
}

static OmacVMTouch T;
static OmacVMTouchActions o;

/*
 * Two fingers at (ax, y) and (bx, y) at time t, as ui/cocoa.m gives them: the
 * move (their centre, no own movement worth a scroll), then the two fingers.
 * The actions of both, the move's first.
 */
static void two(double t, double ax, double bx, double y)
{
    OmacVMTouchActions m;

    omacvm_touch_move(&T, t, (ax + bx) / 2, y, 0, 0, &m);
    omacvm_touch_two(&T, ax, y, bx, y, &o);
    for (int i = 0; i < o.n && m.n < 8; i++) {
        m.a[m.n++] = o.a[i];
    }
    o = m;
}
/* Two fingers land together at (ax, y) and (bx, y). */
static void land2(double t, double ax, double bx, double y)
{
    OmacVMTouchActions m;

    omacvm_touch_begin(&T, t, (ax + bx) / 2, y, 2, &m);
    omacvm_touch_two(&T, ax, y, bx, y, &o);
    check(o.n == 0, "two fingers landing: where they are is only noted");
    o = m;
}

int main(void)
{
    double sx, sy, vx, vy, dx, dy;

    /* A tap: 60 ms, no movement. */
    memset(&T, 0, sizeof(T));
    omacvm_touch_begin(&T, 10.0, 200, 300, 1, &o);
    check(is(&o, "X"), "tap: touch-down only stops a coast; nothing to the guest yet");
    omacvm_touch_lift(&T, 10.06, 0, &o);
    check(is(&o, "M D U") && near(o.a[0].x, 200) && near(o.a[0].y, 300),
          "tap: at the lift, the pointer to the touch, then a click");

    /* A tap that moves less than the slop is still a tap, at the touch-down. */
    omacvm_touch_begin(&T, 20.0, 400, 300, 1, &o);
    omacvm_touch_move(&T, 20.03, 405, 304, 5, 4, &o);
    check(o.n == 0, "tap: moving within 8 pt sends nothing");
    omacvm_touch_lift(&T, 20.07, 0, &o);
    check(is(&o, "M D U") && near(o.a[0].x, 400), "tap: within the slop, a click where it began");

    /* A double tap: the second lands 17 pt away 125 ms after the first's lift. */
    omacvm_touch_begin(&T, 30.0, 389.5, 283.5, 1, &o);
    omacvm_touch_lift(&T, 30.065, 0, &o);
    omacvm_touch_begin(&T, 30.19, 406.5, 282.5, 1, &o);
    omacvm_touch_lift(&T, 30.24, 0, &o);
    check(is(&o, "M D U") && near(o.a[0].x, 389.5) && near(o.a[0].y, 283.5),
          "double tap: the second tap lands on the first (17 pt off, 125 ms)");
    omacvm_touch_begin(&T, 30.33, 380, 300, 1, &o);
    omacvm_touch_lift(&T, 30.38, 0, &o);
    check(near(o.a[0].x, 389.5), "triple tap: the third lands there too");
    omacvm_touch_begin(&T, 31.5, 389.5, 283.5, 1, &o);
    omacvm_touch_lift(&T, 31.55, 0, &o);
    omacvm_touch_begin(&T, 32.0, 395, 290, 1, &o);
    omacvm_touch_lift(&T, 32.05, 0, &o);
    check(near(o.a[0].x, 395), "double tap: not after 0.4 s");
    omacvm_touch_begin(&T, 32.2, 460, 290, 1, &o);
    omacvm_touch_lift(&T, 32.25, 0, &o);
    check(near(o.a[0].x, 460), "double tap: not 65 pt away");

    /* A scroll: moving at once. The pointer goes under the finger first. */
    omacvm_touch_begin(&T, 40.0, 500, 200, 1, &o);
    omacvm_touch_move(&T, 40.03, 500, 215, 0, 15, &o);
    check(is(&o, "M S") && near(o.a[0].y, 200) && near(o.a[1].dy, 7) && near(o.a[1].dx, 0),
          "scroll: past the slop at once, the pointer to the touch, then only the way past the slop (no lurch)");
    omacvm_touch_move(&T, 40.04, 500, 225, 0, 10, &o);
    check(is(&o, "S") && near(o.a[0].dy, 10), "scroll: then each movement");
    for (int i = 1; i <= 8; i++) {
        omacvm_touch_move(&T, 40.04 + 0.008 * i, 500, 225 + 12 * i, 0, 12, &o);
    }
    omacvm_touch_lift(&T, 40.11, 0, &o);
    check(is(&o, "C") && o.a[0].dy > 1000 && fabs(o.a[0].dx) < 1,
          "scroll: a flick (12 pt / 8 ms) coasts at its speed");
    omacvm_touch_begin(&T, 40.3, 600, 200, 1, &o);
    check(is(&o, "X"), "scroll: the next touch stops the coast");
    omacvm_touch_lift(&T, 40.32, 0, &o);

    /* A slow scroll, and one that stops before the lift: no coast. */
    omacvm_touch_begin(&T, 50.0, 500, 200, 1, &o);
    omacvm_touch_move(&T, 50.05, 500, 210, 0, 10, &o);
    for (int i = 1; i <= 10; i++) {
        omacvm_touch_move(&T, 50.05 + 0.05 * i, 500, 210 + i, 0, 1, &o);
    }
    omacvm_touch_lift(&T, 50.56, 0, &o);
    check(o.n == 0, "scroll: a slow one (20 pt/s) does not coast");
    omacvm_touch_begin(&T, 51.0, 500, 200, 1, &o);
    for (int i = 1; i <= 8; i++) {
        omacvm_touch_move(&T, 51.0 + 0.008 * i, 500, 200 + 15 * i, 0, 15, &o);
    }
    omacvm_touch_lift(&T, 51.2, 0, &o);
    check(o.n == 0, "scroll: a finger that stopped before lifting does not coast");

    /* Hold, then drag: moving 470 ms in, and 850 ms in. */
    omacvm_touch_begin(&T, 60.0, 222, 518, 1, &o);
    omacvm_touch_move(&T, 60.2, 223, 519, 1, 1, &o);
    check(o.n == 0, "hold: still within the slop sends nothing");
    omacvm_touch_move(&T, 60.47, 222, 505, -1, -14, &o);
    check(is(&o, "M D M") && near(o.a[0].y, 518) && near(o.a[2].y, 505),
          "hold-drag (moved 470 ms in): the pointer to the touch, the button down, then the finger");
    omacvm_touch_move(&T, 60.5, 222, 480, 0, -25, &o);
    check(is(&o, "M") && near(o.a[0].y, 480), "hold-drag: the pointer follows the finger, the button held");
    omacvm_touch_lift(&T, 61.3, 0, &o);
    check(is(&o, "M U") && near(o.a[0].y, 480), "hold-drag: the button up where the finger lifts");
    omacvm_touch_begin(&T, 62.0, 565, 178, 1, &o);
    omacvm_touch_move(&T, 62.85, 565, 200, 0, 22, &o);
    check(is(&o, "M D M"), "hold-drag (moved 850 ms in, after the long-press time): still a drag, no right click");
    omacvm_touch_lift(&T, 63.6, 0, &o);
    check(is(&o, "M U"), "... and its button up");

    /* A long press: lifted without moving after 0.6 s: a right click at the release. */
    omacvm_touch_begin(&T, 70.0, 817, 480, 1, &o);
    omacvm_touch_move(&T, 70.5, 818, 481, 1, 1, &o);
    check(o.n == 0, "long press: nothing while the finger is down");
    omacvm_touch_lift(&T, 71.0, 0, &o);
    check(is(&o, "M RD RU") && near(o.a[0].x, 817), "long press: a right click where it began, at the release");
    omacvm_touch_begin(&T, 72.0, 400, 400, 1, &o);
    omacvm_touch_lift(&T, 72.45, 0, &o);
    check(is(&o, "M D U"), "a hold lifted between 0.35 and 0.6 s is a click");
    omacvm_touch_begin(&T, 72.6, 405, 402, 1, &o);
    omacvm_touch_lift(&T, 72.65, 0, &o);
    check(near(o.a[0].x, 400), "... and the next tap can make it a double click");
    omacvm_touch_begin(&T, 73.0, 400, 400, 1, &o);
    omacvm_touch_lift(&T, 73.7, 0, &o);
    omacvm_touch_begin(&T, 73.8, 405, 402, 1, &o);
    omacvm_touch_lift(&T, 73.85, 0, &o);
    check(near(o.a[0].x, 405), "a tap after a right click is not its double click");

    /* Two fingers landing together: nothing but the pointer between them. */
    omacvm_touch_begin(&T, 80.0, 726.8, 542, 2, &o);
    check(is(&o, "X M") && near(o.a[1].x, 726.8), "two fingers: the pointer between them at once (a pinch's centre)");
    int moved = 0;
    for (int i = 1; i <= 8; i++) {
        omacvm_touch_move(&T, 80.0 + 0.008 * i, 726.8, 542 - 10 * i, 0, -10, &o);
        moved += o.n;
    }
    check(moved == 0, "two fingers moving: no scroll, nothing at all (as on macOS)");
    omacvm_touch_lift(&T, 80.07, 1, &o);
    check(o.n == 0, "two fingers: the first lift sends nothing (no coast)");
    omacvm_touch_move(&T, 80.075, 782, 194, 50, 20, &o);
    check(o.n == 0, "two fingers: the finger left after it scrolls nothing");
    omacvm_touch_lift(&T, 80.08, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "two fingers: the last lift sends nothing and ends");

    /* A second finger 16 ms after the first (a pinch starting). */
    omacvm_touch_begin(&T, 90.0, 316, 513, 1, &o);
    omacvm_touch_begin(&T, 90.016, 368, 525, 2, &o);
    check(is(&o, "M") && near(o.a[0].x, 368), "two fingers, the second just after: the pointer between them");
    omacvm_touch_move(&T, 90.03, 369, 519, 1, -5.5, &o);
    check(o.n == 0, "... their movement sends nothing");
    omacvm_touch_lift(&T, 90.6, 1, &o);
    omacvm_touch_lift(&T, 90.61, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "... no click at the end, and it ends");

    /* A second finger during a one-finger scroll stops the scroll. */
    omacvm_touch_begin(&T, 95.0, 300, 300, 1, &o);
    omacvm_touch_move(&T, 95.02, 300, 320, 0, 20, &o);
    omacvm_touch_begin(&T, 95.03, 320, 320, 2, &o);
    check(is(&o, "M") && T.phase == OMACVM_TOUCH_MULTI, "a second finger during a scroll: the scroll stops, the pointer between them");
    omacvm_touch_move(&T, 95.04, 320, 330, 0, 10, &o);
    check(o.n == 0, "... the fingers scroll nothing more");
    omacvm_touch_lift(&T, 95.05, 1, &o);
    check(o.n == 0, "... no coast at a lift");
    omacvm_touch_lift(&T, 95.06, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "... nor at the last");

    /* A second finger during a drag changes nothing. */
    omacvm_touch_begin(&T, 97.0, 300, 300, 1, &o);
    omacvm_touch_move(&T, 97.5, 300, 330, 0, 30, &o);
    omacvm_touch_begin(&T, 97.6, 350, 330, 2, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_DRAG, "a second finger during a drag: the drag goes on");
    omacvm_touch_cancel(&T, &o);
    check(is(&o, "U"), "macOS takes the touches during a drag: the button goes up");
    check(T.phase == OMACVM_TOUCH_IDLE, "... and the next touch starts afresh");
    omacvm_touch_cancel(&T, &o);
    check(o.n == 0, "a cancel with nothing under way sends nothing");

    /* Two fingers moving together 80 pt (their spread wobbling 6 pt): no pinch. */
    land2(100.0, 400, 500, 300);
    int sent = 0;
    for (int i = 1; i <= 10; i++) {
        two(100.0 + 0.008 * i, 400 + (i % 2) * 3, 500 - (i % 2) * 3, 300 + 8 * i);
        sent += o.n;
    }
    check(sent == 0 && T.phase == OMACVM_TOUCH_MULTI, "two fingers moving together: no pinch, nothing to the guest");
    omacvm_touch_lift(&T, 100.2, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "... and nothing at their lift");

    /* Spreading 3 pt each side a frame: a pinch once the spread grew by more than 16 pt. */
    land2(110.0, 400, 500, 300);
    two(110.008, 397, 503, 300);
    two(110.016, 394, 506, 300);
    check(o.n == 0, "spreading: no pinch at 12 pt");
    two(110.024, 391, 509, 300);
    check(is(&o, "PB") && near(o.a[0].x, 391) && near(o.a[0].y, 300) && near(o.a[0].dx, 509) && near(o.a[0].dy, 300),
          "spreading: a pinch at 18 pt: both fingers land on the guest's touch screen where they are");
    two(110.032, 380, 520, 300);
    check(is(&o, "PM") && near(o.a[0].x, 380) && near(o.a[0].dx, 520), "... then they move there as they are");
    two(110.04, 390, 530, 310);
    check(is(&o, "PM") && near(o.a[0].x, 390) && near(o.a[0].y, 310),
          "... also moving together (the guest's app pans and zooms as it likes)");
    omacvm_touch_lift(&T, 110.3, 1, &o);
    check(is(&o, "PE") && T.phase == OMACVM_TOUCH_DONE, "a finger lifts: the pinch ends (both lift in the guest)");
    omacvm_touch_move(&T, 110.31, 500, 300, 20, 0, &o);
    check(o.n == 0, "... the finger left sends nothing");
    omacvm_touch_lift(&T, 110.4, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "... nor does its lift");
    omacvm_touch_begin(&T, 110.5, 450, 300, 1, &o);
    omacvm_touch_lift(&T, 110.55, 0, &o);
    check(is(&o, "M D U") && near(o.a[0].x, 450), "a tap after a pinch is a click");

    /* Closing, the centre drifting 6 pt: a pinch. Both lift in one event. */
    land2(120.0, 300, 600, 400);
    two(120.01, 312, 594, 400);
    check(is(&o, "PB"), "closing 18 pt while the centre drifts 3 pt: a pinch");
    omacvm_touch_lift(&T, 120.2, 0, &o);
    check(is(&o, "PE") && T.phase == OMACVM_TOUCH_IDLE, "both fingers lift at once: the pinch ends, and the touch");

    /* The spread changes, but less than 1.3 times the centre's way: no pinch. */
    land2(130.0, 300, 400, 400);
    two(130.01, 330, 450, 400);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_MULTI, "the spread 20 pt wider but the centre 40 pt on: no pinch");
    omacvm_touch_lift(&T, 130.1, 0, &o);

    /* The second finger a moment after the first, and during a scroll. */
    omacvm_touch_begin(&T, 140.0, 300, 300, 1, &o);
    omacvm_touch_begin(&T, 140.016, 350, 300, 2, &o);
    omacvm_touch_two(&T, 300, 300, 400, 300, &o);
    two(140.03, 280, 420, 300);
    check(is(&o, "PB"), "a second finger just after the first, then spreading: a pinch (no click)");
    omacvm_touch_lift(&T, 140.2, 0, &o);
    omacvm_touch_begin(&T, 141.0, 300, 300, 1, &o);
    omacvm_touch_move(&T, 141.02, 300, 320, 0, 20, &o);
    omacvm_touch_begin(&T, 141.03, 350, 320, 2, &o);
    omacvm_touch_two(&T, 300, 320, 400, 320, &o);
    two(141.05, 280, 420, 320);
    check(is(&o, "PB"), "a second finger during a scroll, then spreading: the scroll stopped, a pinch");
    omacvm_touch_lift(&T, 141.2, 1, &o);
    omacvm_touch_lift(&T, 141.21, 0, &o);
    check(o.n == 0, "... and no coast after it");

    /* A third finger ends a pinch; three fingers never pinch. */
    land2(150.0, 400, 500, 300);
    two(150.01, 380, 520, 300);
    omacvm_touch_begin(&T, 150.02, 500, 350, 3, &o);
    check(is(&o, "PE") && T.phase == OMACVM_TOUCH_DONE, "a third finger: the pinch ends");
    two(150.03, 300, 600, 300);
    check(o.n == 0, "... and nothing more until the last lift");
    omacvm_touch_lift(&T, 150.1, 0, &o);
    omacvm_touch_begin(&T, 151.0, 450, 300, 3, &o);
    omacvm_touch_lift(&T, 151.05, 2, &o);
    omacvm_touch_two(&T, 400, 300, 500, 300, &o);
    two(151.1, 350, 550, 300);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_MULTI, "three fingers, one lifted, two spreading: no pinch");
    omacvm_touch_lift(&T, 151.2, 0, &o);
    land2(152.0, 400, 500, 300);
    omacvm_touch_lift(&T, 152.05, 1, &o);
    omacvm_touch_begin(&T, 152.1, 450, 300, 2, &o);
    omacvm_touch_two(&T, 400, 300, 500, 300, &o);
    two(152.15, 350, 550, 300);
    check(o.n == 0, "two fingers, one lifted and landed again: no pinch (nothing until the last lift)");
    omacvm_touch_lift(&T, 152.2, 0, &o);

    /* A drag keeps going; macOS taking the touches ends a pinch; bad input. */
    omacvm_touch_begin(&T, 160.0, 300, 300, 1, &o);
    omacvm_touch_move(&T, 160.5, 300, 330, 0, 30, &o);
    omacvm_touch_begin(&T, 160.6, 350, 330, 2, &o);
    omacvm_touch_two(&T, 300, 330, 400, 330, &o);
    omacvm_touch_two(&T, 250, 330, 450, 330, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_DRAG, "a second finger during a drag, spreading: no pinch, the drag goes on");
    omacvm_touch_cancel(&T, &o);
    land2(161.0, 400, 500, 300);
    two(161.01, 380, 520, 300);
    omacvm_touch_cancel(&T, &o);
    check(is(&o, "PE") && T.phase == OMACVM_TOUCH_IDLE, "macOS takes the touches during a pinch: it ends");
    land2(162.0, 400, 500, 300);
    omacvm_touch_two(&T, 380, NAN, 520, 300, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_MULTI, "bad input: a NaN finger is dropped");
    omacvm_touch_lift(&T, 162.1, 0, &o);

    /* The coast: slows as iOS's (0.998 per ms), ends below 20 pt/s, never jumps. */
    vx = 0;
    vy = 2000;
    double total = 0;
    int steps = 0;
    while (omacvm_touch_coast_step(&vx, &vy, 1.0 / 120, &dx, &dy) && steps < 10000) {
        total += dy;
        steps++;
    }
    check(steps > 100 && steps < 400 && total > 800 && total < 1000,
          "coast: from 2000 pt/s, about 1.6 s and a little under 1000 pt (iOS: v / ln(1/0.998) / 1000)");
    vy = 2000;
    omacvm_touch_coast_step(&vx, &vy, 5.0, &dx, &dy);
    check(dy < 2000 * 0.1 + 1, "coast: a late timer moves at most 100 ms' worth");
    vy = NAN;
    check(!omacvm_touch_coast_step(&vx, &vy, 0.01, &dx, &dy) && dx == 0 && dy == 0, "coast: a bad speed ends it");

    /* The content follows the finger. */
    omacvm_touch_scroll_deltas(0, -10, 2.0, &sx, &sy);
    check(near(sy, 20) && near(sx, 0), "direction: a finger moving down shows what is above (scrollingDeltaY > 0)");
    omacvm_touch_scroll_deltas(10, 0, 2.0, &sx, &sy);
    check(near(sx, 20), "direction: a finger moving right shows what is left (scrollingDeltaX > 0)");

    /* Bad input never sends anything. */
    memset(&T, 0, sizeof(T));
    omacvm_touch_begin(&T, NAN, 1, 1, 1, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "bad input: a NaN time is dropped");
    omacvm_touch_begin(&T, 1.0, 1, 1, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_IDLE, "bad input: no fingers is dropped");
    omacvm_touch_begin(&T, 1.0, 1, 1, 1, &o);
    omacvm_touch_move(&T, 1.1, INFINITY, 1, 0, 0, &o);
    check(o.n == 0 && T.phase == OMACVM_TOUCH_PENDING, "bad input: an infinite place is dropped");
    omacvm_touch_move(&T, 1.1, 1, 1, 0, 0, &o);
    omacvm_touch_lift(&T, NAN, 0, &o);
    check(is(&o, "M D U"), "bad input: a lift without a time still ends the touch");

    /* The switches. */
    check(omacvm_touch_off_env(NULL) && !omacvm_touch_off_env("1") && omacvm_touch_off_env("0") &&
          omacvm_touch_off_env("") && omacvm_touch_off_env("yes"), "OMACVM_TOUCH: on only with 1");
    check(near(omacvm_touch_gain_env(NULL), 1.0) && near(omacvm_touch_gain_env("1.5"), 1.5) &&
          near(omacvm_touch_gain_env("9"), 1.0) && near(omacvm_touch_gain_env("x"), 1.0) &&
          near(omacvm_touch_gain_env("0.1"), 1.0) && near(omacvm_touch_gain_env("nan"), 1.0),
          "OMACVM_TOUCH_SCROLL: 0.25 to 8, else 1");

    printf("%s\n", fail ? "FAIL touch" : "ok   touch: taps, scrolling, hold-drag, right click, two fingers, pinch, coast");
    return fail;
}
