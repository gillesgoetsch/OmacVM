#!/bin/bash
# OmacVM, guest side: everything that makes Omarchy feel native in a VM on a
# Mac, in Parallels or UTM. Run as root inside the VM from a copy of this
# repository's src/ (apply.sh puts it in /usr/local/share/omacvm):
#   guest/install.sh --user NAME --keyboard "LAYOUT [VARIANT]" [--vm-type parallels|utm|fusion]
#                    [--display WxH@Hz] [--feature NAME=on|off]... [--clock-format-b64 FMT]
#                    [--vm-name-b64 NAME] [--only F,...] [--strict F,...|all]
#                    [--graphics opengl|vulkan]   (--vm-type app: OmacVM.app)
# Features: the list in ../features.tsv (bridge, wallpaper, gestures, scroll-momentum,
# omanotch, mac-clock, camera, no-idle-lock, autologin, thp-kernel, battery, external-brightness,
# control-centre, fast-network, chromium-video, vulkan, x86-apps, touch-id) with its defaults; a feature
# needing another one is off without it. Choices are kept in /etc/omacvm/env,
# so a later run without --feature keeps them.
# --vm-type defaults to what the hardware says (Parallels or QEMU = UTM);
# --display (UTM: the fixed mode, from display/mac-display.swift) is required on UTM.
# --vm-name-b64: the VM's name in its app, base64 (kept in /etc/omacvm/env): the
# gestures daemon says it, so the Mac tells two VMs of one app apart.
# Idempotent: run it again after an update of this repository.
# --only F,...: installs only these features' parts again (a repair); the
# system steps are skipped. --strict F,...|all: a part of these features that
# could not be set up fails the run (exit 1, after the other parts); without
# it, such a part is only logged.
# --graphics (OmacVM.app): what the VM's Graphics setting gives it on this Mac
# (the Mac decides Automatic); vulkan builds its Venus driver ahead of the
# start that gets Vulkan. Kept in /etc/omacvm/env.
# Needs, for the bridge, the token from the Mac in ~/.config/omacvm-bridge/token.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=""; KB="us"; TYPE=""; MODE=""; CLOCK_FMT=""; NAME64=""; ONLY=""; STRICT=""; SOFT=(); GRAPHICS=""
FEATURES=(); declare -A F=() NEEDS=() SET=()
while IFS=$'\t' read -r name def _ _ needs _; do
  [[ -z $name || $name == \#* ]] && continue
  FEATURES+=("$name"); NEEDS[$name]=$needs
  [[ $def == on ]] && F[$name]=on || F[$name]=off   # "notch", "laptop": the Mac decides (build.sh, omacvm)
done < "$R/features.tsv"
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --display) MODE=$2; shift 2 ;;
    --host) HOST_GIVEN=$2; shift 2 ;;
    --clock-format-b64) CLOCK_FMT=$(base64 -d <<<"$2"); shift 2 ;;
    --vm-name-b64) NAME64=$2; shift 2 ;;
    --feature) f=${2%%=*} v=${2#*=}
               # idle-lock was renamed no-idle-lock in 3.0.1, on and off the other way round.
               if [[ $f == idle-lock ]]; then f=no-idle-lock; case $v in on) v=off ;; off) v=on ;; esac; fi
               SET[$f]=$v; shift 2 ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --graphics) [[ $2 == opengl || $2 == vulkan ]] || { echo "guest/install.sh: --graphics opengl|vulkan" >&2; exit 2; }
                GRAPHICS=$2; shift 2 ;;
    --strict) STRICT=",$2,"; shift 2 ;;
    *) sed -n '5,7s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $U ]] && id "$U" >/dev/null || { echo "guest/install.sh: --user must be the desktop user" >&2; exit 2; }
