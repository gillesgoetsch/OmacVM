#!/bin/bash
# The Venus driver check after each boot (omacvm-venus-driver.timer), as root
# in an OmacVM.app VM. On only for a VM whose Graphics gives it Vulkan or with
# the vulkan feature (/etc/omacvm/env): with OpenGL nothing of it runs
# (2026-10-06: it ran at every boot). Run by app/guest/install.sh and by
# guest/install.sh's vulkan step (a feature switch runs only that step).
set -euo pipefail
cd "$(dirname "$0")"
ENV=${OMACVM_ENV:-/etc/omacvm/env}
# Up to 3.0.0 RC2 the service itself was wanted by multi-user.target, after
# network-online.target: the boot (and the desktop) waited for a build.
# Now a timer starts it after the desktop is up.
rm -f /etc/systemd/system/multi-user.target.wants/omacvm-venus-driver.service
install -Dm644 omacvm-venus-driver.service /etc/systemd/system/omacvm-venus-driver.service
install -Dm644 omacvm-venus-driver.timer /etc/systemd/system/omacvm-venus-driver.timer
systemctl daemon-reload
graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENV" 2>/dev/null | tail -1)
vfeat=$(sed -n 's/^OMACVM_FEATURE_vulkan=//p' "$ENV" 2>/dev/null | tail -1)
if [[ $graphics == vulkan || $vfeat == on ]]; then
  systemctl enable omacvm-venus-driver.timer >/dev/null 2>&1 || true
else
  systemctl disable --now omacvm-venus-driver.timer >/dev/null 2>&1 || true
fi
