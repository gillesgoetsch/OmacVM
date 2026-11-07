/*
 * FullPanel armed late (ui/omacvm-fullpanel-late.h,
 * omacvm-cocoa-fullpanel-late-arm.patch, #716): the rules. The window's
 * state with a late entry (the lid closed at the start, then opened) is
 * replayed in test-fullpanel-retake.c.
 */
#include <stdio.h>
#include <string.h>

#include "omacvm-fullpanel-late.h"

static int failures, checks;

#define CHECK(c) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void)
{
    double w = 0, h = 0;

    /* A display with a housing and every part: the strip now (the main window or another). */
    CHECK(omacvm_fp_entry(OMACVM_FP_OK, OMACVM_FP_OK, true) == OMACVM_FP_ENTRY_ARM);
    CHECK(omacvm_fp_entry(OMACVM_FP_OK, OMACVM_FP_OK, false) == OMACVM_FP_ENTRY_ARM);
    /* The main window without a housing, every other part there: late. */
    CHECK(omacvm_fp_entry(OMACVM_FP_NO_NOTCH, OMACVM_FP_OK, true) == OMACVM_FP_ENTRY_LATE);
    /* The other displays' windows are made again per display: normal full screen, as before. */
    CHECK(omacvm_fp_entry(OMACVM_FP_NO_NOTCH, OMACVM_FP_OK, false) == OMACVM_FP_ENTRY_NORMAL);
    CHECK(omacvm_fp_entry_why(OMACVM_FP_NO_NOTCH, OMACVM_FP_OK, false) == OMACVM_FP_NO_NOTCH);
    /* Another part missing: never late; the line names that part for the main window. */
    for (OmacVMFPFallback f = OMACVM_FP_MENU_BAR_SHOWN; f <= OMACVM_FP_NO_SKYLIGHT; f++) {
        CHECK(omacvm_fp_entry(OMACVM_FP_NO_NOTCH, f, true) == OMACVM_FP_ENTRY_NORMAL);
        CHECK(omacvm_fp_entry_why(OMACVM_FP_NO_NOTCH, f, true) == f);
        CHECK(omacvm_fp_entry_why(OMACVM_FP_NO_NOTCH, f, false) == OMACVM_FP_NO_NOTCH);
        /* ... and on a display with a housing, as before. */
        CHECK(omacvm_fp_entry(f, f, true) == OMACVM_FP_ENTRY_NORMAL);
        CHECK(omacvm_fp_entry_why(f, f, true) == f);
    }

    /* didEnterFullScreen: entered with the strip, or armed late; never unarmed. */
    CHECK(omacvm_fp_entered(true, true, false));
    CHECK(omacvm_fp_entered(true, false, true));
    CHECK(!omacvm_fp_entered(true, false, false));
    CHECK(!omacvm_fp_entered(false, true, true));
    CHECK(!omacvm_fp_entered(false, false, true));

    /* The panel this start's notch was measured on: "WxD" in points. */
    CHECK(omacvm_fp_panel("1728x1117", &w, &h) && w == 1728 && h == 1117);
    CHECK(omacvm_fp_panel("1512.0x982.0", &w, &h) && w == 1512 && h == 982);
    w = h = 7;
    CHECK(!omacvm_fp_panel(NULL, &w, &h) && !omacvm_fp_panel("", &w, &h));
    CHECK(!omacvm_fp_panel("1728", &w, &h) && !omacvm_fp_panel("1728x", &w, &h));
    CHECK(!omacvm_fp_panel("x1117", &w, &h) && !omacvm_fp_panel("1728x1117x", &w, &h));
    CHECK(!omacvm_fp_panel("1728x1117 ", &w, &h) && !omacvm_fp_panel("1728,1117", &w, &h));
    CHECK(!omacvm_fp_panel("0x0", &w, &h) && !omacvm_fp_panel("-1728x1117", &w, &h));
    CHECK(!omacvm_fp_panel("nanx1117", &w, &h) && !omacvm_fp_panel("1728xinf", &w, &h));
    CHECK(!omacvm_fp_panel("99x1117", &w, &h) && !omacvm_fp_panel("1728x30000", &w, &h));
    CHECK(w == 7 && h == 7);   /* untouched when not a size */

    /* A late full screen takes the strip only on that panel's size (half a point). */
    CHECK(omacvm_fp_late_fits(true, true, 1728, 1117, 1728, 1117));
    CHECK(omacvm_fp_late_fits(true, true, 1728, 1117, 1728.4, 1116.6));
    CHECK(!omacvm_fp_late_fits(true, true, 1728, 1117, 2056, 1329));
    CHECK(!omacvm_fp_late_fits(true, true, 1728, 1117, 1728, 1084));
    CHECK(!omacvm_fp_late_fits(true, true, 1728, 1117, 0, 0));
    /* Not late, or no size given (an older app): anything fits. */
    CHECK(omacvm_fp_late_fits(false, true, 1728, 1117, 2056, 1329));
    CHECK(omacvm_fp_late_fits(true, false, 0, 0, 2056, 1329));

    if (failures) {
        printf("test-fullpanel-late-arm: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("ok   %d rule checks\n", checks);
    return 0;
}
