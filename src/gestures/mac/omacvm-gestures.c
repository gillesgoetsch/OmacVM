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
// A Magic Mouse (any number, also one connected later) while capturing: two
// fingers sliding sideways swipe Omarchy's workspaces (four virtual fingers on
// the guest's touchpad, or three with MouseSwipeFingers 3, as the trackpad's
// swipes; macOS's Space swipe is dropped as the trackpad's is), one finger flicked sideways is back/forward
// in the VM (the Back/Forward keys on the guest's keyboard). Its scrolling
// goes to the VM app as before (mouse-model.h).
// Ctrl+Option+Esc in the full-screen VM hands everything back to macOS and
// moves the display under the pointer to the Space beside the VM's with
// macOS's own "Move left/right a space" shortcut (macOS's own animation; the
// VM stays full screen); pressed there again in macOS, it goes back into the
// VM (escape section below).
// Capture re-arms by itself when the VM is in front again. If this process
// dies, the event tap goes with it and macOS gets its gestures back.
// Each VM says on connect what it wants (the handshake below). Capture
// only covers a full-screen VM whose connected daemon wants the trackpad, so a
// VM with gestures off (or not connected yet) leaves macOS its gestures.
// Glide (scroll momentum, per VM): a trackpad's two-finger scrolling goes to
// the guest too. While fingers touch a trackpad (built-in or Magic Trackpad,
// also one connected later), their raw positions do (every two-finger frame,
// precise to hundredths of a millimetre) along with macOS's own scroll for
// them ("A", macOS's acceleration); after they lift, macOS's momentum goes as
// point deltas ("W"), which the guest continues the touch with. macOS's own
// scroll events then do not reach the VM app. Every other scroll (wheel mice,
// smooth-scrolling mice, a Magic Mouse) still scrolls through the VM app,
// one to one: decided per event by whether a trackpad's fingers made it
// (scroll-model.h).
// --keys-only: no trackpad for any VM (macOS keeps every gesture); on UTM, Cmd
// still reaches the guest as Super (below). --record: the built-in trackpad's
// frames and macOS's scroll events to ~/Library/Logs/omacvm-input.tsv (Glide
// diagnostics, see docs/experiments/scroll-analysis).
//
// Protocol (TCP, the guest connects to the Mac on port 47830: 10.211.55.2 on
// Parallels, 192.168.64.1 on UTM, .1 of Fusion's NAT network), one line per message:
//   F <n> [<id> <x> <y> <size>]...   x/y 0..1 with y down, size >= 0
//   S <on|off|esc> [<keys>]           capture state changes; after esc the combo pressed:
//                                     ctrl-opt, or ctrl-opt-cmd (the old one, through 3.0.x).
//                                     A guest reads no word as ctrl-opt-cmd (a helper
//                                     from before 3.0.0 knows only that one)
//   O <natural> <w> <h>               on connect (and when another trackpad touches): macOS's
//                                     natural scrolling (1/0) and the trackpad's size in 1/100 mm
//   A <dx> <dy>                       Glide: macOS's scroll while the fingers touch (points)
//   W <dx> <dy>                       Glide: macOS's momentum after a trackpad's fingers lifted (points)
//   P                                 Glide: macOS recognized a pinch (magnify)
//   K <code> <0|1|2>                  UTM: a Cmd shortcut as Super+key (Linux keycode)
//                                     (any app: a Magic Mouse flick as Back/Forward, 158/159)
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
#include <time.h>
#include "scroll-model.h"
#include "mouse-model.h"
#include <IOKit/IOKitLib.h>
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
extern int MTDeviceGetDeviceID(MTDeviceRef, uint64_t *);
extern bool MTDeviceIsRunning(MTDeviceRef);
extern int MTDeviceGetFamilyID(MTDeviceRef, int *);
extern io_service_t MTDeviceGetService(MTDeviceRef);

#ifndef PORT
#define PORT 47830
#endif
#ifndef BRIDGE_DIR
#define BRIDGE_DIR "omacvm-bridge"   // the Bridge's token is in ~/Library/Application Support/BRIDGE_DIR
#endif
// The Mac's address on each VM network: Parallels' shared network, UTM's
// shared network (vmnet), VMware Fusion's NAT network (vmnet8: Fusion picks
// its subnet at install time, the Mac is .1; empty without Fusion) and
// OmacVM.app (QEMU's user network reaches the Mac's 127.0.0.1; its fast
// network, src/net/mac, is 192.168.77.0/24). One listener per address; never
// 0.0.0.0.
static char listenAddrs[5][16] = { "10.211.55.2", "192.168.64.1", "", "127.0.0.1", "192.168.77.1" };
#define NET_UTM 1
#define NET_FUSION 2
#define NET_APP 3
#define NET_APP_FAST 4   // its clients count as NET_APP's

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
      if (priv && strcmp(host, listenAddrs[0]) && strcmp(host, listenAddrs[NET_UTM]) && strcmp(host, listenAddrs[NET_APP_FAST])) {
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
// The escape combo is Ctrl+Option+Esc (since 3.0.0). Ctrl+Option+Cmd+Esc, the
// combo up to 2.9.x, still works through 3.0.x as a hidden fallback: the
// guest then shows "New shortcut: ⌃⌥ Esc" once. TODO(after 3.0.x): remove
// ESC_OLD (tracked in tracks/keys-escape.md, "old escape combo").
// Only these two exact modifier sets count: with Shift added it is not the
// combo and goes on as any other key.
enum { ESC_NONE, ESC_NEW, ESC_OLD };
static int escapeCombo(int kc, CGEventFlags f) {
  if (kc != ESC_KEYCODE) return ESC_NONE;
  const CGEventFlags ctrlOpt = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
  CGEventFlags m = f & (ctrlOpt | kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
  return m == ctrlOpt ? ESC_NEW : m == (ctrlOpt | kCGEventFlagMaskCommand) ? ESC_OLD : ESC_NONE;
}
// The last combo pressed, for "S esc <keys>".
static const char *escKeys = "ctrl-opt";
#define PINCH_SPREAD 0.035f         // normalized change of finger distance that makes a pinch
#define PINCH_RATIO 1.3f            // ... and it must exceed the centroid movement by this much

static volatile int frontIsVM, escaped, capturing;
static pid_t frontPid;   // the full-screen VM app in front, else 0
// The escape combo's way out and back: the last app in front that was no VM
// app, and the last full-screen VM, each with its front window.
static pid_t otherPid, vmPid, appPid;   // appPid: the app in front at the last check
static CGWindowID otherWin, vmWin;
// An OmacVM VM in front in a window, and the windowed VM the combo left (the
// combo in macOS brings it back). Main thread, and the event tap (also on it).
static pid_t winVMPid, leftWinPid;
static CGWindowID winVMWin, leftWinWin;
// The last full-screen VM's app is in front but shows no window on this
// Space: its Space is not the one shown (Mission Control closed on a desktop,
// or the Space changed with it in front). Main thread.
static int vmOffSpace;
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
static CFRunLoopSourceRef tapSource;
static CGEventMask tapMask;
static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u);
static int verbose;
int ns_event_type(CGEventRef e);  // scroll_ns.m
void ns_on_app_activate(void (*f)(void));
int ns_activate(pid_t pid);
int ns_hide(pid_t pid);
void ns_unhide(pid_t pid);
int ns_is_regular(pid_t pid);
static int isOther(pid_t pid, int net, const char *name, int regular);
pid_t ns_finder_pid(void);
static int trackpad = 1;          // 0 with --keys-only
static int tpW = 15600, tpH = 9600;   // built-in trackpad, 1/100 mm
static FILE *rec;                 // --record: trackpad frames and macOS's scroll, for analysis
static double unixNow(void) { return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970; }
static volatile int fingers;      // contacts in the touching trackpad's last frame
// The trackpads (built-in, Magic Trackpads, also ones connected later): the
// one touching now has its frames sent; scroll momentum takes only scrolling
// that a trackpad's fingers make (scroll-model.h), never a mouse's.
#define MAX_PADS 8
static struct { MTDeviceRef dev; uint64_t id; int w, h, fingers; } pads[MAX_PADS];
static int nPads, activePad = -1;
static ScrollState scrollSt;
static pthread_mutex_t padLock = PTHREAD_MUTEX_INITIALIZER;   // pads' fingers, activePad, scrollSt
static double monoNow(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static int pinchSent;             // P sent for the current two-finger touch
// The Magic Mice (also ones connected later): their gestures go to the VM
// while capturing (mouse-model.h). mouseSwipeUntil: macOS's own scrolling for
// a two-finger swipe is dropped until then (monoNow; it runs out by itself,
// so a mouse gone mid-swipe never keeps scrolling from the VM).
#define MAX_MICE 4
static struct { MTDeviceRef dev; uint64_t id; int w, h, sent, fingers; MouseState st; } mice[MAX_MICE];
static int nMice;
static pthread_mutex_t mouseLock = PTHREAD_MUTEX_INITIALIZER;   // mice
static volatile double mouseSwipeUntil;
#define MOUSE_SWIPE_HOLD 0.5        // s after a swipe frame or its end
#define MOUSE_SWIPE_GAIN 1.5f       // mouse mm -> virtual trackpad mm (a mouse is small)
#define MOUSE_FINGER_ID 900001      // the virtual fingers' ids (the trackpad's are small)
#define LINUX_KEY_BACK 158
#define LINUX_KEY_FORWARD 159

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

// The front VM's clients (clients[].target); sendLock held. Returns the
// targets as a bit mask.
static unsigned pickTargets(void) {
  int exact = 0; size_t best = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || clients[i].net != frontNet) continue;
    if (nameIs(i, 1)) exact = 1;
    else if (nameIs(i, 0) && strlen(clients[i].name) > best) best = strlen(clients[i].name);
  }
  unsigned mask = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    int on = clients[i].fd >= 0 && clients[i].net == frontNet &&
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

// "O <natural> <w> <h>": the Mac's scrolling direction and the touching
// trackpad's size, so the guest scales finger movement for it (OmacVM's
// tuning is relative to a 156 x 96 mm trackpad with natural scrolling).
static int sizeLine(char *b, size_t cap) {
  CFPropertyListRef nat = CFPreferencesCopyAppValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication);
  int natural = nat ? CFBooleanGetValue((CFBooleanRef)nat) : 1;
  if (nat) CFRelease(nat);
  return snprintf(b, cap, "O %d %d %d\n", natural, tpW, tpH);
}

// Another trackpad (another size) is the one touching now: every VM learns it.
static void sendSize(void) {
  char b[64]; int n = sizeLine(b, sizeof b);
  sendTo(1, b, (size_t)n);
}

// "on"/"esc" concern the front VM; "off" goes to every VM.
static void sendState(const char *s) {
  char b[40]; int n = !strcmp(s, "esc") ? snprintf(b, sizeof b, "S esc %s\n", escKeys) : snprintf(b, sizeof b, "S %s\n", s);
  sendTo(!strcmp(s, "off"), b, (size_t)n);
}

