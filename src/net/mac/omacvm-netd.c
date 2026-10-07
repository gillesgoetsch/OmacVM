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
//   its own network, 192.168.77.0/24 (the Mac is 192.168.77.1), isolated
//   from the other VMs' interfaces. It closes with the connection. Not
//   macOS's default 192.168.64.0/24: while UTM (or another app) has that one
//   up without isolation, vmnet refuses an isolated interface on it.
// - After vmnet fails to start an interface, no new one for BACKOFF seconds
//   (doubling up to BACKOFF_MAX while it keeps failing), and none at all
//   after MAX_FAILURES in a row until the Mac restarts or the service is
//   installed again: each failed start costs macOS's vmnet service
//   (InternetSharing) a descriptor it never gives back, and at 256 vmnet
//   stops working on the whole Mac until a restart. QEMU tries again every
//   second; those tries are refused here. The count and the pause are kept in
//   STATE_FILE, so a daemon that exits idle or is restarted goes on from them.
// - After a failed start, none while 192.168.77.0/24 is up on a bridge that
//   is not ours (no interface of ours up, the vmnet service running):
//   another program's VM network on the same addresses makes every start
//   fail (and leak); it is tried again once that bridge is gone.
// - When macOS's vmnet service (InternetSharing) stops or crashes, our
//   interfaces go with it, but vmnet says nothing and writes still "work":
//   the daemon watches the service's process and closes every connection
//   when it exits, so QEMU connects again and gets a new interface (launchd
//   starts the service again for it), or the app falls back to its user
//   network. A connection whose vmnet reads or writes keep failing is
//   closed too (full vmnet buffers only drop frames, as a busy NIC does).
//   The service is the root process /usr/libexec/InternetSharing: any user
//   can start a process with that name, and its exit means nothing.
// - At most MAX_PER_UID connections per user and MAX_CONNS in all; refusals
//   are logged at most once per LOG_QUIET seconds (its users' apart from the
//   others'), and the log is cut at LOG_MAX bytes.
// - vmnet answers a start or stop within VMNET_WAIT seconds, or the
//   connection is given up (logged) and its slot freed, so a vmnet that never
//   answers cannot use up a user's slots.
// - While VMs are on the fast network: the NAT for networks macOS's vmnet
//   service does not cover (a VPN connected after it started), in the
//   daemon's own pf anchor; see "VPN NAT" below.
// It runs one program, /sbin/pfctl (fixed path and arguments, no shell, for
// the VPN NAT only), opens no files but STATE_FILE and NAT_FILE (root's, in
// /var/run, gone at restart), takes no other requests, and frames
// are only passed on (their length checked), never parsed.
//
// launchd starts it on the first connection (socket activation, see
// install.sh); it stays while VMs are connected or knock, and leaves
// IDLE_EXIT seconds after the last connection of any kind (so the back-off
// outlives a QEMU that keeps trying).
//
// Build: clang -O2 -Wall -o omacvm-netd omacvm-netd.c -framework vmnet
//          -framework Security -framework CoreFoundation -lbsm
// Test without launchd (as root): omacvm-netd --requirement REQ --user UID --socket PATH
// [--state FILE] (both in a directory only root can write).

#include <bsm/libbsm.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <launch.h>
#include <libproc.h>
#include <limits.h>
#include <net/if.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <arpa/inet.h>
#include <net/route.h>
#include <netinet/in.h>
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
#ifndef BACKOFF
#define BACKOFF 30              // seconds without vmnet starts after one failed
#endif
#define BACKOFF_MAX 3600        // ... doubling while it keeps failing, up to this
#ifndef MAX_FAILURES
#define MAX_FAILURES 8          // failed starts in a row, then none until a restart or reinstall
#endif
#define STATE_FILE "/var/run/org.omacvm.netd.state"
#define FAIL_COUNT 5            // vmnet reads or writes failing this many times in a row
#define FAIL_SECS 2             // ... for this many seconds: the interface is gone
#define NET_PREFIX "192.168.77."
#define SHARING "InternetSharing"   // macOS's vmnet service (a launchd daemon) ...
#define SHARING_PATH "/usr/libexec/InternetSharing"   // ... run by root from here
#define NET_FIRST "192.168.77.1"   // the Mac on the fast network
#define NET_LAST "192.168.77.254"
#define NET_MASK "255.255.255.0"

static SecRequirementRef requirement;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int nconns;
static struct { uid_t uid; int n; } perUid[MAX_CONNS];
static time_t lastActive;
static time_t vmnetPause;         // no vmnet starts before this (after failures)
static int vmnetFailures;         // failed starts in a row
static int liveIfaces;            // our interfaces that are up (or did not answer a stop)
static int inherited;             // the daemon before us left interfaces up
static const char *statePath = STATE_FILE;
static struct conn *live[MAX_CONNS];   // connections with an interface up
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

// ---- vmnet's back-off ----

// No vmnet starts until then (failed ones leak in macOS's vmnet service).
static int vmnetPaused(void) {
    pthread_mutex_lock(&lock);
    int p = time(NULL) < vmnetPause;
    pthread_mutex_unlock(&lock);
    return p;
}

// When this Mac started: the state of an earlier boot does not count
// (InternetSharing starts over with the Mac).
static long bootTime(void) {
    struct timeval tv; size_t l = sizeof tv;
    return sysctlbyname("kern.boottime", &tv, &l, NULL, 0) ? 0 : (long)tv.tv_sec;
}

// STATE_FILE: "boot failures pause live" (live: our interfaces, or bridges
// we left behind; readable by all: install.sh and omacvm
// check show a stop). Written under the lock, no links followed.
static void saveState(void) {
    char b[96];
    int n = snprintf(b, sizeof b, "%ld %d %ld %d\n", bootTime(), vmnetFailures, (long)vmnetPause, liveIfaces + inherited);
    int fd = open(statePath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, b, (size_t)n) != n) { /* the next save tries again */ }
    close(fd);
}

