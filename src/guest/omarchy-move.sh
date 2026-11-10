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
#   omarchy-move.sh pending             exit 0 (one line why) while a move began
#                                       here and its package switch is not done:
#                                       OmacVM changes no package then
#   omarchy-move.sh keep                the person keeps the disk as a stopped
#                                       move left it (OmacVM.app's Keep This
#                                       Disk; apply says so): only once its
#                                       package switch is done, else exit 3
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
#   download   the new lists and their file lists; the plan for packages
#              newer than Omarchy's snapshot of Arch Linux ARM (split,
#              renamed, merged since: replaced by the snapshot's own); every
#              package of the switch, nothing installed yet
#   commit     one transaction: omarchy + omarchy-settings with the whole
#              system (pacman -Suu: Omarchy's snapshot can be older than
#              Arch Linux ARM), Omarchy's obsidian for obsidian-appimage, the
#              snapshot's packages for the ones it replaces; omarchy-mac-keyring
#              removed; the keep list again. Cut off in here: Undo only
#   platform   Omarchy's own omarchy-hw-platform must say aarch64
#   mpv        OmacVM's mpv defaults again (4.5's omarchy-settings owns the file)
#   vulkan     OmacVM's Venus driver, rebuilt when its libraries went missing
#   kernel     every kernel has its modules, initramfs and DKMS modules; GRUB
#   update     omarchy update (its migrations), as the user (system-update)
#   report     result.json: packages removed, foreign ones, pacman.conf lines
# Every step ends on the disk (sync) before the journal moves on, and GRUB's
# menu is written beside the old one first (/boot is FAT): a VM that loses
# power at any point boots and goes on from its last step.
# Tests: src/tests/omarchy-move.sh (stand-ins), src/tests/omarchy-move-pacman.sh
# (the real pacman on made-up repos: split, rename, merge, file moves).
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
NEED_GB=14   # the switch's downloads and files (a few GB), then omarchy update wants 10 GiB free itself
PACWAIT=${OMACVM_MOVE_PACMAN_WAIT:-120}   # seconds a Resume waits for another pacman with pacman's lock
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

