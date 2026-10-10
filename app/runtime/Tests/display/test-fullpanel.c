/*
 * Unit test for ui/omacvm-fullpanel.h (FullPanel: the VM's full-screen
 * window over the whole notched display).
 *
 * No notched Mac is needed: the displays are made up from the sizes macOS
 * reports (points, bottom-left origin): MacBook Air 13" 1470x956 and 15"
 * 1710x1112, MacBook Pro 14" 1512x982 and 16" 1728x1117 (a top inset
 * around 32-38), and external displays without an inset. Then a window
 * that moves between them, Split View, AppKit's camera-safe re-asks and
 * the menu bar's reveal at the top edge.
 *
 * cc -Wall -Werror -I<qemu>/ui test-fullpanel.c -o t && ./t
 */
#include <stdio.h>

#include "omacvm-fullpanel.h"

static int failures, checks;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

typedef struct {
    const char *name;
    OmacVMFPRect frame;
    double notch;
} Display;

static const Display builtins[] = {
    { "MacBook Air 13", { 0, 0, 1470, 956 }, 32 },
    { "MacBook Air 15", { 0, 0, 1710, 1112 }, 33 },
    { "MacBook Pro 14", { 0, 0, 1512, 982 }, 32 },
    { "MacBook Pro 16", { 0, 0, 1728, 1117 }, 38 },
    /* A built-in that is not the main display: placed right of an external. */
    { "MacBook Air 13 beside", { 2560, -300, 1470, 956 }, 32 },
};

static const Display externals[] = {
    { "LG 5K", { 0, 0, 2560, 1440 }, 0 },
    { "Studio Display left", { -2560, 0, 2560, 1440 }, 0 },
};

static OmacVMFPRect below_notch(const Display *d)
{
    OmacVMFPRect r = d->frame;
    r.h -= d->notch;
    return r;
}

static OmacVMFPFrameIn frame_in(const Display *d, OmacVMFPRect tile, bool accepted)
{
    OmacVMFPFrameIn in = {
        .usable = omacvm_fp_display_ok(true, d->notch, false),
        .area_lost = false,
        .accepted = accepted,
        .kept = true,
        .full_screen_style = accepted,
        .notch = d->notch,
        .tile = tile,
        .display = d->frame,
    };
    return in;
}

static void test_requested(void)
{
    CHECK(omacvm_fp_requested("1"), "OMACVM_FULLPANEL=1 asks for it");
    CHECK(!omacvm_fp_requested(NULL), "unset: native");
    CHECK(!omacvm_fp_requested("0"), "0: native");
    CHECK(!omacvm_fp_requested("yes"), "only 1 counts");
    CHECK(!omacvm_fp_requested(""), "empty: native");
}

static void test_display_ok(void)
{
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; i++) {
        const Display *d = &builtins[i];
        CHECK(omacvm_fp_display_ok(true, d->notch, false), "%s: usable", d->name);
        CHECK(!omacvm_fp_display_ok(false, d->notch, false), "%s: not asked", d->name);
        CHECK(!omacvm_fp_display_ok(true, d->notch, true),
              "%s: menu bar always shown in full screen: native", d->name);
    }
    for (size_t i = 0; i < sizeof externals / sizeof externals[0]; i++) {
        CHECK(!omacvm_fp_display_ok(true, externals[i].notch, false),
              "%s: no camera housing, never", externals[i].name);
    }
}

static void test_frame(void)
{
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; i++) {
        const Display *d = &builtins[i];
        OmacVMFPFrameIn in;

        /* Entering full screen: AppKit's tile is the whole display. */
        in = frame_in(d, d->frame, false);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_DISPLAY, "%s: whole display", d->name);

        /* AppKit's camera-safe tile before anything was given: its own. */
        in = frame_in(d, below_notch(d), false);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT,
              "%s: camera-safe tile first: AppKit's frame", d->name);

        /* ... and after the whole display was given: kept. */
        in = frame_in(d, below_notch(d), true);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_DISPLAY_KEPT,
              "%s: camera-safe re-ask: whole display kept", d->name);

        /* Not while leaving full screen. */
        in.kept = false;
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: leaving: AppKit's", d->name);

        /* Split View: half the width. */
        OmacVMFPRect half = d->frame;
        half.w = d->frame.w / 2;
        in = frame_in(d, half, true);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: Split View: AppKit's", d->name);

        /* A tile a few points shorter than the inset: not the camera-safe one. */
        OmacVMFPRect odd = below_notch(d);
        odd.h -= 3;
        in = frame_in(d, odd, true);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: other tile: AppKit's", d->name);

        /* The strip was lost once in this full screen: no second try. */
        in = frame_in(d, d->frame, true);
        in.area_lost = true;
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: lost: AppKit's", d->name);

        /* Private parts missing (usable false): AppKit's. */
        in = frame_in(d, d->frame, false);
        in.usable = false;
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: not usable: AppKit's", d->name);
    }
    for (size_t i = 0; i < sizeof externals / sizeof externals[0]; i++) {
        const Display *d = &externals[i];
        OmacVMFPFrameIn in = frame_in(d, d->frame, false);
        CHECK(omacvm_fp_frame(&in) == OMACVM_FP_APPKIT, "%s: external: AppKit's", d->name);
    }
}