static void loadState(void) {
    char b[96] = "";
    int fd = open(statePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t r = read(fd, b, sizeof b - 1);
    close(fd);
    long boot, pause; int fails, live;
    if (r <= 0 || sscanf(b, "%ld %d %ld %d", &boot, &fails, &pause, &live) != 4 || boot != bootTime()) return;
    if (fails < 0 || fails > MAX_FAILURES) fails = MAX_FAILURES;
    vmnetFailures = fails;
    vmnetPause = (time_t)pause;
    inherited = live > 0;
    if (fails) logf_("vmnet failed %d time(s) in a row before this start%s", fails,
                     fails >= MAX_FAILURES ? ": no new interfaces until the Mac restarts or the fast network is installed again" : "");
}

static void vmnetResult(int ok) {
    pthread_mutex_lock(&lock);
    long secs = 0;
    if (ok) { vmnetFailures = 0; vmnetPause = 0; }
    else if (++vmnetFailures >= MAX_FAILURES) {
        vmnetPause = (time_t)LONG_MAX;
    } else {
        int n = vmnetFailures;
        secs = BACKOFF;
        while (--n > 0 && secs < BACKOFF_MAX) secs *= 2;
        if (secs > BACKOFF_MAX) secs = BACKOFF_MAX;
        vmnetPause = time(NULL) + secs;
    }
    int n = vmnetFailures;
    saveState();
    pthread_mutex_unlock(&lock);
    if (!ok && n >= MAX_FAILURES)
        logf_("vmnet failed %d times in a row: no new interfaces until the Mac restarts or the fast network is installed again", n);
    else if (!ok) logf_("vmnet failed %d time(s) in a row: no new interfaces for %ld s", n, secs);
}

static void natPoke(void);
// c's interface is up (add), or gone (stopped: up 0) or given up (a stop
// that was not answered: up 1, it still counts as ours).
static void liveChange(struct conn *c, int add, int up) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_CONNS; i++)
        if (add ? !live[i] : live[i] == c) { live[i] = add ? c : NULL; break; }
    liveIfaces += add ? 1 : up ? 0 : -1;
    if (add) inherited = 0;
    saveState();
    pthread_mutex_unlock(&lock);
    natPoke();   // the VPN NAT follows the VMs
}

static pid_t (*findSharing)(void);   // macOS's vmnet service's pid, 0 when not running

// After a failed start: a bridge with an address in the fast network's
// subnet while none of our interfaces is up and macOS's vmnet service runs,
// so another program's VM network there, the likely reason (its name in
// ifname); else 0. Not before a failure or without the service: a bridge
// the service left behind when it stopped (removed when it starts again,
// for our next start) must not keep us from starting it.
static int foreignBridge(char *ifname, size_t len) {
    pthread_mutex_lock(&lock);
    int ours = liveIfaces > 0 || inherited, failed = vmnetFailures > 0;
    pthread_mutex_unlock(&lock);
    if (ours || !failed || !findSharing()) return 0;
    struct ifaddrs *list, *p;
    int found = 0;
    if (getifaddrs(&list)) return 0;
    for (p = list; p && !found; p = p->ifa_next) {
        char a[INET_ADDRSTRLEN];
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strncmp(p->ifa_name, "bridge", 6)) continue;
        if (!inet_ntop(AF_INET, &((struct sockaddr_in *)(void *)p->ifa_addr)->sin_addr, a, sizeof a)) continue;
        if (!strncmp(a, NET_PREFIX, strlen(NET_PREFIX))) { snprintf(ifname, len, "%s", p->ifa_name); found = 1; }
    }
    freeifaddrs(list);
    return found;
}

// vmnet reads or writes that keep failing: FAIL_COUNT in a row over
// FAIL_SECS seconds. ok resets it.
struct fails { time_t since; unsigned n; };
struct conn;
// vmnet's answer says the interface works: VMNET_BUFFER_EXHAUSTED (its
// buffers are full) drops frames, it is no failure.
static int vmnetOk(vmnet_return_t st) { return st == VMNET_SUCCESS || st == VMNET_BUFFER_EXHAUSTED; }
static int keepsFailing(struct fails *f, int ok) {
    if (ok) { f->n = 0; return 0; }
    time_t now = time(NULL);
    if (!f->n++) f->since = now;
    return f->n >= FAIL_COUNT && now - f->since >= FAIL_SECS;
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
    struct fails rfail, wfail;
    volatile int broken;     // vmnet kept failing: closed for that
    volatile int gone;       // macOS's vmnet service stopped: closed for that
    int lastErr;             // vmnet's last failed status
};

// ---- macOS's vmnet service ----

// pid is macOS's service: root's /usr/libexec/InternetSharing, not just a
// process with that name (any user can start one).
static int isSharing(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    struct proc_bsdinfo bi;
    if (proc_pidpath(pid, path, sizeof path) <= 0 || strcmp(path, SHARING_PATH)) return 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) return 0;
    return bi.pbi_uid == 0 && bi.pbi_ruid == 0;
}

static pid_t sharingPid(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t *p = calloc((size_t)n + 64, sizeof *p), found = 0;
    if (!p) return 0;
    n = proc_listallpids(p, (int)(((size_t)n + 64) * sizeof *p));
    for (int i = 0; i < n && !found; i++) {
        char name[2 * MAXCOMLEN + 1];
        if (proc_name(p[i], name, sizeof name) > 0 && !strcmp(name, SHARING) && isSharing(p[i])) found = p[i];
    }
    free(p);
    return found;
}
static pid_t (*findSharing)(void) = sharingPid;   // the offline test puts its own in

