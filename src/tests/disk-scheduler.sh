#!/bin/bash
# OmacVM's disk rule (src/disk/guest/61-omacvm-io-scheduler.rules, #778):
# read after Omarchy 4.5's 60-omarchy-io-scheduler.rules (kyber on every
# disk) and before a rule of the user's own (99-*), it sets none on QEMU's
# NVMe and virtio disks only; a USB disk passed in (sd*) keeps Omarchy's
# choice. disk/guest/install.sh puts it in /etc/udev/rules.d (a fake root
# here: nothing outside a scratch folder, no udevadm), Update VM runs it with
# the other steps that are no feature's. Where systemd's udevadm has
# `verify` (the Linux CI job), the rule file must pass it.
#   src/tests/disk-scheduler.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/disk/guest
F=$G/61-omacvm-io-scheduler.rules
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-disk.XXXXXX"); trap 'rm -rf "$T"' EXIT
B=$T/bin; mkdir -p "$B"
# Stand-ins: install writes only under $T (macOS's install has no -D);
# udevadm only records that it was called.
cat > "$B/install" <<EOF
#!/bin/bash
mode=644 a=()
for x in "\$@"; do case \$x in -Dm*) mode=\${x#-Dm} ;; -*) ;; *) a+=("\$x") ;; esac; done
case \${a[1]} in "$T"/*) ;; *) echo "OUTSIDE \${a[1]}" >> "$T/calls"; exit 99 ;; esac
mkdir -p "\$(dirname "\${a[1]}")" && cp "\${a[0]}" "\${a[1]}" && chmod "\$mode" "\${a[1]}"
EOF
printf '#!/bin/bash\necho "udevadm $*" >> "%s/calls"\n' "$T" > "$B/udevadm"
chmod 755 "$B"/*

echo "== install.sh (fake root)"
PATH="$B:$PATH" OMACVM_DISK_ROOT=$T/root bash "$G/install.sh" > "$T/out" 2>&1
expect "exit 0" 0 $?
W=$T/root/etc/udev/rules.d/61-omacvm-io-scheduler.rules
expect "the rule is in /etc/udev/rules.d, as shipped" same "$(cmp -s "$F" "$W" && echo same)"
expect "mode 644" 644 "$(stat -c %a "$W" 2>/dev/null || stat -f %Lp "$W")"
expect "nothing outside the fake root, no udevadm" "" "$(cat "$T/calls" 2>/dev/null)"
PATH="$B:$PATH" OMACVM_DISK_ROOT=$T/root bash "$G/install.sh" > /dev/null 2>&1
expect "again: same file, exit 0" "0 same" "$? $(cmp -s "$F" "$W" && echo same)"

echo "== the order udev reads the rules in (by name across /usr/lib, /run, /etc)"
o=$(printf '%s\n' 50-udev-default.rules 60-omarchy-io-scheduler.rules 99-local.rules "${F##*/}" | LC_ALL=C sort | tr '\n' ' ')
expect "after Omarchy's 60-, before a user's 99-" "50-udev-default.rules 60-omarchy-io-scheduler.rules 61-omacvm-io-scheduler.rules 99-local.rules " "$o"

echo "== what the rule matches and sets"
rules=$(grep -v '^[[:space:]]*#' "$F" | grep -v '^[[:space:]]*$')
expect "two rules" 2 "$(wc -l <<<"$rules" | tr -d ' ')"
expect "every rule: add and change, whole block disks, sets none" 2 \
  "$(grep -c '^ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", .*ATTR{queue/scheduler}="none"$' <<<"$rules")"
