#!/bin/bash
# omacvm build: an Omarchy VM that feels like a native Mac, in OmacVM.app,
# from nothing, in one go (10-30 minutes, mostly downloads).
#
#   omacvm build             asks a few questions, shows a summary, then builds
#   omacvm build --dry-run   asks the questions and shows the summary only
#   omacvm build --plan --json   the summary as JSON, nothing built (agents)
#   omacvm build --prebuilt  download a prebuilt VM instead (faster); --build: build it here
#
# Everything can also be given up front (--yes skips the questions; the
# password then comes from OMACVM_PASSWORD):
#   --vm-type app (the only one)   --vm-name NAME   --hostname NAME
#   --resources low|balanced|high|best   --cpus N   --memory-gb N   --disk-gb N
#   --user NAME   --full-name "NAME"
#   --feature NAME=on|off, or --FEATURE / --no-FEATURE (omacvm features lists
#   them: bridge wallpaper gestures scroll-momentum omanotch mac-clock camera battery external-brightness no-idle-lock autologin thp-kernel
#   x86-apps; idle-lock, its name before 3.0.1, the other way round)
# The keyboard layout, timezone and language come from this Mac. Needs Apple
# Silicon and macOS 15 or newer; OmacVM.app is installed after asking when it
# is missing. The VM goes to the VMs folder set in the app.
# Exit codes: 0 built, 1 failed, 2 usage (or a question without a terminal),
# 3 needs a person (an app to install, see the message).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/ui.sh"
source "$R/src/lib/prereq.sh"
source "$R/src/prebuilt/lib.sh"
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
TYPE=app; VM="Omarchy"; RES=""; CPUS=""; MEM_GB=""; DISK_GB=""; U=$(linux_name "$(id -un)"); FULL=""; HOST="omarchy"
[[ -n $U ]] || U=omarchy
BRIDGE=1; WALLPAPER=1; GESTURES=1; GLIDE=1; OMANOTCH=""; MAC_CLOCK=1; CAMERA=1; BATTERY=""; EXT_BRIGHTNESS=1; CHROMIUM_VIDEO=1; GPU_COMPUTE=1; NO_IDLE_LOCK=0; AUTOLOGIN=0; THP=0; CONTROL=1; X86=0
YES=0; DRY=0; PLAN=0; JSON=0; IMAGE=0; SOURCE=""
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
    gpu-compute) GPU_COMPUTE=$v ;;
    no-idle-lock) NO_IDLE_LOCK=$v ;;
    autologin) AUTOLOGIN=$v ;;
    thp-kernel) THP=$v ;;
    x86-apps) X86=$v ;;
    control-centre) CONTROL=$v ;;
    fast-network) [[ $2 == off ]] || usage "the fast network goes on after the build: omacvm enable fast-network --vm NAME" ;;
    vulkan) [[ $2 == off ]] || usage "Vulkan goes on after the build: omacvm enable vulkan --vm NAME" ;;
    mac-ime) [[ $2 == off ]] || usage "the Mac's input methods go on after the build: omacvm enable mac-ime --vm NAME" ;;
    drag-drop) [[ $2 == off ]] || usage "drag and drop goes on after the build: omacvm enable drag-drop --vm NAME" ;;
    *) usage "unknown feature '$1' (omacvm features lists them)" ;;
  esac
  [[ $2 == on || $2 == off ]] || usage "--feature $1=$2: on or off"
}
while (( $# )); do
  # A missing value is a usage error, not a set -u abort.
  case $1 in
    --vm-type|--vm-name|--resources|--cpus|--memory-gb|--disk-gb|--user|--full-name|--hostname|--feature)
      [[ $# -ge 2 ]] || usage "$1 needs a value" ;;
  esac
  case $1 in
    --vm-type) TYPE=$2; shift 2
      route_retired "$TYPE" && usage "$(retired_build_message)"
      [[ $TYPE == app ]] || usage "--vm-type app (OmacVM.app) is the only one" ;;
    --vm-name) VM=$2; NAME_GIVEN=1; shift 2 ;;
    --vm-dir|--graphics-gb) usage "unknown option $1 (see --help)" ;;
    --resources) RES=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-gb) MEM_GB=$2; shift 2 ;;
    --disk-gb) DISK_GB=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --full-name) FULL=$2; shift 2 ;;
    --hostname) HOST=$2; shift 2 ;;
    --feature) feature_flag "${2%%=*}" "${2#*=}"; shift 2 ;;
    --image) IMAGE=1; YES=1; shift ;;           # a VM for a prebuilt image (src/prebuilt/make-image.sh)
    --no-mac) NO_MAC=1; shift ;;                # tests: leave this Mac's apps as they are
    --prebuilt) SOURCE=prebuilt; shift ;;
    --build) SOURCE=build; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --plan) PLAN=1; DRY=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,22s/^# \{0,1\}//p' "$0"; DONE=1; exit 0 ;;
    --no-*) feature_flag "${1#--no-}" off; shift ;;
    --*) feature_flag "${1#--}" on; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ $(uname -m) == arm64 ]] || die "OmacVM needs an Apple Silicon Mac"
