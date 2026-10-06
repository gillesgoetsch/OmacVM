# OmacVM.app's Graphics setting on the Mac side (omacvm apply, omacvm graphics,
# omacvm check): the same rules as app/app/Sources/OmacVM/Graphics.swift,
# which the app uses at each VM start. src/tests/graphics-setting.sh checks
# that both give the same answers.
# A VM folder's `graphics` file: opengl, vulkan or auto (none = auto).
# Venus (Vulkan) at a start: vulkan or auto-picks-Vulkan, once the VM has its
# Venus driver (`venus-ready`, written by omacvm apply; before that OpenGL:
# GRAPHICS_WAITING_FOR_DRIVER); or the vulkan feature's `vulkan` file (always).

GRAPHICS_AUTO_VULKAN=1               # Graphics.autoVulkan (3.0.2: Automatic = Vulkan on macOS 26+ with KosmicKrisp)
GRAPHICS_AUTO_VULKAN_FROM_MACOS=26   # Graphics.autoVulkanFromMacOS
GRAPHICS_AUTO_VULKAN_ON_MOLTENVK=0   # Graphics.autoVulkanOnMoltenVK
GRAPHICS_WAITING_FOR_DRIVER="driver not built yet: runs on OpenGL until the next apply"   # Graphics.waitingForDriver
GRAPHICS_DID_NOT_START="Vulkan did not start on this Mac: using OpenGL"   # Graphics.didNotStart
GRAPHICS_HIGH_PCI_WINDOW_BITS=40     # Graphics.highPCIWindowBits
GRAPHICS_LOW_WINDOW_HOSTMEM_MB=256   # Graphics.lowWindowHostmemMB
GRAPHICS_SMALL_HIGH_WINDOW_MAX_GB=16 # Graphics.smallHighWindowMaxGB

graphics_choice() {   # DIR -> opengl|vulkan|auto
  local c
  c=$(tr -d "[:space:]" 2>/dev/null < "$1/graphics") || c=""
  case $c in opengl|vulkan) echo "$c"; return ;; esac
  # Up to 2.9 the app's hidden `venus` switch put Vulkan in every VM; the
  # 3.0.0 app moves it into this file at its first launch and removes it
  # (Graphics.migrateVenusSwitch). Until then omacvm reads it the same way.
  if [[ -n ${OMACVM_TEST_VENUS_SWITCH+x} ]]; then [[ $OMACVM_TEST_VENUS_SWITCH == 1 ]] && { echo vulkan; return; }
  elif [[ $(defaults read "${APP_ID:-org.omacvm.app}" venus 2>/dev/null) == 1 ]]; then echo vulkan; return; fi
  echo auto
}

graphics_macos_major() { echo "${OMACVM_TEST_MACOS_MAJOR:-$(sw_vers -productVersion | cut -d. -f1)}"; }

# The OmacVM.app whose runtime has KosmicKrisp (Metal 4, macOS 26+).
graphics_kosmickrisp() {
  [[ -n ${OMACVM_TEST_KOSMICKRISP:-} ]] && { [[ $OMACVM_TEST_KOSMICKRISP == 1 ]]; return; }
  # apply-vm.sh: the app that runs it (and its VM).
  [[ -n ${OMACVM_APP_RUNTIME:-} ]] && { [[ -e $OMACVM_APP_RUNTIME/lib/libvulkan_kosmickrisp.dylib ]]; return; }
  local a
  a=$(app_bundle 2>/dev/null) || return 1
  [[ -e $a/Contents/Resources/runtime/lib/libvulkan_kosmickrisp.dylib ]]
}

graphics_auto_vulkan() {   # MACOS_MAJOR KK(0|1): Automatic gives Vulkan on this Mac
  (( GRAPHICS_AUTO_VULKAN && (($1 >= GRAPHICS_AUTO_VULKAN_FROM_MACOS && $2) || GRAPHICS_AUTO_VULKAN_ON_MOLTENVK) ))
}

graphics_forced() {   # DIR: the vulkan feature (OmacVM's Mesa) keeps Venus on
  [[ -e $1/vulkan ]]
}

