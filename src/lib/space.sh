# Free space for omacvm build, on the drives the build writes to (sourced;
# macOS's bash 3.2). A build peaks at about 25 GB: the try-omarchy download
# and the temporary installer (in the downloads folder, about 15 GB at most,
# build-live.sh's own check) and the VM's new disk; a finished VM takes 10-12
# GB and grows as it is used.
#
#   space_targets TYPE DIR SOURCE   "FOLDER<tab>GB" lines: where the build writes, how much it needs there
#   space_problem TYPE DIR SOURCE   a reason the build does not fit, or nothing
#   free_gb_at FOLDER               free GB on the drive of FOLDER, as Finder counts it
#   drive_name FOLDER               the drive as the person knows it ("SD4TB", "this Mac's disk")

SPACE_VM_GB=30      # the VM's folder (with the downloads when they share its drive)
SPACE_CACHE_GB=15   # the downloads folder, when it is on another drive
SPACE_CACHE=$HOME/Library/Caches/omacvm   # build-live.sh's work folder is in here

# FOLDER, or the nearest folder above it that exists (a VMs folder not made yet).
space_existing() {
  local a=${1:-/}
  until [[ -e $a || $a == / ]]; do a=$(dirname "$a"); done
  echo "$a"
}

# Free space as Finder counts it (macOS frees caches and purgeable files when
# needed; df leaves those out), else df's.
free_gb_at() {
  local d g; d=$(space_existing "$1")
  g=$(swift -e 'import Foundation; let v = try? URL(fileURLWithPath: CommandLine.arguments[1]).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]); print((v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)' "$d" 2>/dev/null)
  [[ $g =~ ^[0-9]+$ && $g -gt 0 ]] || g=$(df -g "$d" | awk 'END { print $4 }')
  echo "$g"
}

# The drive, the same way the app's create script tells them apart
# (downloads_dir in app/scripts/vm-common.sh; -L: a link counts where it points).
drive_id() { stat -L -f %d "$(space_existing "$1")"; }

drive_name() {
  local m
  # The mount point is everything after df's fifth column (it can have spaces).
  m=$(df -P "$(space_existing "$1")" | awk 'NR == 2 { sub(/^([^ ]+ +){5}/, ""); print }')
  case $m in
    /Volumes/?*) echo "${m#/Volumes/}" ;;
    *) echo "this Mac's disk" ;;
  esac
}

space_targets() {
  local type=$1 dir=$2 src=$3 label
  label=$(sed "s|^$HOME|~|" <<<"$dir")
  case $type in
    # The app's create script keeps the downloads beside the VMs on another
    # drive, else in the Mac's caches (vm-common.sh downloads_dir): one drive.
    # An OmacVM.app before 3.0.2 keeps them in the Mac's caches
    # (SPACE_APP_CACHE=mac): as for Parallels below.
    app) [[ ${SPACE_APP_CACHE:-} == mac ]] || { printf '%s\t%s\t%s\n' "$dir" "$SPACE_VM_GB" "$label"; return; } ;;
    # --vm-dir: the installer is made in that folder too. Else UTM's library,
    # in its container in the home folder (measured there: the container
    # itself is UTM's, macOS asks before others look into it).
    utm) if [[ -n $dir ]]; then printf '%s\t%s\t%s\n' "$dir" "$SPACE_VM_GB" "$label"; return; fi
         dir=$HOME; label="UTM's library" ;;
  esac
  printf '%s\t%s\t%s\n' "$dir" "$SPACE_VM_GB" "$label"
  # A prebuilt VM's download: prebuilt_space_ok checks it with the image's size.
  [[ $src == prebuilt ]] && return
  [[ $(drive_id "$dir") == "$(drive_id "$SPACE_CACHE")" ]] && return
  printf '%s\t%s\t%s\n' "$SPACE_CACHE" "$SPACE_CACHE_GB" "the download and the temporary installer, $(sed "s|^$HOME|~|" <<<"$SPACE_CACHE")"
}

# Sets SPACE_WHY (the build does not fit: status 1) and SPACE_NOTE (it fits,
# with less than 50 GB left for the VM to grow into).
space_problem() {
  local dir need label free name first=1
  SPACE_WHY=""; SPACE_NOTE=""
  while IFS=$'\t' read -r dir need label; do
    free=$(free_gb_at "$dir"); name=$(drive_name "$dir")
    [[ $free =~ ^[0-9]+$ ]] || continue   # nothing to go by: let it try
    if (( free < need )); then
      SPACE_WHY="OmacVM needs about $need GB free on $name to build ($label); it has $free GB free"
      return 1
    fi
    (( first && free < 50 )) && SPACE_NOTE="$free GB free on $name: enough to build; the VM grows as you use it, so keep some room."
    first=0
  done < <(space_targets "$@")
  return 0
}
