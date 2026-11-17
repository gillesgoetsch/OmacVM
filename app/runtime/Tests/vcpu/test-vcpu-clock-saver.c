/*
 * VM CPU clock saver's rules (qemu-hvf-vcpu-clock-saver-logic.patch, ADR
 * 0073): the switch from OMACVM_VCPU_CLOCK_SAVER; nothing is made while it
 * is off; threads like QEMU's vCPU threads join one work interval, keep their
 * QoS class, priority and timer tier, go out and in again, and leave before
 * they end (a thread that ends while joined stops the process, so this test
 * would crash); a failed join is not tried again until the switch goes off;
 * the tally and the qemu.log line.
 */
#include "qemu/omacvm-vcpu-clock-saver.h"
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread/qos.h>
#include <stdio.h>

static int failed;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", msg); failed = 1; } } while (0)

typedef struct {
    qos_class_t qos;
    int prio;
    integer_t tier;
} Sched;

typedef struct {
    bool on;            /* the switch for this run */
    bool in_first, in_twice, out, in_again, out_end;
    Sched before, after;
} Result;

static Sched sched_now(void)
{
    Sched s = { 0 };
    struct sched_param sp;
    int policy;
    thread_latency_qos_policy_data_t lat = { 0 };
    mach_msg_type_number_t n = THREAD_LATENCY_QOS_POLICY_COUNT;
    boolean_t def = false;

    pthread_get_qos_class_np(pthread_self(), &s.qos, NULL);
    pthread_getschedparam(pthread_self(), &policy, &sp);
    s.prio = sp.sched_priority;
    thread_policy_get(pthread_mach_thread_np(pthread_self()), THREAD_LATENCY_QOS_POLICY,
                      (thread_policy_t)&lat, &n, &def);
    s.tier = lat.thread_latency_qos_tier;
    return s;
}

static void *vcpu(void *arg)
{
    Result *r = arg;
    OmacvmVcs s = { .joined = false };
    volatile unsigned long x = 0;

    r->before = sched_now();
    r->in_first = omacvm_vcs_follow(&s, r->on);
    for (int i = 0; i < 2000000; i++) {
        x += i;
    }
    r->in_twice = omacvm_vcs_follow(&s, r->on) && s.joined;    /* twice: still one join */
    r->out = !omacvm_vcs_follow(&s, false) && !s.joined;        /* the switch off */
    r->in_again = omacvm_vcs_follow(&s, r->on);                  /* and on again */
    r->after = sched_now();
    omacvm_vcs_follow(&s, false);       /* before the thread ends, as hvf does */
    omacvm_vcs_follow(&s, false);       /* twice: harmless */
    r->out_end = !s.joined;
    return NULL;
}

static void run(int n, bool on, Result *r)
{
    pthread_t t[10];

    for (int i = 0; i < n; i++) {
        memset(&r[i], 0, sizeof(r[i]));
        r[i].on = on;
        pthread_create(&t[i], NULL, vcpu, &r[i]);
    }
    for (int i = 0; i < n; i++) {
        pthread_join(t[i], NULL);
    }
}

/* A failed join: no new try while on; off and on again tries once more. */
static void *failing(void *arg)
{
    bool *ok = arg;
    OmacvmVcs s = { .joined = false };
    os_workgroup_t good;

    os_workgroup_cancel(omacvm_vcs_wg);         /* a join to it now fails */
    *ok = !omacvm_vcs_follow(&s, true) && s.failed && !s.joined;
    omacvm_vcs_wg = NULL;
    omacvm_vcs_make();                          /* a group a join would work with */
    good = omacvm_vcs_wg;
    *ok = *ok && good && !omacvm_vcs_follow(&s, true) && !s.joined;  /* not tried again */
    *ok = *ok && !omacvm_vcs_follow(&s, false) && !s.failed;         /* off clears it */
    *ok = *ok && omacvm_vcs_follow(&s, true) && s.joined;            /* on: tried again */
    omacvm_vcs_follow(&s, false);
    return NULL;
}

