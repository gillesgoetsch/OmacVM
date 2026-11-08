#!/bin/bash
# OmacVM's zram cap (src/memory/guest/90-omacvm-zram.conf: a quarter of the
# VM's memory, at most 8 GiB) is the size zram-generator takes, on Omarchy 4.0
# and 4.5, new and moved VMs (#746). zram-generator reads its drop-ins by file
# name across /usr/lib, /usr/local/lib, /etc and /run, and the file read last
# wins (zram-generator.conf(5)); Omarchy 4.5's /usr/lib/.../90-omarchy.conf
# (zram-size = ram) sorted after OmacVM's old /etc/.../90-omacvm.conf.
# memory/guest/install.sh installs the cap as 95-omacvm.conf (after Omarchy's
# 90-, before a user's own 99-*.conf) and then removes the old name; omacvm
# check's "zram swap" line (src/guest/check.sh: zram_decider, zram_line) warns
# over the cap and says who sets the size. A reference reader here (kept apart
# from check.sh's) says which file decides. install.sh runs with a fake root
# (OMACVM_MEMORY_ROOT); stand-ins for install, rm, sysctl and systemd-tmpfiles
# refuse any path outside the scratch folder (the test then fails).
#   src/tests/memory-zram-order.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
I=$R/src/memory/guest/install.sh
C=$R/src/guest/check.sh
Z=$R/src/memory/guest/90-omacvm-zram.conf
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
has() {   # WHAT WANT-PART GOT: GOT contains WANT-PART
  if [[ $3 == *"$2"* ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want in it: %s\n  got: %s\n' "$1" "$2" "$3"; fail=1; fi
}
lacks() {   # WHAT PART GOT: GOT does not contain PART
  if [[ $3 != *"$2"* ]]; then echo "ok   $1"; else printf 'FAIL %s\n  must not say: %s\n  got: %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-zram-order.XXXXXX"); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
B=$T/bin; mkdir -p "$B"
# Stand-ins (macOS's install has no -D). Each writes only under $T; else it
# records OUTSIDE and fails.
cat > "$B/install" <<EOF
#!/bin/bash
mode=644 a=()
for x in "\$@"; do case \$x in -Dm*) mode=\${x#-Dm} ;; -m*) mode=\${x#-m} ;; -*) ;; *) a+=("\$x") ;; esac; done
case \${a[1]} in "$T"/*) ;; *) echo "OUTSIDE install \${a[1]}" | tee -a "$T/outside" >> "$T/calls"; exit 99 ;; esac
echo "install \${a[1]}" >> "$T/calls"
/bin/mkdir -p "\$(dirname "\${a[1]}")" && /bin/rm -f "\${a[1]}" && /bin/cp "\${a[0]}" "\${a[1]}" && /bin/chmod "\$mode" "\${a[1]}"
EOF
cat > "$B/rm" <<EOF
#!/bin/bash
for x in "\$@"; do
  case \$x in -*) ;; "$T"/*) echo "rm \$x" >> "$T/calls" ;; *) echo "OUTSIDE rm \$x" | tee -a "$T/outside" >> "$T/calls"; exit 99 ;; esac
done
exec /bin/rm "\$@"
EOF
printf '#!/bin/bash\necho "sysctl $*" >> "%s/calls"\n' "$T" > "$B/sysctl"
printf '#!/bin/bash\necho "systemd-tmpfiles $*" >> "%s/calls"\n' "$T" > "$B/systemd-tmpfiles"
chmod 755 "$B"/*

# check.sh's two functions, as they are
awk '/^zram_decider\(\) \{/ || /^zram_line\(\) \{/ {on=1} on {print} on && /^}$/ {on=0}' "$C" > "$T/fn.sh"
if grep -q '^zram_decider()' "$T/fn.sh" && grep -q '^zram_line()' "$T/fn.sh"; then
  # shellcheck disable=SC1091
  source "$T/fn.sh"
else
  echo "FAIL check.sh has no zram_decider or zram_line"; fail=1
  zram_decider() { echo "(no zram_decider in check.sh)"; }
  zram_line() { printf 'none\t(no zram_line in check.sh)\n'; }
fi

# Reference reader, zram-generator.conf(5) and zram-generator 1.2.1 (liboverdrop:
# folders in rising priority usr/lib, usr/local/lib, etc, run; the same name in a
# higher one hides the lower; a link to /dev/null masks a name). Drop-ins in
# byte order of their names; the last one with [zram0] zram-size decides; with
# none, the main file (the first of run, etc, usr/local/lib, usr/lib). Prints
# "PATH VALUE" (PATH without the root), or nothing.
ref() {
  local r=$1 prio dir f n p hit=""
  for prio in 1 2 3 4; do
    dir=$(sed -n "${prio}p" <<< $'usr/lib\nusr/local/lib\netc\nrun')
    for f in "$r/$dir/systemd/zram-generator.conf.d"/*.conf; do
      [[ -e $f || -L $f ]] && printf '%s\t%s\t%s\n' "${f##*/}" "$prio" "$f"
    done
  done | LC_ALL=C sort -t $'\t' -k1,1 -k2,2nr | awk -F'\t' '!seen[$1]++ { print $3 }' > "$T/ref.list"
  while IFS= read -r p; do
    [[ -L $p && $(readlink "$p") == /dev/null ]] && continue
    n=$(awk '/^\[/ { z = ($0 == "[zram0]") } z && /^zram-size *=/ { sub(/^zram-size *= */, ""); v = $0 } END { print v }' "$p")
    [[ -n $n ]] && hit="${p#"$r"} $n"
  done < "$T/ref.list"
  if [[ -z $hit ]]; then
    for dir in run etc usr/local/lib usr/lib; do
      f=$r/$dir/systemd/zram-generator.conf
      [[ -e $f ]] || continue
      n=$(awk '/^\[/ { z = ($0 == "[zram0]") } z && /^zram-size *=/ { sub(/^zram-size *= */, ""); v = $0 } END { print v }' "$f")
      [[ -n $n ]] && hit="${f#"$r"} $n"
      break
    done
  fi
  echo "$hit"
}
apply() {   # ROOT: memory/guest/install.sh on the fake root; prints its exit code
  [[ $1 == "$T"/* ]] || { echo "refused: root $1 is not under $T"; return; }
  PATH="$B:$PATH" OMACVM_MEMORY_ROOT=$1 bash "$I" > "$T/out" 2>&1; echo $?
}
D=/etc/systemd/zram-generator.conf.d
NEW=$D/95-omacvm.conf OLD=$D/90-omacvm.conf
CAP="min(ram / 4, 8192)"
VENDOR=/usr/lib/systemd/zram-generator.conf.d
put() { mkdir -p "$(dirname "$1$2")"; printf '%s\n' "$3" > "$1$2"; }
main40() { put "$1" /etc/systemd/zram-generator.conf $'[zram0]\nzram-size = ram\ncompression-algorithm = zstd\nswap-priority = 100'; }
omarchy45() {   # omarchy-settings 4.5.0-3's file
  put "$1" $VENDOR/90-omarchy.conf '# Compressed swap in RAM. zstd averages around 3:1, so even a full device
# occupies roughly a third of RAM. Any smaller cap spills reclaim to the disk
# swapfile, which on encrypted installs pages back through LUKS.
[zram0]
zram-size = ram
compression-algorithm = zstd

# Above the pri=0 that omarchy-hibernation-setup gives the disk swapfile.
swap-priority = 100'
}
old() { mkdir -p "$1$D"; cp "$Z" "$1$OLD"; }
gone() { [[ -e $1$OLD || -L $1$OLD ]] && echo "still there" || echo gone; }
agree() { expect "  check.sh's zram_decider agrees with the reference" "$(ref "$1" | cut -d' ' -f1)" "$(zram_decider "$1")"; }

expect "the source conf is still OmacVM's cap" "zram-size = $CAP" "$(grep '^zram-size' "$Z")"

echo "== 4.0 VM (main file zram-size = ram, OmacVM's old 90-omacvm.conf)"
r=$T/b40; main40 "$r"; old "$r"; : > "$T/calls"
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  OmacVM's file decides, with the cap" "$NEW $CAP" "$(ref "$r")"
expect "  the old name is gone" gone "$(gone "$r")"
expect "  the main file untouched" "zram-size = ram" "$(grep '^zram-size' "$r/etc/systemd/zram-generator.conf")"
agree "$r"

echo "== new 4.5 VM (Omarchy's /usr/lib 90-omarchy.conf, OmacVM's old file)"
r=$T/n45; omarchy45 "$r"; old "$r"; : > "$T/calls"
expect "  before: Omarchy's file decides (the bug)" "$VENDOR/90-omarchy.conf ram" "$(ref "$r")"
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  OmacVM's file decides, with the cap" "$NEW $CAP" "$(ref "$r")"
expect "  the old name is gone" gone "$(gone "$r")"
expect "  Omarchy's file untouched" "zram-size = ram" "$(grep '^zram-size' "$r$VENDOR/90-omarchy.conf")"
agree "$r"
expect "  the new file is the source conf" same "$(cmp -s "$Z" "$r$NEW" && echo same)"
i=$(grep -n "^install $r$NEW\$" "$T/calls" | cut -d: -f1) d=$(grep -n "^rm $r$OLD\$" "$T/calls" | cut -d: -f1)
expect "  the old name goes only after the new file is in place" yes "$([[ -n $i && -n $d ]] && (( i < d )) && echo yes)"

echo "== moved 4.5 VM (main file, Omarchy's 90-omarchy.conf, OmacVM's old file)"
r=$T/m45; main40 "$r"; omarchy45 "$r"; old "$r"; : > "$T/calls"
expect "  before: Omarchy's file decides (the bug)" "$VENDOR/90-omarchy.conf ram" "$(ref "$r")"
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  OmacVM's file decides, with the cap" "$NEW $CAP" "$(ref "$r")"
expect "  the old name is gone" gone "$(gone "$r")"
agree "$r"
(cd "$r" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$T/once"
expect "  run again: exit 0" 0 "$(apply "$r")"
(cd "$r" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) > "$T/twice"
expect "  run again: the same files, the same contents" same "$(cmp -s "$T/once" "$T/twice" && echo same)"

echo "== a fresh VM (no OmacVM file yet)"
r=$T/fresh; omarchy45 "$r"; : > "$T/calls"
expect "  install.sh exit 0, nothing on stderr about the old name" "0 0" "$(apply "$r") $(grep -c 90-omacvm.conf "$T/out")"
expect "  OmacVM's file decides, with the cap" "$NEW $CAP" "$(ref "$r")"
agree "$r"

echo "== a later Omarchy file in /usr/lib named 99-: it decides, the check names it (no Update VM)"
r=$T/later; omarchy45 "$r"; old "$r"; put "$r" $VENDOR/99-omarchy-zram.conf $'[zram0]\nzram-size = ram'
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  Omarchy's 99- file decides" "$VENDOR/99-omarchy-zram.conf ram" "$(ref "$r")"
agree "$r"
l=$(zram_line 4088397824 3992576 "$(zram_decider "$r")" 1)
expect "  check: WARN" warn "${l%%$'\t'*}"
has "  check names the file" "$VENDOR/99-omarchy-zram.conf" "$l"
lacks "  check does not send the user to Update VM" "Update VM" "$l"

echo "== the user's own /etc/.../99-local.conf (Omarchy's advice): it stays and decides"
r=$T/user; omarchy45 "$r"; old "$r"; put "$r" $D/99-local.conf $'[zram0]\nzram-size = ram / 2'
s0=$(cksum < "$r$D/99-local.conf")
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  the user's file byte for byte" "$s0" "$(cksum < "$r$D/99-local.conf")"
expect "  the user's file decides" "$D/99-local.conf ram / 2" "$(ref "$r")"
agree "$r"
l=$(zram_line 2044723200 3992576 "$(zram_decider "$r")" 1)
expect "  check: ok (the user's choice)" ok "${l%%$'\t'*}"
has "  check names the user's file" "$D/99-local.conf" "$l"

echo "== Omarchy's file masked by the user (/etc/.../90-omarchy.conf -> /dev/null)"
r=$T/mask; omarchy45 "$r"; old "$r"; mkdir -p "$r$D"; ln -s /dev/null "$r$D/90-omarchy.conf"
expect "  install.sh exit 0" 0 "$(apply "$r")"
expect "  OmacVM's file decides" "$NEW $CAP" "$(ref "$r")"
expect "  the mask stays" /dev/null "$(readlink "$r$D/90-omarchy.conf")"
agree "$r"

expect "no stand-in was asked to write outside the scratch folder" 0 "$(cat "$T/outside" 2>/dev/null | grep -c OUTSIDE)"

echo "== omacvm check's \"zram swap\" line (zram_line SIZE_BYTES MEMTOTAL_KB DECIDER OURS)"
G4=3992576 G48=50331648   # MemTotal kB: 3899 MiB (the sweep's 4 GB VMs), 48 GiB
line() {   # WHAT WANT-STATUS WANT-PART ARGS...
  local w=$1 s=$2 p=$3 l; shift 3; l=$(zram_line "$@")
  expect "$w: $s" "$s" "${l%%$'\t'*}"; has "$w: says '$p'" "$p" "$l"
}
line "4 GB VM, the cap (974.5M)" ok "974.5M" 1021837312 3991552 "$NEW" 1
line "4 GB VM, 1 % over (MemTotal moved a little)" ok "OmacVM's cap" 1032056832 3991552 "$NEW" 1
line "48 GB VM, 8 GiB" ok "8G" 8589934592 $G48 "$NEW" 1
line "4.5 before Update VM: 3.8G, Omarchy's file over the old one" warn "Update VM (omacvm apply), then restart the VM" 4088397824 $G4 "$VENDOR/90-omarchy.conf" 0
line "  and names Omarchy's file" warn "$VENDOR/90-omarchy.conf" 4088397824 $G4 "$VENDOR/90-omarchy.conf" 0
line "  and the cap" warn "over OmacVM's cap of 974.8M" 4088397824 $G4 "$VENDOR/90-omarchy.conf" 0
line "48 GB VM before Update VM: 48G" warn "Update VM" 51539607552 $G48 "$VENDOR/90-omarchy.conf" 0
line "the old OmacVM file decides, over the cap" warn "Update VM" 4088397824 $G4 "$OLD" 0
line "no OmacVM file, zram-generator's default" warn "Update VM" 4088397824 $G4 "" 0
line "after Update VM, before the restart" warn "the cap applies at the VM's next restart" 4088397824 $G4 "$NEW" 1
l=$(zram_line 4088397824 $G4 "$NEW" 1); lacks "  no Update VM then" "Update VM" "$l"
line "a /run file decides" warn "/run/systemd/zram-generator.conf.d/99-x.conf" 4088397824 $G4 /run/systemd/zram-generator.conf.d/99-x.conf 1
line "the user's file, over the cap" ok "yours; OmacVM's cap is 974.8M" 4088397824 $G4 "$D/99-local.conf" 1
line "the user's file, before Update VM too" ok "$D/99-local.conf" 4088397824 $G4 "$D/99-local.conf" 0
line "no zram" fail "none (reboot after omacvm apply?)" "" $G4 "$NEW" 1
exit $fail
