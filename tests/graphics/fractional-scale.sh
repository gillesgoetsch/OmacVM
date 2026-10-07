#!/bin/bash
# fractional-scale.sh: Omarchy's display scales in an OmacVM.app VM, one after the other, the way
# its scale menu sets them (omarchy-hyprland-monitor-scaling). For each scale it checks that
#   * the output keeps its mode (the size of the Mac window) and gets the clean scale,
#   * the display sync sent at most one rule and never held the output (no loop),
#   * QEMU's log has no refused GPU memory and no lost GPU context since the change,
# and prints one JSON line per scale: the VM's graphics memory now and its peak (QEMU's status
# file logs/gpu-memory next to the log), with --frames also the frame times of a full-screen
# Chromium page (tests/graphics/pacing/pacing.html) for SECS seconds after the change, and with
# --during the frame times while the scale changes (the page runs, the scale changes 2 s in,
# 8 s in all).
#
#   tests/graphics/fractional-scale.sh --port 52431 [--user gilles] [--key ~/.ssh/omacvm]
#       [--qemu-log "<VM folder>/logs/qemu.log"] [--scales "1 1.25 1.5 1.6 1.75 2"]
#       [--frames SECS] [--during] [--hz 60]
#
# Exit 1 when a scale failed a check. Frame times are only comparable with the benchmark lock
# held and the other test VMs paused (tests/graphics/pacing/README.md).
set -u
port="" user=gilles key=$HOME/.ssh/omacvm qlog="" scales="1 1.25 1.5 1.6 1.75 2" frames=0 during=0 hz=60
while (($#)); do
  case $1 in
    --port) port=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --qemu-log) qlog=$2; shift 2 ;;
    --scales) scales=$2; shift 2 ;;
    --frames) frames=$2; shift 2 ;;
    --during) during=1; shift ;;
    --hz) hz=$2; shift 2 ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
  esac
