// omacvm-gestures (Mac side): gives the Omarchy VM in Parallels the Mac trackpad's
// multi-finger gestures.
//
// While Parallels or UTM is the frontmost app and its VM window covers a whole display
// ("capture mode"):
//   * macOS trackpad gesture events (Spaces / Mission Control swipes, pinch,
//     rotate, smart zoom) are dropped by an event tap, so macOS reacts to none
//     of them;
//   * raw finger contacts from the built-in trackpad (MultitouchSupport) are
//     sent to the guest daemon, which replays them on a virtual touchpad:
//     every frame with 3+ fingers, and 2-finger frames once they are a pinch;
//   * one-finger movement, clicks and two-finger scrolling stay on Parallels'
//     own path (absolute pointer, native smooth scrolling), unless the VM
//     uses Glide (below).
// While the VM is full screen, the macOS pointer is hidden wherever the VM window
// is what lies under it (the guest draws its own pointer); over anything else
// (the Omanotch strip, the Dock, menus, another display) it shows.
// Ctrl+Option+Cmd+Esc toggles capture off/on; it re-arms by itself when
// Parallels becomes frontmost again. If this process dies, the event tap goes
// with it and macOS gets its gestures back.
// Each VM says on connect what it wants (the handshake below). Capture
// only covers a full-screen VM whose connected daemon wants the trackpad, so a
// VM with gestures off (or not connected yet) leaves macOS its gestures.
// Glide (experimental, per VM): two-finger scrolling goes to the guest too.
// While fingers touch the built-in trackpad, their raw positions do (every
// two-finger frame, precise to hundredths of a millimetre) along with macOS's
// own scroll for them ("A", macOS's acceleration); after they lift, macOS's
// momentum goes as point deltas ("W"), which the guest continues the touch
// with. macOS's own scroll events then do not reach the VM app. Other
// continuous scrolling (Magic Mouse) goes as W deltas as a whole; a wheel
// mouse (discrete steps) still scrolls through the VM app.
// --keys-only: no trackpad for any VM (macOS keeps every gesture); on UTM, Cmd
// still reaches the guest as Super (below). --record: the built-in trackpad's
// frames and macOS's scroll events to ~/Library/Logs/omacvm-input.tsv (Glide
// diagnostics, see docs/experiments/scroll-analysis).
//
// Protocol (TCP, the guest connects to the Mac on port 47830: 10.211.55.2 on
// Parallels, 192.168.64.1 on UTM, .1 of Fusion's NAT network), one line per message:
//   F <n> [<id> <x> <y> <size>]...   x/y 0..1 with y down, size >= 0
//   S <on|off|esc>                    capture state changes
//   O <natural> <w> <h>               on connect: macOS's natural scrolling (1/0) and the
//                                     trackpad's size in 1/100 mm
//   A <dx> <dy>                       Glide: macOS's scroll while the fingers touch (points)
//   W <dx> <dy>                       Glide: macOS's momentum (and Magic Mouse) in points
//   P                                 Glide: macOS recognized a pinch (magnify)
//   K <code> <0|1|2>                  UTM: a Cmd shortcut as Super+key (Linux keycode)
// and first, the handshake (any VM on these networks, and any Mac program on
// 127.0.0.1, can connect; neither side ever sends the Bridge's token itself):
//   C <guest nonce>                   from the guest: 32 hex digits
//   M <mac nonce> <proof>             the Mac proves it knows the token: HMAC-SHA256(token,
//                                     "omacvm-gestures mac <addr> <guest nonce> <mac nonce>"), hex;
//                                     <addr>: the Mac address it accepted on, so a proof that
//                                     a listener on 127.0.0.1 fetched from 10.211.55.2 fails
//   R <gestures 0|1> <glide 0|1> <proof> [<name>]   from the guest once the Mac's proof
//                                     holds: what this VM wants, its own proof (as above
//                                     with "vm") and the VM's name in base64 (omacvm apply
//                                     tells the VM). Only then do the lines above flow.
// Daemons from before the handshake (OmacVM 2.4, 2.5) send "H <gestures> <glide>
// <token> [<name>]", still let in until omacvm apply gives them the new one.
// Daemons from before the token (2.3 and older) are refused: omacvm update.
// Two VMs in one app share its network: F, K, A, W, P and S on/esc go only to
// the VM whose name is in the title of the app's front window; without such a
// match (VMs from before the name, a renamed VM) to every VM of that app.
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0   // macOS: SO_NOSIGPIPE is set on the socket instead
#endif

// ---- MultitouchSupport (private framework) ----
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
  int32_t frame; double timestamp; int32_t pathIndex, state, fingerID, handID;
  MTVector normalized; float zTotal; int32_t f9; float angle, majorAxis, minorAxis;
  MTVector absolute; int32_t f14, f15; float zDensity;
} MTTouch;
typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int, double, int);
extern CFArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallback);
extern void MTDeviceStart(MTDeviceRef, int);
extern bool MTDeviceIsBuiltIn(MTDeviceRef);
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *, int *);   // 1/100 mm

#ifndef PORT
#define PORT 47830
#endif
// The Mac's address on each VM network: Parallels' shared network, UTM's
// shared network (vmnet), VMware Fusion's NAT network (vmnet8: Fusion picks
// its subnet at install time, the Mac is .1; empty without Fusion) and
// OmacVM.app (QEMU's user network reaches the Mac's 127.0.0.1). One listener
// per address; never 0.0.0.0.
static char listenAddrs[4][16] = { "10.211.55.2", "192.168.64.1", "", "127.0.0.1" };
#define NET_UTM 1
#define NET_FUSION 2
#define NET_APP 3

