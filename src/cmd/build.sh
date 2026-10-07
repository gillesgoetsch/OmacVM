#!/bin/bash
# omacvm build: an Omarchy VM that feels like a native Mac, in Parallels
# Desktop, UTM, VMware Fusion or OmacVM.app, from nothing, in one go (30-70
# minutes, mostly downloads; OmacVM.app 10-30; Fusion about 15 more, it builds
# Hyprland with a fix).
#
#   omacvm build             asks a few questions, shows a summary, then builds
#   omacvm build --dry-run   asks the questions and shows the summary only
#   omacvm build --plan --json   the summary as JSON, nothing built (agents)
#   omacvm build --prebuilt  download a prebuilt VM instead (faster); --build: build it here
#
# Everything can also be given up front (--yes skips the questions; the
# password then comes from OMACVM_PASSWORD):
#   --vm-type parallels|utm|fusion|app   --vm-name NAME   --hostname NAME
#   --resources low|balanced|high|best   --cpus N   --memory-gb N   --disk-gb N
#   --vm-dir PATH   where the VM goes, an external drive for example (Parallels, UTM, Fusion;
#                   default: the app's own folder or library)
#   --graphics-gb N   VMware Fusion: graphics memory, part of the VM's memory (1-8)
#   --user NAME   --full-name "NAME"
#   --parallels-edition standard|pro   only while Parallels has no licence yet
#                (a fresh install; the trial is Pro): the limits to size the VM by
#   --feature NAME=on|off, or --FEATURE / --no-FEATURE (omacvm features lists
#   them: bridge wallpaper gestures scroll-momentum omanotch mac-clock camera battery external-brightness no-idle-lock autologin thp-kernel
#   x86-apps; idle-lock, its name before 3.0.1, the other way round)
# The keyboard layout, timezone and language come from this Mac. Needs Apple
# Silicon, Parallels Desktop 19+, UTM 5, VMware Fusion 13+ or OmacVM.app, and
# Homebrew's zstd + e2fsprogs (not for OmacVM.app, which builds the VM with its
# own script). Fusion VMs go to ~/Virtual Machines.localized, or
# $OMACVM_FUSION_DIR; OmacVM.app's to the folder set in the app.
# Exit codes: 0 built, 1 failed, 2 usage (or a question without a terminal),
# 3 needs a person (an app to install, see the message).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/vm/utm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/ui.sh"
source "$R/src/lib/prereq.sh"
source "$R/src/prebuilt/lib.sh"
source "$R/src/prebuilt/vm.sh"
source "$R/src/lib/proxy.sh"
source "$R/src/lib/space.sh"
features_load
# Bash 3.2 gives the EXIT trap status 0 after a set -u abort: only DONE=1 (set
# right before each successful exit) counts as success.
DONE=0
trap 'rc=$?; (( rc || DONE )) || rc=1; ui_restore; exit $rc' EXIT

# The Linux user name suggested from the Mac's: lower case, letters, digits,
# - and _ only, starting with a letter ("Gilles.Goetsch" -> "gillesgoetsch").
linux_name() {
  local n; n=$(iconv -f UTF-8 -t ASCII//TRANSLIT <<<"$1" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  n=${n#"${n%%[a-z_]*}"}
  printf '%s' "${n:0:32}"
}
TYPE=""; VM="Omarchy"; RES=""; CPUS=""; MEM_GB=""; DISK_GB=""; U=$(linux_name "$(id -un)"); FULL=""; HOST="omarchy"
[[ -n $U ]] || U=omarchy
BRIDGE=1; WALLPAPER=1; GESTURES=1; GLIDE=1; OMANOTCH=""; MAC_CLOCK=1; CAMERA=1; BATTERY=""; EXT_BRIGHTNESS=1; CHROMIUM_VIDEO=1; NO_IDLE_LOCK=0; AUTOLOGIN=0; THP=0; CONTROL=1; X86=0
CHANNEL=""; YES=0; DRY=0; PLAN=0; JSON=0; IMAGE=0; SOURCE=""
usage() { echo "omacvm build: $*" >&2; exit 2; }
needs_person() { printf '\033[1;31mneeds you:\033[0m %s\n' "$*" >&2; exit 3; }
feature_flag() {   # NAME on|off
  local v; [[ $2 == on ]] && v=1 || v=0
  case $1 in
    idle-lock) [[ $2 == on || $2 == off ]] || usage "--feature $1=$2: on or off"
               feature_flag no-idle-lock "$( [[ $2 == on ]] && echo off || echo on)"; return ;;   # its name before 3.0.1
    bridge) BRIDGE=$v; (( v )) || { WALLPAPER=0; EXT_BRIGHTNESS=0; } ;;
    wallpaper) WALLPAPER=$v ;;
    gestures) GESTURES=$v ;;
    scroll-momentum) GLIDE=$v ;;
    omanotch) OMANOTCH=$v ;;
    mac-clock) MAC_CLOCK=$v ;;
    camera) CAMERA=$v ;;
    battery) BATTERY=$v ;;
    external-brightness) EXT_BRIGHTNESS=$v ;;
    chromium-video) CHROMIUM_VIDEO=$v ;;
    no-idle-lock) NO_IDLE_LOCK=$v ;;
    autologin) AUTOLOGIN=$v ;;
    thp-kernel) THP=$v ;;
    x86-apps) X86=$v ;;
    control-centre) CONTROL=$v ;;
    fast-network) [[ $2 == off ]] || usage "the fast network goes on after the build: omacvm enable fast-network --vm NAME" ;;
    vulkan) [[ $2 == off ]] || usage "Vulkan goes on after the build: omacvm enable vulkan --vm NAME" ;;
    *) usage "unknown feature '$1' (omacvm features lists them)" ;;
  esac
  [[ $2 == on || $2 == off ]] || usage "--feature $1=$2: on or off"
}
while (( $# )); do
  # A missing value is a usage error, not a set -u abort.
  case $1 in
    --vm-type|--vm-name|--vm-dir|--graphics-gb|--resources|--cpus|--memory-gb|--disk-gb|--user|--full-name|--hostname|--feature|--parallels-edition|--channel)
      [[ $# -ge 2 ]] || usage "$1 needs a value" ;;
  esac
  case $1 in
    --vm-type) TYPE=$2; shift 2 ;;
    --vm-name) VM=$2; NAME_GIVEN=1; shift 2 ;;
    --vm-dir) VM_DIR=$2; shift 2 ;;
    --graphics-gb) GFX_GB=$2; shift 2 ;;
    --resources) RES=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-gb) MEM_GB=$2; shift 2 ;;
    --disk-gb) DISK_GB=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --full-name) FULL=$2; shift 2 ;;
    --hostname) HOST=$2; shift 2 ;;
    --feature) feature_flag "${2%%=*}" "${2#*=}"; shift 2 ;;
    --parallels-edition) P_PLAN=$2; shift 2
      [[ $P_PLAN == standard || $P_PLAN == pro ]] || usage "--parallels-edition standard or pro" ;;
    --channel) CHANNEL=$2; shift 2 ;;          # rc|stable|edge, for testing omarchy-mac
    --image) IMAGE=1; YES=1; shift ;;           # a VM for a prebuilt image (src/prebuilt/make-image.sh)
    --no-mac) NO_MAC=1; shift ;;                # tests: leave this Mac's apps as they are
    --prebuilt) SOURCE=prebuilt; shift ;;
    --build) SOURCE=build; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --plan) PLAN=1; DRY=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,29s/^# \{0,1\}//p' "$0"; DONE=1; exit 0 ;;
    --no-*) feature_flag "${1#--no-}" off; shift ;;
    --*) feature_flag "${1#--}" on; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ $(uname -m) == arm64 ]] || die "OmacVM needs an Apple Silicon Mac"