macos=$(sw_vers -productVersion 2>/dev/null)
(( ${macos%%.*} >= 15 )) || { printf '\033[1;31mneeds you:\033[0m OmacVM.app needs macOS 15 (Sequoia) or newer; this Mac runs %s\n' "$macos" >&2; exit 3; }
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

# ---------- 1. OmacVM.app ----------
# What the build needs: Xcode's command line tools (installed after asking),
# except when run from the app's own omacvm ("omacvm in Terminal", the control
# centre): the app carries python3, the Swift answers and its Mac helpers ready
# made (src/lib/tools.sh). A plan or a dry run only reports.
if ! have_xcode_tools && _tools_own_resources >/dev/null && tools_python >/dev/null; then
  :
elif (( DRY )); then
  have_xcode_tools || needs_person "Xcode's command line tools are missing: xcode-select --install"
else
  ensure_xcode_tools
  ensure_swift_works
fi
# The app itself: installed now (after asking) when it is missing.
(( DRY )) || ensure_vm_app
CAP_CPUS=$mac_cores; CAP_MEM_GB=$mac_mem_gb
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
fi
# The Mac's battery: on with one.
i=$(feature_index battery)
if [[ -z $BATTERY ]]; then [[ $(feature_default "$i") == on ]] && BATTERY=1 || BATTERY=0
elif (( BATTERY )) && ! feature_available "$i"; then (( JSON )) || info "${FTITLE[$i]}: off ($REASON)"; BATTERY=0; fi
# ---------- build it here, or download a prebuilt VM ----------
build_minutes() { echo "10 to 30"; }
PB_OK=0
# An older installed OmacVM.app has no script for images (omacvm update brings it).
APP_OLD=0
[[ -n ${APP:-} ]] && ! app_has_prebuilt "$APP" && APP_OLD=1
# The version the image must fit: the app's when it makes the VM (it may be
# older or newer than this omacvm), so both find the same image.
PB_FOR=$(cat "$R/src/VERSION")
if [[ $SOURCE != build ]] && ! (( IMAGE || APP_OLD )); then
  if [[ -n ${APP:-} ]]; then
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
      "Build it yourself|about $(build_minutes) minutes, Omarchy 4.5 from its official aarch64 repositories" \
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
# OmacVM.app takes at most 64 characters and no '..' (VMConfig.validName).
NAME_RE='^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
app_name_bad() { [[ $1 == *..* ]]; }
[[ $VM =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] || usage "--vm-name: letters, digits, spaces, dots, _ and - only (got '$VM')"
[[ $VM =~ $NAME_RE ]] || usage "--vm-name: at most 64 characters for OmacVM.app"
app_name_bad "$VM" && usage "--vm-name: no '..' for OmacVM.app"
# A name is taken, also by a retired VM: omacvm --vm NAME has to find one VM.
vm_taken() {
  vms_list | awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }'
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
case ${RES:-balanced} in low) tier=0 ;; balanced) tier=1 ;; high) tier=2 ;; best) tier=3 ;; *) usage "--resources low|balanced|high|best" ;; esac
if (( ! YES )) && [[ -z $CPUS && -z $MEM_GB && -z $RES ]]; then
  say ""
  say "    The VM keeps memory it has touched until it stops; Best leaves macOS and the"
  say "    GPU a buffer of $(( mac_mem_gb / 4 > 8 ? mac_mem_gb / 4 : 8 )) GB."
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
[[ $CPUS =~ ^[0-9]+$ ]] && (( CPUS >= 1 && CPUS <= CAP_CPUS )) || usage "--cpus: 1 to $CAP_CPUS"
[[ $MEM_GB =~ ^[0-9]+$ ]] && (( MEM_GB >= 4 && MEM_GB <= CAP_MEM_GB )) || usage "--memory-gb: 4 to $CAP_MEM_GB GB"
[[ $DISK_GB =~ ^[0-9]+$ ]] && (( DISK_GB >= 64 )) || usage "--disk-gb: at least 64"

