// notchrule.h: small pure helpers of notchcast, kept apart so they can be
// tested offline (src/omanotch/guest/tests/test.sh) without Wayland.
#ifndef NOTCHRULE_H
#define NOTCHRULE_H

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The hidden output's mode in pixels: as wide as the built-in display
// (`sw` px at scale `ss`), and `logical_h` logical px tall, rounded up to a
// whole number of logical px that is also a whole number of pixels at this
// scale (fractional scales such as 1.6 or 5/3). Returns that logical height.
static inline int notch_mode(double sw, double ss, double logical_h, int *w, int *h) {
    int lh = (int)ceil(logical_h - 1e-6);
    for (int k = 0; k < 120 && fabs(lh * ss - round(lh * ss)) > 1e-3; k++) lh++;
    *w = (int)(sw + 0.5);
    *h = (int)round(lh * ss);
    return lh;
}

// Hyprland's monitor rule (Lua) for the hidden output, right above the
// display at (sx, sy).
static inline void notch_rule_lua(char *out, size_t size, const char *output, int w, int h, int sx, int sy,
                                  double ss) {
    snprintf(out, size, "hl.monitor({ output = \"%s\", mode = \"%dx%d@60\", position = \"%dx%d\", scale = %.6f })",
             output, w, h, sx, sy, ss);
}

// The tallest layer surface of namespace `ns` on the output `output` in a
// `j/layers` reply, in logical px; 0: none there, or none with a size yet.
// The search is limited to that output's own JSON object (brace-matched).
static inline int layer_height_on_output(const char *json, const char *output, const char *ns) {
    char pat[128];
    snprintf(pat, sizeof pat, "\"%s\":", output);
    const char *p = json ? strstr(json, pat) : NULL;
    if (!p) return 0;
    const char *start = strchr(p + strlen(pat), '{');
    if (!start) return 0;
    int depth = 0;
    const char *end = start;
    for (; *end; end++) {
        if (*end == '{') depth++;
        else if (*end == '}' && --depth == 0) break;
    }
    snprintf(pat, sizeof pat, "\"namespace\": \"%s\"", ns);
    size_t plen = strlen(pat);
    int best = 0;
    for (const char *q = start; q + plen <= end; q++) {
        if (memcmp(q, pat, plen)) continue;
        // The surface's own object: from its '{' to here, for "w"/"h".
        const char *o = q;
        while (o > start && *o != '{') o--;
        const char *w = strstr(o, "\"w\": "), *h = strstr(o, "\"h\": ");
        if (w && h && w < q && h < q && atoi(w + 5) > 0 && atoi(h + 5) > best) best = atoi(h + 5);
    }
    return best;
}

// Whether such a surface is there with a size (the bar copy exists and is laid out).
static inline int layer_on_output(const char *json, const char *output, const char *ns) {
    return layer_height_on_output(json, output, ns) > 0;
}

// The geometry file the bar reads when it starts (bar patch v17+):
// "left right strip bar" in the built-in display's logical px. Empty values
// are "0" (not known yet).
static inline void geom_line(char *out, size_t size, const char *l, const char *r, const char *strip,
                             const char *bar) {
    snprintf(out, size, "%s %s %s %s\n", *l ? l : "0", *r ? r : "0", *strip ? strip : "0", *bar ? bar : "0");
}

#endif
