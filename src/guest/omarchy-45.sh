#!/bin/bash
# omarchy-45.sh (root, in the VM): Omarchy 4.5 for OmacVM VMs. TEST ONLY:
# OmacVM stays on Omarchy 4.0 (omarchy-mac) until Omarchy 4.5 is released and
# the maintainer turns this route on. Every command refuses to run unless
# OMACVM_TEST_OMARCHY=4.5 is set; nothing in OmacVM sets it.
#
# Omarchy 4.5 merges Omarchy Mac into Omarchy: an ARM VM (platform "aarch64":
# no Apple device tree) runs upstream's own packages, [omarchy] =
# pkgs.omarchy.org/<channel>/aarch64, on Omarchy's mirror of Arch Linux ARM
# (arm-<channel>-mirror.omarchy.org), with no omarchy-mac lane. The repo files
# below are upstream's aarch64 templates (omacom/omarchy default/pacman/aarch64,
# MIT), written out here because the 4.0 VM does not have them yet.
#
#   omarchy-45.sh repos [CHANNEL]   pacman.conf + mirrorlist as 4.5's (the old
#                                   ones kept as *.omacvm-40, once)
#   omarchy-45.sh keyring           Omarchy's package key, trusted (fresh installs)
#   omarchy-45.sh move [CHANNEL]    a 4.0.x VM (omarchy-mac) to 4.5: repos, then
#                                   omarchy + omarchy-settings with the whole
#                                   system (pacman -Syuu), then omarchy update
#                                   as the user (guest/system-update)
#   omarchy-45.sh back              the 4.0 repo files again (before the packages)
#   omarchy-45.sh animations USER   once, after a fresh 4.5 install: animations
#                                   and see-through windows on again (4.5 turns
#                                   them off in any VM; OmacVM's VMs have the
#                                   Mac's GPU)
#   omarchy-45.sh status            omarchy's version, the channel, the repos;
#                                   exit 0 = on 4.5 or later
# CHANNEL: rc (default while 4.5 is a release candidate), stable, edge.
# The route for an existing VM (Update VM, once wired): omacvm apply with this
# version (its initramfs drop-in), move, then omacvm apply again (it finds
# 4.5's files and steps aside where 4.5 does it itself: the workspaces).
set -uo pipefail
G=$(cd "$(dirname "$0")" && pwd)
# The helpers are in OmacVM's guest tree; a fresh install's copy of this
# script sits alone in /usr/local/lib/omacvm.
S=$G; [[ -x $S/system-update ]] || S=${OMACVM_GUEST_DIR:-/usr/local/share/omacvm/guest}
KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571   # Omarchy <pkgs@omarchy.org>
CONF=${OMACVM_PACMAN_CONF:-/etc/pacman.conf}
MIRRORS=${OMACVM_PACMAN_MIRRORS:-/etc/pacman.d/mirrorlist}
say() { echo "OmacVM: $*"; }
die() { echo "omarchy-45: $*" >&2; exit 1; }

[[ ${OMACVM_TEST_OMARCHY:-} == 4.5 ]] || { echo "omarchy-45: Omarchy 4.5 is not supported yet (test switch off)" >&2; exit 3; }

channel() {
  case ${1:-rc} in stable|rc|edge) echo "${1:-rc}" ;; *) die "unknown channel: $1" ;; esac
}

render_conf() {   # CHANNEL: upstream's default/pacman/aarch64/pacman-CHANNEL.conf
  cat <<EOF
# See the pacman.conf(5) manpage for option and repository directives
# Arch Linux ARM provides the aarch64 repositories used below.
# Written by OmacVM (guest/omarchy-45.sh) from Omarchy 4.5's aarch64 template.

[options]
Color
ILoveCandy
VerbosePkgLists
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
DownloadUser = alpm

SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# Omarchy comes first, so a package it also publishes is installed from Omarchy.
[omarchy]
Server = https://pkgs.omarchy.org/$1/\$arch

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist
EOF
}

