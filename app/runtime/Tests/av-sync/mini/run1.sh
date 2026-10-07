#!/bin/bash
# run1.sh LABEL SRC [chromium args...] (ON the mini, VM running): plays /opt/avs/SRC full screen in the guest's
# Chromium, records the Mac's screen + sound with avcap (DUR s, after WARM s), prints and stores the A/V offset.
# Env: LOAD none|gpu (glmark2 offscreen, scene changes = virgl shader compiles on QEMU's main loop).
set -u
W=/private/tmp/omacvm-avs; cd "$W"; mkdir -p out
L=$1; SRC=$2; shift 2; XA="$*"
DUR=${DUR:-60}; WARM=${WARM:-15}
./vm.sh ssh 'pkill -f avs-prof; pkill -f glmark2; sleep 1' >/dev/null 2>&1
QL=$(./vm.sh log); QN0=$(wc -l < "$QL")
./vm.sh hexec sh -c "chromium --user-data-dir=/tmp/avs-prof --no-first-run --no-default-browser-check --disable-session-crashed-bubble --kiosk --autoplay-policy=no-user-gesture-required --enable-logging=stderr --v=0 $XA 'file:///opt/avs/av.html?src=$SRC' > /tmp/avs-chromium.log 2>&1" >/dev/null
[[ ${LOAD:-none} == gpu ]] && ./vm.sh hexec sh -c "glmark2-wayland --off-screen --run-forever -b terrain > /tmp/avs-glmark2.log 2>&1" >/dev/null
sleep 8; ./vm.sh ssh 'pgrep -f avs-prof >/dev/null' || echo "$(date +%T) $L: NO CHROMIUM"
sleep "$WARM"
G=out/$L.guest.txt
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000";
  echo "== sinks"; $R pactl list sinks | grep -E "Name:|Latency|Sample Spec|Configured";
  echo "== sink inputs"; $R pactl list sink-inputs | grep -E "application.name|Latency|Sample Spec|Buffer";
  echo "== pw-top"; $R pw-top -b -n 3 2>/dev/null | tail -12;
  echo "== clock"; $R pw-metadata -n settings 0 2>/dev/null | grep -E "clock" ;
  echo "== alsa"; cat /proc/asound/card*/pcm0p/sub0/hw_params /proc/asound/card*/pcm0p/sub0/status 2>/dev/null;
  echo "== vdecd"; journalctl -u omacvm-vdecd --since "-30s" --no-pager 2>/dev/null | tail -3; ps -eo pcpu,comm | sort -rn | head -6' > "$G" 2>&1
./avcap "$DUR" "out/$L.csv"
./vm.sh ssh 'grep -h AVSYNC /tmp/avs-chromium.log | tail -3; grep -ciE "v4l2|vaapi|hardware" /tmp/avs-chromium.log' >> "$G" 2>&1
./vm.sh ssh 'pkill -f avs-prof; pkill -f glmark2' >/dev/null 2>&1
tail -n +"$((QN0 + 1))" "$QL" > "out/$L.qemu.txt"
python3 avsync.py "out/$L.csv" --json | python3 -c '
import json,sys; r=json.load(sys.stdin); r["label"]=sys.argv[1]
q=open(sys.argv[2]).read(); r["pace_forgive"]=q.count("hda_audio_pace_forgive"); r["full_recovery"]=q.count("hda_audio_full_recovery"); r["timer_late"]=q.count("audio_timer_delayed")
print(json.dumps(r))' "$L" "out/$L.qemu.txt" | tee -a out/results.jsonl
