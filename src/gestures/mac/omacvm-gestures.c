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
// dies, the event tap goes with it and macOS gets its gestures back. If
// Accessibility or Input Monitoring is taken away while it runs, it lets go of
// the keyboard and trackpads at once and waits for the permission (#192).
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
//   X <on 2|off>                      Swipe out to macOS on or off (on connect and when it changes).
//                                     "2": this helper takes the swipe itself (below); a guest
//                                     from 3.1.0-3.1.5 reads only "on" and says X left|right
// and from the guest, once the handshake holds:
//   G <n><ways>... | G -              (after "X on 2") which swipes switch workspaces there
//                                     (Hyprland's gestures): "G 4lr" = 4 fingers going left and
//                                     right; a swipe out follows only those counts and ways
//   E <l> <r>                         (after "X on 2") where a swipe of fingers going left and
//                                     right would go now: left|right = out to the macOS Space on
//                                     that side, - = the guest's own workspace swipe; at once and
//                                     on every workspace change. Such a swipe is the Mac's: it is
//                                     held back from the guest until its way is clear and then
//                                     drives macOS's own Space swipe (swipe-take.h)
//   X <left|right>                    (guests from 3.1.0-3.1.5, after "X on") a swipe went past
//                                     its first or last workspace: out to the macOS Space on
//                                     that side in one step (acted on only for the VM in front
//                                     while captured, at most once a second)
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
#include "swipe-take.h"
#include "cursor-rest.h"
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
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
extern int MTDeviceStart(MTDeviceRef, int);   // an IOReturn, 0: started
extern void MTUnregisterContactFrameCallback(MTDeviceRef, MTFrameCallback);
extern void MTDeviceStop(MTDeviceRef);
extern bool MTDeviceIsBuiltIn(MTDeviceRef);
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *, int *);   // 1/100 mm
extern int MTDeviceGetDeviceID(MTDeviceRef, uint64_t *);
extern bool MTDeviceIsRunning(MTDeviceRef);
extern int MTDeviceGetFamilyID(MTDeviceRef, int *);
extern io_service_t MTDeviceGetService(MTDeviceRef);

// The test identity's port and Bridge folder (and settings domain, below) come
// with its bundle id at run time, as the Bridge's do, so a release copy
// relabeled as org.omacvm.test.gestures (src/tests/e2e/relabel.sh) never
// meets the installed Gestures. A build may still name them (build.sh with
// OMACVM_HELPER_TEST=1).
static int testIdentity(void);
#ifndef PORT
#define PORT (testIdentity() ? 47930 : 47830)
#endif
#ifndef BRIDGE_DIR
#define BRIDGE_DIR (testIdentity() ? "omacvm-test-bridge" : "omacvm-bridge")   // the Bridge's token is in ~/Library/Application Support/BRIDGE_DIR
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
static pid_t frontPid;   // the full-screen VM app in front whose pointer we hide (not OmacVM.app's), else 0
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
// edge: where the guest says a swipe of fingers going left [0] and right [1]
// goes now ("E", -1 the macOS Space on the left, +1 on the right, 0 its own
// swipe); edgeKnown: it said so since it connected. ways: which finger counts
// switch workspaces going left [0] / right [1] there (bit n: n fingers; "G",
// Hyprland's gestures); waysKnown: it said so (else any 3 or more).
// focus: where Hyprland's focused output sits on the Mac ("D", the answer to
// the escape combo's "Q"; OmacVM.app's arrangement of the VM's outputs, points
// from its top-left), focusOk: known; focusAt: when it answered (monoNow, 0:
// never); focusSilent: it did not answer in time once (a guest from before
// 3.1.32): not waited for again.
static struct { int fd, net, gestures, glide, target, edge[2], edgeKnown, waysKnown, focusOk, focusSilent; unsigned ways[2], gen;
                double focusAt; CGRect focus; char ip[32], name[256]; } clients[MAX_CLIENTS];
static volatile int frontNet = -1;
static char frontTitle[512];      // the front VM app's window title (Accessibility)
static pthread_mutex_t sendLock = PTHREAD_MUTEX_INITIALIZER;
// A guest's connection is also read (its reader holds a copy of the socket):
// shut down first, so that reader ends too.
static void closeClient(int fd) { shutdown(fd, SHUT_RDWR); close(fd); }
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
// entry: the IORegistry entry of its device (macOS makes a new one for the same
// trackpad at a wake from deep sleep: startTrackpads).
static struct { MTDeviceRef dev; uint64_t id, entry; int w, h, fingers; } pads[MAX_PADS];
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
// take: its swipe as the Mac's (swipe out to macOS); takeAt: the swipe's
// travel on the guest's touchpad at the last frame (trackpad widths).
static struct { MTDeviceRef dev; uint64_t id, entry; int w, h, sent, fingers; MouseState st; SwipeTake take; double takeAt; } mice[MAX_MICE];
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
      closeClient(clients[i].fd); clients[i].fd = -1; dropped = 1;
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

// Swipe out that follows the fingers (below, with the swipe out): what
// becomes of this trackpad frame (TK_*), and the frames held back meanwhile.
static int takePadFrame(MTTouch **c, int k);
static int keepFrame(const char *line, size_t len);
static void takePadPass(void);
static void flushKept(void);
static void dropKept(void);

