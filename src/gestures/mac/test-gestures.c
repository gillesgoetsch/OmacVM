// Offline test of which VM gets the gestures (src/gestures/mac/test.sh): the
// helper's own handshake (greet) and choice (pickTargets), with the guests
// connecting on 127.0.0.1 as if on the given VM networks. No permissions, no VM.
//   test-gestures PORTFILE NET[,LOCAL,PEER]...
//       accept one guest per NET (the index into listenAddrs), then print the
//       checks' answers and the connected guests. LOCAL: the Mac address the
//       guest came in on as greet sees it (getsockname), PEER: the guest's
//       address (default: the real ones, 127.0.0.1).
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
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0) printf("live %s %s\n", clients[i].name, clients[i].ip);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0)
      printf("client %s: %s\n", clients[i].name, clients[i].net == NET_APP ? "app" : clients[i].net == NET_UTM ? "utm" : "other");
  say("UTM in front, title Windows", targetsFor(NET_UTM, "Windows"));
  say("UTM in front, title UTM VM", targetsFor(NET_UTM, "UTM VM"));
  say("app in front, title App VM", targetsFor(NET_APP, "App VM"));
  // The app VM's own client gone: a UTM VM whose name is in the app's title
  // must not take its place.
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 && clients[i].net == NET_APP) { close(clients[i].fd); clients[i].fd = -1; }
  say("app in front, title App VM, app VM gone", targetsFor(NET_APP, "App VM"));
  return 0;
}
