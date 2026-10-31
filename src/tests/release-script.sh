#!/bin/bash
# The release script's offline parts: KosmicKrisp from another Mac
# (app/runtime/import-kosmickrisp.sh) is taken only with a matching stamp and
# a system-only dylib; release.sh and appcast.sh refuse bad arguments; an app
# built on another Mac (OMACVM_RELEASE_APP_FROM) is checked against M before
# anything signs it; sign-app.sh signs every part of an app (ad hoc here).
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
OMACVM_RELEASE_APP_FROM=$T/m1/release OMACVM_RELEASE_RUNTIME_FROM=$T/runtime expect 1 "app from: a runtime from elsewhere beside it is refused" rel e2e
# Step image after an app from another Mac (APP_FROM in the state, from step
# build): the image VM runs on the app's own runtime (make-image.sh with
# OMACVM_PREBUILT_APP), also when a runtime build sits in the worktree; after a
# build here, on the worktree's runtime build. A stand-in make-image.sh in the
# worktree says what it was given.
H=$T/home; W=$H/omacvm-rel-9.9.9-build
mkdir -p "$W/src/prebuilt" "$W/app/dist/OmacVM.app/Contents/Resources/runtime/bin"
printf '#!/bin/bash\necho "app=${OMACVM_PREBUILT_APP:-none} $*" > "%s"\nexit 1\n' "$T/img-ran" > "$W/src/prebuilt/make-image.sh"
printf '#!/bin/sh\n' > "$W/app/dist/OmacVM.app/Contents/Resources/runtime/bin/OmacVM"
chmod +x "$W/src/prebuilt/make-image.sh" "$W/app/dist/OmacVM.app/Contents/Resources/runtime/bin/OmacVM"
img() { rm -f "$T/img-ran"; HOME=$H OMACVM_RELEASE_OUT=$G "$R/src/release/release.sh" 9.9.9 image > "$T/img.out" 2>&1; cat "$T/img-ran" 2>/dev/null; }
echo "APP_FROM=$T/m1/release" >> "$G/release/state"
[[ $(img) == "app=$W/app/dist/OmacVM.app app build generalize package clean" ]] && ok "image: an app from another Mac makes the image on its own runtime" || { bad "image: not on the app's runtime"; cat "$T/img.out"; }
mkdir -p "$W/app/runtime/.build/qemu-gpu-runtime/bin"; printf '#!/bin/sh\n' > "$W/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
chmod +x "$W/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
[[ $(img) == "app=$W/app/dist/OmacVM.app app build generalize package clean" ]] && ok "image: the app's runtime, not a runtime build left in the worktree" || bad "image: took the worktree's runtime build for an app from another Mac"
echo "APP_FROM=" >> "$G/release/state"
[[ $(img) == "app=none app build generalize package clean" ]] && ok "image: after a build here, the worktree's runtime build" || bad "image: a build here does not use the worktree's runtime"

