// dnd-dst (drag-drop VM rows, src/tests/e2e/drag-drop.sh): a plain window that takes text/uri-list drops and
// writes each drop's text to OUTFILE (appended, one "DROP <text>" block).
// usage: dnd-dst OUTFILE
#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp; static struct wl_shm *shm; static struct wl_seat *seat;
static struct wl_data_device_manager *ddm; static struct xdg_wm_base *wm;
static struct wl_surface *surf; static int cfg_w = 800, cfg_h = 600, configured;
static struct wl_data_offer *cur; static int cur_uri; static uint32_t enter_serial;
static FILE *out; static struct wl_display *dpy;

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_compositor_interface.name)) comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, wl_shm_interface.name)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, wl_seat_interface.name) && !seat) seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5);
    else if (!strcmp(iface, wl_data_device_manager_interface.name)) ddm = wl_registry_bind(r, name, &wl_data_device_manager_interface, ver < 3 ? ver : 3);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_l = { reg_global, reg_remove };
static void wm_ping(void *d, struct xdg_wm_base *w, uint32_t s) { (void)d; xdg_wm_base_pong(w, s); }
static const struct xdg_wm_base_listener wm_l = { wm_ping };
static void xs_configure(void *d, struct xdg_surface *s, uint32_t serial) { (void)d; xdg_surface_ack_configure(s, serial); configured = 1; }
static const struct xdg_surface_listener xs_l = { xs_configure };
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
    (void)d; (void)t; (void)st; if (w > 0) cfg_w = w; if (h > 0) cfg_h = h;
}
static void tl_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }
static const struct xdg_toplevel_listener tl_l = { tl_configure, tl_close };

static void o_offer(void *d, struct wl_data_offer *o, const char *mime) {
    (void)d; (void)o; fprintf(out, "MIME %s\n", mime); fflush(out);
    if (!strcmp(mime, "text/uri-list")) cur_uri = 1;
}
static void o_source_actions(void *d, struct wl_data_offer *o, uint32_t a) { (void)d; (void)o; fprintf(out, "SOURCE-ACTIONS %u\n", a); }
static void o_action(void *d, struct wl_data_offer *o, uint32_t a) { (void)d; (void)o; fprintf(out, "ACTION %u\n", a); fflush(out); }
static const struct wl_data_offer_listener o_l = { o_offer, o_source_actions, o_action };

static void dd_offer(void *d, struct wl_data_device *dd, struct wl_data_offer *o) {
    (void)d; (void)dd; cur_uri = 0; wl_data_offer_add_listener(o, &o_l, NULL);
}
static void dd_enter(void *d, struct wl_data_device *dd, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *o) {
    (void)d; (void)dd; (void)s;
    cur = o; enter_serial = serial;
    fprintf(out, "ENTER %.0f,%.0f uri=%d\n", wl_fixed_to_double(x), wl_fixed_to_double(y), cur_uri); fflush(out);
    if (o && cur_uri) {
        wl_data_offer_accept(o, serial, "text/uri-list");
        if (wl_data_offer_get_version(o) >= 3)
            wl_data_offer_set_actions(o, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    } else if (o) wl_data_offer_accept(o, serial, NULL);
}
static void dd_leave(void *d, struct wl_data_device *dd) {
    (void)d; (void)dd; fprintf(out, "LEAVE\n"); fflush(out);
    if (cur) { wl_data_offer_destroy(cur); cur = NULL; }
}
static int motions;
static void dd_motion(void *d, struct wl_data_device *dd, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d; (void)dd; (void)t; (void)x; (void)y; motions++; }
static void dd_drop(void *d, struct wl_data_device *dd) {
    (void)d; (void)dd;
    if (!cur) return;
    int p[2]; if (pipe(p) < 0) return;
    wl_data_offer_receive(cur, "text/uri-list", p[1]); close(p[1]);
    wl_display_flush(dpy);
    char buf[65536]; size_t n = 0; ssize_t r;
    while (n < sizeof buf - 1 && (r = read(p[0], buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r;
    close(p[0]); buf[n] = 0;
    fprintf(out, "DROP motions=%d bytes=%zu\n%s\nEND\n", motions, n, buf); fflush(out);
    if (wl_data_offer_get_version(cur) >= 3) wl_data_offer_finish(cur);
    wl_data_offer_destroy(cur); cur = NULL;
}
static void dd_sel(void *d, struct wl_data_device *dd, struct wl_data_offer *o) { (void)d; (void)dd; if (o) wl_data_offer_destroy(o); }
static const struct wl_data_device_listener dd_l = { dd_offer, dd_enter, dd_leave, dd_motion, dd_drop, dd_sel };

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    out = fopen(argv[1], "a"); if (!out) return 2;
    dpy = wl_display_connect(NULL); if (!dpy) return 1;
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);
    if (!comp || !shm || !seat || !ddm || !wm) { fprintf(out, "missing global\n"); return 1; }
    xdg_wm_base_add_listener(wm, &wm_l, NULL);
    struct wl_data_device *dd = wl_data_device_manager_get_data_device(ddm, seat);
    wl_data_device_add_listener(dd, &dd_l, NULL);
    surf = wl_compositor_create_surface(comp);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm, surf);
    xdg_surface_add_listener(xs, &xs_l, NULL);
    struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(tl, &tl_l, NULL);
    xdg_toplevel_set_title(tl, "dnd-dst"); xdg_toplevel_set_app_id(tl, "dnd-dst");
    wl_surface_commit(surf);
    while (!configured && wl_display_dispatch(dpy) >= 0) {}
    int stride = cfg_w * 4, size = stride * cfg_h;
    int fd = memfd_create("dnd-dst", MFD_CLOEXEC); if (ftruncate(fd, size) < 0) return 1;
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (int i = 0; i < cfg_w * cfg_h; i++) px[i] = 0xff3060a0;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, cfg_w, cfg_h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_surface_attach(surf, b, 0, 0); wl_surface_damage(surf, 0, 0, cfg_w, cfg_h); wl_surface_commit(surf);
    fprintf(out, "READY %dx%d\n", cfg_w, cfg_h); fflush(out);
    while (wl_display_dispatch(dpy) >= 0) {}
    return 0;
}
