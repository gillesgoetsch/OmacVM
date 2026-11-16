#!/bin/bash
# No App Nap for QEMU's window process (app/runtime/patches/omacvm-cocoa-no-app-nap.patch).
#
#   src/tests/app-nap.sh            offline checks (no VM, no QEMU build): the patch is pinned,
#                                   the runtime build applies and checks it, the activity starts
#                                   before the run loop, keeps idle sleep, has its switch and log lines
#   src/tests/app-nap.sh --live PID a running OmacVM QEMU (its window out of sight: screen locked,
#                                   another Space, minimized): every vCPU thread at priority 31 or
#                                   above (napped: 4, clamped to Utility QoS: 20). Wait 2 minutes
#                                   after hiding it.
# Exit 0 when every check passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/omacvm-cocoa-no-app-nap.patch
BUILD=$R/app/runtime/build-qemu-gpu-runtime.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

if [[ ${1:-} == --live ]]; then
  pid=${2:?usage: app-nap.sh --live PID}
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  # Base priority and name of every thread (proc_pidinfo; same user, no root).
  cat > "$tmp/prio.c" <<'EOF'
#include <libproc.h>
#include <sys/proc_info.h>
#include <stdio.h>
#include <stdlib.h>
#ifndef PROC_PIDLISTTHREADIDS
#define PROC_PIDLISTTHREADIDS 28   /* xnu; not in every SDK */
#endif
int main(int c, char **v) {
    uint64_t ids[1024]; int pid = atoi(v[1]);
    int n = proc_pidinfo(pid, PROC_PIDLISTTHREADIDS, 0, ids, sizeof ids) / (int)sizeof(uint64_t);
    for (int i = 0; i < n; i++) {
        struct proc_threadinfo t;
        if (proc_pidinfo(pid, PROC_PIDTHREADID64INFO, ids[i], &t, sizeof t) > 0)
            printf("%d %s\n", t.pth_priority, t.pth_name);
    }
    return n > 0 ? 0 : 1;
}
EOF
  cc -O2 -o "$tmp/prio" "$tmp/prio.c" || { echo "cc failed"; exit 1; }
  out=$("$tmp/prio" "$pid") || { echo "no such process: $pid"; exit 1; }
  vcpus=$(grep -c ' CPU [0-9]*/HVF$' <<<"$out")
  below=$(awk '/ CPU [0-9]+\/HVF$/ && $1 < 31 { n++ } END { print n + 0 }' <<<"$out")
  echo "vCPU threads: $vcpus, below priority 31: $below"
  awk '/ CPU [0-9]+\/HVF$|qemu_main$/' <<<"$out" | sed 's/^/  prio /'
  check "QEMU has named vCPU threads" test "$vcpus" -gt 0
  check "every vCPU thread at priority 31 or above (napped: 4, Utility QoS clamp: 20)" test "$below" -eq 0
  echo "$((N - FAIL))/$N passed"; exit $((FAIL > 0))
fi

check "patch is pinned in SHA256SUMS" grep -q " omacvm-cocoa-no-app-nap.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "patch matches its pinned checksum" \
  bash -c "cd '$R/app/runtime/patches' && grep ' omacvm-cocoa-no-app-nap.patch$' SHA256SUMS | shasum -a 256 -c -"
check "runtime build applies the patch" grep -q 'patches/omacvm-cocoa-no-app-nap.patch"' "$BUILD"
check "runtime build stops when the activity is missing from cocoa.m" \
  grep -q "grep -q 'beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep'" "$BUILD"
last_cocoa=$(grep -n 'patch -d "$source_dir".*patches/omacvm-cocoa-' "$BUILD" | tail -1 | cut -d: -f2-)
check "it is the last cocoa patch (its context is QEMU's own cocoa_main)" \
  grep -q 'omacvm-cocoa-no-app-nap.patch' <<<"$last_cocoa"
# The activity: against App Nap, but the idle Mac still sleeps (not NSActivityUserInitiated,
# which holds an idle-sleep assertion), and it is kept (retained, manual reference counting).
check "activity keeps idle system sleep" grep -qF '+        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep' "$P"
check "no activity that blocks idle sleep" bash -c "! grep -qE '^\+.*NSActivity(UserInitiated|IdleSystemSleepDisabled)([^A]|$)' '$P'"
# Nor one that keeps the display on or asks for latency-critical timers (more wakeups on battery).
check "no activity that blocks display sleep or is latency critical" \
  bash -c "! grep -qE '^\+.*(NSActivityIdleDisplaySleepDisabled|NSActivityLatencyCritical|IOPMAssertion)' '$P'"
check "the patch starts exactly one activity" test "$(grep -c '^+.*beginActivityWithOptions:' "$P")" -eq 1
check "activity is retained" grep -qF 'reason:@"the virtual machine runs"] retain];' "$P"
# It starts before [NSApp run] in cocoa_main: from then on the window can be hidden.
check "cocoa_main starts it before the run loop" \
  awk '/^ static int cocoa_main\(void\)/ { m = 1 } m && /^\+    omacvm_no_app_nap\(\);/ { a = NR } m && /\[NSApp run\];/ { exit !(a && a < NR) }' "$P"
check "switch OMACVM_APP_NAP=1 lets macOS nap it" grep -qF 'getenv("OMACVM_APP_NAP")' "$P"
for line in "App Nap: off while the VM runs" "App Nap: allowed (OMACVM_APP_NAP=1)"; do
  check "patch logs 'OmacVM: $line'" grep -qF "OmacVM: $line" "$P"
done
# The patch applies to QEMU's own cocoa_main (an upstream function no other patch touches).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a/ui"
cat > "$tmp/a/ui/cocoa.m" <<'EOF'
static void cocoa_x(void)
{
    switch (0) {
    default:
        break;
    }
}

static int cocoa_main(void)
{
    COCOA_DEBUG("Main thread: entering OSX run loop\n");
    [NSApp run];
    COCOA_DEBUG("Main thread: left OSX run loop, which should never happen\n");

    abort();
}
EOF
check "patch applies to QEMU's cocoa_main" patch -d "$tmp/a" -p1 -f -s -i "$P"
check "patched cocoa_main calls it first" \
  awk '/^static int cocoa_main/ { m = 1 } m && /omacvm_no_app_nap\(\);/ { f = 1 } m && /\[NSApp run\]/ { exit !f }' "$tmp/a/ui/cocoa.m"
echo "$((N - FAIL))/$N passed"
exit $((FAIL > 0))
