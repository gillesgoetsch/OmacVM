// Offline tests for notchcast's pure helpers (notchrule.h). Run: ./test.sh
#include "notchrule.h"

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { failures++; printf("FAIL line %d: %s\n", __LINE__, what); } } while (0)

// `hyprctl -j layers` as Hyprland 0.56 prints it (shortened): the bar on both outputs.
static const char *LAYERS =
    "{\n\"Virtual-1\": {\n    \"levels\": {\n\n        \"0\": [\n                {\n"
    "                    \"address\": \"0xaaaac581bf30\",\n                    \"x\": 0,\n"
    "                    \"y\": 0,\n                    \"w\": 1088,\n                    \"h\": 612,\n"
    "                    \"alpha\": 1,\n                    \"namespace\": \"omarchy-background\",\n"
    "                    \"pid\": 872\n                }\n        ],\n        \"2\": [\n                {\n"
    "                    \"address\": \"0xaaaac58a9770\",\n                    \"x\": 0,\n"
    "                    \"y\": 0,\n                    \"w\": 1088,\n                    \"h\": 26,\n"
    "                    \"alpha\": 1,\n                    \"namespace\": \"omarchy-bar\",\n"
    "                    \"pid\": 872\n                }\n        ]\n    }\n},\"NOTCH\": {\n    \"levels\": {\n\n"
    "        \"3\": [\n                {\n                    \"address\": \"0xaaaac59aba40\",\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1088,\n"
    "                    \"h\": 33,\n                    \"alpha\": 1,\n"
    "                    \"namespace\": \"omarchy-background\",\n                    \"pid\": 872\n"
    "                },                {\n                    \"address\": \"0xaaaac58383e0\",\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1088,\n"
    "                    \"h\": 33,\n                    \"alpha\": 1,\n"
    "                    \"namespace\": \"omarchy-bar\",\n                    \"pid\": 872\n"
    "                }\n        ]\n    }\n}\n}\n";

// NOTCH just made: only the wallpaper copy there yet, the bar on Virtual-1.
static const char *LAYERS_NO_BAR =
    "{\n\"Virtual-1\": {\n    \"levels\": {\n        \"2\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": 0,\n                    \"w\": 1470,\n"
    "                    \"h\": 26,\n                    \"namespace\": \"omarchy-bar\"\n                }\n"
    "        ]\n    }\n},\"NOTCH\": {\n    \"levels\": {\n        \"3\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1470,\n"
    "                    \"h\": 33,\n                    \"namespace\": \"omarchy-background\"\n                }\n"
    "        ]\n    }\n}\n}\n";

// The bar's surface on NOTCH before it has a size.
static const char *LAYERS_UNSIZED =
    "{\n\"NOTCH\": {\n    \"levels\": {\n        \"3\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": 0,\n                    \"w\": 0,\n"
    "                    \"h\": 0,\n                    \"namespace\": \"omarchy-bar\"\n                }\n"
    "        ]\n    }\n}\n}\n";