static int frameCb(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  (void)ts; (void)frame;
  MTTouch *c[16]; int k = 0;
  for (int i = 0; i < n && k < 16; i++) if (touching(&touches[i])) c[k++] = &touches[i];

  // One trackpad at a time: another one's frames count once this one is free.
  pthread_mutex_lock(&padLock);
  int pad = -1;
  for (int i = 0; i < nPads; i++) if (pads[i].dev == dev) pad = i;
  if (pad < 0) { pthread_mutex_unlock(&padLock); return 0; }   // one let go (stopTrackpads)
  pads[pad].fingers = k;
  int switched = 0;
  if (pad != activePad) {
    if (k == 0 || (activePad >= 0 && pads[activePad].fingers > 0)) { pthread_mutex_unlock(&padLock); return 0; }
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

  char buf[1024]; int len = 0;
  if (send) {
    len = snprintf(buf, sizeof buf, "F %d", k);
    for (int i = 0; i < k && len < (int)sizeof buf - 64; i++)
      len += snprintf(buf + len, sizeof buf - (size_t)len, " %d %.5f %.5f %.3f", c[i]->pathIndex,
                      c[i]->normalized.pos.x, 1.0f - c[i]->normalized.pos.y, c[i]->zTotal);
    buf[len++] = '\n';
  }
  // A swipe at the VM's edge may be the Mac's (swipe out to macOS): held
  // back until its way is clear, then the guest's after all, or never.
  switch (takePadFrame(c, k)) {
  case TK_HOLD:
    if (!len || keepFrame(buf, (size_t)len)) return 0;
    takePadPass();   // too many to hold: the guest's after all
    flushKept();
    break;
  case TK_FLUSH:
    flushKept();   // then this frame, as any other
    break;
  case TK_BEGIN: case TK_MOVE: case TK_END: case TK_DROP:
    dropKept();
    if (forwarding) { sendLine("F 0\n", 4); forwarding = 0; }   // a two-finger touch it began as
    return 0;
  default:
    break;
  }

  if (len) {
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
static int takeMouseFrame(SwipeTake *t, int k, double step);
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
  int taken = 0;
  if (act == MOUSE_SWIPE && on) {
    // Four fingers (or three, MouseSwipeFingers) in the middle of the guest's
    // touchpad, moved sideways as the two on the mouse (the guest scales by
    // the trackpad's size, tpW). Four by default: OmacVM's guest swipes
    // workspaces with 3 and 4 fingers, and users who give 3 fingers to
    // something else (window snapping) keep 4 for it. Read when a swipe
    // starts, so a change in the app counts from the next swipe.
    if (!mice[m].sent && mice[m].take.state == TAKE_IDLE) mice[m].fingers = mouseSwipeFingers();
    int nf = mice[m].fingers == 3 ? 3 : 4;
    float scale = MOUSE_SWIPE_GAIN * 100.0f / (float)(tpW > 0 ? tpW : 15600);
    // At the VM's edge it may be the Mac's swipe out (as a trackpad's): its
    // first frame brings the travel that made it a swipe.
    double at = dx * scale, step = mice[m].take.state == TAKE_IDLE ? at + (mice[m].st.ax - mice[m].st.sx) * scale : at - mice[m].takeAt;
    mice[m].takeAt = at;
    int tk = takeMouseFrame(&mice[m].take, nf, step);
    taken = tk != TK_FORWARD && tk != TK_FLUSH;
    float o = dx * scale;
    if (o > 0.35f) o = 0.35f;
    if (o < -0.35f) o = -0.35f;
    if (!taken) {
      len = snprintf(buf, sizeof buf, "F %d", nf);
      for (int i = 0; i < nf; i++)
        len += snprintf(buf + len, sizeof buf - (size_t)len, " %d %.5f %.5f %.3f", MOUSE_FINGER_ID + i,
                        0.5f - 0.05f * (float)(nf - 1) + 0.1f * (float)i + o, 0.5f, 0.5f);
      buf[len++] = '\n';
      mice[m].sent = 1;
    }
    mouseSwipeUntil = monoNow() + MOUSE_SWIPE_HOLD;
  } else if (act == MOUSE_SWIPE_END && (mice[m].sent || mice[m].take.state != TAKE_IDLE)) {
    int tk = takeMouseFrame(&mice[m].take, 0, 0);
    if (mice[m].sent) {
      len = snprintf(buf, sizeof buf, "F 0\n");
      logf_("Magic Mouse: two-finger swipe %s, %.0f mm -> %d-finger swipe in the VM", before >= 0 ? "right" : "left", fabsf(before),
            mice[m].fingers == 3 ? 3 : 4);
    } else if (tk == TK_END) {
      logf_("Magic Mouse: two-finger swipe %s, %.0f mm -> swipe out to macOS", before >= 0 ? "right" : "left", fabsf(before));
    }
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
static int vmNet(pid_t pid, const char *name, int *foreign);
// The app in front is a VM (QEMU) of the other identity's OmacVM app (vmNet):
// to this Gestures any other app; its escape combo is the other one's. Its
// launcher is not: the combo there goes back into this Gestures' VM.
static int frontForeign;

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
// check runs only while a full-screen VM is in front (not OmacVM.app's, whose
// QEMU hides the pointer itself): at 120 Hz while the
// pointer moves; once it has rested a second, every 0.5 s with the rest tap
// armed (its first move wakes the check at once), else at 20 Hz
// (cursor-rest.h).
static CFRunLoopTimerRef captureTimer, cursorTimer;
static void updateCursor(CFRunLoopTimerRef t, void *info);
static void restTapDisarm(void);

static void cursorTimerOn(int on) {
  static int running = -1;
  if (!cursorTimer || on == running) return;
  running = on;
  if (!on) { restTapDisarm(); updateCursor(NULL, NULL); }   // shows the pointer again
  CFRunLoopTimerSetNextFireDate(cursorTimer, CFAbsoluteTimeGetCurrent() + (on ? 0 : 1e9));
}

// ---- the pointer at rest: a tap for its first move instead of a look 20 times a second ----
// Listen-only (it never holds an event), at the session level, only the
// pointer's moves and drags, armed only while the pointer rests over a
// full-screen VM in front: its first event disarms it and wakes the pointer
// check at once. macOS disabling it (a timeout, user input) arms it again.
// It cannot be made (no Input Monitoring) or PointerRestTap is off: the check
// looks 20 times a second at rest, as before. Main thread.
static CFMachPortRef restTap;
static CFRunLoopSourceRef restSource;
static int restArmed, restFailed;
static int restTapSetting(void);

static CGEventRef restTapCb(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *info) {
  (void)proxy; (void)info;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (restArmed && restTap) CGEventTapEnable(restTap, true);
    return e;
  }
  if (restArmed) {
    restArmed = 0;
    CGEventTapEnable(restTap, false);
    if (cursorTimer) CFRunLoopTimerSetNextFireDate(cursorTimer, CFAbsoluteTimeGetCurrent());
  }
  return e;
}

static void restTapRemove(void) {
  restArmed = 0;
  if (!restTap) return;
  CGEventTapEnable(restTap, false);
  CFRunLoopRemoveSource(CFRunLoopGetMain(), restSource, kCFRunLoopCommonModes);
  CFRunLoopSourceInvalidate(restSource);
  CFRelease(restSource);
  CFMachPortInvalidate(restTap);
  CFRelease(restTap);
  restTap = NULL;
  restSource = NULL;
}

static void restTapDisarm(void) {
  if (!restArmed) return;
  restArmed = 0;
  if (restTap) CGEventTapEnable(restTap, false);
}

// Armed now (1), or the 20 Hz look (0).
static int restTapArm(void) {
  if (restArmed && restTap && CGEventTapIsEnabled(restTap)) return 1;
  if (!restTapSetting()) { restTapRemove(); return 0; }
  if (!restTap) {
    CGEventMask m = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                    CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventOtherMouseDragged);
    restTap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionListenOnly, m, restTapCb, NULL);
    restSource = restTap ? CFMachPortCreateRunLoopSource(NULL, restTap, 0) : NULL;
    if (!restSource) {
      if (restTap) { CFMachPortInvalidate(restTap); CFRelease(restTap); restTap = NULL; }
      if (!restFailed) logf_("pointer at rest: no tap for its moves (Input Monitoring?): looking 20 times a second");
      restFailed = 1;
      return 0;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), restSource, kCFRunLoopCommonModes);
    if (restFailed) logf_("pointer at rest: the tap for its moves works again");
    restFailed = 0;
  }
  restArmed = 1;
  CGEventTapEnable(restTap, true);
  if (CGEventTapIsEnabled(restTap)) return 1;
  // Made, but macOS does not let it run (the permission went): as before.
  restTapRemove();
  if (!restFailed) logf_("pointer at rest: the tap for its moves was turned off: looking 20 times a second");
  restFailed = 1;
  return 0;
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
// Never without Accessibility (an active tap needs it; issue #192, below).
#define PERM_AX 1     // Accessibility
#define PERM_IM 2     // Input Monitoring
#define PERM_POST 4   // "control the computer" (CGPreflightPostEventAccess): what macOS checks
                      // before it takes the events an active tap hands back
// AXIsProcessTrusted is answered in the process (about 5 us). The two
// CGPreflight calls ask tccd each time (about 5 ms of tccd's CPU each, M4 Mac
// mini, macOS 27): they are asked off the main thread (refreshSlowPerms) every
// 10 s, when macOS says its Accessibility list changed and when it disabled the
// tap, and their last answer is used in between; never in the tap's thread.
static int slowPermNow(void) {
  return (CGPreflightListenEventAccess() ? PERM_IM : 0) | (CGPreflightPostEventAccess() ? PERM_POST : 0);
}
static int slowPerm;   // main thread: slowPermNow's last answer
static int permNow(void) { return (AXIsProcessTrusted() ? PERM_AX : 0) | slowPerm; }
static int (*permFn)(void) = permNow;
static int tapPerm;       // the permissions the tap was created with (main thread)
// The tap the watchdog guards (below); NULL: none. Under watchLock, so the
// watchdog never touches a tap the main thread has let go of.
static pthread_mutex_t watchLock = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef watchTap;   // under watchLock
static double watchAsked;        // under watchLock: when the main thread was asked to answer (0: it did)
static void watchTapSet(CFMachPortRef t) {
  pthread_mutex_lock(&watchLock); watchTap = t; watchAsked = 0; pthread_mutex_unlock(&watchLock);
}
static int seenPerm;      // every permission a tap of this process was created with

// ---- keyboard sharing apps (#350) ----
// A keyboard sharing app (Synergy, Deskflow, Barrier, Input Leap) taps the
// keys at the head of the HID chain too, and the newest tap runs first: a VM
// started after it took the keys while the pointer was on the other computer.
// OmacVM.app's hidden setting (defaults write org.omacvm.app shareKeyboard
// -bool true; the test identity's app is org.omacvm.app.test) puts this tap,
// QEMU's (OMACVM_KEYS_LAST=1) and the Bridge's at the end of the chain, so
// the sharing app sees keys and scrolls first. Read whenever a tap is made.
// The trackpad's gestures come from MultitouchSupport, not the tap: they
// still go to the VM.
static int testIdentity(void);
#ifndef SHARE_KEYBOARD_DOMAIN
#define SHARE_KEYBOARD_DOMAIN (testIdentity() ? CFSTR("org.omacvm.app.test") : CFSTR("org.omacvm.app"))
#endif
static int shareKeyboard(void) {
  CFStringRef domain = SHARE_KEYBOARD_DOMAIN;
  CFPreferencesAppSynchronize(domain);
  return CFPreferencesGetAppBooleanValue(CFSTR("shareKeyboard"), domain, NULL) ? 1 : 0;   // as the app's UserDefaults.bool
}
static CGEventTapPlacement tapPlace = kCGHeadInsertEventTap;   // the last tap's place (main thread)

static int installTap(void) {
  int perm = permFn();
  if (!(perm & PERM_AX)) return 0;
  // "Control the computer" gone after a tap had it: macOS would not take the
  // events this one hands back either. (Never asked for it otherwise: where
  // macOS answers the preflight differently, Accessibility alone decides.)
  if ((seenPerm & PERM_POST) && !(perm & PERM_POST)) return 0;
  CGEventTapPlacement place = shareKeyboard() ? kCGTailAppendEventTap : kCGHeadInsertEventTap;
  CFMachPortRef newTap = CGEventTapCreate(kCGHIDEventTap, place, kCGEventTapOptionDefault, tapMask, tapCb, NULL);
  if (!newTap) return 0;
  if (place != tapPlace) {
    tapPlace = place;
    logf_("keyboard sharing (shareKeyboard) %s", place == kCGTailAppendEventTap ?
          "on: the event tap at the end of the chain" : "off: the event tap at the head of the chain");
  }
  CFRunLoopSourceRef newSource = CFMachPortCreateRunLoopSource(NULL, newTap, 0);
  if (!newSource) { CFMachPortInvalidate(newTap); CFRelease(newTap); return 0; }
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopAddSource(loop, newSource, kCFRunLoopCommonModes);
  if (tapSource) {
    CFRunLoopRemoveSource(loop, tapSource, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(tapSource);
    CFRelease(tapSource);
  }
  watchTapSet(newTap);
  if (tapPort) { CFMachPortInvalidate(tapPort); CFRelease(tapPort); }
  tapPort = newTap;
  tapSource = newSource;
  tapPerm = perm;
  seenPerm |= perm;
  return 1;
}

// The tap out of the HID chain at once: disabled, its run-loop source and
// its port gone.
static void removeTap(void) {
  if (!tapPort) return;
  watchTapSet(NULL);
  CGEventTapEnable(tapPort, false);
  CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, kCFRunLoopCommonModes);
  CFRunLoopSourceInvalidate(tapSource);
  CFRelease(tapSource);
  CFMachPortInvalidate(tapPort);
  CFRelease(tapPort);
  tapPort = NULL;
  tapSource = NULL;
}

// ---- a permission taken away: let go of all input at once (issue #192) ----
// The tap is an active filter at the head of the HID chain. When the user
// took Accessibility (or Input Monitoring) away in System Settings while it
// ran, macOS kept it in the chain but no longer took the events it handed
// back ("Sender is prohibited from synthesizing events") and disabled it on
// timeout; the helper enabled it again at once (tapCb, and every capture
// check), so every key, click and gesture on the Mac stayed held until the
// helper was killed (the pointer still moved). Now: the tap is enabled or
// created only while Accessibility is granted and every permission it was
// created with still is. When one goes, the tap and its run-loop source are
// removed, the trackpads and Magic Mice stopped (MultitouchSupport) and
// capture is off, before anything else; it all comes back once Accessibility
// is granted again. Looked at every second (Input Monitoring and "control
// the computer" every 10 s, slowPermNow), when macOS says its Accessibility
// list changed, and when macOS disables the tap.
static int inputPaused;   // main thread: no tap, no trackpads until the permission is back
static int permitted(int perm) { return (perm & PERM_AX) && (perm & tapPerm) == tapPerm; }
static void stopTrackpads(void);
static void startTrackpads(void);
static void cursorTimerOn(int on);
static void permissionsSeen(int perm);

// No tap and no trackpads: macOS has the keyboard, clicks and gestures.
static void pauseInput(void) {
  removeTap();
  inputPaused = 1;
  stopTrackpads();
  if (capturing) { capturing = 0; logf_("capture off"); sendState("off"); }
  cursorTimerOn(0);   // the macOS pointer shows again
  restTapRemove();
}

// ---- the tap must never hold the Mac's input (#290, the Bridge's rule) ----
// An active tap at the head of the HID chain holds every event of its kind
// until its callback answers. macOS disables a tap that did not answer in
// time; enabling it again (as before) could bring the hold back over and
// over. Now a disabled tap is removed, never enabled again; a new one comes
// after a hold-off (2 s, then 30 s), and after three in 10 minutes none (and
// no trackpads) until macOS's Accessibility list changes. A watchdog off the
// main thread disables the tap when the main thread (the tap's callback) has
// not answered for a second.
#define TAP_PARK 3
#define TAP_FORGET 600.0
static const double tapHoldOff[TAP_PARK - 1] = { 2, 30 };
static double uptimeNow(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static double (*nowFn)(void) = uptimeNow;
static double tapStrikes[TAP_PARK];   // main thread: when taps were disabled (the last 10 minutes)
static int nStrikes;
static double tapUntil;               // main thread: no new tap before this
static int tapParked;                 // main thread: none until the Accessibility list changes
static int tapMayCreate(void) { return !tapParked && nowFn() >= tapUntil; }
static void rearmTap(const char *why);
static void tapBack(void) { if (!tapPort && tapMayCreate()) rearmTap("hold-off over after macOS disabled it"); }
// A strike at `now`; returns the hold-off in s, or -1: parked.
static double tapStrike(double now) {
  int k = 0;
  for (int i = 0; i < nStrikes; i++) if (now - tapStrikes[i] < TAP_FORGET) tapStrikes[k++] = tapStrikes[i];
  if (k == TAP_PARK) { memmove(tapStrikes, tapStrikes + 1, (TAP_PARK - 1) * sizeof *tapStrikes); k--; }
  tapStrikes[k++] = now;
  nStrikes = k;
  if (k >= TAP_PARK) { tapParked = 1; return -1; }
  tapUntil = now + tapHoldOff[k - 1];
  return tapHoldOff[k - 1];
}
// Main thread: the tap was disabled (by macOS or the watchdog).
static void tapDisabled(const char *by) {
  if (!tapPort) return;
  double h = tapStrike(nowFn());
  if (h < 0) {
    pauseInput();
    logf_("event tap disabled (%s) %d times in 10 minutes: removed, trackpads let go (macOS has the keyboard, "
          "clicks and gestures) until macOS's Accessibility list changes", by, TAP_PARK);
    return;
  }
  removeTap();
  logf_("event tap disabled (%s): removed (never enabled again), a new one in %.0f s", by, h);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(h * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tapBack(); });
}
// macOS's Accessibility list changed: a fresh start (main thread).
static void tapPolicyReset(void) { nStrikes = 0; tapUntil = 0; tapParked = 0; }

// The watchdog's step every 0.25 s: 1 = ask the main thread to answer,
// 2 = it has not answered for longer than a second.
static int watchStep(double now, double *asked) {
  if (*asked == 0) { *asked = now; return 1; }
  return now - *asked > 1.0 ? 2 : 0;
}
static void *tapWatchdog(void *u) {
  (void)u;
  for (;;) {
    usleep(250000);
    pthread_mutex_lock(&watchLock);
    int step = watchTap ? watchStep(uptimeNow(), &watchAsked) : 0;
    if (step == 2) {
      CFMachPortRef t = watchTap;
      watchTap = NULL;   // once: the main thread removes it when it is back
      CGEventTapEnable(t, false);
      int still = CFMachPortIsValid(t) && CGEventTapIsEnabled(t);
      pthread_mutex_unlock(&watchLock);
      logf_("the main thread did not answer for 1 s: event tap disabled (macOS passes every key and click on)");
      if (still) { logf_("the event tap could not be disabled: quitting so it goes (launchd starts Gestures again)"); _exit(75); }
      continue;
    }
    pthread_mutex_unlock(&watchLock);
    if (step == 1) dispatch_async(dispatch_get_main_queue(), ^{
      pthread_mutex_lock(&watchLock); watchAsked = 0; pthread_mutex_unlock(&watchLock);
    });
  }
  return NULL;
}

static void checkPermissions(void) {
  if (tapPort && !inputPaused) {
    int perm = permFn();
    if (permitted(perm)) return;
    pauseInput();
    permissionsSeen(perm);
    logf_("permission taken away: event tap removed, trackpads let go (macOS has the keyboard, clicks and "
          "gestures); waiting for Accessibility");
  } else if (inputPaused && !tapParked && installTap()) {
    inputPaused = 0;
    permissionsSeen(tapPerm);
    if (trackpad) startTrackpads();
    logf_("event tap and trackpads on again");
  }
}

// Input Monitoring and "control the computer" asked off the main thread
// (slowPermNow), then looked at on it. Main thread.
static void refreshSlowPerms(void) {
  static int asking;
  if (asking) return;
  asking = 1;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    int p = slowPermNow();
    dispatch_async(dispatch_get_main_queue(), ^{ asking = 0; slowPerm = p; checkPermissions(); });
  });
}

static void permissionTimer(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  static int ticks;
  checkPermissions();
  // Every 10 s; every second while only one of those two keeps the tap away.
  if (++ticks % 10 == 0 || (inputPaused && (permFn() & PERM_AX))) refreshSlowPerms();
}
static int waiting;              // main thread: still waiting for the permissions at start (waitLook)
static void waitLook(void);
// macOS's Accessibility list changed: look now, and once more when it has settled.
static void accessibilityChanged(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef info) {
  (void)c; (void)o; (void)n; (void)obj; (void)info;
  if (waiting) {
    waitLook();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ waitLook(); });
    return;
  }
  tapPolicyReset();
  checkPermissions();
  refreshSlowPerms();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    checkPermissions();
    refreshSlowPerms();
  });
}

// Main thread only. A failed re-creation keeps the old tap while the
// permissions are there (logged once until one works again), never without.
static void rearmTap(const char *why) {
  static int failedLogged;
  if (inputPaused) return;   // checkPermissions brings it back
  if (!tapMayCreate()) return;   // after macOS disabled one: tapBack, or the Accessibility list
  if (installTap()) {
    logf_("event tap created again (%s)", why);
    failedLogged = 0;
  } else if (!permitted(permFn())) {
    checkPermissions();   // the old one goes too
  } else if (!failedLogged) {
    logf_("cannot create the event tap again (%s); keeping the old one", why);
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
  // OmacVM.app's QEMU hides the Mac's pointer over its VM itself (Omanotch
  // leaves it alone too, #260): a second hider here showed it again in the
  // background over QEMU's hide, and the Mac's arrow sat over the VM's own
  // pointer until the user switched out and back (2026-10-19).
  frontPid = front && net != NET_APP ? pid : 0;
  cursorTimerOn(frontPid && !inputPaused);
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  // No capture without the tap and trackpads (a permission taken away).
  int now = front && !escaped && !inputPaused;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    if (rec) fprintf(rec, "C\t%.4f\t%d\n", unixNow(), now);
    sendState(now ? "on" : (front && !inputPaused ? "esc" : "off"));
  }
  // Invalidated or disabled (by macOS or the watchdog): without the
  // permissions it goes (#192); a disabled one is removed, never enabled
  // again (#290).
  if (tapPort && (!CFMachPortIsValid(tapPort) || !CGEventTapIsEnabled(tapPort))) {
    if (!permitted(permFn())) checkPermissions();
    else if (!CFMachPortIsValid(tapPort)) rearmTap("macOS invalidated it");
    else tapDisabled("found disabled");
  }
}

// Its two permissions, logged at start and whenever one changes (looked at
// every 10 s at most); omacvm check reads the last line. A missing one is
// named, not just "waiting".
static void permissionsSeen(int perm) {
  static int last = -1;
  if (perm == last) return;
  last = perm;
  logf_("permissions: Accessibility %s, Input Monitoring %s", perm & PERM_AX ? "granted" : "MISSING",
        perm & PERM_IM ? "granted" : "MISSING");
}
// ---- permission entries macOS kept for another build (#306) ----
// macOS keeps each permission as an entry tied to the code signature of the
// build that asked. One from another signature (a helper built on this Mac,
// before OmacVM.app's signed copy) no longer matches: System Settings shows
// OmacVM Gestures as on, tccd refuses ("Failed to match existing code
// requirement"), and switching it off and on again does not replace it
// (brianmerchant, 3.0.9 on macOS 15.8: waiting for permissions for good,
// fixed only by tccutil reset). The app's own keyboard entry had the same
// (#255). So once per build, when a permission is missing at start, the
// helper clears its own entry for it (tccutil, no admin password needed)
// before it asks: a stale entry goes, and macOS asks again. A permission it
// has is never touched.
extern char **environ;
static int tccReset(const char *service, const char *id) {
  const char *argv[] = { "/usr/bin/tccutil", "reset", service, id, NULL };
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  pid_t pid;
  int rc = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  if (rc) return 0;
  int st = 0;
  while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
  return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}
static int (*tccResetFn)(const char *service, const char *id) = tccReset;