log() { LAST_STEP=$*; printf '\033[1;32m==>\033[0m %s\n' "$*"; }
# A run that stops says where (apply shows it as what failed).
# One EXIT trap for everything that must run at the end (Fusion's DNS below).
LAST_STEP="the start"; REPORTED=""; FUSION_DNS=0; GBM_GUARD=0
on_exit() {
  local rc=$?
  # The desktop's graphics (GBM) must open after this run as they did before
  # (guest/gbm-guard puts back packages that broke them; a black screen
  # otherwise at the next start).
  if (( GBM_GUARD )) && ! "$R/guest/gbm-guard" end; then
    (( rc )) || { echo "guest/install.sh: failed during: the graphics check (GBM)" >&2; REPORTED=1; rc=1; }
  fi
  (( rc == 0 || rc == 2 )) || [[ -n $REPORTED ]] || echo "guest/install.sh: failed during: $LAST_STEP" >&2
  (( ! FUSION_DNS )) || "$R/fusion/guest/dns.sh" off || true
  exit "$rc"
}
trap on_exit EXIT
# want FEATURE: this run installs that feature's part (all of them, or --only).
want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }
system() { [[ -z $ONLY ]]; }   # the steps that are no feature's
# not_set_up FEATURE TEXT: a part that did not install; logged, and with
# --strict it fails the run at the end.
not_set_up() { log "$2: not set up (see above)"; SOFT+=("$1"); }
read -r layout variant <<<"$KB"
H=$(getent passwd "$U" | cut -d: -f6)
user_ctl() { systemctl --user -M "$U@" "$@"; }
# A command in the desktop user's session (Hyprland, Omarchy's environment).
in_session() {
  local run; run=/run/user/$(id -u "$U")
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="$run" WAYLAND_DISPLAY=wayland-1 \
    HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$run/hypr" 2>/dev/null | head -1)" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
# Updated bar widgets load in a new shell: restarted once at the end.
restart_shell_later() { install -d -o "$U" -g "$U" "$H/.local/state/omacvm"; touch "$H/.local/state/omacvm/restart-shell"; }
# What off means for the features with a part in the VM that talks to the Mac.
ROOT=""
source "$R/guest/off.sh"

# Earlier choices, then this run's.
ENV=/etc/omacvm/env
source "$R/guest/autologin.sh"
AUTOLOGIN_CONF=$OMACVM_AUTOLOGIN_CONF
# Set up before choices were kept, or by someone else (an Omarchy install, a
# migration): SDDM logs someone in.
[[ -n $(sddm_autologin_user) ]] && F[autologin]=on
[[ -x $H/.local/bin/notchcast ]] && F[omanotch]=on
[[ $NAME64 =~ ^[A-Za-z0-9+/=]*$ ]] || { echo "guest/install.sh: --vm-name-b64: not base64" >&2; exit 2; }
if [[ -r $ENV ]]; then
  [[ -n $NAME64 ]] || NAME64=$(sed -n 's/^OMACVM_VM_NAME_B64=//p' "$ENV" | tail -1)
  [[ -n $GRAPHICS ]] || GRAPHICS=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENV" | tail -1)
  # scroll-momentum was called glide in the experiment: keep an old VM's choice.
  v=$(sed -n "s/^OMACVM_FEATURE_glide=//p" "$ENV" | tail -1); [[ -n $v ]] && F[scroll-momentum]=$v
  # idle-lock before 3.0.1: off is no-idle-lock on.
  v=$(sed -n "s/^OMACVM_FEATURE_idle_lock=//p" "$ENV" | tail -1)
  case $v in on) F[no-idle-lock]=off ;; off) F[no-idle-lock]=on ;; esac
  for f in "${FEATURES[@]}"; do
    v=$(sed -n "s/^OMACVM_FEATURE_${f//-/_}=//p" "$ENV" | tail -1)
    [[ -n $v ]] && F[$f]=$v
  done
fi
for f in ${ONLY//,/ } ${STRICT//,/ }; do
  [[ $f == all || -n ${F[$f]+x} ]] || { echo "guest/install.sh: --only/--strict: unknown feature '$f'" >&2; exit 2; }
done
for f in "${!SET[@]}"; do
  [[ -n ${F[$f]+x} && ${SET[$f]} =~ ^(on|off)$ ]] || { echo "guest/install.sh: --feature $f=${SET[$f]}: unknown" >&2; exit 2; }
  F[$f]=${SET[$f]}
done
for f in "${FEATURES[@]}"; do
  n=${NEEDS[$f]}; [[ $n == - || -z $n ]] && continue
  [[ ${F[$n]} == on ]] || F[$f]=off
done

# Which VM, and where its Mac is: Parallels' Mac is 10.211.55.2 on its shared
# network; on UTM's shared network the Mac is the default gateway; on VMware
# Fusion's NAT network the gateway is .2 and the Mac is .1.
if [[ -z $TYPE ]]; then
  case $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) in
    Parallels*) TYPE=parallels ;;
    QEMU*) TYPE=utm ;;
    VMware*) TYPE=fusion ;;
    *) echo "guest/install.sh: unknown VM, pass --vm-type parallels|utm|fusion" >&2; exit 2 ;;
  esac
