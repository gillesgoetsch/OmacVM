#!/bin/bash
# OmacVM.app's notch setting (FullPanel, #339): the app
# (app/app/Sources/OmacVMFeatures/NotchArea.swift) and the Mac side of omacvm
# (src/lib/notch.sh) decide the same for every case (setting, the VM's side
# ready, Start in Window or full screen, a notch on the Mac), and `omacvm notch` reads
# and writes the VM folder's file the app reads. No VM, no notch needed.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { [[ $2 == "$3" ]] && ok "$1" || bad "$1: got '$3', want '$2'"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

if command -v swiftc >/dev/null; then
  swiftc -O -o "$T/notch" "$R/app/app/Sources/OmacVMFeatures/NotchArea.swift" "$R/src/tests/notch-setting/main.swift" ||
    { echo "FAIL NotchArea.swift does not build on its own"; exit 1; }
  "$T/notch" > "$T/swift.txt"
  source "$R/src/lib/notch.sh"
  n=0; diff=0
  while IFS='|' read -r left want; do
    read -r mode ready full mac <<<"$left"
    d=$T/vm; rm -rf "$d"; mkdir -p "$d"
    [[ $mode == fullpanel ]] && echo fullpanel > "$d/notch-mode"
    (( ready )) && : > "$d/fullpanel-ready"
    got=$(notch_next_start "$d" "$mac" "$full")
    # The app's FullPanel record adds the geometry: "fullpanel (Omanotch off ...)".
    [[ $want == fullpanel* ]] && want=fullpanel
    n=$((n + 1))
    [[ $got == "$want" ]] || { diff=$((diff + 1)); echo "  differs: $left: app '$want', omacvm '$got'"; }
  done < "$T/swift.txt"
  (( diff == 0 && n == 16 )) && ok "app and omacvm agree on $n cases" || bad "app and omacvm differ in $diff of $n cases"
else
  echo "skip app vs omacvm: no swiftc"
  source "$R/src/lib/notch.sh"
fi

# The rules, on the Mac side.
d=$T/r; mkdir -p "$d"
expect "no file: native" native "$(notch_choice "$d")"
echo FullPanel > "$d/notch-mode"; expect "another word: native" native "$(notch_choice "$d")"
notch_set "$d" fullpanel; expect "set fullpanel" fullpanel "$(notch_choice "$d")"
expect "the file says fullpanel" fullpanel "$(cat "$d/notch-mode")"
notch_set "$d" native; [[ ! -e $d/notch-mode ]] && ok "native removes the file" || bad "native left the file"
notch_set "$d" bogus; expect "a bad value: usage" 2 "$?"
notch_set "$d" fullpanel
expect "not ready: native, says why" "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)" "$(notch_next_start "$d" notch 1)"
: > "$d/fullpanel-ready"
expect "ready, full screen, notch: fullpanel" fullpanel "$(notch_next_start "$d" notch 1)"
echo "bridge=on omanotch=off" > "$d/features"
expect "Omanotch off in the VM: not ready" "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)" "$(notch_next_start "$d" notch 1)"
echo "bridge=on omanotch=on" > "$d/features"
expect "windowed: native" "native (including notch is set, but the app starts VMs in a window)" "$(notch_next_start "$d" notch 0)"
expect "no notch: native" "native (including notch is set, but this Mac's built-in display has no notch now)" "$(notch_next_start "$d" none 1)"
mkdir -p "$d/logs"
printf '%s\n' "OmacVM: notch area: native" "OmacVM: notch area: fullpanel (Omanotch off for this start; notch 640.5-829.5, strip 37.0 of 1470x956 points)" > "$d/logs/qemu.log"
notch_fullpanel_this_start "$d" && ok "this start: FullPanel (the last line)" || bad "this start not read as FullPanel"
echo "OmacVM: notch area: native (including notch is set, but the app starts VMs in a window)" > "$d/logs/qemu.log"
notch_fullpanel_this_start "$d" && bad "a native start read as FullPanel" || ok "this start: native"
rm -f "$d/logs/qemu.log"
notch_fullpanel_this_start "$d" && bad "no log read as FullPanel" || ok "no log: not FullPanel"

