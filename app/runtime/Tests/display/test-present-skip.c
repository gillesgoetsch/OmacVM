/*
 * Test for omacvm-cocoa-present-skipped-last.patch: a drawn frame that the vsync
 * queue skips with none queued after it (the trims after a tick) waits in
 * present_pend, with the tiled present on or off: the next frame that comes takes
 * it over (a tile frame may lie over it), or else the next tick shows it, so the
 * window ends on the guest's last frame.
 *
 * test-present-skip.sh takes PresentFrame, the queue's skip code
 * (present_frame_put, present_frame_absorb, present_pend, present_frame_skip)
 * and the queue itself (present_sync, cocoa_gl_present_queue_frame,
 * cocoa_gl_present_vsync and what they call) from a ui/cocoa.m and builds them
 * here with the tiled present's rules (ui/omacvm-present-tiles.h), stand-ins for
 * IOSurfaces that count their use, and a clock of the test's own. No QEMU, no GL,
 * no display.
 *
 *   cc -IDIR test-present-skip.c -o t -lm && ./t
 *   DIR holds omacvm-present-tiles.h and present-queue.inc.
 */
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int GLint;
#define GL_NEAREST 0x2600

/* An IOSurface: its use count (IOSurfaceIncrementUseCount) and references (CFRetain). */
typedef struct Surface {
    int use, refs;
} *IOSurfaceRef;

/* as cocoa.m's surface_put: IOSurfaceDecrementUseCount, CFRelease */
static void surface_put(IOSurfaceRef s)
{
    s->use--;
    s->refs--;
}
static void g_free(void *p) { free(p); }
static int present_tiles_on;

/* What the queue calls around it. One thread: the lock is a no-op. */
typedef int os_unfair_lock;
static void os_unfair_lock_lock(os_unfair_lock *l) { (void)l; }
static void os_unfair_lock_unlock(os_unfair_lock *l) { (void)l; }
static os_unfair_lock present_lock;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define SCALE_MS 1000000LL
#define QEMU_CLOCK_REALTIME 0
static double clock_s = 100;            /* CACurrentMediaTime() */
static double CACurrentMediaTime(void) { return clock_s; }
static int64_t qemu_clock_get_ns(int clock) { (void)clock; return (int64_t)(clock_s * 1e9); }
static int64_t qemu_input_last_event_ns(void) { return 0; }   /* no input */
static bool present_fixed, present_input_first, present_trim_quarter;
typedef struct QEMUBH QEMUBH;
static QEMUBH *present_bh;
static void qemu_bh_schedule(QEMUBH *bh) { (void)bh; }
#define trace_cocoa_present_direct(...) ((void)0)
#define trace_cocoa_present_frame(...) ((void)0)
#define trace_cocoa_present_second(...) ((void)0)
#define trace_cocoa_present_skips(...) ((void)0)
/* the display link's start and rate on the main queue: not part of this test */
#define dispatch_async(...) ((void)0)
/* the layer: the whole frame it shows (tile frames are not part of these runs) */
static IOSurfaceRef layer;
#define present_frame_show(f) ((void)((f)->surf && (layer = (f)->surf)))

#include "omacvm-present-tiles.h"
#include "present-queue.inc"

static int fails;
static void check(const char *what, bool ok)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

/* A drawn frame as cocoa_gl_present_send queues it: the surface retained and in use. */
static PresentFrame frame(struct Surface *s)
{
    s->use++;
    s->refs++;
    return (PresentFrame){ .surf = s, .filter = GL_NEAREST, .flushed = clock_s };
}

static bool free_again(const struct Surface *s) { return s->use == 0 && s->refs == 0; }
static bool pend_empty(void) { return !present_pend.surf && !present_pend.pt; }

/* 60 Hz: the guest's drawn frames come halfway between two ticks. */
#define TICK_S (1.0 / 60)
static void arrive(struct Surface *s)
{
    present_sync.inflight++;            /* cocoa_gl_present_send */
    cocoa_gl_present_queue_frame(frame(s));
    clock_s += TICK_S / 2;
}
static void tick(void)
{
    cocoa_gl_present_vsync(TICK_S);
    clock_s += TICK_S / 2;
}

/* The queue as QEMU starts it, with the tiled present on or off and the quarter-second trim. */
#define SCROLL_MAX 64
static struct Surface scroll_frames[SCROLL_MAX];
static void queue_reset(int tiles)
{
    memset(&present_sync, 0, sizeof(present_sync));
    present_sync.win_min = INT_MAX;
    present_sync.win_gap = present_sync.win_gap2 = INFINITY;
    present_pend = (PresentFrame){ 0 };
    memset(scroll_frames, 0, sizeof(scroll_frames));
    present_tiles_on = tiles;
    present_trim_quarter = true;
    layer = NULL;
}

