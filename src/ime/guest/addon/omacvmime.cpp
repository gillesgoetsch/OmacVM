// OmacVM mac-ime: an Fcitx5 module (not an input method engine) that lets
// the Mac's input methods type into Omarchy (docs/adr/0043-mac-ime.md).
//
// It runs inside the Fcitx5 that Omarchy already starts, so every frontend
// Fcitx5 has (Wayland input method v2, text-input-v1 for Chromium, D-Bus for
// Qt and GTK, XIM) and the guest's own engines keep working. It tells the
// Mac (OmacVM.app's window, over the virtio port org.omacvm.ime) which kind
// of field has the focus and where its caret is, and puts what the Mac's
// input method composes into that field: the preedit while it is composed,
// the text once it is chosen. Keys never pass through here: the Mac sends
// them as before, or gives them to its input method.
//
// Threading: everything runs in Fcitx5's event loop (one thread).
#include <fcitx-utils/event.h>
#if __has_include(<fcitx-utils/eventloopinterface.h>)
#include <fcitx-utils/eventloopinterface.h>   // Fcitx5 5.1.9 and newer
#endif
#include <fcitx-utils/log.h>
#include <fcitx-utils/textformatflags.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx/userinterface.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <memory>
#include <optional>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>
#include <dirent.h>

#include "protocol.h"

namespace {

FCITX_DEFINE_LOG_CATEGORY(omacvm_ime_log, "omacvm-ime");
#define IME_INFO() FCITX_LOGC(::omacvm_ime_log, Info)

using namespace omacvm_ime;

// Overridable for the tests (src/ime/tests/addon-test.sh).
std::string portPath() {
    const char *p = std::getenv("OMACVM_IME_PORT");
    return p && *p ? p : "/dev/virtio-ports/org.omacvm.ime";
}

// Hyprland's socket for this session ($XDG_RUNTIME_DIR/hypr/<signature>),
// as omacvm-displays finds it: the signature from the environment, else the
// newest folder with a socket.
std::string hyprSocket() {
    const char *run = std::getenv("XDG_RUNTIME_DIR");
    if (!run || !*run) {
        return {};
    }
    std::string base = std::string(run) + "/hypr";
    const char *sig = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
    struct stat st;
    if (sig && *sig) {
        std::string s = base + "/" + sig + "/.socket.sock";
        if (stat(s.c_str(), &st) == 0) {
            return s;
        }
    }
    std::string best;
    time_t newest = 0;
    if (DIR *d = opendir(base.c_str())) {
        while (struct dirent *e = readdir(d)) {
            if (e->d_name[0] == '.') {
                continue;
            }
            std::string s = base + "/" + e->d_name + "/.socket.sock";
            if (stat(s.c_str(), &st) == 0 && st.st_mtime >= newest) {
                newest = st.st_mtime;
                best = s;
            }
        }
        closedir(d);
    }
    return best;
}

// One request on Hyprland's socket (j/activewindow, j/layers), its answer or
// "" once `deadline` (CLOCK_MONOTONIC, µs) has passed: Hyprland answers in
// ~1 ms, and a caret never holds Fcitx5's loop for more than that budget.
std::string hyprRequest(const char *request, uint64_t deadline) {
    auto left = [deadline]() -> uint64_t {
        uint64_t now = fcitx::now(CLOCK_MONOTONIC);
        return now + 1000 < deadline ? deadline - now : 0;
    };
    auto limit = [](int fd, uint64_t usec) {
        struct timeval tv = {time_t(usec / 1000000), suseconds_t(usec % 1000000)};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    };
    std::string path = hyprSocket();
    struct sockaddr_un addr = {};
    uint64_t usec = left();
    if (path.empty() || path.size() >= sizeof(addr.sun_path) || !usec) {
        return {};
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return {};
    }
    limit(fd, usec);
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size());
    std::string reply;
    size_t len = std::strlen(request);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0 &&
        write(fd, request, len) == ssize_t(len)) {
        char buf[4096];
        ssize_t n;
        while (reply.size() < 256 * 1024 && (usec = left())) {
            limit(fd, usec);
            if ((n = read(fd, buf, sizeof buf)) <= 0) {
                break;
            }
            reply.append(buf, size_t(n));
        }
    }
    close(fd);
    return reply;
}

