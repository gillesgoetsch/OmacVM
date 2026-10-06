#!/bin/bash
# End-to-end test of OmacVM.app's self-update (docs/adr/0033) on this Mac,
# apart from any installed OmacVM: test bundles with their own bundle id in
# WORK (never /Applications), a local feed signed with a test key on
# 127.0.0.1, its own settings folder, a VM without an OS, all out of sight.
#   OMACVM_SIGN_ID=<Developer ID> scripts/build-app.sh --name "OmacVM SU-test" --id org.omacvm.sutest
#   OMACVM_SIGN_ID=<Developer ID> scripts/dev/self-update-test.sh dist/"OmacVM SU-test.app" WORK
# Versions made from the build (copied, version changed, signed again):
# 2.7.0 installed, 2.7.1, 2.7.4 and 2.7.5 good, 2.7.2 without a QEMU
# library, 2.7.3 whose launcher exits at once. Tests: weekly schedule,
# silence switch, update held back while a VM runs and applied after (shut
# down, crash, a QEMU without its launcher, next launch), rollback of both
# broken builds, the one step back, a renamed copy (its own update folder),
# an app started during a swap, no window after an update at shutdown, an
# app on another disk (a disk image: copied next to it, renamed in place).
# Exit 0 when all pass.
# check() evals its condition: variables used there look unused.
# shellcheck disable=SC2034
set -uo pipefail
SRC=${1:?usage: self-update-test.sh BUILT_APP WORK}
WORK=${2:?usage: self-update-test.sh BUILT_APP WORK}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
ID=org.omacvm.sutest
NAME="OmacVM SU-test"
PORT=${PORT:-18765}
SIGN_ID=${OMACVM_SIGN_ID:?set OMACVM_SIGN_ID (a Developer ID Application identity)}
die() { echo "ERROR: $*" >&2; exit 1; }
[[ ! -e $HOME/.omacvm-user-testing ]] || die "the user is testing (~/.omacvm-user-testing): no VMs on this Mac now"
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist" 2>/dev/null) == "$ID" ]] ||
  die "$SRC is not a $ID test build"
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
[[ $WORK != /Applications* ]] || die "not in /Applications"

pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
log() { printf '\n== %s\n' "$*"; }

UPD_ROOT="$HOME/Library/Application Support/OmacVM/Updates/$ID"
# One update folder per copy: "<name>-<8 hex of SHA-256 of its real path>".
ukey() { local p; p=$(cd "$1" && pwd -P); printf '%s-%s' "$(basename "$p" .app)" "$(printf '%s' "$p" | shasum -a 256 | cut -c1-8)"; }
INST=$WORK/install
APP=$INST/$NAME.app
FEED=$WORK/feed
SETTINGS=$WORK/settings
SIGN=$REPO/src/release/sign.swift

