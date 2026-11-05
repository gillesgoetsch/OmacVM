#!/bin/bash
# omarchy-move.sh (root, in the VM): Omarchy 4.5 on Omarchy's own aarch64
# repos, and the move of an OmacVM VM from Omarchy 4.0 (omarchy-mac) to it.
#
# Omarchy 4.5 merges Omarchy Mac into Omarchy. A VM is platform "aarch64"
# (QEMU's virt machine: no Apple device tree): [omarchy] is
# pkgs.omarchy.org/<channel>/aarch64, Arch Linux ARM comes from Omarchy's
# snapshot of it (arm-<channel>-mirror.omarchy.org), and there is no
# omarchy-mac lane. Never the aarch64-apple (Asahi) files. The repo files and
# Omarchy's package key are Omarchy 4.5.0's (omacom/omarchy
# default/pacman/aarch64, MIT), in omarchy-45/ beside this script.
#
#   omarchy-move.sh preflight [--json]  may this VM move? Changes nothing
#   omarchy-move.sh start               the move in its own unit (omacvm-move-45),
#                                       so a lost SSH session never stops it
#   omarchy-move.sh run                 the move itself (start runs this); it
#                                       goes on from its journal after a stop
#   omarchy-move.sh status [--json]     the move's state from the journal
#   omarchy-move.sh stop                a running move stops after its step
#                                       (never inside the package switch)
#   omarchy-move.sh record              "<version> <lane> <channel>" for the
#                                       Mac's record of the VM (or "none")
#   omarchy-move.sh repos [CHANNEL]     4.5's repo files (stable)
#   omarchy-move.sh keyring             Omarchy's package key, from the copy here
#   omarchy-move.sh pacman ARGS...      pacman with the rule for a missing file
#   omarchy-move.sh animations USER     once after a fresh install: animations on
# Exit: 0 done, 1 failed, 2 usage, 3 refused (nothing changed), 4 run again
# (network, or stopped). The JSON is the contract with OmacVM.app
# (app/scripts/move-vm.sh; work notes: v340 contract).
#
# The move, step by step (each step checks first whether it already holds):
#   protect    OmacVM's packages marked as installed on purpose
#              (keep-packages.txt): Omarchy 4.5 removes orphans on every update
#   initramfs  OmacVM's drop-in (no Limine hook in a GRUB VM)
#   keyring    a new pacman keyring: Arch Linux ARM's keys and Omarchy's
#              (omarchy-mac's own key goes with the old one)
#   repos      4.5's pacman.conf and mirrorlist (the old ones kept as
#              *.omacvm-40; lines of the user's own are listed, not carried)
#   download   every package of the switch, nothing installed yet
#   commit     one transaction: omarchy + omarchy-settings with the whole
#              system (pacman -Suu: Omarchy's snapshot can be older than
#              Arch Linux ARM), Omarchy's obsidian for obsidian-appimage;
#              omarchy-mac-keyring removed. Cut off in here: Undo only
#   platform   Omarchy's own omarchy-hw-platform must say aarch64
#   mpv        OmacVM's mpv defaults again (4.5's omarchy-settings owns the file)
#   vulkan     OmacVM's Venus driver, rebuilt when its libraries went missing
#   kernel     every kernel has its modules, initramfs and DKMS modules; GRUB
#   update     omarchy update (its migrations), as the user (system-update)
#   report     result.json: packages removed, foreign ones, pacman.conf lines
# Tests: src/tests/omarchy-move.sh.
set -uo pipefail
export LC_ALL=C
G=$(cd "$(dirname "$0")" && pwd)
SELF=$G/$(basename "$0")
# The helpers are in OmacVM's guest tree; a fresh install's copy of this
# script sits alone in /usr/local/lib/omacvm with its omarchy-45 folder.
S=$G; [[ -x $S/system-update ]] || S=${OMACVM_GUEST_DIR:-/usr/local/share/omacvm/guest}
F=$G/omarchy-45; [[ -d $F ]] || F=$S/omarchy-45
ROOT=${OMACVM_MOVE_ROOT:-}            # tests: /proc, /sys, /var, /boot, /etc below it
KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571   # Omarchy <pkgs@omarchy.org>
CONF=${OMACVM_PACMAN_CONF:-/etc/pacman.conf}
MIRRORS=${OMACVM_PACMAN_MIRRORS:-/etc/pacman.d/mirrorlist}
GNUPG=${OMACVM_PACMAN_GNUPG:-/etc/pacman.d/gnupg}
J=${OMACVM_MOVE_DIR:-/var/lib/omacvm/move-4.5}
LOG=${OMACVM_MOVE_LOG:-/var/log/omacvm-move-45.log}
CACHE=${OMACVM_PACMAN_CACHE:-/var/cache/pacman/pkg}
UNIT=omacvm-move-45
CHANNEL=${OMACVM_TEST_OMARCHY_CHANNEL:-stable}
NEED_GB=8
WAIT404=${OMACVM_MOVE_WAIT404:-60}
ALARM_HOST=${OMACVM_MOVE_ALARM:-https://de3.mirror.archlinuxarm.org}
PHASES=(preflight protect initramfs keyring repos download commit platform mpv vulkan kernel update report)
say() { echo "OmacVM: $*"; }
die() { echo "omarchy-move: $*" >&2; exit 1; }

# ---------- small helpers ----------
js() {   # a JSON string
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}
jarr() { local o="" x; for x in "$@"; do o+="${o:+, }$(js "$x")"; done; printf '[%s]' "$o"; }
jlines() { local a=() l; while IFS= read -r l; do [[ -n $l ]] && a+=("$l"); done; jarr ${a[@]+"${a[@]}"}; }
jbool() { if [[ $1 == 1 || $1 == true ]]; then echo true; else echo false; fi; }
jget() { cat "$J/$1" 2>/dev/null || true; }
jset() { mkdir -p "$J" && printf '%s\n' "$2" > "$J/$1.new" && mv -f "$J/$1.new" "$J/$1"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

channel() {
  case ${1:-stable} in stable|rc|edge) echo "${1:-stable}" ;; *) die "unknown channel: $1" ;; esac
}

