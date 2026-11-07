// OmacVM mac-ime: the line protocol on the virtio port org.omacvm.ime
// (docs/adr/0043-mac-ime.md), without Fcitx5 in it, so it is tested on its
// own (src/ime/tests/protocol-test.cpp, on the Mac and in CI).
//
// One JSON object per line, at most kMaxLine bytes; a longer line is dropped
// whole. Guest to Mac: hello, focus, rect, reset. Mac to guest: hello,
// preedit, commit, cancel. Positions from the Mac are Unicode code points;
// Fcitx5 wants bytes of UTF-8, so they are converted here.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace omacvm_ime {

constexpr int kVersion = 1;
constexpr size_t kMaxLine = 4096;
constexpr size_t kMaxSegments = 64;

// Splits a byte stream into lines. Lines longer than kMaxLine are dropped
// (up to their newline); an empty line is ignored.
class LineReader {
public:
    void feed(const char *data, size_t len,
              const std::function<void(std::string_view)> &line);
    void reset() { buf_.clear(); skipping_ = false; }

private:
    std::string buf_;
    bool skipping_ = false;
};

// A small strict JSON value: enough for this protocol and Hyprland's
// j/activewindow and j/layers. Depth and size are limited by the parser.
struct Json {
    enum class Type { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<Json> array;
    std::vector<std::pair<std::string, Json>> object;

    const Json *get(std::string_view key) const;
};

// The whole of `text` is one JSON value (whitespace around it allowed).
bool parseJson(std::string_view text, Json &out, size_t maxDepth = 8);

// `text` as a JSON string (quoted, escaped); invalid UTF-8 becomes U+FFFD.
std::string jsonString(std::string_view text);

// Code points in valid UTF-8 (0 for invalid input).
bool validUtf8(std::string_view text);
size_t codePoints(std::string_view text);
// Byte offset of code point `index` (index <= codePoints(text)).
size_t byteOffset(std::string_view text, size_t index);

struct Segment {
    size_t start, end;   // bytes
    bool active;         // the clause being converted (highlight), else underline
};

struct MacMessage {
    enum class Kind { Invalid, Hello, Preedit, Commit, Cancel };
    Kind kind = Kind::Invalid;
    int version = 0;
    std::string text;
    size_t cursor = 0;            // bytes into text
    std::vector<Segment> segments;  // sorted, not overlapping, inside text
};

// One line from the Mac; Invalid for anything that is not exactly one of
// the four messages with sane values.
MacMessage parseMac(std::string_view line);

struct Rect {
    double x = 0, y = 0, w = 0, h = 0;
};

// Guest to Mac.
std::string helloLine();
std::string focusOffLine();
std::string focusLine(bool password, const std::optional<Rect> &rect, bool exact);
std::string rectLine(const Rect &rect, bool exact);
std::string resetLine();

// The caret in Hyprland's global logical pixels:
//  - a rectangle relative to the window (Fcitx5's RelativeRect: Qt, GTK,
//    kitty), in the client's pixels at `scale`: the window's origin plus it;
//  - otherwise (no rectangle, or one in another space: XIM, Wayland IM v2)
//    the window's box, not exact.
// No window: no rectangle.
struct Caret {
    std::optional<Rect> rect;
    bool exact = false;
};
Caret caretFor(const Rect &cursor, double scale, bool relative,
               const std::optional<Rect> &window);

// Hyprland's j/activewindow: "at" and "size" (logical pixels) and "pid"
// (-1 when missing). Nothing for no window or a broken answer.
struct HyprWindow {
    Rect box;
    long pid = -1;
};
std::optional<HyprWindow> parseHyprActive(std::string_view json);
// The box alone.
std::optional<Rect> parseHyprWindow(std::string_view json);

// Hyprland's j/layers: every layer surface (Omarchy's menu, bar, panels,
// notifications; walker on Omarchy 4.0) of every monitor, in global logical
// pixels. `level` is Hyprland's 0 background, 1 bottom, 2 top, 3 overlay,
// read from its key; `order` is the place in its level's list, where the
// last one is drawn on top. Layers without a size or a pid are left out;
// nothing at all for a broken answer or more than kMaxLayers.
constexpr size_t kMaxLayers = 512;
struct HyprLayer {
    Rect box;
    long pid = -1;
    int level = 0;
    size_t order = 0;
    double alpha = 1;   // the goal: 0 while it fades out
};
std::optional<std::vector<HyprLayer>> parseHyprLayers(std::string_view json);

// The names a process goes by: /proc/PID/comm (cut to 15 bytes, from the
// path it was started by: "qs" for quickshell started through its link)
// and the file name of /proc/PID/exe (links resolved; what Qt reports).
struct ProcName {
    std::string comm;
    std::string exe;
};
// readlink(/proc/PID/exe) -> its file name, without " (deleted)" (a binary
// that an update replaced).
std::string exeName(std::string_view link);
// Fcitx5's program() of an input context (Qt: the file name of the resolved
// executable; GTK: g_get_prgname()) is that process.
bool sameProgram(std::string_view program, const ProcName &proc);

using NameOf = std::function<ProcName(long pid)>;

// Whether the caret may sit in a layer surface rather than in the window:
// a relative caret of a program that is not the active window's (or with
// no window at all). Only then is j/layers worth asking.
bool layerCandidate(const Rect &cursor, bool relative, std::string_view program,
                    const std::optional<HyprWindow> &window, const NameOf &nameOf);

// The caret with layer surfaces (#357: Omarchy 4.5's menu is a layer; its
// caret is relative to that layer, not to the window under it): for a
// layerCandidate, the topmost layer of that program's process that holds
// the caret (highest level, then last in its level; one fading out never),
// its origin plus the caret, exact. Anything else, also no such layer or
// no layers read: caretFor with the window's box, as before.
Caret caretOn(const Rect &cursor, double scale, bool relative, std::string_view program,
              const std::optional<HyprWindow> &window,
              const std::optional<std::vector<HyprLayer>> &layers, const NameOf &nameOf);

} // namespace omacvm_ime
