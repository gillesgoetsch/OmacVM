#!/bin/bash
# The release script's offline parts: KosmicKrisp from another Mac
# (app/runtime/import-kosmickrisp.sh) is taken only with a matching stamp and
# a system-only dylib; release.sh and appcast.sh refuse bad arguments;
# sign-app.sh signs every part of an app (ad hoc here).
# No key, no network, nothing outside a temp folder.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
expect() {   # WANT(0|1) NAME CMD...: 0 = must pass, 1 = must be refused
  local want=$1 name=$2; shift 2
  if "$@" > "$T/out" 2>&1; then [[ $want == 0 ]] && ok "$name" || { bad "$name (passed)"; cat "$T/out"; }
  else [[ $want == 1 ]] && ok "$name" || { bad "$name (refused)"; cat "$T/out"; }; fi
}

# A copy of the runtime folder's two scripts: the import writes next to them.
rt=$T/runtime; mkdir -p "$rt"
cp "$R/app/runtime/import-kosmickrisp.sh" "$R/app/runtime/build-kosmickrisp.sh" "$rt/"
commit=$(sed -n 's/^mesa_commit=//p' "$rt/build-kosmickrisp.sh")
script=$(shasum -a 256 "$rt/build-kosmickrisp.sh" | cut -d' ' -f1)
kk() {   # DIR: a fake KosmicKrisp build (a tiny arm64 dylib on the system only)
  mkdir -p "$1"
  echo 'int vk_icdGetInstanceProcAddr(void) { return 0; }' > "$T/kk.c"
  cc -arch arm64 -dynamiclib -install_name @rpath/libvulkan_kosmickrisp.dylib -o "$1/libvulkan_kosmickrisp.dylib" "$T/kk.c" ${2:-}
  printf '{\n    "ICD": {\n        "api_version": "1.4.363",\n        "library_path": "../../../lib/libvulkan_kosmickrisp.dylib"\n    },\n    "file_format_version": "1.0.1"\n}\n' > "$1/kosmickrisp_mesa_icd.json"
  echo "Mesa licences" > "$1/LICENSE.mesa-kosmickrisp.txt"
  echo "$commit $script llvm-23.1.2 spirv-llvm-translator-23.1.0.0" > "$1/stamp"
}
if command -v cc >/dev/null; then
  kk "$T/good"
  expect 0 "import: a matching build gives its stamp" "$rt/import-kosmickrisp.sh" "$T/good" --stamp
  [[ $("$rt/import-kosmickrisp.sh" "$T/good" --stamp) == "$(cat "$T/good/stamp")" ]] && ok "import: the stamp is the build's" || bad "import: stamp"
  expect 0 "import: copies the build" "$rt/import-kosmickrisp.sh" "$T/good"
  cmp -s "$T/good/libvulkan_kosmickrisp.dylib" "$rt/.build/kosmickrisp/libvulkan_kosmickrisp.dylib" && ok "import: dylib in .build/kosmickrisp" || bad "import: dylib not copied"
  cp -R "$T/good" "$T/mesa"; sed -i '' "s/^$commit/0000000000000000000000000000000000000000/" "$T/mesa/stamp"
  expect 1 "import: another Mesa commit is refused" "$rt/import-kosmickrisp.sh" "$T/mesa" --stamp
  cp -R "$T/good" "$T/script"; sed -i '' "s/ $script / $(printf '%064d' 0) /" "$T/script/stamp"
  expect 1 "import: another build script is refused" "$rt/import-kosmickrisp.sh" "$T/script" --stamp
  # The Mesa patches: a build without the checkout's patches, and one with them.
  mkdir -p "$rt/patches"; echo "--- a/x" > "$rt/patches/mesa-kosmickrisp-test.patch"
  expect 1 "import: a build without the checkout's Mesa patches is refused" "$rt/import-kosmickrisp.sh" "$T/good" --stamp
  cp -R "$T/good" "$T/patched"
  echo "$(cat "$T/good/stamp") patches-$(shasum -a 256 "$rt/patches/mesa-kosmickrisp-test.patch" | cut -c1-16)" > "$T/patched/stamp"
  expect 0 "import: a build with the same Mesa patches is taken" "$rt/import-kosmickrisp.sh" "$T/patched" --stamp
  rm -r "$rt/patches"
  expect 1 "import: a patched build for an unpatched checkout is refused" "$rt/import-kosmickrisp.sh" "$T/patched" --stamp
  cp -R "$T/good" "$T/noicd"; rm "$T/noicd/kosmickrisp_mesa_icd.json"
  expect 1 "import: a build without its ICD file is refused" "$rt/import-kosmickrisp.sh" "$T/noicd" --stamp
  cp -R "$T/good" "$T/nolic"; : > "$T/nolic/LICENSE.mesa-kosmickrisp.txt"
  expect 1 "import: an empty licence notice is refused" "$rt/import-kosmickrisp.sh" "$T/nolic" --stamp
  # A dylib that links a library outside the system.
  echo 'int other(void) { return 1; }' > "$T/o.c"
  cc -arch arm64 -dynamiclib -install_name "$T/libother.dylib" -o "$T/libother.dylib" "$T/o.c"
  kk "$T/linked" "-L$T -lother"
  expect 1 "import: a dylib linking outside the system is refused" "$rt/import-kosmickrisp.sh" "$T/linked" --stamp
  cp -R "$T/good" "$T/x86"; cc -arch x86_64 -dynamiclib -o "$T/x86/libvulkan_kosmickrisp.dylib" "$T/kk.c" 2>/dev/null &&
    expect 1 "import: an x86_64 dylib is refused" "$rt/import-kosmickrisp.sh" "$T/x86" --stamp