# 4.5's files for a channel: stable as Omarchy ships it, rc and edge (tests
# only) the same with their own server names.
render_conf() {
  sed "s|https://pkgs.omarchy.org/stable/|https://pkgs.omarchy.org/$1/|" "$F/pacman-stable.conf"
}
render_mirrors() {
  local host=arm-$1-mirror.omarchy.org
  [[ $1 == edge ]] && host=arm-mirror.omarchy.org
  sed "s|https://arm-stable-mirror.omarchy.org/|https://$host/|" "$F/mirrorlist-stable"
}

version() { pacman -Q omarchy 2>/dev/null | awk '{ print $2 }'; }
at45() {   # VERSION: 4.5 or later
  [[ ${1:-} =~ ^([0-9]+)\.([0-9]+) ]] &&
    (( BASH_REMATCH[1] > 4 || (BASH_REMATCH[1] == 4 && BASH_REMATCH[2] >= 5) ))
}
# The lane the repos name: omarchy-mac (its [omarchy-aarch64]), aarch64
# (Omarchy's own repos, no omarchy-mac lane) or unknown; and its channel.
lane() {
  if grep -q '^\[omarchy-aarch64\]' "$CONF" 2>/dev/null; then echo omarchy-mac
  elif grep -q '^Server = https://pkgs.omarchy.org/[a-z]*/\$arch' "$CONF" 2>/dev/null; then echo aarch64
  else echo unknown; fi
}
lane_channel() {
  case $(lane) in
    omarchy-mac) awk '/^\[omarchy-aarch64\]/ { s = 1; next } /^\[/ { s = 0 }
                  s && /^Server/ { n = split($0, p, "/"); print p[n]; exit }' "$CONF" ;;
    aarch64) sed -n 's|^Server = https://pkgs.omarchy.org/\([a-z]*\)/.*|\1|p' "$CONF" | head -1 ;;
  esac
}

