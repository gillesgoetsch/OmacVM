// omacvm-netd: the fast network for OmacVM.app (the fast-network feature).
//
// QEMU's user network (libslirp) runs a whole TCP/IP stack in one QEMU thread.
// macOS's vmnet (shared mode, what Parallels and UTM use) puts the VM on a
// bridge of the Mac instead, but needs root or Apple's com.apple.vm.networking
// entitlement, which OmacVM.app does not have. This small root daemon makes
// the vmnet interfaces and passes the VM's frames to and from QEMU, which
// connects as an ordinary user with
//   -netdev stream,addr.type=unix,addr.path=/var/run/org.omacvm.netd.sock
// (QEMU's stream framing: a 4-byte big-endian length, then the frame).
//
// What it may do, and nothing else:
// - Accept a connection only from a process of a user it was installed for
//   (--user, one per Mac user who ran omacvm enable fast-network) whose code
//   signature satisfies the requirement it was started with (--requirement):
//   OmacVM.app's QEMU, by its Developer ID team or by the exact build
//   (cdhash). Both come from the connecting process itself (its audit token),
//   not a path or a PID; both are set by root in its launchd plist. The user
//   check matters: anyone can run the signed QEMU with any arguments, and
//   with an interface they could send any frame on the VM network (other
//   VMs of that Mac are the ones they could fool), so only the users who
//   asked for it get one.
// - For each accepted connection, one vmnet interface in shared mode on
//   192.168.64.0/24 (macOS's default shared network: the Mac is 192.168.64.1,
//   as on UTM), isolated from the other VMs' interfaces. It closes with the
//   connection.
// - At most MAX_PER_UID connections per user and MAX_CONNS in all; refusals
//   are logged at most once per LOG_QUIET seconds (its users' apart from the
//   others'), and the log is cut at LOG_MAX bytes.
// - vmnet answers a start or stop within VMNET_WAIT seconds, or the
//   connection is given up (logged) and its slot freed, so a vmnet that never
//   answers cannot use up a user's slots.
// It runs no commands, opens no files, takes no other requests, and frames
// are only passed on (their length checked), never parsed.
//
// launchd starts it on the first connection (socket activation, see
// install.sh); it stays while VMs are connected and leaves IDLE_EXIT seconds
// after the last one went.
//
// Build: clang -O2 -Wall -o omacvm-netd omacvm-netd.c -framework vmnet
//          -framework Security -framework CoreFoundation -lbsm
// Test without launchd (as root): omacvm-netd --requirement REQ --user UID --socket PATH
// (PATH in a directory only root can write).

#include <bsm/libbsm.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <launch.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <arpa/inet.h>
#include <vmnet/vmnet.h>
#include <xpc/xpc.h>

#ifndef NETD_VERSION
#define NETD_VERSION "dev"
#endif
#define MAX_CONNS 32
#define MAX_PER_UID 16
#define MAX_USERS 16
#define LOG_QUIET 10            // seconds between two "refused" lines
#define LOG_MAX (1024 * 1024)   // the log starts over above this
#define IDLE_EXIT 60            // seconds without connections, then exit (launchd restarts on demand)
#define BATCH 64                // frames per vmnet_read / vmnet_write
#define RBUF (512 * 1024)       // socket -> vmnet read buffer
#define MAX_FRAME 65536         // a length above this is not QEMU's framing: drop the connection
#define SOCK_BUF (1024 * 1024)  // our side's socket buffers (macOS's default is 8 KB)
#ifndef VMNET_WAIT
#define VMNET_WAIT 10           // seconds to wait for vmnet's start/stop answer
#endif

static SecRequirementRef requirement;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int nconns;
static struct { uid_t uid; int n; } perUid[MAX_CONNS];
static time_t lastActive;
static uid_t users[MAX_USERS];
static int nusers;

// One line to stderr (launchd's log file), which starts over above LOG_MAX.
static void logf_(const char *fmt, ...) {
    static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
    char ts[32]; struct tm tm; time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm));
    pthread_mutex_lock(&logLock);
    struct stat st;
    if (fstat(STDERR_FILENO, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > LOG_MAX) {
        ftruncate(STDERR_FILENO, 0);
        lseek(STDERR_FILENO, 0, SEEK_SET);   // in case launchd did not open it O_APPEND
    }
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "%s omacvm-netd: ", ts); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
    pthread_mutex_unlock(&logLock);
}

