/*
 * The vCPU stall note's logic and text (include/qemu/omacvm-stall.h from
 * qemu-hvf-vcpu-stall-note.patch), against simulated vCPU threads: each has a
 * CPU time that grows while it runs, a Mach state, and an hv_vcpu_run count.
 * The watchdog samples them every 2 s, every 250 ms while the header asks.
 * Checks: nothing for idle (WFI), busy or exiting vCPUs, short stalls, late
 * wakes or a paused VM; one line per episode with the vCPUs and a duration
 * within 1.25 s of the truth (the mini's 2.4 / 2.1 / 1.2 s stall of 2026-10-28,
 * and 300 random ones), memory vs CPU wording, "still" lines at 10 s and then
 * every 30 s, the status file's keys, and the app menu's line
 * (ui/omacvm-vm-stalls.h, omacvm-cocoa-vm-stalls-menu.patch); which thread
 * this is (include/qemu/omacvm-thread.h, qemu-main-loop-stall-gpu-run.patch);
 * the status between the main loop and the watchdog's thread (only the
 * watchdog writes the file, outside the lock); main loop stalls with the BQL
 * (main_*) apart from those in a GPU run (gpu_*).
 */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "qemu/omacvm-stall.h"
#include "qemu/omacvm-thread.h"
#include "ui/omacvm-vm-stalls.h"

static int failures;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failures += !ok;
}

#define S 1000000000LL
#define MS 1000000LL

/* A simulated vCPU thread: stalled in [s0, s1) (state STALL_STATE), else busy
 * (BUSY of the time on a core) or idle (state 3). */
typedef struct Sim {
    double busy;            /* share of wall time it runs when not stalled */
    int idle;               /* idle in WFI (state 3) when not stalled */
    int64_t s0[8], s1[8];   /* stall intervals */
    int stall_state[8];
    int nstall;
    int exits;              /* leaves the guest now and then (runs moves) */
} Sim;

static int sim_stalled(const Sim *v, int64_t t, int *state)
{
    for (int k = 0; k < v->nstall; k++) {
        if (t >= v->s0[k] && t < v->s1[k]) {
            *state = v->stall_state[k];
            return 1;
        }
    }
    return 0;
}

/* CPU time (us) at T: runs at BUSY outside its stalls, nothing inside */
static uint64_t sim_cpu(const Sim *v, int64_t t)
{
    double run = v->idle ? 0.0 : (double)t;
    for (int k = 0; k < v->nstall; k++) {
        int64_t a = v->s0[k], b = v->s1[k] < t ? v->s1[k] : t;
        if (!v->idle && b > a) {
            run -= (double)(b - a);
        }
    }
    if (v->idle) {
        /* idle in WFI: it runs a little when it wakes (to fault, say) */
        uint64_t us = 1000;
        for (int k = 0; k < v->nstall; k++) {
            us += t >= v->s0[k] ? 50 : 0;
        }
        return us;
    }
    return (uint64_t)(run * v->busy / 1000.0);
}

static OmacvmVcpuSample sim_sample(const Sim *v, int64_t t)
{
    OmacvmVcpuSample s = { .valid = true };
    int state;
    s.cpu_us = sim_cpu(v, t);
    if (sim_stalled(v, t, &state)) {
        s.state = state;
        s.runs = 1;
        /* frozen inside one hv_vcpu_run: the count stays */
        int64_t at = 0;
        for (int k = 0; k < v->nstall; k++) {
            if (t >= v->s0[k] && t < v->s1[k]) {
                at = v->s0[k];
            }
        }
        s.runs = v->exits ? (uint64_t)(at / (10 * MS)) * 2 + 1 : 1;
        return s;
    }
    s.state = v->idle ? OMACVM_TH_WAITING : OMACVM_TH_RUNNING;
    /* idle in the guest: the in-kernel GIC keeps it in one call */
    s.runs = v->exits ? (uint64_t)(t / (10 * MS)) * 2 + 1 : 1;
    return s;
}

typedef struct Result {
    int over, still;
    int64_t span[16];
    int cause[16];
    char vcpus[16][64];
    char line[16][600];
    int64_t still_at[16];
    int wakes;
} Result;

/*
 * The watchdog over N simulated vCPUs from 0 to END: 2 s apart, 250 ms while
 * asked, first wake at FIRST. LATE_AT: one wake that is late; PAUSED: no
 * samples looked at between those times (the VM is not running).
 */