// The service is gone and our interfaces with it: end every connection
// (fromVM sees it; serve stops what is left, QEMU connects again). Its
// bridge stays behind with 192.168.77.1 until the service runs again (for
// our next start): ours, not another program's.
static void sharingGone(void) {
    int n = 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_CONNS; i++)
        if (live[i]) { live[i]->gone = 1; shutdown(live[i]->fd, SHUT_RDWR); n++; }
    if (n) { inherited = 1; saveState(); }
    pthread_mutex_unlock(&lock);
    if (n) logf_("macOS's vmnet service (%s) stopped: closing %d connection(s) (QEMU connects again)", SHARING, n);
    natPoke();
}

// Watches the service's process while we have interfaces. Only an exit it
// saw counts: a service it cannot find (another name in a later macOS) is
// looked for again each second, and connections are never closed on a guess.
static void *watchSharing(void *arg) {
    (void)arg;
    int kq = kqueue();
    pid_t watched = 0;
    int said = 0;
    if (kq < 0) { logf_("kqueue: %s: not watching %s", strerror(errno), SHARING); return NULL; }
    for (;;) {
        pthread_mutex_lock(&lock);
        int any = 0;
        for (int i = 0; i < MAX_CONNS; i++) any |= live[i] != NULL;
        pthread_mutex_unlock(&lock);
        if (!any) { watched = 0; sleep(1); continue; }
        if (!watched) {
            pid_t p = findSharing();
            if (!p) {
                if (!said++) logf_("%s not found: not watching it until it is", SHARING);
                sleep(1);
                continue;
            }
            said = 0;
            struct kevent ev;
            EV_SET(&ev, (uintptr_t)p, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
            if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0) {
                if (errno == ESRCH) sharingGone();   // gone between the two
                sleep(1);
                continue;
            }
            watched = p;
        }
        struct kevent out;
        struct timespec ts = { 1, 0 };
        if (kevent(kq, NULL, 0, &out, 1, &ts) > 0 && out.filter == EVFILT_PROC && (pid_t)out.ident == watched) {
            watched = 0;
            sharingGone();
        }
    }
    return NULL;
}

// ---- VPN NAT ----
//
// macOS's vmnet service translates the fast network's addresses (NAT) only on
// the interfaces that were up when it started. A VPN connected later (a new
// utun) gets the VMs' packets with their own source, 192.168.77.x, and the
// VPN's server drops them (a full tunnel: the VMs lose the internet). So
// while a VM is on the fast network, the daemon adds that NAT itself for each
// up interface the service does not cover, and takes it away when the
// interface goes, when the last VM leaves and when the daemon stops.
// - Only in its own pf anchor, NAT_ANCHOR: a child of "com.apple", which
//   macOS's main ruleset already evaluates (nat-anchor "com.apple/*"). No
//   other anchor and not the main ruleset is changed or flushed. Its rules
//   only match the fast network's addresses as source (NAT, written as the
//   service writes its own: "-> (if:0) extfilter ei") and reassemble
//   fragments arriving on those interfaces (the service does that on its own
//   ones too, also with no-df: pf would drop fragments that have DF set), so
//   the NAT works for fragmented replies. pf keeps an emptied
//   anchor listed (without rules) until the Mac restarts.
// - pf is enabled with a reference of our own (pfctl -E, given back with
//   pfctl -X): pf stays on as long as anyone else wants it.
// - Which interfaces the service covers: the "on <interface>" of its own
//   anchors (SHARED_V4, SHARED_V6). Which are up: getifaddrs. Names must be
//   of a kind that can carry the VMs' traffic away (NAT_KINDS: Ethernet and
//   Wi-Fi, VPN tunnels; never a bridge, so Parallels' and other VM networks
//   are not touched), letters then digits; addresses come from the kernel and
//   are printed with inet_ntop. Nothing in the rules comes from a VM or a user.
// - pfctl runs by its fixed path, with a fixed environment and no shell; the
//   rules go in on its stdin.
// - A routing socket says when interfaces or addresses change (no polling);
//   changes are gathered for NAT_SETTLE ms, then the anchor is set to what is
//   needed, only when that changed (or the anchor lost it). For an IPv4
//   address added to an interface that is already up (an ipsecN, a utun
//   brought up before its address) the service saw only RTM_ADD of the
//   address's own route: route changes count too (natChange).
// - NAT_FILE (readable by all: install.sh --status and omacvm check show it)
//   says what is translated and keeps the pf reference, so the next daemon
//   removes what one that crashed left.
#define NAT_ANCHOR "com.apple/org.omacvm.netd"
#ifndef NAT_FILE
#define NAT_FILE "/var/run/org.omacvm.netd.nat"
#endif
#define NAT_NET NET_PREFIX "0/24"
#define SHARED_V4 "com.apple.internet-sharing/shared_v4"
#define SHARED_V6 "com.apple.internet-sharing/shared_v6"
#ifndef PFCTL
#define PFCTL "/sbin/pfctl"
#endif
#ifndef PFCTL_WAIT
#define PFCTL_WAIT 10          // seconds pfctl may take, then it is killed
#endif
#define NAT_MAX 32             // interfaces
#define NAT_SETTLE 1000        // ms without changes before the NAT follows them ...
#define NAT_SETTLE_MAX 5000    // ... but no longer than this after the first

struct natIf { char name[IFNAMSIZ]; int v4, v6; char a6[INET6_ADDRSTRLEN]; };
struct natSet { int n; struct natIf i[NAT_MAX]; };

