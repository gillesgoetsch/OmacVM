#!/bin/bash
# Omarchy 4.5 (src/guest/omarchy-move.sh): the repo files (Omarchy 4.5.0's,
# byte for byte), the preflight's refusals and its JSON, the move's steps
# from its journal (resume, stop, a cut-off package switch, a refusal
# before any change), the rule for a missing file, the keyring, the report,
# status and the record; pkg-add's marking and the keep list; the animations
# marker and the initramfs drop-in. No VM: pacman and the system's tools are
# stand-ins, the VM's files a scratch folder. The real move: a VM row.
#   src/tests/omarchy-move.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
O=$R/src/guest/omarchy-move.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1" 2>&1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect "omarchy-move.sh can be run (mode 755: the guest tree's copy is run as is)" yes "$([[ -x $O ]] && echo yes || echo no)"
expect "the mode in git" 100755 "$(git -C "$R" ls-files -s src/guest/omarchy-move.sh | cut -d' ' -f1)"

# ---------- Omarchy 4.5.0's own files ----------
# omacom/omarchy v4.5.0 default/pacman/aarch64/{pacman-stable.conf,mirrorlist-stable}
# and the key 40DFB630... (keys.openpgp.org), as shipped.
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
expect "pacman-stable.conf is Omarchy 4.5.0's" af4d42a2fb6964416cd1e773ae617b34202728ccb9f06929cfe8fc3d8251b242 "$(sum "$R/src/guest/omarchy-45/pacman-stable.conf")"
expect "mirrorlist-stable is Omarchy 4.5.0's" 1cf7161dfcba3793979d8cc58af3073852243eea10f6fa6c08af9353e6c24a57 "$(sum "$R/src/guest/omarchy-45/mirrorlist-stable")"
expect "the shipped key names Omarchy's fingerprint" 1 "$(grep -c '^Comment: 40DF B630 FF42 BCFF B047  046C F013 4EE6 80CA C571$' "$R/src/guest/omarchy-45/omarchy-key.asc")"
expect "no aarch64-apple, asahi or omarchy-mac lane in them" 0 "$(cat "$R"/src/guest/omarchy-45/*-stable* | grep -ciE 'asahi|aarch64-apple|omarchy-aarch64')"

# ---------- a VM in a folder ----------
# The guest tree: the script and its files, stand-ins for system-update and
# the venus scripts. Tools: stand-ins in $T/bin (and BSD's install/flock
# replaced when the machine has no GNU ones).
TR=$T/tree; GD=$TR/guest; mkdir -p "$GD" "$TR/app/guest/venus"
cp "$O" "$R/src/guest/keep-packages.txt" "$R/src/guest/keep-explicit" "$R/src/guest/mkinitcpio-omacvm.conf" "$GD/"
cp -R "$R/src/guest/omarchy-45" "$GD/"
M=$GD/omarchy-move.sh
B=$T/bin; mkdir -p "$B"
P=$T/pk; mkdir -p "$P"
cat > "$GD/system-update" <<EOF
#!/bin/bash
echo update >> "$P/calls"; [[ -e $P/su-out ]] && cat "$P/su-out" >> "$T/su.log"
[[ -e $P/update-fails ]] && { rm -f "$P/update-fails"; exit 1; }
if [[ -e $P/aur-fails ]]; then
  printf '%s\n' "== 2026-11-06 01:00:00 omarchy update -y (OmacVM)" "Update system packages" "Orphan system packages" \
    "Update AUR packages" "==> ERROR: dotnet-runtime-2.1 is not available for the 'aarch64' architecture." "== omarchy update exit 1" >> "$T/su.log"
  exit 1
fi
exit 0
EOF
printf '#!/bin/bash\necho mpv >> "%s/calls"\n' "$P" > "$TR/app/guest/venus/mpv.sh"
printf '#!/bin/bash\necho "vulkan $*" >> "%s/calls"\n' "$P" > "$TR/app/guest/venus/vulkan-virtio.sh"
# pacman: $P/db "name version e|d"; $P/after the db after the switch; $P/calls.
cat > "$B/pacman" <<'EOF'
#!/bin/bash
db=$P/db
names() { awk '{ print $1 }' "$db"; }
ver() { awk -v n="$1" '$1 == n { print $2 }' "$db"; }
# --print: the switch's plan (name version), or the repo and file of each
# download (the file the 404 case names).
if [[ " $* " == *" --print "* ]]; then
  [[ " $* " == *" %n %v "* ]] && { awk '$1 != "omarchy-mac-keyring" { print $1, $2 }' "$P/after"; exit 0; }
  echo "extra $(cat "$P/fail404" 2>/dev/null)"; exit 0
fi
case $1 in
  -Q) if (( $# == 1 )); then awk '{ print $1, $2 }' "$db"; exit 0; fi
      rc=0; for n in "${@:2}"; do v=$(ver "$n"); [[ -n $v ]] && echo "$n $v" || rc=1; done; exit $rc ;;
  -Qq) if (( $# == 1 )); then names; exit 0; fi
       rc=0; for n in "${@:2}"; do [[ -n $(ver "$n") ]] && echo "$n" || rc=1; done; exit $rc ;;
  -Qqe) awk '$3 == "e" { print $1 }' "$db" ;;
  -Qqd) for n in "${@:2}"; do awk -v n="$n" '$1 == n && $3 == "d" { print $1 }' "$db"; done ;;
  -Qqm) cat "$P/foreign" 2>/dev/null ;;
  -Ql) cat "$P/files-$2" 2>/dev/null ;;
  -Qlq) cat "$P/files-$2" 2>/dev/null | awk '{ print $2 }' ;;
  -Qi) [[ -n $(ver "$2") ]] || exit 1
       echo "Name            : $2"; echo "Provides        : None"; echo "Replaces        : None"
       echo "Required By     : None"; echo "Depends On      : None"
       grep -qx "$2" "$P/foreign" 2>/dev/null && echo "Validated By    : None" || echo "Validated By    : Signature" ;;
  -Slq) awk '{ print $1 }' "$P/after" | grep -vxf "$P/foreign" ;;
  -Fyy) echo "pacman $*" >> "$P/calls" ;;
  -D) echo "pacman $*" >> "$P/calls"; [[ -e $P/stop-on-D ]] && : > "$J/stop"
      for n in "${@:3}"; do awk -v n="$n" '$1 == n { $3 = "e" } { print }' "$db" > "$db.n" && mv "$db.n" "$db"; done ;;
  -Suuw|-Syyuuw) echo "pacman $*" >> "$P/calls"
      if [[ -s $P/fail404 ]]; then
        f=$(cat "$P/fail404")
        [[ -e $CACHE/$f ]] || { echo "error: failed retrieving file '$f' from arm-stable-mirror.omarchy.org : The requested URL returned error: 404"; exit 1; }
      fi
      [[ -e $P/net-down ]] && { echo "error: failed retrieving file 'x.pkg.tar.zst' from pkgs.omarchy.org : Could not resolve host: pkgs.omarchy.org"; exit 1; }
      exit 0 ;;
  -Syy) echo "pacman $*" >> "$P/calls" ;;
  -Suu) echo "pacman $*" >> "$P/calls"
      [[ -e $P/commit-refused ]] && { echo "error: failed to prepare transaction (conflicting dependencies)"; exit 1; }
      [[ -e $P/commit-breaks ]] && { head -2 "$db" > "$db.n"; mv "$db.n" "$db"; exit 1; }
      # The VM cut off (kill -9 of the move) before pacman changed anything,
      # after it wrote the whole switch, or half way (a package's entry gone).
      [[ -e $P/cut-before ]] && { rm -f "$P/cut-before"; kill -9 $PPID; exit 1; }
      [[ -e $P/slow-switch ]] && { echo $PPID > "$P/runpid"; sleep 3; }
      cp "$P/after" "$db"
      [[ -e $P/cut-after ]] && { rm -f "$P/cut-after"; [[ -e $P/dk-new ]] && mv "$P/dk-new" "$P/dk"; kill -9 $PPID; exit 1; }
      [[ -e $P/cut-half ]] && { rm -f "$P/cut-half"; grep -v '^omarchy-settings ' "$db" > "$db.n"; mv "$db.n" "$db"; kill -9 $PPID; exit 1; }
      exit 0 ;;
  -S) echo "pacman $*" >> "$P/calls" ;;
  -Dk) cat "$P/dk" 2>/dev/null || echo "No database errors have been found!" ;;
  -Rdd) echo "pacman $*" >> "$P/calls"; grep -v "^$3 " "$db" > "$db.n"; mv "$db.n" "$db" ;;
  *) echo "pacman stand-in: $*" >&2; exit 1 ;;
