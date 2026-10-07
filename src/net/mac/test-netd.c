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
#define PFCTL_WAIT 2   // PFCTL: a stand-in from test.sh
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

static vmnet_return_t writeFails;   // what vmnet_write answers; 0: success
vmnet_return_t fake_write(interface_ref i, struct vmpktdesc *p, int *n) {
    (void)i; (void)p;
    if (writeFails) return writeFails;
    (void)n;
    return VMNET_SUCCESS;
}

// The Mac's interfaces: one, with this name and address (or fakeList).
static const char *ifName = "en0", *ifAddr = "192.168.1.5";
static struct sockaddr_in fakeSin;
static struct ifaddrs fakeIfa;
static struct ifaddrs *fakeList;
int fake_getifaddrs(struct ifaddrs **l) {
    if (fakeList) { *l = fakeList; return 0; }
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
static pid_t sharingRuns(void) { return 1; }
static pid_t sharingStopped(void) { return 0; }
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

// ---- VPN NAT: interfaces, macOS's sharing rules and pfctl made up ----

// A made-up interface list (kept for the whole run).
static struct ifaddrs *ifs;
static void ifAdd(const char *name, unsigned flags, const char *addr, int plen) {
    struct ifaddrs *a = calloc(1, sizeof *a);
    a->ifa_name = strdup(name);
    a->ifa_flags = flags;
    if (strchr(addr, ':')) {
        struct sockaddr_in6 *s6 = calloc(1, sizeof *s6), *m6 = calloc(1, sizeof *m6);
        s6->sin6_len = m6->sin6_len = sizeof *s6; s6->sin6_family = m6->sin6_family = AF_INET6;
        inet_pton(AF_INET6, addr, &s6->sin6_addr);
        for (int i = 0; i < plen; i++) m6->sin6_addr.s6_addr[i / 8] |= (unsigned char)(0x80 >> (i % 8));
        a->ifa_addr = (struct sockaddr *)s6; a->ifa_netmask = (struct sockaddr *)m6;
    } else {
        struct sockaddr_in *s4 = calloc(1, sizeof *s4);
        s4->sin_len = sizeof *s4; s4->sin_family = AF_INET;
        inet_pton(AF_INET, addr, &s4->sin_addr);
        a->ifa_addr = (struct sockaddr *)s4;
    }
    a->ifa_next = ifs; ifs = a;
}
// Takes an interface out of the list (it went away).
static void ifDrop(const char *name) {
    for (struct ifaddrs **p = &ifs; *p;) if (!strcmp((*p)->ifa_name, name)) *p = (*p)->ifa_next; else p = &(*p)->ifa_next;
}

// What macOS's sharing has in its anchors on a Mac with Wi-Fi, Ethernet and
// Tailscale up when it started (pfctl -a com.apple.internet-sharing/shared_v4 -s rules).
static const char *sharedRules =
    "No ALTQ support in kernel\nALTQ related functions disabled\n"
    "scrub on utun9 all no-df fragment reassemble\nscrub on en1 all no-df fragment reassemble\n"
    "scrub on en0 all no-df fragment reassemble\npass on utun9 inet all flags any keep state\n"
    "pass on utun9 inet proto esp all no state\npass inet proto igmp all keep state allow-opts\n"
    "pass on en1 inet all flags any keep state\npass on en0 inet all flags any keep state\n";
static const char *sharedNat = "nat on en0 inet from 192.168.77.0/24 to any -> (en0) extfilter ei\n";

// pfctl stand-in: what it was asked, in order; answers like pfctl.
static char pfLog[16384], pfAnchor[4096];
static int pfFailE, pfFailRead, pfFlushed, pfXNamed;
static int fakePf(const char *const *a, const char *in, char *out, size_t len) {
    char cmd[256] = "";
    for (int i = 1; a[i]; i++) { strlcat(cmd, a[i], sizeof cmd); if (a[i + 1]) strlcat(cmd, " ", sizeof cmd); }
    strlcat(pfLog, cmd, sizeof pfLog); strlcat(pfLog, "\n", sizeof pfLog);
    out[0] = 0;
    if (strcmp(a[0], "pfctl")) return -1;
    if (!strcmp(cmd, "-E")) {
        if (pfFailE) { snprintf(out, len, "pfctl: /dev/pf: Permission denied"); return -1; }
        snprintf(out, len, "No ALTQ support in kernel\npf enabled\nToken : 4242\n"); return 0;
    }
    if (!strncmp(cmd, "-X ", 3)) {   // NAT_FILE must not name the reference any more
        char b[512] = ""; FILE *f = fopen(natPath, "r");
        if (f) { size_t n = fread(b, 1, sizeof b - 1, f); b[n] = 0; fclose(f); }
        if (strstr(b, cmd + 3)) pfXNamed = 1;
        return 0;
    }
    if (!strcmp(cmd, "-a " NAT_ANCHOR " -f -")) { snprintf(pfAnchor, sizeof pfAnchor, "%s", in ? in : ""); pfFlushed = 0; return 0; }
    if (!strcmp(cmd, "-a " NAT_ANCHOR " -s nat")) { if (!pfFlushed) { char *n = strstr(pfAnchor, "nat on"); snprintf(out, len, "%s", n ? n : ""); } return 0; }
    if (pfFailRead) { snprintf(out, len, "pfctl: DIOCGETRULES: Invalid argument"); return -1; }
    if (strstr(cmd, "shared_v4 -s rules") || strstr(cmd, "shared_v6 -s rules")) { snprintf(out, len, "%s", sharedRules); return 0; }
    if (strstr(cmd, "shared_v4 -s nat")) { snprintf(out, len, "%s", sharedNat); return 0; }
    if (strstr(cmd, "-s nat")) return 0;
    return -1;
}
static int pfAsked(const char *cmd) {
    char line[300]; snprintf(line, sizeof line, "%s\n", cmd);
    return strstr(pfLog, line) != NULL;
}
static char *slurp(const char *path) {
    static char b[512]; b[0] = 0;
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    size_t n = fread(b, 1, sizeof b - 1, f); b[n] = 0; fclose(f);
    return b;
}

static void natTests(void) {
    const unsigned UPR = IFF_UP | IFF_RUNNING;
    // Names: only the kinds that carry traffic away, letters then digits.
    expect(natName("en0") && natName("utun12") && natName("ipsec0") && natName("ppp0") && natName("tun3") && natName("tap0"),
           "VPN NAT: en, utun, ipsec, ppp, tun, tap interfaces may get it");
    expect(!natName("bridge100") && !natName("vmenet0") && !natName("lo0") && !natName("awdl0") && !natName("utun") &&
           !natName("utun5;x") && !natName("en0 ") && !natName("EN0") && !natName("utun12345") && !natName("") &&
           !natName("en0/24") && !natName("utun1\n"),
           "VPN NAT: bridges (Parallels, other VM networks), loopback, odd or unsafe names never");

    // What macOS's sharing covers, from its own anchors.
    struct natSet cov = { 0 };
    natCovered(sharedRules, &cov, 0);
    natCovered(sharedNat, &cov, 0);
    natCovered(sharedRules, &cov, 1);
    natCovered("pass on { en2, en3 } all\npass on ! en5 all\nblock drop on \"en6\" all\n", &cov, 0);
    struct natIf *e0 = natFind(&cov, "en0"), *u9 = natFind(&cov, "utun9"), *e2 = natFind(&cov, "en2"), *e3 = natFind(&cov, "en3");
    expect(cov.n == 5 && e0 && e0->v4 && e0->v6 && u9 && u9->v4 && u9->v6 && natFind(&cov, "en1") && e2 && e3 && e2->v4 && !e2->v6 &&
           !natFind(&cov, "en5") && !natFind(&cov, "en6"),
           "VPN NAT: interfaces macOS's sharing covers read from its rules (lists, negation, junk)");

    // The Mac: Wi-Fi, Ethernet, Tailscale (covered), a VPN that came later
    // (utun5, IPv4 + IPv6), an Apple tunnel with only a link-local address,
    // Parallels' bridge, the fast network's bridge, odd ones.
    ifAdd("lo0", UPR | IFF_LOOPBACK, "127.0.0.1", 0);
    ifAdd("en0", UPR, "192.168.0.10", 0); ifAdd("en0", UPR, "2a02:1:2:3::10", 64);
    ifAdd("en1", UPR, "192.168.0.11", 0);
    ifAdd("utun9", UPR | IFF_POINTOPOINT, "100.120.222.125", 0); ifAdd("utun9", UPR, "fd7a:115c:a1e0::1", 128);
    ifAdd("utun5", UPR | IFF_POINTOPOINT, "10.8.0.2", 0); ifAdd("utun5", UPR, "fe80::1", 64); ifAdd("utun5", UPR, "fd00:8::2", 64);
    ifAdd("utun3", UPR, "fe80::3", 64);
    ifAdd("bridge100", UPR, "10.211.55.2", 0);
    ifAdd("bridge102", UPR, "192.168.77.1", 0); ifAdd("bridge102", UPR, "fdb3:1:2:3::1", 64); ifAdd("bridge102", UPR, "fe80::77", 64);
    ifAdd("en7", UPR, "169.254.3.4", 0);
    ifAdd("ipsec0", IFF_UP, "10.9.0.2", 0);           // not running
    ifAdd("en9", UPR, "192.168.77.5", 0);             // a LAN on the fast network's addresses
    ifAdd("utun6;x", UPR, "10.10.0.2", 0);            // no such name from the kernel, but never in a rule
    // vmnet's IPv6 prefix for the fast network (its start says it).
    char p6[64];
    natPrefix("fd9f:b9:aae8:1ff::", p6, sizeof p6);
    int prefixOk = !strcmp(p6, "fd9f:b9:aae8:1ff::/64");
    natPrefix("fd9f:b9:aae8:1ff:1:2:3:4", p6, sizeof p6);
    prefixOk &= !strcmp(p6, "fd9f:b9:aae8:1ff::/64");
    natPrefix("fd9f::/64 to any", p6, sizeof p6); prefixOk &= !p6[0];
    natPrefix("fe80::1", p6, sizeof p6); prefixOk &= !p6[0];
    natPrefix(NULL, p6, sizeof p6); prefixOk &= !p6[0];
    expect(prefixOk, "VPN NAT: vmnet's IPv6 prefix taken as a /64, anything else not");
    struct natSet want;
    natWanted(ifs, &cov, "fdb3:1:2:3::/64", &want);
    struct natIf *u5 = natFind(&want, "utun5");
    expect(want.n == 1 && u5 && u5->v4 && u5->v6 && !strcmp(u5->a6, "fd00:8::2"),
           "VPN NAT: only the VPN that came later (IPv4 + IPv6), not covered, link-local, bridges, down or odd ones");
    char rules[NAT_MAX * 256];
    expect(!natRules(&want, "fdb3:1:2:3::/64", rules, sizeof rules) && !strcmp(rules,
           "scrub in on utun5 all no-df fragment reassemble\n"
           "nat on utun5 inet from 192.168.77.0/24 to any -> (utun5:0) extfilter ei\n"
           "nat on utun5 inet6 from fdb3:1:2:3::/64 to any -> (utun5:0) extfilter ei\n"),
           "VPN NAT: the anchor's rules: scrub first, then NAT for the fast network's addresses only (as macOS's own)");
    char tiny[40];
    expect(natRules(&want, "fdb3:1:2:3::/64", tiny, sizeof tiny) == -1, "VPN NAT: rules that do not fit are not cut short");
    // A fast network without IPv6: IPv4 only.
    struct natSet cov4 = { 0 }; natCovered(sharedRules, &cov4, 0);
    natWanted(ifs, &cov4, "", &want);
    u5 = natFind(&want, "utun5");
    struct natIf *w0 = natFind(&want, "en0");
    expect(u5 && u5->v4 && !u5->v6 && want.n == 1 && !w0, "VPN NAT: no IPv6 prefix on the fast network: IPv4 only");
    // Routing messages that can change the NAT, as the service saw them on macOS 27 (Mac mini, 2026-10-06):
    // for an IPv4 address on an up ipsec0 or lo0 only RTM_ADD of its local route (0x200005), for its removal
    // RTM_DELETE; ARP entries (RTF_LLINFO), per-destination copies (RTF_WASCLONED) and failed requests
    // (rtm_errno) change nothing.
    struct { int type, flags, want; } rtm[] = {
        { RTM_ADD, 0x200005, 1 }, { RTM_DELETE, 0x2200004, 1 }, { RTM_ADD, 0x841, 1 }, { RTM_CHANGE, 0x101, 1 },
        { RTM_IFINFO, 0x8051, 1 }, { RTM_NEWADDR, 0x100, 1 }, { RTM_DELADDR, 0x100, 1 }, { RTM_IFINFO2, 0, 1 },
        { RTM_ADD, 0x1200405, 0 }, { RTM_DELETE, 0x3200004 | RTF_LLINFO, 0 }, { RTM_ADD, 0x20045 | RTF_WASCLONED, 0 },
        { RTM_GET, 0x5, 0 }, { RTM_MISS, 0x5, 0 }, { RTM_NEWMADDR, 0, 0 },
    };
    int rtmOk = 1;
    for (size_t i = 0; i < sizeof rtm / sizeof *rtm; i++) {
        struct rt_msghdr m = { .rtm_msglen = sizeof m, .rtm_version = RTM_VERSION, .rtm_type = (unsigned char)rtm[i].type, .rtm_flags = rtm[i].flags };
        if (natChange(&m, sizeof m) != rtm[i].want) { rtmOk = 0; fprintf(stderr, "natChange type %d flags %#x: want %d\n", rtm[i].type, rtm[i].flags, rtm[i].want); }
    }
    struct rt_msghdr shortMsg = { .rtm_type = RTM_ADD, .rtm_flags = 0x200005 };
    rtmOk &= !natChange(&shortMsg, 4) && !natChange(&shortMsg, -1);
    struct rt_msghdr failed = { .rtm_type = RTM_ADD, .rtm_flags = 0x200005, .rtm_errno = EEXIST };
    rtmOk &= !natChange(&failed, sizeof failed);
    // An IPv4 address message (ifa_msghdr and its sockaddrs) is shorter than an rt_msghdr: it still counts.
    struct ifa_msghdr ifam = { .ifam_msglen = 80, .ifam_version = RTM_VERSION, .ifam_type = RTM_NEWADDR };
    char addrMsg[80] = { 0 }; memcpy(addrMsg, &ifam, sizeof ifam);
    rtmOk &= natChange(addrMsg, sizeof addrMsg) && !natChange(addrMsg, 3);
    ifam.ifam_type = RTM_DELADDR; memcpy(addrMsg, &ifam, sizeof ifam);
    rtmOk &= natChange(addrMsg, sizeof addrMsg);
    expect(rtmOk, "VPN NAT: an address on an up interface (only RTM_ADD of its route) counts; ARP and cloned routes do not");
    // pfctl's notes are not what the log says.
    char noisy[] = "No ALTQ support in kernel\nALTQ related functions disabled\npfctl: Use of -f option, could result in flushing of rules\n"
                   "present in the main ruleset added by the system at startup.\nSee /etc/pf.conf for further details.\n\n"
                   "stdin:1: syntax error\npfctl: Syntax error in config file\x1b[0m";
    expect(!strcmp(natOut(noisy), "stdin:1: syntax error pfctl: Syntax error in config file?[0m"), "VPN NAT: pfctl's errors logged without its notes, printable");

    // natSync with pfctl, the Mac and a VM made up.
    char np[PATH_MAX]; snprintf(np, sizeof np, "%s.nat", statePath);
    natPath = np; unlink(np);
    pfRun = fakePf; fakeList = ifs; findSharing = sharingRuns;
    static struct conn vm = { .fd = -1 };
    snprintf(natVmnet6, sizeof natVmnet6, "fdb3:1:2:3::/64");
    natSync();
    expect(!pfLog[0] && !natNow.n, "VPN NAT: no VM on the fast network: pfctl not even asked");
    live[0] = &vm;
    natSync();
    char *f = slurp(np), want1[64];
    snprintf(want1, sizeof want1, "%ld 4242 utun5\n", bootTime());
    expect(pfAsked("-a " SHARED_V4 " -s rules") && pfAsked("-a " SHARED_V6 " -s nat") && pfAsked("-E") &&
           strstr(pfAnchor, "nat on utun5 inet from 192.168.77.0/24") && natToken == 4242 && f && !strcmp(f, want1),
           "VPN NAT: a VM runs: pf enabled with our own reference, rules in our anchor, NAT_FILE says so");
    expect(!strstr(pfLog, "-F") && !strstr(pfLog, "-d\n") && !strstr(pfLog, "-a com.apple.internet-sharing/shared_v4 -f") &&
           !strstr(pfLog, "-a com.apple -f"),
           "VPN NAT: never a flush, never pf disabled, no other anchor written");
    pfLog[0] = 0;
    natSync();
    expect(!pfAsked("-E") && !pfAsked("-a " NAT_ANCHOR " -f -") && pfAsked("-a " NAT_ANCHOR " -s nat"),
           "VPN NAT: nothing changed: the anchor is checked, not loaded again (idempotent)");
    pfFlushed = 1; pfLog[0] = 0;
    natSync();
    expect(pfAsked("-a " NAT_ANCHOR " -f -") && !pfAsked("-E") && strstr(pfAnchor, "utun5"),
           "VPN NAT: someone emptied our anchor: loaded again");
    // The VPN goes: our NAT and our pf reference go.
    ifDrop("utun5"); pfLog[0] = 0;
    natSync();
    expect(pfAsked("-a " NAT_ANCHOR " -f -") && !pfAnchor[0] && pfAsked("-X 4242") && !natToken && !natNow.n && !slurp(np),
           "VPN NAT: the VPN goes down: anchor emptied, pf reference given back, NAT_FILE gone");
    // ... and comes back (another utun): again.
    ifAdd("utun7", IFF_UP | IFF_RUNNING, "10.8.0.6", 0); fakeList = ifs; pfLog[0] = 0;
    natSync();
    expect(strstr(pfAnchor, "nat on utun7 inet from") && natToken == 4242, "VPN NAT: the VPN comes back: NAT again");
    // macOS's sharing rules cannot be read: nothing changes.
    pfFailRead = 1; ifDrop("utun7"); pfLog[0] = 0;
    natSync();
    expect(natNow.n == 1 && natToken == 4242 && !pfAsked("-X 4242"), "VPN NAT: macOS's sharing rules unreadable: nothing changed");
    pfFailRead = 0;
    // The last VM leaves: all ours goes.
    ifAdd("utun7", IFF_UP | IFF_RUNNING, "10.8.0.6", 0); fakeList = ifs;
    live[0] = NULL; pfLog[0] = 0;
    natSync();
    expect(!pfAnchor[0] && pfAsked("-X 4242") && !natNow.n && !slurp(np), "VPN NAT: the last VM leaves: anchor emptied, reference back");
    // pfctl -E fails: no rules, no file.
    live[0] = &vm; pfFailE = 1; pfLog[0] = 0;
    natSync();
    expect(!pfAsked("-a " NAT_ANCHOR " -f -") && !natNow.n && !slurp(np), "VPN NAT: pf cannot be enabled: no rules loaded");
    pfFailE = 0;
    natSync();
    expect(natNow.n == 1 && natToken == 4242, "VPN NAT: ... and works on the next change");
    // The daemon stops (launchd's SIGTERM): nothing stays; no change after.
    pfLog[0] = 0;
    natStop("test");
    expect(!pfAnchor[0] && pfAsked("-X 4242") && !slurp(np), "VPN NAT: the daemon stops: anchor emptied, reference back");
    natSync();
    expect(!natNow.n && !natToken, "VPN NAT: ... and stays off");
    // A daemon that crashed left rules and a reference: the next one removes them.
    FILE *o = fopen(np, "w"); fprintf(o, "%ld 777 utun7\n", bootTime()); fclose(o);
    snprintf(pfAnchor, sizeof pfAnchor, "nat on utun7 inet from 192.168.77.0/24 to any -> (utun7)\n");
    pfLog[0] = 0;
    natStart();
    expect(!pfAnchor[0] && pfAsked("-X 777") && !slurp(np), "VPN NAT: what a crashed daemon left is removed at start");
    o = fopen(np, "w"); fprintf(o, "%ld 778 utun7\n", bootTime() - 100); fclose(o);
    pfLog[0] = 0;
    natStart();
    expect(!pfLog[0] && !slurp(np), "VPN NAT: ... but not a reference of an earlier boot (pf started over)");
    expect(!pfXNamed, "VPN NAT: NAT_FILE stops naming the pf reference before it is given back (no stale -X after a crash)");
    live[0] = NULL; natDone = 0; fakeList = NULL; pfRun = pfctlRun;

    // pfctl itself (test.sh's stand-in prints its arguments, its stdin and
    // its open descriptors): arguments and rules arrive unchanged, nothing
    // but 0, 1, 2 is passed on (no VM's socket), a hung one is stopped.
    int keep = open("/dev/null", O_RDONLY);   // not CLOEXEC: must still not reach pfctl
    char out[4096];
    const char *a1[] = { "pfctl", "-a", NAT_ANCHOR, "-f", "-", NULL };
    int r = pfctlRun(a1, "nat on utun5 inet from 192.168.77.0/24 to any -> (utun5)\n", out, sizeof out);
    expect(!r && strstr(out, "args: -a " NAT_ANCHOR " -f -\n") && strstr(out, "in: nat on utun5 inet from 192.168.77.0/24 to any -> (utun5)\n") &&
           strstr(out, "fds: 0 1 2\n") && strstr(out, "env: PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C\n"),
           "pfctl gets its arguments and rules unchanged, a fixed environment and only stdin/stdout/stderr");
    close(keep);
    const char *a2[] = { "pfctl", "fail", NULL };
    expect(pfctlRun(a2, NULL, out, sizeof out) == -1 && strstr(out, "args: fail"), "pfctl failing: reported, its output kept");
    const char *a3[] = { "pfctl", "hang", NULL };
    time_t t0 = time(NULL);
    r = pfctlRun(a3, NULL, out, sizeof out);
    expect(r == -1 && time(NULL) - t0 <= PFCTL_WAIT + 1 && strstr(out, "took over"), "pfctl hanging: stopped after PFCTL_WAIT");
}

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

    // Another program's bridge on 192.168.77.0/24 after a failed start: no
    // start (no leak) while it is there.
    expect(liveIfaces == 1, "the interface whose stop was never answered still counts as ours");
    liveIfaces = 0; inherited = 0;
    ifName = "bridge100"; ifAddr = "192.168.77.1"; stops = 0;
    findSharing = sharingRuns;
    char who[IFNAMSIZ];
    expect(!foreignBridge(who, sizeof who), "a bridge on 192.168.77.1 before any failure: start (it may be one the service left)");
    vmnetFailures = 1;
    expect(foreignBridge(who, sizeof who) && !strcmp(who, "bridge100"), "after a failure, another program's bridge on 192.168.77.1 is seen");
    oneConnection();
    expect(stops == 0 && vmnetFailures == 1 && nconns == 0, "... and vmnet is not started for it");
    findSharing = sharingStopped;
    expect(!foreignBridge(who, sizeof who), "... but not while the vmnet service is not running (a bridge it left)");
    findSharing = sharingRuns;
    liveIfaces = 1;
    expect(!foreignBridge(who, sizeof who), "with an interface of ours up, the bridge is ours");
    liveIfaces = 0; inherited = 1;
    expect(!foreignBridge(who, sizeof who), "... also when the daemon before us left interfaces up");
    inherited = 0; ifName = "en0";
    expect(!foreignBridge(who, sizeof who), "a LAN on 192.168.77.0/24 is the app's to see, not this");
    ifAddr = "192.168.1.5"; resetBackoff();

    // An interface that keeps failing (InternetSharing restarted under it) is
    // closed within seconds; soon after its start that counts as a failure.
    writeFails = VMNET_FAILURE;
    t = talkingConnection(10);
    expect(t >= FAIL_SECS && t < 5 && nconns == 0 && liveIfaces == 0 && vmnetFailures == 1,
           "vmnet writes keep failing: connection closed, counts as a failed start");
    resetBackoff(); writeFails = 0;
    t = talkingConnection(3);
    expect(t >= 2 && nconns == 0 && vmnetFailures == 0, "vmnet writes work: connection kept until the VM closes");
    // Full vmnet buffers (VMNET_BUFFER_EXHAUSTED) drop frames; the interface works.
    writeFails = VMNET_BUFFER_EXHAUSTED;
    t = talkingConnection(4);
    expect(t >= 3 && nconns == 0 && vmnetFailures == 0, "vmnet buffers full: frames dropped, connection kept, no failure");
    writeFails = 0;

    // A process of a user named InternetSharing (test.sh starts one) is not
    // macOS's service: its exit must not close anyone's connection.
    const char *fp = getenv("NETD_FAKE_SHARING");
    if (fp) {
        pid_t fake = (pid_t)atoi(fp), real = sharingPid();
        char name[2 * MAXCOMLEN + 1] = "";
        proc_name(fake, name, sizeof name);
        expect(!strcmp(name, SHARING) && !isSharing(fake) && real != fake,
               "a user's process named InternetSharing is not taken for macOS's service");
    }

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

    natTests();

    // The limits: MAX_PER_UID per user, MAX_CONNS in all.
    int got = 0;
    for (int i = 0; i < MAX_PER_UID + 1; i++) got += slotTake(600);
    expect(got == MAX_PER_UID, "per-user limit");
    for (int u = 700; u < 700 + MAX_CONNS; u++) got += slotTake((uid_t)u);
    expect(nconns == MAX_CONNS, "total limit");
    return failures ? 1 : 0;
}