static void tally(void)
{
    OmacvmVcsTally t = { 0 };
    char line[160];
    unsigned g1, g2;

    g1 = omacvm_vcs_tally_begin(&t, 3);
    CHECK(!omacvm_vcs_tally_done(&t, g1, true), "the first of 3 vCPUs counts as the last");
    CHECK(!omacvm_vcs_tally_done(&t, g1, false), "the second of 3 vCPUs counts as the last");
    g2 = omacvm_vcs_tally_begin(&t, 3);         /* a new change before the last one followed */
    CHECK(g2 != g1, "a new change has the old number");
    CHECK(!omacvm_vcs_tally_done(&t, g1, true), "a vCPU of the old change counts for the new one");
    CHECK(!omacvm_vcs_tally_done(&t, g2, true) && !omacvm_vcs_tally_done(&t, g2, true),
          "the new change ends before its third vCPU");
    CHECK(omacvm_vcs_tally_done(&t, g2, false), "the third vCPU of 3 does not end the change");
    CHECK(t.joined == 2 && t.total == 3, "the tally does not count 2 of 3");
    CHECK(!omacvm_vcs_tally_done(&t, g2, true), "a vCPU after the last one ends the change again");
    omacvm_vcs_text(line, sizeof(line), true, &t, "the switch");
    CHECK(strcmp(line, "on, 2 of 3 vCPUs (the switch)") == 0, "the line for 2 of 3");
    omacvm_vcs_text(line, sizeof(line), false, &t, "OMACVM_VCPU_CLOCK_SAVER");
    CHECK(strcmp(line, "off (OMACVM_VCPU_CLOCK_SAVER)") == 0, "the line for off");
    g1 = omacvm_vcs_tally_begin(&t, 1);
    CHECK(omacvm_vcs_tally_done(&t, g1, true), "one vCPU does not end its change");
    omacvm_vcs_text(line, sizeof(line), true, &t, "the switch");
    CHECK(strcmp(line, "on, 1 of 1 vCPUs (the switch)") == 0, "the line for 1 of 1");
}

int main(void)
{
    Result r[10];
    char line[160];
    OmacvmVcsTally none = { .joined = 0, .total = 4 };

    unsetenv("OMACVM_VCPU_CLOCK_SAVER");
    CHECK(omacvm_vcs_env() == -1, "unset is not 'the app decides'");
    setenv("OMACVM_VCPU_CLOCK_SAVER", "1", 1);
    CHECK(omacvm_vcs_env() == 1, "1 is not on");
    setenv("OMACVM_VCPU_CLOCK_SAVER", "0", 1);
    CHECK(omacvm_vcs_env() == 0, "0 is not off");
    setenv("OMACVM_VCPU_CLOCK_SAVER", "all", 1);
    CHECK(omacvm_vcs_env() == -1, "a word other than 1 or 0 decides");
    setenv("OMACVM_VCPU_CLOCK_SAVER", "", 1);
    CHECK(omacvm_vcs_env() == -1, "an empty value decides");

    tally();

    /* Off: nothing joins, and the group is not made (AudioToolbox not loaded). */
    run(4, false, r);
    for (int i = 0; i < 4; i++) {
        CHECK(!r[i].in_first && !r[i].in_twice && !r[i].in_again, "a vCPU joined with the switch off");
        CHECK(r[i].before.qos == r[i].after.qos && r[i].before.prio == r[i].after.prio &&
              r[i].before.tier == r[i].after.tier, "the switch off changed a thread's scheduling");
    }
    CHECK(omacvm_vcs_wg == NULL && omacvm_vcs_missing == NULL, "the group was made with the switch off");

    /* On: 10 threads join one group, keep their scheduling, go out and in, leave before they end. */
    run(10, true, r);
    for (int i = 0; i < 10; i++) {
        CHECK(r[i].in_first, "a vCPU thread did not join");
        CHECK(r[i].in_twice, "a second follow while on changed the place");
        CHECK(r[i].out, "the switch off did not take the vCPU out");
        CHECK(r[i].in_again, "the switch on again did not take the vCPU back in");
        CHECK(r[i].out_end, "the vCPU did not leave before it ended");
        CHECK(r[i].before.qos == r[i].after.qos, "joining changed the thread's QoS class");
        CHECK(r[i].before.prio == r[i].after.prio, "joining changed the thread's priority");
        CHECK(r[i].before.tier == r[i].after.tier, "joining changed the thread's timer tier");
    }
    CHECK(omacvm_vcs_wg != NULL && omacvm_vcs_missing == NULL, "no group after the first join");
    /* Threads that start later (a new vCPU) join the same group. */
    run(2, true, r);
    CHECK(r[0].in_first && r[1].in_first, "a later vCPU thread did not join");

    /* The line when the group could not be made. */
    omacvm_vcs_missing = "no work interval on this macOS";
    omacvm_vcs_text(line, sizeof(line), true, &none, "the switch");
    CHECK(strcmp(line, "not available: no work interval on this macOS (the switch)") == 0,
          "the line for no group");
    omacvm_vcs_missing = NULL;

    /* Last: it cancels the group. */
    {
        pthread_t t;
        bool ok = false;

        pthread_create(&t, NULL, failing, &ok);
        pthread_join(t, NULL);
        CHECK(ok, "a failed join was tried again while on, or not again after off and on");
    }

    if (failed) {
        return 1;
    }
    printf("vcpu-clock-saver: rules ok\n");
    return 0;
}
