#!/bin/bash
# review.sh (ON the mini, nohup): the review runs of the 3.0.1 fix. Waits for the mini lock (wait line "av-sync"),
# then: mpv (PipeWire and PulseAudio output) and Firefox with offset 0 and 128, 10 minutes of Chromium (700 s
# clip: the 180 s clip's loop hangs at its end in Chromium) and of mpv for drift, and the crackle tool
# (../../audio/measure.sh, copied to ./audio) with offset 0 and 286 (AirPods-sized). One VM, deleted at the end.
cd /private/tmp/omacvm-avs; exec >> review.log 2>&1
WF=~/.omacvm-mini-vm.lock.wait; LK=~/.omacvm-mini-vm.lock
echo "$(date +%T) review wait pid $$"
setms() { ./vm.sh ssh "/usr/local/bin/omacvm-audio-latency $1; sleep 2; U=\$(stat -c %U /run/user/1000); sudo -u \$U env XDG_RUNTIME_DIR=/run/user/1000 /usr/local/bin/omacvm-audio-latency --show"; }
prio() { grep -qE '^(release|fs-own-space)' "$WF" 2>/dev/null && { echo "$(date +%T) release lane waits: stop"; exit 0; }; }
# WirePlumber came up broken at one boot (streams never linked to the sink, all players silent): check with a
# short play, restart it if so.
wpok() {
  ./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000";
    chk() { ($R pw-play /usr/share/sounds/freedesktop/stereo/bell.oga >/dev/null 2>&1 &); sleep 1; $R pw-top -b -n 2 | grep -E "^[RI] .*alsa_output" | grep -qv " 0 *0 "; };
    if chk; then echo "wireplumber ok"; else echo "wireplumber: no link, restart"; $R systemctl --user restart wireplumber; sleep 4; chk && echo "wireplumber ok now" || echo "wireplumber STILL BROKEN"; fi'
}
work() {
  mkdir -p out; ./outlat > out/outlat-review.txt 2>&1; cat out/outlat-review.txt
  ./setup.sh || exit 1
  ./vm.sh ssh 'cat > /usr/local/bin/omacvm-audio-latency && chmod 755 /usr/local/bin/omacvm-audio-latency' < fix/omacvm-audio-latency
  ./vm.sh ssh 'cat > /etc/systemd/user/omacvm-audio-latency.service && systemctl --global enable omacvm-audio-latency.service' < fix/omacvm-audio-latency.service
  ./vm.sh ssh 'pacman -S --needed --noconfirm firefox mpv ffmpeg 2>&1 | tail -1; pacman -Q firefox mpv'
  ./vm.sh ssh 'U=$(stat -c %U /run/user/1000); rm -rf /tmp/avs-ff; mkdir -p /tmp/avs-ff; cat > /tmp/avs-ff/user.js <<P
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.sessionstore.resume_from_crash", false);
P
chown -R $U /tmp/avs-ff'
  ./vm.sh ssh 'cd /opt/avs && D=700 &&
    nice ffmpeg -loglevel error -y -f lavfi -i "color=c=black:s=1280x720:r=60:d=$D,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='"'"'lt(mod(t+0.0001,1),0.1)'"'"',format=yuv420p" \
      -f lavfi -i "aevalsrc='"'"'0.7*sin(2*PI*1000*t)*lt(mod(t,1),0.05)|0.7*sin(2*PI*1000*t)*lt(mod(t,1),0.05)'"'"':s=48000:d=$D" \
      -c:v libx264 -profile:v high -preset veryfast -g 60 -bf 2 -c:a aac -b:a 128k -movflags +faststart -shortest av-h264-long.mp4 && chmod a+r av-h264-long.mp4'
  MPV="mpv --fs --loop-file=inf --no-osc --no-input-default-bindings /opt/avs/av-h264.mp4"
  FF="firefox --kiosk --no-remote --profile /tmp/avs-ff file:///opt/avs/av.html?src=av-vp9.webm"
  wpok; prio; echo "$(date +%T) offset 0"; setms 0
  ./runp.sh rv-mpv-0 "loop-file=inf" "$MPV"
  ./runp.sh rv-ff-0 "avs-ff" "$FF"
  wpok; prio; echo "$(date +%T) offset 128"; setms 128
  ./runp.sh rv-mpv-128 "loop-file=inf" "$MPV"
  ./runp.sh rv-mpvpulse-128 "loop-file=inf" "${MPV/mpv /mpv --ao=pulse }"
  ./runp.sh rv-ff-128 "avs-ff" "$FF"
  wpok; prio; echo "$(date +%T) 10 min Chromium, offset 128"; DUR=600 ./run1.sh rv-chr-h264-10min-b av-h264-long.mp4
  wpok; prio; echo "$(date +%T) 10 min mpv, offset 128"; DUR=600 ./runp.sh rv-mpv-10min "loop-file=inf" "$MPV"
  wpok; prio; echo "$(date +%T) crackles"
  U=$(./vm.sh ssh 'stat -c %U /run/user/1000')
  for ms in 0 286; do
    setms $ms
    ( sleep 120; ./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000"; $R pw-top -b -n 2 | tail -6; grep -E "period|buffer" /proc/asound/card*/pcm0p/sub0/hw_params; grep delay /proc/asound/card*/pcm0p/sub0/status' > out/rv-crackle-$ms.guest.txt 2>&1 ) & P=$!
    SSH_PORT=52493 KEY=$HOME/.ssh/omacvm GUSER=$U QMP=$PWD/run/qmp QEMU_LOG=$(./vm.sh log) ./audio/measure.sh 300 both 4 \
      | python3 -c 'import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1]); r["label"]=sys.argv[1]; print(json.dumps(r))' "rv-crackle-$ms" | tee -a out/results.jsonl
    wait $P   # not a bare wait: that would wait for the watchdog too
  done
  setms 0
}
for _ in $(seq 960); do
  grep -q '^av-sync ' "$WF" 2>/dev/null || { echo "$(date +%T) my wait line is gone: stop"; exit 0; }
  if [ ! -d "$LK" ] && [ "$(grep -v '^[[:space:]]*$' "$WF" | head -1 | cut -d' ' -f1)" = av-sync ]; then
    if mkdir "$LK" 2>/dev/null; then
      echo "av-sync $(date '+%F %T') review runs, pid $$, one VM (M-avs), until ~$(date -v+75M +%H:%M)" > "$LK/owner"
      grep -v '^av-sync ' "$WF" > "$WF.tmp.$$"; cat "$WF.tmp.$$" > "$WF"; rm -f "$WF.tmp.$$"
      echo "$(date +%T) took the lock"
      release() { kill $WD 2>/dev/null; ./vm.sh stop; rm -rf "$HOME/omacvm-avs-vms/OmacVM M-avs"; grep -q '^av-sync ' "$LK/owner" 2>/dev/null && rm -rf "$LK"; echo "$(date +%T) released"; }
      trap release EXIT
      ( sleep 4500; echo "$(date +%T) watchdog"; pkill -P $$; kill $$ ) & WD=$!
      work
      echo "$(date +%T) review done"; exit 0
    fi
  fi
  sleep 30
done
