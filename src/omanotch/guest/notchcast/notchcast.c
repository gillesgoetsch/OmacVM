// notchcast — stream the Omarchy bar from a hidden Hyprland output to the
// macOS notch helper, and relay the helper's input back to the bar.
//
// Capture: ext-image-copy-capture-v1 session on the output named $NOTCHBAR_OUTPUT
// (default NOTCH), shared-memory buffer. A capture request blocks until
// Hyprland re-renders the output, so an idle bar costs nothing.
//
// Stream: TCP client to the Mac on port $NOTCHBAR_PORT (default 47811). The
// Mac is found by itself on the hypervisors' shared (NAT) networks: the
// default gateway (UTM, where the gateway is the Mac) and address .2 of that
// network (Parallels, where .1 is its NAT and the Mac is .2) are tried in turn
// (VMware Fusion: .1 of the gateway's network, see host_candidates),
// but only when that network is a known VM network ($NOTCHBAR_VM_NETS, default
// 192.168.64.0/24 10.211.55.0/24 10.37.129.0/24): on a bridged network the
// gateway is a real router. $NOTCHBAR_HOST (one address or a comma-separated
// list) sets the Mac's address explicitly. Each
// change is sent as the bounding box of changed pixels, LZ4-compressed. A full
// frame is sent after every (re)connect.
// OmacVM.app's VMs (OMACVM_VM_TYPE=app) reach the Mac's 127.0.0.1, where any
// Mac program could listen: there both sides first prove they know OmacVM's
// Bridge token (see handshake), and the token itself is never sent.
//
// Input/control: the helper sends text lines; they are validated and passed to
// the bar's "notchbar" IPC target (`qs ipc call`), never through a shell.
//
// Cursor: Hyprland draws the software cursor into every output that contains
// it, and the hidden output overlaps the top of the built-in display. The
// cursor area is therefore masked with the last clean pixels.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <lz4.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#define FRAME_MAGIC 0x4843544eu  // "NTCH" little-endian
#define TEXT_MAGIC 0x5458544eu   // "NTXT"
#define CURSOR_MAGIC 0x5255434eu // "NCUR"
#define CURSOR_BEFORE 28         // logical px masked left of / above the hotspot
#define CURSOR_AFTER 44          // logical px masked right of / below the hotspot

struct __attribute__((packed)) frame_header {
    uint32_t magic;
    uint32_t seq;
    uint16_t full_w, full_h;  // frame size in pixels
    uint16_t x, y, w, h;      // rectangle carried by this message
    uint8_t codec;            // 0 = raw, 1 = LZ4 block
    uint8_t format;           // wl_shm format (0 ARGB8888, 1 XRGB8888): BGRA bytes
    uint16_t scale;           // output scale x100
    uint32_t payload_len;
};

struct __attribute__((packed)) text_header {
    uint32_t magic;
    uint32_t len;
};

static const char *cfg_output, *cfg_host, *cfg_shell;
// The display whose bar the strip stands in for (the built-in one): see
// update_screen. Read through screen_name(): the keeper thread changes it.
static char cfg_screen_buf[64] = "Virtual-1";
static pthread_mutex_t screen_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *screen_name(char out[64]) {
    pthread_mutex_lock(&screen_lock);
    memcpy(out, cfg_screen_buf, 64);
    pthread_mutex_unlock(&screen_lock);
    return out;
}
// Set by the keeper: close the capture session, then remove and create the
// hidden output again (see keeper_thread).
static _Atomic int remake_output;
// Height of the Mac's black strip in points (`strip H`); 0 until reported.
// The hidden output is made this tall so the strip needs no padding.
static _Atomic int strip_height;
static int cfg_port;
static int verbose;

// Shared between the capture thread and the network thread.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int sock_fd = -1;
static uint8_t *prev;  // last frame as sent (cursor-masked)
static uint32_t W, H, fmt = UINT32_MAX;
static int have_frame;
static uint32_t seq;
static int scale100 = 200;

static void logf_(const char *f, ...) {
    va_list a;
    va_start(a, f);
    fprintf(stderr, "notchcast: ");
    vfprintf(stderr, f, a);
    fputc('\n', stderr);
    va_end(a);
}
#define LOG(...) logf_(__VA_ARGS__)
#define DBG(...) do { if (verbose) logf_(__VA_ARGS__); } while (0)

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// ---------------------------------------------------------------- network --

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

// Caller holds `lock`. Only shuts the socket down: the network thread owns
// the descriptor and closes it once its recv() returns, so the number cannot
// be reused by another thread while it is still in use.
static void drop_socket_locked(void) {
    if (sock_fd >= 0) {
        shutdown(sock_fd, SHUT_RDWR);
        sock_fd = -1;
    }
}

// Caller holds `lock`. Sends rows [y, y+h) x [x, x+w) of `src` (stride W*4).
static void send_rect_locked(const uint8_t *src, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (sock_fd < 0 || !w || !h) return;
    size_t raw_len = (size_t)w * h * 4;
    uint8_t *raw = malloc(raw_len);
    int bound = LZ4_compressBound((int)raw_len);
    uint8_t *packed = malloc((size_t)bound);
    if (!raw || !packed) {
        free(raw);
        free(packed);
        return;
    }
    for (uint32_t r = 0; r < h; r++)
        memcpy(raw + (size_t)r * w * 4, src + ((size_t)(y + r) * W + x) * 4, (size_t)w * 4);
    int clen = LZ4_compress_default((const char *)raw, (char *)packed, (int)raw_len, bound);
    struct frame_header hd = {
        .magic = FRAME_MAGIC, .seq = ++seq, .full_w = (uint16_t)W, .full_h = (uint16_t)H,
        .x = (uint16_t)x, .y = (uint16_t)y, .w = (uint16_t)w, .h = (uint16_t)h,
        .format = (uint8_t)fmt, .scale = (uint16_t)scale100,
    };
    const uint8_t *payload = raw;
    if (clen > 0 && (size_t)clen < raw_len) {
        hd.codec = 1;
        hd.payload_len = (uint32_t)clen;
        payload = packed;
    } else {
        hd.codec = 0;
        hd.payload_len = (uint32_t)raw_len;
    }
    if (write_all(sock_fd, &hd, sizeof hd) || write_all(sock_fd, payload, hd.payload_len)) {
        LOG("send failed (%s), dropping connection", strerror(errno));
        drop_socket_locked();
    }
    free(raw);
    free(packed);
}

// Caller holds `lock`.
static int send_text_fd(int fd, const char *s) {
    struct text_header th = {.magic = TEXT_MAGIC, .len = (uint32_t)strlen(s)};
    return write_all(fd, &th, sizeof th) || write_all(fd, s, th.len) ? -1 : 0;
}

static void send_text_locked(const char *s) {
    if (sock_fd >= 0 && send_text_fd(sock_fd, s)) drop_socket_locked();
}

static void send_text(const char *s) {
    pthread_mutex_lock(&lock);
    send_text_locked(s);
    pthread_mutex_unlock(&lock);
}

// Session lock. Omarchy's lock screen puts a lock surface (with the password
// field) on every output, the hidden NOTCH one too, and lock surfaces sit above
// everything. While the session is locked nothing is streamed and the helper
// shows a black strip instead ("lock 1"). Hyprland has no lock query, but
// every monitor lists LOCK in solitaryBlockedBy while a session lock is active
// (Omarchy's omarchy-hyprland-session-locked relies on the same).
static int session_locked;  // as last told to the helper; under `lock`
static char *hypr_request(const char *req);

static int query_session_locked(void) {
    char *j = hypr_request("j/monitors all");
    int locked = j && strstr(j, "\"LOCK\"") != NULL;
    free(j);
    return locked;
}

// Runs `qs ipc call -- notchbar <fn> <args...>`; returns its stdout (malloc'd)
// when want_output is set. A call that fails is logged with qs's own words (at
// most every 30 s), so a bar that does not park says why in the journal.
static char *ipc_call(int want_output, const char *fn, const char *a1, const char *a2, const char *a3) {
    int pfd[2] = {-1, -1};
    if (want_output && pipe2(pfd, O_CLOEXEC)) return NULL;
    // qs's stderr goes to a memory file: it can never block the call.
    int efd = memfd_create("notchcast-ipc", MFD_CLOEXEC);
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        dup2(devnull, 0);
        dup2(want_output ? pfd[1] : devnull, 1);
        dup2(efd >= 0 ? efd : devnull, 2);
        const char *argv[12];
        int n = 0;
        argv[n++] = "qs";
        argv[n++] = "ipc";
        argv[n++] = "-n";
        argv[n++] = "-p";
        argv[n++] = cfg_shell;
        argv[n++] = "call";
        argv[n++] = "--";
        argv[n++] = "notchbar";
        argv[n++] = fn;
        if (a1) argv[n++] = a1;
        if (a2) argv[n++] = a2;
        if (a3) argv[n++] = a3;
        argv[n] = NULL;
        execvp("qs", (char **)argv);
        _exit(127);
    }
    char *out = NULL;
    if (want_output) {
        close(pfd[1]);
        size_t cap = 4096, len = 0;
        out = malloc(cap);
        ssize_t r;
        while (out && (r = read(pfd[0], out + len, cap - len - 1)) > 0) {
            len += (size_t)r;
            if (cap - len < 2) out = realloc(out, cap *= 2);
        }
        if (out) {
            out[len] = 0;
            while (len && (out[len - 1] == '\n' || out[len - 1] == '\r')) out[--len] = 0;
        }
        close(pfd[0]);
    }
    int status = 0;
    if (pid > 0 && waitpid(pid, &status, 0) == pid &&
        !(WIFEXITED(status) && WEXITSTATUS(status) == 0)) {
        // At most every 30 s per function; the net thread and the worker both call here.
        static pthread_mutex_t said_lock = PTHREAD_MUTEX_INITIALIZER;
        static struct { char fn[24]; time_t at; } said[8];
        time_t now = time(NULL);
        int say = 0;
        pthread_mutex_lock(&said_lock);
        int k = 0, oldest = 0;
        for (; k < 8 && said[k].fn[0] && strcmp(said[k].fn, fn); k++)
            if (said[k].at < said[oldest].at) oldest = k;
        if (k == 8) k = oldest;
        if (strcmp(said[k].fn, fn) || now - said[k].at >= 30) {
            snprintf(said[k].fn, sizeof said[k].fn, "%s", fn);
            said[k].at = now;
            say = 1;
        }
        pthread_mutex_unlock(&said_lock);
        if (say) {
            char why[240] = "";
            ssize_t n = efd >= 0 ? pread(efd, why, sizeof why - 1, 0) : 0;
            why[n > 0 ? n : 0] = 0;
            why[strcspn(why, "\n")] = 0;
            LOG("ipc %s failed (%s %d)%s%s", fn, WIFEXITED(status) ? "exit" : "signal",
                  WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status), *why ? ": " : "", why);
        }
    } else if (pid < 0) {
        LOG("ipc %s: fork failed: %s", fn, strerror(errno));
    }
    if (efd >= 0) close(efd);
    return out;
}