macos=$(sw_vers -productVersion 2>/dev/null)
(( ${macos%%.*} >= 14 )) || { printf '\033[1;31mneeds you:\033[0m OmacVM needs macOS 14 (Sonoma) or newer; this Mac runs %s\n' "$macos" >&2; exit 3; }
(( JSON )) && ! (( PLAN )) && usage "--json goes with --plan"
(( PLAN && JSON )) && YES=1   # a plan for an agent never asks
(( YES )) || { : < "$TTY"; } 2>/dev/null || usage "the setup questions need a terminal (or pass --yes and the answers as options, see --help)"
onoff() { (( $1 )) && echo on || echo off; }

mac_specs
free_gb=$(free_gb_at "$HOME")   # the disk size's default; the room to build is checked once the VM's folder is known
NOTCH=$(mac_tool mac-notch 2>/dev/null || echo none)
[[ -n $OMANOTCH ]] || { [[ $NOTCH == notch ]] && OMANOTCH=1 || OMANOTCH=0; }

if (( ! JSON )); then
  printf '\n  \033[1;36m⌘\033[0m \033[1mOmacVM %s\033[0m  Omarchy in a VM on your Mac, feeling native\n' "$(cat "$R/src/VERSION")"
  (( YES )) || prereq_screen
fi


# ---------- 1. Parallels, UTM, VMware Fusion or OmacVM.app ----------
if [[ -z $TYPE ]]; then
  (( YES )) && usage "--yes needs --vm-type parallels, utm, fusion or app"
  # OmacVM.app first: the README recommends it.
  ui_select pick "Where should Omarchy run?" 0 \
    "OmacVM.app|recommended · free · its own app, nothing else to install · hardware video · every display" \
    "UTM|free · one display, slower desktop · UTM 5 (beta)" \
    "VMware Fusion|free · every display · slower desktop · OmacVM patches Hyprland for it" \
    "Parallels Desktop|near-native speed, every display · paid"
  case $pick in 0) TYPE=app ;; 1) TYPE=utm ;; 2) TYPE=fusion ;; *) TYPE=parallels ;; esac
  say "    Comparison: $README_ROUTES"
fi
# What the build needs: Xcode's command line tools (installed after asking),
# except for OmacVM.app run from the app's own omacvm ("omacvm in Terminal",
# the control centre): the app carries python3, the Swift answers and its Mac
# helpers ready made (src/lib/tools.sh). Homebrew's tools wait for the route.
# A plan or a dry run only reports.
if [[ $TYPE == app ]] && ! have_xcode_tools && _tools_own_resources >/dev/null && tools_python >/dev/null; then
  :
elif (( DRY )); then
  have_xcode_tools || needs_person "Xcode's command line tools are missing: xcode-select --install"
else
  ensure_xcode_tools
  ensure_swift_works
fi
# The app itself: installed now (after asking) when it is missing.
(( DRY )) || ensure_vm_app "$TYPE"
CAP_CPUS=$mac_cores; CAP_MEM_GB=$mac_mem_gb; P_EDITION=""; P_TRIAL=""
case $TYPE in
  parallels)
    if (( YES )); then
      rc=1; [[ -x $PRLCTL ]] && { parallels_limits && rc=0 || rc=$?; }
      # A fresh install starts its trial when the VM starts: the planned edition.
      (( rc == 3 )) && { parallels_planned_limits "${P_PLAN:-standard}"; rc=0; }
      (( rc != 2 )) || needs_person "Parallels Desktop reports no active licence yet (${P_STATUS:-no status}): start the trial or sign in, then run this again"
      (( rc == 0 )) || needs_person "Parallels Desktop is not installed and set up: install it (https://www.parallels.com/products/desktop/ or brew install --cask parallels), open it once and sign in or start the trial"
    else wait_for_app parallels; fi
    vm_network_ok parallels || needs_person "Parallels' shared network is not its default (see above)"
    (( CAP_CPUS > mac_cores )) && CAP_CPUS=$mac_cores
    (( CAP_MEM_GB > mac_mem_gb )) && CAP_MEM_GB=$mac_mem_gb ;;
  utm)
    if (( YES )); then [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )) || { utm_install_help >&2; needs_person "UTM 5 is not installed (brew install --cask utm@beta, then open UTM once)"; }
    else wait_for_app utm; fi
    if ! (( DRY )); then why=$(utm_scripting) || needs_person "$why"; fi ;;
  fusion)
    if (( YES )); then have_fusion || needs_person "VMware Fusion is not installed: download it from support.broadcom.com (free, needs a sign-in), then open it once"
    else wait_for_app fusion; fi
    vm_network_ok fusion || needs_person "VMware Fusion's NAT network is missing (see above)" ;;
  app)
    # Missing: installed above (ensure_vm_app); a plan or a dry run only checks
    # that this version's download is there.
    if ! APP=$(app_bundle); then
      (( DRY )) || die "OmacVM.app is not installed"
      APP=""; app_published "$(cat "$R/src/VERSION")" || app_not_published "$(cat "$R/src/VERSION")"
    elif (( ! JSON )) && app_version_lt "$(app_version "$APP")" "$(cat "$R/src/VERSION")"; then
      info "OmacVM.app $(app_version "$APP") is older than this OmacVM ($(cat "$R/src/VERSION")): omacvm update updates it"
    fi
    if (( ! DRY )) && other=$(app_other_running ""); then
      needs_person "OmacVM.app runs one VM at a time and the build starts the new one at its end: shut down '$other' first"
    fi ;;
  *) usage "--vm-type parallels, utm, fusion or app" ;;
esac
# The Mac's battery: on with one, except on Parallels (it shows it itself).
i=$(feature_index battery)
if [[ -z $BATTERY ]]; then [[ $(feature_default "$i") == on ]] && BATTERY=1 || BATTERY=0
elif (( BATTERY )) && ! feature_available "$i"; then (( JSON )) || info "${FTITLE[$i]}: off ($REASON)"; BATTERY=0; fi
# Chromium's video on the Mac's media engine: OmacVM.app VMs only.
[[ $TYPE == app ]] || CHROMIUM_VIDEO=0
# Homebrew and its zstd, e2fsprogs and OpenSSL (installed after asking), for
# the routes that build the disk here. OmacVM.app brings its own tools.
(( DRY )) || [[ $TYPE == app ]] || ensure_brew_tools
# ---------- build it here, or download a prebuilt VM ----------
build_minutes() { case $TYPE in fusion) echo "45 to 85" ;; app) echo "10 to 30" ;; *) echo "30 to 70" ;; esac; }
PB_OK=0
# An older installed OmacVM.app has no script for images (omacvm update brings it).
APP_OLD=0
[[ $TYPE == app && -n ${APP:-} ]] && ! app_has_prebuilt "$APP" && APP_OLD=1
# The version the image must fit: the app's when it makes the VM (it may be
# older or newer than this omacvm), so both find the same image.
PB_FOR=$(cat "$R/src/VERSION")
if [[ $TYPE == utm && -n ${VM_DIR:-} ]]; then
  (( IMAGE )) && usage "--vm-dir: an image VM for UTM goes into UTM's library"
  if [[ $SOURCE == prebuilt ]] && ! (( PLAN && JSON )); then
    info "A prebuilt UTM VM goes into UTM's library: building it here instead, so it can go into $VM_DIR (about $(build_minutes) minutes)."
  fi
  SOURCE=build
fi
if [[ $SOURCE != build ]] && ! (( IMAGE || APP_OLD )); then
  if [[ $TYPE == app && -n ${APP:-} ]]; then
    PB_FOR=$(app_version "$APP" || cat "$R/src/VERSION")
    app_prebuilt_lookup "$APP" && PB_OK=1
  else
    prebuilt_lookup "$TYPE" 2>/dev/null && PB_OK=1
  fi
fi
if [[ -z $SOURCE ]]; then
  SOURCE=build
  if (( PB_OK && ! YES )); then
    ui_select how "How should OmacVM make the VM?" 1 \
      "Build it yourself|about $(build_minutes) minutes, everything from Arch Linux ARM and omarchy-mac" \
      "Download a prebuilt VM|faster: about $(pb_gb "$PB_SIZE") GB, Omarchy ${PB_OMARCHY%% *}, updated to OmacVM $PB_FOR on the way"
    (( how == 1 )) && SOURCE=prebuilt
  fi
