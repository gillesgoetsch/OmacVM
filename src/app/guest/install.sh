#!/bin/bash
# OmacVM.app specifics, guest side. Run as root inside the VM: ./install.sh <desktop-user>
#  * the display follows the Mac window (omacvm-display-sync, from try-omarchy);
#    in full screen beside the notch, Omarchy's bar fills the strip
#  * Quit on the Mac (the VM's power button) shuts Omarchy down
#  * the clipboard, both ways (omacvm-clipboard, from try-omarchy)
#  * the QEMU guest agent
#  * the Mac's sound delay for A/V sync in videos (omacvm-audio-latency)
#  * the Mac folder at ~/Mac, when the app shares one (omacvm-mac-folder)
#  * the desktop starts again by itself when the Mac lost its GPU context
#    (omacvm-desktop-recover, run by the app; the new session says so)
#  * video decoding on the Mac's media engine (VA-API: vainfo, a driver shim
#    so Firefox gets NV12 surfaces, Firefox's VA-API switch; an EGL vendor
#    library that tells the shim the size apps show a video at)
#  * video encoding on it: Chrome's and Brave's VA-API encoder for WebRTC
#    (browser-video-encode.py; omacvm-video-encode at apply and each start)
#  * a hyprpicker that draws the frozen screen of screenshots only when it
#    changes (hyprpicker/; the package's drew every display on every frame)
#  * screenshots and screen sharing of HDR apps at SDR white in an HDR VM
#    (hypr-capture/: a fixed shader file per Hyprland release, 0.56.2 and 0.57.0)
#  * every Mac display in full screen (omacvm-displays; the switch
#    "Use external displays" in the bar's display menu)
#  * AirPods and media controls: the VM's player as the Mac's Now Playing
#    (omacvm-media, while the app's switch is on)
#  * OmacVM's virtio-gpu driver (HDR; the pointer on its own layer; Linux
#    7.4's damage fix for "Draw only what changed"),
#    built for every kernel but dormant: loaded only when one of the app's
#    switches starts the VM (omacvm-virtio-gpu-load)
#  * Vulkan (Venus), when the VM's Graphics setting gives it Vulkan: a Venus
#    driver for the Mac's 16 KiB pages while Arch Linux ARM's is too old
#    (venus/), now and at each boot (the setting can change between starts)
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
../../guest/pkg-add qemu-guest-agent python || true
# Started without waiting: a VM without the agent's port (the headless QEMU
# of a build or an update) would hold this step 60-90 s for the device.
systemctl enable qemu-guest-agent >/dev/null 2>&1 || true
systemctl start --no-block qemu-guest-agent >/dev/null 2>&1 || true
install -m755 omacvm-display-sync omacvm-app-host omacvm-clipboard omacvm-displays omacvm-desktop-recover omacvm-media /usr/local/bin/
# What the Mac tells the VM at start (SMBIOS strings), for omacvm-app-host and
# the virtio-gpu driver's loader.
install -Dm755 omacvm-smbios /usr/local/lib/omacvm/omacvm-smbios
# OmacVM's virtio-gpu driver (Linux 7.4's damage fix on older kernels, the
# 10-bit formats, the cursor plane option), built now and by a pacman
# hook for new kernels (as a user id of its own, from kernel.org; a kernel
# without headers is skipped), into /usr/local/lib/omacvm/virtio-gpu/<kernel>, where depmod
# does not see it. A modprobe rule hands virtio_gpu to omacvm-virtio-gpu-load,
# which loads it only when one of the app's switches starts the VM, else the
# stock one.
VG=/usr/local/lib/omacvm/virtio-gpu
install -Dm755 virtio-gpu/omacvm-virtio-gpu-build $VG/omacvm-virtio-gpu-build
install -Dm755 virtio-gpu/omacvm-virtio-gpu-load $VG/omacvm-virtio-gpu-load
install -Dm644 virtio-gpu/linux-virtio-gpu-deep-color.patch $VG/linux-virtio-gpu-deep-color.patch
install -Dm644 virtio-gpu/linux-virtio-gpu-damage-clips.patch $VG/linux-virtio-gpu-damage-clips.patch
install -Dm644 virtio-gpu/linux-virtio-gpu-cursor-plane.patch $VG/linux-virtio-gpu-cursor-plane.patch
install -Dm644 virtio-gpu/linux-virtio-gpu-hdr-metadata.patch $VG/linux-virtio-gpu-hdr-metadata.patch
# Frames in step with the Mac (its vsync-lock patch, 3.2.3-3.2.6) is gone.
rm -f $VG/linux-virtio-gpu-vsync-lock.patch
ln -sf $VG/omacvm-virtio-gpu-build /usr/local/bin/omacvm-virtio-gpu-build
install -Dm644 virtio-gpu/95-omacvm-virtio-gpu.hook /etc/pacman.d/hooks/95-omacvm-virtio-gpu.hook
$VG/omacvm-virtio-gpu-build --hook > /var/log/omacvm-virtio-gpu.log 2>&1 || true
echo "OmacVM.app: virtio-gpu driver $($VG/omacvm-virtio-gpu-build --status 2>/dev/null || true)"
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
# AirPods and media controls (over a virtio port; the same uaccess rule): the
# VM's MPRIS players through Gio (python-gobject, in Omarchy's base; added only
# when missing). The agent waits for the app's switch before it reads them.
../../guest/pkg-add python-gobject || true
install -m644 omacvm-media.service /etc/systemd/user/
systemctl --global enable omacvm-media.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" daemon-reload 2>/dev/null && systemctl --user -M "$U@" restart omacvm-media.service 2>/dev/null || true
# The switch "Use external displays" in Omarchy's display panel: Omarchy's own
# widget with one more section (omacvm.monitor; the stock one stays if it no
# longer fits).
W=$(mktemp -d)
if python3 monitor-widget/build.py "$W/omacvm.monitor"; then
  ../../lib/install-plugin.sh "$U" "$W/omacvm.monitor" || echo "WARN: the display widget did not install"