fi
case $TYPE in
  parallels) HOST=10.211.55.2 ;;
  app) HOST=10.0.2.2 ;;   # OmacVM.app: QEMU's user network always puts the Mac there
  utm) HOST=$(ip route show default | awk '{ print $3; exit }'); : "${HOST:=192.168.64.1}"
       [[ -n $MODE ]] || { echo "guest/install.sh: UTM needs --display WxH@Hz" >&2; exit 2; } ;;
  fusion) HOST=${HOST_GIVEN:-}   # from the Mac (apply.sh): the gateway's network may not be Fusion's
          [[ $HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.1$ ]] || { echo "guest/install.sh: VMware Fusion needs --host (the Mac's address on Fusion's network)" >&2; exit 2; }
          [[ -n $MODE ]] || { echo "guest/install.sh: VMware Fusion needs --display WxH@Hz" >&2; exit 2; } ;;
  *) echo "guest/install.sh: --vm-type parallels, utm, fusion or app" >&2; exit 2 ;;
esac
# Parallels gives the VM the Mac's battery itself.
[[ $TYPE == parallels ]] && F[battery]=off
# The fast network is OmacVM.app's (the other apps have vmnet themselves).
[[ $TYPE == app ]] || F[fast-network]=off
# Chromium's video through V4L2 needs OmacVM.app's VA-API decoding.
[[ $TYPE == app ]] || F[chromium-video]=off
[[ $TYPE == app ]] || F[vulkan]=off
# Fusion: the public DNS from fusion/guest/install.sh goes again also when a
# later step fails.
[[ $TYPE == fusion ]] && FUSION_DNS=1
{
  printf 'OMACVM_VM_TYPE=%s\nOMACVM_HOST=%s\nOMACVM_USER=%s\n' "$TYPE" "$HOST" "$U"
  [[ -z $NAME64 ]] || printf 'OMACVM_VM_NAME_B64=%s\n' "$NAME64"
  [[ $TYPE != app || -z $GRAPHICS ]] || printf 'OMACVM_GRAPHICS=%s\n' "$GRAPHICS"
  for f in "${FEATURES[@]}"; do printf 'OMACVM_FEATURE_%s=%s\n' "${f//-/_}" "${F[$f]}"; done
} | install -Dm644 /dev/stdin "$ENV"
log "$TYPE VM, the Mac is $HOST"
log "features: $(for f in "${FEATURES[@]}"; do printf '%s=%s ' "$f" "${F[$f]}"; done)"

# A VM from a prebuilt image of OmacVM 2.5 or 2.6: first boot left absolute
# links into the image's placeholder home (Omarchy's wallpaper: a black desktop).
OLD=$(sed -n 's/^OMACVM_PREBUILT_USER=//p' /var/lib/omacvm/prebuilt/image 2>/dev/null || true)
if system && [[ $OLD =~ ^[a-z_][a-z0-9_-]*$ && $OLD != "$U" && ! -e /home/$OLD ]]; then
  n=0
  while IFS= read -r -d '' l; do
    t=$(readlink "$l"); ln -sfn "$H${t#/home/$OLD}" "$l"; chown -h "$U:$U" "$l"; n=$((n + 1))
  done < <(find "$H" -xdev -type l \( -lname "/home/$OLD" -o -lname "/home/$OLD/*" \) -print0 2>/dev/null)
  if (( n )); then log "links from the prebuilt image: $n now point into $H (the wallpaper shows after the next login)"; fi
fi

if system; then
  log "system: SSH from the Mac, bootable snapshots, DNS fallback"
  # Omarchy's firewall denies everything inbound; the Mac (Parallels' shared
  # network) may still reach SSH.
  ufw allow from "${HOST%.*}.0/24" to any port 22 proto tcp comment "omacvm: ssh from the Mac" >/dev/null 2>&1 || true
  # OmacVM.app's fast network (vmnet): the Mac reaches SSH from 192.168.77.1
  # (only the Mac: other VMs on that network do not). For every app VM, since
  # the app's own button can turn the fast network on without an apply.
  if [[ $TYPE == app ]]; then
    ufw allow from 192.168.77.1 to any port 22 proto tcp comment "omacvm: ssh from the Mac (fast network)" >/dev/null 2>&1 || true
  else
    ufw delete allow from 192.168.77.1 to any port 22 proto tcp >/dev/null 2>&1 || true
  fi
else
  # A repair, or a feature switch (apply.sh): the rest stays as it is.
  log "only: $(tr , ' ' <<<"${ONLY:1:-1}")"