// perm: what macOS answers now; id: this helper's bundle identifier; stamp:
// the file that keeps which build already did this; build: that build's key.
// Returns how many entries were cleared.
static int clearOldGrants(int perm, const char *id, const char *stamp, const char *build) {
  if (!id || !*id || !stamp || !build || (perm & (PERM_AX | PERM_IM)) == (PERM_AX | PERM_IM)) return 0;
  char was[128] = "";
  FILE *f = fopen(stamp, "r");
  if (f) { if (!fgets(was, sizeof was, f)) was[0] = 0; fclose(f); }
  was[strcspn(was, "\n")] = 0;
  if (!strcmp(was, build)) return 0;
  int n = 0;
  if (!(perm & PERM_AX)) {
    n += tccResetFn("Accessibility", id);
    n += tccResetFn("PostEvent", id);   // "control the computer", its own entry (#255)
  }
  if (!(perm & PERM_IM)) n += tccResetFn("ListenEvent", id);
  f = fopen(stamp, "w");
  if (f) { fprintf(f, "%s\n", build); fclose(f); }
  logf_("cleared what macOS kept of %s's %s%s%s for an older build, so it can ask again (once per build)", id,
        perm & PERM_AX ? "" : "Accessibility", (perm & (PERM_AX | PERM_IM)) ? "" : " and ", perm & PERM_IM ? "" : "Input Monitoring");
  return n;
}

// This build: the executable's size and time (a new build is a new file).
static void buildKey(char *out, size_t cap) {
  char path[4096]; uint32_t len = sizeof path;
  struct stat st;
  if (_NSGetExecutablePath(path, &len) || stat(path, &st)) { snprintf(out, cap, "?"); return; }
  snprintf(out, cap, "%lld-%ld", (long long)st.st_size, (long)st.st_mtimespec.tv_sec);
}

static void clearOldGrantsOnce(int perm) {
  CFStringRef cid = CFBundleGetIdentifier(CFBundleGetMainBundle());
  char id[256], stamp[1024], build[64];
  const char *home = getenv("HOME");
  if (!cid || !home || !CFStringGetCString(cid, id, sizeof id, kCFStringEncodingUTF8)) return;   // not the app (a test)
  snprintf(stamp, sizeof stamp, "%s/Library/Application Support/omacvm", home);
  mkdir(stamp, 0755);
  snprintf(stamp, sizeof stamp, "%s/Library/Application Support/omacvm/%s.tcc-cleared", home, id);
  buildKey(build, sizeof build);
  clearOldGrants(perm, id, stamp, build);
}

// ---- the wait for the permissions at start (#330) ----
// The helper listens only once it may make its event tap. It used to wait in
// a sleep loop before the run loop ran: AXIsProcessTrusted is answered from
// the process's own copy, which macOS updates through the run loop, so a grant
// given while it waited was never seen (brianmerchant, 3.0.13: Accessibility
// on in System Settings, the helper still waiting, nothing on 47830). Now it
// waits on the run loop: every 3 s, and at once when macOS says its
// Accessibility list changed. In case macOS still tells only a new process,
// every third look asks a new copy of itself (--permissions, the same
// identity, nothing cached); when that one may and this one may not, it
// starts again, once (relaunchOnce).

// --permissions: what a new process gets from macOS (PERM_AX | PERM_IM).
static int permissionsChild(void) {
  printf("%d\n", (AXIsProcessTrusted() ? PERM_AX : 0) | (CGPreflightListenEventAccess() ? PERM_IM : 0));
  fflush(stdout);
  return 0;
}

// Asks a new copy of this helper (-1: could not).
static int freshPerm(void) {
  char path[4096]; uint32_t len = sizeof path;
  if (_NSGetExecutablePath(path, &len)) return -1;
  int fds[2];
  if (pipe(fds)) return -1;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
  posix_spawn_file_actions_addclose(&fa, fds[0]);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  char *argv[] = { path, "--permissions", NULL };
  pid_t pid;
  int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  close(fds[1]);
  if (rc) { close(fds[0]); return -1; }
  char buf[16] = ""; ssize_t n, got = 0;
  while (got < (ssize_t)sizeof buf - 1 && (n = read(fds[0], buf + got, sizeof buf - 1 - got)) != 0) {
    if (n < 0) { if (errno == EINTR) continue; break; }
    got += n;
  }
  close(fds[0]);
  int st = 0;
  while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
  if (!WIFEXITED(st) || WEXITSTATUS(st) || got <= 0 || buf[0] < '0' || buf[0] > '3') return -1;
  return buf[0] - '0';
}
static int (*freshPermFn)(void) = freshPerm;

// Once: the stamp keeps the build and when it started again; again only for
// another build or after an hour (a person may take a permission away and
// give it again later). Returns 1 and writes the stamp when it may.
static int mayRelaunch(const char *stamp, const char *build, time_t now) {
  char was[128] = "", wasBuild[128] = "";
  long long at = 0;
  FILE *f = fopen(stamp, "r");
  if (f) { if (!fgets(was, sizeof was, f)) was[0] = 0; fclose(f); }
  if (sscanf(was, "%127s %lld", wasBuild, &at) == 2 && !strcmp(wasBuild, build) && now - at < 3600) return 0;
  f = fopen(stamp, "w");
  if (!f) return 0;   // no stamp, no restart: never a loop
  fprintf(f, "%s %lld\n", build, (long long)now);
  fclose(f);
  return 1;
}

// How it starts again: its LaunchAgent (launchd names the job by its label,
// the bundle id: XPC_SERVICE_NAME; KeepAlive starts it again when it exits)
// or, started by macOS or with open ("application.<id>..."), a new copy
// through open. 0: neither (a test, a shell).
#define RELAUNCH_LAUNCHD 'l'
#define RELAUNCH_OPEN 'o'
static int relaunchHow(const char *service, const char *id, const char *bundle) {
  if (!service || !id || !*id) return 0;
  if (!strcmp(service, id)) return RELAUNCH_LAUNCHD;
  size_t n = bundle ? strlen(bundle) : 0;
  char app[300];
  snprintf(app, sizeof app, "application.%s.", id);
  if (!strncmp(service, app, strlen(app)) && n > 4 && !strcmp(bundle + n - 4, ".app")) return RELAUNCH_OPEN;
  return 0;
}

static int helperArgc;
static char **helperArgv;
static void relaunchOnce(void) {
  CFStringRef cid = CFBundleGetIdentifier(CFBundleGetMainBundle());
  CFURLRef url = CFBundleCopyBundleURL(CFBundleGetMainBundle());
  char id[256] = "", bundle[2048] = "", stamp[1024], build[64];
  const char *home = getenv("HOME");
  if (cid) CFStringGetCString(cid, id, sizeof id, kCFStringEncodingUTF8);
  if (url) { CFURLGetFileSystemRepresentation(url, true, (UInt8 *)bundle, sizeof bundle); CFRelease(url); }
  int how = relaunchHow(getenv("XPC_SERVICE_NAME"), id, bundle);
  if (!home || !how) return;
  snprintf(stamp, sizeof stamp, "%s/Library/Application Support/omacvm/%s.relaunched", home, id);
  buildKey(build, sizeof build);
  if (!mayRelaunch(stamp, build, time(NULL))) return;
  if (how == RELAUNCH_LAUNCHD) {
    logf_("macOS gives the permissions only to a new process: starting again (its LaunchAgent, once)");
    exit(75);
  }
  const char *argv[64] = { "/usr/bin/open", "-n", "-g", bundle };
  int n = 4;
  if (helperArgc > 1) argv[n++] = "--args";
  for (int i = 1; i < helperArgc && n < 63; i++) argv[n++] = helperArgv[i];
  argv[n] = NULL;
  pid_t pid;
  if (posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ)) return;
  int st = 0;
  while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
  if (!WIFEXITED(st) || WEXITSTATUS(st)) return;
  logf_("macOS gives the permissions only to a new process: started a new copy (once)");
  exit(0);
}

static void logPermissions(void) {
  static CFAbsoluteTime at;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (at > 0 && now - at < 10) return;
  at = now;
  permissionsSeen(permFn());
}

static void swipeOutLook(void);
static void takeLook(void);
static void replayLook(void);
static int takeOn(void);
static void updateCapture(CFRunLoopTimerRef t, void *info) {
  (void)info;
  logPermissions();
  swipeOutLook();
  // While a swipe out is the Mac's, macOS's own Space move shows other
  // windows and apps: the capture stays as it is until it is over.
  if (takeOn()) {
    if (t) CFRunLoopTimerSetNextFireDate(t, CFAbsoluteTimeGetCurrent() + 0.2);
    return;
  }
  ProcessSerialNumber psn; pid_t pid = 0; char name[64] = "";
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, name, sizeof name);
  int net = vmNet(pid, name, &frontForeign);
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
  takeLook();   // where a swipe out would go (only while it may)
  replayLook();
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
// it is the front VM's full-screen window (Parallels, UTM, VMware Fusion; not
// OmacVM.app's, see frontChanged). A background process may only
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
  pid_t pid = inputPaused ? 0 : frontPid;
  if (!cursorControl || !pid) { setCursorHidden(0); last.x = -1; return; }
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(e);
  CFRelease(e);
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  int moved = p.x != last.x || p.y != last.y;
  if (moved) { lastMove = now; restTapDisarm(); }
  // At rest: the next look in 0.5 s with the rest tap armed, else in 50 ms
  // (the timer goes back to 120 Hz by itself after the first look that sees
  // it move; the tap's first event brings that look at once).
  double next = cursorNextLook(now - lastMove, now - lastMove > CURSOR_REST_AFTER && t ? restTapArm() : 0);
  if (t && next > 0) CFRunLoopTimerSetNextFireDate(t, now + next);
  // The window list only when the pointer moved, and every half second for
  // windows that appear under a pointer at rest (the Dock, a notification).
  if (!moved && now - lastCheck < CURSOR_WINDOWS_EVERY) return;
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
// information -> one log line, nothing else: no notice in Omarchy (user,
// 2026-10-12: "never a notice"), never Mission Control from one press (user,
// 2026-10-06: "never"; only twice in a row, see missionControl). Back in:
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

// ---- whose VM: this identity's app or the other one's ----
// OmacVM.app (org.omacvm.app) and the test identity's OmacVM Test.app
// (org.omacvm.app.test, its own Gestures org.omacvm.test.gestures on 47930)
// can run on one Mac. Both run their VMs (and launchers) as processes named
// OmacVM, so each Gestures took every OmacVM VM as its own: it captured the
// trackpad, re-armed its tap and acted on the escape combo for the other
// app's VM too (the Bridge had the same, #146). Each Gestures now takes only
// its own app's VMs, told by the process's code signature as the kernel
// holds it (build-app.sh signs the launcher as the app's bundle id and its
// QEMU as "<id>.qemu"): no file is read, so the capture check and the event
// tap never wait on a disk. A process without an OmacVM signature (a
// development build's QEMU) stays every Gestures', as before.
#define APP_ID "org.omacvm.app"
#define TEST_APP_ID "org.omacvm.app.test"

// The test identity's Gestures: built so (build.sh with OMACVM_HELPER_TEST=1,
// like its port and settings domain), or running as its bundle
// (org.omacvm.test.gestures). -1: not looked yet; tests set it.
#ifndef GESTURES_TEST_IDENTITY
#define GESTURES_TEST_IDENTITY 0
#endif
static int identityTest = GESTURES_TEST_IDENTITY ? 1 : -1;
static int testIdentity(void) {
  if (identityTest < 0) {
    CFBundleRef b = CFBundleGetMainBundle();
    CFStringRef id = b ? CFBundleGetIdentifier(b) : NULL;
    identityTest = id && CFStringCompare(id, CFSTR("org.omacvm.test.gestures"), 0) == kCFCompareEqualTo;
  }
  return identityTest;
}

// Started by macOS itself (System Settings' "Quit & Reopen" after a grant, or
// Finder) instead of its LaunchAgent, its output goes to /dev/null, and
// omacvm check would read only the log of the process before (#331). Then it
// writes to its log itself.
static void logToFile(void) {
  struct stat out, null;
  if (fstat(1, &out) == 0 && (stat("/dev/null", &null) != 0 || !S_ISCHR(out.st_mode) || out.st_rdev != null.st_rdev))
    return;   // a file, a pipe or a terminal: as started
  const char *home = getenv("HOME");
  if (!home) return;
  char path[1024];
  snprintf(path, sizeof path, "%s/Library/Logs/%s.log", home,
           testIdentity() ? "omacvm-test-gestures" : "omacvm-gestures");
  int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd < 0) return;
  dup2(fd, 1); dup2(fd, 2);
  if (fd > 2) close(fd);
}

// The code-signing identifier of a running process (the kernel's copy).
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_IDENTITY 11
static int signingID(pid_t pid, char *out, size_t cap) {
  struct { uint32_t magic, length; char id[256]; } b;
  memset(&b, 0, sizeof b);
  if (pid <= 0 || csops(pid, CS_OPS_IDENTITY, &b, sizeof b) != 0) return 0;
  b.id[sizeof b.id - 1] = 0;
  snprintf(out, cap, "%s", b.id);
  return out[0] != 0;
}

// Whether a process signed as `ident` (NULL: unknown) is this Gestures'.
// An OmacVM.app launcher or QEMU ("<bundle id>" or "<bundle id>.qemu",
// bundle id org.omacvm.app or org.omacvm.app.*): the test Gestures takes
// OmacVM Test.app's (org.omacvm.app.test, and a lane's copy re-signed as
// org.omacvm.app.test.<lane>, as the app's own TestIdentity.isTest), every
// other Gestures all the others. Anything else (no OmacVM signature, or one
// that macOS no longer holds valid): every Gestures', as before.
static int vmOursRule(const char *ident, int test) {
  if (!ident || (strcmp(ident, APP_ID) && strncmp(ident, APP_ID ".", strlen(APP_ID ".")))) return 1;
  int isTest = !strcmp(ident, TEST_APP_ID) || !strncmp(ident, TEST_APP_ID ".", strlen(TEST_APP_ID "."));
  return isTest == !!test;
}

static int endsWith(const char *s, const char *end) {
  size_t a = strlen(s), b = strlen(end);
  return a >= b && !strcmp(s + a - b, end);
}

// Which VM app a front process `name` (its executable `exe` and signing
// identifier `ident`, NULL if unknown) is: Parallels' VM window, UTM's,
// VMware Fusion's, or this identity's OmacVM app (-1: none of them).
// *foreign: a VM (QEMU, not the launcher) of the other identity's OmacVM app.
static int vmNetOf(const char *name, const char *exe, const char *ident, int *foreign) {
  *foreign = 0;
  if (!strcmp(name, "prl_client_app")) return 0;
  if (!strcmp(name, "UTM")) return NET_UTM;
  if (!strcmp(name, "VMware Fusion")) return listenAddrs[NET_FUSION][0] ? NET_FUSION : -1;
  if (strcmp(name, "OmacVM")) return -1;
  if (vmOursRule(ident, testIdentity())) return NET_APP;
  // Its QEMU ("<id>.qemu", or not the launcher's path), not its launcher.
  *foreign = endsWith(ident, ".qemu") || (exe && !strstr(exe, "/Contents/MacOS/"));
  return -1;
}

static int vmNet(pid_t pid, const char *name, int *foreign) {
  if (strcmp(name, "OmacVM")) return vmNetOf(name, NULL, NULL, foreign);   // no system calls for other apps
  char exe[PROC_PIDPATHINFO_MAXSIZE], ident[256];
  int haveExe = proc_pidpath(pid, exe, sizeof exe) > 0;
  return vmNetOf(name, haveExe ? exe : NULL, signingID(pid, ident, sizeof ident) ? ident : NULL, foreign);
}