// A name for our rules: letters of a kind in NAT_KINDS, then 1-4 digits.
static int natName(const char *s) {
    static const char *kinds[] = { "en", "utun", "ipsec", "ppp", "tun", "tap" };   // NAT_KINDS
    size_t l = 0, d = 0;
    while (s[l] >= 'a' && s[l] <= 'z') l++;
    while (s[l + d] >= '0' && s[l + d] <= '9') d++;
    if (!l || !d || d > 4 || s[l + d] || l + d >= IFNAMSIZ) return 0;
    for (size_t k = 0; k < sizeof kinds / sizeof *kinds; k++)
        if (strlen(kinds[k]) == l && !strncmp(s, kinds[k], l)) return 1;
    return 0;
}

static struct natIf *natFind(const struct natSet *s, const char *name) {
    for (int i = 0; i < s->n; i++) if (!strcmp(s->i[i].name, name)) return (struct natIf *)&s->i[i];
    return NULL;
}

static struct natIf *natAdd(struct natSet *s, const char *name) {
    struct natIf *f = natFind(s, name);
    if (f || s->n >= NAT_MAX) return f;
    f = &s->i[s->n++];
    memset(f, 0, sizeof *f);
    snprintf(f->name, sizeof f->name, "%s", name);
    return f;
}

// The interfaces pfctl's listing of an anchor names ("... on en0 ...",
// "on { en0 en1 }"; "on ! en0" covers no en0), marked as covered for IPv4
// or IPv6.
static void natCovered(const char *text, struct natSet *cov, int v6) {
    char *copy = strdup(text), *save = NULL, *t;
    if (!copy) return;
    int on = 0, list = 0;
    for (t = strtok_r(copy, " \t\r\n", &save); t; t = strtok_r(NULL, " \t\r\n", &save)) {
        if (!on && !list) { on = !strcmp(t, "on"); continue; }
        if (!list && !strcmp(t, "{")) { list = 1; on = 0; continue; }
        if (list && !strcmp(t, "}")) { list = 0; continue; }
        if (!list && !strcmp(t, "!")) { on = 0; continue; }
        size_t l = strlen(t);
        if (l && t[l - 1] == ',') t[--l] = 0;
        size_t k = 0;
        while (k < l && ((t[k] >= 'a' && t[k] <= 'z') || (t[k] >= '0' && t[k] <= '9'))) k++;
        if (l && k == l && l < IFNAMSIZ) {
            struct natIf *f = natAdd(cov, t);
            if (f) { if (v6) f->v6 = 1; else f->v4 = 1; }
        }
        on = 0;
    }
    free(copy);
}

static int natCmp(const void *a, const void *b) { return strcmp(((const struct natIf *)a)->name, ((const struct natIf *)b)->name); }

// What needs our NAT: each up interface of a NAT_KINDS kind with an address
// of a family the service does not cover on it: IPv4 (not link-local, not
// the fast network's), IPv6 (not link-local; only while the fast network has
// an IPv6 prefix, prefix6, as vmnet told us). Sorted by name.
static void natWanted(struct ifaddrs *list, const struct natSet *cov, const char *prefix6, struct natSet *want) {
    struct in_addr first; inet_pton(AF_INET, NET_FIRST, &first);
    want->n = 0;
    for (struct ifaddrs *p = list; p; p = p->ifa_next) {
        unsigned f = p->ifa_flags;
        if (!p->ifa_addr || !(f & IFF_UP) || !(f & IFF_RUNNING) || (f & IFF_LOOPBACK) || !natName(p->ifa_name)) continue;
        const struct natIf *c = natFind(cov, p->ifa_name);
        if (p->ifa_addr->sa_family == AF_INET) {
            uint32_t a = ntohl(((struct sockaddr_in *)(void *)p->ifa_addr)->sin_addr.s_addr);
            if ((a >> 16) == 0xa9fe || (a >> 8) == ((ntohl(first.s_addr)) >> 8) || (a >> 24) == 127 || !a) continue;
            if (c && c->v4) continue;
            struct natIf *w = natAdd(want, p->ifa_name);
            if (w) w->v4 = 1;
        } else if (p->ifa_addr->sa_family == AF_INET6 && prefix6[0]) {
            const struct in6_addr *a = &((struct sockaddr_in6 *)(void *)p->ifa_addr)->sin6_addr;
            if (IN6_IS_ADDR_LINKLOCAL(a) || IN6_IS_ADDR_LOOPBACK(a) || IN6_IS_ADDR_UNSPECIFIED(a) || IN6_IS_ADDR_MULTICAST(a)) continue;
            if (c && c->v6) continue;
            struct natIf *w = natAdd(want, p->ifa_name);
            if (w && !w->v6 && inet_ntop(AF_INET6, a, w->a6, sizeof w->a6)) w->v6 = 1;
        }
    }
    qsort(want->i, (size_t)want->n, sizeof *want->i, natCmp);
}

// vmnet's IPv6 prefix for the fast network ("fd9f:b9:aae8:1ff::", a /64) as
// "fd9f:b9:aae8:1ff::/64" in out; "" if it is not one.
static void natPrefix(const char *vmnet, char *out, size_t len) {
    struct in6_addr a;
    char s[INET6_ADDRSTRLEN];
    out[0] = 0;
    if (!vmnet || inet_pton(AF_INET6, vmnet, &a) != 1 || IN6_IS_ADDR_LINKLOCAL(&a) || IN6_IS_ADDR_MULTICAST(&a)) return;
    for (int i = 8; i < 16; i++) a.s6_addr[i] = 0;
    if (inet_ntop(AF_INET6, &a, s, sizeof s)) snprintf(out, len, "%s/64", s);
}