// ---- touch forwarding ----
static int forwarding;          // last frame sent to the guest had fingers
static int pinchArmed, pinch;   // 2-finger gesture tracking
static float d0, cx0, cy0;

static int touching(const MTTouch *t) { return t->state >= 1 && t->state <= 5 && t->zTotal > 0.0f; }

static int frameCb(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  (void)ts; (void)frame;
  MTTouch *c[16]; int k = 0;
  for (int i = 0; i < n && k < 16; i++) if (touching(&touches[i])) c[k++] = &touches[i];

  // One trackpad at a time: another one's frames count once this one is free.
  pthread_mutex_lock(&padLock);
  int pad = -1;
  for (int i = 0; i < nPads; i++) if (pads[i].dev == dev) pad = i;
  if (pad >= 0) pads[pad].fingers = k;
  int switched = 0;
  if (pad != activePad) {
    if (pad < 0 || k == 0 || (activePad >= 0 && pads[activePad].fingers > 0)) { pthread_mutex_unlock(&padLock); return 0; }
    activePad = pad;
    switched = pads[pad].w != tpW || pads[pad].h != tpH;
    if (switched) { tpW = pads[pad].w; tpH = pads[pad].h; }
  }
  scrollFingers(&scrollSt, k, monoNow());
  pthread_mutex_unlock(&padLock);
  if (switched) sendSize();   // the guest scales finger movement to this trackpad

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

// ---- Magic Mouse ----
// Its frames always go through the model (so a touch that began before the
// capture is read right), but only a captured VM that wants gestures gets
// anything.
static int mouseSwipeFingers(void);
static int mouseFrameCb(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  (void)ts; (void)frame;
  MouseTouch c[16]; int k = 0;
  pthread_mutex_lock(&mouseLock);
  int m = -1;
  for (int i = 0; i < nMice; i++) if (mice[i].dev == dev) m = i;
  if (m < 0) { pthread_mutex_unlock(&mouseLock); return 0; }
  for (int i = 0; i < n && k < 16; i++) {
    if (!touching(&touches[i])) continue;
    c[k].id = touches[i].pathIndex;
    c[k].x = touches[i].normalized.pos.x * (float)mice[m].w / 100.0f;
    c[k].y = touches[i].normalized.pos.y * (float)mice[m].h / 100.0f;
    k++;
  }
  float before = mice[m].st.dx;   // the swipe's travel up to now (its end resets it)
  int act = mouseFrame(&mice[m].st, c, k, monoNow());
  float dx = mice[m].st.dx;
  int on = capturing && gesturesOn();
  char buf[256]; int len = 0;
  if (act == MOUSE_SWIPE && on) {
    // Four fingers (or three, MouseSwipeFingers) in the middle of the guest's
    // touchpad, moved sideways as the two on the mouse (the guest scales by
    // the trackpad's size, tpW). Four by default: OmacVM's guest swipes
    // workspaces with 3 and 4 fingers, and users who give 3 fingers to
    // something else (window snapping) keep 4 for it. Read when a swipe
    // starts, so a change in the app counts from the next swipe.
    if (!mice[m].sent) mice[m].fingers = mouseSwipeFingers();
    int nf = mice[m].fingers == 3 ? 3 : 4;
    float o = MOUSE_SWIPE_GAIN * dx * 100.0f / (float)(tpW > 0 ? tpW : 15600);
    if (o > 0.35f) o = 0.35f;
    if (o < -0.35f) o = -0.35f;
    len = snprintf(buf, sizeof buf, "F %d", nf);
    for (int i = 0; i < nf; i++)
      len += snprintf(buf + len, sizeof buf - (size_t)len, " %d %.5f %.5f %.3f", MOUSE_FINGER_ID + i,
                      0.5f - 0.05f * (float)(nf - 1) + 0.1f * (float)i + o, 0.5f, 0.5f);
    buf[len++] = '\n';
    mice[m].sent = 1;
    mouseSwipeUntil = monoNow() + MOUSE_SWIPE_HOLD;
  } else if (act == MOUSE_SWIPE_END && mice[m].sent) {
    len = snprintf(buf, sizeof buf, "F 0\n");
    logf_("Magic Mouse: two-finger swipe %s, %.0f mm -> %d-finger swipe in the VM", before >= 0 ? "right" : "left", fabsf(before),
          mice[m].fingers == 3 ? 3 : 4);
    mice[m].sent = 0;
    mouseSwipeUntil = monoNow() + MOUSE_SWIPE_HOLD;
  } else if ((act == MOUSE_BACK || act == MOUSE_FORWARD) && on) {
    int code = act == MOUSE_BACK ? LINUX_KEY_BACK : LINUX_KEY_FORWARD;
    len = snprintf(buf, sizeof buf, "K %d 1\nK %d 0\n", code, code);
    logf_("Magic Mouse: one-finger swipe %s -> %s in the VM", act == MOUSE_BACK ? "right" : "left",
          act == MOUSE_BACK ? "back" : "forward");
  }
  pthread_mutex_unlock(&mouseLock);
  if (len) sendLine(buf, (size_t)len);
  return 0;
}

// ---- capture mode: frontmost app + full-screen VM window ----
// A VM's full-screen window is a normal window (layer 0).
static int isQemu(pid_t pid);
static int (*isQemuFn)(pid_t) = isQemu;

static int vmFullScreen(pid_t pid, CGWindowID *win) {
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
    if (found) CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, win);
  }
  CFRelease(wins);
  return found;
}

// The app's front window on the current Space (the list is front to back), 0
// for none (Finder with only the desktop).
static CGWindowID frontWindow(pid_t pid) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  CGWindowID found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == pid && layer == 0) CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, &found);
  }
  CFRelease(wins);
  return found;
}

// The capture check runs every 0.2 s while a VM app is in front (to see its
// window go full screen), else every 2 s plus on every app switch. The pointer
// check runs only while a full-screen VM is in front: at 120 Hz while the
// pointer moves, at 20 Hz once it has rested a second (an idle desktop then
// costs 20 wake-ups a second here, not 120).
#define CURSOR_REST_AFTER 1.0
#define CURSOR_REST_EVERY 0.05
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

// ---- the event tap: created again when a VM app starts after us ----
// A new event tap goes to the head of the HID chain. QEMU's own one (OmacVM.app,
// full grab) is created when the VM starts and then sits ahead of ours: it
// sends the escape combo to the guest and returns nothing, so we never saw it
// after OmacVM.app was restarted (brianmerchant, PR #39). So the tap is
// created again whenever a different OmacVM VM comes to the front full screen,
// and when macOS has invalidated it. Since 3.0.0 QEMU's tap lets the combo
// through as well (omacvm-cocoa-escape-combo-tap.patch); the re-arm stays for
// a QEMU from before that. The new tap goes in before the old one is removed:
// no gap without one.
static int installTap(void) {
  CFMachPortRef newTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, tapMask, tapCb, NULL);
  if (!newTap) return 0;
  CFRunLoopSourceRef newSource = CFMachPortCreateRunLoopSource(NULL, newTap, 0);
  if (!newSource) { CFMachPortInvalidate(newTap); CFRelease(newTap); return 0; }
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopAddSource(loop, newSource, kCFRunLoopCommonModes);
  if (tapSource) {
    CFRunLoopRemoveSource(loop, tapSource, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(tapSource);
    CFRelease(tapSource);
  }
  if (tapPort) { CFMachPortInvalidate(tapPort); CFRelease(tapPort); }
  tapPort = newTap;
  tapSource = newSource;
  return 1;
}

// Main thread only. A failure (permission taken away) keeps the old tap and
// is logged once until a re-creation works again.
static void rearmTap(const char *why) {
  static int failedLogged;
  if (installTap()) {
    logf_("event tap created again (%s)", why);
    failedLogged = 0;
  } else if (!failedLogged) {
    logf_("cannot create the event tap again (%s): Accessibility or Input Monitoring taken away? Keeping the old one", why);
    failedLogged = 1;
  }
}

// What the capture check found (updateCapture, below): the front app's pid,
// its VM network (-1: not a VM app), whether its VM window covers a display,
// that window's title, the window, and whether the app is one the escape
// combo may go back to (other). Main thread.
static void noteCameFrom(int changed);
static void frontChanged(pid_t pid, int net, int front, const char *title, CGWindowID win, int other) {
  // The last full-screen VM in front with no window on this Space (win 0):
  // still full screen, on its own Space, which is not shown. The combo goes
  // back into it; it is no VM in a window (air-matrix O4: after Mission
  // Control + Esc on Desktop 1 the combo gave the keyboard to Finder and it
  // took three presses to get back).
  int offSpace = net >= 0 && !front && pid > 0 && pid == vmPid && !win;
  // OmacVM.app's launcher has the VMs' process name too: only QEMU counts.
  int winVM = net == NET_APP && !front && pid > 0 && !offSpace && isQemuFn(pid);
  // Each OmacVM VM is its own QEMU process with its own tap: a different pid
  // in front (tapVM is 0 while no VM is) may have put its tap ahead of ours.
  // In a window too: the combo is ours there as well.
  static pid_t tapVM;
  int qemuFront = net == NET_APP && (front || winVM);
  if (qemuFront && pid != tapVM) rearmTap(front ? "an OmacVM VM came to the front" : "an OmacVM VM window came to the front");
  tapVM = qemuFront ? pid : 0;
  if (front) {
    pthread_mutex_lock(&sendLock);
    if (net != frontNet || strcmp(title, frontTitle)) {
      frontNet = net;
      snprintf(frontTitle, sizeof frontTitle, "%s", title);
      retargetLocked(capturing);
    }
    pthread_mutex_unlock(&sendLock);
    vmPid = pid; vmWin = win;
  } else if (other) {
    otherPid = pid; otherWin = win;
  }
  winVMPid = winVM ? pid : 0;
  winVMWin = winVM ? win : 0;
  vmOffSpace = offSpace;
  // In that VM again, or a full-screen VM in front (the newer one to go back to).
  if (pid == leftWinPid || front) leftWinPid = 0;
  // Where the way out of the next full-screen VM goes back to.
  if (!front) noteCameFrom(pid != appPid);
  appPid = pid;
  frontPid = front ? pid : 0;
  cursorTimerOn(front);
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  int now = front && !escaped;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    if (rec) fprintf(rec, "C\t%.4f\t%d\n", unixNow(), now);
    sendState(now ? "on" : (front ? "esc" : "off"));
  }
  if (tapPort && !CFMachPortIsValid(tapPort)) rearmTap("macOS invalidated it");
  else if (tapPort && !CGEventTapIsEnabled(tapPort)) CGEventTapEnable(tapPort, true);
}

