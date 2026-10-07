// Tests notch-place.h: where notchcast puts the hidden NOTCH output.
// cc -I../notchcast notch-place-test.c && ./a.out
#include <stdio.h>
#include "notch-place.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } else printf("ok   " __VA_ARGS__), printf("\n"); } while (0)

// The user's layout on 2026-10-06 10:16 (MacBook in native full screen below
// the camera, 6K above it): `hyprctl -j monitors all`, trimmed.
static const char *user_json =
    "[{\n \"id\": 0,\n \"name\": \"Virtual-1\",\n \"description\": \"Red Hat Inc. QEMU Monitor\",\n"
    " \"width\": 4112,\n \"height\": 2572,\n \"x\": 492,\n \"y\": 1735,\n"
    " \"activeWorkspace\": {\n  \"id\": 1,\n  \"name\": \"1\"\n },\n"
    " \"specialWorkspace\": {\n  \"id\": 0,\n  \"name\": \"\"\n },\n"
    " \"reserved\": [0, 0, 0, 0],\n \"scale\": 2.00,\n \"transform\": 0,\n \"disabled\": false\n},"
    "{\n \"id\": 1,\n \"name\": \"NOTCH\",\n \"width\": 4112,\n \"height\": 86,\n \"x\": 492,\n \"y\": 1735,\n"
    " \"activeWorkspace\": {\n  \"id\": -98,\n  \"name\": \"name:notch\"\n },\n \"scale\": 2.00,\n \"transform\": 0,\n"
    " \"disabled\": false\n},"
    "{\n \"id\": 2,\n \"name\": \"Virtual-2\",\n \"width\": 6016,\n \"height\": 3384,\n \"x\": 0,\n \"y\": 0,\n"
    " \"activeWorkspace\": {\n  \"id\": 2,\n  \"name\": \"2\"\n },\n \"scale\": 2.00,\n \"transform\": 0,\n"
    " \"disabled\": false\n},"
    "{\n \"id\": 3,\n \"name\": \"Virtual-3\",\n \"width\": 1920,\n \"height\": 1080,\n \"x\": 9000,\n \"y\": 0,\n"
    " \"scale\": 1.00,\n \"transform\": 0,\n \"disabled\": true\n}]";

int main(void) {
    NotchRect o[NOTCH_MAX_OUTPUTS];
    int n = notch_other_outputs(user_json, "NOTCH", "Virtual-1", o, NOTCH_MAX_OUTPUTS);
    CHECK(n == 1, "parse: only Virtual-2 is another enabled output (got %d)", n);
    CHECK(n >= 1 && o[0].x == 0 && o[0].y == 0 && o[0].w == 3008 && o[0].h == 1692,
          "parse: Virtual-2 is 3008x1692 logical at 0,0");
    n = notch_other_outputs(user_json, "NOTCH", NULL, o, NOTCH_MAX_OUTPUTS);
    CHECK(n == 2, "parse: Virtual-1 and Virtual-2 when only NOTCH is skipped (got %d)", n);

    double x, y;
    NotchRect v1 = {492, 1735, 2056, 1286};
    n = notch_other_outputs(user_json, "NOTCH", "Virtual-1", o, NOTCH_MAX_OUTPUTS);
    int up = notch_place(v1, 43, o, n, 1, &x, &y);
    CHECK(up == 1 && x == 492 && y == 1692, "user layout, OmacVM.app: NOTCH right above Virtual-1 at 492x1692 (got %d %gx%g)", up, x, y);
    NotchRect notch = {x, y, 2056, 43};
    CHECK(!notch_overlaps(notch, v1) && !notch_overlaps(notch, o[0]), "user layout: NOTCH overlaps neither display");
    CHECK(notch.y + notch.h == v1.y && notch.y == o[0].y + o[0].h, "user layout: NOTCH fills the 43 px gap exactly");

    up = notch_place(v1, 43, o, n, 0, &x, &y);
    CHECK(up == 0 && x == 492 && y == 1735, "Parallels/UTM/Fusion: over the top edge as before (got %gx%g)", x, y);

    NotchRect alone = {0, 0, 1728, 1085};
    up = notch_place(alone, 32, NULL, 0, 1, &x, &y);
    CHECK(up == 1 && x == 0 && y == -32, "one display, OmacVM.app: above it at 0x-32 (got %gx%g)", x, y);

    NotchRect ext = {0, 0, 3008, 1692};
    NotchRect tight = {492, 1700, 2056, 1286};  // no room for 43 px above
    up = notch_place(tight, 43, &ext, 1, 1, &x, &y);
    CHECK(up == 0 && y == 1700, "place above taken by the external: over the top edge (fallback)");

    NotchRect beside = {2056, 0, 1920, 1080};  // a display to the right touches the strip's corner only
    up = notch_place(alone, 32, &beside, 1, 1, &x, &y);
    CHECK(up == 1, "a display beside the screen does not block the place above");

    // The first-login loop (Air, 2026-10-06): NOTCH right above Virtual-1,
    // then a config reload put Virtual-1 ("auto") right beside NOTCH.
    NotchRect air_notch = {0, -33, 1470, 33}, air_v1 = {1470, 0, 1470, 919};
    CHECK(notch_screen_pushed(air_v1, air_notch), "screen pushed right of NOTCH: seen (do not follow it)");
    NotchRect air_notch2 = {23520, -33, 1470, 33}, air_v1b = {24990, 0, 1470, 919};
    CHECK(notch_screen_pushed(air_v1b, air_notch2), "the same far to the right: seen");
    NotchRect air_v1_ok = {0, 0, 1470, 919};
    CHECK(!notch_screen_pushed(air_v1_ok, air_notch), "NOTCH right above the screen: normal");
    NotchRect v2_beside = {1470, 100, 1920, 1080};
    CHECK(!notch_screen_pushed(v2_beside, air_notch), "a display beside, lower down: not this case");
    NotchRect scaled_v1 = {1470.4, 0, 1470, 919};
    CHECK(notch_screen_pushed(scaled_v1, air_notch), "scaled sizes: half a px off still counts");

    // Cursor masking (Air layout: Virtual-1 at 0x0, NOTCH 1470x33 at 0x-33).
    NotchRect strip = {0, -33, 1470, 33};
    CHECK(notch_cursor_masked(strip, 700, -10, 0), "cursor on NOTCH, shown: masked");
    CHECK(!notch_cursor_masked(strip, 1469, 0, 0), "cursor on the display's top row: not masked (no frozen box)");
    CHECK(!notch_cursor_masked(strip, 1469, 0, 5000), "cursor left hidden below the strip: not masked");
    CHECK(!notch_cursor_masked(strip, 700, -10, 5000), "cursor on NOTCH, hidden by notchcast: not masked");
    CHECK(notch_cursor_masked(strip, 700, -10, 100), "cursor just hidden: still masked (the next frame may still show it)");
    CHECK(!notch_cursor_masked(strip, 1470, -10, 0), "cursor beside NOTCH: not masked");
    NotchRect over = {0, 0, 1470, 33};  // Parallels/UTM: NOTCH over the top edge
    CHECK(notch_cursor_masked(over, 20, 5, 0), "overlap layout: cursor in the top rows masked as before");

    printf("%s\n", fails ? "notch-place: FAILED" : "notch-place: all ok");
    return fails != 0;
}