# The move's own unit or run holds the lock (its pacman too: it inherits it).
alive() {
  [[ -e $J/lock ]] || return 1
  ! flock -n "$J/lock" true 2>/dev/null
}
# Another pacman (the user's update, Omarchy's update check, a status
# call's pacman -Q): waited for, up to SECONDS; 1 when one still runs.
pacman_wait() {
  local i
  for ((i = 0; i < ${1:-0}; i++)); do pgrep -x pacman >/dev/null 2>&1 || return 0; sleep 1; done
  ! pgrep -x pacman >/dev/null 2>&1
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
    # On a Resume a short pacman (a status call's) is waited for; one that
    # still runs then is a wait, never a refusal (exit 4: Resume again).
    [[ -n $PF_RESUME ]] && pacman_wait $(( PACWAIT < 10 ? PACWAIT : 10 ))
    if [[ -n $PF_RESUME && -z ${IN_RUN:-} ]] && ! pgrep -x pacman >/dev/null 2>&1; then
      chk pacman 1 "a lock the stopped move left (removed when it goes on)"
    elif pgrep -x pacman >/dev/null 2>&1; then
      chk pacman 0 "pacman runs"
      if [[ -n $PF_RESUME ]]; then refuse pacman-busy 4 "pacman is running in this VM (an update?); Resume when it is done."
      else refuse pacman-busy 3 "pacman is running in this VM (an update?); try again when it is done."; fi
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
  # A Resume after the switch: what is left is omarchy update (its 10 GiB).
  [[ -n $PF_RESUME && -e $J/commit-done ]] && NEED_GB=10
  if (( free >= NEED_GB * 1073741824 )); then chk space 1 "$PF_FREE GB free"
  else chk space 0 "$PF_FREE GB free"; refuse low-space 3 "The VM has $PF_FREE GB free on its disk; the move needs $NEED_GB GB."; fi
  # OmacVM's guest tree of this version (Update VM brings it).
  for f in "$S/system-update" "$S/mkinitcpio-omacvm.conf" "$S/keep-packages.txt" "$S/keep-explicit" "$F/pacman-stable.conf" \
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
      r=$(sed -n "s|^\([a-z]*\) $f\$|\1|p" < <(pacman "$@" --print --print-format '%r %f' 2>/dev/null) | head -1)
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

# OmacVM's packages (keep-packages.txt) and everything they depend on now
# (guest/keep-explicit) marked as installed on purpose: Omarchy 4.5 removes
# orphans on every update.
keep_marked() {
  local have
  have=$(OMACVM_PACMAN_DB=$PACDB "$S/keep-explicit") || { REASON="pacman could not mark OmacVM's packages as installed on purpose"; return 1; }
  [[ -n $have ]] || return 0
  echo "$have" >> "$J/keep-marked.txt"
  say "marked as installed on purpose: $(echo $have)"
}

step_protect() {
  [[ -s $J/pre-packages.txt ]] || pacman -Q > "$J/pre-packages.txt" || return 1
  [[ -s $J/pre-explicit.txt ]] || pacman -Qqe > "$J/pre-explicit.txt" || return 1
  keep_marked
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
  local more=() nd=() x
  targets
  say "the package lists of Omarchy ${PF_TARGET:-4.5} and its snapshot of Arch Linux ARM"
  cmd_pacman -Syy --noconfirm >> "$LOG" 2>&1 || { (( NETFAIL )) && return 4; REASON="pacman could not read the new package lists (see $LOG)"; return 1; }
  # The file lists too (the plan below reads which package carries a file).
  pacman -Fyy --noconfirm >> "$LOG" 2>&1 || say "no file lists from the mirror: the plan goes by package names only"
  plan_replace || return 1
  more=(); while IFS= read -r x; do more+=("$x"); done < <(plan_targets)
  # A package the snapshot replaces can ask for exact versions of others the
  # switch takes back: those checks wait for the switch, where its record is gone.
  [[ -s $J/replace ]] && nd=(-d)
  say "downloading with the whole system: ${TARGETS[*]}${more[*]:+ ${more[*]}} (nothing installed yet)"
  cmd_pacman -Suuw ${nd[@]+"${nd[@]}"} --noconfirm --ask 4 "${TARGETS[@]}" ${more[@]+"${more[@]}"} >> "$LOG" 2>&1 && return 0
  (( NETFAIL )) && return 4
  return 1
}

# ---------- packages the snapshot replaces ----------
# Omarchy's mirror is a snapshot of Arch Linux ARM (2026-10-20 for 4.5.0);
# Arch Linux ARM goes on, and a VM that updated after the snapshot can have
# packages the snapshot does not know: split, renamed or merged since
# (2026-11-06: clang split into clang + clang-libs, so clang-libs owns files
# the snapshot's clang brings back, and pacman refuses the switch). Such a
# package (from a repo, in none of the new ones) whose files, name, base or
# provides a snapshot package carries is replaced by that package in the
# switch: its record leaves pacman's database right before the switch, the
# switch writes those paths (--overwrite, exactly them), and its files that
# no package has afterwards go. Nothing that stays may need it: a package
# built here (AUR) that needs it gets the snapshot's package that provides
# it, else the move stops before any change. Packages built here and ones
# with no counterpart stay (listed in the result).
# Journal: replace ("NAME REASON BY..."), adds (more packages for the switch),
# replaced-db/ (their records, put back if the switch does not start),
# replaced-files/NAME (their paths), overwritten (unowned paths replaced).
PACDB=${OMACVM_PACMAN_DB:-$ROOT/var/lib/pacman}
pkgfield() {   # NAME FIELD: one field of pacman -Qi, continuation lines joined
  pacman -Qi "$1" 2>/dev/null | awk -v f="$2" '
    /^[A-Z]/ { on = (index($0, f " ") == 1 && $0 ~ /^[^:]*: /); if (on) { sub(/^[^:]*: /, ""); print }; next }
    on { sub(/^ +/, ""); print }' | tr -s ' \n' '  ' | sed 's/ *$//'
}
pkgbase() {   # NAME: its pkgbase from pacman's database (pacman -Qi does not show it)
  local v; v=$(pacman -Q "$1" 2>/dev/null | awk '{ print $2 }')
  [[ -n $v ]] && awk '/^%BASE%$/ { getline; print; exit }' "$PACDB/local/$1-$v/desc" 2>/dev/null
}
depname() { local d=${1%%[<>=]*}; echo "${d%%:*}"; }
words() { [[ $1 == None ]] || printf '%s\n' $1; }
satisfies() {   # NAME DEP: NAME is DEP's package or provides it
  local n p; n=$(depname "$2")
  [[ $1 == "$n" ]] && return 0
  for p in $(words "$(pkgfield "$1" Provides)"); do [[ $(depname "$p") == "$n" ]] && return 0; done
  return 1
}
plan_targets() { awk '{ print $1 }' "$J/adds" 2>/dev/null; awk '{ for (i = 3; i <= NF; i++) print $i }' "$J/replace" 2>/dev/null; }
plan_replace() {
  local x r d by meta sync="$J/sync-names"
  rm -rf "$J/replace" "$J/adds" "$J/replaced-files" "$J/replace-files-by" "$J/replace.done" "$J/overwritten" "$J/overwritten-files"
  mkdir -p "$J/replaced-files"; : > "$J/replace"; : > "$J/replace-files-by"
  pacman -Slq 2>/dev/null | sort -u > "$sync"
  [[ -s $sync ]] || { REASON="pacman lists no packages in the new repos (see $LOG)"; return 1; }
  for x in $(pacman -Qqm 2>/dev/null); do
    # Omarchy's obsidian takes obsidian-appimage's place itself (it conflicts).
    [[ $x == obsidian-appimage ]] && continue
    [[ $(pkgfield "$x" "Validated By") == None ]] && continue   # built here (AUR, OmacVM's own): kept
    pacman -Qlq "$x" 2>/dev/null | grep -v '/$' > "$J/replaced-files/$x"
    by=""
    if [[ -s $J/replaced-files/$x ]]; then
      by=$(sed "s|^$ROOT/|/|" "$J/replaced-files/$x" | tr '\n' '\0' | xargs -0 pacman -F --machinereadable -- 2>/dev/null |
           tr '\0' '\t' | awk -F'\t' 'NF >= 2 { print $2 }' | sort -u | grep -vx -- "$x")
    fi
    [[ -n $by ]] && echo "$x" >> "$J/replace-files-by"
    meta=$( { words "$(pkgfield "$x" Replaces)"; words "$(pkgfield "$x" Provides)"; pkgbase "$x"; } |
            while read -r d; do [[ -n $d ]] && depname "$d"; done | sort -u | comm -12 - "$sync" | grep -vx -- "$x")
    by=$(printf '%s\n' $by $meta | sort -u | tr '\n' ' ' | sed 's/ $//')
    [[ -n $by ]] || { rm -f "$J/replaced-files/$x"; continue; }   # no counterpart: stays
    if pacman -Qqe "$x" >/dev/null 2>&1; then r=explicit; else r=dep; fi
    echo "$x $r $by" >> "$J/replace"
  done
  needs_check || return 1
  while read -r x r by; do say "replaced by Omarchy's snapshot in the switch: $x (by $by)"; done < "$J/replace"
  sync
}
# What stays must not need what goes: a package built here that needs one
# gets the snapshot's package that provides it; else one whose files nothing
# in the snapshot carries stays, and one whose files it does stops the move
# before any change.
needs_check() {
  local x r d by sat keep="" blocked=""
  : > "$J/adds"
  while read -r x _; do
    for r in $(words "$(pkgfield "$x" "Required By")"); do
      grep -qx -- "$r" "$J/sync-names" && continue        # switched to the snapshot's own
      grep -q "^$r " "$J/replace" && continue             # replaced too
      for d in $(words "$(pkgfield "$r" "Depends On")"); do
        satisfies "$x" "$d" || continue
        sat=$(pacman -Sddp --print-format '%n' "$d" 2>/dev/null | head -1)
        if [[ -n $sat ]]; then echo "$sat $r" >> "$J/adds"
        elif grep -qx -- "$x" "$J/replace-files-by" 2>/dev/null; then blocked+="${blocked:+, }$x (needed by $r)"
        else keep+=" $x"; fi
      done
    done
  done < "$J/replace"
  if [[ -n $blocked ]]; then
    REASON="Packages newer than Omarchy's snapshot of Arch Linux ARM are needed by packages built in this VM, and the snapshot has nothing in their place: $blocked. Remove those packages, then Resume."
    return 1
  fi
  for x in $keep; do
    awk -v x="$x" '$1 != x' "$J/replace" > "$J/replace.new" && mv -f "$J/replace.new" "$J/replace"
    rm -f "$J/replaced-files/$x"
  done
  return 0
}

# The records of what the snapshot replaces leave pacman's database (their
# files stay until the switch writes the snapshot's), kept in the journal so a
# switch that does not start puts them back.
replaced_out() {
  local x v names=()
  [[ -s $J/replace ]] || return 0
  mkdir -p "$J/replaced-db" || return 1
  while read -r x _; do
    v=$(pacman -Q "$x" 2>/dev/null | awk '{ print $2 }')
    [[ -n $v ]] || continue
    [[ -d $J/replaced-db/$x-$v ]] || cp -a "$PACDB/local/$x-$v" "$J/replaced-db/" || return 1
    names+=("$x")
  done < "$J/replace"
  (( ${#names[@]} )) || return 0
  sync
  OMARCHY_UPDATE_PACMAN=1 pacman -Rdd --dbonly --noconfirm "${names[@]}" >> "$LOG" 2>&1 ||
    { REASON="pacman could not take ${names[*]} out of its database (see $LOG)"; return 1; }
  sync
}
replaced_back() {
  local d
  [[ -d $J/replaced-db ]] || return 0
  for d in "$J"/replaced-db/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    [[ -d $PACDB/local/${d##*/} ]] || cp -a "$d" "$PACDB/local/" || return 1
  done
  rm -rf "$J/replaced-db"; sync
}
globq() { sed 's/[][*?\\]/\\&/g'; }   # a path as a pattern that matches only itself
overwrite_args() {   # -> OW: --overwrite for exactly the paths the switch may write over
  local x p n=0
  OW=(--overwrite /etc/mpv/mpv.conf)
  while read -r x _; do
    while IFS= read -r p; do OW+=(--overwrite "$p"); n=$((n + 1)); done < <(globq < "$J/replaced-files/$x")
  done < <(cat "$J/replace" 2>/dev/null)
  [[ -s $J/overwritten ]] && while IFS= read -r p; do OW+=(--overwrite "$p"); n=$((n + 1)); done < <(globq < "$J/overwritten")
  (( n <= 20000 )) || { REASON="the switch would write over $n files of other packages; OmacVM does not do that many"; return 1; }
}
# pacman's own answer when the plan missed something: a file of a package in
# no new repo (that package is replaced too), or a file no package owns
# (under /usr or /opt: kept in the journal, then replaced). Once.
learn_conflicts() {   # OFFSET into $LOG
  local pkg p o r more=0 bad=""
  while IFS=$'\t' read -r pkg p; do
    o=$(pacman -Qqo "$p" 2>/dev/null | head -1)
    if [[ -n $o ]]; then
      grep -q "^$o " "$J/replace" 2>/dev/null && continue
      if grep -qx -- "$o" "$J/sync-names" || [[ $o == obsidian-appimage || $(pkgfield "$o" "Validated By") == None ]]; then
        bad+="${bad:+, }$p ($o)"; continue
      fi
      if pacman -Qqe "$o" >/dev/null 2>&1; then r=explicit; else r=dep; fi
      pacman -Qlq "$o" 2>/dev/null | grep -v '/$' > "$J/replaced-files/$o"
      echo "$o $r $pkg" >> "$J/replace"; more=1
      say "replaced by Omarchy's snapshot in the switch: $o (by $pkg; pacman's answer)"
    elif [[ ($p == "$ROOT"/usr/* || $p == "$ROOT"/opt/*) && ( -f $p || -L $p ) ]]; then
      grep -qxF -- "$p" "$J/overwritten" 2>/dev/null && continue
      mkdir -p "$J/overwritten-files$(dirname "${p#"$ROOT"}")" &&
        cp -a -- "$p" "$J/overwritten-files${p#"$ROOT"}" && echo "$p" >> "$J/overwritten" && more=1 &&
        say "a file no package owns, in the switch's way: ${p#"$ROOT"} (kept in $J/overwritten-files, then replaced)"
    else
      bad+="${bad:+, }$p"
    fi
  done < <(tail -c +"$1" "$LOG" | sed -n 's|^\([^ :]*\): \(/.*\) exists in filesystem.*|\1\t\2|p' |
           awk -F'\t' -v r="$ROOT" '{ p = $2; if (r != "" && index(p, r "/") == 1) p = substr(p, length(r) + 1); print $1 "\t" r p }' | sort -u)
  [[ -n $bad ]] && { REASON="files of the switch exist in this VM already and OmacVM does not replace them: $bad"; return 1; }
  (( more )) || return 1
  needs_check
}

step_commit() {
  local before after more=() try off x
  targets
  if [[ -e $J/commit-done ]]; then after_switch; return; fi   # cut off after the switch
  if [[ -e $J/commit-started ]]; then
    # Cut off inside the switch (cmd_run lets only these two through).
    case $(switch_cut) in
      cut-done)
        say "the switch was cut off after pacman wrote all of it: its packages again from the cache (their hooks)"
        rm -rf "$J/replaced-db"
        # shellcheck disable=SC2046 # one package per word
        OMARCHY_UPDATE_PACMAN=1 cmd_pacman -S --noconfirm --ask 4 $(awk '{ print $1 }' "$J/commit-plan") >> "$LOG" 2>&1 ||
          { (( NETFAIL )) && return 4; REASON="pacman could not install the switch's packages again (see $LOG)"; return 1; }
        jset commit-done 1; sync
        after_switch; return ;;
      cut-before) say "the switch was cut off before pacman changed anything: it runs again"; rm -f "$J/commit-started"; sync ;;
      *) REASON="The package switch was cut off; Undo puts the VM back as it was before the move."; return 1 ;;
    esac
  fi
  # 4.5's omarchy-settings owns /etc/mpv/mpv.conf (hwdec=auto-safe), which
  # OmacVM wrote before (app/guest/venus/mpv.sh): the package's file replaces
  # it (--overwrite), and the mpv step puts OmacVM's block back into it.
  if [[ -f $ROOT/etc/mpv/mpv.conf && ! -e $ROOT/etc/mpv/mpv.conf.omacvm-40 ]]; then
    cp -p "$ROOT/etc/mpv/mpv.conf" "$ROOT/etc/mpv/mpv.conf.omacvm-40" || return 1
  fi
  # Cut off between taking records out and the switch: nothing switched yet.
  replaced_back || { REASON="the records pacman set aside could not be put back"; return 1; }
  for try in 1 2; do
    more=(); while IFS= read -r x; do more+=("$x"); done < <(plan_targets)
    overwrite_args || return 1
    # pacman's own check of its database before (a cut-off switch is
    # compared with it; the records below are out then).
    pacman -Dk 2>&1 | grep -v '^No database errors' | sort -u > "$J/commit-dk"
    replaced_out || { replaced_back; return 1; }
    # What the switch installs and pacman's database before it: after a
    # cut-off the guest tells a switch that never began from one pacman
    # wrote to the end and from one half done (switch_cut).
    OMARCHY_UPDATE_PACMAN=1 pacman -Suu --print --print-format '%n %v' --noconfirm --ask 4 "${OW[@]}" \
      "${TARGETS[@]}" ${more[@]+"${more[@]}"} 2>/dev/null | grep -E '^[^ :]+ [^ ]+$' > "$J/commit-plan"
    before=$(pacman -Q | sha256sum)
    echo "$before" > "$J/commit-before"
    jset commit-started 1; sync
    say "the switch: ${TARGETS[*]}${more[*]:+ ${more[*]}} with the whole system, from the downloads"
    off=$(( $(wc -c < "$LOG" 2>/dev/null || echo 0) + 1 ))
    # OMARCHY_UPDATE_PACMAN: Omarchy's pacman guard lets an Omarchy update
    # through. --ask 4: yes to "remove the conflicting package" (listed after).
    if OMARCHY_UPDATE_PACMAN=1 cmd_pacman -Suu --noconfirm --ask 4 "${OW[@]}" "${TARGETS[@]}" ${more[@]+"${more[@]}"} >> "$LOG" 2>&1; then
      rm -rf "$J/replaced-db"; jset commit-done 1; sync
      after_switch; return
    fi
    after=$(pacman -Q | sha256sum)
    if [[ $before != "$after" || -e $PACDB/db.lck ]]; then
      REASON="the package switch did not finish (see $LOG)"; return 1
    fi
    # pacman stopped before it changed a package: as before the switch.
    rm -f "$J/commit-started"; replaced_back; sync
    (( NETFAIL )) && { REASON="the switch could not download a package (see $LOG)"; return 4; }
    (( try == 1 )) && learn_conflicts "$off" && continue
    REASON=${REASON:-"pacman refused the switch before it changed anything (see $LOG)"}
    return 1
  done
}

# A switch cut off (the VM lost power, the move was killed) with no pacman
# running now, from pacman's database as it is:
#   cut-before  nothing changed yet (the database as before): the switch runs again
#   cut-done    every package of the switch's plan is installed at its
#               version and pacman's check finds nothing new: pacman wrote
#               it to the end (only its hooks may be missing: Resume
#               installs the same packages again from the cache)
#   half        anything else: Undo only
switch_cut() {
  local now
  now=$(pacman -Q 2>/dev/null | sha256sum)
  if [[ -s $J/commit-before && $now == "$(cat "$J/commit-before")" ]]; then echo cut-before; return; fi
  if [[ -s $J/commit-plan && -z $(comm -23 <(sort -u "$J/commit-plan") <(pacman -Q 2>/dev/null | sort -u)) ]] &&
     [[ -z $(comm -13 <(sort -u "$J/commit-dk" 2>/dev/null) <(pacman -Dk 2>&1 | grep -v '^No database errors' | sort -u)) ]]; then
    echo cut-done; return
  fi
  echo half
}
# The switch now: none (not begun), running, done, or how it was cut off.
# Running is the move's own pacman only (it holds the move's lock); any
# other pacman says nothing about the switch. While one holds pacman's lock
# (it may be writing pacman's database): busy, read again once it is done.
switch_now() {
  [[ -e $J/commit-done ]] && { echo done; return; }
  [[ -e $J/commit-started ]] || { echo none; return; }
  [[ -z ${HOLD:-} && $(jget state) == running ]] && alive && { echo running; return; }
  [[ -e $ROOT/var/lib/pacman/db.lck ]] && pgrep -x pacman >/dev/null 2>&1 && { echo busy; return; }
  switch_cut
}

# After the switch (again after a cut-off): omarchy-mac's keyring out, 4.0's
# factory snapshot out (or a warning), what the replaced packages left that no package has
# now (never in /etc), install reasons, the keep list again (the switch can
# bring new ones as dependencies).
after_switch() {
  local x r by b p
  if pacman -Q omarchy-mac-keyring >/dev/null 2>&1; then
    pacman -Rdd --noconfirm omarchy-mac-keyring >> "$LOG" 2>&1 || say "omarchy-mac-keyring not removed (listed)"
  fi
  factory_out
  if [[ -s $J/replace && ! -e $J/replace.done ]]; then
    pacman -Qlq 2>/dev/null | sort -u > "$J/owned"
    while read -r x r by; do
      sort -u "$J/replaced-files/$x" | comm -23 - "$J/owned" | while IFS= read -r p; do
        [[ $p == "$ROOT"/etc/* ]] && continue
        [[ -f $p || -L $p ]] && rm -f -- "$p"
      done
      for b in $by; do
        grep -q "^$b " "$J/pre-packages.txt" 2>/dev/null && [[ $r != explicit ]] && continue
        pacman -D "--as${r/dep/deps}" "$b" >> "$LOG" 2>&1 || true
      done
    done < "$J/replace"
    while read -r b _; do
      grep -q "^$b " "$J/pre-packages.txt" 2>/dev/null || pacman -D --asdeps "$b" >> "$LOG" 2>&1 || true
    done < <(cat "$J/adds" 2>/dev/null)
    rm -f "$J/owned"; : > "$J/replace.done"
  fi
  keep_marked || return 1
  at45 "$(version)" || { REASON="omarchy is $(version) after the switch"; return 1; }
  sync
}

# omarchy-mac 4.0's factory snapshot (@factory at the top of the btrfs disk,
# from its install and OmacVM's prebuilt images): Omarchy 4.5's Factory Reset
# puts / back to it, which would be omarchy-mac 4.0 on its old repos. It goes
# once the switch is final; Undo brings back the whole disk, @factory with it.
# A new 4.5 VM has none: 4.5's Factory Reset then says so and changes
# nothing. A 4.5 one (not OmacVM's) stays. One that cannot go (the system
# runs from it, a subvolume inside it will not go) stays too, with a warning
# here and in omacvm check: it never stops the move (the switch is done).
# Journal: factory (removed | none | kept | left).
factory_left() {   # WHY
  jset factory left
  local w="omarchy-mac 4.0's factory snapshot (@factory) is still on the disk ($1): Omarchy's Factory Reset would go back to Omarchy 4.0 (see $LOG)"
  grep -qxF -- "$w" "$J/warnings" 2>/dev/null || echo "$w" >> "$J/warnings"
  say "$w"
}
factory_out() {
  local dev top="" m="" v id root def subs s p why=""
  case $(jget factory) in removed|kept) return 0 ;; esac
  if [[ -n ${OMACVM_MOVE_TOPLEVEL:-} ]]; then top=$OMACVM_MOVE_TOPLEVEL   # tests
  else
    dev=$(findmnt -no SOURCE / 2>/dev/null); dev=${dev%%\[*}
    m=$(mktemp -d /run/omacvm-move-top.XXXXXX) || m=""
    if [[ -z $m || ! -b $dev ]] || ! mount -o subvolid=5 "$dev" "$m" 2>>"$LOG"; then
      [[ -z $m ]] || rmdir "$m"
      # Without the top level: whether there is one at all, from / (as omacvm check reads it).
      if s=$(btrfs subvolume list / 2>>"$LOG") && ! sed -n 's/^ID [0-9]* .* path //p' <<<"$s" | sed 's|^<FS_TREE>/||' | grep -qx '@factory'; then
        jset factory none
      else
        factory_left "the top of the disk could not be mounted"
      fi
      sync; return 0
    fi
    top=$m
  fi
  if [[ ! -d $top/@factory ]]; then
    jset factory none
  else
    v=$(ls "$top/@factory/var/lib/pacman/local" 2>/dev/null | sed -n 's/^omarchy-\([0-9][^-]*\)-[^-]*$/\1/p' | head -1)
    if at45 "$v"; then
      say "factory snapshot: Omarchy $v, kept"; jset factory kept
    else
      # Every subvolume of the disk ("ID n ... path p", paths from its top);
      # the ones inside @factory at any depth go first, deepest first.
      s=$(btrfs subvolume list "$top" 2>>"$LOG" | sed -n 's/^ID \([0-9]*\) .* path \(.*\)$/\1 \2/p' | sed 's| <FS_TREE>/| |')
      id=$(awk '$2 == "@factory" { print $1; exit }' <<<"$s")
      subs=$(awk '{ i = $1; sub(/^[0-9]+ /, ""); if (index($0, "@factory/") == 1) print i " " $0 }' <<<"$s")
      root=$(btrfs inspect-internal rootid / 2>/dev/null)
      def=$(btrfs subvolume get-default "$top" 2>/dev/null | sed -n 's/^ID \([0-9]*\) .*/\1/p')
      if [[ -n $root && ( $root == "$id" || $'\n'$subs == *$'\n'"$root "* ) ]]; then
        why="the system runs from it"
      elif [[ -n $def && ( $def == "$id" || $'\n'$subs == *$'\n'"$def "* ) ]]; then
        # The disk's default subvolume (what mounts without subvol=): the
        # one the system runs from now, before @factory can go.
        if [[ $root =~ ^[0-9]+$ ]] && btrfs subvolume set-default "$root" "$top" >> "$LOG" 2>&1; then
          say "the disk's default subvolume: the running system's ($root), not @factory"
        else
          why="it is the disk's default subvolume"
        fi
      fi
      if [[ -z $why ]]; then
        # Subvolumes inside it: in a read-only snapshot none of them could go.
        if [[ -n $subs ]]; then
          btrfs property set -ts "$top/@factory" ro false >> "$LOG" 2>&1 || true
          while IFS= read -r p; do
            [[ -n $p ]] || continue
            btrfs property set -ts "$top/$p" ro false >> "$LOG" 2>&1 || true
            btrfs subvolume delete "$top/$p" >> "$LOG" 2>&1 || say "a subvolume inside @factory did not go: $p"
          done < <(cut -d' ' -f2- <<<"$subs" | awk 'NF { print gsub("/", "/") "\t" $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)
        fi
        if btrfs subvolume delete -c "$top/@factory" >> "$LOG" 2>&1 && [[ ! -d $top/@factory ]]; then
          say "omarchy-mac's factory snapshot (Omarchy ${v:-?}) removed: Omarchy 4.5's Factory Reset cannot go back to 4.0"
          jset factory removed
        else
          why="btrfs did not remove it"
        fi
      fi
      [[ -z $why ]] || factory_left "$why"
    fi
  fi
  [[ -z $m ]] || { umount "$m"; rmdir "$m"; }
  sync
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
  grub_menu >> "$LOG" 2>&1 || { REASON="GRUB's menu did not build (see $LOG)"; return 1; }
  (( bad == 0 )) || say "kernel: see the warnings"
  return 0
}

# GRUB's menu without a moment where a power cut leaves it empty: /boot is
# FAT, and grub-mkconfig rewrites grub.cfg in place. The new menu is written
# beside it, on the disk, then put in its place.
grub_menu() {
  local cfg=$ROOT/boot/grub/grub.cfg
  rm -f "$cfg.omacvm-new"
  grub-mkconfig -o "$cfg.omacvm-new" && [[ -s $cfg.omacvm-new ]] && sync && mv -f "$cfg.omacvm-new" "$cfg" && sync && return 0
  rm -f "$cfg.omacvm-new"; return 1
}

# Omarchy's own words for why its update stopped, from the update's output
# on stdin: the last line before its "Something went wrong during the
# update!", else the last line before the "== omarchy update exit N" line;
# escape sequences (Omarchy's OSC 3008 marks, colours) and other bytes that
# are not printable ASCII out, at most 200 characters, so move-status.json
# stays valid JSON (#742). Nothing when there is no exit line, or N is 128 or
# more (a signal): OmacVM stopped the update (no new output for 10 minutes,
# or 40 minutes up), so its last line is not Omarchy's error.
update_why() {
  local e=$'\033' b=$'\a'
  tr '\t\r' ' \n' | LC_ALL=C sed -E -e "s#${e}\][^${b}${e}]*(${b}|${e}\\\\)?##g" -e "s#${e}\[[0-?]*[ -/]*[@-~]##g" \
      -e "s#${e}[()][0-9A-Za-z]##g" -e 's/[^[:print:]]//g' -e 's/^ +//' -e 's/ +$//' |
    awk '/^== omarchy update exit [0-9]+$/ { x = ($5 + 0 < 128); exit }
         /^Something went wrong during the update!$/ { if (w == "") w = l; next } /^== / { next } NF { l = $0 }
         END { if (x) print (w != "" ? w : l) }' | cut -c1-200 | sed 's/\.$//'
}

step_update() {
  local rc=0 sec u uid started="" log=${OMACVM_SYSTEM_UPDATE_LOG:-/var/log/omacvm-system-update.log} at why
  # Omarchy's migrations talk to the user's systemd (systemctl --user): with
  # nobody logged in (the app moves the VM without a window) the user's
  # manager runs for the update and stops after it; system-update hands its
  # bus to omarchy update.
  u=$(sed -n 's/^OMACVM_USER=//p' "$ROOT/etc/omacvm/env" 2>/dev/null | tail -1)
  [[ -n $u ]] || u=$(getent passwd 1000 | cut -d: -f1)
  uid=$(id -u "$u" 2>/dev/null) || uid=""
  if [[ -n $uid && ! -S $ROOT/run/user/$uid/bus ]]; then
    systemctl start "user@$uid.service" >> "$LOG" 2>&1 && started=1
  fi
  at=$(wc -c 2>/dev/null < "$log") || at=0
  "$S/system-update" >> "$LOG" 2>&1 || rc=$?
  [[ -z $started ]] || systemctl stop "user@$uid.service" >> "$LOG" 2>&1 || true
  # This run's omarchy update (none when system-update stopped before it):
  # its section of the log, from what was added to it now.
  (( $(wc -c 2>/dev/null < "$log" || echo 0) >= at )) || at=0
  sec=$(tail -c +$((at + 1)) "$log" 2>/dev/null | tr -d '\000' |
    awk '/ omarchy update -y \(OmacVM\)$/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }')
  # omarchy update builds AUR packages last (after its migrations and the
  # orphan step): one that does not build on aarch64 is a warning here.
  if (( rc == 1 )); then
    if [[ $sec == *"Update AUR packages"* && $sec == *"omarchy update exit 1"* ]]; then
      echo "omarchy update: AUR packages not updated ($(pacman -Qqm 2>/dev/null | grep -vxE 'linux-aarch64-thp(-headers)?|omacvm-vulkan-virtio' | tr '\n' ' ')): see /var/log/omacvm-system-update.log" >> "$J/warnings"
      return 0
    fi
  fi
  case $rc in
    0) return 0 ;;
    2) REASON="omarchy update ran, but the desktop's graphics would not start (see /var/log/omacvm-system-update.log)" ;;
    *) why=$([[ -z $sec ]] || update_why <<<"$sec")
       if [[ -n $why ]]; then REASON="omarchy update stopped: $why (see /var/log/omacvm-system-update.log)"
       else REASON="omarchy update did not finish (see /var/log/omacvm-system-update.log)"; fi ;;
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
    printf ' "factory_snapshot": %s,\n' "$(js "$(jget factory)")"
    printf ' "vulkan": %s,\n "kernel_thp": %s,\n' \
      "$(js "$(pacman -Qq omacvm-vulkan-virtio vulkan-virtio 2>/dev/null | head -1)")" "$(js "$(jget kernel-thp)")"
    printf ' "single_file_fetches": %s,\n' "$(jlines <<<"$fetched")"
    printf ' "replaced": %s,\n "overwritten": %s,\n' \
      "$(awk '{ b = $3; for (i = 4; i <= NF; i++) b = b " " $i; print $1 " (by " b ")" }' "$J/replace" 2>/dev/null | jlines)" \
      "$(sed "s|^$ROOT/|/|" "$J/overwritten" 2>/dev/null | jlines)"
    printf ' "warnings": %s}\n' "$(jlines <<<"$warn")"
  } > "$J/result.json.new" && mv -f "$J/result.json.new" "$J/result.json"
  [[ -z $removed ]] || say "packages gone in the move: $(echo $removed)"
  [[ -z $foreign ]] || say "in no repo now (kept): $(echo $foreign)"
  [[ -z $warn ]] || say "warnings: $warn"
}

# ---------- run, start, stop, status ----------
finish() {   # STATE CODE REASON EXIT
  jset state "$1"; jset code "$2"; jset reason "$3"; jset finished "$(now)"; sync
  [[ -n $3 ]] && say "$3"
  exit "$4"
}
resumable() {   # 1 unless inside the package switch now, or cut off half way through it
  case $(switch_now) in running|half) echo 0 ;; *) echo 1 ;; esac
}
cmd_run() {
  local i p done_p start=1 rc h
  mkdir -p "$J" || die "could not make $J"
  exec 9>"$J/lock"
  flock -n 9 || { say "a move runs already"; exit 3; }
  HOLD=1
  [[ $(jget state) == done ]] && { say "the move is done (Omarchy $(version))"; exit 0; }
  done_p=$(jget phase-done)
  # A VM reset in the download or the switch leaves pacman's lock. Another
  # pacman with it (the user's update) is waited for, then the lock goes;
  # one that still runs: Resume later (never Undo only for it).
  if [[ -n $done_p && -e $ROOT/var/lib/pacman/db.lck ]]; then
    pacman_wait "$PACWAIT" || finish failed pacman-busy "pacman is running in this VM (an update?); Resume when it is done." 4
    rm -f "$ROOT/var/lib/pacman/db.lck"; say "pacman's lock from the stopped move: removed"
  fi
  if [[ $(resumable) == 0 ]]; then
    finish failed commit "The package switch was cut off; Undo puts the VM back as it was before the move." 1
  fi
  if [[ -n $done_p ]]; then
    # Going on: the journal says this VM was on omarchy-mac when it began.
    # START is 1-based: the step after the last one done (PHASES[i] is step i + 1).
    for i in "${!PHASES[@]}"; do [[ ${PHASES[$i]} == "$done_p" ]] && start=$((i + 2)); done
    say "going on after: $done_p"
    IN_RUN=1 preflight
    if [[ -n $PF_CODE ]]; then finish failed "$PF_CODE" "$PF_REASON" "$PF_EXIT"; fi
  fi
  rm -f "$J/stop"
  # Stopped by its unit (the VM shuts down, systemctl stop): the move stops
  # after the step it is in, as with `stop`. Only this script gets the
  # signal (KillMode=mixed), so pacman is never cut off inside the switch;
  # the unit waits for it (TimeoutStopSec).
  trap ': > "$J/stop"; say "asked to stop: after the step $(jget phase)"' INT TERM
  sync   # what ran before the move (Update VM's GRUB menu, an initramfs) is on the disk first
  jset state running; jset code ""; jset reason ""; jset finished ""; rm -f "$J/kept"
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
      # Tests only (the move's kill rows): a test-hold-STEP file in the
      # journal holds the move here, after the step and before its sync,
      # until test-release-STEP appears (at most 10 minutes), so the VM can
      # be cut off at the worst moment of each step.
      if [[ -e $J/test-hold-$p ]]; then
        : > "$J/test-held-$p"
        for ((h = 0; h < 600; h++)); do [[ -e $J/test-release-$p ]] && break; sleep 1; done
      fi
      # On the disk before the journal moves on: a VM that loses power after
      # this point boots and goes on from here (/boot is FAT: unwritten
      # files there come back empty).
      sync
      if (( rc == 4 )); then
        finish failed network "The download stopped (network); Resume goes on from there." 4
      elif (( rc )); then
        finish failed "$p" "${REASON:-The step '$p' failed (see $LOG).}" 1
      fi
    fi
    jset phase-done "$p"; done_p=$p; sync
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
    -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p KillSignal=SIGINT -p KillMode=mixed -p TimeoutStopSec=900 \
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
  local sw; sw=$(switch_now)
  printf '"commit_started": %s, "switch": %s, "resumable": %s, "started": %s, "finished": %s, "code": %s, "reason": %s, ' \
    "$(jbool "$([[ -e $J/commit-started || -e $J/commit-done ]] && echo 1)")" "$(js "$sw")" \
    "$(jbool "$([[ $sw != running && $sw != half ]] && echo 1)")" "$(js "$(jget started)")" \
    "$(js "$(jget finished)")" "$(js "$(jget code)")" "$(js "$(jget reason)")"
  printf '"omarchy": %s, "lane": %s, "channel": %s, "log": %s, "kept": %s, "result": %s}\n' \
    "$(js "$(version | sed 's/-[^-]*$//')")" "$(js "$(lane)")" "$(js "$(lane_channel)")" "$(js "$LOG")" \
    "$(jbool "$([[ -e $J/kept ]] && echo 1)")" "$res"
}

# A move that began here and whose package switch is not done (stopped,
# failed, cut off before or inside it): the VM is between Omarchy 4.0 and
# 4.5 (4.5's repos and keyring, 4.0's packages, or a switch cut off). A
# package OmacVM installs or removes then (guest/install.sh, system-update,
# pkg-add, the Venus driver) would be a partial update, or turn a cut-off
# switch that Resume can finish into one only Undo can. Only the move's
# Resume (or Undo) goes on from there.
cmd_pending() {
  local st; st=$(jget state)
  [[ -n $st && $st != done && $st != refused && ! -e $J/commit-done ]] || return 1
  echo "the move to Omarchy 4.5 is not finished in this VM (it stopped at '$(jget phase)'): OmacVM changes no packages until Resume finishes it (or Undo)"
}

# The person keeps this disk as a move that stopped left it (OmacVM.app's
# Keep This Disk; apply tells the VM while the Mac's journal says kept or
# done-final). Only once the package switch is done: Omarchy 4.5's packages
# are all in, only steps after the switch did not run, so the move is over
# here (pending no, status "kept", check says so). Before that (not begun,
# cut off, half, busy) the VM is between 4.0 and 4.5: a kept disk there
# would let Update VM, system-update and pkg-add make a partial update.
# Refused (exit 3, says why): Resume finishes the move, or Undo.
cmd_keep() {
  local st sw
  st=$(jget state)
  [[ -n $st && $st != refused && $st != done ]] || { say "no stopped move here: nothing to keep"; return 0; }
  if [[ $st == running ]] && alive; then
    echo "omarchy-move: the move to Omarchy 4.5 runs now: keep this disk once it stopped" >&2; return 3
  fi
  sw=$(switch_now)
  if [[ $sw != done ]]; then
    echo "omarchy-move: the move to Omarchy 4.5 stopped at '$(jget phase)' before its package switch was done ($sw): Resume finishes it, or Undo puts the disk from before back" >&2
    return 3
  fi
  [[ -e $J/kept ]] || { jset kept "$(now)"; sync; }
  say "this disk is kept as the move left it (it stopped at '$(jget phase)', after the package switch)"
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
  pending) cmd_pending ;;
  keep) cmd_keep ;;
  repos) cmd_repos "${2:-}" ;;
  keyring) cmd_keyring ;;
  pacman) shift; cmd_pacman "$@" ;;
  animations) cmd_animations "${2:-}" ;;
  *) echo "usage: omarchy-move.sh preflight [--json] | start | run | stop | status [--json] | record | pending | keep | repos [CHANNEL] | keyring | pacman ARGS... | animations USER" >&2; exit 2 ;;
esac