int main(void) {
    int w, h, lh;
    char buf[256];

    // The Air (1470x923 pt at scale 2, strip 33 pt): 2940x66 px.
    lh = notch_mode(2940, 2, 33, &w, &h);
    CHECK(w == 2940 && h == 66 && lh == 33, "air: 2940x66");
    // Fractional scale 1.6: 26 logical px is 41.6 px, so 30 (48 px).
    lh = notch_mode(2048, 1.6, 26, &w, &h);
    CHECK(lh == 30 && h == 48, "scale 1.6: whole pixels");
    // A strip height a hair over a whole number does not grow by one.
    lh = notch_mode(2940, 2, 33.0000001, &w, &h);
    CHECK(lh == 33, "rounding noise");

    // NOTCH is never shorter than the strip (the strip is not rounded down
    // first): 14-inch, 16-inch and Air at their default resolution, every
    // scale; whole pixels tall.
    {
        const double macs[][3] = {{37, 1512, 3024}, {37, 1728, 3456}, {33, 1470, 2940}, {37, 1512, 3600}};
        const double scales[] = {1, 1.25, 1.5, 1.6, 5.0 / 3, 1.75, 2};
        for (size_t m = 0; m < sizeof macs / sizeof macs[0]; m++)
            for (size_t i = 0; i < sizeof scales / sizeof scales[0]; i++) {
                double ss = scales[i], strip = strip_logical(macs[m][0], macs[m][1], macs[m][2], ss);
                lh = notch_mode(macs[m][2], ss, strip, &w, &h);
                CHECK(lh >= strip - 1e-6 && fabs(h - lh * ss) < 1e-3, "NOTCH covers the strip in whole pixels");
            }
        CHECK(fabs(strip_logical(37, 1728, 3456, 1.6) - 46.25) < 1e-9, "16-inch at 1.6: 46.25 logical px");
    }

    notch_rule_lua(buf, sizeof buf, "NOTCH", 2940, 66, 0, 0, 2);
    CHECK(!strcmp(buf, "hl.monitor({ output = \"NOTCH\", mode = \"2940x66@60\", position = \"0x0\", scale = 2.000000 })"),
          "monitor rule");

    CHECK(layer_on_output(LAYERS, "NOTCH", "omarchy-bar"), "bar on NOTCH");
    CHECK(layer_on_output(LAYERS, "Virtual-1", "omarchy-bar"), "bar on Virtual-1");
    CHECK(!layer_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-bar"), "only the wallpaper on NOTCH");
    CHECK(layer_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-background"), "the wallpaper on NOTCH");
    CHECK(!layer_on_output(LAYERS_UNSIZED, "NOTCH", "omarchy-bar"), "no size yet");
    CHECK(!layer_on_output(LAYERS, "NOTCH2", "omarchy-bar"), "other output");
    CHECK(!layer_on_output("{}", "NOTCH", "omarchy-bar"), "no outputs");
    CHECK(!layer_on_output(NULL, "NOTCH", "omarchy-bar"), "no reply");
    CHECK(layer_height_on_output(LAYERS, "NOTCH", "omarchy-bar") == 33, "bar height on NOTCH");
    CHECK(layer_height_on_output(LAYERS, "Virtual-1", "omarchy-bar") == 26, "bar height on Virtual-1");
    CHECK(layer_height_on_output(LAYERS_UNSIZED, "NOTCH", "omarchy-bar") == 0, "no size: 0");
    CHECK(layer_height_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-bar") == 0, "no bar: 0");

    geom_line(buf, sizeof buf, "646", "825", "33", "0");
    CHECK(!strcmp(buf, "646 825 33 0\n"), "geom line");
    geom_line(buf, sizeof buf, "646", "825", "", "");
    CHECK(!strcmp(buf, "646 825 0 0\n"), "geom line, strip and bar not known");

    // The keeper's rule: a new one at once; the same one at once after NOTCH
    // took it and something moved NOTCH; one not seen taken: 2, 4, 8, 16, 30 s;
    // at most 4 sends of one rule in 30 s.
    NotchRuleState st = {.sent_ms = -1e9, .window_ms = -1e9};
    const char *a = "hl.monitor({ output = \"NOTCH\", position = \"0x-33\" })";
    const char *b = "hl.monitor({ output = \"NOTCH\", position = \"0x-40\" })";
    CHECK(notch_rule_due(&st, a, 0), "the first rule goes at once");
    notch_rule_sent(&st, a, 0);
    CHECK(!notch_rule_due(&st, a, 1000), "the same rule: not before the next look");
    CHECK(notch_rule_due(&st, a, 2000), "not seen taken at the next look (moved back before it): again");
    notch_rule_sent(&st, a, 2000);
    CHECK(!notch_rule_due(&st, a, 4000) && notch_rule_due(&st, a, 5000), "... then after 3 s");
    notch_rule_sent(&st, a, 5000);
    CHECK(!notch_rule_due(&st, a, 10000) && notch_rule_due(&st, a, 11000), "... then after 6 s");
    notch_rule_sent(&st, a, 11000);   // the 4th in 30 s
    CHECK(!notch_rule_due(&st, a, 29999), "never more than 4 sends of one rule in 30 s");
    CHECK(notch_rule_due(&st, a, 30001), "... the next after the 30 s");
    notch_rule_sent(&st, a, 30001);
    CHECK(!notch_rule_due(&st, a, 50000) && notch_rule_due(&st, a, 54001), "never taken: the wait grows to 24 s");
    notch_rule_sent(&st, a, 54001);
    CHECK(!notch_rule_due(&st, a, 84000) && notch_rule_due(&st, a, 84002), "... and stays at 30 s");
    CHECK(notch_rule_due(&st, b, 84000), "a changed rule goes at once");
    notch_rule_seen(&st, a);   // it took at last (the wait was 30 s)
    CHECK(notch_rule_due(&st, a, 56001), "taken after many refusals, then moved: again at the next look, not after 30 s");

    NotchRuleState t = {.sent_ms = -1e9, .window_ms = -1e9};
    notch_rule_sent(&t, a, 0);
    notch_rule_seen(&t, a);   // the next look: NOTCH as the rule wants
    CHECK(notch_rule_due(&t, a, 2000), "NOTCH took it, then was moved (a reload, another eval): again at once");
    notch_rule_sent(&t, a, 4000);
    CHECK(!notch_rule_due(&t, a, 5000) && notch_rule_due(&t, a, 6000), "sent again, not seen taken: the next look");
    notch_rule_seen(&t, b);   // NOTCH as another rule wants: not this one's
    CHECK(!t.held, "seen as another rule wants: not this one taken");
    notch_rule_seen(&t, a); notch_rule_sent(&t, a, 6000);   // 3rd
    notch_rule_seen(&t, a); notch_rule_sent(&t, a, 8000);   // 4th in 30 s
    notch_rule_seen(&t, a);
    CHECK(!notch_rule_due(&t, a, 10000), "something keeps moving it back: not chased every look (4 in 30 s)");
    CHECK(notch_rule_due(&t, a, 30001), "... again once the 30 s are over");

    // How the guest's cursor goes for the strip (host.env from omacvm-app-host).
    {
        struct { const char *env; int mode; const char *what; } c[] = {
            {"OMACVM_SCREEN=2560x1600\nOMACVM_VKWINDOWS=1\n", HOST_CURSOR_HIDES, "older app: the guest hides its cursor as before"},
            {"OMACVM_VKWINDOWS=1\nOMACVM_NOTCHPOINTER=1\n", HOST_CURSOR_PARKED, "the app parks the pointer in NOTCH"},
            {"OMACVM_HWCURSOR=1\n", HOST_CURSOR_STAYS, "Mac pointer for the VM: never hidden"},
            {"OMACVM_NOTCHPOINTER=1\nOMACVM_HWCURSOR=1\n", HOST_CURSOR_STAYS, "both: the Mac pointer wins"},
            {"OMACVM_NOTCHPOINTER=1", HOST_CURSOR_PARKED, "last line without a newline"},
            {"OMACVM_NOTCHPOINTER=0\nOMACVM_HWCURSOR=0\n", HOST_CURSOR_HIDES, "switched off"},
            {"XOMACVM_NOTCHPOINTER=1\n", HOST_CURSOR_HIDES, "only the exact key"},
            {"", HOST_CURSOR_HIDES, "empty"},
        };
        for (size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
            FILE *f = fmemopen((void *)c[i].env, strlen(c[i].env) + 1, "r");
            CHECK(host_env_cursor(f) == c[i].mode, c[i].what);
            if (f) fclose(f);
        }
        CHECK(host_env_cursor(NULL) == HOST_CURSOR_HIDES, "no host.env (an older app, a retired VM app)");
    }
    // Parked: the pointer is on NOTCH (0,-33 1470x33 on the Air) or it is not.
    CHECK(pointer_on_box(735, -33, 0, -33, 1470, 33), "parked: NOTCH's top row, behind the camera");
    CHECK(!pointer_on_box(735, 0, 0, -33, 1470, 33), "the screen's top row is not NOTCH");
    CHECK(!pointer_on_box(1470, -20, 0, -33, 1470, 33), "right of NOTCH");
    CHECK(!pointer_on_box(10, -20, 0, -33, 0, 33), "no NOTCH");

    printf(failures ? "%d failed\n" : "all passed\n", failures);
    return failures != 0;
}