// This identity's OmacVM.app QEMU (Contents/Resources/runtime/bin/OmacVM, or
// a plain qemu-system-aarch64), not its launcher (Contents/MacOS/OmacVM).
// Two system calls, no file read: also asked in the event tap.
static int isQemu(pid_t pid) {
  char path[PROC_PIDPATHINFO_MAXSIZE], ident[256];
  if (proc_pidpath(pid, path, sizeof path) <= 0) return 0;
  return !strstr(path, "/Contents/MacOS/") && vmOursRule(signingID(pid, ident, sizeof ident) ? ident : NULL, testIdentity());
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
// the settings domain for the next start. macOS 26 and older only (the
// fields); the escape combo's Dock swipe and the swipe out that follows the
// fingers both use it (a MacBook Pro on macOS 15.7 learned -1, 2026-10-17).
static int swipeSign = 1;

// ---- the Dock's swipe: what a trackpad's three/four-finger swipe gives the Dock ----
// macOS 27 reads it from an IOHIDEvent attached to the event (private,
// IOKit + SkyLight, looked up at run time; Mac Mouse Fix found the same,
// TouchSimulator.m); the event's fields, which older macOS reads, are
// ignored there (the mini, 2026-10-13). progress: in the Dock's units,
// negative toward the Space on the right (one Space = 1 + 1 / (n - 1) for
// a display with n Spaces); the end's speed in the same units per second.
// Ended finishes the move, Cancelled goes back: the trackpad's own swipe
// decides that at the lift, so do we (swipe-take.h).
#define kSwipeChanged 2
#define kSwipeCancelled 8
#define HID_DOCK_SWIPE 23
#define HID_VELOCITY 9
#define HID_FIELD(type, i) ((uint32_t)(type) << 16 | (uint32_t)(i))
#define HID_PHASE_SHIFT 24
#define HID_FLAVOR_DOCK 3
typedef const void *HIDEventRef;
static HIDEventRef (*hidCreate)(CFAllocatorRef, uint32_t, uint64_t, uint32_t);
static void (*hidSetInt)(HIDEventRef, uint32_t, CFIndex);
static void (*hidSetFloat)(HIDEventRef, uint32_t, double);
static void (*hidAppend)(HIDEventRef, HIDEventRef, uint32_t);
static void (*hidAttach)(CGEventRef, HIDEventRef);

static int lookUpHID(void) {
  static int looked, ok;
  if (!looked) {
    looked = 1;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    hidCreate = (HIDEventRef (*)(CFAllocatorRef, uint32_t, uint64_t, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventCreate");
    hidSetInt = (void (*)(HIDEventRef, uint32_t, CFIndex))dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    hidSetFloat = (void (*)(HIDEventRef, uint32_t, double))dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    hidAppend = (void (*)(HIDEventRef, HIDEventRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    hidAttach = (void (*)(CGEventRef, HIDEventRef))dlsym(RTLD_DEFAULT, "SLEventSetIOHIDEvent");
    ok = hidCreate && hidSetInt && hidSetFloat && hidAppend && hidAttach;
    if (!ok) logf_("swipe out: macOS gives no way to post the Dock's swipe here (IOHIDEvent): one step at the lift");
  }
  return ok;
}

// The swipe as macOS 27 and newer read it (else the fields).
static int hidSwipeOS(void) {
  static int v = -1;
  if (v < 0) { v = 0; if (__builtin_available(macOS 27.0, *)) v = 1; }
  return v;
}
static int (*hidSwipeFn)(void) = hidSwipeOS;

// One event of the Dock's swipe; *extra: a second one to post right after it
// (the gesture event the fields need), or NULL. NULL: none could be made.
static CGEventRef dockSwipeEvent(int asHID, int phase, double progress, double speed, CGPoint at, CGEventRef *extra) {
  *extra = NULL;
  int end = phase == kSwipeEnded || phase == kSwipeCancelled;
  if (asHID) {
    if (!lookUpHID()) return NULL;
    uint64_t now = mach_absolute_time();
    HIDEventRef h = hidCreate(kCFAllocatorDefault, HID_DOCK_SWIPE, now, (uint32_t)phase << HID_PHASE_SHIFT);
    if (!h) return NULL;
    hidSetInt(h, HID_FIELD(HID_DOCK_SWIPE, 1), 1);                 // motion: horizontal
    hidSetInt(h, HID_FIELD(HID_DOCK_SWIPE, 5), HID_FLAVOR_DOCK);   // flavor: the Dock's
    hidSetFloat(h, HID_FIELD(HID_DOCK_SWIPE, 2), progress);
    if (end) {
      HIDEventRef v = hidCreate(kCFAllocatorDefault, HID_VELOCITY, now, 0);
      if (v) {
        hidSetFloat(v, HID_FIELD(HID_VELOCITY, 0), speed);
        hidSetFloat(v, HID_FIELD(HID_VELOCITY, 1), speed);
        hidSetFloat(v, HID_FIELD(HID_VELOCITY, 2), 0);
        hidAppend(h, v, 0);
        CFRelease(v);
      }
    }
    CGEventRef e = CGEventCreate(NULL);
    if (e) {
      CGEventSetType(e, (CGEventType)kCGSEventDockControl);
      CGEventSetLocation(e, at);
      hidAttach(e, h);
    }
    CFRelease(h);
    return e;
  }
  CGEventRef dock = CGEventCreate(NULL), gesture = CGEventCreate(NULL);
  if (!dock || !gesture) {
    if (dock) CFRelease(dock);
    if (gesture) CFRelease(gesture);
    return NULL;
  }
  float f = (float)progress; uint32_t bits; memcpy(&bits, &f, sizeof bits);
  CGEventSetIntegerValueField(gesture, kCGSEventTypeField, kCGSEventGesture);
  CGEventSetIntegerValueField(dock, kCGSEventTypeField, kCGSEventDockControl);
  CGEventSetIntegerValueField(dock, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
  CGEventSetIntegerValueField(dock, kCGEventGesturePhase, phase);
  CGEventSetIntegerValueField(dock, 134, phase);                    // the phase again, as a trackpad's
  CGEventSetDoubleValueField(dock, kCGEventGestureSwipeProgress, progress);
  CGEventSetIntegerValueField(dock, kCGEventScrollGestureFlagBits, (int64_t)bits);   // the progress as a float's bits
  CGEventSetIntegerValueField(dock, kCGEventGestureSwipeMotion, 1);  // horizontal
  CGEventSetIntegerValueField(dock, 165, 1);
  CGEventSetDoubleValueField(dock, kCGEventGestureScrollY, 1.401298464e-45);    // FLT_TRUE_MIN: horizontal
  CGEventSetDoubleValueField(dock, kCGEventGestureZoomDeltaX, 1.401298464e-45);
  if (end) {
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityX, speed);
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityY, speed);
  }
  CGEventSetLocation(dock, at);
  CGEventSetLocation(gesture, at);
  *extra = gesture;
  return dock;
}

static int dockPost(int phase, double progress, double speed, CGPoint at) {
  CGEventRef extra, e = dockSwipeEvent(hidSwipeFn(), phase, progress, speed, at, &extra);
  if (!e) return 0;
  CGEventPost(kCGSessionEventTap, e);   // after the HID taps (ours, QEMU's): they never see it
  CFRelease(e);
  if (extra) { CGEventPost(kCGSessionEventTap, extra); CFRelease(extra); }
  return 1;
}

static int (*dockPostFn)(int, double, double, CGPoint) = dockPost;   // a seam for the offline test

static int dockSwipe(CGPoint at, int phase, int right) {
  if (hidSwipeFn()) {
    // macOS 27 reads only the HID event: a short way toward that Space,
    // then finished (Ended always finishes; the way's sign is known there).
    double s = right ? -1.0 : 1.0;
    if (phase == kSwipeBegan) return dockPostFn(kSwipeBegan, s * 0.05, 0, at) && dockPostFn(kSwipeChanged, s * 0.2, 0, at);
    return dockPostFn(kSwipeEnded, s * 0.2, s * 2.0, at);
  }
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
  int right = hidSwipeFn() ? dir > 0 : dir * swipeSign > 0;   // the HID event's way is known
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

// Every normal window of pid on any Space (layer 0, bigger than 100 x 100):
// OmacVM.app's VM has one per display in full screen.
static int allWindowsOf(pid_t pid, CGWindowID *out, int cap) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  int k = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && k < cap; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r; CGWindowID id = 0;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, &id);
    if (owner == pid && layer == 0 && id && CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) &&
        r.size.width > 100 && r.size.height > 100)
      out[k++] = id;
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

// The test identity has its own domain, port and Bridge folder (from its
// bundle id at run time, or built so: build.sh with OMACVM_HELPER_TEST=1), so
// it never meets the installed Gestures, and takes only OmacVM Test.app's VMs.
#ifndef GESTURES_DOMAIN
#define GESTURES_DOMAIN (testIdentity() ? CFSTR("org.omacvm.test.gestures") : CFSTR("org.omacvm.gestures"))
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

// "SwipeOut" (OmacVM.app's "Swipe out to macOS", off by default; defaults
// write org.omacvm.gestures SwipeOut -bool true): a swipe past the VM's first
// or last workspace goes on to the macOS Space beside the VM's (#342). A
// bool, a number or "yes"/"true", as CFPreferences reads a bool.
// "PointerRestTap" (hidden, on by default; defaults write org.omacvm.gestures
// PointerRestTap -bool false goes back): the pointer at rest wakes the
// pointer check through a tap for its moves instead of a look 20 times a
// second (cursor-rest.h). Read when the pointer comes to rest.
static int restTapSetting(void) {
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  Boolean valid = false;
  int on = CFPreferencesGetAppBooleanValue(CFSTR("PointerRestTap"), GESTURES_DOMAIN, &valid);
  return !valid || on;
}

static int swipeOutSetting(void) {
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  Boolean valid = false;
  int on = CFPreferencesGetAppBooleanValue(CFSTR("SwipeOut"), GESTURES_DOMAIN, &valid);
  return valid && on;
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
static int (*vmAllWindowsFn)(pid_t, CGWindowID *, int) = allWindowsOf;
static pid_t (*topAppFn)(CGRect, pid_t, CGWindowID *) = topAppOn;
static int (*hideFn)(pid_t) = ns_hide;   // a VM in a window only
static int (*escapeAllFn)(void) = escapeAll;
static void (*saveSignFn)(void) = saveSwipeSign;
static CFDictionaryRef (*hotkeysFn)(void) = readHotkeys;
static int (*keyFn)(Hotkey) = postHotkey;
static CGEventFlags (*heldFn)(void) = heldNow;
static int (*missionControlOpenFn)(void) = missionControlOpen;
static int (*swipeOutFn)(void) = swipeOutSetting;
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

// The last move out was for this point (the VM's focused display), not for
// the pointer's: the keyboard follows that display.
static CGPoint leavePoint;
static int leaveByFocus;

// Still in the VM: it has the keyboard, or the display the combo moved (the
// pointer's) still shows its full-screen window.
static const char *stillIn(void) {
  if (frontFn() == vmPid) return "it has the keyboard";
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = leaveByFocus ? leavePoint : pointerFn();
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
  CGPoint p = leaveByFocus ? leavePoint : pointerFn();   // the display the combo moved
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
static int leaveWaiting;             // a move out waits for the combo's keys to come up (nothing posted yet)
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
// log line, nothing else. No notice in Omarchy (user, 2026-10-12: "never a
// notice"; up to 3.0.18 the guest got "N <why>"), never Mission Control
// (user, 2026-10-06: "never"). The trackpad and keys stay macOS's, as after
// any escape; the combo again takes them back.
static void noWayOut(const char *why) {
  logf_("escape combo: %s: nothing done", why);
}

// ---- the moves of the last press: per display, from its Space to the one beside it ----
typedef struct { CGDirectDisplayID id; CGRect b; uint64_t from, to; int dir, done; } Move;
enum { BY_SHORTCUT, BY_DOCK };
static Move moves[MAX_DISPLAYS];
static int nMoves, leaving, signRetried, learnedNow, shortcutOff;
static CGWindowID enterWin;   // back in: the VM's window on the pointer's display (activated when no move lands)

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

// Every move not done yet, one way. Returns how many were made. The displays
// the pointer is not on go first, the pointer's last: once a display's Space
// changes, OmacVM.app's QEMU puts the Mac's cursor back where the guest's
// pointer is, so a later visit to another display ended on the pointer's
// display again and that display's key did nothing (the mini, two displays,
// "all": the second display stayed on the VM, or out of it, 2026-10-24).
static int runMoves(int by, const char *what) {
  int made = 0;
  if (movesCancelled) return 0;
  CGPoint at = pointerFn();
  for (int pass = 0; pass < 2; pass++) {
    for (int i = 0; i < nMoves; i++) {
      Move *m = &moves[i];
      if (m->done || CGRectContainsPoint(m->b, at) != (pass == 1)) continue;
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
  if (shortcutOff) noWayOut("macOS's \"Move left/right a space\" shortcut is off and the swipe did not move");
  else noWayOut("the Space did not change");
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
    goTo(vmPid, enterWin ? enterWin : vmWin, "back into the VM:", NULL);
    return;
  }
  // The keyboard to the VM now on the pointer's display (a full-screen Space
  // usually brings its app), through its window there: the main window on
  // another display would bring that display back into the VM too.
  if (frontFn() != vmPid) goTo(vmPid, enterWin ? enterWin : vmWin, "keyboard to the VM:", NULL);
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

// ---- which display is "focused": the VM's own focus, else the pointer ----
// OmacVM.app's VM in full screen on two or more displays is one Hyprland with
// an output per display. Omarchy turns Hyprland's pointer warps off, so a
// workspace or focus change from the keyboard leaves the Mac's pointer on the
// other display, and the combo moved that display: the one being worked on
// stayed on the VM and had to be swiped out by hand. So the combo ("Focused
// monitor") asks the guest which output has Hyprland's focus ("Q"); it answers
// at once with where that output sits on the Mac ("D x y w h", OmacVM.app's
// arrangement of the VM's outputs, points from its top-left) or "D -". No
// answer within focusWait (a guest from before 3.1.32), two VMs answering, or
// a place on no display of the VM: the pointer's display, as before.
static double focusWait = 0.15;   // s: the guest answers in a few ms (the offline test sets its own)
static void askFocus(void) { sendTo(0, "Q\n", 2); }
static void (*askFocusFn)(void) = askFocus;   // a seam for the offline test

// A front VM's guest still to answer "Q" since askedAt (one that never
// answered before is not waited for).
static int focusPending(double askedAt) {
  int pending = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && clients[i].target && !clients[i].focusSilent && clients[i].focusAt < askedAt) pending = 1;
  pthread_mutex_unlock(&sendLock);
  return pending;
}

static void focusNoAnswer(double askedAt) {
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && clients[i].target && clients[i].focusAt < askedAt) clients[i].focusSilent = 1;
  pthread_mutex_unlock(&sendLock);
}

// The centre of Hyprland's focused output on the Mac, as the front VM's one
// guest said it since askedAt. The arrangement starts at the top-left of the
// displays that show the VM. 0: not known, or not on a display of the VM.
static int guestFocus(double askedAt, const DisplaySpaces *ds, int nd, const CGRect *wins, int nw, CGPoint *at) {
  CGRect r = CGRectNull; int n = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && clients[i].target && clients[i].focusAt >= askedAt) { n++; if (clients[i].focusOk) r = clients[i].focus; }
  pthread_mutex_unlock(&sendLock);
  if (n != 1 || CGRectIsNull(r)) return 0;
  double ox = INFINITY, oy = INFINITY;
  for (int i = 0; i < nd; i++)
    if (showsVM(&ds[i], wins, nw)) { ox = fmin(ox, ds[i].bounds.origin.x); oy = fmin(oy, ds[i].bounds.origin.y); }
  if (!isfinite(ox)) return 0;
  CGPoint c = CGPointMake(ox + CGRectGetMidX(r), oy + CGRectGetMidY(r));
  for (int i = 0; i < nd; i++)
    if (showsVM(&ds[i], wins, nw) && CGRectContainsPoint(ds[i].bounds, c)) { *at = c; return 1; }
  return 0;
}

static void leavePlan(double askedAt);

// Waits (at most focusWait, in 10 ms looks) for the guest's answer.
static void leaveWait(double askedAt, int looks) {
  if (movesCancelled) { leaveWaiting = 0; return; }   // pressed again meanwhile
  if (focusPending(askedAt) && looks > 0) {
    pendingSteps++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(),
                   ^{ pendingSteps--; leaveWait(askedAt, looks - 1); });
    return;
  }
  if (focusPending(askedAt)) {
    focusNoAnswer(askedAt);
    logf_("escape combo: the VM did not say which display it has its focus on (a guest from before 3.1.32): the pointer's display");
  }
  leavePlan(askedAt);
}

// Out of the VM: the focused display (the VM's focus, else the pointer's; or,
// with "all", each display that shows the VM) moves one Space toward the one
// it showed before.
static void leaveVM(void) {
  leaveByFocus = 0;
  if (!escapeAllFn() && frontNet == NET_APP) {
    DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), shown = 0;
    CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
    for (int i = 0; i < nd; i++) shown += showsVM(&ds[i], wins, nw);
    if (shown >= 2) {   // only then can the focus be on another display than the pointer
      double at = monoNow();
      askFocusFn();
      leaveWaiting = 1;
      leaveWait(at, (int)(focusWait / 0.01 + 0.5));
      return;
    }
  }
  leavePlan(-1);
}

static void leavePlan(double askedAt) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = pointerFn(), f;
  leaveWaiting = 0;
  if (!all && askedAt >= 0 && guestFocus(askedAt, ds, nd, wins, nw, &f)) {
    const DisplaySpaces *fd = NULL, *pd = NULL;
    for (int i = 0; i < nd; i++) {
      if (CGRectContainsPoint(ds[i].bounds, f)) fd = &ds[i];
      if (CGRectContainsPoint(ds[i].bounds, p)) pd = &ds[i];
    }
    if (fd != pd) {
      logf_("escape combo: display %u has the VM's focus (the pointer is on display %u)", fd ? fd->id : 0, pd ? pd->id : 0);
      p = f; leavePoint = f; leaveByFocus = 1;
    }
  }
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
    leaveWaiting = 1;
    whenKeysUp(^{
      leaveWaiting = 0;
      if (runMoves(BY_SHORTCUT, "out of the VM")) after(^{ checkLeave(BY_SHORTCUT); });
      else { shortcutOff = 1; checkLeave(BY_SHORTCUT); }   // the shortcut is off: on to the Dock swipe
    }, 50);
    return;
  }
  // The pointer is on a display without the VM: nothing to move there, the
  // keyboard goes to what it shows.
  if (nd && nw && !pointerOnVM && !all) { focusPointerDisplay(); return; }
  if (!nd) noWayOut("macOS gives no Spaces information");
  else noWayOut("the VM's Space has no neighbour");
}

