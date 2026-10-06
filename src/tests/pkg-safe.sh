#!/bin/bash
# Offline test (no VM) of how OmacVM installs packages in a VM: only ones the
# VM lacks, never an update of one it has (src/guest/pkg-add), and that an
# install which breaks the desktop's graphics (GBM) is undone
# (src/guest/gbm-guard). The case of 2026-10-06: a `pacman -Sy` had fetched a
# newer package list, then `pacman -S --needed ... mesa` put Mesa 26.2.4
# (built for LLVM 23) beside LLVM 22: black screen. pacman is a stand-in here
# with an installed list, a package list and a cache.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cache"
# Stand-in pacman. $T/db: installed "name version"; $T/sync: the package list
# "name version dep..."; every call that changes something goes to $T/calls.
cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
db=$T/db; sync=$T/sync
ver() { awk -v n="$1" '$1 == n { print $2 }' "$2"; }
# Like gettext: German output unless the locale is C (LC_ALL, then LANG).
loc() { if [[ ${LC_ALL:-${LANG:-C}} == C* ]]; then cat; else sed 's/installed/installiert/; s/^Depends On     /Hängt ab von   /'; fi; }
case $1 in
  -T) shift; rc=0; for p in "$@"; do [[ -n $(ver "$p" "$db") ]] || { echo "$p"; rc=127; }; done; exit $rc ;;
  -Qq) shift; rc=0; for p in "$@"; do [[ -n $(ver "$p" "$db") ]] && echo "$p" || rc=1; done; exit $rc ;;
  -Qi) echo "Install Reason  : Explicitly installed" ;;
  -Rns) shift; echo "pacman -Rns $*" >> "$T/calls"
      for p in "$@"; do [[ $p == -* ]] || { grep -v "^$p " "$db" > "$db.n"; mv "$db.n" "$db"; }; done ;;
  -Q) [[ $# == 1 ]] && { cat "$db"; exit 0; }
      v=$(ver "$2" "$db"); [[ -n $v ]] && { echo "$2 $v"; exit 0; }; exit 1 ;;
  -S) shift
      if [[ $1 == --print ]]; then
        shift 3   # --print --print-format FMT
        for p in "$@"; do
          [[ $p == --noconfirm ]] && continue
          line=$(awk -v n="$p" '$1 == n' "$sync"); [[ -n $line ]] || { echo "error: target not found: $p" >&2; exit 1; }
          set -- $line; echo "$1 $2"; shift 2
          for d in "$@"; do [[ $d == ~* ]] && continue; s=$(ver "$d" "$sync"); [[ $(ver "$d" "$db") == "$s" ]] || echo "$d $s"; done
        done
        exit 0
      fi
      echo "pacman -S $*" >> "$T/calls"
      if [[ -e $T/mirrors-gone ]]; then
        for p in "$@"; do [[ $p == -* ]] || echo "error: failed retrieving file '$p-1-aarch64.pkg.tar.xz' from mirror.archlinuxarm.org : The requested URL returned error: 404" >&2; done
        echo "error: failed to commit transaction (failed to retrieve some files)" >&2; exit 1
      fi
      for p in "$@"; do [[ $p == -* ]] && continue; s=$(ver "$p" "$sync")
        grep -v "^$p " "$db" > "$db.n"; echo "$p $s" >> "$db.n"; mv "$db.n" "$db"; done ;;
  -Sl) while read -r n v _; do i=$(ver "$n" "$db"); echo "extra $n $v${i:+ [installed${i/#/: }]}" |
         sed 's/ \[installed: '"$v"'\]$/ [installed]/' | loc; done < "$sync" ;;
  -Si) shift; for p in "$@"; do set -- $(awk -v n="$p" '$1 == n' "$sync"); shift 2
         { echo "Name            : $p"; echo "Depends On      : ${*//\~/}"; } | loc; done ;;
  -U) shift; echo "pacman -U $*" >> "$T/calls"
      for f in "$@"; do [[ $f == -* ]] && continue
        b=$(basename "$f"); b=${b%-aarch64.pkg.tar.*}; v=${b##*-}; b=${b%-*}; v=${b##*-}-$v; n=${b%-*}
        grep -v "^$n " "$db" > "$db.n"; echo "$n $v" >> "$db.n"; mv "$db.n" "$db"; done ;;
  *) echo "pacman stand-in: $*" >&2; exit 1 ;;
