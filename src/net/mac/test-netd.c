// Offline tests for omacvm-netd (src/net/mac/test.sh): vmnet is replaced by
// stand-ins that answer, answer late or never, or fail, and the Mac's
// interfaces by a made-up list, so the time limits on vmnet's start and stop,
// the back-off and its state file, the check for another program's bridge
// and the closing of a failing interface are tested without root or a real
// interface. NETD_STATE: a state file to use.
#include <dispatch/dispatch.h>
#include <ifaddrs.h>
#include <stdio.h>
#include <sys/wait.h>
// The daemon's vmnet calls go to the stand-ins below; its main is only used
// for its argument checks.
#define vmnet_start_interface fake_start
#define vmnet_stop_interface fake_stop
#define vmnet_interface_set_event_callback fake_set_callback
#define vmnet_write fake_write
#define getifaddrs fake_getifaddrs
#define freeifaddrs fake_freeifaddrs
int fake_getifaddrs(struct ifaddrs **);
void fake_freeifaddrs(struct ifaddrs *);
#define main netd_main
#define VMNET_WAIT 1
#define MAX_FAILURES 10
#include "omacvm-netd.c"
#undef main

static enum { ANSWER, LATE, NEVER, FAIL } startMode, stopMode;
static volatile int stops, lateStops;
static struct { int dummy; } fakeIface;

