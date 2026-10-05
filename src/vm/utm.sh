# UTM route helpers for build.sh (sourced, Mac side). Everything goes through
# UTM's own AppleScript interface and utmctl; the only edit to a UTM bundle is
# the custom icon (utm_set_icon), which UTM's scripting cannot set.

utm_osa() { osascript "$@" 2>&1; }

# utm_scripting: may OmacVM drive UTM from here? Prints why not. macOS asks
# once per terminal app whether it may control UTM; over SSH it cannot ask
# (-1743) and utmctl refuses to work. Checked before the long download.
utm_scripting() {
  local out pid i t
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    echo "UTM takes no orders over SSH: run omacvm in Terminal on the Mac itself"
    return 1
  fi
  t=$(mktemp)
  osascript -e 'with timeout of 600 seconds' -e 'tell application "UTM" to count virtual machines' -e 'end timeout' > "$t" 2>&1 &
  pid=$!
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
}

# utm_create NAME CPUS MEMORY_MB LIVE_IMAGE DISK_MB
# A QEMU VM like the one ggalancs/omarchy-arm-utm and OmacVM were tested with:
# HVF, UEFI, virtio-gpu-gl (native resolution, dynamic resolution), virtio-net
# on UTM's shared network, the live installer as a VirtIO disk and the system
# disk as NVMe (the base install looks for the NVMe disk).
utm_create() {
  local name=$1 cpus=$2 mem=$3 live=$4 disk=$5 out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  tell application "UTM"' \
    -e '    set vm to make new virtual machine with properties {backend:qemu, configuration:{name:(item 1 of argv), architecture:"aarch64", memory:((item 3 of argv) as integer), cpu cores:((item 2 of argv) as integer), hypervisor:true, uefi:true, icon:"arch-linux", notes:"Omarchy (omarchy-mac) on Arch Linux ARM, built by OmacVM", drives:{{interface:VirtIO, removable:false, source:(POSIX file (item 4 of argv))}, {interface:NVMe, guest size:((item 5 of argv) as integer)}}, network interfaces:{{hardware:"virtio-net-pci", mode:shared}}, displays:{{hardware:"virtio-gpu-gl-pci", dynamic resolution:true, native resolution:true}}}}' \
    -e '    return id of vm' \
    -e '  end tell' \
    -e 'end run' "$name" "$cpus" "$mem" "$live" "$disk")
  [[ $out =~ ^[0-9A-F-]{36}$ ]] || die "UTM could not create the VM: $out"
  echo "$out"
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

# utm_set_icon NAME: OmacVM's icon in UTM's library (the VM must be stopped).
# UTM's scripting only takes its built-in icon names; a custom icon is a PNG in
# the VM's bundle plus two keys in its config.plist, which UTM reloads.
utm_set_icon() {
  local b="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/$1.utm"
  [[ -f $b/config.plist ]] || { info "UTM VM bundle not in UTM's default folder: icon unchanged"; return 0; }
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/icon/make-icns.sh" "$b/Data/omacvm.png" 512
  plutil -replace Information.Icon -string omacvm.png "$b/config.plist"
  plutil -replace Information.IconCustom -bool true "$b/config.plist"
}

# UTM-wide settings that make the guest faster (from the UTM measurements in
# AGENTS.md): no Vulkan driver, so UTM stops forcing a 4K stage-2 page size
# (2x slower on memory-heavy work); the default renderer (ANGLE on Metal):
# with "Apple Core OpenGL" Chrome in the guest gets no GPU; no App Nap for UTM.
utm_tune_app() {
  defaults write com.utmapp.UTM QEMUVulkanDriver -int 1
  defaults write com.utmapp.UTM QEMURendererBackend -int 0
  defaults write com.utmapp.UTM NSAppSleepDisabled -bool YES
}