render_mirrors() {   # CHANNEL: upstream's default/pacman/aarch64/mirrorlist-CHANNEL
  local host=arm-$1-mirror.omarchy.org
  [[ $1 == edge ]] && host=arm-mirror.omarchy.org
  printf '%s\n%s\nServer = https://%s/$arch/$repo\n' \
    "# Omarchy's mirror of Arch Linux ARM, over HTTPS since the repository databases" \
    "# are unsigned. It keeps Arch Linux ARM's \$arch/\$repo layout." "$host"
  # Then the VM's own HTTPS mirrors of Arch Linux ARM (base-install.sh picked
  # them), for a file Omarchy's mirror lists but does not have yet (2026-10-24:
  # luajit 404 on arm-rc-mirror while its database already named it).
  # Packages are signed; the database still comes from the first server.
  # A list without any (Omarchy's mirror only): two of base-install.sh's.
  echo "# OmacVM: Arch Linux ARM's own mirrors when Omarchy's lacks a file"
  grep -s '^Server = https://[a-z0-9.-]*archlinuxarm\.org/' "$MIRRORS.omacvm-40" ||
    printf 'Server = https://%s.mirror.archlinuxarm.org/$arch/$repo\n' de3 fl.us
}

cmd_repos() {
  local c; c=$(channel "${1:-}") || exit 1
  [[ -e $CONF.omacvm-40 ]] || cp -p "$CONF" "$CONF.omacvm-40" || die "could not keep $CONF"
  [[ -e $MIRRORS.omacvm-40 ]] || cp -p "$MIRRORS" "$MIRRORS.omacvm-40" || die "could not keep $MIRRORS"
  render_conf "$c" > "$CONF.new" && render_mirrors "$c" > "$MIRRORS.new" &&
    mv -f "$CONF.new" "$CONF" && mv -f "$MIRRORS.new" "$MIRRORS" || die "could not write the repo files"
  say "repos: Omarchy 4.5 aarch64, channel $c (the old pacman.conf is $CONF.omacvm-40: repos or IgnorePkg of your own are not carried over)"
}

cmd_keyring() {
  pacman-key --list-keys "$KEY" >/dev/null 2>&1 ||
    pacman-key --recv-keys "$KEY" --keyserver hkps://keys.openpgp.org >/dev/null 2>&1 || die "could not fetch Omarchy's package key"
  pacman-key --lsign-key "$KEY" >/dev/null 2>&1 || die "could not trust Omarchy's package key"
}

cmd_back() {
  [[ -e $CONF.omacvm-40 && -e $MIRRORS.omacvm-40 ]] || die "no 4.0 repo files kept"
  cp -p "$CONF.omacvm-40" "$CONF" && cp -p "$MIRRORS.omacvm-40" "$MIRRORS" || die "could not put the 4.0 repo files back"
  say "repos: back to the 4.0 ones"
}

# Omarchy's install (install/user/hardware/vm-no-animations.sh) copies its
# no-animations and window-opaque flags into the user's toggles in a VM. They
# go when they are still Omarchy's copies, once (a marker): turning
# animations off later in Omarchy's menu stays off.
cmd_animations() {
  local u=${1:?user} h d f mark
  h=$(getent passwd "$u" | cut -d: -f6); [[ -d $h ]] || die "no home for $u"
  d=$h/.local/state/omarchy/toggles/hypr; mark=$h/.local/state/omacvm/animations-on
  [[ -e $mark ]] && return 0
  for f in no-animations.lua window-opaque.lua; do
    if [[ -f $d/$f ]] && cmp -s "$d/$f" "${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr/toggles/$f"; then
      runuser -u "$u" -- rm -f "$d/$f" || die "could not remove $f"
    fi
  done
  runuser -u "$u" -- mkdir -p "${mark%/*}" && runuser -u "$u" -- touch "$mark"
  say "animations on (Omarchy's VM default turned off once)"
}

version() { pacman -Q omarchy 2>/dev/null | awk '{print $2}'; }