esac
EOF
cat > "$B/pacman-key" <<'EOF'
#!/bin/bash
echo "pacman-key $*" >> "$P/calls"
case $1 in --init) mkdir -p "$GNUPG" ;; --lsign-key) : > "$GNUPG/trusted" ;; esac
EOF
# gpg: the shipped key's fingerprint; "trusted" once pacman-key signed it.
cat > "$B/gpg" <<'EOF'
#!/bin/bash
if [[ " $* " == *" --show-keys "* ]]; then echo "fpr:::::::::${FPR:-40DFB630FF42BCFFB047046CF0134EE680CAC571}:"; exit 0; fi
[[ -e $GNUPG/trusted ]] && echo "pub:f:4096:1:F0134EE680CAC571:" || echo "pub:-:4096:1:F0134EE680CAC571:"
EOF
printf '#!/bin/bash\necho "${PLATFORM:-aarch64}"\n' > "$B/omarchy-hw-platform"
cat > "$B/grub-mkconfig" <<'EOF'
#!/bin/bash
echo "grub-mkconfig $*" >> "$P/calls"
[[ $1 == -o ]] || exit 1
if [[ -n ${GRUB_FAIL:-} ]]; then : > "$2"; exit 1; fi
echo "menu 4.5" > "$2"
EOF
# sync: what the journal said when it was called (the phase, the last phase done)
printf '#!/bin/bash\necho "sync $(cat "$J/phase" 2>/dev/null) $(cat "$J/phase-done" 2>/dev/null)" >> "%s/calls"\n' "$P" > "$B/sync"
printf '#!/bin/bash\necho "mkinitcpio $*" >> "%s/calls"\n' "$P" > "$B/mkinitcpio"
printf '#!/bin/bash\necho "${FSTYPE:-btrfs}"\n' > "$B/findmnt"
printf '#!/bin/bash\necho Avail; echo "${AVAIL:-42949672960}"\n' > "$B/df"
printf '#!/bin/bash\n[[ -e "%s/pacman-runs" ]]\n' "$P" > "$B/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$B/dkms"
# btrfs: the disk's top level is the folder $TOP (OMACVM_MOVE_TOPLEVEL).
# Subvolumes: @ (256), @factory (299), and one per line of $TOP/nested
# (300, 301 ...) while its folder is there. list: all of them, or with -o
# only the direct children of one; get-default/set-default: $P/default (a
# path; the top level when none); delete: refused for the default one, for
# one with a subvolume still inside it, and inside a read-only @factory
# ($P/ro-factory until property set ... ro false); rootid: $ROOTID (256).
cat > "$B/btrfs" <<'EOF'
#!/bin/bash
echo "btrfs $*" >> "$P/calls"
subs() {   # ID PATH of every subvolume there now
  [[ -d $TOP/@ ]] && echo "256 @"
  [[ -d $TOP/@factory ]] && echo "299 @factory"
  local n=299 l
  [[ -e $TOP/nested ]] && while IFS= read -r l; do n=$((n + 1)); [[ -d $TOP/$l ]] && echo "$n $l"; done < "$TOP/nested"
}
parent() {   # PATH: the subvolume it is in (the longest one above it), else the top level
  local best="" id p
  while read -r id p; do [[ $1 == "$p"/* && ${#p} -gt ${#best} ]] && best=$p; done < <(subs)
  echo "$best"
}
rel() { local x=${1#"$TOP"}; echo "${x#/}"; }
case "$1 $2" in
  "subvolume list")
    o=""; [[ $3 == -o ]] && o=$(rel "${!#}")
    subs | while read -r id p; do
      [[ -z $o || $(parent "$p") == "$o" ]] || continue
      echo "ID $id gen 9 top level 5 path $p"
    done ;;
  "subvolume get-default")
    d=$(cat "$P/default" 2>/dev/null)
    if [[ -n $d ]]; then subs | awk -v d="$d" '$2 == d { print "ID " $1 " gen 9 top level 5 path " d }'; else echo "ID 5 (FS_TREE)"; fi ;;
  "subvolume set-default")
    subs | awk -v i="$3" '$1 == i { print $2 }' > "$P/default" ;;
  "subvolume delete")
    [[ -e $P/btrfs-fails ]] && exit 1
    t=$(rel "${!#}")
    [[ -n $t && $t == "$(cat "$P/default" 2>/dev/null)" ]] && { echo "ERROR: cannot delete the default subvolume" >&2; exit 1; }
    while read -r id p; do [[ $p == "$t"/* ]] && { echo "ERROR: not empty: $p" >&2; exit 1; }; done < <(subs)
    [[ -e $P/ro-factory && $t == @factory/* ]] && { echo "ERROR: read-only file system" >&2; exit 1; }
    rm -rf "${!#}" ;;
  "property set")
    [[ $(rel "${@: -3:1}") == @factory && ${@: -2:1} == ro && ${!#} == false ]] && rm -f "$P/ro-factory" ;;
  "inspect-internal rootid") echo "${ROOTID:-256}" ;;
esac
EOF
printf '#!/bin/bash\necho "systemctl $*" >> "%s/calls"\n' "$P" > "$B/systemctl"
printf '#!/bin/bash\necho "systemd-run $*" >> "%s/calls"\n' "$P" > "$B/systemd-run"
# curl: Omarchy's db (a tar with omarchy-4.5.0-3/), the mirror, Arch Linux ARM's file.
mkdir -p "$T/dbsrc/omarchy-4.5.0-3" "$T/dbsrc/omarchy-keyring-20251027-1"; echo x > "$T/dbsrc/omarchy-4.5.0-3/desc"
( cd "$T/dbsrc" && tar -cf "$T/omarchy.db" omarchy-4.5.0-3 omarchy-keyring-20251027-1 )
cat > "$B/curl" <<'EOF'
#!/bin/bash
[[ -e $P/offline ]] && exit 6
out=""; url=""
while (( $# )); do case $1 in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift; done
echo "curl $url" >> "$P/calls"
case $url in
  */omarchy.db) [[ -n $out && $out != /dev/null ]] && cp "$DB" "$out" ;;
  */core.db) ;;
  *.pkg.tar.*) [[ -n $out ]] && echo pkg > "$out" ;;
  *) exit 22 ;;
esac
EOF
mkdir -p "$T/compat"
command -v flock >/dev/null || cat > "$T/compat/flock" <<'EOF'
#!/usr/bin/env python3
import fcntl, os, subprocess, sys
a = [x for x in sys.argv[1:] if x != "-n"]
nb = fcntl.LOCK_NB if "-n" in sys.argv else 0
try:
    if a[0].isdigit():
        fcntl.flock(int(a[0]), fcntl.LOCK_EX | nb); sys.exit(0)
    fd = os.open(a[0], os.O_RDWR | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX | nb)
except BlockingIOError:
    sys.exit(1)