// The first VNET_8_HOSTONLY_SUBNET line, and only a private address (as
// fusion_host in src/lib/mac.sh and the Bridge read it). Fusion installed
// after this helper started: the Fusion listener reads it again until found.
static void readFusionHost(void) {
  FILE *f = fopen("/Library/Preferences/VMware Fusion/networking", "r");
  char line[256], net[32];
  struct in_addr a;
  if (!f) return;
  while (fgets(line, sizeof line, f)) {
    if (sscanf(line, "answer VNET_8_HOSTONLY_SUBNET %31s", net) != 1) continue;
    if (inet_pton(AF_INET, net, &a) == 1) {
      uint32_t h = ntohl(a.s_addr);
      int priv = (h >> 24) == 10 || (h >> 20) == 0xAC1 || (h >> 16) == 0xC0A8;
      char host[16];
      snprintf(host, sizeof host, "%u.%u.%u.1", h >> 24, (h >> 16) & 255, (h >> 8) & 255);
      if (priv && strcmp(host, listenAddrs[0]) && strcmp(host, listenAddrs[NET_UTM])) {
        // Other threads test the first byte: set it last.
        memcpy(listenAddrs[NET_FUSION] + 1, host + 1, sizeof host - 1);
        __sync_synchronize();
        listenAddrs[NET_FUSION][0] = host[0];
      }
    }
    break;
  }
  fclose(f);
}
#define ESC_KEYCODE 53
#define PINCH_SPREAD 0.035f         // normalized change of finger distance that makes a pinch
#define PINCH_RATIO 1.3f            // ... and it must exceed the centroid movement by this much

static volatile int frontIsVM, escaped, capturing;
static pid_t frontPid;   // the full-screen VM app in front, else 0
// Every VM that runs the guest daemon stays connected (one per address);
// frames go only to VMs on the network of the frontmost VM app (0 = Parallels,
// 1 = UTM, 2 = Fusion, 3 = OmacVM.app, the index into listenAddrs). One connection per VM used to mean
// two running VMs pushed each other off every two seconds.
#define MAX_CLIENTS 8
static struct { int fd, net, gestures, glide, target; char ip[32], name[256]; } clients[MAX_CLIENTS];
static volatile int frontNet = -1;
static char frontTitle[512];      // the front VM app's window title (Accessibility)
static pthread_mutex_t sendLock = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef tapPort;
static int verbose;
int ns_event_type(CGEventRef e);  // scroll_ns.m
void ns_on_app_activate(void (*f)(void));
static int trackpad = 1;          // 0 with --keys-only
static int tpW = 15600, tpH = 9600;   // built-in trackpad, 1/100 mm
static FILE *rec;                 // --record: trackpad frames and macOS's scroll, for analysis
static double unixNow(void) { return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970; }
static volatile int fingers;      // contacts in the built-in trackpad's last frame
static int pinchSent;             // P sent for the current two-finger touch

static void logf_(const char *fmt, ...) {
  time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  va_list ap; va_start(ap, fmt); printf("%s omacvm-gestures: ", ts); vprintf(fmt, ap); printf("\n"); va_end(ap);
  fflush(stdout);
}

// ---- which VM is in front ----
// Every VM of an app connects from the app's one network, so the network tells
// the app, not the VM. The VM is told by its name (from its hello) in the title
// of the app's front window: Parallels, UTM and VMware Fusion put the VM's name
// there, in a window or full screen. The name that is the title wins, else the
// longest name in it ("Omarchy 2" over "Omarchy"). No match: every VM on the
// front app's network, as before VMs said their name.
static int nameIs(int i, int exact) {
  const char *n = clients[i].name;
  return n[0] && (exact ? !strcmp(frontTitle, n) : strstr(frontTitle, n) != NULL);
}

// OmacVM.app's VMs on its fast network (vmnet) come in on UTM's network
// (192.168.64.1): while the app is in front they count as the app's, but only
// by their name in its window title (a UTM VM is there too).
static int onFrontNet(int i) {
  return clients[i].net == frontNet || (frontNet == NET_APP && clients[i].net == NET_UTM && nameIs(i, 0));
}

// The front VM's clients (clients[].target); sendLock held. Returns the
// targets as a bit mask.
static unsigned pickTargets(void) {
  int exact = 0; size_t best = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !onFrontNet(i)) continue;
    if (nameIs(i, 1)) exact = 1;
    else if (nameIs(i, 0) && strlen(clients[i].name) > best) best = strlen(clients[i].name);
  }
  unsigned mask = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    int on = clients[i].fd >= 0 && onFrontNet(i) &&
             (exact ? nameIs(i, 1) : best ? nameIs(i, 0) && strlen(clients[i].name) == best : 1);
    clients[i].target = on;
    if (on) mask |= 1u << i;
  }
  return mask;
}

// After the front window, the front app or the connected VMs changed; sendLock
// held. While capturing (states), a VM that stops being the front one gets
// "S off" (it lets go of held fingers and keys) and a new one "S on".
static void retargetLocked(int states) {
  static unsigned last;
  unsigned mask = pickTargets();
  if (mask == last) return;
  char who[256] = ""; size_t n = 0; int named = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (!(mask & 1u << i)) continue;
    named |= nameIs(i, 0);
    n += (size_t)snprintf(who + n, n < sizeof who ? sizeof who - n : 0, "%s%s", n ? ", " : "", clients[i].ip);
    if (n >= sizeof who) n = sizeof who - 1;
  }
  logf_("front window \"%s\": %s%s", frontTitle, named ? "" : "every VM of the app, ", mask ? who : "no VM connected");
  for (int i = 0; states && i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !((mask ^ last) & 1u << i)) continue;
    const char *st = mask & 1u << i ? "S on\n" : "S off\n";
    send(clients[i].fd, st, strlen(st), MSG_NOSIGNAL);
  }
  last = mask;
}