esac
EOF
# The GBM test: Mesa 26.2.4 needs LLVM 23 (libLLVM.so.23.1), as Arch Linux ARM's does.
cat > "$T/bin/gbmtest" <<'EOF'
#!/bin/bash
m=$(awk '$1 == "mesa" { print $2 }' "$T/db"); l=$(awk '$1 == "llvm-libs" { print $2 }' "$T/db")
[[ $m == 1:26.2.4-1 && $l != 23.* ]] && echo "/usr/lib/gbm/dri_gbm.so needs libLLVM.so.23.1 (not installed)"
exit 0
EOF
chmod +x "$T/bin/"*
export T PATH="$T/bin:$PATH" OMACVM_PKG_LOG=$T/pacman.log OMACVM_GBM_TEST=$T/bin/gbmtest \
  OMACVM_GBM_GUARD_DIR=$T/guard OMACVM_PKG_CACHE=$T/cache
vm() {   # the user's VM of 2026-10-06: Mesa 26.2.3 on LLVM 22, a newer package list
  printf '%s\n' "mesa 1:26.2.3-1" "llvm-libs 22.1.8-2" "ffmpeg 2:9.0.2-1" "libva 2.23.0-1" "dkms 3.2.2-1" \
    "make 4.4.1-2" "gcc 15.2.1-1" "python 3.14.0-1" > "$T/db"
  printf '%s\n' "mesa 1:26.2.4-1 llvm-libs" "llvm-libs 23.1.1-1" "ffmpeg 2:9.0.2-2" "libva 2.23.0-1" "dkms 3.2.2-1" \
    "make 4.4.1-2" "gcc 15.2.1-1" "python 3.14.0-1" "python-textual 8.2.8-2 python" "jq 1.8.1-1" \
    "opencl-mesa 1:26.2.4-1 mesa llvm-libs" "lldb 23.1.1-1 ~llvm-libs ~python" > "$T/sync"
  : > "$T/calls"; rm -rf "$T/guard" "$T/cache"; mkdir -p "$T/cache"
}
P=src/guest/pkg-add G=src/guest/gbm-guard

vm
out=$("$P" dkms make gcc ffmpeg libva mesa 2>&1); rc=$?
[[ $rc == 0 && ! -s $T/calls && $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.3-1" ]] &&
  pass "all there (the chromium-video case): no pacman -S, Mesa stays 26.2.3" ||
  fail "all there: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm
out=$("$P" jq python-textual 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "pacman -S --noconfirm jq python-textual" ]] &&
  pass "missing ones: only they are installed" || fail "missing ones: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm
out=$("$P" --asdeps jq 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "pacman -S --noconfirm --asdeps jq" ]] && pass "--asdeps passed on" ||
  fail "--asdeps: calls '$(cat "$T/calls")'"

vm
out=$("$P" opencl-mesa 2>&1); rc=$?
[[ $rc == 3 && ! -s $T/calls && $out == *"mesa 1:26.2.3-1 -> 1:26.2.4-1"* && $out == *"llvm-libs 22.1.8-2 -> 23.1.1-1"* && $out == *"omarchy update"* ]] &&
  pass "a missing package that would update Mesa and LLVM alone: refused, says why" ||
  fail "partial update not refused: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm
out=$("$P" lldb 2>&1); rc=$?
[[ $rc == 3 && ! -s $T/calls && $out == *"llvm-libs 22.1.8-2 -> 23.1.1-1"* ]] &&
  pass "a missing package built for a newer LLVM (unversioned dependency): refused" ||
  fail "lldb 23 beside LLVM 22: rc $rc, calls '$(cat "$T/calls")', said '$out'"

# pacman's words are translated (Depends On, [installed: ...]); the checks
# must not go blind in a German VM (the boot timer gets the VM's locale).
vm
out=$(LANG=de_CH.UTF-8 LC_ALL= "$P" lldb 2>&1); rc=$?
[[ $rc == 3 && ! -s $T/calls && $out == *"llvm-libs 22.1.8-2 -> 23.1.1-1"* ]] &&
  pass "the same in a German VM: refused" ||
  fail "German locale: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm; printf '%s\n' "llvm-libs 23.1.1-1" >> "$T/db"; grep -v '^llvm-libs 22' "$T/db" > "$T/db.n"; mv "$T/db.n" "$T/db"
out=$("$P" lldb 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "pacman -S --noconfirm lldb" ]] && pass "the same once LLVM is up to date: installed" ||
  fail "lldb with LLVM 23: rc $rc, calls '$(cat "$T/calls")', said '$out'"