static char *hypr_request(const char *req);
static int json_int(const char *json, const char *key, double *out);
static int monitor_field(const char *json, const char *name, const char *field, double *out);

// Runs Lua in Hyprland through its command socket (no hyprctl process).
static void hypr_eval(const char *lua) {
    char *req;
    if (asprintf(&req, "eval %s", lua) < 0) return;
    free(hypr_request(req));
    free(req);
}

// ------------------------------------------------------------- cursors --

// Guest cursor images are sent to the helper so the strip shows the same
// cursor as the VM. Xcursor files: "Xcur" header, TOC of (type, subtype, pos);
// image chunks (type 0xfffd0002, subtype = nominal size) hold a 36-byte header
// then width*height premultiplied ARGB32 pixels.
static char *cursor_path(const char *name) {
    const char *home = getenv("HOME");
    const char *env_theme = getenv("XCURSOR_THEME");
    const char *themes[] = {env_theme, "default", "Adwaita", NULL};
    for (int t = 0; t < 3; t++) {
        if (!themes[t] || !*themes[t]) continue;
        const char *bases[] = {"%s/.local/share/icons/%s/cursors/%s", "%s/.icons/%s/cursors/%s",
                               "/usr/share/icons/%s/cursors/%s"};
        for (int b = 0; b < 3; b++) {
            char *path = NULL;
            int r = b < 2 ? asprintf(&path, bases[b], home ? home : "", themes[t], name)
                          : asprintf(&path, bases[b], themes[t], name);
            if (r > 0 && access(path, R_OK) == 0) return path;
            free(path);
        }
    }
    return NULL;
}

static void send_cursor(const char *label, const char *const names[], int nominal_wanted) {
    char *path = NULL;
    for (int i = 0; names[i] && !path; i++) path = cursor_path(names[i]);
    if (!path) return;
    FILE *f = fopen(path, "rb");
    free(path);
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = size > 16 && size < (8 << 20) ? malloc((size_t)size) : NULL;
    if (!d || fread(d, 1, (size_t)size, f) != (size_t)size || memcmp(d, "Xcur", 4)) {
        free(d);
        fclose(f);
        return;
    }
    fclose(f);
    uint32_t ntoc, best_pos = 0, best_nom = 0;
    memcpy(&ntoc, d + 12, 4);
    for (uint32_t i = 0; i < ntoc && 16 + (i + 1) * 12 <= (uint32_t)size; i++) {
        uint32_t type, sub, pos;
        memcpy(&type, d + 16 + i * 12, 4);
        memcpy(&sub, d + 20 + i * 12, 4);
        memcpy(&pos, d + 24 + i * 12, 4);
        if (type != 0xfffd0002u) continue;
        // Exact size if available, otherwise the smallest larger one, otherwise the largest.
        int better = !best_nom || (sub == (uint32_t)nominal_wanted) ||
                     (best_nom != (uint32_t)nominal_wanted &&
                      ((sub > (uint32_t)nominal_wanted && (best_nom < (uint32_t)nominal_wanted || sub < best_nom)) ||
                       (best_nom < (uint32_t)nominal_wanted && sub > best_nom)));
        if (better) {
            best_nom = sub;
            best_pos = pos;
        }
    }
    uint32_t hdr[9];
    if (!best_nom || (size_t)best_pos + 36 > (size_t)size) {
        free(d);
        return;
    }
    memcpy(hdr, d + best_pos, 36);
    uint32_t w = hdr[4], h = hdr[5], xh = hdr[6], yh = hdr[7];
    size_t pix = (size_t)w * h * 4;
    if (w > 256 || h > 256 || (size_t)best_pos + 36 + pix > (size_t)size) {
        free(d);
        return;
    }
    size_t nlen = strlen(label);
    size_t body = 1 + nlen + 10 + pix;
    uint8_t *msg = malloc(8 + body);
    if (!msg) {
        free(d);
        return;
    }
    uint32_t magic = CURSOR_MAGIC, blen = (uint32_t)body;
    memcpy(msg, &magic, 4);
    memcpy(msg + 4, &blen, 4);
    uint8_t *p = msg + 8;
    *p++ = (uint8_t)nlen;
    memcpy(p, label, nlen);
    p += nlen;
    uint16_t v[5] = {(uint16_t)w, (uint16_t)h, (uint16_t)xh, (uint16_t)yh, (uint16_t)best_nom};
    memcpy(p, v, 10);
    p += 10;
    memcpy(p, d + best_pos + 36, pix);
    pthread_mutex_lock(&lock);
    if (sock_fd >= 0 && write_all(sock_fd, msg, 8 + body)) drop_socket_locked();
    pthread_mutex_unlock(&lock);
    free(msg);
    free(d);
}

static void send_cursors(void) {
    int size = getenv("XCURSOR_SIZE") ? atoi(getenv("XCURSOR_SIZE")) : 24;
    if (size <= 0) size = 24;
    int nominal = (int)(size * (scale100 / 100.0) + 0.5);
    const char *arrow[] = {"default", "left_ptr", "arrow", NULL};
    const char *hand[] = {"pointer", "hand2", "hand1", NULL};
    // The cursor's size in logical px: Hyprland scales whichever theme image
    // it picks to exactly this, so the helper sizes the image by it too.
    char msg[32];
    snprintf(msg, sizeof msg, "cursorsize %d", size);
    send_text(msg);
    send_cursor("arrow", arrow, nominal);
    send_cursor("pointer", hand, nominal);
}

// VMware Fusion moves the Mac's pointer when the guest moves its cursor, so
// on Fusion the guest cursor is never moved from here: that pulled the Mac's
// pointer straight back out of the strip.
static int on_vmware(void) {
    static int v = -1;
    if (v >= 0) return v;
    char vendor[64] = "";
    FILE *f = fopen("/sys/class/dmi/id/sys_vendor", "r");
    if (f) {
        if (!fgets(vendor, sizeof vendor, f)) vendor[0] = 0;
        fclose(f);
    }
    return v = strstr(vendor, "VMware") != NULL;
}

// Hides or shows the guest's own cursor (while the pointer is over the strip
// the helper shows the guest's cursor images itself).
static void set_guest_cursor_visible(int visible) {
    if (visible) {
        hypr_eval("hl.config({ cursor = { invisible = false } })");
        return;
    }
    if (on_vmware()) {
        hypr_eval("hl.config({ cursor = { invisible = true } })");
        return;
    }
    // Hyprland applies `invisible` only at its next repaint, and nothing
    // repaints while the pointer sits on the strip, so the old cursor image
    // lingered (~50-100 ms measured). A 1 px nudge makes it repaint at once
    // (~0-40 ms measured).
    char *j = hypr_request("j/cursorpos");
    double x, y;
    if (j && !json_int(j, "x", &x) && !json_int(j, "y", &y)) {
        char lua[160];
        snprintf(lua, sizeof lua,
                 "hl.config({ cursor = { invisible = true } }) hl.dispatch(hl.dsp.cursor.move({ x = %d, y = %d }))",
                 (int)x, (int)y + 1);
        hypr_eval(lua);
    } else {
        hypr_eval("hl.config({ cursor = { invisible = true } })");
    }
    free(j);
}

// Shows the guest cursor again where the pointer leaves the strip: just below
// the top edge of the built-in display ("down"), or just above it on the
// display arranged above ("up"). Without this the cursor would reappear where
// it was hidden and jump once Parallels reports the next position.
static void show_guest_cursor_at_exit(const char *dir, double strip_x, double depth) {
    if (on_vmware()) {   // Fusion already puts the cursor where the Mac's pointer is
        set_guest_cursor_visible(1);
        return;
    }
    char *j = hypr_request("j/monitors all"), scr[64];
    double x, y, w, s;
    screen_name(scr);
    if (!j || monitor_field(j, scr, "x", &x) || monitor_field(j, scr, "y", &y) ||
        monitor_field(j, scr, "width", &w) || monitor_field(j, scr, "scale", &s) || s <= 0) {
        free(j);
        set_guest_cursor_visible(1);
        return;
    }
    free(j);
    double lw = w / s;
    double tx = x + (strip_x < 0 ? 0 : strip_x > lw - 1 ? lw - 1 : strip_x);
    // depth: how far the pointer already is inside the destination display,
    // measured from the edge it crossed.
    if (depth < 1) depth = 1;
    double ty = !strcmp(dir, "up") ? y - 1 - depth : y + depth;
    char lua[256];
    snprintf(lua, sizeof lua,
             "hl.dispatch(hl.dsp.cursor.move({ x = %d, y = %d })) hl.config({ cursor = { invisible = false } })",
             (int)tx, (int)ty);
    hypr_eval(lua);
}

