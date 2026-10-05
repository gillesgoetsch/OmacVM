#!/bin/bash
# GPU check for an OmacVM.app VM: Google Chrome in the VM runs WebGL Aquarium
# and Basemark Web 3.0 (src/bench/bench.sh). Both must give a number, and
# QEMU's log must show no shader the Mac refused: one refused shader stops
# that GL context in the guest for good (Chrome hung in Basemark at test 5).
#
#   gpu-check.sh VM_DIR [RUNS]      (default 1; Basemark takes about 2 minutes)
#
# Run on the Mac while the VM runs (in the app or any QEMU window) and its
# desktop user is logged in. Installs Google Chrome in the VM when it is
# missing. Exit 0 = passed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "${1:?usage: gpu-check.sh VM_DIR [RUNS]}"
RUNS=${2:-1}
QLOG=$LOG/qemu.log

vssh true 2>/dev/null || die "no SSH to $NAME on 127.0.0.1:$SSH_PORT: is it running?"
for _ in $(seq 60); do vssh "ls /run/user/1000/hypr" >/dev/null 2>&1 && break; sleep 5; done
vssh "ls /run/user/1000/hypr" >/dev/null 2>&1 || die "no desktop session in $NAME"
U=$(vssh "id -nu 1000")

log "bench tools and Google Chrome in the VM"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$OMACVM_SRC" -cf - bench |
  vssh "rm -rf /opt/omacvm-bench && mkdir -p /opt/omacvm-bench && tar --no-same-owner --strip-components 1 -C /opt/omacvm-bench -xf -" ||
  die "could not copy the bench tools"
vssh "[ -x /opt/google/chrome/google-chrome ] || /opt/omacvm-bench/install-chrome.sh >/dev/null" ||
  die "could not install Google Chrome in the VM"

start=$(wc -c < "$QLOG" 2>/dev/null || echo 0)
log "Aquarium and Basemark, $RUNS run(s)"
vssh "SIG=\$(ls -t /run/user/1000/hypr | head -1)
  E='XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE='\$SIG
  idle=\$(pgrep -u $U -x hypridle >/dev/null && echo 1)
  pkill -u $U -x hypridle
  rm -f /tmp/gpu-check.jsonl
  sudo -u $U env \$E bash -c 'cd /tmp && /opt/omacvm-bench/bench.sh --runs $RUNS --only aquarium,basemark /tmp/gpu-check.jsonl' >&2
  [ -n \"\$idle\" ] && sudo -u $U env \$E bash -c 'setsid hypridle >/dev/null 2>&1 < /dev/null &'
  cat /tmp/gpu-check.jsonl" > "$LOG/gpu-check.jsonl"

fail=0
for t in aquarium basemark; do
  vals=$(python3 -c 'import json,sys
print(" ".join(str(json.loads(l).get("value")) for l in open(sys.argv[1]) if json.loads(l).get("test") == sys.argv[2]))' \
    "$LOG/gpu-check.jsonl" "$t" 2>/dev/null)
  if [[ -z $vals || $vals == *None* ]]; then
    echo "FAIL: $t: ${vals:-no result}"; fail=1
  else
    echo "PASS: $t: $vals"
  fi
done
refused=$(tail -c +$((start + 1)) "$QLOG" 2>/dev/null |
  grep -E -m5 'Shader failed to compile|failed to dispatch|ctrl 0x[0-9a-f]+, error' || true)
if [[ -n $refused ]]; then
  echo "FAIL: the Mac's OpenGL refused GPU work (more in $QLOG):"; echo "$refused"; fail=1
else
  echo "PASS: no refused shaders or GPU commands in QEMU's log"
fi
exit $fail