# A package list older than the mirrors (a fresh prebuilt VM a day later): the
# downloads are 404s; it says to update the system, not just "pacman failed".
vm; : > "$T/mirrors-gone"
out=$("$P" jq 2>&1); rc=$?; rm -f "$T/mirrors-gone"
[[ $rc == 3 && $out == *"older than the mirrors"*"omarchy update"* && $(grep -c "error: 404" "$T/pacman.log") -ge 1 ]] &&
  pass "mirrors no longer have the listed versions: says to update the system, log kept" ||
  fail "stale package list: rc $rc, said '$out'"

vm
out=$("$P" no-such-package 2>&1); rc=$?
[[ $rc == 1 && ! -s $T/calls && $out == *"does not find"* ]] && pass "unknown package: one line, nothing installed" ||
  fail "unknown package: rc $rc, said '$out'"

# gbm-guard: an install that updated Mesa alone is undone from the cache.
vm; : > "$T/cache/mesa-1:26.2.3-1-aarch64.pkg.tar.xz"; : > "$T/cache/mesa-1:26.2.3-1-aarch64.pkg.tar.xz.sig"
"$G" begin
echo "mesa 1:26.2.4-1" > "$T/db.n"; grep -v '^mesa ' "$T/db" >> "$T/db.n"; mv "$T/db.n" "$T/db"   # what pacman -S --needed did
[[ $("$G" test) == *"libLLVM.so.23.1"* ]] && pass "test: sees the broken GBM" || fail "test does not see it"
out=$("$G" end 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "pacman -U --noconfirm $T/cache/mesa-1:26.2.3-1-aarch64.pkg.tar.xz" &&
   $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.3-1" && $out == *"graphics work again"* ]] &&
  pass "end: Mesa put back to 26.2.3 from the cache, GBM opens again" ||
  fail "end: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm; "$G" begin
echo "mesa 1:26.2.4-1" > "$T/db.n"; grep -v '^mesa ' "$T/db" >> "$T/db.n"; mv "$T/db.n" "$T/db"
out=$("$G" end 2>&1); rc=$?
[[ $rc == 1 && ! -s $T/calls && $out == *"not in the package cache: mesa-1:26.2.3-1"* && $out == *"Do not restart"* ]] &&
  pass "end: old package not in the cache: fails, says how to recover" || fail "end without cache: rc $rc, said '$out'"

vm; "$G" begin
out=$("$G" end 2>&1); rc=$?
[[ $rc == 0 && -z $out && ! -s $T/calls && ! -e $T/guard ]] && pass "end: nothing changed: silent" || fail "end, no change: rc $rc, said '$out'"

vm; echo "mesa 1:26.2.4-1" > "$T/db.n"; grep -v '^mesa ' "$T/db" >> "$T/db.n"; mv "$T/db.n" "$T/db"
"$G" begin; out=$("$G" end 2>&1); rc=$?
[[ $rc == 0 && ! -s $T/calls && $out == *"so before this install"* ]] && pass "end: broken before the install: says so, undoes nothing" ||
  fail "end, broken before: rc $rc, said '$out'"

# A full update (Mesa and LLVM together) is fine for the test.
vm; printf '%s\n' "mesa 1:26.2.4-1" "llvm-libs 23.1.1-1" > "$T/db"
[[ $("$G" test) == "GBM opens" ]] && pass "test: Mesa 26.2.4 with LLVM 23 opens" || fail "test: full update said broken"

# guest/system-update: omarchy update (a stand-in here: the whole system to the
# mirrors' versions), then the GBM test. Exit 0 / 1 not updated / 2 graphics broken.
cat > "$T/bin/omarchy-update" <<'EOF'
#!/bin/bash
echo "omarchy update $*" >> "$T/calls"
[[ -e $T/update-fails ]] && { echo "error: failed to synchronize all databases"; exit 1; }
# Omarchy asks this even with -y (omarchy-update-orphan-pkgs in a terminal).
if [[ -e $T/orphans ]]; then
  gum style "Orphan system packages"
  if gum confirm --default=false "Remove 1 orphaned package(s)?"; then echo removed >> "$T/calls"; else echo kept >> "$T/calls"; fi
fi
# Shown, not asked: they must not wait or fail the update.
if [[ -e $T/pages ]]; then
  gum pager "Release notes" >> "$T/calls" || exit 1
  printf 'a,b\n1,2\n' | gum table || exit 1
  gum input --placeholder "Name" && echo answered >> "$T/calls"
fi
[[ -e $T/update-hangs ]] && exec sleep 20
[[ -e $T/sudoers-seen ]] && ls "$T/etc/sudoers.d" >> "$T/calls" 2>&1
[[ -e $T/mirror ]] && cp "$T/mirror" "$T/sync"
[[ -e $T/mirrors-behind ]] || rm -f "$T/mirrors-gone"
awk 'NR == FNR { v[$1] = $2; next } { print $1, ($1 in v) ? v[$1] : $2 }' "$T/sync" "$T/db" > "$T/db.n"; mv "$T/db.n" "$T/db"
if [[ -e $T/update-mesa-only ]]; then
  grep -v '^llvm-libs ' "$T/db" > "$T/db.n"; echo "llvm-libs 22.1.8-2" >> "$T/db.n"; mv "$T/db.n" "$T/db"
fi
# An Omarchy migration that installs a package (one of the driver's build tools).
[[ -e $T/update-adds ]] && echo "meson 1.9.0-1" >> "$T/db"
exit 0
EOF
chmod +x "$T/bin/omarchy-update"
# Stand-in gum: says yes to every question.
printf '#!/bin/bash\necho "gum $*" >> "$T/calls"\n' > "$T/bin/gum"; chmod +x "$T/bin/gum"
# flock(1) is Linux's; on the Mac a stand-in with the same lock (flock(2) on the fd).
if ! command -v flock >/dev/null; then
  printf '%s\n' '#!/usr/bin/env python3' 'import fcntl, sys' \
    'try: fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | (fcntl.LOCK_NB if "-n" in sys.argv else 0))' \
    'except OSError: sys.exit(1)' > "$T/bin/flock"
  chmod +x "$T/bin/flock"
fi
S=src/guest/system-update
export OMACVM_SYSTEM_UPDATE_RUN="omarchy-update -y" OMACVM_SYSTEM_UPDATE_LOG=$T/system-update.log \
  OMACVM_SYSTEM_UPDATE_DIR=$T/system-update-run OMACVM_SYSTEM_UPDATE_LOCK=$T/system-update.lock

vm; "$G" begin
out=$("$S" 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "omarchy update -y" && $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.4-1" &&
   $out == *"up to date (GBM opens;"* ]] && pass "system-update: omarchy update -y, then the GBM test" ||
  fail "system-update: rc $rc, calls '$(cat "$T/calls")', said '$out'"