// Its two permissions, logged at start and whenever one changes (looked at
// every 10 s at most); omacvm check reads the last line. A missing one is
// named, not just "waiting".
static void logPermissions(void) {
  static int last = -1; static CFAbsoluteTime at;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (last >= 0 && now - at < 10) return;
  at = now;
  int ax = AXIsProcessTrusted() != 0, im = CGPreflightListenEventAccess() != 0;
  if ((ax | im << 1) == last) return;
  last = ax | im << 1;
  logf_("permissions: Accessibility %s, Input Monitoring %s", ax ? "granted" : "MISSING", im ? "granted" : "MISSING");
}

static void updateCapture(CFRunLoopTimerRef t, void *info) {
  (void)info;
  logPermissions();
  ProcessSerialNumber psn; pid_t pid = 0; char name[64] = "";
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, name, sizeof name);
  // Parallels' VM window, UTM's, or VMware Fusion's.
  int net = !strcmp(name, "prl_client_app") ? 0 : !strcmp(name, "UTM") ? NET_UTM
          : !strcmp(name, "VMware Fusion") && listenAddrs[NET_FUSION][0] ? NET_FUSION
          : !strcmp(name, "OmacVM") ? NET_APP : -1;   // OmacVM.app's QEMU
  CGWindowID win = 0;
  int front = net >= 0 && vmFullScreen(pid, &win);
  // Which of the app's VMs: its window title, on this check (every 0.2 s
  // while a VM app is full screen in front) and on every app switch.
  char title[sizeof frontTitle] = "";
  if (front) windowTitle(pid, title, sizeof title);
  int other = isOther(pid, net, name, net < 0 && pid > 0 && ns_is_regular(pid));
  // A VM app not full screen: its window here, 0 when it shows none on this
  // Space (its full-screen VM on a Space not shown).
  if (other || (net >= 0 && !front)) win = frontWindow(pid);
  frontChanged(pid, net, front, title, win, other);
  if (t) {
    // Every 0.2 s while a VM app is in front, else every 2 s; the slow look
    // may come up to 0.5 s late so macOS can batch it with other wake-ups.
    CFRunLoopTimerSetTolerance(t, net >= 0 ? 0.02 : 0.5);
    CFRunLoopTimerSetNextFireDate(t, CFAbsoluteTimeGetCurrent() + (net >= 0 ? 0.2 : 2.0));
  }
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
  static CFAbsoluteTime lastCheck, lastMove;
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
  int moved = p.x != last.x || p.y != last.y;
  if (moved) lastMove = now;
  // At rest: the next look in 50 ms instead of 8 (the timer goes back to
  // 120 Hz by itself after the first look that sees it move).
  if (t && now - lastMove > CURSOR_REST_AFTER) CFRunLoopTimerSetNextFireDate(t, now + CURSOR_REST_EVERY);
  // The window list only when the pointer moved, and every half second for
  // windows that appear under a pointer at rest (the Dock, a notification).
  if (!moved && now - lastCheck < 0.5) return;
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

// ---- the escape combo: out of the VM's Space with macOS's own shortcut, and back ----
// Ctrl+Option+Esc (escapeCombo above) in the captured full-screen VM hands the
// trackpad and keys back to macOS at once ("S esc <keys>", Omarchy lets go of
// held keys). Then the display under the pointer moves one Space toward the
// one it showed before the VM, with macOS's own "Move left/right a space" shortcut (System
// Settings > Keyboard > Keyboard Shortcuts > Mission Control: Ctrl+Left and
// Ctrl+Right unless the user changed them), so macOS animates it as its own
// swipe; the keyboard goes to what that display shows. Pressed again there in
// macOS, it moves back to the VM's Space. The setting "EscapeSwipe" = "all"
// (OmacVM.app's "Escape combo", or defaults write org.omacvm.gestures
// EscapeSwipe all) moves every display that shows the VM instead.
// The VM stays full screen and is never hidden (user, 2026-10-05: "I want to
// swipe away to macOS, not close its full screen").
// Every move is checked. Out: the shortcut is off or the Space did not change
// -> a Dock swipe (the events a three/four-finger swipe makes; on macOS 15
// the shortcut does nothing from the notched built-in display's full-screen
// Space, the swipe does) -> still in the VM's Space, or macOS gives no Spaces
// information -> one log line and a short notice in Omarchy ("N <why>"),
// nothing else: never Mission Control from one press (user, 2026-10-06:
// "never"; only twice in a row, see missionControl). Back in:
// the shortcut did not land -> the VM's window to the front (macOS shows its
// Space).
// An OmacVM VM in a window with the keyboard has no Space of its own: the
// combo gives the keyboard back to macOS (the app from before, else Finder,
// COMBO_WINDOW_OUT); pressed again in macOS, that window comes back with the
// keyboard (COMBO_WINDOW_BACK).
enum { COMBO_PASS, COMBO_LEAVE, COMBO_CAPTURE, COMBO_ENTER, COMBO_WINDOW_OUT, COMBO_WINDOW_BACK };

// haveVM: a full-screen VM to go back to, and its app is not the one in front
// (Parallels, UTM or Fusion in a window keep the combo, as before) or it is,
// with no window on this Space (vmOffSpace: its Space not shown). winVM: an
// OmacVM VM in front in a window. winBack: the windowed VM the combo left,
// still there and not in front (newer than any full-screen VM left).
static int comboAction(int vmFront, int esc, int haveVM, int winVM, int winBack) {
  if (vmFront) return esc ? COMBO_CAPTURE : COMBO_LEAVE;
  if (winVM) return COMBO_WINDOW_OUT;
  if (winBack) return COMBO_WINDOW_BACK;
  return haveVM ? COMBO_ENTER : COMBO_PASS;
}

// OmacVM.app's QEMU (Contents/Resources/runtime/bin/OmacVM, or a plain
// qemu-system-aarch64), not its launcher (Contents/MacOS/OmacVM).
static int isQemu(pid_t pid) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, path, sizeof path) <= 0) return 0;
  return !strstr(path, "/Contents/MacOS/");
}

static int alive(pid_t p) { return p > 0 && (kill(p, 0) == 0 || errno == EPERM); }

// An app the combo may go back to: no VM app, not this helper, not the lock
// screen, and a regular app (Raycast, Alfred, Spotlight or a password
// manager's panel are in front only for a moment and show no window).
static int isOther(pid_t pid, int net, const char *name, int regular) {
  return net < 0 && pid > 0 && pid != getpid() && strcmp(name, "loginwindow") && regular;
}

// The app in front now (the capture check's way of asking).
static pid_t frontNow(void) {
  ProcessSerialNumber psn; pid_t pid = 0;
  return GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr ? pid : 0;
}

// This window still exists and belongs to pid: a VM app (Parallels, UTM,
// Fusion) outlives its VM, and a pid may be used again.
static int windowAlive(pid_t pid, CGWindowID win) {
  if (!win) return 0;
  CFArrayRef w = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, win);
  int ok = 0;
  if (w && CFArrayGetCount(w) > 0) {
    int owner = 0;
    CFNumberGetValue(CFDictionaryGetValue(CFArrayGetValueAtIndex(w, 0), kCGWindowOwnerPID), kCFNumberIntType, &owner);
    ok = owner == pid;
  }
  if (w) CFRelease(w);
  return ok;
}

// Brings the app with this window to the front. The window server's own call
// (SkyLight, private; window managers use it) works from a background helper
// and across Spaces; NSRunningApplication's activate is the fallback, and
// the way for an app without a known window.
typedef CGError (*SetFrontFn)(ProcessSerialNumber *, uint32_t, uint32_t);
static int bringToFront(pid_t pid, CGWindowID win) {
  static SetFrontFn setFront; static int looked;
  if (!looked) {
    looked = 1;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    setFront = (SetFrontFn)dlsym(RTLD_DEFAULT, "_SLPSSetFrontProcessWithOptions");
    if (!setFront) logf_("escape combo: no SkyLight front-window call, using NSRunningApplication");
  }
  ns_unhide(pid);
  ProcessSerialNumber psn;
  if (win && setFront && GetProcessForPID(pid, &psn) == noErr && setFront(&psn, win, 0x200 /* user generated */) == kCGErrorSuccess)
    return 1;
  return ns_activate(pid);
}

// ---- Spaces (SkyLight, private; looked up at run time) ----
#define MAX_SPACES 32
#define MAX_DISPLAYS 16
typedef struct {
  CGDirectDisplayID id;
  CGRect bounds;
  uint64_t spaces[MAX_SPACES];   // left to right
  int n;
  uint64_t current;
} DisplaySpaces;

typedef int (*ConnFn)(void);
typedef CFArrayRef (*CopyDisplaySpacesFn)(int);
typedef CFArrayRef (*CopySpacesForWindowsFn)(int, int, CFArrayRef);
typedef CFUUIDRef (*DisplayUUIDFn)(CGDirectDisplayID);
static ConnFn cgsConn;
static CopyDisplaySpacesFn cgsDisplaySpaces;
static CopySpacesForWindowsFn cgsWindowSpaces;
static DisplayUUIDFn displayUUID;

