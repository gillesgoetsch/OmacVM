#!/bin/bash
# ffmpeg-encode.sh [--size 1920x1080] [--seconds 10] [--runs 3] [--out FILE.json] [ENCODER...]
# FFmpeg in the guest encodes the same raw clip (testsrc2 with noise, NV12, made once in
# the guest's /tmp) with each encoder: the Mac's media engine through VA-API (h264_vaapi,
# hevc_vaapi) or the VM's CPU (libx264, libx265). Per run: wall time (frames per second),
# the guest's CPU (FFmpeg's user + system time), QEMU's CPU on the Mac and that of the
# Mac's VideoToolbox encoder service (VTEncoderXPCService, where the media engine's
# sessions run); once per
# encoder: bitrate and luma PSNR against the source. Medians of the runs.
# Default encoders: h264_vaapi libx264 hevc_vaapi libx265.
# VM: PORT (ssh, default 52296), KEY (~/.ssh/omacvm), VM (name, for QEMU's CPU).
set -euo pipefail
SIZE=1920x1080; SECS=10; RUNS=3; OUT=""; ENCS=()
while [ $# -gt 0 ]; do case $1 in
  --size) SIZE=$2; shift 2;; --seconds) SECS=$2; shift 2;; --runs) RUNS=$2; shift 2;;
  --out) OUT=$2; shift 2;; -*) echo "unknown: $1"; exit 2;; *) ENCS+=("$1"); shift;; esac; done
[ ${#ENCS[@]} -gt 0 ] || ENCS=(h264_vaapi libx264 hevc_vaapi libx265)
H=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-52296}; KEY=${KEY:-$HOME/.ssh/omacvm}; VM=${VM:-OmacVM T-video-encode}
OUT=${OUT:-$H/results/ffmpeg-encode-$SIZE-$(date +%Y%m%d-%H%M%S).json}; mkdir -p "$(dirname "$OUT")"
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
FPS=30; FRAMES=$((SECS * FPS)); SRC=/tmp/ffmpeg-encode-$SIZE-$SECS.nv12
qpid=$(pgrep -f "qemu-system-aarch64 -name $VM -machine" | head -1 || true)
qcpu() {   # QEMU's CPU time so far, seconds
  [ -n "$qpid" ] || { echo 0; return; }
  ps -o time= -p "$qpid" | awk -F'[:.]' '{ n = NF; s = $(n-1) + $n / 100; m = $(n-2); h = (n > 3) ? $(n-3) : 0; print h * 3600 + m * 60 + s }'
}
vtcpu() {   # CPU time of all VTEncoderXPCService processes so far, seconds
  local t=0 p
  for p in $(pgrep -f VTEncoderXPCService); do
    t=$(echo "$t + $(ps -o time= -p "$p" | awk -F'[:.]' '{ n = NF; s = $(n-1) + $n / 100; m = $(n-2); h = (n > 3) ? $(n-3) : 0; print h * 3600 + m * 60 + s }')" | bc)
  done
  echo "$t"
}
"${SSH[@]}" "test -s $SRC || ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=$SIZE:rate=$FPS,noise=alls=4:allf=t \
  -frames:v $FRAMES -pix_fmt nv12 -f rawvideo $SRC"
args() {   # encoder -> FFmpeg output options: the same rate limits for all (8 Mbit/s at 1080p30, by pixels)
  local px=$(( ${SIZE%x*} * ${SIZE#*x} )) b r
  b=$(( 8000 * px / 2073600 )); r="-b:v ${b}k -maxrate ${b}k -bufsize $((2 * b))k"
  case $1 in
    h264_vaapi) echo "-vf hwupload -c:v h264_vaapi $r" ;;
    hevc_vaapi) echo "-vf hwupload -c:v hevc_vaapi $r" ;;
    libx264) echo "-c:v libx264 -preset veryfast $r" ;;
    libx265) echo "-c:v libx265 -preset ultrafast $r -x265-params log-level=error" ;;
    *) echo "unknown encoder $1" >&2; exit 2 ;;
  esac
}
in="-f rawvideo -pix_fmt nv12 -s $SIZE -r $FPS -i $SRC"
echo "[" > "$OUT.tmp"; first=1
for e in "${ENCS[@]}"; do
  hw=""; case $e in *_vaapi) hw="-vaapi_device /dev/dri/renderD128" ;; esac
  for r in $(seq "$RUNS"); do
    q0=$(qcpu); v0=$(vtcpu)
    line=$("${SSH[@]}" "cd /tmp; TIMEFORMAT='%R %U %S'; { time ffmpeg -nostdin -v error -y $hw $in $(args $e) /tmp/ffmpeg-encode-$e.mp4 ; } 2>&1 | tail -1")
    q1=$(qcpu); v1=$(vtcpu)
    read -r wall user sys <<< "$line"
    printf '%s {"encoder": "%s", "run": %d, "wall": %s, "guest_cpu": %.2f, "qemu_cpu": %.2f, "mac_vt_cpu": %.2f}' \
      "$([ $first = 1 ] || echo ,)" "$e" "$r" "$wall" "$(echo "$user + $sys" | bc)" "$(echo "$q1 - $q0" | bc)" \
      "$(echo "$v1 - $v0" | bc)" >> "$OUT.tmp"
    first=0
    echo "$e run $r: wall $wall s, guest $user+$sys s, QEMU $(echo "$q1 - $q0" | bc) s, VT service $(echo "$v1 - $v0" | bc) s" >&2
  done
  q=$("${SSH[@]}" "cd /tmp; ffmpeg -nostdin -hide_banner -i ffmpeg-encode-$e.mp4 $in -lavfi '[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]psnr' -f null - 2>&1 |
        sed -n 's/.*PSNR y:\([0-9.]*\) .*/\1/p' | tail -1; ffprobe -v error -show_entries format=bit_rate -of csv=p=0 ffmpeg-encode-$e.mp4")
  printf ', {"encoder": "%s", "psnr_y": %s, "bitrate": %s}' "$e" $(echo $q | cut -d' ' -f1) $(echo $q | cut -d' ' -f2) >> "$OUT.tmp"
done
echo "]" >> "$OUT.tmp"
python3 - "$OUT.tmp" "$OUT" "$SIZE" "$FRAMES" <<'PY'
import json, statistics, sys
recs = json.load(open(sys.argv[1])); size, frames = sys.argv[3], int(sys.argv[4])
out = {"test": "ffmpeg-encode", "size": size, "frames": frames, "encoders": {}}
for e in dict.fromkeys(r["encoder"] for r in recs):
    runs = [r for r in recs if r["encoder"] == e and "run" in r]
    q = next(r for r in recs if r["encoder"] == e and "psnr_y" in r)
    med = lambda k: round(statistics.median(r[k] for r in runs), 2)
    out["encoders"][e] = {"runs": len(runs), "wall_s": med("wall"), "fps": round(frames / med("wall"), 1),
                          "guest_cpu_s": med("guest_cpu"), "qemu_cpu_s": med("qemu_cpu"),
                          "mac_vt_cpu_s": med("mac_vt_cpu"),
                          "psnr_y": q["psnr_y"], "kbit_s": round(q["bitrate"] / 1000)}
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(json.dumps(out, indent=1))
PY
rm -f "$OUT.tmp"