// ~/.local/state/omanotch/<name> (created on first use). Small files there
// carry the heartbeat and the bar's state without starting any process.
static void state_path(char *out, size_t size, const char *name) {
    const char *state = getenv("XDG_STATE_HOME");
    char dir[512];
    if (state && *state) snprintf(dir, sizeof dir, "%s/omanotch", state);
    else snprintf(dir, sizeof dir, "%s/.local/state/omanotch", getenv("HOME") ? getenv("HOME") : "/tmp");
    static int made;
    if (!made) {
        char parent[512];
        snprintf(parent, sizeof parent, "%s", dir);
        char *slash = strrchr(parent, '/');
        if (slash) *slash = 0;
        mkdir(parent, 0755);
        mkdir(dir, 0755);
        made = 1;
    }
    snprintf(out, size, "%s/%s", dir, name);
}

// Heartbeat for the bar's watchdog: the time in ms, rewritten in place.
static void write_beat(void) {
    char path[600];
    state_path(path, sizeof path, "beat");
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%.0f\n", ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6);
        fclose(f);
    }
}

// The parking the helper asked for, for a shell that starts (or restarts)
// after it was said: "1 <output>" or "0", rewritten in place. The bar (patch
// v14+) reads it with the beat at startup and every few seconds, so a new
// shell parks at once instead of waiting for an IPC call that may have gone
// to the old shell, or to none while the new one was still loading.
static void write_park(int on) {
    char path[600], scr[64];
    state_path(path, sizeof path, "park");
    FILE *f = fopen(path, "w");
    if (!f) return;
    if (on) fprintf(f, "1 %s\n", screen_name(scr));
    else fputs("0\n", f);
    fclose(f);
}

// The bar's own report (bar patch v9+): {"parked":…,"barSize":…,"started":…}.
struct bar_state {
    int parked;
    double bar_size, started;
};
static int read_bar_state(struct bar_state *st) {
    char path[600], buf[256];
    state_path(path, sizeof path, "bar-state");
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = strstr(buf, "\"parked\":"), *b = strstr(buf, "\"barSize\":"), *t = strstr(buf, "\"started\":");
    if (!p || !b || !t) return 0;
    st->parked = !strncmp(p + 9, "true", 4);
    st->bar_size = strtod(b + 10, NULL);
    st->started = strtod(t + 10, NULL);
    return 1;
}

// The hidden output's logical height, remembered for notchbar.lua so a
// Hyprland config reload recreates the output at the right height right away.
static void save_strip_height(int h) {
    char path[600];
    state_path(path, sizeof path, "strip-height");
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%d\n", h);
        fclose(f);
    }
}

#ifndef OMACVM_ENV
#define OMACVM_ENV "/etc/omacvm/env"
#endif

// A value from OmacVM's /etc/omacvm/env (KEY=value, maybe quoted; the last
// one counts). 0 when there is none.
static int omacvm_env(const char *key, char *out, size_t size) {
    char line[512];
    int found = 0;
    size_t kl = strlen(key);
    FILE *f = fopen(OMACVM_ENV, "r");
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, kl) || line[kl] != '=') continue;
        char *v = line + kl + 1;
        v[strcspn(v, "\r\n")] = 0;
        size_t n = strlen(v);
        if (n >= 2 && (*v == '"' || *v == '\'') && v[n - 1] == *v) {
            v[n - 1] = 0;
            v++;
            n -= 2;
        }
        found = n > 0 && n < size;
        if (found) memcpy(out, v, n + 1);
    }
    fclose(f);
    return found;
}

// The VM's name in its app, base64, as OmacVM writes it (OMACVM_VM_NAME_B64).
static int vm_name_b64(char *out, size_t size) {
    return omacvm_env("OMACVM_VM_NAME_B64", out, size) &&
           strspn(out, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=") == strlen(out);
}

// ------------------------------------------------------------ handshake --
// OmacVM.app's VMs reach the helper on the Mac's 127.0.0.1, where any Mac
// program could connect, or listen in the helper's place. So both sides prove
// they know OmacVM's Bridge token, the helper first, and the token itself
// never goes over the wire:
//   challenge <guest nonce>      from here, 32 hex digits
//   proof <mac nonce> <proof>    the helper: HMAC-SHA256(token,
//                                "omanotch mac <addr> <guest nonce> <mac nonce>"), hex;
//                                <addr>: the Mac address it accepted on
//   proof <proof>                from here, the same with "vm"
// <addr> must be 127.0.0.1, so a proof that a listener there fetched from a
// helper on another address fails. Other VMs skip this: there the VM network
// is the check.

// SHA-256 (FIPS 180-4) and HMAC, just for the handshake.
struct sha256 {
    uint32_t h[8];
    uint64_t len;
    uint8_t buf[64];
    size_t n;
};

static const uint32_t sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) ((x) >> (n) | (x) << (32 - (n)))

static void sha256_block(struct sha256 *s, const uint8_t *p) {
    uint32_t w[64], v[8];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ w[i - 15] >> 3;
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ w[i - 2] >> 10;
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    memcpy(v, s->h, sizeof v);
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = v[7] + (ROR(v[4], 6) ^ ROR(v[4], 11) ^ ROR(v[4], 25)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) +
                      sha256_k[i] + w[i];
        uint32_t t2 = (ROR(v[0], 2) ^ ROR(v[0], 13) ^ ROR(v[0], 22)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof *v);
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (int i = 0; i < 8; i++) s->h[i] += v[i];
}

static void sha256_init(struct sha256 *s) {
    static const uint32_t h0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, h0, sizeof h0);
    s->len = 0;
    s->n = 0;
}

static void sha256_update(struct sha256 *s, const void *data, size_t len) {
    const uint8_t *p = data;
    s->len += len;
    while (len) {
        size_t k = 64 - s->n < len ? 64 - s->n : len;
        memcpy(s->buf + s->n, p, k);
        s->n += k;
        p += k;
        len -= k;
        if (s->n == 64) {
            sha256_block(s, s->buf);
            s->n = 0;
        }
    }
}