static int lookUpSpaces(void) {
  static int looked;
  if (!looked) {
    looked = 1;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    cgsConn = (ConnFn)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    cgsDisplaySpaces = (CopyDisplaySpacesFn)dlsym(RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces");
    cgsWindowSpaces = (CopySpacesForWindowsFn)dlsym(RTLD_DEFAULT, "CGSCopySpacesForWindows");
    displayUUID = (DisplayUUIDFn)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
    if (!cgsConn || !cgsDisplaySpaces || !displayUUID)
      logf_("escape combo: macOS gives no Spaces information here: the combo switches apps instead of swiping");
  }
  return cgsConn && cgsDisplaySpaces && displayUUID;
}

static uint64_t spaceID(CFDictionaryRef s) {
  int64_t v = 0;
  CFNumberRef n = s ? CFDictionaryGetValue(s, CFSTR("ManagedSpaceID")) : NULL;
  if (!n || CFGetTypeID(n) != CFNumberGetTypeID()) n = s ? CFDictionaryGetValue(s, CFSTR("id64")) : NULL;
  if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
  return v > 0 ? (uint64_t)v : 0;
}

// Every active display with its Spaces, as macOS lists them (with "Displays
// have separate Spaces" off, one list ("Main") for all). 0: not known.
static int readSpaces(DisplaySpaces *out, int cap) {
  if (!lookUpSpaces()) return 0;
  CFArrayRef list = cgsDisplaySpaces(cgsConn());
  if (!list) return 0;
  CGDirectDisplayID ids[MAX_DISPLAYS]; uint32_t nd = 0;
  CGGetActiveDisplayList(MAX_DISPLAYS, ids, &nd);
  int k = 0;
  for (uint32_t i = 0; i < nd && k < cap; i++) {
    char uuid[64] = "";
    CFUUIDRef u = displayUUID(ids[i]);
    if (u) {
      CFStringRef s = CFUUIDCreateString(NULL, u);
      if (s) { CFStringGetCString(s, uuid, sizeof uuid, kCFStringEncodingUTF8); CFRelease(s); }
      CFRelease(u);
    }
    CFDictionaryRef entry = NULL;
    for (CFIndex j = 0; j < CFArrayGetCount(list) && !entry; j++) {
      CFDictionaryRef e = CFArrayGetValueAtIndex(list, j);
      CFStringRef d = CFGetTypeID(e) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(e, CFSTR("Display Identifier")) : NULL;
      char name[64] = "";
      if (d && CFGetTypeID(d) == CFStringGetTypeID()) CFStringGetCString(d, name, sizeof name, kCFStringEncodingUTF8);
      if ((uuid[0] && !strcasecmp(name, uuid)) || (!strcmp(name, "Main") && CFArrayGetCount(list) == 1)) entry = e;
    }
    if (!entry) continue;
    DisplaySpaces *d = &out[k];
    memset(d, 0, sizeof *d);
    d->id = ids[i];
    d->bounds = CGDisplayBounds(ids[i]);
    d->current = spaceID(CFDictionaryGetValue(entry, CFSTR("Current Space")));
    CFArrayRef sp = CFDictionaryGetValue(entry, CFSTR("Spaces"));
    if (sp && CFGetTypeID(sp) == CFArrayGetTypeID())
      for (CFIndex j = 0; j < CFArrayGetCount(sp) && d->n < MAX_SPACES; j++) {
        uint64_t id = spaceID(CFArrayGetValueAtIndex(sp, j));
        if (id) d->spaces[d->n++] = id;
      }
    if (d->n && d->current) k++;
  }
  CFRelease(list);
  return k;
}

// The Space a window is on; 0: not known.
static uint64_t readWindowSpace(CGWindowID win) {
  if (!win || !lookUpSpaces() || !cgsWindowSpaces) return 0;
  int32_t w = (int32_t)win;
  CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
  CFArrayRef ws = CFArrayCreate(NULL, (const void **)&n, 1, &kCFTypeArrayCallBacks);
  CFRelease(n);
  CFArrayRef r = cgsWindowSpaces(cgsConn(), 7 /* all Spaces */, ws);
  CFRelease(ws);
  int64_t v = 0;
  if (r && CFArrayGetCount(r) > 0) CFNumberGetValue(CFArrayGetValueAtIndex(r, 0), kCFNumberSInt64Type, &v);
  if (r) CFRelease(r);
  return v > 0 ? (uint64_t)v : 0;
}

static int spaceIndex(const DisplaySpaces *d, uint64_t id) {
  for (int i = 0; i < d->n; i++) if (d->spaces[i] == id) return i;
  return -1;
}

// Out of the VM's Space without knowing where the user came from: to the one
// on its left (macOS puts a full-screen Space right after the one its window
// came from), else the one on its right. 0: no neighbour.
static int stepOut(const DisplaySpaces *d) {
  int i = spaceIndex(d, d->current);
  if (i < 0) return 0;
  return i > 0 ? -1 : i + 1 < d->n ? 1 : 0;
}

// One swipe toward `want`: only when it is right beside the current Space
// (+1 right, -1 left); farther away or gone: 0 (then the app switch).
static int stepToward(const DisplaySpaces *d, uint64_t want) {
  int i = spaceIndex(d, d->current), j = spaceIndex(d, want);
  return i < 0 || j < 0 || (j - i != 1 && i - j != 1) ? 0 : j - i;
}

// Out of the VM's Space: one Space toward the one this display showed before
// the VM (cameFrom), else as stepOut. -1 left, +1 right, 0: no neighbour.
static int leaveDir(const DisplaySpaces *d, uint64_t cameFrom) {
  int i = spaceIndex(d, d->current), j = cameFrom ? spaceIndex(d, cameFrom) : -1;
  if (i < 0) return 0;
  if (j >= 0 && j != i) return j < i ? -1 : 1;
  return stepOut(d);
}

// ---- macOS's own Space shortcuts (com.apple.symbolichotkeys) ----
// AppleSymbolicHotKeys: { "79" = { enabled = 1; value = { parameters =
// (65535, 123, 8650752); type = standard; }; }; ... }: the character (65535:
// none), the key code and the modifiers (CGEventFlags bits; 8650752 =
// Control + fn, as macOS keeps an arrow key). An entry not listed was never
// changed: macOS's default, on.
#define HOTKEY_SPACE_LEFT 79        // Ctrl+Left
#define HOTKEY_SPACE_RIGHT 81       // Ctrl+Right
// The marker on the keys this helper posts for macOS (the Bridge's value):
// our tap and OmacVM.app's QEMU (omacvm-cocoa-keys-for-macos.patch) let them
// through instead of taking them for the VM.
#define OMACVM_KEY_MARKER 0x0BAC0E5C
#define HOTKEY_MODS (kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | \
                     kCGEventFlagMaskCommand | kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad)
typedef struct { int enabled, keycode; CGEventFlags flags; } Hotkey;

static int cfTrue(CFTypeRef v) {
  if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v);
  int n = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
  return n != 0;
}

static int64_t cfInt(CFArrayRef a, CFIndex i) {
  CFTypeRef v = CFArrayGetValueAtIndex(a, i);
  int64_t n = -1;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
  return n;
}

// One of them from that dictionary (NULL: none at all, every one the default).
static Hotkey hotkeyFrom(CFDictionaryRef all, int id) {
  Hotkey k = { 1, id == HOTKEY_SPACE_LEFT ? 123 : id == HOTKEY_SPACE_RIGHT ? 124 : 126,
               kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn };
  char name[16];
  snprintf(name, sizeof name, "%d", id);
  CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
  CFTypeRef e = all && key && CFGetTypeID(all) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(all, key) : NULL;
  if (key) CFRelease(key);
  if (!e || CFGetTypeID(e) != CFDictionaryGetTypeID()) return k;
  CFTypeRef on = CFDictionaryGetValue(e, CFSTR("enabled"));
  if (on) k.enabled = cfTrue(on);
  CFTypeRef v = CFDictionaryGetValue(e, CFSTR("value"));
  CFTypeRef p = v && CFGetTypeID(v) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(v, CFSTR("parameters")) : NULL;
  if (p && CFGetTypeID(p) == CFArrayGetTypeID() && CFArrayGetCount(p) >= 3) {
    int64_t code = cfInt(p, 1), mods = cfInt(p, 2);
    if (code < 0 || code > 127 || mods < 0) k.enabled = 0;   // 65535: no key set
    else { k.keycode = (int)code; k.flags = (CGEventFlags)mods & HOTKEY_MODS; }
  }
  return k;
}

static CFDictionaryRef readHotkeys(void) {
  CFStringRef domain = CFSTR("com.apple.symbolichotkeys");
  CFPreferencesAppSynchronize(domain);
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"), domain);
  if (v && CFGetTypeID(v) != CFDictionaryGetTypeID()) { CFRelease(v); v = NULL; }
  return v;
}

// The key event macOS would get from the keyboard for it: an arrow key
// carries fn and the keypad flag. Marked as ours. NULL if CG made none.
static CGEventRef hotkeyEvent(Hotkey k, int down) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)k.keycode, down);
  if (!e) return NULL;
  CGEventFlags f = k.flags;
  if (k.keycode >= 123 && k.keycode <= 126) f |= kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad;
  CGEventSetFlags(e, f);
  CGEventSetIntegerValueField(e, kCGEventSourceUserData, OMACVM_KEY_MARKER);
  return e;
}

// Down and up at the HID level, where the keyboard's own keys come in.
static int postHotkey(Hotkey k) {
  int ok = 1;
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = hotkeyEvent(k, down);
    if (!e) { ok = 0; continue; }
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
  }
  return ok;
}

static CGEventFlags heldNow(void) { return CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState); }

// ---- the swipe: a Dock swipe, the events a three/four-finger swipe makes ----
// Only for the escape combo when macOS's "Move left/right a space" did not
// move the display (macOS 15 from the notched built-in display's full-screen
// Space). Only after the late looks (checkLeave): the user's log of
// 2026-10-06 10:13-10:18 was the shortcut landing late, so the swipe moved a
// second Space. Never Mission Control.
#define kCGSEventTypeField 55
#define kCGEventGestureHIDType 110
#define kCGEventGestureScrollY 119
#define kCGEventGestureSwipeMotion 123
#define kCGEventGestureSwipeProgress 124
#define kCGEventGestureSwipeVelocityX 129
#define kCGEventGestureSwipeVelocityY 130
#define kCGEventGesturePhase 132
#define kCGEventScrollGestureFlagBits 135
#define kCGEventGestureZoomDeltaX 139
#define kIOHIDEventTypeDockSwipe 23
#define kCGSEventGesture 29
#define kCGSEventDockControl 30
#define kSwipeBegan 1
#define kSwipeEnded 4

// Which sign of the swipe's progress goes to the Space on the right. Not
// documented: a swipe seen going the other way flips it (learnSign), kept in
// the settings domain for the next start.
static int swipeSign = 1;

static int dockSwipe(CGPoint at, int phase, int right) {
  CGEventRef dock = CGEventCreate(NULL), gesture = CGEventCreate(NULL);
  if (!dock || !gesture) {
    if (dock) CFRelease(dock);
    if (gesture) CFRelease(gesture);
    return 0;
  }
  double s = right ? -1.0 : 1.0;   // fingers to the left reveal the Space on the right
  CGEventSetIntegerValueField(gesture, kCGSEventTypeField, kCGSEventGesture);
  CGEventSetIntegerValueField(dock, kCGSEventTypeField, kCGSEventDockControl);
  CGEventSetIntegerValueField(dock, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
  CGEventSetIntegerValueField(dock, kCGEventGesturePhase, phase);
  CGEventSetIntegerValueField(dock, kCGEventScrollGestureFlagBits, right ? 1 : 0);
  CGEventSetIntegerValueField(dock, kCGEventGestureSwipeMotion, 1);   // horizontal
  CGEventSetDoubleValueField(dock, kCGEventGestureScrollY, 0);
  CGEventSetDoubleValueField(dock, kCGEventGestureZoomDeltaX, 1.401298464e-45);   // FLT_TRUE_MIN, as the trackpad sends
  if (phase == kSwipeEnded) {
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeProgress, s * 2.0);
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityX, s * 400.0);
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityY, 0);
  }
  CGEventSetLocation(dock, at);
  CGEventSetLocation(gesture, at);
  CGEventPost(kCGSessionEventTap, dock);
  CGEventPost(kCGSessionEventTap, gesture);
  CFRelease(dock); CFRelease(gesture);
  return 1;
}

static CGPoint pointerNow(void) {
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
  if (e) CFRelease(e);
  return p;
}

