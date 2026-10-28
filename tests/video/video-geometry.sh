#!/bin/bash
# video-geometry.sh [--apps "mpv chrome ..."] [--sizes "1920x1080 ..."] [--codecs "vp9 hevc ..."] [--mode fit|1to1]
#                   [--output 2560x1600] [--chrome PATH] [--out FILE.jsonl]
# Where hardware-decoded video's rows and columns land on an OmacVM.app VM's screen, per app
# (guest/video-geometry.py): the test card's last 8 rows and columns must stay 8 (OmacVM 3.2.10 and older showed the
# picture squeezed with its last row repeated below it, ADR 0059). Copies the guest script and the DevTools helpers
# (src/bench/video-bench.py, browser-bench.py) into the VM, makes the clips there with FFmpeg (once), runs each app
# in the desktop user's Hyprland session (grim), prints a verdict per clip; exit 1 when a row that must be exact is
# not (known cases: guest/video-geometry.py's check). Defaults: apps mpv mpvnext chrome chromium firefox; codecs
# vp9 hevc (add av1 on an M3/M4 Mac); every size of the script; fit; the output 2560x1600 for the run.
# VM: PORT (ssh to root, default 52296), KEY (~/.ssh/omacvm), GUSER (the desktop user, default: the one Hyprland
# runs as). Use your own test VM, never the person's.
set -uo pipefail
APPS="mpv mpvnext chrome chromium firefox"; SIZES=""; CODECS="vp9 hevc"; MODE=fit; CHROME=""; OUT=""; OUTPUT=2560x1600
while [ $# -gt 0 ]; do case $1 in
  --apps) APPS=$2; shift 2;; --sizes) SIZES=$2; shift 2;; --codecs) CODECS=$2; shift 2;;
  --mode) MODE=$2; shift 2;; --chrome) CHROME=$2; shift 2;; --out) OUT=$2; shift 2;;
  --output) OUTPUT=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../.." && pwd)
PORT=${PORT:-52296}; KEY=${KEY:-$HOME/.ssh/omacvm}
OUT=${OUT:-$H/results/video-geometry-$(date +%Y%m%d-%H%M%S).jsonl}; mkdir -p "$(dirname "$OUT")"
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
D=/tmp/video-geometry
"${SSH[@]}" "mkdir -p $D/bin" || { echo "no ssh to the VM on port $PORT" >&2; exit 2; }
tar -C "$H/guest" -cf - video-geometry.py | "${SSH[@]}" "tar -C $D/bin -xf -"
tar -C "$R/src/bench" -cf - video-bench.py browser-bench.py | "${SSH[@]}" "tar -C $D/bin -xf -"
U=${GUSER:-$("${SSH[@]}" 'ps -o user= -C Hyprland | head -1' | tr -d ' ')}
[ -n "$U" ] || { echo "no Hyprland session in the VM" >&2; exit 2; }
"${SSH[@]}" "chown -R $U: $D"
# as the desktop user in the Hyprland session, with the session's environment.d (LIBVA_DRIVER_NAME=omacvm)
guser() {
  "${SSH[@]}" "R=/run/user/\$(id -u $U); H=\$(ls -t \$R/hypr 2>/dev/null | head -1); W=\$(ls \$R 2>/dev/null | grep -m1 '^wayland-[0-9]*\$'); cd /tmp; runuser -u $U -- env \$(grep -h -v '^#' /etc/environment.d/*.conf 2>/dev/null) HOME=/home/$U XDG_RUNTIME_DIR=\$R HYPRLAND_INSTANCE_SIGNATURE=\$H WAYLAND_DISPLAY=\${W:-wayland-1} DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=\$R/bus VIDEO_GEOMETRY_CHROME_FLAGS='${VIDEO_GEOMETRY_CHROME_FLAGS:-}' VIDEO_GEOMETRY_CHROME_FEATURES='${VIDEO_GEOMETRY_CHROME_FEATURES:-}' $1"
}
guser "python3 $D/bin/video-geometry.py clips $D/clips $SIZES 2>/dev/null" | tail -1
# the output larger than every clip (scale 1): fitted videos keep their 2-pixel lines; put back at the end
guser "python3 $D/bin/video-geometry.py output $OUTPUT"
only=""; for c in $CODECS; do only+="$c-,"; done; [[ " $APPS " == *" mpv "* ]] && only+="h264-1920x1080,"
ch=""; [ -n "$CHROME" ] && ch="--chrome $CHROME"
for app in $APPS; do
  "${SSH[@]}" "pkill -f video-geometry-ud- ; pkill -x firefox ; pkill -x mpv ; true"; sleep 2
  guser "python3 $D/bin/video-geometry.py run $app $MODE --clips $D/clips --only $only $ch --out $D/out.jsonl"
done
"${SSH[@]}" "cat $D/out.jsonl" > "$OUT"
guser "python3 $D/bin/video-geometry.py output" >/dev/null
guser "python3 $D/bin/video-geometry.py check $D/out.jsonl"; rc=$?
"${SSH[@]}" "rm -f $D/out.jsonl"
echo "results: $OUT"
exit $rc
