#!/bin/bash
# VMware Fusion guest specifics. Runs as root in the VM:
#   install.sh <desktop-user> <WxH@Hz: the Mac's display>
set -euo pipefail
U=${1:?usage: install.sh <desktop-user> <WxH@Hz>}
MODE=${2:?usage: install.sh <desktop-user> <WxH@Hz>}
[[ $MODE =~ ^[0-9]+x[0-9]+(@[0-9.]+)?$ ]] || { echo "install.sh: --display WxH@Hz, not '$MODE'" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
H=$(getent passwd "$U" | cut -d: -f6)

# Public DNS while OmacVM installs (guest/install.sh turns it off at the end).
"$here/dns.sh" on

# What runs as root later (the pacman hook) gets its own root-owned copy.
L=/usr/local/lib/omacvm/fusion
install -d -o root -g root -m755 "$L"
install -o root -g root -m755 "$here/build-hyprland.sh" "$L/"
install -o root -g root -m644 "$here/hyprland-vmwgfx-dmabuf.patch" "$L/"

# Hyprland with the vmwgfx fix, now and after every hyprland upgrade. The hook
# cannot install packages (pacman's database is locked), so the build tools stay.
install -Dm644 /dev/stdin /etc/pacman.d/hooks/zz-omacvm-hyprland.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = hyprland

[Action]
Description = OmacVM: Hyprland with the vmwgfx fix for VMware Fusion (10 to 20 minutes)
When = PostTransaction
Exec = /usr/local/lib/omacvm/fusion/build-hyprland.sh --hook
HOOK
# This first build runs from OmacVM's own folder: it installs its build tools with
# ../../guest/pkg-add, which the copy in $L cannot reach (the hook needs none).
"$here/build-hyprland.sh" "$U"

# Displays: VMware Tools brings Fusion's layout (every Mac display in full
# screen, the window size in a window) to vmwgfx; omacvm-fusion-displays puts
# Hyprland's monitors where it says. monitors.lua starts every output at its
# preferred mode, the Mac's display mode until the layout arrives. Scale: what
# Omarchy's scaling menu chose, else 2 on a Retina-size display.
"$here/build-open-vm-tools.sh" "$U"
install -m644 "$here/omacvm-fusion-displays.service" /etc/systemd/user/omacvm-fusion-displays.service
systemctl --global disable omacvm-fusion-displays.service >/dev/null 2>&1 || true   # older versions: every user
systemctl --user -M "$U@" enable omacvm-fusion-displays.service >/dev/null 2>&1
# Copy and paste: VMware's agent on a private X display, synced with Wayland's
# clipboard (omacvm-fusion-clipboard). The tools' own autostart entry would
# start a second agent on Hyprland's X11 display, where it cannot work.
"$here/../../guest/pkg-add" xorg-server-xvfb xorg-xauth xsel wl-clipboard libxfixes
install -Dm644 /dev/stdin "$H/.config/autostart/vmware-user.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=VMware User Agent (started by omacvm-fusion-clipboard instead)
Exec=/usr/bin/vmware-user-suid-wrapper
Hidden=true
DESKTOP
chown -R "$U:$U" "$H/.config/autostart"
install -m644 "$here/omacvm-fusion-clipboard.service" /etc/systemd/user/omacvm-fusion-clipboard.service
systemctl --global disable omacvm-fusion-clipboard.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" enable omacvm-fusion-clipboard.service >/dev/null 2>&1

# Chromium, Chrome and Brave block VMware's GPU driver (SVGA3D) and draw
# everything in software: WebGL off, slow pages. The GPU works fine, so skip
# the blocklist. Chromium and Chrome (through install-chrome.sh's launcher)
# read /etc/<name>-flags.conf, which Omarchy never rewrites. Brave reads only
# ~/.config/brave-flags.conf, which "omarchy install browser brave" replaces:
# omacvm apply puts the line back.
B=$H/.config/brave-flags.conf
for c in /etc/chromium-flags.conf /etc/chrome-flags.conf "$B"; do
  [[ $c == /etc/* || -f $c ]] || command -v brave >/dev/null || continue
  grep -qx -- '--ignore-gpu-blocklist' "$c" 2>/dev/null || echo '--ignore-gpu-blocklist' >> "$c"
done
if [[ -f $B ]]; then chown "$U:$U" "$B"; fi
# Firefox counts every vmwgfx driver as software GL (widget/gtk/GfxInfo.cpp)
# and draws pages (WebRender) and WebGL (llvmpipe) in software. Allow the GPU
# for those three. Our own default-pref file: Firefox updates leave it alone,
# and Firefox's downloadable blocklist only sets or clears user values.
# Written even without Firefox, so a later install is covered.
install -Dm644 /dev/stdin /usr/lib/firefox/defaults/pref/omacvm-fusion.js <<'JS'
// OmacVM, VMware Fusion: Firefox counts VMware's GPU driver (vmwgfx) as
// software GL and draws pages and WebGL in software. The GPU works: allow it.
pref("gfx.blacklist.layers.opengl", 1);
pref("gfx.blacklist.webrender", 1);
pref("gfx.blacklist.webgl-use-hardware", 1);
JS

M=$H/.config/hypr/monitors.lua
# Written next to it and moved into place, only when it changes: Hyprland
# reloads on every write.
tmp=$(mktemp "$M.XXXXXX")
# Ours already: only the first mode changes, the rest stays as you left it.
if head -1 "$M" 2>/dev/null | grep -q '^-- OmacVM, VMware Fusion'; then
  sed "s|^\(hl.monitor({ output = \"Virtual-1\", mode = \)\"[^\"]*\"|\1\"$MODE\"|" "$M" > "$tmp"
else
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" 2>/dev/null | head -1)
[[ -n $scale ]] || { w=${MODE%%x*}; (( w >= 3000 )) && scale=2 || scale=1; }
gdk=$(printf '%.0f' "$scale")
cat > "$tmp" <<LUA
-- OmacVM, VMware Fusion: every output VMware Fusion gives the VM (one per Mac
-- display in full screen), placed by omacvm-fusion-displays as Fusion lays them
-- out. Virtual-1 starts at the Mac's display mode until Fusion's layout
-- arrives. Omarchy's scaling menu writes omarchy_monitor_scale here.
local omarchy_gdk_scale = ${gdk}
local omarchy_monitor_scale = ${scale}

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "$MODE", position = "0x0", scale = omarchy_monitor_scale })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
LUA
fi
if cmp -s "$tmp" "$M"; then rm -f "$tmp"; else chmod 644 "$tmp"; chown "$U:$U" "$tmp"; mv -f "$tmp" "$M"; fi
scale=$(sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' "$M" | head -1)
if systemctl --user -M "$U@" daemon-reload 2>/dev/null; then
  systemctl --user -M "$U@" restart omacvm-fusion-displays.service 2>/dev/null || true
  pkill -u "$U" -f 'vmtoolsd -n vmusr' 2>/dev/null || true   # a stray agent on Hyprland's X11 display
  systemctl --user -M "$U@" restart omacvm-fusion-clipboard.service 2>/dev/null || true
fi
echo "VMware Fusion: Hyprland with the vmwgfx fix, VMware Tools, displays (first: $MODE, scale $scale), copy and paste, browsers on the GPU"
