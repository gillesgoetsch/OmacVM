#!/bin/bash
# An older omacvm never puts its OmacVM over a VM's newer one by mistake
# (#233: an old ~/.omacvm checkout's `omacvm disable fast-network` replaced a
# 3.0.3 VM's /usr/local/share/omacvm with 2.9.1). Without a VM:
#  * version_cmp: 3.0.10 > 3.0.9, pre-release labels, no version;
#  * omacvm_downgrade: when it stops, what it says, --allow-downgrade;
#  * a copy of this checkout labelled 2.9.1 against a made-up OmacVM.app VM
#    (a stand-in QEMU that holds the VM's SSH port, ssh and swift as
#    stand-ins on the PATH, a throwaway HOME, the test identity): disable,
#    apply and update stop with exit 3 before the Mac side, the VM's copy or
#    its record change; with --allow-downgrade, the same version or an older
#    VM they go on; features --json lists but leaves the record alone;
#  * the omacvm entry script says when OmacVM.app is newer than it;
#  * the Bridge's cli file: OmacVM.app takes it from an older checkout.
#   src/tests/version-guard.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() {   # WHAT TEXT NEEDLE
  if [[ $2 == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $2"; fail=1; fi
}
T=$(mktemp -d /tmp/vg.XXXXXX)   # short and without commas: QEMU's -drive line
QEMU=""
cleanup() { [[ -n $QEMU ]] && kill "$QEMU" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# ---- version_cmp ----
source "$R/src/lib/version.sh"
cmp() { local r; r=$(version_cmp "$1" "$2"); echo "${r:-none}:$?"; }
expect "3.0.10 is newer than 3.0.9" "1:0" "$(cmp 3.0.10 3.0.9)"
expect "3.0.9 is older than 3.0.10" "-1:0" "$(cmp 3.0.9 3.0.10)"
expect "2.9.1 is older than 3.0.3" "-1:0" "$(cmp 2.9.1 3.0.3)"
expect "2.10.0 is newer than 2.9.1" "1:0" "$(cmp 2.10.0 2.9.1)"
expect "3.0 is 3.0.0" "0:0" "$(cmp 3.0 3.0.0)"
expect "the same" "0:0" "$(cmp 3.0.3 3.0.3)"
expect "v and +build are ignored" "0:0" "$(cmp v3.0.3+abc 3.0.3)"
expect "a pre-release is older than its release" "-1:0" "$(cmp 3.0.5-rc1 3.0.5)"
expect "a release is newer than its pre-release" "1:0" "$(cmp 3.0.5 3.0.5-rc1)"
expect "a pre-release is newer than the release before" "1:0" "$(cmp 3.0.5-rc1 3.0.4)"
expect "rc9 < rc10" "-1:0" "$(cmp 3.0.5-rc9 3.0.5-rc10)"
expect "rc.2 < rc.10" "-1:0" "$(cmp 3.0.5-rc.2 3.0.5-rc.10)"
expect "beta < rc" "-1:0" "$(cmp 3.0.5-beta.2 3.0.5-rc.1)"
expect "labels in any case" "1:0" "$(cmp 3.0.0-RC14 3.0.0-rc2)"
expect "numbers before words" "-1:0" "$(cmp 3.0.5-1 3.0.5-rc)"
expect "1.x (a VM from before VERSION) is older" "-1:0" "$(cmp 1.x 2.0.0)"
expect "no version: none, status 2" "none:2" "$(cmp main 3.0.3)"
expect "empty: none, status 2" "none:2" "$(cmp "" 3.0.3)"
version_lt 2.9.1 3.0.3 && echo "ok   version_lt" || { echo "FAIL version_lt 2.9.1 3.0.3"; fail=1; }
version_lt "" 3.0.3 && { echo "FAIL version_lt with no version"; fail=1; } || echo "ok   version_lt: no version is not older"

# ---- omacvm_downgrade ----
g() { OUT=$(omacvm_downgrade "$@" 2>&1); G=$?; }   # -> OUT, G (0: it stops)
R=/x/co g disable "'Test'" 3.0.3 2.9.1; expect "a newer VM stops the run" 0 "$G"
has "it says both versions" "$OUT" "'Test' has OmacVM 3.0.3, this omacvm is 2.9.1 (/x/co/omacvm)"
has "and what to do" "$OUT" "run \`omacvm update\` first"
has "and how to go back on purpose" "$OUT" "--allow-downgrade"
g apply x 3.0.3 3.0.3; expect "the same version goes on" 1 "$G"
g apply x 2.9.1 3.0.3; expect "an older VM goes on" 1 "$G"
g apply x "" 3.0.3; expect "a VM without OmacVM goes on" 1 "$G"
g apply x garbage 3.0.3; expect "a VM that says no version goes on" 1 "$G"
OMACVM_ALLOW_DOWNGRADE=1 g apply x 3.0.3 2.9.1; expect "--allow-downgrade goes on" 1 "$G"
has "and says so" "$OUT" "goes back from OmacVM 3.0.3 to 2.9.1"
g apply x $'3.0.3\033[31mred' 2.9.1; expect "a VM's version with an escape still stops" 0 "$G"
[[ $OUT != *$'\033'* ]] && echo "ok   no escape from the VM in the message" || { echo "FAIL escape in: $OUT"; fail=1; }
OMACVM_APP_CLI=/A/OmacVM.app/Contents/Resources/omacvm/omacvm g apply x 3.0.4 3.0.3; expect "OmacVM.app's own older copy stops" 0 "$G"
has "and says to update the app" "$OUT" "update OmacVM.app first"

# ---- a checkout labelled 2.9.1 against a made-up OmacVM.app VM ----
H=$T/home; B=$T/bin; S=$T/state; CO=$T/co
mkdir -p "$H/Applications" "$B" "$S" "$CO"
cp -R "$R/omacvm" "$R/src" "$CO/"
echo 2.9.1 > "$CO/src/VERSION"
# The Mac side: never installed by a run that stops; a run that goes on stops here.
printf '#!/bin/bash\necho "$*" >> %q/mac-install\nexit 1\n' "$S" > "$CO/src/mac/install.sh"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
stub swift 'echo none'
# ssh: the probe answers from $S/probe; everything else is logged (stdin read).
stub ssh "S=$S"'
c=${!#}
case $c in
  *OMACVM_VERSION=*) echo PROBE >> "$S/ssh.log"; cat "$S/probe" ;;
  true) ;;
  *) printf "%s\n" "$c" >> "$S/ssh.log"; cat > /dev/null ;;
