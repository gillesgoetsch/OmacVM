#!/bin/bash
# fix.sh (ON the mini, from hold.sh after the matrix, VM may be off): the 3.0.1 fix, re-measured.
# Installs omacvm-audio-latency in the test VM (as src/app/guest/install.sh does), sets the delay as the app
# would (QEMU's part + the Mac's output device), plays the clips again. avcap takes the sound before the output
# device, so the expected offset is about minus the device's latency (outlat), and the same at the ear.
# QPART: QEMU's part in ms (default: the app's AudioDelay.qemuMs); CAL=1 also runs with QEMU's part taken from
# this run's def-h264 median (the calibration).
set -u
W=/private/tmp/omacvm-avs; cd "$W"; mkdir -p out
QPART=${QPART:-115}
dev=$(sed -n 's/.* = \([0-9.]*\) ms$/\1/p' out/outlat.txt | head -1); dev=${dev:-0}
echo "$(date +%T) fix: device ${dev} ms, QEMU part ${QPART} ms"
./vm.sh stop; GFX=opengl ./vm.sh start || exit 1
./vm.sh ssh 'cat > /usr/local/bin/omacvm-audio-latency && chmod 755 /usr/local/bin/omacvm-audio-latency' < fix/omacvm-audio-latency
./vm.sh ssh 'cat > /etc/systemd/user/omacvm-audio-latency.service && systemctl --global enable omacvm-audio-latency.service' < fix/omacvm-audio-latency.service
G=out/fix-setup.guest.txt
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000";
  echo "== cards"; $R pactl -f json list cards | python3 -c "import json,sys; [print(c[\"name\"], list(c[\"ports\"])) for c in json.load(sys.stdin)]";
  echo "== sinks before"; $R pactl list sinks | grep -E "Name:|Latency"' > "$G" 2>&1
setrun() {  # setrun MS LABEL...: the delay as root (as qemu-ga runs it), then the clips
  local ms=$1; shift
  ./vm.sh ssh "/usr/local/bin/omacvm-audio-latency $ms; echo rc \$?; U=\$(stat -c %U /run/user/1000);
    sudo -u \$U env XDG_RUNTIME_DIR=/run/user/1000 /usr/local/bin/omacvm-audio-latency --show;
    sudo -u \$U env XDG_RUNTIME_DIR=/run/user/1000 pactl list sinks | grep -E 'Latency'" >> "$G" 2>&1
  for l in "$@"; do
    case $l in
      *vp9*) ./run1.sh "$l" av-vp9.webm ;;
      *stall*) LOAD=gpu DUR=90 ./run1.sh "$l" av-h264.mp4 ;;
      *) ./run1.sh "$l" av-h264.mp4 ;;
    esac
  done
}
total=$(python3 -c "print(round($QPART + $dev))")
T=${TAG:-}   # TAG: a label suffix for repeated runs
setrun "$total" "fix$T-h264" "fix$T-vp9" "fix$T-h264-stall"
if [[ ${CAL:-1} == 1 ]]; then
  cal=$(python3 -c "
import json
r=[json.loads(l) for l in open('out/results.jsonl') if l.strip()]
d=[x for x in r if x.get('label')=='def-h264' and 'median_ms' in x]
print(round(d[-1]['median_ms'] + $dev) if d else '')")
  [[ -n $cal ]] && setrun "$cal" "fix-cal${cal}-h264" "fix-cal${cal}-vp9"
fi
# Survives PipeWire's restart (WirePlumber keeps the offset), and the user unit sets it again.
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); R="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000";
  $R systemctl --user restart pipewire pipewire-pulse wireplumber; sleep 6;
  echo "== after PipeWire restart"; $R /usr/local/bin/omacvm-audio-latency --show;
  $R systemctl --user start omacvm-audio-latency.service; echo "unit: $($R systemctl --user is-active omacvm-audio-latency.service) $($R systemctl --user show -p Result --value omacvm-audio-latency.service)";
  $R /usr/local/bin/omacvm-audio-latency --show' >> "$G" 2>&1
./vm.sh ssh '/usr/local/bin/omacvm-audio-latency 0' >/dev/null 2>&1
echo "$(date +%T) fix done"
