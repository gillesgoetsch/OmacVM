#!/bin/bash
# runp.sh LABEL KILLPAT CMD (ON the mini, VM running): plays with any player in the guest's session (CMD via
# hyprctl exec), records avcap DUR s after WARM s, stores the A/V offset like run1.sh.
set -u
W=/private/tmp/omacvm-avs; cd "$W"; mkdir -p out
L=$1; K=$2; C=$3; DUR=${DUR:-60}; WARM=${WARM:-15}
./vm.sh ssh "pkill -f '$K'; sleep 1" >/dev/null 2>&1
QL=$(./vm.sh log); QN0=$(wc -l < "$QL")
./vm.sh hexec sh -c "$C > /tmp/avs-$L.log 2>&1" >/dev/null
sleep 8; ./vm.sh ssh "pgrep -f '$K' >/dev/null" || echo "$(date +%T) $L: NO PLAYER"
sleep "$WARM"
G=out/$L.guest.txt
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000";
  /usr/local/bin/omacvm-audio-latency --show 2>&1 | sed "s/^/offset: /"; $R /usr/local/bin/omacvm-audio-latency --show;
  echo "== sink inputs"; $R pactl list sink-inputs | grep -E "application.name|Latency|Sample Spec|Buffer";
  echo "== pw-top"; $R pw-top -b -n 2 2>/dev/null | tail -8;
  echo "== alsa"; cat /proc/asound/card*/pcm0p/sub0/hw_params 2>/dev/null | grep -E "period|buffer"; grep delay /proc/asound/card*/pcm0p/sub0/status' > "$G" 2>&1
./avcap "$DUR" "out/$L.csv"
./vm.sh ssh "tail -5 /tmp/avs-$L.log; pkill -f '$K'" >> "$G" 2>&1
tail -n +"$((QN0 + 1))" "$QL" > "out/$L.qemu.txt"
python3 avsync.py "out/$L.csv" --json | python3 -c '
import json,sys; r=json.load(sys.stdin); r["label"]=sys.argv[1]
q=open(sys.argv[2]).read(); r["pace_forgive"]=q.count("hda_audio_pace_forgive"); r["timer_late"]=q.count("audio_timer_delayed")
print(json.dumps(r))' "$L" "out/$L.qemu.txt" | tee -a out/results.jsonl
