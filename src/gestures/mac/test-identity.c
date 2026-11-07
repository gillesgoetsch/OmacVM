// Offline test (test.sh): each Gestures takes only its own OmacVM app's VMs.
// OmacVM.app and OmacVM Test.app both run their VMs as processes named
// OmacVM; build-app.sh signs each launcher as its bundle id and its QEMU as
// "<id>.qemu". The normal Gestures takes org.omacvm.app's, the test
// identity's Gestures (built with GESTURES_TEST_IDENTITY) org.omacvm.app.test's,
// and a process without an OmacVM signature (a development build's QEMU)
// stays every Gestures'. The signature is the kernel's (real processes for
// signingID); the combo in the other identity's VM is passed on (its own
// Gestures acts on it); in its launcher it goes back into ours. No
// permissions, no VM.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;
static int fail;
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

static int fakeWindow(pid_t pid, CGWindowID win) { (void)win; return pid > 0; }
static int fakeNoMC(void) { return 0; }
static CGEventRef combo(int down) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, kCGEventSourceStateHIDSystemState);
  return e;
}
// The combo pressed with this app in front, classified as the capture check
// does: 1 = handled here (back into our full-screen VM), 0 = passed on.
static int comboHere(const char *name, const char *exe, const char *ident) {
  int foreign;
  int net = vmNetOf(name, exe, ident, &foreign);
  frontForeign = foreign;
  frontChanged(700, net, 0, "", 0, net < 0);
  int before = pendingSteps;
  CGEventRef d = combo(1), u = combo(0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL);
  tapCb(NULL, kCGEventKeyUp, u, NULL);
  int here = rd == NULL && pendingSteps == before + 1;
  CFRelease(d); CFRelease(u);
  lastComboAt = -1;   // no double press
  return here;
}

#define PROD_QEMU "/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM"
#define PROD_LAUNCHER "/Applications/OmacVM.app/Contents/MacOS/OmacVM"
#define TEST_QEMU "/Users/a/Applications/OmacVM Test.app/Contents/Resources/runtime/bin/OmacVM"
#define TEST_LAUNCHER "/Users/a/Applications/OmacVM Test.app/Contents/MacOS/OmacVM"

