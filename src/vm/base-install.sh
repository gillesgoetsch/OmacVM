#!/bin/bash
# Install Arch Linux ARM onto the VM's NVMe disk. Runs as root in the live
# installer (build.sh copies it there with /root/omacvm.env):
#   OMA_USER OMA_FULLNAME OMA_HASH OMA_TZ OMA_LANG OMA_XKB_LAYOUT OMA_XKB_VARIANT OMA_HOSTNAME
# plus /root/omacvm.pub (SSH key for root, used by build.sh).
#
# Layout: GPT, 2 GiB EFI (/boot) + btrfs with @, @home, @log (omarchy-mac adds
# @factory and snapper); zstd:1, noatime, async discard. GRUB, because
# omarchy-mac's snapshot restore/reset tooling expects it.
set -euo pipefail
source /root/omacvm.env
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# retry CMD...: a download step again after a failure (a flaky mirror, network
# or proxy: "Operation too slow"), 3 tries.
retry() {
  local i
  for i in 1 2 3; do
    "$@" && return 0
    if (( i < 3 )); then echo "failed (try $i of 3), again in $((i * 10)) s: $*" >&2; sleep $((i * 10)); fi
  done
  return 1
}

# The Mac's proxy (#122): create-vm.sh or build.sh writes it when the Mac has
# one. This script's downloads go through it, and the new system keeps it
# (environment.d for the desktop, profile.d for shells, sudo passes it on).
PROXY_ENV=/root/omacvm-proxy.env
PROXY_VARS="http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"
if [[ -s $PROXY_ENV ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROXY_ENV"
  set +a
  echo "proxy: $(sed -nE 's|//[^/@]*@|//***@|; s/^(http|https|all)_proxy=//p' "$PROXY_ENV" | tr '\n' ' ')"
fi

D=$(lsblk -dnpo NAME,TRAN | awk '$2 == "nvme" { print $1; exit }')
[[ -b ${D:-} ]] || { echo "base-install: no NVMe disk found" >&2; exit 1; }
P=${D}p

log "clock"
# Package signatures and HTTPS need a right clock. The live system's comes from
# the VM's RTC; check it against the mirror's Date header (plain HTTP, so a
# wrong clock can't fail the TLS check) and set it when it is off by > 5 min.
timedatectl set-ntp true 2>/dev/null || true
web=$(curl -sI --max-time 6 http://mirror.archlinuxarm.org/aarch64/core/core.db 2>/dev/null |
  tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1 || true)
if [[ -n $web ]] && ref=$(date -u -d "$web" +%s 2>/dev/null); then
  off=$(( $(date -u +%s) - ref ))
  if (( off > 300 || off < -300 )); then
    echo "the clock is off by ${off}s ($(date -u '+%F %T') UTC, the mirror says $web): setting it"
    date -u -s "@$ref" >/dev/null || echo "WARNING: could not set the clock"
  fi
else
  echo "WARNING: no time from the mirror; keeping the clock as it is"
fi
# This script is from 2026: an earlier year means the clock is wrong.
(( $(date -u +%Y) >= 2026 )) ||
  echo "WARNING: the clock says $(date -u '+%F %T') UTC; package signature checks will likely fail"
echo "clock: $(date -u '+%F %T') UTC"

log "fastest Arch Linux ARM mirrors from here"
# The geo-DNS default can send you across the world and time out; rank a few
# mirrors by how fast they serve the core database, keep the default last.
ranked=$(for m in de3 de4 dk hu nl fl.us ca.us nj.us il.us tx.us sg tw au br za; do
  if t=$(curl -fo /dev/null -s -w '%{time_total}' --max-time 6 "https://$m.mirror.archlinuxarm.org/aarch64/core/core.db"); then
    printf '%s %s\n' "$t" "$m"
  fi
done | sort -n | head -4 | awk '{ print $2 }' || true)
{
  for m in $ranked; do echo "Server = https://$m.mirror.archlinuxarm.org/\$arch/\$repo"; done
  echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo'
} > /etc/pacman.d/mirrorlist
cat /etc/pacman.d/mirrorlist

log "package signing keys"
# The try-omarchy live system ships a set-up keyring. Create it if an image
# ever comes without one, then take the current archlinuxarm-keyring (a no-op
# while it is up to date). pacstrap copies this keyring into the new system.
G=/etc/pacman.d/gnupg
if [[ ! -s $G/trustdb.gpg ]] || [[ ! -s $G/pubring.gpg && ! -s $G/pubring.kbx ]]; then
  echo "no pacman keyring in the live system: creating it"
  pacman-key --init || die "pacman-key --init failed"
  pacman-key --populate archlinuxarm || die "pacman-key --populate archlinuxarm failed"
fi
retry pacman -Sy --noconfirm --needed archlinuxarm-keyring ||
  die "could not update archlinuxarm-keyring (mirror, network or clock; see the lines above)"

log "tools for the install"
retry pacman -S --noconfirm --needed arch-install-scripts dosfstools btrfs-progs gptfdisk >/dev/null ||
  die "could not install the tools for the install (see the lines above)"

log "partitions on $D"
sgdisk --zap-all "$D" >/dev/null
sgdisk -n1:1MiB:+2GiB -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:omarchy "$D" >/dev/null
partprobe "$D"; sleep 1
mkfs.fat -F32 -n OMARCHYEFI "${P}1" >/dev/null
mkfs.btrfs -f -L omarchy "${P}2" >/dev/null
mount "${P}2" /mnt
for s in @ @home @log; do btrfs subvolume create "/mnt/$s" >/dev/null; done
umount /mnt
O=noatime,compress=zstd:1,space_cache=v2,discard=async
mount -o "$O,subvol=@" "${P}2" /mnt
mkdir -p /mnt/home /mnt/var/log /mnt/boot
mount -o "$O,subvol=@home" "${P}2" /mnt/home
mount -o "$O,subvol=@log" "${P}2" /mnt/var/log
mount -o umask=0077 "${P}1" /mnt/boot

log "pacstrap"
cat > /root/pacman.alarm.conf <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
CheckSpace
ParallelDownloads = 8
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[alarm]
Include = /etc/pacman.d/mirrorlist
[aur]
Include = /etc/pacman.d/mirrorlist
EOF
# pacstrap's full output goes to $PACLOG (and later into the new system's
# /var/log); on screen only its tail. pacman's "failed to commit transaction
# (unexpected error)" says nothing: the cause is in the lines above it, so on a
# failure those are shown. One retry after a fresh database sync covers a
# flaky mirror or network.
PACLOG=/root/pacstrap.log
PKGS=(base base-devel linux-aarch64 linux-aarch64-headers archlinuxarm-keyring
  btrfs-progs dosfstools grub efibootmgr openssh sudo git networkmanager nano vim man-db)
# OmacVM.app sends progress.sh first: then its progress lines go to the Mac too.
declare -F pac_progress >/dev/null || pac_progress() { cat > "$1"; }
declare -F cache_watch >/dev/null || cache_watch() { :; }
pacstrap_run() {   # try number; output to $PACLOG.try, appended to $PACLOG
  local rc
  set +e
  # sed -u passes whole lines only: pacman writes in blocks, and cache_watch's
  # lines must not land in the middle of one (seen in a real build).
  ( cache_watch /mnt/var/cache/pacman/pkg & w=$!
    pacstrap -C /root/pacman.alarm.conf /mnt "${PKGS[@]}" 2>&1 | sed -u ''; rc=${PIPESTATUS[0]}
    kill "$w" 2>/dev/null; exit "$rc" ) | pac_progress "$PACLOG.try"
  rc=${PIPESTATUS[0]}
  set -e
  { echo "---- pacstrap, try $1, exit $rc ----"; cat "$PACLOG.try"; } >> "$PACLOG"
  return "$rc"
}
pacstrap_errors() {
  local f=$PACLOG.try n
  echo "---- pacstrap errors (full output: $PACLOG in the live system) ----"
  grep '^error:' "$f" | awk '!seen[$0]++' | head -20 || true
  n=$(grep -n 'failed to commit transaction' "$f" | tail -1 | cut -d: -f1 || true)
  if [[ -n $n ]]; then
    # pacman prints the cause before that line (signatures, extraction) or
    # after it (conflicting files): show 20 lines before and 10 after.
    echo "---- around \"failed to commit transaction\" ----"
    sed -n "$(( n > 20 ? n - 20 : 1 )),$(( n + 10 ))p" "$f"
  elif ! grep -q '^error:' "$f"; then
    tail -20 "$f"
  fi
  echo "----"
}
: > "$PACLOG"
if ! pacstrap_run 1; then
  pacstrap_errors
  log "pacstrap again, after a fresh package database sync"
  { echo "---- pacman -Syy ----"; pacman --config /root/pacman.alarm.conf -r /mnt -Syy --noconfirm 2>&1; } >> "$PACLOG" ||
    echo "WARNING: the database sync failed too (see $PACLOG)"
  if ! pacstrap_run 2; then
    pacstrap_errors
    die "pacstrap failed twice; the cause is in the error lines above"
  fi
fi
tail -3 "$PACLOG.try"
cp /root/pacman.alarm.conf /mnt/etc/pacman.conf
sed -i 's/^\[options\]/[options]\nColor\nVerbosePkgLists/' /mnt/etc/pacman.conf
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
genfstab -U /mnt > /mnt/etc/fstab
install -m644 "$PACLOG" /mnt/var/log/omacvm-pacstrap.log
if [[ -s $PROXY_ENV ]]; then
  log "the Mac's proxy, kept in the new system"
  install -Dm644 "$PROXY_ENV" /mnt/etc/environment.d/90-omacvm-proxy.conf
  { echo "# The Mac's proxy when this VM was built (OmacVM). Delete this file,"
    echo "# /etc/environment.d/90-omacvm-proxy.conf and /etc/sudoers.d/05-omacvm-proxy to stop using it."
    sed -n "s/^\([A-Za-z_]*\)=\(.*\)$/export \1='\2'/p" "$PROXY_ENV"; } > /mnt/etc/profile.d/omacvm-proxy.sh
  printf 'Defaults env_keep += "%s"\n' "$PROXY_VARS" > /mnt/etc/sudoers.d/05-omacvm-proxy
  chmod 440 /mnt/etc/sudoers.d/05-omacvm-proxy
fi

log "base system: $OMA_TZ, $OMA_LANG, keyboard $OMA_XKB_LAYOUT${OMA_XKB_VARIANT:+ ($OMA_XKB_VARIANT)}, user $OMA_USER"
install -m600 /root/omacvm.env /mnt/root/omacvm.env
install -m600 /root/omacvm.pub /mnt/root/omacvm.pub
cat > /mnt/root/setup-base.sh <<'EOF'
set -euo pipefail
source /root/omacvm.env
ln -sf "/usr/share/zoneinfo/$OMA_TZ" /etc/localtime
hwclock --systohc 2>/dev/null || true
grep -q "^${OMA_LANG} " /usr/share/i18n/SUPPORTED || OMA_LANG=en_US.UTF-8
sed -i "s/^#en_US.UTF-8/en_US.UTF-8/; s/^#${OMA_LANG}/${OMA_LANG}/" /etc/locale.gen
locale-gen >/dev/null
echo "LANG=$OMA_LANG" > /etc/locale.conf
# Console keymap: systemd's own X11 -> console table.
keymap=$(awk -v l="$OMA_XKB_LAYOUT" -v v="${OMA_XKB_VARIANT:-}" \
  '!/^#/ && $2 == l && ($4 == v || (v == "" && $4 == "-")) { print $1; exit }' /usr/share/systemd/kbd-model-map)
echo "KEYMAP=${keymap:-us}" > /etc/vconsole.conf
echo "$OMA_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$OMA_HOSTNAME" "$OMA_HOSTNAME" > /etc/hosts
pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
useradd -m -G wheel -s /bin/bash -c "$OMA_FULLNAME" "$OMA_USER"
usermod -p "$OMA_HASH" "$OMA_USER"
passwd -l root >/dev/null
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel; chmod 440 /etc/sudoers.d/10-wheel
install -d -m700 /root/.ssh; install -m600 /root/omacvm.pub /root/.ssh/authorized_keys
cat > /etc/ssh/sshd_config.d/10-omacvm.conf <<EOT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOT
systemctl enable NetworkManager sshd systemd-timesyncd fstrim.timer >/dev/null 2>&1
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/; s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet mitigations=off nowatchdog"/; s/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
grub-install --target=arm64-efi --efi-directory=/boot --bootloader-id=GRUB 2>&1 | tail -1
grub-install --target=arm64-efi --efi-directory=/boot --removable 2>&1 | tail -1
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -1
rm /root/omacvm.pub
EOF
arch-chroot /mnt bash /root/setup-base.sh
rm -f /mnt/root/setup-base.sh
sync; umount -R /mnt
log "base system installed on $D"
