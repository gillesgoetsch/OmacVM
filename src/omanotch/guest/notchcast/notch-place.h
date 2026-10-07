// notch-place.h — where notchcast puts the hidden NOTCH output.
//
// No Wayland and no Hyprland in here, so it is tested on its own
// (notch-place-test.c, run by test.sh next to it).
//
// Two places:
//  - ABOVE the built-in display's output, touching its top edge, same x and
//    width. That is where the strip is on the Mac (the VM window sits below
//    the camera in macOS's full screen), and nothing overlaps, so Hyprland
//    shows no "Monitor NOTCH overlaps" warning. Only under OmacVM.app: it
//    maps its pointer by the outputs the guest reports (omacvm-displays),
//    so a layout that grows by the strip keeps the pointer exact.
//  - OVER the output's top edge (the old place): Parallels, UTM and Fusion
//    map their absolute pointer onto the box around all outputs, which must
//    not change; and the fallback when the place above is taken (another
//    display there with no gap for the strip).
#ifndef NOTCH_PLACE_H
#define NOTCH_PLACE_H

#include <stdlib.h>
#include <string.h>

typedef struct { double x, y, w, h; } NotchRect;

#define NOTCH_MAX_OUTPUTS 16

static int notch_overlaps(NotchRect a, NotchRect b) {
    // Touching edges do not count (Hyprland does not warn about them). Half a
    // logical px of slack for scaled sizes.
    const double e = 0.5;
    return a.x + e < b.x + b.w && b.x + e < a.x + a.w && a.y + e < b.y + b.h && b.y + e < a.y + a.h;
}

// The hidden output's place: *x, *y. Returns 1 when it goes above the screen,
// 0 when it overlaps the screen's top edge.
// screen: the built-in display's output (logical px); lh: NOTCH's logical
// height; others: every other enabled output but NOTCH and the screen;
// above_ok: the host maps the pointer by the guest's real layout.
static int notch_place(NotchRect screen, double lh, const NotchRect *others, int n, int above_ok, double *x,
                       double *y) {
    *x = screen.x;
    *y = screen.y;
    if (!above_ok || lh <= 0) return 0;
    NotchRect up = {screen.x, screen.y - lh, screen.w, lh};
    for (int i = 0; i < n; i++)
        if (notch_overlaps(up, others[i])) return 0;
    *y = screen.y - lh;
    return 1;
}

// The screen sits right beside NOTCH, level with it: Hyprland put it there
// by itself (its place is "auto", e.g. right after the first login's config
// reload, before omacvm-display-sync placed it again). Moving NOTCH after it
// would move the screen on again, every 2 s, without end (Air, 2026-10-06).
// screen and notch in logical px.
static int notch_screen_pushed(NotchRect screen, NotchRect notch) {
    double dx = screen.x - (notch.x + notch.w), dy = notch.y + notch.h - screen.y;
    return dx > -1 && dx < 1 && dy > -1 && dy < 1;
}

// The enabled outputs of a `j/monitors all` reply but `skip_a` and `skip_b`,
// in logical px (width / scale; a transform of 90/270 swaps them). Returns
// how many (at most `max`).
static int notch_other_outputs(const char *json, const char *skip_a, const char *skip_b, NotchRect *out, int max) {
    int n = 0;
    const char *key = "\"name\": \"";
    for (const char *p = json ? strstr(json, key) : NULL; p && n < max; p = strstr(p + 1, key)) {
        // The monitor object around this name (activeWorkspace and
        // specialWorkspace have names too: those are nested, one level in).
        const char *start = p;
        int depth = 0;
        while (start > json) {
            start--;
            if (*start == '}') depth++;
            else if (*start == '{' && depth-- == 0) break;
        }
        if (*start != '{') continue;
        // Top-level objects only: the character before `{` (skipping spaces) is `[` or `,`.
        const char *b = start;
        while (b > json && (b[-1] == ' ' || b[-1] == '\n' || b[-1] == '\t' || b[-1] == '\r')) b--;
        if (b == json || (b[-1] != '[' && b[-1] != ',')) continue;
        const char *end = start;
        for (depth = 0; *end; end++) {
            if (*end == '{') depth++;
            else if (*end == '}' && --depth == 0) break;
        }
        const char *nm = p + strlen(key), *q = strchr(nm, '"');
        if (!q || q > end) continue;
        size_t len = (size_t)(q - nm);
        if ((skip_a && strlen(skip_a) == len && !memcmp(nm, skip_a, len)) ||
            (skip_b && strlen(skip_b) == len && !memcmp(nm, skip_b, len)))
            continue;
        double v[6] = {0, 0, 0, 0, 1, 0};  // x y width height scale transform
        const char *fields[6] = {"\"x\": ", "\"y\": ", "\"width\": ", "\"height\": ", "\"scale\": ", "\"transform\": "};
        int disabled = 0;
        // Fields of the monitor itself: skip nested objects while scanning.
        depth = 0;
        for (const char *c = start; c < end; c++) {
            if (*c == '{') { depth++; continue; }
            if (*c == '}') { depth--; continue; }
            if (depth != 1) continue;
            for (int f = 0; f < 6; f++) {
                size_t fl = strlen(fields[f]);
                if (!strncmp(c, fields[f], fl)) v[f] = strtod(c + fl, NULL);
            }
            if (!strncmp(c, "\"disabled\": true", 16)) disabled = 1;
        }
        if (disabled || v[2] <= 0 || v[3] <= 0) continue;
        double s = v[4] > 0 ? v[4] : 1, w = v[2] / s, h = v[3] / s;
        if (((int)v[5]) % 2) { double t = w; w = h; h = t; }
        out[n++] = (NotchRect){v[0], v[1], w, h};
    }
    return n;
}

// Whether notchcast masks the guest cursor in a captured NOTCH frame (it
// restores those pixels from the previous frame, so the strip never shows a
// cursor the Mac draws itself). Only while the hotspot is on NOTCH: a cursor
// on the display below that reaches up into NOTCH is drawn there by Hyprland,
// which also repaints NOTCH when it moves away. Masking it froze the strip
// under it: hiding the bar left a box of the old bar at the strip's end. Not
// while notchcast keeps the cursor hidden either (hidden_ms > 300: the first
// frame after hiding may still show it).
static inline int notch_cursor_masked(NotchRect out, double cx, double cy, double hidden_ms) {
    if (hidden_ms > 300) return 0;
    return cx >= out.x && cx < out.x + out.w && cy >= out.y && cy < out.y + out.h;
}

#endif
