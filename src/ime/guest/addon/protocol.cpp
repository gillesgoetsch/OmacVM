// OmacVM mac-ime: the port's line protocol (see protocol.h).
#include "protocol.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace omacvm_ime {

void LineReader::feed(const char *data, size_t len,
                      const std::function<void(std::string_view)> &line) {
    for (size_t i = 0; i < len; i++) {
        char c = data[i];
        if (c == '\n') {
            if (!skipping_ && !buf_.empty()) {
                line(buf_);
            }
            buf_.clear();
            skipping_ = false;
            continue;
        }
        if (skipping_) {
            continue;
        }
        if (buf_.size() >= kMaxLine) {
            // Too long: dropped up to its newline.
            buf_.clear();
            skipping_ = true;
            continue;
        }
        buf_.push_back(c);
    }
}

const Json *Json::get(std::string_view key) const {
    if (type != Type::Object) {
        return nullptr;
    }
    for (const auto &kv : object) {
        if (kv.first == key) {
            return &kv.second;
        }
    }
    return nullptr;
}

namespace {

class Parser {
public:
    Parser(std::string_view s, size_t maxDepth) : s_(s), maxDepth_(maxDepth) {}

    bool parse(Json &out) {
        skip();
        if (!value(out, 0)) {
            return false;
        }
        skip();
        return i_ == s_.size();
    }

private:
    std::string_view s_;
    size_t i_ = 0;
    size_t maxDepth_;

