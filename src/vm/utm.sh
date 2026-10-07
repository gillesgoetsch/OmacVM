# UTM route helpers for build.sh (sourced, Mac side). Everything goes through
# UTM's own AppleScript interface and utmctl; the only edit to a UTM bundle is
# the custom icon (utm_set_icon), which UTM's scripting cannot set.

utm_osa() { osascript "$@" 2>&1; }

# utm_scripting: may OmacVM drive UTM from here? Prints why not. macOS asks
# once per terminal app whether it may control UTM; over SSH it cannot ask
# (-1743) and utmctl refuses to work. Checked before the long download.
# A subshell, for its own Ctrl-C trap: osascript waits in the background,
# which ignores Ctrl-C, and would go on waiting for an answer for 10 minutes.
utm_scripting() (
  local out pid i t
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    echo "UTM takes no orders over SSH: run omacvm in Terminal on the Mac itself"
    return 1
  fi
  t=$(mktemp)
  osascript -e 'with timeout of 600 seconds' -e 'tell application "UTM" to count virtual machines' -e 'end timeout' > "$t" 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null; rm -f "$t"; exit 130' INT TERM
  for ((i = 0; i < 6; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && info "macOS asks whether this terminal may control UTM: click Allow" >&2
  wait "$pid" && { rm -f "$t"; return 0; }
  out=$(cat "$t"); rm -f "$t"
  case $out in
    *-1743*) echo "this terminal may not control UTM: System Settings > Privacy & Security > Automation > your terminal app > UTM: on, then run omacvm again" ;;
    *-1712*) echo "UTM did not answer in time: click Allow if macOS still asks whether this terminal may control UTM, else quit and reopen UTM; then run omacvm again" ;;
    *) echo "UTM did not answer (${out:-no reply}): quit and reopen UTM, then run omacvm again" ;;
  esac
  return 1
)

# utm_create NAME CPUS MEMORY_MB LIVE_IMAGE DISK_MB
# A QEMU VM like the one ggalancs/omarchy-arm-utm and OmacVM were tested with:
# HVF, UEFI, virtio-gpu-gl (native resolution, dynamic resolution), virtio-net
# on UTM's shared network, the live installer as a VirtIO disk and the system
# disk as NVMe (the base install looks for the NVMe disk). LIVE_IMAGE "": the
# NVMe disk only (utm_add_live adds the installer later).
utm_create() {
  local name=$1 cpus=$2 mem=$3 live=$4 disk=$5 out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  set f to missing value' \
    -e '  if (item 4 of argv) is not "" then set f to POSIX file (item 4 of argv)' \
    -e '  tell application "UTM"' \
    -e '    set ds to {{interface:NVMe, guest size:((item 5 of argv) as integer)}}' \
    -e '    if f is not missing value then set ds to {{interface:VirtIO, removable:false, source:f}} & ds' \
    -e '    set vm to make new virtual machine with properties {backend:qemu, configuration:{name:(item 1 of argv), architecture:"aarch64", memory:((item 3 of argv) as integer), cpu cores:((item 2 of argv) as integer), hypervisor:true, uefi:true, icon:"arch-linux", notes:"Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM", drives:ds, network interfaces:{{hardware:"virtio-net-pci", mode:shared}}, displays:{{hardware:"virtio-gpu-gl-pci", dynamic resolution:true, native resolution:true}}}}' \
    -e '    return id of vm' \
    -e '  end tell' \
    -e 'end run' "$name" "$cpus" "$mem" "$live" "$disk")
  [[ $out =~ ^[0-9A-F-]{36}$ ]] || die "UTM could not create the VM: $out"
  echo "$out"
}

# utm_move NAME DIR: put a new (stopped) VM in DIR instead of UTM's own
# folder, which is in UTM's container on the Mac's internal disk. UTM's
# scripting exports it there, deletes the original and opens the copy, which
# UTM keeps in its list (by a bookmark, as File > Open does). Only UTM touches
# its container. The copy is opened through UTM's scripting: on the Mac mini
# (macOS 27, UTM 5.0.6) a UTM started by an Apple event ignored `open -a UTM
# bundle`; LaunchServices' open is only the fallback.
utm_move() {
  local name=$1 b="$2/$1.utm" out i
  [[ ! -e $b ]] || die "$b already exists"
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  set f to POSIX file (item 2 of argv)' \
    -e '  tell application "UTM"' \
    -e '    export (virtual machine named (item 1 of argv)) to f' \
    -e '  end tell' \
    -e 'end run' "$name" "$b") || true   # build.sh runs with set -e: the check below says why
  [[ -f $b/config.plist ]] || die "UTM could not put the VM into $2: $out"
  out=$(utm_osa -e 'on run argv' -e 'tell application "UTM" to delete (virtual machine named (item 1 of argv))' -e 'end run' "$name") ||
    die "UTM could not delete its own copy of the VM ($out): delete '$name' in UTM, then open $b in UTM"
  utm_osa -e 'on run argv' -e 'tell application "UTM" to open (POSIX file (item 1 of argv))' -e 'end run' "$b" >/dev/null || true
  for ((i = 0; i < 30; i++)); do
    "$UTMCTL" list 2>/dev/null | awk 'NR > 1 { $1 = ""; $2 = ""; sub(/^  /, ""); print }' | grep -qxF "$name" && return 0
    (( i == 10 )) && open -a UTM "$b"
    sleep 1
  done
  die "UTM did not open the VM in $b: open it in UTM (File > Open) and run omacvm build again"
}

