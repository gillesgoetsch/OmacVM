#!/bin/bash
# omacvm-vdecd (Chromium video) comes back by itself: a GPU that is not usable
# at boot is tried again (the daemon waits longer each time, exit 4, no storm,
# and a crash after it was ready restarts in 2 s again); a pacman update
# builds it again when FFmpeg's soname changed and starts it when it was down;
# omacvm check says why it is down. No VM needed: vdecd.sh runs with ldd,
# readelf, systemctl, journalctl, cc and pkg-config replaced. On Linux with
# the daemon's build libraries (CI's guest job) the real daemon is built and
# its GPU waits are timed too.
#   src/tests/vdecd-down.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/vdec/guest
T=$(mktemp -d "${TMPDIR:-/tmp}/vdecd-down.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() {   # WHAT FILE TEXT
  if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' not in ${2#"$R"/}"; fail=1; fi
}

# ---------- the real daemon (Linux with its build libraries only) ----------
if [[ $(uname) == Linux ]] && pkg-config --exists libva gbm egl glesv2 libavcodec libsystemd 2>/dev/null &&
   [[ ! -e /dev/dri/renderD128 ]]; then
  if OMACVM_VDECD_LOG=$T/real.log "$G/vdecd.sh" build "$T/real"; then
    echo "ok   daemon builds"
    # No render node here: the GPU is not usable. Run 1 exits at once, run 2
    # after 2 s (4 s with the unit's RestartSec); a stale status goes.
    mkdir "$T/run"; echo "H.264" > "$T/run/status"
    for want in "4 0 1" "4 2 2"; do
      t0=$(date +%s%3N); RUNTIME_DIRECTORY=$T/run "$T/real" 2>> "$T/real.err"; rc=$?
      waited=$((($(date +%s%3N) - t0 + 500) / 1000))
      expect "daemon: GPU not usable, try ${want##* }: exit, wait, count" "$want" \
        "$rc $waited $(cat "$T/run/gpu-tries" 2>/dev/null)"
    done
    x=1; [[ -e $T/run/status ]] || x=0; expect "daemon: no status from an earlier run" 0 $x
    has "daemon: says the GPU is not usable" "$T/real.err" "the GPU is not usable (open on /dev/dri/renderD128 failed)"
    # With the real unit under systemd (CI only: it installs into the system).
    if [[ ${OMACVM_VDECD_SYSTEMD:-} == 1 ]]; then
      sudo install -m755 "$T/real" /usr/local/bin/omacvm-vdecd
      getent group render >/dev/null || sudo groupadd -r render
      sudo useradd -r -M -s /usr/sbin/nologin omacvm-vdec 2>/dev/null
      grep -v '^ConditionPathExists=' "$G/omacvm-vdecd.service" | sudo tee /etc/systemd/system/omacvm-vdecd.service >/dev/null
      sudo systemctl daemon-reload && sudo systemctl start omacvm-vdecd
      # Starts at 0 s, 2 s (no wait), 6 s (waits 2 s before), then waits 6 s.
      sleep 8
      sd() { systemctl show -p "$1" --value omacvm-vdecd; }
      expect "systemd: restarted twice, the 3rd run waits, count kept" "2 running 3" \
        "$(sd NRestarts) $(sd SubState) $(sudo cat /run/omacvm-vdec/gpu-tries)"
      expect "systemd: why = this run's line" \
        "the GPU is not usable (open on /dev/dri/renderD128 failed): apps decode on the CPU, trying again" \
        "$(sudo "$G/vdecd.sh" why)"
      inv=$(sd InvocationID)
      sudo "$G/vdecd.sh" hook; sleep 1
      x=1; [[ $(sd InvocationID) != "$inv" ]] && x=0
      expect "systemd: the hook starts a daemon that waits for the GPU again" 0 $x
      sudo systemctl stop omacvm-vdecd
      x=1; [[ -e /run/omacvm-vdec ]] || x=0; expect "systemd: stopped, the count goes" 0 $x
    fi
  else
    cat "$T/real.log"; echo "FAIL daemon builds"; fail=1
  fi