elif [[ $SOURCE == prebuilt ]] && ! (( PB_OK )); then
  # No image for this app and OmacVM version (or no connection): build it here.
  if (( APP_OLD )); then
    (( PLAN && JSON )) || info "OmacVM.app $(app_version "$APP") makes no VMs from prebuilt images (omacvm update updates it): building it here instead (about $(build_minutes) minutes)."
  else
    (( PLAN && JSON )) || info "No prebuilt $TYPE VM for OmacVM ${PB_FOR%%.*}.x up to $PB_FOR: building it here instead (about $(build_minutes) minutes)."
  fi
  SOURCE=build
fi
# OmacVM.app also takes at most 64 characters and no '..' (VMConfig.validName).
NAME_RE='^[A-Za-z0-9][A-Za-z0-9 ._-]*$'
[[ $TYPE == app ]] && NAME_RE='^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
app_name_bad() { [[ $TYPE == app && $1 == *..* ]]; }
[[ $VM =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] || usage "--vm-name: letters, digits, spaces, dots, _ and - only (got '$VM')"
[[ $VM =~ $NAME_RE ]] || usage "--vm-name: at most 64 characters for OmacVM.app"
app_name_bad "$VM" && usage "--vm-name: no '..' for OmacVM.app"
# A name is taken in any app: omacvm --vm NAME has to find one VM.
vm_taken() {
  [[ -e "$HOME/Parallels/$1.pvm" || -e $(fusion_bundle "$1") ]] || vms_list | awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }'
}
if vm_taken "$VM"; then
  n=2; while vm_taken "$VM $n"; do n=$((n + 1)); done
  if (( YES )); then
    [[ -n ${NAME_GIVEN:-} ]] && usage "a VM named '$VM' already exists (choose another --vm-name, e.g. '$VM $n')"
    VM="$VM $n"   # the default name, taken: the next free one
  fi
fi
if vm_taken "$VM"; then
  hd "You already have a VM named '$VM'"
  while :; do
    name=$(ask_value "name for the new VM" "$VM $n" "$NAME_RE")
    app_name_bad "$name" && { say "    OmacVM.app takes no '..' in a name"; continue; }
    VM=$name
    vm_taken "$VM" || break
    say "    '$VM' exists too"
  done
fi
# ---------- 2. resources ----------
LIMITED=""
if [[ $TYPE == parallels && $CAP_CPUS -le 4 ]]; then
  if [[ -n ${P_PLANNED:-} ]]; then
    LIMITED="You plan on Parallels Desktop Standard: $CAP_CPUS CPUs / $CAP_MEM_GB GB per VM; Pro raises this to 18 CPUs / 128 GB."
  else
    LIMITED="Parallels Desktop $(tr '[:lower:]' '[:upper:]' <<<"${P_EDITION:0:1}")${P_EDITION:1} allows $CAP_CPUS CPUs / $CAP_MEM_GB GB per VM; Pro raises this to 18 CPUs / 128 GB."
  fi
fi
case ${RES:-balanced} in low) tier=0 ;; balanced) tier=1 ;; high) tier=2 ;; best) tier=3 ;; *) usage "--resources low|balanced|high|best" ;; esac
tier_values 0; low="$T_CPUS/$T_MEM"; tier_values 3
if [[ $low == "$T_CPUS/$T_MEM" && -n $LIMITED ]]; then
  (( YES )) || { hd "Resources"; say "    $LIMITED"; say "    The VM gets that: $T_CPUS CPUs, $T_MEM GB memory."; }
  tier=3
elif (( ! YES )) && [[ -z $CPUS && -z $MEM_GB && -z $RES ]]; then
  say ""
  say "    The VM keeps memory it has touched until it stops; Best leaves macOS and the"
  say "    GPU a buffer of $(( mac_mem_gb / 4 > 8 ? mac_mem_gb / 4 : 8 )) GB.${LIMITED:+ $LIMITED}"
  opts=()
  for t in 0 1 2 3; do tier_values "$t"; rec=""; (( t == 1 )) && rec="  (recommended)"; opts+=("${TIERS[$t]}|$T_CPUS CPUs, $T_MEM GB memory$rec"); done
  opts+=("Custom|choose CPUs, memory and the disk size")
  ui_select tier "How much of this Mac ($mac_cores CPUs, $mac_mem_gb GB) should the VM get?" 1 "${opts[@]}"
  (( tier == 4 )) && { custom=1; tier=1; }
fi
tier_values "$tier"
: "${CPUS:=$T_CPUS}"; : "${MEM_GB:=$T_MEM}"
: "${DISK_GB:=$(( free_gb >= 400 ? 200 : 128 ))}"
if (( ${custom:-0} )); then
  CPUS=$(ask_value "CPUs (1-$CAP_CPUS)" "$CPUS" '^[0-9]+$')
  MEM_GB=$(ask_value "memory in GB (4-$CAP_MEM_GB)" "$MEM_GB" '^[0-9]+$')
  DISK_GB=$(ask_value "disk size limit in GB (64 or more; it only takes what it holds)" "$DISK_GB" '^[0-9]+$')
fi
[[ $CPUS =~ ^[0-9]+$ ]] && (( CPUS >= 1 && CPUS <= CAP_CPUS )) || usage "--cpus: 1 to $CAP_CPUS${LIMITED:+ ($LIMITED)}"
[[ $MEM_GB =~ ^[0-9]+$ ]] && (( MEM_GB >= 4 && MEM_GB <= CAP_MEM_GB )) || usage "--memory-gb: 4 to $CAP_MEM_GB GB${LIMITED:+ ($LIMITED)}"
[[ $DISK_GB =~ ^[0-9]+$ ]] && (( DISK_GB >= 64 )) || usage "--disk-gb: at least 64"
# VMware Fusion: the GPU's memory comes out of the VM's own. A quarter of it,
# up to Fusion's 8 GB (two Retina displays need several GB).
if [[ $TYPE == fusion ]]; then
  gfx_auto=$(( MEM_GB / 4 )); (( gfx_auto > 8 )) && gfx_auto=8; (( gfx_auto < 1 )) && gfx_auto=1
  if (( ${custom:-0} )) && [[ -z ${GFX_GB:-} ]]; then
    GFX_GB=$(ask_value "graphics memory in GB, part of the VM's memory (1-8)" "$gfx_auto" '^[0-9]+$')
  fi
  : "${GFX_GB:=$gfx_auto}"
  [[ $GFX_GB =~ ^[0-9]+$ ]] && (( GFX_GB >= 1 && GFX_GB <= 8 && GFX_GB < MEM_GB )) || usage "--graphics-gb: 1 to 8, less than the VM's memory"
fi

# ---------- where the VM goes ----------
# Any folder (an external drive, say). UTM keeps its VMs in its own library on
# the Mac's disk; with a folder, the build has UTM move the new VM there
# (utm_move). A prebuilt UTM VM goes into UTM's library (prebuilt_make_vm).
default_dir() { case $TYPE in parallels) echo "$HOME/Parallels" ;; fusion) echo "$FUSION_DIR" ;; utm) echo "UTM's library" ;; app) app_vms_root ;; esac; }
vm_dir_problem() {   # DIR -> a reason it does not work, or nothing
  local fs dev
  [[ -d $1 && -w $1 ]] || { echo "not a folder you can write to"; return; }
  # By the device, not the mount point (which can have spaces).
  dev=$(df -P "$1" | awk 'END { print $1 }')
  fs=$(diskutil info -plist "$dev" 2>/dev/null | plutil -extract FilesystemType raw -o - - 2>/dev/null)
  case $fs in apfs|hfs) ;; *) echo "its drive is ${fs:-unknown}: a VM disk needs APFS or Mac OS Extended (Disk Utility can erase it as APFS)"; return ;; esac
  local g; g=$(free_gb_at "$1")
  (( g >= SPACE_VM_GB )) || echo "only $g GB free on $(drive_name "$1") (the VM needs about $SPACE_VM_GB)"
}
if [[ -n ${VM_DIR:-} && $TYPE == app ]]; then usage "--vm-dir: OmacVM.app keeps its VMs in the folder set in the app"; fi
if [[ -z ${VM_DIR:-} && $TYPE != app ]] && (( ! YES )) && ! [[ $TYPE == utm && $SOURCE == prebuilt ]]; then
  ui_select loc "Where should the VM go?" 0 "Default|$(default_dir | sed "s|^$HOME|~|")" \
    "Another folder…|an external drive, for example (a Finder window opens)"
  while (( loc == 1 )); do
    VM_DIR=$(osascript -e 'POSIX path of (choose folder with prompt "Where should the Omarchy VM go?")' 2>/dev/null) ||
      VM_DIR=$(ask_value "folder for the VM" "" '^/')
    VM_DIR=${VM_DIR%/}
    p=$(vm_dir_problem "$VM_DIR")
    [[ -z $p ]] && break
    say "    $VM_DIR: $p"
    ui_select loc "Where should the VM go?" 1 "Default|$(default_dir | sed "s|^$HOME|~|")" "Another folder…|pick again"
    (( loc == 0 )) && VM_DIR=""
  done