# Omarchy 4.5's own platform rules (bin/omarchy-hw-platform) on a booted VM,
# read here so a 4.0 VM, which does not have that command, can be checked:
# an Apple or Qualcomm device tree, an NVIDIA N1x or GB10, else plain aarch64.
platform() {
  local m f d v p apple=0 qcom=0
  m=${OMACVM_MOVE_MACHINE:-$(uname -m)}
  for f in "$ROOT/proc/device-tree/compatible" "$ROOT/sys/firmware/devicetree/base/compatible"; do
    [[ -r $f ]] || continue
    tr '\0' '\n' < "$f" | grep -q '^apple,' && apple=1
    tr '\0' '\n' < "$f" | grep -q '^qcom,' && qcom=1
  done
  for d in "$ROOT"/sys/bus/acpi/devices/NVDA0200:*; do [[ -d $d ]] && { echo aarch64-n1x; return; }; done
  for d in "$ROOT"/sys/bus/pci/devices/*; do
    [[ -r $d/vendor && -r $d/device ]] || continue
    read -r v < "$d/vendor"; read -r p < "$d/device"
    [[ $v == 0x10de && $p == 0x2e06 ]] && { echo aarch64-n1x; return; }
    [[ $v == 0x10de && $p == 0x2e12 ]] && { echo aarch64-gb10; return; }
  done
  if (( apple )); then echo aarch64-apple
  elif (( qcom )); then echo aarch64-qualcomm
  elif [[ $m == aarch64 ]]; then echo aarch64
  else echo "$m"; fi
}

# The move's own unit or run holds the lock.
alive() {
  [[ -e $J/lock ]] || return 1
  ! flock -n "$J/lock" true 2>/dev/null
}

# ---------- preflight ----------
CHECKS="" PF_CODE="" PF_REASON="" PF_EXIT=0 PF_FREE="" PF_TARGET=""
chk() {   # ID OK TEXT; the first failed check is the answer
  CHECKS+="${CHECKS:+, }{\"id\": $(js "$1"), \"ok\": $(jbool "$2"), \"text\": $(js "$3")}"
}
refuse() {   # CODE EXIT REASON
  [[ -z $PF_CODE ]] || return 0
  PF_CODE=$1 PF_EXIT=$2 PF_REASON=$3
}
preflight() {
  local v ln ch pl vendor free need f missing="" db tmp st pd
  v=$(version); ln=$(lane); ch=$(lane_channel)
  st=$(jget state); pd=$(jget phase-done)
  # A move that began here and stopped (Resume): the journal says it was
  # omarchy-mac 4.0 then; the VM may be half way now.
  PF_RESUME=""; [[ -n $pd && $st != done && $st != refused ]] && PF_RESUME=$pd
  if [[ -z ${IN_RUN:-} && $st == running ]] && alive; then
    chk move-running 0 "a move to Omarchy 4.5 runs now"
    refuse move-running 3 "A move to Omarchy 4.5 is already running in this VM."
  fi
  if [[ -n $PF_RESUME ]]; then
    if [[ $(resumable) == 0 ]]; then
      chk journal 0 "the package switch was cut off"
      refuse undo-only 3 "The package switch was cut off; Undo puts the VM back as it was before the move."
    else
      chk journal 1 "the move goes on after: $PF_RESUME"
    fi
  # Omarchy 4.0 from omarchy-mac, and nothing else.
  elif [[ -z $v ]]; then
    chk omarchy 0 "no omarchy package"; refuse not-omarchy 3 "This VM has no Omarchy package; there is nothing to move."
  elif at45 "$v"; then
    chk omarchy 0 "Omarchy $v"; refuse already-moved 3 "This VM is on Omarchy $v already."
  elif [[ $v != 4.0* ]]; then
    chk omarchy 0 "Omarchy $v"; refuse not-omarchy-40 3 "This VM has Omarchy $v; the move takes Omarchy 4.0 only."
  else
    chk omarchy 1 "Omarchy $v"
  fi
  if [[ -n $PF_RESUME ]]; then
    :
  elif [[ $ln == omarchy-mac ]] || pacman -Q omarchy-mac-keyring >/dev/null 2>&1; then
    chk lane 1 "omarchy-mac (${ch:-?})"
  elif [[ -n $v ]] && ! at45 "$v"; then
    chk lane 0 "repos: $ln"
    refuse no-omarchy-mac 3 "This VM's Omarchy is not from omarchy-mac; OmacVM does not know how to move it."
  fi
  # Platform aarch64 only: never the Apple (Asahi) files.
  pl=$(platform)
  case $pl in
    aarch64) chk platform 1 "platform aarch64" ;;
    aarch64-apple) chk platform 0 "platform $pl"
      refuse apple-platform 3 "This system reports Apple hardware (an Asahi device tree); OmacVM moves VMs only." ;;
    *) chk platform 0 "platform $pl"
      refuse platform 3 "This system reports platform $pl; OmacVM moves plain aarch64 VMs only." ;;
  esac
  vendor=$(cat "$ROOT/sys/class/dmi/id/sys_vendor" 2>/dev/null || true)
  if [[ $vendor == QEMU ]]; then chk vm 1 "QEMU virtual machine"
  else chk vm 0 "system vendor ${vendor:-unknown}"; refuse not-qemu 3 "This is not an OmacVM.app (QEMU) virtual machine."; fi
  f=$ROOT/var/lib/omarchy/image/target
  if [[ -e $f ]] && grep -qi 'apple' "$f" 2>/dev/null; then
    chk image-target 0 "$f names Apple hardware"
    refuse image-target 3 "Omarchy's image record in this VM names Apple hardware; OmacVM does not move it."
  fi
  # pacman: free, and not cut off in the middle of a run.
  if [[ -e $ROOT/var/lib/pacman/db.lck ]]; then
    if [[ -n $PF_RESUME && -z ${IN_RUN:-} ]] && ! pgrep -x pacman >/dev/null 2>&1; then
      chk pacman 1 "a lock the stopped move left (removed when it goes on)"
    elif pgrep -x pacman >/dev/null 2>&1; then
      chk pacman 0 "pacman runs"; refuse pacman-busy 3 "pacman is running in this VM (an update?); try again when it is done."
    else
      chk pacman 0 "pacman's lock without pacman"
      refuse pacman-lock 3 "pacman was cut off in this VM (its lock is left); Update VM clears it, then try again."
    fi
  else
    chk pacman 1 "pacman free"
  fi
  # The disk OmacVM made: btrfs root, GRUB.
  if command -v grub-mkconfig >/dev/null 2>&1 && [[ -f $ROOT/boot/grub/grub.cfg ]]; then chk grub 1 "GRUB"
  else chk grub 0 "no GRUB"; refuse no-grub 3 "This VM does not boot with GRUB, as OmacVM's VMs do."; fi
  if [[ $(findmnt -no FSTYPE / 2>/dev/null) == btrfs ]]; then chk layout 1 "btrfs root"
  else chk layout 0 "root is not btrfs"; refuse layout 3 "This VM's disk is not laid out as OmacVM's (btrfs)."; fi
  free=$(df -B1 --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
  [[ $free =~ ^[0-9]+$ ]] || free=0
  PF_FREE=$(awk -v b="$free" 'BEGIN { printf "%.1f", b / 1073741824 }')
  if (( free >= NEED_GB * 1073741824 )); then chk space 1 "$PF_FREE GB free"
  else chk space 0 "$PF_FREE GB free"; refuse low-space 3 "The VM has $PF_FREE GB free on its disk; the move needs $NEED_GB GB."; fi
  # OmacVM's guest tree of this version (Update VM brings it).
  for f in "$S/system-update" "$S/mkinitcpio-omacvm.conf" "$S/keep-packages.txt" "$F/pacman-stable.conf" \
           "$F/mirrorlist-stable" "$F/omarchy-key.asc" "$S/../app/guest/venus/mpv.sh"; do
    [[ -e $f ]] || missing+=" ${f##*/}"
  done
  for f in systemd-run flock gpg; do command -v "$f" >/dev/null 2>&1 || missing+=" $f"; done
  if [[ -z $missing ]]; then chk guest 1 "OmacVM's guest files"
  else chk guest 0 "missing:$missing"; refuse guest-old 3 "OmacVM's files in this VM are older than the move needs: Update VM first."; fi
  # Omarchy's repos answer (only when nothing else refused: a network wait).
  if [[ -z $PF_CODE ]]; then
    tmp=$(mktemp) || tmp=/dev/null
    if curl -fsS --max-time 30 -o "$tmp" "https://pkgs.omarchy.org/$CHANNEL/aarch64/omarchy.db" 2>/dev/null &&
       curl -fsSI --max-time 30 -o /dev/null "https://arm-$CHANNEL-mirror.omarchy.org/aarch64/core/core.db" 2>/dev/null; then
      db=$(tar -tf "$tmp" 2>/dev/null | sed -n 's|^omarchy-\([0-9][^/]*\)/$|\1|p' | head -1)
      PF_TARGET=${db%-*}
      chk repos 1 "Omarchy ${PF_TARGET:-?} on pkgs.omarchy.org/$CHANNEL"
      if [[ -z $PF_TARGET ]] || ! at45 "$PF_TARGET"; then
        refuse repos-unreachable 4 "Omarchy's $CHANNEL repo did not offer Omarchy 4.5; try again later."
      fi
    else
      chk repos 0 "pkgs.omarchy.org or Omarchy's Arch Linux ARM mirror did not answer"
      refuse repos-unreachable 4 "Omarchy's package servers did not answer; check the VM's network and try again."
    fi
    [[ $tmp == /dev/null ]] || rm -f "$tmp"
  fi
  PF_VERSION=$v PF_LANE=$ln PF_CHANNEL=$ch PF_PLATFORM=$pl
}
preflight_json() {
  printf '{"format": 1, "ok": %s, "code": %s, "reason": %s, "omarchy": %s, "lane": %s, "channel": %s, "platform": %s, ' \
    "$(jbool "$([[ -z $PF_CODE ]] && echo 1)")" "$(js "$PF_CODE")" "$(js "$PF_REASON")" "$(js "${PF_VERSION%-*}")" \
    "$(js "$PF_LANE")" "$(js "$PF_CHANNEL")" "$(js "$PF_PLATFORM")"
  printf '"free_gb": %s, "need_gb": %s, "target": {"omarchy": %s, "channel": %s}, "resume": %s, "phase_done": %s, "checks": [%s]}\n' \
    "${PF_FREE:-0}" "$NEED_GB" "$(js "$PF_TARGET")" "$(js "$CHANNEL")" "$(jbool "$([[ -n $PF_RESUME ]] && echo 1)")" \
    "$(js "$PF_RESUME")" "$CHECKS"
}
cmd_preflight() {
  preflight
  if [[ ${1:-} == --json ]]; then preflight_json
  elif [[ -z $PF_CODE ]]; then say "ready to move to Omarchy ${PF_TARGET:-4.5} ($PF_FREE GB free)"
  else say "$PF_REASON ($PF_CODE)"; fi
  [[ -z $PF_CODE ]] && return 0
  return "$PF_EXIT"
}

