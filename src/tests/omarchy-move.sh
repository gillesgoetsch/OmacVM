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
cp "$O" "$R/src/guest/keep-packages.txt" "$R/src/guest/mkinitcpio-omacvm.conf" "$GD/"
cp -R "$R/src/guest/omarchy-45" "$GD/"
M=$GD/omarchy-move.sh
B=$T/bin; mkdir -p "$B"
P=$T/pk; mkdir -p "$P"
cat > "$GD/system-update" <<EOF
#!/bin/bash
echo update >> "$P/calls"; [[ -e $P/update-fails ]] && { rm -f "$P/update-fails"; exit 1; }; exit 0
EOF
printf '#!/bin/bash\necho mpv >> "%s/calls"\n' "$P" > "$TR/app/guest/venus/mpv.sh"
printf '#!/bin/bash\necho "vulkan $*" >> "%s/calls"\n' "$P" > "$TR/app/guest/venus/vulkan-virtio.sh"
# pacman: $P/db "name version e|d"; $P/after the db after the switch; $P/calls.
cat > "$B/pacman" <<'EOF'
#!/bin/bash
db=$P/db
names() { awk '{ print $1 }' "$db"; }
ver() { awk -v n="$1" '$1 == n { print $2 }' "$db"; }
case $1 in
  -Q) if (( $# == 1 )); then awk '{ print $1, $2 }' "$db"; exit 0; fi
      rc=0; for n in "${@:2}"; do v=$(ver "$n"); [[ -n $v ]] && echo "$n $v" || rc=1; done; exit $rc ;;
  -Qq) if (( $# == 1 )); then names; exit 0; fi
       rc=0; for n in "${@:2}"; do [[ -n $(ver "$n") ]] && echo "$n" || rc=1; done; exit $rc ;;
  -Qqe) awk '$3 == "e" { print $1 }' "$db" ;;
  -Qqd) for n in "${@:2}"; do awk -v n="$n" '$1 == n && $3 == "d" { print $1 }' "$db"; done ;;
  -Qqm) cat "$P/foreign" 2>/dev/null ;;
  -Ql) cat "$P/files-$2" 2>/dev/null ;;
  -D) echo "pacman $*" >> "$P/calls"; [[ -e $P/stop-on-D ]] && : > "$J/stop"
      for n in "${@:3}"; do awk -v n="$n" '$1 == n { $3 = "e" } { print }' "$db" > "$db.n" && mv "$db.n" "$db"; done ;;
  -Syyuuw|-Syyuu) echo "pacman $*" >> "$P/calls"
      if [[ -s $P/fail404 ]]; then
        f=$(cat "$P/fail404")
        [[ -e $CACHE/$f ]] || { echo "error: failed retrieving file '$f' from arm-stable-mirror.omarchy.org : The requested URL returned error: 404"; exit 1; }
      fi
      [[ -e $P/net-down ]] && { echo "error: failed retrieving file 'x.pkg.tar.zst' from pkgs.omarchy.org : Could not resolve host: pkgs.omarchy.org"; exit 1; }
      exit 0 ;;
  -Syy) echo "pacman $*" >> "$P/calls" ;;
  -Suup) echo "extra $(cat "$P/fail404" 2>/dev/null)" ;;
  -Suu) echo "pacman $*" >> "$P/calls"
      [[ -e $P/commit-refused ]] && { echo "error: failed to prepare transaction (conflicting dependencies)"; exit 1; }
      [[ -e $P/commit-breaks ]] && { head -2 "$db" > "$db.n"; mv "$db.n" "$db"; exit 1; }
      cp "$P/after" "$db" ;;
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
printf '#!/bin/bash\necho "grub-mkconfig" >> "%s/calls"\n' "$P" > "$B/grub-mkconfig"
printf '#!/bin/bash\necho "mkinitcpio $*" >> "%s/calls"\n' "$P" > "$B/mkinitcpio"
printf '#!/bin/bash\necho "${FSTYPE:-btrfs}"\n' > "$B/findmnt"
printf '#!/bin/bash\necho Avail; echo "${AVAIL:-42949672960}"\n' > "$B/df"
printf '#!/bin/bash\n[[ -e "%s/pacman-runs" ]]\n' "$P" > "$B/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$B/dkms"
printf '#!/bin/bash\nexit 0\n' > "$B/systemctl"
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
  rm -rf "$RT" "$T/j" "$T/cache" "$P"/*; mkdir -p "$RT/sys/class/dmi/id" "$RT/boot/grub" "$RT/etc/default" \
    "$RT/usr/share/pacman/keyrings" "$RT/var/lib/pacman" "$RT/etc/mpv" "$T/cache" "$T/gnupg"
  echo QEMU > "$RT/sys/class/dmi/id/sys_vendor"; : > "$RT/boot/grub/grub.cfg"; echo 'GRUB_TIMEOUT=2' > "$RT/etc/default/grub"
  : > "$RT/usr/share/pacman/keyrings/archlinuxarm.gpg"; : > "$RT/usr/share/pacman/keyrings/omarchy-mac.gpg"
  echo 'hwdec=auto' > "$RT/etc/mpv/mpv.conf"; echo old > "$T/gnupg/pubring.kbx"
  printf '%s\n' "omarchy 4.0.3rc4-2 e" "omarchy-settings 4.0.3rc4-2 d" "omarchy-mac-keyring 20260914-2 d" \
    "snapper 0.13-1 d" "iwd 3.10-1 d" "jq 1.8.1-1 e" "obsidian-appimage 1.13.7-2 e" "vi 1:070224-6 e" > "$P/db"
  printf '%s\n' "omarchy 4.5.0-3 e" "omarchy-settings 4.5.0-3 d" "omarchy-mac-keyring 20260914-2 d" \
    "snapper 0.13-1 e" "iwd 3.10-1 e" "jq 1.8.1-1 e" "obsidian 1.15.0-1 e" "vi 1:070224-6 e" "gliff 0.4.2-1 d" > "$P/after"
  printf 'vi\n' > "$P/foreign"
  printf '[options]\nColor\nHoldPkg = pacman glibc\nArchitecture = aarch64\nIgnorePkg = mine\n\n[omarchy]\nUsage = Sync\nServer = https://pkgs.omarchy.org/edge/$arch\n\n[omarchy-aarch64]\nSigLevel = Optional TrustAll\nServer = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc\n\n[asahi-alarm]\nInclude = /etc/pacman.d/mirrorlist.asahi-alarm\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[myrepo]\nServer = https://example.invalid/$arch\n' > "$T/pacman.conf"
  printf 'Server = https://de3.mirror.archlinuxarm.org/$arch/$repo\n' > "$T/mirrorlist"
  cp "$T/pacman.conf" "$T/c40"; cp "$T/mirrorlist" "$T/m40"
}
export P DB=$T/omarchy.db J=$T/j CACHE=$T/cache GNUPG=$T/gnupg
o() {
  PATH="$B:$T/compat:$PATH" OMACVM_MOVE_ROOT=$RT OMACVM_MOVE_MACHINE=aarch64 OMACVM_PACMAN_CONF=$T/pacman.conf \
    OMACVM_PACMAN_MIRRORS=$T/mirrorlist OMACVM_PACMAN_GNUPG=$GNUPG OMACVM_MOVE_DIR=$J OMACVM_MOVE_LOG=$T/move.log \
    OMACVM_PACMAN_CACHE=$CACHE OMACVM_MOVE_WAIT404=0 OMARCHY_PATH=$T/omarchy "$M" "$@"
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
refusal "not QEMU" not-qemu 3 'echo "Parallels International GmbH." > "$RT/sys/class/dmi/id/sys_vendor"'
refusal "an image record naming Apple" image-target 3 'mkdir -p "$RT/var/lib/omarchy/image"; echo platform=aarch64-apple > "$RT/var/lib/omarchy/image/target"'
refusal "pacman runs" pacman-busy 3 ': > "$RT/var/lib/pacman/db.lck"; : > "$P/pacman-runs"'
refusal "pacman's lock without pacman" pacman-lock 3 ': > "$RT/var/lib/pacman/db.lck"'
refusal "no GRUB" no-grub 3 'rm -f "$RT/boot/grub/grub.cfg"'
refusal "not btrfs" layout 3 'export FSTYPE=ext4'; unset FSTYPE
refusal "less than 8 GB free" low-space 3 'export AVAIL=4294967296'; unset AVAIL
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
expect "result: snapper and iwd marked (keep list), foreign vi listed" "iwd snapper | vi" \
  "$(json '" ".join(sorted(d["result"]["keep_marked"])) + " | " + " ".join(d["result"]["foreign"])' <<<"$res")"
expect "result: the user's own pacman.conf lines listed (not carried over)" "IgnorePkg = mine|[myrepo]|Server = https://example.invalid/\$arch" \
  "$(json '"|".join(d["result"]["pacman_conf_lines"])' <<<"$res")"
expect "result: Omarchy 4.5.0, aarch64, stable" "4.5.0 aarch64 stable" "$(json '" ".join([d["result"]["omarchy"], d["result"]["platform"], d["result"]["channel"]])' <<<"$res")"
expect "the switch: one transaction with omarchy, omarchy-settings and obsidian, from the downloads" \
  "pacman -Suu --noconfirm --ask 4 --overwrite /etc/mpv/mpv.conf omarchy omarchy-settings obsidian" "$(grep -- '-Suu ' "$P/calls")"
expect "downloads first, then the switch, then omarchy-mac-keyring out" "-Syyuuw -Suu -Rdd" \
  "$(grep -oE -- '-Syyuuw|-Suu |-Rdd' "$P/calls" | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
expect "keyring: a new one with Arch Linux ARM's keys and Omarchy's, never omarchy-mac's" \
  "pacman-key --populate archlinuxarm|pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571" \
  "$(grep -E -- '--populate|--lsign' "$P/calls" | tr '\n' '|' | sed 's/|$//')"
expect "keyring: the old one kept beside it" old "$(cat "$T/gnupg.omacvm-40/pubring.kbx" 2>/dev/null)"
expect "initramfs drop-in in place before the switch" same "$(cmp -s "$RT/etc/mkinitcpio.conf.d/zz-omacvm.conf" "$GD/mkinitcpio-omacvm.conf" && echo same)"
expect "mpv.conf kept, mpv and omarchy update ran, GRUB's menu built" "hwdec=auto 1 1 1" \
  "$(cat "$RT/etc/mpv/mpv.conf.omacvm-40") $(calls '^mpv$') $(calls '^update$') $(calls grub-mkconfig)"
out=$(o run 2>&1); expect "run again: done, nothing again" "0 1" "$? $(calls 'pacman -Suu ')"

# A step fails after the switch: Resume goes on there, nothing before it again.
fresh; : > "$P/update-fails"; o run >/dev/null 2>&1; rc=$?
expect "omarchy update fails: exit 1, state failed, code update, resumable" "1 failed update True" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
out=$(o preflight --json); rc=$?
expect "preflight on a stopped move (Omarchy is 4.5 now): ok to go on, resume, after kernel" "0 True True kernel" \
  "$rc $(json '" ".join(str(x) for x in [d["ok"], d["resume"], d["phase_done"]])' <<<"$out")"
o run >/dev/null 2>&1; rc=$?
expect "resume: done, the switch and the download not again" "0 done 1 1" "$rc $(cat "$J/state") $(calls 'pacman -Suu ') $(calls 'pacman -Syyuuw')"

# Cut off inside the switch: Undo only.
fresh; o run >/dev/null 2>&1; rm -f "$J/commit-done" "$J/state"; echo download > "$J/phase-done"; : > "$J/commit-started"
o run >/dev/null 2>&1; rc=$?
expect "cut off inside the switch: refused (exit 1), Undo only" "1 failed commit False" \
  "$rc $(o status --json | json '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
expect "start: refused too (exit 3), no unit" "3 0" "$(o start >/dev/null 2>&1; echo $?) $(calls systemd-run)"
expect "preflight then: undo-only (exit 3)" "undo-only 3" "$(o preflight --json | json 'd["code"]') $(o preflight >/dev/null 2>&1; echo $?)"

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
expect "... after the lists again (-Syy) once" 1 "$(calls 'pacman -Syy --noconfirm')"
expect "... and the repo files name no second mirror" same "$(cmp -s "$T/mirrorlist" "$GD/omarchy-45/mirrorlist-stable" && echo same)"

# Platform: Omarchy's own answer after the switch must be aarch64.
fresh; export PLATFORM=aarch64-apple; o run >/dev/null 2>&1; rc=$?; unset PLATFORM
expect "omarchy-hw-platform says aarch64-apple after the switch: failed, before omarchy update" "1 platform 0" "$rc $(cat "$J/code") $(calls update)"

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
# Code lines only (comments say "pkg-add installs nothing ..."); Parallels,
# UTM and Fusion keep omarchy-mac 4.0.
for w in $(git -C "$R" grep -hE '(pkg-add"?|PKG_ADD"?) [a-z0-9]' -- 'src/**' ':!src/tests/**' ':!src/fusion/**' ':!src/utm/**' \
             ':!**/*.md' ':!**/*.py' ':!src/guest/pkg-add' | grep -vE '^\s*#' |
           grep -oE '(pkg-add"?|PKG_ADD"?) [a-z0-9][a-z0-9 ._+-]*' | sed -E 's/^(pkg-add"?|PKG_ADD"?) //'); do
  [[ $w =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || continue
  grep -qx "$w" "$R/src/guest/keep-packages.txt" || missing+=" $w"
done
expect "every package OmacVM's guest asks pkg-add for is in keep-packages.txt" "" "$missing"
expect "the keep list has snapper, iwd and OmacVM's Venus driver" 3 "$(grep -cxE 'snapper|iwd|omacvm-vulkan-virtio' "$R/src/guest/keep-packages.txt")"

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
exit $fail