# utm_add_live NAME LIVE_IMAGE: the live installer as the first disk (VirtIO);
# UTM copies it into the VM's bundle. The VM must be stopped.
utm_add_live() {
  local out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  set f to POSIX file (item 2 of argv)' \
    -e '  tell application "UTM"' \
    -e '    set vm to virtual machine named (item 1 of argv)' \
    -e '    copy (configuration of vm) to c' \
    -e '    set drives of c to {{interface:VirtIO, removable:false, source:f}} & (drives of c)' \
    -e '    update configuration of vm with c' \
    -e '    copy (configuration of vm) to c2' \
    -e '    set ds to drives of c2' \
    -e '    return length of ds' \
    -e '  end tell' \
    -e 'end run' "$1" "$2") || true
  [[ $out == 2 ]] || die "UTM could not add the live installer disk: $out"
}

# utm_import BUNDLE: add a .utm bundle to UTM's library (UTM copies it into
# its own folder).
utm_import() {
  local out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  tell application "UTM"' \
    -e '    set vm to import new virtual machine from (POSIX file (item 1 of argv))' \
    -e '    return id of vm' \
    -e '  end tell' \
    -e 'end run' "$1")
  [[ $out =~ ^[0-9A-F-]{36}$ ]] || die "UTM could not import the VM: $out"
}

# utm_drop_live NAME: keep only the NVMe system disk (the VM must be stopped).
utm_drop_live() {
  local out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  tell application "UTM"' \
    -e '    set vm to virtual machine named (item 1 of argv)' \
    -e '    copy (configuration of vm) to c' \
    -e '    set keep to {}' \
    -e '    repeat with d in (drives of c)' \
    -e '      if interface of d is NVMe then set end of keep to (contents of d)' \
    -e '    end repeat' \
    -e '    set drives of c to keep' \
    -e '    update configuration of vm with c' \
    -e '    copy (configuration of vm) to c2' \
    -e '    set ds to drives of c2' \
    -e '    return length of ds' \
    -e '  end tell' \
    -e 'end run' "$1")
  [[ $out == 1 ]] || die "could not remove the live installer disk: $out"
}

# utm_set_icon NAME [BUNDLE]: OmacVM's icon in UTM's library (the VM must be
# stopped). UTM's scripting only takes its built-in icon names; a custom icon is
# a PNG in the VM's bundle plus two keys in its config.plist, which UTM reloads.
# BUNDLE: a VM outside UTM's folder (utm_move).
utm_set_icon() {
  local b=${2:-"$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/$1.utm"}
  [[ -f $b/config.plist ]] || { info "UTM VM bundle not in UTM's default folder: icon unchanged"; return 0; }
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/icon/make-icns.sh" "$b/Data/omacvm.png" 512
  plutil -replace Information.Icon -string omacvm.png "$b/config.plist"
  plutil -replace Information.IconCustom -bool true "$b/config.plist"
}

# UTM-wide settings that make the guest faster (from the UTM measurements in
# AGENTS.md): no Vulkan driver, so UTM stops forcing a 4K stage-2 page size
# (2x slower on memory-heavy work); the default renderer (ANGLE on Metal):
# with "Apple Core OpenGL" Chrome in the guest gets no GPU; no App Nap for UTM.
# They live in UTM's container: when macOS keeps this terminal app out of other
# apps' data (the "access data from other apps" question was answered Don't
# Allow), the VM is still built, with UTM's settings as they are.
utm_tune_app() {
  { defaults write com.utmapp.UTM QEMUVulkanDriver -int 1 &&
    defaults write com.utmapp.UTM QEMURendererBackend -int 0 &&
    defaults write com.utmapp.UTM NSAppSleepDisabled -bool YES; } 2>/dev/null && return 0
  info "UTM's settings unchanged: macOS does not let this terminal app change UTM's data (it asked whether it may access data from other apps). The VM works; it is faster with them."
}
