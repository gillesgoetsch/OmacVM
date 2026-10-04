// Offline tests for omacvm-netd (src/net/mac/test.sh): vmnet is replaced by
// stand-ins that answer, answer late or never, so the time limits on vmnet's
// start and stop are tested without root or a real interface.
#include <dispatch/dispatch.h>
#include <stdio.h>
// The daemon's vmnet calls go to the stand-ins below; its main is not used.
#define vmnet_start_interface fake_start
#define vmnet_stop_interface fake_stop
#define vmnet_interface_set_event_callback fake_set_callback
#define main netd_main
#define VMNET_WAIT 1
#include "omacvm-netd.c"
#undef main

static enum { ANSWER, LATE, NEVER } startMode, stopMode;
static volatile int stops, lateStops;
static struct { int dummy; } fakeIface;

interface_ref fake_start(xpc_object_t desc, dispatch_queue_t q, vmnet_start_interface_completion_handler_t h) {
    (void)desc;
    if (startMode == NEVER) return (interface_ref)&fakeIface;
    xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(p, vmnet_max_packet_size_key, 1514);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, startMode == LATE ? 1500 * NSEC_PER_MSEC : 0), q, ^{ h(VMNET_SUCCESS, p); });
    return (interface_ref)&fakeIface;
}

vmnet_return_t fake_stop(interface_ref i, dispatch_queue_t q, vmnet_interface_completion_handler_t h) {
    (void)i;
    __sync_fetch_and_add(&stops, 1);
    if (startMode == LATE) __sync_fetch_and_add(&lateStops, 1);
    if (stopMode != NEVER) dispatch_async(q, ^{ h(VMNET_SUCCESS); });
    return VMNET_SUCCESS;
}

vmnet_return_t fake_set_callback(interface_ref i, interface_event_t ev, dispatch_queue_t q, vmnet_interface_event_callback_t cb) {
    (void)i; (void)ev; (void)q; (void)cb;
    return VMNET_SUCCESS;
}

static int failures;
static void expect(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

// One connection through serve(); the VM side closes at once. Returns the
// seconds serve() took.
static double oneConnection(void) {
    int sv[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    close(sv[1]);
    struct conn *c = calloc(1, sizeof *c);
    c->fd = sv[0]; c->uid = 501; c->pid = 1;
    if (!slotTake(501)) return -1;
    time_t t0 = time(NULL);
    serve(c);
    return difftime(time(NULL), t0);
}

int main(void) {
    startMode = ANSWER; stopMode = ANSWER;
    double t = oneConnection();
    expect(t >= 0 && t < 1 && nconns == 0 && stops == 1, "vmnet answers: started, stopped, slot freed");

    startMode = NEVER; stops = 0;
    t = oneConnection();
    expect(t >= 0 && t <= 2 && nconns == 0, "start never answered: given up after VMNET_WAIT, slot freed");

    startMode = LATE; stops = 0; lateStops = 0;
    t = oneConnection();
    sleep(1);   // the late answer comes after the give-up
    expect(t >= 0 && t <= 2 && nconns == 0 && lateStops == 1, "start answered late: given up, the late interface stopped");

    startMode = ANSWER; stopMode = NEVER; stops = 0;
    t = oneConnection();
    expect(t >= 0 && t <= 2 && nconns == 0 && stops == 1, "stop never answered: given up after VMNET_WAIT, slot freed");

    // The limits: MAX_PER_UID per user, MAX_CONNS in all.
    int got = 0;
    for (int i = 0; i < MAX_PER_UID + 1; i++) got += slotTake(600);
    expect(got == MAX_PER_UID, "per-user limit");
    for (int u = 700; u < 700 + MAX_CONNS; u++) got += slotTake((uid_t)u);
    expect(nconns == MAX_CONNS, "total limit");
    return failures ? 1 : 0;
}