# ---------- the rule for a missing file (no fallback mirror) ----------
# Omarchy's snapshot of Arch Linux ARM can name a file it does not have yet
# (2026-10-24: luajit). Inside OmacVM's own transactions only: on a 404 the
# lists again and one more try a minute later; still a 404: that exact file
# (name and version as the snapshot's list says) from Arch Linux ARM into
# pacman's cache, where pacman checks it against the list's checksum and its
# signature as always. Never a second mirror in the repo files.
fourohfour() { sed -n "s/^error: failed retrieving file '\([^']*\)' from .*404.*/\1/p" "$1" | sort -u; }
cmd_pacman() {
  local out rc f r files n=0
  out=$(mktemp) || return 1
  pacman "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  if (( rc )) && [[ -n $(fourohfour "$out") ]]; then
    say "a file Omarchy's mirror lists is not there yet: the lists again in ${WAIT404} s, then once more"
    sleep "$WAIT404"
    pacman -Syy --noconfirm >/dev/null 2>&1
    pacman "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
  fi
  if (( rc )) && files=$(fourohfour "$out") && [[ -n $files ]]; then
    for f in $files; do
      [[ $f =~ ^[A-Za-z0-9@._+-]+\.pkg\.tar\.(zst|xz|gz)$ ]] || continue
      r=$(sed -n "s|^\([a-z]*\) $f\$|\1|p" < <(pacman_files) | head -1)
      case $r in core|extra|alarm) ;; *) say "$f: not one of Arch Linux ARM's (repo ${r:-unknown}); not fetched"; continue ;; esac
      if curl -fsS --max-time 600 -o "$CACHE/$f.part" "$ALARM_HOST/aarch64/$r/$f" &&
         curl -fsS --max-time 60 -o "$CACHE/$f.sig.part" "$ALARM_HOST/aarch64/$r/$f.sig"; then
        mv -f "$CACHE/$f.part" "$CACHE/$f"; mv -f "$CACHE/$f.sig.part" "$CACHE/$f.sig"
        say "$f from Arch Linux ARM ($r), checked by pacman as always"
        [[ ! -d $J ]] || echo "$f" >> "$J/single-file-fetches"
        n=$((n + 1))
      else
        rm -f "$CACHE/$f.part" "$CACHE/$f.sig.part"
      fi
    done
    if (( n )); then pacman "$@" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}; fi
  fi
  NETFAIL=0
  grep -qE 'failed retrieving file|failed to synchronize|Could not resolve host|Operation too slow|Connection timed out' "$out" && NETFAIL=1
  rm -f "$out"
  return "$rc"
}
# "repo file" of everything the switch downloads.
pacman_files() { pacman -Suup --print-format '%r %f' "${TARGETS[@]}" 2>/dev/null; }