// The anchor's rules for want (pf wants scrub before nat); -1 if they do not fit.
static int natRules(const struct natSet *want, const char *prefix6, char *buf, size_t len) {
    size_t o = 0;
    buf[0] = 0;
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < want->n; i++) {
            const struct natIf *w = &want->i[i];
            int n = 0;
            if (pass == 0)
                n = snprintf(buf + o, len - o, "scrub in on %s all no-df fragment reassemble\n", w->name);
            else {
                // As macOS's sharing writes its own: the interface's first
                // address, followed when it changes; endpoint-independent.
                if (w->v4) n = snprintf(buf + o, len - o, "nat on %s inet from " NAT_NET " to any -> (%s:0) extfilter ei\n", w->name, w->name);
                if (n >= 0 && (size_t)n < len - o && w->v6 && prefix6[0]) {
                    o += (size_t)n;
                    n = snprintf(buf + o, len - o, "nat on %s inet6 from %s to any -> (%s:0) extfilter ei\n", w->name, prefix6, w->name);
                }
            }
            if (n < 0 || (size_t)n >= len - o) return -1;
            o += (size_t)n;
        }
    return 0;
}

static int natSame(const struct natSet *a, const struct natSet *b) {
    if (a->n != b->n) return 0;
    for (int i = 0; i < a->n; i++)
        if (strcmp(a->i[i].name, b->i[i].name) || a->i[i].v4 != b->i[i].v4 || a->i[i].v6 != b->i[i].v6 ||
            strcmp(a->i[i].a6, b->i[i].a6)) return 0;
    return 1;
}

// "utun5 (IPv4, IPv6)" for the log.
static const char *natSays(const struct natIf *f, char *buf, size_t len) {
    snprintf(buf, len, "%s (%s%s%s)", f->name, f->v4 ? "IPv4" : "", f->v4 && f->v6 ? ", " : "", f->v6 ? "IPv6" : "");
    return buf;
}

// Runs pfctl with args (args[0] "pfctl"), in on its stdin; its output (and
// errors) in out. 0 when it exited 0.
static int pfctlRun(const char *const *args, const char *in, char *out, size_t outlen) {
    int ip[2], op[2];
    out[0] = 0;
    if (pipe(ip)) { snprintf(out, outlen, "pipe: %s", strerror(errno)); return -1; }
    if (pipe(op)) { snprintf(out, outlen, "pipe: %s", strerror(errno)); close(ip[0]); close(ip[1]); return -1; }
    fcntl(ip[1], F_SETFD, FD_CLOEXEC); fcntl(op[0], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t fa; posix_spawnattr_t at;
    posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&at);
    posix_spawn_file_actions_adddup2(&fa, ip[0], 0);
    posix_spawn_file_actions_adddup2(&fa, op[1], 1);
    posix_spawn_file_actions_adddup2(&fa, op[1], 2);
    sigset_t none, all; sigemptyset(&none); sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);   // SIGPIPE is ignored here, not in pfctl
    // Only 0, 1, 2 reach pfctl (no VM's socket, no listening socket).
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *const env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", NULL };
    pid_t pid = 0;
    int e = posix_spawn(&pid, PFCTL, &fa, &at, (char *const *)args, env);
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at);
    close(ip[0]); close(op[1]);
    if (e) { snprintf(out, outlen, "%s: %s", PFCTL, strerror(e)); close(ip[1]); close(op[0]); return -1; }
    if (in) {   // a few lines: they fit the pipe, and pfctl reads them all before it says anything
        size_t l = strlen(in), o = 0;
        while (o < l) {
            ssize_t w = write(ip[1], in + o, l - o);
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) break;
            o += (size_t)w;
        }
    }
    close(ip[1]);
    size_t have = 0;
    int late = 0;
    time_t end = time(NULL) + PFCTL_WAIT;
    for (;;) {
        int left = (int)(end - time(NULL));
        struct pollfd pf = { .fd = op[0], .events = POLLIN };
        if (left <= 0 || poll(&pf, 1, left * 1000) == 0) {
            kill(pid, SIGKILL);
            snprintf(out, outlen, "pfctl took over %d s: stopped", PFCTL_WAIT);
            late = 1;
            break;
        }
        char b[1024];
        ssize_t n = read(op[0], b, sizeof b);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        size_t k = (size_t)n < outlen - 1 - have ? (size_t)n : outlen - 1 - have;
        memcpy(out + have, b, k); have += k; out[have] = 0;
    }
    close(op[0]);
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return !late && WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : -1;
}
static int (*pfRun)(const char *const *args, const char *in, char *out, size_t outlen) = pfctlRun;   // the offline test puts its own in

static pthread_mutex_t natLock = PTHREAD_MUTEX_INITIALIZER;   // taken before lock, never after
static struct natSet natNow;        // what NAT_ANCHOR has
static char natNow6[64];            // ... with this IPv6 prefix of the fast network
static unsigned long long natToken; // our pf enable reference; 0: none
static int natDone;                 // the daemon stops: no more changes
static int natSaid;                 // "cannot read the service's rules" logged
static int natWake[2] = { -1, -1 };
static const char *natPath = NAT_FILE;
static char natVmnet6[64];          // the fast network's IPv6 prefix, from vmnet's start (under lock)

// pfctl's output for the log: one line, printable, short, without the
// notes it always prints (ALTQ, "Use of -f option ...").
static const char *natOut(char *out) {
    char *s = out;
    static const char *notes[] = { "No ALTQ", "ALTQ related", "pfctl: Use of -f option", "present in the main ruleset", "See /etc/pf.conf", "\n" };
    for (int more = 1; more;) {
        more = 0;
        for (size_t i = 0; i < sizeof notes / sizeof *notes; i++)
            if (!strncmp(s, notes[i], strlen(notes[i]))) { char *nl = strchr(s, '\n'); if (nl) { s = nl + 1; more = 1; } break; }
    }
    for (char *p = s; *p; p++) if (*p == '\n') *p = ' '; else if ((unsigned char)*p < 32 || (unsigned char)*p > 126) *p = '?';
    if (strlen(s) > 200) s[200] = 0;
    return s;
}

