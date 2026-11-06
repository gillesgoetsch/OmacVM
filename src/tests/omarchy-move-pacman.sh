#!/bin/bash
# The move's package switch with the real pacman (src/guest/omarchy-move.sh).
# Arch Linux ARM goes on after Omarchy's snapshot of it, so a VM that updated
# later can have packages the snapshot does not know (2026-11-06: clang split
# into clang + clang-libs, and pacman refused the switch). Small made-up repos
# model it: "live" is the VM's Arch Linux ARM and omarchy-mac 4.0, "snap" is
# Omarchy 4.5 and its snapshot. Each case is a fresh root moved by
# omarchy-move.sh run: pacman is the real one (on that root, its own
# database, cache and config), the rest are stand-ins. Cases: a split, a
# rename, a merge, a file moved between packages, a new package with no
# counterpart, a package built in the VM that needs a split-off one (with and
# without a snapshot package that provides it), a file no package owns, and
# a move cut off between taking a record out and the switch.
# Needs pacman, repo-add and bsdtar (CI's guest job installs Debian's
# pacman-package-manager); skipped without them. As root, or under fakeroot.
#   src/tests/omarchy-move-pacman.sh
set -uo pipefail
export LC_ALL=C
R=$(cd "$(dirname "$0")/../.." && pwd)
REAL=$(command -v pacman 2>/dev/null)
for t in pacman repo-add bsdtar; do
  command -v $t >/dev/null || { echo "skip: no $t here (CI's guest job and the VM have it)"; exit 0; }
done
if (( EUID != 0 )); then
  command -v fakeroot >/dev/null || { echo "skip: not root and no fakeroot"; exit 0; }
  exec fakeroot -- "$0" "$@"
fi
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1" 2>&1; }
T=$(mktemp -d); trap '[[ -n ${OMACVM_TEST_KEEP:-} ]] && echo "kept $T" || rm -rf "$T"' EXIT
export T

