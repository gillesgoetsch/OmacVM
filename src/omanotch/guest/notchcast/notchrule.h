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

// The strip's height (`mac_h` points on a display `mac_w` points wide) in
// logical px of the guest's built-in display (`sw` px wide at scale `ss`).
static inline double strip_logical(double mac_h, double mac_w, double sw, double ss) {
    return mac_w > 0 && ss > 0 ? mac_h * (sw / ss) / mac_w : 0;
}

// Hyprland's monitor rule (Lua) for the hidden output, right above the
// display at (sx, sy).
static inline void notch_rule_lua(char *out, size_t size, const char *output, int w, int h, int sx, int sy,
                                  double ss) {
    snprintf(out, size, "hl.monitor({ output = \"%s\", mode = \"%dx%d@60\", position = \"%dx%d\", scale = %.6f })",
             output, w, h, sx, sy, ss);
}

// When the keeper sends NOTCH's rule (hyprctl eval) again. A new rule goes
// at once. The same rule as last time goes at once too when NOTCH was seen
// as that rule wants since it was sent: something else moved NOTCH after it
// took (a config reload with notchbar.lua's older rule, another eval), and
// waiting would leave the strip wrong. Not seen so yet (the move came before
// the keeper's next look, or Hyprland keeps refusing or changing the rule):
// again at the next look, then after waits doubling up to 30 s (1.5, 3, 6,
// 12, 24, 30, 30 ... s; the keeper looks every 2 s). Never more than
// NOTCH_RULE_BURST sends of one rule in 30 s, so something that keeps moving
// NOTCH back is not chased every look (each send reconfigures the monitor).
#define NOTCH_RULE_RETRY_MS 30000
#define NOTCH_RULE_FIRST_MS 1500   // the keeper's next look (it looks every 2 s)
#define NOTCH_RULE_BURST 4
typedef struct {
    char sent[256];      // the rule sent last
    double sent_ms;      // when
    int held;            // NOTCH was seen as `sent` wants since then
    int unseen;          // sends of `sent` in a row without that
    double window_ms;    // the first send of `sent` in the current 30 s
    int window_sends;    // sends of `sent` since window_ms
} NotchRuleState;

static inline int notch_rule_due(const NotchRuleState *st, const char *lua, double now_ms) {
    if (strcmp(lua, st->sent)) return 1;
    if (st->window_sends >= NOTCH_RULE_BURST && now_ms - st->window_ms < NOTCH_RULE_RETRY_MS) return 0;
    if (st->held) return 1;
    double wait = NOTCH_RULE_FIRST_MS;
    for (int i = 1; i < st->unseen && wait < NOTCH_RULE_RETRY_MS; i++) wait *= 2;
    return now_ms - st->sent_ms >= (wait < NOTCH_RULE_RETRY_MS ? wait : NOTCH_RULE_RETRY_MS);
}

static inline void notch_rule_sent(NotchRuleState *st, const char *lua, double now_ms) {
    if (strcmp(lua, st->sent)) {
        snprintf(st->sent, sizeof st->sent, "%s", lua);
        st->unseen = 0;
        st->window_sends = 0;
        st->window_ms = now_ms;
    }
    if (now_ms - st->window_ms >= NOTCH_RULE_RETRY_MS) {
        st->window_ms = now_ms;
        st->window_sends = 0;
    }
    st->window_sends++;
    st->unseen = st->held ? 1 : st->unseen + 1;
    st->held = 0;
    st->sent_ms = now_ms;
}

// NOTCH is as `lua` wants (the keeper's look found nothing to change).
static inline void notch_rule_seen(NotchRuleState *st, const char *lua) {
    if (!strcmp(lua, st->sent)) {
        st->held = 1;
        st->unseen = 0;
    }
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

// /run/omacvm/host.env (what OmacVM.app tells the VM at start): how the
// guest's own cursor goes while the pointer is on the strip.
//  - HOST_CURSOR_STAYS (OMACVM_HWCURSOR=1): the Mac's cursor shows the
//    guest's pointer, so there is only one cursor: never hidden, never moved.
//  - HOST_CURSOR_PARKED (OMACVM_NOTCHPOINTER=1): the app moves the guest's
//    pointer up into NOTCH (out of sight) in the same moment the Mac's
//    pointer leaves for the strip, and back with the next motion over the
//    VM. Hiding it through Hyprland's cursor:invisible lagged by its tick
//    (85-540 ms): two arrows on the way up, none on the way back. Never
//    moved; hidden only when it did not get to NOTCH (notchcast checks).
//  - HOST_CURSOR_HIDES: hidden for the strip, shown again at the exit point
//    (older apps, the retired VM apps).
enum { HOST_CURSOR_HIDES = 0, HOST_CURSOR_STAYS = 1, HOST_CURSOR_PARKED = 2 };

static inline int host_env_cursor(FILE *f) {
    char line[128];
    int hw = 0, parked = 0;
    while (f && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strcmp(line, "OMACVM_HWCURSOR=1")) hw = 1;
        if (!strcmp(line, "OMACVM_NOTCHPOINTER=1")) parked = 1;
    }
    return hw ? HOST_CURSOR_STAYS : parked ? HOST_CURSOR_PARKED : HOST_CURSOR_HIDES;
}

// The guest's pointer (cx, cy) is on NOTCH (x, y, w, h: logical px).
static inline int pointer_on_box(double cx, double cy, double x, double y, double w, double h) {
    return w > 0 && h > 0 && cx >= x && cx < x + w && cy >= y && cy < y + h;
}

#endif