/*
 * A scroll in drawn frames (extra brightness, or a guest buffer that is no
 * IOSurface): close frames link the queue (two go on the layer at once, the
 * third starts the link), then a frame is left over after every tick until
 * the quarter-second trim skips the one left over, which is the scroll's
 * newest. With MORE a newer frame comes before the next tick. LAST: the frame
 * the trim skipped; SHOWN: what the layer shows after that next tick. False if
 * the trim did not skip the newest frame right after the tick showed the one
 * before it.
 */
static bool scroll(int tiles, bool more, struct Surface **last, IOSurfaceRef *shown)
{
    int n = 0;

    queue_reset(tiles);
    while (n < 4) {
        arrive(&scroll_frames[n++]);
    }
    while (n < SCROLL_MAX) {
        tick();
        if (!present_sync.queued) {
            break;                      /* the trim skipped the frame left over */
        }
        arrive(&scroll_frames[n++]);
    }
    if (n == SCROLL_MAX || layer != &scroll_frames[n - 2]) {
        return false;
    }
    *last = &scroll_frames[n - 1];
    if (more) {
        arrive(&scroll_frames[n++]);
    }
    tick();
    *shown = layer;
    return true;
}

static bool all_free(void)
{
    for (int i = 0; i < SCROLL_MAX; i++) {
        if (!free_again(&scroll_frames[i])) {
            return false;
        }
    }
    return pend_empty();
}

int main(void)
{
    struct Surface drawn = { 0 }, newer = { 0 };

    /* A drawn whole frame skipped with none after it: the next tile frame lies over it. */
    present_tiles_on = 1;
    PresentFrame w = frame(&drawn);
    present_frame_skip(&w, NULL);
    check("tiles on: a drawn whole frame skipped with none after it waits in present_pend",
          present_pend.surf == &drawn && drawn.use == 1);
    PresentFrame t = { .filter = GL_NEAREST, .pt = calloc(1, sizeof(OmacvmPTFrame)) };
    present_frame_absorb(&t, &present_pend);
    check("tiles on: ... and the next tile frame takes it as its whole frame",
          t.pt->base == &drawn && drawn.use == 1 && pend_empty());
    present_frame_put(&t);
    check("tiles on: ... which gives it back once shown", free_again(&drawn));

    /* Without the tiled present it waits too; skipped before a newer frame, it goes. */
    present_tiles_on = 0;
    drawn = (struct Surface){ 0 };
    w = frame(&drawn);
    present_frame_skip(&w, NULL);
    check("tiles off: a drawn frame skipped with none after it waits in present_pend",
          present_pend.surf == &drawn && drawn.use == 1);
    present_frame_put(&present_pend);
    drawn = (struct Surface){ 0 };
    w = frame(&drawn);
    PresentFrame next = frame(&newer);
    present_frame_skip(&w, &next);
    check("tiles off: a drawn frame skipped before a newer one just goes",
          free_again(&drawn) && pend_empty() && newer.use == 1);
    present_frame_put(&next);

    /* The queue: the quarter-second trim skips the last frame of a scroll. */
    for (int tiles = 1; tiles >= 0; tiles--) {
        struct Surface *last;
        IOSurfaceRef shown;
        char what[200];
        bool ran = scroll(tiles, false, &last, &shown);
        const char *on = present_tiles_on ? "tiles on" : "tiles off";
        snprintf(what, sizeof(what), "%s: the trim after a tick skips a scroll's newest drawn frame", on);
        check(what, ran);
        snprintf(what, sizeof(what),
                 "%s: ... with no frame after it, the next tick shows it (the window ends on it)", on);
        check(what, ran && shown == last);
        snprintf(what, sizeof(what), "%s: ... and every surface goes back", on);
        check(what, ran && all_free());
        ran = scroll(tiles, true, &last, &shown);
        snprintf(what, sizeof(what),
                 "%s: ... with a newer frame before the next tick, that tick shows the newer "
                 "(the trim still saves a refresh)", on);
        check(what, ran && shown == last + 1 && free_again(last));
        snprintf(what, sizeof(what), "%s: ... and every surface goes back", on);
        check(what, ran && all_free());
    }

    /*
     * The link's first tick comes a second late with two frames queued: it shows the
     * first, the once-a-second drop skips the second (left over in every tick of the
     * window), and the frames came one at a time, which ends the link.
     */
    queue_reset(0);
    for (int n = 0; n < 4; n++) {
        arrive(&scroll_frames[n]);
    }
    clock_s += 1.0;
    bool ticking = cocoa_gl_present_vsync(TICK_S);
    check("a late first tick that skips the newest frame keeps the link for it",
          layer == &scroll_frames[2] && ticking);
    tick();
    check("... and the next tick shows it", layer == &scroll_frames[3] && all_free());

    printf("%s\n", fails ? "test-present-skip: FAIL" : "test-present-skip: all ok");
    return fails != 0;
}
