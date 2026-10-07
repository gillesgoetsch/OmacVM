#!/bin/bash
# setup.sh (ON the mini, under the lock): runtime copy (v3.0.0's), avcap build, APFS clone of "Bench OmacVM", clip into the guest.
set -euo pipefail
W=/private/tmp/omacvm-avs; cd "$W"
A="$HOME/Applications/OmacVM Test.app/Contents/Resources"
if [ ! -x rt/runtime/bin/OmacVM ]; then
  mkdir -p rt; cp -R "$A/runtime" "$A/firmware" rt/; cp "$A/omacvm/COMMIT" rt/COMMIT
fi
echo "runtime from test app commit $(cat rt/COMMIT); pacing strings: $(strings rt/runtime/bin/OmacVM | grep -c 'HDA sound pacing')"
[ -x avcap ] || nice -n 20 swiftc -O -o avcap avcap.swift
S="$HOME/omacvm-bench-vms/Bench OmacVM"; D="$HOME/omacvm-avs-vms/OmacVM M-avs"
pgrep -f -- "-name Bench OmacVM -machine" >/dev/null && { echo "Bench OmacVM runs: no clone"; exit 1; }
if [ ! -f "$D/disk.img" ]; then mkdir -p "$D/logs"; cp -c "$S/disk.img" "$S/efi-vars.fd" "$D/"; fi
./vm.sh start
./vm.sh ssh 'rm -rf /opt/avs && mkdir -p /opt/avs'
tar -C clip -cf - . | ./vm.sh ssh 'tar --no-same-owner -C /opt/avs -xf - && chmod -R a+rX /opt/avs && ls /opt/avs'
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); echo "user $U"; pacman -Q chromium glmark2 pipewire wireplumber linux-aarch64 2>&1;
  echo "flags:"; cat /home/$U/.config/chromium-flags.conf 2>&1; echo "vdecd: $(systemctl is-active omacvm-vdecd 2>&1) module: $(lsmod | grep -c omacvm_vdec) dev: $(ls /dev/video* 2>&1 | tr "\n" " ")";
  ls /opt/omacvm 2>/dev/null | head; cat /etc/omacvm/features 2>/dev/null | head -40'
# chromium-video as in 3.0.0 (the user's VM has it on): install from v3.0.0's source if the clone lacks it
if [[ $(./vm.sh ssh 'systemctl is-active omacvm-vdecd' 2>/dev/null) != active ]]; then
  echo "$(date +%T) installing chromium-video (v3.0.0 src/vdec)"
  ./vm.sh ssh 'rm -rf /root/avs-vdec && mkdir -p /root/avs-vdec' && ./vm.sh ssh 'tar -C /root/avs-vdec -xf -' < vdec-v3.0.0.tar
  ./vm.sh ssh 'U=$(stat -c %U /run/user/1000); cd /root/avs-vdec/src/vdec/guest && ./install.sh "$U" on 2>&1 | tail -15' || true
fi
# Without it the def-* rows are Chromium's software decode (said here, the matrix goes on).
echo "vdecd now: $(./vm.sh ssh 'systemctl is-active omacvm-vdecd; ls /dev/video* 2>&1' 2>&1 | tr '\n' ' ')"
./vm.sh ssh 'U=$(stat -c %U /run/user/1000); tail -3 /home/$U/.config/chromium-flags.conf'