done
[[ -n $port ]] || { sed -n '2,19p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
ssh_vm() {
  ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
# A command line (all of it, also after ";") in the desktop user's Hyprland session.
as_user() {
  local c
  c=$(printf '%q' "$*")
  ssh_vm "uid=\$(id -u $user); sig=\$(ls -t /run/user/\$uid/hypr | head -1); cd /tmp; sudo -u $user env \
XDG_RUNTIME_DIR=/run/user/\$uid WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$sig bash -c $c"
}
monitor() {
  as_user hyprctl -j monitors | python3 -c '
import json, sys
m = next(m for m in json.load(sys.stdin) if m["name"] == "Virtual-1")
print(m["width"], m["height"], m["scale"])'
}
clean_scale() {   # what Omarchy's own script picks: the next scale up that keeps whole pixels
  awk -v s="$1" -v w="$2" -v h="$3" 'function gcd(a, b, t) { while (b) { t = a % b; a = b; b = t } return a }
    BEGIN { g = gcd(w * 120, h * 120); k = int(s * 120 + 0.5); if (k > g) k = g; while (g % k) k++; printf "%g\n", k / 120 }'
}
state=/run/user/$(ssh_vm id -u "$user")/omacvm/display-sync

# pacing PARAMS: the full-screen page in Chromium (kiosk); its numbers land in /tmp/pacing-stats.json.
pacing_start() {
  as_user "rm -f /tmp/pacing-stats.json; setsid -f chromium --ozone-platform=wayland --kiosk --no-first-run \
--user-data-dir=/tmp/omacvm-pacing-profile 'http://127.0.0.1:8765/pacing.html?$1' >/dev/null 2>&1 </dev/null"
}
pacing_result() {   # SECS: wait for the page, print its stats (JSON) or null, close it
  local r
  for _ in $(seq $(($1 + 30))); do ssh_vm test -s /tmp/pacing-stats.json && break; sleep 1; done
  r=$(ssh_vm "python3 /tmp/omacvm-pacing/stats.py /tmp/pacing-stats.json $(awk -v h="$hz" 'BEGIN { print 1000 / h }')" 2>/dev/null)
  echo "${r:-null}"
  as_user "pkill -f -- '--user-data-dir=/tmp/omacvm-pacing-profile'" >/dev/null 2>&1
  sleep 2
}
status_mb() {   # KEY: a number from QEMU's status file, else empty
  local f
  f="$(dirname "$qlog")/gpu-memory"
  [[ -n $qlog && -f $f ]] && sed -n "s/^$1=//p" "$f" | head -1
}

if ((frames || during)); then
  ssh_vm "mkdir -p /tmp/omacvm-pacing" &&
    scp -q -i "$key" -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "$here/pacing/pacing.html" "$here/pacing/srv.py" "$here/pacing/stats.py" root@127.0.0.1:/tmp/omacvm-pacing/ &&
    ssh_vm "chmod -R a+rX /tmp/omacvm-pacing"
  as_user "setsid -f python3 /tmp/omacvm-pacing/srv.py >/dev/null 2>&1 </dev/null"
  trap 'as_user "pkill -f /tmp/omacvm-pacing/srv.py; rm -rf /tmp/omacvm-pacing-profile" >/dev/null 2>&1' EXIT INT TERM
fi

read -r w0 h0 s0 < <(monitor) || { echo "no Virtual-1 in Hyprland" >&2; exit 1; }
fail=0
for s in $scales; do
  t0=$(ssh_vm date +%s.%N)
  qlines=$([[ -f $qlog ]] && wc -l < "$qlog" || echo 0)
  held0=$(ssh_vm "cat $state/held 2>/dev/null | wc -l")
  ftd="null"
  if ((during)); then
    pacing_start "secs=8&hz=$hz"
    for _ in $(seq 40); do ssh_vm "pgrep -f omacvm-pacing-profile >/dev/null" && break; sleep 0.5; done
    sleep 4    # the page loads, then records 8 s; the change comes about 2 s in
  fi
  as_user omarchy-hyprland-monitor-scaling "$s" >/dev/null 2>&1
  ((during)) && ftd=$(pacing_result 8)
  sleep 5
  read -r w h shown < <(monitor)
  want=$(clean_scale "$s" "$w0" "$h0")
  applies=$(ssh_vm "awk -v t=$t0 '\$1 >= t' $state/Virtual-1.history 2>/dev/null | wc -l")
  held=$(( $(ssh_vm "cat $state/held 2>/dev/null | wc -l") - held0 ))
  gpu=""
  [[ -f $qlog ]] && gpu=$(tail -n +"$((qlines + 1))" "$qlog" | grep -E "budget of [0-9]+ MB reached|apps' share of [0-9]+ MB reached|macOS is short of memory|is lost|context error reported" | head -1)
  peak=$(status_mb peak_mb)
  [[ -n $peak ]] || peak=$([[ -f $qlog ]] && grep -o 'guest GPU memory in use: [0-9]* MB' "$qlog" | tail -1 | grep -o '[0-9]*')
  now=$(status_mb in_use_mb)
  why=()
  [[ $w == "$w0" && $h == "$h0" ]] || why+=("mode $w x $h, was $w0 x $h0")
  awk -v a="$shown" -v b="$want" 'BEGIN { exit !(a - b < 0.001 && b - a < 0.001) }' || why+=("scale $shown, want $want")
  ((applies <= 1)) || why+=("display sync sent $applies rules")
  ((held == 0)) || why+=("display sync held the output")
  [[ -z $gpu ]] || why+=("GPU: $gpu")
  ft="null"
  if ((frames)); then
    pacing_start "secs=$frames&hz=$hz"
    ft=$(pacing_result "$frames")
  fi
  ok=true; ((${#why[@]})) && { ok=false; fail=1; }
  printf '{"scale": "%s", "ok": %s, "mode": "%sx%s", "shown_scale": %s, "logical": "%sx%s", "applies": %s, "held": %s, "gpu_now_mb": %s, "gpu_peak_mb": %s, "frames": %s, "frames_during_change": %s, "why": "%s"}\n' \
    "$s" "$ok" "$w" "$h" "$shown" "$(awk -v a="$w" -v s="$shown" 'BEGIN { printf "%d", a / s + 0.5 }')" \
    "$(awk -v a="$h" -v s="$shown" 'BEGIN { printf "%d", a / s + 0.5 }')" "$applies" "$held" "${now:-null}" "${peak:-null}" "$ft" "$ftd" \
    "$(IFS=';'; echo "${why[*]:-}")"
done
exit $fail