// ---- Swipe out to macOS (#342) ----
// A guest that says where swipes go ("E", after "X on 2") leaves such a
// swipe to the Mac, which follows the fingers (below, "Swipe out that
// follows the fingers"). A guest from 3.1.0-3.1.5 decides (its workspaces as
// they were when the swipe began, the fingers' way at the lift) and says "X
// left|right"; the Mac then moves the way the combo does (EscapeSwipe: the
// pointer's display, or each display that shows the VM), only to that side:
// no Space there = nothing, no notice (user, 2026-10-12). Then the same
// checks as the combo's (its shortcut, a Dock swipe, the other direction
// once). Pressed in macOS, the combo goes back into the VM, as after the
// combo.
static volatile int swipeOut = -1;   // the setting as last read (written on the main thread), -1: not yet
// "2": this helper follows the fingers itself (the guest says where swipes go,
// "E"); a guest from 3.1.0-3.1.5 reads "on" and decides at the lift ("X").
#define SWIPE_OUT_ON "X on 2\n"
static double swipeOutLooked = -1, swipeOutAt = -1;
static double swipeOutEvery = 1.0;   // s between two looks at the setting (the offline test sets 0)
static double swipeOutGap = 1.0;     // s: at most one swipe out in this time

// The setting, looked at with the capture check (at most once a second):
// every guest learns a change ("X on 2|off"), a new one on connect.
static void takeTravelLook(void);
static void swipeOutLook(void) {
  double now = monoNow();
  if (swipeOutLooked >= 0 && now - swipeOutLooked < swipeOutEvery) return;
  swipeOutLooked = now;
  int on = swipeOutFn() ? 1 : 0;
  if (on) takeTravelLook();
  if (on == swipeOut) return;
  swipeOut = on;
  logf_("swipe out to macOS %s", on ? "on" : "off");
  if (!on) {
    // A guest says where swipes go again after the next "X on 2".
    pthread_mutex_lock(&sendLock);
    for (int i = 0; i < MAX_CLIENTS; i++) clients[i].edgeKnown = clients[i].waysKnown = 0;
    pthread_mutex_unlock(&sendLock);
  }
  sendTo(1, on ? SWIPE_OUT_ON : "X off\n", on ? strlen(SWIPE_OUT_ON) : 6);
}

// Out of the VM toward one side (dir): the pointer's display, or with
// EscapeSwipe all each display that shows the VM, one Space with macOS's
// shortcut (the combo's way). done: a display the fingers already took out
// (the swipe that follows them): only the others follow, with "all".
// Returns how many displays it moves.
static int leaveToward(int dir, CGDirectDisplayID done) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = pointerFn();
  const char *side = dir < 0 ? "left" : "right";
  if (done && !all) return 0;
  nMoves = 0; leaving = 1; signRetried = 0; shortcutOff = 0; lateLooks = 0; movesCancelled = 0; leaveByFocus = 0;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    int at = spaceIndex(d, d->current);
    if (d->id == done || at < 0 || !showsVM(d, wins, nw) || !(all || CGRectContainsPoint(d->bounds, p))) continue;
    if (at + dir < 0 || at + dir >= d->n) continue;   // no Space on that side of this display
    if (addMove(d, dir, d->spaces[at + dir])) rememberOn(left, d->id, d->current);
  }
  if (!nMoves) {
    if (!done) logf_("swipe out to the %s: %s", side, nd ? "no macOS Space on that side: nothing done" : "macOS gives no Spaces information: nothing done");
    return 0;
  }
  // As the combo: macOS gets the trackpad and keys back at once (the guest
  // lets go), and the Dock swipe below is not dropped by our own tap.
  if (capturing) {
    capturing = 0; escaped = 1;
    logf_("swipe out to the %s: capture off", side);
    sendState("esc");
  }
  leaveWaiting = 1;
  whenKeysUp(^{
    leaveWaiting = 0;
    if (runMoves(BY_SHORTCUT, done ? "swipe out, the other displays" : "swipe out")) after(^{ checkLeave(BY_SHORTCUT); });
    else { shortcutOff = 1; checkLeave(BY_SHORTCUT); }
  }, 50);
  return nMoves;
}

static void leaveVMToward(int dir) { leaveToward(dir, 0); }

// "X left|right" from a guest (main thread): only the VM in front, captured,
// with the setting on, and one at a time.
static void swipeOutFrom(int fd, unsigned gen, int dir) {
  int target = 0, known = 0;
  char who[256] = "";
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd == fd && clients[i].gen == gen) {
      known = 1; target = clients[i].target;
      snprintf(who, sizeof who, "%s", clients[i].name[0] ? clients[i].name : clients[i].ip);
    }
  pthread_mutex_unlock(&sendLock);
  const char *side = dir < 0 ? "left" : "right", *no = NULL;
  double now = monoNow();
  if (!known) no = "that guest is gone";
  else if (swipeOut != 1) no = "the setting is off";
  else if (!target || !frontIsVM || frontForeign) no = "its VM is not the one in front";
  else if (!capturing) no = "not captured";
  else if (swipeOutAt >= 0 && now - swipeOutAt < swipeOutGap) no = "one a moment ago";
  if (no) { logf_("swipe out to the %s from \"%s\": %s: ignored", side, who, no); return; }
  swipeOutAt = now;
  logf_("swipe out to the %s from \"%s\"", side, who);
  leaveVMToward(dir);
}

// "E" (after "X on 2"): left -1, right +1, "-" 0; anything else 2.
static int edgeWord(const char *w) {
  return !strcmp(w, "left") ? -1 : !strcmp(w, "right") ? 1 : !strcmp(w, "-") ? 0 : 2;
}

// "G": which finger counts switch workspaces going left and right, from
// tokens like "4lr", "3l" (2-9 fingers), or "-" for none. 0: not that form.
static int waysFrom(const char *s, unsigned ways[2]) {
  ways[0] = ways[1] = 0;
  if (!strcmp(s, "-")) return 1;
  int n = 0;
  while (*s) {
    while (*s == ' ') s++;
    if (!*s) break;
    if (*s < '2' || *s > '9' || ++n > 16) return 0;
    unsigned bit = 1u << (*s++ - '0'), any = 0;
    for (; *s == 'l' || *s == 'r'; s++) { ways[*s == 'r'] |= bit; any = 1; }
    if (!any || (*s && *s != ' ')) return 0;
  }
  return n > 0;
}

// One line a guest sent after its handshake (its reader thread). "E <l> <r>"
// and "G ..." are kept with its connection (the trackpad's thread reads them
// when a swipe begins); "X left|right" is acted on on the main thread.
// Anything else is skipped.
static void guestLine(int fd, unsigned gen, const char *line) {
  char a[8], b[8], more;
  unsigned ways[2];
  if (!strncmp(line, "G ", 2) && waysFrom(line + 2, ways)) {
    pthread_mutex_lock(&sendLock);
    for (int i = 0; i < MAX_CLIENTS; i++)
      if (clients[i].fd == fd && clients[i].gen == gen) { clients[i].ways[0] = ways[0]; clients[i].ways[1] = ways[1]; clients[i].waysKnown = 1; }
    pthread_mutex_unlock(&sendLock);
    if (verbose) logf_("swipe out: workspaces switch with %s", line + 2);
    return;
  }
  if (!strncmp(line, "E ", 2) && sscanf(line + 2, "%7s %7s %c", a, b, &more) == 2) {
    int l = edgeWord(a), r = edgeWord(b);
    if (l == 2 || r == 2) return;
    pthread_mutex_lock(&sendLock);
    for (int i = 0; i < MAX_CLIENTS; i++)
      if (clients[i].fd == fd && clients[i].gen == gen) { clients[i].edge[0] = l; clients[i].edge[1] = r; clients[i].edgeKnown = 1; }
    pthread_mutex_unlock(&sendLock);
    if (verbose) logf_("swipe out: fingers to the left %s, to the right %s", a, b);
    return;
  }
  if (!strncmp(line, "D ", 2)) {
    double x, y, w, h; char extra;
    int ok = sscanf(line + 2, "%lf %lf %lf %lf %c", &x, &y, &w, &h, &extra) == 4 && isfinite(x) && isfinite(y) &&
             isfinite(w) && isfinite(h) && fabs(x) < 1e6 && fabs(y) < 1e6 && w > 0 && h > 0 && w < 1e6 && h < 1e6;
    if (!ok && strcmp(line + 2, "-")) return;   // neither a place nor "not known"
    pthread_mutex_lock(&sendLock);
    for (int i = 0; i < MAX_CLIENTS; i++)
      if (clients[i].fd == fd && clients[i].gen == gen) {
        clients[i].focusOk = ok; clients[i].focusAt = monoNow(); clients[i].focusSilent = 0;
        if (ok) clients[i].focus = CGRectMake(x, y, w, h);
      }
    pthread_mutex_unlock(&sendLock);
    return;
  }
  int dir = !strcmp(line, "X left") ? -1 : !strcmp(line, "X right") ? 1 : 0;
  if (dir) dispatch_async(dispatch_get_main_queue(), ^{ swipeOutFrom(fd, gen, dir); });
}

// ---- Swipe out that follows the fingers ----
// With a guest that says where swipes go ("E", after "X on 2"), a swipe out
// of the VM is the Mac's: held back from the guest until its way is clear
// (swipe-take.h), then macOS's own Space swipe on the pointer's display
// follows the fingers and finishes or goes back at the lift; the guest sees
// none of it. If macOS does not follow (a finished one did not change the
// Space), it is the one step as before (leaveToward); twice in a row, the
// one step from then on until the helper starts again. (Whether the display
// moves while the swipe runs cannot be asked from here: macOS's
// CGSManagedDisplayIsAnimating said no in this helper while the Space
// followed, the mini 2026-10-14.) A Magic Mouse's swipe too (mouseFrameCb).

// What the capture check last saw of the pointer's display while a VM is
// captured (main thread writes, the trackpad's and the mouse's threads read).
typedef struct {
  int ok, n, left, right;   // n: its Spaces; left, right: one beside the VM's
  CGDirectDisplayID id;
  CGRect b;
  uint64_t vmSpace;
} TakeDisplay;
// The swipe the Mac has now (one at a time).
typedef struct {
  int on, follows, toward;
  int sign;                 // the progress's way: 1 (macOS 27's HID event) or swipeSign, at the start
  double began, unit;       // unit: the Dock's progress for one Space there
  CGPoint at;
  TakeDisplay d;
} TakeRun;
static TakeDisplay takeDisp;
static TakeRun takeRun;
static pthread_mutex_t takeLock = PTHREAD_MUTEX_INITIALIZER;   // takeDisp, takeRun.on
static SwipeTake padTake;
static double (*takeClockFn)(void) = monoNow;   // the offline test's own clock
static double takeClock(void) { return takeClockFn(); }
static volatile int dockFollows = 1;     // 0: macOS did not follow twice in a row: one step from then on (main thread writes)
static int dockMisses;                   // finished swipes in a row that did not change the Space (main thread)
static int missFlipped;                  // macOS 26 and older: swipeSign flipped after a miss, to be confirmed (main thread)
static volatile double takeQuietUntil;   // the real trackpad's gesture events dropped until then
static volatile double takeTravel = TAKE_TRAVEL;   // trackpad widths per Space ("SwipeOutTravel")
#define TAKE_QUIET 0.4                   // s after a taken swipe's end
#define TAKE_PINCH_MIN 0.03              // trackpad widths the fingers' spread changes in a pinch ...
#define TAKE_PINCH_RATIO 0.25            // ... and this share of it (fingers drift a little in a swipe)
#define TAKE_SETTLE 0.6                  // s macOS takes to slide the VM's Space back
static double takeHoldUntil;             // the capture check waits until then (takeLock)