fi
if [[ -n ${VM_DIR:-} ]]; then
  VM_DIR=${VM_DIR%/}
  p=$(vm_dir_problem "$VM_DIR"); [[ -z $p ]] || needs_person "--vm-dir $VM_DIR: $p"
  VM_DIR=$(cd "$VM_DIR" && pwd)   # absolute: the live build runs in its own folder
  dev=$(df -P "$VM_DIR" | awk 'END { print $1 }')
  if diskutil info "$dev" 2>/dev/null | grep -qE "Device Location: +External|Removable Media: +Removable"; then
    EXTERNAL=1
    (( PLAN && JSON )) || info "On an external drive: connect it before you start the VM, and never unplug it while the VM runs."
  fi
  [[ $TYPE == fusion ]] && FUSION_DIR=$VM_DIR
fi
VM_DIR_GIVEN=${VM_DIR:-}
[[ -n ${VM_DIR:-} || $TYPE == utm ]] || VM_DIR=$(default_dir)
case $TYPE in
  parallels) [[ ! -e $VM_DIR/$VM.pvm ]] || usage "$VM_DIR/$VM.pvm already exists (choose another --vm-name)" ;;
  fusion) [[ ! -e $(fusion_bundle "$VM") ]] || usage "$(fusion_bundle "$VM") already exists (choose another --vm-name)" ;;
  utm) [[ -z ${VM_DIR:-} || ! -e $VM_DIR/$VM.utm ]] || usage "$VM_DIR/$VM.utm already exists (choose another --vm-name)" ;;
  app) if d=$(app_missing_drive "$VM_DIR"); then
         needs_person "$d is not connected, and OmacVM.app's VMs folder is on it ($VM_DIR): connect it, or pick another folder in the app"
       fi
       [[ ! -e $VM_DIR/$VM ]] || usage "$VM_DIR/$VM already exists (choose another --vm-name)"
       if [[ -d $VM_DIR ]]; then p=$(vm_dir_problem "$VM_DIR"); [[ -z $p ]] || needs_person "$VM_DIR (OmacVM.app's VMs): $p"; fi ;;
esac
# Room to build on the drives the build writes to: the VM's folder, and the
# downloads folder when it is on another drive (not this Mac's disk when the
# VM goes to an external one).
SPACE_APP_CACHE=""
if [[ $TYPE == app && -n ${APP:-} ]] && ! grep -q downloads_dir "$APP/Contents/Resources/scripts/vm-common.sh" 2>/dev/null; then
  SPACE_APP_CACHE=mac   # OmacVM.app before 3.0.2: its downloads stay in the Mac's caches
fi
if ! space_problem "$TYPE" "${VM_DIR:-}" "$SOURCE"; then
  case $TYPE in
    parallels|fusion|utm) [[ -n $VM_DIR_GIVEN ]] || SPACE_WHY+=" (or put the VM on another drive with --vm-dir)" ;;
    app) if [[ $SPACE_APP_CACHE == mac && $SPACE_WHY == *"the download"* ]]; then
           SPACE_WHY+=" (omacvm update updates OmacVM.app, which then keeps its downloads on the VMs folder's drive)"
         else SPACE_WHY+=" (or pick a VMs folder on another drive in OmacVM.app)"; fi ;;
  esac
  needs_person "$SPACE_WHY"
fi
[[ -z $SPACE_NOTE ]] || (( PLAN && JSON )) || info "$SPACE_NOTE"