# Step build with OMACVM_RELEASE_APP_FROM: an app put together at M on another
# Mac is checked before anything signs it. A stand-in worktree (a git repo, its
# HEAD is M; its app/scripts/sign-app.sh only leaves a mark) and a stand-in app
# made the way build-app.sh makes one (what it copies from git is read from its
# own lines: the archive paths, the scripts). Each bad app must be refused for
# its own reason before sign-app.sh runs; a matching one reaches it (then
# codesign --verify stops step build: nothing is signed here).
umask 022
BA=$R/app/scripts/build-app.sh
# build-app.sh's lines, read as text ($ROOT and $REPO stay literal).
# shellcheck disable=SC2016
read -r -a SCR <<< "$(awk '/install -m755 "\$ROOT\/scripts\// { f = 1 } f { print; if (!/\\$/) exit }' "$BA" | grep -o '\$ROOT/scripts/[^"]*' | sed 's|.*/||' | tr '\n' ' ')"
# shellcheck disable=SC2016
read -r -a ARC <<< "$(sed -n 's/.*git -C "\$REPO" archive "\$COMMIT" \(.*\) | tar -x -C "\$C\/Resources\/omacvm".*/\1/p' "$BA")"
(( ${#SCR[@]} && ${#ARC[@]} )) && ok "app from: build-app.sh's scripts (${SCR[*]}) and archive paths (${ARC[*]}) read" ||
  bad "app from: build-app.sh's scripts or archive paths not found"
H2=$T/home2; W2=$H2/omacvm-rel-9.9.9-build; G2=$T/gate2; AF=$T/af; MARK=$T/signed
mkdir -p "$W2/src/lib" "$W2/app/scripts" "$G2/release" "$AF"
git -C "$W2" init -q
printf '#!/bin/bash\necho omacvm\n' > "$W2/omacvm"; chmod 755 "$W2/omacvm"
echo 9.9.9 > "$W2/src/VERSION"; echo 'x=1' > "$W2/src/lib/x.sh"; echo '# Changelog' > "$W2/CHANGELOG.md"
for p in ${ARC[@]+"${ARC[@]}"}; do [[ -e $W2/$p ]] || echo "$p" > "$W2/$p"; done
for s in ${SCR[@]+"${SCR[@]}"}; do printf '#!/bin/bash\necho %s\n' "$s" > "$W2/app/scripts/$s"; chmod 755 "$W2/app/scripts/$s"; done
[[ -f $W2/app/scripts/vm-common.sh ]] && chmod 644 "$W2/app/scripts/vm-common.sh"   # as in git (sourced, not run)
printf '#!/bin/bash\ntouch "%s"\n' "$MARK" > "$W2/app/scripts/sign-app.sh"; chmod 755 "$W2/app/scripts/sign-app.sh"
echo /dist/ > "$W2/app/.gitignore"
git -C "$W2" add -A && git -C "$W2" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m M
M2=$(git -C "$W2" rev-parse HEAD); echo "M=$M2" > "$G2/release/state"
goodapp() {   # DIR: DIR/OmacVM.app and DIR/build.log as build-app.sh --release leaves them at M
  local c=$1/OmacVM.app/Contents s
  mkdir -p "$c/MacOS" "$c/Resources/omacvm" "$c/Resources/scripts" "$c/Resources/runtime/bin" "$c/Resources/runtime/lib" \
    "$c/Resources/firmware" "$c/Resources/licenses" "$c/Resources/python/bin" "$c/Resources/tools"
  git -C "$W2" archive "$M2" ${ARC[@]+"${ARC[@]}"} | tar -x -C "$c/Resources/omacvm"
  echo "$M2" > "$c/Resources/omacvm/COMMIT"; chmod -R go-w "$c/Resources/omacvm"
  for s in ${SCR[@]+"${SCR[@]}"}; do git -C "$W2" show "$M2:app/scripts/$s" > "$c/Resources/scripts/$s"; chmod 755 "$c/Resources/scripts/$s"; done
  printf '#!/bin/sh\n' > "$c/Resources/runtime/bin/OmacVM"; chmod 755 "$c/Resources/runtime/bin/OmacVM"
  ln -s ../Resources/runtime/bin/OmacVM "$c/MacOS/OmacVM-VM"
  printf 'x' > "$c/Resources/python/bin/python3.13"; ln -s python3.13 "$c/Resources/python/bin/python3"
  printf 'x' > "$c/Resources/tools/mac-notch"
  printf 'x' > "$c/Resources/runtime/lib/libvulkan_kosmickrisp.dylib"; echo "Mesa licences" > "$c/Resources/licenses/LICENSE.mesa-kosmickrisp.txt"
  echo "omacvm edk2-stable202408-omacvm (stand-in)" > "$c/Resources/firmware/firmware-source"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.omacvm.app</string><key>CFBundleShortVersionString</key><string>9.9.9</string><key>OmacVMCommit</key><string>%s</string></dict></plist>\n' "$M2" > "$c/Info.plist"
  echo "==> built (stand-in)" > "$1/build.log"
}
goodapp "$AF/good"
mk() { rm -rf "${AF:?}/$1"; ditto "$AF/good" "$AF/$1"; }   # CASE: a copy of the matching app
afrun() {   # CASE [VAR=VALUE...]: step build with it; says whether sign-app.sh ran
  local c=$1; shift
  rm -f "$MARK"
  env "$@" HOME="$H2" OMACVM_RELEASE_OUT="$G2" OMACVM_SIGN_ID=x OMACVM_RELEASE_APP_FROM="$AF/$c" "$R/src/release/release.sh" 9.9.9 build > "$T/af.out" 2>&1
  [[ -e $MARK ]] && echo signed || echo refused
}
refused() {   # NAME CASE WHY [VAR=VALUE...]: refused before sign-app.sh, saying WHY
  local name=$1 c=$2 why=$3; shift 3
  if [[ $(afrun "$c" "$@") == refused && $(cat "$T/af.out") == *"$why"* ]]; then ok "app from: $name"
  else bad "app from: $name (not refused with \"$why\")"; cat "$T/af.out"; fi
}
taken() {   # NAME CASE [VAR=VALUE...]: reaches sign-app.sh
  local name=$1 c=$2; shift 2
  if [[ $(afrun "$c" "$@") == signed ]]; then ok "app from: $name"; else bad "app from: $name (refused)"; cat "$T/af.out"; fi
}
pl() { /usr/libexec/PlistBuddy -c "Set :$2 $3" "$AF/$1/OmacVM.app/Contents/Info.plist"; }   # CASE KEY VALUE
taken "a matching app reaches sign-app.sh" good
C1=OmacVM.app/Contents
mk commit; pl commit OmacVMCommit 1111111111111111111111111111111111111111
refused "another OmacVMCommit" commit "the app is not M"
mk version; pl version CFBundleShortVersionString 9.9.8
refused "another version" version "the app is not 9.9.9"
mk id; pl id CFBundleIdentifier org.omacvm.app.test
refused "another bundle id" id "the app is not org.omacvm.app"
mk nolog; rm "$AF/nolog/build.log"
refused "no build.log" nolog "or build.log in"
# Resources/omacvm (git archive M, COMMIT, go-w).
mk om-changed; echo more >> "$AF/om-changed/$C1/Resources/omacvm/CHANGELOG.md"
refused "omacvm: a changed file" om-changed "its omacvm is not git archive M"
mk om-extra; echo x > "$AF/om-extra/$C1/Resources/omacvm/src/extra.sh"
refused "omacvm: an extra file" om-extra "its omacvm is not git archive M"
mk om-mode; chmod 755 "$AF/om-mode/$C1/Resources/omacvm/CHANGELOG.md"
refused "omacvm: a mode change" om-mode "its omacvm is not git archive M"
mk om-link; rm "$AF/om-link/$C1/Resources/omacvm/src/lib/x.sh"; ln -s /etc/hosts "$AF/om-link/$C1/Resources/omacvm/src/lib/x.sh"
refused "omacvm: a link" om-link "its omacvm is not git archive M"

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
