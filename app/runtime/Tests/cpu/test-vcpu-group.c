/*
 * The vCPU group's rules (qemu-hvf-vcpu-group-logic.patch, ADR 0055):
 * nothing changes without OMACVM_VCPU_GROUP=1; with it, threads like QEMU's
 * vCPU threads join one work interval at their start, keep their QoS, and
 * leave before they end (a thread that ends while joined stops the process,
 * so this test would crash); a leave without a join does nothing.
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
    OmacvmVcpuGroup g;
    volatile unsigned long x = 0;

    pthread_get_qos_class_np(pthread_self(), &r->before, NULL);
    r->joined = omacvm_vcpu_group_join(&g);
    for (int i = 0; i < 2000000; i++) {
        x += i;
    }
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

int main(void)
{
    Result r[8] = {0};
    OmacvmVcpuGroup never = {0};

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
    /* threads that start later (vCPU hotplug) join the same group */
    run(2, r);
    CHECK(r[0].joined && r[1].joined, "a later vCPU thread did not join");

    if (failed) {
        return 1;
    }
    printf("vcpu-group: ok (%s)\n", omacvm_vcpu_group_state());
    return 0;
}