# ---------- 3. features ----------
# The build's switches by feature name (src/features.tsv).
fvar() {
  case $1 in
    bridge) echo BRIDGE ;; wallpaper) echo WALLPAPER ;; gestures) echo GESTURES ;;
    scroll-momentum) echo GLIDE ;; omanotch) echo OMANOTCH ;; mac-clock) echo MAC_CLOCK ;; camera) echo CAMERA ;; no-idle-lock) echo NO_IDLE_LOCK ;;
    battery) echo BATTERY ;; external-brightness) echo EXT_BRIGHTNESS ;; chromium-video) echo CHROMIUM_VIDEO ;;
    autologin) echo AUTOLOGIN ;; thp-kernel) echo THP ;; control-centre) echo CONTROL ;;
    x86-apps) echo X86 ;;
  esac
}
fget() { local v; v=$(fvar "$1"); echo "${!v:-0}"; }
fput() { local v; v=$(fvar "$1"); [[ -n $v ]] && printf -v "$v" '%s' "$2"; return 0; }
explain_features() {
  local i v state
  for ((i = 0; i < ${#FN[@]}; i++)); do
    feature_has_tag "$i" app-only && continue
    v=$(fget "${FN[$i]}")
    state=$( ((v)) && echo on || echo off)
    [[ ${FN[$i]} == no-idle-lock ]] && state=$( ((v)) && echo "on, the Mac's lock" || echo "off, Omarchy's own")
    [[ ${FN[$i]} == omanotch && $NOTCH != notch ]] && state="off (no notch)"
    feature_has_tag "$i" laptop && ! feature_available "$i" && state="off ($REASON)"
    printf '    %-48s %s%s\n' "${FTITLE[$i]}" "$state" "$(feature_has_tag "$i" experimental && echo "  (experimental)")"
  done
}
if (( ! YES )); then
  UI_KEYS=(); UI_LABELS=(); UI_DETAILS=(); UI_ON=(); UI_TAG=(); UI_OFF_REASON=(); UI_NEEDS=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    # Opt-in after the build (omacvm enable): the fast network.
    feature_has_tag "$i" app-only && continue
    UI_KEYS+=("${FN[$i]}"); UI_LABELS+=("${FTITLE[$i]}"); UI_DETAILS+=("${FSUM[$i]}")
    UI_ON+=("$(fget "${FN[$i]}")")
    t=""; feature_has_tag "$i" experimental && t=experimental; feature_has_tag "$i" slow && t=slow
    UI_TAG+=("$t")
    r=""; feature_available "$i" || r=$REASON
    UI_OFF_REASON+=("$r")
    n=${FNEEDS[$i]}; [[ $n == - ]] && n=""; UI_NEEDS+=("$n")
  done
  ui_checklist "Features (the recommended ones are on; switch any later with omacvm features)"
  for ((i = 0; i < ${#UI_KEYS[@]}; i++)); do fput "${UI_KEYS[$i]}" "${UI_ON[$i]}"; done
fi
(( GESTURES )) || GLIDE=0
(( BRIDGE )) || { WALLPAPER=0; EXT_BRIGHTNESS=0; }

# ---------- 4. you ----------
: "${FULL:=$(id -F 2>/dev/null || echo "$U")}"
if (( ! YES )); then
  hd "Your user in Omarchy"
  U=$(ask_value "user name" "$U" '^[a-z_][a-z0-9_-]{0,31}$')
  FULL=$(ask_value "full name" "$FULL" '.')
fi
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || usage "--user '$U': lower-case letters, digits, - and _ only"
[[ $HOST =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || usage "--hostname '$HOST': letters, digits and - only (not first or last), up to 63"

KB_NOTE=$("$R/src/keyboard/mac-layout.sh" 2>&1 >/dev/null)
KB=$("$R/src/keyboard/mac-layout.sh" 2>/dev/null)
KB_SHOWN="$KB   (from the Mac)"
[[ -n $KB_NOTE ]] && KB_SHOWN="$KB   (no Linux match for your Mac's layout yet: set yours in Omarchy's keyboard settings)"
TZ_MAC=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^A-Za-z-]//gp')   # e.g. de-CH
region=$(defaults read -g AppleLocale 2>/dev/null | sed 's/@.*//')                 # e.g. de_CH
case $lang in
  en*|"") LANG_VM=en_US.UTF-8 ;;
  *-*) LANG_VM="${lang%%-*}_${lang##*-}.UTF-8" ;;
  *) LANG_VM="${lang}_${region##*_}.UTF-8" ;;
esac
[[ -n $CHANNEL ]] || CHANNEL=$(omarchy_channel)
# A prebuilt image carries nothing of this Mac: the first boot sets these.
(( IMAGE )) && { KB=us; KB_NOTE=""; KB_SHOWN=us; TZ_MAC=UTC; LANG_VM=en_US.UTF-8; }

FEATS=(bridge "$BRIDGE" wallpaper "$WALLPAPER" gestures "$GESTURES" scroll-momentum "$GLIDE" omanotch "$OMANOTCH"
       mac-clock "$MAC_CLOCK" camera "$CAMERA" battery "$BATTERY" external-brightness "$EXT_BRIGHTNESS" chromium-video "$CHROMIUM_VIDEO" no-idle-lock "$NO_IDLE_LOCK" autologin "$AUTOLOGIN" thp-kernel "$THP"
       control-centre "$CONTROL" x86-apps "$X86")
# The one-time steps only a person can do on the Mac, one per line.
human_steps() {
  (( ${EXTERNAL:-0} )) && echo "The VM is on an external drive: connect it before you start the VM, and never unplug it while the VM runs."
  if (( BRIDGE )); then
    echo "Allow Wi-Fi names: Location Services for OmacVM Bridge (macOS asks)."
    echo "Allow media keys: Accessibility for OmacVM Bridge."
    echo "Allow Bluetooth devices: Bluetooth for OmacVM Bridge (macOS asks)."
  elif (( CAMERA || BATTERY )) && [[ $TYPE == utm || $TYPE == fusion ]]; then
    local what="The camera and the Mac's battery come"
    (( CAMERA && BATTERY )) || { (( CAMERA )) && what="The camera comes" || what="The Mac's battery comes"; }
    echo "$what through OmacVM Bridge, so it is installed although its bar features are off. On its first start macOS asks for Location Services, Accessibility and Bluetooth for it: say no, they are not needed for this."
  fi
  if (( GESTURES )) || [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; then
    local what="the trackpad"
    [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]] && { (( GESTURES )) && what="the trackpad and Cmd keys" || what="the Cmd keys"; }
    echo "Allow $what: Accessibility and Input Monitoring for OmacVM Gestures."
  fi
  case $TYPE in
    utm) echo "Allow the microphone: macOS asks for UTM the first time a Linux app records." ;;
    fusion) echo "Allow the microphone: VMware Fusion in System Settings > Privacy & Security > Microphone (without it the VM records nothing)." ;;
    app) echo "Allow the microphone: macOS asks for OmacVM when it starts the VM (if a Linux app records nothing right after, restart the VM once)." ;;
    parallels) echo "Allow the microphone: Parallels Desktop in System Settings > Privacy & Security > Microphone (without it the VM records silence)." ;;
  esac
  if (( CAMERA )); then
    case $TYPE in
      utm|fusion) echo "Allow the camera: macOS asks for OmacVM Bridge the first time a Linux app uses it." ;;
      app) echo "Allow the camera: macOS asks for OmacVM.app the first time a Linux app uses it." ;;
      parallels) echo "Allow the camera: macOS asks for Parallels Desktop the first time a Linux app uses it." ;;
    esac
  fi
  case $TYPE in
  parallels)
    [[ -n ${P_PLANNED:-} ]] && echo "Parallels has no licence yet: when the build starts the VM, start the free trial or sign in in the window Parallels shows."
    parallels_profile_emptied || echo "Let Cmd+C/V/X reach Omarchy as Super: quit Parallels Desktop, run src/mac/parallels-shortcuts.sh (app-wide: every Linux VM in Parallels)."
    parallels_sends_shortcuts || echo "Let Cmd+Space etc. reach Omarchy: Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts > \"Send macOS system shortcuts: Always\" (an alert shows where)." ;;
  utm)
    echo "UTM: put the VM in full screen on the main display, a MacBook's own screen (gestures and media keys need it); keep UTM in the foreground, a backgrounded UTM runs slower." ;;
  fusion)
    echo "VMware Fusion asks for Accessibility on its first start: click OK, then turn on VMware Fusion in System Settings > Privacy & Security > Accessibility (keyboard and mouse in the VM)."
    echo "VMware Fusion: put the VM in full screen (View > Full Screen; gestures and media keys need it)." ;;
  app)
    echo "OmacVM.app: put the VM in full screen (gestures and Cmd shortcuts need it)." ;;
  esac
}
if (( PLAN && JSON )); then
  cmd="OMACVM_PASSWORD=… omacvm build --yes --$SOURCE --vm-type $TYPE --vm-name $(printf %q "$VM") --cpus $CPUS --memory-gb $MEM_GB --disk-gb $DISK_GB --user $U --full-name $(printf %q "$FULL") --hostname $(printf %q "$HOST")"
  # No licence yet: the edition the limits were planned for.
  [[ -n ${P_PLANNED:-} ]] && cmd+=" --parallels-edition $P_EDITION"
  [[ -n ${VM_DIR:-} && $VM_DIR != "$(default_dir)" ]] && cmd+=" --vm-dir $(printf %q "$VM_DIR")"
  [[ -n ${GFX_GB:-} ]] && cmd+=" --graphics-gb $GFX_GB"
  printf '{\n  "omacvm": %s,\n' "$(json_str "$(cat "$R/src/VERSION")")"
  printf '  "vm": {"name": %s, "type": "%s", "app_version": %s, "cpus": %s, "memory_gb": %s, "disk_gb": %s, "hostname": %s, "dir": %s},\n' \
    "$(json_str "$VM")" "$TYPE" "$(json_str "$(case $TYPE in
      (parallels) echo "Parallels Desktop $P_EDITION${P_TRIAL:+ trial=$P_TRIAL}${P_PLANNED:+ (planned: no licence yet, Parallels asks for the trial or a sign-in when the VM starts)}" ;;
      (utm) echo "UTM $(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null)" ;;
      (fusion) echo "VMware Fusion $(fusion_version)" ;;
      (app) [[ -n $APP ]] && echo "OmacVM.app $(app_version "$APP") ($APP)" || echo "OmacVM.app $(cat "$R/src/VERSION") (not installed: downloaded by the build)" ;;
    esac)")" \
    "$CPUS" "$MEM_GB" "$DISK_GB" "$(json_str "$HOST")" "$(json_str "${VM_DIR:-UTM library}")"
  printf '  "limits": {"cpus": %s, "memory_gb": %s},\n' "$CAP_CPUS" "$CAP_MEM_GB"
  [[ -n ${GFX_GB:-} ]] && printf '  "graphics_gb": %s,\n' "$GFX_GB"
  printf '  "resource_tiers": {'   # what --resources gives on this Mac
  for t in 0 1 2 3; do
    tier_values "$t"
    printf '%s"%s": {"cpus": %s, "memory_gb": %s}' "$( ((t)) && echo ', ')" "$(tr '[:upper:]' '[:lower:]' <<<"${TIERS[$t]}")" "$T_CPUS" "$T_MEM"
  done
  printf '},\n'

  printf '  "user": {"name": %s, "full_name": %s},\n' "$(json_str "$U")" "$(json_str "$FULL")"
  printf '  "from_the_mac": {"keyboard": %s, "timezone": %s, "language": %s, "notch": %s},\n' \
    "$(json_str "$KB")" "$(json_str "$TZ_MAC")" "$(json_str "$LANG_VM")" "$( [[ $NOTCH == notch ]] && echo true || echo false)"
  printf '  "features": {'
  for ((k = 0; k < ${#FEATS[@]}; k += 2)); do
    printf '%s"%s": %s' "$( ((k)) && echo ', ')" "${FEATS[$k]}" "$( ((FEATS[k+1])) && echo true || echo false)"
    cmd+=" --feature ${FEATS[$k]}=$( ((FEATS[k+1])) && echo on || echo off)"
  done
  printf '},\n  "source": "%s",\n' "$SOURCE"
  if (( PB_OK )); then
    printf '  "prebuilt": {"available": true, "release": %s, "download_gb": %s, "omarchy": %s, "omacvm": %s},\n' \
      "$(json_str "$PB_TAG")" "$(pb_gb "$PB_SIZE")" "$(json_str "$PB_OMARCHY")" "$(json_str "$PB_VERSION")"
  else
    printf '  "prebuilt": {"available": false},\n'
  fi
  [[ $SOURCE == prebuilt ]] && mins="3-10 plus the download" || mins=$(build_minutes | sed 's/ to /-/')
  printf '  "minutes": "%s",\n  "needs_human": [' "$mins"
  first=1
  while IFS= read -r step; do
    printf '%s\n    %s' "$( ((first)) || echo ,)" "$(json_str "$step")"; first=0
  done < <([[ $TYPE == app ]] || have_homebrew || echo "Install Homebrew (https://brew.sh): /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
           [[ $TYPE == app ]] || { bt=$(missing_brew_tools); [[ -z $bt ]] || echo "Install Homebrew's tools for the build: brew install $bt"; }
           [[ $TYPE != app || -n $APP ]] || echo "Install OmacVM.app (omacvm build without --yes does it after asking): $(app_install_cmd "$(cat "$R/src/VERSION")")"
           echo "Choose the password for $U in Omarchy (OMACVM_PASSWORD for --yes)."; human_steps)
  printf '\n  ],\n  "command": %s\n}\n' "$(json_str "$cmd")"
  DONE=1; exit 0
fi
# What the VM runs in, for the summary.
if [[ $TYPE == parallels ]]; then
  APP_LINE="Parallels Desktop $(tr '[:lower:]' '[:upper:]' <<<"${P_EDITION:0:1}")${P_EDITION:1}"
  if [[ -n ${P_PLANNED:-} ]]; then APP_LINE+=" (planned; no licence yet, the trial starts with the VM)"
  elif [[ $P_TRIAL == yes ]]; then APP_LINE+=" (trial)"; fi
  APP_LINE+=" ($(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM.pvm"))"
elif [[ $TYPE == utm ]]; then
  APP_LINE="UTM $(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
  [[ -n ${VM_DIR:-} ]] && APP_LINE+=" ($(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM.utm"))"
