#!/bin/bash
# omacvm build's free-space check looks at the drives the build writes to: the
# VM's folder (an external drive, say), and the downloads folder when it is on
# another drive. It used to look at the home folder's drive only, so a VM for
# an SD card was refused on a Mac with a nearly full disk, and one for a full
# SD card was not. No VM, nothing of this Mac's setup touched:
# src/lib/space.sh with made-up drives, and its real helpers on a folder.
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

  # space_problem stops reading at a drive that is too small: the rest of
  # space_targets goes quietly where SIGPIPE is ignored (CI runners: bash's
  # "printf: write error: Broken pipe"). A slow drive look makes it sure.
  drive_id() { sleep 0.3; [[ $1 == /Volumes/SD4TB* ]] && echo sd || echo int; }
  HOME_GB=100 SD_GB=5 SPACE_APP_CACHE=mac
  expect "SIGPIPE ignored, the VM's drive too small: nothing on stderr" "" "$( (trap '' PIPE; try app "$SD" build >/dev/null) 2>&1)"
  exit "$fail"
) || fail=1

# The real helpers: a folder not made yet counts on its drive.
(
  source "$R/src/lib/tools.sh"
  source "$R/src/lib/space.sh"
  expect "a folder not made yet: its drive" "$(stat -L -f %d "$T")" "$(drive_id "$T/no/such/VMs")"
  g=$(free_gb_at "$T/no/such")
  expect "free GB of a folder not made yet" yes "$([[ $g =~ ^[0-9]+$ ]] && echo yes || echo "$g")"
  expect "the home folder's drive by name" "this Mac's disk" "$(HOME=/; drive_name /usr)"
  exit "$fail"
) || fail=1

exit $fail