// "SwipeOutTravel" (hidden, for tuning; defaults write org.omacvm.gestures
// SwipeOutTravel -float 0.5): how much of the trackpad's width moves macOS
// one Space. Not set or out of 0.15-1.5: TAKE_TRAVEL.
static void takeTravelLook(void) {
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("SwipeOutTravel"), GESTURES_DOMAIN);
  double t = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &t);
  if (v) CFRelease(v);
  takeTravel = t >= 0.15 && t <= 1.5 ? t : TAKE_TRAVEL;
}

// A guest in front that says where swipes go, with a way out.
static int edgesKnown(void) {
  int any = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && clients[i].target && clients[i].edgeKnown && (clients[i].edge[0] || clients[i].edge[1])) any = 1;
  pthread_mutex_unlock(&sendLock);
  return any;
}

// With the capture check (main thread): the pointer's display, while it is
// worth knowing.
static void takeLook(void) {
  TakeDisplay t = { 0 };
  if (capturing && swipeOut == 1 && edgesKnown()) {
    DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
    CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
    CGPoint p = pointerFn();
    for (int i = 0; i < nd; i++) {
      const DisplaySpaces *d = &ds[i];
      int at = spaceIndex(d, d->current);
      if (at < 0 || !CGRectContainsPoint(d->bounds, p) || !showsVM(d, wins, nw)) continue;
      t = (TakeDisplay){ 1, d->n, at > 0, at + 1 < d->n, d->id, d->bounds, d->current };
      break;
    }
  }
  pthread_mutex_lock(&takeLock);
  takeDisp = t;
  if (takeRun.on && takeClock() - takeRun.began > 10) takeRun.on = 0;   // its end never came
  pthread_mutex_unlock(&takeLock);
}

// Where fingers going left and right go out (every VM in front must say the
// same; 0 = the guest's), only toward a macOS Space, with k fingers: only a
// count the guest switches workspaces with that way ("G"; a guest that did
// not say: any 3 or more). k = 0: with any count (worth holding back?).
static void takeSides(int *sl, int *sr, int k) {
  *sl = *sr = 0;
  if (swipeOut != 1) return;
  int e[2] = { 0, 0 }, n = 0, all = 1;
  unsigned ok[2] = { ~0u << 3, ~0u << 3 };   // fingers allowed per way: 3 and more
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !clients[i].target) continue;
    if (!clients[i].edgeKnown) all = 0;
    else if (!n++) { e[0] = clients[i].edge[0]; e[1] = clients[i].edge[1]; }
    else for (int w = 0; w < 2; w++) if (e[w] != clients[i].edge[w]) e[w] = 0;
    if (clients[i].waysKnown) for (int w = 0; w < 2; w++) ok[w] &= clients[i].ways[w];
  }
  pthread_mutex_unlock(&sendLock);
  if (!n || !all) return;
  for (int w = 0; w < 2; w++) if (k > 0 ? k > 31 || !(ok[w] & 1u << k) : !(ok[w] & ~7u)) e[w] = 0;
  pthread_mutex_lock(&takeLock);
  TakeDisplay t = takeDisp; int busy = takeRun.on;
  pthread_mutex_unlock(&takeLock);
  if (!t.ok || busy) return;
  for (int w = 0; w < 2; w++) {
    int s = (e[w] < 0 && t.left) || (e[w] > 0 && t.right) ? e[w] : 0;
    if (w) *sr = s; else *sl = s;
  }
}

// macOS did not follow a swipe (main thread): that one goes in one step; two
// in a row, every one from then on (logged once). macOS 26 and older first
// try the other way (a swipe the wrong way only bounces at the edge): the
// next swipe that lands keeps it; one that misses too puts it back.
static void takeMissed(const char *why) {
  if (!dockFollows) return;
  if (!hidSwipeFn() && !missFlipped && !dockMisses) {   // the first miss in a row only
    swipeSign = -swipeSign; missFlipped = 1;
    logf_("swipe out: macOS did not follow this swipe (%s): one step; the next one tries the other direction", why);
    return;
  }
  if (missFlipped) { swipeSign = -swipeSign; missFlipped = 0; }   // not the way: as it was
  if (++dockMisses < 2) { logf_("swipe out: macOS did not follow this swipe (%s): one step", why); return; }
  dockFollows = 0;
  logf_("swipe out: macOS does not follow the swipe here (%s): one step at the lift from now on", why);
}

static void takeLanded(TakeRun r, int looks);

// A taken swipe's end (main thread).
static void takeEnded(TakeRun r, int commit, double progress, double speed) {
  const char *side = r.toward < 0 ? "left" : "right";
  if (!commit) {
    logf_("swipe out to the %s: back into the VM (%.2f of a Space, %.1f Spaces/s)", side, progress, speed);
    // macOS slides the VM's Space back: the capture check waits for that too.
    pthread_mutex_lock(&takeLock); takeRun.on = 0; takeHoldUntil = takeClock() + TAKE_SETTLE; pthread_mutex_unlock(&takeLock);
    return;
  }
  swipeOutAt = monoNow();
  if (!r.follows) {
    logf_("swipe out to the %s: one step (%.2f of a Space, %.1f Spaces/s)", side, progress, speed);
    pthread_mutex_lock(&takeLock); takeRun.on = 0; pthread_mutex_unlock(&takeLock);
    leaveToward(r.toward, 0);
    return;
  }
  rememberOn(left, r.d.id, r.d.vmSpace);   // the combo in macOS goes back to it
  logf_("swipe out to the %s: out with the fingers (%.2f of a Space, %.1f Spaces/s)%s", side, progress, speed,
        capturing ? ": capture off" : "");
  if (capturing) { capturing = 0; escaped = 1; sendState("esc"); }
  after(^{ takeLanded(r, 0); });
}

// Did macOS finish it: the display shows another Space. Else the one step.
static void takeLanded(TakeRun r, int looks) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  const DisplaySpaces *d = displayIn(ds, nd, r.d.id);
  if (d && d->current == r.d.vmSpace && looks < LATE_LOOKS) { afterLook(^{ takeLanded(r, looks + 1); }); return; }
  pthread_mutex_lock(&takeLock); takeRun.on = 0; pthread_mutex_unlock(&takeLock);
  if (!d) { logf_("swipe out: the display is gone"); return; }
  if (d->current != r.d.vmSpace) {
    dockMisses = 0;
    int from = spaceIndex(d, r.d.vmSpace), to = spaceIndex(d, d->current);
    if (!hidSwipeFn() && from >= 0 && to >= 0 && (to - from) * r.toward < 0) {
      // macOS 26 and older read the way from fields it does not document:
      // it went the other way. Learned for the next swipe (and the combo).
      if (missFlipped) missFlipped = 0;
      swipeSign = -swipeSign; saveSignFn();
      logf_("swipe out: macOS went to the %s instead: direction learned for the next swipe", r.toward < 0 ? "right" : "left");
      return;
    }
    if (missFlipped) { missFlipped = 0; saveSignFn(); logf_("swipe out: the other direction worked: direction learned"); }
    logf_("swipe out: out of the VM's Space (macOS's swipe)");
    if (!leaveToward(r.toward, r.d.id)) focusPointerDisplay();   // with "all" the other displays follow
    return;
  }
  takeMissed("a finished swipe did not change the Space");
  leaveToward(r.toward, 0);
}

// A swipe out is the Mac's now (until macOS has finished it, at most 5 s), or
// macOS still slides the VM's Space back after one: the capture check waits.
static int takeOn(void) {
  pthread_mutex_lock(&takeLock);
  double now = takeClock();
  int on = (takeRun.on && now - takeRun.began < 5) || now < takeHoldUntil;
  pthread_mutex_unlock(&takeLock);
  return on;
}

static double takeUnits(double spaces) { return -takeRun.toward * takeRun.sign * spaces * takeRun.unit; }

// What a frame of a swipe the Mac may take does (the trackpad's or a Magic
// Mouse's thread): macOS's swipe begins, moves, ends.
static void takeAct(SwipeTake *s, int tk, const char *who) {
  double now = takeClock();
  if (tk == TK_BEGIN) {
    pthread_mutex_lock(&takeLock);
    takeRun.on = 1; takeRun.d = takeDisp; takeRun.toward = s->toward; takeRun.began = now;
    takeRun.sign = hidSwipeFn() ? 1 : swipeSign;
    takeRun.follows = dockFollows && (!hidSwipeFn() || lookUpHID());
    takeRun.unit = takeRun.d.n <= 1 ? 2.0 : 1.0 + 1.0 / (takeRun.d.n - 1);
    CGPoint p = pointerFn();
    takeRun.at = CGRectContainsPoint(takeRun.d.b, p) ? p : CGPointMake(CGRectGetMidX(takeRun.d.b), CGRectGetMidY(takeRun.d.b));
    pthread_mutex_unlock(&takeLock);
    logf_("swipe out to the %s (%s): %s", s->toward < 0 ? "left" : "right", who,
          takeRun.follows ? "macOS's Space follows the fingers" : "one step at the lift");
    if (takeRun.follows && !dockPostFn(kSwipeBegan, takeUnits(s->progress), 0, takeRun.at)) takeRun.follows = 0;
  } else if (tk == TK_MOVE && takeRun.follows) {
    dockPostFn(kSwipeChanged, takeUnits(s->progress), 0, takeRun.at);
  } else if (tk == TK_END) {
    int commit = takeRun.follows ? s->commit : s->along >= TAKE_STEP_MIN && s->speed > TAKE_BACK;
    if (takeRun.follows) dockPostFn(commit ? kSwipeEnded : kSwipeCancelled, takeUnits(s->progress), takeUnits(s->speed), takeRun.at);
    takeQuietUntil = monoNow() + TAKE_QUIET;
    TakeRun r = takeRun;
    double progress = s->progress, speed = s->speed;
    dispatch_async(dispatch_get_main_queue(), ^{ takeEnded(r, commit, progress, speed); });
  }
}

// Capture gone while a swipe was the Mac's (another app came to the front,
// a permission taken away): macOS's swipe goes back, the rest is dropped.
static int takeAbort(SwipeTake *s, int k) {
  if (s->state == TAKE_TAKEN) {
    if (takeRun.follows) dockPostFn(kSwipeCancelled, takeUnits(s->progress), 0, takeRun.at);
    takeQuietUntil = monoNow() + TAKE_QUIET;
    pthread_mutex_lock(&takeLock); takeRun.on = 0; pthread_mutex_unlock(&takeLock);
    logf_("swipe out: capture ended during the swipe: back");
    s->state = k ? TAKE_DONE : TAKE_IDLE;
    return TK_DROP;
  }
  if (s->state == TAKE_DONE) { if (!k) s->state = TAKE_IDLE; return TK_DROP; }
  s->state = TAKE_IDLE;
  return TK_FORWARD;
}

// The frames held back from the guest while a swipe's way is not clear
// (the trackpad's thread).
static char kept[16384];
static size_t keptLen;
static int keepFrame(const char *line, size_t len) {
  if (keptLen + len > sizeof kept) return 0;
  memcpy(kept + keptLen, line, len); keptLen += len;
  return 1;
}
static void flushKept(void) {
  if (!keptLen) return;
  sendLine(kept, keptLen);
  keptLen = 0;
  forwarding = 1;
}
static void dropKept(void) { keptLen = 0; }
static void takePadPass(void) { padTake.state = TAKE_PASS; }

// A trackpad frame (frameCb): its fingers' movement since the last frame
// (those in both), into the model.
static int takePadFrame(MTTouch **c, int k) {
  static struct { int id; float x, y; } last[16];
  static int nLast;
  double ddx = 0, ddy = 0; int common = 0;
  for (int i = 0; i < k; i++)
    for (int j = 0; j < nLast; j++)
      if (last[j].id == c[i]->pathIndex) { ddx += c[i]->normalized.pos.x - last[j].x; ddy += c[i]->normalized.pos.y - last[j].y; common++; }
  if (common) { ddx /= common; ddy = ddy / common * (tpW > 0 ? (double)tpH / tpW : 0.6); }   // up/down in trackpad widths too
  nLast = k;
  for (int i = 0; i < k; i++) { last[i].id = c[i]->pathIndex; last[i].x = c[i]->normalized.pos.x; last[i].y = c[i]->normalized.pos.y; }
  if (!(capturing && gesturesOn())) { dropKept(); return takeAbort(&padTake, k); }
  // How far apart the fingers are (in trackpad widths): a pinch or spread
  // while the way is not clear is no swipe.
  static double spread0;
  double cx = 0, cy = 0, spread = 0;
  for (int i = 0; i < k; i++) { cx += c[i]->normalized.pos.x; cy += c[i]->normalized.pos.y; }
  if (k) { cx /= k; cy /= k; }
  for (int i = 0; i < k; i++) spread += hypot(c[i]->normalized.pos.x - cx, (c[i]->normalized.pos.y - cy) * tpH / (tpW > 0 ? tpW : 1));
  if (k) spread /= k;
  static int spreadK;
  int wl = 0, wr = 0, sl = 0, sr = 0;
  if (padTake.state == TAKE_IDLE && k >= 3) takeSides(&wl, &wr, 0);
  if ((padTake.state == TAKE_IDLE || padTake.state == TAKE_WATCH) && k >= 3) takeSides(&sl, &sr, k);
  int was = padTake.state;
  int tk = takeFrame(&padTake, k, wl, wr, sl, sr, ddx, ddy, takeTravel, takeClock());
  // Still not clear which way: fingers spreading or closing (a pinch) are no
  // swipe. Measured for the same fingers only: one more coming down (3, then
  // the 4th of a four-finger swipe) changes the spread by itself.
  if (tk == TK_HOLD) {
    if (was == TAKE_IDLE || k != spreadK) { spread0 = spread; spreadK = k; }
    else if (fabs(spread - spread0) >= TAKE_PINCH_MIN && fabs(spread - spread0) >= TAKE_PINCH_RATIO * spread0) {
      padTake.state = TAKE_PASS;
      return TK_FLUSH;
    }
  }
  takeAct(&padTake, tk, "trackpad");
  return tk;
}

