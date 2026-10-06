#!/bin/bash
# OmacVM.app specifics, guest side. Run as root inside the VM: ./install.sh <desktop-user>
#  * the display follows the Mac window (omacvm-display-sync, from try-omarchy);
#    in full screen beside the notch, Omarchy's bar fills the strip
#  * Quit on the Mac (the VM's power button) shuts Omarchy down
#  * the clipboard, both ways (omacvm-clipboard, from try-omarchy)
#  * the QEMU guest agent
#  * video decoding on the Mac's media engine (VA-API: vainfo, a driver shim
#    so Firefox gets NV12 surfaces, Firefox's VA-API switch)
#  * video encoding on it: Chrome's and Brave's VA-API encoder for WebRTC
#    (browser-video-encode.py)
#  * every Mac display in full screen (omacvm-displays; the switch
#    "Use external displays" in the bar's display menu)
#  * HDR's 10-bit virtio-gpu module builder (not built until the user asks)
#  * Vulkan (Venus), when the VM's Graphics setting gives it Vulkan: a Venus
#    driver for the Mac's 16 KiB pages while Arch Linux ARM's is too old
#    (venus/), now and at each boot (the setting can change between starts)
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
../../guest/pkg-add qemu-guest-agent python || true
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
install -m755 omacvm-display-sync omacvm-app-host omacvm-clipboard omacvm-displays /usr/local/bin/
# HDR (off until the user runs omacvm-virtio-gpu-build): the 10-bit virtio-gpu
# module's builder, and a pacman hook that rebuilds it for new kernels.
install -Dm755 virtio-gpu/omacvm-virtio-gpu-build /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-build
install -Dm644 virtio-gpu/linux-virtio-gpu-deep-color.patch /usr/local/lib/omacvm/virtio-gpu/linux-virtio-gpu-deep-color.patch
ln -sf /usr/local/lib/omacvm/virtio-gpu/omacvm-virtio-gpu-build /usr/local/bin/omacvm-virtio-gpu-build
install -Dm644 virtio-gpu/95-omacvm-virtio-gpu.hook /etc/pacman.d/hooks/95-omacvm-virtio-gpu.hook
# Clipboard both ways, over a virtio port (the agent is try-omarchy's).
../../guest/pkg-add wl-clipboard || true
# uaccess: the logged-in user may open the port (before 73-seat-late.rules).
install -m644 70-omacvm-clipboard.rules /etc/udev/rules.d/
udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
install -m644 omacvm-clipboard.service /etc/systemd/user/
systemctl --global enable omacvm-clipboard.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" daemon-reload 2>/dev/null && systemctl --user -M "$U@" restart omacvm-clipboard.service 2>/dev/null || true
# The Mac's displays (over a virtio port; the same uaccess rule).
install -m644 omacvm-displays.service /etc/systemd/user/
systemctl --global enable omacvm-displays.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" daemon-reload 2>/dev/null && systemctl --user -M "$U@" restart omacvm-displays.service 2>/dev/null || true
# The switch "Use external displays" in Omarchy's display panel: Omarchy's own
# widget with one more section (omacvm.monitor; the stock one stays if it no
# longer fits).
W=$(mktemp -d)
if python3 monitor-widget/build.py "$W/omacvm.monitor"; then
  ../../lib/install-plugin.sh "$U" "$W/omacvm.monitor" || echo "WARN: the display widget did not install"
fi
rm -rf "$W"
install -m644 omacvm-app-host.service /etc/systemd/system/
systemctl enable --now omacvm-app-host.service >/dev/null 2>&1 || true
install -Dm644 90-omacvm-app.conf /etc/environment.d/90-omacvm-app.conf
# Omarchy ignores the power key; here it comes only from the Mac's Quit.
install -Dm644 90-omacvm-app-power.conf /etc/systemd/logind.conf.d/90-omacvm-app-power.conf
install -o "$U" -g "$U" -m644 omacvm_app.lua "$H/.config/hypr/omacvm_app.lua"
B=$H/.config/hypr/hyprland.lua
grep -qxF 'require("hypr.omacvm_app")' "$B" || {
  printf -- '-- OmacVM.app: the display follows the Mac window.\nrequire("hypr.omacvm_app")\n' >> "$B"; chown "$U:$U" "$B"; }