esac'
# OmacVM.app (test identity) with a VM folder; the app's settings domain is one nobody has.
fake_app() {   # VERSION
  local a="$H/Applications/OmacVM Test.app"
  mkdir -p "$a/Contents/Resources/scripts" "$a/Contents/Resources/omacvm/src"
  : > "$a/Contents/Resources/scripts/create-vm.sh"
  printf '#!/bin/bash\n' > "$a/Contents/Resources/omacvm/omacvm"; echo "$1" > "$a/Contents/Resources/omacvm/src/VERSION"
  plutil -create xml1 "$a/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string org.omacvm.app.test "$a/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$1" "$a/Contents/Info.plist"
}
D=$H/OmacVM/Test; mkdir -p "$D"
: > "$D/disk.img"
printf "NAME='Test'\nKEYBOARD='us'\n" > "$D/vm.env"
FEATS="fast-network=on control-centre=on"
reset_vm() {   # VM_VERSION
  echo "$FEATS" > "$D/features"; echo "mac=52:54:00:01:02:03" > "$D/fast-network"; echo "$1" > "$D/omacvm-version"
  printf 'OMACVM_USER=zorro\nOMACVM_VERSION=%s\nOMACVM_FEATURE_fast_network=on\nOMACVM_FEATURE_control_centre=on\n' "$1" > "$S/probe"
  rm -f "$S/ssh.log" "$S/mac-install"
}
start_qemu() {   # a process with the VM's disk on its command line, holding its SSH port
  python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(600)' "$S/port" "file=$D/disk.img,if=none" &
  QEMU=$!
  for _ in $(seq 50); do [[ -s $S/port ]] && break; sleep 0.1; done
  printf "SSH_PORT='%s'\n" "$(cat "$S/port")" >> "$D/vm.env"
}
start_qemu
run() {   # omacvm ARGS... -> OUT, RC
  OUT=$(cd "$T" && HOME=$H PATH="$B:$PATH" OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=org.omacvm.versionguard.none \
        PRLCTL=/nonexistent "$CO/omacvm" "$@" 2>&1 < /dev/null); RC=$?
}
untouched() {   # WHAT [SSH]: nothing changed on the Mac or in the VM (SSH: what went to it, the probe)
  expect "$1: exit 3" 3 "$RC"
  [[ ! -e $S/mac-install ]] && echo "ok   $1: the Mac side was not touched" || { echo "FAIL $1: the Mac side ran: $(cat "$S/mac-install")"; fail=1; }
  expect "$1: only the probe went to the VM" "${2-PROBE}" "$(sort -u "$S/ssh.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  expect "$1: the record is as it was" "$FEATS" "$(cat "$D/features")"
  [[ -s $D/fast-network ]] && echo "ok   $1: the fast network as it was" || { echo "FAIL $1: fast-network file gone"; fail=1; }
}
fake_app 3.0.3

reset_vm 3.0.3
run disable fast-network --vm Test --yes
untouched "disable on a newer VM (the feature toggle of #233)"
has "disable: what it says" "$OUT" "omacvm disable: 'Test' has OmacVM 3.0.3, this omacvm is 2.9.1"
has "disable: names the app's omacvm" "$OUT" "use the omacvm of OmacVM.app ($H/Applications/OmacVM Test.app/Contents/Resources/omacvm/omacvm)"

reset_vm 3.0.3
run enable vulkan --vm Test --yes
untouched "enable on a newer VM"

