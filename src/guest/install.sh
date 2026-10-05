#!/bin/bash
# OmacVM, guest side: everything that makes Omarchy feel native in a VM on a
# Mac, in Parallels or UTM. Run as root inside the VM from a copy of this
# repository's src/ (apply.sh puts it in /usr/local/share/omacvm):
#   guest/install.sh --user NAME --keyboard "LAYOUT [VARIANT]" [--vm-type parallels|utm|fusion]
#                    [--display WxH@Hz] [--feature NAME=on|off]... [--clock-format-b64 FMT]
#                    [--vm-name-b64 NAME]   (or --vm-type app: OmacVM.app)
# Features: the list in ../features.tsv (bridge, wallpaper, gestures, scroll-momentum,
# omanotch, mac-clock, camera, idle-lock, autologin, thp-kernel, battery) with its defaults; a feature
# needing another one is off without it. Choices are kept in /etc/omacvm/env,
# so a later run without --feature keeps them.
# --vm-type defaults to what the hardware says (Parallels or QEMU = UTM);
# --display (UTM: the fixed mode, from display/mac-display.swift) is required on UTM.
# --vm-name-b64: the VM's name in its app, base64 (kept in /etc/omacvm/env): the
# gestures daemon says it, so the Mac tells two VMs of one app apart.
# Idempotent: run it again after an update of this repository.
# Needs, for the bridge, the token from the Mac in ~/.config/omacvm-bridge/token.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
U=""; KB="us"; TYPE=""; MODE=""; CLOCK_FMT=""; NAME64=""
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
    --feature) SET[${2%%=*}]=${2#*=}; shift 2 ;;
    *) sed -n '5,6s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $U ]] && id "$U" >/dev/null || { echo "guest/install.sh: --user must be the desktop user" >&2; exit 2; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
read -r layout variant <<<"$KB"
H=$(getent passwd "$U" | cut -d: -f6)
user_ctl() { systemctl --user -M "$U@" "$@"; }

# Earlier choices, then this run's.
ENV=/etc/omacvm/env
AUTOLOGIN_CONF=/etc/sddm.conf.d/20-omacvm-autologin.conf
# Set up before choices were kept:
[[ -f $AUTOLOGIN_CONF ]] && F[autologin]=on
[[ -x $H/.local/bin/notchcast ]] && F[omanotch]=on
[[ $NAME64 =~ ^[A-Za-z0-9+/=]*$ ]] || { echo "guest/install.sh: --vm-name-b64: not base64" >&2; exit 2; }
if [[ -r $ENV ]]; then
  [[ -n $NAME64 ]] || NAME64=$(sed -n 's/^OMACVM_VM_NAME_B64=//p' "$ENV" | tail -1)
  # scroll-momentum was called glide in the experiment: keep an old VM's choice.
  v=$(sed -n "s/^OMACVM_FEATURE_glide=//p" "$ENV" | tail -1); [[ -n $v ]] && F[scroll-momentum]=$v
  for f in "${FEATURES[@]}"; do
    v=$(sed -n "s/^OMACVM_FEATURE_${f//-/_}=//p" "$ENV" | tail -1)
    [[ -n $v ]] && F[$f]=$v
  done
fi
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
# Fusion: the public DNS from fusion/guest/install.sh goes again also when a
# later step fails.
if [[ $TYPE == fusion ]]; then trap '"$R/fusion/guest/dns.sh" off' EXIT; fi
{
  printf 'OMACVM_VM_TYPE=%s\nOMACVM_HOST=%s\nOMACVM_USER=%s\n' "$TYPE" "$HOST" "$U"
  [[ -z $NAME64 ]] || printf 'OMACVM_VM_NAME_B64=%s\n' "$NAME64"
  for f in "${FEATURES[@]}"; do printf 'OMACVM_FEATURE_%s=%s\n' "${f//-/_}" "${F[$f]}"; done
} | install -Dm644 /dev/stdin "$ENV"
log "$TYPE VM, the Mac is $HOST"
log "features: $(for f in "${FEATURES[@]}"; do printf '%s=%s ' "$f" "${F[$f]}"; done)"