static void sha256_final(struct sha256 *s, uint8_t out[32]) {
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80, zero = 0, lenb[8];
    sha256_update(s, &pad, 1);
    while (s->n != 56) sha256_update(s, &zero, 1);
    for (int i = 0; i < 8; i++) lenb[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(s, lenb, 8);
    for (int i = 0; i < 32; i++) out[i] = (uint8_t)(s->h[i / 4] >> (24 - 8 * (i % 4)));
}

// HMAC-SHA256(key, msg) in hex.
static void hmac_sha256_hex(const char *key, const char *msg, char out[65]) {
    uint8_t k[64] = {0}, pad[64], inner[32], mac[32];
    size_t kl = strlen(key);
    struct sha256 s;
    if (kl > 64) {
        sha256_init(&s);
        sha256_update(&s, key, kl);
        sha256_final(&s, k);
    } else {
        memcpy(k, key, kl);
    }
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
    sha256_init(&s);
    sha256_update(&s, pad, 64);
    sha256_update(&s, msg, strlen(msg));
    sha256_final(&s, inner);
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
    sha256_init(&s);
    sha256_update(&s, pad, 64);
    sha256_update(&s, inner, 32);
    sha256_final(&s, mac);
    for (int i = 0; i < 32; i++) snprintf(out + 2 * i, 3, "%02x", mac[i]);
}

// The Bridge's token as OmacVM puts it into the VM; 0 when there is none.
static int bridge_token(char *tok, size_t size) {
    const char *home = getenv("HOME");
    char path[512];
    if (!home) return 0;
    snprintf(path, sizeof path, "%s/.config/omacvm-bridge/token", home);
    FILE *t = fopen(path, "r");
    if (!t) return 0;
    if (!fgets(tok, (int)size, t)) tok[0] = 0;
    fclose(t);
    tok[strcspn(tok, "\r\n")] = 0;
    return strlen(tok) >= 32 && strspn(tok, "0123456789abcdefABCDEF") == strlen(tok);
}

static int proof_ok(const char *a, const char *b) {  // constant time, 64 hex digits each
    unsigned char diff = 0;
    for (int i = 0; i < 64; i++) diff |= (unsigned char)(a[i] ^ b[i]);
    return diff == 0;
}

// The handshake above on a fresh connection; 0 once both proofs are through.
static int handshake(int fd, const char *tok) {
    uint8_t r[16];
    char gn[33], mn[33], got[65], want[65], mine[65], msg[160], line[256];
    if (getrandom(r, sizeof r, 0) != (ssize_t)sizeof r) return -1;
    for (int i = 0; i < 16; i++) snprintf(gn + 2 * i, 3, "%02x", r[i]);
    snprintf(msg, sizeof msg, "challenge %s", gn);
    if (send_text_fd(fd, msg)) return -1;
    struct timeval tv = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    size_t n = 0;
    while (n < sizeof line - 1 && !memchr(line, '\n', n)) {
        ssize_t k = recv(fd, line + n, sizeof line - 1 - n, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) {
            LOG("the helper answered no proof (Omanotch on the Mac from before the handshake? update it)");
            return -1;
        }
        n += (size_t)k;
    }
    line[n] = 0;
    line[strcspn(line, "\n")] = 0;
    if (sscanf(line, "proof %32[0-9a-f] %64[0-9a-f]", mn, got) != 2 || strlen(mn) != 32 || strlen(got) != 64) {
        LOG("the helper answered no proof: not talking to it");
        return -1;
    }
    snprintf(msg, sizeof msg, "omanotch mac 127.0.0.1 %s %s", gn, mn);
    hmac_sha256_hex(tok, msg, want);
    if (!proof_ok(got, want)) {
        LOG("the helper did not prove it knows the Bridge's token: not talking to it");
        return -1;
    }
    snprintf(msg, sizeof msg, "omanotch vm 127.0.0.1 %s %s", gn, mn);
    hmac_sha256_hex(tok, msg, mine);
    snprintf(msg, sizeof msg, "proof %s", mine);
    tv.tv_sec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return send_text_fd(fd, msg);
}

// Tells the helper which hypervisor this guest runs in, so it only takes this
// VM app's full-screen window for the strip ("hello qemu", "hello parallels"),
// and the VM's name for its log and to spot a rebooted OmacVM.app VM
// ("vmname <base64>"; older helpers ignore it).
static void send_hello(void) {
    char vendor[64] = "", msg[96], name[400], namemsg[420];

    FILE *f = fopen("/sys/class/dmi/id/sys_vendor", "r");
    if (f) {
        if (!fgets(vendor, sizeof vendor, f)) vendor[0] = 0;
        fclose(f);
    }
    const char *hv = strstr(vendor, "QEMU") ? "qemu" : strstr(vendor, "Parallels") ? "parallels"
                   : strstr(vendor, "VMware") ? "vmware" : strstr(vendor, "Apple") ? "apple" : "unknown";
    snprintf(msg, sizeof msg, "hello %s", hv);
    send_text(msg);
    if (vm_name_b64(name, sizeof name)) {
        snprintf(namemsg, sizeof namemsg, "vmname %s", name);
        send_text(namemsg);
    }
}

static int is_number(const char *s) {
    if (!s || !*s) return 0;
    char *end;
    strtod(s, &end);
    return *end == 0;
}

// Bar state as last told to the shell (worker thread only). -1: unknown.
#define BEAT_EVERY_MS 4000
static int bar_parked = -1;
static double bar_beat_ms;
static char want_notch_l[32], want_notch_r[32], want_strip[32], want_bar[32];
static char sent_notch_l[32], sent_notch_r[32], sent_strip[32], sent_bar[32];

// The helper's geometry in Mac points (`geom L R H W`, W = strip width).
// Converted here with the built-in display's own logical width, which stays
// put while the hidden output is being resized: a transitional frame on the
// Mac can no longer turn into a wrong strip height. Older helpers send
// `notch`/`strip` already converted; those are ignored once `geom` arrived.
static double mac_l, mac_r, mac_h, mac_w;
static int have_geom;
// The bar's own height in Mac points (`bar H`, Omanotch's flush setting: the
// camera housing's height); 0: the bar fills the strip.
static double mac_bar;

static double screen_logical_width(void) {
    char *j = hypr_request("j/monitors all"), scr[64];
    double w = 0, sc = 0;
    screen_name(scr);
    if (j && !monitor_field(j, scr, "width", &w) && !monitor_field(j, scr, "scale", &sc) && sc > 0)
        w /= sc;
    else
        w = 0;
    free(j);
    return w;
}

static void sync_geometry(int always);

static void apply_mac_geometry(void) {
    double lw = screen_logical_width();
    if (!have_geom || lw <= 0 || mac_w <= 0) return;
    double k = lw / mac_w;
    snprintf(want_notch_l, sizeof want_notch_l, "%.0f", mac_l * k);
    snprintf(want_notch_r, sizeof want_notch_r, "%.0f", mac_r * k);
    snprintf(want_strip, sizeof want_strip, "%.0f", mac_h * k);
    snprintf(want_bar, sizeof want_bar, "%.0f", mac_bar > 0 ? mac_bar * k : 0);
    int h = (int)(mac_h * k + 0.5);
    if (h >= 10 && h <= 200) atomic_store(&strip_height, h);
    sync_geometry(0);
}

// Passes the notch geometry on to the bar when it changed (or always).
static void sync_geometry(int always) {
    if (*want_notch_l && (always || strcmp(want_notch_l, sent_notch_l) || strcmp(want_notch_r, sent_notch_r))) {
        free(ipc_call(0, "setNotch", want_notch_l, want_notch_r, NULL));
        snprintf(sent_notch_l, sizeof sent_notch_l, "%s", want_notch_l);
        snprintf(sent_notch_r, sizeof sent_notch_r, "%s", want_notch_r);
    }
    if (*want_strip && (always || strcmp(want_strip, sent_strip))) {
        free(ipc_call(0, "setNotchHeight", want_strip, NULL, NULL));
        snprintf(sent_strip, sizeof sent_strip, "%s", want_strip);
    }
    if (*want_bar && (always || strcmp(want_bar, sent_bar))) {
        free(ipc_call(0, "setNotchBarHeight", want_bar, NULL, NULL));
        snprintf(sent_bar, sizeof sent_bar, "%s", want_bar);
    }
}

// One command line from the helper. Everything is validated before use.
static void handle_command(char *line) {
    char *argv[6] = {0};
    int argc = 0;
    // strtok_r: the net thread (cursor fast path) and the worker run this at the same time.
    char *save = NULL;
    for (char *tok = strtok_r(line, " \t", &save); tok && argc < 6; tok = strtok_r(NULL, " \t", &save))
        argv[argc++] = tok;
    if (!argc) return;
    const char *c = argv[0];
    DBG("cmd: %s %s %s %s", c, argv[1] ? argv[1] : "", argv[2] ? argv[2] : "", argv[3] ? argv[3] : "");
    // Every call into the bar starts a `qs ipc` process (a Qt program), so
    // they are kept rare: the helper's once-a-second "park 1" becomes one
    // heartbeat every few seconds, and the notch geometry is only passed on
    // when it changes, or again when the heartbeat shows that the shell was
    // restarted (it then starts unparked, from its defaults).
    if (!strcmp(c, "park") && argc == 2) {
        int on = !strcmp(argv[1], "1");
        double now = now_ms();
        if (on != bar_parked || now - bar_beat_ms > BEAT_EVERY_MS) {
            int fresh = 0;
            if (on) write_beat();
            if (on && bar_parked == 1) {
                struct bar_state st;
                static double started;
                if (read_bar_state(&st)) {
                    // Unparked although we keep it parked, or a new shell.
                    // The first read cannot tell an old shell's report from
                    // the current one's: count it as new (one extra call).
                    fresh = !st.parked || st.started != started;
                    started = st.started;
                } else {
                    // A bar patched before v9 only knows the IPC heartbeat.
                    char *r = ipc_call(1, "heartbeat", NULL, NULL, NULL);
                    fresh = !r || strncmp(r, "parked", 6);
                    free(r);
                }
            }
            if (on != bar_parked || fresh) {
                char scr[64];
                write_park(on);  // first: a shell starting right now reads it
                free(ipc_call(0, "setParkedScreen", screen_name(scr), NULL, NULL));
                free(ipc_call(0, "setParked", on ? "true" : "false", NULL, NULL));
                if (on && fresh) sync_geometry(1);
            }
            bar_parked = on;
            bar_beat_ms = now;
        }
    } else if (!strcmp(c, "screen") && argc == 1) {
        // The built-in display is another output now (update_screen).
        char scr[64];
        if (bar_parked == 1) {
            write_park(1);
            free(ipc_call(0, "setParkedScreen", screen_name(scr), NULL, NULL));
        }
    } else if (!strcmp(c, "beat") && argc == 1) {
        free(ipc_call(0, "heartbeat", NULL, NULL, NULL));
    } else if (!strcmp(c, "geom") && argc == 5 && is_number(argv[1]) && is_number(argv[2]) &&
               is_number(argv[3]) && is_number(argv[4])) {
        mac_l = strtod(argv[1], NULL);
        mac_r = strtod(argv[2], NULL);
        mac_h = strtod(argv[3], NULL);
        mac_w = strtod(argv[4], NULL);
        have_geom = mac_w > 0 && mac_h >= 10 && mac_h <= 200;
        apply_mac_geometry();
    } else if (!strcmp(c, "bar") && argc == 2 && is_number(argv[1])) {
        double b = strtod(argv[1], NULL);
        mac_bar = b >= 10 && b <= 200 ? b : 0;
        apply_mac_geometry();
    } else if (!strcmp(c, "regeom") && argc == 1) {
        apply_mac_geometry();  // the built-in display changed size
    } else if (have_geom && (!strcmp(c, "notch") || !strcmp(c, "strip"))) {
        // superseded by geom
    } else if (!strcmp(c, "notch") && argc == 3 && is_number(argv[1]) && is_number(argv[2])) {
        snprintf(want_notch_l, sizeof want_notch_l, "%s", argv[1]);
        snprintf(want_notch_r, sizeof want_notch_r, "%s", argv[2]);
        sync_geometry(0);
    } else if (!strcmp(c, "strip") && argc == 2 && is_number(argv[1])) {
        double h = strtod(argv[1], NULL);
        if (h >= 10 && h <= 200) {
            atomic_store(&strip_height, (int)(h + 0.5));
            snprintf(want_strip, sizeof want_strip, "%s", argv[1]);
            sync_geometry(0);
        }
    } else if (!strcmp(c, "click") && argc == 4 && is_number(argv[1]) && is_number(argv[2]) && is_number(argv[3])) {
        free(ipc_call(0, "click", argv[1], argv[2], argv[3]));
    } else if (!strcmp(c, "wheel") && argc == 4 && is_number(argv[1]) && is_number(argv[2]) && is_number(argv[3])) {
        free(ipc_call(0, "wheel", argv[1], argv[2], argv[3]));
    } else if (!strcmp(c, "targets") && argc == 1) {
        char *out = ipc_call(1, "targets", NULL, NULL, NULL);
        if (out) {
            char *msg;
            if (asprintf(&msg, "targets %s", out) > 0) {
                send_text(msg);
                free(msg);
            }
            free(out);
        }
    } else if (!strcmp(c, "cursor") && argc == 2) {
        set_guest_cursor_visible(!strcmp(argv[1], "1"));
    } else if (!strcmp(c, "cursor") && (argc == 4 || argc == 5) && !strcmp(argv[1], "1") &&
               (!strcmp(argv[2], "down") || !strcmp(argv[2], "up")) && is_number(argv[3]) &&
               (argc == 4 || is_number(argv[4]))) {
        show_guest_cursor_at_exit(argv[2], strtod(argv[3], NULL), argc == 5 ? strtod(argv[4], NULL) : 1);
    } else if (!strcmp(c, "cursors") && argc == 1) {
        send_cursors();
    } else if (!strcmp(c, "key") && argc == 1) {
        // Helper asks for a full frame (e.g. after it re-created its buffer).
        pthread_mutex_lock(&lock);
        int had = have_frame;
        if (had && !session_locked) send_rect_locked(prev, 0, 0, W, H);
        pthread_mutex_unlock(&lock);
        if (!had) free(ipc_call(0, "poke", NULL, NULL, NULL));
    } else {
        LOG("ignored command: %s", c);
    }
}

// Slow commands (each runs a `qs ipc` process, ~25 ms) go through a queue and a
// worker thread, so cursor show/hide never waits behind them.
#define QUEUE_MAX 64
static char *queue_items[QUEUE_MAX];
static int queue_len;
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_cond = PTHREAD_COND_INITIALIZER;

static void enqueue_command(const char *line) {
    pthread_mutex_lock(&queue_lock);
    if (queue_len < QUEUE_MAX) {
        queue_items[queue_len++] = strdup(line);
        pthread_cond_signal(&queue_cond);
    } else {
        LOG("command queue full, dropping: %s", line);
    }
    pthread_mutex_unlock(&queue_lock);
}

static void *worker_thread(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&queue_lock);
        while (!queue_len) pthread_cond_wait(&queue_cond, &queue_lock);
        char *line = queue_items[0];
        memmove(queue_items, queue_items + 1, (size_t)(queue_len - 1) * sizeof(char *));
        queue_len--;
        pthread_mutex_unlock(&queue_lock);
        if (line) {
            handle_command(line);
            free(line);
        }
    }
    return NULL;
}