// One swipe on that display (dir +1: to the Space on the right). The Dock
// swipes the display the pointer is on (postMove puts it there first); the
// events also carry it.
static int postSwipe(CGDirectDisplayID d, CGRect b, int dir) {
  (void)d;
  CGPoint p = pointerNow();
  CGPoint at = CGRectContainsPoint(b, p) ? p : CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  int right = dir * swipeSign > 0;
  return dockSwipe(at, kSwipeBegan, right) && dockSwipe(at, kSwipeEnded, right);
}

// The on-screen windows of pid (layer 0), front to back, as rectangles.
static int windowsOf(pid_t pid, CGRect *out, int cap) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  int k = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && k < cap; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == pid && layer == 0 && CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) &&
        r.size.width > 100 && r.size.height > 100)
      out[k++] = r;
  }
  CFRelease(wins);
  return k;
}

// Mission Control is showing: the Dock then has a window over a whole display
// below its own level (layer 18 on macOS 26; its normal window sits at the
// Dock level, 20, and its backdrops below 0). macOS gives no call for it. In
// Mission Control the Space shortcut and app switches do nothing, macOS keeps
// the app from before in front, and the Spaces list names Desktop 1 as shown.
static int missionControlOpen(void) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  if (!wins) return 0;
  CGDirectDisplayID ds[16]; uint32_t nd = 0; CGGetActiveDisplayList(16, ds, &nd);
  int dockLevel = (int)CGWindowLevelForKey(kCGDockWindowLevelKey), found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int layer = -1; CGRect r; char owner[32] = "";
    CFStringRef name = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (!name || !CFStringGetCString(name, owner, sizeof owner, kCFStringEncodingUTF8) || strcmp(owner, "Dock")) continue;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (layer <= 0 || layer >= dockLevel || !CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r)) continue;
    for (uint32_t d = 0; d < nd && !found; d++) found = CGRectEqualToRect(CGRectIntegral(r), CGRectIntegral(CGDisplayBounds(ds[d])));
  }
  CFRelease(wins);
  return found;
}

// The front app on a display now: the owner of its topmost normal window that
// is not `skip`'s (the VM), with that window. 0: none (the desktop).
static pid_t topAppOn(CGRect b, pid_t skip, CGWindowID *win) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  pid_t found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == skip || owner == getpid() || layer != 0 ||
        !CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) ||
        r.size.width <= 100 || r.size.height <= 100 || !CGRectContainsPoint(b, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r))))
      continue;
    found = owner;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, win);
  }
  CFRelease(wins);
  return found;
}

// The test identity (build.sh with OMACVM_HELPER_TEST=1) builds with its own
// domain, port and Bridge folder, so it never meets the installed Gestures.
#ifndef GESTURES_DOMAIN
#define GESTURES_DOMAIN CFSTR("org.omacvm.gestures")
#endif

// "EscapeSwipe": "all" moves every display that shows the VM, anything else
// (default) the display under the pointer only.
static int escapeAll(void) {
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("EscapeSwipe"), GESTURES_DOMAIN);
  int all = v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringCompare((CFStringRef)v, CFSTR("all"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
  if (v) CFRelease(v);
  return all;
}

// "MouseSwipeFingers": a Magic Mouse two-finger swipe is this many fingers on
// the guest's touchpad, 3 or 4 (OmacVM.app's "Magic Mouse swipe", or defaults
// write org.omacvm.gestures MouseSwipeFingers -int 3). Not set, or anything
// else: 4 (Omarchy switches workspaces with 4).
static int mouseFingersOf(CFPropertyListRef v) {
  double n = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &n);
  else if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringCompare((CFStringRef)v, CFSTR("3"), 0) == kCFCompareEqualTo) n = 3;
  return n == 3 ? 3 : 4;
}

static int mouseSwipeFingers(void) {
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("MouseSwipeFingers"), GESTURES_DOMAIN);
  int n = mouseFingersOf(v);
  if (v) CFRelease(v);
  return n;
}

static void loadSwipeSign(void) {
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("SwipeSign"), GESTURES_DOMAIN);
  int s = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &s);
  if (v) CFRelease(v);
  if (s == -1) swipeSign = -1;
}

static void saveSwipeSign(void) {
  CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &swipeSign);
  CFPreferencesSetAppValue(CFSTR("SwipeSign"), n, GESTURES_DOMAIN);
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  CFRelease(n);
}

// Seams for the offline test (test-escape.c): the window server is not asked.
static int (*activateFn)(pid_t, CGWindowID) = bringToFront;
static pid_t (*finderFn)(void) = ns_finder_pid;
static pid_t (*frontFn)(void) = frontNow;
static int (*vmWindowFn)(pid_t, CGWindowID) = windowAlive;
static int (*spacesFn)(DisplaySpaces *, int) = readSpaces;
static uint64_t (*windowSpaceFn)(CGWindowID) = readWindowSpace;
static int (*swipeFn)(CGDirectDisplayID, CGRect, int) = postSwipe;
static CGPoint (*pointerFn)(void) = pointerNow;
static void warpPointer(CGPoint p) { CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(true); }
static void (*warpFn)(CGPoint) = warpPointer;
static double warpSettle = 0.08;   // s: macOS takes the move before the pointer goes back
static int (*vmWindowsFn)(pid_t, CGRect *, int) = windowsOf;
static pid_t (*topAppFn)(CGRect, pid_t, CGWindowID *) = topAppOn;
static int (*hideFn)(pid_t) = ns_hide;   // a VM in a window only
static int (*escapeAllFn)(void) = escapeAll;
static void (*saveSignFn)(void) = saveSwipeSign;
static CFDictionaryRef (*hotkeysFn)(void) = readHotkeys;
static int (*keyFn)(Hotkey) = postHotkey;
static CGEventFlags (*heldFn)(void) = heldNow;
static int (*missionControlOpenFn)(void) = missionControlOpen;
static double verifyAfter = 0.8;   // s: a Space's animation is over by then
static double cameFromEvery = 0.5; // s: the Spaces read at most this often for the same app

// The escape combo's steps still to run (main thread): the offline test runs
// the main queue until none is left.
static int pendingSteps;

static void after(void (^f)(void)) {
  pendingSteps++;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(verifyAfter * NSEC_PER_SEC)), dispatch_get_main_queue(),
                 ^{ pendingSteps--; f(); });
}

// Per display: the VM's Space when the combo left it (pressed again there,
// it goes back to it), and the Space it showed before the VM (the way out
// goes toward it).
typedef struct { CGDirectDisplayID id; uint64_t space; } DisplaySpace;
static DisplaySpace left[MAX_DISPLAYS], cameFrom[MAX_DISPLAYS];

static void rememberOn(DisplaySpace *m, CGDirectDisplayID id, uint64_t space) {
  for (int i = 0; i < MAX_DISPLAYS; i++)
    if (m[i].id == id || !m[i].id) { m[i].id = id; m[i].space = space; return; }
}

static uint64_t spaceOn(const DisplaySpace *m, CGDirectDisplayID id) {
  for (int i = 0; i < MAX_DISPLAYS && m[i].id; i++) if (m[i].id == id) return m[i].space;
  return 0;
}

// While no full-screen VM is in front (the capture check): what each display
// shows, except the last VM's Space. changed: another app came to the front.
static void noteCameFrom(int changed) {
  static double at = -1;
  double now = monoNow();
  if (!changed && at >= 0 && now - at < cameFromEvery) return;
  at = now;
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  uint64_t vmSpace = nd && vmWin ? windowSpaceFn(vmWin) : 0;
  for (int i = 0; i < nd; i++) if (ds[i].current != vmSpace) rememberOn(cameFrom, ds[i].id, ds[i].current);
}

static const DisplaySpaces *displayIn(const DisplaySpaces *ds, int n, CGDirectDisplayID id) {
  for (int i = 0; i < n; i++) if (ds[i].id == id) return &ds[i];
  return NULL;
}

static Hotkey hotkey(int id) {
  CFDictionaryRef all = hotkeysFn();
  Hotkey k = hotkeyFrom(all, id);
  if (all) CFRelease(all);
  return k;
}

// Brings an app to the front; after a moment it must be there, else the usual
// activation once more. done(1) once it is in front, done(0) if not.
static void goTo(pid_t pid, CGWindowID win, const char *what, void (^done)(int)) {
  char name[64] = "";
  proc_name(pid, name, sizeof name);
  int ok = activateFn(pid, win);
  logf_("escape combo: %s %s (pid %d, window %u)%s", what, name, pid, win, ok ? "" : ": macOS refused, trying again");
  after(^{
    if (frontFn() == pid) { if (done) done(1); return; }
    int again = activateFn(pid, 0);
    after(^{
      char who[64] = "";
      proc_name(pid, who, sizeof who);
      int in = frontFn() == pid;
      logf_("escape combo: %s %s (second try %s)", who, in ? "is in front" : "did not come to the front", again ? "taken" : "refused");
      if (done) done(in);
    });
  });
}

// A VM window covering this display (its full screen, either kind).
static int fullOn(const DisplaySpaces *d, const CGRect *wins, int nw) {
  for (int i = 0; i < nw; i++)
    if (fabs(wins[i].size.width - d->bounds.size.width) < 2 && wins[i].size.height >= d->bounds.size.height - 80 &&
        CGRectContainsPoint(d->bounds, CGPointMake(CGRectGetMidX(wins[i]), CGRectGetMidY(wins[i])))) return 1;
  return 0;
}

// Still in the VM: it has the keyboard, or the pointer's display still shows
// its full-screen window.
static const char *stillIn(void) {
  if (frontFn() == vmPid) return "it has the keyboard";
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = pointerFn();
  for (int i = 0; i < nd; i++)
    if (CGRectContainsPoint(ds[i].bounds, p) && fullOn(&ds[i], wins, nw)) return "its full screen still shows";
  return NULL;
}

static void checkOut(void) {
  const char *why = stillIn();
  if (!why) logf_("escape combo: out of the VM (checked)");
  else logf_("escape combo: still in the VM (%s); it stays full screen", why);
}

// Out of the VM's Space: the keyboard follows the pointer's display. The VM
// may still be in front (its window on another display, or macOS kept it
// there): then the app on top of the pointer's display, else Finder.
static void focusPointerDisplay(void) {
  if (frontFn() != vmPid) { checkOut(); return; }
  CGPoint p = pointerFn();
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  CGRect b = CGRectNull;
  for (int i = 0; i < nd; i++) if (CGRectContainsPoint(ds[i].bounds, p)) b = ds[i].bounds;
  CGWindowID w = 0;
  pid_t to = CGRectIsNull(b) ? 0 : topAppFn(b, vmPid, &w);
  if (to <= 0) { to = finderFn(); w = 0; }
  if (to <= 0) { checkOut(); return; }
  goTo(to, w, "keyboard to", ^(int ok) { (void)ok; checkOut(); });
}

