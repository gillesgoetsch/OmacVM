// Offline test of which VM gets the gestures (src/gestures/mac/test.sh): the
// helper's own handshake (greet) and choice (pickTargets), with the guests
// connecting on 127.0.0.1 as if on UTM's network. No permissions, no VM.
//   test-gestures PORTFILE N   accept N guests, then print the checks' answers
#define main helper_main
#include "omacvm-gestures.c"
#undef main

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
  if (argc != 3) return 2;
  int want = atoi(argv[2]);
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
    struct greetArg *g = malloc(sizeof *g);
    // Each guest as if it came in on UTM's address; greet decides the rest.
    g->fd = c; g->net = NET_UTM; g->addr = peer.sin_addr;
    __sync_add_and_fetch(&greeting, 1);
    greet(g);
  }
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