// /proc/PID/comm and the file name of /proc/PID/exe (the same user's
// processes: Fcitx5 runs in the desktop session).
ProcName procName(long pid) {
    ProcName p;
    if (pid <= 0) {
        return p;
    }
    std::string dir = "/proc/" + std::to_string(pid);
    int fd = ::open((dir + "/comm").c_str(), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        char buf[64];
        ssize_t n = read(fd, buf, sizeof buf);
        close(fd);
        if (n > 0) {
            p.comm.assign(buf, size_t(n));
            while (!p.comm.empty() && p.comm.back() == '\n') {
                p.comm.pop_back();
            }
        }
    }
    char link[4096];
    ssize_t n = readlink((dir + "/exe").c_str(), link, sizeof link);
    if (n > 0 && size_t(n) < sizeof link) {
        p.exe = exeName(std::string_view(link, size_t(n)));
    }
    return p;
}

class OmacVMIme : public fcitx::AddonInstance {
public:
    explicit OmacVMIme(fcitx::Instance *instance) : instance_(instance) {
        using fcitx::EventType;
        auto watch = [this](EventType type, void (OmacVMIme::*fn)(fcitx::InputContext *)) {
            watchers_.push_back(instance_->watchEvent(
                type, fcitx::EventWatcherPhase::Default, [this, fn](fcitx::Event &event) {
                    auto &e = static_cast<fcitx::InputContextEvent &>(event);
                    (this->*fn)(e.inputContext());
                }));
        };
        watch(EventType::InputContextFocusIn, &OmacVMIme::focusIn);
        watch(EventType::InputContextFocusOut, &OmacVMIme::focusOut);
        watch(EventType::InputContextDestroyed, &OmacVMIme::focusOut);
        watch(EventType::InputContextCursorRectChanged, &OmacVMIme::rectChanged);
        watch(EventType::InputContextCapabilityChanged, &OmacVMIme::kindChanged);
        watch(EventType::InputContextReset, &OmacVMIme::reset);
        open();
    }

    ~OmacVMIme() override {
        // Fcitx5 stops: the Mac sends keys as keys again at once.
        io_.reset();
        if (fd_ >= 0) {
            outbox_.clear();
            queue(focusOffLine());
            close(fd_);
        }
    }

private:
    fcitx::Instance *instance_;
    int fd_ = -1;
    std::unique_ptr<fcitx::EventSourceIO> io_;
    std::unique_ptr<fcitx::EventSourceTime> retry_;
    std::unique_ptr<fcitx::EventSourceTime> rectTimer_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> watchers_;
    fcitx::TrackableObjectReference<fcitx::InputContext> focused_;
    LineReader reader_;
    std::string outbox_;
    std::string lastRect_;
    bool lastPassword_ = false;
    bool composing_ = false;

    fcitx::EventLoop &loop() { return instance_->eventLoop(); }

    // Later: the port again (not there yet), or the Mac (not connected yet).
    // One timer, armed again each time (a source is never freed inside its
    // own callback).
    void retryIn(uint64_t usec) {
        uint64_t when = fcitx::now(CLOCK_MONOTONIC) + usec;
        if (retry_) {
            retry_->setTime(when);
            retry_->setOneShot();
            return;
        }
        retry_ = loop().addTimeEvent(CLOCK_MONOTONIC, when, 0, [this](fcitx::EventSourceTime *, uint64_t) {
            if (fd_ < 0) {
                open();
            } else {
                flush();
                if (io_) {
                    io_->setEnabled(true);
                }
            }
            return true;
        });
    }