// all: every client; else the front VM's.
static void sendTo(int all, const char *line, size_t len) {
  pthread_mutex_lock(&sendLock);
  int dropped = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || (!all && !clients[i].target)) continue;
    if (send(clients[i].fd, line, len, MSG_NOSIGNAL) < 0) {
      logf_("guest disconnected: %s", clients[i].ip);
      close(clients[i].fd); clients[i].fd = -1; dropped = 1;
    }
  }
  if (dropped) retargetLocked(capturing);
  pthread_mutex_unlock(&sendLock);
}

static int haveClient(void) {
  int found = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) if (clients[i].fd >= 0 && clients[i].target) found = 1;
  pthread_mutex_unlock(&sendLock);
  return found;
}

// What the front VM wants. Without a name match these are all VMs of the front
// app, and every one must agree (either may be the one in front), so a VM that
// does not use a feature never loses macOS's own handling to it.
static int wants(int glide) {
  int any = 0, all = 1;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !clients[i].target) continue;
    any = 1;
    if (!(glide ? clients[i].glide && clients[i].gestures : clients[i].gestures)) all = 0;
  }
  pthread_mutex_unlock(&sendLock);
  return trackpad && any && all;
}
static int gesturesOn(void) { return frontNet >= 0 && wants(0); }
static int glideOn(void) { return frontNet >= 0 && wants(1); }

static void sendLine(const char *line, size_t len) { sendTo(0, line, len); }

// "on"/"esc" concern the front VM; "off" goes to every VM.
static void sendState(const char *s) {
  char b[16]; int n = snprintf(b, sizeof b, "S %s\n", s);
  sendTo(!strcmp(s, "off"), b, (size_t)n);
}

// ---- touch forwarding ----
static int forwarding;          // last frame sent to the guest had fingers
static int pinchArmed, pinch;   // 2-finger gesture tracking
static float d0, cx0, cy0;

static int touching(const MTTouch *t) { return t->state >= 1 && t->state <= 5 && t->zTotal > 0.0f; }

static int frameCb(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  (void)dev; (void)ts; (void)frame;
  MTTouch *c[16]; int k = 0;
  for (int i = 0; i < n && k < 16; i++) if (touching(&touches[i])) c[k++] = &touches[i];

  int send = 0;
  if (k != 2) pinchSent = 0;
  fingers = k;
  if (rec && k > 0) {
    float sx = 0, sy = 0;
    for (int i = 0; i < k; i++) { sx += c[i]->normalized.pos.x; sy += 1.0f - c[i]->normalized.pos.y; }
    fprintf(rec, "F\t%.4f\t%d\t%.5f\t%.5f\t%d\n", unixNow(), k, sx / k, sy / k, capturing);
  }
  if (capturing && gesturesOn()) {
    if (k >= 3 || (k == 2 && glideOn())) send = 1;
    else if (k == 2) {
      float dx = c[0]->normalized.pos.x - c[1]->normalized.pos.x, dy = c[0]->normalized.pos.y - c[1]->normalized.pos.y;
      float d = sqrtf(dx * dx + dy * dy);
      float cx = (c[0]->normalized.pos.x + c[1]->normalized.pos.x) / 2, cy = (c[0]->normalized.pos.y + c[1]->normalized.pos.y) / 2;
      if (!pinchArmed) { pinchArmed = 1; pinch = 0; d0 = d; cx0 = cx; cy0 = cy; }
      if (!pinch) {
        float spread = fabsf(d - d0), move = hypotf(cx - cx0, cy - cy0);
        if (spread > PINCH_SPREAD && spread > move * PINCH_RATIO) { pinch = 1; if (verbose) logf_("pinch"); }
      }
      send = pinch;
    }
  }
  if (k != 2) pinchArmed = 0;

  if (send) {
    char buf[1024]; int len = snprintf(buf, sizeof buf, "F %d", k);
    for (int i = 0; i < k && len < (int)sizeof buf - 64; i++)
      len += snprintf(buf + len, sizeof buf - (size_t)len, " %d %.5f %.5f %.3f", c[i]->pathIndex,
                      c[i]->normalized.pos.x, 1.0f - c[i]->normalized.pos.y, c[i]->zTotal);
    buf[len++] = '\n';
    sendLine(buf, (size_t)len);
    forwarding = 1;
  } else if (forwarding) {
    sendLine("F 0\n", 4);   // gesture over (fingers lifted below the threshold, or capture ended)
    forwarding = 0;
  }
  return 0;
}

// ---- capture mode: frontmost app + full-screen VM window ----
static int vmFullScreen(pid_t pid) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  CGDirectDisplayID ds[16]; uint32_t nd = 0; CGGetActiveDisplayList(16, ds, &nd);
  int found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner != pid || layer != 0) continue;
    if (!CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r)) continue;
    for (uint32_t d = 0; d < nd; d++) {
      CGRect b = CGDisplayBounds(ds[d]);
      // Parallels' full-screen window spans the display width and sits below the
      // menu bar / notch strip, so allow a gap at the top.
      if (fabs(r.size.width - b.size.width) < 2 && r.size.height >= b.size.height - 80 &&
          fabs(r.origin.x - b.origin.x) < 2) { found = 1; break; }
    }
  }
  CFRelease(wins);
  return found;
}

// The capture check runs every 0.2 s while a VM app is in front (to see its
// window go full screen), else every 2 s plus on every app switch. The pointer
// check runs at 120 Hz only while a full-screen VM is in front.
static CFRunLoopTimerRef captureTimer, cursorTimer;
static void updateCursor(CFRunLoopTimerRef t, void *info);

static void cursorTimerOn(int on) {
  static int running = -1;
  if (!cursorTimer || on == running) return;
  running = on;
  if (!on) updateCursor(NULL, NULL);   // shows the pointer again
  CFRunLoopTimerSetNextFireDate(cursorTimer, CFAbsoluteTimeGetCurrent() + (on ? 0 : 1e9));
}