static void run(const Sim *v, int n, int64_t first, int64_t end, int64_t late_at,
                int64_t pause0, int64_t pause1, Result *r, OmacvmStallStatus *st)
{
    static OmacvmStallMonitor m;
    OmacvmMacMemory mac = { .free_mb = 300, .vm_mb = 51 * 1024, .vm_compressed_mb = 20 * 1024,
                            .pressure = 1, .load = 126 };
    int64_t t = first, wait = 0;
    int late_done = 0;

    omacvm_stall_reset(&m);
    memset(r, 0, sizeof(*r));
    while (t < end) {
        OmacvmVcpuSample s[OMACVM_STALL_MAX_VCPUS];
        int what;

        r->wakes++;
        if ((late_at && !late_done && t >= late_at) || (t >= pause0 && t < pause1)) {
            late_done |= t >= late_at;
            omacvm_stall_reset(&m);
            wait = 0;
        } else {
            for (int i = 0; i < n; i++) {
                s[i] = sim_sample(&v[i], t);
            }
            what = omacvm_stall_step(&m, s, n, t, &wait);
            if (what != OMACVM_STALL_NOTHING && r->over + r->still < 16) {
                int k = r->over + r->still;
                omacvm_stall_line(&m, what, &mac, r->line[k], sizeof(r->line[k]));
                if (what == OMACVM_STALL_OVER) {
                    r->span[r->over] = m.ep.longest;
                    r->cause[r->over] = m.ep.cause;
                    omacvm_stall_vcpu_list(&m.ep, ",", r->vcpus[r->over], sizeof(r->vcpus[0]));
                    r->over++;
                    if (st) {
                        omacvm_stall_status_add(st, &m, &mac, 1761637419);
                    }
                } else {
                    r->still_at[r->still++] = m.ep.longest;
                }
            }
        }
        t += wait > 0 ? wait : 2 * S;
    }
}

/* The watchdog's thread for case 16: takes the status when it changed and
 * "writes" it after the take, on a slow disk (1.5 s a write). */
static OmacvmStallStore store = OMACVM_STALL_STORE_INIT;
static int writing, writes, lock_free_in_write, stop_writer;
static char written[1024];

static void *watchdog_writer(void *arg)
{
    (void)arg;
    while (!__atomic_load_n(&stop_writer, __ATOMIC_ACQUIRE)) {
        OmacvmStallStatus st;
        if (omacvm_stall_store_take(&store, &st)) {
            if (pthread_mutex_trylock(&store.lock) == 0) {
                lock_free_in_write++;
                pthread_mutex_unlock(&store.lock);
            }
            __atomic_store_n(&writing, 1, __ATOMIC_RELEASE);
            usleep(1500000);
            omacvm_stall_status_text(&st, written, sizeof(written));
            __atomic_add_fetch(&writes, 1, __ATOMIC_RELEASE);
            __atomic_store_n(&writing, 0, __ATOMIC_RELEASE);
        }
        usleep(10000);
    }
    return NULL;
}

static int64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * S + ts.tv_nsec;
}

static void *other_thread(void *arg)
{
    uintptr_t *ids = arg;

    ids[0] = omacvm_thread_self();
    ids[1] = omacvm_thread_self();
    ids[2] = (uintptr_t)getpid();
    return NULL;
}

