#!/bin/bash
# webrtc-encode.sh [--source camera|screen] [--seconds N] [--size 1280x720] [--features LIST]
#                  [--fake] [--out FILE.json]
# Chrome in the guest's desktop session sends a camera (or the screen) through a WebRTC
# loopback (guest/webrtc-loopback.html, H.264 preferred) and reports which encoder it
# used (encoderImplementation), frames encoded and encode time; the host adds the guest's
# and QEMU's CPU while it runs.
# --fake uses Chrome's fake camera and auto-accepts the picker (no camera needed).
# VM: PORT (ssh, default 52296), KEY (~/.ssh/omacvm), GUSER (gilles), VM (name, for QEMU's CPU).
set -euo pipefail
SRC=camera; SECS=20; SIZE=1280x720; FEATURES="AcceleratedVideoEncoder,VaapiVideoEncoder"; FAKE=0; OUT=""
while [ $# -gt 0 ]; do case $1 in
  --source) SRC=$2; shift 2;; --seconds) SECS=$2; shift 2;; --size) SIZE=$2; shift 2;;
  --features) FEATURES=$2; shift 2;; --fake) FAKE=1; shift;; --out) OUT=$2; shift 2;;
  *) echo "unknown: $1"; exit 2;; esac; done
H=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-52296}; KEY=${KEY:-$HOME/.ssh/omacvm}; GUSER=${GUSER:-gilles}; VM=${VM:-OmacVM T-video-encode}
OUT=${OUT:-$H/results/webrtc-$SRC-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
G=/opt/webrtc-encode; PROF=/tmp/webrtc-encode-prof
session() {   # run as the desktop user inside the Hyprland session
  "${SSH[@]}" "SIG=\$(ls /run/user/1000/hypr/ | head -1); sudo -u $GUSER env XDG_RUNTIME_DIR=/run/user/1000 \
    WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HYPRLAND_INSTANCE_SIGNATURE=\$SIG $*"
}
W=${SIZE%x*}; Hh=${SIZE#*x}
"${SSH[@]}" "mkdir -p $G; rm -f $G/out.jsonl; pkill -f '$G/[p]ost-server.py' || true"
"${SSH[@]}" "cat > $G/post-server.py" < "$H/guest/post-server.py"
"${SSH[@]}" "cat > $G/page.html" < "$H/guest/webrtc-loopback.html"
"${SSH[@]}" "nohup python3 $G/post-server.py $G/page.html $G/out.jsonl 8767 >/dev/null 2>&1 &"
sleep 1
FLAGS="--enable-features=$FEATURES --ignore-gpu-blocklist"
[ $FAKE = 1 ] && FLAGS="$FLAGS --use-fake-device-for-media-stream --use-fake-ui-for-media-stream --auto-select-desktop-capture-source=Entire"
# pkill -f must not see its pattern's plain text in the same command line (it would
# match its own shell): one ssh for pkill, one for rm.
"${SSH[@]}" "pkill -f '/tmp/[w]ebrtc-encode-prof' || true"
"${SSH[@]}" "rm -rf $PROF"
session bash -c "\"nohup google-chrome-stable --user-data-dir=$PROF --no-first-run --no-default-browser-check \
  --ozone-platform=wayland $FLAGS 'http://127.0.0.1:8767/?source=$SRC&seconds=$SECS&w=$W&h=$Hh&fps=30' \
  >/tmp/webrtc-encode-chrome.log 2>&1 &\""
# CPU while it runs: guest (all of /proc/stat) and QEMU (ps), sampled every 2 s
qpid=$(pgrep -f "qemu-system-aarch64 -name $VM -machine" | head -1 || true)
cpu0=$("${SSH[@]}" "head -1 /proc/stat"); t0=$(date +%s)
qsamples=""
for _ in $(seq $(( (SECS + 10) / 2 ))); do
  sleep 2
  [ -n "$qpid" ] && qsamples="$qsamples $(ps -o %cpu= -p $qpid | tr -d ' ')"
  "${SSH[@]}" "grep -q '\"kind\": \"result\"' $G/out.jsonl 2>/dev/null" && break
done
cpu1=$("${SSH[@]}" "head -1 /proc/stat"); t1=$(date +%s)
"${SSH[@]}" "cat $G/out.jsonl" > "$OUT.jsonl" || true
"${SSH[@]}" "pkill -f '/tmp/[w]ebrtc-encode-prof' || true; pkill -f '$G/[p]ost-server.py' || true"
python3 - "$OUT" "$cpu0" "$cpu1" "$((t1 - t0))" "$qsamples" "$SRC" "$FEATURES" <<'PY'
import json, sys
out, c0, c1, secs, qs, src, feats = sys.argv[1:8]
a = [int(x) for x in c0.split()[1:]]; b = [int(x) for x in c1.split()[1:]]
busy = (sum(b) - sum(a)) - ((b[3] + b[4]) - (a[3] + a[4]))
guest_cores = busy / 100.0 / max(int(secs), 1)
recs = [json.loads(l) for l in open(out + '.jsonl') if l.strip()]
res = next((r for r in recs if r.get('kind') == 'result'), {})
q = [float(x) for x in qs.split()] if qs.strip() else []
summary = {"test": "webrtc-encode", "source": src, "chrome_features": feats, "result": res,
           "guest_cpu_cores": round(guest_cores, 2),
           "qemu_cpu_cores": round(sum(q) / len(q) / 100, 2) if q else None,
           "hardware_encoder": bool(res.get("encoder")) and "libvpx" not in res.get("encoder", "")
                               and "OpenH264" not in res.get("encoder", "")}
json.dump(summary, open(out, "w"), indent=1)
print(json.dumps(summary, indent=1))
PY