// Whether an address (network byte order) lies in one of the VM shared
// networks: $NOTCHBAR_VM_NETS, a space- or comma-separated list of a.b.c.d/nn.
static int on_vm_network(uint32_t addr_be) {
    const char *nets = getenv("NOTCHBAR_VM_NETS");
    char buf[512];
    snprintf(buf, sizeof buf, "%s", nets && *nets ? nets : "192.168.64.0/24 10.211.55.0/24 10.37.129.0/24");
    uint32_t a = ntohl(addr_be);
    for (char *save = NULL, *tok = strtok_r(buf, ", ", &save); tok; tok = strtok_r(NULL, ", ", &save)) {
        char *slash = strchr(tok, '/');
        int bits = slash ? atoi(slash + 1) : 32;
        if (slash) *slash = 0;
        struct in_addr net;
        if (inet_pton(AF_INET, tok, &net) != 1 || bits < 0 || bits > 32) continue;
        uint32_t mask = bits ? 0xffffffffu << (32 - bits) : 0;
        if ((a & mask) == (ntohl(net.s_addr) & mask)) return 1;
    }
    return 0;
}

// Candidate addresses of the Mac, in the order they are tried.
static int host_candidates(struct in_addr *out, int max) {
    int n = 0;
    if (cfg_host && *cfg_host) {
        char buf[256];
        snprintf(buf, sizeof buf, "%s", cfg_host);
        for (char *save = NULL, *tok = strtok_r(buf, ", ", &save); tok && n < max; tok = strtok_r(NULL, ", ", &save))
            if (inet_pton(AF_INET, tok, &out[n]) == 1) n++;
        return n;
    }
    // Default route from /proc/net/route: "Iface Destination Gateway ..." in
    // network byte order, printed as hex.
    FILE *f = fopen("/proc/net/route", "r");
    if (!f) return 0;
    char line[256];
    unsigned int gw = 0;
    while (fgets(line, sizeof line, f)) {
        char iface[64];
        unsigned int dest, g, flags;
        if (sscanf(line, "%63s %x %x %x", iface, &dest, &g, &flags) == 4 && dest == 0 && g) {
            gw = g;
            break;
        }
    }
    fclose(f);
    if (!gw) return 0;
    // VMware Fusion: the gateway (.2) is Fusion's NAT, the Mac is .1, and the
    // subnet is picked when Fusion is installed (any private network).
    char vendor[64] = "";
    FILE *v = fopen("/sys/class/dmi/id/sys_vendor", "r");
    if (v) {
        if (!fgets(vendor, sizeof vendor, v)) vendor[0] = 0;
        fclose(v);
    }
    if (strstr(vendor, "VMware")) {
        uint32_t g = ntohl(gw);
        int priv = (g >> 24) == 10 || (g >> 20) == 0xAC1 || (g >> 16) == 0xC0A8;
        if (!priv) return 0;
        out[n++].s_addr = htonl((g & 0xffffff00u) | 1u);
        return n;
    }
    if (!on_vm_network(gw)) {
        static int warned;
        if (!warned++) LOG("the default route is not on a VM shared network (bridged networking?): set NOTCHBAR_HOST");
        return 0;
    }
    out[n++].s_addr = gw;
    uint32_t two = (ntohl(gw) & 0xffffff00u) | 2u;
    if (htonl(two) != gw && n < max) out[n++].s_addr = htonl(two);
    return n;
}

// connect() with a timeout, so an address with nobody behind it (no ARP
// answer) does not stall the rotation for half a minute.
static int connect_timeout(int fd, const struct sockaddr_in *sa, int timeout_ms) {
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, (const struct sockaddr *)sa, sizeof *sa);
    if (r && errno == EINPROGRESS) {
        struct pollfd p = {.fd = fd, .events = POLLOUT};
        int err = 0;
        socklen_t el = sizeof err;
        r = poll(&p, 1, timeout_ms) == 1 && !getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) && !err ? 0 : -1;
    }
    fcntl(fd, F_SETFL, fl);
    return r;
}

static void *net_thread(void *unused) {
    (void)unused;
    int backoff_ms = 250;
    unsigned attempt = 0;
    for (;;) {
        struct in_addr hosts[8];
        int nh = host_candidates(hosts, 8);
        if (!nh) {
            usleep(2000 * 1000);
            continue;
        }
        // OmacVM.app: the handshake needs the Bridge's token.
        char type[16] = "", tok[160] = "";
        int app = omacvm_env("OMACVM_VM_TYPE", type, sizeof type) && !strcmp(type, "app");
        if (app && !bridge_token(tok, sizeof tok)) {
            static int warned;
            if (!warned++) LOG("no Bridge token yet (~/.config/omacvm-bridge/token): waiting for it");
            usleep(2000 * 1000);
            continue;
        }
        struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons((uint16_t)cfg_port),
                                 .sin_addr = hosts[attempt++ % (unsigned)nh]};
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0 || connect_timeout(fd, &sa, 1500)) {
            if (fd >= 0) close(fd);
            // A full round over all candidates failed: back off.
            if (attempt % (unsigned)nh == 0) {
                usleep((useconds_t)backoff_ms * 1000);
                if (backoff_ms < 2000) backoff_ms *= 2;
            }
            continue;
        }
        backoff_ms = 250;
        attempt--;  // keep this address first for the next reconnect
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sa.sin_addr, ip, sizeof ip);
        LOG("connected to %s:%d", ip, cfg_port);
        double connected_at = now_ms();
        int refused = app && handshake(fd, tok);
        explicit_bzero(tok, sizeof tok);
        if (refused) {
            close(fd);
            sleep(3);
            continue;
        }

        pthread_mutex_lock(&lock);
        sock_fd = fd;
        if (session_locked) send_text_locked("lock 1");
        else if (have_frame) send_rect_locked(prev, 0, 0, W, H);  // keyframe
        pthread_mutex_unlock(&lock);
        send_hello();
        send_cursors();

        char buf[4096];
        size_t len = 0;
        for (;;) {
            ssize_t n = recv(fd, buf + len, sizeof buf - 1 - len, 0);
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            len += (size_t)n;
            buf[len] = 0;
            char *start = buf, *nl;
            while ((nl = memchr(start, '\n', len - (size_t)(start - buf)))) {
                *nl = 0;
                if (!strncmp(start, "cursor ", 7)) handle_command(start);  // fast path
                else enqueue_command(start);
                start = nl + 1;
            }
            len -= (size_t)(start - buf);
            memmove(buf, start, len);
            if (len >= sizeof buf - 1) len = 0;  // oversized line: discard
        }
        LOG("helper disconnected");
        enqueue_command("park 0");  // bring the bar back now, not after the watchdog
        pthread_mutex_lock(&lock);
        if (sock_fd == fd) sock_fd = -1;
        pthread_mutex_unlock(&lock);
        close(fd);
        set_guest_cursor_visible(1);
        // Dropped right away: most likely turned away because another VM
        // holds the strip (older helpers serve one VM only). Do not hammer
        // the helper.
        if (now_ms() - connected_at < 2000) sleep(3);
    }
    return NULL;
}

// ------------------------------------------------------- Hyprland socket --

// Sends one request to Hyprland's command socket and returns the reply.
static char *hypr_request(const char *req) {
    const char *rt = getenv("XDG_RUNTIME_DIR"), *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!rt || !sig) return NULL;
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s/hypr/%s/.socket.sock", rt, sig);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return NULL;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) || write_all(fd, req, strlen(req))) {
        close(fd);
        return NULL;
    }
    size_t cap = 8192, len = 0;
    char *out = malloc(cap);
    ssize_t r;
    while (out && (r = read(fd, out + len, cap - len - 1)) > 0) {
        len += (size_t)r;
        if (cap - len < 2) out = realloc(out, cap *= 2);
    }
    close(fd);
    if (out) out[len] = 0;
    return out;
}

static int json_int(const char *json, const char *key, double *out) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(json, pat);
    if (!p) return -1;
    *out = strtod(p + strlen(pat), NULL);
    return 0;
}

// Logical geometry of the capture output.
static double out_x, out_y, out_scale = 2;

static void refresh_output_geometry(void) {
    char *j = hypr_request("j/monitors all");
    if (!j) return;
    double x, y, sc;
    if (!monitor_field(j, cfg_output, "x", &x) && !monitor_field(j, cfg_output, "y", &y) &&
        !monitor_field(j, cfg_output, "scale", &sc) && sc > 0) {
        pthread_mutex_lock(&lock);
        out_x = x;
        out_y = y;
        out_scale = sc;
        scale100 = (int)(sc * 100 + 0.5);
        pthread_mutex_unlock(&lock);
    }
    free(j);
}