int main(int argc, char **argv) {
  // The stand-in QEMU below is a copy of this test run with --stand-in.
  if (argc > 1 && !strcmp(argv[1], "--stand-in")) { sleep(30); return 0; }
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  check(testIdentity() == 0, "built without GESTURES_TEST_IDENTITY and run outside its bundle: the normal identity");
  check(vmOursRule("org.omacvm.app.qemu", 0) && vmOursRule("org.omacvm.app", 0) &&
        !vmOursRule("org.omacvm.app.qemu", 1) && !vmOursRule("org.omacvm.app", 1), "OmacVM.app's VM and launcher: the normal Gestures'");
  check(vmOursRule("org.omacvm.app.test.qemu", 1) && vmOursRule("org.omacvm.app.test", 1) &&
        !vmOursRule("org.omacvm.app.test.qemu", 0) && !vmOursRule("org.omacvm.app.test", 0),
        "OmacVM Test.app's VM and launcher: the test Gestures'");
  check(!vmOursRule("org.omacvm.app.test.lane.qemu", 0) && vmOursRule("org.omacvm.app.test.lane.qemu", 1) &&
        vmOursRule("org.omacvm.app.test.lane", 1), "a lane's copy (org.omacvm.app.test.<lane>): the test Gestures', as the app's TestIdentity");
  check(vmOursRule("org.omacvm.apps", 1) && vmOursRule("org.omacvm.apps", 0), "org.omacvm.apps is no OmacVM.app signature");
  check(vmOursRule(NULL, 0) && vmOursRule(NULL, 1) && vmOursRule("qemu-system-aarch64-5555", 0) &&
        vmOursRule("qemu-system-aarch64-5555", 1), "no OmacVM signature (a development build): every Gestures'");

  // Port, settings domain and Bridge folder follow the identity at run time
  // (a release copy relabeled as the test identity is a whole test identity).
  identityTest = 0;
  check(PORT == 47830 && !strcmp(BRIDGE_DIR, "omacvm-bridge") &&
        CFStringCompare(GESTURES_DOMAIN, CFSTR("org.omacvm.gestures"), 0) == kCFCompareEqualTo,
        "normal Gestures: port 47830, org.omacvm.gestures, the Bridge's own folder");
  identityTest = 1;
  check(PORT == 47930 && !strcmp(BRIDGE_DIR, "omacvm-test-bridge") &&
        CFStringCompare(GESTURES_DOMAIN, CFSTR("org.omacvm.test.gestures"), 0) == kCFCompareEqualTo,
        "test Gestures (also a relabeled release): port 47930, org.omacvm.test.gestures, the test Bridge's folder");

  int foreign;
  identityTest = 0;   // the normal Gestures
  check(vmNetOf("OmacVM", PROD_QEMU, "org.omacvm.app.qemu", &foreign) == NET_APP && !foreign &&
        vmNetOf("OmacVM", PROD_LAUNCHER, "org.omacvm.app", &foreign) == NET_APP && !foreign,
        "normal Gestures: OmacVM.app's VM and launcher are its own");
  check(vmNetOf("OmacVM", TEST_QEMU, "org.omacvm.app.test.qemu", &foreign) < 0 && foreign,
        "normal Gestures: OmacVM Test.app's VM is the other one's");
  check(vmNetOf("OmacVM", TEST_LAUNCHER, "org.omacvm.app.test", &foreign) < 0 && !foreign,
        "normal Gestures: OmacVM Test.app's launcher is just another app");
  check(vmNetOf("OmacVM", NULL, "org.omacvm.app.test.qemu", &foreign) < 0 && foreign &&
        vmNetOf("OmacVM", NULL, "org.omacvm.app.test", &foreign) < 0 && !foreign,
        "no path: the signature alone tells the other identity's QEMU from its launcher");
  identityTest = 1;   // the test identity's Gestures
  check(vmNetOf("OmacVM", TEST_QEMU, "org.omacvm.app.test.qemu", &foreign) == NET_APP &&
        vmNetOf("OmacVM", TEST_LAUNCHER, "org.omacvm.app.test", &foreign) == NET_APP,
        "test Gestures: OmacVM Test.app's VM and launcher are its own");
  check(vmNetOf("OmacVM", PROD_QEMU, "org.omacvm.app.qemu", &foreign) < 0 && foreign,
        "test Gestures: OmacVM.app's VM is the other one's");
  check(vmNetOf("OmacVM", "/x/qemu-system-aarch64", NULL, &foreign) == NET_APP,
        "test Gestures: a VM without an OmacVM signature stays its own");
  // The retired routes' VM apps (3.4.0) are other apps: no gestures, no combo for them.
  const char *retiredApps[] = { "UTM", "prl_client_app", "VMware Fusion" }; int retiredOurs = 0;
  for (int i = 0; i < 3; i++) retiredOurs |= vmNetOf(retiredApps[i], PROD_QEMU, "org.omacvm.app.qemu", &foreign) >= 0;
  check(!retiredOurs && vmNetOf("Safari", NULL, "com.apple.Safari", &foreign) < 0, "the retired routes' VM apps and other apps: not ours");

  // The kernel's signature of real processes, and a development build's QEMU
  // (a copy of this test outside any bundle: not OmacVM-signed) as every Gestures'.
  // Not a copy of /bin/sleep: on macOS 27.0 syspolicyd crashes on such a copy, and
  // until launchd starts it again (up to 20 min) every new program on the Mac waits.
  char id[256];
  check(signingID(1, id, sizeof id) && !strcmp(id, "com.apple.xpc.launchd"), "signingID: launchd's own identifier");
  check(!signingID(-1, id, sizeof id), "signingID: no process, no identifier");
  char tmpl[] = "/tmp/omacvm-gestures-identity.XXXXXX", p[128];
  if (mkdtemp(tmpl)) {
    snprintf(p, sizeof p, "%s/qemu-system-aarch64", tmpl);
    char self[PROC_PIDPATHINFO_MAXSIZE], cmd[2 * PROC_PIDPATHINFO_MAXSIZE];
    uint32_t n = sizeof self;
    if (_NSGetExecutablePath(self, &n)) self[0] = 0;
    snprintf(cmd, sizeof cmd, "cp '%s' '%s'", self, p);
    pid_t dev = 0;
    char *args[] = {p, "--stand-in", NULL};
    if (self[0] && !system(cmd) && !posix_spawn(&dev, p, NULL, NULL, args, environ)) {
      for (int i = 0; i < 100; i++) { char e[PROC_PIDPATHINFO_MAXSIZE]; if (proc_pidpath(dev, e, sizeof e) > 0) break; usleep(20000); }
      identityTest = 0;
      check(isQemu(dev) && vmNet(dev, "OmacVM", &foreign) == NET_APP, "normal Gestures: a development build's QEMU is its own");
      identityTest = 1;
      check(isQemu(dev) && vmNet(dev, "OmacVM", &foreign) == NET_APP, "test Gestures: a development build's QEMU is its own");
      kill(dev, SIGKILL); waitpid(dev, NULL, 0);
    } else check(0, "start a stand-in QEMU");
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmpl);
    if (system(cmd)) {}
  } else check(0, "a temporary folder");

  // The escape combo with one of ours full screen on another Space.
  identityTest = 0;
  vmWindowFn = fakeWindow; missionControlOpenFn = fakeNoMC;
  frontChanged(getppid(), NET_APP, 1, "Omarchy", 0, 0);   // ours in front, full screen (a live pid)
  check(!comboHere("OmacVM", TEST_QEMU, "org.omacvm.app.test.qemu"),
        "the combo in the other identity's VM: passed on, not back into ours");
  check(comboHere("OmacVM", TEST_LAUNCHER, "org.omacvm.app.test"),
        "... in the other identity's launcher (no VM): back into ours");
  check(comboHere("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", "com.apple.Safari"),
        "... in any other app: back into ours, as before");
  return fail;
}