out=$("$G" end 2>&1); rc=$?
[[ $rc == 0 && $(cat "$T/calls") == "omarchy update -y" ]] && pass "system-update inside an install: end keeps the update" ||
  fail "end after a system update: rc $rc, calls '$(cat "$T/calls")', said '$out'"

vm; : > "$T/update-fails"
out=$("$S" 2>&1); rc=$?; rm -f "$T/update-fails"
[[ $rc == 1 && $out == *"omarchy update stopped (exit 1"* && $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.3-1" ]] &&
  pass "system-update: the update fails: exit 1, says so" || fail "system-update fails: rc $rc, said '$out'"

vm; : > "$T/update-mesa-only"
out=$("$S" 2>&1); rc=$?; rm -f "$T/update-mesa-only"
[[ $rc == 2 && $out == *"libLLVM.so.23.1"*"do not restart"* ]] && pass "system-update: graphics broken after it: exit 2, do not restart" ||
  fail "system-update, GBM broken: rc $rc, said '$out'"

vm; : > "$T/orphans"
out=$("$S" 2>&1); rc=$?; rm -f "$T/orphans"
[[ $rc == 0 && $(tr '\n' ' ' < "$T/calls") == "omarchy update -y gum style Orphan system packages kept " && ! -e $T/system-update-run ]] &&
  pass "system-update: nobody to answer: a question gets no, the rest is gum" ||
  fail "system-update, a question: rc $rc, calls '$(tr '\n' ' ' < "$T/calls")', said '$out'"

vm; : > "$T/pages"
out=$("$S" 2>&1); rc=$?; rm -f "$T/pages"
[[ $rc == 0 && $(tr '\n' ' ' < "$T/calls") == "omarchy update -y Release notes gum table --print " ]] &&
  pass "system-update: a pager or table is printed without waiting, input gets no answer" ||
  fail "system-update, pager/table: rc $rc, calls '$(tr '\n' ' ' < "$T/calls")', said '$out'"

# One at a time: a second run while the first holds the lock stops at once,
# without touching the first one's helpers.
vm; mkdir -p "$T/system-update-run"; : > "$T/system-update-run/rc"
exec 8>>"$T/system-update.lock"; flock -n 8
out=$("$S" 2>&1); rc=$?
exec 8>&-
[[ $rc == 1 && $out == *"an update runs already"* && ! -s $T/calls && -e $T/system-update-run/rc ]] &&
  pass "system-update: a second run at the same time stops, the first one's files stay" ||
  fail "system-update, two at once: rc $rc, calls '$(cat "$T/calls")', said '$out'"
rm -rf "$T/system-update-run"

# The unit's way (the tests above skip it): systemd, visudo, getent and pgrep
# are stand-ins, the script's /etc, /run and pacman paths are under $T.
U=$T/unit; rm -rf "$U" "$T/etc" "$T/run" "$T/pacman" "$T/home"
mkdir -p "$U/guest" "$T/etc/sudoers.d" "$T/etc/tmpfiles.d" "$T/etc/omacvm" "$T/run/user/$(id -u)/hypr/sig1" \
  "$T/pacman" "$T/home/.local/share/omarchy/bin"
sed -e "s#/etc/#$T/etc/#g" -e "s#/run/#$T/run/#g" -e "s#/var/lib/pacman/#$T/pacman/#g" \
  -e 's/sleep 5$/sleep 0.1/' -e 's/sleep 5;/sleep 0.1;/' -e '/(( EUID == 0 )) ||/d' "$S" > "$U/guest/system-update"
cp "$G" "$U/guest/"; chmod +x "$U/guest/"*
cp "$T/bin/omarchy-update" "$T/home/.local/share/omarchy/bin/"
echo "OMACVM_USER=$(id -un)" > "$T/etc/omacvm/env"
printf '#!/bin/bash\necho "$(id -un):x:$(id -u):$(id -g)::$T/home:/bin/bash"\n' > "$T/bin/getent"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/visudo"
printf '#!/bin/bash\n[[ -e $T/pacman-running ]] || exit 1\n[[ $1 != -ax ]] || echo "4242 pacman -S jq"\n' > "$T/bin/pgrep"
# The unit is a background job; its -p and -E names go to $T/units.
cat > "$T/bin/systemd-run" <<'EOF2'
#!/bin/bash
envs=() post="" out=/dev/null
while (( $# )); do
  case $1 in
    --quiet|--unit=*|--uid=*|--gid=*) shift ;;
    -p) echo "-p $2" >> "$T/units"
        case $2 in ExecStopPost=*) post=${2#ExecStopPost=+} ;; StandardOutput=append:*) out=${2#StandardOutput=append:} ;; esac
        shift 2 ;;
    -E) echo "-E ${2%%=*}" >> "$T/units"; [[ $2 == PATH=* ]] && envs+=("$2:/bin") || envs+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
# shellcheck disable=SC2086 # the stop command and its words
( env "${envs[@]}" "$@" >>"$out" 2>&1 & echo $! > "$T/unit.cmd"; wait $!; $post ) >/dev/null 2>&1 </dev/null 9>&- &
echo $! > "$T/unit.pid"
EOF2
cat > "$T/bin/systemctl" <<'EOF2'
#!/bin/bash
alive() { [[ -s $T/unit.pid ]] && kill -0 "$(cat "$T/unit.pid")" 2>/dev/null; }
echo "systemctl $*" >> "$T/units"
case $1 in
  is-active) alive; exit ;;
  stop) if alive; then c=$(cat "$T/unit.cmd"); kill $c $(/usr/bin/pgrep -P "$c"); while alive; do sleep 0.1; done; fi ;;
