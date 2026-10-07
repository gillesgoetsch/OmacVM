#!/bin/bash
# OmacVM.app's `--control-run` (ControlRun.swift): OmacVM Bridge runs the
# control centre's omacvm for the app's VMs through the app, so macOS counts
# the run as the app's (a VMs folder on an external drive). It runs only for
# OmacVM Bridge (its parent, signed like the app), only the app's own omacvm,
# only the Bridge's commands, with a fixed environment; the exit status comes
# back. Builds ControlRun.swift into a fake app (ad hoc signed) and a fake
# Bridge parent; no window, no VM, no prompt.
#   src/tests/app-control-run.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
APP=$T/Fake.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/omacvm"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omacvm.app</string>
  <key>CFBundleExecutable</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
# The app's omacvm: says what it got; update ends with 4 (rolled back).
cat > "$APP/Contents/Resources/omacvm/omacvm" <<'EOF'
#!/bin/bash
echo "args: $*"
echo "progress=${OMACVM_PROGRESS:-} foo=${FOO:-} test=${OMACVM_TEST_IDENTITY:-}"
echo "path=$PATH home=$HOME status=${OMACVM_JOB_STATUS:-} self=$0"
[[ $1 == update ]] && exit 4
exit 0
EOF
chmod 755 "$APP/Contents/Resources/omacvm/omacvm"
cp "$APP/Contents/Resources/omacvm/omacvm" "$T/other-omacvm"
cat > "$T/main.swift" <<'SWIFT'
import Foundation
if CommandLine.arguments.dropFirst().first == ControlRun.flag {
    ControlRun.main(Array(CommandLine.arguments.dropFirst(2)), test: ProcessInfo.processInfo.environment["AS_TEST"] == "1")
}
exit(3)
SWIFT
swiftc -O -o "$APP/Contents/MacOS/OmacVM" "$R/app/app/Sources/OmacVM/ControlRun.swift" "$T/main.swift" 2>"$T/cc.log" || { cat "$T/cc.log"; exit 1; }
codesign -f -s - -i org.omacvm.app "$APP" 2>/dev/null
# A parent that spawns its arguments and waits, as the Bridge does (ad hoc, like the app).
cat > "$T/parent.c" <<'EOF'
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
int main(int argc, char **argv) {
  pid_t p; int st;
  if (posix_spawn(&p, argv[1], 0, 0, argv + 1, environ)) return 99;
  waitpid(p, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 98;
}
EOF
xcrun clang -O2 -o "$T/bridge" "$T/parent.c" && codesign -f -s - -i org.omacvm.bridge "$T/bridge" 2>/dev/null
cp "$T/bridge" "$T/testbridge" && codesign -f -s - -i org.omacvm.test.bridge "$T/testbridge" 2>/dev/null
cp "$T/bridge" "$T/gestures" && codesign -f -s - -i org.omacvm.gestures "$T/gestures" 2>/dev/null
# A process that execs the signed Bridge in its own place after starting the
# app: the parent check passes, so what it passes along must not count.
cat > "$T/swap.c" <<'EOF'
#include <unistd.h>
int main(int argc, char **argv) {   /* BRIDGE APP CLI */
  if (fork() == 0) {
    usleep(500000);
    char *a[] = {argv[2], "--control-run", argv[3], "vms", 0};
    execv(argv[2], a); _exit(1);
  }
  char *b[] = {argv[1], "/bin/sleep", "3", 0};
  execv(argv[1], b); return 1;
}
EOF
xcrun clang -O2 -o "$T/swap" "$T/swap.c"
EXE=$APP/Contents/MacOS/OmacVM CLI=$APP/Contents/Resources/omacvm/omacvm
REAL_CLI=$(cd "$(dirname "$CLI")" && pwd -P)/omacvm
FIXED=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
MYHOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')
JOBS=$T/support/jobs/0123456789abcdef.rc

out=$(FOO=bar OMACVM_PROGRESS=json "$T/bridge" "$EXE" --control-run "$CLI" vms --json --app-only 2>&1); rc=$?
expect "the Bridge: runs the app's omacvm" "args: vms --json --app-only" "$(sed -n 1p <<<"$out")"
expect "fixed environment: OMACVM_PROGRESS kept, others dropped" "progress=json foo= test=" "$(sed -n 2p <<<"$out")"
expect "status 0" 0 "$rc"
"$T/bridge" "$EXE" --control-run "$CLI" update --vm A --vm-type app >/dev/null 2>&1
expect "the command's status comes back (4: rolled back)" 4 "$?"
ln -s "$APP" "$T/Link.app"
"$T/bridge" "$EXE" --control-run "$T/Link.app/Contents/Resources/omacvm/omacvm" features --json >/dev/null 2>&1
expect "the app's omacvm by another path to it: runs" 0 "$?"
out=$(AS_TEST=1 "$T/testbridge" "$EXE" --control-run "$CLI" check --json 2>&1)
expect "the test identity: the test Bridge, OMACVM_TEST_IDENTITY set" "progress= foo= test=1" "$(sed -n 2p <<<"$out")"
out=$(PATH=$T/evil:$PATH HOME=$T/evil "$T/bridge" "$EXE" --control-run "$T/Link.app/Contents/Resources/omacvm/omacvm" vms 2>&1)
expect "PATH and HOME are set here, not taken; runs by its real path" "path=$FIXED home=$MYHOME status= self=$REAL_CLI" "$(sed -n 3p <<<"$out")"
out=$(OMACVM_JOB_STATUS=$JOBS OMACVM_PROGRESS=other "$T/bridge" "$EXE" --control-run "$CLI" update --vm A 2>&1)
expect "a job status file of the Bridge's shape: kept; OMACVM_PROGRESS only json" "progress= foo= test=|path=$FIXED home=$MYHOME status=$JOBS self=$REAL_CLI" "$(sed -n '2,3p' <<<"$out" | paste -sd'|' -)"
out=$(PATH=$T/evil:/usr/bin:/bin "$T/swap" "$T/bridge" "$EXE" "$CLI" 2>&1)
expect "the Bridge exec'd in place of the caller: still the fixed PATH" "path=$FIXED" "$(grep -o '^path=[^ ]*' <<<"$out")"

refused() {   # WHAT, then the command
  local what=$1 out rc; shift
  out=$("$@" 2>&1); rc=$?
  expect "$what: refused (126)" 126 "$rc"
  [[ $out == *"args:"* ]] && { echo "FAIL $what: the omacvm ran"; fail=1; }
}
refused "started from a shell, not the Bridge" "$EXE" --control-run "$CLI" vms --json
refused "a parent signed as another helper" "$T/gestures" "$EXE" --control-run "$CLI" vms --json
refused "the installed app from the test Bridge" "$T/testbridge" "$EXE" --control-run "$CLI" vms --json
refused "another omacvm (not the app's own)" "$T/bridge" "$EXE" --control-run "$T/other-omacvm" vms --json
refused "a program, not omacvm" "$T/bridge" "$EXE" --control-run /bin/sh -c "echo args: x"
refused "a command the control centre does not run" "$T/bridge" "$EXE" --control-run "$CLI" home
refused "no command" "$T/bridge" "$EXE" --control-run "$CLI"
refused "another host (--ip)" "$T/bridge" "$EXE" --control-run "$CLI" check --vm A --ip 10.0.0.9
refused "another key (--key=)" "$T/bridge" "$EXE" --control-run "$CLI" apply --vm A --key=/tmp/k
refused "another user (--user)" "$T/bridge" "$EXE" --control-run "$CLI" check --vm A --user root
refused "a status file elsewhere" env "OMACVM_JOB_STATUS=$T/notes.txt" "$T/bridge" "$EXE" --control-run "$CLI" update --vm A
refused "a status file with .." env "OMACVM_JOB_STATUS=$T/x/jobs/../jobs/0123456789abcdef.rc" "$T/bridge" "$EXE" --control-run "$CLI" update --vm A
refused "nothing" "$T/bridge" "$EXE" --control-run
exit $fail
