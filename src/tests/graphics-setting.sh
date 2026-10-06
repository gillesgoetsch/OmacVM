#!/bin/bash
# OmacVM.app's Graphics setting: the app (app/app/Sources/OmacVM/Graphics.swift)
# and the Mac side of omacvm (src/lib/graphics.sh) decide the same for every
# case (macOS version, KosmicKrisp in the app, the VM's Venus driver, the
# vulkan feature, Mac and VM memory, the Mac's VM address space, a Vulkan
# start that fell back), plus the rules themselves. No VM.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { [[ $2 == "$3" ]] && ok "$1" || bad "$1: got '$3', want '$2'"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

swiftc -O -o "$T/graphics" "$R/app/app/Sources/OmacVM/Graphics.swift" "$R/src/tests/graphics-setting/main.swift" ||
  { echo "FAIL Graphics.swift does not build on its own"; exit 1; }
"$T/graphics" > "$T/swift.txt"

source "$R/src/lib/graphics.sh"
app_bundle() { return 1; }
n=0; diff=0
export OMACVM_TEST_VENUS_SWITCH=0
while IFS='|' read -r left want_s; do
  read -r c macos kk ready forced mac vm ipa fb _ want_v want_m want_w <<<"$left"; want_s=${want_s# }
  d=$T/vm; rm -rf "$d"; mkdir -p "$d"
  echo "$c" > "$d/graphics"
  (( ready )) && : > "$d/venus-ready"
  (( forced )) && : > "$d/vulkan"
  (( fb )) && echo "the firmware found no devices" > "$d/graphics-fallback"
  got_v=$(OMACVM_TEST_MACOS_MAJOR=$macos OMACVM_TEST_KOSMICKRISP=$kk graphics_next_start "$d")
  got_s=$(OMACVM_TEST_MACOS_MAJOR=$macos OMACVM_TEST_KOSMICKRISP=$kk graphics_summary "$d")
  got_m=$(graphics_hostmem_mb "$mac" "$vm" "$ipa")
  got_w=-; [[ $got_v == vulkan ]] && got_w=$(graphics_high_window_gb "$vm" "$ipa") && [[ -n $got_w ]] || got_w=-
  n=$((n + 1))
  if [[ $got_v != "$want_v" || $got_m != "$want_m" || $got_w != "$want_w" || $got_s != "$want_s" ]]; then
    diff=$((diff + 1)); (( diff <= 5 )) && echo "  differs: $c macOS $macos kk $kk ready $ready forced $forced $mac/$vm GB ipa $ipa fallback $fb: app $want_v $want_m $want_w '$want_s', omacvm $got_v $got_m $got_w '$got_s'"
  fi
done < "$T/swift.txt"
(( diff == 0 )) && ok "app and omacvm agree on $n cases" || bad "app and omacvm differ in $diff of $n cases"

line() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f1 | awk '{ print $(NF-2) }'; }
mem() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f1 | awk '{ print $(NF-1) }'; }
win() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f1 | awk '{ print $NF }'; }
summ() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f2- | sed 's/^ //'; }
# The rules (choice macOS kk ready forced macGB vmGB ipaBits fallback).
expect "OpenGL: no Vulkan"                          opengl "$(line 'opengl 27 1 1 0 16 8 42 0')"
expect "Vulkan with the driver: Vulkan"             vulkan "$(line 'vulkan 15 0 1 0 16 8 42 0')"
expect "Vulkan without the driver: OpenGL"          opengl "$(line 'vulkan 15 0 0 0 16 8 42 0')"
expect "  ... and says so" "Vulkan (driver not built yet: runs on OpenGL until the next apply)" "$(summ 'vulkan 27 1 0 0 16 8 42 0')"
expect "Automatic, macOS 27 + KosmicKrisp + driver: OpenGL (3.0.0)" opengl "$(line 'auto 27 1 1 0 16 8 42 0')"
expect "Automatic waits for the VM's driver"        opengl "$(line 'auto 27 1 0 0 16 8 42 0')"
expect "Automatic, macOS 26 without KosmicKrisp"    opengl "$(line 'auto 26 0 1 0 16 8 42 0')"
expect "Automatic, macOS 15 (MoltenVK)"             opengl "$(line 'auto 15 1 1 0 16 8 42 0')"
expect "vulkan feature keeps Vulkan under OpenGL"   vulkan "$(line 'opengl 15 0 0 1 16 8 42 0')"
# The host memory window: what the Mac has beyond the VM and macOS's reserve.
expect "8 GB Mac, 4 GB VM: 1 GB"    1024  "$(mem 'auto 15 0 0 0 8 4 42 0')"
expect "16 GB Mac, 8 GB VM: 4 GB"   4096  "$(mem 'auto 15 0 0 0 16 8 42 0')"
expect "36 GB Mac, 16 GB VM: 8 GB"  8192  "$(mem 'auto 15 0 0 0 36 16 42 0')"
expect "128 GB Mac, 16 GB VM: 32 GB (most)" 32768 "$(mem 'auto 15 0 0 0 128 16 42 0')"
expect "128 GB Mac, 48 GB VM: 64 -> 32 GB"  32768 "$(mem 'auto 15 0 0 0 128 48 42 0')"
# M1/M2 (36-bit VM address space): QEMU's own high PCI window does not fit,
# so the app asks for a small one right above RAM (16 GB at most); the host
# memory window takes at most half of it. A 1 GB BAR never fits below 1 GB.
expect "M2 Air, 8 GB Mac, 4 GB VM: 1 GB"    1024 "$(mem 'vulkan 26 1 1 0 8 4 36 0')"
expect "  ... in a 16 GB PCI window"        16   "$(win 'vulkan 26 1 1 0 8 4 36 0')"
expect "M2, 128 GB Mac, 16 GB VM: 8 GB (half of 16)" 8192 "$(mem 'vulkan 26 1 1 0 128 16 36 0')"
expect "M2, 128 GB Mac, 48 GB VM: 8 GB window" 8   "$(win 'vulkan 26 1 1 0 128 48 36 0')"
expect "  ... 4 GB host memory"             4096 "$(mem 'vulkan 26 1 1 0 128 48 36 0')"
expect "M2, 96 GB Mac, 60 GB VM: 1 GB window, 512 MB" 512 "$(mem 'vulkan 26 1 1 0 96 60 36 0')"
expect "M2, 128 GB Mac, 62 GB VM: no window fits, 256 MB" 256 "$(mem 'vulkan 26 1 1 0 128 62 36 0')"
expect "  ... and no window asked for"      -    "$(win 'vulkan 26 1 1 0 128 62 36 0')"
expect "M4: QEMU's own window"              -    "$(win 'vulkan 26 1 1 0 8 4 42 0')"
expect "OpenGL: no window asked for"        -    "$(win 'opengl 26 1 1 0 8 4 36 0')"
expect "M2: Vulkan stays on"                vulkan "$(line 'vulkan 26 1 1 0 8 4 36 0')"
# A Vulkan start that showed nothing: OpenGL from then on, and it says so.
expect "fallback: OpenGL"                   opengl "$(line 'vulkan 26 1 1 0 8 4 36 1')"
expect "  ... and says so" "Vulkan did not start on this Mac: using OpenGL (the firmware found no devices; choose Vulkan again to try once more)" "$(summ 'vulkan 26 1 1 0 8 4 36 1')"
expect "fallback: the vulkan feature too"   opengl "$(line 'opengl 27 1 1 1 16 8 42 1')"
expect "fallback: OpenGL VM unchanged"      "OpenGL" "$(summ 'opengl 27 1 1 0 16 8 42 1')"
expect "fallback waits behind the driver"   "Vulkan (driver not built yet: runs on OpenGL until the next apply)" "$(summ 'vulkan 27 1 0 0 16 8 42 1')"