# A VM from a prebuilt image of OmacVM 2.5 or 2.6: first boot left absolute
# links into the image's placeholder home (Omarchy's wallpaper: a black desktop).
OLD=$(sed -n 's/^OMACVM_PREBUILT_USER=//p' /var/lib/omacvm/prebuilt/image 2>/dev/null || true)
if [[ $OLD =~ ^[a-z_][a-z0-9_-]*$ && $OLD != "$U" && ! -e /home/$OLD ]]; then
  n=0
  while IFS= read -r -d '' l; do
    t=$(readlink "$l"); ln -sfn "$H${t#/home/$OLD}" "$l"; chown -h "$U:$U" "$l"; n=$((n + 1))
  done < <(find "$H" -xdev -type l \( -lname "/home/$OLD" -o -lname "/home/$OLD/*" \) -print0 2>/dev/null)
  if (( n )); then log "links from the prebuilt image: $n now point into $H (the wallpaper shows after the next login)"; fi
fi

log "system: SSH from the Mac, bootable snapshots, DNS fallback"
# Omarchy's firewall denies everything inbound; the Mac (Parallels' shared
# network) may still reach SSH.
ufw allow from "${HOST%.*}.0/24" to any port 22 proto tcp comment "omacvm: ssh from the Mac" >/dev/null 2>&1 || true
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
pacman -S --needed --noconfirm jq >/dev/null 2>&1 || { echo "guest/install.sh: pacman could not install jq (no network?)" >&2; exit 1; }
if command -v grub-mkconfig >/dev/null; then
  # Snapshots (snapper, set up by omarchy-mac) appear in the GRUB menu.
  pacman -S --needed --noconfirm grub-btrfs inotify-tools >/dev/null 2>&1
  # Read-only snapshots picked in GRUB boot with a temporary writable overlay
  # (Omarchy does this with Limine on x86; omarchy-mac uses GRUB).
  printf '%s\n' '[[ " ${HOOKS[*]} " == *" grub-btrfs-overlayfs "* ]] || HOOKS+=(grub-btrfs-overlayfs)' \
    > /etc/mkinitcpio.conf.d/zz-omacvm.conf
  systemctl enable --now grub-btrfsd >/dev/null 2>&1 || true
  # Arch Linux ARM's kernel under a name GRUB pairs with its initramfs.
  "$R/kernel/stock-kernel.sh"
fi
install -Dm644 /dev/stdin /etc/systemd/resolved.conf.d/10-omacvm.conf <<'EOF'
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9 2606:4700:4700::1111 2620:fe::fe
EOF
systemctl try-restart systemd-resolved 2>/dev/null || true
if [[ ${F[autologin]} == on ]]; then
  # The Mac is FileVault-encrypted and locked already; hyprlock still locks
  # the session after idle (unless idle-lock is off).
  install -Dm644 /dev/stdin "$AUTOLOGIN_CONF" <<EOF
[Autologin]
User=$U
Session=hyprland-uwsm
Relogin=false
EOF
else
  rm -f "$AUTOLOGIN_CONF"
fi

# Omarchy's idle screensaver and lock: its own "Stay Awake" switch turns both
# off (the shell watches the file). The marker remembers that OmacVM set it, so
# turning the feature back on never undoes a Stay Awake the user chose.
STAY=$H/.local/state/omarchy/indicators/stay-awake
MARK=$H/.local/state/omacvm/stay-awake-by-omacvm
# The Mac's clock: --clock-format-b64 comes from clock/mac-clock.swift (apply.sh).
if [[ ${F[mac-clock]} == on ]]; then
  if [[ -n $CLOCK_FMT ]]; then log "clock"; "$R/clock/guest/clock.sh" "$U" on "$CLOCK_FMT"; fi
else
  "$R/clock/guest/clock.sh" "$U" off
fi

if [[ ${F[idle-lock]} == off ]]; then
  log "idle screensaver and lock: off (the Mac's lock protects the VM)"
  install -d -o "$U" -g "$U" "$(dirname "$STAY")" "$(dirname "$MARK")"
  sudo -u "$U" touch "$STAY" "$MARK"