A=$H/.config/hypr/autostart.lua
grep -q omacvm-display-sync "$A" 2>/dev/null || { echo 'o.launch_on_start("omacvm-display-sync")' >> "$A"; chown "$U:$U" "$A"; }
# Video decoding on the Mac's media engine (the app's QEMU passes VA-API to
# VideoToolbox): vainfo, the driver shim for Firefox, and Firefox's switch.
../../guest/pkg-add libva-utils || true
T=$(mktemp -d)
if cc -shared -fPIC -O2 -o "$T/omacvm_drv_video.so" omacvm_drv_video.c -ldl 2>/dev/null; then
  install -Dm755 "$T/omacvm_drv_video.so" /usr/local/lib/dri/omacvm_drv_video.so
  install -Dm644 90-omacvm-video.conf /etc/environment.d/90-omacvm-video.conf
  # Firefox decodes in its sandboxed RDD process, which may read only the
  # library paths ld.so knows: without this vaInitialize fails there.
  echo /usr/local/lib/dri > /etc/ld.so.conf.d/omacvm-video.conf
  ldconfig
else
  echo "OmacVM.app: no C compiler, video decoding without the Firefox shim"
fi
rm -rf "$T"
install -Dm644 omacvm-app-video.js /usr/lib/firefox/defaults/pref/omacvm-app-video.js
# Vulkan (Venus): a Venus driver that sizes GPU memory to the Mac's 16 KiB
# pages (venus/vulkan-virtio.sh says why). Built now when the Mac says this VM
# gets Vulkan (OMACVM_GRAPHICS, from omacvm apply), and after each boot (a
# timer, after the desktop) when the VM has Venus and still lacks it.
graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' /etc/omacvm/env 2>/dev/null | tail -1)
want=""; [[ $graphics == vulkan ]] && want=--want
venus/vulkan-virtio.sh $want || echo "WARN: Vulkan (Venus) is not set up; OpenGL is unaffected"
# OpenCL (GPU compute) on that Vulkan: the distro's rusticl on Zink (venus/opencl.sh says where it works).
if [[ $graphics == vulkan ]]; then venus/opencl.sh || echo "WARN: OpenCL is not set up; Vulkan and OpenGL are unaffected"
elif [[ $graphics == opengl ]]; then venus/opencl.sh --off; fi
# WebGPU in Chromium on that Vulkan: the "Chromium (WebGPU)" launcher (venus/webgpu.sh).
if [[ $graphics == vulkan ]]; then venus/webgpu.sh || echo "WARN: WebGPU in Chromium is not set up; Vulkan and OpenGL are unaffected"
elif [[ $graphics == opengl ]]; then venus/webgpu.sh --off; fi
# Vulkan windows: on the GPU when the Mac's app can show them, else through a
# CPU copy (omacvm-vulkan-present says why). It replaces 3.0.0 RC's fixed
# environment.d file.
rm -f /etc/environment.d/90-omacvm-vulkan.conf
install -Dm755 omacvm-vulkan-present /usr/lib/systemd/user-environment-generators/90-omacvm-vulkan-present
# Up to 3.0.0 RC2 the service itself was wanted by multi-user.target, after
# network-online.target: the boot (and the desktop) waited for a build.
# Now a timer starts it after the desktop is up.
rm -f /etc/systemd/system/multi-user.target.wants/omacvm-venus-driver.service
install -Dm644 venus/omacvm-venus-driver.service /etc/systemd/system/omacvm-venus-driver.service
install -Dm644 venus/omacvm-venus-driver.timer /etc/systemd/system/omacvm-venus-driver.timer
systemctl daemon-reload
# Only for a VM whose Graphics gives it Vulkan (or with the vulkan feature):
# with OpenGL nothing of it runs (2026-10-06: it ran at every boot).
vfeat=$(sed -n 's/^OMACVM_FEATURE_vulkan=//p' /etc/omacvm/env 2>/dev/null | tail -1)
if [[ $graphics == vulkan || $vfeat == on ]]; then
  systemctl enable omacvm-venus-driver.timer >/dev/null 2>&1 || true
else
  systemctl disable --now omacvm-venus-driver.timer >/dev/null 2>&1 || true
fi
# Video encoding on the Mac's media engine (FFmpeg's h264_vaapi/hevc_vaapi need
# nothing): Chrome's and Brave's WebRTC encoder, when this app offers encoding.
if vainfo --display drm 2>/dev/null | grep -q VAEntrypointEncSlice; then
  python3 browser-video-encode.py "$U" on
  echo "OmacVM.app: display sync, every Mac display, guest agent, video decoding and encoding"
else
  python3 browser-video-encode.py "$U" off
  echo "OmacVM.app: display sync, every Mac display, guest agent, video decoding"
fi