# ---------- repos, keyring ----------
cmd_repos() {
  local c; c=$(channel "${1:-$CHANNEL}") || exit 1
  [[ -f $F/pacman-stable.conf && -f $F/mirrorlist-stable ]] || die "Omarchy 4.5's repo files are not in $F"
  [[ -e $CONF.omacvm-40 ]] || cp -p "$CONF" "$CONF.omacvm-40" || die "could not keep $CONF"
  [[ -e $MIRRORS.omacvm-40 ]] || cp -p "$MIRRORS" "$MIRRORS.omacvm-40" || die "could not keep $MIRRORS"
  render_conf "$c" > "$CONF.new" && render_mirrors "$c" > "$MIRRORS.new" &&
    mv -f "$CONF.new" "$CONF" && mv -f "$MIRRORS.new" "$MIRRORS" || die "could not write the repo files"
  ! grep -qiE 'asahi|aarch64-apple|omarchy-aarch64' "$CONF" "$MIRRORS" || die "the repo files name Apple's or omarchy-mac's repos"
  say "repos: Omarchy 4.5 aarch64, channel $c"
}
repos_hold() { cmp -s "$CONF" <(render_conf "$CHANNEL") && cmp -s "$MIRRORS" <(render_mirrors "$CHANNEL"); }

key_ok() {   # the shipped copy is Omarchy's key
  local fpr
  fpr=$(gpg --batch --quiet --no-tty --show-keys --with-colons "$F/omarchy-key.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  [[ $fpr == "$KEY" ]]
}
key_trusted() {
  [[ $(gpg --homedir "$GNUPG" --no-permission-warning --batch --with-colons --list-keys "$KEY" 2>/dev/null) =~ (^|$'\n')pub:[fu]: ]]
}
cmd_keyring() {
  key_trusted && return 0
  key_ok || die "the copy of Omarchy's package key is not $KEY"
  pacman-key --add "$F/omarchy-key.asc" >/dev/null 2>&1 || die "could not add Omarchy's package key"
  pacman-key --lsign-key "$KEY" >/dev/null 2>&1 || die "could not trust Omarchy's package key"
  key_trusted || die "Omarchy's package key is still not trusted"
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

# ---------- the steps ----------
TARGETS=()
targets() {
  TARGETS=(omarchy omarchy-settings)
  # obsidian-appimage is omarchy-mac's; Omarchy's aarch64 repo has obsidian
  # (it conflicts with the AppImage, which goes in the same transaction).
  if pacman -Q obsidian-appimage >/dev/null 2>&1 || grep -q '^obsidian-appimage ' "$J/pre-packages.txt" 2>/dev/null; then
    TARGETS+=(obsidian)
  fi
}

step_protect() {
  local want have
  [[ -s $J/pre-packages.txt ]] || pacman -Q > "$J/pre-packages.txt" || return 1
  [[ -s $J/pre-explicit.txt ]] || pacman -Qqe > "$J/pre-explicit.txt" || return 1
  want=$(grep -v '^#' "$S/keep-packages.txt" | awk 'NF { print $1 }')
  # shellcheck disable=SC2086 # one package per word
  have=$(pacman -Qqd $want 2>/dev/null || true)
  if [[ -n $have ]]; then
    # shellcheck disable=SC2086
    pacman -D --asexplicit $have >/dev/null || return 1
    echo "$have" >> "$J/keep-marked.txt"
    say "marked as installed on purpose: $(echo $have)"
  fi
}

step_initramfs() {
  local d=$ROOT/etc/mkinitcpio.conf.d
  cmp -s "$S/mkinitcpio-omacvm.conf" "$d/zz-omacvm.conf" && return 0
  install -Dm644 "$S/mkinitcpio-omacvm.conf" "$d/zz-omacvm.conf"
}

step_keyring() {
  local k list=()
  [[ -e $J/keyring-done ]] && key_trusted && return 0
  key_ok || { REASON="OmacVM's copy of Omarchy's package key is not Omarchy's"; return 1; }
  # The old keyring stays beside it (Undo restores the whole disk anyway).
  gpgconf --homedir "$GNUPG" --kill gpg-agent >/dev/null 2>&1 || true
  if [[ -d $GNUPG && ! -e $GNUPG.omacvm-40 ]]; then mv "$GNUPG" "$GNUPG.omacvm-40" || return 1
  else rm -rf "$GNUPG"; fi
  for k in archlinuxarm archlinux omarchy; do [[ -f $ROOT/usr/share/pacman/keyrings/$k.gpg ]] && list+=("$k"); done
  [[ " ${list[*]-} " == *" archlinuxarm "* ]] || { REASON="Arch Linux ARM's keyring package is missing"; return 1; }
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate "${list[@]}" >/dev/null 2>&1 || return 1
  pacman-key --add "$F/omarchy-key.asc" >/dev/null 2>&1 && pacman-key --lsign-key "$KEY" >/dev/null 2>&1 || return 1
  key_trusted || return 1
  : > "$J/keyring-done"
  say "pacman keyring: new, with Arch Linux ARM's keys and Omarchy's ($KEY)"
}

step_repos() {
  repos_hold && return 0
  ( cmd_repos "$CHANNEL" ) || return 1
}

step_download() {
  targets
  say "downloading Omarchy ${PF_TARGET:-4.5} with the whole system: ${TARGETS[*]} (nothing installed yet)"
  cmd_pacman -Syyuuw --noconfirm --ask 4 "${TARGETS[@]}" >> "$LOG" 2>&1 && return 0
  (( NETFAIL )) && return 4
  return 1
}

step_commit() {
  local before after
  targets
  # 4.5's omarchy-settings owns /etc/mpv/mpv.conf (hwdec=auto-safe), which
  # OmacVM wrote before (app/guest/venus/mpv.sh): the package's file replaces
  # it (--overwrite), and the mpv step puts OmacVM's block back into it.
  if [[ -f $ROOT/etc/mpv/mpv.conf && ! -e $ROOT/etc/mpv/mpv.conf.omacvm-40 ]]; then
    cp -p "$ROOT/etc/mpv/mpv.conf" "$ROOT/etc/mpv/mpv.conf.omacvm-40" || return 1
  fi
  before=$(pacman -Q | sha256sum)
  jset commit-started 1; sync
  say "the switch: ${TARGETS[*]} with the whole system, from the downloads"
  # OMARCHY_UPDATE_PACMAN: Omarchy's pacman guard lets an Omarchy update
  # through. --ask 4: yes to "remove the conflicting package" (listed after).
  if ! OMARCHY_UPDATE_PACMAN=1 cmd_pacman -Suu --noconfirm --ask 4 --overwrite /etc/mpv/mpv.conf "${TARGETS[@]}" >> "$LOG" 2>&1; then
    after=$(pacman -Q | sha256sum)
    if [[ $before == "$after" && ! -e $ROOT/var/lib/pacman/db.lck ]]; then
      rm -f "$J/commit-started"; sync   # pacman stopped before it changed a package
      REASON="pacman refused the switch before it changed anything (see $LOG)"
      (( NETFAIL )) && return 4
    else
      REASON="the package switch did not finish (see $LOG)"
    fi
    return 1
  fi
  if pacman -Q omarchy-mac-keyring >/dev/null 2>&1; then
    pacman -Rdd --noconfirm omarchy-mac-keyring >> "$LOG" 2>&1 || say "omarchy-mac-keyring not removed (listed)"
  fi
  at45 "$(version)" || { REASON="omarchy is $(version) after the switch"; return 1; }
  jset commit-done 1; sync
}

step_platform() {
  local p
  p=$(omarchy-hw-platform 2>/dev/null) || p=""
  [[ $p == aarch64 ]] && return 0
  REASON="Omarchy says this VM is platform '${p:-none}', not aarch64"
  return 1
}

step_mpv() {
  local m=$S/../app/guest/venus/mpv.sh
  [[ -x $m ]] || return 0
  "$m" >/dev/null || say "mpv's defaults are not set again"
  [[ -f $ROOT/etc/mpv/mpv.conf.omacvm-40 ]] && say "the old /etc/mpv/mpv.conf is /etc/mpv/mpv.conf.omacvm-40"
  return 0
}

step_vulkan() {
  local v=$S/../app/guest/venus/vulkan-virtio.sh have
  have=$(pacman -Q omacvm-vulkan-virtio vulkan-virtio 2>/dev/null | awk '{ print $2 }' | head -1)
  [[ -x $v && $have == *omacvm* ]] || return 0
  "$v" --want >> "$LOG" 2>&1 || echo "Vulkan: OmacVM's Venus driver was not rebuilt (OpenGL is unaffected; the VM tries again at its next start)" >> "$J/warnings"
  return 0
}

# Every kernel: its modules folder, an initramfs for each preset, DKMS's
# modules for it (the switch can take Arch Linux ARM's kernel and headers
# back to the snapshot's). The memory-optimized kernel is OmacVM's own build
# and stays as it is; without its modules GRUB boots the stock kernel.
step_kernel() {
  local k kv p n i before bad=0 thp=none
  for k in linux-aarch64 linux-aarch64-thp; do
    pacman -Q "$k" >/dev/null 2>&1 || continue
    kv=$(pacman -Ql "$k" 2>/dev/null | sed -n 's|^[^ ]* /usr/lib/modules/\([^/]*\)/kernel/$|\1|p' | head -1)
    [[ $k == linux-aarch64-thp ]] && thp=ok
    if [[ -z $kv || ! -d $ROOT/usr/lib/modules/$kv ]]; then
      [[ $k == linux-aarch64-thp ]] && thp=rebuild-failed
      echo "$k: no modules for its version (${kv:-?})" >> "$J/warnings"; bad=1; continue
    fi
    # DKMS (battery, camera, video decoding): built for this kernel when its
    # headers are there; dkms autoinstall does only what is missing.
    if command -v dkms >/dev/null 2>&1 && [[ -d $ROOT/usr/lib/modules/$kv/build ]] &&
       [[ -n $(dkms status 2>/dev/null) ]]; then
      before=$(dkms status -k "$kv" 2>/dev/null | grep -vc ': installed' || true)
      dkms autoinstall -k "$kv" >> "$LOG" 2>&1 || true
      if [[ -n $(dkms status -k "$kv" 2>/dev/null | grep -v ': installed') ]]; then
        echo "$k $kv: DKMS modules not built (battery, camera, video decoding may be missing on it)" >> "$J/warnings"
      elif [[ $k == linux-aarch64-thp && ${before:-0} != 0 ]]; then
        thp=rebuilt
      fi
    fi
  done
  for p in "$ROOT"/etc/mkinitcpio.d/*.preset; do
    [[ -f $p ]] || continue
    ( source "$p"; for n in "${PRESETS[@]}"; do i=${n}_image; [[ -z ${!i:-} || -f $ROOT${!i} ]] || exit 1; done ) && continue
    say "an initramfs is missing: building them again"
    mkinitcpio -P >> "$LOG" 2>&1 || { REASON="the initramfs did not build (see $LOG)"; return 1; }
    break
  done
  if [[ $thp == rebuild-failed ]] && grep -q '^GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"$' "$ROOT/etc/default/grub" 2>/dev/null; then
    sed -i 's|^GRUB_TOP_LEVEL="/boot/vmlinuz-linux-aarch64-thp"$|GRUB_TOP_LEVEL="/boot/vmlinuz-linux"|' "$ROOT/etc/default/grub"
    echo "The memory-optimized kernel has no modules after the move: GRUB starts Arch Linux ARM's kernel (Update VM builds it again)" >> "$J/warnings"
  fi
  echo "$thp" > "$J/kernel-thp"
  grub-mkconfig -o "$ROOT/boot/grub/grub.cfg" >> "$LOG" 2>&1 || { REASON="GRUB's menu did not build (see $LOG)"; return 1; }
  (( bad == 0 )) || say "kernel: see the warnings"
  return 0
}

step_update() {
  local rc=0
  "$S/system-update" >> "$LOG" 2>&1 || rc=$?
  case $rc in
    0) return 0 ;;
    2) REASON="omarchy update ran, but the desktop's graphics would not start (see /var/log/omacvm-system-update.log)" ;;
    *) REASON="omarchy update did not finish (see /var/log/omacvm-system-update.log)" ;;
  esac
  return 1
}

# The user's own pacman.conf lines (not omarchy-mac's, base-install.sh's or
# 4.5's): listed, not carried over (Omarchy's refresh would drop them anyway).
user_conf_lines() {
  local old=$CONF.omacvm-40
  [[ -f $old ]] || return 0
  awk '
    function norm(s) { gsub(/[ \t]*=[ \t]*/, " = ", s); gsub(/[ \t]+$/, "", s); return s }
    BEGIN {
      split("Color|ILoveCandy|VerbosePkgLists|HoldPkg = pacman glibc|Architecture = auto|Architecture = aarch64|CheckSpace|ParallelDownloads = 5|ParallelDownloads = 8|DownloadUser = alpm|SigLevel = Required DatabaseOptional|LocalFileSigLevel = Optional", o, "|")
      for (i in o) known[o[i]] = 1
      split("omarchy|omarchy-aarch64|asahi-alarm|core|extra|alarm|aur", r, "|")
      for (i in r) repo[r[i]] = 1
    }
    /^[ \t]*(#|$)/ { next }
    /^\[/ { sec = substr($0, 2, index($0, "]") - 2); if (sec != "options" && !(sec in repo)) print $0; next }
    sec == "options" { l = norm($0); if (!(l in known)) print l; next }
    !(sec in repo) { print norm($0); next }
    sec == "omarchy" || sec == "omarchy-aarch64" || sec == "asahi-alarm" { next }
    { l = norm($0); if (l != "Include = /etc/pacman.d/mirrorlist") print "[" sec "] " l }
  ' "$old"
}

step_report() {
  local removed foreign keep fetched warn obs=none
  removed=$(comm -23 <(awk '{ print $1 }' "$J/pre-packages.txt" | sort) <(pacman -Qq | sort))
  foreign=$(pacman -Qqm 2>/dev/null | grep -vxE 'linux-aarch64-thp(-headers)?|omacvm-vulkan-virtio' || true)
  keep=$(sort -u "$J/keep-marked.txt" 2>/dev/null)
  fetched=$(cat "$J/single-file-fetches" 2>/dev/null)
  warn=$(cat "$J/warnings" 2>/dev/null)
  grep -qx obsidian-appimage <<<"$removed" && pacman -Q obsidian >/dev/null 2>&1 && obs=swapped
  {
    printf '{"omarchy": %s, "channel": %s, "platform": %s,\n' "$(js "$(version | sed 's/-[^-]*$//')")" "$(js "$CHANNEL")" "$(js aarch64)"
    printf ' "removed": %s,\n "foreign": %s,\n' "$(jlines <<<"$removed")" "$(jlines <<<"$foreign")"
    printf ' "pacman_conf_lines": %s,\n "pacman_conf_backup": %s,\n' "$(user_conf_lines | jlines)" "$(js "$CONF.omacvm-40")"
    printf ' "obsidian": %s,\n "keep_marked": %s,\n' "$(js "$obs")" "$(jlines <<<"$keep")"
    printf ' "vulkan": %s,\n "kernel_thp": %s,\n' \
      "$(js "$(pacman -Qq omacvm-vulkan-virtio vulkan-virtio 2>/dev/null | head -1)")" "$(js "$(jget kernel-thp)")"
    printf ' "single_file_fetches": %s,\n "warnings": %s}\n' "$(jlines <<<"$fetched")" "$(jlines <<<"$warn")"
  } > "$J/result.json.new" && mv -f "$J/result.json.new" "$J/result.json"
  [[ -z $removed ]] || say "packages gone in the move: $(echo $removed)"
  [[ -z $foreign ]] || say "in no repo now (kept): $(echo $foreign)"
  [[ -z $warn ]] || say "warnings: $warn"
}

# ---------- run, start, stop, status ----------
finish() {   # STATE CODE REASON EXIT
  jset state "$1"; jset code "$2"; jset reason "$3"; jset finished "$(now)"
  [[ -n $3 ]] && say "$3"
  exit "$4"
}
resumable() {   # 1 unless cut off inside the package switch
  if [[ -e $J/commit-started && ! -e $J/commit-done ]]; then echo 0; else echo 1; fi
}
cmd_run() {
  local i p done_p start=1 rc
  mkdir -p "$J" || die "could not make $J"
  exec 9>"$J/lock"
  flock -n 9 || { say "a move runs already"; exit 3; }
  [[ $(jget state) == done ]] && { say "the move is done (Omarchy $(version))"; exit 0; }
  if [[ $(resumable) == 0 ]]; then
    finish failed commit "The package switch was cut off; Undo puts the VM back as it was before the move." 1
  fi
  done_p=$(jget phase-done)
  if [[ -n $done_p ]]; then
    # Going on: the journal says this VM was on omarchy-mac when it began.
    for i in "${!PHASES[@]}"; do [[ ${PHASES[$i]} == "$done_p" ]] && start=$((i + 1)); done
    say "going on after: $done_p"
    # A VM reset in the download leaves pacman's lock (no pacman runs now).
    if [[ -e $ROOT/var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null 2>&1; then
      rm -f "$ROOT/var/lib/pacman/db.lck"; say "pacman's lock from the stopped move: removed"
    fi
    IN_RUN=1 preflight
    if [[ -n $PF_CODE ]]; then finish failed "$PF_CODE" "$PF_REASON" "$PF_EXIT"; fi
  fi
  rm -f "$J/stop"
  jset state running; jset code ""; jset reason ""; jset finished ""
  [[ -s $J/started ]] || jset started "$(now)"
  for ((i = start - 1; i < ${#PHASES[@]}; i++)); do
    p=${PHASES[$i]}
    if [[ -e $J/stop ]]; then
      rm -f "$J/stop"; finish stopped stopped "Stopped after the step '$done_p'; Resume goes on from there." 4
    fi
    jset phase "$p"
    say "step $((i + 1))/${#PHASES[@]}: $p"
    if [[ $p == preflight ]]; then
      IN_RUN=1 preflight
      if [[ -n $PF_CODE ]]; then
        rm -f "$J/started"
        finish refused "$PF_CODE" "$PF_REASON" "$PF_EXIT"
      fi
      jset target "$PF_TARGET"
    else
      PF_TARGET=$(jget target)
      REASON="" NETFAIL=0 rc=0
      "step_$p" || rc=$?
      if (( rc == 4 )); then
        finish failed network "The download stopped (network); Resume goes on from there." 4
      elif (( rc )); then
        finish failed "$p" "${REASON:-The step '$p' failed (see $LOG).}" 1
      fi
    fi
    jset phase-done "$p"; done_p=$p
  done
  finish done "" "" 0
}

cmd_start() {
  local out rc=0
  mkdir -p "$J" || die "could not make $J"
  if [[ $(jget state) == running ]] && alive; then say "the move runs already"; return 0; fi
  out=$(cmd_preflight --json) || rc=$?
  if (( rc )); then echo "$out"; return "$rc"; fi
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemd-run --quiet --collect --unit="$UNIT" -p StandardInput=null \
    -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p KillSignal=SIGINT -p TimeoutStopSec=900 \
    -E PATH=/usr/local/sbin:/usr/local/bin:/usr/bin -E LANG=C.UTF-8 "$SELF" run ||
    die "could not start the move's unit"
  # Its state is "running" once it holds the lock.
  for _ in 1 2 3 4 5 6 7 8 9 10; do alive && break; sleep 0.5; done
  say "the move runs (unit $UNIT, log $LOG)"
}

cmd_stop() {
  alive || { say "no move runs"; return 0; }
  : > "$J/stop"; say "the move stops after its current step"
}

cmd_status() {
  local st res=null
  st=$(jget state); [[ -n $st ]] || st=none
  [[ $st == running ]] && ! alive && st=interrupted
  [[ $st == done && -s $J/result.json ]] && res=$(cat "$J/result.json")
  if [[ ${1:-} != --json ]]; then
    echo "omarchy $(version), repos $(lane) $(lane_channel), move: $st $(jget phase)"
    return 0
  fi
  local idx=0 i p; p=$(jget phase)
  for i in "${!PHASES[@]}"; do [[ ${PHASES[$i]} == "$p" ]] && idx=$((i + 1)); done
  printf '{"format": 1, "state": %s, "phase": %s, "phase_index": %s, "phases": %s, ' "$(js "$st")" "$(js "$p")" "$idx" "$(jarr "${PHASES[@]}")"
  printf '"commit_started": %s, "resumable": %s, "started": %s, "finished": %s, "code": %s, "reason": %s, ' \
    "$(jbool "$([[ -e $J/commit-started ]] && echo 1)")" "$(jbool "$(resumable)")" "$(js "$(jget started)")" \
    "$(js "$(jget finished)")" "$(js "$(jget code)")" "$(js "$(jget reason)")"
  printf '"omarchy": %s, "lane": %s, "channel": %s, "log": %s, "result": %s}\n' \
    "$(js "$(version | sed 's/-[^-]*$//')")" "$(js "$(lane)")" "$(js "$(lane_channel)")" "$(js "$LOG")" "$res"
}

cmd_record() {
  local v; v=$(version)
  [[ -n $v ]] || { echo none; return 0; }
  echo "${v%-*} $(lane) $(lane_channel)"
}

case ${1:-} in
  preflight) cmd_preflight "${2:-}" ;;
  start) cmd_start ;;
  run) cmd_run ;;
  stop) cmd_stop ;;
  status) cmd_status "${2:-}" ;;
  record) cmd_record ;;
  repos) cmd_repos "${2:-}" ;;
  keyring) cmd_keyring ;;
  pacman) shift; cmd_pacman "$@" ;;
  animations) cmd_animations "${2:-}" ;;
  *) echo "usage: omarchy-move.sh preflight [--json] | start | run | stop | status [--json] | record | repos [CHANNEL] | keyring | pacman ARGS... | animations USER" >&2; exit 2 ;;
esac