# ---------- packages and repos ----------
# mkpkg REPO NAME VER [depends=a,b provides=.. conflicts=.. replaces=.. base=..] -- PATH...
# Each file says which package and version wrote it.
mkpkg() {
  local repo=$1 name=$2 ver=$3 w=$T/w/$2-$3 k v f; shift 3
  rm -rf "$w"; mkdir -p "$w" "$(dirname "$repo")"
  { echo "pkgname = $name"; echo "pkgver = $ver"; echo "pkgdesc = $name"; echo "url = https://example.invalid"
    echo "builddate = 1762400000"; echo "packager = Test <t@example.invalid>"; echo "size = 1"; echo "arch = any"
    echo "license = MIT"; } > "$w/.PKGINFO"
  local base=$name
  while (( $# )) && [[ $1 != -- ]]; do
    k=${1%%=*} v=${1#*=}
    if [[ $k == base ]]; then base=$v
    else
      case $k in depends) k=depend ;; conflicts) k=conflict ;; esac   # .PKGINFO's names (provides, replaces as they are)
      for f in ${v//,/ }; do echo "$k = $f" >> "$w/.PKGINFO"; done
    fi
    shift
  done
  echo "pkgbase = $base" >> "$w/.PKGINFO"
  shift
  for f in "$@"; do mkdir -p "$w/$(dirname "$f")"; echo "$name $ver $f" > "$w/$f"; done
  ( cd "$w" && bsdtar -czf .MTREE --format=mtree --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' .PKGINFO "$@" &&
    bsdtar -czf "$repo-$name-$ver-any.pkg.tar.gz" .PKGINFO .MTREE "$@" ) || { echo "mkpkg $name failed"; exit 1; }
}
# REPODIR: the repo's db from its packages (name = the folder's)
mkrepo() { local d=$1; ( cd "$d" && repo-add -q "${d##*/}.db.tar.gz" ./*.pkg.tar.gz >/dev/null 2>&1 ); }

# ---------- a VM root, the script's tree and stand-ins ----------
TR=$T/tree; GD=$TR/guest; mkdir -p "$GD" "$TR/app/guest/venus"
cp "$R/src/guest/omarchy-move.sh" "$R/src/guest/keep-packages.txt" "$R/src/guest/mkinitcpio-omacvm.conf" "$GD/"
cp -R "$R/src/guest/omarchy-45" "$GD/"
printf '#!/bin/bash\nexit 0\n' > "$GD/system-update"
printf '#!/bin/bash\nexit 0\n' > "$TR/app/guest/venus/mpv.sh"
B=$T/bin; mkdir -p "$B"
# pacman on the case's root; the 4.0 repos until the move writes Omarchy 4.5's
# files, then the snapshot's (the move's own pacman.conf names the real servers).
cat > "$B/pacman" <<EOF
#!/bin/bash
c=$T/live.conf
grep -q 'pkgs.omarchy.org/stable/' "\$OMACVM_PACMAN_CONF" 2>/dev/null && c=$T/snap.conf
"$REAL" --config "\$c" --root "\$RT" --dbpath "\$RT/var/lib/pacman" --cachedir "$T/cache" --gpgdir "$T/pgp" \\
  --hookdir "$T/hooks" --logfile "$T/pacman.log" "\$@"
rc=\$?
# Cut off right after the records were taken out (the next step is the switch).
if [[ -e $T/kill-after-dbonly && " \$* " == *" --dbonly "* && \$rc == 0 ]]; then rm -f "$T/kill-after-dbonly"; kill -9 \$PPID; fi
exit \$rc
EOF
cat > "$B/pacman-key" <<'EOF'
#!/bin/bash
case $1 in --init) mkdir -p "$GNUPG" ;; --lsign-key) : > "$GNUPG/trusted" ;; esac
EOF
cat > "$B/gpg" <<'EOF'
#!/bin/bash
if [[ " $* " == *" --show-keys "* ]]; then echo "fpr:::::::::40DFB630FF42BCFFB047046CF0134EE680CAC571:"; exit 0; fi
[[ -e $GNUPG/trusted ]] && echo "pub:f:4096:1:F0134EE680CAC571:" || echo "pub:-:4096:1:F0134EE680CAC571:"
EOF
printf '#!/bin/bash\necho aarch64\n' > "$B/omarchy-hw-platform"
printf '#!/bin/bash\nfor ((i = 1; i <= $#; i++)); do [[ ${!i} == -o ]] && { j=$((i + 1)); echo menu > "${!j}"; }; done\nexit 0\n' > "$B/grub-mkconfig"
printf '#!/bin/bash\nexit 0\n' > "$B/mkinitcpio"
printf '#!/bin/bash\necho btrfs\n' > "$B/findmnt"
printf '#!/bin/bash\necho Avail; echo 42949672960\n' > "$B/df"
printf '#!/bin/bash\nexit 1\n' > "$B/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$B/systemctl"
printf '#!/bin/bash\nexit 0\n' > "$B/dkms"
cat > "$B/curl" <<EOF
#!/bin/bash
out=""; url=""
while (( \$# )); do case \$1 in -o) out=\$2; shift ;; http*) url=\$1 ;; esac; shift; done
case \$url in
  */omarchy.db) [[ -n \$out && \$out != /dev/null ]] && cp "$T/snap/omarchy/omarchy.db.tar.gz" "\$out" ;;
  */core.db) ;;
  *) exit 22 ;;
esac
EOF
chmod 755 "$B"/* "$GD/system-update" "$TR/app/guest/venus/mpv.sh"
mkdir -p "$T/hooks" "$T/cache" "$T/pgp"
for side in live snap; do
  printf '[options]\nArchitecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\nNoProgressBar\n' > "$T/$side.conf"
done
printf '\n[omarchy-aarch64]\nServer = file://%s/live/omarchy-aarch64\n[core]\nServer = file://%s/live/core\n' "$T" "$T" >> "$T/live.conf"
printf '\n[omarchy]\nServer = file://%s/snap/omarchy\n[core]\nServer = file://%s/snap/core\n' "$T" "$T" >> "$T/snap.conf"

export GNUPG=$T/gnupg
o() {
  PATH="$B:$PATH" OMACVM_MOVE_ROOT=$RT OMACVM_MOVE_MACHINE=aarch64 OMACVM_PACMAN_CONF=$RT/etc/pacman.conf \
    OMACVM_PACMAN_MIRRORS=$RT/etc/pacman.d/mirrorlist OMACVM_PACMAN_GNUPG=$GNUPG OMACVM_MOVE_DIR=$RT/var/lib/omacvm/move-4.5 \
    OMACVM_MOVE_LOG=$T/move.log OMACVM_PACMAN_CACHE=$T/cache OMACVM_MOVE_WAIT404=0 OMARCHY_PATH=$T/omarchy RT=$RT \
    "$GD/omarchy-move.sh" "$@"
}
p() { PATH="$B:$PATH" OMACVM_PACMAN_CONF=$RT/etc/pacman.conf RT=$RT pacman "$@"; }
J() { echo "$RT/var/lib/omacvm/move-4.5"; }

# A case: the live and snapshot repos from the function CASE_repos (both
# sides get omarchy, omarchy-settings and a base), the VM's packages
# installed from live (and AUR ones with pacman -U), then the move.
newcase() {   # NAME INSTALL...  (CASE_repos defines the case's own packages)
  local name=$1; shift
  rm -rf "$T/live" "$T/snap" "$T/w" "$T/cache"/* "$T/gnupg" "$T/move.log" "$T/aur"
  mkdir -p "$T/live/core" "$T/live/omarchy-aarch64" "$T/snap/core" "$T/snap/omarchy" "$T/aur"
  RT=$T/root-$name; rm -rf "$RT"
  mkdir -p "$RT/var/lib/pacman" "$RT/sys/class/dmi/id" "$RT/boot/grub" "$RT/etc/pacman.d" "$RT/usr/share/pacman/keyrings" "$RT/etc/omacvm"
  echo QEMU > "$RT/sys/class/dmi/id/sys_vendor"; echo menu-40 > "$RT/boot/grub/grub.cfg"
  : > "$RT/usr/share/pacman/keyrings/archlinuxarm.gpg"
  printf '[options]\nArchitecture = aarch64\n\n[omarchy-aarch64]\nServer = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/rc\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$RT/etc/pacman.conf"
  printf 'Server = https://de3.mirror.archlinuxarm.org/$arch/$repo\n' > "$RT/etc/pacman.d/mirrorlist"
  mkpkg "$T/live/omarchy-aarch64/x" omarchy 4.0.3rc4-2 depends=base -- usr/share/omarchy/version
  mkpkg "$T/live/omarchy-aarch64/x" omarchy-settings 4.0.3rc4-2 -- etc/omarchy/settings
  mkpkg "$T/live/omarchy-aarch64/x" omarchy-mac-keyring 20260914-2 -- usr/share/pacman/keyrings/omarchy-mac.gpg
  mkpkg "$T/live/core/x" base 3-2 -- usr/share/base/v
  mkpkg "$T/snap/omarchy/x" omarchy 4.5.0-3 depends=base -- usr/share/omarchy/version
  mkpkg "$T/snap/omarchy/x" omarchy-settings 4.5.0-3 -- etc/omarchy/settings
  mkpkg "$T/snap/core/x" base 3-1 -- usr/share/base/v
  "${name}_repos"
  for d in "$T/live/core" "$T/live/omarchy-aarch64" "$T/snap/core" "$T/snap/omarchy"; do mkrepo "$d"; done
  p -Sy --noconfirm omarchy omarchy-settings omarchy-mac-keyring "$@" > "$T/install.log" 2>&1 || { echo "FAIL $name: live install"; tail -5 "$T/install.log"; fail=1; }
  local a; for a in "$T"/aur/*.pkg.tar.gz; do [[ -f $a ]] && { p -U --noconfirm "$a" >> "$T/install.log" 2>&1 || { echo "FAIL $name: AUR install"; fail=1; }; }; done
  p -Q > "$T/before"
}
run() { o run > "$T/run-${RT##*root-}.out" 2>&1; echo $?; }
has() { p -Q 2>/dev/null | awk -v n="$1" '$1 == n { print $2 }'; }
reason() { p -Qi "$1" 2>/dev/null | sed -n 's/^Install Reason *: //p' | awk '{ print $1 }'; }
file() { cat "$RT/$1" 2>/dev/null || echo missing; }
owner() { p -Qqo "$RT/$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
consistent() { p -Dk > "$T/dk" 2>&1 && echo ok || head -3 "$T/dk" | tr '\n' ' '; }
status() { o status --json | json "$1"; }

# ---------- a split: clang -> clang + clang-libs in live, one clang in the snapshot ----------
split_repos() {
  mkpkg "$T/live/core/x" llvm-libs 2-1 -- usr/lib/libLLVM.so
  mkpkg "$T/live/core/x" clang 2-1 depends=clang-libs=2-1,llvm-libs -- usr/bin/clang
  mkpkg "$T/live/core/x" clang-libs 2-1 depends=llvm-libs base=clang -- usr/lib/libclang.so usr/lib/clang/2/include/__clang_cuda_x.h usr/share/clang/only-live.txt
  mkpkg "$T/snap/core/x" llvm-libs 1-1 -- usr/lib/libLLVM.so
  mkpkg "$T/snap/core/x" clang 1-1 depends=llvm-libs -- usr/bin/clang usr/lib/libclang.so usr/lib/clang/2/include/__clang_cuda_x.h
}
newcase split clang
expect "split: live has clang + clang-libs" "2-1 2-1" "$(has clang) $(has clang-libs)"
rc=$(run)
expect "split: the move is done (exit 0)" "0 done" "$rc $(cat "$(J)/state" 2>/dev/null)"
expect "split: clang from the snapshot, clang-libs gone, llvm-libs back to the snapshot's" "1-1 - 1-1 4.5.0-3" \
  "$(has clang) $([[ -z $(has clang-libs) ]] && echo -) $(has llvm-libs) $(has omarchy)"
expect "split: clang-libs's files are the snapshot clang's, owned by clang" "clang 1-1 usr/lib/libclang.so|clang" \
  "$(file usr/lib/libclang.so)|$(owner usr/lib/libclang.so)"
expect "split: a header in a deeper folder too" "clang 1-1 usr/lib/clang/2/include/__clang_cuda_x.h" "$(file usr/lib/clang/2/include/__clang_cuda_x.h)"
expect "split: clang-libs's file the snapshot has not is gone" missing "$(file usr/share/clang/only-live.txt)"
expect "split: pacman's database has no missing dependency" ok "$(consistent)"
expect "split: clang stays explicit" Explicitly "$(reason clang)"
expect "split: the result lists it" "['clang-libs (by clang)']" "$(status 'd["result"]["replaced"]')"

# ---------- a rename: live's newtool replaces oldtool, the snapshot has only oldtool ----------
rename_repos() {
  mkpkg "$T/live/core/x" newtool 2-1 replaces=oldtool -- usr/bin/tool
  mkpkg "$T/live/core/x" app 2-1 depends=newtool -- usr/bin/app
  mkpkg "$T/snap/core/x" oldtool 1-1 -- usr/bin/tool
  mkpkg "$T/snap/core/x" app 1-1 depends=oldtool -- usr/bin/app
}
newcase rename app
rc=$(run)
expect "rename: done" "0 done" "$rc $(cat "$(J)/state" 2>/dev/null)"
expect "rename: oldtool in newtool's place, as a dependency" "1-1 - Installed" \
  "$(has oldtool) $([[ -z $(has newtool) ]] && echo -) $(reason oldtool)"
expect "rename: the tool's file is the snapshot's" "oldtool 1-1 usr/bin/tool|oldtool" "$(file usr/bin/tool)|$(owner usr/bin/tool)"
expect "rename: no missing dependency" ok "$(consistent)"

# ---------- a merge: live's bigpart replaces parta + partb, the snapshot has both ----------
merge_repos() {
  mkpkg "$T/live/core/x" bigpart 2-1 replaces=parta,partb provides=parta,partb conflicts=parta,partb -- usr/lib/a.so usr/lib/b.so
  mkpkg "$T/live/core/x" user 2-1 depends=parta -- usr/bin/user
  mkpkg "$T/snap/core/x" parta 1-1 -- usr/lib/a.so
  mkpkg "$T/snap/core/x" partb 1-1 -- usr/lib/b.so
  mkpkg "$T/snap/core/x" user 1-1 depends=parta -- usr/bin/user
}
newcase merge user bigpart
rc=$(run)
expect "merge: done" "0 done" "$rc $(cat "$(J)/state" 2>/dev/null)"
expect "merge: parta + partb from the snapshot in bigpart's place (it was explicit: so are they)" "1-1 1-1 - Explicitly Explicitly" \
  "$(has parta) $(has partb) $([[ -z $(has bigpart) ]] && echo -) $(reason parta) $(reason partb)"
expect "merge: their files are the snapshot's" "parta 1-1 usr/lib/a.so|partb 1-1 usr/lib/b.so" "$(file usr/lib/a.so)|$(file usr/lib/b.so)"
expect "merge: no missing dependency" ok "$(consistent)"

# ---------- a file moved between two packages both repos have (pacman's own case) ----------
filemove_repos() {
  mkpkg "$T/live/core/x" pkga 2-1 -- usr/lib/a1
  mkpkg "$T/live/core/x" pkgb 2-1 -- usr/lib/b1 usr/lib/a2
  mkpkg "$T/snap/core/x" pkga 1-1 -- usr/lib/a1 usr/lib/a2
  mkpkg "$T/snap/core/x" pkgb 1-1 -- usr/lib/b1
}
newcase filemove pkga pkgb
rc=$(run)
expect "file moved between two packages: done, nothing replaced" "0 done []" "$rc $(cat "$(J)/state" 2>/dev/null) $(status 'd["result"]["replaced"]')"
expect "file moved: back with pkga" "pkga 1-1 usr/lib/a2|pkga" "$(file usr/lib/a2)|$(owner usr/lib/a2)"

# ---------- a package live has and the snapshot has nothing for: it stays ----------
nocp_repos() {
  mkpkg "$T/live/core/x" newlib 2-1 -- usr/lib/newlib.so
  mkpkg "$T/live/core/x" app 2-1 depends=newlib -- usr/bin/app
  mkpkg "$T/snap/core/x" app 1-1 -- usr/bin/app
}
newcase nocp app
rc=$(run)
expect "no counterpart: done, newlib stays (listed as foreign)" "0 done 2-1 True" \
  "$rc $(cat "$(J)/state" 2>/dev/null) $(has newlib) $(status '"newlib" in d["result"]["foreign"]')"

# ---------- a package built in the VM needs the split-off one ----------
aurneeds_repos() {
  split_repos
  mkpkg "$T/aur/x" mytool 1-1 depends=clang-libs -- usr/bin/mytool
}
newcase aurneeds clang
rc=$(run)
expect "built here, needs clang-libs, nothing in the snapshot provides it: stops before any change (exit 1, download, resumable)" \
  "1 failed download True" "$rc $(status '" ".join(str(x) for x in [d["state"], d["code"], d["resumable"]])')"
expect "... the reason names both" yes "$(status 'd["reason"]' | grep -q 'clang-libs (needed by mytool)' && echo yes)"
expect "... nothing changed: the packages as before" same "$(p -Q | cmp -s - "$T/before" && echo same)"
aurprov_repos() {
  mkpkg "$T/live/core/x" llvm-libs 2-1 -- usr/lib/libLLVM.so
  mkpkg "$T/live/core/x" clang 2-1 depends=clang-libs=2-1 -- usr/bin/clang
  mkpkg "$T/live/core/x" clang-libs 2-1 provides=libclang base=clang -- usr/lib/libclang.so
  mkpkg "$T/snap/core/x" clang 1-1 provides=libclang -- usr/bin/clang usr/lib/libclang.so
  mkpkg "$T/aur/x" mytool 1-1 depends=libclang -- usr/bin/mytool
}
newcase aurprov clang
rc=$(run)
expect "built here, needs libclang, which the snapshot's clang provides: done, mytool kept" "0 done 1-1 1-1 ok" \
  "$rc $(cat "$(J)/state" 2>/dev/null) $(has clang) $(has mytool) $(consistent)"

# ---------- a file no package owns where the switch puts one ----------
stray_repos() {
  mkpkg "$T/snap/core/x" base 3-1 depends=pyx -- usr/share/base/v
  mkpkg "$T/snap/core/x" pyx 1-1 -- usr/lib/python/pyx.py
}
newcase stray
mkdir -p "$RT/usr/lib/python"; echo "pip's copy" > "$RT/usr/lib/python/pyx.py"
rc=$(run)
expect "a file no package owns (pip's): done, the package's file in place, the old one kept in the journal and listed" \
  "0 done pyx 1-1 usr/lib/python/pyx.py|pip's copy|['/usr/lib/python/pyx.py']" \
  "$rc $(cat "$(J)/state" 2>/dev/null) $(file usr/lib/python/pyx.py)|$(cat "$(J)/overwritten-files/usr/lib/python/pyx.py" 2>/dev/null)|$(status 'd["result"]["overwritten"]')"

# ---------- cut off between taking the record out and the switch ----------
cut_repos() { split_repos; }
newcase cut clang
: > "$T/kill-after-dbonly"
o run > "$T/run.out" 2>&1
expect "cut off after clang-libs's record left: interrupted, resumable, no switch begun" "interrupted True False" \
  "$(status '" ".join(str(x) for x in [d["state"], d["resumable"], d["commit_started"]])')"
rc=$(run)
expect "... Resume: done, as the split case" "0 done 1-1 ok" "$rc $(cat "$(J)/state" 2>/dev/null) $(has clang) $(consistent)"
expect "... clang-libs gone for good" "" "$(has clang-libs)"
exit $fail
