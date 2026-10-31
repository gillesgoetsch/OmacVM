#!/bin/bash
# OmacVM.app's VM window keeps its settings (3.1, plan "Settings persistence"):
# (a) a fresh settings domain and new VMs read every documented default
#     (AGENTS.md, "The VM window's settings");
# (b) a change made the way the window's row makes it is read back by a new
#     launch, and the next one;
# (c) per-VM settings stay with their VM, app-wide ones are the same for all;
# (d) a VM folder and settings as 3.0.x wrote them read the same (no new keys);
# (e) `omacvm resources|graphics|fullscreen|notch --skip` change what the window reads.
# Builds the app's sources with a test main of its own bundle id (own settings
# domain, own Gestures domain), a throwaway HOME, no VM is started, nothing
# of the person's is read or written.
#   src/tests/app-settings.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
D=org.omacvm.test.settings.$$          # the app's settings domain
G=org.omacvm.test.settings-gestures.$$ # its Gestures' (EscapeSwipe, MouseSwipeFingers, SwipeOut)
trap 'defaults delete "$D" >/dev/null 2>&1; defaults delete "$G" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$D.plist" "$HOME/Library/Preferences/$G.plist"; rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's modules, then its sources with this test's main, as an app of its own id.
mkdir -p "$T/mods"
for m in OmacVMUpdate OmacVMNet OmacVMUSB OmacVMFolder OmacVMFeatures OmacVMAuth OmacVMBuildProgress OmacVMWindow OmacVMDesktop OmacVMAudio OmacVMIcon OmacVMMedia; do
  swiftc -swift-version 5 -parse-as-library -module-cache-path "$T/mc" -module-name $m -emit-module \
    -emit-module-path "$T/mods/$m.swiftmodule" -emit-library -static -o "$T/lib$m.a" "$R"/app/app/Sources/$m/*.swift 2>"$T/cc.log" ||
    { cat "$T/cc.log"; echo "FAIL $m does not build"; exit 1; }
done
srcs=()
for f in "$R"/app/app/Sources/OmacVM/*.swift; do
  case $(basename "$f") in main.swift|RenderUpdateUI.swift) ;; *) srcs+=("$f") ;; esac
done
cat > "$T/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$D</string>
<key>OmacVMGesturesDomain</key><string>$G</string>
</dict></plist>
PLIST
swiftc -swift-version 5 -module-cache-path "$T/mc" -I "$T/mods" -L "$T" -lOmacVMUpdate -lOmacVMNet -lOmacVMUSB -lOmacVMFolder \
  -lOmacVMFeatures -lOmacVMAuth -lOmacVMBuildProgress -lOmacVMWindow -lOmacVMDesktop -lOmacVMAudio -lOmacVMIcon -lOmacVMMedia \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$T/Info.plist" \
  -o "$T/t" "${srcs[@]}" "$R/src/tests/app-settings/main.swift" 2>"$T/cc.log" || { cat "$T/cc.log"; echo "FAIL the test app does not build"; exit 1; }

H=$T/home; V=$H/VMs
mkdir -p "$H" "$T/settings"
defaults write "$D" vmsRoot "$V"
run() { HOME=$H CFFIXED_USER_HOME=$H OMACVM_SETTINGS_DIR=$T/settings OMACVM_RESOURCES=$R/app "$T/t" "$@"; }
dump() { run dump > "$T/dump.json" || { echo "FAIL dump"; fail=1; }; }
val() { plutil -extract "$1" raw -o - "$T/dump.json" 2>/dev/null; }   # KEYPATH (vms.0.name)
vm() {   # NAME: a VM folder as the app's build leaves it (create-vm.sh)
  mkdir -p "$V/$1/logs"
  printf "NAME='%s'\nCPUS=4\nMEM_MB=8192\nDISK_GB=64\nSSH_PORT=52222\nVM_USER='me'\nFEATURES='bridge=on gestures=on'\n" "$1" > "$V/$1/vm.env"
  : > "$V/$1/disk.img"; : > "$V/$1/efi-vars.fd"; : > "$V/$1/ready"
  echo "bridge=on gestures=on omanotch=off" > "$V/$1/features"
}
vm Alpha; vm Beta

# (a) Fresh: the documented defaults.
dump
expect "fresh: the dump names the test domain's VMs folder" "$V" "$(val app.vmsRoot)"
expect "fresh: Start in full screen" true "$(val app.startFullScreen)"
expect "fresh: Keep the Dock and hot corners away on" true "$(val app.keepDockAway)"
expect "fresh: Sound on its own thread on" true "$(val app.audioThread)"
expect "fresh: Graphics without QEMU's lock on (gpuOffMainLoop)" true "$(val app.gpuOffMainLoop)"
expect "fresh: Keyboard sharing apps off" false "$(val app.shareKeyboard)"
expect "fresh: Vulkan windows without a copy on (vkWindowsNoCopy)" true "$(val app.vkWindowsNoCopy)"
expect "fresh: HDR and 10-bit colour off" false "$(val app.hdr)"
expect "fresh: Extra brightness off" false "$(val app.extraBrightness)"
expect "fresh: Pause drawing while hidden off" false "$(val app.pauseWhileHidden)"
expect "fresh: Pointer on its own layer off" false "$(val app.pointerPlane)"
expect "fresh: Draw only what changed off" false "$(val app.presentTiles)"
expect "fresh: Ghostty on the Mac's GPU off" false "$(val app.ghosttyGPU)"
expect "fresh: AirPods and media controls on" true "$(val app.mediaControls)"
expect "  on for the app (org.omacvm.app)" true "$(run mediadefault org.omacvm.app)"
expect "  off for the test identity: a test VM never takes the person's AirPods" "false false" \
  "$(run mediadefault org.omacvm.app.test) $(run mediadefault org.omacvm.app.test.lane)"
expect "fresh: Closing the window shuts down" shutdown "$(val app.closeAction)"
expect "fresh: OmacVM's own icon" default "$(val app.appIconTheme)"
expect "fresh: escape combo: focused monitor" pointer "$(val app.escapeSwipe)"
expect "fresh: Magic Mouse swipe: 4 fingers" 4 "$(val app.mouseSwipeFingers)"
expect "fresh: Swipe out to macOS off" false "$(val app.swipeOut)"
expect "fresh: weekly update checks on" true "$(val app.updateChecks)"
for i in 0 1; do
  n=$(val vms.$i.name)
  expect "fresh $n: graphics Automatic" auto "$(val vms.$i.graphics)"
  expect "fresh $n: notch via Omanotch" native "$(val vms.$i.notchMode)"
  expect "fresh $n: Skip the notch off" false "$(val vms.$i.notchSkip)"
  expect "fresh $n: Mac folder off" "" "$(val vms.$i.macFolder)"
  expect "fresh $n: USB devices off, none remembered" "false 0" "$(val vms.$i.usb) $(val vms.$i.usbRemembered)"
  expect "fresh $n: fast network off" false "$(val vms.$i.fastNetwork)"
  expect "fresh $n: Mac input off" false "$(val vms.$i.macIME)"
  expect "fresh $n: resources as built" "4 8 64" "$(val vms.$i.cpus) $(val vms.$i.memoryGB) $(val vms.$i.diskGB)"
done
# The ways back while both graphics switches are on by default: GPU safe mode turns both off,
# gpuMainLoop the lock one, vkWindowsCopy the copy one.
for k in gpuSafeMode gpuMainLoop vkWindowsCopy; do
  defaults write "$D" $k -bool true; dump; defaults delete "$D" $k
  case $k in gpuSafeMode) want="false false" ;; gpuMainLoop) want="false true" ;; vkWindowsCopy) want="true false" ;; esac
  expect "fresh + $k: gpuOffMainLoop vkWindowsNoCopy" "$want" "$(val app.gpuOffMainLoop) $(val app.vkWindowsNoCopy)"
done

# (b) Changes as the window makes them, read by the next launches; (c) per VM.
mkdir -p "$H/Shared"
for kv in "startFullScreen false" "keepDockAway false" "audioThread false" "gpuOffMainLoop false" "shareKeyboard true" "vkWindowsNoCopy false" "hdr true" "extraBrightness true" "pauseWhileHidden true" "pointerPlane true" "presentTiles true" "ghosttyGPU true" "mediaControls false" "closeAction ask" "appIconTheme flexoki-light" \
          "escapeSwipe all" "mouseSwipeFingers 3" "swipeOut true" "updateChecks false"; do
  run set $kv || { echo "FAIL set $kv"; fail=1; }
done
for kv in "resources 6:12" "graphics vulkan" "notchMode fullpanel" "notchSkip true" "macFolder $H/Shared" "usb true" \
          "usbRemember STLink" "macIME true"; do
  run set $kv Alpha || { echo "FAIL set $kv Alpha"; fail=1; }
done
for launch in 1 2; do
  dump
  expect "launch $launch: Start in a window" false "$(val app.startFullScreen)"
  expect "launch $launch: Keep the Dock away off" false "$(val app.keepDockAway)"
  expect "launch $launch: Sound on its own thread off" false "$(val app.audioThread)"
  expect "launch $launch: Graphics without QEMU's lock off" false "$(val app.gpuOffMainLoop)"
  expect "launch $launch: Keyboard sharing apps on" true "$(val app.shareKeyboard)"
  expect "launch $launch: Vulkan windows copied" false "$(val app.vkWindowsNoCopy)"
  expect "launch $launch: HDR and 10-bit colour on" true "$(val app.hdr)"
  expect "launch $launch: Extra brightness on" true "$(val app.extraBrightness)"
  expect "launch $launch: Pause drawing while hidden on" true "$(val app.pauseWhileHidden)"
  expect "launch $launch: Pointer on its own layer on" true "$(val app.pointerPlane)"
  expect "launch $launch: Draw only what changed on" true "$(val app.presentTiles)"
  expect "launch $launch: Ghostty on the Mac's GPU on" true "$(val app.ghosttyGPU)"
  expect "launch $launch: AirPods and media controls off" false "$(val app.mediaControls)"
  expect "launch $launch: Closing the window asks" ask "$(val app.closeAction)"
  expect "launch $launch: icon Flexoki Light" flexoki-light "$(val app.appIconTheme)"
  expect "launch $launch: escape combo: all monitors" all "$(val app.escapeSwipe)"
  expect "launch $launch: Magic Mouse 3 fingers" 3 "$(val app.mouseSwipeFingers)"
  expect "launch $launch: Swipe out on" true "$(val app.swipeOut)"
  expect "launch $launch: update checks off" false "$(val app.updateChecks)"
  expect "launch $launch Alpha: 6 CPUs, 12 GB" "6 12" "$(val vms.0.cpus) $(val vms.0.memoryGB)"
  expect "launch $launch Alpha: Vulkan, including notch" "vulkan fullpanel" "$(val vms.0.graphics) $(val vms.0.notchMode)"
  expect "launch $launch Alpha: Skip the notch on" true "$(val vms.0.notchSkip)"
  expect "launch $launch Beta: Skip the notch still off" false "$(val vms.1.notchSkip)"
  expect "launch $launch Alpha: Mac folder" "$H/Shared" "$(val vms.0.macFolder)"
  expect "launch $launch Alpha: USB on, 1 remembered" "true 1" "$(val vms.0.usb) $(val vms.0.usbRemembered)"
  expect "launch $launch Alpha: Mac input on" true "$(val vms.0.macIME)"
  expect "launch $launch Beta keeps its own: 4 CPUs, auto, native, no folder, USB off" "4 auto native  false false" \
    "$(val vms.1.cpus) $(val vms.1.graphics) $(val vms.1.notchMode) $(val vms.1.macFolder) $(val vms.1.usb) $(val vms.1.macIME)"
done
expect "the switches went where Gestures reads them" "all 3 1" \
  "$(defaults read "$G" EscapeSwipe) $(defaults read "$G" MouseSwipeFingers) $(defaults read "$G" SwipeOut)"
expect "closeAction and appIconTheme in the app's domain" "ask flexoki-light" \
  "$(defaults read "$D" closeAction) $(defaults read "$D" appIconTheme)"
expect "the sound switch is 3.1.16's key in the app's domain" 0 "$(defaults read "$D" audioThread)"
expect "the graphics switch is 3.1.18's key in the app's domain" 0 "$(defaults read "$D" gpuOffMainLoop)"
expect "the keyboard sharing switch is 3.0.18's key in the app's domain" 1 "$(defaults read "$D" shareKeyboard)"
expect "the Vulkan windows switch is a key in the app's domain" 0 "$(defaults read "$D" vkWindowsNoCopy)"
expect "the HDR switch is the hidden switch's key in the app's domain" 1 "$(defaults read "$D" hdr)"
expect "the extra brightness switch is the key QEMU reads in the app's domain" 1 "$(defaults read "$D" extraBrightness)"
expect "the pause switch is the key QEMU reads in the app's domain" 1 "$(defaults read "$D" pauseWhileHidden)"
expect "the media controls switch is the key the launcher watches in the app's domain" 0 "$(defaults read "$D" mediaControls)"
expect "update checks in the file the control centre shares" "false" \
  "$(plutil -extract update_checks raw -o - "$T/settings/settings.json")"

# Frames in step with the Mac (vsyncLock, 3.2.3-3.2.6) is gone (3.2.7, ADR 0057): a launch removes
# the stored key once, nothing reads or shows it, and no start asks the VM for it.
defaults write "$D" vsyncLock -bool true
run retire 2>"$T/retire.log" || { echo "FAIL retire"; fail=1; }
expect "vsyncLock stored by 3.2.3-3.2.6: removed at launch" "" "$(defaults read "$D" vsyncLock 2>/dev/null)"
expect "  says so once" 1 "$(grep -c 'Frames in step with the Mac was removed in 3.2.7' "$T/retire.log")"
run retire 2>"$T/retire.log" || { echo "FAIL retire again"; fail=1; }
expect "  a later launch has nothing to say" 0 "$(grep -c . "$T/retire.log")"
dump
expect "  not in the window's settings" "" "$(val app.vsyncLock)"
grep -q '^ *Settings.removeRetiredSwitches()' "$R/app/app/Sources/OmacVM/main.swift" &&
  echo "ok   the app removes retired switches at launch" || { echo "FAIL main.swift does not call Settings.removeRetiredSwitches()"; fail=1; }
S=$R/app/app/Sources/OmacVM
for w in 'omacvm.vsynclock' 'vsyncLock' 'VsyncLockRow' 'Frames in step'; do
  n=$(grep -l "$w" "$S/Runner.swift" "$S/SettingsRows.swift" "$S/SettingsView.swift" "$S/SettingsDump.swift" | wc -l | tr -d ' ')
  expect "no '$w' in Runner, the rows, the window or the dump" 0 "$n"
done

# (d) A VM and the settings as 3.0.17 wrote them: the same keys, read as they are.
vm Gamma
echo fullpanel > "$V/Gamma/notch-mode"; echo opengl > "$V/Gamma/graphics"; echo on > "$V/Gamma/fast-network"
echo "$H/Shared" > "$V/Gamma/mac-folder"; echo on > "$V/Gamma/usb-enabled"
echo "bridge=on gestures=on omanotch=off mac-ime=on fast-network=on" > "$V/Gamma/features"
defaults write "$D" startFullScreen -bool true
defaults write "$D" keepDockAway -bool true
defaults write "$G" EscapeSwipe pointer
defaults write "$G" MouseSwipeFingers -int 4
dump
expect "3.0.x Gamma: OpenGL, including notch" "opengl fullpanel" "$(val vms.2.graphics) $(val vms.2.notchMode)"
expect "3.0.x Gamma: fast network, Mac folder, USB, Mac input" "true $H/Shared true true" \
  "$(val vms.2.fastNetwork) $(val vms.2.macFolder) $(val vms.2.usb) $(val vms.2.macIME)"
expect "3.0.x app-wide: full screen, Dock away, focused monitor, 4 fingers" "true true pointer 4" \
  "$(val app.startFullScreen) $(val app.keepDockAway) $(val app.escapeSwipe) $(val app.mouseSwipeFingers)"
expect "3.1's own stay: ask, Flexoki Light, Swipe out" "ask flexoki-light true" \
  "$(val app.closeAction) $(val app.appIconTheme) $(val app.swipeOut)"
expect "3.0.x Gamma: Skip the notch off (new, off by default), Alpha's kept" "false true" \
  "$(val vms.2.notchSkip) $(val vms.0.notchSkip)"
# A folder from 3.1.14-3.1.26 with Vendor HID devices on (usb-vendor-hid, gone since): plain USB, no stale setting.
echo on > "$V/Gamma/usb-vendor-hid"
dump
expect "3.1.14-3.1.26 Gamma: usb-vendor-hid left there: USB on as before, nothing of it in the window" "true 0 0" \
  "$(val vms.2.usb) $(val vms.2.usbRemembered) $(grep -ci "vendor.\{0,1\}hid" "$T/dump.json")"

# (e) omacvm on the Mac changes what the window reads (the test identity's
# CLI with this test's settings domain).
cli() { HOME=$H OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=$D "$R/omacvm" "$@" >"$T/cli.log" 2>&1 || { echo "FAIL omacvm $*: $(tail -1 "$T/cli.log")"; fail=1; }; }
cli resources --vm Beta --vm-type app --cpus 2 --memory-gb 6
cli graphics --vm Beta opengl
cli fullscreen --vm Beta notch
dump
expect "omacvm resources: Beta 2 CPUs, 6 GB" "2 6" "$(val vms.1.cpus) $(val vms.1.memoryGB)"
expect "omacvm graphics: Beta OpenGL" opengl "$(val vms.1.graphics)"
expect "omacvm fullscreen notch: Beta including notch" fullpanel "$(val vms.1.notchMode)"
expect "Alpha untouched by Beta's changes" "6 vulkan" "$(val vms.0.cpus) $(val vms.0.graphics)"
cli fullscreen --vm Beta standard
dump
expect "omacvm fullscreen standard: Beta via Omanotch" native "$(val vms.1.notchMode)"
cli notch --vm Beta --skip on
dump
expect "omacvm notch --skip on: Beta skips the notch" true "$(val vms.1.notchSkip)"
cli notch --vm Alpha --skip off
dump
expect "omacvm notch --skip off: Alpha off, Beta on" "false true" "$(val vms.0.notchSkip) $(val vms.1.notchSkip)"
expect "  the file the window and the CLI share" "on" "$(cat "$V/Beta/notch-skip")"

# (f) Extra brightness keeps the user's setting, off as well as on. Only the user's switches write
# it (the row, the VM's Display panel, defaults write); a start reads it. Each step: what a start
# reads (`t start`, as Runner.start), then a new launch's dump. OMACVM_TEST_EDR stands in for the
# display: 16,2.4 an XDR panel, 1,1 an SDR monitor (a MacBook in clamshell: no row, no extra brightness).
defaults delete "$D" hdr
for want in false true; do
  run set extraBrightness $want || { echo "FAIL set extraBrightness $want"; fail=1; }
  for step in "XDR" "GPU safe mode on" "GPU safe mode off" "HDR on" "HDR off" "an SDR monitor only" "XDR again" "a second VM's start"; do
    case $step in
      "GPU safe mode on") defaults write "$D" gpuSafeMode -bool true ;;
      "GPU safe mode off") defaults delete "$D" gpuSafeMode ;;
      "HDR on") run set hdr true ;;
      "HDR off") run set hdr false ;;
    esac
    edr=16,2.4; [[ $step == "an SDR monitor only" ]] && edr=1,1
    s=$(OMACVM_TEST_EDR=$edr run start)
    case $want/$step in
      false/*) w="extra false (switch off)" ;;
      true/"GPU safe mode on") w="extra false (GPU safe mode)" ;;
      true/"an SDR monitor only") w="extra false (no display with extra brightness)" ;;
      true/*) w="extra true (up to 2x on a display with the headroom)" ;;
    esac
    expect "Extra brightness $want, $step: the start's answer" "$w" "${s%%, hdr*}"
    dump
    expect "Extra brightness $want, $step: the switch still $want" $want "$(val app.extraBrightness)"
  done
  expect "Extra brightness $want: the key as the switch left it" "$([[ $want == true ]] && echo 1 || echo 0)" \
    "$(defaults read "$D" extraBrightness)"
done
expect "Extra brightness: HDR's own switch as set last" false "$(val app.hdr)"

# (g) Draw only what changed: a start asks the VM for its driver's damage fix (SMBIOS
# omacvm.damage=1) and QEMU for tiles (OMACVM_GL_PRESENT_TILES=1) only with the switch on and
# GPU safe mode off; GPU safe mode leaves the switch as set. Runner takes both from one answer.
for want in false true; do
  run set presentTiles $want || { echo "FAIL set presentTiles $want"; fail=1; }
  for step in "plain" "GPU safe mode on" "GPU safe mode off" "layer present"; do
    case $step in
      "GPU safe mode on") defaults write "$D" gpuSafeMode -bool true ;;
      "GPU safe mode off") defaults delete "$D" gpuSafeMode ;;
    esac
    if [[ $step == "layer present" ]]; then s=$(OMACVM_GL_PRESENT=layer run start); else s=$(run start); fi
    case $want/$step in
      false/*) w="tiles false (switch off)" ;;
      true/"GPU safe mode on") w="tiles false (GPU safe mode)" ;;
      true/"layer present") w="tiles false (OMACVM_GL_PRESENT=layer: frames in a CAOpenGLLayer)" ;;
      true/*) w="tiles true (the VM's driver says what changed, QEMU shows it in tiles)" ;;
    esac
    expect "Draw only what changed $want, $step: the start's answer" "$w" "tiles ${s##*, tiles }"
    dump
    expect "Draw only what changed $want, $step: the switch still $want" $want "$(val app.presentTiles)"
  done
done
# (h) Ghostty on the Mac's GPU: a start tells the VM (SMBIOS omacvm.glzink=1) only with the switch
# on, GPU safe mode off, Venus at that start and KosmicKrisp as its Vulkan driver; GPU safe mode
# leaves the switch as set.
for want in false true; do
  run set ghosttyGPU $want || { echo "FAIL set ghosttyGPU $want"; fail=1; }
  for step in "1 kosmickrisp" "0 kosmickrisp" "1 moltenvk" "1 listed" "safe 1 kosmickrisp"; do
    [[ $step == safe* ]] && defaults write "$D" gpuSafeMode -bool true
    s=$(run ghostty ${step#safe })
    defaults delete "$D" gpuSafeMode 2>/dev/null
    case $want/$step in
      false/*) w="ghostty false (switch off)" ;;
      true/safe*) w="ghostty false (GPU safe mode)" ;;
      "true/0 kosmickrisp") w="ghostty false (Graphics is OpenGL at this start)" ;;
      "true/1 moltenvk") w="ghostty false (MoltenVK: needs KosmicKrisp (macOS 26 and newer))" ;;
      "true/1 listed") w="ghostty false (the Vulkan driver VK_DRIVER_FILES names)" ;;
      true/*) w="ghostty true (Zink over Venus on KosmicKrisp)" ;;
    esac
    expect "Ghostty on the Mac's GPU $want, $step: the start's answer" "$w" "$s"
    dump
    expect "Ghostty on the Mac's GPU $want, $step: the switch still $want" $want "$(val app.ghosttyGPU)"
  done
done
RUNNER=$R/app/app/Sources/OmacVM/Runner.swift
grep -q 'ghosttyGPU = Settings.ghosttyGPUStart(venus: g.venus, driver: Runner.vulkanDriverKind)' "$RUNNER" &&
  grep -A1 -F 'if ghosttyGPU.on {' "$RUNNER" | grep -q 'value=\\(GhosttyGPU.smbios)' &&
  grep -A1 -F 'if Settings.ghosttyGPU {' "$RUNNER" | grep -q 'GhosttyGPU.record(ghosttyGPU)' &&
  ! grep -q 'Settings.ghosttyGPU &&' "$RUNNER" && echo "ok   Runner: omacvm.glzink=1 from this start's answer (Venus, the driver), the qemu.log line while the switch is on" ||
  { echo "FAIL Runner: omacvm.glzink=1 not from Settings.ghosttyGPUStart(venus:driver:) or no qemu.log line"; fail=1; }
expect "Runner: QEMU's tiles and the guest's omacvm.damage=1 from the same start answer" "2" \
  "$(grep -c 'if tiles.on {' "$RUNNER")"
grep -q 'a += \["-smbios", "type=11,value=omacvm.damage=1"\]' "$RUNNER" && grep -q 'env\["OMACVM_GL_PRESENT_TILES"\] = env\["OMACVM_GL_PRESENT_TILES"\] == "check" ? "check" : "1"' "$RUNNER" &&
  ! grep -q 'Settings.presentTiles && ' "$RUNNER" && echo "ok   Runner: both under tiles.on, not the bare switch" ||
  { echo "FAIL Runner: omacvm.damage=1 / OMACVM_GL_PRESENT_TILES not from Settings.presentTilesStart()"; fail=1; }
# The (i): with the switch off, HDR and the pointer layer still load OmacVM's driver, and it
# carries the damage fix; only the Mac's tiles are off. Not "the standard driver", and not the
# removed Frames in step with the Mac.
info=$(sed -n '/^struct PresentTilesRow/,/static let info/p' "$R/app/app/Sources/OmacVM/SettingsRows.swift" | tail -n1)
if [[ $info == *"HDR and 10-bit colour or Pointer on its own layer is on"* &&
      $info == *"draws whole frames"* && $info != *"keeps its standard driver"* && $info != *"Frames in step"* ]]; then
  echo "ok   Draw only what changed (i): off = the driver the other switches ask for, whole frames on the Mac"
else
  echo "FAIL Draw only what changed (i): says off = the standard driver (HDR / pointer layer load OmacVM's, with the damage fix), or names the removed Frames in step"; fail=1
fi
# The M1 Max's HDR 120 Hz set (td2) passed: the (i) says 120 Hz is tested, with its numbers.
if [[ $info == *"M1 Max"* && $info == *"120 Hz"* && $info != *"not tested yet"* ]]; then
  echo "ok   Draw only what changed (i): tested at 120 Hz (HDR, M1 Max)"
else
  echo "FAIL Draw only what changed (i): still says 120 Hz is not tested (td2 passed on the M1 Max)"; fail=1
fi
# td2's M1 Max watts had a macOS prompt over the VM on both sides: no M1 Max percentages in the (i)
# until td2b runs without it (the Air's measured -11..-17 % stays).
m1=${info#*M1 Max}; m1=${m1%%(*}
if [[ $m1 != *"%"* ]]; then
  echo "ok   Draw only what changed (i): no M1 Max power figures before td2b"
else
  echo "FAIL Draw only what changed (i): gives M1 Max percentages from td2 (prompt over the VM, re-run pending)"; fail=1
fi

exit $fail
