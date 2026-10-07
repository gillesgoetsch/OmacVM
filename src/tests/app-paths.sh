#!/bin/bash
# Where OmacVM.app's VMs and the app itself are found: the omacvm command
# (src/lib/app.sh) and the app (VMsFolder.swift) must agree; every folder with
# VMs (older ones, 2.9's) is searched. Runs in a
# throwaway HOME with a throwaway settings domain; touches no real VM or app.
#   src/tests/app-paths.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
export OMACVM_APP_ID=org.omacvm.test.app-paths.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$OMACVM_APP_ID.plist"' EXIT
source "$R/src/lib/app.sh"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's rules, compiled on their own.
cat > "$T/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let home = URL(fileURLWithPath: a[2])
if a[1] == "prepare" {
    try VMsFolder.prepare(URL(fileURLWithPath: a[3]), home: home)
} else {
    print(VMsFolder.resolve(custom: a[1].isEmpty ? nil : a[1], home: home).path)
}
EOF
swiftc -module-cache-path "$T/mc" -o "$T/vmsf" "$R/app/app/Sources/OmacVM/VMsFolder.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL VMsFolder.swift does not compile on its own"; exit 1; }

case_n=0
check() {   # WHAT WANT [SETTING]: the command and the app both give WANT
  local cli app
  if [[ -n ${3:-} ]]; then defaults write "$OMACVM_APP_ID" vmsRoot "$3"; else defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; fi
  cli=$(HOME=$H app_vms_root)
  app=$("$T/vmsf" "${3:-}" "$H")
  expect "$1 (omacvm)" "$2" "$cli"
  expect "$1 (app)" "$2" "$app"
}
fresh() { case_n=$((case_n + 1)); H=$T/home$case_n; mkdir -p "$H"; OLD=$H/$APP_VMS_OLD; }
vm() { mkdir -p "$1"; echo "NAME='$(basename "$1")'" > "$1/vm.env"; : > "$1/disk.img"; }

fresh; check "nothing yet: ~/OmacVM" "$H/OmacVM"
fresh; vm "$OLD/Omarchy"; check "VMs in the old place only: ~/OmacVM for new ones" "$H/OmacVM"
fresh; vm "$OLD/Omarchy"; mkdir "$H/OmacVM"; check "~/OmacVM there: ~/OmacVM, old VMs or not" "$H/OmacVM"
fresh; mkdir -p "$OLD/leftover"; check "old place without a VM: ~/OmacVM" "$H/OmacVM"
fresh; vm "$OLD/Omarchy"; mkdir "$H/OmacVM"; check "the setting wins" "/Volumes/Some Drive/VMs" "/Volumes/Some Drive/VMs"
fresh; mkdir -p "$H/OmacVM/.git"; check "~/OmacVM is a git clone: the old place" "$OLD"
fresh; : > "$H/OmacVM"; check "~/OmacVM is a file: the old place" "$OLD"
fresh; mkdir "$H/omacvm"
if [[ -d $H/OmacVM ]]; then check "~/omacvm on a case-insensitive drive: the old place" "$OLD"
else check "~/omacvm on a case-sensitive drive: ~/OmacVM" "$H/OmacVM"; fi

# First use: ~/OmacVM with .metadata_never_index; another folder is left alone.
fresh; "$T/vmsf" prepare "$H" "$H/OmacVM"
expect "first use makes ~/OmacVM with .metadata_never_index" yes "$([[ -d $H/OmacVM && -f $H/OmacVM/.metadata_never_index ]] && echo yes || echo no)"
"$T/vmsf" prepare "$H" "$H/Elsewhere"
expect "a picked folder is not made or marked" no "$([[ -e $H/Elsewhere ]] && echo yes || echo no)"

# The command finds VMs there.
fresh; vm "$H/OmacVM/Omarchy"; defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "omacvm lists a VM in ~/OmacVM" "Omarchy	app	stopped" "$(HOME=$H app_list)"
expect "omacvm finds its folder" "$H/OmacVM/Omarchy" "$(HOME=$H app_dir Omarchy)"
fresh; vm "$OLD/Omarchy"
expect "omacvm still finds a VM in the old place" "$OLD/Omarchy" "$(HOME=$H app_dir Omarchy)"

# Every folder with VMs: where new ones go, older folders the app keeps
# (otherVMsRoots), the old place; each once.
names() { HOME=$H app_list | cut -f1 | tr '\n' '|'; }
expect "folders: ~/OmacVM, then the old place" "$H/OmacVM|$OLD|" "$(HOME=$H app_vms_roots | tr '\n' '|')"
vm "$H/OmacVM/New"
expect "VMs of both, the new folder first" "New|Omarchy|" "$(names)"
vm "$T/ext$case_n/OmacVM/Ext"
defaults write "$OMACVM_APP_ID" vmsRoot "$T/ext$case_n/OmacVM/"
defaults write "$OMACVM_APP_ID" otherVMsRoots -array "$H/OmacVM" "$T/ext$case_n/OmacVM" "/Volumes/OmacVM-no-such-drive/VMs"
expect "the folder set in the app, without a trailing /" "$T/ext$case_n/OmacVM" "$(HOME=$H app_vms_root)"
expect "folders: set, older ones once each, the old place" "$T/ext$case_n/OmacVM|$H/OmacVM|/Volumes/OmacVM-no-such-drive/VMs|$OLD|" \
  "$(HOME=$H app_vms_roots | tr '\n' '|')"