static int cursor_pos(double *x, double *y) {
    char *j = hypr_request("j/cursorpos");
    if (!j) return -1;
    int ok = !json_int(j, "x", x) && !json_int(j, "y", y);
    free(j);
    return ok ? 0 : -1;
}

// ----------------------------------------------------- output keeper --

// Reads one numeric field of the monitor object named `name` from a
// `j/monitors all` reply. Returns -1 if absent. The search is limited to that
// monitor's own JSON object (brace-matched), whose nested objects
// (activeWorkspace, specialWorkspace) never contain the fields read here.
static int monitor_field(const char *json, const char *name, const char *field, double *out) {
    char pat[128];
    snprintf(pat, sizeof pat, "\"name\": \"%s\"", name);
    const char *p = strstr(json, pat);
    if (!p) return -1;
    const char *start = p;
    while (start > json && *start != '{') start--;
    if (*start != '{') return -1;
    int depth = 0;
    const char *end = start;
    for (; *end; end++) {
        if (*end == '{') depth++;
        else if (*end == '}' && --depth == 0) break;
    }
    snprintf(pat, sizeof pat, "\"%s\": ", field);
    size_t plen = strlen(pat);
    for (const char *q = start; q + plen <= end; q++)
        if (!memcmp(q, pat, plen)) {
            *out = strtod(q + plen, NULL);
            return 0;
        }
    return -1;
}

// Whether output A comes before output B in Hyprland's list (creation order).
static int listed_before(const char *json, const char *a, const char *b) {
    char pa[96], pb[96];
    snprintf(pa, sizeof pa, "\"name\": \"%s\"", a);
    snprintf(pb, sizeof pb, "\"name\": \"%s\"", b);
    const char *x = strstr(json, pa), *y = strstr(json, pb);
    return x && y && x < y;
}

static void run_quiet(const char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        dup2(devnull, 0);
        dup2(devnull, 1);
        dup2(devnull, 2);
        execvp(argv[0], (char **)argv);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

// The bar's own height, asked for at most every 30 s (it only changes with
// the theme or font; see the note on ipc_call costs in handle_command).
static double bar_size(void) {
    static double cached = 26, at = -1e9;
    struct bar_state bs;
    if (read_bar_state(&bs) && bs.bar_size > 0 && bs.bar_size < 200) return cached = bs.bar_size;
    if (now_ms() - at < 30000) return cached;
    at = now_ms();
    char *st = ipc_call(1, "state", NULL, NULL, NULL);
    double v = 26;
    if (st) {
        char *q = strstr(st, "\"barSize\":");
        if (q) v = strtod(q + strlen("\"barSize\":"), NULL);
        free(st);
    }
    return cached = v > 0 && v < 200 ? v : 26;
}

// UTM resizes the guest display to its window: the virtio-gpu connector gets
// a new preferred mode. Hyprland neither picks that up (it even keeps the old
// mode list) nor keeps it across a config reload that re-applies a fixed mode.
// So once the preferred mode changes while running, the display is kept at it.
// The preferred mode seen at startup is not trusted: UTM starts a VM with the
// size of its previous run, which may not fit the window any more, and the
// user's monitor configuration knows better. On QEMU (UTM) by default.
// NOTCHBAR_FOLLOW_MODE=1/on or 0/off forces it (Parallels has its own tools).
static int follow_modes(void) {
    static int v = -1;
    if (v >= 0) return v;
    const char *e = getenv("NOTCHBAR_FOLLOW_MODE");
    if (e && *e) {
        v = !strcmp(e, "1") || !strcasecmp(e, "on") || !strcasecmp(e, "true") || !strcasecmp(e, "yes");
        if (!v && strcmp(e, "0") && strcasecmp(e, "off") && strcasecmp(e, "false") && strcasecmp(e, "no"))
            LOG("NOTCHBAR_FOLLOW_MODE=%s not understood, treating it as off", e);
        return v;
    }
    char vendor[64] = "";
    FILE *f = fopen("/sys/class/dmi/id/sys_vendor", "r");
    if (f) {
        if (!fgets(vendor, sizeof vendor, f)) vendor[0] = 0;
        fclose(f);
    }
    return v = strstr(vendor, "QEMU") != NULL;
}

static int preferred_mode(int *w, int *h) {
    char pattern[128];
    char scr[64];
    snprintf(pattern, sizeof pattern, "/sys/class/drm/card*-%s/modes", screen_name(scr));
    glob_t g;
    int found = 0;
    if (glob(pattern, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc && !found; i++) {
            FILE *f = fopen(g.gl_pathv[i], "r");
            if (!f) continue;
            found = fscanf(f, "%dx%d", w, h) == 2 && *w > 0 && *h > 0;
            fclose(f);
        }
        globfree(&g);
    }
    return found;
}

static int whole(double v) { return fabs(v - round(v)) < 0.01; }

static void follow_preferred_mode(const char *monitors_json) {
    static char last_applied[256];
    static double last_ms = -1e9;
    static int seen_w, seen_h, following;
    int w, h;
    if (!follow_modes() || !preferred_mode(&w, &h)) return;
    if (!seen_w) {
        seen_w = w;
        seen_h = h;
        return;
    }
    if (w != seen_w || h != seen_h) {
        seen_w = w;
        seen_h = h;
        following = 1;
    }
    if (!following) return;
    double cw, ch, x, y, s, r;
    char scr[64];
    screen_name(scr);
    if (monitor_field(monitors_json, scr, "width", &cw) || monitor_field(monitors_json, scr, "height", &ch) ||
        monitor_field(monitors_json, scr, "x", &x) || monitor_field(monitors_json, scr, "y", &y) ||
        monitor_field(monitors_json, scr, "scale", &s) || monitor_field(monitors_json, scr, "refreshRate", &r) ||
        s <= 0)
        return;
    if ((int)cw == w && (int)ch == h) return;
    // Keep the scale if it divides the new size; otherwise the nearest one
    // that does (Hyprland scales are multiples of 1/120).
    if (!whole(w / s) || !whole(h / s)) {
        double found = 0;
        for (int d = 0; d <= 60 && !found; d++)
            for (int sign = -1; sign <= 1 && !found; sign += 2) {
                double c = (round(s * 120) + sign * d) / 120.0;
                if (c >= 0.5 && whole(w / c) && whole(h / c)) found = c;
            }
        if (!found) return;
        s = found;
    }
    char lua[256];
    snprintf(lua, sizeof lua,
             "hl.monitor({ output = \"%s\", mode = \"%dx%d@%d\", position = \"%dx%d\", scale = %.6f })",
             scr, w, h, (int)(r + 0.5), (int)x, (int)y, s);
    // Do not hammer Hyprland with a rule it keeps refusing.
    if (!strcmp(lua, last_applied) && now_ms() - last_ms < 30000) return;
    snprintf(last_applied, sizeof last_applied, "%s", lua);
    last_ms = now_ms();
    LOG("display follows the host's window size: %s", lua);
    hypr_eval(lua);
}

// Which output is the built-in display: $NOTCHBAR_SCREEN if set; else the one
// OmacVM.app names in $XDG_RUNTIME_DIR/omacvm/builtin (with external displays
// it can be any Virtual-N: Virtual-1 is the main window's display); else
// Virtual-1, the only one under Parallels, UTM and Fusion. Says when it changed.
static int update_screen(void) {
    if (getenv("NOTCHBAR_SCREEN")) return 0;
    char want[64] = "Virtual-1", path[512];
    const char *rt = getenv("XDG_RUNTIME_DIR");
    snprintf(path, sizeof path, "%s/omacvm/builtin", rt && *rt ? rt : "/nonexistent");
    FILE *f = fopen(path, "r");
    if (f) {
        char line[64] = "";
        if (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\r\n")] = 0;
            int ok = !strncmp(line, "Virtual-", 8) && line[8];
            for (const char *q = line + 8; ok && *q; q++) ok = *q >= '0' && *q <= '9';
            if (ok) snprintf(want, sizeof want, "%s", line);
        }
        fclose(f);
    }
    pthread_mutex_lock(&screen_lock);
    int changed = strcmp(want, cfg_screen_buf) != 0;
    if (changed) snprintf(cfg_screen_buf, sizeof cfg_screen_buf, "%s", want);
    pthread_mutex_unlock(&screen_lock);
    if (changed) LOG("built-in display: %s", want);
    return changed;
}

// Keeps the hidden output present and exactly as wide as the display whose
// bar it stands in for, overlapping that display's top edge. Overlapping keeps
// it inside the existing layout, so absolute pointers keep their mapping.
static void *keeper_thread(void *unused) {
    (void)unused;
    char last_applied[256] = "";
    double last_apply_ms = -1e9;
    int created_attempts = 0;
    double last_recreate_ms = -1e9;
    for (;;) {
        if (update_screen()) enqueue_command("screen");
        char *j = hypr_request("j/monitors all"), scr[64];
        screen_name(scr);
        if (j) {
            double sx, sy, sw, ss, nx, ny, nw, nh, ns;
            int have_screen = !monitor_field(j, scr, "x", &sx) && !monitor_field(j, scr, "y", &sy) &&
                              !monitor_field(j, scr, "width", &sw) && !monitor_field(j, scr, "scale", &ss);
            int have_notch = !monitor_field(j, cfg_output, "x", &nx) && !monitor_field(j, cfg_output, "y", &ny) &&
                             !monitor_field(j, cfg_output, "width", &nw) && !monitor_field(j, cfg_output, "height", &nh) &&
                             !monitor_field(j, cfg_output, "scale", &ns);
            if (!have_notch && have_screen && created_attempts < 5 && !atomic_load(&remake_output)) {
                LOG("creating headless output %s", cfg_output);
                const char *argv[] = {"hyprctl", "output", "create", "headless", cfg_output, NULL};
                run_quiet(argv);
                created_attempts++;
            } else if (have_notch && have_screen && listed_before(j, cfg_output, scr) &&
                       now_ms() - last_recreate_ms > 10000) {
                // Hyprland gives a point that two outputs cover to the one made
                // first. A display that came later (OmacVM.app's external
                // displays) would lose its top edge to the hidden output, so it
                // is made again, after the display: by the capture loop, once
                // its session is closed (removing an output that is being
                // captured crashes Hyprland 0.56). A repaint wakes the loop.
                LOG("%s came before %s: making it again", cfg_output, scr);
                atomic_store(&remake_output, 1);
                free(ipc_call(0, "poke", NULL, NULL, NULL));
                last_recreate_ms = now_ms();
            } else if (have_notch && have_screen && !atomic_load(&remake_output)) {
                created_attempts = 0;
                static double last_lw;
                if (ss > 0 && fabs(sw / ss - last_lw) > 0.5) {
                    if (last_lw > 0) enqueue_command("regeom");
                    last_lw = sw / ss;
                }
                double bs = bar_size();
                int sh = atomic_load(&strip_height);
                // With the helper's geometry in points, convert with the
                // display's current width right here: a scale change then
                // resizes NOTCH once, not via an intermediate height.
                if (have_geom && mac_w > 0 && ss > 0) {
                    int conv = (int)(mac_h * (sw / ss) / mac_w + 0.5);
                    if (conv >= 10 && conv <= 200) sh = conv;
                }
                if (sh > bs) bs = sh;
                // A whole number of logical px that is also a whole number of
                // pixels at this scale (fractional scales such as 1.6 or 5/3).
                int lh = (int)ceil(bs - 1e-6);
                for (int k = 0; k < 120 && fabs(lh * ss - round(lh * ss)) > 1e-3; k++) lh++;
                int want_w = (int)(sw + 0.5), want_h = (int)round(lh * ss);
                static int saved_lh;
                if (lh != saved_lh && atomic_load(&strip_height) > 0) {
                    saved_lh = lh;
                    save_strip_height(lh);
                }
                if ((int)nw != want_w || (int)nh != want_h || (int)nx != (int)sx || (int)ny != (int)sy ||
                    ns < ss - 0.01 || ns > ss + 0.01) {
                    char lua[256];
                    snprintf(lua, sizeof lua,
                             "hl.monitor({ output = \"%s\", mode = \"%dx%d@60\", position = \"%dx%d\", scale = %.6f })",
                             cfg_output, want_w, want_h, (int)sx, (int)sy, ss);
                    // Do not hammer Hyprland with a rule it keeps refusing.
                    if (strcmp(lua, last_applied) || now_ms() - last_apply_ms > 30000) {
                        LOG("resizing %s: %s", cfg_output, lua);
                        const char *argv[] = {"hyprctl", "eval", lua, NULL};
                        run_quiet(argv);
                        snprintf(last_applied, sizeof last_applied, "%s", lua);
                        last_apply_ms = now_ms();
                    }
                }
            }
            follow_preferred_mode(j);
            free(j);
        }
        refresh_output_geometry();
        {
            // A new scale wants other cursor images (nominal size = size x scale).
            static int sent_scale100;
            pthread_mutex_lock(&lock);
            int sc = scale100;
            pthread_mutex_unlock(&lock);
            if (sent_scale100 && sc != sent_scale100) send_cursors();
            sent_scale100 = sc;
        }
        {
            int locked_now = query_session_locked();
            pthread_mutex_lock(&lock);
            if (locked_now != session_locked) {
                session_locked = locked_now;
                send_text_locked(locked_now ? "lock 1" : "lock 0");
                if (!locked_now && have_frame) send_rect_locked(prev, 0, 0, W, H);
            }
            pthread_mutex_unlock(&lock);
        }
        sleep(2);
    }
    return NULL;
}

// ------------------------------------------------------------- wayland --

static struct wl_display *dpy;
static struct wl_shm *shm;
static struct ext_image_copy_capture_manager_v1 *copy_mgr;
static struct ext_output_image_capture_source_manager_v1 *source_mgr;
#define MAX_OUTPUTS 16
static struct wl_output *outputs[MAX_OUTPUTS];
static uint32_t output_ids[MAX_OUTPUTS];
static char *output_names[MAX_OUTPUTS];
static int n_outputs;
static int outputs_changed;

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp,
                         const char *mk, const char *md, int32_t t) {
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)mk; (void)md; (void)t;
}
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    (void)d; (void)o; (void)f; (void)w; (void)h; (void)r;
}
static void out_done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void out_scale_ev(void *d, struct wl_output *o, int32_t s) { (void)d; (void)o; (void)s; }
static void out_name(void *d, struct wl_output *o, const char *name) {
    (void)d;
    for (int i = 0; i < n_outputs; i++)
        if (outputs[i] == o) {
            free(output_names[i]);
            output_names[i] = strdup(name);
        }
}
static void out_desc(void *d, struct wl_output *o, const char *s) { (void)d; (void)o; (void)s; }
static const struct wl_output_listener output_listener = {out_geometry, out_mode, out_done, out_scale_ev, out_name, out_desc};