fi
rm -rf "$W"
# The Mac's sound delay (QEMU's buffers and the Mac's output), sent by the
# app over the guest agent: PipeWire's latency offset on the card's output,
# so videos keep the picture in step with the sound.
install -m755 omacvm-audio-latency /usr/local/bin/
install -m644 omacvm-audio-latency.service /etc/systemd/user/
systemctl --global enable omacvm-audio-latency.service >/dev/null 2>&1 || true
install -m644 omacvm-app-host.service /etc/systemd/system/
systemctl enable --now omacvm-app-host.service >/dev/null 2>&1 || true
# The Mac folder at ~/Mac, when the app shares one (its setting; off by default).
install -m755 omacvm-mac-folder /usr/local/bin/
install -m644 omacvm-mac-folder.service /etc/systemd/system/
systemctl enable omacvm-mac-folder.service >/dev/null 2>&1 || true
install -Dm644 90-omacvm-app.conf /etc/environment.d/90-omacvm-app.conf
# Omarchy ignores the power key; here it comes only from the Mac's Quit.
install -Dm644 90-omacvm-app-power.conf /etc/systemd/logind.conf.d/90-omacvm-app-power.conf
# Idle power: the display's vblank timer stops 100 ms after the last frame
# instead of DRM's 5 s: now, at each boot (tmpfiles) and for a drm module
# loaded later (modprobe.d).
install -Dm644 90-omacvm-vblank.tmpfiles /etc/tmpfiles.d/90-omacvm-vblank.conf
install -Dm644 omacvm-vblank.modprobe /etc/modprobe.d/omacvm-vblank.conf
systemd-tmpfiles --create /etc/tmpfiles.d/90-omacvm-vblank.conf 2>/dev/null || true
# Only when it changed: Hyprland reloads its config on every write, and a
# reload moves the displays (a flicker on each apply).
home_same "$H/.config/hypr/omacvm_app.lua" omacvm_app.lua || home_put "$H/.config/hypr/omacvm_app.lua" < omacvm_app.lua
B=$H/.config/hypr/hyprland.lua
home_grep "$B" -qxF 'require("hypr.omacvm_app")' ||
  printf -- '-- OmacVM.app: the display follows the Mac window.\nrequire("hypr.omacvm_app")\n' | home_append "$B"