// NAT_FILE: "boot token interface...", readable by all; gone when nothing is ours.
static void natSave(void) {
    if (!natNow.n && !natToken) { unlink(natPath); return; }
    char b[64 + NAT_MAX * (IFNAMSIZ + 1)];
    int o = snprintf(b, sizeof b, "%ld %llu", bootTime(), natToken);
    for (int i = 0; i < natNow.n && o > 0 && (size_t)o < sizeof b; i++) o += snprintf(b + o, sizeof b - (size_t)o, " %s", natNow.i[i].name);
    if (o < 0 || (size_t)o >= sizeof b - 1) return;
    b[o++] = '\n';
    int fd = open(natPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return;
    if (write(fd, b, (size_t)o) != o) { /* the next save tries again */ }
    close(fd);
}

static int natLoad(const char *rules) {
    const char *a[] = { "pfctl", "-a", NAT_ANCHOR, "-f", "-", NULL };
    char out[1024];
    if (!pfRun(a, rules, out, sizeof out)) return 0;
    logf_("VPN NAT: pfctl could not set %s: %s", NAT_ANCHOR, natOut(out));
    return -1;
}

// Gives our pf reference back. NAT_FILE stops naming it first: pf's
// reference values can come back for another program, so a crash in between
// must leave one nobody gives back (pf stays on), never one a later -X (the
// next daemon, install.sh) would take from someone else.
static void natRelease(void) {
    if (!natToken) return;
    char t[24]; snprintf(t, sizeof t, "%llu", natToken);
    natToken = 0;
    natSave();
    const char *a[] = { "pfctl", "-X", t, NULL };
    char out[512];
    if (pfRun(a, NULL, out, sizeof out)) logf_("VPN NAT: pfctl -X %s failed: %s", t, natOut(out));
}

static int natEnable(void) {
    const char *a[] = { "pfctl", "-E", NULL };
    char out[1024];
    const char *t = NULL;
    if (!pfRun(a, NULL, out, sizeof out) && (t = strstr(out, "Token : "))) {
        char *end; unsigned long long v = strtoull(t + 8, &end, 10);
        if (end != t + 8 && v) { natToken = v; return 0; }
    }
    logf_("VPN NAT: pfctl -E failed: %s", natOut(out));
    return -1;
}

// Everything ours out of pf (under natLock).
static void natOff(const char *why) {
    if (!natNow.n && !natToken) return;
    int had = natNow.n;
    // Not taken out: all kept (and NAT_FILE says so), tried again on the next
    // change, or by the next daemon (natStart).
    if (had && natLoad("")) return;
    natNow.n = 0; natNow6[0] = 0;
    natRelease();
    natSave();
    if (had) logf_("VPN NAT off: %s", why);
}

static int natLive(void) {
    int any = 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_CONNS; i++) any |= live[i] != NULL;
    pthread_mutex_unlock(&lock);
    return any;
}

// The anchor still has a nat rule for each interface of natNow (nobody flushed it).
static int natStillThere(void) {
    const char *a[] = { "pfctl", "-a", NAT_ANCHOR, "-s", "nat", NULL };
    char out[8192];
    if (pfRun(a, NULL, out, sizeof out)) return 0;
    struct natSet have = { 0 };
    natCovered(out, &have, 0);
    for (int i = 0; i < natNow.n; i++) if (!natFind(&have, natNow.i[i].name)) return 0;
    return 1;
}

// Sets NAT_ANCHOR to what is needed now.
static void natSync(void) {
    pthread_mutex_lock(&natLock);
    struct natSet want = { 0 };
    char p6[64] = "";
    if (natDone) goto out;
    if (natLive()) {
        if (!findSharing()) goto out;   // the service restarts: the VMs connect again, then this runs again
        static const char *anchors[] = { SHARED_V4, SHARED_V4, SHARED_V6, SHARED_V6 }, *kinds[] = { "rules", "nat", "rules", "nat" };
        struct natSet cov = { 0 };
        char out[16384];
        for (int i = 0; i < 4; i++) {
            const char *a[] = { "pfctl", "-a", anchors[i], "-s", kinds[i], NULL };
            if (pfRun(a, NULL, out, sizeof out)) {
                if (!natSaid++) logf_("VPN NAT: macOS's sharing rules cannot be read (%s): VPN NAT not changed", natOut(out));
                goto out;
            }
            natCovered(out, &cov, i >= 2);
        }
        natSaid = 0;
        pthread_mutex_lock(&lock);
        snprintf(p6, sizeof p6, "%s", natVmnet6);
        pthread_mutex_unlock(&lock);
        struct ifaddrs *l;
        if (getifaddrs(&l)) goto out;
        natWanted(l, &cov, p6, &want);
        freeifaddrs(l);
    }
    if (natSame(&want, &natNow) && !strcmp(p6, natNow6) && (!want.n || natStillThere())) goto out;
    if (!want.n) { natOff(natLive() ? "macOS's sharing covers every network now" : "no VM on the fast network"); goto out; }
    char rules[NAT_MAX * 256];
    if (natRules(&want, p6, rules, sizeof rules)) goto out;
    if (!natToken) {
        if (natEnable()) goto out;
        natSave();   // the reference is kept before any rule: a crash leaves nothing unknown
    }
    if (natLoad(rules)) { if (!natNow.n) { natRelease(); natSave(); } goto out; }
    char s1[64];
    for (int i = 0; i < want.n; i++) {
        const struct natIf *o = natFind(&natNow, want.i[i].name);
        if (!o || o->v4 != want.i[i].v4 || o->v6 != want.i[i].v6)
            logf_("VPN NAT on %s: macOS's sharing does not cover it (a network that came up after it started, such as a VPN)",
                  natSays(&want.i[i], s1, sizeof s1));
    }
    for (int i = 0; i < natNow.n; i++)
        if (!natFind(&want, natNow.i[i].name)) logf_("VPN NAT off %s: gone, or covered by macOS's sharing now", natNow.i[i].name);
    natNow = want;
    snprintf(natNow6, sizeof natNow6, "%s", p6);
    natSave();
out:
    pthread_mutex_unlock(&natLock);
}