expect "NVMe only when QEMU's controller" 'KERNEL=="nvme*", ATTRS{model}=="QEMU NVMe Ctrl",' \
  "$(grep -o 'KERNEL=="nvme\*", ATTRS{model}=="[^"]*",' <<<"$rules")"
expect "virtio disks" 1 "$(grep -c 'KERNEL=="vd\*", ' <<<"$rules")"
expect "every rule acts only while OmacVM's record is there" 2 "$(grep -c ', TEST=="/etc/omacvm/env", ATTR{queue/scheduler}="none"$' <<<"$rules")"
expect "no USB/SD disks (sd*, mmcblk*)" 0 "$(grep -cE 'sd\*|mmcblk' <<<"$rules")"
expect "sets no other attribute" 2 "$(grep -o 'ATTR{[^}]*}=' <<<"$rules" | grep -c 'ATTR{queue/scheduler}=')"

echo "== Update VM runs it"
expect "guest/install.sh: the disk step beside memory (no feature's)" 1 \
  "$(sed -n '/^if system; then$/,/^fi$/p' "$R/src/guest/install.sh" | grep -c '"$R/disk/guest/install.sh"')"

echo "== omacvm check's \"disk scheduler\" line (check.sh's disk_sched_line, as it is; a fake root)"
awk '/^disk_sched_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh" > "$T/fn.sh"
if grep -q '^disk_sched_line()' "$T/fn.sh" && bash -n "$T/fn.sh"; then
  source "$T/fn.sh"
  V=$T/vm; mkdir -p "$V/sys/block/nvme0n1/queue" "$V/etc/udev/rules.d"
  sched() { echo "$1" > "$V/sys/block/nvme0n1/queue/scheduler"; }
  sched '[none] mq-deadline kyber bfq'
  expect "none: ok" "ok	none on nvme0n1: the Mac schedules the VM's disk I/O" "$(disk_sched_line "$V" nvme0n1)"
  sched 'none mq-deadline [kyber] bfq'
  cp "$F" "$T/ours"
  expect "kyber, OmacVM's rule missing: Update VM" "warn	kyber on nvme0n1: OmacVM's rule is missing (Update VM / omacvm apply puts it back)" \
    "$(disk_sched_line "$V" nvme0n1)"
  echo 'ATTR{queue/scheduler}="kyber"' > "$V/etc/udev/rules.d/60-omarchy-io-scheduler.rules"
  cp "$T/ours" "$V/etc/udev/rules.d/61-omacvm-io-scheduler.rules"
  expect "kyber with OmacVM's rule and nothing after it: restart or apply" "warn	kyber on nvme0n1, not none: restart the VM, or run omacvm apply" \
    "$(disk_sched_line "$V" nvme0n1)"
  echo 'ACTION=="add", ATTR{queue/scheduler}="bfq"' > "$V/etc/udev/rules.d/99-local.rules"
  echo '# no scheduler here' > "$V/etc/udev/rules.d/70-other.rules"
  expect "a later rule of the user's sets it: named" "warn	kyber on nvme0n1, set by a rule read after OmacVM's: /etc/udev/rules.d/99-local.rules (yours: your choice)" \
    "$(disk_sched_line "$V" nvme0n1)"
  # A package's rule read later (in /usr/lib, owned by it as pacman -Qqo says): named with the package, not
  # blamed on the user; the same name in /etc hides it (udev reads only the /etc one).
  rm "$V/etc/udev/rules.d/99-local.rules"
  mkdir -p "$V/usr/lib/udev/rules.d"
  echo 'ACTION=="add|change", ATTR{queue/scheduler}="kyber"' > "$V/usr/lib/udev/rules.d/65-pkg-io.rules"
  printf '#!/bin/bash\n[[ $1 == -Qqo && $2 == /usr/lib/udev/rules.d/65-pkg-io.rules ]] && { echo omarchy; exit 0; }\nexit 1\n' > "$B/pacman"
  chmod 755 "$B/pacman"
  expect "a package's rule read later: named with the package" "warn	kyber on nvme0n1, set by a rule read after OmacVM's: /usr/lib/udev/rules.d/65-pkg-io.rules (package omarchy: OmacVM's rule has to come after it, Update VM once OmacVM has that)" \
    "$(PATH="$B:$PATH" disk_sched_line "$V" nvme0n1)"
  echo '# emptied by the user' > "$V/etc/udev/rules.d/65-pkg-io.rules"
  expect "the same name in /etc hides the package's rule" "warn	kyber on nvme0n1, not none: restart the VM, or run omacvm apply" \
    "$(PATH="$B:$PATH" disk_sched_line "$V" nvme0n1)"
  rm "$V/etc/udev/rules.d/65-pkg-io.rules" "$V/usr/lib/udev/rules.d/65-pkg-io.rules"
  expect "no disk: skip" "skip	the VM's disk was not found" "$(disk_sched_line "$V" "")"
  expect "a disk without a queue: skip" "skip	the VM's disk was not found" "$(disk_sched_line "$V" vda)"
else
  echo "FAIL check.sh has no disk_sched_line, or it does not parse"; fail=1
fi
expect "check.sh shows it as \"disk scheduler\" for the root file system's disk" 1 \
  "$(grep -c '^r=$(disk_sched_line / "$dk")$' "$R/src/guest/check.sh")"
# The root's disk: lsblk's inverse list from the root's device up to the entry of type disk (a partition,
# or a partition under device-mapper). A stand-in lsblk with the lists util-linux prints (-nrso NAME,TYPE).
dkline=$(grep '^dk=\$(lsblk ' "$R/src/guest/check.sh")
expect "check.sh finds the root's disk with one lsblk line" 1 "$(grep -c '^dk=\$(lsblk ' "$R/src/guest/check.sh")"
cat > "$B/lsblk" <<'EOF'
#!/bin/bash
case ${!#} in
  /dev/nvme0n1p2) printf 'nvme0n1p2 part\nnvme0n1 disk\n' ;;
  /dev/mapper/root) printf 'root crypt\nnvme0n1p2 part\nnvme0n1 disk\n' ;;
  /dev/vda) printf 'vda disk\n' ;;
esac
EOF
cat > "$B/findmnt" <<'EOF'
#!/bin/bash
echo "$FAKE_ROOT_SRC"
EOF
chmod 755 "$B/lsblk" "$B/findmnt"
printf '%s\n' "$dkline" 'echo "$dk"' > "$T/dk.sh"
for c in "/dev/nvme0n1p2[/@] nvme0n1" "/dev/mapper/root nvme0n1" "/dev/vda vda"; do
  expect "root on ${c%% *}: its disk" "${c##* }" "$(PATH="$B:$PATH" FAKE_ROOT_SRC=${c% *} bash "$T/dk.sh")"
done

if udevadm verify --help >/dev/null 2>&1; then
  echo "== udevadm verify ($(udevadm --version))"
  udevadm verify --resolve-names=never "$F" > "$T/verify" 2>&1
  expect "udevadm verify: no errors" "0" "$?"
  [[ $fail == 0 ]] || cat "$T/verify"
else
  echo "skip udevadm verify (no systemd udevadm with verify here)"
fi
exit $fail
