/*
 * The guest's pointer as the Mac's cursor (ui/omacvm-hw-cursor.h, made by
 * omacvm-cocoa-hw-cursor-logic.patch): when the Mac's cursor carries the
 * guest's image, when it is empty, when QEMU's own pointer layer shows, and
 * the checks on the guest's image. A small model of ui/cocoa.m's
 * omacvmUpdateMacCursor runs the cases a VM goes through.
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "omacvm-hw-cursor.h"

static int failures, checks;

#define CHECK(cond, ...) do {                                   \
        checks++;                                               \
        if (!(cond)) {                                          \
            failures++;                                         \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);         \
            printf(__VA_ARGS__);                                \
            printf("\n");                                       \
        }                                                       \
    } while (0)

/* What the Mac shows over the VM, as ui/cocoa.m decides it. */
enum mac { ARROW, HIDDEN, GUEST_IMAGE, EMPTY };

static enum mac mac_cursor(const OmacVMHwCursor *c, bool grabbed, bool absolute,
                           bool old_hide)
{
    if (grabbed && omacvm_hwc_active(c, absolute)) {
        return omacvm_hwc_visible(c) ? GUEST_IMAGE : EMPTY;
    }
    return old_hide ? HIDDEN : ARROW;
}

static void test_off(void)
{
    OmacVMHwCursor c = { 0 };

    /* Off (the default): nothing changes, whatever the guest sends. */
    omacvm_hwc_define(&c, 0);
    omacvm_hwc_show(&c, 0, true);
    CHECK(!c.shape, "off: an image does not count");
    CHECK(!omacvm_hwc_active(&c, true), "off: never active");
    CHECK(mac_cursor(&c, true, true, true) == HIDDEN, "off: the old hide decision stays");
    CHECK(mac_cursor(&c, true, true, false) == ARROW, "off: the old show decision stays");
    CHECK(!omacvm_hwc_layer_hidden(&c, true) && !omacvm_hwc_layer_hidden(&c, false),
          "off: QEMU's pointer layer as upstream");
}

static void test_start_and_reset(void)
{
    OmacVMHwCursor c = { .on = true };

    /* Boot: no image yet (firmware, boot, a guest with a software cursor): as before. */
    CHECK(!omacvm_hwc_active(&c, true), "no image yet: not active");
    CHECK(mac_cursor(&c, true, true, true) == HIDDEN, "no image yet: hidden as before (guest draws)");
    CHECK(mac_cursor(&c, true, true, false) == ARROW, "no image yet: shown as before (booting)");
    CHECK(!omacvm_hwc_layer_hidden(&c, true),
          "no image yet (or refused): QEMU's layer as before, the pointer stays visible");
    /* Hyprland puts its pointer on the plane. */
    omacvm_hwc_define(&c, 0);
    omacvm_hwc_show(&c, 0, true);
    CHECK(omacvm_hwc_active(&c, true), "image: active");
    CHECK(mac_cursor(&c, true, true, true) == GUEST_IMAGE,
          "image: the Mac's cursor shows it, even where the old way hid the cursor");
    CHECK(mac_cursor(&c, false, true, false) == ARROW, "not grabbed: the arrow");
    /* A reset: back to the old way until the next image. */
    omacvm_hwc_reset(&c);
    CHECK(!omacvm_hwc_active(&c, true) && !omacvm_hwc_visible(&c), "reset: not active, nothing shown");
    CHECK(mac_cursor(&c, true, true, false) == ARROW, "reset: the old way while it boots");
    CHECK(!omacvm_hwc_layer_hidden(&c, true), "reset: QEMU's layer as before");
    omacvm_hwc_define(&c, 0);
    omacvm_hwc_show(&c, 0, true);
    CHECK(mac_cursor(&c, true, true, true) == GUEST_IMAGE, "after reset: the image again");
}