elif [[ -f $MARK ]]; then
  rm -f "$STAY" "$MARK"
fi

# Sound, speakers and microphone, on every route: PipeWire's ALSA, PulseAudio
# and JACK parts (omarchy-mac installs them only on Apple hardware; the VM's
# card is Parallels', Intel HDA on UTM and OmacVM.app, HD Audio on Fusion).
# pipewire-jack replaces jack2.
if ! pacman -Q pipewire-alsa pipewire-pulse pipewire-jack rtkit >/dev/null 2>&1; then
  log "sound: PipeWire's ALSA, PulseAudio and JACK parts"
  pacman -Q jack2 >/dev/null 2>&1 && pacman -Rdd --noconfirm jack2 >/dev/null
  pacman -S --needed --noconfirm pipewire-alsa pipewire-pulse pipewire-jack rtkit >/dev/null 2>&1 || true
  user_ctl restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
fi
case $TYPE in
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
if [[ ${F[battery]} == on ]]; then
  log "the Mac's battery"
  "$R/battery/guest/install.sh" on || log "the Mac's battery: not installed (see above)"
elif [[ -f /etc/systemd/system/omacvm-battery.service ]]; then
  log "the Mac's battery: off"
  "$R/battery/guest/install.sh" off || log "the Mac's battery: not removed (see above)"