fi
# Network cards without a link: their routes are skipped at once. OmacVM.app
# moves a running VM between its two cards (fast network <-> QEMU's user
# network) by their links; the kernel kept sending on the card whose link
# went down until NetworkManager dropped its route, about 6 s without
# internet at each move (seen on the Mac mini). App VMs only.
if [[ $TYPE == app ]]; then
  printf '%s\n' "# OmacVM.app: skip the routes of a network card without a link (src/guest/install.sh)" \
    "net.ipv4.conf.all.ignore_routes_with_linkdown = 1" "net.ipv6.conf.all.ignore_routes_with_linkdown = 1" \
    > /etc/sysctl.d/90-omacvm-net.conf
  sysctl -q -p /etc/sysctl.d/90-omacvm-net.conf >/dev/null 2>&1 || true
elif [[ -e /etc/sysctl.d/90-omacvm-net.conf ]]; then
  rm -f /etc/sysctl.d/90-omacvm-net.conf
  sysctl -q -w net.ipv4.conf.all.ignore_routes_with_linkdown=0 net.ipv6.conf.all.ignore_routes_with_linkdown=0 >/dev/null 2>&1 || true
fi
# A VM switched off during pacman keeps pacman's lock, and every pacman below
# would fail. Wait for one that runs (omarchy update); a lock without pacman goes.
for ((i = 0; i < 120; i++)); do
  [[ -e /var/lib/pacman/db.lck ]] && pgrep -x pacman >/dev/null || break
  (( i )) || log "waiting for pacman (another install runs)"
  sleep 5
done
if [[ -e /var/lib/pacman/db.lck ]]; then
  pgrep -x pacman >/dev/null && { echo "guest/install.sh: pacman still runs after 10 minutes: try again when it is done" >&2; exit 1; }
  log "pacman's lock from an install that was cut off: removed"
  rm -f /var/lib/pacman/db.lck
fi
# Packages: only ones the VM lacks, never an update of one it has
# (guest/pkg-add says why). And the graphics still open at the end.
"$R/guest/gbm-guard" begin && GBM_GUARD=1
"$R/guest/pkg-add" jq || { echo "guest/install.sh: pacman could not install jq (see above)" >&2; exit 1; }
if system && command -v grub-mkconfig >/dev/null; then
  # Snapshots (snapper, set up by omarchy-mac) appear in the GRUB menu.
  "$R/guest/pkg-add" grub-btrfs inotify-tools
  # Read-only snapshots picked in GRUB boot with a temporary writable overlay
  # (Omarchy does this with Limine on x86; omarchy-mac uses GRUB).
  printf '%s\n' '[[ " ${HOOKS[*]} " == *" grub-btrfs-overlayfs "* ]] || HOOKS+=(grub-btrfs-overlayfs)' \
    > /etc/mkinitcpio.conf.d/zz-omacvm.conf
  systemctl enable --now grub-btrfsd >/dev/null 2>&1 || true
  # Arch Linux ARM's kernel under a name GRUB pairs with its initramfs.
  "$R/kernel/stock-kernel.sh"
fi
if system; then
  printf '[Resolve]\nFallbackDNS=1.1.1.1 9.9.9.9 2606:4700:4700::1111 2620:fe::fe\n' |
    install -Dm644 /dev/stdin /etc/systemd/resolved.conf.d/10-omacvm.conf
  systemctl try-restart systemd-resolved 2>/dev/null || true
fi
if ! want autologin; then
  :
elif [[ ${F[autologin]} == on ]]; then
  # The Mac is FileVault-encrypted and locked already; hyprlock still locks
  # the session after idle (unless no-idle-lock is on).
  install -Dm644 /dev/stdin "$AUTOLOGIN_CONF" <<EOF
[Autologin]
User=$U
Session=hyprland-uwsm
Relogin=false
EOF
else
  rm -f "$AUTOLOGIN_CONF"
  # Off means off: another file that logs someone in (an Omarchy install, a
  # migration) is kept beside, as NAME.omacvm-off, which SDDM does not read.
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    mv -f "$f" "$f.omacvm-off" && log "autologin: off ($f kept as $f.omacvm-off)"
  done < <(sddm_autologin_others)
  [[ -z $(sddm_autologin_user) ]] || log "autologin: SDDM still logs $(sddm_autologin_user) in (/etc/sddm.conf or /usr/lib/sddm/sddm.conf.d): remove [Autologin] there"
fi

# Omarchy's idle screensaver and lock: its own "Stay Awake" switch turns both
# off (the shell watches the file). The marker remembers that OmacVM set it, so
# turning the feature back on never undoes a Stay Awake the user chose.
STAY=$H/.local/state/omarchy/indicators/stay-awake
MARK=$H/.local/state/omacvm/stay-awake-by-omacvm
# The Mac's clock: --clock-format-b64 comes from clock/mac-clock.swift (apply.sh).
if ! want mac-clock; then
  :