esac
exit 0
EOF2
chmod +x "$T/bin/"*
unit() {   # [VAR=VALUE]...: the script, no unit before it
  : > "$T/units"; rm -f "$T/unit.pid" "$T/unit.cmd"
  env -u OMACVM_SYSTEM_UPDATE_RUN -u OMACVM_SYSTEM_UPDATE_DIR -u OMACVM_SYSTEM_UPDATE_LOCK "$@" "$U/guest/system-update" 2>&1
}
left() { find "$T/etc/sudoers.d" "$T/etc/tmpfiles.d" -type f; ls -d "$T/run/omacvm-system-update" 2>/dev/null; }

vm; : > "$T/sudoers-seen"; : > "$T/orphans"
out=$(unit); rc=$?; rm -f "$T/sudoers-seen" "$T/orphans"
[[ $rc == 0 && $(tr '\n' ' ' < "$T/calls") == "omarchy update -y gum style Orphan system packages kept zz-omacvm-update " &&
   -z $(left) && $(grep -c '== omarchy update exit 0' "$T/system-update.log") -ge 1 &&
   $(grep -c -e '-p RuntimeMaxSec=2400' -e '-p KillSignal=SIGINT' -e '-E HYPRLAND_INSTANCE_SIGNATURE' -e '-E GUM_CONFIRM_TIMEOUT' "$T/units") == 4 &&
   $out == *"up to date"* ]] &&
  pass "system-update unit: sudo only while it runs, a time limit, the session's Hyprland, its exit status" ||
  fail "system-update unit: rc $rc, calls '$(tr '\n' ' ' < "$T/calls")', left '$(left)', units '$(tr '\n' ' ' < "$T/units")', said '$out'"