// ---- the combo pressed twice: Mission Control ----
// User, 2026-10-06 10:31: "esc combo triggering mission control is rather
// nerving.. disable it, maybe only do it when combo is clicked twice". A
// single press only ever moves one Space (or does nothing); a second press
// within doublePress stops what the first one has not posted yet and opens
// Mission Control: macOS's own shortcut (as the user set it), else the app.
static double doublePress = 0.4;     // s between the two presses (the offline test sets its own)
#define HOTKEY_MISSION_CONTROL 32    // Ctrl+Up
int ns_open_mission_control(void);
static int (*missionAppFn)(void) = ns_open_mission_control;
static int movesCancelled;           // the first press's steps not posted yet are dropped
static double mcClosedAt = -1;       // when we last closed Mission Control (its shortcut toggles it)
static double mcClosing = 1.0;       // s it may still be listed while it closes (the offline test sets its own)
static double lastComboAt = -1;

static void missionControl(void) {
  mcClosedAt = -1;   // opened again: the next close is a real one
  Hotkey k = hotkey(HOTKEY_MISSION_CONTROL);
  if (k.enabled && keyFn(k)) {
    logf_("escape combo: pressed twice: Mission Control (macOS's shortcut)");
    return;
  }
  int ok = missionAppFn();
  logf_("escape combo: pressed twice: Mission Control (the app%s)", ok ? "" : ": macOS refused!");
}

// No way out to macOS (the Space shortcut is off, macOS did not move the
// Space, not even with a Dock swipe, or it gives no Spaces information): one
// log line and a short notice in Omarchy, nothing else. Never Mission
// Control (user, 2026-10-06: "never"). The trackpad and keys stay macOS's, as after
// any escape; the combo again takes them back.
static void noWayOut(const char *why, const char *notice) {
  logf_("escape combo: %s: nothing done", why);
  char b[48]; int n = snprintf(b, sizeof b, "N %s\n", notice);
  sendTo(0, b, (size_t)n);
}

// ---- the moves of the last press: per display, from its Space to the one beside it ----
typedef struct { CGDirectDisplayID id; CGRect b; uint64_t from, to; int dir, done; } Move;
enum { BY_SHORTCUT, BY_DOCK };
static Move moves[MAX_DISPLAYS];
static int nMoves, leaving, signRetried, learnedNow, shortcutOff;

static int addMove(const DisplaySpaces *d, int dir, uint64_t to) {
  // "Displays have separate Spaces" off: one list for every display, moved once.
  for (int i = 0; i < nMoves; i++) if (moves[i].from == d->current) return 0;
  if (!dir || nMoves >= MAX_DISPLAYS) return 0;
  moves[nMoves++] = (Move){ d->id, d->bounds, d->current, to, dir, 0 };
  return 1;
}

// One move on its display. macOS moves the display the pointer is on: for
// another display (the "all" setting) the pointer goes to its centre first,
// then back. 0: not made (the shortcut is off). *k: the shortcut used.
static int postMove(const Move *m, int by, Hotkey *k) {
  if (by == BY_SHORTCUT) {
    *k = hotkey(m->dir < 0 ? HOTKEY_SPACE_LEFT : HOTKEY_SPACE_RIGHT);
    if (!k->enabled) return 0;
  }
  CGPoint p = pointerFn();
  int away = !CGRectContainsPoint(m->b, p);
  if (away) warpFn(CGPointMake(CGRectGetMidX(m->b), CGRectGetMidY(m->b)));
  int ok = by == BY_SHORTCUT ? keyFn(*k) : swipeFn(m->id, m->b, m->dir);
  if (away) {
    if (warpSettle > 0) usleep((useconds_t)(warpSettle * 1e6));
    warpFn(p);
  }
  return ok;
}

// Every move not done yet, one way. Returns how many were made.
static int runMoves(int by, const char *what) {
  int made = 0;
  if (movesCancelled) return 0;
  for (int i = 0; i < nMoves; i++) {
    Move *m = &moves[i];
    if (m->done) continue;
    const char *side = m->dir > 0 ? "right" : "left";
    Hotkey k = { 0 };
    if (!postMove(m, by, &k)) {
      if (by == BY_SHORTCUT) logf_("escape combo: macOS's \"Move %s a space\" shortcut is off or has no key", side);
      continue;
    }
    made++;
    if (by == BY_SHORTCUT)
      logf_("escape combo: display %u: macOS's \"Move %s a space\" (key %d, modifiers 0x%llx; %s)", m->id, side, k.keycode,
            (unsigned long long)k.flags, what);
    else logf_("escape combo: display %u swiped %s (%s)", m->id, side, what);
  }
  return made;
}

// Which moves landed: out, any Space but the VM's on that display; back in,
// the VM's. A Dock swipe seen going the other way teaches its sign (kept).
// *moved: some display's Space changed at all. Returns the moves not done.
static int movesLeft(int by, int *moved) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), rest = 0;
  *moved = 0; learnedNow = 0;
  for (int i = 0; i < nMoves; i++) {
    Move *m = &moves[i];
    if (m->done) continue;
    const DisplaySpaces *d = displayIn(ds, nd, m->id);
    if (!d) { m->done = 1; continue; }   // the display is gone
    int from = spaceIndex(d, m->from), now = spaceIndex(d, d->current);
    if (d->current != m->from) *moved = 1;
    if (by == BY_DOCK && from >= 0 && now == from - m->dir && !learnedNow) {
      swipeSign = -swipeSign;
      saveSignFn();
      learnedNow = 1;
      logf_("escape combo: the swipe went the other way: direction learned");
    }
    if (leaving ? d->current != m->from : d->current == m->to) m->done = 1;
    else rest++;
  }
  return rest;
}

// Nothing moved: with only two Spaces (a Mac mini: Desktop 1 and the VM's) a
// swipe the wrong way just bounces at the edge, so nothing is learned. Try
// the other direction once; if that lands, it is kept. 1: a retry is on.
static int retryOtherWay(void (^then)(void)) {
  if (signRetried) return 0;
  signRetried = 1;
  swipeSign = -swipeSign;
  logf_("escape combo: the swipe bounced: trying the other direction");
  if (!runMoves(BY_DOCK, "the other direction")) { swipeSign = -swipeSign; return 0; }
  after(then);
  return 1;
}

// Out: macOS's shortcut, then (it did not move: macOS 15 from the notched
// display's full-screen Space) a Dock swipe, then the other direction once.
// Nothing landed: noWayOut. Never Mission Control.
// A Space change can land after verifyAfter (macOS still sliding or busy).
// Before the next step (a swipe, the other direction) look again a few times:
// a step after a late landing moves a second Space (the user's 10:13 log:
// the shortcut, then the swipe, ended on Desktop 1 of 3 instead of the Space
// beside the VM).
#define LATE_LOOKS 2
static int lateLooks;
// The extra looks come quicker than the first one (half of verifyAfter).
static void afterLook(void (^f)(void)) {
  pendingSteps++;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(verifyAfter * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                 ^{ pendingSteps--; f(); });
}
static void landedLate(int rest, int moved) {
  if (lateLooks && (moved || !rest))
    logf_("escape combo: macOS's Space change landed late (%.1f s after the key): no further step", verifyAfter * (1 + 0.5 * lateLooks));
}
static void checkLeave(int by) {
  if (movesCancelled) return;
  int moved, rest = movesLeft(by, &moved);
  if (rest && !moved && lateLooks < LATE_LOOKS) {
    lateLooks++;
    afterLook(^{ checkLeave(by); });
    return;
  }
  landedLate(rest, moved);
  lateLooks = 0;
  if (by == BY_DOCK && signRetried && !learnedNow) {
    if (rest) swipeSign = -swipeSign;   // the retry did not land either: as before
    else { saveSignFn(); logf_("escape combo: the other direction worked: direction learned"); }
  }
  if (!rest) {
    logf_("escape combo: out of the VM's Space (%s)", by == BY_SHORTCUT ? "macOS's shortcut" : "a Dock swipe");
    focusPointerDisplay();
    return;
  }
  if (by == BY_SHORTCUT) {
    logf_("escape combo: still in the VM's Space: trying a Dock swipe");
    if (runMoves(BY_DOCK, "out of the VM")) { after(^{ checkLeave(BY_DOCK); }); return; }
  } else if (!moved && retryOtherWay(^{ checkLeave(BY_DOCK); })) {
    return;
  }
  if (shortcutOff) noWayOut("macOS's \"Move left/right a space\" shortcut is off and the swipe did not move", "space-shortcut-off");
  else noWayOut("the Space did not change", "space-unchanged");
}

static void checkEnter(void) {
  if (movesCancelled) return;
  int moved, rest = movesLeft(BY_SHORTCUT, &moved);
  if (rest && !moved && lateLooks < LATE_LOOKS) {
    lateLooks++;
    afterLook(^{ checkEnter(); });
    return;
  }
  landedLate(rest, moved);
  lateLooks = 0;
  if (rest) {
    logf_("escape combo: not in the VM's Space: its window to the front instead");
    goTo(vmPid, vmWin, "back into the VM:", NULL);
    return;
  }
  // The keyboard to the VM now on the pointer's display (a full-screen Space
  // usually brings its app).
  if (frontFn() != vmPid) goTo(vmPid, vmWin, "keyboard to the VM:", NULL);
}

// The combo's Ctrl, Option and Cmd are most likely still down when its steps
// run: macOS's shortcut goes once they are up (at most 1 s), so macOS reads
// it as the shortcut and not as one with more keys.
static void whenKeysUp(void (^f)(void), int tries) {
  CGEventFlags combo = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
  if (tries <= 0 || !(heldFn() & combo)) { f(); return; }
  pendingSteps++;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(),
                 ^{ pendingSteps--; whenKeysUp(f, tries - 1); });
}

static void missionControlWhenKeysUp(void) { whenKeysUp(^{ missionControl(); }, 50); }

static int showsVM(const DisplaySpaces *d, const CGRect *wins, int nw) {
  for (int i = 0; i < nw; i++)
    if (CGRectContainsPoint(d->bounds, CGPointMake(CGRectGetMidX(wins[i]), CGRectGetMidY(wins[i])))) return 1;
  return 0;
}

