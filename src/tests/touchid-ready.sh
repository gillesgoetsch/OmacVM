#!/bin/bash
# Touch ID turned on works at once and says so (3.0.4), without a VM or the
# Mac's helpers: omacvm apply's last word after turning it on ("ready: try
# sudo -v", or the one restart a VM started by OmacVM.app 3.0.3 or older
# needs, and an app's own switch), omacvm check's "Touch ID (Mac)" line
# (what is missing on the Mac), and the VM's "Touch ID last request" line
# (the PAM client's journal). Each part is cut out of its script and run
# with stand-ins.
#   src/tests/touchid-ready.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
part() {   # FILE FIRST-LINE-REGEX LAST-LINE-REGEX: the lines from the first to the last (excluded)
  awk -v a="$2" -v b="$3" '$0 ~ a { on = 1 } on && $0 ~ b { exit } on { print }' "$1"
}
source "$R/src/lib/app.sh"   # app_touchid_port
mkdir -p "$T/bin" "$T/vm/logs"
export PATH="$T/bin:$PATH"
port_line() { printf 'OmacVM: Mac links: Omanotch on, Gestures on, Bridge on, battery on, camera on, %s\n' "$1" > "$T/vm/logs/qemu.log"; }

# ---- omacvm apply: after "Touch ID on" ----
ap=$(part "$R/src/cmd/apply.sh" '^# Touch ID turned on by this run' '^log "done')
[[ $ap == *'Touch ID is ready'* ]] || { echo "FAIL apply.sh: no Touch ID ready block"; fail=1; }
apply_end() {   # TYPE PREV GUEST-ANSWER [RUNNING]
  ( TYPE=$1 VM=Omarchy IP=192.0.2.5 U=vincent TOKEN=1 NAMED=1 PREV=("$2") GUEST=$3 RUN=${4:-1}
    on() { [[ $1 == touch-id ]]; }
    feature_index() { echo 0; }
    gssh() { cat > /dev/null; printf '%b' "$GUEST"; }
    info() { echo "$*"; }
    app_dir() { echo "$T/vm"; }
    app_running_dir() { (( RUN )); }
    eval "$ap" )
}
port_line "Touch ID off, Touch ID port on"
expect "apply, app 3.0.4: on while it runs: ready at once" "Touch ID is ready: try sudo -v in an Omarchy terminal" \
  "$(apply_end app off 'ready\n')"
port_line "Touch ID off"
expect "apply, a VM OmacVM.app 3.0.3 started: one restart" "Touch ID: on - restart the VM once to finish (shut it down, then start it again)" \
  "$(apply_end app off 'ready\n')"
expect "apply, app VM not running: ready (the next start has the port)" "Touch ID is ready: try sudo -v in an Omarchy terminal" \
  "$(apply_end app off 'ready\n' 0)"
expect "apply, another VM type: ready, and 1Password's own switch" \
  "Touch ID is ready: try sudo -v in an Omarchy terminal|Touch ID: 1Password: turn on Settings › Security › Unlock using system authentication to use Touch ID" \
  "$(apply_end other off 'ready\n1password\toff\t1Password\tturn on Settings › Security › Unlock using system authentication to use Touch ID\nbitwarden\ton\tBitwarden\tuses Touch ID\n' | paste -sd'|' -)"
expect "apply, the VM side did not set it up: said, no ready" "Touch ID: not set up in the VM (see above); the password keeps working" \
  "$(apply_end other off '')"
expect "apply, Touch ID was on before (an update, another switch): nothing" "" "$(apply_end other on 'ready\n')"