static int userAllowed(uid_t uid) {
    for (int i = 0; i < nusers; i++) if (users[i] == uid) return 1;
    return 0;
}

// "refused" lines: at most one per LOG_QUIET seconds (a loop of connects,
// such as a QEMU reconnecting every second, must not fill the disk); the next
// one says how many were not logged. The users it was installed for count
// apart from everyone else, so others' floods cannot hide theirs.
static void refused(pid_t pid, uid_t uid, const char *why) {
    static time_t last[2]; static unsigned long quiet[2];
    int k = userAllowed(uid);
    time_t now = time(NULL);
    pthread_mutex_lock(&lock);
    int say = now - last[k] >= LOG_QUIET;
    unsigned long n = quiet[k];
    if (say) { last[k] = now; quiet[k] = 0; } else quiet[k]++;
    pthread_mutex_unlock(&lock);
    if (say) logf_("pid %d (uid %d) refused: %s%s", pid, uid, why, n ? " (and earlier refusals not logged)" : "");
}

// ---- who may connect ----

// 0 if the process behind tok satisfies the requirement; else why not.
static const char *checkPeer(const audit_token_t *tok) {
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)tok, sizeof *tok);
    const void *k[] = { kSecGuestAttributeAudit }, *v[] = { data };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus st = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code);
    CFRelease(attrs); CFRelease(data);
    if (st != errSecSuccess || !code) return "its code could not be identified";
    st = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(code);
    return st == errSecSuccess ? NULL : "its code signature is not OmacVM.app's QEMU";
}

// Takes one connection slot for uid; 0 if the limits are reached.
static int slotTake(uid_t uid) {
    int ok = 0;
    pthread_mutex_lock(&lock);
    int free_ = -1, mine = -1;
    for (int i = 0; i < MAX_CONNS; i++) {
        if (perUid[i].n && perUid[i].uid == uid) mine = i;
        else if (!perUid[i].n && free_ < 0) free_ = i;
    }
    if (nconns < MAX_CONNS && (mine < 0 || perUid[mine].n < MAX_PER_UID)) {
        if (mine < 0) { mine = free_; perUid[mine].uid = uid; }
        perUid[mine].n++; nconns++; ok = 1;
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

static void slotGive(uid_t uid) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_CONNS; i++)
        if (perUid[i].n && perUid[i].uid == uid) { perUid[i].n--; break; }
    nconns--;
    lastActive = time(NULL);
    pthread_mutex_unlock(&lock);
}

// ---- one VM ----

struct conn {
    int fd;
    uid_t uid;
    pid_t pid;
    interface_ref iface;
    dispatch_queue_t q;      // vmnet's callbacks: vmnet -> socket
    size_t maxPacket;        // vmnet's maximum frame size
    unsigned char *rx;       // BATCH * maxPacket bytes for vmnet_read
    unsigned long long toVM, fromVM, dropped;
};