elif [[ ${F[mac-clock]} == on ]]; then
  if [[ -n $CLOCK_FMT ]]; then log "clock"; "$R/clock/guest/clock.sh" "$U" on "$CLOCK_FMT"; fi
else
  "$R/clock/guest/clock.sh" "$U" off
fi

if ! want no-idle-lock; then
  :
elif [[ ${F[no-idle-lock]} == on ]]; then
  log "idle screensaver and lock: disabled (the Mac's lock protects the VM)"
  install -d -o "$U" -g "$U" "$(dirname "$STAY")" "$(dirname "$MARK")"
  sudo -u "$U" touch "$STAY" "$MARK"
elif [[ -f $MARK ]]; then
  rm -f "$STAY" "$MARK"
fi

# Sound, speakers and microphone, on every route: PipeWire's ALSA, PulseAudio
# and JACK parts (omarchy-mac installs them only on Apple hardware; the VM's
# card is Parallels', Intel HDA on UTM and OmacVM.app, HD Audio on Fusion).
# pipewire-jack replaces jack2.
if system && ! pacman -Q pipewire-alsa pipewire-pulse pipewire-jack rtkit >/dev/null 2>&1; then
  log "sound: PipeWire's ALSA, PulseAudio and JACK parts"
  pacman -Q jack2 >/dev/null 2>&1 && pacman -Rdd --noconfirm jack2 >/dev/null
  "$R/guest/pkg-add" pipewire-alsa pipewire-pulse pipewire-jack rtkit || true
  user_ctl restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
# PipeWire's sound threads get real-time priority through RTKit. RTKit's
# watchdog demotes them for good after the VM was stopped (sound/
# rtkit-no-canary.conf says why): run it without the watchdog. PipeWire
# asks again at its next start (the next login).
if system && ! cmp -s "$R/guest/sound/rtkit-no-canary.conf" /etc/systemd/system/rtkit-daemon.service.d/90-omacvm-no-canary.conf; then
  log "sound: PipeWire stays real-time after the VM was stopped"
  install -Dm644 "$R/guest/sound/rtkit-no-canary.conf" /etc/systemd/system/rtkit-daemon.service.d/90-omacvm-no-canary.conf
  systemctl daemon-reload || true
  systemctl try-restart rtkit-daemon.service 2>/dev/null || true
fi
system && case $TYPE in
  parallels)
    log "display";    "$R/display/guest/install.sh" "$U"
    log "clipboard";  "$R/clipboard/guest/install.sh" "$U" ;;
  utm)
    log "UTM";        "$R/utm/guest/install.sh" "$U" "$MODE" ;;
  app)
    log "OmacVM.app"; "$R/app/guest/install.sh" "$U" ;;
  fusion)
    log "VMware Fusion"; "$R/fusion/guest/install.sh" "$U" "$MODE" ;;
esac
# Chromium's video through V4L2: OmacVM.app VMs only (off on the other routes
# above). Its own step, so the control centre can repair it alone.
if want chromium-video && [[ $TYPE == app ]]; then
  if [[ ${F[chromium-video]} == on ]]; then
    log "Chromium video on the Mac's media engine"
    "$R/vdec/guest/install.sh" "$U" on || not_set_up chromium-video "Chromium video"
  else
    "$R/vdec/guest/install.sh" "$U" off || not_set_up chromium-video "Chromium video (off)"
  fi
fi
# Vulkan (Venus): OmacVM's Mesa for it, built once in the VM. Its own step,
# so the control centre can repair it alone.
if want vulkan && [[ $TYPE == app ]]; then
  if [[ ${F[vulkan]} == on ]]; then
    log "WebGPU and GPU compute (the first time: Mesa builds in the VM, a few minutes)"
    "$R/app/guest/venus/install.sh" --force || not_set_up vulkan "Vulkan (GL is as it was)"
  elif [[ -e /opt/omacvm-mesa ]]; then
    log "Vulkan: off"; "$R/app/guest/venus/install.sh" --remove || not_set_up vulkan "Vulkan (off)"
  fi
  # The driver check after each boot follows the switch (a switch runs only this step).
  "$R/app/guest/venus/timer.sh" || true
fi
# x86 apps: box64, built once in the VM as a pacman package. Every route.
if want x86-apps; then
  if [[ ${F[x86-apps]} == on ]]; then
    log "x86 apps (the first time: box64 builds in the VM, a few minutes)"
    "$R/x86/guest/install.sh" on || not_set_up x86-apps "x86 apps"
  else
    "$R/x86/guest/install.sh" off || not_set_up x86-apps "x86 apps (off)"
  fi