else
  echo "skip the import checks (no cc)"
fi

# release.sh: usage and bad input, before anything is touched.
expect 1 "release.sh: no version prints the usage" "$R/src/release/release.sh"
[[ $("$R/src/release/release.sh" 2>&1) == *--dry-run* ]] && ok "release.sh: usage names --dry-run" || bad "release.sh: usage"
expect 1 "release.sh: not a version" "$R/src/release/release.sh" --dry-run 3.0 check
OMACVM_RELEASE_OUT=$T/out expect 1 "release.sh: an unknown step" "$R/src/release/release.sh" --dry-run 9.9.9 nonsense
expect 1 "release.sh: an unknown option" "$R/src/release/release.sh" --force 9.9.9 check
# The e2e gate (step e2e, checked again by publish): a passing result for M only.
G=$T/gate; mkdir -p "$G/release/e2e"; echo "M=1111111111111111111111111111111111111111" > "$G/release/state"
gate() {   # PASS COMMIT ONLY: a result.json as cc-switches.sh writes it
  printf '{"kind": "omacvm-e2e-cc-switches", "commit": "%s", "version": "9.9.9", "only": "%s", "pass": %s, "counts": {"ok": 40, "FAIL": 0, "BLOCKED": 0, "skip": 2}, "not_ok": [], "seconds": 3600}\n' \
    "$2" "$3" "$1" > "$G/release/e2e/result.json"
}
rel() { OMACVM_RELEASE_OUT=$G "$R/src/release/release.sh" 9.9.9 "$@"; }
expect 1 "e2e: no result is refused" rel e2e
expect 1 "publish: refused while the gate has not passed" rel publish
[[ $(rel publish 2>&1) == *"e2e gate has not passed"* ]] && ok "publish: says why" || bad "publish: no reason given"
gate true 2222222222222222222222222222222222222222 all
expect 1 "e2e: a result for another commit is refused" rel e2e
gate false 1111111111111111111111111111111111111111 all
expect 1 "e2e: a result that did not pass is refused" rel e2e
gate true 1111111111111111111111111111111111111111 ",switches,"
expect 1 "e2e: a run of some steps only is refused" rel e2e
gate true 1111111111111111111111111111111111111111 all
expect 0 "e2e: a passing result for M is taken" rel e2e
[[ $(sed -n 's/^E2E=//p' "$G/release/state" | tail -1) == pass ]] && ok "e2e: the state says pass" || bad "e2e: state"
echo "M=3333333333333333333333333333333333333333" >> "$G/release/state"
[[ $(rel publish 2>&1) == *"e2e gate has not passed"* ]] && ok "publish: a pass for an earlier M does not count" || bad "publish: took a pass for an earlier M"
echo "M=1111111111111111111111111111111111111111" >> "$G/release/state"
rm "$G/release/e2e/result.json"; echo "E2E=" >> "$G/release/state"
OMACVM_RELEASE_E2E_OVERRIDE=short expect 1 "e2e: an override without a reason is refused" rel e2e
OMACVM_RELEASE_E2E_OVERRIDE="the test Mac is away; checked by hand on the Air" expect 0 "e2e: an override with a reason" rel e2e
grep -q "checked by hand on the Air" "$G/release/e2e-override.log" && ok "e2e: the override is logged" || bad "e2e: override not logged"
[[ $(sed -n 's/^E2E=//p' "$G/release/state" | tail -1) == override ]] && ok "e2e: the state says override" || bad "e2e: override state"