// Out of the VM: the pointer's display (or, with "all", each display that
// shows the VM) moves one Space toward the one it showed before.
static void leaveVM(void) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = pointerFn();
  nMoves = 0; leaving = 1; signRetried = 0; shortcutOff = 0; lateLooks = 0;
  int pointerOnVM = 0;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    int under = CGRectContainsPoint(d->bounds, p), vm = showsVM(d, wins, nw);
    pointerOnVM |= under && vm;
    if (!vm || !(all || under)) continue;
    int dir = leaveDir(d, spaceOn(cameFrom, d->id));
    if (dir && addMove(d, dir, d->spaces[spaceIndex(d, d->current) + dir])) rememberOn(left, d->id, d->current);
  }
  if (nMoves) {
    whenKeysUp(^{
      if (runMoves(BY_SHORTCUT, "out of the VM")) after(^{ checkLeave(BY_SHORTCUT); });
      else { shortcutOff = 1; checkLeave(BY_SHORTCUT); }   // the shortcut is off: on to the Dock swipe
    }, 50);
    return;
  }
  // The pointer is on a display without the VM: nothing to move there, the
  // keyboard goes to what it shows.
  if (nd && nw && !pointerOnVM && !all) { focusPointerDisplay(); return; }
  if (!nd) noWayOut("macOS gives no Spaces information", "no-spaces");
  else noWayOut("the VM's Space has no neighbour", "space-unchanged");
}

// Into the VM again: the pointer's display (or, with "all", each display the
// combo left) moves back to the VM's Space when it is right beside it; else,
// or if that does not land, the VM's window comes to the front (macOS shows
// its Space).
static void enterVMNow(int mayCloseMC);
static void enterVM(void) { enterVMNow(1); }

// The VM's Space shows on some display.
static int vmSpaceShown(void) {
  uint64_t s = windowSpaceFn(vmWin);
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  for (int i = 0; s && i < nd; i++) if (ds[i].current == s) return 1;
  return 0;
}

// Mission Control open (the combo pressed twice, then once more in it): the
// Space shortcut and app switches do nothing there, so it took presses that
// did nothing, or gave the keyboard to Finder (air-matrix O4). Its own
// shortcut (or the app) closes it, back to the Space it was opened from: the
// VM's after a double press in the VM. Another Space -> the usual way in.
// Mission Control still closing (or the VM's Space not listed yet): look
// again a few times before the usual way in, whose Space move would go one
// Space too far once macOS lands on the VM's.
static void afterMissionControl(int looks) {
  if (movesCancelled) return;
  if (vmSpaceShown()) {
    if (frontFn() != vmPid) goTo(vmPid, vmWin, "keyboard to the VM:", NULL);
    return;
  }
  if (looks < LATE_LOOKS) { afterLook(^{ afterMissionControl(looks + 1); }); return; }
  enterVMNow(0);
}

// Its shortcut toggles it: posted only while it is still open and not
// already being closed by us (its close animation still lists it), else a
// second close would open it again.
static int closeMissionControlOnce(const char *why) {
  double now = monoNow();
  if ((mcClosedAt >= 0 && now - mcClosedAt < mcClosing) || !missionControlOpenFn()) return 0;
  mcClosedAt = now;
  Hotkey k = hotkey(HOTKEY_MISSION_CONTROL);
  int byKey = k.enabled && keyFn(k), ok = byKey || missionAppFn();
  logf_("%s: closing Mission Control (%s)", why, byKey ? "macOS's shortcut" : ok ? "the app" : "macOS refused!");
  return 1;
}

static void closeMissionControlThenEnter(void) {
  whenKeysUp(^{
    if (movesCancelled) return;
    closeMissionControlOnce("escape combo: Mission Control is open");
    after(^{ afterMissionControl(0); });
  }, 50);
}

// Esc in Mission Control while OmacVM's QEMU is the app in front: QEMU's own
// event tap (full grab) took it for the VM, so Mission Control stayed open
// and the VM got an Esc (the Air, air-matrix O4). Ours sees it first:
// Mission Control's own shortcut closes it instead, back to the Space it was
// opened from.
static void closeMissionControl(void) {
  whenKeysUp(^{ closeMissionControlOnce("Esc in Mission Control (the VM would have taken it)"); }, 50);
}

static void enterVMNow(int mayCloseMC) {
  if (mayCloseMC && missionControlOpenFn()) { closeMissionControlThenEnter(); return; }
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGPoint p = pointerFn();
  uint64_t vmSpace = windowSpaceFn(vmWin);
  nMoves = 0; leaving = 0; lateLooks = 0;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    if (!all && !CGRectContainsPoint(d->bounds, p)) continue;
    uint64_t want = spaceOn(left, d->id);
    if (!want || spaceIndex(d, want) < 0) want = all ? 0 : vmSpace;
    if (want && d->current != want) addMove(d, stepToward(d, want), want);
  }
  if (!nMoves) { goTo(vmPid, vmWin, "back into the VM:", NULL); return; }
  whenKeysUp(^{
    if (runMoves(BY_SHORTCUT, "back into the VM")) after(^{ checkEnter(); });
    else checkEnter();
  }, 50);
}

// A windowed VM with the keyboard: the app from before (else Finder) gets
// it; the VM still in front -> its app is hidden.
static void leaveWindow(void) {
  pid_t vm = leftWinPid, to = alive(otherPid) ? otherPid : finderFn();
  CGWindowID w = to == otherPid ? otherWin : 0;
  void (^check)(int) = ^(int ok) {
    (void)ok;
    if (frontFn() != vm) return;
    char name[64] = "";
    proc_name(vm, name, sizeof name);
    int hid = hideFn(vm);
    logf_("escape combo: %s kept the keyboard: hidden%s (the combo brings it back)", name, hid ? "" : " (refused!)");
  };
  if (to <= 0) { check(0); return; }
  goTo(to, w, to == otherPid ? "keyboard back to" : "keyboard back to (the app from before has quit)", check);
}

// Into the windowed VM the combo left: its window to the front, with the keyboard.
static void enterWindow(void) {
  goTo(leftWinPid, leftWinWin, "back into the VM window:", NULL);
}

// The switch runs after the tap's callback has returned (it talks to the
// window server; the callback must stay quick).
static void later(void (*f)(void)) { pendingSteps++; dispatch_async(dispatch_get_main_queue(), ^{ pendingSteps--; f(); }); }

// ---- event tap: drop macOS gestures while capturing; escape combo ----
static int swallowEscUp, escClosedMC;

static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u) {
  (void)p; (void)u;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(tapPort, true); return e;
  }
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    // Ours for macOS (the combo's Space shortcut): never the VM's.
    if (CGEventGetIntegerValueField(e, kCGEventSourceUserData) == OMACVM_KEY_MARKER) return e;
    int kc = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    CGEventFlags f = CGEventGetFlags(e);
    int combo = escapeCombo(kc, f);
    // vmOffSpace (no VM window on this Space, as in Mission Control) first:
    // an Esc in a windowed VM never pays for the window list.
    if (kc == ESC_KEYCODE && escClosedMC) {   // the rest of that Esc: held (repeats) and its up
      if (type == kCGEventKeyUp) { escClosedMC = 0; swallowEscUp = 0; return NULL; }
      if (CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat)) return NULL;
      escClosedMC = 0;
    }
    if (kc == ESC_KEYCODE && type == kCGEventKeyDown && !combo && !frontIsVM && vmOffSpace && appPid > 0 && appPid == vmPid &&
        !(f & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) &&
        CGEventGetIntegerValueField(e, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState &&
        !CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat) && isQemuFn(vmPid) && missionControlOpenFn()) {
      escClosedMC = 1;   // its repeats and its up too: QEMU must not see half a key
      later(closeMissionControl);
      return NULL;
    }
    // A plain Esc going down: the combo's Esc up we meant to eat went elsewhere
    // (QEMU's tap ahead of ours takes it when Ctrl or Option comes up first),
    // so this press keeps its own up.
    if (kc == ESC_KEYCODE && type == kCGEventKeyDown && !combo) swallowEscUp = 0;
    if (kc == ESC_KEYCODE && type == kCGEventKeyUp && swallowEscUp) { swallowEscUp = 0; return NULL; }
    int act = combo
              ? comboAction(frontIsVM, escaped, alive(vmPid) && (vmPid != appPid || vmOffSpace) && vmWindowFn(vmPid, vmWin),
                            winVMPid > 0 && winVMPid == appPid,
                            alive(leftWinPid) && leftWinPid != appPid && vmWindowFn(leftWinPid, leftWinWin))
              : COMBO_PASS;
    // In Mission Control (no VM in front there) with a full-screen VM to go
    // back to: back into it, whatever macOS says is in front (enterVM closes
    // Mission Control first). Asked only for a combo from the keyboard.
    if (combo && !frontIsVM && type == kCGEventKeyDown && act != COMBO_ENTER && act != COMBO_WINDOW_BACK &&
        CGEventGetIntegerValueField(e, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState &&
        !CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat) &&
        alive(vmPid) && vmWindowFn(vmPid, vmWin) && missionControlOpenFn())
      act = COMBO_ENTER;
    if (act == COMBO_PASS) {
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
    escKeys = combo == ESC_OLD ? "ctrl-opt-cmd" : "ctrl-opt";
    if (combo == ESC_OLD) logf_("escape combo: the old Ctrl+Option+Cmd+Esc (works through 3.0.x; the new one is Ctrl+Option+Esc)");
    // Twice in a row (the first press's state stays: out of the VM, capture
    // off): Mission Control, and nothing more of the first press.
    double nowCombo = monoNow();
    if (lastComboAt >= 0 && nowCombo - lastComboAt < doublePress) {
      lastComboAt = -1;
      movesCancelled = 1;
      if (capturing) { capturing = 0; escaped = 1; logf_("escape combo: capture off"); sendState("esc"); }
      // Ctrl+Up once Ctrl and Option are up, like the Space shortcut: with
      // them still held macOS reads it as Ctrl+Option+Up (no Mission Control).
      later(missionControlWhenKeysUp);
      swallowEscUp = 1;
      return NULL;
    }
    lastComboAt = nowCombo;
    movesCancelled = 0;   // this press's steps run (a second press may drop them)
    if (act == COMBO_ENTER) {
      later(enterVM);
    } else if (act == COMBO_WINDOW_BACK) {
      later(enterWindow);
    } else if (act == COMBO_WINDOW_OUT) {
      leftWinPid = winVMPid; leftWinWin = winVMWin;
      later(leaveWindow);
    } else {
      escaped = act == COMBO_LEAVE;
      capturing = !escaped;
      logf_("escape combo: capture %s", capturing ? "ON" : "off");
      sendState(capturing ? "on" : "esc");
      if (act == COMBO_LEAVE) later(leaveVM);
    }
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
    // A Magic Mouse's two-finger swipe is the guest's workspace swipe: macOS's
    // scrolling for the same fingers would also scroll the VM sideways.
    if (capturing && monoNow() < mouseSwipeUntil && gesturesOn()) return NULL;
    // Glide: a trackpad's scrolling, as macOS shaped it, goes to the guest;
    // everything else (wheel mice, smooth-scrolling mice, a Magic Mouse)
    // passes to the VM app as it is (scroll-model.h).
    if (!(capturing && glideOn())) return e;
    ScrollEvent se = { (int)CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous),
                       (int)CGEventGetIntegerValueField(e, kCGScrollWheelEventScrollPhase),
                       (int)CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase), monoNow() };
    pthread_mutex_lock(&padLock);
    int route = scrollRoute(&scrollSt, &se);
    pthread_mutex_unlock(&padLock);
    if (route == SCROLL_PASS) return e;
    double dy = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1);
    double dx = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2);
    if (dx != 0 || dy != 0) {
      // While fingers touch, their raw frames carry this scroll; the guest
      // only learns from it how much macOS accelerates right now ("A").
      // After they lift, macOS's momentum ("W").
      char b[64]; int n = snprintf(b, sizeof b, "%c %.2f %.2f\n", route == SCROLL_TOUCH ? 'A' : 'W', dx, dy);
      sendLine(b, (size_t)n);
    }
    return NULL;
  }
  // macOS recognized a pinch (NSEventTypeMagnify): tell the guest, so its
  // two-finger touch passes raw fingers from now on.
  if (!pinchSent && capturing && glideOn() &&
      (type == 30 || (type == 29 && ns_event_type(e) == 30))) {
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
  snprintf(path, sizeof path, "%s/Library/Application Support/" BRIDGE_DIR "/token", getenv("HOME"));
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
  // apart, or two running VMs would keep pushing each other out. An app VM
  // the app moved between its fast network and the user network comes back
  // from another address: its name tells it is the same VM (its old
  // connection may not have noticed yet that its path is gone).
  int loopback = !strncmp(ip, "127.", 4);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 &&
        ((!strcmp(clients[i].ip, ip) && (!loopback || !strcmp(clients[i].name, name))) ||
         (net == NET_APP && clients[i].net == NET_APP && name[0] && !strcmp(clients[i].name, name)))) {
      if (strcmp(clients[i].ip, ip)) logf_("guest %s now comes from %s: its old connection closed", clients[i].ip, ip);
      close(clients[i].fd); slot = i; break;
    }
  for (int i = 0; slot < 0 && i < MAX_CLIENTS; i++) if (clients[i].fd < 0) slot = i;
  if (slot < 0) { close(clients[0].fd); slot = 0; }   // full: drop the oldest slot
  clients[slot].fd = c; clients[slot].net = net;
  clients[slot].gestures = gestures != 0; clients[slot].glide = glide != 0;
  snprintf(clients[slot].ip, sizeof clients[slot].ip, "%s", ip);
  snprintf(clients[slot].name, sizeof clients[slot].name, "%s", name);
  logf_("guest connected: %s (gestures %s, scroll momentum %s%s%s%s%s)", ip, gestures ? "on" : "off",
        glide ? "on" : "off", name[0] ? ", VM \"" : "", name, name[0] ? "\"" : "",
        net == NET_APP && strncmp(ip, "127.", 4) ? ", OmacVM.app on its fast network" : "");
  retargetLocked(capturing);
  int front = clients[slot].target;
  pthread_mutex_unlock(&sendLock);
  const char *st = capturing && front ? "on\n" : "off\n";
  char b[96]; int n = snprintf(b, sizeof b, "S %s", st);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
  n = sizeLine(b, sizeof b);   // the Mac's scrolling direction and the trackpad's size
  send(c, b, (size_t)n, MSG_NOSIGNAL);
}