# DIR -> vulkan|opengl: what the VM gets on this Mac once its driver is there
# (omacvm apply builds the driver ahead for vulkan).
graphics_wants() {
  local kk=0
  graphics_kosmickrisp && kk=1
  if graphics_forced "$1"; then echo vulkan; return; fi
  case $(graphics_choice "$1") in
    vulkan) echo vulkan ;;
    opengl) echo opengl ;;
    auto) graphics_auto_vulkan "$(graphics_macos_major)" "$kk" && echo vulkan || echo opengl ;;
  esac
}

# DIR: Vulkan wanted, but the VM has no Venus driver for 16 KiB pages yet
# (OpenGL until then: with the old driver every Vulkan app fails).
graphics_waiting_for_driver() {
  [[ $(graphics_wants "$1") == vulkan && ! -e $1/venus-ready ]] && ! graphics_forced "$1"
}

# DIR -> why the last Vulkan start fell back to OpenGL (graphics-fallback,
# written by the app: Graphics.recordFallback); fails when it did not.
graphics_fallback() {
  [[ -e $1/graphics-fallback ]] || return 1
  local l; l=$(head -1 "$1/graphics-fallback" 2>/dev/null) || l=""
  echo "${l:-it showed nothing}"
}

# DIR -> vulkan|opengl at the VM's next start (with the driver condition).
graphics_next_start() {
  if graphics_waiting_for_driver "$1" || graphics_fallback "$1" >/dev/null; then echo opengl; else graphics_wants "$1"; fi
}

# DIR -> the next start in words (GraphicsPlan.summary).
graphics_summary() {
  local f
  if [[ $(graphics_next_start "$1") == vulkan ]]; then echo "OpenGL and Vulkan"
  elif [[ $(graphics_choice "$1") == vulkan ]] && graphics_waiting_for_driver "$1"; then echo "Vulkan ($GRAPHICS_WAITING_FOR_DRIVER)"
  elif [[ $(graphics_choice "$1") == vulkan ]] && [[ $(graphics_wants "$1") == vulkan ]] && f=$(graphics_fallback "$1"); then
    echo "$GRAPHICS_DID_NOT_START ($f; choose Vulkan again to try once more)"
  else echo OpenGL; fi
}

# QEMU's high PCI window in GB on a Mac whose VMs get less than 40 address
# bits (M1/M2): Graphics.highWindowGB. Nothing when none fits or not needed.
graphics_high_window_gb() {   # VM_GB [VM_ADDRESS_BITS]
  local b=${2:-} top start w=$GRAPHICS_SMALL_HIGH_WINDOW_MAX_GB
  [[ -n $b ]] && (( b < GRAPHICS_HIGH_PCI_WINDOW_BITS && b > 30 )) || return 0
  top=$(( 1 << (b - 30) )); start=$(( $1 + 3 ))
  while (( w >= 1 )); do
    (( (start + w - 1) / w * w + w <= top )) && { echo "$w"; return; }
    w=$(( w / 2 ))
  done
}

# Venus's host memory window in MB: Graphics.hostmemMB (on a Mac whose VMs
# get less than 40 address bits, M1/M2: at most half the small high PCI
# window, or 256 MB when none fits).
graphics_hostmem_mb() {   # MAC_GB VM_GB [VM_ADDRESS_BITS]
  local reserve=8 free p=1 w m
  if [[ -n ${3:-} ]] && (( $3 < GRAPHICS_HIGH_PCI_WINDOW_BITS )); then
    w=$(graphics_high_window_gb "$2" "$3")
    [[ -n $w ]] || { echo "$GRAPHICS_LOW_WINDOW_HOSTMEM_MB"; return; }
    m=$(graphics_hostmem_mb "$1" "$2")
    (( m > w * 512 )) && m=$(( w * 512 ))
    echo "$m"; return
  fi
  (( $1 <= 36 )) && reserve=6
  (( $1 <= 16 )) && reserve=4
  free=$(( $1 - $2 - reserve ))
  (( free < 1 )) && free=1
  (( free > 32 )) && free=32
  while (( p * 2 <= free )); do p=$(( p * 2 )); done
  echo $(( p * 1024 ))
}

graphics_title() {   # opengl|vulkan|auto -> its name in the app
  case $1 in opengl) echo OpenGL ;; vulkan) echo Vulkan ;; *) echo Automatic ;; esac
}