// The title of the VM app's focused window (its main window when none has
// focus), through Accessibility, which this helper has for its event tap
// anyway; the window list would need Screen Recording for window names.
static void windowTitle(pid_t pid, char *out, size_t cap) {
  static AXUIElementRef app; static pid_t appPid;
  out[0] = 0;
  if (pid != appPid || !app) {
    if (app) CFRelease(app);
    app = AXUIElementCreateApplication(pid); appPid = pid;
    if (app) AXUIElementSetMessagingTimeout(app, 0.1f);   // a hung VM app must not stall the event tap
  }
  if (!app) return;
  CFTypeRef win = NULL, title = NULL;
  if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &win) != kAXErrorSuccess || !win)
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &win) != kAXErrorSuccess) win = NULL;
  if (win && AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &title) == kAXErrorSuccess && title &&
      CFGetTypeID(title) == CFStringGetTypeID())
    CFStringGetCString(title, out, (CFIndex)cap, kCFStringEncodingUTF8);
  if (title) CFRelease(title);
  if (win) CFRelease(win);
}

static void updateCapture(CFRunLoopTimerRef t, void *info) {
  (void)info;
  ProcessSerialNumber psn; pid_t pid = 0; char name[64] = "";
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, name, sizeof name);
  // Parallels' VM window, UTM's, or VMware Fusion's.
  int net = !strcmp(name, "prl_client_app") ? 0 : !strcmp(name, "UTM") ? NET_UTM
          : !strcmp(name, "VMware Fusion") && listenAddrs[NET_FUSION][0] ? NET_FUSION
          : !strcmp(name, "OmacVM") ? NET_APP : -1;   // OmacVM.app's QEMU
  int front = net >= 0 && vmFullScreen(pid);
  if (front) {
    // Which of the app's VMs: its window title, on this check (every 0.2 s
    // while a VM app is full screen in front) and on every app switch.
    char title[sizeof frontTitle];
    windowTitle(pid, title, sizeof title);
    pthread_mutex_lock(&sendLock);
    if (net != frontNet || strcmp(title, frontTitle)) {
      frontNet = net;
      memcpy(frontTitle, title, sizeof frontTitle);
      retargetLocked(capturing);
    }
    pthread_mutex_unlock(&sendLock);
  }
  frontPid = front ? pid : 0;
  cursorTimerOn(front);
  if (t) CFRunLoopTimerSetNextFireDate(t, CFAbsoluteTimeGetCurrent() + (net >= 0 ? 0.2 : 2.0));
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  int now = front && !escaped;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    if (rec) fprintf(rec, "C\t%.4f\t%d\n", unixNow(), now);
    sendState(now ? "on" : (front ? "esc" : "off"));
  }
  if (tapPort && !CGEventTapIsEnabled(tapPort)) CGEventTapEnable(tapPort, true);
}

// ---- the macOS pointer over the full-screen VM ----
// Parallels and UTM only hide the macOS pointer over their window when it comes
// in from their own window; from the Omanotch strip or another app it can stay
// on top of the guest's pointer. So it is hidden here whenever the window under
// it is the front VM's full-screen window. A background process may only
// do that with the window server's "SetsCursorInBackground" (private, but
// stable for many macOS releases); without it this does nothing.
static int cursorHidden, cursorControl = -1;

static int enableCursorControl(void) {
  typedef int (*DefaultConnection)(void);
  typedef int (*SetProperty)(int, int, CFStringRef, CFTypeRef);
  DefaultConnection c = (DefaultConnection)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
  SetProperty set = (SetProperty)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
  if (!c || !set) return 0;
  int cid = c();
  return set(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue) == 0;
}

static void setCursorHidden(int h) {
  if (h == cursorHidden) return;
  cursorHidden = h;
  if (h) CGDisplayHideCursor(kCGNullDirectDisplay); else CGDisplayShowCursor(kCGNullDirectDisplay);
}

// Whether the window a click at p would reach belongs to the front VM app and
// is a normal window. AppKit's hit test, not the window list: it skips
// click-through overlays that cover the whole screen (macOS's screenshot
// tool keeps one around for hours, Bartender has one over the menu bar).
typedef long (*WindowAtFn)(id, SEL, CGPoint, long);
static char hitOwner[64]; static int hitLayer;

static int vmWindowAt(CGPoint p, pid_t pid) {
  static Class nsWindow; static SEL windowAt;
  if (!nsWindow) {
    // AppKit needs its application object before it talks to the window server.
    ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    nsWindow = objc_getClass("NSWindow");
    windowAt = sel_registerName("windowNumberAtPoint:belowWindowWithWindowNumber:");
  }
  // AppKit's screen coordinates start at the primary display's bottom left.
  CGPoint q = { p.x, CGDisplayBounds(CGMainDisplayID()).size.height - p.y };
  long n = ((WindowAtFn)objc_msgSend)((id)nsWindow, windowAt, q, 0);
  hitOwner[0] = 0; hitLayer = -1;
  if (n <= 0) return 0;
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)n);
  if (!wins) return 0;
  int hit = 0;
  if (CFArrayGetCount(wins) > 0) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, 0);
    int owner = 0;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &hitLayer);
    CFStringRef name = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (name) CFStringGetCString(name, hitOwner, sizeof hitOwner, kCFStringEncodingUTF8);
    hit = owner == pid && hitLayer == 0;
    // Only a window that fills its display: the VM's full-screen window, not
    // another window of the same app (VMware Fusion's library, say).
    CGRect r;
    CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
    if (hit && b && CGRectMakeWithDictionaryRepresentation(b, &r)) {
      CGDirectDisplayID d; uint32_t nd = 0;
      CGGetDisplaysWithPoint(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)), 1, &d, &nd);
      CGRect s = nd ? CGDisplayBounds(d) : CGRectNull;
      hit = nd && r.size.width >= s.size.width - 1 && r.size.height >= s.size.height - 80;
    }
  }
  CFRelease(wins);
  return hit;
}