// Writes all of iov (blocking socket); 0 when done, -1 when the peer is gone.
static int writeAll(int fd, struct iovec *iov, int n) {
    while (n > 0) {
        ssize_t w = writev(fd, iov, n > IOV_MAX ? IOV_MAX : n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        while (n > 0 && (size_t)w >= iov->iov_len) { w -= (ssize_t)iov->iov_len; iov++; n--; }
        if (n > 0) { iov->iov_base = (char *)iov->iov_base + w; iov->iov_len -= (size_t)w; }
    }
    return 0;
}

// vmnet has frames for the VM: read them in batches, pass them to QEMU.
// Runs on c->q. While QEMU does not read (a paused VM) this blocks and vmnet
// drops what does not fit in its own buffers, as a full NIC would.
static void toVM(struct conn *c) {
    struct vmpktdesc pkts[BATCH];
    struct iovec iov[BATCH], out[2 * BATCH];
    uint32_t hdr[BATCH];
    for (;;) {
        int n = BATCH;
        for (int i = 0; i < n; i++) {
            iov[i].iov_base = c->rx + (size_t)i * c->maxPacket;
            iov[i].iov_len = c->maxPacket;
            pkts[i] = (struct vmpktdesc){ .vm_pkt_size = c->maxPacket, .vm_pkt_iov = &iov[i], .vm_pkt_iovcnt = 1 };
        }
        if (vmnet_read(c->iface, pkts, &n) != VMNET_SUCCESS || n <= 0) return;
        int k = 0;
        for (int i = 0; i < n; i++) {
            if (!pkts[i].vm_pkt_size || pkts[i].vm_pkt_size > c->maxPacket) continue;
            hdr[i] = htonl((uint32_t)pkts[i].vm_pkt_size);
            out[k++] = (struct iovec){ &hdr[i], 4 };
            out[k++] = (struct iovec){ iov[i].iov_base, pkts[i].vm_pkt_size };
        }
        if (writeAll(c->fd, out, k)) { shutdown(c->fd, SHUT_RDWR); return; }
        c->toVM += (unsigned long long)(k / 2);
        c->dropped += (unsigned long long)(n - k / 2);
        if (n < BATCH) return;
    }
}

static dispatch_time_t vmnetDeadline(void) { return dispatch_time(DISPATCH_TIME_NOW, (int64_t)VMNET_WAIT * NSEC_PER_SEC); }

// Stops c's vmnet interface on its own queue and waits: no callback runs
// after. 0 when stopped; -1 when vmnet did not answer in time: a callback may
// still run then, so the caller must keep c (and its socket) alive.
static int stopInterface(struct conn *c) {
    if (!c->iface) return 0;
    vmnet_interface_set_event_callback(c->iface, 0, NULL, NULL);
    // The semaphore is not released on a timeout: the late callback still signals it.
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    int r = 0;
    if (vmnet_stop_interface(c->iface, c->q, ^(vmnet_return_t st) { (void)st; dispatch_semaphore_signal(s); }) == VMNET_SUCCESS) {
        if (dispatch_semaphore_wait(s, vmnetDeadline())) {
            logf_("pid %d: vmnet did not stop within %d s: giving the interface up", c->pid, VMNET_WAIT);
            r = -1;
        }
    }
    if (!r) dispatch_release(s);
    c->iface = NULL;
    return r;
}

// 0: c's vmnet interface is up. -1: it is not. -2: vmnet did not answer in
// time and may still call back on c->q: the caller keeps c alive.
static int startInterface(struct conn *c) {
    xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, VMNET_SHARED_MODE);
    xpc_dictionary_set_string(desc, vmnet_start_address_key, "192.168.64.1");
    xpc_dictionary_set_string(desc, vmnet_end_address_key, "192.168.64.254");
    xpc_dictionary_set_string(desc, vmnet_subnet_mask_key, "255.255.255.0");
    // A VM cannot reach another VM's interface: no ARP games between them.
    xpc_dictionary_set_bool(desc, vmnet_enable_isolation_key, true);
    // The VM keeps the MAC address QEMU gives it (OmacVM picks one per VM).
    xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false);
    uuid_t id; uuid_generate_random(id);
    xpc_dictionary_set_uuid(desc, vmnet_interface_id_key, id);

    // vmnet answers on c->q. Waited for VMNET_WAIT seconds; an answer after
    // that (late) stops what it started. The answer and the giving up are
    // decided under the lock, so exactly one of the two happens.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block vmnet_return_t status = VMNET_FAILURE;
    __block size_t maxPacket = 0;
    __block int answered = 0, late = 0;
    __block interface_ref iface = NULL;
    dispatch_queue_t q = c->q;
    iface = vmnet_start_interface(desc, q, ^(vmnet_return_t st, xpc_object_t param) {
        pthread_mutex_lock(&lock);
        int gaveUp = late;
        if (!gaveUp) {
            answered = 1;
            status = st;
            if (st == VMNET_SUCCESS && param) maxPacket = (size_t)xpc_dictionary_get_uint64(param, vmnet_max_packet_size_key);
        }
        pthread_mutex_unlock(&lock);
        if (!gaveUp) dispatch_semaphore_signal(done);
        else if (st == VMNET_SUCCESS && iface) vmnet_stop_interface(iface, q, ^(vmnet_return_t s2) { (void)s2; });
    });
    xpc_release(desc);
    c->iface = iface;
    if (!c->iface) { dispatch_release(done); return -1; }
    if (dispatch_semaphore_wait(done, vmnetDeadline())) {
        pthread_mutex_lock(&lock);
        int got = answered;
        if (!got) late = 1;
        pthread_mutex_unlock(&lock);
        if (!got) {
            logf_("pid %d: vmnet did not start within %d s: giving it up", c->pid, VMNET_WAIT);
            dispatch_release(done);
            c->iface = NULL;
            return -2;   // the late answer still uses c->q: keep it
        }
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);   // answered just now: signalled next
    }
    dispatch_release(done);
    if (status != VMNET_SUCCESS) {
        logf_("pid %d: vmnet did not start (status %d)", c->pid, status);
        c->iface = NULL;
        return -1;
    }
    c->maxPacket = maxPacket;
    c->rx = maxPacket >= 1514 && maxPacket <= MAX_FRAME ? malloc((size_t)BATCH * maxPacket) : NULL;
    if (!c->rx) {
        logf_("pid %d: no buffers for vmnet's frames (max packet %zu)", c->pid, maxPacket);
        if (stopInterface(c)) return -2;
        return -1;
    }
    vmnet_interface_set_event_callback(c->iface, VMNET_INTERFACE_PACKETS_AVAILABLE, c->q,
                                       ^(interface_event_t ev, xpc_object_t e) { (void)ev; (void)e; toVM(c); });
    return 0;
}

