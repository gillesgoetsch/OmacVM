/*
 * The rules of ui/omacvm-video-awake.h (omacvm-cocoa-video-awake-logic.patch):
 * when QEMU keeps the Mac's display on for a video in the VM, and every way
 * it lets go. Run by test-video-awake.sh.
 */
#include "omacvm-video-awake.h"

#include <stdio.h>
#include <string.h>

static int fails;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static int name(const char *s)
{
    return omacvm_va_name(s, strlen(s));
}

static OmacVMVaDo decide(OmacVMVideoAwake *v, unsigned seen, bool running, double now, OmacVMVaWhy *why)
{
    return omacvm_va_decide(v, seen, running, true, now, why);
}

static void names(void)
{
    CHECK(name("Virtual-1") == 0);
    CHECK(name("Virtual-2") == 1);
    CHECK(name("Virtual-8") == 7);
    CHECK(name("Virtual-9") == -1);      /* valid, no window here */
    CHECK(name("Virtual-999") == -1);
    CHECK(name("Virtual-1000") == -2);
    CHECK(name("Virtual-0") == -2);
    CHECK(name("Virtual-01") == -2);
    CHECK(name("Virtual-") == -2);
    CHECK(name("Virtual") == -2);
    CHECK(name("virtual-1") == -2);
    CHECK(name("Virtual-1 ") == -2);
    CHECK(name("Virtual-1x") == -2);
    CHECK(name("Virtual--1") == -2);
    CHECK(name("HDMI-A-1") == -2);
    CHECK(name("") == -2);
    CHECK(omacvm_va_name(NULL, 9) == -2);
    CHECK(omacvm_va_name("Virtual-1\0junk", 14) == -2);   /* a NUL inside */
}