static void updateCursor(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  static CGPoint last = { -1, -1 };
  static CFAbsoluteTime lastCheck;
  if (cursorControl < 0) {
    cursorControl = enableCursorControl();
    if (!cursorControl) logf_("cannot hide the macOS pointer from the background");
  }
  pid_t pid = frontPid;
  if (!cursorControl || !pid) { setCursorHidden(0); last.x = -1; return; }
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(e);
  CFRelease(e);
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  // The window list only when the pointer moved, and every half second for
  // windows that appear under a pointer at rest (the Dock, a notification).
  if (p.x == last.x && p.y == last.y && now - lastCheck < 0.5) return;
  last = p; lastCheck = now;
  int h = vmWindowAt(p, pid);
  if (verbose && h != cursorHidden)
    logf_("macOS pointer %s (over %s, layer %d)", h ? "hidden" : "shown", hitOwner[0] ? hitOwner : "nothing", hitLayer);
  setCursorHidden(h);
}

// ---- Cmd as Super on UTM ----
// UTM does not grab the keyboard (Omanotch needs a free pointer), so macOS keeps
// Cmd+Space, Cmd+Tab & co. While a UTM VM is full screen and capturing, every
// Cmd+key goes to the guest daemon instead, which types it as Super+key on a
// virtual keyboard: "K <linux keycode> <0 up|1 down|2 repeat>". Parallels has
// its own setting for this ("Send macOS system shortcuts: Always").
static unsigned short macToLinux[128];
static unsigned char forwarded[128];

static void initKeymap(void) {
  // Physical keys (kVK_* -> KEY_*); the guest's own layout gives them meaning.
  static const unsigned short pairs[][2] = {
    {0,30},{1,31},{2,32},{3,33},{4,35},{5,34},{6,44},{7,45},{8,46},{9,47},{11,48},{12,16},{13,17},{14,18},
    {15,19},{16,21},{17,20},{18,2},{19,3},{20,4},{21,5},{22,7},{23,6},{24,13},{25,10},{26,8},{27,12},{28,9},
    {29,11},{30,27},{31,24},{32,22},{33,26},{34,23},{35,25},{36,28},{37,38},{38,36},{39,40},{40,37},{41,39},
    {42,43},{43,51},{44,53},{45,49},{46,50},{47,52},{48,15},{49,57},{51,14},{53,1},{76,96},
    {96,63},{97,64},{98,65},{99,61},{100,66},{101,67},{103,87},{109,68},{111,88},{118,62},{120,60},{122,59},
    {115,102},{116,104},{117,111},{119,107},{121,109},{123,105},{124,106},{125,108},{126,103}};
  for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++) macToLinux[pairs[i][0]] = pairs[i][1];
  // The key left of 1 and the extra key beside left Shift swap places on ISO keyboards.
  int iso = KBGetLayoutType(LMGetKbdType()) == kKeyboardISO;
  macToLinux[10] = iso ? 41 : 86;   // kVK_ISO_Section
  macToLinux[50] = iso ? 86 : 41;   // kVK_ANSI_Grave
}

static void sendKey(int code, int val) {
  char b[24]; int n = snprintf(b, sizeof b, "K %d %d\n", code, val); sendLine(b, (size_t)n);
}

static void forwardKey(int kc, CGEventFlags f, int val) {
  if (val == 1) {
    sendKey(125, 1);                                         // Super
    if (f & kCGEventFlagMaskShift) sendKey(42, 1);
    if (f & kCGEventFlagMaskControl) sendKey(29, 1);
    if (f & kCGEventFlagMaskAlternate) sendKey(56, 1);
  }
  sendKey(macToLinux[kc], val);
  if (val == 0) { sendKey(56, 0); sendKey(29, 0); sendKey(42, 0); sendKey(125, 0); }
}

// ---- event tap: drop macOS gestures while capturing; escape combo ----
static int swallowEscUp;

static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u) {
  (void)p; (void)u;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(tapPort, true); return e;
  }
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    int kc = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    CGEventFlags f = CGEventGetFlags(e);
    int combo = (f & kCGEventFlagMaskControl) && (f & kCGEventFlagMaskAlternate) && (f & kCGEventFlagMaskCommand);
    if (kc == ESC_KEYCODE && type == kCGEventKeyUp && swallowEscUp) { swallowEscUp = 0; return NULL; }
    if (kc != ESC_KEYCODE || !combo || !frontIsVM) {
      if (kc >= 0 && kc < 128 && macToLinux[kc]) {
        // UTM, VMware Fusion and OmacVM.app (without Accessibility for it) keep
        // Cmd shortcuts like Cmd+Space for macOS: in full screen they go to
        // Omarchy as Super, through the guest daemon.
        if (type == kCGEventKeyDown && capturing && (frontNet == NET_UTM || frontNet == NET_FUSION || frontNet == NET_APP) &&
            (f & kCGEventFlagMaskCommand) && haveClient()) {
          forwardKey(kc, f, CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat) ? 2 : 1);
          forwarded[kc] = 1;
          return NULL;
        }
        if (type == kCGEventKeyUp && forwarded[kc]) { forwarded[kc] = 0; forwardKey(kc, f, 0); return NULL; }
      }
      return e;
    }
    if (type == kCGEventKeyUp) return e;
    if (CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat)) return NULL;
    // Only the real keyboard: apps that post key events (VM apps among them)
    // must not hand the trackpad back to macOS.
    int64_t srcPid = CGEventGetIntegerValueField(e, kCGEventSourceUnixProcessID);
    int64_t srcState = CGEventGetIntegerValueField(e, kCGEventSourceStateID);
    if (srcState != kCGEventSourceStateHIDSystemState) {
      char who[64] = "";
      if (srcPid > 0) proc_name((pid_t)srcPid, who, sizeof who);
      logf_("escape combo ignored: posted by pid %lld (%s), state %lld", srcPid, who, srcState);
      return e;
    }
    escaped = !escaped;
    capturing = frontIsVM && !escaped;
    logf_("escape combo: capture %s", capturing ? "ON" : "off");
    sendState(capturing ? "on" : "esc");
    swallowEscUp = 1;
    return NULL;
  }
  if (type == kCGEventScrollWheel && rec)
    fprintf(rec, "S\t%.4f\t%lld\t%lld\t%.2f\t%.2f\t%lld\t%d\n", unixNow(),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventScrollPhase),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase),
            CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2),
            CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous), capturing);
  if (type == kCGEventScrollWheel) {
    // Glide: continuous (trackpad, Magic Mouse) scrolling, as macOS shaped it,
    // goes to the guest; a wheel mouse's discrete steps pass to the VM app.
    if (!(capturing && glideOn())) return e;
    if (!CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous)) return e;
    double dy = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1);
    double dx = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2);
    if (dx != 0 || dy != 0) {
      // Fingers on the built-in trackpad: their raw frames carry this scroll;
      // the guest only learns from it how much macOS accelerates right now.
      int touch = fingers >= 2 && !CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase);
      char b[64]; int n = snprintf(b, sizeof b, "%c %.2f %.2f\n", touch ? 'A' : 'W', dx, dy);
      sendLine(b, (size_t)n);
    }
    return NULL;
  }
  // macOS recognized a pinch (NSEventTypeMagnify): tell the guest, so its
  // two-finger touch passes raw fingers from now on.
  if ((type == 29 || type == 30) && !pinchSent && capturing && glideOn() && ns_event_type(e) == 30) {
    sendLine("P\n", 2);
    pinchSent = 1;
    if (verbose) logf_("pinch (macOS)");
  }
  return capturing && gesturesOn() ? NULL : e;   // a gesture event type
}

