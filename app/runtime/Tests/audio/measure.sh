#!/bin/bash
# measure.sh SECONDS [GUEST_LOAD] [MAC_THREADS]: sound glitches of a running test VM under load.
#   GUEST_LOAD: none | cpu (stress-ng on every vCPU) | gpu (glmark2, scene changes every 10 s) | both
#   MAC_THREADS: busy `yes` loops on the Mac (default 0)
# Env: SSH_PORT (the VM's SSH on 127.0.0.1), KEY (~/.ssh/omacvm), GUSER (the desktop user),
#      LOAD_AS (root: stress-ng in root's SSH session, as before; user: in the desktop user's
#      app.slice, where a browser or a build runs and where it competes with PipeWire),
#      QMP (QEMU's QMP socket), QEMU_LOG (QEMU's log, started with -trace audio_timer_delayed
#      -trace hda_audio_full_recovery), SDLPROBE_PCM (optional: sdlprobe.c's stream file).
# The guest plays a 30 Hz tone through PipeWire's PulseAudio part (as Spotify does) from
# python3 | pacat (an endless stream); QEMU's mixer output is taken with HMP
# `wavcapture`. Prints one JSON line: guest xruns (pw-top ERR of the sink and the
# player), glitches of the tone in QEMU's output (glitches.py) and in what SDL got
# (with the probe), and how late QEMU's 1 ms audio timer ran (the main loop).
# Test VMs only: it installs stress-ng with pacman and plays sound.
set -u
H=$(cd "$(dirname "$0")" && pwd)
S=${1:?seconds}; G=${2:-both}; M=${3:-0}
: "${SSH_PORT:?}" "${GUSER:?}" "${QMP:?}" "${QEMU_LOG:?}"
SSH=(ssh -i "${KEY:-$HOME/.ssh/omacvm}" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1)
user() { "${SSH[@]}" "cd /tmp; sudo -u $GUSER env XDG_RUNTIME_DIR=/run/user/\$(id -u $GUSER) $(printf '%q ' "$@")"; }
hmp() {
  python3 - "$QMP" "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(json.dumps({"execute": "human-monitor-command", "arguments": {"command-line": sys.argv[2]}}) + '\n'); f.flush()
while True:
    l = f.readline()
    if '"return"' in l or '"error"' in l or not l: break
EOF
}
errs() { user pw-top -b -n 2 2>/dev/null | awk '$1 ~ /^[RSC]$/ && ($NF ~ /^alsa_output/ || $NF == "pacat") { e[$NF ~ /^alsa/ ? "sink" : "app"] = $9 } END { printf "%d %d", e["sink"], e["app"] }'; }
T=$(mktemp -d); pids=()
cleanup() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done
  "${SSH[@]}" 'pkill -x stress-ng; pkill -f glmark2' >/dev/null 2>&1
  user pkill -x pacat >/dev/null 2>&1; "${SSH[@]}" pkill -f omacvm-tone.py >/dev/null 2>&1
  hmp "stopcapture 0" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT INT TERM
"${SSH[@]}" 'command -v stress-ng >/dev/null || pacman -S --needed --noconfirm stress-ng >/dev/null 2>&1
cat > /var/tmp/omacvm-tone.py <<EOF
import math, struct, sys
one = b"".join(struct.pack("<hh", v, v) for v in (int(round(8191 * math.sin(2 * math.pi * i / 1600))) for i in range(1600)))
while True:
    sys.stdout.buffer.write(one * 30)
EOF
chmod 644 /var/tmp/omacvm-tone.py'
user wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 >/dev/null
(user sh -c "python3 /var/tmp/omacvm-tone.py | pacat --raw --format=s16le --rate=48000 --channels=2" </dev/null >/dev/null 2>&1 &)
sleep 3
read -r e0 a0 <<<"$(errs)"
hmp "wavcapture $T/qemu.wav snd0 44100 16 2"
[ -n "${SDLPROBE_PCM:-}" ] && : > "$SDLPROBE_PCM"
T0=$(date -u +%Y-%m-%dT%H:%M:%S)
case $G in cpu|both)
  if [ "${LOAD_AS:-root}" = user ]; then
    "${SSH[@]}" "systemd-run --user -M $GUSER@ --slice=app.slice --collect -q stress-ng --cpu 0 --timeout ${S}s"
  else
    "${SSH[@]}" "nohup stress-ng --cpu 0 --timeout ${S}s >/dev/null 2>&1 &"
  fi ;;
esac
case $G in gpu|both) "${SSH[@]}" "SIG=\$(ls -t /run/user/\$(id -u $GUSER)/hypr | head -1); sudo -u $GUSER env XDG_RUNTIME_DIR=/run/user/\$(id -u $GUSER) WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG nohup glmark2-wayland --run-forever -b terrain >/dev/null 2>&1 &" ;; esac
for ((i = 0; i < M; i++)); do (exec yes >/dev/null) & pids+=($!); done
sleep "$S"
T1=$(date -u +%Y-%m-%dT%H:%M:%S)
for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done; pids=()
hmp "stopcapture 0"
[ -n "${SDLPROBE_PCM:-}" ] && cp "$SDLPROBE_PCM" "$T/sdl.raw"
read -r e1 a1 <<<"$(errs)"
late=$(awk -v a="$T0" -v b="$T1" 'substr($1, 1, 19) >= a && substr($1, 1, 19) <= b {
    if ($2 == "audio_timer_delayed") { ms = $4 + 0; if (ms >= 100) c[">=100"]++; else if (ms >= 50) c["50-99"]++; else if (ms >= 20) c["20-49"]++; else if (ms >= 10) c["10-19"]++; else if (ms >= 5) c["5-9"]++; if (ms > w) w = ms }
    if ($2 == "hda_audio_full_recovery") r++ }
  END { printf "{\"5-9\":%d,\"10-19\":%d,\"20-49\":%d,\"50-99\":%d,\">=100\":%d,\"worst_ms\":%d,\"hda_full_recovery\":%d}", c["5-9"], c["10-19"], c["20-49"], c["50-99"], c[">=100"], w, r }' "$QEMU_LOG")
qemu=$(python3 "$H/glitches.py" "$T/qemu.wav")
sdl=null; [ -s "$T/sdl.raw" ] && sdl=$(python3 "$H/glitches.py" "$T/sdl.raw")
echo "{\"start\":\"$T0\",\"seconds\":$S,\"guest_load\":\"$G\",\"load_as\":\"${LOAD_AS:-root}\",\"mac_threads\":$M,\"guest_xruns\":{\"sink\":$((e1 - e0)),\"app\":$((a1 - a0))},\"main_loop_late_ms\":$late,\"qemu_out\":$qemu,\"sdl_in\":$sdl}"