static OmacVMFPKeepIn keep_in(const Display *d, OmacVMFPRect tile)
{
    OmacVMFPKeepIn in = {
        .kept = true, .accepted = true, .full_screen_style = true,
        .usable = omacvm_fp_display_ok(true, d->notch, false), .area_lost = false,
        .frame = d->frame, .display = d->frame, .tile = tile,
    };
    return in;
}

static void test_keep(void)
{
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; i++) {
        const Display *d = &builtins[i];
        OmacVMFPKeepIn in = keep_in(d, below_notch(d));

        CHECK(omacvm_fp_keep(&in), "%s: camera-safe relayout refused", d->name);
        in.tile = d->frame;
        CHECK(omacvm_fp_keep(&in), "%s: same frame again: kept", d->name);

        OmacVMFPRect half = d->frame;
        half.w /= 2;
        in.tile = half;
        CHECK(!omacvm_fp_keep(&in), "%s: Split View goes through", d->name);

        in = keep_in(d, d->frame);
        in.frame = below_notch(d);
        CHECK(!omacvm_fp_keep(&in), "%s: not at the whole display: not kept", d->name);

        in = keep_in(d, d->frame);
        in.accepted = false;
        CHECK(!omacvm_fp_keep(&in), "%s: nothing given yet: not kept", d->name);

        in = keep_in(d, d->frame);
        in.full_screen_style = false;
        CHECK(!omacvm_fp_keep(&in), "%s: windowed: not kept", d->name);

        in = keep_in(d, d->frame);
        in.area_lost = true;
        CHECK(!omacvm_fp_keep(&in), "%s: lost: not kept", d->name);
    }
    OmacVMFPKeepIn ext = keep_in(&externals[0], externals[0].frame);
    CHECK(!omacvm_fp_keep(&ext), "external display: never kept");
}

static void test_strip_lost(void)
{
    const Display *d = &builtins[0];
    CHECK(!omacvm_fp_strip_lost(true, true, d->frame, d->frame), "covering: not lost");
    CHECK(omacvm_fp_strip_lost(true, true, below_notch(d), d->frame), "below the notch: lost");
    CHECK(!omacvm_fp_strip_lost(true, false, below_notch(d), d->frame), "windowed: not a loss");
    /* An external display (or the Mac mini's): letterboxed full screen is no loss. */
    OmacVMFPRect boxed = { 0, 150, 800, 450 }, ext = { 0, 0, 800, 600 };
    CHECK(!omacvm_fp_strip_lost(false, true, boxed, ext), "no notch: nothing to lose");
}

/*
 * A window moving between displays (the displays patch makes one window per
 * display; a display plugged in or out moves them): each display decides
 * for itself, and the decision follows the window's display at once.
 */
static void test_moves(void)
{
    const Display *path[] = { &builtins[0], &externals[0], &builtins[4], &externals[1], &builtins[0] };
    for (size_t i = 0; i < sizeof path / sizeof path[0]; i++) {
        const Display *d = path[i];
        OmacVMFPFrameIn in = frame_in(d, d->frame, false);
        OmacVMFPFrame want = d->notch > 0 ? OMACVM_FP_DISPLAY : OMACVM_FP_APPKIT;
        CHECK(omacvm_fp_frame(&in) == want, "move %zu to %s", i, d->name);
    }
}

static void test_reveal(void)
{
    const Display *d = &builtins[0];
    double top = d->frame.y + d->frame.h, notch = d->notch;
    bool allowed = false;

    allowed = omacvm_fp_reveal_allowed(allowed, false, top - 200, top, notch);
    CHECK(!allowed, "pointer in the VM: menu bar held back");
    allowed = omacvm_fp_reveal_allowed(allowed, false, top - 10, top, notch);
    CHECK(!allowed, "pointer in the strip: still held back");
    allowed = omacvm_fp_reveal_allowed(allowed, false, top - 0.5, top, notch);
    CHECK(allowed, "pointer at the top row: may come down");
    allowed = omacvm_fp_reveal_allowed(allowed, false, top - 10, top, notch);
    CHECK(allowed, "back in the strip: stays allowed");
    allowed = omacvm_fp_reveal_allowed(allowed, true, top - 300, top, notch);
    CHECK(allowed, "menu open: stays while the pointer is in a menu");
    allowed = omacvm_fp_reveal_allowed(allowed, false, top - notch - 1, top, notch);
    CHECK(!allowed, "below the strip, menu closed: held back again");
}

int main(void)
{
    test_requested();
    test_display_ok();
    test_frame();
    test_keep();
    test_strip_lost();
    test_moves();
    test_reveal();
    if (failures) {
        printf("test-fullpanel: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test-fullpanel: %d checks passed\n", checks);
    return 0;
}
