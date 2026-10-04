#!/bin/bash
# webrtc-encode.sh [--source camera|screen|call] [--seconds N] [--size 1280x720] [--hd]
#                  [--features LIST] [--fake] [--out FILE.json]
# Chrome in the guest's desktop session sends a camera (or the screen, or a call:
# camera, microphone and the screen) through a WebRTC loopback (guest/webrtc-loopback.html,
# H.264 preferred) and reports which encoder each video sender used
# (encoderImplementation), frames encoded and encode time. From the call's start to its
# result the host measures the CPU of the guest, of QEMU and of the Mac's VideoToolbox
# encoder service. Permission prompts and the screen picker are accepted automatically
# (a throw-away profile).
# --features "" passes no --enable-features: Chrome then runs with the flags files
# OmacVM writes (src/app/guest/browser-video-encode.py).
# --fake uses Chrome's fake camera and microphone (no camera needed).
# --hd keeps the full size and starts the bandwidth estimate high (see the page).
# VM: PORT (ssh, default 52296), KEY (~/.ssh/omacvm), GUSER (gilles), VM (name, for QEMU's CPU).
set -euo pipefail
SRC=camera; SECS=20; SIZE=1280x720; FEATURES="AcceleratedVideoEncoder,VaapiVideoEncoder"; FAKE=0; OUT=""; HD=0
while [ $# -gt 0 ]; do case $1 in
  --source) SRC=$2; shift 2;; --seconds) SECS=$2; shift 2;; --size) SIZE=$2; shift 2;;
  --features) FEATURES=$2; shift 2;; --fake) FAKE=1; shift;; --out) OUT=$2; shift 2;;
  --hd) HD=1; shift;;
  *) echo "unknown: $1"; exit 2;; esac; done
