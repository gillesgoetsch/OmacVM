#!/bin/bash
# A Mac without Xcode's Command Line Tools (and without Homebrew): OmacVM.app's
# route never runs one of macOS's stubs (/usr/bin/python3, swift, git, clang,
# make and the rest), each of which opens the "install the command line
# developer tools?" window. Stand-ins take the stubs' place (each writes down
# its call and fails), xcode-select finds no tools, and a made-up OmacVM.app
# carries this src/, a python3 and the Swift tools (src/lib/tools.sh). Runs
# the app's prebuilt lookup, omacvm vms and features from the app, apply's
# feature parts and src/mac/install.sh with stand-ins. No VM, no network,
# nothing installed, no LaunchAgent touched.
#   src/tests/no-clt.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d /tmp/omacvm-noclt.XXXXXX)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
# No stand-in may have run (CALLS: the file they write to).
no_calls() {   # WHAT
  if [[ -s $T/calls ]]; then echo "FAIL $1: ran macOS's stubs: $(tr '\n' ';' < "$T/calls")"; fail=1; : > "$T/calls"
  else echo "ok   $1: no stub ran"; fi
}

# Before the stand-ins: a python3 that works (for the made-up app) and the
# test release keys (they need swiftc).
REALPY=$(command -v python3) || { echo "FAIL no python3 to start from"; exit 1; }
source "$R/src/tests/release-test-keys.sh"

