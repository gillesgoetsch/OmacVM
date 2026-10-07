#!/bin/bash
# omacvm build's free-space check looks at the drives the build writes to: the
# VM's folder (an external drive, say), and the downloads folder when it is on
# another drive. It used to look at the home folder's drive only, so a VM for
# an SD card was refused on a Mac with a nearly full disk, and one for a full
# SD card was not. No VM, nothing of this Mac's setup touched:
# (1) src/lib/space.sh with made-up drives, every route;
# (2) the real src/cmd/build.sh --plan for Parallels with --vm-dir, its own
#     HOME, stand-ins for swift and Parallels' tools: the home folder's drive
#     has 10 GB, the VM's folder 100 GB.
#   src/tests/build-space.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() { [[ $2 == *"$1"* ]] && echo yes || echo "$2"; }

# ---------- (1) the rule, with made-up drives ----------
(
  source "$R/src/lib/space.sh"
  HOME=/Users/p; SPACE_CACHE=$HOME/Library/Caches/omacvm
  SD=/Volumes/SD4TB/OMACVM/VMs
  HOME_GB=10; SD_GB=100
  # Two drives: the home folder's and the SD card.
  drive_id() { [[ $1 == /Volumes/SD4TB* ]] && echo sd || echo int; }
  drive_name() { [[ $1 == /Volumes/SD4TB* ]] && echo SD4TB || echo "this Mac's disk"; }
  free_gb_at() { [[ $1 == /Volumes/SD4TB* ]] && echo "$SD_GB" || echo "$HOME_GB"; }
  try() {   # TYPE DIR SOURCE -> ok, or the reason
    if space_problem "$@"; then echo "ok${SPACE_NOTE:+ / $SPACE_NOTE}"; else echo "$SPACE_WHY"; fi
  }

  for type in parallels fusion; do
    HOME_GB=20 SD_GB=100
    expect "$type --vm-dir on the SD, 20 GB on the Mac: builds" ok "$(try $type "$SD" build)"
    HOME_GB=10
    w=$(try $type "$SD" build)
    expect "$type --vm-dir on the SD, 10 GB on the Mac: the download does not fit" yes \
      "$(has "about 15 GB free on this Mac's disk to build (the download and the temporary installer, ~/Library/Caches/omacvm); it has 10 GB free" "$w")"
    expect "$type --vm-dir on the SD, prebuilt: the download is prebuilt_space_ok's" ok "$(try $type "$SD" prebuilt)"
    HOME_GB=100 SD_GB=20
    w=$(try $type "$SD" build)
    expect "$type --vm-dir on a full SD, 100 GB on the Mac: refused, names the SD" yes \
      "$(has "about 30 GB free on SD4TB to build (/Volumes/SD4TB/OMACVM/VMs); it has 20 GB free" "$w")"
    HOME_GB=25
    w=$(try $type "$HOME/VMs" build)
    expect "$type on the Mac's disk with 25 GB: refused" yes "$(has "30 GB free on this Mac's disk to build (~/VMs); it has 25 GB free" "$w")"
    expect "$type on the Mac's disk: one check (the downloads share the drive)" 1 "$(space_targets $type "$HOME/VMs" build | wc -l | tr -d ' ')"
    HOME_GB=40
    expect "$type on the Mac's disk with 40 GB: builds, keep some room" yes \
      "$(has "ok / 40 GB free on this Mac's disk: enough to build" "$(try $type "$HOME/VMs" build)")"
  done

  # OmacVM.app: its downloads follow the VMs folder, so only that drive counts.
  HOME_GB=5 SD_GB=100
  expect "app, VMs folder on the SD, 5 GB on the Mac: builds" ok "$(try app "$SD" build)"
  expect "app: one check" 1 "$(space_targets app "$SD" build | wc -l | tr -d ' ')"
  SD_GB=12
  expect "app, VMs folder on a full SD: names the SD" yes "$(has "30 GB free on SD4TB to build (/Volumes/SD4TB/OMACVM/VMs); it has 12 GB free" "$(try app "$SD" build)")"
  HOME_GB=12
  expect "app, VMs folder on the Mac: names this Mac's disk" yes "$(has "30 GB free on this Mac's disk to build (~/OmacVM); it has 12 GB free" "$(try app "$HOME/OmacVM" build)")"
  SD_GB=45 HOME_GB=5
  expect "app on the SD with 45 GB: keep some room on the SD" yes "$(has "ok / 45 GB free on SD4TB:" "$(try app "$SD" prebuilt)")"

  # An OmacVM.app before 3.0.2 keeps its downloads in the Mac's caches.
  SPACE_APP_CACHE=mac HOME_GB=10 SD_GB=100
  expect "app before 3.0.2, VMs folder on the SD, 10 GB on the Mac: the download does not fit" yes \
    "$(has "about 15 GB free on this Mac's disk to build (the download and the temporary installer" "$(try app "$SD" build)")"
  HOME_GB=20
  expect "app before 3.0.2, VMs folder on the SD, 20 GB on the Mac: builds" ok "$(try app "$SD" build)"
  expect "app before 3.0.2, VMs folder on the Mac: one check" 1 "$(space_targets app "$HOME/OmacVM" build | wc -l | tr -d ' ')"
  SPACE_APP_CACHE=""

  # UTM: --vm-dir makes the installer and the VM in that folder; else UTM's library.
  HOME_GB=5 SD_GB=100
  expect "utm --vm-dir on the SD, 5 GB on the Mac: builds" ok "$(try utm "$SD" build)"
  SD_GB=20
  expect "utm --vm-dir on a full SD: names the SD" yes "$(has "30 GB free on SD4TB to build (/Volumes/SD4TB/OMACVM/VMs); it has 20 GB free" "$(try utm "$SD" build)")"
  HOME_GB=20
  expect "utm in UTM's library, 20 GB on the Mac: refused" yes "$(has "30 GB free on this Mac's disk to build (UTM's library); it has 20 GB free" "$(try utm "" build)")"
  HOME_GB=60
  expect "utm in UTM's library, 60 GB: builds" ok "$(try utm "" build)"
  exit "$fail"
) || fail=1