interface_ref fake_start(xpc_object_t desc, dispatch_queue_t q, vmnet_start_interface_completion_handler_t h) {
    (void)desc;
    if (startMode == NEVER) return (interface_ref)&fakeIface;
    if (startMode == FAIL) { dispatch_async(q, ^{ h(VMNET_SHARING_SERVICE_BUSY, NULL); }); return (interface_ref)&fakeIface; }
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

static int writeFails;
vmnet_return_t fake_write(interface_ref i, struct vmpktdesc *p, int *n) {
    (void)i; (void)p;
    if (writeFails) return VMNET_FAILURE;
    (void)n;
    return VMNET_SUCCESS;
}

// The Mac's interfaces: one, with this name and address.
static const char *ifName = "en0", *ifAddr = "192.168.1.5";
static struct sockaddr_in fakeSin;
static struct ifaddrs fakeIfa;
int fake_getifaddrs(struct ifaddrs **l) {
    fakeSin = (struct sockaddr_in){ .sin_len = sizeof fakeSin, .sin_family = AF_INET };
    inet_pton(AF_INET, ifAddr, &fakeSin.sin_addr);
    fakeIfa = (struct ifaddrs){ .ifa_name = (char *)ifName, .ifa_addr = (struct sockaddr *)&fakeSin };
    *l = &fakeIfa;
    return 0;
}
void fake_freeifaddrs(struct ifaddrs *l) { (void)l; }

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

// One connection whose VM sends a small frame every 100 ms for up to `secs`
// seconds (or until the daemon closes). Returns the seconds serve() took.
static int vmSide[2];
static pid_t stand;
static pid_t standIn(void) { return stand; }
static int killAfter;   // seconds; then the stand-in service exits
static void *sendFrames(void *arg) {
    int secs = (int)(intptr_t)arg;
    unsigned char f[64] = { 0, 0, 0, 60 };
    for (int i = 0; i < secs * 10; i++) {
        if (killAfter && i == killAfter * 10) kill(stand, SIGTERM);
        if (write(vmSide[1], f, sizeof f) != (ssize_t)sizeof f) break;
        usleep(100 * 1000);
    }
    close(vmSide[1]);
    return NULL;
}
static double talkingConnection(int secs) {
    socketpair(AF_UNIX, SOCK_STREAM, 0, vmSide);
    int one = 1;
    setsockopt(vmSide[1], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct conn *c = calloc(1, sizeof *c);
    c->fd = vmSide[0]; c->uid = 501; c->pid = 2;
    if (!slotTake(501)) return -1;
    pthread_t t;
    pthread_create(&t, NULL, sendFrames, (void *)(intptr_t)secs);
    time_t t0 = time(NULL);
    serve(c);
    double took = difftime(time(NULL), t0);
    pthread_join(t, NULL);
    return took;
}

static void resetBackoff(void) { vmnetPause = 0; vmnetFailures = 0; unlink(statePath); }

int main(void) {
    if (getenv("NETD_STATE")) statePath = getenv("NETD_STATE");
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

    // A failed start pauses vmnet starts (BACKOFF, then doubling); a good one ends it.
    startMode = FAIL; stopMode = ANSWER;
    t = oneConnection();
    time_t p1 = vmnetPause - time(NULL);
    expect(t >= 0 && nconns == 0 && vmnetPaused() && p1 >= BACKOFF - 1 && p1 <= BACKOFF, "vmnet failed: back-off");
    vmnetPause = 0;
    oneConnection();
    time_t p2 = vmnetPause - time(NULL);
    expect(vmnetFailures == 2 && p2 >= 2 * BACKOFF - 1 && p2 <= 2 * BACKOFF, "failed again: back-off doubles");
    // It is in the state file: a daemon started after this one goes on from it.
    int keepFailures = vmnetFailures; time_t keepPause = vmnetPause;
    vmnetFailures = 0; vmnetPause = 0;
    loadState();
    expect(vmnetFailures == keepFailures && vmnetPause == keepPause, "back-off kept across a daemon restart (state file)");
    // ... but not from an earlier boot of the Mac.
    FILE *f = fopen(statePath, "w");
    fprintf(f, "%ld 5 %ld 0\n", bootTime() - 100, (long)time(NULL) + 999);
    fclose(f);
    vmnetFailures = 0; vmnetPause = 0;
    loadState();
    expect(vmnetFailures == 0 && vmnetPause == 0, "state of an earlier boot ignored");
    vmnetFailures = keepFailures;
    for (int i = vmnetFailures; i < MAX_FAILURES - 1; i++) { vmnetPause = 0; oneConnection(); }
    expect(vmnetFailures == MAX_FAILURES - 1 && vmnetPause - time(NULL) <= BACKOFF_MAX, "back-off capped");
    vmnetPause = 0; oneConnection();
    expect(vmnetFailures == MAX_FAILURES && vmnetPaused() && vmnetPause == (time_t)LONG_MAX,
           "MAX_FAILURES in a row: no more starts until a restart or reinstall");
    vmnetFailures = 0; vmnetPause = 0;
    loadState();
    expect(vmnetFailures == MAX_FAILURES && vmnetPaused(), "... also after a daemon restart");
    resetBackoff(); startMode = ANSWER;
    oneConnection();
    expect(vmnetFailures == 0 && !vmnetPaused(), "vmnet works again: no back-off");

    // Another program's bridge on 192.168.77.0/24: no start (no leak), no back-off.
    expect(liveIfaces == 1, "the interface whose stop was never answered still counts as ours");
    liveIfaces = 0; inherited = 0;
    ifName = "bridge100"; ifAddr = "192.168.77.1"; stops = 0;
    char who[IFNAMSIZ];
    expect(foreignBridge(who, sizeof who) && !strcmp(who, "bridge100"), "another program's bridge on 192.168.77.1 is seen");
    oneConnection();
    expect(stops == 0 && vmnetFailures == 0 && nconns == 0, "... and vmnet is not started for it");
    liveIfaces = 1;
    expect(!foreignBridge(who, sizeof who), "with an interface of ours up, the bridge is ours");
    liveIfaces = 0; inherited = 1;
    expect(!foreignBridge(who, sizeof who), "... also when the daemon before us left interfaces up");
    inherited = 0; ifName = "en0";
    expect(!foreignBridge(who, sizeof who), "a LAN on 192.168.77.0/24 is the app's to see, not this");
    ifAddr = "192.168.1.5";

    // An interface that keeps failing (InternetSharing restarted under it) is
    // closed within seconds; soon after its start that counts as a failure.
    writeFails = 1;
    t = talkingConnection(10);
    expect(t >= FAIL_SECS && t < 5 && nconns == 0 && liveIfaces == 0 && vmnetFailures == 1,
           "vmnet writes keep failing: connection closed, counts as a failed start");
    resetBackoff(); writeFails = 0;
    t = talkingConnection(3);
    expect(t >= 2 && nconns == 0 && vmnetFailures == 0, "vmnet writes work: connection kept until the VM closes");

    // macOS's vmnet service exits under a live connection (a child process
    // stands in for it): the connection is closed within seconds.
    resetBackoff();
    pid_t child = fork();
    if (child == 0) { pause(); _exit(0); }
    stand = child;
    findSharing = standIn;
    pthread_t w;
    pthread_create(&w, NULL, watchSharing, NULL);
    killAfter = 2;
    t = talkingConnection(15);
    expect(t >= 2 && t < 6 && nconns == 0 && liveIfaces == 0 && vmnetFailures == 0,
           "vmnet's service exits: connection closed, not counted as a failure");
    waitpid(child, NULL, 0);
    // The bridge it left behind (192.168.77.1, no service to remove it) is ours.
    ifName = "bridge100"; ifAddr = "192.168.77.1";
    expect(inherited && !foreignBridge(who, sizeof who), "... and the bridge it left is not taken for another program's");
    inherited = 0; ifName = "en0"; ifAddr = "192.168.1.5";

    // --user takes a number (an empty one is not uid 0).
    char *a1[] = { "netd", "--requirement", "x", "--user", "", NULL };
    char *a2[] = { "netd", "--requirement", "x", "--user", "12x", NULL };
    char *a3[] = { "netd", "--requirement", "x", "--user", "-1", NULL };
    expect(netd_main(5, a1) == 2 && netd_main(5, a2) == 2 && netd_main(5, a3) == 2, "--user \"\", 12x, -1 refused");

    // The limits: MAX_PER_UID per user, MAX_CONNS in all.
    int got = 0;
    for (int i = 0; i < MAX_PER_UID + 1; i++) got += slotTake(600);
    expect(got == MAX_PER_UID, "per-user limit");
    for (int u = 700; u < 700 + MAX_CONNS; u++) got += slotTake((uid_t)u);
    expect(nconns == MAX_CONNS, "total limit");
    return failures ? 1 : 0;
}