# OMACVM_RELEASE_APP_FROM (an app built at M on another Mac): an absolute path
# only, refused before any step runs.
gate true 1111111111111111111111111111111111111111 all
OMACVM_RELEASE_APP_FROM=m1/release expect 1 "app from: a relative path is refused" rel e2e
[[ $(OMACVM_RELEASE_APP_FROM=m1/release rel e2e 2>&1) == *"absolute path"* ]] && ok "app from: says it wants an absolute path" || bad "app from: no reason given"
OMACVM_RELEASE_APP_FROM=$T/m1/release expect 0 "app from: an absolute path is taken" rel e2e

# sign-app.sh (build-app.sh's signing, also release.sh's for an app built
# elsewhere): its arguments, and an ad hoc signing of a stand-in app with every
# part the real one has (tiny arm64 programs), which then verifies.
SA=$R/app/scripts/sign-app.sh
expect 1 "sign-app.sh: no arguments" "$SA"
expect 1 "sign-app.sh: not an app" "$SA" "$T" org.omacvm.test.signapp
if command -v cc >/dev/null; then
  A=$T/sa/Stand-in.app; C=$A/Contents
  echo 'int main(void) { return 0; }' > "$T/m.c"; cc -arch arm64 -o "$T/m" "$T/m.c"
  echo 'int f(void) { return 0; }' > "$T/l.c"; cc -arch arm64 -dynamiclib -o "$T/l.dylib" "$T/l.c"
  bundle() {   # DIR ID EXE TYPE: a bundle with its program and Info.plist
    mkdir -p "$1/Contents/MacOS"; cp "$T/m" "$1/Contents/MacOS/$3"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string></dict></plist>\n' "$2" "$3" "$4" > "$1/Contents/Info.plist"
  }
  bundle "$A" org.omacvm.test.signapp OmacVM APPL
  mkdir -p "$C/Resources/runtime/lib" "$C/Resources/runtime/bin" "$C/Resources/tools" "$C/Resources/python/bin" "$C/Library/LaunchServices" "$C/Helpers" "$C/PlugIns"
  cp "$T/l.dylib" "$C/Resources/runtime/lib/libstand-in.dylib"
  for f in runtime/bin/zstd runtime/bin/OmacVM tools/mac-notch python/bin/python3.13; do cp "$T/m" "$C/Resources/$f"; done
  cp "$T/m" "$C/Library/LaunchServices/org.omacvm.netd"
  for h in "OmacVM Test Bridge:org.omacvm.test.bridge" "OmacVM Test Gestures:org.omacvm.test.gestures" "Omanotch:ch.gillesgoetsch.omanotch"; do
    bundle "$C/Helpers/${h%%:*}.app" "${h#*:}" helper APPL; codesign --force --sign - "$C/Helpers/${h%%:*}.app" 2>/dev/null
  done
  bundle "$C/PlugIns/OmacVMDockTile.docktileplugin" org.omacvm.test.signapp.docktile OmacVMDockTile BNDL
  expect 0 "sign-app.sh: ad hoc, every part, verifies" env -u OMACVM_SIGN_ID "$SA" "$A" org.omacvm.test.signapp --test-identity
  [[ $(codesign -dv "$C/Resources/runtime/bin/OmacVM" 2>&1) == *"Identifier=org.omacvm.test.signapp.qemu"* ]] && ok "sign-app.sh: QEMU's identifier follows the id" || bad "sign-app.sh: QEMU identifier"
  [[ $(codesign -dv "$A" 2>&1) == *"Identifier=org.omacvm.test.signapp"* ]] && ok "sign-app.sh: the app's identifier is the given id" || bad "sign-app.sh: app identifier"
  expect 1 "sign-app.sh: without --test-identity the release helpers' names are wanted" env OMACVM_SIGN_ID=- "$SA" "$A" org.omacvm.test.signapp
else
  echo "skip the sign-app.sh stand-in (no cc)"
