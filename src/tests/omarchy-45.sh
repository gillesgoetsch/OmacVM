#!/bin/bash
# Omarchy 4.5, test only (src/guest/omarchy-45.sh, branch omarchy-45, #506): the
# test switch, the repo files and the way back, the mirror fallback, status on
# 4.5 and later, the animations marker, and the initramfs drop-in
# (guest/mkinitcpio-omacvm.conf). No VM: pacman, getent and runuser replaced,
# the repo files in a scratch folder. The move itself needs a VM (the PR's matrix).
#   src/tests/omarchy-45.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
O=$R/src/guest/omarchy-45.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/bin; mkdir -p "$S"
# pacman -Q omarchy: the version in $T/version (none: not installed)
printf '#!/bin/sh\n[ "$1 $2" = "-Q omarchy" ] && [ -s "%s/version" ] && { echo "omarchy $(cat "%s/version")"; exit 0; }\nexit 1\n' "$T" "$T" > "$S/pacman"
printf '#!/bin/sh\necho "$2:x:%s:%s::%s/home:/bin/bash"\n' "$(id -u)" "$(id -g)" "$T" > "$S/getent"
printf '#!/bin/sh\nshift 2; [ "$1" = -- ] && shift\nexec "$@"\n' > "$S/runuser"   # runuser -u USER -- CMD
chmod 755 "$S"/*
C=$T/pacman.conf M=$T/mirrorlist
o() { PATH="$S:$PATH" OMACVM_TEST_OMARCHY=4.5 OMACVM_PACMAN_CONF=$C OMACVM_PACMAN_MIRRORS=$M OMARCHY_PATH=$T/omarchy "$O" "$@"; }

# ---------- a command, and off without the switch ----------
expect "omarchy-45.sh can be run (mode 755: the guest tree's copy is run as is)" yes "$([[ -x $O ]] && echo yes || echo no)"
expect "the mode in git" 100755 "$(git -C "$R" ls-files -s src/guest/omarchy-45.sh | cut -d' ' -f1)"
OMACVM_TEST_OMARCHY= "$O" status >/dev/null 2>&1
expect "without OMACVM_TEST_OMARCHY=4.5: refused (exit 3)" 3 "$?"

# ---------- repos, back ----------
# A 4.0 VM's files: omarchy-mac's lane, base-install.sh's mirrors (HTTPS ones and the HTTP default).
printf '[options]\nIgnorePkg = mine\n\n[omarchy-aarch64]\nServer = https://example.invalid/$arch\n' > "$C"
printf 'Server = https://de3.mirror.archlinuxarm.org/$arch/$repo\nServer = https://nl.mirror.archlinuxarm.org/$arch/$repo\nServer = http://mirror.archlinuxarm.org/$arch/$repo\n' > "$M"
cp "$C" "$T/c40"; cp "$M" "$T/m40"
o repos rc >/dev/null
expect "repos: 4.5's [omarchy] for the channel" "Server = https://pkgs.omarchy.org/rc/\$arch" "$(awk '/^\[omarchy\]/ { getline; print }' "$C")"
expect "repos: no omarchy-mac lane" 0 "$(grep -c 'omarchy-aarch64' "$C")"
expect "repos: Omarchy's mirror first, then the VM's HTTPS Arch Linux ARM mirrors (not the HTTP one)" \
  "https://arm-rc-mirror.omarchy.org/\$arch/\$repo https://de3.mirror.archlinuxarm.org/\$arch/\$repo https://nl.mirror.archlinuxarm.org/\$arch/\$repo" \
  "$(sed -n 's/^Server = //p' "$M" | tr '\n' ' ' | sed 's/ $//')"
expect "repos: the 4.0 files kept" "same same" "$(cmp -s "$C.omacvm-40" "$T/c40" && echo same) $(cmp -s "$M.omacvm-40" "$T/m40" && echo same)"
o repos edge >/dev/null
expect "repos again (edge): edge's mirror, the 4.0 copies not overwritten" "https://arm-mirror.omarchy.org/\$arch/\$repo same" \
  "$(sed -n '1,/^Server/s/^Server = //p' "$M") $(cmp -s "$C.omacvm-40" "$T/c40" && echo same)"
o repos nightly >/dev/null 2>&1
expect "repos: an unknown channel is refused" 1 "$?"
o back >/dev/null
expect "back: the 4.0 files again" "same same" "$(cmp -s "$C" "$T/c40" && echo same) $(cmp -s "$M" "$T/m40" && echo same)"
# A 4.0 list with Omarchy's mirror only: two of base-install.sh's HTTPS mirrors.
rm -f "$C.omacvm-40" "$M.omacvm-40"; printf 'Server = https://arm-mirror.omarchy.org/$arch/$repo\n' > "$M"
o repos >/dev/null
expect "repos (rc by default) without Arch Linux ARM mirrors in the old list: two of base-install.sh's" \
  "https://arm-rc-mirror.omarchy.org/\$arch/\$repo https://de3.mirror.archlinuxarm.org/\$arch/\$repo https://fl.us.mirror.archlinuxarm.org/\$arch/\$repo" \
  "$(sed -n 's/^Server = //p' "$M" | tr '\n' ' ' | sed 's/ $//')"

# ---------- status: 4.5 and every later one ----------
st() { echo "$1" > "$T/version"; o status >/dev/null 2>&1 && echo 0 || echo 1; }
expect "status: 4.0.3rc4-1 is not 4.5" 1 "$(st 4.0.3rc4-1)"
expect "status: 4.4.9-1 is not 4.5" 1 "$(st 4.4.9-1)"
expect "status: 4.5.0rc1-1" 0 "$(st 4.5.0rc1-1)"
expect "status: 4.9.1-1" 0 "$(st 4.9.1-1)"
expect "status: 4.10.0-1 (two digits)" 0 "$(st 4.10.0-1)"
expect "status: 5.0.0-1" 0 "$(st 5.0.0-1)"
: > "$T/version"
expect "status: no omarchy package" "omarchy none, repos rc" "$(o status 2>/dev/null)"

# ---------- animations: Omarchy's VM flags go once ----------
TG=$T/home/.local/state/omarchy/toggles/hypr; OT=$T/omarchy/default/hypr/toggles
mkdir -p "$TG" "$OT"
for f in no-animations.lua window-opaque.lua; do echo "-- $f" > "$OT/$f"; cp "$OT/$f" "$TG/$f"; done
echo '-- changed' >> "$TG/window-opaque.lua"
o animations "$(id -un)" >/dev/null
expect "animations: Omarchy's own flag goes, a changed one stays" "no yes" \
  "$([[ -e $TG/no-animations.lua ]] && echo yes || echo no) $([[ -e $TG/window-opaque.lua ]] && echo yes || echo no)"
expect "animations: the marker" yes "$([[ -e $T/home/.local/state/omacvm/animations-on ]] && echo yes || echo no)"
cp "$OT/no-animations.lua" "$TG/"; o animations "$(id -un)" >/dev/null
expect "animations: once only (turned off later in Omarchy's menu: stays off)" yes "$([[ -e $TG/no-animations.lua ]] && echo yes || echo no)"

# ---------- the initramfs drop-in ----------
# Omarchy 4.5's baseline ends in Limine's btrfs-overlayfs; a GRUB VM does not have its hook.
D=$R/src/guest/mkinitcpio-omacvm.conf
hooks() { bash -c 'HOOKS=('"$1"'); for i in 1 2; do source "$0"; done; echo "${HOOKS[*]}"' "$D"; }
if [[ ! -e /usr/lib/initcpio/install/btrfs-overlayfs ]]; then
  expect "drop-in: 4.5's baseline without Limine's hook, grub-btrfs-overlayfs once (read twice)" \
    "base udev autodetect microcode modconf kms keyboard keymap block filesystems fsck grub-btrfs-overlayfs" \
    "$(hooks 'base udev autodetect microcode modconf kms keyboard keymap block filesystems fsck btrfs-overlayfs')"
else
  echo "skip the drop-in's Limine case (this machine has btrfs-overlayfs's hook)"
fi
expect "drop-in: 4.0's HOOKS get grub-btrfs-overlayfs" "base udev block filesystems fsck grub-btrfs-overlayfs" \
  "$(hooks 'base udev block filesystems fsck')"
expect "guest/install.sh writes the drop-in from the file" 1 \
  "$(grep -c 'install -Dm644 "$R/guest/mkinitcpio-omacvm.conf" /etc/mkinitcpio.conf.d/zz-omacvm.conf' "$R/src/guest/install.sh")"
expect "the move writes it before its transaction" before \
  "$(awk '/^cmd_move\(\)/ { s = 1 } s && /install .*mkinitcpio-omacvm.conf/ { d = NR } s && /pacman -Syu/ { p = NR }
     END { print (d && p && d < p) ? "before" : "not before" }' "$O")"
exit $fail
