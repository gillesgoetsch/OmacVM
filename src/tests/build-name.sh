#!/bin/bash
# omacvm build's VM name check (src/cmd/build.sh) treats any existing folder or
# file in the VMs folder (a half-built VM without disk.img from a stopped build,
# a broken symlink, another folder) as taken, like VMPick.freeName in the app:
# --yes / --plan picks the next free name ("Omarchy 2"), explicit --vm-name
# refuses with a suggestion, and interactive mode asks for another name up front
# instead of exiting after the resources question. Throwaway HOME and settings;
# no VM, no network.
#   src/tests/build-name.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
export OMACVM_APP_ID=org.omacvm.test.build-name.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
  rm -rf "$T" "$HOME/Library/Preferences/$OMACVM_APP_ID.plist"' EXIT

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() { [[ $2 == *"$1"* ]] && echo yes || echo "$2"; }

# Stand-in OmacVM.app and swift (100 GB free, no notch): no network, no real app.
H=$T/home
mkdir -p "$H/Applications/OmacVM.app/Contents/Resources/scripts" "$H/OmacVM" "$T/bin" "$T/sysapps"
VER=$(cat "$R/src/VERSION")
cat > "$H/Applications/OmacVM.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.omacvm.app</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
</dict></plist>
EOF
touch "$H/Applications/OmacVM.app/Contents/Resources/scripts/create-vm.sh"
echo "# downloads_dir" > "$H/Applications/OmacVM.app/Contents/Resources/scripts/vm-common.sh"
printf '#!/bin/bash\n[[ $1 == -e || $1 == */mac-free-gb.swift ]] && echo 100 || echo none\n' > "$T/bin/swift"
chmod +x "$T/bin/swift"

run_plan() {   # EXTRA_ARGS... -> prints "RC NAME" (or "RC ERR" when non-zero)
  local out err rc
  err=$T/err
  out=$(HOME=$H PATH="$T/bin:$PATH" OMACVM_SYSTEM_APPS="$T/sysapps" \
    "$R/omacvm" build --plan --json --build "$@" 2>"$err")
  rc=$?
  if (( rc == 0 )); then
    printf '0 %s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["vm"]["name"])' <<<"$out")"
  else
    printf '%d %s\n' "$rc" "$(tr '\n' ' ' <"$err")"
  fi
}

# 1. Empty VMs folder: default name "Omarchy".
expect "empty VMs folder: Omarchy" "0 Omarchy" "$(run_plan)"

# 2. Half-built VM folder (vm.env, no disk.img, as left by a failed step 1).
mkdir -p "$H/OmacVM/Omarchy"
printf "NAME='Omarchy'\n" > "$H/OmacVM/Omarchy/vm.env"
expect "half-built Omarchy: --plan picks Omarchy 2" "0 Omarchy 2" "$(run_plan)"

out=$(run_plan --vm-name Omarchy)
expect "half-built Omarchy with explicit --vm-name: exit 2" "2" "${out%% *}"
expect "half-built Omarchy with explicit --vm-name: suggests Omarchy 2" yes \
  "$(has "Omarchy 2" "$out")"

# 3. Half-built Omarchy + another folder Omarchy 2: skips both to Omarchy 3.
mkdir -p "$H/OmacVM/Omarchy 2"
expect "half-built Omarchy + folder Omarchy 2: Omarchy 3" "0 Omarchy 3" "$(run_plan)"

# 4. Real VM Omarchy (with disk.img) + half-built Omarchy 2: skips to Omarchy 3.
touch "$H/OmacVM/Omarchy/disk.img"
printf "NAME='Omarchy 2'\n" > "$H/OmacVM/Omarchy 2/vm.env"
expect "real Omarchy + half-built Omarchy 2: Omarchy 3" "0 Omarchy 3" "$(run_plan)"

# 5. Case-insensitive VM collision in another VMs folder (otherVMsRoots).
rm -rf "$H/OmacVM/Omarchy" "$H/OmacVM/Omarchy 2"
mkdir -p "$T/other/work"
printf "NAME='work'\n" > "$T/other/work/vm.env"
touch "$T/other/work/disk.img"
defaults write "$OMACVM_APP_ID" otherVMsRoots -array "$T/other"
out=$(run_plan --vm-name Work)
expect "case-insensitive VM in other root: exit 2" "2" "${out%% *}"
expect "case-insensitive VM in other root: suggests Work 2" yes \
  "$(has "Work 2" "$out")"
defaults delete "$OMACVM_APP_ID" otherVMsRoots >/dev/null 2>&1 || true

# 6. Broken symlink at target path is treated as taken.
ln -s "$T/no-such-target" "$H/OmacVM/Omarchy"
expect "broken symlink Omarchy: Omarchy 2" "0 Omarchy 2" "$(run_plan)"

# 7. Interactive dry-run with a half-built Omarchy folder: asks for a new name
# up front (before Balanced) and completes with Omarchy 2.
rm -rf "$H/OmacVM/Omarchy"
mkdir -p "$H/OmacVM/Omarchy"
printf "NAME='Omarchy'\n" > "$H/OmacVM/Omarchy/vm.env"

cat > "$T/tty-run.py" <<'PY'
import os, pty, select, signal, sys, time
cmd = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "dumb"
    os.execv(cmd[0], cmd)

buf = b""
def read_until(pat, secs=10):
    global buf
    end = time.time() + secs
    while True:
        if pat in buf:
            return True
        left = end - time.time()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            return False
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return False
        if not chunk:
            return False
        buf += chunk

# Prompts: new VM name, resources (accept default Balanced), features checklist (enter),
# user name, full name.
timed_out = False
for prompt, reply in [
    (b"name for the new VM [Omarchy 2]:", b"\n"),
    (b"Choose 1-5 [2]:", b"\n"),
    (b"Return keeps these:", b"\n"),
    (b"user name [", b"\n"),
    (b"full name [", b"\n"),
]:
    if not read_until(prompt, 10):
        timed_out = True
        break
    os.write(fd, reply)

if timed_out:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    _, st = os.waitpid(pid, 0)
    os.close(fd)
    sys.stdout.buffer.write(buf)
    sys.exit(124)

end = time.time() + 10
rc = None
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            buf += chunk
    done_pid, st = os.waitpid(pid, os.WNOHANG)
    if done_pid == pid:
        rc = os.waitstatus_to_exitcode(st)
        break

if rc is None:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    rc = 124

os.close(fd)
sys.stdout.buffer.write(buf)
sys.exit(rc)
PY

pty_out=$(HOME=$H PATH="$T/bin:$PATH" OMACVM_SYSTEM_APPS="$T/sysapps" \
  python3 "$T/tty-run.py" "$R/omacvm" build --dry-run --build 2>&1)
pty_rc=$?
expect "interactive dry-run with half-built Omarchy: exit 0" 0 "$pty_rc"
expect "interactive dry-run: mentions half-built folder" yes \
  "$(has "half-built" "$pty_out")"
expect "interactive dry-run: asks for new VM name" yes \
  "$(has "name for the new VM [Omarchy 2]:" "$pty_out")"
expect "interactive dry-run: summary uses Omarchy 2" yes \
  "$(has "Omarchy 2, in OmacVM.app" "$pty_out")"

exit $fail