# The start watch (VenusStartWatch): the Air hang falls back in 25 s, a normal
# start never does, the Mac's sleep does not count.
"$T/graphics" watch > "$T/watch.txt"
wv() { grep "^$1 " "$T/watch.txt" | cut -d' ' -f2-; }
expect "watch: the Air hang -> OpenGL at once" "fallback now the firmware found no devices in 25 s: no boot disk, no picture" "$(wv air-hang)"
expect "watch: a normal start is fine"          fine "$(wv normal)"
expect "watch: firmware at 24 s is no hang"     wait "$(wv normal-24s)"
expect "watch: paused does not count"           wait "$(wv paused)"
expect "watch: QEMU silent 30 s -> OpenGL"      "fallback now QEMU stopped answering for 30 s while Vulkan started" "$(wv silent)"
expect "watch: QEMU silent 15 s is no hang"     wait "$(wv silent-short)"
expect "watch: QMP never reachable, console ok: no fallback" wait "$(wv no-qmp-console)"
expect "watch: QMP never reachable, no console: firmware rule" "fallback now the firmware found no devices in 25 s: no boot disk, no picture" "$(wv no-qmp-nothing)"
expect "watch: no picture after the firmware -> shut down first" "fallback graceful no picture from the VM after 90 s" "$(wv no-picture)"
expect "watch: console output counts as firmware" wait "$(wv console-only)"
expect "watch: the Mac's wake resets the silence" wait "$(wv woke)"
expect "watch: info pci mapped / not mapped"    "true false" "$(wv pci-mapped)"
expect "watch: hostmem by address bits"         "1024 1024 1024 256 MB 4 GB" "$(wv bits)"
expect "qemu.log line on the Air" "vulkan -> vulkan (chosen, KosmicKrisp), host memory window 1 GB, PCI window 16 GB" "$(wv record)"
# The fallback file: the app and omacvm read it the same way; a choice made by hand removes it.
fd=$T/fb; mkdir -p "$fd"; echo vulkan > "$fd/graphics"
expect "fallback: none (app)" - "$("$T/graphics" fallback "$fd")"
graphics_fallback "$fd" >/dev/null; expect "fallback: none (omacvm)" 1 "$?"
echo "the firmware found no devices in 25 s" > "$fd/graphics-fallback"
expect "fallback: why (app)"    "the firmware found no devices in 25 s" "$("$T/graphics" fallback "$fd")"
expect "fallback: why (omacvm)" "the firmware found no devices in 25 s" "$(graphics_fallback "$fd")"
"$T/graphics" write vulkan "$fd"
expect "fallback: choosing again removes it (app)" no "$([[ -e $fd/graphics-fallback ]] && echo yes || echo no)"
expect "fallback text: same" "$("$T/graphics" didnotstart)" "$GRAPHICS_DID_NOT_START"
s_bits=$(sed -n 's/.*static let highPCIWindowBits = \([0-9]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
s_low=$(sed -n 's/.*static let lowWindowHostmemMB = \([0-9]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "high PCI window bits: same" "$s_bits" "$GRAPHICS_HIGH_PCI_WINDOW_BITS"
expect "low window hostmem: same" "$s_low" "$GRAPHICS_LOW_WINDOW_HOSTMEM_MB"
s_win=$(sed -n 's/.*static let smallHighWindowMaxGB = \([0-9]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "small high window: same" "$s_win" "$GRAPHICS_SMALL_HIGH_WINDOW_MAX_GB"

# The hidden venus switch of 2.9 (moved once): a VM without its own choice
# gets Vulkan, one set to OpenGL keeps it; omacvm reads the switch the same way
# until the app has moved it.
m=$T/m; mkdir -p "$m/a" "$m/b" "$m/c"; echo opengl > "$m/b/graphics"; echo auto > "$m/c/graphics"
"$T/graphics" migrate "$m/a" "$m/b" "$m/c" > "$T/migrate.txt"
expect "switch: VM without a choice -> vulkan (app)" vulkan "$(cat "$m/a/graphics")"
expect "switch: VM on OpenGL keeps it (app)" opengl "$(cat "$m/b/graphics")"
expect "switch: VM on Automatic -> vulkan (app)" vulkan "$(cat "$m/c/graphics")"
expect "switch: logged per VM" 2 "$(grep -c 'hidden venus switch was on' "$T/migrate.txt")"
rm -f "$m/a/graphics" "$m/c/graphics"
expect "switch on: no file -> vulkan (omacvm)" vulkan "$(OMACVM_TEST_VENUS_SWITCH=1 graphics_choice "$m/a")"
expect "switch on: OpenGL stays (omacvm)" opengl "$(OMACVM_TEST_VENUS_SWITCH=1 graphics_choice "$m/b")"
expect "switch off: no file -> auto (omacvm)" auto "$(OMACVM_TEST_VENUS_SWITCH=0 graphics_choice "$m/a")"
grep -q 'Settings.migrateVenusSwitch()' "$R/app/app/Sources/OmacVM/main.swift" && ! grep -q 'Settings.venus' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  ok "the app moves the switch at launch and no longer reads it at start" || bad "the app still reads the hidden venus switch"

# The file: missing or unknown means Automatic, in both.
d=$T/f; mkdir -p "$d"
expect "no file: auto (app)"     auto "$("$T/graphics" file "$d")"
expect "no file: auto (omacvm)"  auto "$(graphics_choice "$d")"
printf 'metal\n' > "$d/graphics"
expect "unknown value: auto (app)"    auto "$("$T/graphics" file "$d")"
expect "unknown value: auto (omacvm)" auto "$(graphics_choice "$d")"
printf ' vulkan \n' > "$d/graphics"
expect "spaces around: vulkan (app)"    vulkan "$("$T/graphics" file "$d")"
expect "spaces around: vulkan (omacvm)" vulkan "$(graphics_choice "$d")"

# The constants are the same in both.
s_auto=$(sed -n 's/.*static let autoVulkan = \([a-z]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "Automatic gives Vulkan at all: same" "$([[ $s_auto == true ]] && echo 1 || echo 0)" "$GRAPHICS_AUTO_VULKAN"
expect "3.0.0: Automatic is OpenGL on every Mac" 0 "$GRAPHICS_AUTO_VULKAN"
expect "waiting-for-driver text: same" "$("$T/graphics" waiting)" "$GRAPHICS_WAITING_FOR_DRIVER"
s_from=$(sed -n 's/.*static let autoVulkanFromMacOS = \([0-9]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
s_mvk=$(sed -n 's/.*static let autoVulkanOnMoltenVK = \([a-z]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "Automatic from macOS: same" "$s_from" "$GRAPHICS_AUTO_VULKAN_FROM_MACOS"
expect "Automatic on MoltenVK: same" "$([[ $s_mvk == true ]] && echo 1 || echo 0)" "$GRAPHICS_AUTO_VULKAN_ON_MOLTENVK"

# omacvm graphics on a stopped VM, in a throwaway HOME and settings domain
# (no real VM, app or setting).
H=$T/home; mkdir -p "$H/OmacVM/Test VM/logs"
printf "NAME='Test VM'\nSSH_PORT=52999\n" > "$H/OmacVM/Test VM/vm.env"
export OMACVM_APP_ID=org.omacvm.test.graphics-setting.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T"' EXIT
cli() { HOME=$H OMACVM_TEST_MACOS_MAJOR=${MAJ:-15} OMACVM_TEST_KOSMICKRISP=${KK:-0} OMACVM_TEST_VENUS_SWITCH=0 \
          "$R/src/cmd/graphics.sh" --vm "Test VM" "$@"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }
expect "omacvm graphics: a VM that never started" auto "$(cli --json | j graphics)"
expect "omacvm graphics: set vulkan" True "$(cli vulkan --json | j changed)"
expect "omacvm graphics: written" vulkan "$(cat "$H/OmacVM/Test VM/graphics")"
expect "omacvm graphics: vulkan without the driver: OpenGL next start" opengl "$(cli --json | j next_start)"
expect "omacvm graphics: ... waiting for the driver" True "$(cli --json | j waiting_for_driver)"
expect "omacvm graphics: ... and says so" "Vulkan (driver not built yet: runs on OpenGL until the next apply)" "$(cli --json | j summary)"
: > "$H/OmacVM/Test VM/venus-ready"
expect "omacvm graphics: vulkan with the driver" vulkan "$(cli --json | j next_start)"
expect "omacvm graphics: auto on macOS 27 + KK with the driver: OpenGL (3.0.0)" opengl "$(cli auto --json >/dev/null; MAJ=27 KK=1 cli --json | j next_start)"
echo "OmacVM: graphics: auto -> vulkan (macOS 27, KosmicKrisp), host memory window 4 GB" > "$H/OmacVM/Test VM/logs/qemu.log"
expect "omacvm graphics: the last start" "auto -> vulkan (macOS 27, KosmicKrisp), host memory window 4 GB" "$(MAJ=27 KK=1 cli --json | j this_start)"
echo "QEMU stopped answering for 30 s while Vulkan started" > "$H/OmacVM/Test VM/graphics-fallback"
cli vulkan >/dev/null
expect "omacvm graphics: vulkan after a fallback" vulkan "$(cli --json | j next_start)"
expect "omacvm graphics: ... after a fallback (removed by the choice)" no "$([[ -e "$H/OmacVM/Test VM/graphics-fallback" ]] && echo yes || echo no)"
grep -q 'watchVenusStart()' "$R/app/app/Sources/OmacVM/Runner.swift" && grep -q 'r?.venusFallback' "$R/app/app/Sources/OmacVM/main.swift" &&
  ok "the app watches Vulkan starts and starts again on OpenGL" || bad "no Vulkan start watch in the app"
cli metal >/dev/null 2>&1; expect "omacvm graphics: unknown value refused" 2 "$?"
cli --vm-type utm >/dev/null 2>&1; expect "omacvm graphics: app VMs only" 2 "$?"

# Wired in: the app uses the plan for QEMU's Venus options; apply passes it to the VM.
grep -q 'g.venus ? ",blob=true,venus=true,hostmem=\\(g.hostmemMB)M"' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  ok "Runner's Venus options come from the plan" || bad "Runner.swift does not use the plan"
grep -q '"virt,gic-version=3" + (g.highWindowGB.map { ",highmem-mmio-size=\\($0)G" }' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  ok "Runner asks for the small PCI window from the plan" || bad "Runner.swift does not pass highmem-mmio-size"
grep -q ' qemu-virt-small-high-window.patch$' "$R/app/runtime/patches/SHA256SUMS" &&
  grep -q 'patches/qemu-virt-small-high-window.patch"' "$R/app/runtime/build-qemu-gpu-runtime.sh" &&
  ok "the runtime takes a small highmem-mmio-size (patch pinned and applied)" || bad "small high window patch not in the runtime build"
grep -q 'GI_ARGS+=" --graphics $GRAPHICS"' "$R/src/cmd/apply.sh" && ok "apply passes --graphics" || bad "apply.sh: no --graphics"
grep -q 'vulkan-virtio.sh --ready' "$R/src/cmd/apply.sh" && ok "apply writes venus-ready from the VM" || bad "apply.sh: no venus-ready"
# Vulkan windows on the GPU (omacvm.vkwindows): MoltenVK yes, KosmicKrisp not yet (untested there).
mkdir -p "$T/vkw"
cat > "$T/vkw/main.swift" <<'EOF2'
let cases: [(Int, Bool, String?)] = [(15, false, nil), (15, true, nil), (26, false, nil), (26, true, nil),
                                     (27, true, "moltenvk"), (15, true, "kosmickrisp")]
for (m, k, d) in cases {
    print("\(m) \(k) \(d ?? "-") \(Graphics.vulkanWindowsOnGPU(macOSMajor: m, kosmicKrisp: k, driver: d))")
}
EOF2
swiftc -O -o "$T/vkw/run" "$R/app/app/Sources/OmacVM/Graphics.swift" "$T/vkw/main.swift" &&
  expect "Vulkan windows on the GPU: MoltenVK only" \
    "15 false - true|15 true - true|26 false - true|26 true - false|27 true moltenvk true|15 true kosmickrisp false" \
    "$("$T/vkw/run" | paste -sd'|' -)" || bad "vulkanWindowsOnGPU does not build"

exit $fail