A=$H/.config/hypr/autostart.lua
home_grep "$A" -q omacvm-display-sync || echo 'o.launch_on_start("omacvm-display-sync")' | home_append "$A"
# After the app restarted a desktop that lost its GPU context: say so, and which apps closed.
home_grep "$A" -q omacvm-desktop-recover || echo 'o.launch_on_start("omacvm-desktop-recover notify")' | home_append "$A"
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
  # Videos at their own size where the decoder's surface is larger (H.264 1080p: 1088
  # rows): an EGL vendor library in front of Mesa's hands the app's video imports to the
  # shim (omacvm_egl.c, ADR 0063); it also starts Ghostty on Mesa's CPU renderer (ADR 0064).
  # The library first, then glvnd's file; if it does not build, the file goes first (glvnd
  # would skip a missing library anyway).
  if cc -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libEGL_omacvm.so.0 \
       -o "$T/libEGL_omacvm.so.0" omacvm_egl.c -ldl 2>/dev/null; then
    install -Dm755 "$T/libEGL_omacvm.so.0" /usr/local/lib/libEGL_omacvm.so.0
    install -Dm644 10-omacvm-egl.json /etc/glvnd/egl_vendor.d/10_omacvm.json
  else
    rm -f /etc/glvnd/egl_vendor.d/10_omacvm.json
    rm -f /usr/local/lib/libEGL_omacvm.so.0
    echo "OmacVM.app: the EGL vendor library did not build (EGL or glvnd headers missing?): H.264 1080p keeps 8 extra rows in Chrome and mpv, and Ghostty opens no window"
  fi
else
  echo "OmacVM.app: no C compiler, video decoding without the Firefox shim"
fi
rm -rf "$T"
install -Dm644 omacvm-app-video.js /usr/lib/firefox/defaults/pref/omacvm-app-video.js
# Chrome, Chromium, Brave, Vivaldi and Electron (by program name): a GL
# renderer string without "virgl", so Skia keeps instanced drawing for canvas
# and SVG paths (the file says why).
install -Dm644 50-omacvm-chrome.drirc /usr/share/drirc.d/50-omacvm-chrome.conf
# Vulkan (Venus): a Venus driver that sizes GPU memory to the Mac's 16 KiB
# pages (venus/vulkan-virtio.sh says why). Built now when the Mac says this VM
# gets Vulkan (OMACVM_GRAPHICS, from omacvm apply), and after each boot (a
# timer, after the desktop) when the VM has Venus and still lacks it.
graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' /etc/omacvm/env 2>/dev/null | tail -1)
want=""; [[ $graphics == vulkan ]] && want=--want
venus/vulkan-virtio.sh $want || echo "WARN: Vulkan (Venus) is not set up; OpenGL is unaffected"
# vulkaninfo (vulkan-tools, small) for omacvm check's Vulkan line, with the Venus driver (#332).
if pacman -Q vulkan-virtio >/dev/null 2>&1 && ! command -v vulkaninfo >/dev/null; then
  ../../guest/pkg-add vulkan-tools || echo "WARN: vulkaninfo not installed (vulkan-tools); omacvm check does not ask it"