// A Magic Mouse's swipe frame (mouseFrameCb, mouseLock held): k virtual
// fingers (0: its end), step: its travel on the guest's touchpad since the
// last one (trackpad widths). The mouse's surface is a third of a trackpad's
// width: one Space for half the travel (half a Space: 13 mm on the mouse,
// about what switches a workspace in the VM).
#define TAKE_MOUSE_TRAVEL 0.5
static int takeMouseFrame(SwipeTake *t, int k, double step) {
  if (!(capturing && gesturesOn())) return takeAbort(t, k);
  int sl = 0, sr = 0;   // its virtual fingers (MouseSwipeFingers): as many as the guest gets
  if ((t->state == TAKE_IDLE || t->state == TAKE_WATCH) && k >= 3) takeSides(&sl, &sr, k);
  int tk = takeFrame(t, k, sl, sr, sl, sr, step, 0, takeTravel * TAKE_MOUSE_TRAVEL, takeClock());
  takeAct(t, tk, "Magic Mouse");
  return tk;
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

// The VM's own Space on this display and its window there: its main window's,
// else another of its windows' (OmacVM.app has one per display in full
// screen), the one nearest the display's current Space. 0: none there.
static uint64_t vmSpaceOn(const DisplaySpaces *d, CGWindowID *win) {
  uint64_t s = windowSpaceFn(vmWin);
  *win = vmWin;
  if (s && spaceIndex(d, s) >= 0) return s;
  CGWindowID ws[MAX_DISPLAYS * 2]; int n = vmAllWindowsFn(vmPid, ws, MAX_DISPLAYS * 2);
  int at = spaceIndex(d, d->current), best = -1;
  uint64_t found = 0;
  *win = 0;
  for (int i = 0; i < n; i++) {
    uint64_t t = windowSpaceFn(ws[i]);
    int j = t ? spaceIndex(d, t) : -1;
    if (j < 0) continue;
    int dist = at < 0 ? 0 : abs(j - at);
    if (best < 0 || dist < best) { best = dist; found = t; *win = ws[i]; }
  }
  return found;
}

static void enterVMNow(int mayCloseMC) {
  if (mayCloseMC && missionControlOpenFn()) { closeMissionControlThenEnter(); return; }
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGPoint p = pointerFn();
  nMoves = 0; leaving = 0; lateLooks = 0; enterWin = vmWin;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    int under = CGRectContainsPoint(d->bounds, p);
    if (!all && !under) continue;
    uint64_t want = spaceOn(left, d->id);
    CGWindowID w = 0;
    // Not left by the combo (a swipe, Mission Control, or the VM's Spaces
    // are new): the VM's Space on this display, also a second display's
    // window's (before, only the main window's: on the external the combo
    // brought the main window instead).
    if (!want || spaceIndex(d, want) < 0) want = all ? 0 : vmSpaceOn(d, &w);
    else if (under) vmSpaceOn(d, &w);
    if (under && w) enterWin = w;
    if (want && d->current != want) addMove(d, stepToward(d, want), want);
  }
  if (!nMoves) { goTo(vmPid, enterWin, "back into the VM:", NULL); return; }
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
    // Never enabled again (#290): removed after this callback has returned,
    // a new one after a hold-off; without the permissions it goes for good
    // until they are back (#192). (This callback runs on the main thread:
    // refreshSlowPerms asks tccd off it.)
    const char *by = type == kCGEventTapDisabledByTimeout ? "macOS's timeout" : "user input";
    CFMachPortRef was = tapPort;
    if (permitted(permFn())) { dispatch_async(dispatch_get_main_queue(), ^{ if (tapPort == was) tapDisabled(by); }); refreshSlowPerms(); }
    else dispatch_async(dispatch_get_main_queue(), ^{ checkPermissions(); });
    return e;
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
    // The other identity's VM in front: its Gestures' combo, not ours.
    int act = combo && !frontForeign
              ? comboAction(frontIsVM, escaped, alive(vmPid) && (vmPid != appPid || vmOffSpace) && vmWindowFn(vmPid, vmWin),
                            winVMPid > 0 && winVMPid == appPid,
                            alive(leftWinPid) && leftWinPid != appPid && vmWindowFn(leftWinPid, leftWinWin))
              : COMBO_PASS;
    // In Mission Control (no VM in front there) with a full-screen VM to go
    // back to: back into it, whatever macOS says is in front (enterVM closes
    // Mission Control first). Asked only for a combo from the keyboard.
    if (combo && !frontIsVM && !frontForeign && type == kCGEventKeyDown && act != COMBO_ENTER && act != COMBO_WINDOW_BACK &&
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
      // Back in before the last move out was posted (it waits for Ctrl and
      // Option to come up): that move is dropped, the VM stays.
      else if (leaveWaiting) { movesCancelled = 1; logf_("escape combo: pressed again before the move out: it is dropped"); }
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
  // A gesture event type. Also just after a swipe the Mac took (TAKE_QUIET):
  // the trackpad's own end of it must not reach the Dock's swipe.
  return (capturing && gesturesOn()) || monoNow() < takeQuietUntil ? NULL : e;
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
  snprintf(path, sizeof path, "%s/Library/Application Support/%s/token", getenv("HOME"), BRIDGE_DIR);
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

static unsigned addClient(int c, int net, const char *ip, int gestures, int glide, const char *name) {
  static unsigned gens;
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
      else logf_("guest %s connected again: its old connection closed", ip);
      closeClient(clients[i].fd); slot = i; break;
    }
  for (int i = 0; slot < 0 && i < MAX_CLIENTS; i++) if (clients[i].fd < 0) slot = i;
  if (slot < 0) { closeClient(clients[0].fd); slot = 0; }   // full: drop the oldest slot
  clients[slot].fd = c; clients[slot].net = net; clients[slot].gen = ++gens;
  clients[slot].gestures = gestures != 0; clients[slot].glide = glide != 0;
  clients[slot].edge[0] = clients[slot].edge[1] = 0; clients[slot].edgeKnown = 0;
  clients[slot].ways[0] = clients[slot].ways[1] = 0; clients[slot].waysKnown = 0;
  clients[slot].focusOk = clients[slot].focusSilent = 0; clients[slot].focusAt = 0;
  snprintf(clients[slot].ip, sizeof clients[slot].ip, "%s", ip);
  snprintf(clients[slot].name, sizeof clients[slot].name, "%s", name);
  logf_("guest connected: %s (gestures %s, scroll momentum %s%s%s%s%s)", ip, gestures ? "on" : "off",
        glide ? "on" : "off", name[0] ? ", VM \"" : "", name, name[0] ? "\"" : "",
        net == NET_APP && strncmp(ip, "127.", 4) ? ", OmacVM.app on its fast network" : "");
  retargetLocked(capturing);
  int front = clients[slot].target;
  unsigned gen = clients[slot].gen;
  pthread_mutex_unlock(&sendLock);
  const char *st = capturing && front ? "on\n" : "off\n";
  char b[96]; int n = snprintf(b, sizeof b, "S %s", st);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
  n = sizeLine(b, sizeof b);   // the Mac's scrolling direction and the trackpad's size
  send(c, b, (size_t)n, MSG_NOSIGNAL);
  if (swipeOut == 1) send(c, SWIPE_OUT_ON, strlen(SWIPE_OUT_ON), MSG_NOSIGNAL);   // Swipe out to macOS (else off, as the guest starts)
  return gen;
}

// The guest's connection ended while it was still the guest's (its reader saw
// it end; err: recv's errno, 0 = closed by the VM): it is dropped and the
// front VM's guests picked again, as a failed send does (sendTo). Before, it
// stayed until the next send to it failed or the VM connected again, and
// neither said so: a reset while the Mac slept (keepalive gets no answer from
// a VM that does not run during Power Nap's dark wakes) left no line in the
// log. One the Mac closed itself (replaced, dropped) is not its slot's any more.
static void guestGone(int fd, unsigned gen, int err) {
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd != fd || clients[i].gen != gen) continue;
    logf_("guest disconnected: %s (%s)", clients[i].ip, !err ? "closed by the VM" : err == ETIMEDOUT ?
          "no answer to keepalive: the VM did not run, or its network went away" : err == ECONNRESET ? "connection reset" : strerror(err));
    closeClient(fd); clients[i].fd = -1;
    retargetLocked(capturing);
  }
  pthread_mutex_unlock(&sendLock);
}

// After the handshake: the guest's lines ("X left|right"), until it goes or
// its connection is closed here (closeClient shuts the socket down). rd is
// this thread's own copy of the socket, so a closed fd number taken by a new
// connection is never read here. Lines longer than the buffer are skipped.
static void readGuest(int rd, int fd, unsigned gen) {
  struct timeval none = { 0 };
  setsockopt(rd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof none);
  char buf[256]; size_t n = 0; int skipping = 0, err = 0;
  for (;;) {
    ssize_t r = recv(rd, buf + n, sizeof buf - 1 - n, 0);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) { err = r < 0 ? errno : 0; break; }
    n += (size_t)r;
    char *start = buf, *nl;
    while ((nl = memchr(start, '\n', n - (size_t)(start - buf)))) {
      *nl = 0;
      if (!skipping) guestLine(fd, gen, start);
      skipping = 0;
      start = nl + 1;
    }
    n -= (size_t)(start - buf);
    memmove(buf, start, n);
    if (n == sizeof buf - 1) { n = 0; skipping = 1; }   // too long: the rest of it too
  }
  close(rd);
  guestGone(fd, gen, err);
}

struct readerArg { int rd, fd; unsigned gen; };
static void *readerMain(void *arg) {
  struct readerArg r = *(struct readerArg *)arg; free(arg);
  readGuest(r.rd, r.fd, r.gen);
  return NULL;
}

// Its own thread per guest (at most MAX_CLIENTS live: a replaced or dropped
// guest's reader ends with its socket).
static void startReader(int rd, int fd, unsigned gen) {
  struct readerArg *r = malloc(sizeof *r);
  pthread_t th; pthread_attr_t at;
  if (!r) { close(rd); return; }
  *r = (struct readerArg){ rd, fd, gen };
  pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
  if (pthread_create(&th, &at, readerMain, r)) { free(r); close(rd); }
  pthread_attr_destroy(&at);
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
    // Its reader's own copy, taken before anyone else can close c.
    int rd = dup(c);
    // OmacVM.app's VMs on its fast network are the app's (its window in
    // front), whichever address they came in on.
    unsigned gen = addClient(c, g.net == NET_APP_FAST ? NET_APP : g.net, ip, gestures, glide, name);
    if (rd >= 0) startReader(rd, c, gen);
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
// HID product (isMagicMouseKind). Looked for again every 10 s, and 1 s after
// macOS adds a multi-touch device (watchMultitouch), so a Magic Trackpad or
// Magic Mouse connected later (or again) is taken too.
// At a wake from deep sleep (Power Nap's dark wakes too) macOS makes the
// built-in trackpad's device anew: the same Multitouch ID, a new IORegistry
// entry, the old one gone. MultitouchSupport tells only devices run with
// MTDeviceScheduleOnRunLoop about that, not ours (MTDeviceStart): the old one
// still says it runs and its frames never come again (the M1 Max, 2026-10-22:
// no trackpad frames from the first wake on, until the helper started again).
// So a listed device is the one held only while its IORegistry entry is the
// same; a newer entry with the same ID takes its place.
static int trackpadStarted;
static int isReplayDev(MTDeviceRef d);

// The IORegistry entry of a multi-touch surface's device (0: unknown).
static uint64_t mtEntry(MTDeviceRef d) {
  io_service_t svc = MTDeviceGetService(d);
  uint64_t e = 0;
  if (!svc || IORegistryEntryGetRegistryEntryID(svc, &e) != KERN_SUCCESS) return 0;
  return e;
}

// d (IORegistry entry `entry`) is listed with the Multitouch ID of the device
// held (heldEntry): does it take its place? A newer entry: macOS made the
// device anew, or it was connected again. An older one never (the old one may
// still be listed for a moment next to the new). The same entry, or none
// known: only once the held one no longer runs, as before.
static int takesOver(MTDeviceRef held, uint64_t heldEntry, MTDeviceRef d, uint64_t entry) {
  if (held == d) return 0;
  if (heldEntry && entry && heldEntry != entry) return entry > heldEntry;
  return !MTDeviceIsRunning(held);
}

// Let go of a device taken (startTrackpads, startMouse): no more frames from
// it, and the hold on it (CFRetain) ends.
static void stopDevice(MTDeviceRef d, MTFrameCallback cb) {
  MTUnregisterContactFrameCallback(d, cb);
  if (MTDeviceIsRunning(d)) MTDeviceStop(d);
  CFRelease(d);
}
static void (*stopDeviceFn)(MTDeviceRef, MTFrameCallback) = stopDevice;

// Start a device taken (its frames come from now on): 1 if MultitouchSupport
// did. One it did not start does not run, so the next look takes it again
// (takesOver); said at most once a minute (and never as a "trackpad: " line,
// which omacvm check shows).
static int startDevice(MTDeviceRef d, MTFrameCallback cb, const char *what) {
  MTRegisterContactFrameCallback(d, cb);
  int err = MTDeviceStart(d, 0);
  if (!err) return 1;
  static time_t said;
  time_t now = time(NULL);
  if (now - said >= 60) {
    said = now;
    logf_("MultitouchSupport did not start the %s (0x%08x): tried again at each look", what, (unsigned)err);
  }
  return 0;
}

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

// A Magic Mouse not taken yet, or a new device for one (above): its frames come
// from now on. The device is held (CFRetain) until let go (stopDevice).
static void startMouse(MTDeviceRef d, int w, int h, int family, int product) {
  uint64_t id = 0, entry = mtEntry(d);
  MTDeviceGetDeviceID(d, &id);
  int slot = -1, known = 0, renewed = 0;
  MTDeviceRef old = NULL;
  pthread_mutex_lock(&mouseLock);
  for (int k = 0; k < nMice; k++) {
    if (mice[k].id != id || isReplayDev(mice[k].dev)) continue;
    if (takesOver(mice[k].dev, mice[k].entry, d, entry)) slot = k; else known = 1;
  }
  if (!known && slot >= 0) { old = mice[slot].dev; renewed = mice[slot].entry != entry; }
  if (!known && slot < 0 && nMice < MAX_MICE) slot = nMice++;
  if (!known && slot >= 0) {
    CFRetain(d);
    mice[slot].dev = d; mice[slot].id = id; mice[slot].entry = entry; mice[slot].sent = 0;
    mice[slot].w = w > 0 ? w : 5150; mice[slot].h = h > 0 ? h : 9050;
    mouseStateInit(&mice[slot].st);
    takeReset(&mice[slot].take);
  }
  int mw = slot >= 0 ? mice[slot].w : 0, mh = slot >= 0 ? mice[slot].h : 0;
  pthread_mutex_unlock(&mouseLock);
  if (known || slot < 0) return;
  if (old) stopDeviceFn(old, mouseFrameCb);   // its device is gone (or did not start): let go of it
  if (!startDevice(d, mouseFrameCb, "Magic Mouse")) return;
  logf_("Magic Mouse%s: family %d, product 0x%04x, %d x %d mm (in the VM: two-finger swipe = workspaces, "
        "one-finger flick = back/forward; scrolling as before)", renewed ? " again" : "", family, product, mw / 100, mh / 100);
}

static int isTrackpad(MTDeviceRef d, int *w, int *h) {
  if (MTDeviceGetSensorSurfaceDimensions(d, w, h) != 0) *w = *h = 0;
  return MTDeviceIsBuiltIn(d) || *w >= 10000;
}

static void startTrackpads(void) {
  CFArrayRef list = MTDeviceCreateList();
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    int w = 0, h = 0;
    uint64_t id = 0, entry = mtEntry(d);
    if (!isTrackpad(d, &w, &h)) {
      int family = 0;
      if (MTDeviceGetFamilyID(d, &family) != 0) family = 0;
      int product = mtProduct(d);
      if (isMagicMouseKind(MTDeviceIsBuiltIn(d), family, product, w, h)) startMouse(d, w, h, family, product);
      continue;
    }
    MTDeviceGetDeviceID(d, &id);
    int slot = -1, known = 0, renewed = 0, sized = 0;
    MTDeviceRef old = NULL;
    pthread_mutex_lock(&padLock);
    for (int k = 0; k < nPads; k++) {
      if (pads[k].id != id || isReplayDev(pads[k].dev)) continue;
      if (takesOver(pads[k].dev, pads[k].entry, d, entry)) slot = k; else known = 1;
    }
    if (!known && slot >= 0) { old = pads[slot].dev; renewed = pads[slot].entry != entry; }
    if (!known && slot < 0 && nPads < MAX_PADS) slot = nPads++;
    if (!known && slot >= 0) {
      CFRetain(d);   // held until let go (stopDevice)
      pads[slot].dev = d; pads[slot].id = id; pads[slot].entry = entry; pads[slot].fingers = 0;
      pads[slot].w = w > 0 ? w : 15600; pads[slot].h = h > 0 ? h : 9600;
      // A new device for a trackpad held (old) keeps the one touched last: the
      // built-in one's at a wake must not take over from a Magic Trackpad, or
      // the guest, told the Magic Trackpad's size, never hears the built-in's.
      if (activePad < 0 || (!old && MTDeviceIsBuiltIn(d))) {
        activePad = slot;
        sized = tpW != pads[slot].w || tpH != pads[slot].h;
        tpW = pads[slot].w; tpH = pads[slot].h;
      }
    }
    int pw = slot >= 0 ? pads[slot].w : 0, ph = slot >= 0 ? pads[slot].h : 0;
    pthread_mutex_unlock(&padLock);
    if (sized) sendSize();   // the guests scale finger movement to this trackpad now
    if (known || slot < 0) continue;
    if (old) stopDeviceFn(old, frameCb);   // its device is gone (or did not start): let go of it
    int builtIn = MTDeviceIsBuiltIn(d);
    if (!startDevice(d, frameCb, builtIn ? "built-in trackpad" : "Magic Trackpad")) continue;
    logf_("trackpad: %s%s, %d x %d mm (%s)", builtIn ? "built-in" : "Magic Trackpad", renewed ? " again" : "", pw / 100, ph / 100,
          renewed ? "a new device for it from macOS: after sleep, or connected again" : "scroll momentum: its scrolling only, never a mouse's");
  }
  if (list) CFRelease(list);   // the devices taken are held on their own
  if (nPads) trackpadStarted = 1;
}