# What must not move: the installed app's settings, the shared settings file.
fingerprint() {
  { defaults read org.omacvm.app 2>/dev/null; cat "$HOME/Library/Application Support/omacvm/settings.json" 2>/dev/null
    for a in /Applications/*.app "$HOME"/Applications/*.app; do
      [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null) == org.omacvm.app ]] &&
        { echo "$a"; shasum "$a/Contents/Info.plist" "$a/Contents/MacOS/OmacVM"; }
    done; } | shasum | cut -c1-16
}
FP_BEFORE=$(fingerprint)

# Swap scripts first (one waiting for a marker would bring an app back),
# then every app and VM from WORK.
stop_all() {
  pkill -f "update-swap.sh .*$WORK/" 2>/dev/null
  pkill -f "$WORK/.*/Contents/" 2>/dev/null
  sleep 1
}
MNT=$WORK/mnt
cleanup() {
  stop_all
  [[ -n ${SERVER:-} ]] && kill "$SERVER" 2>/dev/null
  mount | grep -qF " on $MNT " && hdiutil detach -force "$MNT" >/dev/null 2>&1
}
trap cleanup EXIT
stop_all   # leftovers of an earlier run

# ---- versions ----
log "test versions"
mount | grep -qF " on $MNT " && hdiutil detach -force "$MNT" >/dev/null 2>&1
rm -rf "$WORK/v" "$FEED" "$SETTINGS" "$INST" "$WORK/VMs" "$UPD_ROOT" "$WORK/vol.sparseimage" "$MNT"
mkdir -p "$WORK/v" "$FEED" "$SETTINGS" "$INST" "$WORK/VMs"
resign() { codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none --identifier "$ID" \
  --entitlements "$HERE/app/OmacVM.entitlements" "$1" 2>/dev/null; }
make_version() {   # VERSION -> $WORK/v/VERSION/NAME.app
  local d=$WORK/v/$1
  mkdir -p "$d"; ditto "$SRC" "$d/$NAME.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" -c "Set :CFBundleVersion $1" "$d/$NAME.app/Contents/Info.plist"
}
for v in 2.7.0 2.7.1 2.7.2 2.7.3 2.7.4 2.7.5; do make_version $v; done
# 2.7.2: QEMU misses a library (dyld stops it).
rm "$WORK/v/2.7.2/$NAME.app/Contents/Resources/runtime/lib/libvirglrenderer.1.dylib"
# 2.7.3: a launcher that exits at once.
printf 'int main(void) { return 3; }\n' > "$WORK/v/exit3.c"
cc -o "$WORK/v/2.7.3/$NAME.app/Contents/MacOS/OmacVM" "$WORK/v/exit3.c"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$WORK/v/2.7.3/$NAME.app/Contents/MacOS/OmacVM"
for v in 2.7.0 2.7.1 2.7.2 2.7.3 2.7.4 2.7.5; do resign "$WORK/v/$v/$NAME.app" || die "signing $v"; done
# The team of the identity the test versions are signed with: the feed names it.
TEAM=$(codesign -dv "$WORK/v/2.7.0/$NAME.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ $TEAM =~ ^[A-Z0-9]{10}$ ]] || die "OMACVM_SIGN_ID is not a Developer ID (no team)"
DEVID="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""
for v in 2.7.0 2.7.1 2.7.2 2.7.3 2.7.4 2.7.5; do
  check "$v is signed with the Developer ID" 'codesign --verify --deep --strict -R="$DEVID" "$WORK/v/$v/$NAME.app" 2>/dev/null'
done
ditto "$WORK/v/2.7.0/$NAME.app" "$APP"
UPD="$UPD_ROOT/$(ukey "$APP")"

# ---- feed ----
# Throwaway keys: test-key and spare-key play the main and the spare release
# key (the app gets both), stranger-key is neither.
for k in test-key spare-key stranger-key; do swift "$SIGN" keygen "$WORK/$k" > "$WORK/$k.pub" || die keygen; done
publish() {   # VERSION [TEAMS (JSON strings)] [KEY]: the feed offers it
  local z=$FEED/$NAME-$1.zip teams=${2:-\"$TEAM\"} key=${3:-$WORK/test-key}
  rm -f "$FEED"/*.zip
  ditto -c -k --keepParent "$WORK/v/$1/$NAME.app" "$z"
  cat > "$FEED/OmacVM-appcast.json" <<EOF
{"schema": 1, "kind": "app-feed", "version": "$1", "url": "http://127.0.0.1:$PORT/$(basename "$z" | sed 's/ /%20/g')",
 "length": $(stat -f %z "$z"), "sha256": "$(shasum -a 256 "$z" | cut -d' ' -f1)", "minimum_macos": "15.0",
 "devid_teams": [$teams]}
EOF
  swift "$SIGN" sign "$key" "$FEED/OmacVM-appcast.json" > "$FEED/OmacVM-appcast.json.sig"
}
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED" > "$WORK/server.log" 2>&1 &
SERVER=$!
sleep 1
requests() { grep -c "GET /$1" "$WORK/server.log"; }

# ---- the test app's own settings ----
defaults delete "$ID" >/dev/null 2>&1
defaults write "$ID" vmsRoot "$WORK/VMs"
defaults write "$ID" installedPath "$APP"
defaults write "$ID" startFullScreen -bool false
days_ago() { mkdir -p "$UPD"; date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' > "$UPD/last-check"; }
ENV=(--env "OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json" --env "OMACVM_APPCAST_KEY=$(cat "$WORK/test-key.pub") $(cat "$WORK/spare-key.pub")"
     --env "OMACVM_SETTINGS_DIR=$SETTINGS" --env OMACVM_COCOA_HIDDEN=1 --env OMACVM_UPDATE_WAIT=20)
start_app() { open -n "${ENV[@]}" "$1" --args "${@:2}"; }
# QEMU, started as Contents/MacOS/OmacVM-VM (3.0.1, DockIdentity) or by its own path.
QEMU_RE='(MacOS/OmacVM-VM|Resources/runtime/bin/OmacVM) '
launcher_pid() { pgrep -f "$1/Contents/MacOS/OmacVM( |\$)" | head -1; }
# A swap that is still on (waiting for the new app's answer) ends first.
wait_swaps() { local i; for ((i = 0; i < 180; i++)); do pgrep -f "update-swap.sh .*$WORK/" >/dev/null || return 0; sleep 0.5; done; return 1; }
quit_app() { local p; wait_swaps; p=$(launcher_pid "$1"); [[ -z $p ]] || { kill "$p"; sleep 1; }; }
# PlistBuddy, not defaults: cfprefsd caches a plist it read by path.
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
wait_for() {   # SECONDS CONDITION
  local i; for ((i = 0; i < $1 * 2; i++)); do eval "$2" && return 0; sleep 0.5; done; return 1
}
logtail() { tail -3 "$UPD/update.log" 2>/dev/null | sed 's/^/    /'; }

# ---- 0. release keys and Developer ID teams ----
log "0. the feed names another team only: not staged; signed by a stranger: refused"
publish 2.7.1 '"0000000000"'
days_ago 8
start_app "$APP"
check "another team only: refused" 'wait_for 60 "grep -q \"is not signed with a Developer ID the update feed allows\" \"\$UPD/update.log\""'
check "nothing staged" '[[ ! -d $UPD/staged/2.7.1 ]]'
quit_app "$APP"
publish 2.7.1 "" "$WORK/stranger-key"
days_ago 8
start_app "$APP"
check "signed by a stranger: refused" 'wait_for 60 "grep -q \"does not match OmacVM.s release keys\" \"\$UPD/update.log\""'
quit_app "$APP"; logtail

# ---- 1. weekly schedule ----
log "1. weekly: checked a day ago -> no check; 8 days ago -> check, download, offer (feed signed with the spare)"
publish 2.7.1 "" "$WORK/spare-key"
n0=$(requests OmacVM-appcast.json) s0=$(requests OmacVM-appcast.json.sig)
days_ago 1
start_app "$APP"
sleep 30
check "checked a day ago: no request" '[[ $(requests OmacVM-appcast.json) == "$n0" ]]'
quit_app "$APP"
days_ago 8
start_app "$APP"
check "8 days ago: feed fetched within 40 s" 'wait_for 40 "[[ \$(requests OmacVM-appcast.json.sig) -gt $s0 ]]"'
check "signed with the spare key: 2.7.1 downloaded, checked and offered" 'wait_for 30 "grep -q \"ready: 2.7.1\" \"\$UPD/update.log\""'
check "the staged app has no quarantine flag" '! xattr -r "$UPD/staged" 2>/dev/null | grep -q quarantine'
check "nothing replaced without asking" '[[ $(version "$APP") == 2.7.0 ]]'
quit_app "$APP"; logtail

# ---- 2. silence ----
log "2. update checks off: no request, nothing offered"
printf '{"update_checks": false}\n' > "$SETTINGS/settings.json"
n0=$(requests OmacVM-appcast.json)
days_ago 8
start_app "$APP"
sleep 30
check "checks off: no request after 30 s" '[[ $(requests OmacVM-appcast.json) == "$n0" ]]'
quit_app "$APP"
printf '{"update_checks": true}\n' > "$SETTINGS/settings.json"

# ---- 3. held back while a VM runs, applied after ----
log "3. a VM runs from the app: the update waits, then goes in when it stops"
VM=$WORK/VMs/SU-test-vm
mkdir -p "$VM"
cat > "$VM/vm.env" <<EOF
NAME='SU-test-vm'
CPUS=2
MEM_MB=1024
DISK_GB=1
SSH_PORT=52399
VM_USER='test'
FEATURES='bridge=off gestures=off omanotch=off camera=off battery=off'
EOF
dd if=/dev/null of="$VM/disk.img" bs=1 seek=$((1 << 30)) 2>/dev/null
mkfile -n 64m "$VM/efi-vars.fd"; touch "$VM/ready"
start_app "$APP" --start --vm SU-test-vm
check "the test VM's QEMU runs from the app" 'wait_for 20 "pgrep -f \"\$APP/Contents/$QEMU_RE\" >/dev/null"'
start_app "$APP" --update-now
check "update asked for: held back" 'wait_for 30 "grep -q \"install 2.7.1 deferred\" \"\$UPD/update.log\""'
sleep 3
check "still 2.7.0 while the VM runs" '[[ $(version "$APP") == 2.7.0 ]]'
check "the VM still runs" 'pgrep -f "$APP/Contents/$QEMU_RE" >/dev/null'
# Shut the VM down (QMP quit: QEMU ends with 0, as after a guest power-off).
QMP=$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(printf '%s' "$VM" | shasum | cut -c1-8).qmp
qmp_quit() {
  python3 - "$QMP" <<'EOF'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline()
for c in ("qmp_capabilities", "quit"):
    f.write(json.dumps({"execute": c}) + "\n"); f.flush(); time.sleep(0.3)
EOF
}
qemu_runs() { pgrep -f "$APP/Contents/$QEMU_RE" >/dev/null; }
qmp_quit
check "after the VM stopped: 2.7.1 in place" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.1 ]]"'
check "swap result: installed" 'wait_for 30 "grep -q \"result: installed 2.7.0 2.7.1\" \"\$UPD/update.log\""'
check "2.7.0 kept for one step back" '[[ $(version "$UPD/previous/$NAME.app") == 2.7.0 ]]'
# Shut down from the guest: the app was quitting, so 2.7.1 only checks
# that it starts and opens no window.
check "2.7.1 started quietly (no window) and quit" 'wait_for 30 "grep -q \"started after the update (quiet\" \"\$UPD/update.log\"" && wait_swaps && wait_for 10 "[[ -z \$(launcher_pid \"\$APP\") ]]"'
check "the result waits for the next launch" '[[ -e "$UPD/result" ]]'
start_app "$APP"
check "next launch: 2.7.1 read the result (its window says it updated)" 'wait_for 15 "[[ ! -e \"\$UPD/result\" ]]"'
check "installed app keeps the Developer ID" 'codesign --verify --deep --strict -R="$DEVID" "$APP" 2>/dev/null'
quit_app "$APP"; logtail

# ---- 4. rollback: QEMU does not start ----
log "4. 2.7.2 (QEMU misses a library): back to 2.7.1, 2.7.2 skipped"
publish 2.7.2
start_app "$APP" --update-now
check "rolled back within 60 s" 'wait_for 60 "grep -q \"result: rolled-back 2.7.2\" \"\$UPD/update.log\""'
check "2.7.1 in place again" '[[ $(version "$APP") == 2.7.1 ]]'
check "2.7.1 runs again" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
check "2.7.2 skipped" 'wait_for 10 "[[ \$(cat \"\$UPD/skip\" 2>/dev/null) == 2.7.2 ]]"'
check "2.7.0 still kept" '[[ $(version "$UPD/previous/$NAME.app") == 2.7.0 ]]'
quit_app "$APP"; logtail

# Skipped: a weekly check neither downloads nor offers it.
n0=$(requests "OmacVM%20SU-test-2.7.2.zip")
days_ago 8
start_app "$APP"
check "weekly check after the rollback: feed fetched" 'wait_for 40 "grep -q \"2.7.2 is skipped\" \"\$UPD/update.log\""'
check "skipped version not downloaded again" '[[ $(requests "OmacVM%20SU-test-2.7.2.zip") == "$n0" ]]'
quit_app "$APP"

# ---- 5. rollback: the launcher exits at once ----
log "5. 2.7.3 (launcher exits at once): back to 2.7.1"
publish 2.7.3
start_app "$APP" --update-now
check "rolled back after the 20 s wait" 'wait_for 60 "grep -q \"result: rolled-back 2.7.3\" \"\$UPD/update.log\""'
check "2.7.1 in place again" '[[ $(version "$APP") == 2.7.1 ]]'
check "2.7.1 runs again" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
quit_app "$APP"; logtail

# ---- 6. one step back (the menu's Go Back runs this) ----
log "6. go back to 2.7.0"
OMACVM_COCOA_HIDDEN=1 OMACVM_SETTINGS_DIR=$SETTINGS OMACVM_APPCAST_KEY="$(cat "$WORK/test-key.pub") $(cat "$WORK/spare-key.pub")" \
  OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json \
  bash "$APP/Contents/Resources/scripts/update-swap.sh" rollback "$APP" - "$UPD" 99999 "$(openssl rand -hex 16)" \
  >> "$UPD/update.log" 2>&1 &
check "2.7.0 in place" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.0 ]]"'
check "swap result: went back" 'wait_for 30 "grep -q \"result: went-back 2.7.1\" \"\$UPD/update.log\""'
check "2.7.1 skipped" 'wait_for 10 "[[ \$(cat \"\$UPD/skip\" 2>/dev/null) == 2.7.1 ]]"'
quit_app "$APP"; logtail

# ---- 7. a copy installed under its own name ----
log "7. renamed copy 'Omarchy SU' (ad hoc, as the installer does): keeps its name and its own update folder"
publish 2.7.1
rm -f "$UPD/skip"
PREV_A=$(version "$UPD/previous/$NAME.app")
REN=$INST/Omarchy\ SU.app
ditto "$WORK/v/2.7.0/$NAME.app" "$REN"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omarchy SU" -c "Set :CFBundleDisplayName Omarchy SU" "$REN/Contents/Info.plist"
codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$REN" 2>/dev/null
start_app "$REN" --update-now
check "renamed copy updated to 2.7.1" 'wait_for 90 "[[ \$(version \"\$REN\") == 2.7.1 ]]"'
check "it keeps its name" '[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$REN/Contents/Info.plist") == "Omarchy SU" ]]'
check "its signature is valid" 'codesign --verify --deep --strict "$REN" 2>/dev/null'
check "its QEMU keeps the Developer ID" 'codesign --verify -R="$DEVID" "$REN/Contents/Resources/runtime/bin/OmacVM" 2>/dev/null'
check "it started (no rollback)" 'wait_swaps && [[ $(version "$REN") == 2.7.1 ]] && [[ -n $(launcher_pid "$REN") ]]'
UPD_REN="$UPD_ROOT/$(ukey "$REN")"
check "its 2.7.0 kept in its own folder" '[[ $UPD_REN != "$UPD" && $(version "$UPD_REN/previous/Omarchy SU.app") == 2.7.0 ]]'
check "the other copy's kept version untouched ($PREV_A)" '[[ -n $PREV_A && $(version "$UPD/previous/$NAME.app") == "$PREV_A" ]]'
check "the other copy's log has nothing of it" '! grep -q "Omarchy SU" "$UPD/update.log"'
quit_app "$REN"; logtail

# ---- 8. a waiting update after a crash of the VM ----
log "8. update held back, then the VM's QEMU crashes: 2.7.4 goes in"
publish 2.7.4
start_app "$APP" --start --vm SU-test-vm
check "the test VM runs" 'wait_for 20 qemu_runs'
start_app "$APP" --update-now
check "update asked for: held back" 'wait_for 30 "grep -q \"install 2.7.4 deferred\" \"\$UPD/update.log\""'
pkill -9 -f "$APP/Contents/$QEMU_RE"
check "after the crash: 2.7.4 in place" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.4 ]]"'
check "swap result: installed" 'wait_for 30 "grep -q \"result: installed 2.7.0 2.7.4\" \"\$UPD/update.log\""'
check "2.7.4 runs" 'wait_for 10 "[[ -n \$(launcher_pid \"\$APP\") ]]"'
quit_app "$APP"; logtail

# ---- 9. a QEMU without its launcher; the next launch ----
log "9. QEMU runs without the app's runner: --update-now does not stay hidden; the next launch waits, then installs"
publish 2.7.5
start_app "$APP" --start --vm SU-test-vm
check "the test VM runs" 'wait_for 20 qemu_runs'
kill -9 "$(launcher_pid "$APP")"; sleep 2
check "its launcher gone, QEMU still runs" '[[ -z $(launcher_pid "$APP") ]] && qemu_runs'
start_app "$APP" --update-now
check "update asked for: held back (QEMU from the bundle)" 'wait_for 30 "grep -q \"install 2.7.5 deferred\" \"\$UPD/update.log\""'
check "the hidden --update-now launcher quits" 'wait_for 20 "[[ -z \$(launcher_pid \"\$APP\") ]]"'
check "the request is kept" '[[ $(cat "$UPD/install-pending" 2>/dev/null) == 2.7.5 ]]'
check "still 2.7.4" '[[ $(version "$APP") == 2.7.4 ]]'
start_app "$APP"
check "next launch: the kept request waits (QEMU runs)" 'wait_for 30 "[[ \$(grep -c \"install 2.7.5 deferred\" \"\$UPD/update.log\") -ge 2 ]]"'
check "still 2.7.4 while QEMU runs" '[[ $(version "$APP") == 2.7.4 ]]'
qmp_quit
check "QEMU stopped: 2.7.5 in place (the app checks every 30 s)" 'wait_for 60 "[[ \$(version \"\$APP\") == 2.7.5 ]]"'
check "swap result: installed" 'wait_for 30 "grep -q \"result: installed 2.7.4 2.7.5\" \"\$UPD/update.log\""'
check "the request is cleared" 'wait_swaps && [[ ! -e "$UPD/install-pending" ]]'
quit_app "$APP"; logtail

# ---- 10. something starts from the app during the swap ----
# A process from the kept version (previous/) stands in for an app opened
# between the swap's first check and its moves: the check after the move
# sees it and puts everything back.
log "10. a process from the kept version during a swap: nothing moves"
printf 'int main(void) { for (;;) pause(); }\n' > "$WORK/v/sleep.c"
mkdir -p "$UPD/previous/$NAME.app/Contents/MacOS"
cc -include unistd.h -o "$UPD/previous/$NAME.app/Contents/MacOS/sleeper" "$WORK/v/sleep.c"
"$UPD/previous/$NAME.app/Contents/MacOS/sleeper" & SLEEPER=$!
rm -rf "$UPD/incoming"; mkdir -p "$UPD/incoming"; ditto "$WORK/v/2.7.1/$NAME.app" "$UPD/incoming/$NAME.app"
OMACVM_COCOA_HIDDEN=1 OMACVM_SETTINGS_DIR=$SETTINGS OMACVM_APPCAST_KEY="$(cat "$WORK/test-key.pub") $(cat "$WORK/spare-key.pub")" \
  OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json \
  bash "$APP/Contents/Resources/scripts/update-swap.sh" install "$APP" "$UPD/incoming/$NAME.app" "$UPD" 99999 "$(openssl rand -hex 16)" \
  >> "$UPD/update.log" 2>&1
check "swap result: aborted, started during the update" 'grep -q "result: aborted $NAME.app was started during the update" "$UPD/update.log"'
check "2.7.5 still in place" '[[ $(version "$APP") == 2.7.5 ]]'
check "the kept version still in previous/" '[[ -x "$UPD/previous/$NAME.app/Contents/MacOS/sleeper" && ! -e "$UPD/previous.old" ]]'
check "the new app not moved" '[[ $(version "$UPD/incoming/$NAME.app") == 2.7.1 ]]'
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
quit_app "$APP"; logtail

# ---- 11. an app on another disk ----
log "11. an app on another disk (a disk image): copied next to it, checked, renamed; nothing crosses disks"
hdiutil create -quiet -size 1g -type SPARSE -fs JHFS+ -volname "SU-test-vol" "$WORK/vol" || die "disk image"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$WORK/vol.sparseimage" || die "attach the disk image"
EXT=$MNT/Apps/$NAME.app
mkdir -p "$MNT/Apps"; ditto "$WORK/v/2.7.0/$NAME.app" "$EXT"
UPD_EXT="$UPD_ROOT/$(ukey "$EXT")"
EXT_WORK="$MNT/Apps/.omacvm-updates/$(ukey "$EXT")"
check "the disk image is another volume" '[[ $(stat -f %d "$MNT") != $(stat -f %d "$HOME/Library") ]]'
publish 2.7.1
start_app "$EXT" --update-now
check "the app on the other disk updated to 2.7.1" 'wait_for 90 "[[ \$(version \"\$EXT\") == 2.7.1 ]]"'
check "swap result: installed" 'wait_for 30 "grep -q \"result: installed 2.7.0 2.7.1\" \"\$UPD_EXT/update.log\""'
check "the copy was made and checked on that disk" 'grep -qF "copied to $EXT_WORK/incoming/$NAME.app and checked" "$UPD_EXT/update.log"'
check "2.7.0 kept on its own disk" '[[ $(version "$EXT_WORK/previous/$NAME.app") == 2.7.0 ]]'
check "no app kept in the home folder" '[[ ! -e $UPD_EXT/previous && ! -e $UPD_EXT/incoming ]]'
check "it started (no rollback), Developer ID kept" 'wait_swaps && [[ -n $(launcher_pid "$EXT") ]] && codesign --verify --deep --strict -R="$DEVID" "$EXT" 2>/dev/null'
quit_app "$EXT"; logtail
# The swap itself refuses a work folder on another disk than the app.
mkdir -p "$UPD_EXT/incoming"; ditto "$WORK/v/2.7.4/$NAME.app" "$UPD_EXT/incoming/$NAME.app"
OMACVM_COCOA_HIDDEN=1 OMACVM_SETTINGS_DIR=$SETTINGS \
  bash "$EXT/Contents/Resources/scripts/update-swap.sh" install "$EXT" "$UPD_EXT/incoming/$NAME.app" "$UPD_EXT" 99999 "$(openssl rand -hex 16)" \
  >> "$UPD_EXT/update.log" 2>&1
check "work folder on another disk: refused" 'grep -q "result: aborted .* is on another disk than $NAME.app: nothing moved" "$UPD_EXT/update.log"'
check "2.7.1 still in place, nothing moved" '[[ $(version "$EXT") == 2.7.1 && $(version "$UPD_EXT/incoming/$NAME.app") == 2.7.4 && $(version "$EXT_WORK/previous/$NAME.app") == 2.7.0 ]]'
quit_app "$EXT"
hdiutil detach -quiet "$MNT" || hdiutil detach -force -quiet "$MNT"

log "the installed OmacVM and the shared settings untouched"
check "fingerprint unchanged" '[[ $(fingerprint) == "$FP_BEFORE" ]]'

echo; echo "$pass passed, $fail failed (log: $UPD/update.log, server: $WORK/server.log)"
(( fail == 0 ))