# The real helpers: a folder not made yet counts on its drive.
(
  source "$R/src/lib/space.sh"
  expect "a folder not made yet: its drive" "$(stat -L -f %d "$T")" "$(drive_id "$T/no/such/VMs")"
  g=$(free_gb_at "$T/no/such")
  expect "free GB of a folder not made yet" yes "$([[ $g =~ ^[0-9]+$ ]] && echo yes || echo "$g")"
  expect "the home folder's drive by name" "this Mac's disk" "$(HOME=/; drive_name /usr)"
  exit "$fail"
) || fail=1

# ---------- (2) build.sh --plan: Parallels, the VM on another folder ----------
mkdir -p "$T/bin" "$T/home" "$T/ext"
# swift: the free space probe says 100 GB for $T/ext, 10 for anything else;
# the notch probe: none.
cat > "$T/bin/swift" <<EOF
#!/bin/bash
[[ \$1 == -e ]] || { echo none; exit 0; }
[[ \${3:-} == "$T/ext"* ]] && echo 100 || echo 10
EOF
# Parallels Desktop Pro, its default shared network, no VMs.
printf '#!/bin/bash\n[[ $1 == list ]] && echo "STATUS NAME"\nexit 0\n' > "$T/bin/prlctl"
printf '#!/bin/bash\n[[ $1 == info ]] && echo "edition=\\"pro\\" status=\\"ACTIVE\\" cpu_total=8 max_memory=16384"\nexit 0\n' > "$T/bin/prlsrvctl"
chmod +x "$T/bin/"*
plan() {   # VM_DIR -> the plan's exit status and output
  HOME=$T/home PATH="$T/bin:$PATH" PRLCTL=$T/bin/prlctl OMACVM_TEST_IDENTITY=1 \
    "$R/src/cmd/build.sh" --plan --json --build --vm-type parallels --vm-name "Space Test" --cpus 2 --memory-gb 4 --vm-dir "$1" 2>&1 < /dev/null
}
out=$(plan "$T/ext"); rc=$?
expect "build --plan, --vm-dir with 100 GB, 10 GB in the home folder: planned" 0 "$rc"
expect "build --plan: the plan names the folder" yes "$(has "$T/ext" "$out")"
# The downloads stay in the home folder's caches; here on the same drive as
# $T/ext, so that drive alone counts. A full one is refused, naming it.
cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
[[ $1 == -e ]] && echo 12 || echo none
EOF
out=$(plan "$T/ext"); rc=$?
expect "build --plan, --vm-dir with 12 GB: needs a person" 3 "$rc"
expect "build --plan, 12 GB: says where" yes "$(has "$T/ext: only 12 GB free on this Mac's disk (the VM needs about 30)" "$out")"
# No --vm-dir: ~/Parallels, on the home folder's drive.
out=$(HOME=$T/home PATH="$T/bin:$PATH" PRLCTL=$T/bin/prlctl OMACVM_TEST_IDENTITY=1 \
  "$R/src/cmd/build.sh" --plan --json --build --vm-type parallels --vm-name "Space Test" --cpus 2 --memory-gb 4 2>&1 < /dev/null); rc=$?
expect "build --plan, ~/Parallels with 12 GB: needs a person" 3 "$rc"
expect "build --plan, ~/Parallels with 12 GB: names the drive, offers --vm-dir" yes \
  "$(has "OmacVM needs about 30 GB free on this Mac's disk to build (~/Parallels); it has 12 GB free (or put the VM on another drive with --vm-dir)" "$out")"

exit $fail