static void reg_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_shm_interface.name)) {
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    } else if (!strcmp(iface, ext_image_copy_capture_manager_v1_interface.name)) {
        copy_mgr = wl_registry_bind(r, id, &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (!strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name)) {
        source_mgr = wl_registry_bind(r, id, &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (!strcmp(iface, wl_output_interface.name) && ver >= 4 && n_outputs < MAX_OUTPUTS) {
        outputs[n_outputs] = wl_registry_bind(r, id, &wl_output_interface, 4);
        output_ids[n_outputs] = id;
        output_names[n_outputs] = NULL;
        wl_output_add_listener(outputs[n_outputs], &output_listener, NULL);
        n_outputs++;
        outputs_changed = 1;
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) {
    (void)d; (void)r;
    for (int i = 0; i < n_outputs; i++)
        if (output_ids[i] == id) {
            wl_output_destroy(outputs[i]);
            free(output_names[i]);
            outputs[i] = outputs[n_outputs - 1];
            output_ids[i] = output_ids[n_outputs - 1];
            output_names[i] = output_names[n_outputs - 1];
            n_outputs--;
            outputs_changed = 1;
            return;
        }
}
static const struct wl_registry_listener registry_listener = {reg_global, reg_remove};

// Session state.
static uint32_t sess_w, sess_h, sess_fmt;
static int sess_done, sess_stopped, frame_ready, frame_failed;

static void s_size(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) {
    (void)d; (void)s;
    sess_w = w;
    sess_h = h;
}
static void s_shm(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f) {
    (void)d; (void)s;
    // Prefer XRGB8888, accept ARGB8888 (both are BGRA bytes in memory).
    if (f == WL_SHM_FORMAT_XRGB8888 || (f == WL_SHM_FORMAT_ARGB8888 && sess_fmt != WL_SHM_FORMAT_XRGB8888))
        sess_fmt = f;
}
static void s_dmabuf_dev(void *d, struct ext_image_copy_capture_session_v1 *s, struct wl_array *a) {
    (void)d; (void)s; (void)a;
}
static void s_dmabuf_fmt(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f, struct wl_array *m) {
    (void)d; (void)s; (void)f; (void)m;
}
static void s_done(void *d, struct ext_image_copy_capture_session_v1 *s) {
    (void)d; (void)s;
    sess_done = 1;
}
static void s_stopped(void *d, struct ext_image_copy_capture_session_v1 *s) {
    (void)d; (void)s;
    sess_stopped = 1;
}
static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    s_size, s_shm, s_dmabuf_dev, s_dmabuf_fmt, s_done, s_stopped};

static void f_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) { (void)d; (void)f; (void)t; }
static void f_damage(void *d, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)d; (void)f; (void)x; (void)y; (void)w; (void)h;
}
static void f_time(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) {
    (void)d; (void)f; (void)a; (void)b; (void)c;
}
static void f_ready(void *d, struct ext_image_copy_capture_frame_v1 *f) {
    (void)d; (void)f;
    frame_ready = 1;
}
static void f_failed(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
    (void)d; (void)f;
    frame_failed = (int)reason + 1;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {f_transform, f_damage, f_time,
                                                                                f_ready, f_failed};

static struct wl_output *find_output(void) {
    for (int i = 0; i < n_outputs; i++)
        if (output_names[i] && !strcmp(output_names[i], cfg_output)) return outputs[i];
    return NULL;
}

// Restores the cursor rectangle(s) from the previous frame (logical coords).
static void mask_cursor(uint8_t *px, double cx, double cy) {
    double s = out_scale;
    int x0 = (int)((cx - out_x - CURSOR_BEFORE) * s), y0 = (int)((cy - out_y - CURSOR_BEFORE) * s);
    int x1 = (int)((cx - out_x + CURSOR_AFTER) * s), y1 = (int)((cy - out_y + CURSOR_AFTER) * s);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int)W) x1 = (int)W;
    if (y1 > (int)H) y1 = (int)H;
    if (x0 >= x1 || y0 >= y1) return;
    for (int r = y0; r < y1; r++)
        memcpy(px + ((size_t)r * W + (size_t)x0) * 4, prev + ((size_t)r * W + (size_t)x0) * 4, (size_t)(x1 - x0) * 4);
}

// First frame of a session: there is no clean previous frame, so paint the
// cursor rectangle with the pixels just left of it (the bar background).
static void fill_cursor(uint8_t *px, double cx, double cy) {
    double s = out_scale;
    int x0 = (int)((cx - out_x - CURSOR_BEFORE) * s), y0 = (int)((cy - out_y - CURSOR_BEFORE) * s);
    int x1 = (int)((cx - out_x + CURSOR_AFTER) * s), y1 = (int)((cy - out_y + CURSOR_AFTER) * s);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int)W) x1 = (int)W;
    if (y1 > (int)H) y1 = (int)H;
    if (x0 >= x1 || y0 >= y1) return;
    int src = x0 > 0 ? x0 - 1 : (x1 < (int)W ? x1 : -1);
    if (src < 0) return;
    for (int r = y0; r < y1; r++) {
        uint32_t *row = (uint32_t *)(px + (size_t)r * W * 4);
        for (int c = x0; c < x1; c++) row[c] = row[src];
    }
}

