# Sourced by the tests that build OmacVM.app's SwiftUI sources with swiftc (app-settings.sh,
# app-mouse-swipe.sh, app-storage-ui.sh). SwiftUI's @State and its other macros need the macro
# plugins of an Xcode macOS platform; the Command Line Tools have none, so a CLT swiftc fails
# with "plugin for module 'SwiftUIMacros' not found" (the 3.4.4 suites, 23:47).
# swift_toolchain [MODULE_CACHE]: one @State typechecked with the swiftc these tests call (in
# their module cache, so the build after it starts warm). When that fails,
# Xcode's (DEVELOPER_DIR, else xcode-select's, else /Applications/Xcode.app, as the release
# build), and swiftc becomes a function that runs xcrun's. Says which toolchain it took; returns 1
# with the reason when nothing here expands the macros.
swift_toolchain() {
  local d p r s mc=()
  s=$(type -P swiftc)
  p=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-swift-probe.XXXXXX")
  [[ -n ${1:-} ]] && mc=(-module-cache-path "$1")
  printf 'import SwiftUI\nstruct P: View { @State var n = 0; var body: some View { Text("") } }\n' > "$p/p.swift"
  if swiftc -typecheck ${mc[@]+"${mc[@]}"} "$p/p.swift" > "$p/log" 2>&1; then
    echo "swift toolchain: $s (DEVELOPER_DIR ${DEVELOPER_DIR:-not set}, xcode-select $(xcode-select -p 2>/dev/null))"
    rm -rf "$p"; return 0
  fi
  r=$(grep -m1 -o 'error: .*' "$p/log")
  for d in "${DEVELOPER_DIR:-}" "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer; do
    [[ -n $d && -d $d/Platforms/MacOSX.platform ]] || continue
    if env -u SDKROOT DEVELOPER_DIR="$d" xcrun swiftc -typecheck ${mc[@]+"${mc[@]}"} "$p/p.swift" > /dev/null 2>&1; then
      export DEVELOPER_DIR=$d; unset SDKROOT
      swiftc() { xcrun swiftc "$@"; }
      echo "swift toolchain: Xcode's, $d ($s cannot expand SwiftUI's macros: ${r:-no error line})"
      rm -rf "$p"; return 0
    fi
  done
  rm -rf "$p"
  echo "FAIL no Swift toolchain here expands SwiftUI's macros ($s: ${r:-no error line}); install Xcode or set DEVELOPER_DIR to one"
  return 1
}