fi
# OpenCL and WebGPU on that Vulkan: guest/install.sh's gpu-compute step (venus/compute.sh).
# mpv's defaults (venus/mpv.sh): vo=gpu in every app VM (gpu-next leaks a file
# per frame on virgl), and OpenGL while the VM has Venus (no video on Vulkan yet).
venus/mpv.sh || echo "WARN: mpv's defaults are not set; mpv may stop drawing after ~17 s of video"
# Vulkan windows: on the GPU when the Mac's app can show them, else through a
# CPU copy (omacvm-vulkan-present says why). It replaces 3.0.0 RC's fixed
# environment.d file.
rm -f /etc/environment.d/90-omacvm-vulkan.conf
install -Dm755 omacvm-vulkan-present /usr/lib/systemd/user-environment-generators/90-omacvm-vulkan-present
# The Venus driver check after each boot (a timer, only with Vulkan).
venus/timer.sh || true
# Screenshots and the screen recording picker freeze the screen with hyprpicker,
# which drew every display again on every frame (a whole screen to the Mac's GPU
# each time): a build that draws only when something changed, now and after
# hyprpicker upgrades (hyprpicker/build.sh; the package's stays if it fails).
install -Dm755 hyprpicker/build.sh /usr/local/lib/omacvm/hyprpicker/build.sh
install -Dm644 hyprpicker/redraw-on-change.patch /usr/local/lib/omacvm/hyprpicker/redraw-on-change.patch
install -Dm644 hyprpicker/95-omacvm-hyprpicker.hook /etc/pacman.d/hooks/95-omacvm-hyprpicker.hook
hyprpicker/build.sh "$U" || true
# What that build left up to 3.1.24: 3 buffer files per display per screenshot
# in the runtime folder (/run/user/UID, a tmpfs of 10 % of the VM's memory),
# until it was full and Hyprland and apps died of SIGBUS. A restart clears them
# too. Only while no hyprpicker runs (a screenshot being taken keeps its own).
if ! pgrep -x hyprpicker >/dev/null; then
  find /run/user -mindepth 2 -maxdepth 2 -type f -name '.hyprpicker_*' -delete 2>/dev/null || true
fi
# Screenshots, colour picks and screen sharing of HDR apps (Chrome) in an HDR VM
# came out 2.54 times too bright: Hyprland 0.56.2 and 0.57.0 put their SDR white
# at 80 nits in its copy for captures (#579). A fixed copy of that one shader
# file (one per Hyprland release), only while the installed Hyprland is the one
# it was made for; pacman hooks take it out before Hyprland changes and put the
# new release's in after (hypr-capture/hypr-capture.sh). A running desktop gets
# it at once.
HC=/usr/local/lib/omacvm/hypr-capture
rm -rf "$HC.new" "$HC.old"
install -Dm755 hypr-capture/hypr-capture.sh "$HC.new/hypr-capture.sh"
install -Dm644 hypr-capture/guard.py "$HC.new/guard.py"
install -Dm644 hypr-capture/LICENSE.hyprland "$HC.new/LICENSE.hyprland"
for v in hypr-capture/*/; do
  install -Dm644 -t "$HC.new/$(basename "$v")" "${v}cm_helpers.glsl" "${v}original"
done
if [[ -d $HC ]]; then mv "$HC" "$HC.old"; fi
mv "$HC.new" "$HC"; rm -rf "$HC.old"
install -Dm644 hypr-capture/05-omacvm-hypr-capture-pre.hook /etc/pacman.d/hooks/05-omacvm-hypr-capture-pre.hook
install -Dm644 hypr-capture/95-omacvm-hypr-capture.hook /etc/pacman.d/hooks/95-omacvm-hypr-capture.hook
"$HC/hypr-capture.sh" || true
# Video encoding on the Mac's media engine (FFmpeg's h264_vaapi/hevc_vaapi need
# nothing): Chrome's and Brave's WebRTC encoder, when this app offers encoding.
# Without the VM's GPU (Update VM's run) the flags stay as they are; each
# start puts back what is missing (omacvm-video-encode).
install -m755 omacvm-video-encode /usr/local/bin/
install -m644 omacvm-video-encode.service /etc/systemd/system/
systemctl enable omacvm-video-encode.service >/dev/null 2>&1 || true
OMACVM_VIDEO_ENCODE_PY=$PWD/browser-video-encode.py ./omacvm-video-encode apply "$U"
echo "OmacVM.app: display sync, every Mac display, media controls, guest agent, video decoding and encoding"