static void plays(void)
{
    OmacVMVideoAwake v = { 0 };
    OmacVMVaWhy why;

    /* An old guest says nothing: never held. */
    CHECK(decide(&v, 1, true, 100, &why) == OMACVM_VA_KEEP);
    CHECK(!v.held && omacvm_va_look_at(&v, 100) == 0);

    /* A video on Virtual-1, its window seen: held at once. */
    omacvm_va_list(&v, 1, 100);
    CHECK(decide(&v, 1, true, 100, &why) == OMACVM_VA_HOLD && why == OMACVM_VA_WHY_PLAYING && v.held);
    CHECK(decide(&v, 1, true, 101, &why) == OMACVM_VA_KEEP);
    /* powerd's timeout armed again every 10 s while held. */
    CHECK(decide(&v, 1, true, 110, &why) == OMACVM_VA_RENEW);
    CHECK(decide(&v, 1, true, 115, &why) == OMACVM_VA_KEEP);
    /* The guest says it again every 10 s: still held well past one lease. */
    omacvm_va_list(&v, 1, 110);
    omacvm_va_list(&v, 1, 120);
    omacvm_va_list(&v, 1, 130);
    CHECK(decide(&v, 1, true, 140, &why) != OMACVM_VA_RELEASE && v.held);
    CHECK(omacvm_va_look_at(&v, 140) == 142);

    /* The video ends: [] releases at once. */
    omacvm_va_list(&v, 0, 141);
    CHECK(decide(&v, 1, true, 141, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_ENDED && !v.held);
    CHECK(omacvm_va_look_at(&v, 141) == 0);
    CHECK(decide(&v, 1, true, 142, &why) == OMACVM_VA_KEEP);
}

static void lease(void)
{
    OmacVMVideoAwake v = { 0 };
    OmacVMVaWhy why;

    /* The agent stops or hangs: released at the lease's end, not before. */
    omacvm_va_list(&v, 1, 0);
    CHECK(decide(&v, 1, true, 0, &why) == OMACVM_VA_HOLD);
    CHECK(decide(&v, 1, true, 29.9, &why) != OMACVM_VA_RELEASE && v.held);
    CHECK(omacvm_va_look_at(&v, 29) == 30);   /* looked at right at its end */
    CHECK(decide(&v, 1, true, 30, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_LEASE);
    /* Not again until the guest speaks again. */
    CHECK(decide(&v, 1, true, 31, &why) == OMACVM_VA_KEEP && !v.held);
    CHECK(omacvm_va_look_at(&v, 31) == 0);
    omacvm_va_list(&v, 1, 40);
    CHECK(decide(&v, 1, true, 40, &why) == OMACVM_VA_HOLD);

    /* A clock that goes back does not hold it longer. */
    OmacVMVideoAwake w = { 0 };
    omacvm_va_list(&w, 1, 100);
    CHECK(decide(&w, 1, true, 100, &why) == OMACVM_VA_HOLD);
    CHECK(decide(&w, 1, true, 50, &why) == OMACVM_VA_RELEASE);
}

static void unseen(void)
{
    OmacVMVideoAwake v = { 0 };
    OmacVMVaWhy why;

    /* Window not seen (hidden, minimised, covered, another Space, locked): never held. */
    omacvm_va_list(&v, 1, 0);
    CHECK(decide(&v, 0, true, 0, &why) == OMACVM_VA_KEEP && !v.held);
    /* Seen: held; out of sight: released at once. */
    CHECK(decide(&v, 1, true, 1, &why) == OMACVM_VA_HOLD);
    CHECK(decide(&v, 0, true, 2, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_UNSEEN);
    /* Seen again within the lease: held again. */
    CHECK(decide(&v, 1, true, 3, &why) == OMACVM_VA_HOLD);

    /* Another output's window: only its own window counts. */
    OmacVMVideoAwake w = { 0 };
    omacvm_va_list(&w, 1u << 1, 0);   /* Virtual-2 */
    CHECK(decide(&w, 1, true, 0, &why) == OMACVM_VA_KEEP && !w.held);
    CHECK(decide(&w, 1u << 1, true, 1, &why) == OMACVM_VA_HOLD);
    CHECK(decide(&w, 1, true, 2, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_UNSEEN);
    /* Two outputs: one seen is enough. */
    omacvm_va_list(&w, 3, 3);
    CHECK(decide(&w, 1u << 1, true, 3, &why) == OMACVM_VA_HOLD);
}

static void stops(void)
{
    OmacVMVideoAwake v = { 0 };
    OmacVMVaWhy why;

    /* The VM stops (QMP stop, the Mac's sleep pause, shutdown): released at once. */
    omacvm_va_list(&v, 1, 0);
    CHECK(decide(&v, 1, true, 0, &why) == OMACVM_VA_HOLD);
    CHECK(decide(&v, 1, false, 1, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_STOPPED);
    CHECK(decide(&v, 1, false, 2, &why) == OMACVM_VA_KEEP && !v.held);
    /* Running again (cont) with the lease still live: held again. */
    CHECK(decide(&v, 1, true, 3, &why) == OMACVM_VA_HOLD);

    /* The channel closes: released, and it stays so until a new list. */
    omacvm_va_forget(&v, OMACVM_VA_WHY_CHANNEL);
    CHECK(decide(&v, 1, true, 4, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_CHANNEL);
    CHECK(decide(&v, 1, true, 5, &why) == OMACVM_VA_KEEP && !v.held);
    CHECK(omacvm_va_look_at(&v, 5) == 0);

    /* The Mac goes to sleep. */
    omacvm_va_list(&v, 1, 10);
    CHECK(decide(&v, 1, true, 10, &why) == OMACVM_VA_HOLD);
    omacvm_va_forget(&v, OMACVM_VA_WHY_SLEEP);
    CHECK(decide(&v, 1, true, 11, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_SLEEP);
    /* After the wake the guest's next word holds it again; the old reason is gone. */
    omacvm_va_list(&v, 1, 20);
    CHECK(v.forgot == OMACVM_VA_WHY_NONE);
    CHECK(decide(&v, 1, true, 20, &why) == OMACVM_VA_HOLD);
    omacvm_va_list(&v, 0, 21);
    CHECK(decide(&v, 1, true, 21, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_ENDED);

    /* The switch off (OMACVM_VIDEO_AWAKE=0): never held, and let go when it goes off. */
    OmacVMVideoAwake w = { 0 };
    omacvm_va_list(&w, 1, 0);
    CHECK(omacvm_va_decide(&w, 1, true, false, 0, &why) == OMACVM_VA_KEEP && !w.held);
    CHECK(omacvm_va_decide(&w, 1, true, true, 1, &why) == OMACVM_VA_HOLD);
    CHECK(omacvm_va_decide(&w, 1, true, false, 2, &why) == OMACVM_VA_RELEASE && why == OMACVM_VA_WHY_OFF);
}

static void texts(void)
{
    for (int w = OMACVM_VA_WHY_PLAYING; w <= OMACVM_VA_WHY_SLEEP; w++) {
        CHECK(*omacvm_va_why_text((OmacVMVaWhy)w));
    }
    CHECK(!*omacvm_va_why_text(OMACVM_VA_WHY_NONE));
}

int main(void)
{
    names();
    plays();
    lease();
    unseen();
    stops();
    texts();
    if (fails) {
        printf("test-video-awake: %d FAIL\n", fails);
        return 1;
    }
    printf("test-video-awake: rules ok\n");
    return 0;
}
