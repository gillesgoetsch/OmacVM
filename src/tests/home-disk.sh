#!/bin/bash
# The home disk (docs/adr/0073): a VM whose vm.env has HOME_GB (omacvm build
# --home-gb) gets data.img as a second NVMe disk in every start, and a VM
# without it starts exactly as before. vm-common.sh's QEMU arguments with a
# stand-in QEMU that writes them down, omacvm build's refusals, and omacvm
# check's "home disk" line (check.sh's home_disk_line, as it is). No VM,
# nothing of this Mac's setup touched.
#   src/tests/home-disk.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

echo "== vm-common.sh: what QEMU gets"
# A fake app layout (runtime/bin/OmacVM, firmware, omacvm/src), as src/tests/proxy.sh.
A=$T/app; mkdir -p "$A/scripts" "$A/runtime/bin" "$A/firmware" "$A/omacvm"
cp "$R/app/scripts/vm-common.sh" "$A/scripts/"; ln -s "$R/src" "$A/omacvm/src"
touch "$A/firmware/edk2-aarch64-code.fd"
cat > "$A/runtime/bin/OmacVM" <<END
#!/bin/bash
printf '%s\n' "\$@" > "$T/qemu-args"
sleep 5
END
chmod +x "$A/runtime/bin/OmacVM"
V="$T/a,b"; mkdir -p "$V"   # a comma in the path: QEMU wants it twice
start() {   # [ENV=VALUE...]: vm_load + a start as update-vm.sh makes it; QEMU's arguments
  rm -f "$T/qemu-args"
  # shellcheck disable=SC2163  # "$@" is VAR=VALUE words
  ( export OMACVM_KEY=$T/key "$@"
    source "$A/scripts/vm-common.sh"
    vm_load "$V" >/dev/null
    qemu_headless update "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 >/dev/null
    kill "$(cat "$PIDFILE")" 2>/dev/null ) 2>&1
  cat "$T/qemu-args" 2>/dev/null
}
env_file() { printf 'NAME=T\nCPUS=1\nMEM_MB=512\nDISK_GB=1\nSSH_PORT=1\nVM_USER=t\n%s' "${1:-}" > "$V/vm.env"; }
env_file; plain=$(start)
expect "no HOME_GB: the system disk is the last device, as before" \
  "-device nvme,serial=omacvm,drive=disk,bootindex=0" "$(tail -n 2 <<<"$plain" | paste -sd' ' -)"
expect "no HOME_GB: nothing of a home disk" "" "$(grep -E 'data\.img|omacvm-home' <<<"$plain")"
expect "HOME_GB only in the environment: not this VM's" "$plain" "$(start HOME_GB=8)"
env_file $'HOME_GB=8\n'; home=$(start)
expect "HOME_GB=8: the same arguments, then the home disk" "$plain
-drive
if=none,id=home,file=$T/a,,b/data.img,format=raw,cache=writeback,discard=unmap
-device
nvme,serial=omacvm-home,drive=home" "$home"
env_file $'HOME_GB=big\n'
expect "HOME_GB that is no number: no start" "ERROR: HOME_GB in vm.env is not a number" "$(start)"

echo "== omacvm build --home-gb"
if [[ $(uname -s) == Darwin ]]; then
  out=$("$R/omacvm" build --plan --json --home-gb 0 2>&1); rc=$?
  expect "--home-gb 0: usage" "2 omacvm build: --home-gb: the home disk's size in GB" "$rc $out"
  out=$("$R/omacvm" build --plan --json --home-gb 64 --prebuilt 2>&1); rc=$?
  expect "--home-gb with --prebuilt: usage" "2 omacvm build: --home-gb needs --build: a prebuilt VM has its home on its system disk" "$rc $out"
else
  echo "skip omacvm build runs on macOS"
fi

echo "== omacvm check's \"home disk\" line"
awk '/^home_disk_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh" > "$T/fn.sh"
if grep -q '^home_disk_line()' "$T/fn.sh" && bash -n "$T/fn.sh"; then
  # shellcheck source=/dev/null
  source "$T/fn.sh"
  G=$((1 << 30))
  expect "/home on the disk, xfs, discard: ok" "ok	/home on xfs on nvme1n1 (data.img), 187.5 of 200.0 GiB free; discard" \
    "$(home_disk_line /dev/nvme1n1 /dev/nvme1n1 xfs rw,noatime,attr2,discard,inode64 1 $((375 * G / 2)) $((200 * G)))"
  expect "the disk attached, /home still in @home: fail, says where the steps are" \
    "fail	the home disk (nvme1n1) is attached, but /home is on /dev/nvme0n1p2[/@home] (btrfs): the steps are in docs/routes/app.md, \"A home disk for a VM you have\"" \
    "$(home_disk_line /dev/nvme1n1 '/dev/nvme0n1p2[/@home]' btrfs rw,noatime 1 0 0)"
  expect "xfs that stopped after an error: fail" fail "$(home_disk_line /dev/nvme1n1 /dev/nvme1n1 xfs rw,noatime,discard "" 1 1 | cut -f1)"
  expect "mounted without discard: warn" \
    "warn	/home on xfs on nvme1n1, mounted without discard: what is deleted there keeps its space on the Mac until the weekly trim" \
    "$(home_disk_line /dev/nvme1n1 /dev/nvme1n1 xfs rw,noatime 1 1 1)"
else
  echo "FAIL check.sh has no home_disk_line, or it does not parse"; fail=1
fi

if (( fail )); then echo "FAILED"; else echo "all passed"; fi
exit "$fail"