reset_vm 3.0.3
run apply --vm Test --vm-type app --yes
untouched "apply on a newer VM"
has "apply: what it says" "$OUT" "omacvm apply: 'Test' has OmacVM 3.0.3"

reset_vm 3.0.3
run apply --vm Test --vm-type app --reinstall bridge --yes
untouched "a repair (apply --reinstall) on a newer VM"

reset_vm 3.0.3
run update --vm Test --yes
untouched "update --vm on a newer VM"
has "update: what it says" "$OUT" "omacvm update: 'Test' has OmacVM 3.0.3"
has "update: not itself as the way out (it has pulled already)" "$OUT" "use an omacvm with OmacVM 3.0.3 or newer"

# All running VMs: only those OmacVM set up from this Mac (a remembered host key).
PIN="$H/Library/Application Support/omacvm-test/known_hosts/app-Test-$(printf %s Test | cksum | cut -d' ' -f1)"
mkdir -p "$(dirname "$PIN")"; echo "omacvm-vm ssh-ed25519 AAAA" > "$PIN"
reset_vm 3.0.3
run update --yes
untouched "update (all running VMs) with a newer one"
rm -f "$PIN"

reset_vm 3.0.3
run disable fast-network --vm Test --yes --allow-downgrade
[[ -e $S/mac-install ]] && echo "ok   --allow-downgrade: goes on (the Mac side ran)" || { echo "FAIL --allow-downgrade did not go on: $OUT"; fail=1; }
has "--allow-downgrade: says so" "$OUT" "goes back from OmacVM 3.0.3 to 2.9.1"

reset_vm 2.9.1
run disable fast-network --vm Test --yes
[[ -e $S/mac-install ]] && echo "ok   the same version: goes on" || { echo "FAIL the same version did not go on: $OUT"; fail=1; }

reset_vm 2.9.0
run apply --vm Test --vm-type app --yes
[[ -e $S/mac-install ]] && echo "ok   an older VM: goes on (an update)" || { echo "FAIL an older VM did not go on: $OUT"; fail=1; }

# A list of a newer VM: shown, its record not fixed (the fast-network file
# says on, the record off: an older omacvm would write its own list there).
reset_vm 3.0.3; echo "fast-network=off control-centre=on" > "$D/features"
run features --vm Test --json
expect "features --json on a newer VM: exit 0" 0 "$RC"
has "features --json: the VM's version" "$OUT" '"omacvm": "3.0.3"'
has "features --json: not fixed, and why" "$OUT" "the record was not fixed (the VM has a newer OmacVM than this omacvm)"
expect "features --json: the record as it was" "fast-network=off control-centre=on" "$(cat "$D/features")"
expect "features --json: nothing written in the VM" "PROBE" "$(sort -u "$S/ssh.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# A stopped VM: update --vm reads the app VM's folder.
kill "$QEMU" 2>/dev/null; wait "$QEMU" 2>/dev/null; QEMU=""
reset_vm 3.0.3
run update --vm Test --yes
untouched "update --vm on a stopped newer VM (its folder's omacvm-version)" ""

# ---- the entry script: OmacVM.app newer than this checkout ----
run --version
has "--version still answers" "$OUT" "OmacVM 2.9.1"
has "a newer OmacVM.app is named" "$OUT" "this omacvm ($CO/omacvm) is OmacVM 2.9.1, older than OmacVM.app 3.0.3 on this Mac"
fake_app 2.9.1
run --version
expect "the same version: nothing said" "OmacVM 2.9.1" "$OUT"
fake_app 2.9.0
run --version
expect "an older app: nothing said" "OmacVM 2.9.1" "$OUT"

# ---- the Bridge's cli file ----
mkdir -p "$T/old/src" "$T/new/src"; : > "$T/old/omacvm"; : > "$T/new/omacvm"
echo 2.9.1 > "$T/old/src/VERSION"; echo 3.0.3 > "$T/new/src/VERSION"
fake_app 3.0.3
APPCLI="$H/Applications/OmacVM Test.app/Contents/Resources/omacvm/omacvm"
F="$H/Library/Application Support/omacvm/cli"
cli_file() {   # CURRENT -> what cli_file_app leaves in the file
  mkdir -p "$(dirname "$F")"; printf '%s\n' "$1" > "$F"
  HOME=$H OMACVM_TEST_IDENTITY="" bash -c 'source "$1/src/lib/mac.sh"; cli_file_app "$2"' _ "$R" "$APPCLI"
  head -n1 "$F"
}
expect "an older checkout: OmacVM.app takes the cli file" "$APPCLI" "$(cli_file "$T/old/omacvm")"
expect "a checkout as new as the app keeps it" "$T/new/omacvm" "$(echo 3.0.3 > "$T/new/src/VERSION"; cli_file "$T/new/omacvm")"
expect "a newer checkout keeps it" "$T/new/omacvm" "$(echo 3.0.4 > "$T/new/src/VERSION"; cli_file "$T/new/omacvm")"
expect "a checkout without a version keeps it" "$T/new/omacvm" "$(rm "$T/new/src/VERSION"; cli_file "$T/new/omacvm")"
exit $fail