// A guest whose path went away (OmacVM.app moved it to another network, a
// VM that was killed) is noticed in about KA_IDLE + KA_INTVL * KA_CNT seconds,
// not after TCP's minutes: the next send to it fails and drops it.
#define KA_IDLE 5
#define KA_INTVL 2
#define KA_CNT 3
static void keepalive(int c) {
  int on = 1, idle = KA_IDLE, intvl = KA_INTVL, cnt = KA_CNT;
  setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
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
    // OmacVM.app's VMs on its fast network are the app's (its window in
    // front), whichever address they came in on.
    addClient(c, g.net == NET_APP_FAST ? NET_APP : g.net, ip, gestures, glide, name);
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
      keepalive(c);
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

// ---- the trackpads (the built-in one, every Magic Trackpad) and Magic Mice ----
// MultitouchSupport lists every multi-touch surface, the Magic Mouse's too; a
// trackpad is told apart by its size (a Magic Trackpad is 160 x 115 mm, a Magic
// Mouse's surface well under 100 mm wide), a Magic Mouse by its family id or
// HID product (isMagicMouseKind). Looked for again every 10 s, so a Magic
// Trackpad or Magic Mouse connected later (or again) is taken too.
static int trackpadStarted;

// The HID product id of the device behind a multi-touch surface (0: unknown).
static int mtProduct(MTDeviceRef d) {
  io_service_t svc = MTDeviceGetService(d);
  if (!svc) return 0;
  int product = 0;
  CFTypeRef v = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, CFSTR("ProductID"), NULL,
                                                kIORegistryIterateRecursively | kIORegistryIterateParents);
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &product);
  if (v) CFRelease(v);
  return product;
}

// A Magic Mouse not taken yet: 1 if it was added (its frames now come).
static int startMouse(MTDeviceRef d, int w, int h, int family, int product) {
  uint64_t id = 0;
  MTDeviceGetDeviceID(d, &id);
  int slot = -1, known = 0;
  pthread_mutex_lock(&mouseLock);
  for (int k = 0; k < nMice; k++) {
    if (mice[k].id != id) continue;
    // The same mouse connected again comes as a new device: take that one.
    if (mice[k].dev == d || MTDeviceIsRunning(mice[k].dev)) known = 1; else slot = k;
  }
  if (!known && slot < 0 && nMice < MAX_MICE) slot = nMice++;
  if (!known && slot >= 0) {
    mice[slot].dev = d; mice[slot].id = id; mice[slot].sent = 0;
    mice[slot].w = w > 0 ? w : 5150; mice[slot].h = h > 0 ? h : 9050;
    mouseStateInit(&mice[slot].st);
  }
  pthread_mutex_unlock(&mouseLock);
  if (known || slot < 0) return 0;
  MTRegisterContactFrameCallback(d, mouseFrameCb);
  MTDeviceStart(d, 0);
  logf_("Magic Mouse: family %d, product 0x%04x, %d x %d mm (in the VM: two-finger swipe = workspaces, "
        "one-finger flick = back/forward; scrolling as before)", family, product, mice[slot].w / 100, mice[slot].h / 100);
  return 1;
}

static int isTrackpad(MTDeviceRef d, int *w, int *h) {
  if (MTDeviceGetSensorSurfaceDimensions(d, w, h) != 0) *w = *h = 0;
  return MTDeviceIsBuiltIn(d) || *w >= 10000;
}

static void startTrackpads(void) {
  CFArrayRef list = MTDeviceCreateList();
  int added = 0;
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    int w = 0, h = 0;
    uint64_t id = 0;
    if (!isTrackpad(d, &w, &h)) {
      int family = 0;
      if (MTDeviceGetFamilyID(d, &family) != 0) family = 0;
      int product = mtProduct(d);
      if (isMagicMouseKind(MTDeviceIsBuiltIn(d), family, product, w, h)) added += startMouse(d, w, h, family, product);
      continue;
    }
    MTDeviceGetDeviceID(d, &id);
    int slot = -1, known = 0;
    pthread_mutex_lock(&padLock);
    for (int k = 0; k < nPads; k++) {
      if (pads[k].id != id) continue;
      // The same trackpad connected again comes as a new device: take that one.
      if (pads[k].dev == d || MTDeviceIsRunning(pads[k].dev)) known = 1; else slot = k;
    }
    if (!known && slot < 0 && nPads < MAX_PADS) slot = nPads++;
    if (!known && slot >= 0) {
      pads[slot].dev = d; pads[slot].id = id; pads[slot].fingers = 0;
      pads[slot].w = w > 0 ? w : 15600; pads[slot].h = h > 0 ? h : 9600;
      if (activePad < 0 || MTDeviceIsBuiltIn(d)) {
        activePad = slot;
        tpW = pads[slot].w; tpH = pads[slot].h;
      }
    }
    pthread_mutex_unlock(&padLock);
    if (known || slot < 0) continue;
    MTRegisterContactFrameCallback(d, frameCb);
    MTDeviceStart(d, 0);
    added++;
    logf_("trackpad: %s, %d x %d mm (scroll momentum: its scrolling only, never a mouse's)",
          MTDeviceIsBuiltIn(d) ? "built-in" : "Magic Trackpad", pads[slot].w / 100, pads[slot].h / 100);
  }
  // Devices with a callback must stay: keep a list that gave us one.
  if (list && !added) CFRelease(list);
  if (nPads) trackpadStarted = 1;
}

static void retryTrackpad(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  startTrackpads();
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

  tapMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
  int gestureTypes[] = { 18, 19, 20, 29, 30, 31, 32, 34 };   // rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure
  for (size_t i = 0; i < sizeof gestureTypes / sizeof *gestureTypes; i++) tapMask |= (CGEventMask)1 << gestureTypes[i];
  // Needs Accessibility (to drop events) and Input Monitoring (to see the escape
  // combo). Ask once, then wait for the grant instead of exiting, so launchd
  // does not restart us into a loop of prompts.
  CFStringRef keys[] = { kAXTrustedCheckOptionPrompt }; CFTypeRef vals[] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int asked = 0;
  while (!installTap()) {
    if (!asked) {
      logf_("waiting for Accessibility and Input Monitoring permission");
      logPermissions();   // which one is missing
      AXIsProcessTrustedWithOptions(opts);
      CGRequestListenEventAccess();
      asked = 1;
    }
    sleep(3);
  }
  CFRelease(opts);
  if (asked) logf_("permissions granted");
  logPermissions();

  // The trackpad only now, with the permissions granted and the run loop about
  // to run: opened while still waiting, its frames were never taken, and on a
  // MacBook that stalled the built-in keyboard and trackpad (one device) until
  // the user granted Accessibility, which they then could not click.
  if (trackpad) {
    scrollStateInit(&scrollSt);
    startTrackpads();
    // A Mac without a built-in trackpad (Mac mini, iMac, Studio) and no
    // Magic Trackpad connected yet: keys only until one is, instead of
    // exiting into a launchd restart loop. Mice scroll as they are.
    if (!trackpadStarted) logf_("no trackpad found: keys only until a Magic Trackpad connects; mice scroll as they are");
    // Every 10 s: a Magic Trackpad or Magic Mouse connected later, or again.
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0, retryTrackpad, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopCommonModes);
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
  loadSwipeSign();
  readFusionHost();
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) {
    if (!listenAddrs[i][0] && i != NET_FUSION) continue;
    pthread_t th; pthread_create(&th, NULL, serverThread, (void *)(intptr_t)i);
  }
  logf_(trackpad ? "running (escape: Ctrl+Option+Esc)" : "running, keys only: trackpad gestures stay with macOS");
  CFRunLoopRun();
  return 0;
}
