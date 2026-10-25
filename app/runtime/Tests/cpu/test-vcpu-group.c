/*
 * The vCPU group's rules (qemu-hvf-vcpu-group-logic.patch, ADR 0055):
 * nothing changes without OMACVM_VCPU_GROUP=1; with it, threads like QEMU's
 * vCPU threads join one work interval, keep their QoS, go in and out as the
 * rule says (light: in; busy: out for the hold; input: all out), and leave
 * before they end (a thread that ends while joined stops the process, so
 * this test would crash); a leave without a join does nothing.
 */
#include "qemu/omacvm-vcpu-group.h"
#include <pthread/qos.h>
#include <stdio.h>
#include <unistd.h>

static int failed;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); failed = 1; } } while (0)

typedef struct { bool joined; qos_class_t before, after; } Result;

static void *vcpu(void *arg)
{
    Result *r = arg;
    OmacvmVcpuGroup g = { .joined = false };
    volatile unsigned long x = 0;

    pthread_get_qos_class_np(pthread_self(), &r->before, NULL);
    r->joined = omacvm_vcpu_group_join(&g);
    for (int i = 0; i < 2000000; i++) {
        x += i;
    }
    /* out and in again on its own thread, as the loop does */
    omacvm_vcpu_group_follow(&g, false);
    if (g.joined) {
        r->joined = false;
    }
    omacvm_vcpu_group_follow(&g, true);
    omacvm_vcpu_group_follow(&g, true);   /* twice: still one join */
    r->joined = r->joined && g.joined;
    pthread_get_qos_class_np(pthread_self(), &r->after, NULL);
    omacvm_vcpu_group_leave(&g);
    omacvm_vcpu_group_leave(&g);   /* twice: harmless */
    return NULL;
}

static void run(int n, Result *r)
{
    pthread_t t[8];

    for (int i = 0; i < n; i++) {
        pthread_create(&t[i], NULL, vcpu, &r[i]);
    }
    for (int i = 0; i < n; i++) {
        pthread_join(t[i], NULL);
    }
}

static void rules(void)
{
    const int64_t ms = 1000000, tick = OMACVM_VG_TICK_MS * ms;
    int64_t out = 0, now = 10000 * ms;

    CHECK(omacvm_vcpu_group_decide(tick / 10, tick, now, 0, &out), "a light vCPU is not in the group");
    CHECK(!omacvm_vcpu_group_decide(tick / 2, tick, now, 0, &out), "a busy vCPU stays in the group");
    now += tick;
    CHECK(!omacvm_vcpu_group_decide(0, tick, now, 0, &out), "a busy vCPU comes back before the hold is over");
    now += OMACVM_VG_HOLD_MS * ms;
    CHECK(omacvm_vcpu_group_decide(0, tick, now, 0, &out), "a vCPU light again does not come back after the hold");
    CHECK(!omacvm_vcpu_group_decide(0, tick, now, now - 200 * ms, &out), "a vCPU stays in the group while input comes in");
    CHECK(omacvm_vcpu_group_decide(0, tick, now, now - (OMACVM_VG_INPUT_MS + 1) * ms, &out),
          "a vCPU does not come back after the input");
    CHECK(omacvm_vcpu_group_decide(tick * OMACVM_VG_BUSY_PCT / 100, tick, now, 0, &out), "exactly the limit counts as busy");
    CHECK(omacvm_vcpu_group_decide(5, 0, now, 0, &out), "a tick without time counts as busy");
}

int main(void)
{
    Result r[8] = {0};
    OmacvmVcpuGroup never = { .joined = false };

    rules();

    omacvm_vcpu_group_leave(&never);   /* a leave without a join */

    unsetenv("OMACVM_VCPU_GROUP");
    run(2, r);
    CHECK(!r[0].joined && !r[1].joined, "joined without OMACVM_VCPU_GROUP=1");
    CHECK(strcmp(omacvm_vcpu_group_state(), "off") == 0, "state is not off without the variable");

    setenv("OMACVM_VCPU_GROUP", "0", 1);
    run(1, r);
    CHECK(!r[0].joined, "joined with OMACVM_VCPU_GROUP=0");

    setenv("OMACVM_VCPU_GROUP", "1", 1);
    memset(r, 0, sizeof r);
    run(8, r);
    for (int i = 0; i < 8; i++) {
        CHECK(r[i].joined, "a vCPU thread did not join");
        CHECK(r[i].before == r[i].after, "joining changed the thread's QoS");
    }
    CHECK(strcmp(omacvm_vcpu_group_state(), "on") == 0, "state is not on");
    setenv("OMACVM_VCPU_GROUP", "always", 1);
    CHECK(strcmp(omacvm_vcpu_group_state(), "on (always)") == 0, "state does not say always");
    setenv("OMACVM_VCPU_GROUP", "1", 1);
    /* threads that start later (vCPU hotplug) join the same group */
    run(2, r);
    CHECK(r[0].joined && r[1].joined, "a later vCPU thread did not join");

    if (failed) {
        return 1;
    }
    printf("vcpu-group: ok (%s)\n", omacvm_vcpu_group_state());
    return 0;
}
