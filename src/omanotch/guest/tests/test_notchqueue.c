// Offline test of notchqueue.h (#849): moves of a drag are merged at the end
// of the queue, nothing else is; the three drag commands are named.
#include <stdio.h>
#include "notchqueue.h"

static int fails;
static void check(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) fails++;
}

int main(void) {
    check(nq_replaces("drag 10.0 5.0", "drag 20.0 5.0"), "a move replaces a waiting move");
    check(!nq_replaces("press 10.0 5.0", "drag 20.0 5.0"), "a move never replaces the press");
    check(!nq_replaces("drag 10.0 5.0", "release 20.0 5.0"), "the release is never merged");
    check(!nq_replaces("click 1 2 1", "click 3 4 1"), "clicks are never merged");
    check(!nq_replaces("dragon 1", "drag 1 2"), "only the command drag");
    check(!nq_replaces(NULL, "drag 1 2"), "an empty queue: added");
    check(nq_is_drag_command("press") && nq_is_drag_command("drag") && nq_is_drag_command("release"),
          "press, drag, release are the strip's drag");
    check(!nq_is_drag_command("click") && !nq_is_drag_command("pressx") && !nq_is_drag_command(NULL),
          "nothing else is");
    if (fails) { printf("%d failed\n", fails); return 1; }
    printf("all notchqueue checks passed\n");
    return 0;
}