fi

# make-image.sh app (release.sh's image step) makes and starts the image VM
# with this checkout's app/scripts and runtime build, or, with
# OMACVM_PREBUILT_APP, with that app's own scripts and runtime (an app built on
# another Mac leaves no runtime build in the checkout). Run from a copy of the
# parts it reads, with stand-in scripts that only say which one ran: no VM, no
# download.
MI=$T/mi; IA=$T/mi-app/OmacVM.app; mkdir -p "$MI/src" "$MI/app/scripts" "$IA/Contents/Resources/scripts" "$IA/Contents/Resources/runtime/bin"
cp -R "$R/src/lib" "$R/src/vm" "$R/src/prebuilt" "$R/src/VERSION" "$MI/src/"
standin() {   # DIR WHO: create-vm.sh and vm-common.sh that write WHO and stop
  printf '#!/bin/bash\necho "%s create $1" > "%s"\nexit 1\n' "$2" "$MI/ran" > "$1/create-vm.sh"; chmod +x "$1/create-vm.sh"
  printf 'vm_load() { echo "%s boot $1" > "%s"; exit 1; }\n' "$2" "$MI/ran" > "$1/vm-common.sh"
}
standin "$MI/app/scripts" checkout; standin "$IA/Contents/Resources/scripts" app
printf '#!/bin/sh\n' > "$IA/Contents/Resources/runtime/bin/OmacVM"; chmod +x "$IA/Contents/Resources/runtime/bin/OmacVM"
plist_version() {   # VERSION: the stand-in app's Info.plist
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.omacvm.app</string><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' "$1" > "$IA/Contents/Info.plist"
}
plist_version "$(cat "$R/src/VERSION")"
mimg() { rm -f "$MI/ran"; HOME=$T/mi-home OMACVM_PREBUILT_OUT=$T/mi-out "$MI/src/prebuilt/make-image.sh" app "$@" > "$T/mi.out" 2>&1; cat "$MI/ran" 2>/dev/null; }
VMD=$T/mi-out/app/vm
[[ $(mimg build) == "" ]] && ok "make-image: no runtime build and no app: nothing runs" || bad "make-image: ran without a runtime"
[[ $(OMACVM_PREBUILT_APP=$IA mimg build) == "app create $VMD" ]] && ok "make-image: OMACVM_PREBUILT_APP: the app's create script makes the VM" || { bad "make-image: the app's create script did not run"; cat "$T/mi.out"; }
rm -rf "$VMD"; mkdir -p "$VMD"
[[ $(OMACVM_PREBUILT_APP=$IA mimg generalize) == "app boot $VMD" ]] && ok "make-image: OMACVM_PREBUILT_APP: the app's scripts start the VM" || { bad "make-image: the app's scripts did not start the VM"; cat "$T/mi.out"; }
rm -rf "$VMD"
mkdir -p "$MI/app/runtime/.build/qemu-gpu-runtime/bin"; printf '#!/bin/sh\n' > "$MI/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
chmod +x "$MI/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
[[ $(OMACVM_PREBUILT_APP=$IA mimg build) == "app create $VMD" ]] && ok "make-image: OMACVM_PREBUILT_APP wins over a runtime build in the checkout" || bad "make-image: took the checkout's runtime over OMACVM_PREBUILT_APP"
rm -rf "$VMD"
[[ $(mimg build) == "checkout create $VMD" ]] && ok "make-image: without it, the checkout's scripts and runtime build" || bad "make-image: the checkout's scripts did not run"
rm -rf "$VMD"
[[ $(OMACVM_PREBUILT_APP=mi-app/OmacVM.app mimg build) == "" && $(cat "$T/mi.out") == *"absolute path"* ]] && ok "make-image: a relative OMACVM_PREBUILT_APP is refused" || bad "make-image: took a relative OMACVM_PREBUILT_APP"
plist_version 0.0.1
[[ $(OMACVM_PREBUILT_APP=$IA mimg build) == "" && $(cat "$T/mi.out") == *"0.0.1"* ]] && ok "make-image: an app of another version is refused" || bad "make-image: took an app of another version"
rm -rf "$VMD"

# appcast.sh ZIP: only an OmacVM-<version>.zip.
touch "$T/Other.zip"
expect 1 "appcast.sh: a zip with another name is refused" "$R/app/scripts/appcast.sh" "$T/Other.zip"

(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