static void retryTrackpad(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  if (!inputPaused) startTrackpads();
}

// macOS added a multi-touch device (the built-in trackpad's, made anew at a
// wake; a Magic Trackpad or Magic Mouse connected): looked for 1 s later
// instead of at the next 10 s look. Not at once: MTDeviceStart waits for a
// busy device (up to 5 s, on this thread, the event tap's).
static int lookQueued;   // main thread
static void lookSoon(void) {
  if (lookQueued) return;
  lookQueued = 1;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    lookQueued = 0;
    if (trackpad && !inputPaused) startTrackpads();
  });
}
static void multitouchAdded(void *refcon, io_iterator_t it) {
  (void)refcon;
  io_object_t o;
  while ((o = IOIteratorNext(it))) IOObjectRelease(o);   // all of them, or no next notice comes
  lookSoon();
}
static void watchMultitouch(void) {
  IONotificationPortRef port = IONotificationPortCreate(MACH_PORT_NULL);
  io_iterator_t it = 0;
  if (!port) return;
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
  if (IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                       multitouchAdded, NULL, &it) != KERN_SUCCESS) {
    logf_("not told about new multi-touch devices: looked for every 10 s only");
    return;
  }
  io_object_t o;
  while ((o = IOIteratorNext(it))) IOObjectRelease(o);   // the ones there now (taken at start); arms it
}

// A permission taken away (checkPermissions): every trackpad and Magic Mouse
// let go, so none of them waits on frames nobody takes; startTrackpads takes
// them again. The callbacks run on MultitouchSupport's thread: the tables
// are emptied under their locks first, the devices stopped outside them.
static void stopTrackpads(void) {
  MTDeviceRef p[MAX_PADS], m[MAX_MICE];
  pthread_mutex_lock(&padLock);
  int np = nPads;
  for (int i = 0; i < np; i++) p[i] = pads[i].dev;
  nPads = 0; activePad = -1;
  pthread_mutex_unlock(&padLock);
  pthread_mutex_lock(&mouseLock);
  int nm = nMice;
  for (int i = 0; i < nm; i++) m[i] = mice[i].dev;
  nMice = 0;
  pthread_mutex_unlock(&mouseLock);
  for (int i = 0; i < np; i++) if (!isReplayDev(p[i])) stopDeviceFn(p[i], frameCb);
  for (int i = 0; i < nm; i++) if (!isReplayDev(m[i])) stopDeviceFn(m[i], mouseFrameCb);
  fingers = 0;
  if (np + nm) logf_("trackpads let go: %d trackpad%s, %d Magic Mouse", np, np == 1 ? "" : "s", nm);
}

#if GESTURES_TEST_IDENTITY
// ---- the test identity only: finger frames from a file ----
// A Mac without a trackpad (the Mac mini) cannot make the swipe out happen
// for real: its end-to-end test plays made-up frames into the real
// callbacks. OMACVM_TEST_REPLAY_DIR=<dir> at start: <dir>/next.tsv is taken
// with the capture check (renamed to playing.tsv), played on its own thread
// and removed. Lines: <seconds> pad|mouse <n> [<id> <x> <y>]... (0..1, y up,
// as MultitouchSupport gives them). Never in the helper that ships
// (GESTURES_TEST_IDENTITY: build.sh with OMACVM_HELPER_TEST=1).
static char replayDir[900];
static int replayPadDev, replayMouseDev;   // their addresses stand for the devices
static volatile int replaying;
static int isReplayDev(MTDeviceRef d) { return d == (MTDeviceRef)&replayPadDev || d == (MTDeviceRef)&replayMouseDev; }

static void replayDevices(void) {
  pthread_mutex_lock(&padLock);
  int have = 0;
  for (int i = 0; i < nPads; i++) have |= pads[i].dev == (MTDeviceRef)&replayPadDev;
  if (!have && nPads < MAX_PADS) {
    pads[nPads].dev = (MTDeviceRef)&replayPadDev; pads[nPads].id = 0; pads[nPads].fingers = 0;
    pads[nPads].w = 15600; pads[nPads].h = 9600; nPads++;
  }
  pthread_mutex_unlock(&padLock);
  pthread_mutex_lock(&mouseLock);
  have = 0;
  for (int i = 0; i < nMice; i++) have |= mice[i].dev == (MTDeviceRef)&replayMouseDev;
  if (!have && nMice < MAX_MICE) {
    mice[nMice].dev = (MTDeviceRef)&replayMouseDev; mice[nMice].id = 0; mice[nMice].sent = 0;
    mice[nMice].w = 5150; mice[nMice].h = 9050;
    mouseStateInit(&mice[nMice].st); takeReset(&mice[nMice].take); nMice++;
  }
  pthread_mutex_unlock(&mouseLock);
}

static void *replayMain(void *arg) {
  char *path = arg, line[2048];
  FILE *f = fopen(path, "r");
  double t0 = monoNow();
  int frame = 0;
  while (f && fgets(line, sizeof line, f)) {
    double t; char kind[8]; int n, off = 0;
    if (sscanf(line, "%lf %7s %d%n", &t, kind, &n, &off) != 3 || n < 0 || n > 16) continue;
    MTTouch tch[16]; memset(tch, 0, sizeof tch);
    const char *q = line + off; int k = 0;
    for (int i = 0; i < n; i++) {
      int id, used = 0; float x, y;
      if (sscanf(q, "%d %f %f%n", &id, &x, &y, &used) != 3) break;
      q += used;
      tch[k].pathIndex = tch[k].fingerID = id; tch[k].state = 4; tch[k].zTotal = 0.5f;
      tch[k].normalized.pos.x = x; tch[k].normalized.pos.y = y; k++;
    }
    double wait = t0 + t - monoNow();
    if (wait > 0) usleep((useconds_t)(wait * 1e6));
    if (!strcmp(kind, "mouse")) mouseFrameCb((MTDeviceRef)&replayMouseDev, tch, k, t, frame++);
    else frameCb((MTDeviceRef)&replayPadDev, tch, k, t, frame++);
  }
  if (f) fclose(f);
  unlink(path);
  logf_("replay: done (%d frames)", frame);
  free(path);
  replaying = 0;
  return NULL;
}

static void replayLook(void) {
  if (!replayDir[0] || replaying || inputPaused) return;
  char next[1024], playing[1024];
  snprintf(next, sizeof next, "%s/next.tsv", replayDir);
  snprintf(playing, sizeof playing, "%s/playing.tsv", replayDir);
  if (rename(next, playing)) return;
  replayDevices();
  replaying = 1;
  logf_("replay: %s", playing);
  pthread_t th;
  char *arg = strdup(playing);
  if (!arg || pthread_create(&th, NULL, replayMain, arg)) { free(arg); replaying = 0; return; }
  pthread_detach(th);
}
#else
static int isReplayDev(MTDeviceRef d) { (void)d; return 0; }
static void replayLook(void) {}
#endif

static void appActivated(void) { updateCapture(captureTimer, NULL); }

// Everything that needs the permissions: the tap is made (installTap), the
// trackpads, the timers and the listeners start. Main thread, once.
static void startRunning(void) {
  waiting = 0;
  { pthread_t th; pthread_create(&th, NULL, tapWatchdog, NULL); pthread_detach(th); }
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
    // ... and 1 s after macOS adds one (a wake makes the built-in trackpad's anew).
    watchMultitouch();
  }


  cursorTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1.0 / 120, 0, 0, updateCursor, NULL);
  CFRunLoopTimerSetTolerance(cursorTimer, 0.001);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), cursorTimer, kCFRunLoopCommonModes);
  captureTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.2, 0, 0, updateCapture, NULL);
  CFRunLoopTimerSetTolerance(captureTimer, 0.02);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), captureTimer, kCFRunLoopCommonModes);
  ns_on_app_activate(appActivated);
  // A permission taken away while we run: let go at once (checkPermissions).
  CFRunLoopTimerRef perm = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0, permissionTimer, NULL);
  CFRunLoopTimerSetTolerance(perm, 0.1);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), perm, kCFRunLoopCommonModes);

  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  initKeymap();
  loadSwipeSign();
  readFusionHost();
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) {
    if (!listenAddrs[i][0] && i != NET_FUSION) continue;
    pthread_t th; pthread_create(&th, NULL, serverThread, (void *)(intptr_t)i);
  }
  logf_(trackpad ? "running (escape: Ctrl+Option+Esc)" : "running, keys only: trackpad gestures stay with macOS");
}

// While waiting (main thread, run loop): every 3 s and when macOS's
// Accessibility list changed. Every third look also asks a new process.
static CFRunLoopTimerRef waitTimer;
static int freshAsking, freshSays = -1;
static int (*installTapFn)(void) = installTap;          // tests: stand-ins
static void (*startRunningFn)(void) = startRunning;
static void (*relaunchFn)(void) = relaunchOnce;
static int (*slowPermFn)(void) = slowPermNow;
static void waitLook(void) {
  if (!waiting) return;
  slowPerm = slowPermFn();
  int perm = permFn();
  permissionsSeen(perm);
  if (installTapFn()) {
    CFRunLoopTimerInvalidate(waitTimer);
    logf_("permissions granted");
    startRunningFn();
    return;
  }
  static int looks, newSaw;
  // A new process may make the tap and this one may not (twice in a row):
  // macOS tells only new processes. Started again, once (relaunchOnce).
  if (freshSays >= 0) {
    newSaw = (freshSays & PERM_AX) ? newSaw + 1 : 0;
    freshSays = -1;
    if (newSaw >= 2) { newSaw = 0; relaunchFn(); }
  }
  if (++looks % 3 == 0 && !freshAsking) {
    freshAsking = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      int p = freshPermFn();
      dispatch_async(dispatch_get_main_queue(), ^{ freshAsking = 0; freshSays = p; });
    });
  }
}
static void waitTick(CFRunLoopTimerRef t, void *info) { (void)t; (void)info; waitLook(); }

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--permissions")) return permissionsChild();
  logToFile();
  logf_("starting (pid %d)", (int)getpid());
  helperArgc = argc; helperArgv = argv;
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
#if GESTURES_TEST_IDENTITY
  const char *rd = getenv("OMACVM_TEST_REPLAY_DIR");
  if (rd && rd[0] == '/') { snprintf(replayDir, sizeof replayDir, "%s", rd); logf_("test identity: frames from %s/next.tsv", replayDir); }
  // SIGUSR2: the rest tap as macOS turns a tap off (a timeout), for the
  // end-to-end test of re-arming it. Test identity only.
  signal(SIGUSR2, SIG_IGN);
  static dispatch_source_t usr2;
  usr2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(usr2, ^{
    logf_("test identity: the rest tap turned off as by a timeout (%s)", restArmed ? "armed" : "not armed");
    if (restTap) CGEventTapEnable(restTap, false);
    restTapCb(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
  });
  dispatch_resume(usr2);
#endif

  tapMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
  int gestureTypes[] = { 18, 19, 20, 29, 30, 31, 32, 34 };   // rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure
  for (size_t i = 0; i < sizeof gestureTypes / sizeof *gestureTypes; i++) tapMask |= (CGEventMask)1 << gestureTypes[i];
  // Needs Accessibility (to drop events) and Input Monitoring (to see the escape
  // combo). Ask once, then wait for the grant instead of exiting, so launchd
  // does not restart us into a loop of prompts. The wait is on the run loop
  // (waitLook), so macOS can tell this process about a grant.
  CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, accessibilityChanged,
                                  CFSTR("com.apple.accessibility.api"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
  slowPerm = slowPermNow();
  if (installTap()) startRunning();
  else {
    waiting = 1;
    logf_("waiting for Accessibility and Input Monitoring permission");
    logPermissions();   // which one is missing
    clearOldGrantsOnce(permFn());
    CFStringRef keys[] = { kAXTrustedCheckOptionPrompt }; CFTypeRef vals[] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AXIsProcessTrustedWithOptions(opts);
    CFRelease(opts);
    CGRequestListenEventAccess();
    waitTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0, waitTick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), waitTimer, kCFRunLoopCommonModes);
  }
  CFRunLoopRun();
  return 0;
}