elif [[ $TYPE == app ]]; then
  APP_LINE="OmacVM.app $( [[ -n $APP ]] && app_version "$APP" || echo "$(cat "$R/src/VERSION"), downloaded first") ($(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM"))"
else
  APP_LINE="VMware Fusion $(fusion_version) ($(fusion_bundle "$VM" | sed "s|^$HOME|~|"))"
fi
box=("OmacVM will build this VM" ""
     "VM         $VM, in $APP_LINE"
     "resources  $CPUS of $mac_cores CPUs, $MEM_GB of $mac_mem_gb GB memory${GFX_GB:+ ($GFX_GB GB of it for graphics)}, $DISK_GB GB disk (expanding)"
     "user       $U ($FULL), hostname $HOST"
     "keyboard   $KB_SHOWN"
     "timezone   $TZ_MAC, language $LANG_VM"
     "Omarchy    $( [[ $SOURCE == prebuilt ]] && echo "prebuilt VM: Omarchy $PB_OMARCHY ($(pb_gb "$PB_SIZE") GB download, release $PB_TAG)" || echo "omarchy-mac, $CHANNEL packages, built here")" "")
while IFS= read -r l; do box+=("${l#    }"); done < <(explain_features)
if (( UI_FANCY )) && ! (( YES )); then ui_box "${box[@]}"
else printf '\n'; for l in "${box[@]}"; do printf '  %s\n' "$l"; done; fi
echo
if (( DRY )); then echo "  $( ((PLAN)) && echo Plan || echo "Dry run"): nothing was built."; DONE=1; exit 0; fi
if (( ! YES )); then
  ask_yn "Go ahead?" y || exit 1
fi
if [[ -n ${OMACVM_PASSWORD:-} ]]; then
  PW=$OMACVM_PASSWORD
elif (( YES )) && ! { : < "$TTY"; } 2>/dev/null; then
  usage "--yes without a terminal needs OMACVM_PASSWORD (the password for $U in Omarchy)"
else
  read -r -s -p "  Password for $U in Omarchy: " PW < "$TTY"; echo
  read -r -s -p "  Again: " PW2 < "$TTY"; echo
  [[ $PW == "$PW2" && -n $PW ]] || die "passwords differ or are empty"
fi
# OmacVM.app's script takes the password itself and hashes it in the VM.
if [[ $TYPE != app ]]; then
  HASH=$(printf '%s' "$PW" | "$(sha512_openssl)" passwd -6 -stdin) || die "could not hash the password (openssl passwd -6)"
  [[ $HASH == '$6$'* ]] || die "could not hash the password (openssl passwd -6)"
  unset PW PW2
fi

# Cmd as Super in Parallels: its Linux keyboard profile turns Cmd+C/V/X into
# Ctrl. Emptying it needs Parallels Desktop closed: done now when no VM runs.
if [[ $TYPE == parallels ]] && ! (( IMAGE )) && ! parallels_profile_emptied; then
  if ! "$PRLCTL" list -o status 2>/dev/null | grep -q running; then
    if pgrep -xq prl_client_app; then
      osascript -e 'quit app "Parallels Desktop"' >/dev/null 2>&1 || true
      for _ in $(seq 20); do pgrep -xq prl_client_app || break; sleep 1; done
    fi
    if ! pgrep -xq prl_client_app && "$R/src/mac/parallels-shortcuts.sh" >/dev/null; then
      log "Cmd reaches Omarchy as Super (Parallels' Linux keyboard profile emptied)"
    fi
  fi
fi

# From here on: numbered steps, and everything also into a log file.
STEP=0; STEPS=$(case $TYPE in (parallels) (( IMAGE )) && echo 5 || echo 6 ;; (app) echo 2 ;; (*) echo 5 ;; esac)
[[ $SOURCE == prebuilt && $TYPE != app ]] && STEPS=4
step() { STEP=$((STEP + 1)); ui_step "$STEP" "$STEPS" "$*"; }
BUILD_LOG=~/Library/Logs/omacvm-build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$BUILD_LOG") 2>&1
UI_LOG=$BUILD_LOG
build_end() {
  local rc=$1
  if [[ $SOURCE == prebuilt ]]; then prebuilt_exit; fi   # the seed and an unused unpacked image go
  (( rc == 0 && DONE )) && return
  # UTM with --vm-dir: the installer image and build-live's work folder on that drive
  if [[ $TYPE == utm && -n ${VM_DIR:-} ]]; then rm -f "$VM_DIR/.$VM-live.img"; rm -rf "$VM_DIR/.omacvm-build-live"; fi
  (( rc )) || rc=1
  printf '\n\033[1;31mThe build stopped\033[0m in step %s of %s. The whole log:\n  open "%s"\n' "$STEP" "$STEPS" "$BUILD_LOG"
  printf 'Fix what it says and run omacvm again (a half-built VM can be deleted in %s first).\n' \
    "$(case $TYPE in (parallels) echo "Parallels Desktop" ;; (utm) echo UTM ;; (fusion) echo "VMware Fusion" ;; (app) echo OmacVM.app ;; esac)"
  return "$rc"
}
trap 'build_end $? && rc=0 || rc=$?; ui_restore; exit $rc' EXIT