expect "VMs of every folder" "Ext|New|Omarchy|" "$(names)"
expect "a terminal that forces ls colours (CLICOLOR_FORCE): the same VMs" "Ext|New|Omarchy|" "$(TERM=xterm-256color CLICOLOR=1 CLICOLOR_FORCE=1 names)"
expect "a VM in an older folder by its folder name" "$H/OmacVM/New" "$(HOME=$H app_dir New)"
for d in Ext New Omarchy; do f=$(HOME=$H app_dir "$d"); echo "SSH_PORT=5222$((${#d} % 7))" >> "$f/vm.env"; done
p=$(HOME=$H app_free_port)
expect "the SSH ports of every folder are taken" yes "$([[ $p =~ ^5[0-9]+$ && $p != 52220 && $p != 52223 && $p != 52224 ]] && echo yes || echo "$p")"
echo mac=x > "$OLD/Omarchy/fast-network"
HOME=$H app_any_fast_network; expect "the fast network of a VM in the old place counts" 0 $?
defaults write "$OMACVM_APP_ID" vmsRoot "$OLD"; defaults delete "$OMACVM_APP_ID" otherVMsRoots
expect "set to the old place: listed once" "$OLD|" "$(HOME=$H app_vms_roots | tr '\n' '|')"
defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
expect "a drive that is not connected" "OmacVM-no-such-drive" "$(app_missing_drive /Volumes/OmacVM-no-such-drive/VMs)"
app_missing_drive "$H/OmacVM" >/dev/null; expect "the home folder is no drive" 1 $?

# The old place as the app made it on disk: ~/Library/Application Support/omacvm
# (lowercase). The app starts QEMU with that spelling; the command spells it
# OmacVM. A running VM there is found all the same, and only its own disk counts.
fresh; LOW="$H/Library/Application Support/omacvm/VMs"; vm "$LOW/Old,VM"
if [[ -d $OLD ]]; then   # a drive that ignores case (every Mac's default)
  d=$(HOME=$H app_dir "Old,VM")
  expect "lowercase old place: found under the command's spelling" "$OLD/Old,VM" "$d"
  bash -c 'exec -a "qemu-system-aarch64 -drive if=none,file=$1/disk.img,format=raw" sleep 30' _ "$LOW/Old,,VM" &
  q=$!; sleep 0.3
  expect "lowercase old place: its running QEMU is found" "$q" "$(app_pid_dir "$d")"
  expect "lowercase old place: listed as running" "Old,VM	app	running" "$(HOME=$H app_list)"
  vm "$LOW/Old,VM2"
  expect "lowercase old place: another VM's disk does not count" "" "$(app_pid_dir "$OLD/Old,VM2")"
  kill "$q" 2>/dev/null; wait "$q" 2>/dev/null
  expect "lowercase old place: stopped once QEMU is gone" "" "$(app_pid_dir "$d")"
  defaults write "$OMACVM_APP_ID" otherVMsRoots -array "$LOW"
  expect "lowercase old place from the app: listed once" "$H/OmacVM|$LOW|" "$(HOME=$H app_vms_roots | tr '\n' '|')"
  expect "lowercase old place from the app: each VM once" "Old,VM|Old,VM2|" "$(names)"
  defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1
else
  echo "skip lowercase old place: this drive tells cases apart"
fi

# The app: ~/Applications first, then /Applications; new installs in ~/Applications.
fakeapp() {   # DIR/NAME.app with the app's bundle id
  mkdir -p "$1/Contents/Resources/scripts"; : > "$1/Contents/Resources/scripts/create-vm.sh"
  defaults write "$1/Contents/Info" CFBundleIdentifier org.omacvm.app
}
fresh
sys=""
for a in /Applications/*.app; do
  [[ -f $a/Contents/Resources/scripts/create-vm.sh && $(defaults read "$a/Contents/Info" CFBundleIdentifier 2>/dev/null) == org.omacvm.app ]] && { sys=$a; break; }
done
if [[ -n $sys ]]; then expect "only /Applications has the app: found there" "$sys" "$(HOME=$H app_bundle)"
else expect "no app anywhere: none found" "" "$(HOME=$H app_bundle)"; fi
fakeapp "$H/Applications/My OmacVM.app"
expect "~/Applications has it: found there first" "$H/Applications/My OmacVM.app" "$(HOME=$H app_bundle)"
expect "new installs go to ~/Applications" "$H/Applications" "$(HOME=$H app_install_dir)"
# The app's own omacvm (OMACVM_APP_RUNTIME) means that app, also on another drive.
fakeapp "$H/Drive/OmacVM.app"
expect "the app whose omacvm runs: that one first" "$H/Drive/OmacVM.app" \
  "$(HOME=$H OMACVM_APP_RUNTIME="$H/Drive/OmacVM.app/Contents/Resources/runtime" app_bundle)"
mkdir -p "$H/Drive/Other.app/Contents/Resources/scripts"; : > "$H/Drive/Other.app/Contents/Resources/scripts/create-vm.sh"
defaults write "$H/Drive/Other.app/Contents/Info" CFBundleIdentifier org.example.other
expect "a runtime of an app with another id: not taken" "$H/Applications/My OmacVM.app" \
  "$(HOME=$H OMACVM_APP_RUNTIME="$H/Drive/Other.app/Contents/Resources/runtime" app_bundle)"

exit $fail