int main(void)
{
    Sim v[16];
    Result r;
    char what[600];

    /* 1: an idle VM (14 vCPUs in WFI), 30 min: nothing, no fast wakes */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 14; i++) {
        v[i].idle = 1;
        v[i].busy = 1;
    }
    run(v, 14, 0, 1800 * S, 0, 0, 0, &r, NULL);
    snprintf(what, sizeof(what), "idle VM, 30 min: %d lines, %d wakes (one per 2 s: %d)",
             r.over + r.still, r.wakes, 900);
    check(r.over + r.still == 0 && r.wakes == 900, what);

    /* 2: busy vCPUs, some leaving the guest often: nothing */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 14; i++) {
        v[i].busy = 0.3 + 0.05 * i;
        v[i].exits = i & 1;
    }
    run(v, 14, 0, 600 * S, 0, 0, 0, &r, NULL);
    snprintf(what, sizeof(what), "busy vCPUs, 10 min: %d lines", r.over + r.still);
    check(r.over + r.still == 0 && r.wakes == 300, what);

    /* 3: the mini, 2026-10-28 10:44:59: cpu7 2.39 s, cpu6 2.07 s, cpu2 1.23 s blocked
     * in the kernel (state 4) at once, the other 7 of 10 ran */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 10; i++) {
        v[i].busy = 0.6;
    }
    int64_t at = 1000 * S + 377 * MS;
    v[7].s0[0] = at; v[7].s1[0] = at + 2390 * MS; v[7].stall_state[0] = 4; v[7].nstall = 1;
    v[6].s0[0] = at + 150 * MS; v[6].s1[0] = at + 2220 * MS; v[6].stall_state[0] = 4; v[6].nstall = 1;
    v[2].s0[0] = at + 900 * MS; v[2].s1[0] = at + 2130 * MS; v[2].stall_state[0] = 4; v[2].nstall = 1;
    OmacvmStallStatus st;
    memset(&st, 0, sizeof(st));
    run(v, 10, 0, 1100 * S, 0, 0, 0, &r, &st);
    snprintf(what, sizeof(what), "the mini's stall: %d episode, vCPUs %s, about %.2f s (truth 2.39 s), "
             "cause %d", r.over, r.vcpus[0], r.span[0] / 1e9, r.cause[0]);
    check(r.over == 1 && r.still == 0 && !strcmp(r.vcpus[0], "2,6,7") &&
          fabs(r.span[0] / 1e9 - 2.39) <= 1.25 && r.cause[0] == OMACVM_STALL_CAUSE_MEMORY, what);
    printf("  line: %s\n", r.line[0]);
    check(strstr(r.line[0], "OmacVM: stall: vCPUs 2, 6, 7 stood still for about ") &&
          strstr(r.line[0], ", blocked in macOS's kernel waiting for memory (Mac: 0.3 GB free, "
                 "pressure normal; the VM holds 51 GB, 20 GB of it compressed by macOS)"),
          "the memory line names the vCPUs, the cause and the Mac's memory");
    char text[1024];
    omacvm_stall_status_text(&st, text, sizeof(text));
    check(strstr(text, "stalls=1\n") && strstr(text, "last_cause=memory\n") &&
          strstr(text, "last_vcpus=2,6,7\n") && strstr(text, "last_vm_mb=52224\n") &&
          strstr(text, "last_at=1761637419\n") && strstr(text, "gpu_stalls=0\n"),
          "the status file has the episode");

    /* 4: one vCPU that gets no Mac core for 3 s (runnable, state 1) */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 4; i++) {
        v[i].busy = 0.9;
    }
    v[3].s0[0] = 50 * S + 500 * MS; v[3].s1[0] = 53 * S + 500 * MS; v[3].stall_state[0] = 1;
    v[3].nstall = 1;
    run(v, 4, 0, 80 * S, 0, 0, 0, &r, NULL);
    printf("  line: %s\n", r.over ? r.line[0] : "(none)");
    snprintf(what, sizeof(what), "no Mac core for 3 s: %d line, about %.1f s, \"for a Mac core\"",
             r.over, r.over ? r.span[0] / 1e9 : 0);
    check(r.over == 1 && r.cause[0] == OMACVM_STALL_CAUSE_CPU &&
          fabs(r.span[0] / 1e9 - 3.0) <= 1.25 &&
          strstr(r.line[0], "OmacVM: stall: vCPU 3 waited ") &&
          strstr(r.line[0], " for a Mac core (the Mac's CPUs are busy: load average 126)"), what);

    /* 5: a 0.6 s memory stall: no line (below 1 s) */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 4; i++) {
        v[i].busy = 0.5;
    }
    v[1].s0[0] = 20 * S - 100 * MS; v[1].s1[0] = 20 * S + 500 * MS; v[1].stall_state[0] = 4;
    v[1].nstall = 1;
    run(v, 4, 0, 40 * S, 0, 0, 0, &r, NULL);
    check(r.over == 0 && r.still == 0, "a 0.6 s stall: no line");

    /* 6: the user's 60 s (4 vCPUs of 14): "still" at 10 s and 40 s, then one line */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 14; i++) {
        v[i].busy = 0.2;
    }
    int cpus[] = { 1, 2, 3, 8 };
    for (int k = 0; k < 4; k++) {
        Sim *c = &v[cpus[k]];
        c->s0[0] = 100 * S + 300 * MS + k * 100 * MS;
        c->s1[0] = 160 * S + 800 * MS;
        c->stall_state[0] = 4;
        c->nstall = 1;
    }
    run(v, 14, 0, 200 * S, 0, 0, 0, &r, NULL);
    for (int k = 0; k < r.over + r.still; k++) {
        printf("  line: %s\n", r.line[k]);
    }
    snprintf(what, sizeof(what), "a 60.5 s stall of vCPUs 1, 2, 3, 8: %d still lines (at %.0f s, %.0f s), "
             "one line, about %.1f s", r.still, r.still ? r.still_at[0] / 1e9 : 0,
             r.still > 1 ? r.still_at[1] / 1e9 : 0, r.over ? r.span[0] / 1e9 : 0);
    check(r.still == 2 && r.over == 1 && !strcmp(r.vcpus[0], "1,2,3,8") &&
          r.still_at[0] >= 10 * S && r.still_at[0] < 11 * S &&
          r.still_at[1] >= 40 * S && r.still_at[1] < 41 * S &&
          fabs(r.span[0] / 1e9 - 60.5) <= 1.25 &&
          strstr(r.line[0], "OmacVM: stall: vCPUs 1, 2, 3, 8 still stand (10 s so far)"), what);

    /* 7: a late wake inside the stall (QEMU stopped, App Nap): that episode gets no line */
    run(v, 14, 0, 200 * S, 130 * S, 0, 0, &r, NULL);
    snprintf(what, sizeof(what), "late wake inside a stall: %d lines after it", r.over);
    check(r.over == 1 && r.span[0] < 31 * S, "late wake inside a stall: only what came after it, "
          "measured from then");

    /* 8: the VM paused across the stall: no line */
    run(v, 14, 0, 200 * S, 0, 90 * S, 170 * S, &r, NULL);
    check(r.over == 0 && r.still == 0, "the VM paused across the stall: no line");

    /* 9: a vCPU idle in WFI (state 3) whose thread waits: never a stall, even long */
    memset(v, 0, sizeof(v));
    v[0].idle = 1;
    v[0].busy = 1;
    v[0].s0[0] = 10 * S; v[0].s1[0] = 70 * S; v[0].stall_state[0] = 3; v[0].nstall = 1;
    run(v, 1, 0, 100 * S, 0, 0, 0, &r, NULL);
    check(r.over == 0 && r.still == 0, "a vCPU waiting in WFI for 60 s: no line");

    /* 10: 300 random memory stalls of 2.25-20 s at random times, one at a time,
     * random vCPUs of 10: every one found, each within 1.25 s. (One of 2-2.25 s
     * can end before the 250 ms look that would see it stand: a gap of 2 s
     * between two wakes hides at most 2.25 s.) */
    srand(42);
    int found = 0, close_enough = 0;
    double worst = 0;
    for (int k = 0; k < 300; k++) {
        memset(v, 0, sizeof(v));
        for (int i = 0; i < 10; i++) {
            v[i].busy = 0.05 + (rand() % 90) / 100.0;
            v[i].exits = rand() & 1;
        }
        int c = rand() % 10;
        int64_t s0 = 30 * S + (int64_t)(rand() % 4000) * MS;
        int64_t len = 2250 * MS + (int64_t)(rand() % 17750) * MS;
        v[c].s0[0] = s0; v[c].s1[0] = s0 + len; v[c].stall_state[0] = 4; v[c].nstall = 1;
        run(v, 10, (int64_t)(rand() % 2000) * MS, s0 + len + 10 * S, 0, 0, 0, &r, NULL);
        char want[8];
        snprintf(want, sizeof(want), "%d", c);
        if (r.over != 1 || strcmp(r.vcpus[0], want)) {
            printf("  missed: vCPU %d (busy %.2f, exits %d) stalled %.3f s from %.3f s: %d lines%s%s\n",
                   c, v[c].busy, v[c].exits, len / 1e9, s0 / 1e9, r.over,
                   r.over ? ", vCPUs " : "", r.over ? r.vcpus[0] : "");
        }
        if (r.over == 1 && !strcmp(r.vcpus[0], want)) {
            double err = fabs((r.span[0] - len) / 1e9);
            found++;
            close_enough += err <= 1.25;
            if (err > worst) {
                worst = err;
            }
        }
    }
    snprintf(what, sizeof(what), "300 random stalls of 2.25-20 s: %d found with the right vCPU, %d within "
             "1.25 s (worst %.2f s)", found, close_enough, worst);
    check(found == 300 && close_enough == 300, what);

    /* 12: paging that is not a stall: 14 vCPUs (busy 20-100 %, idle in WFI,
     * exiting), each with 8 waits for memory of 5-400 ms at random times over
     * 2 min: no line. (A vCPU that is runnable all the time with little CPU is
     * waiting for a core: that is case 4, a stall.) */
    int lines = 0;
    for (int round = 0; round < 50; round++) {
        memset(v, 0, sizeof(v));
        for (int i = 0; i < 14; i++) {
            v[i].busy = 0.2 + (rand() % 80) / 100.0;
            v[i].idle = rand() % 3 == 0;
            v[i].exits = rand() & 1;
            v[i].nstall = 8;
            for (int k = 0; k < 8; k++) {
                v[i].s0[k] = (int64_t)(k * 15000 + rand() % 14000) * MS;
                v[i].s1[k] = v[i].s0[k] + (5 + rand() % 395) * MS;
                v[i].stall_state[k] = 4;
            }
        }
        run(v, 14, (int64_t)(rand() % 2000) * MS, 120 * S, 0, 0, 0, &r, NULL);
        lines += r.over + r.still;

    }
    snprintf(what, sizeof(what), "paging waits of 5-400 ms (50 VMs x 14 vCPUs x 8, 2 min): %d lines",
             lines);
    check(lines == 0, what);

    /* 13: a vCPU idle in WFI that wakes and waits 20 s for memory: found; its
     * start is taken as late as it can be (no CPU rate to go by), so the time
     * is short by at most the 2 s between two looks */
    memset(v, 0, sizeof(v));
    for (int i = 0; i < 4; i++) {
        v[i].idle = 1;
        v[i].busy = 1;
    }
    v[2].s0[0] = 40 * S + 700 * MS; v[2].s1[0] = 60 * S + 700 * MS; v[2].stall_state[0] = 4;
    v[2].nstall = 1;
    run(v, 4, 0, 90 * S, 0, 0, 0, &r, NULL);
    snprintf(what, sizeof(what), "an idle vCPU's 20 s wait for memory: %d line, about %.1f s",
             r.over, r.over ? r.span[0] / 1e9 : 0);
    check(r.over == 1 && !strcmp(r.vcpus[0], "2") && r.span[0] <= 20 * S + 250 * MS &&
          r.span[0] >= 18 * S - 250 * MS, what);

    /* 11: GPU stalls and odd text in the status file */
    memset(&st, 0, sizeof(st));
    omacvm_stall_status_gpu(&st, 2500, "VTDecompressionSessionCreate (from session_create)\n=x");
    omacvm_stall_status_gpu(&st, 1700, "glFinish");
    omacvm_stall_status_text(&st, text, sizeof(text));
    check(strstr(text, "gpu_stalls=2\n") && strstr(text, "gpu_longest_ms=2500\n") &&
          strstr(text, "gpu_last_where=glFinish\n") && strstr(text, "stalls=0\n"),
          "GPU stalls in the status file");
    omacvm_stall_status_gpu(&st, 10, "a\nb\x01" "c");
    omacvm_stall_status_text(&st, text, sizeof(text));
    check(strstr(text, "gpu_last_where=a?b?c\n") != NULL, "a where with control characters stays one line");

    /* 14: the app menu's line */
    char menu[200];
    memset(&st, 0, sizeof(st));
    check(!omacvm_stall_menu_line(&st, menu, sizeof(menu)), "no stall: no menu line");
    st.stalls = 2;
    st.longest_ms = 58000;
    st.longest_cause = OMACVM_STALL_CAUSE_MEMORY;
    check(omacvm_stall_menu_line(&st, menu, sizeof(menu)) &&
          !strcmp(menu, "The VM stood still 2 times (longest 58 s): the Mac ran out of memory"),
          "menu line: memory");
    st.stalls = 1;
    st.longest_ms = 2100;
    st.longest_cause = OMACVM_STALL_CAUSE_CPU;
    check(omacvm_stall_menu_line(&st, menu, sizeof(menu)) &&
          !strcmp(menu, "The VM waited for the Mac's processors 1 time (longest 2.1 s)"),
          "menu line: no Mac core");
    memset(&st, 0, sizeof(st));
    omacvm_stall_status_gpu(&st, 2500, "glFinish");
    check(omacvm_stall_menu_line(&st, menu, sizeof(menu)) &&
          !strcmp(menu, "The VM's graphics stood still 1 time (longest 2.5 s)"),
          "menu line: graphics only");

    /* 15: which thread this is (the watchdog's notes, virtio-gpu's runs): the
     * main loop's id differs from another thread's, stays the same within one;
     * getpid() (qemu_get_thread_id() on macOS) is the same for both */
    uintptr_t mine = omacvm_thread_self(), theirs[3] = { 0, 0, 0 };
    pthread_t th;
    check(!pthread_create(&th, NULL, other_thread, theirs) && !pthread_join(th, NULL),
          "a second thread ran");
    snprintf(what, sizeof(what), "thread ids: this %#lx, the other %#lx (twice %#lx), "
             "getpid() %ld in both: %s", (unsigned long)mine, (unsigned long)theirs[0],
             (unsigned long)theirs[1], (long)getpid(),
             theirs[2] == (uintptr_t)getpid() ? "yes" : "no");
    check(mine && theirs[0] && mine != theirs[0] && theirs[0] == theirs[1] &&
          mine == omacvm_thread_self(), what);

    /* 16: the status between threads: the main loop (which may hold the BQL)
     * records a GPU-run stall in memory and returns at once while the
     * watchdog's thread writes the file on a slow disk; that write runs with
     * the lock let go; only the watchdog's takes write, the zeros first */
    pthread_t w;
    int64_t t0, rec_ns, copy_ns;
    OmacvmStallStatus copy;
    check(!pthread_create(&w, NULL, watchdog_writer, NULL), "the watchdog's writer runs");
    for (int i = 0; i < 300 && !__atomic_load_n(&writing, __ATOMIC_ACQUIRE); i++) {
        usleep(10000);
    }
    t0 = mono_ns();
    omacvm_stall_store_loop(&store, true, 2548, "g_usleep (from virtio_gpu_process_cmdq)");
    rec_ns = mono_ns() - t0;
    t0 = mono_ns();
    omacvm_stall_store_copy(&store, &copy);
    copy_ns = mono_ns() - t0;
    for (int i = 0; i < 500 && __atomic_load_n(&writes, __ATOMIC_ACQUIRE) < 2; i++) {
        usleep(10000);
    }
    __atomic_store_n(&stop_writer, 1, __ATOMIC_RELEASE);
    pthread_join(w, NULL);
    snprintf(what, sizeof(what), "while the watchdog writes (1.5 s): the main loop's record "
             "took %.2f ms, a copy %.2f ms; %d writes (the zeros, then the stall), %d with the "
             "lock free", rec_ns / 1e6, copy_ns / 1e6, writes, lock_free_in_write);
    check(rec_ns < 50 * MS && copy_ns < 50 * MS && copy.gpu_stalls == 1 && writes == 2 &&
          lock_free_in_write == 2 && strstr(written, "gpu_stalls=1\n") &&
          strstr(written, "gpu_longest_ms=2548\n"), what);

    /* 17: a main loop stall with the BQL held (the idle row of 2026-10-28 on the
     * swapping mini: "main loop stalled for 2.1 s with the BQL held (the VM
     * waits); where: close < qemu_memfd_free < ... < qemu_free_displaysurface",
     * over after 2.2 s): counted apart from GPU runs, in the file and the menu */
    OmacvmStallStore s17 = OMACVM_STALL_STORE_INIT;
    OmacvmStallStatus st17;
    omacvm_stall_store_loop(&s17, false, 2214, "close (from qemu_memfd_free)");
    check(omacvm_stall_store_take(&s17, &st17), "a main loop stall changes the status");
    omacvm_stall_status_text(&st17, text, sizeof(text));
    check(strstr(text, "main_stalls=1\n") && strstr(text, "main_longest_ms=2214\n") &&
          strstr(text, "main_last_where=close (from qemu_memfd_free)\n") &&
          strstr(text, "gpu_stalls=0\n") && !strncmp(text, "stalls=0\n", 9),
          "the 2.2 s close() with the BQL: main_stalls=1, main_longest_ms=2214, its where");
    check(omacvm_stall_menu_line(&st17, menu, sizeof(menu)) &&
          !strcmp(menu, "The VM stood still 1 time (longest 2.2 s): QEMU was busy"),
          "menu line: QEMU's main loop with the BQL");
    omacvm_stall_store_loop(&s17, true, 2500, "glFinish");
    omacvm_stall_store_copy(&s17, &st17);
    check(st17.main_stalls == 1 && st17.gpu_stalls == 1 && omacvm_stall_menu_line(&st17, menu, sizeof(menu)) &&
          !strcmp(menu, "The VM stood still 1 time (longest 2.2 s): QEMU was busy"),
          "a GPU run's stall goes to gpu_*; the menu names the VM's wait first");

    if (failures) {
        printf("vcpu stall: %d checks FAILED\n", failures);
        return 1;
    }
    printf("vcpu stall: all checks passed\n");
    return 0;
}
