#!/bin/bash
# Power draw of the whole Mac under the same loads, on the Mac itself or with
# one VM doing the work, to compare routes and estimate battery life.
#   power-suite.sh [--vm USER@IP[:PORT]] [--seconds N] [--only idle,light,video,cpu,gpu] [OUT.jsonl]
# Run on the Mac, with nothing else open (other VMs and their apps quit, the
# VM under test in full screen on the built-in display, fixed brightness).
# Loads, each for N seconds (default 180, plus up to a minute: see power.sh)
# after 30 s to settle:
#   idle   nothing: the desktop, as you leave it
#   light  Chrome scrolling a long text page (pages/reading.html)
#   video  YouTube 4K in Chrome (video-bench.py: also reports the decoder)
#   cpu    every CPU core busy
#   gpu    WebGL Aquarium with 30,000 fish in Chrome
# The display stays on (caffeinate) at 50 % brightness, set before each load
# and read after it ("brightness" in each line: if it moved, the Mac's
# automatic brightness is on; turn it off in System Settings > Displays).
# In a VM it needs Google Chrome (install-chrome.sh) and this folder in
# /usr/local/share/omacvm/bench (omacvm apply or update puts it there); SSH as
# root with ~/.ssh/omacvm. Measures with power.sh,
# so don't touch the Mac meanwhile, and keep other programs quiet.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
VM=""; SECS=180; ONLY=idle,light,video,cpu,gpu
while [[ ${1:-} == --* ]]; do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --seconds) SECS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    *) echo "power-suite.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
OUT=${1:-$PWD/power-${VM:+vm-}$(date +%Y%m%d-%H%M).jsonl}
want() { [[ ,$ONLY, == *,$1,* ]]; }
BR=$(mktemp -d)/brightness
swiftc -O -o "$BR" "$here/brightness.swift" 2>/dev/null || BR=""
caffeinate -d -i -w $$ &
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
K=(-i "$HOME/.ssh/omacvm" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# USER@HOST:PORT (OmacVM.app: root@127.0.0.1:52222)
if [[ $VM == *:* ]]; then K+=(-p "${VM##*:}"); VM=${VM%:*}; fi
CHROME_MAC="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=9339
VM_BENCH=/usr/local/share/omacvm/bench   # where omacvm apply copies src/bench

# Run a command as the desktop user in the VM's session (or on the Mac).
in_vm() {
  ssh "${K[@]}" "$VM" "U=\$(id -nu 1000); SIG=\$(ls -t /run/user/1000/hypr | head -1)
    sudo -u \$U env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG HOME=/home/\$U $1"
}
chrome_start() {   # url
  if [[ -n $VM ]]; then
    in_vm "bash -c 'P=/tmp/omacvm-power; rm -rf \$P; mkdir -p \$P; setsid google-chrome-stable --ozone-platform=wayland --user-data-dir=\$P --remote-debugging-port=$PORT --no-first-run --no-default-browser-check --start-fullscreen \"$1\" >/dev/null 2>&1 &'"
  else
    P=$(mktemp -d); "$CHROME_MAC" --user-data-dir="$P" --remote-debugging-port=$PORT --no-first-run --no-default-browser-check --start-fullscreen "$1" >/dev/null 2>&1 &
  fi
  sleep 8
}
chrome_stop() {
  if [[ -n $VM ]]; then in_vm "pkill -f -- 'remote-debugging-port=${PORT}[ ]'" || true
  else pkill -f -- "remote-debugging-port=${PORT}[ ]" || true; fi
  sleep 3
}
measure() {   # label: settle, then power.sh; prints and appends one JSON line
  [[ -n $BR ]] && "$BR" 0.5 >/dev/null
  sleep 30
  local line b
  line=$("$here/power.sh" "$SECS" "$1")
  b=$([[ -n $BR ]] && "$BR" || echo null)
  sed "s/^{/{\"where\": \"${VM:-mac}\", \"brightness\": $b, /" <<<"$line" | tee -a "$OUT"
}
serve_reading() {   # -> URL of pages/reading.html where Chrome runs
  if [[ -n $VM ]]; then echo "file://$VM_BENCH/pages/reading.html"
  else echo "file://$here/pages/reading.html"; fi
}

if [[ -n $VM ]] && { want light || want video; } && ! ssh "${K[@]}" "$VM" "test -f $VM_BENCH/pages/reading.html -a -f $VM_BENCH/video-bench.py" </dev/null; then
  echo "power-suite.sh: $VM_BENCH not found in the VM (no SSH, or run omacvm update first)" >&2; exit 1
fi
if want idle; then say "idle"; measure idle; fi
if want light; then
  say "light: scrolling text"; chrome_start "$(serve_reading)"; measure light; chrome_stop
fi
if want video; then
  say "video: YouTube 4K"; chrome_start about:blank
  if [[ -n $VM ]]; then
    in_vm "python3 $VM_BENCH/video-bench.py --port $PORT --seconds $((SECS + 150))" > /tmp/omacvm-video.json &
  else
    python3 "$here/video-bench.py" --port $PORT --seconds $((SECS + 150)) > /tmp/omacvm-video.json &
  fi
  vb=$!
  sleep 10; measure video; wait $vb || true   # video-bench plays past the measurement
  sed "s/^{/{\"where\": \"${VM:-mac}\", /" /tmp/omacvm-video.json | tee -a "$OUT"; chrome_stop
fi
if want cpu; then
  say "cpu: every core busy"
  loop='import multiprocessing as m, time
def spin(_):
    while True: pass
with m.get_context("fork").Pool(m.cpu_count()) as p: p.map(spin, range(m.cpu_count()))'
  if [[ -n $VM ]]; then ssh "${K[@]}" "$VM" "python3 -c '$loop'" & else python3 -c "$loop" & fi
  ld=$!; measure cpu
  if [[ -n $VM ]]; then ssh "${K[@]}" "$VM" "pkill -f 'multiprocessing as [m]'" || true; fi
  kill $ld 2>/dev/null || true; pkill -f 'multiprocessing as [m]' || true; wait $ld 2>/dev/null || true
fi
if want gpu; then
  say "gpu: WebGL Aquarium, 30,000 fish"
  chrome_start "https://webglsamples.org/aquarium/aquarium.html?numFish=30000"; measure gpu; chrome_stop
fi
say "done: $OUT"