H=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-52296}; KEY=${KEY:-$HOME/.ssh/omacvm}; GUSER=${GUSER:-gilles}; VM=${VM:-OmacVM T-video-encode}
OUT=${OUT:-$H/results/webrtc-$SRC-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
G=/opt/webrtc-encode; PROF=/tmp/webrtc-encode-prof
session() {   # run as the desktop user inside the Hyprland session
  "${SSH[@]}" "SIG=\$(ls /run/user/1000/hypr/ | head -1); sudo -u $GUSER env XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland \
    WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HYPRLAND_INSTANCE_SIGNATURE=\$SIG $*"
}
W=${SIZE%x*}; Hh=${SIZE#*x}
# The real screen goes through xdg-desktop-portal-hyprland, whose picker wants a click:
# for the test, a picker that takes the first screen; the user's xdph.conf comes back after.
XDPH=/home/$GUSER/.config/hypr/xdph.conf
if [ $SRC != camera ] && [ $FAKE = 0 ]; then
  "${SSH[@]}" "mkdir -p $G; cat > $G/pick-screen.sh; chmod 755 $G/pick-screen.sh" <<'PICK'
#!/bin/sh
# xdg-desktop-portal-hyprland picker for tests: the first screen, no questions.
echo "[SELECTION]/screen:$(hyprctl -j monitors | jq -r '.[0].name')"
PICK
  "${SSH[@]}" "cp -p $XDPH $XDPH.webrtc-test 2>/dev/null || touch $XDPH.webrtc-test
    printf 'screencopy {\n    custom_picker_binary = $G/pick-screen.sh\n}\n' > $XDPH; chown $GUSER: $XDPH
    systemctl --user -M $GUSER@ restart xdg-desktop-portal-hyprland"
  trap '"${SSH[@]}" "if [ -s $XDPH.webrtc-test ]; then mv -f $XDPH.webrtc-test $XDPH; else rm -f $XDPH $XDPH.webrtc-test; fi
    systemctl --user -M $GUSER@ restart xdg-desktop-portal-hyprland"' EXIT
fi
"${SSH[@]}" "mkdir -p $G; rm -f $G/out.jsonl; pkill -f '$G/[p]ost-server.py' || true"
"${SSH[@]}" "cat > $G/post-server.py" < "$H/guest/post-server.py"
"${SSH[@]}" "cat > $G/page.html" < "$H/guest/webrtc-loopback.html"
"${SSH[@]}" "nohup python3 $G/post-server.py $G/page.html $G/out.jsonl 8767 >/dev/null 2>&1 &"
sleep 1
FLAGS="--ignore-gpu-blocklist --use-fake-ui-for-media-stream --auto-select-desktop-capture-source=Entire ${EXTRA_FLAGS:-}"
[ -n "$FEATURES" ] && FLAGS="--enable-features=$FEATURES $FLAGS"
[ $FAKE = 1 ] && FLAGS="$FLAGS --use-fake-device-for-media-stream"
# pkill -f must not see its pattern's plain text in the same command line (it would
# match its own shell): one ssh for pkill, one for rm.
"${SSH[@]}" "pkill -f '/tmp/[w]ebrtc-encode-prof' || true"
"${SSH[@]}" "rm -rf $PROF"
session bash -c "\"nohup google-chrome-stable --user-data-dir=$PROF --no-first-run --no-default-browser-check \
  --ozone-platform=wayland $FLAGS 'http://127.0.0.1:8767/?source=$SRC&seconds=$SECS&w=$W&h=$Hh&fps=30&hd=$HD' \
  >/tmp/webrtc-encode-chrome.log 2>&1 &\""
# CPU from the call's start to its result: the guest (all of /proc/stat), QEMU and the
# Mac's VideoToolbox encoder service (CPU time, ps)
cputime() { ps -o time= -p "$1" 2>/dev/null | awk -F'[:.]' '{ n = NF; s = $(n-1) + $n / 100; m = $(n-2); h = (n > 3) ? $(n-3) : 0; print h * 3600 + m * 60 + s }'; }
mac_cpu() {   # QEMU's and the VT encoder services' CPU time so far
  local q=0 v=0 p
  [ -n "$qpid" ] && q=$(cputime "$qpid")
  for p in $(pgrep -f VTEncoderXPCService); do v=$(echo "$v + $(cputime "$p")" | bc); done
  echo "$q $v"
}
qpid=$(pgrep -f "qemu-system-aarch64 -name $VM -machine" | head -1 || true)
for _ in $(seq 60); do
  "${SSH[@]}" "grep -q '\"kind\": \"\(start\|result\)\"' $G/out.jsonl 2>/dev/null" && break
  sleep 0.5
done
cpu0=$("${SSH[@]}" "head -1 /proc/stat"); t0=$(python3 -c "import time; print(time.time())"); m0=$(mac_cpu)
for _ in $(seq $(( SECS + 30 ))); do
  sleep 1
  "${SSH[@]}" "grep -q '\"kind\": \"result\"' $G/out.jsonl 2>/dev/null" && break
done
cpu1=$("${SSH[@]}" "head -1 /proc/stat"); t1=$(python3 -c "import time; print(time.time())"); m1=$(mac_cpu)
"${SSH[@]}" "cat $G/out.jsonl" > "$OUT.jsonl" || true
"${SSH[@]}" "pkill -f '/tmp/[w]ebrtc-encode-prof' || true; pkill -f '$G/[p]ost-server.py' || true"
python3 - "$OUT" "$cpu0" "$cpu1" "$t0" "$t1" "$m0" "$m1" "$SRC" "$FEATURES" <<'PY'
import json, sys
out, c0, c1, t0, t1, m0, m1, src, feats = sys.argv[1:10]
secs = max(float(t1) - float(t0), 1)
a = [int(x) for x in c0.split()[1:]]; b = [int(x) for x in c1.split()[1:]]
busy = (sum(b) - sum(a)) - ((b[3] + b[4]) - (a[3] + a[4]))
guest_cores = busy / 100.0 / secs
(q0, v0), (q1, v1) = [[float(x) for x in m.split()] for m in (m0, m1)]
recs = [json.loads(l) for l in open(out + '.jsonl') if l.strip()]
res = next((r for r in recs if r.get('kind') == 'result'), {})
summary = {"test": "webrtc-encode", "source": src, "chrome_features": feats, "result": res,
           "seconds": round(secs, 1), "guest_cpu_cores": round(guest_cores, 2),
           "qemu_cpu_cores": round((q1 - q0) / secs, 2), "mac_vt_cpu_cores": round((v1 - v0) / secs, 3),
           "hardware_encoder": bool(res.get("senders")) and all(
               "Vaapi" in (o.get("encoder") or "") for o in res["senders"])}
json.dump(summary, open(out, "w"), indent=1)
print(json.dumps(summary, indent=1))
PY