// Something changed for the NAT (a VM came or left, the service stopped).
static void natPoke(void) {
    if (natWake[1] >= 0 && write(natWake[1], "x", 1) < 0) { /* full: a wake is pending anyway */ }
}

// The daemon stops: nothing of ours stays in pf.
static void natStop(const char *why) {
    pthread_mutex_lock(&natLock);
    natDone = 1;
    natOff(why);
    pthread_mutex_unlock(&natLock);
}

// What a daemon before us left (it crashed or was killed): removed.
static void natStart(void) {
    char b[64 + NAT_MAX * (IFNAMSIZ + 1)] = "";
    int fd = open(natPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t r = read(fd, b, sizeof b - 1);
    close(fd);
    long boot = 0; unsigned long long tok = 0;
    if (r > 0 && sscanf(b, "%ld %llu", &boot, &tok) == 2 && boot == bootTime()) {
        pthread_mutex_lock(&natLock);
        natLoad("");
        natToken = tok;
        natRelease();
        pthread_mutex_unlock(&natLock);
        logf_("VPN NAT: removed what the daemon before left");
    }
    unlink(natPath);
}

static long msSince(const struct timespec *t) {
    struct timespec n; clock_gettime(CLOCK_MONOTONIC, &n);
    return (n.tv_sec - t->tv_sec) * 1000 + (n.tv_nsec - t->tv_nsec) / 1000000;
}

// A routing message (len bytes) that can change what needs our NAT: an
// interface's state, an address, or a route that is not a neighbour's
// (ARP/NDP) or a per-destination copy (RTF_LLINFO, RTF_WASCLONED: they come
// with every new peer and change nothing for the NAT). Only the first 4
// bytes (length, version, type) are common to all: address messages
// (ifa_msghdr) are shorter than an rt_msghdr. A route request that failed
// (rtm_errno) changed nothing.
static int natChange(const void *msg, ssize_t len) {
    if (len < (ssize_t)offsetof(struct rt_msghdr, rtm_index)) return 0;
    switch (((const unsigned char *)msg)[offsetof(struct rt_msghdr, rtm_type)]) {
    case RTM_IFINFO: case RTM_IFINFO2: case RTM_NEWADDR: case RTM_DELADDR: return 1;
    case RTM_ADD: case RTM_DELETE: case RTM_CHANGE: {
        struct rt_msghdr m;
        if (len < (ssize_t)sizeof m) return 0;
        memcpy(&m, msg, sizeof m);
        return !m.rtm_errno && !(m.rtm_flags & (RTF_LLINFO | RTF_WASCLONED));
    }
    default: return 0;
    }
}

// Waits for changes of interfaces and addresses (routing socket) and for
// natPoke, then lets the NAT follow.
static void *natWatch(void *arg) {
    (void)arg;
    int rs = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (rs < 0) { logf_("VPN NAT: no routing socket (%s): the NAT follows only VMs coming and going", strerror(errno)); }
    struct timespec first = { 0, 0 };
    long due = -1;   // ms after first; -1: nothing pending
    for (;;) {
        struct pollfd pf[2] = { { .fd = natWake[0], .events = POLLIN }, { .fd = rs, .events = POLLIN } };
        int wait = -1;
        if (due >= 0) { long left = due - msSince(&first); wait = left > 0 ? (int)left : 0; }
        int n = poll(pf, rs >= 0 ? 2 : 1, wait);
        if (n < 0 && errno != EINTR) { sleep(1); continue; }
        long settle = -1;
        if (n > 0 && (pf[0].revents & POLLIN)) {
            char b[64];
            while (read(natWake[0], b, sizeof b) > 0) {}
            settle = 0;
        }
        if (n > 0 && rs >= 0 && (pf[1].revents & POLLIN)) {
            char b[2048];
            ssize_t r = read(rs, b, sizeof b);
            if (r < 0 && errno == ENOBUFS) settle = NAT_SETTLE;   // messages lost: something changed
            else if (natChange(b, r)) settle = NAT_SETTLE;
        }
        if (settle >= 0) {
            if (due < 0) { clock_gettime(CLOCK_MONOTONIC, &first); due = settle; }
            else { long d = msSince(&first) + settle; due = d < NAT_SETTLE_MAX ? d : NAT_SETTLE_MAX; if (!settle) due = msSince(&first); }
        }
        if (due >= 0 && msSince(&first) >= due) { due = -1; natSync(); }
    }
    return NULL;
}

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
        vmnet_return_t st = vmnet_read(c->iface, pkts, &n);
        if (keepsFailing(&c->rfail, vmnetOk(st))) {
            // The interface is gone: end the connection (fromVM sees it).
            c->lastErr = st; c->broken = 1;
            shutdown(c->fd, SHUT_RDWR);
            return;
        }
        if (st != VMNET_SUCCESS || n <= 0) return;
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
    xpc_dictionary_set_string(desc, vmnet_start_address_key, NET_FIRST);
    xpc_dictionary_set_string(desc, vmnet_end_address_key, NET_LAST);
    xpc_dictionary_set_string(desc, vmnet_subnet_mask_key, NET_MASK);
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
            if (st == VMNET_SUCCESS && param) {
                maxPacket = (size_t)xpc_dictionary_get_uint64(param, vmnet_max_packet_size_key);
                natPrefix(xpc_dictionary_get_string(param, vmnet_nat66_prefix_key), natVmnet6, sizeof natVmnet6);
            }
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
            vmnet_return_t st = vmnet_write(c->iface, pkts, &sent);
            if (st != VMNET_SUCCESS) c->dropped += (unsigned long long)n;
            else { c->fromVM += (unsigned long long)sent; c->dropped += (unsigned long long)(n - sent); }
            if (keepsFailing(&c->wfail, vmnetOk(st))) { c->lastErr = st; c->broken = 1; break; }
        }
        if (c->broken) break;
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
    char other[IFNAMSIZ] = "";
    int r = foreignBridge(other, sizeof other) ? -3 : startInterface(c);
    if (r == -3) refused(c->pid, c->uid, "192.168.77.0/24 is up on another program's bridge: not starting vmnet (its VMs use the fast network's addresses)");
    else vmnetResult(r == 0);
    if (r == 0) {
        liveChange(c, 1, 1);
        time_t up = time(NULL);
        logf_("pid %d (uid %d): connected, vmnet interface up (max frame %zu)", c->pid, c->uid, c->maxPacket);
        fromVM(c);
        // Wake a write that waits for QEMU, then stop vmnet on its own queue:
        // no callback runs after the stop.
        shutdown(c->fd, SHUT_RDWR);
        hung = stopInterface(c) != 0;
        liveChange(c, 0, hung);
        if (c->broken && !c->gone) {
            // An interface that failed soon after its start counts as a failed
            // start (the back-off then lets the app fall back); one that
            // worked for a while does not (QEMU gets a new one at once).
            logf_("pid %d: vmnet kept failing (status %d): closing", c->pid, c->lastErr);
            if (time(NULL) - up < 30) vmnetResult(0);
        }
        logf_("pid %d: disconnected (%llu frames to the VM, %llu from it, %llu dropped)", c->pid, c->toVM, c->fromVM, c->dropped);
    } else if (r == -3) {
        close(c->fd);
        dispatch_release(c->q);
        slotGive(c->uid);
        free(c);
        return NULL;
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
    pthread_mutex_lock(&lock);
    lastActive = time(NULL);   // its users' VMs keep it alive (the back-off is in STATE_FILE anyway)
    pthread_mutex_unlock(&lock);
    const char *why = checkPeer(&tok);
    if (why) { refused(pid, uid, why); close(fd); return; }
    if (vmnetPaused()) { refused(pid, uid, "vmnet failed a moment ago: trying again later"); close(fd); return; }
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

// SIGTERM (launchd stops the service: install.sh, uninstall) or SIGINT (a
// test run): the main loop takes the VPN NAT out of pf, then exits.
static int stopPipe[2] = { -1, -1 };
static void onStop(int sig) {
    (void)sig;
    int e = errno;
    if (write(stopPipe[1], "s", 1) < 0) { /* one is enough */ }
    errno = e;
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
            const char *arg = argv[++i];
            char *end; long u = strtol(arg, &end, 10);
            if (end == arg || *end || u < 0 || u > (long)UINT32_MAX - 1) { fprintf(stderr, "omacvm-netd: --user takes a uid\n"); return 2; }
            if (nusers < MAX_USERS) users[nusers++] = (uid_t)u;
            else logf_("more than %d users: uid %ld left out", MAX_USERS, u);
        }
        else if (!strcmp(argv[i], "--socket") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) statePath = argv[++i];
        else { fprintf(stderr, "usage: omacvm-netd --requirement REQ --user UID... [--socket PATH] [--state FILE]\n"); return 2; }
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
    loadState();
    natStart();
    pthread_t w;
    if (pthread_create(&w, NULL, watchSharing, NULL) == 0) pthread_detach(w);
    if (pipe(natWake) == 0) {
        for (int i = 0; i < 2; i++) { fcntl(natWake[i], F_SETFL, O_NONBLOCK); fcntl(natWake[i], F_SETFD, FD_CLOEXEC); }
        if (pthread_create(&w, NULL, natWatch, NULL) == 0) pthread_detach(w);
    } else logf_("VPN NAT: no pipe (%s): off", strerror(errno));
    if (pipe(stopPipe) == 0) {
        for (int i = 0; i < 2; i++) { fcntl(stopPipe[i], F_SETFL, O_NONBLOCK); fcntl(stopPipe[i], F_SETFD, FD_CLOEXEC); }
        struct sigaction sa = { .sa_handler = onStop };
        sigemptyset(&sa.sa_mask);
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
    }

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
        struct pollfd pf[2] = { { .fd = ls, .events = POLLIN }, { .fd = stopPipe[0], .events = POLLIN } };
        int r = poll(pf, stopPipe[0] >= 0 ? 2 : 1, 10 * 1000);
        if (r == 0) {
            pthread_mutex_lock(&lock);
            int quit = !path && nconns == 0 && time(NULL) - lastActive >= IDLE_EXIT;
            pthread_mutex_unlock(&lock);
            if (quit) { natStop("no VM on the fast network"); return 0; }
            continue;
        }
        if (r < 0) { if (errno != EINTR) { logf_("poll: %s", strerror(errno)); sleep(1); } continue; }
        if (pf[1].revents & POLLIN) { natStop("the service stops"); logf_("stopped"); return 0; }
        if (!(pf[0].revents & POLLIN)) continue;
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) { if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) continue; logf_("accept: %s", strerror(errno)); sleep(1); continue; }
        accepted(fd);
    }
}