# macOS's stubs: the tools in /usr/bin that are hard links of one small program
# that asks to install the Command Line Tools (this list from macOS 15), and
# xcrun, which the tools must not even ask while xcode-select finds nothing.
STUBS="ar as bison c++ c89 c99 cc clang clang++ codesign_allocate cpp ctags dsymutil flex g++ gcc gcov git
gm4 gnumake gperf indent install_name_tool ld lex libtool lipo lldb m4 make mig nm nmedit objdump otool
pip3 python3 ranlib rpcgen size strings strip swift swiftc unifdef vtool yacc xcrun"
B=$T/stubs; mkdir -p "$B"
for s in $STUBS; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\necho "xcode-select: note: No developer tools were found, requesting install." >&2\nexit 1\n' "$s" "$T" > "$B/$s"
done
printf '#!/bin/bash\necho "xcode-select: error: unable to get active developer directory" >&2\nexit 2\n' > "$B/xcode-select"
printf '#!/bin/bash\nexit 1\n' > "$B/launchctl"   # nothing installed, nothing running
# The app's download for this version counts as published: the test does not ask
# GitHub (on a release branch the new version is not out yet).
printf '#!/bin/bash\ncase "$*" in *OmacVM-appcast.json.sig*) exit 0;; esac\nexec /usr/bin/curl "$@"\n' > "$B/curl"
chmod +x "$B"/*
: > "$T/calls"
NOCLT=(env "PATH=$B:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$T/home" "OMACVM_STUB_BIN=$B")
mkdir -p "$T/home"

# The made-up OmacVM.app (the layout of app/scripts/build-app.sh).
APP=$T/Apps/OmacVM.app
RES=$APP/Contents/Resources
mkdir -p "$RES/scripts" "$RES/firmware" "$RES/runtime/bin" "$RES/runtime/lib" "$RES/tools" "$RES/python/bin" \
  "$RES/omacvm" "$APP/Contents/Helpers"
# A test build's id: a release app's copy never takes the test keys (keys.py).
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.omacvm.app.test</string></dict></plist>' > "$APP/Contents/Info.plist"
cp -R "$R/src" "$RES/omacvm/src"
cp "$R/omacvm" "$RES/omacvm/omacvm"
echo test > "$RES/omacvm/COMMIT"
cp "$R/app/scripts/"*.sh "$RES/scripts/"
: > "$RES/firmware/edk2-aarch64-code.fd"
printf '#!/bin/bash\nexit 0\n' > "$RES/runtime/bin/OmacVM"; cp "$RES/runtime/bin/OmacVM" "$RES/runtime/bin/zstd"
ln -s "$REALPY" "$RES/python/bin/python3"
printf '#!/bin/bash\necho notch\n' > "$RES/tools/mac-notch"
printf '#!/bin/bash\necho "EEE d MMM  H:mm"\n' > "$RES/tools/mac-clock"
printf '#!/bin/bash\necho 500\n' > "$RES/tools/mac-free-gb"
chmod +x "$RES/runtime/bin/"* "$RES/tools/"*
IN=$RES/omacvm/src

touch "$T/start"
# Which python3 and which Swift answers: the app's.
got=$("${NOCLT[@]}" bash -c 'source "$1/lib/tools.sh"; tools_python' _ "$IN")
expect "python3: the app's" "$RES/python/bin/python3" "$got"
got=$("${NOCLT[@]}" bash -c 'source "$1/lib/mac.sh"; command -v python3; echo "$PYTHONDONTWRITEBYTECODE"' _ "$IN" | tr '\n' ' ')
expect "mac.sh: the app's python3 first on PATH, no __pycache__" "$RES/python/bin/python3 1 " "$got"
got=$("${NOCLT[@]}" bash -c 'source "$1/lib/tools.sh"; mac_tool mac-notch' _ "$IN")
expect "mac_tool: the app's mac-notch" "notch" "$got"
# A copy of the app's src/ (apply-vm.sh, the app's omacvm) finds the app by its runtime.
cp -R "$IN" "$T/copy"
got=$("${NOCLT[@]}" OMACVM_APP_RUNTIME="$RES/runtime" bash -c 'source "$1/lib/tools.sh"; tools_python; mac_tool mac-free-gb' _ "$T/copy" | tr '\n' ' ')
expect "a copy of it: the app's python3 and tools" "$RES/python/bin/python3 500 " "$got"
# A plain checkout without the tools and no app: nothing runs, no stub either.
got=$("${NOCLT[@]}" bash -c 'source "$1/lib/tools.sh"; mac_tool mac-notch; echo "status $?"' _ "$T/copy")
expect "no app, no Command Line Tools: mac_tool says no" "status 1" "$got"
no_calls "tools.sh"

# The setup screen's first question: is there a prebuilt image? (a local,
# signed manifest; prebuilt-vm.sh --lookup, as the app runs it)
VERSION=$(cat "$R/src/VERSION")
mkdir -p "$T/images"
M=$T/images/omacvm-prebuilt-$VERSION-app.json
"$REALPY" - "$M" "$VERSION" <<'PY'
import json, sys
json.dump({"format": 1, "kind": "prebuilt-manifest", "devid_teams": ["722686Y34B"], "route": "app",
           "omacvm": sys.argv[2], "omarchy": "4.0.3", "bundle": "Omarchy", "unpacked_kb": 7000000,
           "disk_gb": 64, "compression": "tar + zstd --long=27", "created": "2026-10-07T03:44:00Z",
           "size": 3600000000, "parts": [{"name": "omacvm-prebuilt-%s-app.tar.zst.part-aa" % sys.argv[2],
                                          "size": 3600000000, "sha256": "0" * 64}]}, open(sys.argv[1], "w"))
PY
sign_doc "$M"
got=$("${NOCLT[@]}" OMACVM_PREBUILT_SOURCE="$T/images" OMACVM_CACHE="$T/cache" bash "$RES/scripts/prebuilt-vm.sh" --lookup 2>&1)
expect "prebuilt-vm.sh --lookup (the setup screen)" "local 3600000000 4.0.3 $VERSION" "$got"
no_calls "prebuilt-vm.sh --lookup"
# The password hash for the image's first boot.
got=$(printf 'pw' | "${NOCLT[@]}" bash -c 'source "$1/lib/mac.sh"; python3 "$1/prebuilt/sha512crypt.py"' _ "$IN")
expect "the password hash" '$6$' "${got:0:3}"
no_calls "the password hash"

# omacvm from the app ("omacvm in Terminal", the Bridge's control centre jobs).
got=$("${NOCLT[@]}" "$RES/omacvm/omacvm" vms --json 2>&1)
expect "omacvm vms --json" '{"omacvm":' "${got:0:10}"
no_calls "omacvm vms --json"
"${NOCLT[@]}" "$RES/omacvm/omacvm" features --json > "$T/features.json" 2>&1
expect "omacvm features --json" 0 "$("$REALPY" -c 'import json,sys; json.load(open(sys.argv[1])); print(0)' "$T/features.json" 2>&1)"
no_calls "omacvm features --json"

# omacvm build's plan for OmacVM.app, from the app: the Command Line Tools are
# not asked for (exit 3 "needs a person" before).
"${NOCLT[@]}" OMACVM_PREBUILT_SOURCE="$T/images" "$RES/omacvm/omacvm" build --plan --json --vm-type app > "$T/plan.json" 2>"$T/plan.err"
expect "omacvm build --plan --vm-type app: a plan" 0 "$("$REALPY" -c 'import json,sys; json.load(open(sys.argv[1])); print(0)' "$T/plan.json" 2>&1 || cat "$T/plan.err")"
expect "... nothing about the Command Line Tools" "" "$(grep -i "command line tools" "$T/plan.json" "$T/plan.err")"
no_calls "omacvm build --plan --vm-type app"

# apply's VM-side parts (src/lib/features.sh, python3).
got=$("${NOCLT[@]}" bash -c 'source "$1/lib/mac.sh"; source "$1/lib/features.sh"
  feature_switch_parts "{\"parts\": {\"core\": {\"digest\": \"a\"}, \"camera\": {\"digest\": \"b\"}}}" \
    "{\"parts\": {\"core\": {\"digest\": \"a\"}, \"camera\": {\"digest\": \"c\"}}}" "" "bridge camera"' _ "$IN")
expect "apply: the feature parts to run" "camera" "$got"
no_calls "apply's feature parts"

# src/mac/install.sh with no helper from the app and nothing to build them:
# it says so for each, and never runs swiftc or clang. Stand-in installers:
# nothing is installed even if it tried.
S=$T/run/src; mkdir -p "$T/run"; cp -R "$IN" "$S"
for d in bridge/mac gestures/mac omanotch/mac; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/installs"\n' "$d" "$T" > "$S/$d/install.sh"; chmod +x "$S/$d/install.sh"
done
out=$("${NOCLT[@]}" OMACVM_HELPERS="$T/none" "$S/mac/install.sh" --skip-clip --omanotch --quiet 2>&1); rc=$?
expect "install.sh without the app's helpers: exit 5" 5 "$rc"
expect "... says the Bridge needs the Command Line Tools" 1 "$(grep -c "^OmacVM Bridge: building it needs Xcode's Command Line Tools" <<<"$out")"
expect "... and Omanotch" 1 "$(grep -c "^Omanotch: building it needs Xcode's Command Line Tools" <<<"$out")"
expect "... no installer ran" "" "$(cat "$T/installs" 2>/dev/null)"
no_calls "src/mac/install.sh"

# Nothing written into the app: a new __pycache__ there breaks its seal.
expect "nothing written into the app (__pycache__)" "" "$(find "$APP" -newer "$T/start" -name '*.pyc')"

# What the stand-ins cannot catch: a stub run by its full path. The Mac side's
# scripts name none (install.sh's /usr/bin/git runs only once xcode-select found the tools).
re=$(printf '%s|' $STUBS | sed 's/|$//; s/+/\\+/g')
hits=$(cd "$R" && grep -nE "/usr/bin/($re)([^a-z0-9_+-]|$)" omacvm app/scripts/*.sh src/cmd/*.sh src/lib/*.sh src/mac/*.sh \
  src/prebuilt/*.sh src/*/mac/install.sh 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|^install\.sh:')
expect "no stub by its full path on the Mac side" "" "$hits"
# swift scripts run with `swift FILE` need the tools: mac_tool instead.
hits=$(cd "$R" && grep -nE '(^|[^a-z_])swift (-e |"\$R/src)' omacvm src/cmd/*.sh src/lib/*.sh src/mac/*.sh src/prebuilt/*.sh app/scripts/*.sh 2>/dev/null |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|src/lib/tools.sh:')
expect "no swift scripts run on the Mac side (mac_tool)" "" "$hits"
exit $fail