fi
log "memory";     "$R/memory/guest/install.sh"
log "keyboard";   "$R/keyboard/guest/install.sh" "$U" "$layout" "${variant:-}"
# On UTM, VMware Fusion and OmacVM.app the gestures daemon also types Cmd
# shortcuts as Super, so it stays.
if [[ ${F[gestures]} == on || $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; then
  log "gestures";   "$R/gestures/guest/install.sh" "$U"
elif systemctl is-enabled -q omacvm-gestures 2>/dev/null; then
  log "gestures: off"; systemctl disable --now omacvm-gestures >/dev/null 2>&1 || true
fi
if [[ ${F[scroll-momentum]} == on ]]; then
  log "macOS-native scroll momentum (experimental)"; "$R/gestures/guest/glide.sh" "$U" on
elif [[ -f $H/.config/hypr/omacvm_glide.lua ]]; then
  log "scroll momentum: off"; "$R/gestures/guest/glide.sh" "$U" off
fi
log "workspaces"; "$R/workspaces/guest/install.sh" "$U"
if [[ ${F[bridge]} == on ]]; then
  log "bridge";     "$R/bridge/guest/install.sh" "$U"
elif [[ -x /usr/local/bin/omacvm-bridge ]]; then
  # Disabling the clones brings Omarchy's own Bluetooth, Wi-Fi and audio widgets back.
  log "bridge: off"
  user_ctl disable --now omacvm-bridge-osd.service omacvm-bridge-events.socket >/dev/null 2>&1 || true
  user_ctl stop omacvm-bridge-events.service >/dev/null 2>&1 || true
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" bash -c \
    'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
     for p in omacvm.bluetooth omacvm.wifi omacvm.audio omacvm.wifiqr omacvm.nightshift; do omarchy plugin disable "$p" >/dev/null 2>&1; done' || true
  # Omarchy's own night light indicator, as it was before the Bridge.
  NL=$H/.local/state/omacvm/nightlight-indicator C=$H/.config/omarchy/shell.json
  if [[ -f $NL && -f $C ]]; then
    tmp=$(mktemp "$C.XXXXXX")
    jq --argjson items "$(cat "$NL")" '(.bar.layout[]?[]? | select(.id == "omarchy.indicators")) |= (if $items == null then del(.items) else .items = $items end)' "$C" > "$tmp" &&
      chmod --reference="$C" "$tmp" && chown "$U:$U" "$tmp" && mv -f "$tmp" "$C"
    rm -f "$tmp" "$NL"
  fi
  rm -f /usr/local/bin/omarchy-toggle-nightlight /usr/local/bin/omarchy-network-qr /usr/local/bin/omarchy-network-password
fi
# The Mac's camera: Parallels passes it itself; elsewhere /dev/video42.
if [[ ${F[camera]} == on && $TYPE != parallels ]]; then log "camera (Mac Camera)"; fi
"$R/camera/guest/install.sh" "$U" "$TYPE" "${F[camera]}" || log "camera: not set up (see above)"
if [[ ${F[wallpaper]} == on ]]; then
  log "wallpaper";  "$R/wallpaper/guest/install.sh" "$U"
elif user_ctl is-enabled -q omacvm-wallpaper.path 2>/dev/null; then
  log "wallpaper: off"; user_ctl disable --now omacvm-wallpaper.path omacvm-wallpaper.service >/dev/null 2>&1 || true
fi
# Omanotch's VM side (omanotch/guest in this copy) builds and installs in the
# desktop session: omacvm-omanotch.service runs it at the next login, or right
# away when the session is running. A changed copy installs again.
in_session() {
  local run; run=/run/user/$(id -u "$U")
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="$run" WAYLAND_DISPLAY=wayland-1 \
    HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$run/hypr" 2>/dev/null | head -1)" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
# Earlier versions cloned Omanotch into the user's home; this copy is used now.
if [[ -d $H/.local/share/omanotch/.git ]]; then
  if [[ -z $(git -C "$H/.local/share/omanotch" status --porcelain 2>/dev/null) ]]; then
    rm -rf "$H/.local/share/omanotch"
  else
    echo "  ~/.local/share/omanotch has local changes and is no longer used: left in place" >&2
  fi
fi
# OmacVM.app too: its full screen sits below the notch like the other routes'
# (its own notch-strip mode is an opt-in; Omanotch then leaves the strip alone).
if [[ ${F[omanotch]} == on ]]; then
  # An empty notchcast is a broken install (seen once): build it again.
  [[ -e $H/.local/bin/notchcast && ! -s $H/.local/bin/notchcast ]] && rm -f "$H/.local/bin/notchcast"
  sum=$(cd "$R/omanotch/guest" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
  stamp=$H/.local/state/omacvm/omanotch
  if [[ -x $H/.local/bin/notchcast && $(cat "$stamp" 2>/dev/null) != "$sum" ]]; then
    log "Omanotch: changed, installs again"
    rm -f "$H/.local/bin/notchcast"
  fi
  if [[ ! -x $H/.local/bin/notchcast ]]; then
    log "Omanotch (the bar beside the notch)"
    pacman -S --needed --noconfirm base-devel lz4 wayland wayland-protocols git >/dev/null 2>&1
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
  if [[ -n $(/usr/local/lib/omacvm/omanotch-notifications.sh on || true) ]]; then
    install -d -o "$U" -g "$U" "$H/.local/state/omacvm"; touch "$H/.local/state/omacvm/restart-shell"
  fi
elif [[ -x $H/.local/bin/notchcast ]]; then
  log "Omanotch: off"
  systemctl --global disable omacvm-omanotch.service >/dev/null 2>&1 || true
  rm -f /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook
  [[ -n $("$R/guest/omanotch-notifications.sh" off || true) ]] && { install -d -o "$U" -g "$U" "$H/.local/state/omacvm"; touch "$H/.local/state/omacvm/restart-shell"; }
  in_session bash "$R/omanotch/guest/uninstall.sh" >/dev/null 2>&1 ||
    user_ctl disable --now notchcast.service >/dev/null 2>&1 || true
  rm -f "$H/.local/state/omacvm/omanotch"
fi
if [[ ${F[thp-kernel]} == on ]]; then
  if command -v grub-mkconfig >/dev/null; then
    log "memory-optimized kernel (about 10 minutes)"
    "$R/kernel/build-thp-kernel.sh" "$U" || log "memory-optimized kernel: not updated (see above)"
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
if [[ ${F[thp-kernel]} != on ]] && pacman -Q linux-aarch64-thp >/dev/null 2>&1; then
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
log "OmacVM guest side installed for $U (reboot to apply everything)"