# ---- omacvm check: "Touch ID (Mac)" ----
ck=$(part "$R/src/cmd/check.sh" '^# Touch ID .ADR 0041., the Mac.s side' '^FEATURE=omanotch   # the Mac links row below')
[[ $ck == *'"Touch ID (Mac)"'* ]] || { echo "FAIL check.sh: no Touch ID (Mac) row"; fail=1; }
mkdir -p "$T/keys" "$T/support"; : > "$T/bridge.log"
mac_check() {   # TYPE TOUCH_ID [BRIDGE-RUNNING]
  ( TYPE=$1 VM=Omarchy TID=$2 RUNNING=${3:-1} OMA_BRIDGE_SUPPORT=$T/support BRIDGE_LOG=$T/bridge.log L_BRIDGE=org.omacvm.bridge
    feat() { [[ $1 == touch_id ]] && echo "$TID" || echo on; }
    vm_key_file() { echo "$T/keys/$1-$2"; }
    running() { (( RUNNING )); }
    app_dir() { echo "$T/vm"; }
    ok() { echo "ok: $2"; }
    bad() { echo "fail: $2${3:+ (person)}"; }
    skip() { echo "skip: $2${3:+ (person)}"; }
    eval "$ck" )
}
printf '#!/bin/sh\necho "User 501:\t2 biometric template(s)"\necho "Operation performed successfully."\n' > "$T/bin/bioutil"; chmod +x "$T/bin/bioutil"
expect "check, Touch ID off: no Mac line" "" "$(mac_check other off)"
expect "check: no key on the Mac: said how" "fail: no Touch ID key for this VM on the Mac: omacvm apply --vm NAME makes it, or omacvm enable touch-id" \
  "$(mac_check other on)"
echo k > "$T/keys/other-Omarchy.touchid"; echo k > "$T/keys/app-Omarchy.touchid"
expect "check: the Bridge not running" "fail: OmacVM Bridge is not running, and it asks the Mac's Touch ID: omacvm update" "$(mac_check other on 0)"
expect "check: all there" "ok: the VM's key, OmacVM Bridge and 2 fingerprint(s) ready" "$(mac_check other on)"
expect "check, app: no relay socket" "fail: OmacVM Bridge has no socket for OmacVM.app's requests: omacvm update" "$(mac_check app on)"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/support/relay.sock"
port_line "Touch ID off"
expect "check, app: started by 3.0.3 without the port: the next start, for the person" \
  "skip: on from the VM's next start: shut it down, then start it again (OmacVM.app adds its Touch ID port at the start) (person)" "$(mac_check app on)"
port_line "Touch ID off, Touch ID port on"
printf '%s\n' "2026-10-07 06:52:40 omacvm-bridge: touchid: from relay (Omarchy): 409 unknown-vm" \
  "2026-10-07 07:01:09 omacvm-bridge: touchid: from relay (Other): 200 sudo yes" > "$T/bridge.log"
expect "check, app with the port: ready, and this VM's last request" \
  "ok: the VM's key, OmacVM Bridge and 2 fingerprint(s) ready; last request 06:52: 409 unknown-vm" "$(mac_check app on)"
printf '#!/bin/sh\necho "User 501:\t0 biometric template(s)"\n' > "$T/bin/bioutil"
expect "check: no fingerprint on the Mac: for the person" \
  "fail: no fingerprint in this Mac's Touch ID (or no sensor): System Settings › Touch ID & Password; until then the VM asks for the password (person)" \
  "$(mac_check other on)"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/bioutil"; : > "$T/bridge.log"
expect "check: bioutil says nothing: no claim about fingerprints" "ok: the VM's key, OmacVM Bridge ready" "$(mac_check other on)"

# ---- the VM's check: "Touch ID last request" (journalctl -t omacvm-touchid) ----
gk=$(part "$R/src/guest/check.sh" '^  # How the last request went' '^  # The Mac.s Touch ID panel draws')
[[ $gk == *'"Touch ID last request"'* ]] || { echo "FAIL guest/check.sh: no Touch ID last request row"; fail=1; }
guest_check() {   # JOURNAL-LINE
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$T/bin/journalctl"; chmod +x "$T/bin/journalctl"
  ( TOUCH_ID=on
    ok() { echo "ok: $2"; }
    skip() { echo "skip: $2"; }
    eval "$gk" )
}
expect "VM: no request yet" "skip: none yet: try sudo -v in a terminal" "$(guest_check "")"
expect "VM: the last one was a yes" "ok: 07:01: sudo for vincent, Touch ID yes" \
  "$(guest_check "2026-10-07T07:01:09+02:00 omarchy omacvm-touchid[812]: sudo for vincent: Touch ID yes")"
expect "VM: the last one went to the password: why" "skip: 06:52: polkit for vincent: the password (the Mac is still starting: try again in a moment)" \
  "$(guest_check "2026-10-07T06:52:40+0200 omarchy omacvm-touchid[77]: polkit for vincent: the password (the Mac is still starting: try again in a moment)")"
exit $fail