fi
if ! want battery; then
  :
elif [[ ${F[battery]} == on ]]; then
  log "the Mac's battery"
  "$R/battery/guest/install.sh" on || not_set_up battery "the Mac's battery"
else
  # Says "battery: off" when there was something to take off.
  "$R/battery/guest/install.sh" off || not_set_up battery "the Mac's battery (off)"
fi
if system; then
  log "memory";     "$R/memory/guest/install.sh"
  log "keyboard";   "$R/keyboard/guest/install.sh" "$U" "$layout" "${variant:-}"
fi
# Off means off on every route (off.sh): no service of the feature runs in the
# VM and nothing of it connects to the Mac.
if ! want gestures && ! want scroll-momentum; then
  :
elif [[ ${F[gestures]} == on ]]; then
  log "gestures";   "$R/gestures/guest/install.sh" "$U"
else
  gestures_off
fi
if ! want scroll-momentum; then
  :
elif [[ ${F[scroll-momentum]} == on ]]; then
  log "macOS-native scroll momentum (experimental)"; "$R/gestures/guest/glide.sh" "$U" on
elif [[ -f $H/.config/hypr/omacvm_glide.lua ]]; then
  log "scroll momentum: off"; "$R/gestures/guest/glide.sh" "$U" off
fi
if system; then log "workspaces"; "$R/workspaces/guest/install.sh" "$U"; fi
if ! want bridge; then
  :
elif [[ ${F[bridge]} == on ]]; then
  log "bridge";     "$R/bridge/guest/install.sh" "$U"
else
  bridge_off   # Omarchy's own Bluetooth, Wi-Fi and audio widgets come back
fi
# External display brightness: Omarchy's own DDC/CI path (ddcutil) goes through
# the Bridge to the external Mac display an output is on. Only our ddcutil is
# ever removed; Omarchy's cached "no DDC here" (60 s) goes with each change.
DDC=/usr/local/bin/ddcutil
if ! want external-brightness; then
  :
elif [[ ${F[external-brightness]} == on ]]; then
  log "external display brightness"
  cmp -s "$R/bridge/guest/omacvm-ddcutil" "$DDC" || install -m755 "$R/bridge/guest/omacvm-ddcutil" "$DDC"
  rm -rf "/run/user/$(id -u "$U")/omarchy-brightness-display-ddc"
elif grep -qs '^# omacvm-ddcutil' "$DDC"; then
  log "external display brightness: off"
  rm -f "$DDC" && rm -rf "/run/user/$(id -u "$U")/omarchy-brightness-display-ddc"
fi
# Touch ID for sudo, polkit and 1Password (ADR 0041): the keys come from omacvm apply.
if want touch-id; then
  if [[ ${F[touch-id]} == on ]]; then
    log "Touch ID (sudo, polkit, 1Password)"; "$R/bridge/guest/touchid.sh" on "$U" || not_set_up touch-id "Touch ID"
  elif [[ -e /usr/lib/omacvm/omacvm-touchid || -e /etc/omacvm/touchid-key ]]; then
    log "Touch ID: off"; "$R/bridge/guest/touchid.sh" off "$U"
  fi
fi
# The control centre (omacvm in Omarchy): on, or gone again.
if want control-centre; then
  if [[ ${F[control-centre]} == on ]]; then log "control centre (omacvm)"
  elif [[ -e /usr/local/bin/omacvm || -f /etc/systemd/system/omacvm-check.socket ]]; then log "control centre: off"; fi
  if [[ ${F[control-centre]} == on || -e /usr/local/bin/omacvm || -f /etc/systemd/system/omacvm-check.socket ]]; then
    "$R/control/guest/install.sh" "$U" "${F[control-centre]}" "$TYPE" || not_set_up control-centre "control centre"
  fi
fi
# The Mac's camera: Parallels passes it itself; elsewhere /dev/video42.
if want camera; then
  if [[ ${F[camera]} == on && $TYPE != parallels ]]; then log "camera (Mac Camera)"; fi
  "$R/camera/guest/install.sh" "$U" "$TYPE" "${F[camera]}" || not_set_up camera "camera"
fi
if ! want wallpaper; then
  :
elif [[ ${F[wallpaper]} == on ]]; then
  log "wallpaper";  "$R/wallpaper/guest/install.sh" "$U"
else
  wallpaper_off