    void open() {
        int fd = ::open(portPath().c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOCTTY);
        if (fd < 0) {
            // OmacVM.app adds the port at the VM's start when mac-ime is on.
            retryIn(30 * 1000000ull);
            return;
        }
        fd_ = fd;
        IME_INFO() << "port open: " << portPath();
        io_ = loop().addIOEvent(fd_, fcitx::IOEventFlag::In,
                                [this](fcitx::EventSourceIO *, int, fcitx::IOEventFlags flags) {
                                    readable(flags);
                                    return true;
                                });
        queue(helloLine());
        sendFocus();
    }

    void readable(fcitx::IOEventFlags flags) {
        char buf[4096];
        ssize_t n = read(fd_, buf, sizeof buf);
        if (n > 0) {
            reader_.feed(buf, size_t(n), [this](std::string_view line) { macLine(line); });
            return;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR) && !(flags & fcitx::IOEventFlag::Hup)) {
            return;
        }
        // The Mac is not connected (the port reports hang-up until it is):
        // look again in a second; it says hello when it connects.
        reader_.reset();
        io_->setEnabled(false);
        retryIn(1000000);
    }

    void queue(const std::string &line) {
        if (fd_ < 0) {
            return;
        }
        if (outbox_.size() > 64 * 1024) {
            // The Mac has not read for a long time: only the newest state matters.
            outbox_.clear();
        }
        outbox_ += line;
        outbox_ += '\n';
        flush();
    }

    void flush() {
        while (fd_ >= 0 && !outbox_.empty()) {
            ssize_t n = write(fd_, outbox_.data(), outbox_.size());
            if (n > 0) {
                outbox_.erase(0, size_t(n));
            } else if (n < 0 && errno == EINTR) {
                continue;
            } else {
                // EAGAIN: the Mac is not connected; sent with the next retry.
                return;
            }
        }
    }

    fcitx::InputContext *focused() {
        fcitx::InputContext *ic = focused_.get();
        return ic && ic->hasFocus() ? ic : nullptr;
    }

    static bool password(fcitx::InputContext *ic) {
        auto caps = ic->capabilityFlags();
        return caps.test(fcitx::CapabilityFlag::Password) ||
               caps.test(fcitx::CapabilityFlag::Sensitive);
    }

    Caret caret(fcitx::InputContext *ic) {
        const fcitx::Rect &r = ic->cursorRect();
        Rect cursor{double(r.left()), double(r.top()), double(r.width()), double(r.height())};
        bool relative = ic->capabilityFlags().test(fcitx::CapabilityFlag::RelativeRect);
        const std::string &program = ic->program();
        // Both requests share one budget: Fcitx5's loop waits for them.
        uint64_t deadline = fcitx::now(CLOCK_MONOTONIC) + 150000;
        auto window = parseHyprActive(hyprRequest("j/activewindow", deadline));
        std::vector<std::pair<long, ProcName>> known;   // each pid read once
        NameOf names = [&known](long pid) {
            for (const auto &k : known) {
                if (k.first == pid) {
                    return k.second;
                }
            }
            known.emplace_back(pid, procName(pid));
            return known.back().second;
        };
        std::optional<std::vector<HyprLayer>> layers;
        if (layerCandidate(cursor, relative, program, window, names)) {
            // A layer surface (Omarchy 4.5's menu) may hold the caret (#357).
            layers = parseHyprLayers(hyprRequest("j/layers", deadline));
        }
        return caretOn(cursor, ic->scaleFactor(), relative, program, window, layers, names);
    }

    void sendFocus() {
        fcitx::InputContext *ic = focused();
        if (!ic) {
            queue(focusOffLine());
            return;
        }
        Caret c = caret(ic);
        lastRect_ = c.rect ? rectLine(*c.rect, c.exact) : "";
        lastPassword_ = password(ic);
        queue(focusLine(lastPassword_, c.rect, c.exact));
    }

    void focusIn(fcitx::InputContext *ic) {
        if (!ic) {
            return;
        }
        clearPreedit(focused());
        focused_ = ic->watch();
        sendFocus();
    }

    void focusOut(fcitx::InputContext *ic) {
        if (!ic || ic != focused_.get()) {
            return;
        }
        focused_.unwatch();
        composing_ = false;
        queue(focusOffLine());
    }

    // Apps change their capabilities often (GTK after each commit): only a
    // field that turned into a password field or back is news for the Mac.
    void kindChanged(fcitx::InputContext *ic) {
        if (ic && ic == focused() && password(ic) != lastPassword_) {
            sendFocus();
        }
    }

    void reset(fcitx::InputContext *ic) {
        if (ic && ic == focused() && composing_) {
            composing_ = false;
            queue(resetLine());
        }
    }

    // One rectangle per frame at most (a caret that moves with every key).
    void rectChanged(fcitx::InputContext *ic) {
        if (!ic || ic != focused() || rectPending_) {
            return;
        }
        rectPending_ = true;
        uint64_t when = fcitx::now(CLOCK_MONOTONIC) + 16000;
        if (rectTimer_) {
            rectTimer_->setTime(when);
            rectTimer_->setOneShot();
            return;
        }
        rectTimer_ = loop().addTimeEvent(CLOCK_MONOTONIC, when, 0, [this](fcitx::EventSourceTime *, uint64_t) {
            rectPending_ = false;
            if (fcitx::InputContext *f = focused()) {
                Caret c = caret(f);
                if (c.rect) {
                    std::string line = rectLine(*c.rect, c.exact);
                    if (line != lastRect_) {
                        lastRect_ = line;
                        queue(line);
                    }
                }
            }
            return true;
        });
    }
    bool rectPending_ = false;

    static void setPreedit(fcitx::InputContext *ic, const fcitx::Text &text) {
        auto &panel = ic->inputPanel();
        if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
            panel.setClientPreedit(text);
            panel.setPreedit(fcitx::Text());
        } else {
            // The app draws no preedit: Fcitx5's own panel shows it.
            panel.setClientPreedit(fcitx::Text());
            panel.setPreedit(text);
        }
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    void clearPreedit(fcitx::InputContext *ic) {
        if (ic && composing_) {
            setPreedit(ic, fcitx::Text());
        }
        composing_ = false;
    }

    void macLine(std::string_view line) {
        MacMessage m = parseMac(line);
        fcitx::InputContext *ic = focused();
        switch (m.kind) {
        case MacMessage::Kind::Hello:
            // The Mac (re)connected: it knows nothing yet.
            queue(helloLine());
            sendFocus();
            return;
        case MacMessage::Kind::Cancel:
            clearPreedit(ic);
            return;
        case MacMessage::Kind::Commit:
            if (ic && !password(ic)) {
                clearPreedit(ic);
                ic->commitString(m.text);
            }
            return;
        case MacMessage::Kind::Preedit: {
            if (!ic || password(ic)) {
                return;
            }
            if (m.text.empty()) {
                clearPreedit(ic);
                return;
            }
            fcitx::Text text;
            size_t at = 0;
            for (const Segment &s : m.segments) {
                if (s.start > at) {
                    text.append(m.text.substr(at, s.start - at), fcitx::TextFormatFlag::Underline);
                }
                text.append(m.text.substr(s.start, s.end - s.start),
                            s.active ? fcitx::TextFormatFlags{fcitx::TextFormatFlag::HighLight}
                                     : fcitx::TextFormatFlags{fcitx::TextFormatFlag::Underline});
                at = s.end;
            }
            if (at < m.text.size()) {
                text.append(m.text.substr(at), fcitx::TextFormatFlag::Underline);
            }
            text.setCursor(int(m.cursor));
            composing_ = true;
            setPreedit(ic, text);
            return;
        }
        case MacMessage::Kind::Invalid:
            return;
        }
    }
};

class OmacVMImeFactory : public fcitx::AddonFactory {
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new OmacVMIme(manager->instance());
    }
};

} // namespace

#ifdef FCITX_ADDON_FACTORY_V2_BACKWARDS
FCITX_ADDON_FACTORY_V2_BACKWARDS(omacvmime, OmacVMImeFactory)
#else
FCITX_ADDON_FACTORY(OmacVMImeFactory)
#endif
