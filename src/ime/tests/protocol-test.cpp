// The mac-ime port protocol, guest side (src/ime/guest/addon/protocol.cpp),
// without Fcitx5 or a VM: framing, the Mac's messages (also broken and
// hostile ones), code points to bytes, the lines the guest sends, the caret.
//   src/ime/tests/run.sh   (builds and runs this; CI and on the Mac)
#include "../guest/addon/protocol.h"

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

using namespace omacvm_ime;

static int failures = 0;
#define EXPECT(cond, what)                                                       \
    do {                                                                         \
        if (cond) {                                                              \
            std::printf("ok   %s\n", what);                                      \
        } else {                                                                 \
            std::printf("FAIL %s (line %d)\n", what, __LINE__);                  \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static std::vector<std::string> lines(const std::vector<std::string> &chunks) {
    LineReader r;
    std::vector<std::string> out;
    for (const auto &c : chunks) {
        r.feed(c.data(), c.size(), [&](std::string_view l) { out.emplace_back(l); });
    }
    return out;
}

int main() {
    // ---------- framing ----------
    {
        auto l = lines({"{\"a\":1}\n{\"b\"", ":2}\n\n", "tail"});
        EXPECT(l.size() == 2 && l[0] == "{\"a\":1}" && l[1] == "{\"b\":2}",
               "lines split across reads; empty lines and an unfinished one ignored");
        std::string big(kMaxLine + 1, 'x');
        l = lines({big.substr(0, 3000), big.substr(3000) + "\n{\"ok\":1}\n"});
        EXPECT(l.size() == 1 && l[0] == "{\"ok\":1}", "a line over 4 KiB is dropped whole, the next one kept");
        std::string fits(kMaxLine, 'y');
        l = lines({fits + "\n"});
        EXPECT(l.size() == 1 && l[0].size() == kMaxLine, "a line of exactly 4 KiB is kept");
    }

    // ---------- JSON ----------
    {
        Json j;
        EXPECT(parseJson(" {\"t\":\"x\",\"n\":[1,2.5,-3e2],\"b\":true,\"z\":null} ", j) &&
                   j.get("n")->array.size() == 3 && j.get("n")->array[2].number == -300,
               "JSON: object, array, numbers, literals");
        EXPECT(parseJson("\"\\u65e5\\u672c\\ud83d\\ude00\"", j) && j.string == "日本😀",
               "JSON: \\u escapes and a surrogate pair");
        EXPECT(!parseJson("\"\\ud83d\"", j), "JSON: a lone surrogate is refused");
        EXPECT(!parseJson("\"a\\u0000b\"", j), "JSON: NUL in a string is refused");
        EXPECT(!parseJson("{\"a\":1,}", j) && !parseJson("[1 2]", j) && !parseJson("{a:1}", j) &&
                   !parseJson("01", j) && !parseJson("1.", j) && !parseJson("\"x", j) &&
                   !parseJson("{} {}", j) && !parseJson("nan", j) && !parseJson("1e999", j),
               "JSON: malformed input is refused");
        std::string deep(20, '[');
        deep += std::string(20, ']');
        EXPECT(!parseJson(deep, j), "JSON: nesting is limited");
        EXPECT(!parseJson(std::string("\"\xff\""), j), "JSON: invalid UTF-8 in a string is refused");
    }

    // ---------- the Mac's messages ----------
    {
        MacMessage m = parseMac("{\"t\":\"hello\",\"v\":1}");
        EXPECT(m.kind == MacMessage::Kind::Hello && m.version == 1, "hello");
        EXPECT(parseMac("{\"t\":\"hello\"}").kind == MacMessage::Kind::Invalid, "hello without a version: dropped");
        EXPECT(parseMac("{\"t\":\"cancel\"}").kind == MacMessage::Kind::Cancel, "cancel");
        m = parseMac("{\"t\":\"commit\",\"text\":\"日本\"}");
        EXPECT(m.kind == MacMessage::Kind::Commit && m.text == "日本", "commit");
        EXPECT(parseMac("{\"t\":\"commit\",\"text\":\"\"}").kind == MacMessage::Kind::Invalid,
               "an empty commit: dropped");
        EXPECT(parseMac("{\"t\":\"commit\",\"text\":5}").kind == MacMessage::Kind::Invalid,
               "a commit whose text is no string: dropped");

        // にほn: 3 code points, 7 bytes (3+3+1); cursor 3 = byte 7.
        m = parseMac("{\"t\":\"preedit\",\"text\":\"にほn\",\"cursor\":3,\"segs\":[[0,2,1],[2,3,0]]}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 7 && m.segments.size() == 2 &&
                   m.segments[0].start == 0 && m.segments[0].end == 6 && m.segments[0].active &&
                   m.segments[1].start == 6 && m.segments[1].end == 7 && !m.segments[1].active,
               "preedit: code points become UTF-8 bytes for Fcitx5");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"😀a\",\"cursor\":1}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 4, "preedit: an emoji is one code point, four bytes");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"ab\"}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 2 && m.segments.empty(),
               "preedit without cursor: at the end");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"\"}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.text.empty(), "an empty preedit (the guest clears it)");

        const char *bad[] = {
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":3}",              // past the end
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":-1}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":1.5}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":1e300}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":\"1\"}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,3,0]]}",        // past the end
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[1,1,0]]}",        // empty
            "{\"t\":\"preedit\",\"text\":\"abc\",\"segs\":[[0,2,0],[1,3,0]]}",  // overlapping
            "{\"t\":\"preedit\",\"text\":\"abc\",\"segs\":[[1,2,0],[0,1,0]]}",  // out of order
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,1,2]]}",        // unknown kind
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,1]]}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":{}}",
            "{\"t\":\"preedit\"}",
            "{\"t\":\"focus\",\"on\":true}",                                 // the guest's own message
            "{\"t\":7}",
            "[]",
            "\"preedit\"",
            "",
        };
        bool all = true;
        for (const char *b : bad) {
            all = all && parseMac(b).kind == MacMessage::Kind::Invalid;
        }
        EXPECT(all, "wrong types, positions, segments and messages: all dropped");
        std::string many = "{\"t\":\"preedit\",\"text\":\"" + std::string(100, 'a') + "\",\"segs\":[";
        for (int i = 0; i < 65; i++) {
            many += (i ? "," : "") + std::string("[") + std::to_string(i) + "," + std::to_string(i + 1) + ",0]";
        }
        many += "]}";
        EXPECT(parseMac(many).kind == MacMessage::Kind::Invalid, "more than 64 segments: dropped");
        std::string longText = "{\"t\":\"commit\",\"text\":\"" + std::string(kMaxLine, 'a') + "\"}";
        EXPECT(parseMac(longText).kind == MacMessage::Kind::Invalid, "a line over 4 KiB: dropped");
    }

    // ---------- the guest's lines ----------
    {
        EXPECT(helloLine() == "{\"t\":\"hello\",\"v\":1}", "hello line");
        EXPECT(focusOffLine() == "{\"t\":\"focus\",\"on\":false}", "focus off line");
        EXPECT(focusLine(false, Rect{10, 20.5, 2, 18}, true) ==
                   "{\"t\":\"focus\",\"on\":true,\"kind\":\"text\",\"rect\":[10,20.5,2,18],\"exact\":true}",
               "focus line with a caret");
        EXPECT(focusLine(true, std::nullopt, false) == "{\"t\":\"focus\",\"on\":true,\"kind\":\"password\"}",
               "focus line: a password field, no caret");
        EXPECT(rectLine(Rect{-1920, 0, 1, 1}, false) == "{\"t\":\"rect\",\"rect\":[-1920,0,1,1],\"exact\":false}",
               "rect line (outputs left of the main one have negative x)");
        EXPECT(resetLine() == "{\"t\":\"reset\"}", "reset line");
        Json j;
        EXPECT(jsonString("a\"b\\c\n\x01") == "\"a\\\"b\\\\c\\n\\u0001\"" &&
                   parseJson(jsonString(std::string("x\xff" "y")), j) && j.string == "x\xef\xbf\xbdy",
               "strings escaped; invalid UTF-8 becomes U+FFFD");
    }

    // ---------- the caret ----------
    {
        Rect win{100, 50, 800, 600};
        Caret c = caretFor(Rect{40, 60, 4, 36}, 2.0, true, win);
        EXPECT(c.rect && c.exact && c.rect->x == 120 && c.rect->y == 80 && c.rect->w == 2 && c.rect->h == 18,
               "relative caret at scale 2: window origin + caret / 2, exact");
        c = caretFor(Rect{0, 0, 0, 0}, 1.0, true, win);
        EXPECT(c.rect && !c.exact && c.rect->x == 100 && c.rect->w == 800, "no caret (Wayland IM v2): the window, not exact");
        c = caretFor(Rect{500, 400, 2, 20}, 1.0, false, win);
        EXPECT(c.rect && !c.exact && c.rect->x == 100, "an absolute caret (XIM): the window, not exact");
        c = caretFor(Rect{40, 60, 4, 36}, 0.0, true, win);
        EXPECT(c.rect && c.rect->x == 140, "scale 0 counts as 1");
        c = caretFor(Rect{40, 60, 4, 36}, 1.0, true, std::nullopt);
        EXPECT(!c.rect, "no window known: no caret");
        auto w = parseHyprWindow("{\"address\":\"0x1\",\"at\":[12, -40],\"size\":[1900,1018],\"title\":\"x\"}");
        EXPECT(w && w->x == 12 && w->y == -40 && w->w == 1900 && w->h == 1018, "Hyprland's j/activewindow");
        EXPECT(!parseHyprWindow("{}") && !parseHyprWindow("{\"at\":[1],\"size\":[1,1]}") &&
                   !parseHyprWindow("{\"at\":[0,0],\"size\":[0,10]}") && !parseHyprWindow("not json"),
               "no window, or a broken answer: nothing");
    }

    // ---------- the caret in a layer surface (#357) ----------
    // Omarchy 4.5's menu (Super+Space) is a layer surface of quickshell; Qt
    // gives its caret relative to that layer. Numbers from the 4.5 row on the
    // mini (work/open-1107/i357): foot at [12,38] 1296x690, the menu
    // full-screen at level 3, its caret at about (578,106) in the menu.
    // Without the layer rule (3.4.0 and older) the module sent [590,144] over
    // foot and nothing with no window open.
    {
        // pid 700 quickshell (started through its "qs" link), 800 foot,
        // 900 a long name.
        NameOf names = [](long pid) {
            if (pid == 700) return ProcName{"qs", "quickshell"};
            if (pid == 800) return ProcName{"foot", "foot"};
            if (pid == 900) return ProcName{"telegram-deskto", "telegram-desktop"};
            if (pid == 901) return ProcName{"soffice.bin", "soffice.bin"};
            return ProcName{};
        };
        auto layer = [](double x, double y, double w, double h, long pid, int level, size_t order,
                        double alpha = 1) {
            HyprLayer l;
            l.box = Rect{x, y, w, h};
            l.pid = pid;
            l.level = level;
            l.order = order;
            l.alpha = alpha;
            return l;
        };
        // Omarchy 4.5's shell layers, in Hyprland's order (the row's list).
        std::vector<HyprLayer> shell = {
            layer(0, 0, 1320, 740, 700, 0, 0),     // background
            layer(0, 0, 1320, 740, 700, 2, 0),     // bar
            layer(0, 533, 1320, 207, 700, 2, 1),   // dock
            layer(921, 0, 399, 740, 700, 3, 0),    // notifications
            layer(0, 0, 1320, 740, 700, 3, 1),     // the menu
        };
        HyprWindow foot{Rect{12, 38, 1296, 690}, 800};
        Rect menuCaret{578, 106, 1, 22};

        Caret c = caretOn(menuCaret, 1.0, true, "quickshell", foot, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 578 && c.rect->y == 106 && c.rect->w == 1 && c.rect->h == 22,
               "the menu over foot: the menu's caret (was [590,144], foot's origin added)");
        c = caretOn(menuCaret, 1.0, true, "quickshell", std::nullopt, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 578 && c.rect->y == 106,
               "the menu with no window: its caret (was no rect)");
        c = caretOn(Rect{1156, 212, 2, 44}, 2.0, true, "quickshell", foot, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 578 && c.rect->y == 106 && c.rect->w == 1 && c.rect->h == 22,
               "the menu at scale 2: the caret in the layer's logical pixels");

        // The notifications layer (same process, same level) after the menu in
        // the list, the caret outside its box: still the menu.
        std::vector<HyprLayer> notesLast = {shell[0], shell[1], shell[2], layer(0, 0, 1320, 740, 700, 3, 0),
                                            layer(921, 0, 399, 740, 700, 3, 1)};
        c = caretOn(menuCaret, 1.0, true, "quickshell", foot, notesLast, names);
        EXPECT(c.rect && c.exact && c.rect->x == 578 && c.rect->y == 106,
               "notifications after the menu, caret outside them: the menu");
        // Inside a level the last one is on top.
        std::vector<HyprLayer> two = {layer(0, 0, 1320, 740, 700, 3, 0), layer(100, 50, 800, 600, 700, 3, 1)};
        c = caretOn(Rect{10, 10, 1, 20}, 1.0, true, "quickshell", foot, two, names);
        EXPECT(c.rect && c.rect->x == 110 && c.rect->y == 60, "inside a level: the last one (on top)");
        // A higher level wins over the order; one fading out never counts.
        std::vector<HyprLayer> lv = {layer(0, 0, 1320, 740, 700, 3, 0), layer(200, 0, 1000, 740, 700, 2, 5),
                                     layer(300, 300, 900, 400, 700, 3, 1, 0)};
        c = caretOn(Rect{10, 10, 1, 20}, 1.0, true, "quickshell", foot, lv, names);
        EXPECT(c.rect && c.rect->x == 10 && c.rect->y == 10, "a higher level wins; a layer fading out never");
        // A second monitor to the right.
        std::vector<HyprLayer> right = {layer(1320, 0, 1920, 1080, 700, 3, 0)};
        c = caretOn(menuCaret, 1.0, true, "quickshell", std::nullopt, right, names);
        EXPECT(c.rect && c.exact && c.rect->x == 1898 && c.rect->y == 106, "a menu on a second monitor");

        // Today's result, unchanged:
        Caret before = caretFor(Rect{40, 60, 4, 36}, 2.0, true, foot.box);
        c = caretOn(Rect{40, 60, 4, 36}, 2.0, true, "foot", foot, shell, names);
        EXPECT(c.rect && before.rect && c.exact == before.exact && c.rect->x == before.rect->x &&
                   c.rect->y == before.rect->y && c.rect->x == 32 && c.rect->y == 68,
               "the window's own program: window origin + caret, as before");
        // A program whose name is not its window's process (LibreOffice's
        // soffice.bin under another name, a wrapper): no layer of that name,
        // so today's exact window-relative caret, never the window's box.
        HyprWindow office{Rect{12, 38, 1296, 690}, 901};
        c = caretOn(Rect{40, 60, 4, 36}, 1.0, true, "soffice", office, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 52 && c.rect->y == 98,
               "a name that matches nothing: today's window-relative caret, exact");
        c = caretOn(Rect{40, 60, 4, 36}, 1.0, true, "", office, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 52, "no program name: today's result");
        c = caretOn(menuCaret, 1.0, true, "quickshell", foot, std::nullopt, names);
        EXPECT(c.rect && c.exact && c.rect->x == 590 && c.rect->y == 144,
               "layers not read (Hyprland did not answer): today's result");
        c = caretOn(menuCaret, 1.0, true, "walker", std::nullopt, shell, names);
        EXPECT(!c.rect, "no window and no layer of that program: no rect, as before");
        c = caretOn(Rect{0, 0, 0, 0}, 1.0, true, "quickshell", foot, shell, names);
        EXPECT(c.rect && !c.exact && c.rect->x == 12, "no caret: the window's box, as before");
        c = caretOn(menuCaret, 1.0, false, "quickshell", foot, shell, names);
        EXPECT(c.rect && !c.exact && c.rect->x == 12, "an absolute caret: the window's box, as before");
        c = caretOn(Rect{1400, 106, 1, 22}, 1.0, true, "quickshell", foot, shell, names);
        EXPECT(c.rect && c.exact && c.rect->x == 1412, "a caret outside every layer of the program: today's result");

        EXPECT(layerCandidate(menuCaret, true, "quickshell", foot, names) &&
                   layerCandidate(menuCaret, true, "quickshell", std::nullopt, names) &&
                   !layerCandidate(menuCaret, true, "foot", foot, names) &&
                   !layerCandidate(menuCaret, false, "quickshell", foot, names) &&
                   !layerCandidate(Rect{0, 0, 0, 0}, true, "quickshell", foot, names) &&
                   !layerCandidate(menuCaret, true, "", foot, names),
               "j/layers is asked only for a relative caret of a program that is not the window's");

        // Names: Qt's program name against comm (15 bytes, the started path)
        // and the file name of the resolved executable.
        EXPECT(sameProgram("quickshell", ProcName{"qs", "quickshell"}), "names: quickshell started as qs (exe)");
        EXPECT(sameProgram("telegram-desktop", ProcName{"telegram-deskto", ""}),
               "names: a long name against comm's 15 bytes");
        EXPECT(sameProgram("telegram-desktop", ProcName{"telegram-deskto", "telegram-desktop"}) &&
                   sameProgram("/usr/bin/foot", ProcName{"foot", ""}),
               "names: exe, and a program given as a path");
        EXPECT(!sameProgram("quickshell", ProcName{"qs", ""}) && !sameProgram("qs", ProcName{"quickshel", "x"}) &&
                   !sameProgram("", ProcName{"", ""}) && !sameProgram("foot", ProcName{"", ""}) &&
                   !sameProgram("/", ProcName{"", ""}),
               "names: no match without a name in common");
        EXPECT(exeName("/usr/bin/quickshell") == "quickshell" &&
                   exeName("/usr/bin/quickshell (deleted)") == "quickshell" && exeName("foot") == "foot" &&
                   exeName("") == "",
               "exe names: file name, a binary replaced by an update");
    }

    // ---------- Hyprland's j/layers and j/activewindow ----------
    {
        // Hyprland 0.56.2's j/layers layout (HyprCtl.cpp layersRequest), the
        // levels written out of order on purpose: the level is the key.
        const char *layers = R"({
"Virtual-1": {
    "levels": {
        "3": [
                {
                    "address": "0xaaaa",
                    "x": 921,
                    "y": 0,
                    "w": 399,
                    "h": 740,
                    "alpha": 1,
                    "namespace": "omarchy-notifications",
                    "pid": 700
                },                {
                    "address": "0xbbbb",
                    "x": 0,
                    "y": 0,
                    "w": 1320,
                    "h": 740,
                    "alpha": 0.5,
                    "namespace": "omarchy-menu",
                    "pid": 700
                }
        ],
        "0": [
                {
                    "address": "0xcccc",
                    "x": 0,
                    "y": 0,
                    "w": 1320,
                    "h": 740,
                    "alpha": 1,
                    "namespace": "omarchy-background",
                    "pid": 700
                }
        ],
        "1": [],
        "2": []
    }
},
"Virtual-2": {
    "levels": {
        "0": [],
        "1": [],
        "2": [
                {
                    "address": "0xdddd",
                    "x": 1320,
                    "y": 0,
                    "w": 0,
                    "h": 30,
                    "alpha": 1,
                    "namespace": "empty",
                    "pid": 700
                }
        ],
        "3": []
    }
}
}
)";
        auto ls = parseHyprLayers(layers);
        EXPECT(ls && ls->size() == 3 && (*ls)[0].level == 3 && (*ls)[0].order == 0 && (*ls)[1].level == 3 &&
                   (*ls)[1].order == 1 && (*ls)[1].alpha == 0.5 && (*ls)[1].box.w == 1320 && (*ls)[2].level == 0 &&
                   (*ls)[0].pid == 700 && (*ls)[0].box.x == 921,
               "j/layers: levels by key, order inside a level, sizeless layers left out");
        EXPECT(parseHyprLayers("{}") && parseHyprLayers("{}")->empty(), "j/layers: no monitors");
        EXPECT(!parseHyprLayers("{\"M\":{\"levels\":{\"4\":[]}}}") &&
                   !parseHyprLayers("{\"M\":{\"levels\":{\"10\":[]}}}") &&
                   !parseHyprLayers("{\"M\":{\"levels\":[]}}") && !parseHyprLayers("{\"M\":{}}") &&
                   !parseHyprLayers("{\"M\":{\"levels\":{\"0\":[{\"x\":\"0\",\"y\":0,\"w\":1,\"h\":1,\"pid\":1}]}}}") &&
                   !parseHyprLayers("{\"M\":{\"levels\":{\"0\":[{\"x\":1e9,\"y\":0,\"w\":1,\"h\":1,\"pid\":1}]}}}") &&
                   !parseHyprLayers("{\"M\":{\"levels\":{\"0\":[{\"y\":0,\"w\":1,\"h\":1,\"pid\":1}]}}}") &&
                   !parseHyprLayers("[]") && !parseHyprLayers("not json"),
               "j/layers: unknown levels, wrong types, huge or missing values: nothing");
        auto nopid = parseHyprLayers("{\"M\":{\"levels\":{\"0\":[{\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"pid\":-1},"
                                     "{\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"pid\":1.5},{\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}}}");
        EXPECT(nopid && nopid->empty(), "j/layers: layers without a usable pid are left out");
        std::string many = "{\"M\":{\"levels\":{\"0\":[";
        for (size_t i = 0; i <= kMaxLayers; i++) {
            many += std::string(i ? "," : "") + "{\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"pid\":1}";
        }
        many += "]}}}";
        EXPECT(!parseHyprLayers(many), "j/layers: more than 512 layers: nothing");
        EXPECT(!parseHyprLayers(std::string(256 * 1024 + 1, ' ')), "j/layers: an answer over 256 KiB: nothing");
        auto w = parseHyprActive("{\"address\":\"0x1\",\"at\":[12, 38],\"size\":[1296,690],\"pid\":812}");
        EXPECT(w && w->box.x == 12 && w->pid == 812, "j/activewindow: the pid");
        w = parseHyprActive("{\"at\":[12, 38],\"size\":[1296,690],\"pid\":\"812\"}");
        EXPECT(w && w->pid == -1, "j/activewindow: a pid that is no number: -1, the box still read");
    }

    // ---------- fuzz: random and mutated input never crashes ----------
    {
        std::mt19937 rng(273);
        const std::vector<std::string> seeds = {
            "{\"t\":\"preedit\",\"text\":\"にほn\",\"cursor\":3,\"segs\":[[0,2,1],[2,3,0]]}",
            "{\"t\":\"commit\",\"text\":\"日本\"}", "{\"t\":\"hello\",\"v\":1}", "{\"t\":\"cancel\"}"};
        size_t valid = 0;
        LineReader r;
        for (int i = 0; i < 200000; i++) {
            std::string s = seeds[size_t(i) % seeds.size()];
            int edits = 1 + int(rng() % 4);
            for (int k = 0; k < edits; k++) {
                size_t at = rng() % (s.size() + 1);
                switch (rng() % 3) {
                case 0: s.insert(at, 1, char(rng() % 256)); break;
                case 1: if (at < s.size()) s.erase(at, 1); break;
                default: if (at < s.size()) s[at] = char(rng() % 256); break;
                }
            }
            MacMessage m = parseMac(s);
            if (m.kind == MacMessage::Kind::Preedit) {
                // Whatever got through is consistent.
                bool ok = m.cursor <= m.text.size() && validUtf8(m.text);
                size_t last = 0;
                for (const auto &seg : m.segments) {
                    ok = ok && seg.start >= last && seg.start < seg.end && seg.end <= m.text.size();
                    last = seg.end;
                }
                if (!ok) {
                    EXPECT(false, "fuzz: a preedit that got through is consistent");
                    break;
                }
            }
            valid += m.kind != MacMessage::Kind::Invalid;
            s += '\n';
            r.feed(s.data(), s.size(), [](std::string_view l) { (void)parseMac(l); });
        }
        std::printf("ok   fuzz: 200000 mutated lines, %zu still valid, every one handled\n", valid);
    }

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
