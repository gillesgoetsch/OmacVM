#!/bin/bash
# The Mac's camera in Omarchy, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <vm-type> on|off
# UTM, VMware Fusion and OmacVM.app: /dev/video42 "Mac Camera" (v4l2loopback,
# built by DKMS for each kernel), fed by the user service omacvm-camera from
# the Bridge (UTM, Fusion) or the app's virtio port, only while an app reads it.
# Parallels passes the Mac's camera itself: nothing to install there.
# off: the service, the module and our files go; the packages stay.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <vm-type> on|off}; TYPE=${2:?vm type}; ON=${3:?on or off}
user_ctl() { systemctl --user -M "$U@" "$@"; }
FILES=(/etc/systemd/user/omacvm-camera.service /usr/local/bin/omacvm-camera /etc/modprobe.d/90-omacvm-camera.conf
       /etc/modules-load.d/90-omacvm-camera.conf /etc/udev/rules.d/70-omacvm-camera.rules)

if [[ $ON != on || $TYPE == parallels ]]; then
  [[ -e /usr/local/bin/omacvm-camera || -e /etc/systemd/user/omacvm-camera.service ]] || exit 0
  systemctl --global disable omacvm-camera.service >/dev/null 2>&1 || true
  user_ctl stop omacvm-camera.service 2>/dev/null || true
  systemctl --user -M root@ stop omacvm-camera.service >/dev/null 2>&1 || true
  rm -f "${FILES[@]}"
  rmmod v4l2loopback 2>/dev/null || true
  echo "camera: off"
  exit 0
fi

# v4l2loopback is built by DKMS against the headers of each installed kernel
# (guest/dkms.sh).
say() { echo "camera: $*" >&2; }
source ../../guest/dkms.sh
../../guest/pkg-add python dkms
kernel_headers linux-aarch64
../../guest/pkg-add v4l2loopback-dkms
# Headers that came after the module (or a new kernel): build it for them too.
[[ -n $(modinfo -k "$(uname -r)" -F filename v4l2loopback 2>/dev/null) ]] ||
  dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || true
install -Dm644 90-omacvm-camera.conf /etc/modprobe.d/90-omacvm-camera.conf
echo v4l2loopback | install -Dm644 /dev/stdin /etc/modules-load.d/90-omacvm-camera.conf
install -Dm644 70-omacvm-camera.rules /etc/udev/rules.d/70-omacvm-camera.rules
install -m755 omacvm-camera /usr/local/bin/
install -m644 omacvm-camera.service /etc/systemd/user/
usermod -aG video "$U"
udevadm control --reload 2>/dev/null || true

# Loaded with our options (another loopback device would take /dev/video42's place).
if [[ ! -e /sys/class/video4linux/video42 ]] && lsmod | grep -q '^v4l2loopback '; then
  rmmod v4l2loopback 2>/dev/null || true
fi
if ! modprobe v4l2loopback 2>/dev/null; then
  if [[ -z $(modinfo -k "$(uname -r)" -F filename v4l2loopback 2>/dev/null) ]]; then
    echo "camera: no v4l2loopback for the running kernel $(uname -r) (headers for another one?): reboot after the next kernel update, then omacvm apply" >&2
  fi
fi
udevadm trigger --subsystem-match=video4linux --subsystem-match=virtio-ports 2>/dev/null || true

systemctl --global enable omacvm-camera.service >/dev/null 2>&1
# root's own manager (an SSH login) may run one from before ConditionUser.
systemctl --user -M root@ stop omacvm-camera.service >/dev/null 2>&1 || true
if user_ctl daemon-reload 2>/dev/null; then
  user_ctl restart omacvm-camera.service 2>/dev/null || true
fi
echo "camera: /dev/video42 (Mac Camera)$( [[ -e /sys/class/video4linux/video42 ]] || echo ", after a reboot")"
