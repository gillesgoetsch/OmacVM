/*
 * Drag and drop's rules in QEMU's window code (ui/omacvm-drop.h, made by
 * omacvm-cocoa-drop-logic.patch), without QEMU or a display:
 *   cc -I<folder with omacvm-drop.h> test-drop.c && ./a.out
 * Run by test-drop.sh (the runtime build and CI).
 */
#include "omacvm-drop.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define EXPECT(ok, what) do { \
    if (ok) { printf("ok   %s\n", what); } else { printf("FAIL %s (line %d)\n", what, __LINE__); failures++; } \
} while (0)

static int lines_seen;
static char last_line[256];
static void on_line(const char *l, void *ctx)
{
    (void)ctx;
    lines_seen++;
    snprintf(last_line, sizeof last_line, "%s", l);
}

int main(void)
{
    OmacVMDropIn in = { .ready = true, .count = 2 };
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_TAKE, "two files, ready: taken");
    in.ready = false;
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_NOT_READY, "before the VM's hello: no drop (hello gating)");
    in = (OmacVMDropIn){ .ready = true, .count = 0 };
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_NO_FILES, "no file URLs: no drop");
    in.count = 256;
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_TAKE, "256 files: taken");
    in.count = 257;
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_TOO_MANY, "257 files: no drop");
    in = (OmacVMDropIn){ .ready = true, .count = 3, .folder = true };
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_FOLDER, "a folder in it: no drop (files only)");
    in = (OmacVMDropIn){ .ready = true, .count = 1, .busy = true };
    EXPECT(omacvm_drop_verdict(&in) == OMACVM_DROP_BUSY, "the last drop still opening: no drop");
    EXPECT(strstr(omacvm_drop_why(OMACVM_DROP_FOLDER), "folder") != NULL, "why: says folder");

    EXPECT(omacvm_drop_name_ok("a b #%.txt") && omacvm_drop_name_ok("Gr\xc3\xbc\xc3\x9f" "e.pdf"), "names: spaces, #, %, UTF-8");
    EXPECT(!omacvm_drop_name_ok("") && !omacvm_drop_name_ok(".") && !omacvm_drop_name_ok("..") &&
           !omacvm_drop_name_ok("a/b") && !omacvm_drop_name_ok("a\nb") && !omacvm_drop_name_ok("a\x7f") &&
           !omacvm_drop_name_ok(NULL), "names: empty, dots, slash, newline, DEL, none refused");
    {
        char n[257];
        memset(n, 'x', 255); n[255] = 0;
        EXPECT(omacvm_drop_name_ok(n), "names: 255 bytes ok");
        memset(n, 'x', 256); n[256] = 0;
        EXPECT(!omacvm_drop_name_ok(n), "names: 256 bytes refused");
    }
    EXPECT(!strcmp(omacvm_drop_base("/Users/me/Desktop/a.txt"), "a.txt") && !strcmp(omacvm_drop_base("a"), "a"),
           "base name of a path");

    {
        char f[OMACVM_DROP_FRAME_MAX + 4];
        const char *names[] = { "a.txt", "say \"hi\"\\.png" };
        size_t n = omacvm_drop_frame(f, sizeof f, 7, 1700000000123LL, true, names, 2, 1);
        unsigned len = (unsigned char)f[0] << 24 | (unsigned char)f[1] << 16 | (unsigned char)f[2] << 8 | (unsigned char)f[3];
        char json[512] = { 0 };
        memcpy(json, f + 4, n > 4 && n - 4 < sizeof json ? n - 4 : 0);
        EXPECT(n > 4 && len == n - 4, "frame: length prefix");
        EXPECT(!strcmp(json, "{\"v\":1,\"drop\":7,\"at\":1700000000123,\"last\":true,"
                             "\"names\":[\"a.txt\",\"say \\\"hi\\\"\\\\.png\"],\"skipped\":1}"),
               "frame: JSON with names escaped");
        const char *bad[] = { "ok", "../x" };
        EXPECT(omacvm_drop_frame(f, sizeof f, 1, 0, true, bad, 2, 0) == 0, "frame: a bad name: no frame");
        const char *many[33];
        for (int i = 0; i < 33; i++) many[i] = "n";
        EXPECT(omacvm_drop_frame(f, sizeof f, 1, 0, true, many, 33, 0) == 0, "frame: more than 32 files: no frame");
        EXPECT(omacvm_drop_frame(f, 70, 1, 0, true, names, 2, 0) == 0, "frame: too small a buffer: no frame");
        n = omacvm_drop_frame(f, sizeof f, 1, 0, false, names, 0, 0);
        EXPECT(n > 4 && strstr(f + 4, "\"names\":[]") && strstr(f + 4, "\"last\":false"), "frame: no files (the end of a drop)");
        /* 32 names of 255 bytes, every byte escaped would be 6x: the biggest real case is 32 x 255. */
        static char longn[32][256];
        const char *ln[32];
        for (int i = 0; i < 32; i++) { memset(longn[i], 'y', 255); longn[i][255] = 0; ln[i] = longn[i]; }
        EXPECT(omacvm_drop_frame(f, sizeof f, 1, 0, true, ln, 32, 0) > 32 * 255, "frame: 32 names of 255 bytes fit");
    }

    EXPECT(omacvm_drop_line("ready") == OMACVM_DROP_LINE_READY && omacvm_drop_line("wait") == OMACVM_DROP_LINE_WAIT,
           "lines: ready, wait");
    EXPECT(omacvm_drop_line("test-drop\t/a") == OMACVM_DROP_LINE_TEST && omacvm_drop_line("readyx") == OMACVM_DROP_LINE_OTHER,
           "lines: test-drop, anything else");
    {
        static OmacVMDropLines l;
        omacvm_drop_feed(&l, "rea", 3, on_line, NULL);
        EXPECT(lines_seen == 0, "framing: half a line waits");
        omacvm_drop_feed(&l, "dy\nwait\n", 8, on_line, NULL);
        EXPECT(lines_seen == 2 && !strcmp(last_line, "wait"), "framing: complete lines");
        char *big = malloc(OMACVM_DROP_LINE_MAX + 10);
        memset(big, 'z', OMACVM_DROP_LINE_MAX + 10);
        omacvm_drop_feed(&l, big, OMACVM_DROP_LINE_MAX + 10, on_line, NULL);
        omacvm_drop_feed(&l, "\nready\n", 7, on_line, NULL);
        EXPECT(lines_seen == 3 && !strcmp(last_line, "ready"), "framing: a too long line dropped whole, the next read");
        free(big);
    }
    printf(failures ? "test-drop: %d failed\n" : "test-drop: all passed\n", failures);
    return failures != 0;
}