static void test_hide_and_outputs(void)
{
    OmacVMHwCursor c = { .on = true };

    omacvm_hwc_define(&c, 0);
    omacvm_hwc_show(&c, 0, true);
    /* Hyprland hides the pointer while typing: empty, not the arrow, not the old hide. */
    omacvm_hwc_show(&c, 0, false);
    CHECK(mac_cursor(&c, true, true, false) == EMPTY, "guest hides it: empty cursor");
    omacvm_hwc_show(&c, 0, true);
    CHECK(mac_cursor(&c, true, true, false) == GUEST_IMAGE, "shown again");
    /* To the second output: shown there first, then hidden on the first (or the other way). */
    omacvm_hwc_define(&c, 1);
    omacvm_hwc_show(&c, 1, true);
    omacvm_hwc_show(&c, 0, false);
    CHECK(mac_cursor(&c, true, true, false) == GUEST_IMAGE, "moved to output 1: still the image");
    omacvm_hwc_show(&c, 0, true);
    omacvm_hwc_show(&c, 1, false);
    CHECK(mac_cursor(&c, true, true, false) == GUEST_IMAGE, "back on output 0: still the image");
    omacvm_hwc_show(&c, 0, false);
    CHECK(mac_cursor(&c, true, true, false) == EMPTY, "hidden on every output: empty");
    /* Out-of-range outputs change nothing. */
    omacvm_hwc_show(&c, 32, true);
    omacvm_hwc_show(&c, -1, true);
    CHECK(!omacvm_hwc_visible(&c), "output 32 / -1 ignored");
}

static void test_relative(void)
{
    OmacVMHwCursor c = { .on = true };

    omacvm_hwc_define(&c, 0);
    omacvm_hwc_show(&c, 0, true);
    /* A game asks for a relative pointer: QEMU's own way (held and hidden, layer drawn). */
    CHECK(!omacvm_hwc_active(&c, false), "relative: not active");
    CHECK(mac_cursor(&c, true, false, true) == HIDDEN, "relative: the old decision (hidden)");
    CHECK(!omacvm_hwc_layer_hidden(&c, false), "relative: QEMU's layer draws the guest's image");
    CHECK(omacvm_hwc_layer_hidden(&c, true), "absolute: no second pointer in QEMU's layer");
}

static bool near(double a, double b)
{
    return fabs(a - b) < 1e-9;
}

static void test_image(void)
{
    OmacVMHwcImage im;

    /* Retina window: 2 guest pixels a point. */
    im = omacvm_hwc_image(64, 64, 6, 4, 0.5);
    CHECK(im.ok && near(im.w, 32) && near(im.h, 32) && near(im.hot_x, 3) && near(im.hot_y, 2),
          "64x64 hot 6,4 at 0.5: 32x32 pt hot 3,2 (got %d %.2fx%.2f %.2f,%.2f)",
          im.ok, im.w, im.h, im.hot_x, im.hot_y);
    /* An external display at 1 point a pixel. */
    im = omacvm_hwc_image(64, 64, 0, 0, 1.0);
    CHECK(im.ok && near(im.w, 64), "64x64 at 1.0: 64 pt");
    /* Hot spot outside the image (guest-controlled): kept inside. */
    im = omacvm_hwc_image(64, 64, 500, -3, 1.0);
    CHECK(im.ok && near(im.hot_x, 63) && near(im.hot_y, 0), "hot spot clamped (got %.1f,%.1f)",
          im.hot_x, im.hot_y);
    im = omacvm_hwc_image(64, 64, (int)0x80000000u, (int)0xffffffffu, 1.0);
    CHECK(im.ok && near(im.hot_x, 0) && near(im.hot_y, 0), "hot spot from huge u32 values clamped");
    /* Sizes the Mac must not get. */
    CHECK(!omacvm_hwc_image(0, 64, 0, 0, 1).ok, "zero width refused");
    CHECK(!omacvm_hwc_image(64, -1, 0, 0, 1).ok, "negative height refused");
    CHECK(!omacvm_hwc_image(257, 64, 0, 0, 1).ok, "257 wide refused");
    CHECK(omacvm_hwc_image(256, 256, 0, 0, 1).ok, "256x256 allowed");
    /* Scales that make no sense (no window yet, zero width output). */
    CHECK(!omacvm_hwc_image(64, 64, 0, 0, 0).ok, "scale 0 refused");
    CHECK(!omacvm_hwc_image(64, 64, 0, 0, NAN).ok, "scale NaN refused");
    CHECK(!omacvm_hwc_image(64, 64, 0, 0, INFINITY).ok, "scale inf refused");
    CHECK(!omacvm_hwc_image(64, 64, 0, 0, 9).ok, "scale 9 refused");
}

int main(void)
{
    test_off();
    test_start_and_reset();
    test_hide_and_outputs();
    test_relative();
    test_image();
    printf("test-hw-cursor: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