// Runs one capture session until it stops or the output disappears.
static void capture_session(struct wl_output *out) {
    struct ext_image_capture_source_v1 *src = ext_output_image_capture_source_manager_v1_create_source(source_mgr, out);
    struct ext_image_copy_capture_session_v1 *ses = ext_image_copy_capture_manager_v1_create_session(copy_mgr, src, 0);
    ext_image_copy_capture_session_v1_add_listener(ses, &session_listener, NULL);
    sess_done = sess_stopped = 0;
    sess_fmt = UINT32_MAX;
    while (!sess_done && !sess_stopped)
        if (wl_display_dispatch(dpy) < 0) goto out_no_buf;
    if (sess_stopped || sess_fmt == UINT32_MAX) goto out_no_buf;

    refresh_output_geometry();
    uint32_t stride = sess_w * 4;
    size_t size = (size_t)stride * sess_h;
    int fd = memfd_create("notchcast", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size)) goto out_no_buf;
    uint8_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, (int32_t)sess_w, (int32_t)sess_h, (int32_t)stride, sess_fmt);
    wl_shm_pool_destroy(pool);
    close(fd);

    pthread_mutex_lock(&lock);
    if (W != sess_w || H != sess_h) {
        free(prev);
        prev = calloc(1, size);
        have_frame = 0;
    }
    W = sess_w;
    H = sess_h;
    fmt = sess_fmt;
    pthread_mutex_unlock(&lock);
    LOG("capturing %s: %ux%u format 0x%x scale %.2f", cfg_output, W, H, fmt, out_scale);
    // A capture only completes when the output repaints; ask the bar for one
    // so the helper gets its first frame straight away.
    if (!have_frame) free(ipc_call(0, "poke", NULL, NULL, NULL));

    double pcx = -1e9, pcy = -1e9;  // cursor position at the previous frame
    while (!sess_stopped && !outputs_changed && !atomic_load(&remake_output)) {
        frame_ready = frame_failed = 0;
        struct ext_image_copy_capture_frame_v1 *f = ext_image_copy_capture_session_v1_create_frame(ses);
        ext_image_copy_capture_frame_v1_add_listener(f, &frame_listener, NULL);
        ext_image_copy_capture_frame_v1_attach_buffer(f, buf);
        ext_image_copy_capture_frame_v1_damage_buffer(f, 0, 0, (int32_t)W, (int32_t)H);
        ext_image_copy_capture_frame_v1_capture(f);
        int alive = 1;
        while (!frame_ready && !frame_failed && !sess_stopped)
            if (wl_display_dispatch(dpy) < 0) {
                alive = 0;
                break;
            }
        ext_image_copy_capture_frame_v1_destroy(f);
        if (!alive) break;
        if (frame_failed) {
            DBG("frame failed, reason %d", frame_failed - 1);
            if (frame_failed - 1 == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS) break;
            usleep(50000);
            continue;
        }
        double t0 = now_ms();
        double cx, cy;
        int locked_now = query_session_locked();
        pthread_mutex_lock(&lock);
        int unlocked_now = session_locked && !locked_now;
        if (locked_now != session_locked) {
            session_locked = locked_now;
            send_text_locked(locked_now ? "lock 1" : "lock 0");
        }
        if (!cursor_pos(&cx, &cy)) {
            if (have_frame) {
                mask_cursor(px, cx, cy);
                mask_cursor(px, pcx, pcy);
            } else {
                fill_cursor(px, cx, cy);
            }
            pcx = cx;
            pcy = cy;
        }
        // Bounding box of changed pixels.
        int y0 = -1, y1 = -1, x0 = (int)W, x1 = -1;
        if (!have_frame) {
            y0 = 0; y1 = (int)H - 1; x0 = 0; x1 = (int)W - 1;
        } else {
            for (int r = 0; r < (int)H; r++) {
                const uint32_t *a = (const uint32_t *)(px + (size_t)r * stride);
                const uint32_t *b = (const uint32_t *)(prev + (size_t)r * stride);
                if (!memcmp(a, b, stride)) continue;
                if (y0 < 0) y0 = r;
                y1 = r;
                int l = 0, rr = (int)W - 1;
                while (l < x0 && a[l] == b[l]) l++;
                while (rr > x1 && a[rr] == b[rr]) rr--;
                if (l < x0) x0 = l;
                if (rr > x1) x1 = rr;
            }
        }
        if (y0 >= 0) {
            for (int r = y0; r <= y1; r++)
                memcpy(prev + (size_t)r * stride + (size_t)x0 * 4, px + (size_t)r * stride + (size_t)x0 * 4,
                       (size_t)(x1 - x0 + 1) * 4);
            have_frame = 1;
            if (!session_locked && !unlocked_now) {
                send_rect_locked(prev, (uint32_t)x0, (uint32_t)y0, (uint32_t)(x1 - x0 + 1), (uint32_t)(y1 - y0 + 1));
                DBG("sent %d,%d %dx%d in %.2f ms", x0, y0, x1 - x0 + 1, y1 - y0 + 1, now_ms() - t0);
            }
        }
        // Back from the lock screen: the helper's picture is stale, send all.
        if (unlocked_now && have_frame) send_rect_locked(prev, 0, 0, W, H);
        pthread_mutex_unlock(&lock);
    }

    wl_buffer_destroy(buf);
    munmap(px, size);
out_no_buf:
    ext_image_copy_capture_session_v1_destroy(ses);
    ext_image_capture_source_v1_destroy(src);
    wl_display_roundtrip(dpy);
}

// Restores the guest cursor when the service is stopped (it may have been
// hidden while the pointer was over the strip).
static void *signal_thread(void *arg) {
    sigset_t *set = arg;
    int sig = 0;
    sigwait(set, &sig);
    LOG("signal %d, restoring the guest cursor and exiting", sig);
    set_guest_cursor_visible(1);
    write_park(0);
    _exit(0);
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    static sigset_t term;
    sigemptyset(&term);
    sigaddset(&term, SIGTERM);
    sigaddset(&term, SIGINT);
    pthread_sigmask(SIG_BLOCK, &term, NULL);  // inherited by every thread created below
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-v")) verbose = 1;
    cfg_output = getenv("NOTCHBAR_OUTPUT") ? getenv("NOTCHBAR_OUTPUT") : "NOTCH";
    cfg_host = getenv("NOTCHBAR_HOST");  // NULL: find the Mac by itself
    {
        // Start at the strip height of the last run, not at the bar's: no
        // resize flash while the helper has not said it again yet.
        char path[600];
        state_path(path, sizeof path, "strip-height");
        FILE *f = fopen(path, "r");
        int h = 0;
        if (f) {
            if (fscanf(f, "%d", &h) != 1) h = 0;
            fclose(f);
        }
        if (h >= 10 && h <= 200) atomic_store(&strip_height, h);
    }
    cfg_port = getenv("NOTCHBAR_PORT") ? atoi(getenv("NOTCHBAR_PORT")) : 47811;
    // The display whose bar is parked while the strip shows (the built-in one).
    if (getenv("NOTCHBAR_SCREEN"))
        snprintf(cfg_screen_buf, sizeof cfg_screen_buf, "%s", getenv("NOTCHBAR_SCREEN"));
    update_screen();
    write_park(0);  // nothing is parked until the helper says so
    const char *op = getenv("OMARCHY_PATH") ? getenv("OMARCHY_PATH") : "/usr/share/omarchy";
    if (asprintf((char **)&cfg_shell, "%s/shell", op) < 0) return 1;

    set_guest_cursor_visible(1);
    pthread_t th, keeper, sigth;
    pthread_create(&sigth, NULL, signal_thread, &term);
    pthread_t worker;
    pthread_create(&worker, NULL, worker_thread, NULL);
    pthread_create(&th, NULL, net_thread, NULL);
    pthread_create(&keeper, NULL, keeper_thread, NULL);
    for (;;) {
        dpy = wl_display_connect(NULL);
        if (!dpy) {
            LOG("cannot connect to Wayland, retrying");
            sleep(2);
            continue;
        }
        n_outputs = 0;
        struct wl_registry *reg = wl_display_get_registry(dpy);
        wl_registry_add_listener(reg, &registry_listener, NULL);
        wl_display_roundtrip(dpy);
        wl_display_roundtrip(dpy);
        if (!shm || !copy_mgr || !source_mgr) {
            LOG("compositor lacks ext-image-copy-capture-v1");
            return 1;
        }
        while (wl_display_get_error(dpy) == 0) {
            outputs_changed = 0;
            struct wl_output *out = find_output();
            if (!out) {
                // Wait for the output to appear (registry events arrive via dispatch).
                struct pollfd p = {.fd = wl_display_get_fd(dpy), .events = POLLIN};
                wl_display_flush(dpy);
                if (poll(&p, 1, 1000) > 0 && wl_display_dispatch(dpy) < 0) break;
                wl_display_roundtrip(dpy);
                continue;
            }
            capture_session(out);
            if (atomic_load(&remake_output)) {
                const char *rm[] = {"hyprctl", "output", "remove", cfg_output, NULL};
                const char *mk[] = {"hyprctl", "output", "create", "headless", cfg_output, NULL};
                run_quiet(rm);
                wl_display_roundtrip(dpy);  // forget the old output before the new one
                run_quiet(mk);
                wl_display_roundtrip(dpy);
                atomic_store(&remake_output, 0);
                continue;
            }
            if (!outputs_changed) usleep(200000);  // stopped session: brief pause before retrying
        }
        LOG("Wayland connection lost, reconnecting");
        for (int i = 0; i < n_outputs; i++) free(output_names[i]);
        n_outputs = 0;
        shm = NULL;
        copy_mgr = NULL;
        source_mgr = NULL;
        wl_display_disconnect(dpy);
        sleep(1);
    }
}
