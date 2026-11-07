// Offline test of which VM gets the gestures (src/gestures/mac/test.sh): the
// helper's own handshake (greet) and choice (pickTargets), with the guests
// connecting on 127.0.0.1 as if on the given VM networks. No permissions, no VM.
//   test-gestures PORTFILE NET[,LOCAL,PEER]...
//       accept one guest per NET (the index into listenAddrs), then print the
//       checks' answers and the connected guests. LOCAL: the Mac address the
//       guest came in on as greet sees it (getsockname), PEER: the guest's
//       address (default: the real ones, 127.0.0.1).
//       TEST_WAIT_GONE=1: first wait (up to 4 s) until no guest is connected
//       (their readers drop a connection that ended).
#include <arpa/inet.h>
#include <sys/socket.h>
static const char *fakeLocal;
static int test_getsockname(int fd, struct sockaddr *a, socklen_t *l) {
  int r = getsockname(fd, a, l);
  if (!r && fakeLocal && a->sa_family == AF_INET) inet_pton(AF_INET, fakeLocal, &((struct sockaddr_in *)a)->sin_addr);
  return r;
}
#define getsockname test_getsockname
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#undef getsockname

// The front app and window, as updateCapture would set them.
static unsigned targetsFor(int net, const char *title) {
  pthread_mutex_lock(&sendLock);
  frontNet = net;
  snprintf(frontTitle, sizeof frontTitle, "%s", title);
  unsigned m = pickTargets();
  pthread_mutex_unlock(&sendLock);
  return m;
}

static int liveClients(void) {
  int n = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) n += clients[i].fd >= 0;
  pthread_mutex_unlock(&sendLock);
  return n;
}

static void say(const char *what, unsigned mask) {
  printf("%s:", what);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (mask & 1u << i) printf(" %s", clients[i].name[0] ? clients[i].name : "(no name)");
  printf("\n");
}

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  int want = argc - 2;
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  // TEST_SWIPE_OUT=1: Swipe out to macOS on, so each guest gets "X on 2" with
  // its hello; its lines are read and acted on (here: no VM in front).
  if (getenv("TEST_SWIPE_OUT")) swipeOut = 1;
  int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
  socklen_t al = sizeof a;
  if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8) || getsockname(s, (struct sockaddr *)&a, &al)) return 1;
  FILE *f = fopen(argv[1], "w");
  fprintf(f, "%d\n", ntohs(a.sin_port));
  fclose(f);
  for (int k = 0; k < want; k++) {
    struct sockaddr_in peer; socklen_t pl = sizeof peer;
    int c = accept(s, (struct sockaddr *)&peer, &pl);
    if (c < 0) return 1;
    keepalive(c);
    struct greetArg *g = malloc(sizeof *g);
    // As if it came in on that network's address; greet decides the rest.
    char item[128], *local = NULL, *from = NULL;
    snprintf(item, sizeof item, "%s", argv[2 + k]);
    if ((local = strchr(item, ','))) { *local++ = 0; if ((from = strchr(local, ','))) *from++ = 0; }
    g->fd = c; g->net = atoi(item); g->addr = peer.sin_addr;
    if (from) inet_pton(AF_INET, from, &g->addr);
    fakeLocal = local;
    __sync_add_and_fetch(&greeting, 1);
    greet(g);
    printf("accepted %d\n", k + 1);
    fflush(stdout);
  }
  // The guests' lines, read on their own threads, are acted on here (the main queue).
  if (getenv("TEST_SWIPE_OUT")) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
  if (getenv("TEST_WAIT_GONE")) for (int t = 0; t < 40 && liveClients(); t++) usleep(100000);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0) printf("live %s %s\n", clients[i].name, clients[i].ip);
  for (int i = 0; i < MAX_CLIENTS; i++)   // what each guest said about its swipes ("E")
    if (clients[i].fd >= 0 && clients[i].edgeKnown) printf("edges %s %d %d ways %x %x\n", clients[i].name, clients[i].edge[0], clients[i].edge[1],
                                                            clients[i].ways[0], clients[i].ways[1]);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0)
      printf("client %s: %s\n", clients[i].name, clients[i].net == NET_APP ? "app" : "other");
  // The addresses the helper listens on: OmacVM.app's only (the retired
  // routes' networks get nothing, 3.4.0).
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) printf("listen %s\n", listenAddrs[i]);
  say("app in front, title Work VM", targetsFor(NET_APP, "Work VM"));
  say("app in front, title App VM", targetsFor(NET_APP, "App VM"));
  say("app in front, title Windows", targetsFor(NET_APP, "Windows"));
  say("no VM app in front", targetsFor(-1, "App VM"));
  return 0;
}