// The VM's name from its hello: base64, so a name may hold spaces. Anything
// else gives no name.
static void base64Name(const char *in, char *out, size_t cap) {
  static const char abc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  unsigned v = 0; int bits = 0; size_t n = 0;
  for (; *in && *in != '='; in++) {
    const char *p = strchr(abc, *in);
    if (!p) { n = 0; break; }
    v = (v << 6 | (unsigned)(p - abc)) & 0xffff; bits += 6;
    if (bits >= 8) { bits -= 8; if (n + 1 < cap) out[n++] = (char)(v >> bits & 0xff); }
  }
  out[n] = 0;
  for (size_t i = 0; i < n; i++) if ((unsigned char)out[i] < 32) { out[0] = 0; break; }   // no control characters (the log)
}

// ---- who may connect ----
// Any VM on these networks, and any Mac program on 127.0.0.1, can reach the
// listeners: a VM's daemon proves it knows the Bridge's token (header).

// The Bridge's token, or 0 when there is none.
static size_t readToken(char tok[160]) {
  char path[1024];
  tok[0] = 0;
  snprintf(path, sizeof path, "%s/Library/Application Support/omacvm-bridge/token", getenv("HOME"));
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  if (!fgets(tok, 160, f)) tok[0] = 0;
  fclose(f);
  tok[strcspn(tok, "\r\n")] = 0;
  size_t n = strlen(tok);
  return n >= 32 ? n : 0;
}

static int sameText(const char *a, const char *b) {   // constant time
  size_t n = strlen(a);
  if (strlen(b) != n) return 0;
  unsigned char diff = 0;
  for (size_t i = 0; i < n; i++) diff |= (unsigned char)(a[i] ^ b[i]);
  return diff == 0;
}

static int isHex(const char *s, size_t n) {
  if (strlen(s) != n) return 0;
  for (; *s; s++) if (!strchr("0123456789abcdef", *s)) return 0;
  return 1;
}

// HMAC-SHA256(token, "omacvm-gestures <who> <addr> <guest nonce> <mac nonce>") in hex.
static void proof(const char *tok, size_t tl, const char *who, const char *addr, const char *gn, const char *mn,
                  char out[65]) {
  char msg[160]; unsigned char d[CC_SHA256_DIGEST_LENGTH];
  int n = snprintf(msg, sizeof msg, "omacvm-gestures %s %s %s %s", who, addr, gn, mn);
  CCHmac(kCCHmacAlgSHA256, tok, tl, msg, (size_t)n, d);
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

// Daemons from before the handshake say the token itself.
static int bridgeTokenOK(const char *given) {
  char tok[160];
  int ok = readToken(tok) && sameText(tok, given);
  memset(tok, 0, sizeof tok);
  return ok;
}

// ---- server ----
// One line from the guest, up to a few reads (SO_RCVTIMEO each): the newline
// is cut off. -1: nothing came.
static ssize_t recvLine(int fd, char *buf, size_t cap) {
  size_t n = 0;
  for (int i = 0; i < 4 && n + 1 < cap; i++) {
    ssize_t r = recv(fd, buf + n, cap - 1 - n, 0);
    if (r <= 0) break;
    n += (size_t)r;
    char *nl = memchr(buf, '\n', n);
    if (nl) { *nl = 0; return nl - buf; }
  }
  buf[n] = 0;
  return n ? (ssize_t)n : -1;
}

static void addClient(int c, int net, const char *ip, int gestures, int glide, const char *name) {
  pthread_mutex_lock(&sendLock);
  int slot = -1;
  // The same VM reconnecting replaces its old connection. OmacVM.app's VMs
  // all come from 127.0.0.1 (QEMU's user network): there the name tells them
  // apart, or two running VMs would keep pushing each other out.
  int loopback = !strncmp(ip, "127.", 4);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && !strcmp(clients[i].ip, ip) && (!loopback || !strcmp(clients[i].name, name))) {
      close(clients[i].fd); slot = i; break;
    }
  for (int i = 0; slot < 0 && i < MAX_CLIENTS; i++) if (clients[i].fd < 0) slot = i;
  if (slot < 0) { close(clients[0].fd); slot = 0; }   // full: drop the oldest slot
  clients[slot].fd = c; clients[slot].net = net;
  clients[slot].gestures = gestures != 0; clients[slot].glide = glide != 0;
  snprintf(clients[slot].ip, sizeof clients[slot].ip, "%s", ip);
  snprintf(clients[slot].name, sizeof clients[slot].name, "%s", name);
  logf_("guest connected: %s (gestures %s, scroll momentum %s%s%s%s)", ip, gestures ? "on" : "off",
        glide ? "on" : "off", name[0] ? ", VM \"" : "", name, name[0] ? "\"" : "");
  retargetLocked(capturing);
  int front = clients[slot].target;
  pthread_mutex_unlock(&sendLock);
  const char *st = capturing && front ? "on\n" : "off\n";
  char b[96]; int n = snprintf(b, sizeof b, "S %s", st);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
  // The Mac's scrolling direction and the trackpad's size, so the guest
  // scales finger movement for this Mac (OmacVM's tuning is relative to a
  // 156 x 96 mm trackpad with natural scrolling).
  CFPropertyListRef nat = CFPreferencesCopyAppValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication);
  int natural = nat ? CFBooleanGetValue((CFBooleanRef)nat) : 1;
  if (nat) CFRelease(nat);
  n = snprintf(b, sizeof b, "O %d %d %d\n", natural, tpW, tpH);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
}