sys.exit(subprocess.call(a[1:]) if len(a) > 1 else 0)
EOF
install -D /dev/null "$T/probe" 2>/dev/null || cat > "$T/compat/install" <<'EOF'
#!/bin/bash
m=644; d=0; a=()
while (( $# )); do case $1 in -D) d=1 ;; -Dm*) d=1; m=${1#-Dm} ;; -m) m=$2; shift ;; -m*) m=${1#-m} ;; *) a+=("$1") ;; esac; shift; done
(( d )) && mkdir -p "$(dirname "${a[1]}")"; cp "${a[0]}" "${a[1]}" && chmod "$m" "${a[1]}"
EOF
chmod 755 "$B"/* "$GD/system-update" "$TR/app/guest/venus/"*.sh "$T"/compat/* 2>/dev/null

RT=$T/root
fresh() {   # a 4.0 VM from omarchy-mac: packages, files, journal gone
  rm -rf "$RT" "$T/j" "$T/cache" "$P"/* "$TOP"; mkdir -p "$TOP/@factory/var/lib/pacman/local/omarchy-4.0.3rc4-2" "$TOP/@"
  mkdir -p "$RT/sys/class/dmi/id" "$RT/boot/grub" "$RT/etc/default" \
    "$RT/usr/share/pacman/keyrings" "$RT/var/lib/pacman" "$RT/etc/mpv" "$T/cache" "$T/gnupg"
  echo QEMU > "$RT/sys/class/dmi/id/sys_vendor"; echo "menu 4.0" > "$RT/boot/grub/grub.cfg"; echo 'GRUB_TIMEOUT=2' > "$RT/etc/default/grub"
  : > "$RT/usr/share/pacman/keyrings/archlinuxarm.gpg"; : > "$RT/usr/share/pacman/keyrings/omarchy-mac.gpg"
  echo 'hwdec=auto' > "$RT/etc/mpv/mpv.conf"; echo old > "$T/gnupg/pubring.kbx"
  mkdir -p "$RT/etc/omacvm"; echo "OMACVM_USER=$(id -un)" > "$RT/etc/omacvm/env"
  printf '%s\n' "omarchy 4.0.3rc4-2 e" "omarchy-settings 4.0.3rc4-2 d" "omarchy-mac-keyring 20260914-2 d" \
    "snapper 0.13-1 d" "iwd 3.10-1 d" "jq 1.8.1-1 e" "obsidian-appimage 1.13.7-2 e" "vi 1:070224-6 e" > "$P/db"
  printf '%s\n' "omarchy 4.5.0-3 e" "omarchy-settings 4.5.0-3 d" "omarchy-mac-keyring 20260914-2 d" \
    "snapper 0.13-1 e" "iwd 3.10-1 e" "jq 1.8.1-1 e" "obsidian 1.15.0-1 e" "vi 1:070224-6 e" "gliff 0.4.2-1 d" "libclc 23.1.3-1 d" > "$P/after"
  printf 'vi\n' > "$P/foreign"
  printf '[options]\nColor\nHoldPkg = pacman glibc\nArchitecture = aarch64\nIgnorePkg = mine\n\n[omarchy]\nUsage = Sync\nServer = https://pkgs.omarchy.org/edge/$arch\n\n[omarchy-aarch64]\nSigLevel = Optional TrustAll\nServer = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc\n\n[asahi-alarm]\nInclude = /etc/pacman.d/mirrorlist.asahi-alarm\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[myrepo]\nServer = https://example.invalid/$arch\n' > "$T/pacman.conf"
  printf 'Server = https://de3.mirror.archlinuxarm.org/$arch/$repo\n' > "$T/mirrorlist"
  cp "$T/pacman.conf" "$T/c40"; cp "$T/mirrorlist" "$T/m40"
}
export P DB=$T/omarchy.db J=$T/j CACHE=$T/cache GNUPG=$T/gnupg TOP=$T/top
o() {
  PATH="$B:$T/compat:$PATH" OMACVM_MOVE_ROOT=$RT OMACVM_MOVE_MACHINE=aarch64 OMACVM_PACMAN_CONF=$T/pacman.conf \
    OMACVM_PACMAN_MIRRORS=$T/mirrorlist OMACVM_PACMAN_GNUPG=$GNUPG OMACVM_MOVE_DIR=$J OMACVM_MOVE_LOG=$T/move.log \
    OMACVM_PACMAN_CACHE=$CACHE OMACVM_MOVE_WAIT404=0 OMACVM_SYSTEM_UPDATE_LOG=$T/su.log OMARCHY_PATH=$T/omarchy \
    OMACVM_MOVE_TOPLEVEL=$TOP OMACVM_MOVE_PACMAN_WAIT=${PACWAIT_T:-1} "$M" "$@"
}
calls() { grep -c -e "$1" "$P/calls" 2>/dev/null; }

# ---------- repos, record ----------
fresh
expect "record: a 4.0 VM" "4.0.3rc4 omarchy-mac rc" "$(o record)"
o repos >/dev/null
expect "repos: pacman.conf is Omarchy 4.5.0's stable file" same "$(cmp -s "$T/pacman.conf" "$GD/omarchy-45/pacman-stable.conf" && echo same)"
expect "repos: mirrorlist is Omarchy 4.5.0's stable file (no second mirror)" same "$(cmp -s "$T/mirrorlist" "$GD/omarchy-45/mirrorlist-stable" && echo same)"
expect "repos: the 4.0 files kept" "same same" "$(cmp -s "$T/pacman.conf.omacvm-40" "$T/c40" && echo same) $(cmp -s "$T/mirrorlist.omacvm-40" "$T/m40" && echo same)"
o repos edge >/dev/null
expect "repos edge (tests): edge's servers, the 4.0 copies not overwritten" "https://pkgs.omarchy.org/edge/\$arch https://arm-mirror.omarchy.org/\$arch/\$repo same" \
  "$(sed -n 's/^Server = //p' "$T/pacman.conf") $(sed -n 's/^Server = //p' "$T/mirrorlist") $(cmp -s "$T/pacman.conf.omacvm-40" "$T/c40" && echo same)"
o repos nightly >/dev/null 2>&1; expect "repos: an unknown channel is refused" 1 "$?"
o repos >/dev/null; printf '%s\n' "omarchy 4.5.0-3 e" > "$P/db"
expect "record: after the move" "4.5.0 aarch64 stable" "$(o record)"
: > "$P/db"; expect "record: no omarchy package" none "$(o record)"

# ---------- preflight ----------
pf() { o preflight --json; echo "rc=$?"; }
fresh; out=$(pf)
expect "preflight: a 4.0 VM may move (exit 0)" rc=0 "$(tail -1 <<<"$out")"
expect "preflight JSON: ok, lane, channel, target, free space" "True omarchy-mac rc 4.5.0 40.0 aarch64" \
  "$(sed '$d' <<<"$out" | json '" ".join(str(x) for x in [d["ok"], d["lane"], d["channel"], d["target"]["omarchy"], d["free_gb"], d["platform"]])')"
expect "preflight changes nothing" "same same no" "$(cmp -s "$T/pacman.conf" "$T/c40" && echo same) $(cmp -s "$T/mirrorlist" "$T/m40" && echo same) $([[ -e $J/state ]] && echo yes || echo no)"
refusal() {   # WHAT CODE EXIT SETUP...
  local what=$1 code=$2 rc=$3; shift 3
  fresh; eval "$*"
  out=$(pf)
  expect "preflight refuses: $what" "$code rc=$rc False" "$(sed '$d' <<<"$out" | json 'd["code"]') $(tail -1 <<<"$out") $(sed '$d' <<<"$out" | json 'd["ok"]')"
}
refusal "already on 4.5" already-moved 3 'echo "omarchy 4.5.0-3 e" > "$P/db"'
refusal "no Omarchy" not-omarchy 3 ': > "$P/db"'
refusal "Omarchy 3.x" not-omarchy-40 3 'echo "omarchy 3.2.0-1 e" > "$P/db"'
refusal "not omarchy-mac's" no-omarchy-mac 3 'echo "omarchy 4.0.1-1 e" > "$P/db"; printf "[core]\nInclude = x\n" > "$T/pacman.conf"'
refusal "an Apple device tree (Asahi)" apple-platform 3 'mkdir -p "$RT/proc/device-tree"; printf "apple,j314s\0apple,arm-platform\0" > "$RT/proc/device-tree/compatible"'
refusal "an NVIDIA GB10" platform 3 'mkdir -p "$RT/sys/bus/pci/devices/0000:01:00.0"; echo 0x10de > "$RT/sys/bus/pci/devices/0000:01:00.0/vendor"; echo 0x2e12 > "$RT/sys/bus/pci/devices/0000:01:00.0/device"'
refusal "not QEMU" not-qemu 3 'echo "innotek GmbH" > "$RT/sys/class/dmi/id/sys_vendor"'
refusal "an image record naming Apple" image-target 3 'mkdir -p "$RT/var/lib/omarchy/image"; echo platform=aarch64-apple > "$RT/var/lib/omarchy/image/target"'
refusal "pacman runs" pacman-busy 3 ': > "$RT/var/lib/pacman/db.lck"; : > "$P/pacman-runs"'
refusal "pacman's lock without pacman" pacman-lock 3 ': > "$RT/var/lib/pacman/db.lck"'
refusal "no GRUB" no-grub 3 'rm -f "$RT/boot/grub/grub.cfg"'
refusal "not btrfs" layout 3 'export FSTYPE=ext4'; unset FSTYPE
refusal "less than 14 GB free (omarchy update itself wants 10 GiB)" low-space 3 'export AVAIL=12884901888'; unset AVAIL
refusal "Omarchy's servers do not answer (run again)" repos-unreachable 4 ': > "$P/offline"'
fresh; cp "$T/omarchy.db" "$T/db45"; ( cd "$T/dbsrc" && rm -rf omarchy-4.5.0-3 && mkdir -p omarchy-4.4.9-1 && tar -cf "$T/omarchy.db" omarchy-4.4.9-1 )
out=$(pf); expect "preflight: the repo offers no 4.5 (run again)" "repos-unreachable rc=4" "$(sed '$d' <<<"$out" | json 'd["code"]') $(tail -1 <<<"$out")"
cp "$T/db45" "$T/omarchy.db"
fresh; mv "$GD/keep-packages.txt" "$T/kp"; out=$(pf); mv "$T/kp" "$GD/keep-packages.txt"
expect "preflight: an older guest tree (Update VM first)" "guest-old rc=3" "$(sed '$d' <<<"$out" | json 'd["code"]') $(tail -1 <<<"$out")"
fresh; out=$(pf); expect "preflight JSON lists every check" "omarchy lane platform vm pacman grub layout space guest repos" \
  "$(sed '$d' <<<"$out" | json '" ".join(c["id"] for c in d["checks"])')"

# ---------- the move ----------
fresh; out=$(o run 2>&1); rc=$?
expect "run: a 4.0 VM to 4.5 (exit 0, state done)" "0 done" "$rc $(cat "$J/state")"
res=$(o status --json)
expect "status JSON: done, last phase, result" "done report 13 True" \
  "$(json '" ".join(str(x) for x in [d["state"], d["phase"], d["phase_index"], d["resumable"]])' <<<"$res")"
expect "result: removed omarchy-mac-keyring and obsidian-appimage, obsidian swapped" "['obsidian-appimage', 'omarchy-mac-keyring'] swapped" \
  "$(json 'str(sorted(d["result"]["removed"])) + " " + d["result"]["obsidian"]' <<<"$res")"
expect "result: snapper and iwd marked (keep list; libclc after the switch), foreign vi listed" "iwd libclc snapper | vi" \
  "$(json '" ".join(sorted(d["result"]["keep_marked"])) + " | " + " ".join(d["result"]["foreign"])' <<<"$res")"
expect "result: the user's own pacman.conf lines listed (not carried over)" "IgnorePkg = mine|[myrepo]|Server = https://example.invalid/\$arch" \
  "$(json '"|".join(d["result"]["pacman_conf_lines"])' <<<"$res")"
expect "result: Omarchy 4.5.0, aarch64, stable" "4.5.0 aarch64 stable" "$(json '" ".join([d["result"]["omarchy"], d["result"]["platform"], d["result"]["channel"]])' <<<"$res")"
expect "the switch: one transaction with omarchy, omarchy-settings and obsidian, from the downloads" \
  "pacman -Suu --noconfirm --ask 4 --overwrite /etc/mpv/mpv.conf omarchy omarchy-settings obsidian" "$(grep -- '-Suu ' "$P/calls")"
expect "the lists (and their file lists), the downloads, then the switch, then omarchy-mac-keyring out" "-Syy -Fyy -Suuw -Suu -Rdd" \
  "$(grep -oE -- '-Syy |-Fyy|-Suuw|-Suu |-Rdd' "$P/calls" | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
expect "result: nothing replaced or written over (no package newer than the snapshot)" "[] []" \
  "$(json 'str(d["result"]["replaced"]) + " " + str(d["result"]["overwritten"])' <<<"$res")"
# A cut-off write leaves a file empty (/boot is FAT): a power cut must find the old or the new.
expect "on the disk before the journal moves on: a sync after every step, and after its journal line" \
  "protect initramfs keyring repos download commit platform mpv vulkan kernel update report|preflight protect initramfs keyring repos download commit platform mpv vulkan kernel update report" \
  "$(awk '$1 == "sync" && NF == 3 && $2 != $3 && !s[$2]++ { print $2 }' "$P/calls" | tr '\n' ' ' | sed 's/ $//')|$(awk '$1 == "sync" && NF == 3 && $2 == $3 && !s[$2]++ { print $2 }' "$P/calls" | tr '\n' ' ' | sed 's/ $//')"
expect "GRUB's menu: written beside it, then put in its place" "grub-mkconfig -o $RT/boot/grub/grub.cfg.omacvm-new|menu 4.5|no" \
  "$(grep '^grub-mkconfig' "$P/calls")|$(cat "$RT/boot/grub/grub.cfg")|$([[ -e $RT/boot/grub/grub.cfg.omacvm-new ]] && echo yes || echo no)"
expect "keep list after the switch: libclc, new as a dependency of the switch, marked as installed on purpose" "libclc 23.1.3-1 e" \
  "$(grep '^libclc ' "$P/db")"
expect "keyring: a new one with Arch Linux ARM's keys and Omarchy's, never omarchy-mac's" \
  "pacman-key --populate archlinuxarm|pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571" \
  "$(grep -E -- '--populate|--lsign' "$P/calls" | tr '\n' '|' | sed 's/|$//')"
expect "keyring: the old one kept beside it" old "$(cat "$T/gnupg.omacvm-40/pubring.kbx" 2>/dev/null)"
expect "initramfs drop-in in place before the switch" same "$(cmp -s "$RT/etc/mkinitcpio.conf.d/zz-omacvm.conf" "$GD/mkinitcpio-omacvm.conf" && echo same)"
expect "nobody logged in: the user's systemd runs for omarchy update (its migrations use systemctl --user), stops after" \
  "systemctl start user@$(id -u).service|update|systemctl stop user@$(id -u).service" \
  "$(grep -E '^(systemctl (start|stop) user@|update$)' "$P/calls" | tr '\n' '|' | sed 's/|$//')"
expect "mpv.conf kept, mpv and omarchy update ran, GRUB's menu built" "hwdec=auto 1 1 1" \
  "$(cat "$RT/etc/mpv/mpv.conf.omacvm-40") $(calls '^mpv$') $(calls '^update$') $(calls grub-mkconfig)"
out=$(o run 2>&1); expect "run again: done, nothing again" "0 1" "$? $(calls 'pacman -Suu ')"

# omarchy-mac 4.0's factory snapshot (D14): Omarchy 4.5's Factory Reset would
# put / back to it (4.0 on omarchy-mac's repos). The switch done, it goes.
expect "4.0's @factory removed after the switch (the top level's other subvolumes stay), the result says so" \
  "no yes removed 1" "$([[ -d $TOP/@factory ]] && echo yes || echo no) $([[ -d $TOP/@ ]] && echo yes || echo no) \
$(json 'd["result"]["factory_snapshot"]' <<<"$res") $(calls "btrfs subvolume delete -c $TOP/@factory")"
expect "... after the switch, not before (a refused switch keeps it: Undo is not even needed)" "commit" \
  "$(awk '/^pacman -Suu / { s = 1 } /^btrfs subvolume delete/ && s { print "commit"; exit }' "$P/calls")"
fresh; : > "$P/commit-refused"; o run >/dev/null 2>&1
expect "the switch refused: @factory still there" yes "$([[ -d $TOP/@factory ]] && echo yes || echo no)"
fresh; echo "@factory/var/lib/portables" > "$TOP/nested"; mkdir -p "$TOP/@factory/var/lib/portables"; o run >/dev/null 2>&1
expect "a subvolume inside @factory goes first" "btrfs subvolume delete $TOP/@factory/var/lib/portables|btrfs subvolume delete -c $TOP/@factory|no" \
  "$(grep '^btrfs subvolume delete' "$P/calls" | tr '\n' '|')$([[ -d $TOP/@factory ]] && echo yes || echo no)"
fresh; : > "$P/btrfs-fails"; o run >/dev/null 2>&1; rc=$?
expect "@factory that btrfs does not remove: the move goes on to done, factory left, a warning (never stuck at commit)" \
  "0 done yes left 1" \
  "$rc $(cat "$J/state") $([[ -d $TOP/@factory ]] && echo yes || echo no) $(o status --json | json 'd["result"]["factory_snapshot"]') \
$(o status --json | json 'sum("factory snapshot (@factory) is still on the disk (btrfs did not remove it)" in w for w in d["result"]["warnings"])')"
# Subvolumes inside @factory at any depth (btrfs list -o names only the direct ones), deepest first.
fresh; printf '%s\n' "@factory/var/lib/machines" "@factory/var/lib/machines/box" > "$TOP/nested"
mkdir -p "$TOP/@factory/var/lib/machines/box"; o run >/dev/null 2>&1
expect "a subvolume inside a subvolume inside @factory: the deepest first, then its parent, then @factory" \
  "btrfs subvolume delete $TOP/@factory/var/lib/machines/box|btrfs subvolume delete $TOP/@factory/var/lib/machines|btrfs subvolume delete -c $TOP/@factory|done removed" \
  "$(grep '^btrfs subvolume delete' "$P/calls" | tr '\n' '|')$(cat "$J/state") $(cat "$J/factory")"
fresh; echo "@factory/var/lib/portables" > "$TOP/nested"; mkdir -p "$TOP/@factory/var/lib/portables"; : > "$P/ro-factory"; o run >/dev/null 2>&1
expect "a read-only @factory with a subvolume inside: made writable first, then all of it goes" "no removed" \
  "$([[ -d $TOP/@factory ]] && echo yes || echo no) $(cat "$J/factory")"
fresh; o run >/dev/null 2>&1
expect "no subvolume inside it: @factory stays read-only until it goes (no property change)" 0 "$(calls 'btrfs property set')"
# @factory as the disk's default subvolume: the running system's becomes the default first.
fresh; echo @factory > "$P/default"; o run >/dev/null 2>&1
expect "@factory is the disk's default subvolume: the running system's (256) the default, then @factory goes" "1 @ no removed" \
  "$(calls 'btrfs subvolume set-default 256 ') $(cat "$P/default") $([[ -d $TOP/@factory ]] && echo yes || echo no) $(cat "$J/factory")"
fresh; export ROOTID=299; o run >/dev/null 2>&1; unset ROOTID
expect "the system runs from @factory: kept, left, a warning, the move done" "yes 0 done left 1" \
  "$([[ -d $TOP/@factory ]] && echo yes || echo no) $(calls 'btrfs subvolume delete') $(cat "$J/state") $(cat "$J/factory") \
$(grep -c 'the system runs from it' "$J/warnings")"
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; n=$(calls 'btrfs subvolume delete'); rm -f "$P/update-fails"; o run >/dev/null 2>&1
expect "a Resume after it was removed: not again" "$n done removed" "$(calls 'btrfs subvolume delete') $(cat "$J/state") $(cat "$J/factory")"
fresh; rm -rf "$TOP/@factory"; o run >/dev/null 2>&1
expect "no @factory (a VM not from omarchy-mac's install): none" "done none 0" \
  "$(cat "$J/state") $(o status --json | json 'd["result"]["factory_snapshot"]') $(calls 'btrfs subvolume delete')"
fresh; rm -rf "$TOP/@factory"; mkdir -p "$TOP/@factory/var/lib/pacman/local/omarchy-4.5.0-3"; o run >/dev/null 2>&1
expect "a 4.5 @factory (not omarchy-mac's): kept" "done yes kept kept" "$(cat "$J/state") $([[ -d $TOP/@factory ]] && echo yes || echo no) $(cat "$J/factory") \
$(o status --json | json 'd["result"]["factory_snapshot"]')"

# omacvm check's line for it (guest/check.sh), from the disk's subvolumes and the move's journal.
cblk=$(awk '/# omarchy-mac 4.0.s factory snapshot: the move removes it/ { on = 1 } on { print } on && /^  fi$/ { exit }' "$R/src/guest/check.sh")
ck() { PATH="$B:$PATH" bash -c 'ok() { echo "ok $1: $2"; }; warn() { echo "warn $1: $2"; }; om_v=4.5.0'$'\n'"${cblk//\/var\/lib\/omacvm\/move-4.5/$J}" 2>&1; }
fresh; o run >/dev/null 2>&1
expect "check: removed by the move: ok, nothing to go back to" "ok factory reset: no factory snapshot" "$(ck | cut -d: -f1-2 | cut -d'(' -f1 | sed 's/: Omarchy.*//')"
fresh; : > "$P/btrfs-fails"; o run >/dev/null 2>&1
expect "check: the move could not remove it: a warning naming 4.0 and the move's log" 1 "$(ck | grep -c "^warn factory reset: omarchy-mac 4.0's factory snapshot (@factory) is still there (the move could not remove it, /var/log/omacvm-move-45.log)")"
fresh; rm -rf "$TOP/@factory"; mkdir -p "$TOP/@factory/var/lib/pacman/local/omarchy-4.5.0-3"; o run >/dev/null 2>&1
expect "check: a 4.5 @factory the move kept: ok, not 'from before 4.5'" 1 "$(ck | grep -c '^ok factory reset: a factory snapshot of Omarchy 4.5 (@factory')"
fresh
expect "check: an @factory and no move's word on it: a warning that does not guess its version" 1 "$(ck | grep -c '^warn factory reset: a factory snapshot (@factory) is there: .*may be older than 4.5.0')"

# A move stopped after its switch and kept: check reads it as over (no "Resume or Undo").
mblk=$(awk '/^om_mv=\$\(cat/ { on = 1 } on { print } on && /&& om_mv=kept$/ { exit }' "$R/src/guest/check.sh")
cm() { PATH="$B:$T/compat:$PATH" bash -c "${mblk//\/var\/lib\/omacvm\/move-4.5/$J}"$'\n''echo "$om_mv"' 2>&1; }
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "check: a move that failed after its switch: stopped (Resume or Undo); kept: over" "failed kept" "$(cm) $(o keep >/dev/null 2>&1; cm)"

# A step fails after the switch: Resume goes on there, nothing before it again.
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; rc=$?
expect "omarchy update fails: exit 1, state failed, code update, resumable" "1 failed update True" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
out=$(o preflight --json); rc=$?
expect "preflight on a stopped move (Omarchy is 4.5 now): ok to go on, resume, after kernel" "0 True True kernel" \
  "$rc $(json '" ".join(str(x) for x in [d["ok"], d["resume"], d["phase_done"]])' <<<"$out")"
o run >/dev/null 2>&1; rc=$?
expect "resume: done, the switch and the download not again" "0 done 1 1" "$rc $(cat "$J/state") $(calls 'pacman -Suu ') $(calls 'pacman -Suuw')"
expect "resume: goes on with the step after the last one done (kernel's GRUB menu not again), update again" "1 2" \
  "$(calls grub-mkconfig) $(calls '^update$')"
# Cut off right after the download (the switch done meanwhile would be another case): the switch is next, the
# download's plan (what the snapshot replaces) is not made again.
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; printf 'clang-libs dep clang\n' > "$J/replace"; echo download > "$J/phase-done"
rm -f "$J/commit-started" "$J/commit-done"; o run >/dev/null 2>&1
expect "resume after 'download': the switch next, the plan kept" "1 2 clang-libs dep clang" \
  "$(calls 'pacman -Suuw') $(calls 'pacman -Suu ') $(cat "$J/replace")"

# The keep set follows pacman's database: what OmacVM's packages need now
# (libclc, new as a dependency of the switch, needs zz-libdep: not on the list).
fresh; mkdir -p "$RT/var/lib/pacman/local/libclc-23.1.3-1" "$RT/var/lib/pacman/local/zz-libdep-1-1"
printf '%%NAME%%\nlibclc\n\n%%DEPENDS%%\nzz-libdep>=1\n\n' > "$RT/var/lib/pacman/local/libclc-23.1.3-1/desc"
printf '%%NAME%%\nzz-libdep\n\n' > "$RT/var/lib/pacman/local/zz-libdep-1-1/desc"
echo "zz-libdep 1-1 d" >> "$P/after"; o run >/dev/null 2>&1
expect "the move: the keep list's packages and what they need marked after the switch (libclc's zz-libdep too)" "e e" \
  "$(awk '$1 == "libclc" || $1 == "zz-libdep" { print $3 }' "$P/db" | tr '\n' ' ' | sed 's/ $//')"

# omarchy update stops at an AUR package that does not build on aarch64 (after its migrations): a warning.
fresh; : > "$P/aur-fails"; o run >/dev/null 2>&1; rc=$?
expect "omarchy update fails only in its AUR step: done, with a warning" "0 done 1" \
  "$rc $(cat "$J/state") $(o status --json | json 'sum("AUR packages not updated" in w for w in d["result"]["warnings"])')"
rm -f "$P/aur-fails" "$T/su.log"

# omarchy update stops on its own error (#742): Omarchy's line in the reason, the status still JSON. The
# output as the unit logs it: OSC 3008 marks (made-up values), colours, a charset switch, a NUL, a tab.
E=$'\033' BL=$'\a'
reason() { o status --json | json 'd["reason"]'; }
{ echo "== 2026-11-08 09:14:05 omarchy update -y (OmacVM)"
  printf '%s]3008;start=00aa;user=test;type=session%s\\\000%s]3008;end=00aa%s\\\n' "$E" "$E" "$E" "$E"
  printf 'Prune package cache\n==>%s(B finished: 3 packages removed%s(B\nCreate system snapshot\n'  "$E" "$E"
  printf '%s]3008;end=00bb%sOMARCHY_PATH does not match\tthis Omarchy command.\xc3\xa9\n\n' "$E" "$BL"
  printf '%s[0;31mSomething went wrong during the update!\n\nPlease review the output above carefully.%s[0m\n' "$E" "$E"
  echo "OMARCHY_PATH does not match this Omarchy command."; echo "== omarchy update exit 1"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1; rc=$?
expect "omarchy update stops on Omarchy's own error: failed, the reason is Omarchy's line (escapes out), JSON valid" \
  "1 omarchy update stopped: OMARCHY_PATH does not match this Omarchy command (see /var/log/omacvm-system-update.log)" \
  "$rc $(reason)"
expect "... the journal's reason has no control bytes" 0 "$(LC_ALL=C grep -c '[^[:print:]]' "$J/reason")"
# No "Something went wrong" (stopped another way): its last line, never OmacVM's "== ... exit" line; cut at 200.
{ echo "== 2026-11-08 09:20:00 omarchy update -y (OmacVM)"; printf 'error: failed to synchronize all databases (%s[1mtimeout%s[0m)\n\n' "$E" "$E"
  echo "== omarchy update exit 1"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... no 'Something went wrong': the last line" \
  "omarchy update stopped: error: failed to synchronize all databases (timeout) (see /var/log/omacvm-system-update.log)" "$(reason)"
{ echo "== 2026-11-08 09:21:00 omarchy update -y (OmacVM)"; printf 'x%.0s' $(seq 1 300); echo; echo "== omarchy update exit 1"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... a long line: 200 characters of it" 200 "$(reason | sed -e 's/^omarchy update stopped: //' -e 's/ (see .*//' | tr -d '\n' | wc -c | tr -d ' ')"
# What comes after the exit line (keep-explicit's stderr) is not the update's.
{ echo "== 2026-11-08 09:21:30 omarchy update -y (OmacVM)"; echo "error: target not found: foo"; echo "== omarchy update exit 1"
  echo "error: keep-explicit could not mark omacvm-vulkan-virtio"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... a line after the exit line: not read" \
  "omarchy update stopped: error: target not found: foo (see /var/log/omacvm-system-update.log)" "$(reason)"
# OmacVM stopped the update (10 minutes without output, or its 40 are up): no exit line, or a signal's
# 128+N. Its last line (pacman's progress, even an Omarchy line printed while it stops) is not why.
{ echo "== 2026-11-08 09:22:00 omarchy update -y (OmacVM)"; echo "(213/340) upgrading linux-firmware [###---] 45%"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... stopped by OmacVM, no exit line: the old text" \
  "omarchy update did not finish (see /var/log/omacvm-system-update.log)" "$(reason)"
{ echo "== 2026-11-08 09:23:00 omarchy update -y (OmacVM)"; echo "(213/340) upgrading linux-firmware"
  echo "Something went wrong during the update!"; echo "== omarchy update exit 130"; } > "$T/su-out"
fresh; mv "$T/su-out" "$P/su-out"; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... stopped by OmacVM, exit 130 (SIGINT): the old text" \
  "omarchy update did not finish (see /var/log/omacvm-system-update.log)" "$(reason)"
# system-update stopped before omarchy update (nothing new in its log): an older run's words are not this one's.
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "... nothing new in the log (an older failed run there): today's text" \
  "omarchy update did not finish (see /var/log/omacvm-system-update.log)" "$(reason)"
rm -f "$T/su.log"

# Cut off inside the switch (the VM lost power, the move was killed): the
# guest's own word, from pacman's database as it is.
st() { o status --json | json '" ".join(str(x) for x in [d["state"], d["switch"], d["resumable"]])'; }
fresh; : > "$P/cut-half"; o run >/dev/null 2>&1
expect "cut off half way through the switch: interrupted, half, Undo only" "interrupted half False" "$(st)"
o run >/dev/null 2>&1; rc=$?
expect "... run: refused (exit 1), Undo only" "1 failed commit False" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
expect "start: refused too (exit 3), no unit" "3 0" "$(o start >/dev/null 2>&1; echo $?) $(calls systemd-run)"
expect "preflight then: undo-only (exit 3)" "undo-only 3" "$(o preflight --json | json 'd["code"]') $(o preflight >/dev/null 2>&1; echo $?)"
fresh; echo "error: missing 'x' dependency for 'y'" > "$P/dk-new"; : > "$P/cut-after"; o run >/dev/null 2>&1
expect "cut off after pacman wrote the switch, but pacman's check finds a new problem: half, Undo only" "interrupted half False" "$(st)"
fresh; : > "$P/cut-after"; o run >/dev/null 2>&1
expect "cut off after pacman wrote the whole switch (every planned package, its check clean): resumable" "interrupted cut-done True" "$(st)"
expect "... preflight: ok to go on (resume)" "True True download" "$(o preflight --json | json '" ".join(str(x) for x in [d["ok"], d["resume"], d["phase_done"]])')"
o run >/dev/null 2>&1; rc=$?
expect "... Resume: done; the switch's packages again from the cache (hooks), the switch itself not again" \
  "0 done 1 1 pacman -S --noconfirm --ask 4 omarchy omarchy-settings snapper iwd jq obsidian vi gliff libclc" \
  "$rc $(cat "$J/state") $(calls 'pacman -Suu ') $(calls 'pacman -S ') $(grep '^pacman -S ' "$P/calls")"
expect "... then as a move that was not cut: omarchy-mac-keyring out, keep list marked, report" "0 e done" \
  "$(grep -c '^omarchy-mac-keyring ' "$P/db") $(awk '$1 == "libclc" { print $3 }' "$P/db") $(o status --json | json 'd["state"]')"
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1
expect "cut off before pacman changed anything: resumable" "interrupted cut-before True" "$(st)"
o run >/dev/null 2>&1; rc=$?
expect "... Resume: the switch runs again, done" "0 done 2 0" "$rc $(cat "$J/state") $(calls 'pacman -Suu ') $(calls 'pacman -S ')"
# Another pacman (the user's, Omarchy's update check, a status call's
# pacman -Q) says nothing about a cut-off switch: never Undo only for it.
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1; : > "$P/pacman-runs"
expect "cut off before pacman began, another pacman runs (no lock): cut-before, resumable" "interrupted cut-before True" "$(st)"
o run >/dev/null 2>&1; rc=$?
expect "... Resume while it runs: the switch again, done (not 'failed commit')" "0 done 2" "$rc $(cat "$J/state") $(calls 'pacman -Suu ')"
rm -f "$P/pacman-runs"
fresh; : > "$P/cut-after"; o run >/dev/null 2>&1; : > "$P/pacman-runs"
expect "cut off after pacman wrote it, another pacman runs: cut-done, resumable" "interrupted cut-done True" "$(st)"
rm -f "$P/pacman-runs"
fresh; : > "$P/cut-half"; o run >/dev/null 2>&1; : > "$P/pacman-runs"
expect "cut off half way, another pacman runs: half all the same (pacman's database decides)" "interrupted half False" "$(st)"
rm -f "$P/pacman-runs"
# Another pacman holds pacman's lock (it may be writing the database): busy,
# resumable; the cut is read once it is done.
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1; : > "$RT/var/lib/pacman/db.lck"; : > "$P/pacman-runs"
expect "cut off, another pacman holds pacman's lock: busy, resumable" "interrupted busy True" "$(st)"
expect "... preflight and start on that Resume: pacman-busy, run again (exit 4), never undo-only" "pacman-busy 4 4 0" \
  "$(o preflight --json | json 'd["code"]') $(o preflight >/dev/null 2>&1; echo $?) $(o start >/dev/null 2>&1; echo $?) $(calls systemd-run)"
o run >/dev/null 2>&1; rc=$?
expect "... run: waits for it, then stops: exit 4, failed pacman-busy, resumable, its lock kept, nothing switched again" \
  "4 failed pacman-busy True yes 1" \
  "$rc $(cat "$J/state") $(cat "$J/code") $(o status --json | json 'd["resumable"]') $([[ -e $RT/var/lib/pacman/db.lck ]] && echo yes) $(calls 'pacman -Suu ')"
rm -f "$P/pacman-runs"; o run >/dev/null 2>&1; rc=$?
expect "... once it is done: the lock goes, the switch again, done" "0 done no 2" \
  "$rc $(cat "$J/state") $([[ -e $RT/var/lib/pacman/db.lck ]] && echo yes || echo no) $(calls 'pacman -Suu ')"

# pending: a move began here and its switch is not done. Update VM
# (guest/install.sh), system-update, pkg-add and the Venus build change no
# package then (src/tests/pkg-safe.sh runs the last ones).
pend() { o pending >/dev/null 2>&1; echo $?; }
fresh; expect "pending: no move here" 1 "$(pend)"
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1
expect "pending: cut off before the switch began (and says why)" "0 1" "$(pend) $(o pending | grep -c 'not finished in this VM (it stopped at .commit.)')"
fresh; : > "$P/cut-after"; o run >/dev/null 2>&1; expect "pending: cut off after pacman wrote it (hooks not run)" 0 "$(pend)"
fresh; : > "$P/net-down"; o run >/dev/null 2>&1; expect "pending: stopped in the download (4.5's repos, 4.0's packages)" 0 "$(pend)"
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; expect "pending: no, failed after the switch (Update VM sets up the 4.5 system)" 1 "$(pend)"
fresh; o run >/dev/null 2>&1; expect "pending: no, done" 1 "$(pend)"
fresh; echo "omarchy 4.5.0-3 e" > "$P/db"; o run >/dev/null 2>&1; expect "pending: no, refused (nothing changed)" 1 "$(pend)"
# guest/install.sh, the Update VM of a Resume: nothing of it while pending.
gblk=$(awk '/^# The move stopped before its package switch was done/ { on = 1 } on { print } on && /^fi$/ { exit }' "$R/src/guest/install.sh")
gi() { OMACVM_MOVE_DIR=$J bash -c "R='$TR'"$'\n'"$gblk"$'\n''echo goes-on' 2>&1; echo "rc=$?"; }
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1; out=$(OMACVM_MOVE_RUN=1 gi)
expect "guest/install.sh of the move's own apply on a cut-off switch: stops at once (exit 0), says why, nothing after it runs" "rc=0 1 0" \
  "$(tail -1 <<<"$out") $(grep -c '^OmacVM: the move to Omarchy 4.5 is not finished' <<<"$out") $(grep -c goes-on <<<"$out")"
out=$(gi)
expect "guest/install.sh of any other apply there: fails (exit 5: apply records nothing), says why, nothing after it runs" "rc=5 1 1 0" \
  "$(tail -1 <<<"$out") $(grep -c '^OmacVM: the move to Omarchy 4.5 is not finished' <<<"$out") $(grep -c '^guest/install.sh: nothing was set up: .*Resume or Undo' <<<"$out") $(grep -c goes-on <<<"$out")"
fresh; o run >/dev/null 2>&1; expect "guest/install.sh after a move: goes on" "goes-on rc=0" "$(gi | tr '\n' ' ' | sed 's/ $//')"
# apply's call of it: OMACVM_MOVE_RUN=1 only from the move's own apply (move-vm.sh).
ablk=$(awk '/^guest_install\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' "$R/src/cmd/apply.sh")
ga() { bash -c 'gssh() { echo "$2"; }; feature_index() { echo 0; }; FN=(); TYPE=app U=u KB=k MODE= GI_ARGS= NAMED=0'$'\n'"$ablk"$'\n''guest_install' 2>&1; }
expect "apply: the move's own apply tells guest/install.sh so (OMACVM_MOVE_RUN=1), any other does not" "1 0" \
  "$(OMACVM_MOVE_RUN=1 ga | grep -c '^OMACVM_MOVE_RUN=1 /usr/local/share/omacvm/guest/install.sh --user ') $(ga | grep -c OMACVM_MOVE_RUN)"

# keep: the person keeps the disk a stopped move left (OmacVM.app's Keep
# This Disk, told by apply). Only once the switch is done: then the move is
# over here (not pending, status kept, Update VM goes on). On a switch not
# done the VM is between 4.0 and 4.5: refused, still pending, Update VM fails
# (never a silent exit 0 that apply records as installed).
kp() { o keep >/dev/null 2>&1; echo "$? $(pend) $([[ -e $J/kept ]] && echo kept || echo -) $(gi | tail -1)"; }
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1
expect "keep after a cut-off before the switch: refused (3), still pending, Update VM fails (5)" "3 0 - rc=5" "$(kp)"
expect "... and says why" 1 "$(o keep 2>&1 | grep -c "stopped at 'commit' before its package switch was done (cut-before): Resume finishes it, or Undo")"
fresh; : > "$P/cut-half"; o run >/dev/null 2>&1
expect "keep after a switch cut half way: refused, still pending, Update VM fails" "3 0 - rc=5" "$(kp)"
fresh; : > "$P/cut-after"; o run >/dev/null 2>&1
expect "keep after a switch cut off once written (hooks not run): refused, still pending" "3 0 - rc=5" "$(kp)"
fresh; : > "$P/net-down"; o run >/dev/null 2>&1
expect "keep after a stop in the download (switch not begun): refused, still pending" "3 0 - rc=5" "$(kp)"
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1
expect "keep after a failure after the switch: kept, not pending, Update VM goes on" "0 1 kept goes-on" \
  "$(o keep >/dev/null 2>&1; echo "$? $(pend) $([[ -e $J/kept ]] && echo kept || echo -) $(gi | grep -c goes-on | sed 's/^1$/goes-on/')")"
expect "... status says kept; keep again: still 0" "True failed 0" \
  "$(o status --json | json '" ".join(str(x) for x in [d["kept"], d["state"]])') $(o keep >/dev/null 2>&1; echo $?)"
o run >/dev/null 2>&1
expect "... a Resume after it goes on to done, and the kept mark goes" "done False" "$(cat "$J/state") $(o status --json | json 'd["kept"]')"
fresh; expect "keep with no move here: nothing to keep (0), nothing written" "0 no" "$(o keep >/dev/null 2>&1; echo $?) $([[ -e $J/kept ]] && echo yes || echo no)"
fresh; o run >/dev/null 2>&1; expect "keep after a finished move: nothing to keep (0)" "0 no" "$(o keep >/dev/null 2>&1; echo $?) $([[ -e $J/kept ]] && echo yes || echo no)"
fresh; : > "$P/cut-before"; o run >/dev/null 2>&1; echo running > "$J/state"
( PATH="$B:$T/compat:$PATH"; exec 9>"$J/lock"; flock 9; sleep 3 ) & hp=$!; sleep 0.5
expect "keep while the move runs: refused (3), says so" "3 1" "$(o keep >/dev/null 2>&1; echo $?) $(o keep 2>&1 | grep -c 'runs now')"
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
gl=$(grep -n '^# The move stopped before its package switch was done' "$R/src/guest/install.sh" | cut -d: -f1)
expect "guest/install.sh: that check comes before anything that changes a package or pacman's lock" "0 yes" \
  "$(head -n "${gl:-0}" "$R/src/guest/install.sh" | grep -v '^[[:space:]]*#' | grep -cE 'pkg-add|gbm-guard|pacman |db\.lck|makepkg') \
$( (( ${gl:-99999} < $(grep -n 'rm -f /var/lib/pacman/db.lck' "$R/src/guest/install.sh" | head -1 | cut -d: -f1) )) && echo yes)"
expect "the Venus driver's build checks it too (before it builds)" 1 \
  "$(awk '/omarchy-move.sh" pending/ { p = NR } /building Mesa.s vulkan-virtio/ && p { print 1; exit }' "$R/src/app/guest/venus/vulkan-virtio.sh")"

# Stopped by its unit inside the switch (the VM shuts down): only the move
# gets the signal (KillMode=mixed); pacman ends the switch, the move stops after it.
# (Job control on: a background job of a script would ignore SIGINT.)
fresh; : > "$P/slow-switch"; set -m; ( o run >/dev/null 2>&1; echo $? > "$T/rc" ) & set +m
for _ in $(seq 1 50); do [[ -s $P/runpid ]] && break; sleep 0.1; done
kill -INT "$(cat "$P/runpid")"; wait
expect "SIGINT to the move inside the switch: the switch ends, then stopped (exit 4), resumable" "4 stopped commit done True" \
  "$(cat "$T/rc") $(cat "$J/state") $(cat "$J/phase-done") $(o status --json | json '" ".join(str(x) for x in [d["switch"], d["resumable"]])')"
expect "... pacman's database is the switch's (omarchy-mac-keyring out after it)" same \
  "$(diff <(awk '{ print $1, $2 }' "$P/db") <(awk '$1 != "omarchy-mac-keyring" { print $1, $2 }' "$P/after") >/dev/null && echo same)"
rm -f "$P/slow-switch"; o run >/dev/null 2>&1
expect "... Resume: done" "0 done" "$? $(cat "$J/state")"

# pacman refuses the switch before it changes anything: Resume is fine.
fresh; : > "$P/commit-refused"; o run >/dev/null 2>&1; rc=$?
expect "the switch refused before any change: exit 1, resumable, commit-started gone" "1 failed commit True no" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])') $([[ -e $J/commit-started ]] && echo yes || echo no)"
fresh; : > "$P/commit-breaks"; o run >/dev/null 2>&1
expect "the switch broke off half way: Undo only" "failed False" "$(o status --json | json '" ".join(str(x) for x in [d["state"], d["resumable"]])')"

# Network down in the download: run again (exit 4), then Resume.
fresh; o preflight >/dev/null; : > "$P/net-down"
out=$(o run 2>&1); rc=$?
expect "network down in the download: exit 4, failed, code network, resumable" "4 failed network True" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
rm -f "$P/net-down"; : > "$RT/var/lib/pacman/db.lck"
expect "preflight after a VM reset in the download (pacman's lock left): ok to go on" "True" "$(o preflight --json | json 'd["ok"]')"
o run >/dev/null 2>&1; expect "resume after the network: done, the lock removed" "0 done no" "$? $(cat "$J/state") $([[ -e $RT/var/lib/pacman/db.lck ]] && echo yes || echo no)"

# Tests' hold (the kill rows): after the step, before its sync, until released.
fresh; mkdir -p "$J"; : > "$J/test-hold-repos"
( o run >/dev/null 2>&1 ) & hp=$!
for _ in $(seq 1 50); do [[ -e $J/test-held-repos ]] && break; sleep 0.2; done
expect "a test hold: the move waits after the step, before the journal says it is done" "yes repos keyring" \
  "$([[ -e $J/test-held-repos ]] && echo yes || echo no) $(cat "$J/phase") $(cat "$J/phase-done")"
: > "$J/test-release-repos"; wait $hp
expect "... released: done" "0 done" "$? $(cat "$J/state")"

# Stop: after the current step.
fresh; : > "$P/stop-on-D"; o run >/dev/null 2>&1; rc=$?
expect "stop asked in the protect step: stopped after it (exit 4)" "4 stopped protect" "$rc $(cat "$J/state") $(cat "$J/phase-done")"
rm -f "$P/stop-on-D"; o run >/dev/null 2>&1; expect "resume after a stop: done" "0 done" "$? $(cat "$J/state")"

# A refusal inside run: nothing changed, state refused.
fresh; echo "omarchy 4.5.0-3 e" > "$P/db"; o run >/dev/null 2>&1; rc=$?
expect "run on a 4.5 VM: refused (exit 3), the repo files untouched" "3 refused already-moved same" \
  "$rc $(cat "$J/state") $(cat "$J/code") $(cmp -s "$T/pacman.conf" "$T/c40" && echo same)"

# The rule for a missing file: lists again, one more try, then that one file.
fresh; echo luajit-2.1.1765228720-1-aarch64.pkg.tar.xz > "$P/fail404"
o run >/dev/null 2>&1; rc=$?
expect "404 twice: that file from Arch Linux ARM, then done" "0 1 luajit-2.1.1765228720-1-aarch64.pkg.tar.xz" \
  "$rc $(calls 'curl https://de3.mirror.archlinuxarm.org/aarch64/extra/luajit-2.1.1765228720-1-aarch64.pkg.tar.xz$') $(o status --json | json '" ".join(d["result"]["single_file_fetches"])')"
expect "... after the lists again (-Syy: the download's, then once more)" 2 "$(calls 'pacman -Syy --noconfirm')"
expect "... and the repo files name no second mirror" same "$(cmp -s "$T/mirrorlist" "$GD/omarchy-45/mirrorlist-stable" && echo same)"

# A Resume after the switch: what is left is omarchy update (its own 10 GiB).
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; rm -f "$P/update-fails"
expect "a Resume after the switch with 12 GB free: ok (10 needed); before the switch 14" "True 10 | low-space 14" \
  "$(AVAIL=12884901888 o preflight --json | json '" ".join(str(x) for x in [d["ok"], d["need_gb"]])') | $(fresh; AVAIL=12884901888 o preflight --json | json '" ".join(str(x) for x in [d["code"], d["need_gb"]])')"

# Platform: Omarchy's own answer after the switch must be aarch64.
fresh; export PLATFORM=aarch64-apple; o run >/dev/null 2>&1; rc=$?; unset PLATFORM
expect "omarchy-hw-platform says aarch64-apple after the switch: failed, before omarchy update" "1 platform 0" "$rc $(cat "$J/code") $(calls update)"

# GRUB's menu cut off half written (a power cut; /boot is FAT): the old menu stays.
fresh; GRUB_FAIL=1 o run >/dev/null 2>&1; rc=$?
expect "GRUB's menu not written to the end: the kernel step fails, the old menu is still there" "1 kernel menu 4.0" \
  "$rc $(cat "$J/code") $(cat "$RT/boot/grub/grub.cfg")"

# The shipped key must be Omarchy's.
fresh; export FPR=0000000000000000000000000000000000000000; o run >/dev/null 2>&1; rc=$?; unset FPR
expect "a key copy with another fingerprint: the keyring step fails, nothing switched" "1 keyring 0" "$rc $(cat "$J/code") $(calls 'pacman -Suu ')"

# status
fresh; expect "status: no move" none "$(o status --json | json 'd["state"]')"
mkdir -p "$J"; echo running > "$J/state"; echo download > "$J/phase"; : > "$J/lock"
expect "status: running in the journal, nobody holds the lock: interrupted, resumable" "interrupted download True" \
  "$(o status --json | json '" ".join(str(x) for x in [d["state"], d["phase"], d["resumable"]])')"
fresh; o start >/dev/null 2>&1
expect "start: the move in its own unit" 1 "$(calls 'systemd-run --quiet --collect --unit=omacvm-move-45')"
expect "... a stop of it signals the move only (pacman finishes the switch), waits up to 15 minutes" 1 \
  "$(calls 'systemd-run .*-p KillSignal=SIGINT -p KillMode=mixed -p TimeoutStopSec=900')"

# ---------- pkg-add marks OmacVM's packages; the keep list ----------
K=$T/pkgadd; mkdir -p "$K"
cat > "$K/pacman" <<'EOF'
#!/bin/bash
case $1 in -Qqd) for n in "${@:2}"; do [[ $n == snapper ]] && echo snapper; done ;; -D) echo "pacman $*" >> "$KC" ;; -T) exit 0 ;; esac
EOF
chmod 755 "$K/pacman"; export KC=$K/calls
PATH="$K:$PATH" "$R/src/guest/pkg-add" snapper jq; PATH="$K:$PATH" "$R/src/guest/pkg-add" --asdeps snapper
expect "pkg-add: a package there as a dependency is marked as installed on purpose (not with --asdeps)" \
  "pacman -D --asexplicit snapper" "$(cat "$KC")"
missing=""
# Code lines only (comments say "pkg-add installs nothing ...").
for w in $(git -C "$R" grep -hE '(pkg-add"?|PKG_ADD"?) [a-z0-9]' -- 'src/**' ':!src/tests/**' \
             ':!**/*.md' ':!**/*.py' ':!src/guest/pkg-add' | grep -vE '^\s*#' |
           grep -oE '(pkg-add"?|PKG_ADD"?) [a-z0-9][a-z0-9 ._+-]*' | sed -E 's/^(pkg-add"?|PKG_ADD"?) //'); do
  [[ $w =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || continue
  grep -qx "$w" "$R/src/guest/keep-packages.txt" || missing+=" $w"
done
expect "every package OmacVM's guest asks pkg-add for is in keep-packages.txt" "" "$missing"
expect "the keep list has snapper, iwd and OmacVM's Venus driver" 3 "$(grep -cxE 'snapper|iwd|omacvm-vulkan-virtio' "$R/src/guest/keep-packages.txt")"

# ---------- keep-explicit: the keep list and all it needs, from pacman's database ----------
KD=$T/kdb; KE=$GD/keep-explicit
desc() {   # NAME DEPENDS PROVIDES
  mkdir -p "$KD/local/$1-1-1"
  { printf '%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n' "$1"
    [[ -z $2 ]] || { echo '%DEPENDS%'; printf '%s\n' $2; echo; }
    [[ -z $3 ]] || { echo '%PROVIDES%'; printf '%s\n' $3; echo; }; } > "$KD/local/$1-1-1/desc"
}
rm -rf "$KD"; fresh; : > "$P/calls"
# opencl-mesa is OmacVM's (keep list), clang too; what they need is not on the list.
desc opencl-mesa "clang libclc>=19 spirv-llvm-translator sh" ""
desc clang "llvm-libs=23.1 compiler-rt" ""
desc libclc "" ""; desc spirv-llvm-translator "spirv-tools" ""; desc spirv-tools "" ""
desc llvm-libs "zlib libffi.so=8-64" ""; desc zlib "" ""; desc libffi "" "libffi.so=8-64"
desc compiler-rt "" ""; desc bash "" "sh"; desc zsh "" "sh"; desc firefox "nss" ""; desc nss "" ""
printf '%s\n' "opencl-mesa 1-1 e" "clang 1-1 d" "libclc 1-1 d" "spirv-llvm-translator 1-1 d" "spirv-tools 1-1 d" \
  "llvm-libs 1-1 d" "zlib 1-1 d" "libffi 1-1 d" "compiler-rt 1-1 d" "bash 1-1 e" "zsh 1-1 d" "firefox 1-1 e" "nss 1-1 d" > "$P/db"
k() { PATH="$B:$T/compat:$PATH" OMACVM_PACMAN_DB=$KD "$KE" "$@"; }
expect "keep set: the keep list's installed packages and everything they need (by name or what provides it), nothing else" \
  "bash clang compiler-rt libclc libffi llvm-libs opencl-mesa spirv-llvm-translator spirv-tools zlib zsh" "$(k --list | tr '\n' ' ' | sed 's/ $//')"
expect "--list changes nothing" 0 "$(calls 'pacman -D')"
expect "keep-explicit: marks the ones installed as dependencies, prints them" \
  "clang compiler-rt libclc libffi llvm-libs spirv-llvm-translator spirv-tools zlib zsh" "$(k | tr '\n' ' ' | sed 's/ $//')"
expect "... in pacman's database (firefox's nss untouched)" "e e e d" \
  "$(awk '$1 == "libclc" || $1 == "zlib" || $1 == "spirv-tools" || $1 == "nss" { print $3 }' "$P/db" | tr '\n' ' ' | sed 's/ $//')"
expect "... again: nothing left to mark" "" "$(k)"
expect "guest/install.sh marks it at its end on Omarchy 4.5 (new VMs, prebuilt, moved, Update VM)" 1 \
  "$(grep -c '"$R/guest/keep-explicit" >/dev/null' "$R/src/guest/install.sh")"
expect "guest/system-update marks it before and after omarchy update (its orphan step)" 2 \
  "$(grep -c '^keep$' "$R/src/guest/system-update")"
expect "keep-explicit can be run (mode 755 in git)" 100755 "$(git -C "$R" ls-files -s src/guest/keep-explicit | cut -d' ' -f1)"

# ---------- animations: Omarchy's VM flags go once ----------
printf '#!/bin/sh\necho "$2:x:%s:%s::%s/home:/bin/bash"\n' "$(id -u)" "$(id -g)" "$T" > "$B/getent"
printf '#!/bin/sh\nshift 2; [ "$1" = -- ] && shift\nexec "$@"\n' > "$B/runuser"   # runuser -u USER -- CMD
chmod 755 "$B/getent" "$B/runuser"
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
# /boot is FAT: a VM stopped right after Update VM (the move starts then) must find the old or the new menu.
expect "guest/install.sh: GRUB's menu beside the old one, synced, renamed; everything synced at its end" "0 1 1 1" \
  "$(grep -c 'grub-mkconfig -o /boot/grub/grub.cfg ' "$R/src/guest/install.sh") $(grep -c 'grub-mkconfig -o /boot/grub/grub.cfg.omacvm-new' "$R/src/guest/install.sh") $(grep -c 'sync && mv -f /boot/grub/grub.cfg.omacvm-new /boot/grub/grub.cfg' "$R/src/guest/install.sh") $(grep -B1 'log "OmacVM guest side installed for' "$R/src/guest/install.sh" | grep -c '^sync ')"
exit $fail