// QEMU -> vmnet: parse the length-prefixed frames, write them in batches.
static void fromVM(struct conn *c) {
    unsigned char *buf = malloc(RBUF);
    if (!buf) return;
    size_t have = 0;
    for (;;) {
        ssize_t r = read(c->fd, buf + have, RBUF - have);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        have += (size_t)r;
        size_t off = 0;
        int bad = 0;
        while (!bad) {
            struct vmpktdesc pkts[BATCH];
            struct iovec iov[BATCH];
            int n = 0;
            while (n < BATCH && have - off >= 4) {
                uint32_t len;
                memcpy(&len, buf + off, 4);
                len = ntohl(len);
                if (len == 0 || len > MAX_FRAME) { bad = 1; break; }
                if (have - off - 4 < len) break;        // the rest comes with the next read
                if (len <= c->maxPacket) {
                    iov[n] = (struct iovec){ buf + off + 4, len };
                    pkts[n] = (struct vmpktdesc){ .vm_pkt_size = len, .vm_pkt_iov = &iov[n], .vm_pkt_iovcnt = 1 };
                    n++;
                } else {
                    c->dropped++;                       // bigger than vmnet takes: a NIC drops it too
                }
                off += 4 + len;
            }
            if (!n) break;
            int sent = n;
            if (vmnet_write(c->iface, pkts, &sent) != VMNET_SUCCESS) c->dropped += (unsigned long long)n;
            else { c->fromVM += (unsigned long long)sent; c->dropped += (unsigned long long)(n - sent); }
        }
        if (bad) { logf_("pid %d: not QEMU's stream framing: closing", c->pid); break; }
        memmove(buf, buf + off, have - off);
        have -= off;
    }
    free(buf);
}

static void *serve(void *arg) {
    struct conn *c = arg;
    char label[64];
    snprintf(label, sizeof label, "org.omacvm.netd.%d", c->fd);
    c->q = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
    int hung = 0;
    int r = startInterface(c);
    if (r == 0) {
        logf_("pid %d (uid %d): connected, vmnet interface up (max frame %zu)", c->pid, c->uid, c->maxPacket);
        fromVM(c);
        // Wake a write that waits for QEMU, then stop vmnet on its own queue:
        // no callback runs after the stop.
        shutdown(c->fd, SHUT_RDWR);
        hung = stopInterface(c) != 0;
        logf_("pid %d: disconnected (%llu frames to the VM, %llu from it, %llu dropped)", c->pid, c->toVM, c->fromVM, c->dropped);
    } else {
        hung = r == -2;
        logf_("pid %d: no vmnet interface: closing", c->pid);
    }
    if (hung) {
        // vmnet may still call toVM on c->q: keep c, its buffers and its
        // (shut down) socket, so nothing it touches is freed or reused. The
        // slot goes back; the leak ends when the daemon exits idle.
        shutdown(c->fd, SHUT_RDWR);
        slotGive(c->uid);
        return NULL;
    }
    close(c->fd);
    dispatch_release(c->q);
    slotGive(c->uid);
    free(c->rx);
    free(c);
    return NULL;
}