KEY=~/.ssh/omacvm
[[ -f $KEY ]] || { log "SSH key for the VM: $KEY"; mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"; ssh-keygen -t ed25519 -N "" -C "omacvm" -f "$KEY" -q; }
export OMA_KEY=$KEY
started=$(date +%s)

if [[ $TYPE == app ]]; then
# ---------- OmacVM.app: its own create script, then omacvm apply ----------
# The same script the app runs when you build in it (live installer, Arch
# Linux ARM, Omarchy, OmacVM from the copy inside the app), or with --prebuilt
# the one that makes it from the image (download, first boot with a seed); it
# leaves the VM shut down. Its STEP lines become ==> lines, curl's progress
# bar is dropped, and so are the app's progress lines (only sent when the app
# asks, OMACVM_PROGRESS=1; also dropped here for an app of another version).
pb_arg=()
if [[ $SOURCE == prebuilt ]]; then
  pb_arg=(--prebuilt)
  step "OmacVM.app makes the VM from the prebuilt image ($(pb_gb "$PB_SIZE") GB download, its logs in $(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM")/logs)"
else
  step "OmacVM.app builds the VM (10-30 minutes, its logs in $(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM")/logs)"
fi
port=$(app_free_port) || die "no free port for the VM's SSH (52222-52421)"
fv=""
for ((k = 0; k < ${#FEATS[@]}; k += 2)); do fv+=" ${FEATS[$k]}=$(onoff "${FEATS[k+1]}")"; done
# --no-mac: the app's own build leaves the Mac's helpers alone too.
printf '%s\n' "$PW" | OMACVM_CREATE_NO_MAC=${NO_MAC:-0} app_create ${pb_arg[@]+"${pb_arg[@]}"} "$VM_DIR/$VM" NAME="$VM" CPUS="$CPUS" MEM_MB=$((MEM_GB * 1024)) DISK_GB="$DISK_GB" \
  SSH_PORT="$port" VM_USER="$U" VM_FULLNAME="$FULL" VM_HOSTNAME="$HOST" VM_TZ="$TZ_MAC" VM_LANG="$LANG_VM" \
  KEYBOARD="$KB" FEATURES="${fv# }" 2>&1 |
  sed -l -e $'s/.*\r//' -e '/^#.*%$/d' -e '/^READY /d' -e '/^{"omacvm_progress"/d' -e '/^| /d' -e 's|^STEP \([0-9]*/[0-9]*\) |==> \1 |' |
  ui_follow "Building in OmacVM.app" ||
  die "OmacVM.app's build stopped (its logs: $VM_DIR/$VM/logs)"
unset PW PW2

step "OmacVM: the Mac side, then the VM side (the VM starts in OmacVM.app)"
args=(--vm "$VM" --vm-type app --user "$U" --keyboard "$KB" --reset-host-key)
(( ${NO_MAC:-0} )) && args+=(--no-mac)
for ((k = 0; k < ${#FEATS[@]}; k += 2)); do
  args+=(--feature "${FEATS[$k]}=$( ((FEATS[k+1])) && echo on || echo off)")
done
"$R/src/cmd/apply.sh" "${args[@]}"
IP=$(app_ip "$VM") || die "'$VM' does not run in OmacVM.app"
vm_pin "$VM" app
gssh "$IP" "systemctl reboot" 2>/dev/null || true
else

if [[ $SOURCE == prebuilt ]]; then
  prebuilt_make_vm     # download, unpack, first boot with the seed: sets IP
else
# ---------- 2. temporary live installer + the real disk ----------
step "Temporary live installer (try-omarchy, about 1.4 GB download)"
if [[ $TYPE == parallels ]]; then
  info "Parallels Desktop may show its own windows on the way (sign in, continue the trial,"
  info "allow access): click through them, the build waits for the VM to start."
fi
if [[ $TYPE == parallels ]]; then
  "$R/src/vm/live/build-live.sh" --vm-name "$VM" --vm-dir "$VM_DIR" --root-size-gib 16 --skip-boot --ssh-key "$KEY.pub"
  PVM="$VM_DIR/$VM.pvm"
  "$PRLCTL" unregister "$VM" >/dev/null
  log "VM settings and a ${DISK_GB} GB NVMe disk"
  /usr/local/bin/prl_disk_tool create --hdd "$PVM/omarchy.hdd" --size "${DISK_GB}G" >/dev/null
  P="$R/src/vm/pvs.py"
  python3 "$P" "$PVM/config.pvs" omacvm --cpus "$CPUS" --memsize $((MEM_GB * 1024)) \
    --description "Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM"
  python3 "$P" "$PVM/config.pvs" add-nvme omarchy.hdd $((DISK_GB * 1024)) >/dev/null
  python3 "$P" "$PVM/config.pvs" boot-from 0
  mkdir -p "$HOME/.local/share/omacvm/clip"
  python3 "$P" "$PVM/config.pvs" add-share vmlog "$PVM" ro                       # display layout (parallels.log)
  python3 "$P" "$PVM/config.pvs" add-share clip "$HOME/.local/share/omacvm/clip" rw     # clipboard VM -> Mac
  cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
  "$PRLCTL" register "$PVM" >/dev/null
  vm_start "$VM" "$PVM"
  ui_spin_val IP "The live installer gets its address" vm_ip "$PVM" 300 || die "the live installer got no IP address"
elif [[ $TYPE == fusion ]]; then
  # The raw live image goes inside the VM's folder; Fusion reads it in place.
  LIVE="$(fusion_bundle "$VM").live.img"
  "$R/src/vm/live/build-live.sh" --root-size-gib 16 --raw-image "$LIVE" --ssh-key "$KEY.pub"
  log "VMware Fusion VM with a ${DISK_GB} GB NVMe disk"
  VMX=$(fusion_create "$VM" "$CPUS" $((MEM_GB * 1024)) "$LIVE" "$DISK_GB" "$GFX_GB")
  mv "$LIVE" "$(fusion_bundle "$VM")/live.img"; LIVE="$(fusion_bundle "$VM")/live.img"   # live.vmdk points here
  fusion_start "$VM"
  ui_spin_val IP "The live installer gets its address" fusion_ip "$VM" 300 || die "the live installer got no IP address"
else
  # --vm-dir: the installer image and the VM go to that folder; UTM makes the
  # VM in its own folder (empty disk only), then moves it there.
  if [[ -n ${VM_DIR:-} ]]; then
    LIVE="$VM_DIR/.$VM-live.img"
    "$R/src/vm/live/build-live.sh" --root-size-gib 16 --raw-image "$LIVE" --ssh-key "$KEY.pub" --workdir "$VM_DIR/.omacvm-build-live"
    rm -rf "$VM_DIR/.omacvm-build-live"   # its leftovers (kernel, boot files): not needed after
  else
    LIVE="$HOME/Library/Caches/omacvm/build-live/$VM-live.img"
    "$R/src/vm/live/build-live.sh" --root-size-gib 16 --raw-image "$LIVE" --ssh-key "$KEY.pub"
  fi
  utm_tune_app
  log "UTM VM with a ${DISK_GB} GB NVMe disk"
  pgrep -xq UTM || { open -a UTM; sleep 3; }
  if [[ -n ${VM_DIR:-} ]]; then
    utm_create "$VM" "$CPUS" $((MEM_GB * 1024)) "" $((DISK_GB * 1024)) >/dev/null
    utm_move "$VM" "$VM_DIR"
    UTM_BUNDLE="$VM_DIR/$VM.utm"
    log "UTM VM in $UTM_BUNDLE"
    utm_add_live "$VM" "$LIVE"
  else
    utm_create "$VM" "$CPUS" $((MEM_GB * 1024)) "$LIVE" $((DISK_GB * 1024)) >/dev/null
  fi
  rm -f "$LIVE"
  utm_start "$VM"
  ui_spin_val IP "The live installer gets its address" utm_ip "$VM" 300 || die "the live installer got no IP address"
fi
# SSH host keys: the live installer's is remembered for this step only, the
# new system's for good (from its first start on).
export OMA_PIN_NEW=1 OMA_PIN
OMA_PIN=$(mktemp -t omacvm-live)
ui_spin "Waiting for SSH on $IP" wait_ssh "$IP" || die "no SSH on $IP"
# The Mac's proxy (#122). Parallels', UTM's and Fusion's VMs cannot reach the
# Mac's 127.0.0.1: only a proxy on another address (or one the Mac serves on
# its LAN address) is passed on. OmacVM.app's build does its own (vm-common.sh).
if ! (( IMAGE )); then
  proxy_detect
  [[ -z $PROXY_NOTE ]] || info "proxy: $PROXY_NOTE"
  [[ -z $(proxy_ports) ]] ||
    info "proxy: the Mac's proxy listens on 127.0.0.1, which $TYPE VMs cannot reach; set http_proxy/https_proxy to the Mac's LAN address (with the proxy allowing LAN connections) and build again, or build in OmacVM.app"
  penv=$(proxy_guest_env "")
  if [[ -n $penv ]]; then
    log "proxy: $(proxy_summary)"
    printf '%s\n' "$penv" | gssh "$IP" "umask 022; cat > /root/omacvm-proxy.env"
  fi
fi

# ---------- 3. Arch Linux ARM onto the NVMe disk ----------
step "Arch Linux ARM onto the VM's disk ($IP)"
{
  printf 'OMA_USER=%q\nOMA_FULLNAME=%q\nOMA_HASH=%q\nOMA_TZ=%q\nOMA_LANG=%q\nOMA_HOSTNAME=%q\n' \
    "$U" "$FULL" "$HASH" "$TZ_MAC" "$LANG_VM" "$HOST"
  read -r l v <<<"$KB"; printf 'OMA_XKB_LAYOUT=%q\nOMA_XKB_VARIANT=%q\n' "$l" "${v:-}"
} | gssh "$IP" "umask 077; cat > /root/omacvm.env"
gssh "$IP" "cat > /root/omacvm.pub" < "$KEY.pub"
if ! gssh "$IP" "bash -s" < "$R/src/vm/base-install.sh" 2>&1 | ui_follow "Arch Linux ARM onto the disk"; then
  # pacstrap's full output is only in the live system: keep it in the build log.
  { echo "---- /root/pacstrap.log ----"; gssh "$IP" "cat /root/pacstrap.log" < /dev/null; } >> "$BUILD_LOG" 2>&1 || true
  die "the Arch Linux ARM install failed"
fi
gssh "$IP" "systemctl poweroff" 2>/dev/null || true

step "Booting from the new disk"
if [[ $TYPE == utm ]]; then
  ui_spin "The live installer shuts down" utm_wait_stopped "$VM"
  utm_drop_live "$VM"
  utm_set_icon "$VM" ${UTM_BUNDLE:+"$UTM_BUNDLE"}
  utm_add_sound "$VM" ${UTM_BUNDLE:+"$UTM_BUNDLE"}
  utm_start "$VM"
  sleep 20
  ui_spin_val IP "The new system starts and gets its address" utm_ip "$VM" 300 || die "the new system got no IP address"
elif [[ $TYPE == fusion ]]; then
  ui_spin "The live installer shuts down" fusion_wait_stopped "$VM"
  fusion_drop_live "$VM"
  fusion_add_sound "$VM"
  rm -f "$LIVE"
  fusion_start "$VM"
  sleep 20
  ui_spin_val IP "The new system starts and gets its address" fusion_ip "$VM" 300 || die "the new system got no IP address"
else
ui_spin "The live installer shuts down" wait_stopped "$VM"
"$PRLCTL" unregister "$VM" >/dev/null
live=$(python3 - "$PVM/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
for h in ET.parse(sys.argv[1]).getroot().find("Hardware").findall("Hdd"):
    if h.findtext("InterfaceType") != "3": print(h.findtext("Index"), h.findtext("SystemName"))
PY
)
read -r live_idx live_disk <<<"$live"
nvme_idx=$(python3 - "$PVM/config.pvs" <<'PY'
import sys, xml.etree.ElementTree as ET
print(next(h.findtext("Index") for h in ET.parse(sys.argv[1]).getroot().find("Hardware").findall("Hdd") if h.findtext("InterfaceType") == "3"))
PY
)
python3 "$P" "$PVM/config.pvs" remove-hdd "$live_idx"
python3 "$P" "$PVM/config.pvs" boot-from "$nvme_idx"
rm -rf "${PVM:?}/$live_disk" "$PVM"/*.mem "$PVM"/*.mem.sh "$PVM/vm.lock"
cp "$PVM/config.pvs" "$PVM/config.pvs.backup"
"$PRLCTL" register "$PVM" >/dev/null
vm_start "$VM" "$PVM"
sleep 20
ui_spin_val IP "The new system starts and gets its address" vm_ip "$PVM" 300 || die "the new system got no IP address"
fi
rm -f "$OMA_PIN"
OMA_PIN_RESET=1 vm_pin "$VM" "$TYPE"   # a VM of that name before this one: its key goes
ui_spin "Waiting for SSH on $IP" wait_ssh "$IP" || die "no SSH on $IP"

# ---------- 4. Omarchy + Parallels Tools ----------
step "Omarchy from omarchy-mac (the longest step)"
[[ $TYPE == fusion ]] && gssh "$IP" "bash -s" < "$R/src/fusion/guest/dns.sh"   # Fusion's own DNS fails the install
gssh "$IP" "OMARCHY_MAC_CHANNEL=$CHANNEL bash -s" < "$R/src/vm/omarchy-install.sh" 2>&1 | ui_follow "Installing Omarchy (20-40 minutes)"
# Parallels Tools come from this Mac's Parallels; never in a prebuilt image.
if [[ $TYPE == parallels ]] && ! (( IMAGE )); then
  step "Parallels Tools"
  parallels_tools_install "$IP"
fi
gssh "$IP" "rm -f /root/omacvm.env"   # it holds the password hash
fi

# ---------- 5. OmacVM ----------
step "OmacVM: the Mac side, then the VM side"
args=(--vm "$VM" --vm-type "$TYPE" --ip "$IP" --user "$U" --keyboard "$KB")
(( IMAGE )) && args+=(--no-mac --no-token --no-tools)   # nothing of this Mac in an image
(( ${NO_MAC:-0} )) && args+=(--no-mac)
for ((k = 0; k < ${#FEATS[@]}; k += 2)); do
  args+=(--feature "${FEATS[$k]}=$( ((FEATS[k+1])) && echo on || echo off)")
done
"$R/src/cmd/apply.sh" "${args[@]}"
if [[ $SOURCE == prebuilt ]]; then
  prebuilt_drop_seed
else
  gssh "$IP" "systemctl reboot" 2>/dev/null || true
fi
fi

mac_steps=$(human_steps | sed 's/^/    * /')
ssh_to="root@$IP"; [[ $IP == *:* ]] && ssh_to="-p ${IP##*:} root@${IP%:*}"   # OmacVM.app: 127.0.0.1:PORT
cat <<EOF

  Done in $(mins=$(( ($(date +%s) - started) / 60 )); (( mins == 1 )) && echo "1 minute" || echo "$mins minutes")${PB_TIMES:+ ($PB_TIMES)}. VM '$VM' ($TYPE) is rebooting into Omarchy.

  One-time steps on the Mac:
$mac_steps
  In full screen, the trackpad and ⌘ shortcuts belong to Omarchy.
  ${UB}⌃⌥ Esc (Control + Option + Escape) takes you back to macOS; in macOS, back into the VM.${UR}

  SSH: ssh -i "$KEY" $ssh_to
  Check everything: omacvm check --vm "$VM"
  Switch features later: omacvm features --vm "$VM"
EOF
DONE=1