# ---------- where the VM goes ----------
# OmacVM.app's VMs folder (set in the app).
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
VM_DIR=$(app_vms_root)
if d=$(app_missing_drive "$VM_DIR"); then
  needs_person "$d is not connected, and OmacVM.app's VMs folder is on it ($VM_DIR): connect it, or pick another folder in the app"
fi
[[ ! -e $VM_DIR/$VM ]] || usage "$VM_DIR/$VM already exists (choose another --vm-name)"
if [[ -d $VM_DIR ]]; then p=$(vm_dir_problem "$VM_DIR"); [[ -z $p ]] || needs_person "$VM_DIR (OmacVM.app's VMs): $p"; fi
# Room to build on the drives the build writes to: the VM's folder, and the
# downloads folder when it is on another drive (not this Mac's disk when the
# VM goes to an external one).
SPACE_APP_CACHE=""
if [[ -n ${APP:-} ]] && ! grep -q downloads_dir "$APP/Contents/Resources/scripts/vm-common.sh" 2>/dev/null; then
  SPACE_APP_CACHE=mac   # OmacVM.app before 3.0.2: its downloads stay in the Mac's caches
fi
if ! space_problem "$TYPE" "$VM_DIR" "$SOURCE"; then
  if [[ $SPACE_APP_CACHE == mac && $SPACE_WHY == *"the download"* ]]; then
    SPACE_WHY+=" (omacvm update updates OmacVM.app, which then keeps its downloads on the VMs folder's drive)"
  else SPACE_WHY+=" (or pick a VMs folder on another drive in OmacVM.app)"; fi
  needs_person "$SPACE_WHY"
fi
[[ -z $SPACE_NOTE ]] || (( PLAN && JSON )) || info "$SPACE_NOTE"

# ---------- 3. features ----------
# The build's switches by feature name (src/features.tsv).
fvar() {
  case $1 in
    bridge) echo BRIDGE ;; wallpaper) echo WALLPAPER ;; gestures) echo GESTURES ;;
    scroll-momentum) echo GLIDE ;; omanotch) echo OMANOTCH ;; mac-clock) echo MAC_CLOCK ;; camera) echo CAMERA ;; no-idle-lock) echo NO_IDLE_LOCK ;;
    battery) echo BATTERY ;; external-brightness) echo EXT_BRIGHTNESS ;; chromium-video) echo CHROMIUM_VIDEO ;; gpu-compute) echo GPU_COMPUTE ;;
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
# A prebuilt image carries nothing of this Mac: the first boot sets these.
(( IMAGE )) && { KB=us; KB_NOTE=""; KB_SHOWN=us; TZ_MAC=UTC; LANG_VM=en_US.UTF-8; }

FEATS=(bridge "$BRIDGE" wallpaper "$WALLPAPER" gestures "$GESTURES" scroll-momentum "$GLIDE" omanotch "$OMANOTCH"
       mac-clock "$MAC_CLOCK" camera "$CAMERA" battery "$BATTERY" external-brightness "$EXT_BRIGHTNESS" chromium-video "$CHROMIUM_VIDEO" gpu-compute "$GPU_COMPUTE" no-idle-lock "$NO_IDLE_LOCK" autologin "$AUTOLOGIN" thp-kernel "$THP"
       control-centre "$CONTROL" x86-apps "$X86")