static void accepted(int fd) {
    int one = 1, sz = SOCK_BUF;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
    audit_token_t tok;
    socklen_t tl = sizeof tok;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &tl) || tl != sizeof tok) {
        refused(0, (uid_t)-1, "no credentials");
        close(fd);
        return;
    }
    pid_t pid = audit_token_to_pid(tok);
    uid_t uid = audit_token_to_euid(tok);
    if (!userAllowed(uid)) { refused(pid, uid, "not a user the fast network was installed for"); close(fd); return; }
    const char *why = checkPeer(&tok);
    if (why) { refused(pid, uid, why); close(fd); return; }
    if (!slotTake(uid)) { refused(pid, uid, "too many VMs connected"); close(fd); return; }
    struct conn *c = calloc(1, sizeof *c);
    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (!c || (c->fd = fd, c->uid = uid, c->pid = pid, pthread_create(&t, &a, serve, c))) {
        logf_("pid %d: out of resources: refused", pid);
        free(c); close(fd); slotGive(uid);
    }
    pthread_attr_destroy(&a);
}

static int listenOn(const char *path) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (s < 0 || strlen(path) >= sizeof a.sun_path) return -1;
    strcpy(a.sun_path, path);
    unlink(path);
    // The mode comes from the umask at bind: no chmod that could follow a link.
    mode_t old = umask(0111);
    int r = bind(s, (struct sockaddr *)&a, sizeof a);
    umask(old);
    if (r || listen(s, 16)) return -1;
    return s;
}

int main(int argc, char **argv) {
    const char *req = NULL, *path = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--version")) { puts(NETD_VERSION); return 0; }
        if (!strcmp(argv[i], "--requirement") && i + 1 < argc) req = argv[++i];
        else if (!strcmp(argv[i], "--user") && i + 1 < argc) {
            char *end; long u = strtol(argv[++i], &end, 10);
            if (*end || u < 0) { fprintf(stderr, "omacvm-netd: --user takes a uid\n"); return 2; }
            if (nusers < MAX_USERS) users[nusers++] = (uid_t)u;
            else logf_("more than %d users: uid %ld left out", MAX_USERS, u);
        }
        else if (!strcmp(argv[i], "--socket") && i + 1 < argc) path = argv[++i];
        else { fprintf(stderr, "usage: omacvm-netd --requirement REQ --user UID... [--socket PATH]\n"); return 2; }
    }
    if (!req || !nusers) { fprintf(stderr, "omacvm-netd: --requirement and --user are needed\n"); return 2; }
    if (geteuid() != 0) { fprintf(stderr, "omacvm-netd: vmnet needs root\n"); return 1; }
    CFStringRef rs = CFStringCreateWithCString(NULL, req, kCFStringEncodingUTF8);
    if (!rs || SecRequirementCreateWithString(rs, kSecCSDefaultFlags, &requirement) != errSecSuccess) {
        logf_("not a code requirement: %s", req);
        return 1;
    }
    CFRelease(rs);
    signal(SIGPIPE, SIG_IGN);

    int ls = -1;
    if (path) {
        ls = listenOn(path);
    } else {
        int *fds = NULL; size_t n = 0;
        if (launch_activate_socket("omacvm-netd", &fds, &n) == 0 && n >= 1) ls = fds[0];
        for (size_t i = 1; i < n; i++) close(fds[i]);
        free(fds);
    }
    if (ls < 0) { logf_("no socket to listen on (%s)", path ? path : "launchd"); return 1; }

    // Leave when idle; launchd starts us again on the next connection. Decided
    // here, between accepts, so a connection that just came in is never dropped.
    lastActive = time(NULL);
    for (;;) {
        struct pollfd pf = { .fd = ls, .events = POLLIN };
        int r = poll(&pf, 1, 10 * 1000);
        if (r == 0) {
            pthread_mutex_lock(&lock);
            int quit = !path && nconns == 0 && time(NULL) - lastActive >= IDLE_EXIT;
            pthread_mutex_unlock(&lock);
            if (quit) return 0;
            continue;
        }
        if (r < 0) { if (errno != EINTR) { logf_("poll: %s", strerror(errno)); sleep(1); } continue; }
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) { if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) continue; logf_("accept: %s", strerror(errno)); sleep(1); continue; }
        accepted(fd);
    }
}