else
  echo "skip the real daemon (Linux with libva, gbm, egl, glesv2, libavcodec and libsystemd, no GPU)"
fi

# ---------- the stand-ins ----------
# LDD: what ldd prints; NEEDED: the binary's own libraries (readelf);
# STATE: active|auto-restart|dead; RESULT: systemd's Result; JOURNAL: the
# unit's lines in its last run (invocation "last"; an earlier run said
# "closed after 120 frames"); CC: ok|fail. CALLS: what ran.
mkdir -p "$T/bin"
cat > "$T/bin/ldd" <<'EOF'
#!/bin/bash
printf '%s\n' "$LDD"
EOF
cat > "$T/bin/readelf" <<'EOF'
#!/bin/bash
for l in $NEEDED; do echo " 0x0000000000000001 (NEEDED)             Shared library: [$l]"; done
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "is-active -q") [[ $STATE == active ]] ;;
  "show -p") case $3 in SubState) echo "$STATE" ;; Result) echo "$RESULT" ;; InvocationID) echo last ;;
             ExecMainStatus) echo 1 ;; esac ;;
  *) echo "systemctl $*" >> "$CALLS" ;;
esac
EOF
cat > "$T/bin/journalctl" <<'EOF'
#!/bin/bash
if [[ " $* " == *" _SYSTEMD_INVOCATION_ID=last "* ]]; then printf '%s\n' "$JOURNAL"
else echo "vdecd: inst 3: closed after 120 frames"; fi
EOF
cat > "$T/bin/cc" <<'EOF'
#!/bin/bash
echo "cc" >> "$CALLS"
[[ $CC == ok ]] || exit 1
while (( $# )); do [[ $1 == -o ]] && echo new > "$2"; shift; done
EOF
cat > "$T/bin/pkg-config" <<'EOF'
#!/bin/bash
echo -lavcodec
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" CALLS=$T/calls NEEDED="libavcodec.so.62 libva.so.2"
export OMACVM_VDECD_BIN=$T/omacvm-vdecd OMACVM_VDECD_UNIT=$T/omacvm-vdecd.service OMACVM_VDECD_LOG=$T/build.log
export OMACVM_VDECD_STATUS=$T/status
gone="	libavcodec.so.62 => not found"
under="	libdav1d.so.7 => not found"
fine="	libavcodec.so.62 => /usr/lib/libavcodec.so.62 (0x0000)"
gpu="vdecd: the GPU is not usable (GBM on /dev/dri/renderD128 failed): apps decode on the CPU, trying again"

why() {   # LDD STATE RESULT JOURNAL
  LDD=$1 STATE=$2 RESULT=$3 JOURNAL=$4 "$G/vdecd.sh" why
}
hook() {   # LDD STATE READY CC -> what ran, the binary, what it said
  : > "$CALLS"; echo old > "$OMACVM_VDECD_BIN"
  if [[ $3 == ready ]]; then echo "H.264 VP9" > "$OMACVM_VDECD_STATUS"; else rm -f "$OMACVM_VDECD_STATUS"; fi
  local said; said=$(LDD=$1 STATE=$2 RESULT=success JOURNAL="" CC=$4 "$G/vdecd.sh" hook)
  echo "$(tr '\n' ' ' < "$CALLS")| $(cat "$OMACVM_VDECD_BIN") | $said"
}

# ---------- why it is down (omacvm check, control centre) ----------
expect "why: a new FFmpeg, the old soname gone" \
  "built against a library that is gone (libavcodec.so.62 missing): omacvm apply" "$(why "$gone" dead exit-code "")"
expect "why: a library under FFmpeg gone (not its own)" \
  "a library under FFmpeg or Mesa is gone (libdav1d.so.7 missing; a partial update?): pacman -Syu" \
  "$(why "$fine
$under" dead exit-code "")"
expect "why: GPU not usable, waiting" "${gpu#vdecd: }" "$(why "$fine" running success "$gpu")"
expect "why: GPU not usable, restarting" "${gpu#vdecd: }" "$(why "$fine" auto-restart exit-code "$gpu")"
expect "why: no decoding offered (exit 0)" "VA-API offers no H.264, HEVC or VP9 decoding: exiting, apps decode on the CPU" \
  "$(why "$fine" dead success "vdecd: VA-API offers no H.264, HEVC or VP9 decoding: exiting, apps decode on the CPU")"
expect "why: exit without a word, an earlier run's line not used" \
  "it exited with status 1 (journalctl -u omacvm-vdecd)" "$(why "$fine" dead exit-code "")"
expect "why: watchdog, restarting" "it stopped answering (killed by the watchdog); starts again by itself" \
  "$(why "$fine" auto-restart watchdog "vdecd: ready: H.264 VP9")"
expect "why: crashed" "it crashed (journalctl -u omacvm-vdecd)" "$(why "$fine" dead signal "vdecd: ready: H.264 VP9")"
expect "why: out of memory" "it ran out of memory (killed); starts again by itself" "$(why "$fine" auto-restart oom-kill "")"
expect "why: gave up" "it failed too often: systemctl restart omacvm-vdecd" "$(why "$fine" failed start-limit-hit "")"
expect "why: nothing known" "not running (journalctl -u omacvm-vdecd)" "$(why "$fine" dead success "")"

# ---------- the pacman hook ----------
: > "$CALLS"; echo old > "$OMACVM_VDECD_BIN"
LDD=$gone STATE=dead CC=ok "$G/vdecd.sh" hook
expect "hook: feature off (no unit): nothing" "" "$(cat "$CALLS")"
touch "$OMACVM_VDECD_UNIT"
restart="systemctl restart --no-block omacvm-vdecd.service"
expect "hook: ready, libraries there: left alone" "| old | " "$(hook "$fine" active ready ok)"
expect "hook: down, libraries there: started again" "$restart | old | " "$(hook "$fine" auto-restart no ok)"
expect "hook: running but waits for the GPU: started again" "$restart | old | " "$(hook "$fine" active no ok)"
expect "hook: soname gone, ready: built again, not restarted" \
  "cc | new | omacvm-vdecd: built again (libavcodec.so.62 is gone)" "$(hook "$gone" active ready ok)"
expect "hook: soname gone, down: built again and started" \
  "cc $restart | new | omacvm-vdecd: built again (libavcodec.so.62 is gone)" "$(hook "$gone" dead no ok)"
expect "hook: does not build: old binary kept, says so" \
  "cc $restart | old | omacvm-vdecd: does not build against the new libraries (log: $T/build.log): omacvm apply" \
  "$(hook "$gone" dead no fail)"
expect "hook: a library under FFmpeg gone: not built again (no use)" "$restart | old | " "$(hook "$fine
$under" dead no ok)"

# ---------- VA-API that does not start (the "video decoding" row) ----------
vafail() { printf '%s\n' "$1" | "$G/vdecd.sh" vafail; }
expect "vafail: started without decoders (off on the Mac), a Mesa warning: nothing" "" \
  "$(vafail "libva info: VA-API version 1.22.0
MESA-LOADER: failed to open zink: /usr/lib/dri/zink_dri.so: cannot open shared object file
vainfo: Driver version: OmacVM
vainfo: Supported profile and entrypoints
      VAProfileNone                   :	VAEntrypointVideoProc")"
expect "vafail: the VA driver does not start: libva's line" "libva error: /usr/local/lib/dri/omacvm_drv_video.so init failed" \
  "$(vafail "libva info: Trying to open /usr/local/lib/dri/omacvm_drv_video.so
libva error: /usr/local/lib/dri/omacvm_drv_video.so init failed
libva info: va_openDriver() returns 1
vaInitialize failed with error code 1 (operation failed),exit")"
expect "vafail: GBM broken: Mesa's line" "MESA-LOADER: failed to open dri: /usr/lib/gbm/dri_gbm.so: cannot open shared object file" \
  "$(vafail "MESA-LOADER: failed to open dri: /usr/lib/gbm/dri_gbm.so: cannot open shared object file
libva error: /usr/lib/dri/virtio_gpu_drv_video.so init failed
vaInitialize failed with error code -1 (unknown libva error),exit")"
has "check.sh: asks vdecd.sh vafail" "$R/src/guest/check.sh" 'vdecd.sh vafail <<<"$va"'

# ---------- the pieces fit ----------
U=$G/omacvm-vdecd.service
has "unit: restarts on failure" "$U" "Restart=on-failure"
# Flat: a crash or watchdog kill after a GPU that came back late restarts in
# 2 s (systemd's RestartSteps would count every restart of the boot).
expect "unit: restarts after 2 s, no systemd backoff" "RestartSec=2" "$(grep -E '^Restart(Sec|Steps|MaxDelaySec)=' "$U")"
expect "unit: exit 3 (module) and 127 (library gone) stay down, 4 (GPU) does not" "3 127" \
  "$(sed -n 's/^RestartPreventExitStatus=//p' "$U")"
has "unit: the GPU try count survives a restart" "$U" "RuntimeDirectoryPreserve=restart"
C=$G/omacvm-vdecd.c
expect "daemon: GPU not usable = wait, then exit 4" 1 "$(grep -A1 '^		gpu_wait();$' "$C" | grep -c '^		return 4;$')"
expect "daemon: the count goes once it is ready" 1 \
  "$(grep -A1 'runtime_path(path, sizeof(path), "gpu-tries"))$' "$C" | grep -c '^		unlink(path);$')"
# The daemon's waits before exit 4, plus RestartSec: fewer than StartLimitBurst
# (5) starts in StartLimitIntervalSec (10 s), so it never gives up, and a GPU
# that stays broken costs one try every 2 minutes.
w=$(sed -n 's/^[[:space:]]*wait = n >= \([0-9]*\) ? \([0-9]*\) : (2 << n) - 2;$/\1 \2/p' "$C")
sec=$(sed -n 's/^RestartSec=//p' "$U")
starts=$(awk -v w="$w" -v s="$sec" 'BEGIN {
  split(w, a, " "); t = 0; c = 1
  for (n = 0; n < 20; n++) { d = (n >= a[1] ? a[2] : 2 ^ (n + 1) - 2) + s; t += d; if (t <= 10) c++ }
  print (c < 5 ? "ok" : c) "," d }')
expect "daemon: waits 2 s -> 2 min, under the start limit" "ok,120" "$starts"
H=$G/95-omacvm-vdecd.hook
has "hook: by path" "$H" "Type = Path"
has "hook: on any library (FFmpeg, Mesa, libva, theirs)" "$H" "Target = usr/lib/*.so*"
# apply copies src/ to /usr/local/share/omacvm: the hook's path is that copy.
expect "hook: runs vdecd.sh where apply puts it" "/usr/local/share/omacvm/vdec/guest/vdecd.sh hook" \
  "$(sed -n 's/^Exec = //p' "$H")"
x=1; [[ -x $G/vdecd.sh ]] && x=0; expect "vdecd.sh is executable" 0 $x
has "install.sh: installs the hook" "$G/install.sh" "/etc/pacman.d/hooks/95-omacvm-vdecd.hook"
expect "install.sh off: removes the hook" 1 "$(sed -n '/^if \[\[ \$ON == off \]\]/,/^fi$/p' "$G/install.sh" | grep -c '95-omacvm-vdecd.hook')"
has "check.sh: asks vdecd.sh why" "$R/src/guest/check.sh" "/usr/local/share/omacvm/vdec/guest/vdecd.sh why"

exit $fail