# omacvm notch on a made-up app VM, in a throwaway HOME and settings domain
# (no real VM, app or setting).
H=$T/home; V=$H/OmacVM/Test-notch; mkdir -p "$V/logs"
printf "NAME='Test notch'\nSSH_PORT='52999'\n" > "$V/vm.env"
export OMACVM_APP_ID=org.omacvm.test.notch-setting.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T"' EXIT
run() { HOME=$H "$R/omacvm" notch "$@" 2>&1; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }
expect "omacvm notch --json: native" native "$(run --vm "Test notch" --json | j notch)"
expect "  next start: native" native "$(run --vm "Test notch" --json | j next_start)"
expect "  full screen: the app's default (on)" True "$(run --vm "Test notch" --json | j full_screen)"
expect "omacvm notch fullpanel: changed" True "$(run --vm "Test notch" fullpanel --json --yes | j changed)"
expect "  the file the app reads" fullpanel "$(cat "$V/notch-mode")"
expect "  again: unchanged" False "$(run --vm "Test notch" fullpanel --json | j changed)"
expect "  the VM is not ready yet" False "$(run --vm "Test notch" --json | j vm_ready)"
: > "$V/fullpanel-ready"
defaults write "$OMACVM_APP_ID" startFullScreen -bool false
expect "  windowed in the app: native next start" "native (including notch is set, but the app starts VMs in a window)" "$(run --vm "Test notch" --json | j next_start)"
defaults delete "$OMACVM_APP_ID" startFullScreen
echo "OmacVM: notch area: fullpanel (Omanotch off for this start; notch 640.5-829.5, strip 37.0 of 1470x956 points)" > "$V/logs/qemu.log"
expect "  this start from qemu.log" "fullpanel (Omanotch off for this start; notch 640.5-829.5, strip 37.0 of 1470x956 points)" "$(run --vm "Test notch" --json | j this_start)"
out=$(run --vm "Test notch" native)
[[ $out == *"Full screen, notch via Omanotch (from the VM's next start)"* && ! -e $V/notch-mode ]] && ok "omacvm notch native" || bad "native: $out"
fs() { HOME=$H "$R/omacvm" fullscreen "$@" 2>&1; }
expect "omacvm fullscreen notch: the same file" True "$(fs --vm "Test notch" notch --json --yes | j changed)"
expect "  notch-mode fullpanel" fullpanel "$(cat "$V/notch-mode")"
expect "  its title" "Full screen including notch, no Omanotch needed (experimental)" "$(fs --vm "Test notch" --json | j title)"
out=$(fs --vm "Test notch" standard)
[[ $out == *"Full screen, notch via Omanotch (from the VM's next start)"* && ! -e $V/notch-mode ]] && ok "omacvm fullscreen standard" || bad "standard: $out"
defaults write "$OMACVM_APP_ID" startFullScreen -bool false
out=$(fs --vm "Test notch"); [[ $out == *"Start in: Window"* ]] && ok "Window in the app: says so" || bad "window: $out"
defaults delete "$OMACVM_APP_ID" startFullScreen
out=$(fs --vm "Test notch" notch standard); [[ $out == *"one setting"* ]] && ok "two settings: usage" || bad "two: $out"
out=$(run --vm "Test notch" auto); [[ $? == 2 || $out == *usage* || $out == *"unknown option"* ]] && ok "a bad value: usage" || bad "bad value: $out"
out=$(run --vm "No such VM" --json); [[ $out == *"no OmacVM.app VM named"* ]] && ok "unknown VM: says so" || bad "unknown VM: $out"
out=$(run --vm "Test notch" --vm-type utm); [[ $out == *"OmacVM.app's setting"* ]] && ok "another route: says Omanotch fills the strip there" || bad "utm: $out"

exit $fail