    void skip() {
        while (i_ < s_.size() &&
               (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) {
            i_++;
        }
    }
    bool literal(std::string_view w) {
        if (s_.substr(i_, w.size()) != w) {
            return false;
        }
        i_ += w.size();
        return true;
    }
    static void put(std::string &out, uint32_t cp) {
        if (cp < 0x80) {
            out.push_back(char(cp));
        } else if (cp < 0x800) {
            out.push_back(char(0xC0 | (cp >> 6)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(char(0xE0 | (cp >> 12)));
            out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(char(0xF0 | (cp >> 18)));
            out.push_back(char(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        }
    }
    bool hex4(uint32_t &v) {
        if (i_ + 4 > s_.size()) {
            return false;
        }
        v = 0;
        for (int k = 0; k < 4; k++) {
            char c = s_[i_++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= uint32_t(c - '0');
            else if (c >= 'a' && c <= 'f') v |= uint32_t(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= uint32_t(c - 'A' + 10);
            else return false;
        }
        return true;
    }
    bool str(std::string &out) {
        if (i_ >= s_.size() || s_[i_] != '"') {
            return false;
        }
        i_++;
        size_t start = i_;
        while (i_ < s_.size()) {
            unsigned char c = (unsigned char)s_[i_];
            if (c == '"') {
                i_++;
                return validUtf8(out);
            }
            if (c < 0x20) {
                return false;
            }
            if (c != '\\') {
                out.push_back(char(c));
                i_++;
                continue;
            }
            i_++;
            if (i_ >= s_.size()) {
                return false;
            }
            char e = s_[i_++];
            switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                uint32_t cp;
                if (!hex4(cp)) return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t lo;
                    if (!literal("\\u") || !hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) {
                        return false;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return false;
                }
                if (cp == 0) return false;   // no NUL in text
                put(out, cp);
                break;
            }
            default:
                return false;
            }
        }
        (void)start;
        return false;
    }
    bool num(double &out) {
        size_t start = i_;
        if (i_ < s_.size() && s_[i_] == '-') i_++;
        if (i_ >= s_.size()) return false;
        if (s_[i_] == '0') {
            i_++;
        } else if (s_[i_] >= '1' && s_[i_] <= '9') {
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
        } else {
            return false;
        }
        if (i_ < s_.size() && s_[i_] == '.') {
            i_++;
            size_t d = i_;
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
            if (i_ == d) return false;
        }
        if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
            i_++;
            if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) i_++;
            size_t d = i_;
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
            if (i_ == d) return false;
        }
        if (i_ - start > 32) return false;
        std::string t(s_.substr(start, i_ - start));
        char *end = nullptr;
        out = std::strtod(t.c_str(), &end);
        return end && *end == '\0' && std::isfinite(out);
    }
    bool value(Json &out, size_t depth) {
        if (depth > maxDepth_ || i_ >= s_.size()) {
            return false;
        }
        char c = s_[i_];
        if (c == '{') {
            out.type = Json::Type::Object;
            i_++;
            skip();
            if (i_ < s_.size() && s_[i_] == '}') {
                i_++;
                return true;
            }
            for (;;) {
                skip();
                std::string key;
                if (!str(key)) return false;
                skip();
                if (i_ >= s_.size() || s_[i_] != ':') return false;
                i_++;
                skip();
                Json v;
                if (!value(v, depth + 1)) return false;
                out.object.emplace_back(std::move(key), std::move(v));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
                return false;
            }
        }
        if (c == '[') {
            out.type = Json::Type::Array;
            i_++;
            skip();
            if (i_ < s_.size() && s_[i_] == ']') {
                i_++;
                return true;
            }
            for (;;) {
                skip();
                Json v;
                if (!value(v, depth + 1)) return false;
                out.array.push_back(std::move(v));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
                return false;
            }
        }
        if (c == '"') {
            out.type = Json::Type::String;
            return str(out.string);
        }
        if (literal("true")) { out.type = Json::Type::Bool; out.boolean = true; return true; }
        if (literal("false")) { out.type = Json::Type::Bool; out.boolean = false; return true; }
        if (literal("null")) { out.type = Json::Type::Null; return true; }
        out.type = Json::Type::Number;
        return num(out.number);
    }
};

// One code point at s[i]: its length in bytes, or 0 when the UTF-8 is bad
// (overlong forms, surrogates and values past U+10FFFF included).
size_t utf8Len(std::string_view s, size_t i) {
    unsigned char c = (unsigned char)s[i];
    size_t n;
    uint32_t cp, min;
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; min = 0x80; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; min = 0x800; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; min = 0x10000; }
    else return 0;
    if (i + n > s.size()) return 0;
    for (size_t k = 1; k < n; k++) {
        unsigned char d = (unsigned char)s[i + k];
        if ((d & 0xC0) != 0x80) return 0;
        cp = (cp << 6) | (d & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
    return n;
}

bool count(const Json *v, double &out) {
    if (!v || v->type != Json::Type::Number || v->number < 0 || v->number > 1e6 ||
        v->number != std::floor(v->number)) {
        return false;
    }
    out = v->number;
    return true;
}

std::string num(double v) {
    char b[64];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

std::string rectJson(const Rect &r) {
    return "[" + num(r.x) + "," + num(r.y) + "," + num(r.w) + "," + num(r.h) + "]";
}

} // namespace

bool parseJson(std::string_view text, Json &out, size_t maxDepth) {
    out = Json();
    Parser p(text, maxDepth);
    return p.parse(out);
}

bool validUtf8(std::string_view text) {
    for (size_t i = 0; i < text.size();) {
        size_t n = utf8Len(text, i);
        if (!n) return false;
        i += n;
    }
    return true;
}

size_t codePoints(std::string_view text) {
    size_t n = 0;
    for (size_t i = 0; i < text.size(); n++) {
        size_t l = utf8Len(text, i);
        if (!l) return 0;
        i += l;
    }
    return n;
}

size_t byteOffset(std::string_view text, size_t index) {
    size_t i = 0;
    for (size_t k = 0; k < index && i < text.size(); k++) {
        size_t l = utf8Len(text, i);
        if (!l) return text.size();
        i += l;
    }
    return i;
}

std::string jsonString(std::string_view text) {
    std::string out = "\"";
    for (size_t i = 0; i < text.size();) {
        size_t n = utf8Len(text, i);
        if (!n) {
            out += "\\ufffd";
            i++;
            continue;
        }
        unsigned char c = (unsigned char)text[i];
        if (n == 1) {
            switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20 || c == 0x7F) {
                    char b[8];
                    std::snprintf(b, sizeof b, "\\u%04x", c);
                    out += b;
                } else {
                    out.push_back(char(c));
                }
            }
        } else {
            out.append(text.substr(i, n));
        }
        i += n;
    }
    out += "\"";
    return out;
}

MacMessage parseMac(std::string_view line) {
    MacMessage m;
    Json j;
    if (line.size() > kMaxLine || !parseJson(line, j) || j.type != Json::Type::Object) {
        return m;
    }
    const Json *t = j.get("t");
    if (!t || t->type != Json::Type::String) {
        return m;
    }
    if (t->string == "hello") {
        double v;
        if (!count(j.get("v"), v) || v < 1) return m;
        m.version = int(v);
        m.kind = MacMessage::Kind::Hello;
        return m;
    }
    if (t->string == "cancel") {
        m.kind = MacMessage::Kind::Cancel;
        return m;
    }
    const Json *text = j.get("text");
    if (!text || text->type != Json::Type::String) {
        return m;
    }
    if (t->string == "commit") {
        if (text->string.empty()) return m;
        m.text = text->string;
        m.kind = MacMessage::Kind::Commit;
        return m;
    }
    if (t->string != "preedit") {
        return m;
    }
    m.text = text->string;
    size_t cps = codePoints(m.text);
    double cursor = double(cps);
    if (const Json *c = j.get("cursor")) {
        if (!count(c, cursor) || cursor > double(cps)) return m;
    }
    m.cursor = byteOffset(m.text, size_t(cursor));
    if (const Json *segs = j.get("segs")) {
        if (segs->type != Json::Type::Array || segs->array.size() > kMaxSegments) return m;
        size_t last = 0;
        for (const Json &s : segs->array) {
            double a, b, k;
            if (s.type != Json::Type::Array || s.array.size() != 3 ||
                !count(&s.array[0], a) || !count(&s.array[1], b) || !count(&s.array[2], k) ||
                a >= b || b > double(cps) || size_t(a) < last || k > 1) {
                return m;
            }
            last = size_t(b);
            m.segments.push_back({byteOffset(m.text, size_t(a)), byteOffset(m.text, size_t(b)), k == 1});
        }
    }
    m.kind = MacMessage::Kind::Preedit;
    return m;
}

std::string helloLine() {
    return "{\"t\":\"hello\",\"v\":" + std::to_string(kVersion) + "}";
}

std::string focusOffLine() {
    return "{\"t\":\"focus\",\"on\":false}";
}

std::string focusLine(bool password, const std::optional<Rect> &rect, bool exact) {
    std::string s = "{\"t\":\"focus\",\"on\":true,\"kind\":\"";
    s += password ? "password" : "text";
    s += "\"";
    if (rect) {
        s += ",\"rect\":" + rectJson(*rect) + ",\"exact\":" + (exact ? "true" : "false");
    }
    return s + "}";
}

std::string rectLine(const Rect &rect, bool exact) {
    return "{\"t\":\"rect\",\"rect\":" + rectJson(rect) + ",\"exact\":" + (exact ? "true" : "false") + "}";
}

std::string resetLine() {
    return "{\"t\":\"reset\"}";
}

Caret caretFor(const Rect &cursor, double scale, bool relative,
               const std::optional<Rect> &window) {
    Caret c;
    if (!window) {
        return c;
    }
    if (!(scale > 0) || !std::isfinite(scale)) {
        scale = 1;
    }
    bool none = cursor.x == 0 && cursor.y == 0 && cursor.w == 0 && cursor.h == 0;
    if (relative && !none) {
        c.rect = Rect{window->x + cursor.x / scale, window->y + cursor.y / scale,
                      cursor.w / scale, cursor.h / scale};
        c.exact = true;
        return c;
    }
    c.rect = *window;
    c.exact = false;
    return c;
}

namespace {

// A coordinate or size from Hyprland: a number of sane size.
bool coord(const Json *v, double &out) {
    if (!v || v->type != Json::Type::Number || !(std::fabs(v->number) < 1e7)) {
        return false;
    }
    out = v->number;
    return true;
}

long pidOf(const Json *v) {
    if (!v || v->type != Json::Type::Number || v->number <= 0 || v->number > 2147483647.0 ||
        v->number != std::floor(v->number)) {
        return -1;
    }
    return long(v->number);
}

// The caret's top left corner inside a box of that size (its own pixels).
bool holds(const Rect &box, double x, double y) {
    return x >= 0 && y >= 0 && x <= box.w && y <= box.h;
}

} // namespace

std::optional<HyprWindow> parseHyprActive(std::string_view json) {
    Json j;
    if (json.size() > 256 * 1024 || !parseJson(json, j, 16) || j.type != Json::Type::Object) {
        return std::nullopt;
    }
    const Json *at = j.get("at"), *size = j.get("size");
    auto pair = [](const Json *v, double &a, double &b) {
        return v && v->type == Json::Type::Array && v->array.size() == 2 &&
               coord(&v->array[0], a) && coord(&v->array[1], b);
    };
    HyprWindow w;
    if (!pair(at, w.box.x, w.box.y) || !pair(size, w.box.w, w.box.h) || w.box.w <= 0 || w.box.h <= 0) {
        return std::nullopt;
    }
    w.pid = pidOf(j.get("pid"));
    return w;
}

std::optional<Rect> parseHyprWindow(std::string_view json) {
    auto w = parseHyprActive(json);
    if (!w) {
        return std::nullopt;
    }
    return w->box;
}

std::optional<std::vector<HyprLayer>> parseHyprLayers(std::string_view json) {
    Json j;
    if (json.size() > 256 * 1024 || !parseJson(json, j, 16) || j.type != Json::Type::Object) {
        return std::nullopt;
    }
    std::vector<HyprLayer> out;
    size_t seen = 0;
    for (const auto &mon : j.object) {
        const Json *levels = mon.second.get("levels");
        if (!levels || levels->type != Json::Type::Object) {
            return std::nullopt;
        }
        for (const auto &lv : levels->object) {
            // The level is its key, "0" to "3"; never the object's order.
            if (lv.first.size() != 1 || lv.first[0] < '0' || lv.first[0] > '3' ||
                lv.second.type != Json::Type::Array) {
                return std::nullopt;
            }
            size_t order = 0;
            for (const Json &l : lv.second.array) {
                if (++seen > kMaxLayers || l.type != Json::Type::Object) {
                    return std::nullopt;
                }
                HyprLayer h;
                h.level = lv.first[0] - '0';
                h.order = order++;
                h.pid = pidOf(l.get("pid"));
                if (const Json *a = l.get("alpha")) {
                    if (a->type != Json::Type::Number || !std::isfinite(a->number)) {
                        return std::nullopt;
                    }
                    h.alpha = a->number;
                }
                if (!coord(l.get("x"), h.box.x) || !coord(l.get("y"), h.box.y) ||
                    !coord(l.get("w"), h.box.w) || !coord(l.get("h"), h.box.h)) {
                    return std::nullopt;
                }
                if (h.box.w > 0 && h.box.h > 0 && h.pid > 0) {
                    out.push_back(h);
                }
            }
        }
    }
    return out;
}

std::string exeName(std::string_view link) {
    constexpr std::string_view deleted = " (deleted)";
    if (link.size() > deleted.size() && link.substr(link.size() - deleted.size()) == deleted) {
        link.remove_suffix(deleted.size());
    }
    size_t slash = link.rfind('/');
    return std::string(slash == std::string_view::npos ? link : link.substr(slash + 1));
}

bool sameProgram(std::string_view program, const ProcName &proc) {
    size_t slash = program.rfind('/');
    if (slash != std::string_view::npos) {
        program.remove_prefix(slash + 1);
    }
    if (program.empty()) {
        return false;
    }
    // The kernel keeps 15 bytes of the name in comm.
    return (!proc.exe.empty() && program == proc.exe) ||
           (!proc.comm.empty() && program.substr(0, 15) == proc.comm);
}

bool layerCandidate(const Rect &cursor, bool relative, std::string_view program,
                    const std::optional<HyprWindow> &window, const NameOf &nameOf) {
    bool none = cursor.x == 0 && cursor.y == 0 && cursor.w == 0 && cursor.h == 0;
    if (!relative || none || program.empty()) {
        return false;
    }
    return !window || window->pid <= 0 || !sameProgram(program, nameOf(window->pid));
}

Caret caretOn(const Rect &cursor, double scale, bool relative, std::string_view program,
              const std::optional<HyprWindow> &window,
              const std::optional<std::vector<HyprLayer>> &layers, const NameOf &nameOf) {
    std::optional<Rect> box;
    if (window) {
        box = window->box;
    }
    if (!layers || !layerCandidate(cursor, relative, program, window, nameOf)) {
        return caretFor(cursor, scale, relative, box);
    }
    if (!(scale > 0) || !std::isfinite(scale)) {
        scale = 1;
    }
    double x = cursor.x / scale, y = cursor.y / scale;
    const HyprLayer *top = nullptr;
    std::vector<std::pair<long, bool>> named;   // pid -> is that program
    for (const HyprLayer &l : *layers) {
        if (!(l.alpha > 0) || !holds(l.box, x, y)) {
            continue;
        }
        if (top && (l.level < top->level || (l.level == top->level && l.order < top->order))) {
            continue;
        }
        bool same = false, known = false;
        for (const auto &n : named) {
            if (n.first == l.pid) {
                same = n.second;
                known = true;
            }
        }
        if (!known) {
            same = sameProgram(program, nameOf(l.pid));
            named.emplace_back(l.pid, same);
        }
        if (same) {
            top = &l;
        }
    }
    if (!top) {
        return caretFor(cursor, scale, relative, box);
    }
    Caret c;
    c.rect = Rect{top->box.x + x, top->box.y + y, cursor.w / scale, cursor.h / scale};
    c.exact = true;
    return c;
}

} // namespace omacvm_ime