vm; : > "$T/pacman/db.lck"; : > "$T/pacman-running"
( sleep 1; rm -f "$T/pacman/db.lck" "$T/pacman-running" ) &
out=$(unit); rc=$?
wait
[[ $rc == 0 && $out == *"waiting for pacman (4242 pacman -S jq)"*"up to date"* ]] &&
  pass "system-update: waits for a pacman that holds the lock (Omarchy's check after login)" ||
  fail "system-update, pacman busy: rc $rc, said '$out'"

vm; : > "$T/pacman/db.lck"
out=$(unit); rc=$?
[[ $rc == 0 && ! -e $T/pacman/db.lck && $out != *"waiting for pacman"* ]] &&
  pass "system-update: a pacman lock without pacman (cut off) is removed" ||
  fail "system-update, stale lock: rc $rc, said '$out'"

vm; : > "$T/update-hangs"
out=$(unit OMACVM_SYSTEM_UPDATE_STALL=1); rc=$?; rm -f "$T/update-hangs"
[[ $rc == 1 && $out == *"shows nothing new"*"stopped before its end"* && -z $(left) &&
   $(grep -c '^systemctl stop' "$T/units") -ge 1 && $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.3-1" ]] &&
  pass "system-update: an update that waits for an answer is stopped, sudo goes with it" ||
  fail "system-update, stuck: rc $rc, left '$(left)', units '$(tr '\n' ' ' < "$T/units")', said '$out'"
rm -f "$T/bin/getent" "$T/bin/visudo" "$T/bin/pgrep" "$T/bin/systemd-run" "$T/bin/systemctl"

# Graphics -> Vulkan on a prebuilt VM a day after its image (air-notch F4):
# its package list names versions the mirrors no longer have, so the Venus
# driver's build tools 404. omacvm graphics (OMACVM_SYSTEM_UPDATE_OK, after
# asking) updates the whole system first, then builds; omacvm apply and the
# boot timer never update: exit 4.
V=$T/vm/app/guest/venus; rm -rf "$T/vm"; mkdir -p "$V"
cp -R src/app/guest/venus/. "$V/"
sed -e "s#/var/log/#$T/#" -e '/^(( EUID == 0 )) ||/d' src/app/guest/venus/vulkan-virtio.sh > "$V/vulkan-virtio.sh"
ours=$(cd "$V" && bash -c 'source ./PKGBUILD && echo "$epoch:$pkgver-$pkgrel"')
printf '#!/bin/bash\nexit 0\n' > "$T/bin/chown"
printf '#!/bin/bash\nwhile [[ $1 != -- ]]; do shift; done; shift; exec "$@"\n' > "$T/bin/runuser"
printf '#!/bin/bash\n: > "$PKGDEST/vulkan-virtio-%s-aarch64.pkg.tar.zst"\n' "$ours" > "$T/bin/makepkg"
cat > "$T/bin/vercmp" <<'EOF'
#!/usr/bin/env python3
import re, sys
def key(v):
    e, _, v = v.rpartition(":")
    v, _, r = v.partition("-")
    num = lambda s: [int(x) for x in re.findall(r"\d+", s)]
    return (int(e or 0), num(v), num(r))
a, b = key(sys.argv[1]), key(sys.argv[2])
print((a > b) - (a < b))
EOF
chmod +x "$T/bin/"*
tools=$(cd "$V" && bash -c 'source ./PKGBUILD; printf "%s\n" base-devel "${depends[@]}" "${makedepends[@]}"' | sort -u)
prebuilt() {   # VERSION of the distro's vulkan-virtio on the mirrors. Installed = package list = the image's
  vm; rm -f "$T/mirrors-gone" "$T/mirror"
  printf '%s\n' "mesa 1:26.2.3-1 llvm-libs" "llvm-libs 22.1.8-2" "vulkan-virtio 1:26.2.3-1" > "$T/sync"
  for t in $tools; do
    if [[ $t == vulkan-mesa-implicit-layers ]]; then echo "$t 1:26.2.3-1"; else echo "$t 1.0-1"; fi
  done >> "$T/sync"
  grep -vE '^(mesa|llvm-libs|vulkan-virtio|vulkan-mesa-implicit-layers) ' "$T/sync" > "$T/mirror"
  printf '%s\n' "mesa 1:26.2.4-1 llvm-libs" "llvm-libs 23.1.1-1" "vulkan-virtio 1:${1:-26.2.3}-1" \
    "vulkan-mesa-implicit-layers 1:26.2.4-1" >> "$T/mirror"
  [[ -n ${1:-} ]] && echo "vulkan-virtio 1:26.2.3-1" >> "$T/db"
  : > "$T/mirrors-gone"
}
vv() {   # PROBE ARGS...
  local probe=$1; shift
  OMACVM_PKG_ADD=$PWD/$P OMACVM_SYSTEM_UPDATE=$PWD/$S OMACVM_VENUS_PROBE=$probe \
    OMACVM_MESA_ICD=$T/none.json OMACVM_VENUS_LIB=$T/none.so "$V/vulkan-virtio.sh" "$@" 2>&1
}
OFF="venus=0 blob_alignment=0"
meson() { awk '$1 == "meson"' "$T/db"; }

prebuilt
out=$(vv "$OFF" --want); rc=$?
[[ $rc == 4 && $(grep -c 'omarchy update' "$T/calls") == 0 && $(grep -c 'pacman -U\|pacman -Rns' "$T/calls") == 0 &&
   $out == *"older than the mirrors"*"needs a full update first"* ]] &&
  pass "omacvm apply, old package list: no system update, exit 4, says why" ||
  fail "apply on a stale prebuilt VM: rc $rc, calls '$(cat "$T/calls")', said '$out'"

prebuilt
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?
c=$(cut -d' ' -f1-3 "$T/calls" | uniq | tr '\n' ',')
[[ $rc == 0 && $c == "pacman -S --noconfirm,omarchy update -y,pacman -S --noconfirm,pacman -U --noconfirm,pacman -Rns --noconfirm," &&
   $(awk '$1 == "vulkan-virtio"' "$T/db") == "vulkan-virtio $ours" && $(awk '$1 == "mesa"' "$T/db") == "mesa 1:26.2.4-1" &&
   $out == *"updating the whole system first"*"up to date"*"building"*"ready for the VM's next start"* &&
   $out != *"Update the system with omarchy update"* ]] &&
  pass "Graphics Vulkan, old package list: system updated, then the driver built" ||
  fail "Vulkan on a stale prebuilt VM: rc $rc, calls '$c', said '$out'"
rm_=$(grep 'pacman -Rns' "$T/calls")
[[ $rm_ == *meson* && $rm_ != *vulkan-mesa-implicit-layers* && -n $(awk '$1 == "vulkan-mesa-implicit-layers"' "$T/db") &&
   $out != *"build tools left installed"* ]] && pass "... build tools removed after, the driver's own dependencies kept" ||
  fail "removal after the build: '$rm_', said '$out'"
[[ -z $(grep -E 'pacman -Sy|pacman -S .*(mesa|llvm-libs)( |$)' "$T/calls") ]] && pass "... and never pacman -Sy or Mesa alone" ||
  fail "partial update: $(cat "$T/calls")"

# What the update installed itself (an Omarchy migration) is never removed after.
prebuilt 26.2.4; : > "$T/update-adds"
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?
[[ $rc == 0 && $(awk '$1 == "vulkan-virtio"' "$T/db") == "vulkan-virtio $ours" && -n $(meson) &&
   $(grep 'pacman -Rns' "$T/calls") != *meson* ]] &&
  pass "the update brings the distro's 26.2.4 and meson: ours built (WebGPU), meson stays" ||
  fail "update with 26.2.4 and meson: rc $rc, calls '$(cat "$T/calls")', said '$out'"

prebuilt 26.2.5
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?
[[ $rc == 0 && $(grep -c 'pacman -U\|pacman -Rns' "$T/calls") == 0 && $(awk '$1 == "vulkan-virtio"' "$T/db") == "vulkan-virtio 1:26.2.5-1" &&
   -n $(meson) && $out == *"nothing to build"* ]] && pass "the update brings a newer distro driver: no build, nothing removed" ||
  fail "update with the distro's 26.2.5: rc $rc, calls '$(cat "$T/calls")', said '$out'"
rm -f "$T/update-adds"

prebuilt; : > "$T/update-fails"
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?; rm -f "$T/update-fails"
[[ $rc == 1 && $(grep -c 'pacman -U\|pacman -Rns' "$T/calls") == 0 && $out == *"not built: the VM's system update did not go through"* ]] &&
  pass "the update fails: stops with the reason, nothing built or removed" ||
  fail "update fails: rc $rc, calls '$(cat "$T/calls")', said '$out'"

prebuilt; : > "$T/update-mesa-only"; : > "$T/update-adds"
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?; rm -f "$T/update-mesa-only" "$T/update-adds"
[[ $rc == 3 && $(grep -c 'pacman -U\|pacman -Rns' "$T/calls") == 0 && -n $(meson) && $out == *"do not restart"* ]] &&
  pass "updated, but GBM broken: exit 3 (do not restart), nothing built or removed" ||
  fail "update breaks GBM: rc $rc, calls '$(cat "$T/calls")', said '$out'"

prebuilt; : > "$T/mirrors-behind"
out=$(OMACVM_SYSTEM_UPDATE_OK=1 vv "$OFF" --want); rc=$?; rm -f "$T/mirrors-behind"
[[ $rc == 1 && $(grep -c 'omarchy update' "$T/calls") == 1 && $out == *"even after the update"* && $out != *"then omacvm apply"* ]] &&
  pass "tools still 404 after the update: says so, not 'omarchy update' again" ||
  fail "mirrors behind: rc $rc, calls '$(cat "$T/calls")', said '$out'"

prebuilt
out=$(vv "venus=1 blob_alignment=16384"); rc=$?
[[ $rc == 4 && $(grep -c 'omarchy update' "$T/calls") == 0 && $out == *"older than the mirrors"*"omarchy update"* ]] &&
  pass "boot timer (no --want): no system update on its own, says what to do" ||
  fail "boot timer, stale list: rc $rc, calls '$(cat "$T/calls")', said '$out'"
unset OMACVM_SYSTEM_UPDATE_RUN

# Wired in, and no other way to pacman -S in guest code.
grep -q '"$R/guest/gbm-guard" begin && GBM_GUARD=1' src/guest/install.sh &&
  grep -q '"$R/guest/gbm-guard" end' src/guest/install.sh && pass "guest/install.sh runs the GBM guard" ||
  fail "guest/install.sh does not run the GBM guard"
bad=$(git grep -nE 'pacman +(-S[a-zA-Z]*|--sync)( |$)' -- 'src/**' ':!src/tests/**' ':!src/guest/pkg-add' ':!src/vm/**' \
  ':!**/*.md' ':!src/bench/**' | grep -vE '^[^:]+:[0-9]+:\s*#' |
  grep -vE 'pacman -(Syu|Scc|Si) |\(pacman -S [a-z0-9 -]*\)|pacman -Q openssh [^|]*\|\| pacman -S |"\$k-headers"' || true)
# Allowed above: a full update, cache cleaning and reads; "(pacman -S x)" in a
# message; openssh only when missing; the kernel's own headers version (dkms.sh).
[[ -z $bad ]] && pass "no pacman -S/-Sy in guest code outside guest/pkg-add" || { fail "pacman -S outside guest/pkg-add:"; echo "$bad"; }
! grep -q OMACVM_SYSTEM_UPDATE_OK src/app/guest/install.sh src/guest/install.sh src/cmd/apply.sh &&
  grep -q 'vk OMACVM_SYSTEM_UPDATE_OK=1' src/cmd/graphics.sh && grep -q 'read -r -p "Update the VM' src/cmd/graphics.sh &&
  pass "only omacvm graphics updates the VM's system, after asking (or --yes)" || fail "the system update runs from apply, or unasked"
grep -q "^ExecCondition=.*OMACVM_GRAPHICS=vulkan" src/app/guest/venus/omacvm-venus-driver.service &&
  grep -q 'systemctl disable --now omacvm-venus-driver.timer' src/app/guest/install.sh &&
  pass "Venus driver unit only with Graphics Vulkan (or the vulkan feature)" || fail "Venus driver unit also runs with OpenGL"

exit $fails