# The one-time steps only a person can do on the Mac, one per line.
human_steps() {
  if (( BRIDGE )); then
    echo "Allow Wi-Fi names: Location Services for OmacVM Bridge (macOS asks)."
    echo "Allow media keys: Accessibility for OmacVM Bridge."
    echo "Allow Bluetooth devices: Bluetooth for OmacVM Bridge (macOS asks)."
  fi
  echo "Allow $( ((GESTURES)) && echo "the trackpad and Cmd keys" || echo "the Cmd keys"): Accessibility and Input Monitoring for OmacVM Gestures."
  echo "Allow the microphone: macOS asks for OmacVM when it starts the VM (if a Linux app records nothing right after, restart the VM once)."
  (( CAMERA )) && echo "Allow the camera: macOS asks for OmacVM.app the first time a Linux app uses it."
  echo "OmacVM.app: put the VM in full screen (gestures and Cmd shortcuts need it)."
}
if (( PLAN && JSON )); then
  cmd="OMACVM_PASSWORD=… omacvm build --yes --$SOURCE --vm-type $TYPE --vm-name $(printf %q "$VM") --cpus $CPUS --memory-gb $MEM_GB --disk-gb $DISK_GB --user $U --full-name $(printf %q "$FULL") --hostname $(printf %q "$HOST")"
  printf '{\n  "omacvm": %s,\n' "$(json_str "$(cat "$R/src/VERSION")")"
  printf '  "vm": {"name": %s, "type": "%s", "app_version": %s, "cpus": %s, "memory_gb": %s, "disk_gb": %s, "hostname": %s, "dir": %s},\n' \
    "$(json_str "$VM")" "$TYPE" "$(json_str "$(if [[ -n $APP ]]; then echo "OmacVM.app $(app_version "$APP") ($APP)"
      else echo "OmacVM.app $(cat "$R/src/VERSION") (not installed: downloaded by the build)"; fi)")" \
    "$CPUS" "$MEM_GB" "$DISK_GB" "$(json_str "$HOST")" "$(json_str "$VM_DIR")"
  printf '  "limits": {"cpus": %s, "memory_gb": %s},\n' "$CAP_CPUS" "$CAP_MEM_GB"
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
  done < <([[ -n $APP ]] || echo "Install OmacVM.app (omacvm build without --yes does it after asking): $(app_install_cmd "$(cat "$R/src/VERSION")")"
           echo "Choose the password for $U in Omarchy (OMACVM_PASSWORD for --yes)."; human_steps)
  printf '\n  ],\n  "command": %s\n}\n' "$(json_str "$cmd")"
  DONE=1; exit 0
fi
# What the VM runs in, for the summary.
APP_LINE="OmacVM.app $( [[ -n $APP ]] && app_version "$APP" || echo "$(cat "$R/src/VERSION"), downloaded first") ($(sed "s|^$HOME|~|" <<<"$VM_DIR/$VM"))"
box=("OmacVM will build this VM" ""
     "VM         $VM, in $APP_LINE"
     "resources  $CPUS of $mac_cores CPUs, $MEM_GB of $mac_mem_gb GB memory, $DISK_GB GB disk (expanding)"
     "user       $U ($FULL), hostname $HOST"
     "keyboard   $KB_SHOWN"
     "timezone   $TZ_MAC, language $LANG_VM"
     "Omarchy    $( [[ $SOURCE == prebuilt ]] && echo "prebuilt VM: Omarchy $PB_OMARCHY ($(pb_gb "$PB_SIZE") GB download, release $PB_TAG)" || { [[ $(omarchy_route) == 4.5 ]] && echo "Omarchy 4.5, $(omarchy45_channel) packages, built here"; } || echo "omarchy-mac 4.0 (tests only), built here")" "")
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

# From here on: numbered steps, and everything also into a log file.
STEP=0; STEPS=2
step() { STEP=$((STEP + 1)); ui_step "$STEP" "$STEPS" "$*"; }
BUILD_LOG=~/Library/Logs/omacvm-build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$BUILD_LOG") 2>&1
UI_LOG=$BUILD_LOG
build_end() {
  local rc=$1
  (( rc == 0 && DONE )) && return
  (( rc )) || rc=1
  printf '\n\033[1;31mThe build stopped\033[0m in step %s of %s. The whole log:\n  open "%s"\n' "$STEP" "$STEPS" "$BUILD_LOG"
  printf 'Fix what it says and run omacvm again (a half-built VM can be deleted in OmacVM.app first).\n'

  return "$rc"
}
trap 'build_end $? && rc=0 || rc=$?; ui_restore; exit $rc' EXIT

KEY=~/.ssh/omacvm
[[ -f $KEY ]] || { log "SSH key for the VM: $KEY"; mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"; ssh-keygen -t ed25519 -N "" -C "omacvm" -f "$KEY" -q; }
export OMA_KEY=$KEY
started=$(date +%s)

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