cmd_status() {
  local v c
  v=$(version); c=$(sed -n 's|^Server = https://pkgs.omarchy.org/\([a-z]*\)/.*|\1|p' "$CONF" | head -1)
  grep -q '^\[omarchy-aarch64\]' "$CONF" && c="omarchy-mac (${c:-?})"
  echo "omarchy ${v:-none}, repos ${c:-?}"
  [[ $v =~ ^([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] > 4 || (BASH_REMATCH[1] == 4 && BASH_REMATCH[2] >= 5) ))
}

cmd_move() {
  local c v pk vv nv gone; c=$(channel "${1:-}") || exit 1
  v=$(version)
  [[ -n $v ]] || die "no omarchy package here (not an Omarchy VM?)"
  if [[ $v != 4.0* ]] && cmd_status >/dev/null; then say "already on Omarchy $v"; return 0; fi
  [[ -x $S/system-update && -x $S/../app/guest/venus/mpv.sh && -f $S/mkinitcpio-omacvm.conf ]] ||
    die "OmacVM's guest files are not in $S (omacvm apply first)"
  # The transaction rebuilds the initramfs with 4.5's HOOKS baseline: OmacVM's
  # drop-in of this version must be there first (Limine's hook out).
  if [[ -f /etc/mkinitcpio.conf.d/zz-omacvm.conf ]]; then
    install -m644 "$S/mkinitcpio-omacvm.conf" /etc/mkinitcpio.conf.d/zz-omacvm.conf || die "could not write the initramfs drop-in"
  fi
  pacman -Q omarchy-keyring >/dev/null 2>&1 || cmd_keyring
  cmd_repos "$c"
  # 4.5's omarchy-settings owns /etc/mpv/mpv.conf (hwdec=auto-safe), which
  # OmacVM wrote before (app/guest/venus/mpv.sh): the package's file replaces
  # it (--overwrite below), and mpv.sh puts its block back into it right after.
  # Lines of the user's there are in the copy.
  if [[ -f /etc/mpv/mpv.conf && ! -e /etc/mpv/mpv.conf.omacvm-40 ]]; then
    cp -p /etc/mpv/mpv.conf /etc/mpv/mpv.conf.omacvm-40 || die "could not keep /etc/mpv/mpv.conf"
  fi
  pk=$(pacman -Qq); vv=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{print $2}')
  # One transaction: the new repos' omarchy and omarchy-settings with the whole
  # system. -u twice (Omarchy's mirror may be a little behind Arch Linux ARM)
  # also takes a newer package back to the mirror's version: OmacVM's own
  # vulkan-virtio build when the mirror has the same Mesa without our fixes
  # (vulkan-virtio.sh's boot timer builds ours again; a newer Mesa stays, as
  # on 4.0). Never -Sy alone (guest/pkg-add). OMARCHY_UPDATE_PACMAN: Omarchy's pacman guard lets an Omarchy update
  # through. --ask 4 answers yes to "remove the conflicting package": a package
  # that conflicts with one of 4.5's goes (listed after).
  say "omarchy + omarchy-settings from channel $c (with the whole system)"
  if ! OMARCHY_UPDATE_PACMAN=1 pacman -Syu --sysupgrade --noconfirm --ask 4 --overwrite /etc/mpv/mpv.conf omarchy omarchy-settings; then
    cmd_back; die "the package switch failed; the 4.0 repo files are back"
  fi
  gone=$(comm -23 <(sort <<< "$pk") <(pacman -Qq | sort) | tr '\n' ' ')
  [[ -z $gone ]] || say "packages gone (replaced by 4.5's or in conflict with them): $gone"
  nv=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{print $2}')
  if [[ $vv == *omacvm* && -n $nv && $nv != *omacvm* ]] && (( $(vercmp "$nv" "$vv") < 0 )); then
    say "Vulkan: OmacVM's vulkan-virtio $vv went back to the mirror's $nv; vulkan-virtio.sh builds OmacVM's again at the next boot"
  fi
  [[ -f /etc/mpv/mpv.conf.omacvm-40 ]] && say "the old /etc/mpv/mpv.conf is /etc/mpv/mpv.conf.omacvm-40"
  "$S/../app/guest/venus/mpv.sh" >/dev/null || say "mpv's defaults are not set again"
  # Omarchy's own update: its migrations for every 4.x step, the shell restart.
  "$S/system-update" || die "omarchy update did not finish (see /var/log/omacvm-system-update.log)"
  say "on Omarchy $(version); now omacvm apply (4.5's own workspaces)"
}

case ${1:-} in
  repos) cmd_repos "${2:-}" ;;
  keyring) cmd_keyring ;;
  move) cmd_move "${2:-}" ;;
  back) cmd_back ;;
  animations) cmd_animations "${2:-}" ;;
  status) cmd_status ;;
  *) echo "usage: omarchy-45.sh repos|keyring|move|back|status [CHANNEL] | animations USER" >&2; exit 2 ;;
esac