// Each connection's handshake runs in its own thread, so a peer that connects
// and says nothing holds up no one else; at most this many at once.
#define MAX_GREETING 64
static volatile int greeting;
struct greetArg { int fd, net; struct in_addr addr; };

static void *greet(void *arg) {
  struct greetArg g = *(struct greetArg *)arg; free(arg);
  int c = g.fd, gestures = 1, glide = 0, ok = 0;
  const char *addr = listenAddrs[g.net];
  char ip[32]; inet_ntop(AF_INET, &g.addr, ip, sizeof ip);
  char line[640], name64[360] = "", name[256];
  const char *why = "no token (omacvm update gives the VM a daemon that proves it)";
  struct timeval tv = { .tv_sec = 1 };
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  ssize_t n = recvLine(c, line, sizeof line);
  char gn[72] = "";
  if (n > 0 && line[0] == 'C' && sscanf(line + 1, "%71s", gn) == 1) {
    // This daemon's handshake (header): the Mac's proof first.
    char tok[160], mn[33], mine[65], want[65], got[72] = "", out[160];
    size_t tl = readToken(tok);
    why = !tl ? "no Bridge token on this Mac" : "wrong proof";
    // Both proofs name the address this came in on (the VM checks it is its own).
    struct sockaddr_in me; socklen_t ml = sizeof me; char at[INET_ADDRSTRLEN] = "";
    if (getsockname(c, (struct sockaddr *)&me, &ml) || !inet_ntop(AF_INET, &me.sin_addr, at, sizeof at)) tl = 0;
    if (tl && isHex(gn, 32)) {
      unsigned char r[16]; arc4random_buf(r, sizeof r);
      for (int i = 0; i < 16; i++) snprintf(mn + 2 * i, 3, "%02x", r[i]);
      proof(tok, tl, "mac", at, gn, mn, mine);
      int k = snprintf(out, sizeof out, "M %s %s\n", mn, mine);
      tv.tv_sec = 3; setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
      if (send(c, out, (size_t)k, MSG_NOSIGNAL) == k && recvLine(c, line, sizeof line) > 0 && line[0] == 'R' &&
          sscanf(line + 1, "%d %d %71s %359s", &gestures, &glide, got, name64) >= 3) {
        proof(tok, tl, "vm", at, gn, mn, want);
        ok = sameText(got, want);
      }
    }
    memset(tok, 0, sizeof tok);
  } else if (n > 0 && line[0] == 'H') {
    // Daemons from before the handshake say the token itself.
    char given[160] = "";
    sscanf(line + 1, "%d %d %159s %359s", &gestures, &glide, given, name64);
    if (given[0]) { why = "wrong token"; ok = bridgeTokenOK(given); }
  }
  if (ok) {
    base64Name(name64, name, sizeof name);
    addClient(c, g.net, ip, gestures, glide, name);
  } else {
    // A refused daemon tries again every 2 s; only the log line is throttled.
    // Keeping its socket open instead would not save anything: a daemon from
    // 2.3 or older then polls it every 2 ms. omacvm check tells the user.
    static char lastIp[32]; static time_t lastLog;
    pthread_mutex_lock(&sendLock);
    if (strcmp(lastIp, ip) || time(NULL) - lastLog >= 60) {
      logf_("refused %s on %s: %s", ip, addr, why);
      snprintf(lastIp, sizeof lastIp, "%s", ip); lastLog = time(NULL);
    }
    pthread_mutex_unlock(&sendLock);
    close(c);
  }
  __sync_fetch_and_sub(&greeting, 1);
  return NULL;
}

