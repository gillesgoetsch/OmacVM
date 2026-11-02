// omacvm-drop-at: drop a list of files into the app under the pointer
// (drag and drop from the Mac, feature drag-drop; docs/drag-and-drop.md).
//
//   omacvm-drop-at URIFILE      URIFILE: the text/uri-list to drop
//
// The pointer stays where it is: QEMU already put the VM's pointer under the
// Mac's (an absolute virtual-pointer move maps over the whole layout and
// lands 19 px off with Omanotch's hidden NOTCH output). How:
//   1. a fully transparent overlay (layer shell) over the output, no keyboard;
//   2. a virtual-pointer press on it gives a real button serial;
//   3. wl_data_device.start_drag with a source that offers only
//      text/uri-list, action copy;
//   4. the overlay's input region becomes empty, so the surface under the
//      pointer is the app's again;
//   5. two tiny moves make the compositor pick it; the release is the drop.
// Proven on Hyprland 0.56.2 (Nautilus copies the file, a test window takes
// it; work/tracks/dnd.md's spike). The overlay is drawn transparent and lives
// under half a second; the pointer ends where it started.
//
// Prints one line: "app" (an app took the drop and finished it), "none" (no
// app took it: cancelled), or "error WHAT". Exit 0, 3, 1.
// Built in the VM by src/drop/guest/install.sh (gcc, wayland-scanner).
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#define MAX_URIS (1 << 20)

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_data_device_manager *ddm;
static struct zwlr_layer_shell_v1 *lsh;
static struct zwlr_virtual_pointer_manager_v1 *vpm;
static struct wl_surface *surf;
static int cfg_w, cfg_h, configured, entered, pressed;
static uint32_t press_serial;
static char *uris;
static size_t uris_len;
static int finished, cancelled;
static struct timespec t0;

static long ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000;
}
static uint32_t now32(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name)) comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, wl_shm_interface.name)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name) && !seat) seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
    else if (!strcmp(iface, wl_data_device_manager_interface.name)) ddm = wl_registry_bind(r, name, &wl_data_device_manager_interface, ver < 3 ? ver : 3);
    else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name)) lsh = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
    else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) vpm = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };

static void ls_configure(void *d, struct zwlr_layer_surface_v1 *s, uint32_t serial, uint32_t w, uint32_t h) {
    (void)d; cfg_w = (int)w; cfg_h = (int)h; configured = 1;
    zwlr_layer_surface_v1_ack_configure(s, serial);
}
static void ls_closed(void *d, struct zwlr_layer_surface_v1 *s) { (void)d; (void)s; }
static const struct zwlr_layer_surface_v1_listener ls_l = { ls_configure, ls_closed };

static void p_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)serial; (void)x; (void)y;
    if (s == surf) entered = 1;
}
static void p_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) { (void)d; (void)p; (void)serial; (void)s; }
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d; (void)p; (void)t; (void)x; (void)y; }
static void p_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t t, uint32_t b, uint32_t st) {
    (void)d; (void)p; (void)t;
    if (b == BTN_LEFT && st == WL_POINTER_BUTTON_STATE_PRESSED) { press_serial = serial; pressed = 1; }
}
static void p_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d; (void)p; (void)t; (void)a; (void)v; }
static void p_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void p_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void p_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d; (void)p; (void)t; (void)a; }
static void p_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static const struct wl_pointer_listener p_l = { p_enter, p_leave, p_motion, p_button, p_axis, p_frame, p_axis_source, p_axis_stop, p_axis_discrete };

static void s_target(void *d, struct wl_data_source *s, const char *mime) { (void)d; (void)s; (void)mime; }
static void s_send(void *d, struct wl_data_source *s, const char *mime, int32_t fd) {
    (void)d; (void)s; (void)mime;
    size_t off = 0;
    while (off < uris_len) {
        ssize_t n = write(fd, uris + off, uris_len - off);
        if (n <= 0) break;
        off += (size_t)n;
    }
    close(fd);
}
static void s_cancelled(void *d, struct wl_data_source *s) { (void)d; (void)s; cancelled = 1; }
static void s_drop(void *d, struct wl_data_source *s) { (void)d; (void)s; }
static void s_finished(void *d, struct wl_data_source *s) { (void)d; (void)s; finished = 1; }
static void s_action(void *d, struct wl_data_source *s, uint32_t a) { (void)d; (void)s; (void)a; }
static const struct wl_data_source_listener s_l = { s_target, s_send, s_cancelled, s_drop, s_finished, s_action };

/* Events for up to `t` ms, or until *flag. */
static void pump(int t, int *flag) {
    long end = ms() + t;
    while ((!flag || !*flag) && ms() < end) {
        while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        struct pollfd pfd = { wl_display_get_fd(dpy), POLLIN, 0 };
        int left = (int)(end - ms());
        if (left < 0) left = 0;
        if (poll(&pfd, 1, left > 20 ? 20 : left) > 0) wl_display_read_events(dpy);
        else wl_display_cancel_read(dpy);
        if (wl_display_dispatch_pending(dpy) < 0) return;
    }
}