fi
# Omanotch's VM side (omanotch/guest in this copy) builds and installs in the
# desktop session: omacvm-omanotch.service runs it at the next login, or right
# away when the session is running. A changed copy installs again.
# Earlier versions cloned Omanotch into the user's home; this copy is used now.
if want omanotch && [[ -d $H/.local/share/omanotch/.git ]]; then
  if [[ -z $(git -C "$H/.local/share/omanotch" status --porcelain 2>/dev/null) ]]; then
    rm -rf "$H/.local/share/omanotch"
  else
    echo "  ~/.local/share/omanotch has local changes and is no longer used: left in place" >&2
  fi
fi
# OmacVM.app too: its full screen sits below the notch like the other routes'
# (its own notch-strip mode is an opt-in; Omanotch then leaves the strip alone).
if ! want omanotch; then
  :
elif [[ ${F[omanotch]} == on ]]; then
  # An empty notchcast is a broken install (seen once): build it again; a repair always does.
  [[ -e $H/.local/bin/notchcast && ! -s $H/.local/bin/notchcast ]] && rm -f "$H/.local/bin/notchcast"
  [[ -n $ONLY ]] && rm -f "$H/.local/state/omacvm/omanotch"
  sum=$(cd "$R/omanotch/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
  stamp=$H/.local/state/omacvm/omanotch
  if [[ -x $H/.local/bin/notchcast && $(cat "$stamp" 2>/dev/null) != "$sum" ]]; then
    log "Omanotch: changed, installs again"
    rm -f "$H/.local/bin/notchcast"
  fi
  if [[ ! -x $H/.local/bin/notchcast ]]; then
    log "Omanotch (the bar beside the notch)"
    "$R/guest/pkg-add" base-devel lz4 wayland wayland-protocols git
    install -d -o "$U" -g "$U" "$H/.local/state/omacvm"
    echo "$sum" > "$stamp"; chown "$U:$U" "$stamp"
    install -m644 "$R/guest/omacvm-omanotch.service" /etc/systemd/user/
    systemctl --global enable omacvm-omanotch.service >/dev/null 2>&1
    if pgrep -u "$U" -x Hyprland >/dev/null; then
      user_ctl daemon-reload 2>/dev/null || true
      user_ctl start omacvm-omanotch.service 2>/dev/null || log "Omanotch: installs at the next login"
    else
      log "Omanotch: installs at the first login"
    fi
  fi
  # The Mac's address, so notchcast does not have to guess it (on VMware
  # Fusion the gateway is Fusion's NAT, not the Mac).
  install -d -o "$U" -g "$U" "$H/.config/systemd/user/notchcast.service.d"
  # OmacVM.app: its display sync already follows the window.
  { printf '[Service]\nEnvironment=NOTCHBAR_HOST=%s\n' "$HOST"
    [[ $TYPE == app ]] && printf 'Environment=NOTCHBAR_FOLLOW_MODE=0\n'; } > "$H/.config/systemd/user/notchcast.service.d/omacvm-host.conf"
  chown "$U:$U" "$H/.config/systemd/user/notchcast.service.d/omacvm-host.conf"
  user_ctl daemon-reload 2>/dev/null || true
  user_ctl try-restart notchcast.service 2>/dev/null || true
  # Notifications right under the strip, not a bar's height lower (see the script).
  install -Dm755 "$R/guest/omanotch-notifications.sh" /usr/local/lib/omacvm/omanotch-notifications.sh
  install -Dm644 /dev/stdin /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/share/omarchy/shell/plugins/notifications/Service.qml

[Action]
Description = OmacVM: Omarchy's notifications under Omanotch's strip
When = PostTransaction
Exec = /usr/local/lib/omacvm/omanotch-notifications.sh on
HOOK
  if [[ -n $(/usr/local/lib/omacvm/omanotch-notifications.sh on || true) ]]; then restart_shell_later; fi
else
  # Also an Omanotch queued for the next login, not built yet.
  omanotch_off
fi
if ! want thp-kernel; then
  :
elif [[ ${F[thp-kernel]} == on ]]; then
  if command -v grub-mkconfig >/dev/null; then
    log "memory-optimized kernel: a kernel build on $(nproc) CPUs (about 10 minutes with 16, over an hour with 4)"
    "$R/kernel/build-thp-kernel.sh" "$U" || not_set_up thp-kernel "memory-optimized kernel"
  else
    log "memory-optimized kernel skipped: this VM does not boot with GRUB"
  fi
elif [[ -f /boot/vmlinuz-linux ]] && command -v grub-mkconfig >/dev/null; then
  # Off: GRUB boots Arch Linux ARM's own kernel, by stock-kernel.sh's name
  # for it (with its initramfs).
  G=/etc/default/grub
  sed -i -e '/^GRUB_TOP_LEVEL="\/boot\/vmlinuz-linux-aarch64-thp"$/d' -e '/^GRUB_TOP_LEVEL="\/boot\/Image"$/d' $G
  grep -q '^GRUB_TOP_LEVEL=' $G || echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux"' >> $G
fi
# The memory-optimized kernel's package goes once the VM no longer runs it
# (this run, or the next one after a reboot).
if want thp-kernel && [[ ${F[thp-kernel]} != on ]] && pacman -Q linux-aarch64-thp >/dev/null 2>&1; then
  if [[ $(uname -r) == *thp* ]]; then
    log "memory-optimized kernel: off, Arch Linux ARM's own kernel from the next boot"
  else
    log "memory-optimized kernel: off, removed"
    pacman -Rn --noconfirm $(pacman -Qq linux-aarch64-thp linux-aarch64-thp-headers 2>/dev/null) >/dev/null
  fi
fi
# Updated bar widgets only load in a new shell: restart it once if any changed.
# Never while the session is locked: Omarchy's lock screen lives in the shell,
# and a restart leaves Hyprland's "lockscreen app died" screen behind. Locked:
# a background job restarts it right after the next unlock.
RS=$H/.local/state/omacvm/restart-shell
if [[ -f $RS ]]; then
  rm -f "$RS"
  sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" bash -c '
    source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
    omarchy-shell shell ping >/dev/null 2>&1 || exit 0
    if [[ $(omarchy-shell lock isLocked 2>/dev/null) != true ]]; then
      omarchy-restart-shell >/dev/null 2>&1
    else
      systemd-run --user --quiet --collect --unit=omacvm-restart-shell bash -c "
        source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
        while [[ \$(omarchy-shell lock isLocked 2>/dev/null) == true ]]; do sleep 5; done
        sleep 2; omarchy-restart-shell" 2>/dev/null || true
      echo "the Omarchy shell restarts after the next unlock (new bar widgets)"
    fi' || true
fi
# The initramfs and GRUB's menu: rebuilt only when what goes into them changed
# (several seconds on every apply and update otherwise). Kernel and hook
# updates rebuild the initramfs through pacman's own hook.
BOOT_STAMP=/var/lib/omacvm/boot-inputs
# A missing file or an empty folder's glob must not stop the install (pipefail).
digest() { { cat "$@" 2>/dev/null || true; } | sha256sum | cut -c1-16; }
init_conf=$(digest /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/* /etc/mkinitcpio.d/*)
init_in=$init_conf
for p in /etc/mkinitcpio.d/*.preset; do   # an image a preset builds is missing: rebuild
  [[ -f $p ]] || continue
  ( source "$p"; for n in "${PRESETS[@]}"; do i=${n}_image; [[ -z ${!i:-} || -f ${!i} ]] || exit 1; done ) ||
    init_in=missing
done
grub_old=$(sed -n 's/^grub //p' $BOOT_STAMP 2>/dev/null || true)
if [[ $(sed -n 's/^initramfs //p' $BOOT_STAMP 2>/dev/null || true) != "$init_in" ]]; then
  init_ok=; grub_old=
  if mkinitcpio -P >/dev/null 2>&1; then init_ok=$init_conf; fi
else
  init_ok=$init_in
fi
grub_digest() { echo "$(digest /etc/default/grub /etc/grub.d/*)-$(ls /boot | sha256sum | cut -c1-16)"; }   # + the kernels' names
grub_in=$(grub_digest)
[[ -f /boot/grub/grub.cfg ]] || grub_in=missing
grub_ok=$grub_in
if [[ $grub_old != "$grub_in" ]] && command -v grub-mkconfig >/dev/null; then
  if grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then grub_ok=$(grub_digest); else grub_ok=; fi
fi
printf 'initramfs %s\ngrub %s\n' "$init_ok" "$grub_ok" | install -Dm644 /dev/stdin $BOOT_STAMP
[[ $TYPE == fusion ]] && "$R/fusion/guest/dns.sh" off   # back to Fusion's DNS, which follows the Mac's
for f in ${SOFT[@]+"${SOFT[@]}"}; do
  if [[ $STRICT == ",all," || $STRICT == *",$f,"* ]]; then
    echo "guest/install.sh: $f was not set up (see above)" >&2
    REPORTED=1; exit 1
  fi
done
log "OmacVM guest side installed for $U (reboot to apply everything)"