static void *serverThread(void *arg) {
  int net = (int)(intptr_t)arg, inUse = 0;
  const char *addr = listenAddrs[net];
  while (net == NET_FUSION && !addr[0]) { sleep(10); readFusionHost(); }
  for (;;) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    if (inet_pton(AF_INET, addr, &a.sin_addr) != 1 || a.sin_addr.s_addr == INADDR_ANY) {
      close(s); logf_("not listening on '%s': not an address", addr); return NULL;   // never 0.0.0.0
    }
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 16) < 0) {
      // That VM network is not up (yet); another program on the port is worth a line.
      if (errno == EADDRINUSE && !inUse) { logf_("%s:%d is taken by another program; trying again", addr, PORT); inUse = 1; }
      close(s); sleep(5); continue;
    }
    inUse = 0;
    logf_("listening on %s:%d", addr, PORT);
    for (;;) {
      struct sockaddr_in peer; socklen_t pl = sizeof peer;
      int c = accept(s, (struct sockaddr *)&peer, &pl);
      if (c < 0) break;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
      struct greetArg *g = malloc(sizeof *g);
      if (!g || __sync_add_and_fetch(&greeting, 1) > MAX_GREETING) {
        if (g) { __sync_fetch_and_sub(&greeting, 1); free(g); }
        close(c); continue;
      }
      g->fd = c; g->net = net; g->addr = peer.sin_addr;
      pthread_t th; pthread_attr_t at;
      pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
      if (pthread_create(&th, &at, greet, g)) { __sync_fetch_and_sub(&greeting, 1); free(g); close(c); }
      pthread_attr_destroy(&at);
    }
    close(s);
  }
  return NULL;
}

// ---- the trackpad: the built-in one, else an external Magic Trackpad ----
// MultitouchSupport lists every multi-touch surface, the Magic Mouse's too; a
// trackpad is told apart by its size (a Magic Trackpad is 160 x 115 mm, a Magic
// Mouse's surface well under 100 mm wide).
static int trackpadStarted;

static void startTrackpad(void) {
  CFArrayRef list = MTDeviceCreateList();
  MTDeviceRef pick = NULL; int pw = 0, ph = 0;
  for (int pass = 0; pass < 2 && !pick; pass++) {
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && !pick; i++) {
      MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
      int w = 0, h = 0;
      if (MTDeviceGetSensorSurfaceDimensions(d, &w, &h) != 0) w = h = 0;
      if (pass == 0 ? MTDeviceIsBuiltIn(d) : (!MTDeviceIsBuiltIn(d) && w >= 10000)) { pick = d; pw = w; ph = h; }
    }
  }
  if (!pick) return;
  if (pw > 0 && ph > 0) { tpW = pw; tpH = ph; }
  MTRegisterContactFrameCallback(pick, frameCb);
  MTDeviceStart(pick, 0);
  trackpadStarted = 1;
  logf_("trackpad: %s, %d x %d mm", MTDeviceIsBuiltIn(pick) ? "built-in" : "Magic Trackpad", tpW / 100, tpH / 100);
}

static void retryTrackpad(CFRunLoopTimerRef t, void *info) {
  (void)info;
  if (!trackpadStarted) startTrackpad();
  if (trackpadStarted) CFRunLoopTimerInvalidate(t);
}

static void appActivated(void) { updateCapture(captureTimer, NULL); }

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-v")) verbose = 1;
    else if (!strcmp(argv[i], "--keys-only")) trackpad = 0;
    else if (!strcmp(argv[i], "--record")) {
      char path[1024]; snprintf(path, sizeof path, "%s/Library/Logs/omacvm-input.tsv", getenv("HOME"));
      rec = fopen(path, "a");
      if (rec) setvbuf(rec, NULL, _IOLBF, 0);
    }
    // A wrong option is not worth a launchd restart loop: say it and go on.
    else logf_("unknown option %s, ignored", argv[i]);
  }
  signal(SIGPIPE, SIG_IGN);

  CGEventMask m = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
  int gestureTypes[] = { 18, 19, 20, 29, 30, 31, 32, 34 };   // rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure
  for (size_t i = 0; i < sizeof gestureTypes / sizeof *gestureTypes; i++) m |= (CGEventMask)1 << gestureTypes[i];
  // Needs Accessibility (to drop events) and Input Monitoring (to see the escape
  // combo). Ask once, then wait for the grant instead of exiting, so launchd
  // does not restart us into a loop of prompts.
  CFStringRef keys[] = { kAXTrustedCheckOptionPrompt }; CFTypeRef vals[] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int asked = 0;
  while (!(tapPort = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, m, tapCb, NULL))) {
    if (!asked) {
      logf_("waiting for Accessibility and Input Monitoring permission");
      AXIsProcessTrustedWithOptions(opts);
      CGRequestListenEventAccess();
      asked = 1;
    }
    sleep(3);
  }
  CFRelease(opts);
  if (asked) logf_("permissions granted");
  CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(NULL, tapPort, 0), kCFRunLoopCommonModes);

  // The trackpad only now, with the permissions granted and the run loop about
  // to run: opened while still waiting, its frames were never taken, and on a
  // MacBook that stalled the built-in keyboard and trackpad (one device) until
  // the user granted Accessibility, which they then could not click.
  if (trackpad) {
    startTrackpad();
    if (!trackpadStarted) {
      // A Mac without a built-in trackpad (Mac mini, iMac, Studio) and no
      // Magic Trackpad connected yet: keys only until one is (checked again
      // every 10 s), instead of exiting into a launchd restart loop.
      logf_("no trackpad found: keys only until a Magic Trackpad connects");
      CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0, retryTrackpad, NULL);
      CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopCommonModes);
    }
  }


  cursorTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1.0 / 120, 0, 0, updateCursor, NULL);
  CFRunLoopTimerSetTolerance(cursorTimer, 0.001);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), cursorTimer, kCFRunLoopCommonModes);
  captureTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.2, 0, 0, updateCapture, NULL);
  CFRunLoopTimerSetTolerance(captureTimer, 0.02);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), captureTimer, kCFRunLoopCommonModes);
  ns_on_app_activate(appActivated);

  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  initKeymap();
  readFusionHost();
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) {
    if (!listenAddrs[i][0] && i != NET_FUSION) continue;
    pthread_t th; pthread_create(&th, NULL, serverThread, (void *)(intptr_t)i);
  }
  logf_(trackpad ? "running (escape: Ctrl+Option+Cmd+Esc)" : "running, keys only: trackpad gestures stay with macOS");
  CFRunLoopRun();
  return 0;
}