static struct wl_buffer *clear_buffer(int w, int h) {
    int stride = w * 4;
    size_t size = (size_t)stride * (size_t)h;
    int fd = memfd_create("omacvm-drop-at", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) return NULL;
    /* A new memfd reads as zeros: fully transparent ARGB. */
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return b;
}

static void vmove(struct zwlr_virtual_pointer_v1 *vp, int dx) {
    zwlr_virtual_pointer_v1_motion(vp, now32(), wl_fixed_from_int(dx), 0);
    zwlr_virtual_pointer_v1_frame(vp);
}

int main(int argc, char **argv) {
    clock_gettime(CLOCK_MONOTONIC, &t0);
    if (argc != 2) { fprintf(stderr, "usage: omacvm-drop-at URIFILE\n"); return 2; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { puts("error no uri list"); return 1; }
    uris = malloc(MAX_URIS);
    if (!uris) return 1;
    uris_len = fread(uris, 1, MAX_URIS, f);
    fclose(f);
    if (uris_len == 0 || uris_len == MAX_URIS) { puts("error uri list empty or too long"); return 1; }
    dpy = wl_display_connect(NULL);
    if (!dpy) { puts("error no wayland session"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);
    if (!comp || !shm || !seat || !ddm || !lsh || !vpm) { puts("error the compositor lacks layer shell, virtual pointer or data device"); return 1; }
    struct wl_pointer *ptr = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(ptr, &p_l, NULL);
    struct wl_data_device *dd = wl_data_device_manager_get_data_device(ddm, seat);
    struct zwlr_virtual_pointer_v1 *vp = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vpm, seat);

    /* NULL output: the compositor puts the overlay on the focused output,
       where the pointer is. */
    surf = wl_compositor_create_surface(comp);
    struct zwlr_layer_surface_v1 *ls = zwlr_layer_shell_v1_get_layer_surface(lsh, surf, NULL,
        ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "omacvm-drop");
    zwlr_layer_surface_v1_add_listener(ls, &ls_l, NULL);
    zwlr_layer_surface_v1_set_anchor(ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                     ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(ls, 0, 0);
    zwlr_layer_surface_v1_set_exclusive_zone(ls, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(ls, 0);
    wl_surface_commit(surf);
    pump(1000, &configured);
    if (!configured || cfg_w <= 0 || cfg_h <= 0) { puts("error no overlay"); return 1; }
    struct wl_buffer *b = clear_buffer(cfg_w, cfg_h);
    if (!b) { puts("error no buffer"); return 1; }
    wl_surface_attach(surf, b, 0, 0);
    wl_surface_damage(surf, 0, 0, cfg_w, cfg_h);
    wl_surface_commit(surf);
    wl_display_roundtrip(dpy);
    /* No real move is coming: a tiny one there and back puts the pointer on the overlay. */
    vmove(vp, 1); vmove(vp, -1);
    pump(1000, &entered);
    int ok = entered;
    if (ok) {
        zwlr_virtual_pointer_v1_button(vp, now32(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(vp);
        pump(1000, &pressed);
        ok = pressed;
    }
    if (!ok) {
        puts(entered ? "error no button serial" : "error the pointer did not reach the overlay (a grab?)");
        zwlr_layer_surface_v1_destroy(ls);
        wl_surface_destroy(surf);
        wl_display_roundtrip(dpy);
        return 1;
    }
    struct wl_data_source *src = wl_data_device_manager_create_data_source(ddm);
    wl_data_source_add_listener(src, &s_l, NULL);
    wl_data_source_offer(src, "text/uri-list");
    if (wl_data_source_get_version(src) >= 3) wl_data_source_set_actions(src, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    wl_data_device_start_drag(dd, src, surf, NULL, press_serial);
    wl_display_roundtrip(dpy);
    struct wl_region *empty = wl_compositor_create_region(comp);
    wl_surface_set_input_region(surf, empty);
    wl_region_destroy(empty);
    wl_surface_commit(surf);
    wl_display_roundtrip(dpy);
    pump(30, NULL);
    for (int i = 0; i < 2; i++) { vmove(vp, 1); pump(20, NULL); vmove(vp, -1); pump(20, NULL); }
    zwlr_virtual_pointer_v1_button(vp, now32(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(vp);
    long end = ms() + 5000;
    while (ms() < end && !finished && !cancelled) pump(50, NULL);
    wl_data_source_destroy(src);
    zwlr_layer_surface_v1_destroy(ls);
    wl_surface_destroy(surf);
    zwlr_virtual_pointer_v1_destroy(vp);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    if (finished) { puts("app"); return 0; }
    puts(cancelled ? "none" : "none (no answer in 5 s)");
    return 3;
}
