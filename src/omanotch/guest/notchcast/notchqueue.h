// Omanotch's command queue (notchcast.c): what the Mac's strip sends for the
// bar copy, apart from the Wayland code so it is tested offline
// (tests/test_notchqueue.c).
#pragma once
#include <string.h>

// A drag from the strip (#849) sends a move per mouse event, and each runs a
// `qs ipc` process in the worker (~25 ms): a new move replaces a move still
// waiting at the end of the queue, so the bar follows the newest point and
// the release is never held behind old moves. Nothing else is merged.
static inline int nq_replaces(const char *last, const char *line) {
    return last && line && !strncmp(last, "drag ", 5) && !strncmp(line, "drag ", 5);
}

// The strip's left button (#849): "press X Y", "drag X Y", "release X Y".
static inline int nq_is_drag_command(const char *c) {
    return c && (!strcmp(c, "press") || !strcmp(c, "drag") || !strcmp(c, "release"));
}
